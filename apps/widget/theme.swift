// The panel and the corner card from the 2026-10-30 UI handoff
// (dango-ui-handoff, README and tokens.json there): a white panel with the
// illustrated office on top — the design's room picture and role cut-outs,
// with the eyes drawn over them for each state; a job without a cut-out is
// drawn as the vector 团子 from the design's SVG. (The classic theme went
// on 2026-11-06, the vector office on 2026-11-07.)

import AppKit

// MARK: - Tokens (tokens.json; text greys at the accessible #6E6E73)

/// Light or dark, and the time of day in the office.
enum Appearance {
    /// Snapshots: --dark / --light, --hour H.
    static var forced: Bool?
    static var hour: Double?
    /// UserDefaults "appearance": "system" (the default), "light" or "dark".
    static var choice: String { UserDefaults.standard.string(forKey: "appearance") ?? "system" }
    static var dark: Bool {
        if let forced { return forced }
        switch choice {
        case "dark": return true
        case "light": return false
        default: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    /// Draws the panel, the office or the pet in the theme's colours.
    static func drawing(_ body: () -> Void) {
        let was = V3.dark
        V3.dark = dark
        body()
        V3.dark = was
    }
    /// The office's sky by the Mac's clock, in both themes (user, 2026-11-07:
    /// 「办公室应该随着系统时间发生变化」): how much of the sunset picture and
    /// of the night picture go over the day's. Day 7:00–17:00; the sun sets
    /// 17:00–18:00; night falls 18:30–19:30; dawn 5:00–6:00, sunrise 6:00–7:00.
    static func sky(_ date: Date = Date()) -> (dusk: CGFloat, night: CGFloat) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = hour ?? Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        switch h {
        case 7..<17: return (0, 0)
        case 17..<18: return (CGFloat(h - 17), 0)
        case 18..<18.5: return (1, 0)
        case 18.5..<19.5: return (1, CGFloat(h - 18.5))
        case 5..<6: return (1, CGFloat(6 - h))
        case 6..<7: return (CGFloat(7 - h), 0)
        default: return (1, 1)
        }
    }
}

enum V3 {
    /// The dark theme (user, 2026-11-07: 「dark的theme是白团子」): on only
    /// while the panel, the office and the corner pet draw (`Appearance.drawing`),
    /// so the share images, the boss card and the report window stay light
    /// with black 团子 wherever they are drawn.
    static var dark = false
    private static func pick(_ light: String, _ night: String) -> NSColor { color(hex: dark ? night : light) }
    static var ink: NSColor { pick("#1C1C1C", "#F2F2F7") }
    static var surface: NSColor { dark ? color(hex: "#1C1C1E") : NSColor.white }
    static var tile: NSColor { pick("#F6F6F6", "#2C2C2E") }
    static var control: NSColor { pick("#F4F4F4", "#2C2C2E") }
    static var line: NSColor { pick("#E6E6E8", "#3A3A3C") }
    static var secondary: NSColor { pick("#6E6E73", "#A1A1A6") }
    static var bar: NSColor { pick("#DADADA", "#48484A") }
    static var barZero: NSColor { pick("#EDEDED", "#2C2C2E") }
    static var today: NSColor { pick("#16A34A", "#30D158") }
    static var track: NSColor { pick("#E9E9E9", "#3A3A3C") }
    static var brand: NSColor { pick("#2F7BF5", "#4F8DFF") }
    static var workingText: NSColor { pick("#15803D", "#30D158") }
    static var waitingText: NSColor { pick("#B45309", "#FFB340") }
    /// What sits on an ink-filled shape (a busy staff card, the share button).
    static var onInk: NSColor { dark ? color(hex: "#1C1C1E") : NSColor.white }
    /// A raised card or the chosen segment: white by day.
    static var raised: NSColor { dark ? color(hex: "#3A3A3C") : NSColor.white }
    static let body = color(hex: "#1E1E1E")
    static let outline = color(hex: "#111111")

    static func dot(_ status: String) -> NSColor {
        switch status {
        case "working", "happy": return color(hex: "#16A34A")
        case "waiting": return color(hex: "#D97706")
        case "fuming": return color(hex: "#DC2626")
        case "off": return color(hex: "#E6E6E8")
        default: return color(hex: "#B5B5BA")
        }
    }

    /// SF Mono (the design's JetBrains Mono falls back to it).
    static func mono(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ c: NSColor = ink) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: monoFont(size, weight), .foregroundColor: c])
    }

    /// SF Mono at each size and weight, made once and kept. On macOS 27.0.1
    /// CoreText aborts at random when fresh monospaced system fonts of mixed
    /// weights are typeset over and over, as the pet's card does 24 times a
    /// second; kept fonts never did in 1.8 million tries.
    private static var monoFonts: [String: NSFont] = [:]
    static func monoFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let key = "\(size) \(weight.rawValue)"
        if let f = monoFonts[key] { return f }
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        monoFonts[key] = f
        return f
    }

    static func sans(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ c: NSColor = ink) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c])
    }
}

/// What a status is called on the roster and the card.
func statusName(_ s: String) -> String {
    switch s {
    case "working": return L("在干", "working")
    case "happy": return L("开心", "happy")
    case "fuming": return L("冒烟", "fuming")
    case "waiting": return L("等你批准", "needs you")
    case "sleeping": return L("睡了", "asleep")
    case "off": return L("下班", "off")
    default: return L("摸鱼", "slacking")
    }
}

/// A job's state in the v3 office and roster (README 办公室的状态). The
/// daemon does not report waiting or fuming yet, so from data come only:
/// working; happy (the job just done, the character happy, within 30
/// minutes); idle; sleeping (nothing for an hour); off (nothing today).
func officeStatus(_ o: Occupant, _ m: Model?, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
    // The daemon's event-driven states; happy wears off after half an hour.
    if let s = o.status, s != "happy" || o.statusSince == 0 || now - o.statusSince < 30 * 60_000 { return s }
    if o.working { return "working" }
    guard o.since > 0, Calendar.current.isDateInToday(Date(timeIntervalSince1970: o.since / 1000)) else { return "off" }
    let quiet = (now - o.since) / 60_000
    if let m, m.job?.id == o.job.id, ["happy", "proud"].contains(m.mood), quiet < 30 { return "happy" }
    return quiet > 60 ? "sleeping" : "idle"
}

/// A blink: eyes shut for 0.12 s every 4.3 s, offset per character, in the
/// states whose eyes are open.
func blinking(_ status: String, _ t: Double) -> Bool {
    ["working", "idle", "waiting", "fuming", "off"].contains(status) && (t.truncatingRemainder(dividingBy: 4.3) + 4.3).truncatingRemainder(dividingBy: 4.3) < 0.12
}

// MARK: - SVG paths

