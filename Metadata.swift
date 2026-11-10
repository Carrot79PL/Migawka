import SwiftUI
import AppKit
import ImageIO
import AVFoundation
import CoreServices

/// Everything known about a photo or film, grouped like Preview's inspector and Finder's Get Info:
/// the file and Spotlight's attributes, then the picture's EXIF, TIFF, GPS, IPTC… dictionaries,
/// or the film's tracks and embedded metadata. Read on demand, kept only while shown.
enum Metadata {
    struct Section: Identifiable {
        let id = UUID()
        let title: String
        var rows: [(String, String)]
    }

    static func all(for photo: Photo) async -> [Section] {
        let url = photo.url
        var sections: [Section] = []
        if PhotoLibrary.isAsset(url) {
            let rows = PhotoLibrary.details(url)
            if !rows.isEmpty { sections.append(Section(title: String(localized: "Biblioteka Zdjęć"), rows: rows)) }
        } else {
            let file = fileRows(url)
            if !file.isEmpty { sections.append(Section(title: String(localized: "Plik"), rows: file)) }
            let spotlight = spotlightRows(url)
            if !spotlight.isEmpty { sections.append(Section(title: "Spotlight", rows: spotlight)) }
        }
        if photo.isVideo {
            sections += await videoSections(url)
        } else {
            sections += await Task.detached(priority: .userInitiated) { imageSections(url) }.value
        }
        return sections
    }

    // MARK: File

