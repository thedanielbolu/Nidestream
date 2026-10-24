// Draws the app and extension icons. Run: swift scripts/make-icons.swift <output-folder>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// `inset` leaves the transparent margin macOS app icons use; extension icons fill the canvas.
func drawIcon(size: CGFloat, inset: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let margin = inset ? size * 0.098 : size * 0.02
    let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rect.width * 0.225

    if inset {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = size * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        shadow.set()
    }
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.56, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.29, green: 0.25, blue: 0.86, alpha: 1)])!.draw(in: tile, angle: -90)
    NSShadow().set()

    // Soft highlight at the top.
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Speed lines on the left, arrow in the middle, tray at the bottom.
    NSColor.white.setFill()
    let unit = rect.width / 100
    for (index, length) in [CGFloat(11), 17, 11].enumerated() {
        let y = rect.minY + unit * (56 - CGFloat(index) * 9)
        NSBezierPath(roundedRect: NSRect(x: rect.minX + unit * 12, y: y, width: unit * length, height: unit * 4.2),
                     xRadius: unit * 2.1, yRadius: unit * 2.1).fill()
    }
    let arrow = NSBezierPath()
    let cx = rect.minX + unit * 57
    arrow.move(to: NSPoint(x: cx - unit * 9, y: rect.minY + unit * 80))
    arrow.line(to: NSPoint(x: cx + unit * 9, y: rect.minY + unit * 80))
    arrow.line(to: NSPoint(x: cx + unit * 9, y: rect.minY + unit * 50))
    arrow.line(to: NSPoint(x: cx + unit * 22, y: rect.minY + unit * 50))
    arrow.line(to: NSPoint(x: cx, y: rect.minY + unit * 27))
    arrow.line(to: NSPoint(x: cx - unit * 22, y: rect.minY + unit * 50))
    arrow.line(to: NSPoint(x: cx - unit * 9, y: rect.minY + unit * 50))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.fill()
    NSBezierPath(roundedRect: NSRect(x: cx - unit * 27, y: rect.minY + unit * 16, width: unit * 54, height: unit * 6),
                 xRadius: unit * 3, yRadius: unit * 3).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String, in folder: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(drawIcon(size: CGFloat(base), inset: true), "icon_\(base)x\(base).png", in: iconset)
    save(drawIcon(size: CGFloat(base * 2), inset: true), "icon_\(base)x\(base)@2x.png", in: iconset)
}
let extensionIcons = output.appendingPathComponent("extension")
try? FileManager.default.createDirectory(at: extensionIcons, withIntermediateDirectories: true)
for size in [16, 32, 48, 128] {
    save(drawIcon(size: CGFloat(size), inset: false), "icon\(size).png", in: extensionIcons)
}
print("Icons written to \(output.path)")
