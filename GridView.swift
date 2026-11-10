import SwiftUI
import AppKit

/// The thumbnail grid as an AppKit collection view: only the cells on screen exist, so tens of thousands
/// of photos scroll and filter without stalls. Cells and headers are small SwiftUI views.
struct PhotoGrid: NSViewRepresentable {
    @ObservedObject var gallery: Gallery
    let thumbSize: CGFloat
    let showNames: Bool

    func makeCoordinator() -> Coordinator { Coordinator(gallery: gallery) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.sectionHeadersPinToVisibleBounds = true
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 6, left: 16, bottom: 14, right: 16)
        layout.headerReferenceSize = NSSize(width: 100, height: 32)
        let collection = GridCollectionView()
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.coordinator = context.coordinator
        collection.register(GridCell.self, forItemWithIdentifier: GridCell.identifier)
        collection.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridHeader.identifier)
        collection.delegate = context.coordinator
        context.coordinator.attach(to: collection)
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Room below the last row for the floating capsule
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.gallery = gallery
        guard let collection = coordinator.collection,
              let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let itemSize = NSSize(width: thumbSize, height: thumbSize + (showNames ? 20 : 0))
        let looksChanged = layout.itemSize != itemSize || coordinator.showNames != showNames
            || coordinator.favorites != gallery.favorites || coordinator.revisions != gallery.editRevision
        coordinator.revisions = gallery.editRevision
        layout.itemSize = itemSize
        coordinator.thumbSize = thumbSize
        coordinator.showNames = showNames
        coordinator.favorites = gallery.favorites
        if coordinator.update(to: gallery.sections, keepingPositionIn: scroll) == false, looksChanged {
            coordinator.refreshVisible()
        }
        if !coordinator.returnHandled {
            coordinator.returnHandled = true
            coordinator.returnToPosition(in: scroll, attempts: 20)
        }
    }

    /// The grid is replaced by the large view when a photo opens; its scroll position is kept for the way back
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.gallery.gridScrollOffset = scroll.contentView.bounds.minY }
    }

    final class Coordinator: NSObject, NSCollectionViewDelegate {
        var gallery: Gallery
        weak var collection: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<String, URL>?
        /// Photo and its position in `visible`, by file
        private var lookup: [URL: (index: Int, photo: Photo)] = [:]
        private var counts: [String: Int] = [:]
        private var shown: [Gallery.GridSection] = []
        var favorites: Set<URL> = []
        /// Edits made in other programs: a changed photo's cell loads it again
        var revisions: [URL: Int] = [:]
        var thumbSize: CGFloat = 160
        var showNames = true
        /// The way back from the large view has been dealt with (done once, when the grid appears)
        var returnHandled = false

        init(gallery: Gallery) { self.gallery = gallery }

        func attach(to collection: NSCollectionView) {
            self.collection = collection
            let dataSource = NSCollectionViewDiffableDataSource<String, URL>(collectionView: collection) { [weak self] view, path, url in
                let item = view.makeItem(withIdentifier: GridCell.identifier, for: path)
                if let self, let photo = self.lookup[url]?.photo {
                    (item as? GridCell)?.show(photo, size: self.thumbSize, name: self.showNames, favorite: self.favorites.contains(url),
                                              revision: self.revisions[url] ?? 0)
                }
                return item
            }
            dataSource.supplementaryViewProvider = { [weak self] view, kind, path in
                let header = view.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.identifier, for: path) as! GridHeader
                if let self, let group = self.dataSource?.snapshot().sectionIdentifiers[safe: path.section] {
                    header.show(group: group, count: self.counts[group] ?? 0)
                }
                return header
            }
            self.dataSource = dataSource
        }

        /// Applies the new contents as insertions and removals: cells already on screen keep their photos, so
        /// nothing flickers or swaps while archives stream in, and the photo at the top of the view stays put.
        /// Returns whether anything changed.
        private var lastApply = Date.distantPast
        private var pending: (sections: [Gallery.GridSection], scroll: NSScrollView)?

        @discardableResult
        func update(to sections: [Gallery.GridSection], keepingPositionIn scroll: NSScrollView) -> Bool {
            guard dataSource != nil, !sameContents(sections) else { return false }
            // While a big folder streams in, at most about four updates a second, always with the newest state
            let wait = 0.25 - Date().timeIntervalSince(lastApply)
            if wait > 0, !shown.isEmpty {
                let scheduled = pending != nil
                pending = (sections, scroll)
                if !scheduled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                        guard let self, let pending = self.pending else { return }
                        self.pending = nil
                        self.apply(pending.sections, keepingPositionIn: pending.scroll)
                    }
                }
                return true
            }
            pending = nil
            apply(sections, keepingPositionIn: scroll)
            return true
        }

        private func apply(_ sections: [Gallery.GridSection], keepingPositionIn scroll: NSScrollView) {
            guard let dataSource else { return }
            lastApply = Date()
            let anchor = topVisiblePhoto()
            shown = sections
            var lookup: [URL: (index: Int, photo: Photo)] = [:]
            lookup.reserveCapacity(sections.reduce(0) { $0 + $1.items.count })
            var counts: [String: Int] = [:]
            var snapshot = NSDiffableDataSourceSnapshot<String, URL>()
            for section in sections {
                snapshot.appendSections([section.group])
                snapshot.appendItems(section.items.map(\.photo.url), toSection: section.group)
                counts[section.group] = section.items.count
                for item in section.items { lookup[item.photo.url] = item }
            }
            self.lookup = lookup
            self.counts = counts
            // A plain reload: with thousands of photos it is far cheaper than animated insertions, and it
            // doesn't show: cells start from the thumbnail in memory and the top photo is put back in place
            dataSource.apply(snapshot, animatingDifferences: false)
            refreshVisible()
            if let anchor { restore(anchor, in: scroll) }
        }

        private func sameContents(_ sections: [Gallery.GridSection]) -> Bool {
            guard sections.count == shown.count else { return false }
            for (a, b) in zip(sections, shown) where a.group != b.group || a.items.count != b.items.count
                || a.items.first?.photo.url != b.items.first?.photo.url || a.items.last?.photo.url != b.items.last?.photo.url {
                return false
            }
            return true
        }

        /// New size, names on/off or favourites: redraw the cells and headers on screen in place
        func refreshVisible() {
            guard let collection else { return }
            for item in collection.visibleItems() {
                guard let cell = item as? GridCell, let url = cell.url, let photo = lookup[url]?.photo else { continue }
                cell.show(photo, size: thumbSize, name: showNames, favorite: favorites.contains(url), revision: revisions[url] ?? 0)
            }
            let kind = NSCollectionView.elementKindSectionHeader
            let groups = dataSource?.snapshot().sectionIdentifiers ?? []
            for path in collection.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let header = collection.supplementaryView(forElementKind: kind, at: path) as? GridHeader,
                      let group = groups[safe: path.section] else { continue }
                header.show(group: group, count: counts[group] ?? 0)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            collectionView.deselectItems(at: indexPaths)
            guard let path = indexPaths.first, let url = dataSource?.itemIdentifier(for: path),
                  let index = lookup[url]?.index else { return }
            MainActor.assumeIsolated { gallery.selected = index }
        }

        /// The first photo showing at the top of the view and how far below the top edge it sits
        func topVisiblePhoto() -> (url: URL, offset: CGFloat)? {
            guard let collection else { return nil }
            let visible = collection.visibleRect
            let header = (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize.height ?? 0
            var best: (path: IndexPath, frame: CGRect)?
            for path in collection.indexPathsForVisibleItems() {
                guard let frame = collection.layoutAttributesForItem(at: path)?.frame, frame.maxY > visible.minY + header else { continue }
                if best == nil || (frame.minY, frame.minX) < (best!.frame.minY, best!.frame.minX) { best = (path, frame) }
            }
            guard let best, let url = dataSource?.itemIdentifier(for: best.path) else { return nil }
            return (url, best.frame.minY - visible.minY)
        }

        func restore(_ anchor: (url: URL, offset: CGFloat), in scroll: NSScrollView) {
            guard let collection, let layout = collection.collectionViewLayout,
                  let target = dataSource?.indexPath(for: anchor.url) else { return }
            // Ask the layout itself, freshly worked out: the view may not have caught up with the update yet
            layout.invalidateLayout()
            layout.prepare()
            guard let frame = layout.layoutAttributesForItem(at: target)?.frame else { return }
            let height = layout.collectionViewContentSize.height
            let maxY = max(height - scroll.contentView.bounds.height, 0)
            if collection.frame.height < height { collection.setFrameSize(NSSize(width: collection.frame.width, height: height)) }
            let y = min(max(frame.minY - anchor.offset, 0), maxY)
            guard abs(y - scroll.contentView.bounds.minY) > 0.5 else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Coming back from the large view: the grid scrolled as it was, and the photo just viewed on screen
        /// (centred, if browsing with the arrows went beyond what was in view)
        func returnToPosition(in scroll: NSScrollView, attempts: Int) {
            let (offset, url) = MainActor.assumeIsolated { (gallery.gridScrollOffset, gallery.lastViewedURL) }
            guard let collection, offset != nil || url != nil else { return }
            // A grid just put back in the window has no size yet: wait for its first layout
            guard scroll.contentView.bounds.height > 0, collection.frame.width > 0 else {
                if attempts > 0 {
                    DispatchQueue.main.async { [weak self, weak scroll] in
                        if let self, let scroll { self.returnToPosition(in: scroll, attempts: attempts - 1) }
                    }
                }
                return
            }
            collection.collectionViewLayout?.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            if let height = collection.collectionViewLayout?.collectionViewContentSize.height, collection.frame.height < height {
                collection.setFrameSize(NSSize(width: collection.frame.width, height: height))
            }
            let height = collection.collectionViewLayout?.collectionViewContentSize.height ?? collection.frame.height
            let maxY = max(height - scroll.contentView.bounds.height, 0)
            if let offset {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(offset, 0), maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            guard let url, let path = dataSource?.indexPath(for: url),
                  let frame = collection.layoutAttributesForItem(at: path)?.frame else { return }
            let header = (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize.height ?? 0
            var visible = scroll.contentView.bounds
            visible.origin.y += header
            visible.size.height -= header
            if !visible.contains(frame) {
                let y = min(max(frame.midY - scroll.contentView.bounds.height / 2, 0), maxY)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func photo(at path: IndexPath) -> Photo? {
            guard let url = dataSource?.itemIdentifier(for: path) else { return nil }
            return lookup[url]?.photo
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Right-click menu for the photo under the pointer
final class GridCollectionView: NSCollectionView {
    weak var coordinator: PhotoGrid.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point), let coordinator, let photo = coordinator.photo(at: path) else { return nil }
        let gallery = coordinator.gallery
        let menu = NSMenu()
        let favourite = MainActor.assumeIsolated { gallery.favorites.contains(photo.url) }
        menu.addItem(ClosureMenuItem(favourite ? String(localized: "Usuń z ulubionych") : String(localized: "Dodaj do ulubionych")) {
            MainActor.assumeIsolated { gallery.toggleFavorite(photo.url) }
        })
        if !photo.isVideo {
            menu.addItem(ExternalEditor.submenu(for: photo, gallery: gallery))
            menu.addItem(ClosureMenuItem("Drukuj…") { MainActor.assumeIsolated { gallery.print(photo) } })
        }
        // Finder and Preview keep thumbnails / recent files on disk, so archive contents never go there
        if !photo.isTemporary {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) })
            menu.addItem(ClosureMenuItem(String(localized: "Otwórz w Podglądzie")) { NSWorkspace.shared.open(photo.url) })
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// One thumbnail with its name and badges
private struct GridCellContent: View {
    let photo: Photo
    let size: CGFloat
    let name: Bool
    let favorite: Bool
    let revision: Int

    var body: some View {
        VStack(spacing: 4) {
            Thumbnail(url: photo.url, size: size)
                // A reused cell starts clean instead of briefly showing its previous photo; an edited one reloads
                .id("\(photo.url.path)#\(revision)")
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(5)
                    }
                }
            if name {
                Text(photo.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(width: size)
            }
        }
        .help(photo.url.lastPathComponent)
    }
}

final class GridCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    private var host: NSHostingView<AnyView>?
    /// The photo this cell shows
    private(set) var url: URL?

    override func loadView() { view = NSView() }

    func show(_ photo: Photo, size: CGFloat, name: Bool, favorite: Bool, revision: Int) {
        url = photo.url
        let content = AnyView(GridCellContent(photo: photo, size: size, name: name, favorite: favorite, revision: revision))
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
            self.host = host
        }
    }
}

/// Folder name and count above each folder's photos; stays at the top while its photos scroll
final class GridHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridHeader")
    private var host: NSHostingView<AnyView>?

    func show(group: String, count: Int) {
        let content = AnyView(
            HStack {
                Image(systemName: "folder")
                Text(group).fontWeight(.semibold).lineLimit(1).truncationMode(.head)
                Text("\(count)").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .background(.bar)
        )
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }
}