/// The design's path data as a bezier path: M L H V C Q Z, absolute and
/// relative (enough for the 团子 and the room).
func svgPath(_ d: String) -> NSBezierPath {
    let p = NSBezierPath()
    var tokens: [String] = []
    var cur = ""
    for ch in d {
        if ch.isLetter {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
            tokens.append(String(ch))
        } else if ch == "-" {
            if !cur.isEmpty && !cur.hasSuffix("e") { tokens.append(cur); cur = "" }
            cur.append(ch)
        } else if ch == " " || ch == "," {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
        } else if ch == "." && cur.contains(".") {
            tokens.append(cur)
            cur = "."
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty { tokens.append(cur) }
    var i = 0
    var cmd: Character = "M"
    var pt = NSPoint.zero, start = NSPoint.zero
    func num() -> CGFloat {
        defer { i += 1 }
        return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0
    }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter {
            cmd = c
            i += 1
            if c == "Z" || c == "z" {
                p.close()
                pt = start
                continue
            }
        }
        let rel = cmd.isLowercase
        let o = rel ? pt : .zero
        switch cmd {
        case "M", "m":
            pt = NSPoint(x: o.x + num(), y: o.y + num())
            p.move(to: pt)
            start = pt
            cmd = rel ? "l" : "L"
        case "L", "l":
            pt = NSPoint(x: o.x + num(), y: o.y + num())
            p.line(to: pt)
        case "H", "h":
            pt = NSPoint(x: (rel ? pt.x : 0) + num(), y: pt.y)
            p.line(to: pt)
        case "V", "v":
            pt = NSPoint(x: pt.x, y: (rel ? pt.y : 0) + num())
            p.line(to: pt)
        case "C", "c":
            let c1 = NSPoint(x: o.x + num(), y: o.y + num()), c2 = NSPoint(x: o.x + num(), y: o.y + num())
            pt = NSPoint(x: o.x + num(), y: o.y + num())
            p.curve(to: pt, controlPoint1: c1, controlPoint2: c2)
        case "Q", "q":
            let q = NSPoint(x: o.x + num(), y: o.y + num())
            let end = NSPoint(x: o.x + num(), y: o.y + num())
            p.curve(to: end, controlPoint1: NSPoint(x: pt.x + 2 / 3 * (q.x - pt.x), y: pt.y + 2 / 3 * (q.y - pt.y)),
                    controlPoint2: NSPoint(x: end.x + 2 / 3 * (q.x - end.x), y: end.y + 2 / 3 * (q.y - end.y)))
            pt = end
        default:
            i += 1
        }
    }
    return p
}

/// Draws `body` in a `w` × `h` drawing (y down, as in the design's SVG)
/// fitted to `box`, in a flipped or an unflipped view.
func inDrawing(_ box: NSRect, _ w: CGFloat, _ h: CGFloat, _ body: () -> Void) {
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    NSGraphicsContext.saveGraphicsState()
    let tr = NSAffineTransform()
    tr.translateX(by: box.minX, yBy: flipped ? box.minY : box.maxY)
    tr.scaleX(by: box.width / w, yBy: (flipped ? 1 : -1) * box.height / h)
    tr.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

private func fill(_ p: NSBezierPath, _ c: NSColor, stroke: NSColor? = nil, width: CGFloat = 0) {
    c.setFill()
    p.fill()
    if let stroke {
        stroke.setStroke()
        p.lineWidth = width
        p.lineJoinStyle = .round
        p.stroke()
    }
}

private func strokePath(_ d: String, _ c: NSColor, _ width: CGFloat) {
    let p = svgPath(d)
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    c.setStroke()
    p.stroke()
}

private func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

// MARK: - Motion (tokens.json motion)

/// How a 团子 moves in a state at time `t`: an offset, a vertical squash
/// about its feet, and a tilt (degrees) about 90% down.
func motion(_ status: String, _ t: Double) -> (dx: CGFloat, dy: CGFloat, sy: CGFloat, rot: CGFloat) {
    func phase(_ period: Double) -> Double { (t.truncatingRemainder(dividingBy: period)) / period }
    switch status {
    case "working":
        return (0, -3 * CGFloat(1 - cos(phase(1.1) * 2 * .pi)) / 2, 1, 0)
    case "happy":
        // 0% 0 → 30% -8 (1.06) → 60% 0 (0.94) → 100% 0 (1).
        let p = phase(1.4)
        func ease(_ x: Double) -> CGFloat { CGFloat((1 - cos(x * .pi)) / 2) }
        if p < 0.3 { let k = ease(p / 0.3); return (0, -8 * k, 1 + 0.06 * k, 0) }
        if p < 0.6 { let k = ease((p - 0.3) / 0.3); return (0, -8 * (1 - k), 1.06 - 0.12 * k, 0) }
        return (0, 0, 0.94 + 0.06 * ease((p - 0.6) / 0.4), 0)
    case "fuming":
        let p = phase(0.5) * 5
        let k = p - floor(p)
        let a: [CGFloat] = [0, -2, 2, -2, 2, 0]
        let n = Int(p)
        return (a[n] + (a[min(n + 1, 5)] - a[n]) * CGFloat(k), 0, 1, 0)
    case "waiting":
        return (0, 0, 1, -4 * CGFloat(cos(phase(1.6) * 2 * .pi)))
    case "sleeping":
        return (0, 0, 1 + 0.03 * CGFloat(1 - cos(phase(3.2) * 2 * .pi)) / 2, 0)
    default:
        return (0, 0, 1, 0)
    }
}

/// Draws `body` with a state's motion applied to `box`.
func moving(_ status: String, _ t: Double, _ box: NSRect, _ body: () -> Void) {
    let m = motion(status, t)
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let up: CGFloat = flipped ? 1 : -1
    let feet = NSPoint(x: box.midX, y: flipped ? box.maxY : box.minY)
    let pivot = NSPoint(x: box.midX, y: flipped ? box.minY + box.height * 0.9 : box.maxY - box.height * 0.9)
    NSGraphicsContext.saveGraphicsState()
    let tr = NSAffineTransform()
    tr.translateX(by: m.dx, yBy: m.dy * up)
    tr.translateX(by: feet.x, yBy: feet.y)
    tr.scaleX(by: 1, yBy: m.sy)
    tr.translateX(by: -feet.x, yBy: -feet.y)
    if m.rot != 0 {
        tr.translateX(by: pivot.x, yBy: pivot.y)
        tr.rotate(byDegrees: m.rot * (flipped ? 1 : -1))
        tr.translateX(by: -pivot.x, yBy: -pivot.y)
    }
    tr.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// The little things around a 团子 in a state (README): z z when asleep,
/// steam when fuming (needing you is a raised paw now, `drawPose`). `box`
/// is the 团子's.
func stateExtras(_ status: String, _ t: Double, _ box: NSRect) {
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    /// A point `dx` from the left and `dy` above the top of `box`.
    func above(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint {
        NSPoint(x: box.minX + dx, y: flipped ? box.minY - dy : box.maxY + dy)
    }
    let s = box.width / 52
    switch status {
    case "sleeping":
        for (k, (dx, dy, size)) in [(box.width - 4 * s, 4 * s, 12 * s), (box.width + 4 * s, 14 * s, 15 * s)].enumerated() {
            let p = ((t - Double(k) * 0.7).truncatingRemainder(dividingBy: 2.2) + 2.2).truncatingRemainder(dividingBy: 2.2) / 2.2
            let alpha = p < 0.3 ? p / 0.3 : 1 - (p - 0.3) / 0.7
            let rise = CGFloat(-3 + 11 * p) * s
            let pt = above(dx, dy + rise)
            put(V3.mono("z", size, .regular, color(hex: V3.dark ? "#D6D1C8" : "#8A8278").withAlphaComponent(CGFloat(alpha))), pt.x, flipped ? pt.y - size : pt.y)
        }
    case "fuming":
        for (k, (fx, dy, d)) in [(0.30, 6.0, 8.0), (0.50, 10.0, 10.0), (0.66, 4.0, 7.0)].enumerated() {
            let p = ((t - Double(k) * 0.4).truncatingRemainder(dividingBy: 1.3) + 1.3).truncatingRemainder(dividingBy: 1.3) / 1.3
            let alpha = p < 0.4 ? p / 0.4 * 0.9 : 0.9 * (1 - (p - 0.4) / 0.6)
            let size = CGFloat(d * (0.6 + 0.6 * p)) * s
            let c = above(box.width * CGFloat(fx) + CGFloat(d / 2) * s, CGFloat(dy) * s + CGFloat(16 * p) * s)
            color(hex: "#B8B2A8").withAlphaComponent(CGFloat(alpha)).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)).fill()
        }
    default:
        break
    }
}

// MARK: - The room picture, and the 团子 from the design pack

/// Where the design's pictures are: in the app, next to a checkout, or in
/// $DANGO_ASSETS.
let themeAssets: URL? = {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let e = ProcessInfo.processInfo.environment["DANGO_ASSETS"] { dirs.append(URL(fileURLWithPath: e)) }
    if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("theme-b")) }
    dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("apps/widget/assets/theme-b"))
    dirs.append(URL(fileURLWithPath: "/Applications/Dango.app/Contents/Resources/theme-b"))
    return dirs.first { fm.fileExists(atPath: $0.appendingPathComponent("room.png").path) }
}()

private var imageCache: [String: NSImage] = [:]

func themeImage(_ name: String) -> NSImage? {
    if let i = imageCache[name] { return i }
    guard let url = themeAssets?.appendingPathComponent(name + ".png"), let i = NSImage(contentsOf: url) else { return nil }
    imageCache[name] = i
    return i
}