    private static func fileRows(_ url: URL) -> [(String, String)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey, .localizedTypeDescriptionKey, .typeIdentifierKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return [] }
        var rows: [(String, String)] = [(String(localized: "Nazwa"), url.lastPathComponent)]
        if let kind = values.localizedTypeDescription { rows.append((String(localized: "Rodzaj"), kind)) }
        if let type = values.typeIdentifier { rows.append((String(localized: "Typ (UTI)"), type)) }
        if let size = values.fileSize {
            rows.append((String(localized: "Rozmiar"), "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size.formatted()) B)"))
        }
        if let date = values.creationDate { rows.append((String(localized: "Utworzono"), format(date))) }
        if let date = values.contentModificationDate { rows.append((String(localized: "Zmodyfikowano"), format(date))) }
        if let date = values.contentAccessDate { rows.append((String(localized: "Ostatnio otwarty"), format(date))) }
        return rows
    }

    /// Finder's "More info": whatever Spotlight has indexed for the file (nothing for the RAM disk, which isn't indexed)
    private static func spotlightRows(_ url: URL) -> [(String, String)] {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let names = MDItemCopyAttributeNames(item) as? [String] else { return [] }
        let skipped: Set<String> = ["kMDItemFSName", "kMDItemDisplayName", "kMDItemPath", "kMDItemFSSize",
                                    "kMDItemFSCreationDate", "kMDItemFSContentChangeDate", "kMDItemContentTypeTree",
                                    "kMDItemFSOwnerUserID", "kMDItemFSOwnerGroupID", "kMDItemFSNodeCount",
                                    "kMDItemFSFinderFlags", "kMDItemFSTypeCode", "kMDItemFSCreatorCode",
                                    "kMDItemFSInvisible", "kMDItemFSIsExtensionHidden", "kMDItemFSLabel",
                                    "kMDItemDocumentIdentifier", "_kMDItemDisplayNameWithExtensions"]
        var rows: [(String, String)] = []
        for name in names.sorted() where !skipped.contains(name) && !name.hasPrefix("_") {
            guard let value = MDItemCopyAttribute(item, name as CFString), let text = describe(value) else { continue }
            rows.append((readable(String(name.dropFirst(name.hasPrefix("kMDItem") ? 7 : 0))), text))
        }
        return rows
    }

    // MARK: Pictures

    private static func imageSections(_ url: URL) -> [Section] {
        guard let source = PhotoLibrary.imageSource(url) else { return [] }
        var sections: [Section] = []
        var general: [(String, String)] = []
        if let type = CGImageSourceGetType(source) as String? { general.append((String(localized: "Format"), type)) }
        let count = CGImageSourceGetCount(source)
        if count > 1 { general.append((String(localized: "Obrazy w pliku"), "\(count)")) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return general.isEmpty ? [] : [Section(title: String(localized: "Obraz"), rows: general)]
        }
        var dictionaries: [(String, [String: Any])] = []
        for (key, value) in props {
            if let dictionary = value as? [String: Any] {
                dictionaries.append((key, dictionary))
            } else if let text = describe(value) {
                general.append((readable(key), text))
            }
        }
        general.sort { $0.0 < $1.0 }
        if !general.isEmpty { sections.append(Section(title: String(localized: "Obraz"), rows: general)) }
        // The usual order of Preview's tabs, then anything else (maker notes, PNG, HEIC…)
        let order = ["{Exif}", "{ExifAux}", "{TIFF}", "{GPS}", "{IPTC}"]
        dictionaries.sort { a, b in
            let i = order.firstIndex(of: a.0) ?? order.count, j = order.firstIndex(of: b.0) ?? order.count
            return i != j ? i < j : a.0 < b.0
        }
        for (key, dictionary) in dictionaries {
            let rows = flatten(dictionary)
            if !rows.isEmpty { sections.append(Section(title: dictionaryName(key), rows: rows)) }
        }
        return sections
    }

    private static func dictionaryName(_ key: String) -> String {
        let bare = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        switch bare {
        case "Exif": return "EXIF"
        case "ExifAux": return String(localized: "EXIF (dodatkowe)")
        case "MakerApple": return "Apple"
        case "MakerCanon": return "Canon"
        case "MakerNikon": return "Nikon"
        case "MakerFuji": return "Fujifilm"
        case "MakerOlympus": return "Olympus"
        case "MakerPentax": return "Pentax"
        case "MakerMinolta": return "Minolta"
        case "8BIM": return "Photoshop"
        default: return bare
        }
    }

    /// Nested dictionaries become "Parent › Child" rows
    private static func flatten(_ dictionary: [String: Any], prefix: String = "") -> [(String, String)] {
        var rows: [(String, String)] = []
        for key in dictionary.keys.sorted() {
            let name = prefix + readable(key)
            if let inner = dictionary[key] as? [String: Any] {
                rows += flatten(inner, prefix: name + " › ")
            } else if let text = describe(dictionary[key]!) {
                rows.append((name, text))
            }
        }
        return rows
    }

    // MARK: Films

    private static func videoSections(_ url: URL) async -> [Section] {
        let file = await PhotoLibrary.playable(url)
        let asset = AVURLAsset(url: file)
        var sections: [Section] = []
        var general: [(String, String)] = []
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            general.append((String(localized: "Czas"), String(format: "%.3f s", duration.seconds)))
        }
        if let date = try? await asset.load(.creationDate), let text = try? await date.load(.stringValue) {
            general.append((String(localized: "Data utworzenia"), text))
        }
        if let rate = try? await asset.load(.preferredRate), rate != 1 { general.append((String(localized: "Prędkość"), "\(rate)")) }
        if !general.isEmpty { sections.append(Section(title: String(localized: "Film"), rows: general)) }

        let tracks = (try? await asset.load(.tracks)) ?? []
        for (i, track) in tracks.enumerated() {
            var rows: [(String, String)] = [(String(localized: "Rodzaj"), trackKind(track.mediaType))]
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                rows.append((String(localized: "Kodek"), fourCC(CMFormatDescriptionGetMediaSubType(format))))
                if track.mediaType == .audio, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    rows.append((String(localized: "Próbkowanie"), "\(Int(basic.mSampleRate)) Hz"))
                    rows.append((String(localized: "Kanały"), "\(basic.mChannelsPerFrame)"))
                }
                if let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
                    for key in ["CVImageBufferColorPrimaries", "CVImageBufferTransferFunction", "CVImageBufferYCbCrMatrix", "BitsPerComponent", "FormatName"] {
                        if let value = extensions[key], let text = describe(value) { rows.append((readable(key), text)) }
                    }
                }
            }
            if track.mediaType == .video {
                if let size = try? await track.load(.naturalSize) {
                    rows.append((String(localized: "Wymiary"), "\(Int(size.width)) × \(Int(size.height)) px"))
                }
                if let transform = try? await track.load(.preferredTransform), transform != .identity {
                    let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
                    rows.append((String(localized: "Obrót"), "\(degrees)°"))
                }
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    rows.append((String(localized: "Klatki na sekundę"), String(format: "%.3f", fps)))
                }
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                rows.append((String(localized: "Przepływność"), "\(Int((rate / 1000).rounded())) kb/s"))
            }
            if let language = try? await track.load(.languageCode), language != "und" {
                rows.append((String(localized: "Język"), language))
            }
            sections.append(Section(title: String(localized: "Ścieżka \(i + 1)"), rows: rows))
        }

        var embedded: [(String, String)] = []
        for metadataFormat in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            for item in (try? await asset.loadMetadata(for: metadataFormat)) ?? [] {
                let key = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "?"
                var text: String?
                if let date = try? await item.load(.dateValue) { text = format(date) }
                if text == nil, let string = try? await item.load(.stringValue) { text = string }
                if text == nil, let number = try? await item.load(.numberValue) { text = number.stringValue }
                if let text, !text.isEmpty { embedded.append((readable(metadataKey(key)), text)) }
            }
        }
        if !embedded.isEmpty { sections.append(Section(title: String(localized: "Metadane w pliku"), rows: embedded)) }

        // Containers macOS doesn't read (AVI, MKV…): what ffmpeg sees
        if tracks.isEmpty, FFmpeg.isAvailable, !PhotoLibrary.isAsset(file) {
            let rows = await FFmpeg.details(file)
            if !rows.isEmpty { sections.append(Section(title: "ffmpeg", rows: rows)) }
        }
        return sections
    }

    private static func trackKind(_ type: AVMediaType) -> String {
        switch type {
        case .video: String(localized: "obraz")
        case .audio: String(localized: "dźwięk")
        case .text, .subtitle, .closedCaption: String(localized: "napisy")
        case .timecode: String(localized: "kod czasowy")
        case .metadata: String(localized: "metadane")
        default: type.rawValue
        }
    }

    /// "mdta/com.apple.quicktime.location.ISO6709" → "location.ISO6709", "uiso/%A9too" → "©too"
    private static func metadataKey(_ identifier: String) -> String {
        let decoded = identifier.replacingOccurrences(of: "%A9", with: "©")
        var key = decoded.removingPercentEncoding ?? decoded
        if let slash = key.firstIndex(of: "/") { key = String(key[key.index(after: slash)...]) }
        for prefix in ["com.apple.quicktime.", "com.apple.photos.", "com.apple."] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        return key
    }

    // MARK: Formatting

    /// Values as text; nil for what can't be shown (thumbnails and other binary data show only their size)
    private static func describe(_ value: Any) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? String(localized: "tak") : String(localized: "nie") }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? "\(Int64(double))" : String(format: "%.6g", double)
        case let date as Date:
            return format(date)
        case let data as Data:
            return String(localized: "\(data.count) bajtów danych")
        case let array as [Any]:
            let parts = array.compactMap(describe)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            let text = "\(value)"
            return text.isEmpty ? nil : text
        }
    }

    private static func format(_ date: Date) -> String { date.formatted(date: .long, time: .standard) }

    /// "ExposureBiasValue" → "Exposure Bias Value", "ISOSpeedRatings" → "ISO Speed Ratings"
    static func readable(_ key: String) -> String {
        var result = ""
        let chars = Array(key)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let previous = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) { result.append(" ") }
            } else if i > 0, c.isNumber, chars[i - 1].isLetter, chars[i - 1].isLowercase {
                result.append(" ")
            }
            result.append(c)
        }
        return result.replacingOccurrences(of: "_", with: " ")
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "\(code)" : text
    }
}

