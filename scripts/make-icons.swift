// Draws the app and extension icons. Run: swift scripts/make-icons.swift <output-folder>
//
// The Nidestream mark: a bold download arrow landing in ripples, on a light sky-blue tile.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// `inset` leaves the transparent margin macOS app icons use; extension icons fill the canvas.
func drawIcon(size: CGFloat, inset: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let margin = inset ? size * 0.098 : size * 0.02
    let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rect.width * 0.225
    let unit = rect.width / 100
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }

    // Tile: pale sky at the top deepening to light blue, with a soft shadow under the icon.
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if inset {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x0B4F8A, 0.30)
        shadow.shadowBlurRadius = size * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
        shadow.set()
        color(0xA9DCFF).setFill()
        tile.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    NSGradient(colors: [color(0xF2FBFF), color(0xCBEBFF), color(0x8ED0FF)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)

    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    // Glow behind the arrow.
    NSGradient(colors: [color(0xFFFFFF, 0.75), color(0xFFFFFF, 0)])!
        .draw(fromCenter: point(50, 58), radius: 0, toCenter: point(50, 58), radius: 46 * unit, options: [])
    // Ripples where the arrow lands.
    for (index, (width, height, alpha)) in [(70.0, 15.0, 0.16), (50.0, 10.0, 0.26), (30.0, 6.0, 0.4)].enumerated() {
        let ripple = NSBezierPath(ovalIn: NSRect(x: rect.minX + (50 - width / 2) * unit, y: rect.minY + (19 - height / 2) * unit,
                                                 width: width * unit, height: height * unit))
        ripple.lineWidth = max(1, unit * (index == 2 ? 2.4 : 2))
        color(0x1C7FD6, alpha).setStroke()
        ripple.stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // The arrow: a shaft with a rounded top and a head with rounded corners, sharing one gradient.
    let shaft = NSBezierPath(roundedRect: NSRect(x: rect.minX + 42.5 * unit, y: rect.minY + 46 * unit,
                                                 width: 15 * unit, height: 45.5 * unit),
                             xRadius: 7.5 * unit, yRadius: 7.5 * unit)
    let left = point(24, 52), right = point(76, 52), tip = point(50, 23)
    let corner = 3.2 * unit
    let head = NSBezierPath()
    head.move(to: NSPoint(x: (left.x + right.x) / 2, y: left.y))
    head.appendArc(from: right, to: tip, radius: corner)
    head.appendArc(from: tip, to: left, radius: corner * 1.3)
    head.appendArc(from: left, to: right, radius: corner)
    head.close()

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0B4F8A, 0.25)
    shadow.shadowBlurRadius = unit * 2
    shadow.shadowOffset = NSSize(width: 0, height: -unit * 0.8)
    shadow.set()
    color(0x1A73D9).setFill()
    shaft.fill()
    head.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [color(0x5DBBF8), color(0x2B93EC), color(0x1565C0)])!
    let span = NSRect(x: rect.minX + 24 * unit, y: rect.minY + 23 * unit, width: 52 * unit, height: 68.5 * unit)
    for part in [shaft, head] {
        NSGraphicsContext.current?.saveGraphicsState()
        part.addClip()
        gradient.draw(in: span, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // A thin highlight down the shaft.
    let highlight = NSBezierPath()
    highlight.move(to: point(53.6, 84))
    highlight.line(to: point(53.6, 62))
    highlight.lineWidth = max(0.5, unit * 1.1)
    highlight.lineCapStyle = .round
    color(0xFFFFFF, 0.55).setStroke()
    highlight.stroke()

    // Highlight along the top edge of the tile.
    if inset {
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: unit * 0.6, dy: unit * 0.6), xRadius: radius, yRadius: radius)
        edge.lineWidth = max(1, unit * 0.9)
        color(0xFFFFFF, 0.7).setStroke()
        edge.stroke()
    }

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
