// Renders the app icon (1024×1024 PNG) for bundle.sh: a dark rounded
// square with a gold medal and a dollar sign. Usage: icon <out.png>

import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let bg = NSRect(x: 102, y: 102, width: 820, height: 820)
NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: bg, xRadius: 184, yRadius: 184).fill()
let medal = NSRect(x: 272, y: 272, width: 480, height: 480)
NSColor(calibratedRed: 0.83, green: 0.69, blue: 0.22, alpha: 1).setFill()
NSBezierPath(ovalIn: medal).fill()
NSColor.black.withAlphaComponent(0.18).setStroke()
let ring = NSBezierPath(ovalIn: medal.insetBy(dx: 8, dy: 8))
ring.lineWidth = 16
ring.stroke()
let glyph = NSAttributedString(string: "$", attributes: [
    .font: NSFont.systemFont(ofSize: 330, weight: .bold),
    .foregroundColor: NSColor.black.withAlphaComponent(0.75),
])
let gs = glyph.size()
glyph.draw(at: NSPoint(x: medal.midX - gs.width / 2, y: medal.midY - gs.height / 2 + 6))
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
