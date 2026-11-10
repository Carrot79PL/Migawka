import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// View-only image corrections. The original file is never changed and nothing is saved.
final class ImageAdjustments: ObservableObject {
    struct Values: Hashable {
        var exposure: Double = 0        // EV, -3…3
        var gamma: Double = 1           // >1 lightens mid-tones, <1 darkens
        var brightness: Double = 0      // -0.5…0.5
        var contrast: Double = 1        // 0.5…2
        var shadows: Double = 0         // 0…1, lifts dark areas
        var highlights: Double = 1      // 0…1, lower recovers bright areas
        var saturation: Double = 1      // 0…2
        var temperature: Double = 6500  // K; lower = warmer picture, higher = cooler
        var sharpness: Double = 0       // 0…2
        var auto = false
        var grayscale = false
        var invert = false
        var quarterTurns = 0            // clockwise
        var flipped = false

        var isIdentity: Bool { self == Values() }
    }

    @Published var panelVisible = false
    @Published var values = Values()
    /// Keep the corrections when moving to another photo (rotation and flip are always per photo)
    @Published var keepForNextPhotos = true

    func reset() { values = Values() }

    func rotate(clockwise: Bool) {
        values.quarterTurns = (values.quarterTurns + (clockwise ? 1 : 3)) % 4
    }

    func photoChanged() {
        if keepForNextPhotos {
            values.quarterTurns = 0
            values.flipped = false
        } else {
            reset()
        }
    }

    // MARK: Rendering

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ source: CGImage, with v: Values) -> NSImage? {
        var image = CIImage(cgImage: source)

        if v.flipped || v.quarterTurns != 0 {
            var t = CGAffineTransform.identity
            if v.flipped { t = t.scaledBy(x: -1, y: 1) }
            t = t.concatenating(CGAffineTransform(rotationAngle: -CGFloat(v.quarterTurns) * .pi / 2))
            image = image.transformed(by: t)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if v.auto {
            for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let out = filter.outputImage { image = out }
            }
        }
        if v.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(v.exposure)
            image = f.outputImage ?? image
        }
        if v.gamma != 1 {
            let f = CIFilter.gammaAdjust()
            f.inputImage = image
            f.power = Float(1 / v.gamma)
            image = f.outputImage ?? image
        }
        if v.shadows != 0 || v.highlights != 1 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.shadowAmount = Float(v.shadows)
            f.highlightAmount = Float(v.highlights)
            image = f.outputImage ?? image
        }
        if v.brightness != 0 || v.contrast != 1 || v.saturation != 1 || v.grayscale {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(v.brightness)
            f.contrast = Float(v.contrast)
            f.saturation = v.grayscale ? 0 : Float(v.saturation)
            image = f.outputImage ?? image
        }
        if v.temperature != 6500 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: v.temperature, y: 0)
            image = f.outputImage ?? image
        }
        if v.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(v.sharpness)
            f.radius = 2
            image = f.outputImage ?? image
        }
        if v.invert {
            let f = CIFilter.colorInvert()
            f.inputImage = image
            image = f.outputImage ?? image
        }

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Some filters (blur in sharpen) grow the extent; crop back to the picture
        let rect = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: source.width, height: source.height) : image.extent
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

// MARK: - Panel

