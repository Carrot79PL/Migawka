// Rysuje ikonę aplikacji (1024×1024 PNG): zdjęcie z górami i słońcem na ciemnym tle oraz kłódka,
// bo Migawka chroni dane. Użycie: swift make_icon.swift wyjscie.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the shape sits inside a 824 pt square with a soft shadow below
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo to violet
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.15, green: 0.13, blue: 0.36, alpha: 1).cgColor,
        NSColor(red: 0.33, green: 0.29, blue: 0.72, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // The photo: a white-framed print, slightly tilted
    ctx.translateBy(x: 512, y: 520)
    ctx.rotate(by: -0.08)
    let frame = CGRect(x: -300, y: -230, width: 600, height: 460)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)

    // Picture inside the frame: sky, sun, two mountains
    let picture = frame.insetBy(dx: 34, dy: 34)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: picture, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 1.0, green: 0.73, blue: 0.45, alpha: 1).cgColor,
        NSColor(red: 0.42, green: 0.70, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: picture.minY), end: CGPoint(x: 0, y: picture.maxY), options: [])
    ctx.setFillColor(NSColor(red: 1.0, green: 0.93, blue: 0.55, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: 95, y: 40, width: 120, height: 120))
    func mountain(_ points: [CGPoint], _ color: NSColor) {
        ctx.beginPath()
        ctx.move(to: points[0])
        points.dropFirst().forEach { ctx.addLine(to: $0) }
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
    mountain([CGPoint(x: -280, y: -200), CGPoint(x: -90, y: 70), CGPoint(x: 120, y: -200)],
             NSColor(red: 0.20, green: 0.45, blue: 0.40, alpha: 1))
    mountain([CGPoint(x: -60, y: -200), CGPoint(x: 120, y: 20), CGPoint(x: 290, y: -200)],
             NSColor(red: 0.10, green: 0.33, blue: 0.30, alpha: 1))
    ctx.restoreGState()
    ctx.restoreGState()

    // Lock badge, bottom right: the data stays protected
    let badge = CGRect(x: 620, y: 150, width: 250, height: 250)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.setFillColor(NSColor(red: 0.11, green: 0.62, blue: 0.46, alpha: 1).cgColor)
    ctx.fillEllipse(in: badge)
    ctx.restoreGState()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: badge.midX, y: badge.midY + 18), radius: 46, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: badge.midX - 72, y: badge.midY - 78, width: 144, height: 104),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor(red: 0.11, green: 0.62, blue: 0.46, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: badge.midX - 15, y: badge.midY - 40, width: 30, height: 30))
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
