import SwiftUI
import AppKit
import AVKit
import AVFoundation

struct VideoInfo {
    /// macOS can decode it directly
    let playable: Bool
    /// Codec name for messages, e.g. "XVID"
    let codec: String?
}

enum VideoSupport {
    /// Containers the macOS player handles fully. Others (AVI, MKV…) may open and even give a frame,
    /// yet fail in the player, so with ffmpeg they are always repackaged first.
    static let nativeContainers: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2"]

    /// Checks the video really decodes: the AVI container opens on recent macOS, but codecs such as
    /// XviD/DivX inside it often don't, which would show a black player.
    static func inspect(_ url: URL) async -> VideoInfo {
        let url = await PhotoLibrary.playable(url)
        let asset = AVURLAsset(url: url)
        var codec: String?
        var playable = false
        if (try? await asset.load(.isPlayable)) == true,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let format = try? await track.load(.formatDescriptions).first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
            }
            if (try? await track.load(.isDecodable)) == true {
                playable = await decodesFrame(asset)
            }
        }
        if FFmpeg.isAvailable, !nativeContainers.contains(url.pathExtension.lowercased()) {
            playable = false
        }
        if codec == nil, !playable, FFmpeg.isAvailable {
            codec = await FFmpeg.probe(url).codec
        }
        return VideoInfo(playable: playable, codec: codec)
    }

    static func decodesFrame(_ asset: AVAsset) async -> Bool {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 64)
        return (try? await generator.image(at: .zero)) != nil
    }

    static func thumbnail(_ url: URL, maxPixels: CGFloat) async -> NSImage? {
        if PhotoLibrary.isAsset(url) { return await PhotoLibrary.thumbnail(url, maxPixels: maxPixels) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        // A frame a little into the clip is more telling than the (often black) first one
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let time = CMTime(seconds: duration.isFinite ? min(1, duration / 2) : 0, preferredTimescale: 600)
        if let cg = try? await generator.image(at: time).image {
            return NSImage(cgImage: cg, size: .zero)
        }
        return FFmpeg.isAvailable ? await FFmpeg.thumbnail(url, maxPixels: maxPixels) : nil
    }

    static func duration(_ url: URL) async -> String? {
        var seconds = PhotoLibrary.duration(url)
        let url = await PhotoLibrary.playable(url)
        if seconds == nil, let time = try? await AVURLAsset(url: url).load(.duration) {
            let s = CMTimeGetSeconds(time)
            if s.isFinite, s > 0 { seconds = s }
        }
        if seconds == nil, FFmpeg.isAvailable { seconds = await FFmpeg.probe(url).duration }
        guard let seconds else { return nil }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian, Array.init)
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).uppercased() ?? "?"
    }
}

/// Optional ffmpeg (brew install ffmpeg) for formats macOS can't decode, e.g. XviD/DivX in AVI.
/// Thumbnails come back through a pipe straight into memory; videos are converted onto the RAM disk only.
enum FFmpeg {
    static let path = Subprocess.locate("ffmpeg")
    static var isAvailable: Bool { path != nil }

    /// Local files only: a crafted video can't make ffmpeg fetch anything from the network
    private static let safety = ["-nostdin", "-hide_banner", "-protocol_whitelist", "file,pipe"]
    /// Input options that get as much as possible out of damaged or incomplete files: decoding errors
    /// are skipped, broken packets dropped and missing timestamps (common in AVI) filled in
    private static let tolerant = ["-err_detect", "ignore_err", "-fflags", "+genpts+discardcorrupt"]

    private static let lock = NSLock()
    private static var converted: [URL: URL] = [:]

    /// Forget conversions (their files vanish with the RAM disk)
    static func clearCache() {
        lock.lock(); defer { lock.unlock() }
        converted.removeAll()
    }