/// Adjustments as a floating card beside the photo, in the same style as the info panel and the capsules
struct AdjustmentsPanel: View {
    @ObservedObject var adjustments: ImageAdjustments
    let isVideo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Korekty").font(.headline)
                Spacer()
                Button { adjustments.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Resetuj wszystko")
                    .disabled(adjustments.values.isIdentity)
                Button { adjustments.panelVisible = false } label: { Image(systemName: "xmark") }
                    .help(String(localized: "Panel korekt obrazu (⌘E)"))
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 8)
            if isVideo {
                Text("Korekty działają tylko dla zdjęć.").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Światło") {
                            row(String(localized: "Ekspozycja"), \.exposure, -3...3, default: 0) { String(format: String(localized: "%+.1f EV"), $0) }
                            row(String(localized: "Gamma"), \.gamma, 0.25...4, default: 1, logarithmic: true) { String(format: String(localized: "%.2f"), $0) }
                            row(String(localized: "Jasność"), \.brightness, -0.5...0.5, default: 0) { String(format: String(localized: "%+.0f"), $0 * 200) }
                            row(String(localized: "Kontrast"), \.contrast, 0.5...2, default: 1) { String(format: String(localized: "%.0f%%"), $0 * 100) }
                            row(String(localized: "Rozjaśnij cienie"), \.shadows, 0...1, default: 0) { String(format: String(localized: "%.0f%%"), $0 * 100) }
                            row(String(localized: "Światła"), \.highlights, 0...1, default: 1) { String(format: String(localized: "%.0f%%"), $0 * 100) }
                        }
                        section("Kolor") {
                            row(String(localized: "Nasycenie"), \.saturation, 0...2, default: 1) { String(format: String(localized: "%.0f%%"), $0 * 100) }
                            row(String(localized: "Temperatura"), \.temperature, 3000...12000, default: 6500) { String(format: String(localized: "%.0f K"), $0) }
                            toggle("Skala szarości", $adjustments.values.grayscale)
                            toggle("Negatyw", $adjustments.values.invert)
                        }
                        section("Szczegóły") {
                            row(String(localized: "Wyostrzenie"), \.sharpness, 0...2, default: 0) { String(format: "%.0f%%", $0 * 50) }
                            toggle("Automatyczna korekta", $adjustments.values.auto)
                        }
                        section("Orientacja") {
                            HStack(spacing: 16) {
                                Button { adjustments.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                                    .help("Obróć w lewo (⌘L)")
                                Button { adjustments.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                                    .help("Obróć w prawo (⌘R)")
                                Button { adjustments.values.flipped.toggle() } label: {
                                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                }
                                .help("Odbij poziomo (⇧⌘H)")
                            }
                            .buttonStyle(.borderless)
                            .imageScale(.large)
                        }
                        Divider()
                        toggle("Zachowaj korekty dla kolejnych zdjęć", $adjustments.keepForNextPhotos)
                        Text("Korekty zmieniają tylko podgląd. Plik nie jest modyfikowany ani zapisywany.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.callout) }
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private func row(_ title: String, _ key: WritableKeyPath<ImageAdjustments.Values, Double>,
                     _ range: ClosedRange<Double>, default def: Double, logarithmic: Bool = false,
                     format: @escaping (Double) -> String) -> some View {
        let value = $adjustments.values[dynamicMember: key]
        // Gamma is multiplicative, so a log scale puts 1.0 in the middle of the slider
        let slider = logarithmic
            ? Binding(get: { log(value.wrappedValue) }, set: { value.wrappedValue = exp($0) })
            : value
        let sliderRange = logarithmic ? log(range.lowerBound)...log(range.upperBound) : range
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value.wrappedValue)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button { value.wrappedValue = def } label: { Image(systemName: "arrow.counterclockwise").font(.caption) }
                    .buttonStyle(.borderless)
                    .help("Przywróć domyślne")
                    .opacity(value.wrappedValue == def ? 0 : 1)
            }
            ThinSlider(value: slider, range: sliderRange) { _ in }
        }
    }
}

// MARK: - Menu

struct ImageCommands: Commands {
    @ObservedObject var adjustments: ImageAdjustments
    @ObservedObject var gallery: Gallery
    /// Portrait photos and films turned a quarter to fill a landscape screen: 0 no, -1 left, 1 right
    @AppStorage("portraitTurns") private var portraitTurns = 0

    /// A photo turns through its corrections; a film is turned by the large view
    private func rotate(clockwise: Bool) {
        if let index = gallery.selected, gallery.visible.indices.contains(index), gallery.visible[index].isVideo {
            NotificationCenter.default.post(name: .viewerRotate, object: nil, userInfo: ["clockwise": clockwise])
        } else {
            adjustments.rotate(clockwise: clockwise)
        }
    }

    var body: some Commands {
        CommandMenu("Obraz") {
            Toggle("Panel korekt obrazu", isOn: $adjustments.panelVisible)
                .keyboardShortcut("e")
            Divider()
            Group {
                Button("Obróć w lewo") { rotate(clockwise: false) }
                    .keyboardShortcut("l")
                Button("Obróć w prawo") { rotate(clockwise: true) }
                    .keyboardShortcut("r")
                Picker("Pionowe zdjęcia i filmy", selection: $portraitTurns) {
                    Text("Bez obracania").tag(0)
                    Text("Obracaj w lewo, by wypełniały ekran").tag(-1)
                    Text("Obracaj w prawo, by wypełniały ekran").tag(1)
                }
                Button("Odbij poziomo") { adjustments.values.flipped.toggle() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Toggle("Automatyczna korekta", isOn: $adjustments.values.auto)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Toggle("Skala szarości", isOn: $adjustments.values.grayscale)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Toggle("Negatyw", isOn: $adjustments.values.invert)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Resetuj korekty") { adjustments.reset() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(adjustments.values.isIdentity)
            }
            .disabled(gallery.selected == nil)
            Divider()
            Menu("Edytuj w programie") {
                EditInMenuItems(photo: gallery.selected.flatMap { gallery.visible.indices.contains($0) ? gallery.visible[$0] : nil },
                                gallery: gallery)
            }
            .disabled(gallery.selected == nil)
        }
    }
}
