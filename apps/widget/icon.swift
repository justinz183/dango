// Renders the app icon (1024×1024 PNG) for bundle.sh: three 团子 on a
// bamboo skewer, sakura, plain and matcha, on a dark rounded square.
// Usage: icon <out.png>

import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSRect(x: 102, y: 102, width: 820, height: 820)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.19, alpha: 1),
           ending: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))?
    .draw(in: NSBezierPath(roundedRect: bg, xRadius: 184, yRadius: 184), angle: -90)

// The skewer, behind the dango.
let stick = NSBezierPath(roundedRect: NSRect(x: 497, y: 150, width: 30, height: 740), xRadius: 15, yRadius: 15)
NSColor(calibratedRed: 0.80, green: 0.64, blue: 0.40, alpha: 1).setFill()
stick.fill()

let r: CGFloat = 132
let balls: [(CGFloat, NSColor)] = [
    (676, NSColor(calibratedRed: 0.97, green: 0.73, blue: 0.78, alpha: 1)),
    (482, NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)),
    (288, NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.47, alpha: 1)),
]
let bead = NSColor(calibratedWhite: 0.08, alpha: 1)
for (k, (cy, body)) in balls.enumerated() {
    let c = NSPoint(x: 512, y: cy)
    let shade = body.blended(withFraction: 0.32, of: .black) ?? body
    shade.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r - 7, y: c.y - r - 7, width: 2 * r + 14, height: 2 * r + 14)).fill()
    body.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    NSColor.white.withAlphaComponent(0.5).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.62, y: c.y + r * 0.42, width: r * 0.5, height: r * 0.26)).fill()
    // Cheeks, bead eyes with a glint, a small smile (the top one grins).
    NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.55, alpha: 0.5).setFill()
    for dx: CGFloat in [-0.62, 0.38] { NSBezierPath(ovalIn: NSRect(x: c.x + dx * r, y: c.y - r * 0.3, width: r * 0.26, height: r * 0.15)).fill() }
    for dx: CGFloat in [-0.36, 0.2] {
        bead.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x + dx * r, y: c.y - r * 0.02, width: r * 0.17, height: r * 0.24)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x + dx * r + r * 0.08, y: c.y + r * 0.12, width: r * 0.06, height: r * 0.07)).fill()
    }
    bead.setStroke()
    let m = NSBezierPath()
    m.lineWidth = 9
    m.lineCapStyle = .round
    m.move(to: NSPoint(x: c.x - r * 0.12, y: c.y - r * 0.16))
    m.curve(to: NSPoint(x: c.x + r * 0.12, y: c.y - r * 0.16),
            controlPoint1: NSPoint(x: c.x - r * 0.06, y: c.y - r * (k == 0 ? 0.36 : 0.26)), controlPoint2: NSPoint(x: c.x + r * 0.06, y: c.y - r * (k == 0 ? 0.36 : 0.26)))
    m.stroke()
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
