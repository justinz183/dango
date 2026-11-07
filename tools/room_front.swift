// Cuts the office picture's foreground, the sofa's cushions and arms and
// the desk, into theme-b/room-front.png, drawn over the 团子 so they sit in
// the sofa and behind the desk (theme.swift `drawRoom`). The sofa's edge
// follows the cushions' and arms' dark top outline column by column, so a
// 团子 sinks into a rounded cushion instead of being cut flat; the desk's
// edge is its straight front. Ported from ~/dango-promo-video/clean_art.py.
//
//   swiftc -O tools/room_front.swift -o /tmp/room_front
//   /tmp/room_front apps/widget/assets/theme-b/room.png apps/widget/assets/theme-b/room-front.png

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]), let src = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("usage: room_front ROOM.png OUT.png\n".data(using: .utf8)!)
    exit(1)
}
let W = src.pixelsWide, H = src.pixelsHigh
// The app lays the room out 392 × 178 points.
let k = Double(W) / 392
func luma(_ x: Int, _ y: Int) -> Double {
    let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) * 255
}

// The sofa, up to where the desk starts: each column's top outline between
// the arms' tops and the old straight cut.
let x1 = Int(210 * k), rectTop = Int(130 * k), yLo = Int(108 * k), yHi = Int(146 * k)
var tops = [Int](repeating: rectTop, count: x1)
for x in 0..<x1 {
    if let d = (yLo..<yHi).first(where: { luma(x, $0) < 90 }) { tops[x] = d }
}
// A wide median drops the back cushions' thin seams; the seams between
// cushions dip deep, so never open more than the old cut did.
var smooth = tops
for i in 0..<x1 {
    let r = Int((5 * k).rounded())  // 5 points either side
    let w = tops[max(0, i - r)...min(x1 - 1, i + r)].sorted()
    smooth[i] = min(w[w.count / 2], rectTop + Int(2.5 * k))
}

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let bytes = out.bitmapData!
let deskX = Int(210 * k), deskY = Int(118 * k)
for y in 0..<H {
    for x in 0..<W {
        let front = x < x1 ? y >= smooth[x] : (x >= deskX && y >= deskY)
        let i = y * out.bytesPerRow + x * 4
        guard front else { bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0; continue }
        let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        bytes[i] = UInt8(c.redComponent * 255); bytes[i + 1] = UInt8(c.greenComponent * 255)
        bytes[i + 2] = UInt8(c.blueComponent * 255); bytes[i + 3] = 255
    }
}
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(W)×\(H), seat tops \(smooth.min()!)–\(smooth.max()!) px")