/// Where the 团子 parts are (assets/dango, cut from the designer's v2 pack by
/// tools/dango_pack.swift): in the app, next to a checkout, or beside
/// $DANGO_ASSETS.
let packAssets: URL? = {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let e = ProcessInfo.processInfo.environment["DANGO_ASSETS"] { dirs.append(URL(fileURLWithPath: e).deletingLastPathComponent().appendingPathComponent("dango")) }
    if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("dango")) }
    dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("apps/widget/assets/dango"))
    dirs.append(URL(fileURLWithPath: "/Applications/Dango.app/Contents/Resources/dango"))
    return dirs.first { fm.fileExists(atPath: $0.appendingPathComponent("dango.json").path) }
}()

/// dango.json: the pack's 512 × 512 layout (y down) — the body's rect and,
/// per role, its accessory and where the eyes and the accessory go.
let packLayoutJSON: [String: Any] = {
    guard let url = packAssets?.appendingPathComponent("dango.json"), let d = try? Data(contentsOf: url),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}()

private func packFractions(_ key: String) -> [String: [[CGFloat]]] {
    (packLayoutJSON[key] as? [String: [[NSNumber]]] ?? [:]).mapValues { $0.map { $0.map { CGFloat($0.doubleValue) } } }
}
/// Each eye set's left and right eye, as fractions of its image (dango.json).
let packEyeParts = packFractions("eyeParts")
/// The see-through holes an accessory frames (the glasses' lenses).
let packAccessoryHoles = packFractions("accessoryHoles")

/// The design's role for each job it has drawn (README 原型角色和程序里的职业);
/// every other job is the plain 团子.
let packRoles = ["designer": "R02", "video": "R03", "data": "R04", "writer": "R05", "swe": "R06", "ops": "R07", "pm": "R08", "qa": "R09", "research": "R11",
                 // Two of the pack's spare looks (2026-11-07): the afro, the sports headband.
                 "musician": "R01", "trainer": "R12",
                 // And looks drawn for the rest (2026-11-07, dango_pack `extraRoles`).
                 "doctor": "R13", "lawyer": "R14", "architect": "R15", "chef": "R16", "counselor": "R17",
                 "fin": "R18", "web": "R19", "entry": "R20", "scientist": "R21"]

struct PackLayout {
    var body: NSRect
    var eyes: NSRect
    var accessory: String?
    var accessoryRect: NSRect
    /// What the 团子 covers: its body and its accessory.
    var extent: NSRect { accessory == nil ? body : body.union(accessoryRect) }
}

func packLayout(_ role: String?) -> PackLayout {
    func rect(_ a: Any?) -> NSRect? {
        guard let v = a as? [NSNumber], v.count == 4 else { return nil }
        return NSRect(x: v[0].doubleValue, y: v[1].doubleValue, width: v[2].doubleValue, height: v[3].doubleValue)
    }
    let r = role.flatMap { (packLayoutJSON["roles"] as? [String: [String: Any]])?[$0] }
    return PackLayout(body: rect(packLayoutJSON["bodyRect"]) ?? NSRect(x: 80, y: 160, width: 352, height: 240),
                      eyes: rect(r?["eyeRect"]) ?? rect(packLayoutJSON["defaultEyeRect"]) ?? NSRect(x: 151, y: 238, width: 212, height: 124),
                      accessory: r?["accessory"] as? String, accessoryRect: rect(r?["accessoryRect"]) ?? .zero)
}

/// The eyes for a state, as the pack's taskVisuals pair them: working is
/// running (E02), waiting is waiting_user (E04), happy is success (E06),
/// fuming is error (E07), sleeping E09, anything else idle (E01).
func packEyes(_ status: String) -> String {
    switch status {
    case "working": return "E02"
    case "waiting": return "E04"
    case "happy": return "E06"
    case "fuming": return "E07"
    case "sleeping": return "E09"
    default: return "E01"
    }
}

private var packImages: [String: NSImage] = [:]

private func packImage(_ id: String) -> NSImage? {
    if let i = packImages[id] { return i }
    guard let url = packAssets?.appendingPathComponent(id + ".png"), let i = NSImage(contentsOf: url) else { return nil }
    packImages[id] = i
    return i
}

