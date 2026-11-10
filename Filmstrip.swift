import SwiftUI
import AppKit

/// When the strip of neighbouring thumbnails shows in the large view
enum FilmstripMode: String, CaseIterable, Identifiable {
    case always, hover, off
    var id: String { rawValue }

    var name: String {
        switch self {
        case .always: String(localized: "Zawsze widoczny")
        case .hover: String(localized: "Po najechaniu myszą na dół")
        case .off: String(localized: "Wyłączony")
        }
    }
}

/// Thumbnails of the photos before and after the open one, centred on it; click one to open it.
struct Filmstrip: View {
    @ObservedObject var gallery: Gallery
    let current: Int
    static let thumbSize: CGFloat = 76

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(gallery.visible.indices, id: \.self) { index in
                        Thumbnail(url: gallery.visible[index].url, size: Self.thumbSize)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: index == current ? 3 : 0)
                            }
                            .opacity(index == current ? 1 : 0.75)
                            .contentShape(Rectangle())
                            .onTapGesture { gallery.selected = index }
                            .help(gallery.visible[index].url.lastPathComponent)
                            .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: Self.thumbSize + 16)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .onAppear { reader.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, index in
                withAnimation(.easeInOut(duration: 0.25)) { reader.scrollTo(index, anchor: .center) }
            }
        }
    }
}

/// Watches the mouse in the window: true while it is near the bottom edge, so the strip can slide in
@MainActor final class BottomEdgeHover: ObservableObject {
    @Published private(set) var isNear = false
    /// Height of the area along the bottom of the window that reveals the strip
    var zone: CGFloat = 170
    private var monitor: Any?
    private var hideTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        NSApp.keyWindow?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(to: event.locationInWindow.y) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTask?.cancel()
        isNear = false
    }

    private func mouseMoved(to y: CGFloat) {
        if y < zone {
            hideTask?.cancel()
            if !isNear { isNear = true }
        } else if isNear, hideTask == nil || hideTask!.isCancelled {
            // A short grace period, so the strip doesn't flicker when the mouse brushes its edge
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.isNear = false
                self?.hideTask = nil
            }
        }
    }
}
