// Renders the app icon (1024×1024 PNG) for bundle.sh: the 团子 of the word
// mark (assets/theme-b/logo-dango.png: the design pack's body with its idle
// eyes) on a white rounded square, like the corner card, with the word
// mark's blue mark above it, looking up at it.
// Usage: icon <out.png> <logo-dango.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let dango = NSImage(contentsOfFile: args[2]) else {
    FileHandle.standardError.write("usage: icon OUT.png logo-dango.png\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// The plate: macOS's 824-point square on the 1024 grid, with its shadow.
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor.black.withAlphaComponent(0.06).setStroke()
plate.lineWidth = 3
plate.stroke()

// The 团子, 600 wide, a little below the middle (y up).
let w: CGFloat = 600, h = w * dango.size.height / dango.size.width
dango.draw(in: NSRect(x: 512 - w / 2, y: 1024 - 330 - h, width: w, height: h))

// The blue mark (AB.wordmark's "M3 3l4 3M2 8h5M3 13l4-3" on a 16 grid), up right.
let k: CGFloat = 150 / 16, ox: CGFloat = 700, oy: CGFloat = 1024 - 196
let p = NSBezierPath()
for (a, b) in [((3, 3), (7, 6)), ((2, 8), (7, 8)), ((3, 13), (7, 10))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
    p.move(to: NSPoint(x: ox + a.0 * k, y: oy - a.1 * k))
    p.line(to: NSPoint(x: ox + b.0 * k, y: oy - b.1 * k))
}
p.lineWidth = 2.6 * k
p.lineCapStyle = .round
NSColor(srgbRed: 0x2F / 255.0, green: 0x7B / 255.0, blue: 0xF5 / 255.0, alpha: 1).setStroke()
p.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[1]))