/// A 团子 whose body fills `body` (dango.json's bodyRect): the body, a flush
/// on the forehead when fuming, the state's eyes, then the role's accessory
/// (hats, glasses and the bow tie reach past `body`). Flipped or not.
/// `pose` is the state the paws show when the eyes show another (a blink).
func drawPackDango(_ body: NSRect, role: String?, status: String, pose: String? = nil, atDesk: Bool = false) {
    let l = packLayout(role)
    let k = body.width / l.body.width
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    /// A rect of the layout, in the view.
    func place(_ r: NSRect) -> NSRect {
        let x = body.minX + (r.minX - l.body.minX) * k
        let y = flipped ? body.minY + (r.minY - l.body.minY) * k : body.maxY - (r.maxY - l.body.minY) * k
        return NSRect(x: x, y: y, width: r.width * k, height: r.height * k)
    }
    /// `size` fitted into `r` keeping its shape, centred (the pack's
    /// renderer: preserveAspectRatio xMidYMid meet).
    func fit(_ size: NSSize, _ r: NSRect) -> NSRect {
        let s = min(r.width / size.width, r.height / size.height)
        return NSRect(x: r.midX - size.width * s / 2, y: r.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }
    /// Part `f` (fractions of the image, top-left origin) of an image, drawn in `r` (layout).
    func draw(_ img: NSImage, _ f: [CGFloat] = [0, 0, 1, 1], in r: NSRect) {
        let src = NSRect(x: f[0] * img.size.width, y: (1 - f[1] - f[3]) * img.size.height, width: f[2] * img.size.width, height: f[3] * img.size.height)
        img.draw(in: place(r), from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    // B01 drawn as round as the designer's role sheet (bodyRect is taller than B01).
    if let b = packImage(V3.dark ? "B01W" : "B01") { draw(b, in: l.body) }
    if status == "fuming" {
        // 冒火中: the forehead flushes, the body stays black (the pack's rules).
        let f = place(NSRect(x: l.body.midX - 80, y: l.body.minY + 26, width: 160, height: 56))
        NSGradient(colors: [color(hex: "#FF5A5F").withAlphaComponent(0.42), color(hex: "#FF5A5F").withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: f), relativeCenterPosition: .zero)
    }
    let acc = l.accessory.flatMap(packImage)
    let accRect = acc.map { fit($0.size, l.accessoryRect) }
    if let eyes = packImage(packEyes(status)) {
        if let accRect, let holes = packAccessoryHoles[l.accessory ?? ""], let parts = packEyeParts[packEyes(status)], holes.count == 2, parts.count == 2 {
            // Glasses: one eye in each lens, centred, a little inside its rim.
            for (h, part) in zip(holes, parts) {
                let lens = NSRect(x: accRect.minX + h[0] * accRect.width, y: accRect.minY + h[1] * accRect.height, width: h[2] * accRect.width, height: h[3] * accRect.height)
                let size = NSSize(width: part[2] * eyes.size.width, height: part[3] * eyes.size.height)
                draw(eyes, part, in: fit(size, lens.insetBy(dx: lens.width * 0.07, dy: lens.height * 0.07)))
            }
        } else {
            draw(eyes, in: fit(eyes.size, l.eyes))
        }
    }
    if let acc, let accRect { draw(acc, in: accRect) }
    drawPose(pose ?? status, role: role, layout: l, body: body, atDesk: atDesk)
}

/// The clock the waving paw and the alert marks move by: the office and the
/// corner pet set it before drawing; still pictures leave it at rest.
enum Pose {
    static var time = 0.0
}

/// Paws and props in a state, drawn the way the website's 团子 have them
/// (user, 2026-11-09: 「网站上的这些团子的渲染都做的更好…app也做成这样的」):
/// round black nubs with the body's outline, a gloss and two claw lines.
/// Working: both paws on a keyboard (a book for the researcher and the
/// scientist); happy: one paw waving, with motion arcs; waiting: a paw up
/// and yellow alert marks; idle: both paws resting at the front; asleep and
/// fuming: none. At a desk the picture's laptop is the prop, so working
/// draws nothing there. In the layout's units (dango.json, y down).
func drawPose(_ status: String, role: String?, layout l: PackLayout, body: NSRect, atDesk: Bool) {
    let k = body.width / l.body.width
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let tr = NSAffineTransform()
    if flipped {
        tr.translateX(by: body.minX - l.body.minX * k, yBy: body.minY - l.body.minY * k)
        tr.scaleX(by: k, yBy: k)
    } else {
        tr.translateX(by: body.minX - l.body.minX * k, yBy: body.maxY + l.body.minY * k)
        tr.scaleX(by: k, yBy: -k)
    }
    let W = l.body.width, H = l.body.height
    func pt(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: l.body.minX + fx * W, y: l.body.minY + fy * H) }
    let dark = V3.dark
    let fur = color(hex: dark ? "#ECECEE" : "#211F1D"), rim = color(hex: dark ? "#1D1D1E" : "#030303")
    let gloss = color(hex: dark ? "#FFFFFF" : "#5A5853")
    func stroke(_ p: NSBezierPath, _ c: NSColor, _ w: CGFloat) {
        p.transform(using: tr as AffineTransform)
        p.lineWidth = w * k
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        c.setStroke()
        p.stroke()
    }
    func fill(_ p: NSBezierPath, _ c: NSColor) {
        p.transform(using: tr as AffineTransform)
        c.setFill()
        p.fill()
    }
    /// A paw centred at (fx, fy), `w` of the body wide, turned `deg` (0 =
    /// claws down).
    func paw(_ fx: CGFloat, _ fy: CGFloat, w: CGFloat = 0.15, deg: CGFloat = 0) {
        let c = pt(fx, fy), pw = w * W, ph = pw * 0.78
        let turn = AffineTransform(rotationByDegrees: deg)
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let p = turn.transform(NSPoint(x: x, y: y))
            return NSPoint(x: c.x + p.x, y: c.y + p.y)
        }
        let blob = NSBezierPath()
        let n = 28
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            // A little flatter where the claws are.
            let ry = sin(a) > 0 ? ph / 2 * 0.9 : ph / 2
            let p = at(cos(a) * pw / 2, sin(a) * ry)
            i == 0 ? blob.move(to: p) : blob.line(to: p)
        }
        blob.close()
        fill(blob.copy() as! NSBezierPath, fur)
        stroke(blob, rim, 7.5)
        let shine = NSBezierPath()
        shine.move(to: at(-pw * 0.26, -ph * 0.12))
        shine.curve(to: at(-pw * 0.02, -ph * 0.32), controlPoint1: at(-pw * 0.24, -ph * 0.28), controlPoint2: at(-pw * 0.14, -ph * 0.33))
        stroke(shine, gloss, 4.5)
        for x in [-0.14, 0.14] as [CGFloat] {
            let claw = NSBezierPath()
            claw.move(to: at(x * pw, ph * 0.46))
            claw.line(to: at(x * pw, ph * 0.18))
            stroke(claw, rim, 4)
        }
    }
    switch status {
    case "working" where !atDesk:
        if role == "R11" || role == "R21" {
            // An open book held up in front, like the website's researcher.
            let top: CGFloat = 0.66, bottom: CGFloat = 0.99, mid: CGFloat = 0.5, half: CGFloat = 0.36
            let cover = NSBezierPath()
            cover.move(to: pt(mid, top + 0.05)); cover.line(to: pt(mid - half, top)); cover.line(to: pt(mid - half, bottom - 0.03))
            cover.line(to: pt(mid, bottom)); cover.line(to: pt(mid + half, bottom - 0.03)); cover.line(to: pt(mid + half, top)); cover.close()
            fill(cover.copy() as! NSBezierPath, color(hex: "#1F5C5E"))
            stroke(cover, rim, 7)
            let pages = NSBezierPath()
            pages.move(to: pt(mid, top + 0.05)); pages.line(to: pt(mid - half + 0.03, top + 0.005)); pages.line(to: pt(mid - half + 0.03, top + 0.04))
            pages.line(to: pt(mid, top + 0.09)); pages.line(to: pt(mid + half - 0.03, top + 0.04)); pages.line(to: pt(mid + half - 0.03, top + 0.005)); pages.close()
            fill(pages.copy() as! NSBezierPath, color(hex: "#F4EEDC"))
            stroke(pages, rim, 4)
            let spine = NSBezierPath(); spine.move(to: pt(mid, top + 0.05)); spine.line(to: pt(mid, bottom)); stroke(spine, rim, 5)
            let ink = color(hex: "#D9EFEC")
            for (i, h) in [0.10, 0.17, 0.24].enumerated() {
                let x = mid - half + 0.08 + CGFloat(i) * 0.07
                let bar = NSBezierPath(); bar.move(to: pt(x, bottom - 0.07)); bar.line(to: pt(x, bottom - 0.07 - CGFloat(h) * 0.7)); stroke(bar, ink, 8)
            }
            let flask = NSBezierPath()
            flask.move(to: pt(mid + 0.15, top + 0.12)); flask.line(to: pt(mid + 0.15, top + 0.17)); flask.line(to: pt(mid + 0.10, bottom - 0.07))
            flask.line(to: pt(mid + 0.27, bottom - 0.07)); flask.line(to: pt(mid + 0.22, top + 0.17)); flask.line(to: pt(mid + 0.22, top + 0.12))
            stroke(flask, ink, 5)
            paw(0.12, 0.86, w: 0.15, deg: 70)
            paw(0.88, 0.86, w: 0.15, deg: -70)
        } else {
            // A keyboard at the front, both paws on it, like the website's coder.
            let kb = NSBezierPath(roundedRect: NSRect(x: pt(0.07, 0).x, y: pt(0, 0.85).y, width: 0.86 * W, height: 0.14 * H), xRadius: 0.025 * W, yRadius: 0.025 * W)
            fill(kb.copy() as! NSBezierPath, color(hex: dark ? "#9EA2A8" : "#8F9399"))
            stroke(kb, rim, 7)
            let key = color(hex: "#D6D9DE")
            for row in 0..<2 {
                for i in 0..<12 {
                    let x = 0.105 + CGFloat(i) * 0.066, y = 0.872 + CGFloat(row) * 0.052
                    fill(NSBezierPath(roundedRect: NSRect(x: pt(x, 0).x, y: pt(0, y).y, width: 0.05 * W, height: 0.034 * H), xRadius: 0.008 * W, yRadius: 0.008 * W), key)
                }
            }
            paw(0.30, 0.84, w: 0.15)
            paw(0.70, 0.84, w: 0.15)
        }
    case "happy":
        // Waving: the paw swings ±14° about its raised angle.
        let swing = 14 * CGFloat(sin(Pose.time / 0.9 * 2 * .pi))
        paw(0.99, 0.46, w: 0.17, deg: -145 + swing)
        for (i, r) in [0.12, 0.17].enumerated() {
            let arc = NSBezierPath()
            let c = pt(0.99, 0.46)
            arc.appendArc(withCenter: c, radius: CGFloat(r) * W, startAngle: -55, endAngle: 5)
            stroke(arc, color(hex: dark ? "#A9AEB6" : "#7B8089").withAlphaComponent(i == 0 ? 0.9 : 0.6), 5)
        }
    case "waiting":
        // A paw up, asking; the alert marks blink.
        paw(0.01, 0.46, w: 0.17, deg: 145)
        let blink = 0.55 + 0.45 * CGFloat(cos(Pose.time / 1.4 * 2 * .pi))
        let c = pt(-0.03, 0.27)
        for (dx, dy) in [(-0.09, -0.01), (-0.03, -0.09), (0.05, -0.08)] as [(CGFloat, CGFloat)] {
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: c.x + dx * W * 0.45, y: c.y + dy * W * 0.45))
            mark.line(to: NSPoint(x: c.x + dx * W, y: c.y + dy * W))
            stroke(mark, color(hex: "#F5B800").withAlphaComponent(blink), 8)
        }
    case "idle":
        paw(0.30, 0.90, w: 0.13)
        paw(0.70, 0.90, w: 0.13)
    default:
        break
    }
}

/// The rect a role's whole 团子 (accessory too) takes when its body is `body`.
func packExtent(_ body: NSRect, role: String?) -> NSRect {
    let l = packLayout(role), e = l.extent, k = body.width / l.body.width
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let y = flipped ? body.minY + (e.minY - l.body.minY) * k : body.maxY - (e.maxY - l.body.minY) * k
    return NSRect(x: body.minX + (e.minX - l.body.minX) * k, y: y, width: e.width * k, height: e.height * k)
}