extension FFmpeg {
    /// Container and stream details as ffmpeg prints them, one row per line
    static func details(_ url: URL) async -> [(String, String)] {
        guard let path else { return [] }
        let info = await Subprocess.run(path, ["-hide_banner", "-nostdin", "-i", url.path]).stderr
        var rows: [(String, String)] = []
        for line in info.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("Input #"), !text.contains("At least one output"), !text.isEmpty,
                  let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { rows.append((key, value)) }
        }
        return rows
    }
}

/// The full list inside the info card: sections with a search field, everything selectable
struct AllMetadataView: View {
    let photo: Photo
    @State private var sections: [Metadata.Section] = []
    @State private var loading = true
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Szukaj w metadanych", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if shown.isEmpty {
                Text("Brak metadanych").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                                ForEach(section.rows.indices, id: \.self) { i in
                                    GridRow {
                                        Text(section.rows[i].0).foregroundStyle(.secondary)
                                            .frame(width: 130, alignment: .leading)
                                        Text(section.rows[i].1).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: photo.url) {
            loading = true
            sections = await Metadata.all(for: photo)
            loading = false
        }
    }

    private var shown: [Metadata.Section] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            var section = section
            section.rows = section.rows.filter { $0.0.localizedCaseInsensitiveContains(query) || $0.1.localizedCaseInsensitiveContains(query) }
            return section.rows.isEmpty ? nil : section
        }
    }
}
