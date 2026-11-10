import SwiftUI
import AppKit

/// Lets SwiftUI buttons and keyboard shortcuts drive the AppKit zoom view.
final class ZoomController: ObservableObject {
    fileprivate weak var scrollView: ZoomScrollView?
    /// Magnification relative to the image's real size (1 = 100%)
    @Published fileprivate(set) var scale: CGFloat = 1
    @Published fileprivate(set) var minScale: CGFloat = 0.1
    @Published fileprivate(set) var maxScale: CGFloat = 8

    func zoomIn() { scrollView?.zoom(by: 1.25) }
    func zoomOut() { scrollView?.zoom(by: 1 / 1.25) }
    func fit() { scrollView?.fitToWindow() }
    func actualSize() { scrollView?.zoom(to: 1) }
    func zoom(to scale: CGFloat) { scrollView?.zoom(to: scale) }
}

/// Image view with pinch, ⌘/⌥ + scroll wheel and double-click zoom, and drag to pan.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage?
    /// Which photo is shown: a different photo always starts fitted to the window
    let photo: URL?
    let controller: ZoomController

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onZoomChange = { [weak controller] scale, range in
            controller?.scale = scale
            controller?.minScale = range.lowerBound
            controller?.maxScale = range.upperBound
        }
        controller.scrollView = view
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        controller.scrollView = view
        if view.photo != photo {
            view.photo = photo
            view.setImage(image, keepZoom: false)
        } else if view.imageView.image !== image {
            view.setImage(image, keepZoom: true)
        }
    }
}

/// Keeps an image smaller than the window centred instead of stuck in the corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

final class ZoomScrollView: NSScrollView {
    let imageView = NSImageView()
    var photo: URL?
    var onZoomChange: ((CGFloat, ClosedRange<CGFloat>) -> Void)?
    /// While true the image follows the window size
    private var isFit = true
    private var dragStart: NSPoint?

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = imageView
        imageView.imageScaling = .scaleAxesIndependently
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = .black
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fitScale: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return min(contentSize.width / size.width, contentSize.height / size.height)
    }

    private func updateLimits() {
        minMagnification = min(fitScale, 1)
        maxMagnification = max(fitScale * 10, 8)
    }

    /// keepZoom: a corrected version of the same picture keeps the current zoom and position
    func setImage(_ image: NSImage?, keepZoom: Bool) {
        let sameSize = image != nil && image?.size == imageView.image?.size
        imageView.image = image
        if keepZoom, sameSize { return }
        // Image size in points equals its pixel count, so magnification 1 = 100%
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        fitToWindow()
    }

    func fitToWindow() {
        updateLimits()
        magnification = fitScale
        isFit = true
        notifyZoom()
    }

    private func notifyZoom() {
        onZoomChange?(magnification, minMagnification...maxMagnification)
    }

    func zoom(to target: CGFloat, at point: NSPoint? = nil) {
        updateLimits()
        let clamped = min(max(target, minMagnification), maxMagnification)
        let visible = contentView.bounds
        setMagnification(clamped, centeredAt: point ?? NSPoint(x: visible.midX, y: visible.midY))
        isFit = abs(clamped - fitScale) < 0.001
        notifyZoom()
    }

    func zoom(by factor: CGFloat, at point: NSPoint? = nil) {
        zoom(to: magnification * factor, at: point)
    }

    @objc private func liveMagnifyEnded() {
        isFit = abs(magnification - fitScale) < 0.001
        notifyZoom()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isFit { fitToWindow() } else { updateLimits(); notifyZoom() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) else {
            return super.scrollWheel(with: event)
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
        zoom(by: exp(delta), at: contentView.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if isFit {
                zoom(to: fitScale < 1 ? 1 : fitScale * 2, at: point)
            } else {
                fitToWindow()
            }
            dragStart = nil
        } else {
            dragStart = event.locationInWindow
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        var origin = contentView.bounds.origin
        origin.x -= event.deltaX / magnification
        origin.y += event.deltaY / magnification
        let rect = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: rect.origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