/// A role's 团子, accessory and all, fitted into `box` and centred.
func drawFittedDango(_ box: NSRect, role: String?, status: String, pose: String? = nil) {
    let l = packLayout(role), e = l.extent
    let k = min(box.width / e.width, box.height / e.height)
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let ex = box.midX - e.width * k / 2, ey = box.midY - e.height * k / 2
    let by = flipped ? ey + (l.body.minY - e.minY) * k : ey + (e.maxY - l.body.maxY) * k
    drawPackDango(NSRect(x: ex + (l.body.minX - e.minX) * k, y: by, width: l.body.width * k, height: l.body.height * k), role: role, status: status, pose: pose)
}

/// A job's 团子 fitted into `box` (the corner card, the roster).
func themeDango(_ box: NSRect, job: String, status: String, pose: String? = nil) {
    drawFittedDango(box, role: packRoles[job], status: status, pose: pose)
}

private var packPictures: [String: NSImage] = [:]

/// A role's 团子 as a picture, drawn when shown (the ABTI crew lists).
func packPicture(_ role: String, status: String = "idle") -> NSImage {
    if let i = packPictures[role + status] { return i }
    let e = packLayout(role).extent
    let i = NSImage(size: e.size, flipped: true) { b in
        drawFittedDango(b, role: role, status: status)
        return true
    }
    packPictures[role + status] = i
    return i
}

// MARK: - The v3 office

/// The office cell of the panel: the room picture, the 团子 in their places
/// by state, walking between places in 0.9 s.
final class V3OfficeView: NSView {
    var occupants: [Occupant] = []
    var model: Model?
    var t = 0.0
    /// Snapshots: everyone already in place, no walking.
    var instant = false
    override var isFlipped: Bool { true }

    static let height: CGFloat = 178

    /// Where each 团子 was drawn last, for the pointer: hovering one shows its
    /// job and state (user, 2026-11-09: 「鼠标放到对应团子上的时候，要有状态，
    /// 就是在工作或者在摸鱼或者在睡觉的状态」).
    private var spots: [(rect: NSRect, job: String, status: String)] = []
    private var pointer: NSPoint? { didSet { needsDisplay = true } }
    /// Snapshots: the label over this one (`--hover N`).
    var hoverIndex: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { pointer = nil }

    /// A dark pill over the 团子 the pointer is on: 「软件工程师 · 在干」.
    private func drawHoverLabel() {
        let spot: (rect: NSRect, job: String, status: String)?
        if let i = hoverIndex, spots.indices.contains(i) { spot = spots[i] }
        else if let p = pointer { spot = spots.last { $0.rect.insetBy(dx: -2, dy: -2).contains(p) } }
        else { spot = nil }
        guard let spot else { return }
        let text = AB.join([V3.sans(spot.job + " · ", 11, .medium, NSColor.white.withAlphaComponent(0.75)), V3.sans(statusName(spot.status), 11, .semibold, .white)])
        let w = text.size().width + 18, h: CGFloat = 20
        let x = min(max(4, spot.rect.midX - w / 2), bounds.width - 4 - w)
        let y = max(4, spot.rect.minY - h - 4)
        let pill = NSRect(x: x, y: y, width: w, height: h)
        NSColor(calibratedWhite: 0.1, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 9, y: pill.minY + (h - text.size().height) / 2))
    }

    /// Each one's place now and the walk to it: from, to, when it set off.
    private struct Walk { var from: NSRect; var to: NSRect; var start: Double }
    private var walks: [String: Walk] = [:]

    func tick(_ dt: Double) { t += dt }

    /// Where a 团子 stands, `w` wide, its feet at `bottom`.
    private func feet(_ x: CGFloat, bottom: CGFloat, w: CGFloat) -> NSRect { NSRect(x: x, y: bottom - w * 110 / 120, width: w, height: w * 110 / 120) }

    /// Who goes where: two desks for working / happy / fuming, a place to
    /// stand for waiting, the sofa's three seats and then the door for idle
    /// and sleeping; off is outside.
    /// The two desk places' left edges (50 wide), centred behind the
    /// laptops in the designer's office (tools/office_art.py: laptops at
    /// x 234.2 and 297.6, their lids from y 117.5, the desks' tops at 133.9).
    static let deskX: [CGFloat] = [209.2, 272.6]

    private func arrangement() -> [(Occupant, String, NSRect)] {
        let all = occupants.map { ($0, officeStatus($0, model)) }
        let desk = all.filter { ["working", "happy", "fuming"].contains($0.1) }.prefix(2)
        let stand = all.filter { $0.1 == "waiting" }.prefix(1)
        let lounge = all.filter { ["idle", "sleeping"].contains($0.1) }.prefix(3)
        var out: [(Occupant, String, NSRect)] = []
        let desks: [NSRect] = V3OfficeView.deskX.map { feet($0, bottom: 131, w: 50) }
        // The one waiting stands on the floor left of the sofa (the desks are
        // too close together to stand between).
        for (o, s) in stand { out.append((o, s, feet(7, bottom: 166, w: 46))) }
        for (i, (o, s)) in desk.enumerated() { out.append((o, s, desks[i])) }
        // One on each seat cushion (centres 86.2, 122.4, 158.2 between the
        // arms), sunk 1.5 points into its top edge (y 145.2, room-front.png).
        let seats: [NSRect] = [86.2, 122.4, 158.2].map { feet($0 - 23, bottom: 146.7, w: 46) }
        for (i, (o, s)) in lounge.enumerated() { out.append((o, s, seats[i])) }
        return out
    }

    /// The place now, walking there in 0.9 s (ease in and out) when it changed.
    private func now(_ id: String, _ to: NSRect) -> NSRect {
        if instant { return to }
        let outside = NSRect(x: -90, y: to.minY, width: to.width, height: to.height)
        var w = walks[id] ?? Walk(from: outside, to: to, start: t)
        if w.to != to {
            w = Walk(from: current(w), to: to, start: t)
        }
        walks[id] = w
        return current(w)
    }

    private func current(_ w: Walk) -> NSRect {
        let p = CGFloat(min(1, max(0, (t - w.start) / 0.9)))
        let k = p * p * (3 - 2 * p)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return NSRect(x: mix(w.from.minX, w.to.minX), y: mix(w.from.minY, w.to.minY), width: mix(w.from.width, w.to.width), height: mix(w.from.height, w.to.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Appearance.drawing { drawOffice() }
    }

    private func drawOffice() {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).addClip()
        let people = arrangement()
        walks = walks.filter { id, _ in people.contains { $0.0.job.id == id } }
        drawRoom(people)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// One 团子, its body in `body`; its z z / ? / steam over the whole of it.
    private func drawDango(_ o: Occupant, _ s: String, _ body: NSRect, phase: Double) {
        let eyes = blinking(s, t + phase * 7) ? "sleeping" : s
        let role = packRoles[o.job.id]
        Pose.time = t + phase
        let atDesk = ["working", "happy", "fuming"].contains(s)
        moving(s, t + phase, body) {
            drawPackDango(body, role: role, status: eyes, pose: s, atDesk: atDesk)
        }
        stateExtras(s, t + phase, packExtent(body, role: role))
    }

    // The design's picture, the 团子, and the picture's sofa front and desk
    // again in front of them (theme-b/room-front.png, cut along the cushions'
    // and the desk's outlines by tools/room_front.swift).
    private func drawRoom(_ people: [(Occupant, String, NSRect)]) {
        let room = themeImage("room")
        let (dusk, night) = Appearance.sky()
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        // The dark theme's 团子 are white and the picture is a light room, so
        // there the room goes darker, less at night when it already is (user,
        // 2026-11-09: 「暗色背景这个办公室和白团子的对比不够明显」).
        let dim = V3.dark ? 0.45 - 0.2 * night : 0
        func dimmed(_ draw: () -> Void) {
            guard dim > 0, let cg = NSGraphicsContext.current?.cgContext else { return draw() }
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            draw()
            cg.setBlendMode(.sourceAtop)
            cg.setFillColor(color(hex: "#0F1424").withAlphaComponent(dim).cgColor)
            cg.fill(bounds)
            cg.endTransparencyLayer()
        }
        if let room {
            dimmed {
                room.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
                if dusk > 0 { themeImage("room-dusk")?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: dusk, respectFlipped: true, hints: hints) }
                if night > 0 { themeImage("room-night")?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: night, respectFlipped: true, hints: hints) }
            }
        } else {
            color(hex: "#FBF3E4").setFill()
            bounds.fill()
        }
        spots = []
        for (i, (o, s, place)) in people.enumerated() {
            // The body a little narrower than the place, standing on its floor.
            let b = packLayout(nil).body, w = place.width * 0.86, h = w * b.height / b.width
            let at = now(o.job.id, NSRect(x: place.midX - w / 2, y: place.maxY - h, width: w, height: h))
            drawDango(o, s, at, phase: Double(i) * 0.41)
            spots.append((packExtent(at, role: packRoles[o.job.id]), o.job.name, s))
        }
        dimmed {
            themeImage("room-front")?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
            if dusk > 0 { themeImage("room-front-dusk")?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: dusk, respectFlipped: true, hints: hints) }
            if night > 0 { themeImage("room-front-night")?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: night, respectFlipped: true, hints: hints) }
        }
        drawHoverLabel()
    }
}

