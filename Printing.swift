import AppKit

/// Printing of the open photo (as shown, with corrections) and of contact sheets of the grid.
/// macOS passes every print job through its print queue on disk, so the user is told before the first one.
@MainActor enum Printer {
    static func printImage(_ image: NSImage, title: String) {
        guard confirmPrintQueue() else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = image.size.width > image.size.height ? .landscape : .portrait
        setUp(info)
        let view = ImagePrintView(image: image, frame: NSRect(origin: .zero, size: info.imageablePageBounds.size))
        run(view, info: info, title: title)
    }

    /// A grid of small pictures with their names, several pages if needed
    static func printContactSheet(_ photos: [Photo], title: String) async {
        guard !photos.isEmpty, confirmPrintQueue() else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .portrait
        setUp(info)
        let limit = Array(photos.prefix(ContactSheetView.maxPhotos))
        let pictures = await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (i, photo) in limit.enumerated() {
                group.addTask {
                    let image = photo.isVideo
                        ? await VideoSupport.thumbnail(photo.url, maxPixels: 400)
                        : await Task.detached { ThumbnailCache.load(photo.url, maxPixels: 400) }.value
                    return (i, image)
                }
            }
            var result = [NSImage?](repeating: nil, count: limit.count)
            for await (i, image) in group { result[i] = image }
            return result
        }
        let view = ContactSheetView(items: zip(limit, pictures).map { ($0.url.lastPathComponent, $1) },
                                    title: title, pageSize: info.imageablePageBounds.size)
        run(view, info: info, title: title)
    }

    private static func setUp(_ info: NSPrintInfo) {
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.topMargin = 24; info.bottomMargin = 24; info.leftMargin = 24; info.rightMargin = 24
    }

    private static func run(_ view: NSView, info: NSPrintInfo, title: String) {
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.insert([.showsPreview, .showsCopies, .showsPageRange, .showsPaperSize])
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Print jobs (and "Save as PDF") are written to disk by macOS, outside the app's RAM-only rule
    private static func confirmPrintQueue() -> Bool {
        let key = "printQueueNoticeAccepted"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Wydruk opuszcza bezpieczną pamięć aplikacji")
        alert.informativeText = String(localized: "macOS przekazuje każdy wydruk przez systemową kolejkę drukowania, która zapisuje go na dysku do czasu wydrukowania. „Zachowaj jako PDF” tworzy zwykły plik na dysku. Przy danych objętych RODO drukuj tylko na zaufanej drukarce i usuwaj zapisane PDF-y.")
        alert.addButton(withTitle: String(localized: "Drukuj"))
        alert.addButton(withTitle: String(localized: "Anuluj"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Nie pokazuj ponownie")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
        return ok
    }
}

/// One picture, as large as the page allows
final class ImagePrintView: NSView {
    private let image: NSImage

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let rect = NSRect(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

/// Contact sheet: 4 columns, a header on every page, names under the pictures
final class ContactSheetView: NSView {
    static let maxPhotos = 600
    private let items: [(name: String, image: NSImage?)]
    private let title: String
    private let pageSize: NSSize
    private let columns = 4
    private let header: CGFloat = 28
    private let gap: CGFloat = 10
    private var cell: CGFloat { (pageSize.width - gap * CGFloat(columns - 1)) / CGFloat(columns) }
    private var rowHeight: CGFloat { cell + 18 }
    private var rowsPerPage: Int { max(1, Int((pageSize.height - header + gap) / (rowHeight + gap))) }
    private var perPage: Int { rowsPerPage * columns }
    private var pages: Int { max(1, (items.count + perPage - 1) / perPage) }

    init(items: [(String, NSImage?)], title: String, pageSize: NSSize) {
        self.items = items.map { (name: $0.0, image: $0.1) }
        self.title = title
        self.pageSize = pageSize
        super.init(frame: .zero)
        setFrameSize(NSSize(width: pageSize.width, height: pageSize.height * CGFloat(pages)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: pageSize.height * CGFloat(page - 1), width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.black]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
        for page in 0..<pages {
            let top = pageSize.height * CGFloat(page)
            guard dirtyRect.intersects(NSRect(x: 0, y: top, width: pageSize.width, height: pageSize.height)) else { continue }
            (String(localized: "\(title) — strona \(page + 1) z \(pages)") as NSString).draw(at: NSPoint(x: 0, y: top), withAttributes: heading)
            for slot in 0..<perPage {
                let i = page * perPage + slot
                guard i < items.count else { break }
                let x = CGFloat(slot % columns) * (cell + gap)
                let y = top + header + CGFloat(slot / columns) * (rowHeight + gap)
                let box = NSRect(x: x, y: y, width: cell, height: cell)
                NSColor(white: 0.93, alpha: 1).setFill()
                box.fill()
                if let image = items[i].image, image.size.width > 0, image.size.height > 0 {
                    let scale = min(cell / image.size.width, cell / image.size.height)
                    let w = image.size.width * scale, h = image.size.height * scale
                    image.draw(in: NSRect(x: x + (cell - w) / 2, y: y + (cell - h) / 2, width: w, height: h),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                let name = items[i].name as NSString
                name.draw(with: NSRect(x: x, y: y + cell + 3, width: cell, height: 12),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: caption)
            }
        }
    }
}
