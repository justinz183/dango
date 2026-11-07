// The build's check on the 团子 art (bundle.sh runs it; any failure stops
// the build). For every part in assets/dango (dango.json says where each
// goes) and for theme-b/logo-dango.png:
//   - it has real transparency;
//   - its outer edge is not light (art matted off a light ground keeps a
//     light rim; the old cut-outs had ~65% light edge pixels);
//   - it has at least 3 pixels per point where it is drawn biggest: a whole
//     团子 fitted into 120 × 96 points (the day share image's crew panel).
//
//   swiftc -O tools/check_art.swift -o /tmp/check_art && /tmp/check_art apps/widget/assets

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "apps/widget/assets")
let dir = root.appendingPathComponent("dango")
let maxBox = NSSize(width: 120, height: 96)
let lightEdgeMax = 0.30
var failures: [String] = []

func rep(_ url: URL) -> NSBitmapImageRep? { (try? Data(contentsOf: url)).flatMap(NSBitmapImageRep.init(data:)) }

/// Transparency and the share of light pixels along the outer edge.
func edge(_ r: NSBitmapImageRep) -> (alpha: Bool, light: Double) {
    let w = r.pixelsWide, h = r.pixelsHigh
    var a = [UInt8](repeating: 0, count: w * h), l = [Double](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let c = r.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            a[y * w + x] = UInt8(c.alphaComponent * 255)
            l[y * w + x] = (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) * 255
        }
    }
    guard r.hasAlpha, a.contains(where: { $0 < 8 }) else { return (false, 0) }
    // The edge: every visible pixel next to a clear one. A matte rim is
    // light there (the old cut-outs: 99–100%; the pack's parts: ≤ 15%).
    var edge = 0, light = 0
    for y in 0..<h {
        for x in 0..<w where a[y * w + x] >= 8 {
            let out = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { d in
                let nx = x + d.0, ny = y + d.1
                return nx < 0 || ny < 0 || nx >= w || ny >= h || a[ny * w + nx] < 8
            }
            if out {
                edge += 1
                if l[y * w + x] > 160 { light += 1 }
            }
        }
    }
    return (true, edge == 0 ? 0 : Double(light) / Double(edge))
}

func check(_ name: String, _ r: NSBitmapImageRep, needWidth: Double?) {
    let e = edge(r)
    if !e.alpha { failures.append("\(name): no transparency") }
    if e.light > lightEdgeMax { failures.append("\(name): \(Int(e.light * 100))% of its edge is light (a matte rim)") }
    if let need = needWidth, Double(r.pixelsWide) < need.rounded(.up) {
        failures.append("\(name): \(r.pixelsWide) px wide, needs \(Int(need.rounded(.up))) (3× its biggest size)")
    }
}

guard let d = try? Data(contentsOf: dir.appendingPathComponent("dango.json")),
      let layout = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
    print("check_art: no \(dir.path)/dango.json"); exit(1)
}
func rect(_ a: Any?) -> NSRect? {
    guard let v = a as? [NSNumber], v.count == 4 else { return nil }
    return NSRect(x: v[0].doubleValue, y: v[1].doubleValue, width: v[2].doubleValue, height: v[3].doubleValue)
}
let body = rect(layout["bodyRect"])!
let roles = layout["roles"] as? [String: [String: Any]] ?? [:]
// The biggest points-per-unit each part is drawn at, over every role.
var scale: [String: Double] = [:]
func use(_ id: String, _ r: NSRect, _ extent: NSRect) {
    let k = min(maxBox.width / extent.width, maxBox.height / extent.height)
    scale[id] = max(scale[id] ?? 0, 3 * Double(r.width * k))
}
let eyes = (1...12).map { String(format: "E%02d", $0) }
let plainEyes = rect(layout["defaultEyeRect"])!
use("B01", body, body)
for e in eyes { use(e, plainEyes, body) }
for (_, r) in roles {
    guard let acc = r["accessory"] as? String, let ar = rect(r["accessoryRect"]), let er = rect(r["eyeRect"]) else { continue }
    let extent = body.union(ar)
    use("B01", body, extent)
    use(acc, ar, extent)
    for e in eyes { use(e, er, extent) }
}
// The dark theme's white body is drawn wherever the black one is.
scale["B01W"] = scale["B01"]
for (id, need) in scale.sorted(by: { $0.key < $1.key }) {
    guard let r = rep(dir.appendingPathComponent(id + ".png")) else { failures.append("\(id).png: missing"); continue }
    check(id + ".png", r, needWidth: need)
}
if let r = rep(root.appendingPathComponent("theme-b/logo-dango.png")) { check("logo-dango.png", r, needWidth: nil) }

if failures.isEmpty {
    print("check_art: \(scale.count) parts and the logo pass (transparent, no light rim, ≥ 3× their biggest size)")
} else {
    failures.forEach { print("check_art: " + $0) }
    exit(1)
}
