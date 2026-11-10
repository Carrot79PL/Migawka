import SwiftUI
import ImageIO
import MapKit

/// File details beside the large view: camera settings for photos, codec and length for films.
/// Location data from the file is deliberately left out.
struct PhotoInfoPanel: View {
    let photo: Photo
    /// The decoded picture, for its size
    let image: CGImage?
    let fileSize: Int64?
    @State private var rows: [(String, String)] = []
    /// Everything in the file (⌥⌘I) instead of the summary
    @AppStorage("allMetadata") private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Informacje").font(.headline)
                Spacer()
                Button(showAll ? "Mniej" : "Wszystkie metadane") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Wszystkie dane zapisane w pliku: EXIF, TIFF, GPS, IPTC, Spotlight, ścieżki filmu (⌥⌘I)")
            }
            if showAll {
                AllMetadataView(photo: photo)
                    .transition(.opacity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow {
                            Text(rows[i].0).foregroundStyle(.secondary)
                            Text(rows[i].1).textSelection(.enabled).lineLimit(3)
                        }
                    }
                }
                .font(.callout)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: showAll ? 400 : 280, alignment: .leading)
        .frame(maxHeight: showAll ? .infinity : nil, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .task(id: photo.url) { rows = await Self.details(of: photo, size: fileSize) }
        .onChange(of: image == nil) { Task { rows = await Self.details(of: photo, size: fileSize) } }
    }

    static func details(of photo: Photo, size: Int64?) async -> [(String, String)] {
        var rows: [(String, String)] = [(String(localized: "Plik"), photo.url.lastPathComponent), (String(localized: "Folder"), photo.group)]
        if let size { rows.append((String(localized: "Rozmiar"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if photo.isVideo {
            if let duration = await VideoSupport.duration(photo.url) { rows.append((String(localized: "Czas"), duration)) }
            if let codec = await VideoSupport.inspect(photo.url).codec { rows.append((String(localized: "Kodek"), codec)) }
            return rows
        }
        let url = photo.url
        let props = await Task.detached(priority: .utility) {
            PhotoLibrary.imageSource(url)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        }.value
        guard let props else { return rows }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let megapixels = (Double(w * h) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
            rows.append((String(localized: "Wymiary"), String(localized: "\(String(w)) × \(String(h)) px (\(megapixels) Mpx)")))
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append((String(localized: "Zrobione"), formatDate(date))) }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !camera.isEmpty { rows.append((String(localized: "Aparat"), camera.joined(separator: " "))) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append((String(localized: "Obiektyw"), lens)) }
        var exposure: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "f/%.1f", f)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            exposure.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append(String(format: "%.0f mm", focal)) }
        if !exposure.isEmpty { rows.append((String(localized: "Ekspozycja"), exposure.joined(separator: " · "))) }
        if let coordinate = PhotoLocation.coordinate(of: url) {
            // Coordinates only once the user has chosen to see locations (the map option)
            rows.append((String(localized: "Lokalizacja"), UserDefaults.standard.bool(forKey: "gpsMap")
                ? PhotoLocation.text(coordinate) : String(localized: "zapisana w pliku (mapa: klawisz M)")))
        }
        return rows
    }

    /// "2024:07:15 18:32:10" → "15.07.2024, 18:32"
    private static func formatDate(_ exif: String) -> String {
        let parts = exif.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
        guard parts.count >= 5 else { return exif }
        return "\(parts[2]).\(parts[1]).\(parts[0]), \(parts[3]):\(parts[4])"
    }
}

/// Where a photo was taken, from its GPS data (nil when the file has none)
enum PhotoLocation {
    static func coordinate(of url: URL) -> CLLocationCoordinate2D? {
        guard let source = PhotoLibrary.imageSource(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { longitude = -longitude }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude), latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// "50.0614° N, 19.9366° E"
    static func text(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f° %@, %.4f° %@", abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }

    /// The map is the one thing in the app that goes online: tiles come from Apple's servers, which then
    /// learn which area is shown. Asked once, before the map is first switched on.
    @MainActor static func allowMap() -> Bool {
        let key = "gpsMapConsent"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Włączyć mapę miejsca zrobienia zdjęcia?")
        alert.informativeText = String(localized: "Mapa jest pobierana przez internet z serwerów Apple. Apple dowie się, jaki obszar jest pokazywany, czyli w przybliżeniu, gdzie zrobiono zdjęcie, a macOS może zachować fragmenty mapy w swojej pamięci podręcznej na dysku. Samo zdjęcie ani jego nazwa nie są nigdzie wysyłane.\n\nPrzy danych objętych RODO włączaj mapę tylko, gdy to konieczne.")
        alert.addButton(withTitle: String(localized: "Włącz mapę"))
        alert.addButton(withTitle: String(localized: "Anuluj"))
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok { UserDefaults.standard.set(true, forKey: key) }
        return ok
    }
}

/// Small map in the corner of the large view with a pin where the photo was taken
struct PhotoLocationMap: View {
    let coordinate: CLLocationCoordinate2D
    let close: () -> Void
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(position: $position) {
                Marker("", systemImage: "camera.fill", coordinate: coordinate)
            }
            .mapControls { MapZoomStepper() }
            .frame(width: 280, height: 190)
            HStack {
                Image(systemName: "mappin.and.ellipse")
                Text(PhotoLocation.text(coordinate)).monospacedDigit().textSelection(.enabled)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Ukryj mapę (M)")
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .frame(width: 280)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .onAppear { position = Self.camera(coordinate) }
        .onChange(of: coordinate.latitude + coordinate.longitude) { withAnimation { position = Self.camera(coordinate) } }
    }

    private static func camera(_ c: CLLocationCoordinate2D) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000))
    }
}