    private static func cachedCopy(of url: URL) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return converted[url]
    }

    private static func remember(_ copy: URL, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        converted[url] = copy
    }

    static func probe(_ url: URL) async -> (duration: Double?, codec: String?) {
        guard let path else { return (nil, nil) }
        // Without an output ffmpeg exits with an error, but still prints the stream details
        let info = await Subprocess.run(path, safety + tolerant + ["-i", url.path]).stderr
        var duration: Double?
        if let range = info.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let parts = info[range].dropFirst("Duration: ".count).split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { duration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        var codec: String?
        if let range = info.range(of: #"Video: [A-Za-z0-9_]+"#, options: .regularExpression) {
            codec = String(info[range].dropFirst("Video: ".count)).uppercased()
        }
        return (duration, codec)
    }

    static func thumbnail(_ url: URL, maxPixels: CGFloat) async -> NSImage? {
        guard let path else { return nil }
        let n = Int(maxPixels)
        for seek in ["1", "0"] {  // very short clips have no frame at 1 s
            let result = await Subprocess.run(path, safety + [
                "-loglevel", "error", "-ss", seek] + tolerant + ["-i", url.path, "-frames:v", "1",
                "-vf", "scale=\(n):\(n):force_original_aspect_ratio=decrease",
                "-f", "image2pipe", "-c:v", "png", "pipe:1",
            ], captureStdout: true)
            if !result.stdout.isEmpty, let image = NSImage(data: result.stdout) { return image }
        }
        return nil
    }

    /// Pictures macOS can't read at all (badly damaged, or a format ImageIO lacks); the result comes
    /// back through a pipe into memory. Runs on the calling (background) thread.
    static func decodeImage(_ url: URL, maxPixels: CGFloat?) -> NSImage? {
        guard let path else { return nil }
        var args = safety + ["-loglevel", "error"] + tolerant + ["-i", url.path, "-frames:v", "1"]
        if let maxPixels {
            let n = Int(maxPixels)
            args += ["-vf", "scale=\(n):\(n):force_original_aspect_ratio=decrease"]
        }
        let result = Subprocess.runBlocking(path, args + ["-f", "image2pipe", "-c:v", "png", "pipe:1"], captureStdout: true)
        return result.stdout.isEmpty ? nil : NSImage(data: result.stdout)
    }

    /// Picture codecs macOS has no decoder for (MPEG-4 Part 2 = XviD/DivX, old Windows codecs…):
    /// repackaging can't help, so these go straight to conversion
    private static let undecodable: Set<String> = [
        "MPEG4", "MSMPEG4V1", "MSMPEG4V2", "MSMPEG4V3", "WMV1", "WMV2", "WMV3", "VC1", "FLV1",
        "VP6", "VP6F", "VP8", "THEORA", "MPEG1VIDEO", "MPEG2VIDEO", "H263", "RV40", "CINEPAK", "INDEO5",
        "XVID", "DIVX", "DX50", "DIV3", "MP4V", "FMP4",
    ]

    /// Makes a film playable as it goes: ffmpeg writes a fragmented MP4 onto the RAM disk and playback
    /// starts after its first second, while the rest is still being repackaged or converted.
    /// The returned stream keeps growing until `isComplete`; cancelling the calling task stops ffmpeg.
    static func playableStream(of url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> VideoStream? {
        if let cached = cachedCopy(of: url), FileManager.default.fileExists(atPath: cached.path) {
            return VideoStream(url: cached, complete: true)
        }
        guard let path, let root = SecureTemp.shared.root() else { return nil }
        let info = await probe(url)
        let duration = info.duration ?? 0
        let dir = root.appendingPathComponent("video-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = safety + ["-loglevel", "error", "-nostats", "-progress", "pipe:2"] + tolerant
            + ["-i", url.path, "-map", "0:v:0", "-map", "0:a:0?"]
        // Fragments of about a second, each readable on its own, so the file plays while it grows
        let output = ["-c:a", "aac", "-b:a", "192k",
                      "-movflags", "+empty_moov+default_base_moof", "-frag_duration", "1000000", "-f", "mp4"]
        // Keyframes every 2 s keep seeking quick in converted films
        let convert = ["-pix_fmt", "yuv420p", "-g", "50"]
        var attempts: [(String, [String])] = []
        if !undecodable.contains(info.codec ?? "") {
            // Picture copied as is: seconds even for long films
            attempts.append(("copy.mp4", ["-c:v", "copy"]))
        }
        attempts.append(("h264.mp4", ["-c:v", "h264_videotoolbox", "-b:v", "8M"] + convert))
        attempts.append(("x264.mp4", ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"] + convert))

        for (name, codecArgs) in attempts {
            if Task.isCancelled { break }
            let out = dir.appendingPathComponent(name)
            let stream = VideoStream(url: out, complete: false)
            progress(0)
            let job = Task.detached(priority: .userInitiated) {
                let result = await Subprocess.run(path, input + codecArgs + output + ["-y", out.path]) { line in
                    // -progress reports "out_time_us=<microseconds written>"
                    guard duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                    progress(min(max(us / 1_000_000 / duration, 0), 1))
                }
                stream.finish()
                if result.ok, !Task.isCancelled { remember(out, for: url) }
            }
            stream.job = job
            // Wait for the first second of film (or the end of a very short one), then check macOS decodes it
            let enough = min(1.0, max(duration - 0.1, 0.1))
            while !stream.isComplete, !Task.isCancelled {
                if let d = try? await AVURLAsset(url: out).load(.duration), d.seconds.isFinite, d.seconds >= enough { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if Task.isCancelled { stream.cancel(); break }
            if await VideoSupport.decodesFrame(AVURLAsset(url: out)) { return stream }
            stream.cancel()
            await job.value
            try? FileManager.default.removeItem(at: out)
        }
        try? FileManager.default.removeItem(at: dir)
        return nil
    }
}

/// A film ffmpeg is still writing (or has finished writing) onto the RAM disk.
final class VideoStream: @unchecked Sendable, Equatable {
    let url: URL
    private let lock = NSLock()
    private var complete: Bool
    fileprivate var job: Task<Void, Never>?

    init(url: URL, complete: Bool) {
        self.url = url
        self.complete = complete
    }

    /// The file won't grow any more (finished, failed or stopped)
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return complete }
    fileprivate func finish() { lock.lock(); complete = true; lock.unlock() }

    /// Stops ffmpeg if it is still working
    func cancel() { job?.cancel() }

    static func == (a: VideoStream, b: VideoStream) -> Bool { a === b }
}

extension Notification.Name {
    /// The film in the large view played to its real end (not just the end of the part converted so far)
    static let viewerVideoDidFinish = Notification.Name("local.przegladarka.zdjec.videoDidFinish")
    /// Space bar in the large view: play or pause the film
    static let viewerTogglePause = Notification.Name("local.przegladarka.zdjec.togglePause")
}

/// Full-size video player for the large view. For a film still being converted it reopens the growing
/// file shortly before reaching the end of what was there, keeping the position, so playback carries on.
struct VideoPlayer: NSViewRepresentable {
    let url: URL
    /// nil for a file macOS plays directly
    let stream: VideoStream?
    /// The app's own controls (PlaybackBar) drive the player through this
    let state: PlaybackState

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        // Don't publish the file name to Control Center's "Now Playing"
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.bind(state)
        context.coordinator.show(url, stream: stream, in: view)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player?.pause()
        view.player = nil
    }

    @MainActor final class Coordinator: NSObject {
        private weak var view: AVPlayerView?
        private var url: URL?
        private var stream: VideoStream?
        /// The loaded item already holds the whole film
        private var loadedComplete = true
        private var loadedSize: Int64 = 0
        /// Playback reached the end of the converted part and goes on once more is written
        private var resumeWhenGrown = false
        private var timer: Timer?
        private var endObserver: NSObjectProtocol?
        private weak var state: PlaybackState?
        private var timeObserver: Any?
        private var statusObservation: NSKeyValueObservation?

        /// Connects the bar's buttons to this player and keeps its time, state and volume up to date
        func bind(_ state: PlaybackState) {
            guard self.state !== state else { return }
            self.state = state
            state.onTogglePlay = { [weak self] in
                guard let player = self?.view?.player else { return }
                if player.timeControlStatus == .paused { player.playImmediately(atRate: Float(state.rate)) } else { player.pause() }
            }
            state.onSeek = { [weak self] seconds in
                self?.view?.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
            }
            state.onVolume = { [weak self] in self?.view?.player?.volume = Float($0) }
            state.onMute = { [weak self] in self?.view?.player?.isMuted = $0 }
            state.onRate = { [weak self] rate in
                guard let player = self?.view?.player else { return }
                player.defaultRate = Float(rate)
                if player.rate != 0 { player.rate = Float(rate) }
            }
            state.onFrameStep = { [weak self] forward in
                guard let player = self?.view?.player else { return }
                player.pause()
                player.currentItem?.step(byCount: forward ? 1 : -1)
            }
        }

        private func observe(_ player: AVPlayer) {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self, weak player] time in
                MainActor.assumeIsolated {
                    guard let self, let state = self.state, let player else { return }
                    state.position = time.seconds.isFinite ? time.seconds : 0
                    // A film still being converted grows: show the length known so far
                    let length = player.currentItem?.duration.seconds ?? 0
                    if length.isFinite, length > 0 { state.duration = length }
                    if let size = player.currentItem?.presentationSize, size != state.videoSize { state.videoSize = size }
                }
            }
            statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.timeControlStatus != .paused
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.state?.playing = playing } }
            }
        }

        func show(_ url: URL, stream: VideoStream?, in view: AVPlayerView) {
            guard url != self.url else { return }
            stop()
            self.view = view
            self.url = url
            self.stream = stream
            let player = AVPlayer()
            if let state {
                player.volume = Float(state.volume)
                player.isMuted = state.muted
                player.defaultRate = Float(state.rate)
            }
            view.player = player
            observe(player)
            load(at: .zero, playing: true)
            if stream != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            if let timeObserver { view?.player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            statusObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            url = nil
            stream = nil
        }

        private func load(at time: CMTime, playing: Bool) {
            guard let url, let player = view?.player else { return }
            loadedComplete = stream?.isComplete ?? true
            loadedSize = fileSize(url)
            resumeWhenGrown = false
            let item = AVPlayerItem(url: url)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            player.replaceCurrentItem(with: item)
            if time > .zero {
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    if playing { player.play() }
                }
            } else if playing {
                player.play()
            }
        }

        /// Reopens the growing file once more of it is ready and playback nears the end of the loaded part
        private func tick() {
            guard !loadedComplete, let url, let player = view?.player, let item = player.currentItem else { return }
            let grown = fileSize(url) > loadedSize
            let done = stream?.isComplete ?? true
            let remaining = item.duration.seconds - player.currentTime().seconds
            let nearEnd = !remaining.isFinite || remaining < 3
            if grown, nearEnd || done || resumeWhenGrown {
                load(at: player.currentTime(), playing: player.rate > 0 || resumeWhenGrown)
            }
        }

        private func reachedEnd() {
            if loadedComplete {
                NotificationCenter.default.post(name: .viewerVideoDidFinish, object: nil)
            } else {
                // Caught up with the conversion: carry on as soon as the next part is written
                resumeWhenGrown = true
            }
        }

        private func fileSize(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}