// MARK: - The v3 panel

extension DashboardView {
    /// The v3 panel (README 面板结构), 440 wide; returns its height.
    func layoutV3(draw: Bool) -> CGFloat {
        if officeV3.superview == nil { addSubview(officeV3) }
        officeV3.isHidden = false
        let W = bounds.width, padX: CGFloat = 24, inner = W - padX * 2
        var y: CGFloat = 22
        v3Hits = []
        if draw && drawBackground {
            V3.surface.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 36, yRadius: 36).fill()
        }
        guard let m = model else {
            if draw { put(V3.sans(L("等待数据…", "Waiting for data…"), 13, .medium, V3.secondary), padX, y) }
            return 80
        }
        // 1. Top bar: the word mark, the day, a round button that closes.
        if draw {
            let mw = AB.wordmark(padX, y + 8, size: 17, color: V3.ink)
            put(V3.mono(L("第 \(m.daysTogether) 天", "day \(m.daysTogether)"), 11, .regular, V3.secondary), padX + mw + 10, y + 12)
            let b = NSRect(x: W - padX - 36, y: y, width: 36, height: 36)
            V3.control.setFill()
            NSBezierPath(ovalIn: b).fill()
            let c = NSBezierPath()
            c.move(to: NSPoint(x: b.midX - 5, y: b.midY - 2.5))
            c.line(to: NSPoint(x: b.midX, y: b.midY + 2.5))
            c.line(to: NSPoint(x: b.midX + 5, y: b.midY - 2.5))
            c.lineWidth = 1.8
            c.lineCapStyle = .round
            c.lineJoinStyle = .round
            V3.ink.setStroke()
            c.stroke()
        }
        v3Hits.append(("close", NSRect(x: 0, y: 0, width: W, height: y + 36)))
        y += 36 + 20

        // 2. The office.
        let oh = V3OfficeView.height
        officeV3.frame = NSRect(x: padX, y: y, width: inner, height: oh)
        officeV3.model = m
        officeV3.occupants = m.office
        y += oh + 20

        // 3. Today's number, with its model cost and leverage and whether
        //    it is the best day, and the character's line on one row; then
        //    the week, the month and the total in one compact row (2026-11-07,
        //    user: 「这里占地太大了」: today was in a tile too, and four big
        //    tiles took two rows).
        let beating = m.recordUSD > 0 && m.todayUSD + 1e-9 >= m.recordUSD && m.todayUSD > 0
        let hero = V3.mono(fmtUSD(m.todayUSD), 44, .semibold)
        if draw { put(hero, W / 2, y, align: 1) }
        y += hero.size().height + 1
        let todayLev = m.todayCost >= 0.01 ? " · " + fmtUSD(m.todayCost) + " · " + String(format: "%.1f×", m.todayUSD / m.todayCost) : ""
        let sub = V3.mono(L("今天的产出", "Today's output") + todayLev + (beating ? L(" · 单日纪录", " · best day") : ""), 11.5, .regular, V3.secondary)
        if draw {
            let x0 = W / 2 - (sub.size().width + 12) / 2
            V3.today.setFill()
            NSBezierPath(ovalIn: NSRect(x: x0, y: y + 5, width: 6, height: 6)).fill()
            put(sub, x0 + 12, y)
        }
        y += sub.size().height + 6
        if !m.line.isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let line = NSMutableAttributedString(attributedString: V3.sans(m.line, 13, .medium, V3.secondary))
            line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
            if draw { line.draw(with: NSRect(x: padX, y: y, width: inner, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
            y += 18
        }
        y += 14

        let cells: [(String, Double, Double, Double)] = [(L("本周", "This week"), m.weekUSD, m.weekHours, m.weekCost),
                                                          (L("本月", "This month"), m.monthUSD, m.monthHours, m.monthCost), (L("总计", "Total"), m.totalUSD, m.totalHours, m.totalCost)]
        let strip = NSRect(x: padX, y: y, width: inner, height: 64)
        if draw {
            V3.tile.setFill()
            NSBezierPath(roundedRect: strip, xRadius: 18, yRadius: 18).fill()
            let cw = inner / CGFloat(cells.count)
            for (i, t) in cells.enumerated() {
                let x0 = strip.minX + CGFloat(i) * cw
                if i > 0 {
                    V3.line.setFill()
                    NSRect(x: x0, y: strip.minY + 14, width: 1, height: strip.height - 28).fill()
                }
                put(V3.mono(t.0, 10.5, .regular, V3.secondary), x0 + 16, strip.minY + 10)
                put(V3.mono(fmtUSD(t.1), 17, .semibold), x0 + 16, strip.minY + 24)
                let lev = t.3 >= 0.01 ? "\(fmtUSD(t.3)) · " + String(format: "%.1f×", t.1 / t.3) : fmtHours(t.2)
                put(V3.mono(lev, 10, .regular, V3.secondary), x0 + 16, strip.minY + 46)
            }
        }
        y += strip.height + 12

        // 3b. Who you are as a boss, the way the total report shows it,
        //     right under the numbers; it opens the boss card (2026-11-07,
        //     user: 「加到主页面去，能显眼一些」).
        if let b = m.boss {
            let box = NSRect(x: padX, y: y, width: inner, height: 116)
            if draw {
                AB.round(box, 20, V3.tile)
                AB.fit(abtiImage("scene/T-" + b.code), NSRect(x: box.minX + 10, y: box.minY + 12, width: 116, height: 92))
                let tx = box.minX + 136, right = box.maxX - 14
                // The type's name gets smaller (to 13 pt) to stay clear of the
                // link; French and Spanish names run long, and then the link
                // is just its arrow.
                let title = { (size: CGFloat) in AB.join([V3.mono(b.code + " ", size, .semibold), V3.sans(b.name, size, .semibold)]) }
                var link = V3.mono("ABTI ›", 10, .regular, V3.secondary)
                if title(13).size().width > right - link.size().width - 10 - tx {
                    link = V3.mono("›", 12, .regular, V3.secondary)
                }
                put(link, right, box.minY + 10, align: 2)
                var size: CGFloat = 16
                while title(size).size().width > right - link.size().width - 10 - tx && size > 13 { size -= 0.5 }
                put(title(size), tx, box.minY + 14 + (16 - size) * 0.6)
                let p1 = AB.pill(scalePill(b.scale), tx, box.minY + 42, dark: true, size: 11, fill: V3.ink, ink: V3.onInk)
                // The margin's tier name too when it fits on the line.
                let margin = L("压榨率 ", "Margin ") + String(format: "%.1f%%", b.margin * 100)
                let full = margin + (b.marginTier.isEmpty ? "" : " · " + b.marginTier)
                let fits = p1.maxX + 6 + AB.sans(full, 11, .medium).size().width + 24 <= right
                AB.pill(fits ? full : margin, p1.maxX + 6, box.minY + 42, dark: false, size: 11, fill: V3.raised, ink: V3.ink)
                AB.para(V3.sans(b.roast, 12, .regular, V3.secondary), tx, box.minY + 70, right - tx, lineHeight: 16)
            }
            v3Hits.append(("boss", box))
            y += box.height + 14
        }

        // 4. 1D · 7D · 30D: the window of what follows.
        let labels = [(1, L("1 天", "1D")), (7, L("7 天", "7D")), (30, L("30 天", "30D"))]
        let widths = labels.map { V3.mono($0.1, 11.5, .medium).size().width + 26 }
        let groupW = widths.reduce(0, +) + 2 * 2 + 6
        var x = W / 2 - groupW / 2
        if draw {
            V3.control.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: groupW, height: 30), xRadius: 15, yRadius: 15).fill()
        }
        x += 3
        for (i, (days, label)) in labels.enumerated() {
            let r = NSRect(x: x, y: y + 3, width: widths[i], height: 24)
            if draw {
                if days == range {
                    NSGraphicsContext.saveGraphicsState()
                    let sh = NSShadow()
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.08)
                    sh.shadowBlurRadius = 3
                    sh.shadowOffset = NSSize(width: 0, height: -1)
                    sh.set()
                    V3.raised.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let s = V3.mono(label, 11.5, .medium, days == range ? V3.ink : V3.secondary)
                put(s, r.midX, r.midY - s.size().height / 2, align: 1)
            }
            v3Hits.append(("range:\(days)", r))
            x += widths[i] + 2
        }
        y += 30 + 20

