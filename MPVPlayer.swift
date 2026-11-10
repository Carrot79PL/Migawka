import SwiftUI
import AppKit
import OpenGL.GL3
import CMpv

/// Optional mpv (brew install mpv): plays nearly any codec and container directly, without conversion.
/// Used for films the macOS player can't handle. libmpv is linked weakly, so nothing here may be
/// called unless `isAvailable`.
enum MPV {
    static let libraryPath = "/opt/homebrew/opt/mpv/lib/libmpv.2.dylib"
    static let isAvailable = FileManager.default.fileExists(atPath: libraryPath)
}

/// The film itself, played by mpv; the controls are the shared PlaybackBar, driven through `state`.
struct MPVPlayer: View {
    let url: URL
    @ObservedObject var state: PlaybackState

    var body: some View {
        MPVVideoView(url: url, state: state)
            .background(Color.black)
            .onTapGesture(count: 1) { state.togglePlay() }
            .overlay {
                if state.failed {
                    VStack(spacing: 10) {
                        Image(systemName: "film").font(.system(size: 44))
                        Text("Nie udało się odtworzyć tego filmu").font(.title3)
                        Text("Plik jest uszkodzony albo nie zawiera obrazu, który da się odczytać.")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
            }
    }
}

private struct MPVVideoView: NSViewRepresentable {
    let url: URL
    let state: PlaybackState

    func makeNSView(context: Context) -> MPVHostView {
        let view = MPVHostView()
        let layer = view.mpvLayer
        layer.state = state
        state.onTogglePlay = { [weak layer] in layer?.command(["cycle", "pause"]) }
        state.onSeek = { [weak layer] in layer?.command(["seek", String($0), "absolute"]) }
        state.onVolume = { [weak layer] in layer?.command(["set", "volume", String(Int(($0 * 100).rounded()))]) }
        state.onMute = { [weak layer] in layer?.command(["set", "mute", $0 ? "yes" : "no"]) }
        state.onRate = { [weak layer] in layer?.command(["set", "speed", String($0)]) }
        state.onFrameStep = { [weak layer] in layer?.command([$0 ? "frame-step" : "frame-back-step"]) }
        return view
    }

    func updateNSView(_ view: MPVHostView, context: Context) {
        view.mpvLayer.load(url)
    }

    static func dismantleNSView(_ view: MPVHostView, coordinator: ()) {
        view.mpvLayer.shutdown()
    }
}

/// Space bar toggles pause while the film has focus (arrow keys stay with photo navigation).
final class MPVHostView: NSView {
    let mpvLayer = MPVLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = mpvLayer
        mpvLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { mpvLayer.command(["cycle", "pause"]) } else { super.keyDown(with: event) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

/// Renders mpv's picture through its OpenGL render API into a Core Animation layer.
final class MPVLayer: CAOpenGLLayer {
    weak var state: PlaybackState?
    private var mpv: OpaquePointer?
    private var render: OpaquePointer?
    private var loaded: URL?
    /// mpv can only start a film once the picture output exists, i.e. after the layer's first draw
    private var pending: URL?
    private let events = DispatchQueue(label: "local.przegladarka.zdjec.mpv")

    override init() {
        super.init()
        isAsynchronous = false
        backgroundColor = NSColor.black.cgColor
        guard MPV.isAvailable, let handle = mpv_create() else { return }
        mpv = handle
        // Local playback only, nothing read from or written to disk besides the film itself:
        // no config files, scripts, network streams, watch-later or screenshots
        let options: [(String, String)] = [
            ("vo", "libmpv"), ("hwdec", "auto-safe"), ("config", "no"), ("load-scripts", "no"),
            ("ytdl", "no"), ("osc", "no"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"), ("terminal", "no"), ("msg-level", "all=no"),
            ("cache-on-disk", "no"), ("save-position-on-quit", "no"), ("resume-playback", "no"),
            ("load-auto-profiles", "no"), ("demuxer-lavf-o", "protocol_whitelist=file"),
            ("keep-open", "yes"), ("idle", "yes"), ("audio-file-auto", "no"), ("sub-auto", "no"),
            // mpv's built-in Lua scripts (on-screen controls, console, menus) are not used; they would also
            // need executable memory, which the app's hardened runtime rightly refuses
            ("load-stats-overlay", "no"), ("load-console", "no"), ("load-osd-console", "no"),
            ("load-commands", "no"), ("load-context-menu", "no"), ("load-select", "no"),
            ("load-positioning", "no"), ("load-input-conf", "no"), ("load-config-file", "no"),
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            mpv = nil
            return
        }
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 5, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 6, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 7, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 8, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 9, "dheight", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(handle, { ctx in
            let layer = Unmanaged<MPVLayer>.fromOpaque(ctx!).takeUnretainedValue()
            layer.events.async { layer.readEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) {
        guard url != loaded else { return }
        loaded = url
        if render != nil {
            command(["loadfile", url.path, "replace"])
        } else {
            pending = url
            setNeedsDisplay()
        }
    }

    func command(_ args: [String]) {
        guard let mpv else { return }
        var cStrings = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                _ = mpv_command(mpv, $0)
            }
        }
    }

    /// Stops playback and frees mpv; the render context goes first, while mpv is still alive
    func shutdown() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        if let render {
            if let context = cglContext { CGLSetCurrentContext(context) }
            mpv_render_context_set_update_callback(render, nil, nil)
            mpv_render_context_free(render)
            self.render = nil
        }
        mpv = nil
        events.sync {}
        mpv_terminate_destroy(handle)
    }

    private var cglContext: CGLContextObj?

    private func readEvents() {
        guard let mpv else { return }
        while true {
            guard let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { return }
            if event.event_id == MPV_EVENT_SHUTDOWN { return }
            if event.event_id == MPV_EVENT_END_FILE, let data = event.data {
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.state?.failed = true } }
                }
            }
            guard event.event_id == MPV_EVENT_PROPERTY_CHANGE, let data = event.data else { continue }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            var number: Double?
            var flag: Bool?
            if property.format == MPV_FORMAT_DOUBLE, let value = property.data {
                number = value.assumingMemoryBound(to: Double.self).pointee
            } else if property.format == MPV_FORMAT_FLAG, let value = property.data {
                flag = value.assumingMemoryBound(to: Int32.self).pointee != 0
            } else if property.format == MPV_FORMAT_INT64, let value = property.data {
                number = Double(value.assumingMemoryBound(to: Int64.self).pointee)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let state = self.state else { return }
                    switch name {
                    case "time-pos": state.position = number ?? 0
                    case "duration": state.duration = number ?? 0
                    case "pause": state.playing = !(flag ?? false)
                    case "mute": state.muted = flag ?? false
                    case "volume": state.volume = min(max((number ?? 100) / 100, 0), 1)
                    case "speed": state.rate = number ?? 1
                    case "dwidth": state.videoSize.width = number ?? 0
                    case "dheight": state.videoSize.height = number ?? 0
                    case "eof-reached" where flag == true:
                        NotificationCenter.default.post(name: .viewerVideoDidFinish, object: nil)
                    default: break
                    }
                }
            }
        }
    }

    // MARK: OpenGL

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        return format ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat format: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: format)
        cglContext = context
        CGLSetCurrentContext(context)
        createRenderContext()
        return context
    }

    private func createRenderContext() {
        guard let mpv, render == nil else { return }
        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }, get_proc_address_ctx: nil)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        withUnsafeMutablePointer(to: &initParams) { initPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var context: OpaquePointer?
            if mpv_render_context_create(&context, mpv, &params) >= 0 { render = context }
        }
        if let render {
            mpv_render_context_set_update_callback(render, { ctx in
                let layer = Unmanaged<MPVLayer>.fromOpaque(ctx!).takeUnretainedValue()
                DispatchQueue.main.async { layer.frameReady() }
            }, Unmanaged.passUnretained(self).toOpaque())
            if let pending {
                self.pending = nil
                DispatchQueue.main.async { self.command(["loadfile", pending.path, "replace"]) }
            }
        }
    }

    /// mpv has something new: ask it what (as its API requires) and draw a new frame right away rather than
    /// at the next screen refresh, which would leave mpv's decoder waiting and the picture frozen
    fileprivate func frameReady() {
        guard let render else { return }
        let flags = mpv_render_context_update(render)
        if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            setNeedsDisplay()
            display()
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        render != nil
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let render else { return }
        var fboBinding: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fboBinding)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var fbo = mpv_opengl_fbo(fbo: Int32(fboBinding), w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                mpv_render_context_render(render, &params)
            }
        }
        glFlush()
        mpv_render_context_report_swap(render)
    }
}
