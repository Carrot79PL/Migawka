import SwiftUI
import AppKit
import Photos
import ImageIO
import AVFoundation

/// The Mac's Photos library (iCloud Photos included), read through PhotoKit.
/// Photos are handed over as data straight into memory; films are played from the library's own original.
/// Nothing is copied out of the library or written by this app. An original kept only in iCloud
/// ("Optimise Mac Storage") is downloaded by Photos itself into its own library, as the Photos app would.
///
/// Library items travel through the app as `migawka-photos://asset/<id>/<original file name>` URLs, so the
/// grid, favourites and caches treat them like files; the readers below turn them into data or a film.
enum PhotoLibrary {
    static let scheme = "migawka-photos"

    static func isAsset(_ url: URL) -> Bool { url.scheme == scheme }

    // MARK: Access

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static var isDenied: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .denied || status == .restricted
    }

    /// Asks macOS for access the first time; afterwards answers from the user's earlier choice
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: Albums

    struct Album: Identifiable, Hashable {
        /// nil = the whole library
        let id: String?
        let title: String
        let symbol: String
        let count: Int
    }

    /// The whole library, a few of Photos' own albums and the user's albums, empty ones left out
    static func albums() -> [Album] {
        var result: [Album] = []
        let all = PHAsset.fetchAssets(with: nil)
        result.append(Album(id: nil, title: String(localized: "Cała biblioteka"), symbol: "photo.on.rectangle", count: all.count))
        let smart: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumFavorites, "heart"), (.smartAlbumVideos, "film"), (.smartAlbumRecentlyAdded, "clock"),
            (.smartAlbumScreenshots, "camera.viewfinder"), (.smartAlbumSelfPortraits, "person.crop.square"),
        ]
        for (subtype, symbol) in smart {
            guard let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { continue }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > 0 {
                result.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "", symbol: symbol, count: count))
            }
        }
        var user: [Album] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            let shared = collection.assetCollectionSubtype == .albumCloudShared
            user.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "",
                              symbol: shared ? "person.2" : "rectangle.stack", count: count))
        }
        user.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result + user
    }

    // MARK: Listing

    /// Every photo and film in the album (or the library), in batches, grouped by year and month taken
    static func list(album: String?, shouldStop: () -> Bool, emit: ([Photo]) -> Void) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let fetch: PHFetchResult<PHAsset>
        if let album, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject {
            fetch = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: options)
        }
        let months = DateFormatter()
        months.setLocalizedDateFormatFromTemplate("LLLL")
        var batch: [Photo] = []
        var found: [String: PHAsset] = [:]
        for i in 0..<fetch.count {
            if i % 200 == 0, shouldStop() { return }
            let asset = fetch.object(at: i)
            let url = url(for: asset)
            found[asset.localIdentifier] = asset
            let group: String
            if let date = asset.creationDate {
                let parts = Calendar.current.dateComponents([.year, .month], from: date)
                group = String(format: "%d/%02d %@", parts.year ?? 0, parts.month ?? 0, months.string(from: date))
            } else {
                group = String(localized: "Bez daty")
            }
            batch.append(Photo(url: url, group: group, isTemporary: true))
            if batch.count == 500 {
                assets.merge(found)
                found = [:]
                emit(batch)
                batch = []
            }
        }
        assets.merge(found)
        if !batch.isEmpty { emit(batch) }
    }

    /// The file name the photo had when it was taken or imported, with an extension that matches its kind
    private static func url(for asset: PHAsset) -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type) } ?? resources.first
        var name = primary?.originalFilename ?? asset.localIdentifier
        if (name as NSString).pathExtension.isEmpty { name += asset.mediaType == .video ? ".mov" : ".jpg" }
        // Identifiers hold "/", which would split the path
        let id = asset.localIdentifier.replacingOccurrences(of: "/", with: "~")
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "photo"
        return URL(string: "\(scheme)://asset/\(id)/\(encodedName)")!
    }

    /// Assets seen while listing, by identifier
    private static let assets = AssetTable<PHAsset>()

    static func asset(for url: URL) -> PHAsset? {
        guard isAsset(url), url.pathComponents.count >= 2 else { return nil }
        let id = url.pathComponents[1].replacingOccurrences(of: "~", with: "/")
        if let known = assets.get(id) { return known }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Reading

    /// Recently read photos, as data in memory only, so the size check and the decode don't fetch twice
    private static let data: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 400 * 1024 * 1024
        return cache
    }()
    private static let videoFiles = AssetTable<URL>()

    /// The photo as stored in the library (with the user's edits from Photos), read into memory.
    /// Blocks: call it off the main thread.
    static func imageData(_ url: URL) -> Data? {
        if let cached = data.object(forKey: url as NSURL) { return cached as Data }
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        var result: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { bytes, _, _, _ in result = bytes }
        if let result { data.setObject(result as NSData, forKey: url as NSURL, cost: result.count) }
        return result
    }

    /// An ImageIO source for a file or a library photo
    static func imageSource(_ url: URL) -> CGImageSource? {
        if isAsset(url) { return imageData(url).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    /// A grid thumbnail from Photos' own small versions: fast, and no download of the original
    static func thumbnail(_ url: URL, maxPixels: CGFloat) async -> NSImage? {
        guard let asset = asset(for: url) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixels, height: maxPixels),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The film's file inside the library (for a library film), or the URL itself (for anything else)
    static func playable(_ url: URL) async -> URL {
        guard isAsset(url) else { return url }
        if let known = videoFiles.get(url.absoluteString) { return known }
        guard let asset = asset(for: url) else { return url }
        // The edited version first; a slow-motion film's edit is a composition without a file, so then the original
        for version in [PHVideoRequestOptionsVersion.current, .original] {
            let options = PHVideoRequestOptions()
            options.version = version
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let film = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { film, _, _ in
                    continuation.resume(returning: (film as? AVURLAsset)?.url)
                }
            }
            if let film {
                videoFiles.set(url.absoluteString, film)
                return film
            }
        }
        return url
    }

    /// Length straight from the library, without opening the film
    static func duration(_ url: URL) -> Double? {
        guard let asset = asset(for: url), asset.mediaType == .video, asset.duration > 0 else { return nil }
        return asset.duration
    }

    /// Forgets everything read from the library (the wipe and opening another source)
    static func clear() {
        data.removeAllObjects()
        videoFiles.removeAll()
        assets.removeAll()
    }

    /// What the library itself knows about a photo or film, for the full details
    static func details(_ url: URL) -> [(String, String)] {
        guard let asset = asset(for: url) else { return [] }
        var rows: [(String, String)] = []
        let resources = PHAssetResource.assetResources(for: asset)
        if let name = resources.first?.originalFilename { rows.append((String(localized: "Oryginalna nazwa"), name)) }
        rows.append((String(localized: "Wymiary"), "\(asset.pixelWidth) × \(asset.pixelHeight) px"))
        if let date = asset.creationDate { rows.append((String(localized: "Data utworzenia"), date.formatted(date: .long, time: .standard))) }
        if let date = asset.modificationDate { rows.append((String(localized: "Data modyfikacji"), date.formatted(date: .long, time: .standard))) }
        if asset.mediaType == .video { rows.append((String(localized: "Czas"), Duration.seconds(asset.duration).formatted(.time(pattern: .hourMinuteSecond)))) }
        rows.append((String(localized: "Ulubione w Zdjęciach"), asset.isFavorite ? String(localized: "tak") : String(localized: "nie")))
        var kinds: [String] = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoLive) { kinds.append("Live Photo") }
        if subtypes.contains(.photoHDR) { kinds.append("HDR") }
        if subtypes.contains(.photoPanorama) { kinds.append(String(localized: "panorama")) }
        if subtypes.contains(.photoScreenshot) { kinds.append(String(localized: "zrzut ekranu")) }
        if subtypes.contains(.photoDepthEffect) { kinds.append(String(localized: "portret")) }
        if subtypes.contains(.videoHighFrameRate) { kinds.append(String(localized: "zwolnione tempo")) }
        if subtypes.contains(.videoTimelapse) { kinds.append(String(localized: "poklatkowy")) }
        if subtypes.contains(.videoCinematic) { kinds.append(String(localized: "kinowy")) }
        if !kinds.isEmpty { rows.append((String(localized: "Rodzaj"), kinds.joined(separator: ", "))) }
        if asset.representsBurst { rows.append((String(localized: "Seria zdjęć"), String(localized: "tak"))) }
        if resources.contains(where: { $0.type == .adjustmentData }) {
            rows.append((String(localized: "Edytowane w Zdjęciach"), String(localized: "tak")))
        }
        rows.append((String(localized: "Zasoby"), resources.map { "\($0.originalFilename) (\(resourceName($0.type)))" }.joined(separator: "\n")))
        return rows
    }

    private static func resourceName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: String(localized: "zdjęcie")
        case .video: String(localized: "film")
        case .audio: String(localized: "dźwięk")
        case .alternatePhoto: String(localized: "zdjęcie alternatywne")
        case .fullSizePhoto: String(localized: "zdjęcie po edycji")
        case .fullSizeVideo: String(localized: "film po edycji")
        case .adjustmentData: String(localized: "dane edycji")
        case .pairedVideo, .fullSizePairedVideo: String(localized: "film Live Photo")
        case .adjustmentBasePhoto, .adjustmentBaseVideo, .adjustmentBasePairedVideo: String(localized: "podstawa edycji")
        default: String(localized: "inny")
        }
    }
}

