// Cuts the 团子 parts out of the designer's v2 pack (DONGO_Developer_Pack_v2:
// transparent atlases plus data/manifest.json) into apps/widget/assets/dango:
// the body B01, the eyes E01–E12, the accessories P01–P12, and dango.json
// with where each role's eyes and accessory go in the pack's 512 × 512
// layout. The app puts them together itself (theme.swift `drawPackDango`).
//
//   swiftc -O tools/dango_pack.swift -o /tmp/dango_pack
//   /tmp/dango_pack ~/Downloads/DONGO_Developer_Pack_v2 apps/widget/assets/dango

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: dango_pack PACK_DIR OUT_DIR\n".data(using: .utf8)!)
    exit(1)
}
let pack = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: pack.appendingPathComponent("data/manifest.json"))) as! [String: Any]
let atlases = manifest["atlases"] as! [String: [String: Any]]
let frames = manifest["frames"] as! [String: [String: Any]]
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var images: [String: CGImage] = [:]
func atlas(_ name: String) -> CGImage {
    if let i = images[name] { return i }
    let file = atlases[name]!["file"] as! String
    let i = NSBitmapImageRep(data: try! Data(contentsOf: pack.appendingPathComponent(file)))!.cgImage!
    images[name] = i
    return i
}

// The hats and headphones are redrawn as worn on this body
// (apps/widget/assets/dango-src/worn); tools/fit_roles.py cuts them into
// the output folder, so they are not cut from the atlas here.
let worn: Set<String> = ["P03", "P05", "P06", "P07", "P12"]

let ids = ["B01"] + (1...12).map { String(format: "E%02d", $0) } + (1...12).map { String(format: "P%02d", $0) }
for id in ids {
    let f = frames[id]!
    let r = (f["rect"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
    if worn.contains(id) { continue }
    let crop = atlas(f["atlas"] as! String).cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))!
    let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!
    try png.write(to: out.appendingPathComponent(id + ".png"))
}

