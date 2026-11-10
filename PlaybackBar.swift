import SwiftUI
import AppKit

/// What the film controls show and do, shared by both players (macOS for MP4/MOV, mpv for the rest).
/// Each player fills in the values and the actions.
@MainActor final class PlaybackState: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    /// 0…1
    @Published var volume: Double = 1
    @Published var muted = false
    @Published var rate: Double = 1
    @Published var failed = false
    /// The picture's size as shown (after the file's own rotation), to tell portrait films from landscape ones
    @Published var videoSize: CGSize = .zero

    var onTogglePlay: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onVolume: (Double) -> Void = { _ in }
    var onMute: (Bool) -> Void = { _ in }
    var onRate: (Double) -> Void = { _ in }
    /// true = one frame forward, false = one back (pauses)
    var onFrameStep: (Bool) -> Void = { _ in }

    func togglePlay() { onTogglePlay() }
    func seek(to seconds: Double) { onSeek(min(max(seconds, 0), max(duration - 0.05, 0))) }
    func skip(by seconds: Double) { seek(to: position + seconds) }
    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        onVolume(volume)
        if muted, volume > 0 { toggleMute() }
    }
    func toggleMute() { muted.toggle(); onMute(muted) }
    func setRate(_ value: Double) { rate = value; onRate(value) }
    func step(forward: Bool) { onFrameStep(forward) }
}

extension Notification.Name {
    /// ⇧← / ⇧→ in the large view: skip in the film (userInfo "seconds")
    static let viewerSkip = Notification.Name("local.przegladarka.zdjec.skip")
    /// , / . : one frame back / forward (userInfo "forward")
    static let viewerFrameStep = Notification.Name("local.przegladarka.zdjec.frameStep")
    static let viewerToggleMute = Notification.Name("local.przegladarka.zdjec.toggleMute")
    /// ⌘L / ⌘R on a film: turn it (userInfo "clockwise")
    static let viewerRotate = Notification.Name("local.przegladarka.zdjec.rotate")
    /// The app was locked: a playing film stops
    static let viewerPauseForLock = Notification.Name("local.przegladarka.zdjec.pauseForLock")
}

/// The film part of the control capsule: elapsed time, progress, total (or remaining) time
struct PlaybackProgress: View {
    @ObservedObject var state: PlaybackState
    @State private var scrubbing: Double?
    @State private var showRemaining = false

    var body: some View {
        HStack(spacing: 8) {
            Text(PlaybackExtras.time(scrubbing ?? state.position))
                .frame(minWidth: 40, alignment: .trailing)
            ThinSlider(value: Binding(get: { scrubbing ?? state.position }, set: { scrubbing = $0 }),
                       range: 0...max(state.duration, 0.1)) { finished in
                if finished, let target = scrubbing {
                    state.seek(to: target)
                    scrubbing = nil
                }
            }
            .frame(width: 300)
            Button { showRemaining.toggle() } label: {
                Text(showRemaining ? "-" + PlaybackExtras.time(max(state.duration - state.position, 0))
                                   : PlaybackExtras.time(state.duration))
                    .frame(minWidth: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Czas całkowity lub pozostały")
        }
        .font(.callout.monospacedDigit())
    }
}

/// Speed, sound and volume for the film part of the control capsule
struct PlaybackExtras: View {
    @ObservedObject var state: PlaybackState

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button { state.setRate(rate) } label: {
                        if rate == state.rate { Label(Self.rateText(rate), systemImage: "checkmark") } else { Text(Self.rateText(rate)) }
                    }
                }
            } label: {
                Text(Self.rateText(state.rate)).font(.callout.weight(.semibold))
                    .foregroundStyle(state.rate == 1 ? Color.primary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Prędkość odtwarzania")
            Button { state.toggleMute() } label: { Image(systemName: volumeSymbol).frame(width: 22) }
                .help(state.muted ? String(localized: "Włącz dźwięk (M)") : String(localized: "Wycisz (M)"))
            ThinSlider(value: Binding(get: { state.muted ? 0 : state.volume }, set: { state.setVolume($0) }),
                       range: 0...1) { _ in }
                .frame(width: 70)
        }
    }

    private var volumeSymbol: String {
        if state.muted || state.volume == 0 { return "speaker.slash.fill" }
        return state.volume < 0.34 ? "speaker.wave.1.fill" : state.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private static func rateText(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate).replacingOccurrences(of: ".", with: ",")
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The film keys (space, ⇧←/⇧→, , and ., M) and pausing on lock, routed to the player
struct PlaybackKeys: ViewModifier {
    @ObservedObject var state: PlaybackState
    let active: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .viewerTogglePause)) { _ in if active { state.togglePlay() } }
            .onReceive(NotificationCenter.default.publisher(for: .viewerSkip)) { note in
                if active { state.skip(by: note.userInfo?["seconds"] as? Double ?? 0) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .viewerFrameStep)) { note in
                if active { state.step(forward: note.userInfo?["forward"] as? Bool ?? true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .viewerToggleMute)) { _ in if active { state.toggleMute() } }
            .onReceive(NotificationCenter.default.publisher(for: .viewerPauseForLock)) { _ in
                if active, state.playing { state.togglePlay() }
            }
    }
}

/// Slim bar: white fill on a grey track; under the pointer it thickens, takes the accent colour and shows a knob
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Called with true when a drag (or click) ends
    let onEditing: (Bool) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let active = hovering || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.3)).frame(height: active ? 6 : 4)
                Capsule().fill(active ? Color.accentColor : Color.white)
                    .frame(width: max(geometry.size.width * fraction, 0), height: active ? 6 : 4)
                if active {
                    Circle().fill(.white).frame(width: 13, height: 13)
                        .offset(x: geometry.size.width * fraction - 6.5)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    let x = min(max(drag.location.x / max(geometry.size.width, 1), 0), 1)
                    value = range.lowerBound + x * span
                    onEditing(false)
                }
                .onEnded { _ in
                    dragging = false
                    onEditing(true)
                })
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: hovering || dragging)
    }
}