/// A small thread-safe dictionary
final class AssetTable<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    func get(_ key: String) -> Value? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ key: String, _ value: Value) { lock.lock(); values[key] = value; lock.unlock() }
    func merge(_ other: [String: Value]) { lock.lock(); values.merge(other) { $1 }; lock.unlock() }
    func removeAll() { lock.lock(); values = [:]; lock.unlock() }
}

/// The library's albums for the sidebar, loaded once access is given
@MainActor final class PhotoLibraryModel: ObservableObject {
    static let shared = PhotoLibraryModel()
    @Published private(set) var albums: [PhotoLibrary.Album] = []
    @Published private(set) var denied = PhotoLibrary.isDenied

    init() {
        if PhotoLibrary.isAuthorized { refresh() }
    }

    /// First use: the system asks for access, then the albums appear
    func connect() async -> Bool {
        let granted = await PhotoLibrary.requestAccess()
        denied = !granted
        if granted {
            if albums.isEmpty { refresh() }
        } else {
            Self.explainDenied()
        }
        return granted
    }

    /// Access was refused earlier: only System Settings can change that
    private static func explainDenied() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Migawka nie ma dostępu do biblioteki Zdjęć")
        alert.informativeText = String(localized: "Dostęp możesz włączyć w Ustawieniach systemowych › Prywatność i ochrona › Zdjęcia.")
        alert.addButton(withTitle: String(localized: "Otwórz Ustawienia"))
        alert.addButton(withTitle: String(localized: "Anuluj"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let albums = PhotoLibrary.albums()
            await MainActor.run { self.albums = albums }
        }
    }
}