// Measured from the parts, as fractions of each image (0–1, top-left
// origin): each eye set's left and right eye (split at the emptiest column
// near the middle), and the see-through holes an accessory frames (the
// glasses' lenses: clear pixels the clear outside cannot reach). With
// holes, the app sets one eye in each, centred, instead of the pair as one.
func alphaGrid(_ id: String) -> (w: Int, h: Int, a: [Bool]) {
    let r = NSBitmapImageRep(data: try! Data(contentsOf: out.appendingPathComponent(id + ".png")))!
    let w = r.pixelsWide, h = r.pixelsHigh
    var a = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w { a[y * w + x] = r.colorAt(x: x, y: y)!.alphaComponent > 0.5 } }
    return (w, h, a)
}
func frac(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ w: Int, _ h: Int) -> [Double] {
    [Double(x0) / Double(w), Double(y0) / Double(h), Double(x1 - x0 + 1) / Double(w), Double(y1 - y0 + 1) / Double(h)].map { ($0 * 10000).rounded() / 10000 }
}
var eyeParts: [String: [[Double]]] = [:]
for e in (1...12).map({ String(format: "E%02d", $0) }) {
    let (w, h, a) = alphaGrid(e)
    let cols = (0..<w).map { x in (0..<h).filter { a[$0 * w + x] }.count }
    let split = (w * 3 / 10..<w * 7 / 10).min { cols[$0] < cols[$1] }!
    var parts: [[Double]] = []
    for (lo, hi) in [(0, split), (split + 1, w)] {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in lo..<hi where a[y * w + x] { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        parts.append(frac(x0, y0, x1, y1, w, h))
    }
    eyeParts[e] = parts
}
var holes: [String: [[Double]]] = [:]
for p in (1...12).map({ String(format: "P%02d", $0) }) {
    let (w, h, a) = alphaGrid(p)
    var outside = [Bool](repeating: false, count: w * h)
    var stack = (0..<w).flatMap { [$0, (h - 1) * w + $0] } + (0..<h).flatMap { [$0 * w, $0 * w + w - 1] }
    while let i = stack.popLast() {
        if outside[i] || a[i] { continue }
        outside[i] = true
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
    }
    // The enclosed clear regions, biggest first; a hole is 2% of the image or more.
    var seen = [Bool](repeating: false, count: w * h)
    var found: [(Int, [Double])] = []
    for start in 0..<(w * h) where !a[start] && !outside[start] && !seen[start] {
        var q = [start], n = 0, x0 = w, y0 = h, x1 = -1, y1 = -1
        seen[start] = true
        while let i = q.popLast() {
            n += 1
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 && !a[j] && !outside[j] && !seen[j] {
                seen[j] = true
                q.append(j)
            }
        }
        if n * 50 >= w * h { found.append((n, frac(x0, y0, x1, y1, w, h))) }
    }
    if found.count >= 2 { holes[p] = found.sorted { $0.0 > $1.0 }.prefix(2).map { $0.1 }.sorted { $0[0] < $1[0] } }
}

// Where things go, measured off the designer's role sheet (reference/
// original_design_pack/02_roles/12_roles.png) by tools/fit_roles.py: the
// sheet's bodies are rounder than B01 (the app draws B01 that much taller),
// its hats rest on the eyes' top and its headphones' band on the head, and
// the manifest's own rects don't do that (user, 2026-11-07: 「团子的耳机和帽子
// 都是不符合逻辑的」). Rerun fit_roles.py after changing the parts and paste.
let measuredBody: [CGFloat] = [80.0, 131.7, 352.0, 268.3]
let measuredPlainEyes: [CGFloat] = [152.3, 210.8, 233.7, 136.6]
let measured: [String: [String: [CGFloat]]] = [
    "R01": ["eyeRect": [174.9, 217.9, 232.8, 136.1], "accessoryRect": [43.7, -49.0, 444.7, 333.5]],
    "R02": ["eyeRect": [150.3, 211.7, 232.6, 136.0], "accessoryRect": [306.7, 151.8, 89.2, 69.2]],
    "R03": ["eyeRect": [137.0, 212.2, 235.1, 137.4], "accessoryRect": [46.2, 99.8, 417.1, 254.9]],
    "R04": ["eyeRect": [164.6, 209.6, 234.1, 136.8], "accessoryRect": [91.1, 196.3, 319.6, 165.4]],
    "R05": ["eyeRect": [172.0, 216.6, 229.6, 134.2], "accessoryRect": [65.8, 122.0, 288.8, 161.6]],
    "R06": ["eyeRect": [173.9, 225.5, 229.8, 134.3], "accessoryRect": [101.5, 100.6, 309.0, 150.1]],
    "R07": ["eyeRect": [153.7, 221.0, 234.1, 136.8], "accessoryRect": [71.5, 101.0, 337.0, 157.0]],
    "R08": ["eyeRect": [154.3, 210.0, 234.7, 137.2], "accessoryRect": [208.3, 335.6, 110.5, 61.7]],
    "R09": ["eyeRect": [159.8, 219.7, 231.8, 135.5], "accessoryRect": [187.6, 100.7, 164.2, 90.9]],
    "R10": ["eyeRect": [151.0, 218.9, 212.0, 138.6], "accessoryRect": [49.0, 69.1, 414.0, 316.4]],
    "R11": ["eyeRect": [144.5, 199.2, 253.7, 148.2], "accessoryRect": [330.0, 113.2, 95.9, 119.8]],
    "R12": ["eyeRect": [165.3, 233.1, 226.8, 132.6], "accessoryRect": [95.6, 175.0, 320.8, 71.9]],
    "R13": ["eyeRect": [152.3, 160.2, 233.7, 136.6], "accessoryRect": [74.1, 250.3, 363.8, 137.7]],
    "R14": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [58.9, 104.7, 394.2, 244.3]],
    "R15": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [92.0, 86.5, 332.0, 171.4]],
    "R16": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [85.0, 21.8, 342.0, 225.2]],
    "R17": ["eyeRect": [152.3, 169.4, 233.7, 136.6], "accessoryRect": [82.0, 277.3, 348.0, 152.7]],
    "R18": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [168.0, 39.8, 176.0, 114.9]],
    "R19": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [105.5, 86.9, 301.0, 157.9]],
    "R20": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [128.2, 158.8, 257.8, 64.1]],
    "R21": ["eyeRect": [152.3, 210.8, 233.7, 136.6], "accessoryRect": [131.1, 154.5, 252.4, 66.4]],
]
var roles: [String: Any] = [:]
for r in manifest["roles"] as! [[String: Any]] {
    let id = r["id"] as! String
    roles[id] = ["accessory": r["accessory"]!, "name": r["name"]!, "eyeRect": measured[id]!["eyeRect"]!, "accessoryRect": measured[id]!["accessoryRect"]!]
}
// Roles the pack doesn't have (user, 2026-11-07: 「可以把他们的装饰都放到他们的
// 团子上吗」), drawn worn like the hats; their parts P13–P21 come from
// tools/fit_roles.py (`EXTRA`).
let extraRoles = ["R13": "医生", "R14": "律师", "R15": "建筑师", "R16": "厨师", "R17": "心理咨询师",
                  "R18": "金融分析师", "R19": "前端工程师", "R20": "资料录入", "R21": "科学家"]
for (id, name) in extraRoles {
    guard let m = measured[id] else { continue }
    roles[id] = ["accessory": "P" + id.dropFirst(), "name": name, "eyeRect": m["eyeRect"]!, "accessoryRect": m["accessoryRect"]!]
}
let layout: [String: Any] = [
    "source": "DONGO_Developer_Pack_v2 data/manifest.json (2026-10-30)",
    "canvas": [512, 512],
    "bodyRect": measuredBody,
    "defaultEyeRect": measuredPlainEyes,
    "roles": roles,
    "eyeParts": eyeParts,
    "accessoryHoles": holes,
]
try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("dango.json"))
print("wrote \(ids.count - worn.count) parts and dango.json to \(out.path) (the \(worn.count) worn ones come from tools/fit_roles.py)")
