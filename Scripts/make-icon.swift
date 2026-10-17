// Generates the ShadowDesk app icon: a macOS-style rounded square with a
// gradient and the "display" symbol, plus every size the .iconset needs.
//
//   swift Scripts/make-icon.swift /tmp/AppIcon.iconset
//   iconutil -c icns /tmp/AppIcon.iconset -o Scripts/AppIcon.icns

import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let master = 1024

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // macOS icons keep a margin so the rounded square does not touch the edge.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.27, blue: 0.74, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    NSShadow().set()
    NSColor.white.set()
    shape.lineWidth = size * 0.004
    shape.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The monitor glyph, tinted white.
    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.30, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return image }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let target = NSSize(width: symbol.size.width, height: symbol.size.height)
    let origin = NSPoint(
        x: rect.midX - target.width / 2,
        y: rect.midY - target.height / 2 - size * 0.005
    )
    tinted.draw(in: NSRect(origin: origin, size: target))
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    // An explicit bitmap keeps the pixel size exact (tiffRepresentation would
    // render at the display's backing scale).
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

let icon = drawIcon(size: CGFloat(master))
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try writePNG(icon, pixels: pixels, to: outputDirectory.appendingPathComponent("\(name).png"))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