        // 6. The roster: each job of the window, styled by its state.
        let jobsSel = (range == 1 ? m.jobs1 : range == 7 ? m.jobs7 : m.jobs).filter { $0.usd > 0 }
        let stateOf: (String) -> String = { id in m.office.first { $0.job.id == id }.map { officeStatus($0, m) } ?? "off" }
        let states = jobsSel.map { stateOf($0.id) }
        let count = { (set: [String]) in states.filter { set.contains($0) }.count }
        let counts = [(count(["working", "happy", "fuming"]), L("在干", "working")), (count(["waiting"]), L("等你批准", "need you")), (count(["idle", "sleeping"]), L("摸鱼", "slacking"))]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        if draw {
            let title = V3.sans(L("员工名册", "Your staff"), 16, .semibold)
            put(title, padX, y + 8)
            put(V3.mono(counts, 11, .regular, V3.secondary), padX + title.size().width + 10, y + 13)
        }
        for (k, (id, glyph)) in [("menu", "…"), ("expand", jobsOpen ? "−" : "+")].enumerated() {
            let b = NSRect(x: W - padX - 36 - CGFloat(1 - k) * 46, y: y, width: 36, height: 36)
            if draw {
                V3.control.setFill()
                NSBezierPath(ovalIn: b).fill()
                let g = V3.sans(glyph, 17, .semibold)
                put(g, b.midX, b.midY - g.size().height / 2, align: 1)
            }
            v3Hits.append((id, b))
        }
        y += 36 + 12
        if jobsSel.isEmpty {
            if draw { put(V3.sans(L("这段时间还没有活", "No work in this window yet"), 12, .regular, V3.secondary), padX, y) }
            y += 24
        } else {
            let shown = jobsOpen ? jobsSel.count : min(6, jobsSel.count)
            let cw = (inner - 10) / 2, chh: CGFloat = 64
            for i in 0..<shown {
                let j = jobsSel[i], s = states[i]
                let r = NSRect(x: padX + CGFloat(i % 2) * (cw + 10), y: y + CGFloat(i / 2) * (chh + 10), width: cw, height: chh)
                if draw { rosterCard(r, job: j, status: s) }
            }
            y += CGFloat((shown + 1) / 2) * (chh + 10)
            if !jobsOpen && jobsSel.count > 6 {
                let rest = jobsSel.dropFirst(6)
                let allOff = states.dropFirst(6).allSatisfy { $0 == "off" }
                let r = NSRect(x: padX, y: y, width: inner, height: chh)
                if draw {
                    V3.tile.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
                    for (k, j) in rest.prefix(2).enumerated() {
                        NSGraphicsContext.saveGraphicsState()
                        themeDango(NSRect(x: r.minX + 18 + CGFloat(k) * 16, y: r.midY - 13, width: 30, height: 26), job: j.id, status: "off")
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let s = L("还有 \(rest.count) 种 · \(fmtUSD(rest.map(\.usd).reduce(0, +)))", "\(rest.count) more · \(fmtUSD(rest.map(\.usd).reduce(0, +)))")
                        + (allOff ? L(" · 都下班了", " · all off") : "")
                    put(V3.mono(s, 12, .regular, V3.secondary), r.minX + 78, r.midY - 8)
                }
                v3Hits.append(("expand", r))
                y += chh + 10
            }
        }
        y += 10

        // 7. The agents side by side (Claude Code, Codex, DeepSeek,
        //    WorkBuddy): the ones with work in the window, biggest first,
        //    under one short title (their names ran into the note, user
        //    2026-11-07: 「不需要写 Claude Code, Codex, DeepSeek」).
        let toolsSel = Array((range == 1 ? m.tools1 : range == 7 ? m.tools7 : m.tools).filter { $0.usd > 0 }.prefix(4))
        let toolShades = [V3.ink, color(hex: "#636366"), color(hex: "#AEAEB2"), color(hex: "#D1D1D6")]
        if !toolsSel.isEmpty {
            if draw {
                put(V3.sans(L("工具分布", "By tool"), 16, .semibold), padX, y)
                put(V3.mono(L("\(range) 天 · 产出 ÷ 花费", "\(range)D · output ÷ cost"), 11, .regular, V3.secondary), W - padX, y + 4, align: 2)
            }
            y += 30
            if draw {
                V3.track.setFill()
                NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: inner, height: 6), xRadius: 3, yRadius: 3).fill()
                // Each one's share, darkest first; drawn back to front so
                // the rounded ends overlap.
                let shades = toolShades
                var ends: [CGFloat] = []
                var x = padX
                for t in toolsSel { x += inner * CGFloat(t.share); ends.append(x) }
                for k in toolsSel.indices.reversed() {
                    shades[k].setFill()
                    NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: max(6, ends[k] - padX), height: 6), xRadius: 3, yRadius: 3).fill()
                }
            }
            y += 14
            let figures = { (t: ToolShare) in String(format: "%.0f%%", t.share * 100) + (t.cost >= 0.01 ? " · " + String(format: "%.1f×", t.usd / t.cost) : "") }
            if toolsSel.count <= 2 {
                // One on the left, the other on the right.
                if draw {
                    for (k, t) in toolsSel.enumerated() {
                        let s = NSMutableAttributedString(attributedString: V3.mono(t.name + " ", 11.5, .regular))
                        s.append(V3.mono(figures(t), 11.5, .regular, V3.secondary))
                        put(s, k == 0 ? padX : W - padX, y, align: k == 0 ? 0 : 2)
                    }
                }
                y += 20
            } else {
                // Three or more don't fit on a line: one each, its shade beside it.
                let shades = toolShades
                for (k, t) in toolsSel.enumerated() {
                    if draw {
                        shades[k].setFill()
                        NSBezierPath(ovalIn: NSRect(x: padX, y: y + 4.5, width: 7, height: 7)).fill()
                        put(V3.mono(t.name, 11.5, .regular), padX + 14, y)
                        put(V3.mono(figures(t), 11.5, .regular, V3.secondary), W - padX, y, align: 2)
                    }
                    y += 20
                }
            }
            y += 20
        }

        // 8. The last 30 (7) days, or today by hour.
        var bars: [Double] = []
        var first = "", middle = "", last = ""
        if range == 1 {
            bars = (0..<24).map { $0 < m.hours.count ? m.hours[$0] : 0 }
            first = "0:00"; middle = "12:00"; last = L("现在", "now")
        } else {
            let days = Array(m.days.suffix(range))
            bars = days.map(\.usd)
            if !days.isEmpty { first = shortDay(days[0].day); middle = shortDay(days[days.count / 2].day); last = shortDay(days[days.count - 1].day) }
        }
        let total = bars.reduce(0, +)
        if draw {
            put(V3.sans(range == 1 ? L("今天每小时", "Today by hour") : L("最近 \(range) 天", "Last \(range) days"), 16, .semibold), padX, y)
            let right = range == 1 ? L("共 ", "total ") + fmtUSD(total) : L("日均 ", "avg ") + fmtUSD(bars.isEmpty ? 0 : total / Double(bars.count)) + L("", "/d")
            put(V3.mono(right, 11, .regular, V3.secondary), W - padX, y + 4, align: 2)
        }
        y += 34
        let chartH: CGFloat = 90
        if draw && !bars.isEmpty {
            let gap: CGFloat = 4
            let bw = (inner - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
            let maxU = max(bars.max() ?? 1, 0.01)
            let current = range == 1 ? Calendar.current.component(.hour, from: Date()) : bars.count - 1
            for (i, u) in bars.enumerated() {
                let h = u > 0 ? max(4, chartH * CGFloat(u / maxU)) : 2
                let r = NSRect(x: padX + CGFloat(i) * (bw + gap), y: y + chartH - h, width: bw, height: h)
                (i == current ? V3.today : u > 0 ? V3.bar : V3.barZero).setFill()
                NSBezierPath(roundedRect: r, xRadius: min(2, bw / 2), yRadius: min(2, bw / 2)).fill()
            }
            let ly = y + chartH + 8
            put(V3.mono(first, 10.5, .regular, V3.secondary), padX, ly)
            put(V3.mono(middle, 10.5, .regular, V3.secondary), padX + inner / 2, ly, align: 1)
            let now = range == 1 ? (current < bars.count ? bars[current] : 0) : (bars.last ?? 0)
            put(V3.mono(last + " · " + fmtUSD(now), 10.5, .medium, V3.workingText), W - padX, ly, align: 2)
        }
        y += chartH + 8 + 16 + 24

        // 9. One row: where the money comes from, the report window, and
        //    share the report of the range on top: 1 day the day's, 7 days the
        //    week's, 30 days the month's (user, 2026-11-11: 「7天，30天的弹窗应该是
        //    分享周报，分享月报」; right-click it: copy, other periods, the folder).
        let rowH: CGFloat = 36
        let shareText = V3.sans("⇪  " + shareLabel, 13, .semibold, V3.onInk)
        let shareR = NSRect(x: W - padX - shareText.size().width - 32, y: y, width: shareText.size().width + 32, height: rowH)
        let reportText = V3.sans(L("报告", "Reports"), 13, .medium)
        let reportR = NSRect(x: shareR.minX - 8 - reportText.size().width - 28, y: y, width: reportText.size().width + 28, height: rowH)
        if draw {
            let note = V3.mono(L("按 BLS 中位时薪折算", "At BLS median wages"), 10.5, .regular, V3.secondary)
            note.draw(with: NSRect(x: padX, y: y + rowH / 2 - 7, width: reportR.minX - 8 - padX, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            V3.control.setFill()
            NSBezierPath(roundedRect: reportR, xRadius: rowH / 2, yRadius: rowH / 2).fill()
            put(reportText, reportR.midX, reportR.midY - reportText.size().height / 2, align: 1)
            V3.ink.setFill()
            NSBezierPath(roundedRect: shareR, xRadius: rowH / 2, yRadius: rowH / 2).fill()
            put(shareText, shareR.midX, shareR.midY - shareText.size().height / 2, align: 1)
        }
        v3Hits.append(("reports", reportR))
        v3Hits.append(("export", shareR))
        y += rowH + 24
        return y
    }

    /// A roster card: black while at work, outlined while it needs you,
    /// grey at rest, faded when off (README 员工名册).
    private func rosterCard(_ r: NSRect, job: JobShare, status: String) {
        let busy = ["working", "happy", "fuming"].contains(status)
        let off = status == "off"
        let path = NSBezierPath(roundedRect: status == "waiting" ? r.insetBy(dx: 0.75, dy: 0.75) : r, xRadius: 18, yRadius: 18)
        (busy ? V3.ink : status == "waiting" ? V3.raised : V3.tile).setFill()
        path.fill()
        if status == "waiting" {
            V3.ink.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        if off { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        themeDango(NSRect(x: r.minX + 14, y: r.midY - 15, width: 36, height: 30), job: job.id, status: busy ? "working" : status == "sleeping" ? "sleeping" : "idle")
        NSGraphicsContext.restoreGraphicsState()
        let tx = r.minX + 60
        let titleInk = busy ? V3.onInk : off ? V3.secondary : V3.ink
        var x = tx
        if !off && status != "idle" && status != "sleeping" {
            V3.dot(status).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 20, width: 6, height: 6)).fill()
            x += 11
        }
        let title = V3.sans(job.name + " · " + statusName(status), 13, .medium, titleInk)
        title.draw(with: NSRect(x: x, y: r.minY + 14, width: r.maxX - 10 - x, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let sub = V3.mono(fmtHours(job.hours) + " · " + fmtUSD(job.usd), 11, .regular, busy ? V3.onInk.withAlphaComponent(0.6) : V3.secondary)
        put(sub, tx, r.minY + 35)
    }

    /// The share button, where the share menu and its right-click menu open.
    var exportButton: NSRect? { v3Hits.last { $0.0 == "export" }?.1 }

    /// The report the share button shares: the range on top's (1, 7, 30 days →
    /// the day's, this week's, this month's).
    var shareKind: String { range == 1 ? "day" : range == 7 ? "week" : "month" }
    var shareLabel: String {
        switch shareKind {
        case "week": return L("分享周报", "Share this week")
        case "month": return L("分享月报", "Share this month")
        default: return L("分享日报", "Share today")
        }
    }

    func v3MouseDown(_ p: NSPoint) {
        guard let (id, _) = v3Hits.last(where: { $0.1.contains(p) }) else { return }
        switch id {
        case "close":
            onCollapse?()
        case "expand":
            jobsOpen.toggle()
            onResize?()
        case "menu":
            if let e = NSApp.currentEvent { (NSApp.delegate as? App)?.popMenu(e, in: self) }
        case "reports":
            ReportWindow.show()
        case "boss":
            StoryWindow.show()
        case "export":
            (NSApp.delegate as? App)?.makeCard(kind: shareKind, shareFrom: exportButton.map { (self, $0) })
        default:
            if id.hasPrefix("range:"), let days = Int(id.dropFirst(6)), days != range {
                range = days
                UserDefaults.standard.set(days, forKey: "range")
                jobsOpen = false
                onResize?()
            }
        }
    }
}

// MARK: - The corner pet

extension PetView {
    /// Just the 团子, no card (user, 2026-11-07: 「就只放个团子…不需要这么大的
    /// 白色背景」); the rest of the view is room for its state's z z / ? /
    /// steam and the pill above it.
    var cardRect: NSRect { NSRect(x: (bounds.width - 84) / 2, y: 10, width: 84, height: 74) }

    func drawCard() {
        guard let m = model else { return }
        let box = cardRect
        // The current job's state in the office, else the pet's own mood.
        let mine = m.job.flatMap { j in m.office.first { $0.job.id == j.id } }.map { officeStatus($0, m) }
        let working = m.working > 0
        let status = forcedStatus ?? mine.flatMap { ["working", "waiting", "fuming", "happy"].contains($0) ? $0 : nil }
            ?? (working ? "working" : ["happy", "proud"].contains(m.mood) ? "happy" : m.mood == "sleepy" ? "sleeping" : "idle")
        // A soft shadow on the ground, then the 团子 bobbing slowly over it.
        let bob = CGFloat(3 * (1 - cos(t / 3 * 2 * .pi)) / 2)
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: box.midX - 34 + bob, y: box.minY - 5, width: 68 - 2 * bob, height: 11)), relativeCenterPosition: .zero)
        let face = box.offsetBy(dx: 0, dy: bob)
        Pose.time = t
        themeDango(face, job: m.job?.id ?? "", status: blinking(status, t) ? "sleeping" : status, pose: status)
        stateExtras(status, t, face)

        // A pill above it now and then: news, a settled turn, or today's
        // total while the pointer is on it.
        var text: NSAttributedString?
        if t < flashUntil {
            text = V3.sans(flashText, 11.5, .semibold, .white)
        } else if let rc = receipts.last {
            text = V3.mono("+" + fmtUSD(rc.usd) + " · " + rc.name, 11.5, .semibold, .white)
        } else if hovering {
            text = AB.join([V3.sans(L("今天 ", "Today "), 11.5, .medium, NSColor.white.withAlphaComponent(0.7)), V3.mono(fmtUSD(m.todayUSD), 11.5, .semibold, .white)])
        }
        if let text {
            let w = min(bounds.width - 8, text.size().width + 20), h: CGFloat = 22
            let pill = NSRect(x: (bounds.width - w) / 2, y: face.maxY + 12, width: w, height: h)
            NSColor(calibratedWhite: 0.1, alpha: 0.86).setFill()
            NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
            // A faint rim so it still reads on a dark wallpaper.
            NSColor.white.withAlphaComponent(0.16).setStroke()
            NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2, yRadius: h / 2).stroke()
            text.draw(with: NSRect(x: pill.minX + 10, y: pill.minY + 4, width: pill.width - 20, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The pointer is on the 团子.
    var hovering: Bool {
        guard let w = window else { return false }
        return hitRect.contains(convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }
}
