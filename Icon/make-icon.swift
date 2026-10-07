// Draws the app icon (a clock) and writes Icon/AppIcon.icns.
// Usage: swift Icon/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Rounded-square background, inset per macOS icon grid.
    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSGradient(starting: NSColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.52, blue: 0.33, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s), angle: -90)

    // Clock face.
    let c = NSPoint(x: 512 * s, y: 512 * s), r = 300 * s
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()

    // Hour ticks.
    NSColor(white: 0.25, alpha: 1).setStroke()
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6
        let inner = i % 3 == 0 ? r * 0.78 : r * 0.85
        let p = NSBezierPath()
        p.lineWidth = (i % 3 == 0 ? 22 : 12) * s
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: c.x + inner * sin(a), y: c.y + inner * cos(a)))
        p.line(to: NSPoint(x: c.x + r * 0.92 * sin(a), y: c.y + r * 0.92 * cos(a)))
        p.stroke()
    }

    // Hands at 10:10.
    func hand(_ angle: CGFloat, _ length: CGFloat, _ width: CGFloat, _ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath()
        p.lineWidth = width * s
        p.lineCapStyle = .round
        p.move(to: c)
        p.line(to: NSPoint(x: c.x + length * sin(angle), y: c.y + length * cos(angle)))
        p.stroke()
    }
    hand(-60 * .pi / 180, r * 0.5, 34, NSColor(white: 0.15, alpha: 1))
    hand(60 * .pi / 180, r * 0.72, 24, NSColor(white: 0.15, alpha: 1))
    NSColor(red: 0.05, green: 0.52, blue: 0.33, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 26 * s, y: c.y - 26 * s, width: 52 * s, height: 52 * s)).fill()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "Icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
