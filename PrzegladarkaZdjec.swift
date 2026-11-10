import SwiftUI
import AppKit
import ImageIO
import AVFoundation
import MapKit
import UniformTypeIdentifiers

// MARK: - Gallery

@MainActor
final class Gallery: ObservableObject {
    @Published var title: String?
    /// Everything found
    @Published var photos: [Photo] = [] {
        didSet {
            if photos.isEmpty { tree = [] } else { scheduleTreeRebuild() }
            updateVisible()
        }
    }
    /// Every archive found so far (by group path), listed in the tree before it is unpacked
    @Published private(set) var archives: [String: Scanner.ArchiveState] = [:] {
        didSet { scheduleTreeRebuild() }
    }
    /// The grid's sections (one per folder), worked out with `visible` instead of on every redraw
    @Published private(set) var sections: [GridSection] = []
    private var treeRebuild: Task<Void, Never>?

    struct GridSection {
        let group: String
        var items: [(index: Int, photo: Photo)]
    }

    /// While a big folder streams in, the tree is rebuilt a few times a second rather than for every batch
    private func scheduleTreeRebuild() {
        guard treeRebuild == nil else { return }
        treeRebuild = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            treeRebuild = nil
            tree = FolderNode.tree(from: photos, archives: archives)
        }
    }
    /// Why an archive could not be unpacked (by group path)
    @Published private(set) var archiveProblems: [String: String] = [:]
    /// Folder picked in the sidebar ("" = all); includes its subfolders
    @Published var folderFilter: String? = "" {
        didSet {
            selected = nil
            updateVisible()
            preferredGroup.set(folderFilter)
        }
    }
    /// Read by the scanner: an archive picked in the tree is unpacked next
    private let preferredGroup = LockedValue<String?>(nil)
    /// Photos, films or favourites only
    @Published var kindFilter: KindFilter = .all {
        didSet { selected = nil; updateVisible() }
    }
    /// Part of a file name to look for
    @Published var searchText = "" {
        didSet {
            let current = selectedURL
            updateVisible()
            restoreSelection(current)
        }
    }
    /// The window is covered until Touch ID or the Mac password; the loaded data stays in memory
    @Published private(set) var locked = false

    func lock() {
        guard title != nil, !locked else { return }
        locked = true
        slideshow = false
        NotificationCenter.default.post(name: .viewerPauseForLock, object: nil)
    }

    func unlock() {
        AppUnlock.unlock { [weak self] success in
            if success { self?.locked = false }
        }
    }

    /// Films turned by hand (quarter turns, clockwise), in memory only
    @Published private(set) var videoTurns: [URL: Int] = [:]
    func setVideoTurns(_ url: URL, _ turns: Int) { videoTurns[url] = turns }

    /// Marked by the user; kept in memory only, like everything else about what is being viewed
    @Published private(set) var favorites: Set<URL> = []
    /// Corrections on the open photo, applied again at full resolution for printing
    var printAdjustments = ImageAdjustments.Values()

    /// File › Print: the open photo as shown (full resolution, with its corrections), or a contact sheet of the grid
    func printCurrent() {
        guard let index = selected, visible.indices.contains(index), !visible[index].isVideo else {
            printContactSheet()
            return
        }
        let url = visible[index].url, values = printAdjustments
        Task {
            let picture = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let full = ThumbnailCache.load(url) else { return nil }
                guard !values.isIdentity, let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return full }
                return ImageAdjustments.render(cg, with: values) ?? full
            }.value
            if let picture { Printer.printImage(picture, title: url.lastPathComponent) }
        }
    }

    func printContactSheet() {
        let photos = visible, title = title ?? String(localized: "Zdjęcia")
        Task { await Printer.printContactSheet(photos, title: title) }
    }

    /// One photo from the grid's context menu, decoded at full size for the printer
    func print(_ photo: Photo) {
        Task {
            let url = photo.url
            guard let image = await Task.detached(priority: .userInitiated, operation: { ThumbnailCache.load(url) }).value else { return }
            Printer.printImage(image, title: url.lastPathComponent)
        }
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, photos, videos, favorites
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .photos: "photo"
            case .videos: "film"
            case .favorites: "heart"
            }
        }
        var name: String {
            switch self {
            case .all: String(localized: "Wszystko")
            case .photos: String(localized: "Zdjęcia")
            case .videos: String(localized: "Filmy")
            case .favorites: String(localized: "Ulubione")
            }
        }
    }

    func toggleFavorite(_ url: URL) {
        if favorites.contains(url) { favorites.remove(url) } else { favorites.insert(url) }
        if kindFilter == .favorites {
            let current = selectedURL
            updateVisible()
            restoreSelection(current)
        }
    }
    /// Photos in the selected folder; `selected` indexes into this
    @Published private(set) var visible: [Photo] = []
    @Published private(set) var tree: [FolderNode] = []
    @Published var errors: [String] = []
    @Published var isLoading = false
    @Published var status = ""
    @Published var selected: Int? {
        didSet {
            lastShownIndex = oldValue
            if selected == nil {
                presenting = false
                // Back in the grid: show it where it was, around the photo just viewed
                if let oldValue, visible.indices.contains(oldValue) { lastViewedURL = visible[oldValue].url }
            }
        }
    }
    /// Bumped for a photo changed by another program, so its thumbnail and large view load again
    @Published private(set) var editRevision: [URL: Int] = [:]
    /// Files sent to another program for editing, with their modification date at that moment
    private var editedFiles: [URL: Date] = [:]
    private var activationObserver: NSObjectProtocol?

    func watchForEdits(_ url: URL) {
        editedFiles[url] = Self.modificationDate(url) ?? .distantPast
        guard activationObserver == nil else { return }
        // Back from the other program: pick up whatever it saved
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadEditedFiles() }
        }
    }

    private func reloadEditedFiles() {
        for (url, known) in editedFiles {
            guard let current = Self.modificationDate(url), current != known else { continue }
            editedFiles[url] = current
            ThumbnailCache.shared.forget(url)
            editRevision[url, default: 0] += 1
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Where the grid was scrolled to when a photo was opened, and the last photo viewed, to return to them
    var gridScrollOffset: CGFloat?
    var lastViewedURL: URL?
    /// Full-screen show: only the photo on black, controls appear when the mouse moves
    @Published var presenting = false {
        didSet { if !presenting { slideshow = false } }
    }
    /// Advances by itself during the show
    @Published var slideshow = false
    /// The photo shown before the current one, so the show knows which way to animate
    private(set) var lastShownIndex: Int?
    /// Bumped by every load and wipe, so results of an older scan are thrown away
    private var generation = 0
    /// Lets a running scan stop early when another folder is opened or the data is wiped
    private var scanCancel = CancelFlag()
    /// The single photo the user picked: opened as soon as it shows up
    private var openWhenFound: URL?
    var securityMonitor: SecurityMonitor?

    /// Forgets everything shown: list, thumbnails, passwords and the RAM disk with unpacked archives
    func wipe() {
        generation += 1
        scanCancel.cancel()
        openWhenFound = nil
        title = nil
        locked = false
        selected = nil
        folderFilter = ""
        photos = []
        gridScrollOffset = nil
        lastViewedURL = nil
        archives = [:]
        archiveProblems = [:]
        favorites = []
        videoTurns = [:]
        searchText = ""
        kindFilter = .all
        errors = []
        isLoading = false
        ThumbnailCache.shared.removeAll()
        FFmpeg.clearCache()
        PhotoLibrary.clear()
        PasswordMemory.shared.clear()
        Task.detached { SecureTemp.shared.destroy() }
    }

    private func updateVisible() {
        let filter = folderFilter ?? ""
        var result = filter.isEmpty ? photos : photos.filter { $0.group == filter || $0.group.hasPrefix(filter + "/") }
        switch kindFilter {
        case .all: break
        case .photos: result = result.filter { !$0.isVideo }
        case .videos: result = result.filter(\.isVideo)
        case .favorites: result = result.filter { favorites.contains($0.url) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { result = result.filter { $0.url.lastPathComponent.localizedStandardContains(query) } }
        visible = result
        var grouped: [GridSection] = []
        for (i, photo) in result.enumerated() {
            if grouped.last?.group == photo.group {
                grouped[grouped.count - 1].items.append((i, photo))
            } else {
                grouped.append(GridSection(group: photo.group, items: [(i, photo)]))
            }
        }
        sections = grouped
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Otwórz"
        panel.message = String(localized: "Wybierz folder, zdjęcie, film lub archiwum (zip, rar, 7z…)")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let response = panel.runModal()
        SecureTemp.forgetRecentFolders()
        if response == .OK, !panel.urls.isEmpty {
            load(panel.urls)
        }
    }

    /// Starts the full-screen show from the open photo, or the first one when the grid is shown
    func present(slideshow: Bool = false) {
        guard !visible.isEmpty else { return }
        if selected == nil { selected = 0 }
        presenting = true
        self.slideshow = slideshow
    }

    func step(_ delta: Int) {
        guard let index = selected, !visible.isEmpty else { return }
        selected = (index + delta + visible.count) % visible.count
    }

    /// Forgets the previous source and starts a new one; returns its generation and stop flag
    private func beginSource(title: String) -> (Int, CancelFlag) {
        generation += 1
        scanCancel.cancel()
        let cancel = CancelFlag()
        scanCancel = cancel
        isLoading = true
        status = String(localized: "Analizuję…")
        selected = nil
        folderFilter = ""
        photos = []
        gridScrollOffset = nil
        lastViewedURL = nil
        archives = [:]
        archiveProblems = [:]
        favorites = []
        videoTurns = [:]
        searchText = ""
        kindFilter = .all
        errors = []
        self.title = title
        openWhenFound = nil
        ThumbnailCache.shared.removeAll()
        FFmpeg.clearCache()
        PhotoLibrary.clear()
        return (generation, cancel)
    }

    /// Asks for access to the Photos library if needed, then opens it (or one album)
    func openLibrary(_ album: PhotoLibrary.Album? = nil) {
        Task {
            if await PhotoLibraryModel.shared.connect() { loadLibrary(album) }
        }
    }

    /// Photos and films from the Mac's Photos library (or one of its albums), read into memory only
    func loadLibrary(_ album: PhotoLibrary.Album? = nil) {
        let (generation, cancel) = beginSource(title: album.map { $0.id == nil ? String(localized: "Biblioteka Zdjęć") : $0.title }
                                                    ?? String(localized: "Biblioteka Zdjęć"))
        status = String(localized: "Czytam bibliotekę Zdjęć…")
        Task.detached(priority: .userInitiated) {
            // Archives of the previous source go, as with any other new source
            SecureTemp.shared.destroy()
            SecureTemp.shared.prepare()
            PhotoLibrary.list(album: album?.id, shouldStop: { cancel.isCancelled }) { batch in
                Task { @MainActor in
                    guard generation == self.generation else { return }
                    self.insert(batch)
                }
            }
            await MainActor.run {
                guard generation == self.generation else { return }
                self.isLoading = false
            }
        }
    }

    func load(_ sources: [URL]) {
        let (generation, cancel) = beginSource(title: sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) elementy")
        let preferredGroup = preferredGroup
        openWhenFound = sources.count == 1 && Scanner.isMedia(sources[0]) ? sources[0] : nil
        Task.detached(priority: .userInitiated) {
            // Previous archive contents are wiped together with the old RAM disk; a fresh one is made right away
            SecureTemp.shared.destroy()
            SecureTemp.shared.prepare()
            let scanner = Scanner(
                extractionRoot: { SecureTemp.shared.root() },
                askPassword: { archive, wasWrong in
                    DispatchQueue.main.sync { MainActor.assumeIsolated { PasswordPrompt.ask(archive, wasWrong: wasWrong) } }
                },
                progress: { msg in Task { @MainActor in self.status = msg } },
                emit: { event in
                    Task { @MainActor in
                        guard generation == self.generation else { return }
                        switch event {
                        case .found(let batch): self.insert(batch)
                        case .retracted(let urls): self.remove(urls)
                        case .archive(let group, let state):
                            // Events may arrive out of order; a state only moves forward
                            if self.archives[group].map({ $0 < state }) ?? true { self.archives[group] = state }
                        case .archiveFailed(let group, let reason):
                            self.archiveProblems[group] = reason
                        }
                    }
                },
                shouldStop: { cancel.isCancelled },
                preferredGroup: { preferredGroup.value })
            let result = scanner.scan(sources)
            await MainActor.run {
                guard generation == self.generation else {
                    // Wiped while scanning: anything unpacked after the wipe goes too
                    // (a newer load has already replaced the RAM disk itself)
                    if self.title == nil { Task.detached { SecureTemp.shared.destroy() } }
                    return
                }
                self.errors = result.errors
                self.isLoading = false
            }
        }
    }

    /// Adds newly found photos in display order, keeping the open photo open
    private func insert(_ batch: [Photo]) {
        let current = selectedURL
        let sortedBatch = batch.sorted(by: Scanner.inOrder)
        // Merge two sorted lists: cheaper than re-sorting everything for every batch
        var merged: [Photo] = []
        merged.reserveCapacity(photos.count + sortedBatch.count)
        var i = photos.startIndex, j = sortedBatch.startIndex
        while i < photos.endIndex, j < sortedBatch.endIndex {
            if Scanner.inOrder(sortedBatch[j], photos[i]) {
                merged.append(sortedBatch[j]); j += 1
            } else {
                merged.append(photos[i]); i += 1
            }
        }
        merged.append(contentsOf: photos[i...])
        merged.append(contentsOf: sortedBatch[j...])
        photos = merged
        restoreSelection(current)
        if let open = openWhenFound, let index = visible.firstIndex(where: { $0.url == open }) {
            selected = index
            openWhenFound = nil
        }
    }

    private func remove(_ urls: Set<URL>) {
        let current = selectedURL
        photos.removeAll { urls.contains($0.url) }
        restoreSelection(current)
    }

    private var selectedURL: URL? {
        selected.flatMap { visible.indices.contains($0) ? visible[$0].url : nil }
    }

    private func restoreSelection(_ url: URL?) {
        guard let url else { return }
        selected = visible.firstIndex { $0.url == url }
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

// MARK: - Password prompt

@MainActor
enum PasswordPrompt {
    static func ask(_ archive: String, wasWrong: Bool) -> Scanner.PasswordAnswer {
        let alert = NSAlert()
        alert.messageText = String(localized: "Archiwum „\(archive)” jest chronione hasłem")
        alert.informativeText = wasWrong
            ? String(localized: "Hasło jest nieprawidłowe. Spróbuj ponownie.")
            : String(localized: "Podaj hasło, aby zobaczyć jego zawartość. Hasło jest pamiętane tylko do zamknięcia aplikacji.")
        alert.alertStyle = wasWrong ? .warning : .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = String(localized: "Hasło")
        alert.accessoryView = field
        alert.addButton(withTitle: "Otwórz")
        alert.addButton(withTitle: String(localized: "Pomiń"))
        alert.addButton(withTitle: String(localized: "Pomiń wszystkie"))
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .password(field.stringValue)
        case .alertSecondButtonReturn: return .skip
        default: return .skipAll
        }
    }
}

// MARK: - Thumbnails

/// A photo decoded for the large view: no bigger than the screen needs, with the original's size, so that
/// zoom percentages refer to the real photo. Full resolution is decoded separately, only when zooming in.
struct DisplayImage {
    let image: CGImage
    /// Pixel size of the original, upright
    let fullSize: CGSize
    var isFullResolution: Bool { CGFloat(max(image.width, image.height)) >= max(fullSize.width, fullSize.height) - 1 }
}

/// At most one decode per processor core at a time. When the grid scrolls quickly, the newest requests
/// (the cells now on screen) go first, and cells scrolled away give up their place.
actor DecodeQueue {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// false when the task was cancelled before its turn came
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if granted && Task.isCancelled {
            release()
            return false
        }
        return granted
    }

    func release() {
        if let next = waiting.popLast() {
            next.continuation.resume(returning: true)  // the slot passes straight on
        } else {
            running -= 1
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(returning: false)
        }
    }
}

/// Everything decoded is kept in memory only (and dropped on wipe): nothing is ever written to disk.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Newest thumbnail of each file, shown in the large view until the photo itself is decoded
    private let latest = NSCache<NSURL, NSImage>()
    /// Photos at screen size: the open one and its neighbours, so ← → is instant
    private let display: NSCache<NSURL, DisplayBox> = {
        let cache = NSCache<NSURL, DisplayBox>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()
    /// Full resolution, only for a photo zoomed in on
    private let fullResolution: NSCache<NSURL, CGImageBox> = {
        let cache = NSCache<NSURL, CGImageBox>()
        cache.countLimit = 2
        return cache
    }()
    /// Twice the cores: ImageIO waits on the disk and its own helper threads part of the time
    private let imageQueue = DecodeQueue(limit: ProcessInfo.processInfo.activeProcessorCount * 2)
    /// Film thumbnails start ffmpeg or a video decoder, so fewer at once
    private let videoQueue = DecodeQueue(limit: 2)

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private final class DisplayBox {
        let value: DisplayImage
        init(_ value: DisplayImage) { self.value = value }
    }

    /// Longest side, in pixels, of the largest screen: more than that can't be seen without zooming in
    static let screenPixels: CGFloat = {
        let sides = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return max(sides.max() ?? 3000, 2000)
    }()

    func removeAll() {
        cache.removeAllObjects()
        latest.removeAllObjects()
        display.removeAllObjects()
        fullResolution.removeAllObjects()
    }

    func placeholder(for url: URL) -> NSImage? { latest.object(forKey: url as NSURL) }

    /// Drops everything decoded from a file that has since changed
    func forget(_ url: URL) {
        latest.removeObject(forKey: url as NSURL)
        display.removeObject(forKey: url as NSURL)
        fullResolution.removeObject(forKey: url as NSURL)
        keysLock.lock()
        let keys = thumbnailKeys.removeValue(forKey: url) ?? []
        keysLock.unlock()
        for key in keys { cache.removeObject(forKey: key) }
    }
    /// Which thumbnail sizes exist for each file, so a changed file's can all be dropped
    private var thumbnailKeys: [URL: Set<NSString>] = [:]
    private let keysLock = NSLock()

    /// Decoded earlier (e.g. by the prefetch), available without waiting
    func cachedDisplayImage(for url: URL) -> DisplayImage? { display.object(forKey: url as NSURL)?.value }

    func displayImage(for url: URL, priority: TaskPriority = .userInitiated) async -> DisplayImage? {
        if let box = display.object(forKey: url as NSURL) { return box.value }
        let result = await Task.detached(priority: priority) { () -> DisplayImage? in
            guard let fullSize = Self.uprightSize(url),
                  let image = Self.load(url, maxPixels: min(Self.screenPixels, max(fullSize.width, fullSize.height)))?
                      .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                // Not readable by ImageIO: whatever the fallbacks manage, at its own size
                guard let image = Self.load(url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return DisplayImage(image: image, fullSize: CGSize(width: image.width, height: image.height))
            }
            return DisplayImage(image: image, fullSize: fullSize)
        }.value
        if let result {
            display.setObject(DisplayBox(result), forKey: url as NSURL, cost: result.image.bytesPerRow * result.image.height)
        }
        return result
    }

    func fullResolutionImage(for url: URL) async -> CGImage? {
        if let box = fullResolution.object(forKey: url as NSURL) { return box.image }
        let image = await Task.detached(priority: .userInitiated) {
            Self.load(url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }.value
        if let image { fullResolution.setObject(CGImageBox(image), forKey: url as NSURL) }
        return image
    }

    /// Decodes photos in the background, in the given order, so they are ready before the user gets to them
    func prefetch(_ urls: [URL]) {
        let missing = urls.filter { display.object(forKey: $0 as NSURL) == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in missing { _ = await self.displayImage(for: url, priority: .utility) }
        }
    }

    /// Upright pixel size from the file's header, without decoding it
    static func uprightSize(_ url: URL) -> CGSize? {
        guard let source = PhotoLibrary.imageSource(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Pixel size to decode for a thumbnail shown at `size` points (Retina, rounded up so the slider
    /// doesn't trigger a reload on every pixel of movement)
    static func pixelSize(for size: CGFloat) -> CGFloat {
        (size * 2 / 256).rounded(.up) * 256
    }

    /// Already in memory: at this size, or (while the right size loads) the latest of any size
    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let key = "\(Int(Self.pixelSize(for: size)))|\(url.path)" as NSString
        return cache.object(forKey: key) ?? latest.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let pixels = Self.pixelSize(for: size)
        let key = "\(Int(pixels))|\(url.path)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let isVideo = Scanner.isVideo(url)
        let queue = isVideo ? videoQueue : imageQueue
        // A cell scrolled out of view cancels its task and leaves the queue
        guard await queue.acquire() else { return nil }
        let image: NSImage?
        if PhotoLibrary.isAsset(url) {
            image = await PhotoLibrary.thumbnail(url, maxPixels: pixels)
        } else if isVideo {
            image = await VideoSupport.thumbnail(url, maxPixels: pixels)
        } else {
            image = await Task.detached(priority: .userInitiated) { Self.load(url, maxPixels: pixels) }.value
        }
        await queue.release()
        if let image {
            cache.setObject(image, forKey: key)
            latest.setObject(image, forKey: url as NSURL)
            keysLock.lock()
            thumbnailKeys[url, default: []].insert(key)
            keysLock.unlock()
        }
        return image
    }

    /// Loads an image respecting EXIF orientation; nil maxPixels means full size.
    /// Large sizes are decoded at exactly 1/2, 1/4 or 1/8 of the original where that is close enough, which
    /// JPEG decoders do far faster than an arbitrary size; full size skips resampling altogether.
    static func load(_ url: URL, maxPixels: CGFloat? = nil) -> NSImage? {
        guard let src = PhotoLibrary.imageSource(url) else {
            return PhotoLibrary.isAsset(url) ? nil : fallback(url, maxPixels: maxPixels)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let longest = max(w, h)
        var limit = maxPixels ?? longest
        if longest > 0, limit >= longest - 0.5, orientation == 1,
           let lazy = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            // Full size, upright already: plain decode, done here rather than on the first draw (which would
            // happen on the main thread and stutter)
            return NSImage(cgImage: decodedNow(lazy) ?? lazy, size: .zero)
        }
        if longest > 0, limit >= 1024, limit < longest {
            // Snap down to a power-of-two fraction that still gives at least 85% of the size asked for
            var fraction = longest
            while fraction / 2 >= limit * 0.85, fraction / 2 >= 1024 { fraction /= 2 }
            if fraction < longest { limit = fraction.rounded(.up) }
        }
        if longest > 0 { limit = min(limit, longest) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit > 0 ? limit : 4000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return PhotoLibrary.isAsset(url) ? nil : fallback(url, maxPixels: maxPixels)
        }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Forces the pixels into memory by drawing them once into a bitmap
    private static func decodedNow(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// For files ImageIO gives up on: AppKit's own decoders, then ffmpeg, which reads whatever survives
    private static func fallback(_ url: URL, maxPixels: CGFloat?) -> NSImage? {
        if let image = NSImage(contentsOf: url), image.isValid,
           image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil {
            return image
        }
        return FFmpeg.decodeImage(url, maxPixels: maxPixels)
    }

    /// A JPEG or PNG cut short (interrupted copy or download): it still opens, the missing part grey or black
    static func isTruncated(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let marker: [UInt8]
        switch ext {
        case "jpg", "jpeg", "jpe": marker = [0xFF, 0xD9]             // end-of-image marker
        case "png": marker = Array("IEND".utf8)
        default: return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 64 else { return false }
        // Cameras and editors may pad after the marker, so look at the last few KB rather than the last bytes
        let tail = min(size, 16384)
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.readToEnd() else { return false }
        let bytes = [UInt8](data)
        guard bytes.count >= marker.count else { return true }
        for i in stride(from: bytes.count - marker.count, through: 0, by: -1) where Array(bytes[i..<i + marker.count]) == marker {
            return false
        }
        return true
    }
}

struct Thumbnail: View {
    let url: URL
    let size: CGFloat
    /// Starts with the thumbnail already in memory, if any, so cells don't blink while scrolling or loading
    @State private var image: NSImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        _image = State(initialValue: ThumbnailCache.shared.cachedThumbnail(for: url, size: size))
    }
    @State private var failed = false
    @State private var duration: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: Scanner.isVideo(url) ? "film" : "exclamationmark.triangle")
                    .font(.system(size: size / 4)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomLeading) {
            if Scanner.isVideo(url) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                    if let duration { Text(duration).monospacedDigit() }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(5)
            }
        }
        .task(id: url) {
            if Scanner.isVideo(url) { duration = await VideoSupport.duration(url) }
        }
        // Reload at a higher resolution when the thumbnail grows; the old image stays until then
        .task(id: "\(Int(ThumbnailCache.pixelSize(for: size)))|\(url.path)") {
            image = await ThumbnailCache.shared.thumbnail(for: url, size: size)
            if !Task.isCancelled { failed = image == nil }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var gallery: Gallery
    @ObservedObject var adjustments: ImageAdjustments
    @ObservedObject var security: SecuritySettings
    @StateObject private var zoom = ZoomController()
    @AppStorage("thumbSize") private var thumbSize: Double = 160
    @AppStorage("showNames") private var showNames = true
    @State private var dropTargeted = false
    @State private var showErrors = false
    @State private var keyMonitor: Any?

    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var columnsBeforeLargeView: NavigationSplitViewVisibility?
    /// The window went full screen for the show, so it leaves full screen with it
    @State private var fullScreenForShow = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            FolderSidebar(gallery: gallery, security: security)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            Group {
                if let index = gallery.selected, gallery.visible.indices.contains(index) {
                    FullImageView(gallery: gallery, zoom: zoom, adjustments: adjustments, photo: gallery.visible[index], index: index)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    content
                }
            }
            .animation(.easeOut(duration: 0.18), value: gallery.selected == nil)
        }
        .frame(minWidth: 800, minHeight: 500)
        // The large view gets the whole window; the tree comes back with the grid
        .onChange(of: gallery.selected == nil) { _, inGrid in
            if inGrid {
                if let previous = columnsBeforeLargeView { columns = previous }
                columnsBeforeLargeView = nil
            } else if columnsBeforeLargeView == nil {
                columnsBeforeLargeView = columns
                columns = .detailOnly
            }
        }
        .onAppear {
            security.applyToWindows()
            if gallery.securityMonitor == nil {
                let gallery = gallery
                gallery.securityMonitor = SecurityMonitor(settings: security, wipe: {
                    if gallery.title != nil { gallery.wipe() }
                }, lock: {
                    gallery.lock()
                })
            }
            // Read the gallery at key-press time (SwiftUI keyboard shortcuts kept a stale photo index)
            let gallery = gallery, zoom = zoom
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                Self.handleKey(event, gallery: gallery, zoom: zoom) ? nil : event
            }
            ExternalOpen.handler = { gallery.load($0) }
            Self.arrangeWindowOnLaunch()
        }
        .onChange(of: gallery.presenting) { _, presenting in
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
            let fullScreen = window.styleMask.contains(.fullScreen)
            if presenting, !fullScreen {
                fullScreenForShow = true
                window.toggleFullScreen(nil)
            } else if !presenting, fullScreen, fullScreenForShow {
                window.toggleFullScreen(nil)
            }
            if !presenting { fullScreenForShow = false }
        }
        // Leaving full screen another way (green button, ⌃⌘F) ends the show too
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            fullScreenForShow = false
            gallery.presenting = false
        }
        .onChange(of: gallery.selected == nil, initial: true) { _, inGrid in Self.setWindowChrome(visible: inGrid) }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(4)
            }
        }
        // Locked: one opaque cover over everything, sidebar and full screen included
        .overlay {
            if gallery.locked {
                LockScreen(unlock: { gallery.unlock() }, wipe: { gallery.wipe() })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: gallery.locked)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { gallery.load(urls) }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { gallery.choose() } label: {
                    Label("Otwórz", systemImage: "folder")
                }
                .help("Wybierz folder, zdjęcie, film lub archiwum")
                .keyboardShortcut("o")
                if !gallery.errors.isEmpty {
                    Button { showErrors = true } label: {
                        Label("Problemy", systemImage: "exclamationmark.triangle")
                    }
                    .help("Pliki, których nie udało się otworzyć")
                    .popover(isPresented: $showErrors) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(gallery.errors, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                            .padding()
                        }
                        .frame(width: 420, height: 220)
                    }
                }
                Button { gallery.present() } label: {
                    Label("Pokaz na pełnym ekranie", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Pokaz na pełnym ekranie: samo zdjęcie na czarnym tle (F)")
                .disabled(gallery.visible.isEmpty)
            }
        }
        .navigationTitle(gallery.locked ? "Migawka" : (gallery.title ?? "Migawka"))
        .navigationSubtitle(gallery.title == nil || gallery.locked ? "" : countText)
    }

    private static var windowArranged = false

    /// The large view gets the whole window: no toolbar or title, and a see-through title bar over the black
    /// (done in AppKit, as SwiftUI's toolbar visibility doesn't reach this window's toolbar)
    private static func setWindowChrome(visible: Bool) {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.toolbar?.isVisible = visible
                window.titleVisibility = visible ? .visible : .hidden
                window.titlebarAppearsTransparent = !visible
                window.styleMask.insert(.fullSizeContentView)
            }
        }
    }

    /// At launch the window fills the screen (Dock and menu bar stay), or goes full screen if chosen in View
    private static func arrangeWindowOnLaunch() {
        guard !windowArranged else { return }
        windowArranged = true
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true)
            guard UserDefaults.standard.bool(forKey: "startFullScreen") else { return }
            // A window that has only just appeared ignores the switch, so it comes a moment later
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    /// F starts or ends the full-screen show; in the large view ← → change photo, Esc goes back,
    /// + − 0 1 (with or without ⌘) zoom, and during the show the space bar starts or stops the slideshow
    @MainActor
    private static func handleKey(_ event: NSEvent, gallery: Gallery, zoom: ZoomController) -> Bool {
        guard NSApp.modalWindow == nil, let window = NSApp.keyWindow, window.attachedSheet == nil, !gallery.locked else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let fullScreen = window.styleMask.contains(.fullScreen)
        if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "f" {
            if gallery.presenting {
                gallery.presenting = false
            } else if gallery.visible.isEmpty {
                window.toggleFullScreen(nil)
            } else {
                gallery.present()
            }
            return true
        }
        guard let selected = gallery.selected else { return false }
        switch event.keyCode {
        case 123 where mods.isEmpty: gallery.step(-1)   // ←
        case 124 where mods.isEmpty: gallery.step(1)    // →
        // ⇧← / ⇧→ on a film: 10 s back / forward
        case 123 where mods == .shift && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerSkip, object: nil, userInfo: ["seconds": -10.0])
        case 124 where mods == .shift && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerSkip, object: nil, userInfo: ["seconds": 10.0])
        // , / . on a film: one frame back / forward
        case 43 where mods.isEmpty && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerFrameStep, object: nil, userInfo: ["forward": false])
        case 47 where mods.isEmpty && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerFrameStep, object: nil, userInfo: ["forward": true])
        // M on a film: sound on / off
        case 46 where mods.isEmpty && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerToggleMute, object: nil)
        // Space: slideshow on/off (on a film it stays with the player, for play/pause)
        case 49 where mods.isEmpty && gallery.presenting && !gallery.visible[selected].isVideo:
            gallery.slideshow.toggle()
        // Space on a film: play / pause, whichever player shows it
        case 49 where mods.isEmpty && gallery.visible[selected].isVideo:
            NotificationCenter.default.post(name: .viewerTogglePause, object: nil)
        case 37 where mods.isEmpty:   // L: favourite
            gallery.toggleFavorite(gallery.visible[selected].url)
        case 46 where mods.isEmpty:   // M: map of where the photo was taken
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "gpsMap") {
                defaults.set(false, forKey: "gpsMap")
            } else if PhotoLocation.allowMap() {
                defaults.set(true, forKey: "gpsMap")
            }
        case 34 where mods.isEmpty:   // I: file details
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "infoPanel"), forKey: "infoPanel")
        case 17 where mods.isEmpty:   // T: thumbnail strip always on, or back to showing on hover
            let defaults = UserDefaults.standard
            let mode = FilmstripMode(rawValue: defaults.string(forKey: "filmstrip") ?? "") ?? .hover
            defaults.set((mode == .always ? FilmstripMode.hover : .always).rawValue, forKey: "filmstrip")
        case 53 where gallery.presenting: gallery.presenting = false   // Esc: end the show first…
        case 53 where fullScreen && !UserDefaults.standard.bool(forKey: "startFullScreen"):
            window.toggleFullScreen(nil)          // …then leave full screen…
        case 53: gallery.selected = nil                         // …then back to the grid
        default:
            guard mods.subtracting([.command, .shift]).isEmpty else { return false }
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoom.zoomIn()
            case "-", "_": zoom.zoomOut()
            case "0": zoom.fit()
            case "1": zoom.actualSize()
            default: return false
            }
        }
        return true
    }

    @ViewBuilder private var content: some View {
        if gallery.isLoading && gallery.photos.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(gallery.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gallery.title == nil {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60)).foregroundStyle(.secondary)
                Text("Wybierz folder, zdjęcie, film lub archiwum").font(.title2)
                Text(String(localized: "Obsługiwane archiwa: zip, rar, 7z, tar, gz i inne (także z hasłem).\nMożesz też przeciągnąć pliki do tego okna."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Otwórz…") { gallery.choose() }
                    Button {
                        gallery.openLibrary()
                    } label: {
                        Label("Biblioteka Zdjęć", systemImage: "photo.stack")
                    }
                    .help("Zdjęcia i filmy z aplikacji Zdjęcia, także z iCloud")
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gallery.photos.isEmpty {
            Text("Nie znaleziono zdjęć ani filmów").font(.title2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gallery.visible.isEmpty, let filter = gallery.folderFilter, let problem = gallery.archiveProblems[filter] {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                Text("Nie udało się rozpakować tego archiwum").font(.title3)
                Text(problem.prefix(1).uppercased() + problem.dropFirst())
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gallery.visible.isEmpty, let filter = gallery.folderFilter,
                  let state = gallery.archives[filter], state < .done {
            VStack(spacing: 12) {
                ProgressView()
                Text(state == .waiting ? "Archiwum czeka w kolejce – rozpakuję je jako następne" : "Rozpakowuję…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var countText: String {
        let videos = gallery.visible.filter(\.isVideo).count
        let photos = gallery.visible.count - videos
        let photoCount = String(localized: "\(photos) zdjęć")
        return videos == 0 ? photoCount : photoCount + ", " + String(localized: "\(videos) filmów")
    }

    /// The grid with a floating capsule at the bottom, in the same style as the viewer's controls
    private var grid: some View {
        thumbnails
            .overlay(alignment: .bottom) {
                HStack(spacing: 14) {
                    Text(countText).monospacedDigit()
                    if gallery.isLoading {
                        // Photos keep appearing while folders are walked and archives unpacked
                        ProgressView().controlSize(.small)
                        Text(gallery.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220)
                            .transition(.opacity)
                    }
                    Divider().frame(height: 18)
                    Button { showNames.toggle() } label: {
                        Image(systemName: "textformat")
                            .foregroundStyle(showNames ? Color.accentColor : Color.primary)
                    }
                    .help(showNames ? String(localized: "Ukryj nazwy plików (⌥⌘N)") : String(localized: "Pokaż nazwy plików (⌥⌘N)"))
                    Divider().frame(height: 18)
                    Button { thumbSize = max(80, thumbSize - 40) } label: { Image(systemName: "photo").imageScale(.small) }
                        .help("Mniejsze miniatury")
                    ThinSlider(value: $thumbSize, range: 80...600) { _ in }
                        .frame(width: 180)
                        .help("Wielkość miniatur")
                    Button { thumbSize = min(600, thumbSize + 40) } label: { Image(systemName: "photo").imageScale(.large) }
                        .help("Większe miniatury")
                }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 18)
                .animation(.easeInOut(duration: 0.25), value: gallery.isLoading)
            }
    }

    private var thumbnails: some View {
        PhotoGrid(gallery: gallery, thumbSize: thumbSize, showNames: showNames)
    }
}

struct FullImageView: View {
    @ObservedObject var gallery: Gallery
    @ObservedObject var zoom: ZoomController
    @ObservedObject var adjustments: ImageAdjustments
    /// Passed in rather than looked up by index: while a folder is still being read, photos land in front
    /// of this one, and a lookup by a stale index would show (or play) a different file
    let photo: Photo
    let index: Int
    /// As loaded from the file
    @State private var original: CGImage?
    /// The photo's real (upright) pixel size; `original` is usually a screen-sized version of it
    @State private var fullSize: CGSize?
    /// `original` is the full resolution (loaded once the user zooms in past what the screen version holds)
    @State private var baseIsFull = false
    /// With corrections applied
    @State private var image: NSImage?
    /// The photo `image` shows: the previous photo stays on screen until the next one is ready,
    /// instead of a black frame in between
    @State private var imageURL: URL?
    @State private var video: VideoState = .checking
    /// The file is cut short: only the part that could be read is shown
    @State private var truncated = false
    /// How far ffmpeg has got with the film (nil when it isn't working)
    @State private var conversion: Double?
    @StateObject private var showControls = ShowControls()
    /// Film controls (shared by both players); volume, mute and speed carry over from film to film
    @StateObject private var playback = PlaybackState()
    @AppStorage("slideSeconds") private var slideSeconds: Double = 5
    @AppStorage("slideTransition") private var transitionSetting = SlideTransition.random.rawValue
    @AppStorage("filmstrip") private var filmstripSetting = FilmstripMode.hover.rawValue
    @StateObject private var bottomHover = BottomEdgeHover()
    @AppStorage("infoPanel") private var infoVisible = false
    @AppStorage("portraitTurns") private var portraitTurns = 0
    /// Off until the user switches it on (the map goes online, see PhotoLocation.allowMap)
    @AppStorage("gpsMap") private var mapVisible = false
    /// Where the open photo was taken, if its file says
    @State private var location: CLLocationCoordinate2D?
    /// For the line under the name: file size and picture size
    @State private var fileSize: Int64?
    /// During the show: the previous photo, animated away over the new one
    @State private var outgoing: NSImage?
    @State private var transitionKind = SlideTransition.fade
    /// 0 when a transition starts, 1 when it has finished
    @State private var transitionProgress: Double = 1
    @State private var movingForward = true
    /// Slow zoom of the Ken Burns transition
    @State private var kenBurnsScale: CGFloat = 1

    private enum VideoState: Equatable {
        case checking
        case converting(codec: String?)
        case play(URL, VideoStream?)
        /// Played by mpv, straight from the file
        case mpv(URL)
        case unsupported(codec: String?)
    }

    private struct RenderKey: Hashable {
        let url: URL
        let hasOriginal: Bool
        let full: Bool
        let values: ImageAdjustments.Values
    }

    var body: some View {
        ZStack {
            // Black right up to the window's top edge, under the (then see-through) title bar
            Color.black.ignoresSafeArea()
            if photo.isVideo {
                videoArea
            } else {
                photoArea
            }
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .top) {
            if !gallery.presenting {
                topBar
                    .opacity(controlsShown ? 1 : 0)
                    .allowsHitTesting(controlsShown)
            }
        }
        // Info and adjustments: floating cards down the right side, sliding in and out
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if infoVisible && !gallery.presenting {
                    PhotoInfoPanel(photo: photo, image: original, fileSize: fileSize)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if adjustments.panelVisible {
                    AdjustmentsPanel(adjustments: adjustments, isVideo: photo.isVideo)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.top, gallery.presenting ? 14 : 70).padding(.trailing, 14).padding(.bottom, 90)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: adjustments.panelVisible)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: infoVisible)
        }
        .overlay(alignment: .bottomTrailing) {
            if mapVisible, let location {
                PhotoLocationMap(coordinate: location) { mapVisible = false }
                    .padding(.trailing, 14)
                    .padding(.bottom, stripShown ? 190 : 76)
                    .opacity(gallery.presenting && !controlsShown ? 0 : 1)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) { bottomControls }
        .animation(.easeInOut(duration: 0.22), value: mapVisible)
        .animation(.easeInOut(duration: 0.22), value: controlsShown)
        .animation(.easeInOut(duration: 0.22), value: bottomHover.isNear)
        .animation(.easeInOut(duration: 0.22), value: infoVisible)
        .onAppear {
            bottomHover.zone = 240
            bottomHover.start()
            showControls.start()
        }
        .onDisappear {
            bottomHover.stop()
            showControls.stop()
        }
        .onChange(of: gallery.presenting, initial: true) { _, presenting in
            // The cursor hides with the controls only on full screen
            showControls.hidesCursor = presenting
            // The show starts with the whole photo on screen, following the window into full screen
            if presenting { zoom.fit() }
        }
        // Slideshow: photos (and films that won't play) advance after the set time, films when they end
        .task(id: SlideKey(url: photo.url, running: gallery.presenting && gallery.slideshow,
                           seconds: slideSeconds, waitsForFilmEnd: waitsForFilmEnd)) {
            guard gallery.presenting, gallery.slideshow, !waitsForFilmEnd else { return }
            try? await Task.sleep(for: .seconds(slideSeconds))
            if !Task.isCancelled { gallery.step(1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .viewerVideoDidFinish)) { _ in
            if gallery.presenting, gallery.slideshow, waitsForFilmEnd { gallery.step(1) }
        }
        .task(id: "\(photo.url.path)#\(gallery.editRevision[photo.url] ?? 0)") { await loadPhoto() }
        // A new file brings the controls up for a moment (also when browsing with the keys), so they can be seen
        // reshaping between photo and film
        .onChange(of: photo.url) { showControls.reveal() }
        .onReceive(NotificationCenter.default.publisher(for: .viewerRotate)) { note in
            if photo.isVideo { rotateFilm(clockwise: note.userInfo?["clockwise"] as? Bool ?? true) }
        }
        .onChange(of: zoom.scale) { loadFullResolutionIfNeeded() }
        .onChange(of: adjustments.values, initial: true) { gallery.printAdjustments = adjustments.values }
        .onChange(of: photo.url) { adjustments.photoChanged() }
        .task(id: RenderKey(url: photo.url, hasOriginal: original != nil, full: baseIsFull, values: adjustments.values)) {
            await renderAdjusted()
        }
    }

    private var photoArea: some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                ZStack {
                    ZoomableImage(image: image, photo: imageURL, controller: zoom)
                        .scaleEffect(kenBurnsScale)
                        .modifier(SlideEffect(kind: transitionKind, progress: transitionProgress, incoming: true,
                                              width: geometry.size.width, forward: movingForward))
                    if let outgoing {
                        Image(nsImage: outgoing).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .modifier(SlideEffect(kind: transitionKind, progress: transitionProgress, incoming: false,
                                                  width: geometry.size.width, forward: movingForward))
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
            }
            if image == nil && outgoing == nil { ProgressView().frame(maxHeight: .infinity) }
            if truncated {
                Label("Plik jest niekompletny – pokazuję tylko część, którą udało się odczytać",
                      systemImage: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.top, gallery.presenting ? 10 : 70)
            }
        }
    }

    /// Floating controls: they show while the mouse moves (or sits near the bottom) and fade out after
    private var controlsShown: Bool { showControls.visible || bottomHover.isNear }

    private var stripShown: Bool {
        switch filmstripMode {
        case .always: controlsShown
        case .hover: bottomHover.isNear
        case .off: false
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if stripShown {
                Filmstrip(gallery: gallery, current: index)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if gallery.presenting && !photo.isVideo {
                showBar
                    .opacity(controlsShown ? 1 : 0)
                    .allowsHitTesting(controlsShown)
            } else {
                // One capsule for photos and films: moving between them, it reshapes instead of being swapped
                controlCapsule
                    .opacity(capsuleShown ? 1 : 0)
                    .allowsHitTesting(capsuleShown)
            }
        }
        .padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.25), value: capsuleShown)
        .modifier(PlaybackKeys(state: playback, active: hasPlayer))
    }

    /// Photos: with the other controls; films: also whenever paused
    private var capsuleShown: Bool { photo.isVideo ? playerBarShown : controlsShown }

    /// While the film plays, the bar hides with the other controls after a moment without mouse movement;
    /// paused, or with the pointer near the bottom, it stays
    private var playerBarShown: Bool {
        controlsShown || !playback.playing
    }

    /// The film is playing (or ready to), so the player bar is shown
    private var hasPlayer: Bool {
        guard photo.isVideo else { return false }
        switch video {
        case .play, .mpv: return true
        default: return false
        }
    }

    private struct SlideKey: Hashable {
        let url: URL
        let running: Bool
        let seconds: Double
        let waitsForFilmEnd: Bool
    }

    private var waitsForFilmEnd: Bool {
        guard photo.isVideo else { return false }
        if case .unsupported = video { return false }
        return true
    }

    /// Controls during the show: shown while the mouse moves, then hidden together with the cursor
    private var showBar: some View {
        HStack(spacing: 14) {
            Button { gallery.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Poprzednie (←)")
            Button { gallery.slideshow.toggle() } label: {
                Image(systemName: gallery.slideshow ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(gallery.slideshow ? "Zatrzymaj pokaz slajdów (spacja)" : "Pokaz slajdów (spacja)")
            Button { gallery.step(1) } label: { Image(systemName: "chevron.right") }
                .help("Następne (→)")
            Picker("Co", selection: $slideSeconds) {
                ForEach([2.0, 3, 5, 10, 20, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Czas wyświetlania zdjęcia w pokazie slajdów")
            Picker("Przejście", selection: $transitionSetting) {
                ForEach(SlideTransition.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Przejście między zdjęciami w pokazie")
            filmstripMenu
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1) / \(gallery.visible.count) — \(photo.url.lastPathComponent)")
                Text(photo.group).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 420, alignment: .leading)
            Button { adjustments.panelVisible.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Panel korekt obrazu (⌘E)")
            Button { gallery.presenting = false } label: { Image(systemName: "xmark") }
                .help("Zakończ pokaz (Esc lub F)")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var filmstripMode: FilmstripMode { FilmstripMode(rawValue: filmstripSetting) ?? .hover }

    /// Choice of when the thumbnail strip shows
    private var filmstripMenu: some View {
        Menu {
            Picker("Pasek miniatur", selection: $filmstripSetting) {
                ForEach(FilmstripMode.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "rectangle.bottomthird.inset.filled")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pasek miniatur sąsiednich zdjęć (T)")
    }

    /// "12 / 248 · 4032×3024 · 2,8 MB"
    private var metaLine: String {
        var parts = ["\(index + 1) / \(gallery.visible.count)"]
        if !photo.isVideo, let fullSize { parts.append("\(Int(fullSize.width))×\(Int(fullSize.height))") }
        if let fileSize { parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    /// Name and details on the left, actions on the right, floating over the top of the picture
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { gallery.selected = nil } label: {
                Label("Siatka", systemImage: "chevron.left")
            }
            .help("Wróć do siatki (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(photo.url.lastPathComponent).fontWeight(.medium)
                Text(metaLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            let favourite = gallery.favorites.contains(photo.url)
            Button { gallery.toggleFavorite(photo.url) } label: {
                Image(systemName: favourite ? "heart.fill" : "heart").foregroundStyle(favourite ? .pink : .primary)
            }
            .help(favourite ? "Usuń z ulubionych (L)" : "Dodaj do ulubionych (L)")
            Button { adjustments.panelVisible.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Korekty obrazu (⌘E)")
            Button { infoVisible.toggle() } label: { Image(systemName: infoVisible ? "info.circle.fill" : "info.circle") }
                .help("Informacje o pliku (I)")
            if location != nil {
                Button {
                    if mapVisible { mapVisible = false } else if PhotoLocation.allowMap() { mapVisible = true }
                } label: { Image(systemName: mapVisible ? "map.fill" : "map") }
                .help(mapVisible ? "Ukryj mapę (M)" : "Pokaż na mapie, gdzie zrobiono zdjęcie (M)")
            }
            if !photo.isVideo {
                Menu {
                    EditInMenuItems(photo: photo, gallery: gallery)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(photo.isTemporary ? "Edycja w innym programie jest niedostępna dla plików z archiwów i biblioteki Zdjęć"
                                        : "Edytuj w innym programie (Photoshop, Pixelmator…)")
                Button { gallery.printCurrent() } label: { Image(systemName: "printer") }
                    .help("Drukuj zdjęcie tak, jak je widać (⌘P)")
            }
            filmstripMenu
            if !photo.isTemporary {
                Button { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) } label: { Image(systemName: "folder") }
                    .help("Pokaż w Finderze")
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 14).padding(.top, 12)
    }

    /// ‹ ▶ ›  |  − 100% +  Dopasuj  1:1  |  full screen
    /// ‹ ▶ › | zoom | ⤢ for a photo; ‹ ⏪ ⏯ ⏩ › | progress | speed, volume | ⤢ for a film. The shared buttons
    /// keep their place and the capsule springs to its new width, so going from one to the other morphs it.
    private var controlCapsule: some View {
        let film = photo.isVideo
        // Outgoing parts fade at once; incoming ones appear just after, while the capsule is already reshaping,
        // so the two sets never overlap
        let parts = AnyTransition.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85)).animation(.easeOut(duration: 0.22).delay(0.14)),
            removal: .opacity.animation(.easeIn(duration: 0.08)))
        return HStack(spacing: 14) {
            Button { gallery.step(-1) } label: { Image(systemName: "chevron.left") }
                .help(film ? String(localized: "Poprzedni plik (←)") : String(localized: "Poprzednie (←)"))
            if film {
                Button { playback.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                    .help(String(localized: "10 s wstecz (⇧←)"))
                    .transition(parts)
            }
            Button {
                if film { playback.togglePlay() } else { gallery.present(slideshow: true) }
            } label: {
                Image(systemName: film && playback.playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
            .help(film ? (playback.playing ? String(localized: "Pauza (spacja)") : String(localized: "Odtwórz (spacja)"))
                       : String(localized: "Pokaz slajdów na pełnym ekranie"))
            if film {
                Button { playback.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                    .help(String(localized: "10 s do przodu (⇧→)"))
                    .transition(parts)
            }
            Button { gallery.step(1) } label: { Image(systemName: "chevron.right") }
                .help(film ? String(localized: "Następny plik (→)") : String(localized: "Następne (→)"))
            Divider().frame(height: 18)
            if film {
                PlaybackProgress(state: playback)
                    .transition(parts)
                Divider().frame(height: 18)
                PlaybackExtras(state: playback)
                    .transition(parts)
            } else {
                HStack(spacing: 14) {
                    Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Pomniejsz (−)")
                    Text("\(Int((zoom.scale * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
                    Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Powiększ (+)")
                    Button("Dopasuj") { zoom.fit() }.help("Dopasuj do okna (0)")
                    Button("1:1") { zoom.actualSize() }.help("Rzeczywisty rozmiar (1)")
                }
                .transition(parts)
            }
            Divider().frame(height: 18)
            if film {
                Button { rotateFilm(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .help(String(localized: "Obróć film (⌘R, ⌘L w lewo)"))
                    .transition(parts)
            }
            Button {
                if gallery.presenting { gallery.presenting = false } else { gallery.present() }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Pełny ekran (F)")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: film)
    }

    /// Quarter turns for the film on screen: set by hand, or (if chosen in Image) a portrait film turned to
    /// fill a landscape window
    private var filmTurns: Int {
        if let manual = gallery.videoTurns[photo.url] { return manual }
        let size = playback.videoSize
        guard portraitTurns != 0, size.height > size.width * 1.05, windowIsLandscape else { return 0 }
        return portraitTurns
    }

    private var windowIsLandscape: Bool {
        guard let frame = (NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible))?.frame else { return true }
        return frame.width >= frame.height
    }

    private func rotateFilm(clockwise: Bool) {
        gallery.setVideoTurns(photo.url, (filmTurns + (clockwise ? 1 : -1)) % 4)
    }

    /// The player laid out for its turn (sideways it gets the window's height as width) and turned, with a spring
    private func turned<Content: View>(_ player: Content) -> some View {
        let turns = filmTurns
        return GeometryReader { geometry in
            let sideways = turns % 2 != 0
            player
                .frame(width: sideways ? geometry.size.height : geometry.size.width,
                       height: sideways ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(Double(turns) * 90))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: turns)
    }

    private func loadPhoto() async {
        startTransition(from: image)
        video = .checking
        let url = photo.url
        truncated = false
        conversion = nil
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        location = nil
        if photo.isVideo {
            original = nil
            image = nil
            imageURL = nil
            playback.position = 0
            playback.duration = 0
            playback.failed = false
            playback.videoSize = .zero
            // A film from the Photos library plays from the library's own file
            let url = await PhotoLibrary.playable(url)
            if Task.isCancelled { return }
            // Formats outside Apple's own (AVI, MKV, WMV…) go straight to mpv: it plays them as they are
            if MPV.isAvailable, !VideoSupport.nativeContainers.contains(url.pathExtension.lowercased()) {
                video = .mpv(url)
                return
            }
            let info = await VideoSupport.inspect(url)
            if Task.isCancelled { return }
            if info.playable {
                video = .play(url, nil)
            } else if MPV.isAvailable {
                video = .mpv(url)
            } else if FFmpeg.isAvailable {
                video = .converting(codec: info.codec)
                let stream = await FFmpeg.playableStream(of: url) { fraction in
                    Task { @MainActor in
                        // Whole percents only, so the view redraws at most 100 times
                        if (fraction * 100).rounded() != ((conversion ?? -1) * 100).rounded() { conversion = fraction }
                    }
                }
                guard let stream else {
                    conversion = nil
                    if !Task.isCancelled { video = .unsupported(codec: info.codec) }
                    return
                }
                if Task.isCancelled { stream.cancel(); return }
                video = .play(stream.url, stream)
                // ffmpeg keeps going while the film plays; leaving the film stops it
                while !stream.isComplete {
                    if Task.isCancelled { stream.cancel(); return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                conversion = nil
            } else {
                video = .unsupported(codec: info.codec)
            }
        } else {
            baseIsFull = false
            if let cached = ThumbnailCache.shared.cachedDisplayImage(for: url) {
                // Already decoded by the prefetch: on screen in this very frame
                setBase(cached)
                show(cached.image, for: url)
            } else {
                // Grid thumbnail first, full resolution as soon as it is decoded; meanwhile the previous
                // photo stays up (in the show the transition needs the new one, so it starts from black)
                original = nil
                if let placeholder = ThumbnailCache.shared.placeholder(for: url) {
                    image = placeholder
                    imageURL = url
                } else if gallery.presenting {
                    image = nil
                    imageURL = url
                }
                let decoded = await ThumbnailCache.shared.displayImage(for: url)
                if Task.isCancelled { return }
                if let decoded {
                    setBase(decoded)
                    show(decoded.image, for: url)
                } else if imageURL != url {
                    original = nil
                    fullSize = nil
                    image = nil
                    imageURL = url
                }
            }
            truncated = await Task.detached(priority: .utility) { ThumbnailCache.isTruncated(url) }.value
            location = await Task.detached(priority: .utility) { PhotoLocation.coordinate(of: url) }.value
            // Mostly ahead in the direction of travel (the slideshow always goes forward), one behind
            let count = gallery.visible.count
            let last = gallery.lastShownIndex ?? index - 1
            let forward = gallery.slideshow || index > last || (last == count - 1 && index == 0)
            let offsets: [Int] = forward ? [1, 2, 3, -1] : [-1, -2, -3, 1]
            var neighbours: [URL] = []
            for offset in offsets {
                let i = (index + offset + count) % count
                guard i != index, gallery.visible.indices.contains(i), !gallery.visible[i].isVideo else { continue }
                neighbours.append(gallery.visible[i].url)
            }
            ThumbnailCache.shared.prefetch(neighbours)
        }
    }

    /// In the show, the previous photo gives way to the new one with the chosen transition
    private func startTransition(from previous: NSImage?) {
        let instant = Transaction(animation: nil)
        guard let previous, gallery.presenting || zoom.scale <= zoom.minScale * 1.01 else {
            withTransaction(instant) {
                outgoing = nil
                transitionProgress = 1
                kenBurnsScale = 1
            }
            return
        }
        // Outside the show: a short cross-fade (only from a fitted photo, so nothing jumps)
        let setting = SlideTransition(rawValue: transitionSetting) ?? .random
        let kind = !gallery.presenting ? .fade : setting == .random ? SlideTransition.concrete.randomElement()! : setting
        let duration = gallery.presenting ? SlideTransition.duration : 0.2
        let count = gallery.visible.count
        let last = gallery.lastShownIndex ?? index
        withTransaction(instant) {
            outgoing = previous
            transitionKind = kind
            // Forward also when wrapping from the last photo to the first
            movingForward = gallery.slideshow || index > last || (last == count - 1 && index == 0)
            transitionProgress = 0
            kenBurnsScale = 1
        }
        withAnimation(.easeInOut(duration: duration)) { transitionProgress = 1 }
        if kind == .kenBurns {
            withAnimation(.linear(duration: slideSeconds + duration)) { kenBurnsScale = 1.12 }
        }
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.05))
            if outgoing === previous { withTransaction(instant) { outgoing = nil } }
        }
    }

    private func setBase(_ decoded: DisplayImage) {
        original = decoded.image
        fullSize = decoded.fullSize
        baseIsFull = decoded.isFullResolution
        // Portrait photo, landscape window, turning chosen in Image: start it turned (the user can still turn it)
        if portraitTurns != 0, adjustments.values.quarterTurns == 0, windowIsLandscape,
           decoded.fullSize.height > decoded.fullSize.width * 1.05 {
            adjustments.values.quarterTurns = portraitTurns == 1 ? 1 : 3
        }
    }

    /// Size the picture is laid out at: the original's, whatever resolution is decoded, so zoom percentages
    /// and the switch to full resolution don't move anything
    private func logicalSize(of picture: CGImage) -> NSSize {
        guard let original, let fullSize, original.width > 0 else { return NSSize(width: picture.width, height: picture.height) }
        let factor = fullSize.width / CGFloat(original.width)
        return NSSize(width: CGFloat(picture.width) * factor, height: CGFloat(picture.height) * factor)
    }

    /// Puts a freshly loaded photo up at once; with corrections set, renderAdjusted shows it once corrected
    private func show(_ picture: CGImage, for url: URL) {
        guard adjustments.values.isIdentity else { return }
        image = NSImage(cgImage: picture, size: logicalSize(of: picture))
        imageURL = url
    }

    /// Zoomed in beyond what the screen-sized version holds: swap in the full resolution, same place and zoom
    private func loadFullResolutionIfNeeded() {
        guard !photo.isVideo, !baseIsFull, let original, let fullSize else { return }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        guard zoom.scale * fullSize.width * backing > CGFloat(original.width) * 1.1 else { return }
        let url = photo.url
        baseIsFull = true  // once per photo
        Task {
            guard let full = await ThumbnailCache.shared.fullResolutionImage(for: url), photo.url == url else { return }
            self.original = full
        }
    }

    private func renderAdjusted() async {
        guard let original else { return }
        let values = adjustments.values
        let url = photo.url
        if values.isIdentity {
            image = NSImage(cgImage: original, size: logicalSize(of: original))
            imageURL = url
            return
        }
        // Let slider drags settle; a newer value cancels this task before it renders
        try? await Task.sleep(for: .milliseconds(30))
        if Task.isCancelled { return }
        let rendered = await Task.detached(priority: .userInitiated) {
            ImageAdjustments.render(original, with: values)
        }.value
        if !Task.isCancelled, let rendered {
            if let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) { rendered.size = logicalSize(of: cg) }
            image = rendered
            imageURL = url
        }
    }

    @ViewBuilder private var videoArea: some View {
        switch video {
        case .checking:
            ZStack { Color.black; ProgressView() }
        case .mpv(let url):
            turned(MPVPlayer(url: url, state: playback))
        case .play(let url, let stream):
            ZStack(alignment: .topTrailing) {
                turned(VideoPlayer(url: url, stream: stream, state: playback))
                if let conversion {
                    // Playback has started; the rest of the film is still being prepared
                    Label(String(localized: "Przygotowuję resztę filmu: \(Int((conversion * 100).rounded()))%"), systemImage: "gearshape.2")
                        .monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(12)
                        .help("Do przodu można przewinąć tylko w gotowej części")
                }
            }
        case .converting(let codec):
            ZStack {
                Color.black
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Przygotowuję film do odtworzenia…").font(.title3)
                    Text("Format \(formatName(codec)) – konwersja odbywa się w pamięci RAM.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        case .unsupported(let codec):
            ZStack {
                Color.black
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 50))
                    if !FFmpeg.isAvailable {
                        Text("macOS nie potrafi odtworzyć tego filmu (\(formatName(codec)))").font(.title3)
                        Text(String(localized: "Aby oglądać takie filmy w aplikacji, zainstaluj bezpłatny program ffmpeg\n(w Terminalu: brew install ffmpeg) i otwórz plik ponownie."))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if codec == nil {
                        // Neither macOS nor ffmpeg found a readable picture stream
                        Text("Plik jest uszkodzony lub niekompletny").font(.title3)
                        Text(String(localized: "Nie zawiera danych, które da się odczytać. Tak bywa z nagraniem przerwanym przed\nzakończeniem (np. MP4 bez indeksu zapisywanego na końcu pliku)."))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("macOS nie potrafi odtworzyć tego filmu (\(formatName(codec)))").font(.title3)
                        Text("Nie udało się go też przekonwertować – plik może być uszkodzony.")
                            .foregroundStyle(.secondary)
                    }
                    if !photo.isTemporary {
                        Button("Otwórz w innej aplikacji (np. VLC)") { NSWorkspace.shared.open(photo.url) }
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
    }

    private func formatName(_ codec: String?) -> String {
        let container = photo.url.pathExtension.uppercased()
        return codec.map { "\(container), kodek \($0)" } ?? container
    }
}

// MARK: - Full-screen show

/// How one photo gives way to the next during the full-screen show
enum SlideTransition: String, CaseIterable, Identifiable {
    case random, fade, slide, zoom, blur, cube, kenBurns

    static let duration = 0.9
    static let concrete: [SlideTransition] = [.fade, .slide, .zoom, .blur, .cube, .kenBurns]
    var id: String { rawValue }

    var name: String {
        switch self {
        case .random: String(localized: "Losowe przejścia")
        case .fade: String(localized: "Przenikanie")
        case .slide: String(localized: "Przesunięcie")
        case .zoom: String(localized: "Powiększenie")
        case .blur: String(localized: "Rozmycie")
        case .cube: String(localized: "Sześcian")
        case .kenBurns: String(localized: "Ken Burns (powolny najazd)")
        }
    }
}

/// The look of the outgoing or incoming photo at a point (0…1) of the transition
struct SlideEffect: ViewModifier {
    let kind: SlideTransition
    let progress: Double
    let incoming: Bool
    let width: CGFloat
    let forward: Bool

    func body(content: Content) -> some View {
        // How far this photo is from its resting place: incoming ones arrive, outgoing ones leave
        let away = incoming ? 1 - progress : progress
        let side: Double = (forward != incoming) ? -1 : 1
        switch kind {
        case .slide:
            content.offset(x: side * width * away)
        case .zoom:
            content.scaleEffect(incoming ? 1 - 0.15 * away : 1 + 0.35 * away).opacity(1 - away)
        case .blur:
            content.blur(radius: incoming ? 0 : 30 * away).opacity(1 - away)
        case .cube:
            // Two faces of a turning cube, joined along the edge where the photos meet
            content.rotation3DEffect(.degrees(side * 90 * away), axis: (x: 0, y: 1, z: 0),
                                     anchor: side > 0 ? .leading : .trailing, perspective: 0.6)
                .offset(x: side * width * away)
        case .fade, .kenBurns, .random:
            content.opacity(1 - away)
        }
    }
}

/// Shows the show's controls while the mouse moves; hides them, and the cursor, shortly after it stops
@MainActor final class ShowControls: ObservableObject {
    @Published private(set) var visible = true
    /// Hide the mouse pointer too (full screen only)
    var hidesCursor = true
    private var monitor: Any?
    private var hideTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        NSApp.keyWindow?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.poke() }
            return event
        }
        poke()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTask?.cancel()
        visible = true
    }

    /// Shows the controls now and starts the countdown to hiding them again
    func reveal() { poke() }

    private func poke() {
        if !visible { visible = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.visible = false
            if self.hidesCursor { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
}

// MARK: - App

/// Files sent from Finder ("Otwórz za pomocą" or the context-menu service), held until the window is ready
@MainActor enum ExternalOpen {
    private static var pending: [URL] = []
    static var handler: (([URL]) -> Void)? { didSet { flush() } }

    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending += urls
        flush()
    }

    private static func flush() {
        guard let handler, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        handler(urls)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// "Otwórz za pomocą" in Finder, or a file dropped on the Dock icon
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ExternalOpen.open(urls.filter(\.isFileURL)) }
    }

    /// Context-menu service "Otwórz w Migawce" (also works for folders, unlike "Otwórz za pomocą")
    @objc func openInViewer(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else { return }
        // A service call can launch the app without a window, so the files take the same route as
        // "Otwórz za pomocą": an open request to this app, which brings up the window and the app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
    }


    func applicationWillFinishLaunching(_ notification: Notification) {
        // One dark look everywhere – grid, sidebar, viewer – like the photo view, whatever the system theme
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // No window state (which may include window snapshots) is saved to disk
        UserDefaults.standard.register(defaults: [
            "ApplePersistenceIgnoreState": true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        SecureTemp.cleanupLeftovers()
        SecureTemp.shared.prepare()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SecureTemp.shared.destroy()
        SecureTemp.cleanupLeftovers()
    }
}

@main
struct PrzegladarkaZdjecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var gallery = Gallery()
    @StateObject private var adjustments = ImageAdjustments()
    @StateObject private var security = SecuritySettings()
    @AppStorage("showNames") private var showNames = true
    @AppStorage("filmstrip") private var filmstripSetting = FilmstripMode.hover.rawValue
    @AppStorage("gpsMap") private var gpsMap = false
    @AppStorage("startFullScreen") private var startFullScreen = false
    @AppStorage("allMetadata") private var allMetadata = false
    @AppStorage("infoPanel") private var infoPanel = false

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    /// The standard About window (name, icon, version and © from Info.plist) with the author and a short description
    private static func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(
            string: String(localized: "Autor: Tomasz Marchewka\n\nBezpieczna przeglądarka zdjęć, filmów i archiwów z danymi wrażliwymi. Wszystko tylko w pamięci RAM, automatyczne czyszczenie, żadnego wysyłania danych – zgodnie z duchem RODO.\n\nMigawka nie zastępuje szyfrowania dysku: dla pełnej ochrony włącz FileVault."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: centered])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5",
            // Without this the panel adds "(0.5)" after the version a second time
            .version: "",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // One window: files sent from Finder open in it instead of in a new window each time
        Window("Migawka", id: "main") {
            ContentView(gallery: gallery, adjustments: adjustments, security: security)
        }
            .windowToolbarStyle(.unified)
            .commands {
                ImageCommands(adjustments: adjustments, gallery: gallery)
                CommandGroup(replacing: .appInfo) {
                    Button("O programie Migawka") { Self.showAbout() }
                }
                CommandGroup(after: .newItem) {
                    Button("Otwórz bibliotekę Zdjęć") { gallery.openLibrary() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                }
                CommandGroup(replacing: .printItem) {
                    Button("Drukuj…") { gallery.printCurrent() }
                        .keyboardShortcut("p")
                        .disabled(gallery.visible.isEmpty)
                    Button("Drukuj stykówkę…") { gallery.printContactSheet() }
                        .keyboardShortcut("p", modifiers: [.command, .option])
                        .disabled(gallery.visible.isEmpty)
                }
                CommandGroup(after: .toolbar) {
                    Toggle("Nazwy plików pod miniaturami", isOn: $showNames)
                        .keyboardShortcut("n", modifiers: [.command, .option])
                    Picker("Pasek miniatur w podglądzie", selection: $filmstripSetting) {
                        ForEach(FilmstripMode.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Button(allMetadata && infoPanel ? "Ukryj wszystkie metadane" : "Pokaż wszystkie metadane") {
                        if allMetadata && infoPanel { allMetadata = false } else { allMetadata = true; infoPanel = true }
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    Toggle("Uruchamiaj na pełnym ekranie", isOn: $startFullScreen)
                    Button(gpsMap ? "Ukryj mapę lokalizacji" : "Pokaż mapę lokalizacji zdjęcia (M)") {
                        if gpsMap { gpsMap = false } else if PhotoLocation.allowMap() { gpsMap = true }
                    }
                    Divider()
                    Button("Pokaz na pełnym ekranie") { gallery.present() }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .disabled(gallery.visible.isEmpty)
                    Button("Pokaz slajdów") { gallery.present(slideshow: true) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                        .disabled(gallery.visible.isEmpty)
                }
                SecurityCommands(settings: security, wipeNow: { gallery.wipe() }, lockNow: { gallery.lock() })
            }
    }
}
