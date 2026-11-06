// The panel and the corner card from the 2026-10-30 UI handoff
// (dango-ui-handoff, README and tokens.json there): a white panel with the
// illustrated office on top — the design's room picture and role cut-outs,
// with the eyes drawn over them for each state; a job without a cut-out is
// drawn as the vector 团子 from the design's SVG. (The classic theme went
// on 2026-11-06, the vector office on 2026-11-07.)

import AppKit

// MARK: - Tokens (tokens.json; text greys at the accessible #6E6E73)

enum V3 {
    static let ink = color(hex: "#1C1C1C")
    static let surface = NSColor.white
    static let tile = color(hex: "#F6F6F6")
    static let control = color(hex: "#F4F4F4")
    static let line = color(hex: "#E6E6E8")
    static let secondary = color(hex: "#6E6E73")
    static let bar = color(hex: "#DADADA")
    static let barZero = color(hex: "#EDEDED")
    static let today = color(hex: "#16A34A")
    static let track = color(hex: "#E9E9E9")
    static let brand = color(hex: "#2F7BF5")
    static let workingText = color(hex: "#15803D")
    static let waitingText = color(hex: "#B45309")
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
        NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: c])
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

/// The design's accessory for each job it has drawn (README 原型角色和程序里的职业).
let vectorAccessory = ["data": "glasses", "swe": "beanie", "designer": "hairpin", "research": "pencil", "video": "headphones", "ops": "cap"]

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

private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

private func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

/// `body` clipped to an ellipse.
private func clipped(_ e: NSBezierPath, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    e.addClip()
    body()
    NSGraphicsContext.restoreGraphicsState()
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

/// The little things around a 团子 in a state (README): z z when asleep, a
/// blinking "?" when it needs you, steam when fuming. `box` is the 团子's.
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
            put(V3.mono("z", size, .regular, color(hex: "#8A8278").withAlphaComponent(CGFloat(alpha))), pt.x, flipped ? pt.y - size : pt.y)
        }
    case "waiting":
        let alpha = 0.65 + 0.35 * cos(t / 1.4 * 2 * .pi)
        let c = above(box.width + 0 * s, 8 * s)
        let r = NSRect(x: c.x - 10 * s, y: c.y - 10 * s, width: 20 * s, height: 20 * s)
        NSColor.white.withAlphaComponent(CGFloat(alpha)).setFill()
        let o = NSBezierPath(ovalIn: r)
        o.fill()
        V3.outline.withAlphaComponent(CGFloat(alpha)).setStroke()
        o.lineWidth = 1.5 * s
        o.stroke()
        let q = V3.mono("?", 12 * s, .semibold, color(hex: "#D97706").withAlphaComponent(CGFloat(alpha)))
        put(q, r.midX, r.midY - q.size().height / 2, align: 1)
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

// MARK: - The vector 团子 (design A, the 120 × 110 drawing)

/// A 团子 in `box` (120 × 110 proportions): body, the eyes for its state,
/// and the job's accessory. No motion or extras; see `moving`, `stateExtras`.
func drawVectorDango(_ box: NSRect, status: String, acc: String?, shadow: Bool = true) {
    inDrawing(box, 120, 110) {
        if shadow { fill(ellipse(60, 106, 42, 4), V3.body.withAlphaComponent(0.1)) }
        fill(svgPath("M14 86C6 60 18 16 58 12C98 8 114 54 106 86C100 102 22 104 14 86Z"), V3.body, stroke: V3.outline, width: 3.5)
        strokePath("M27 32C33 22 45 16 55 17", color(hex: "#6E6E6E"), 8)
        // Hats sit behind the eyes, as in the design's dashboard.
        switch acc {
        case "beanie":
            fill(svgPath("M12 44C18 0 102 0 108 44Z"), color(hex: "#B894F0"), stroke: V3.outline, width: 3)
            strokePath("M32 30c2-8 4-12 6-16M50 24c1-8 2-12 3-16M68 24c-1-8-2-12-3-16M86 30c-2-8-4-12-6-16", color(hex: "#A77FE6"), 2.5)
            fill(rrect(10, 38, 100, 13, 6.5), color(hex: "#A77FE6"), stroke: V3.outline, width: 3)
        case "beret":
            fill(svgPath("M4 38C10 12 58 2 104 20C100 32 58 42 4 38Z"), color(hex: "#F26B2B"), stroke: V3.outline, width: 3)
            strokePath("M62 6l3-5", V3.outline, 4)
        case "cap":
            fill(svgPath("M16 44C22 10 98 10 104 44Z"), color(hex: "#3BC4C4"), stroke: V3.outline, width: 3)
            fill(svgPath("M4 44H104C110 44 112 50 106 52H8C2 52 0 46 4 44Z"), color(hex: "#2FA9A9"), stroke: V3.outline, width: 3)
        default:
            break
        }
        vectorEyes(status)
        switch acc {
        case "glasses":
            for (r, w, c) in [(rrect(23, 36, 42, 44, 15), 8.0, V3.outline), (rrect(57, 34, 44, 46, 15), 8.0, V3.outline),
                              (rrect(23, 36, 42, 44, 15), 4.5, color(hex: "#5EE3B0")), (rrect(57, 34, 44, 46, 15), 4.5, color(hex: "#5EE3B0"))] {
                r.lineWidth = CGFloat(w)
                c.setStroke()
                r.stroke()
            }
            strokePath("M6 50L23 56", V3.outline, 8)
            strokePath("M6 50L23 56", color(hex: "#5EE3B0"), 4.5)
        case "pencil":
            NSGraphicsContext.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: 100, yBy: 62)
            tr.rotate(byDegrees: 32)
            tr.translateX(by: -100, yBy: -62)
            tr.concat()
            fill(rrect(95, 44, 10, 38, 2), color(hex: "#F7C948"), stroke: V3.outline, width: 2.5)
            fill(svgPath("M95 44L100 32L105 44Z"), color(hex: "#F3D9BC"), stroke: V3.outline, width: 2.5)
            fill(NSBezierPath(rect: NSRect(x: 95, y: 78, width: 10, height: 7)), color(hex: "#F58FA8"), stroke: V3.outline, width: 2.5)
            NSGraphicsContext.restoreGraphicsState()
        case "headphones":
            strokePath("M18 54C18 14 102 14 102 54", V3.outline, 10)
            strokePath("M18 54C18 14 102 14 102 54", V3.brand, 5)
            fill(rrect(6, 44, 18, 26, 7), V3.brand, stroke: V3.outline, width: 3)
            fill(rrect(96, 42, 18, 26, 7), V3.brand, stroke: V3.outline, width: 3)
        case "hairpin":
            strokePath("M80 12l24 14M82 26l22-14", V3.outline, 8)
            strokePath("M80 12l24 14M82 26l22-14", color(hex: "#E8503A"), 4.5)
        default:
            break
        }
    }
}

/// The eyes for a state (the design's E02 / E06 / S01 / E07 / E04 / E09).
private func vectorEyes(_ status: String) {
    let white = NSColor.white
    func eye(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        let e = ellipse(cx, cy, rx, ry)
        fill(e, white, stroke: V3.outline, width: 3)
        return e
    }
    func pupil(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) { fill(ellipse(cx, cy, rx, ry), V3.outline) }
    func glint(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) { fill(ellipse(cx, cy, r, r), white) }
    func lid(_ e: NSBezierPath, _ d: String) { clipped(e) { fill(svgPath(d), V3.body) } }
    switch status {
    case "working":
        let l = eye(44, 59, 17, 20), r = eye(78, 57, 18, 21)
        pupil(47, 63, 6.5, 8.5); pupil(80, 61, 6.5, 8.5)
        glint(45, 59, 2.2); glint(78, 57, 2.2)
        lid(l, "M20 26L64 26L64 56L20 44Z"); lid(r, "M100 24L58 24L58 54L100 42Z")
    case "happy":
        strokePath("M26 62c8-12 28-12 36 0", white, 5)
        strokePath("M60 60c8-12 28-12 36 0", white, 5)
    case "fuming":
        fill(ellipse(60, 27, 34, 13), color(hex: "#C0392B").withAlphaComponent(0.6))
        let l = eye(44, 59, 17, 20), r = eye(78, 57, 18, 21)
        pupil(46, 62, 6.5, 8.5); pupil(79, 60, 6.5, 8.5)
        lid(l, "M18 22L66 22L66 60L18 42Z"); lid(r, "M102 20L58 20L58 58L102 40Z")
    case "waiting":
        let l = eye(44, 62, 19, 21)
        _ = eye(79, 64, 15, 17)
        pupil(38, 55, 6.5, 8.5); pupil(84, 69, 5.5, 7.5)
        glint(36, 51, 2.2); glint(82, 65, 2)
        lid(l, "M20 40L66 40L66 54L20 46Z")
    case "sleeping":
        strokePath("M28 66c6 8 26 8 32 0", white, 5)
        strokePath("M62 64c6 8 26 8 32 0", white, 5)
    default: // idle, off
        let l = eye(44, 60, 16, 18), r = eye(78, 58, 17, 19)
        pupil(50, 63, 6, 8); pupil(84, 61, 6.5, 8.5)
        lid(l, "M20 30L66 30L66 52L20 52Z"); lid(r, "M58 28L100 28L100 50L58 50Z")
    }
}

// MARK: - Design B: the room picture and the role cut-outs

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

/// A role cut-out: its file, size in pixels and the two eyes (cx, cy, rx,
/// ry), from the design's eyes.json, for the jobs the design has drawn.
struct Role { var file: String; var w: CGFloat; var h: CGFloat; var l: [CGFloat]; var r: [CGFloat] }

let roles: [String: Role] = [
    "designer": Role(file: "R02", w: 278, h: 214, l: [103, 124, 42, 46], r: [188, 110, 39, 46]),
    "video": Role(file: "R03", w: 320, h: 241, l: [150, 156, 42, 42], r: [232, 142, 38, 44]),
    "data": Role(file: "R04", w: 296, h: 226, l: [120, 128, 42, 41], r: [221, 116, 39, 45]),
    "swe": Role(file: "R06", w: 299, h: 241, l: [135, 159, 45, 45], r: [224, 140, 40, 47]),
    "ops": Role(file: "R07", w: 307, h: 247, l: [127, 161, 43, 44], r: [217, 148, 42, 48]),
    "qa": Role(file: "R09", w: 294, h: 248, l: [119, 158, 45, 46], r: [210, 147, 40, 47]),
    "research": Role(file: "R11", w: 289, h: 224, l: [112, 134, 42, 44], r: [200, 120, 40, 46]),
]

/// A job's 团子 at `box` (its feet on the box's bottom): the
/// cut-out with the state's eyes drawn over it, or the vector one for jobs
/// the design has not drawn.
func drawRoleDango(_ box: NSRect, job: String, status: String) {
    guard let role = roles[job], let img = themeImage(role.file) else {
        let h = box.width * 110 / 120
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        drawVectorDango(NSRect(x: box.minX, y: flipped ? box.maxY - h : box.minY, width: box.width, height: h), status: status, acc: vectorAccessory[job])
        return
    }
    img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    inDrawing(box, role.w, role.h) { roleEyes(role, status) }
}

/// The state's eyes over a cut-out (the design's RoomRef formulas).
private func roleEyes(_ role: Role, _ status: String) {
    let L = role.l, R = role.r
    let sw = (role.w / 24).rounded(), swArc = (role.w / 24).rounded() * 1.2
    let prx = (L[2] * 0.4).rounded(), pry = (L[3] * 0.42).rounded(), prs = (L[2] * 0.4).rounded() * 0.85
    let gr = (L[2] * 0.14).rounded()
    let lidInk = color(hex: "#1C1C1C")
    func eye(_ e: [CGFloat], _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        let p = ellipse(e[0], e[1], rx, ry)
        fill(p, .white, stroke: V3.outline, width: sw)
        return p
    }
    func cover(_ e: [CGFloat]) { fill(ellipse(e[0], e[1], e[2] + 11, e[3] + 11), lidInk) }
    func pupil(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) { fill(ellipse(x, y, rx, ry), V3.outline) }
    func glint(_ x: CGFloat, _ y: CGFloat) { fill(ellipse(x - prx * 0.3, y - pry * 0.35, gr, gr), .white) }
    func lid(_ e: [CGFloat], _ innerRight: Bool, _ outer: CGFloat, _ inner: CGFloat, clip: NSBezierPath) {
        let x0 = e[0] - e[2] - 8, x1 = e[0] + e[2] + 8, y0 = e[1] - e[3] - 8
        let yO = e[1] - e[3] + outer * 2 * e[3], yI = e[1] - e[3] + inner * 2 * e[3]
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0, y: y0))
        p.line(to: NSPoint(x: x1, y: y0))
        p.line(to: NSPoint(x: x1, y: innerRight ? yI : yO))
        p.line(to: NSPoint(x: x0, y: innerRight ? yO : yI))
        p.close()
        clipped(clip) { fill(p, lidInk) }
    }
    func arc(_ e: [CGFloat], up: Bool) {
        let k: CGFloat = up ? -1.1 : 0.9, off: CGFloat = up ? 0.15 : -0.15
        let p = NSBezierPath()
        let a = NSPoint(x: e[0] - 0.72 * e[2], y: e[1] + off * e[3]), b = NSPoint(x: e[0] + 0.72 * e[2], y: e[1] + off * e[3])
        let q = NSPoint(x: e[0], y: e[1] + k * e[3])
        p.move(to: a)
        p.curve(to: b, controlPoint1: NSPoint(x: a.x + 2 / 3 * (q.x - a.x), y: a.y + 2 / 3 * (q.y - a.y)),
                controlPoint2: NSPoint(x: b.x + 2 / 3 * (q.x - b.x), y: b.y + 2 / 3 * (q.y - b.y)))
        p.lineWidth = swArc
        p.lineCapStyle = .round
        NSColor.white.setStroke()
        p.stroke()
    }
    switch status {
    case "working":
        let l = eye(L, L[2] + 5, L[3] + 5), r = eye(R, R[2] + 5, R[3] + 5)
        let pl = NSPoint(x: L[0] + 0.1 * L[2], y: L[1] + 0.2 * L[3]), pr = NSPoint(x: R[0] + 0.1 * R[2], y: R[1] + 0.2 * R[3])
        pupil(pl.x, pl.y, prx, pry); pupil(pr.x, pr.y, prx, pry)
        glint(pl.x, pl.y); glint(pr.x, pr.y)
        lid(L, true, 0.2, 0.52, clip: l); lid(R, false, 0.2, 0.52, clip: r)
    case "fuming":
        fill(ellipse((L[0] + R[0]) / 2, min(L[1], R[1]) - 1.15 * L[3], ((R[0] - L[0]) * 0.75).rounded(), (L[3] * 0.4).rounded()),
             color(hex: "#C0392B").withAlphaComponent(0.55))
        let l = eye(L, L[2] + 5, L[3] + 5), r = eye(R, R[2] + 5, R[3] + 5)
        pupil(L[0], L[1] + 0.08 * L[3], prx, pry); pupil(R[0], R[1] + 0.08 * R[3], prx, pry)
        lid(L, true, 0.12, 0.66, clip: l); lid(R, false, 0.12, 0.66, clip: r)
    case "waiting":
        cover(L); cover(R)
        let l = eye(L, (L[2] * 1.18).rounded(), (L[3] * 1.12).rounded())
        _ = eye(R, (R[2] * 0.82).rounded(), (R[3] * 0.82).rounded())
        let pl = NSPoint(x: L[0] - 0.3 * L[2], y: L[1] - 0.3 * L[3])
        pupil(pl.x, pl.y, prx, pry); pupil(R[0] + 0.3 * R[2], R[1] + 0.35 * R[3], prs, prs)
        glint(pl.x, pl.y)
        lid(L, true, 0.3, 0.46, clip: l)
    case "happy":
        cover(L); cover(R)
        arc(L, up: true); arc(R, up: true)
    case "sleeping":
        cover(L); cover(R)
        arc(L, up: false); arc(R, up: false)
    default: // idle, off
        let l = eye(L, L[2] + 5, L[3] + 5), r = eye(R, R[2] + 5, R[3] + 5)
        pupil(L[0] + 0.35 * L[2], L[1] + 0.12 * L[3], prx, pry); pupil(R[0] + 0.3 * R[2], R[1] + 0.12 * R[3], prx, pry)
        lid(L, true, 0.48, 0.48, clip: l); lid(R, false, 0.48, 0.48, clip: r)
    }
}

/// A job's 团子 fitted to `box`: its cut-out where there is one, else the
/// vector one.
func themeDango(_ box: NSRect, job: String, status: String) {
    if let role = roles[job], themeImage(role.file) != nil {
        let h = box.width * role.h / role.w
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let r = NSRect(x: box.minX, y: flipped ? box.midY - h / 2 : box.midY - h / 2, width: box.width, height: h)
        drawRoleDango(r, job: job, status: status)
    } else {
        let h = box.width * 110 / 120
        drawVectorDango(NSRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h), status: status, acc: vectorAccessory[job], shadow: false)
    }
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

    /// Each one's place now and the walk to it: from, to, when it set off.
    private struct Walk { var from: NSRect; var to: NSRect; var start: Double }
    private var walks: [String: Walk] = [:]

    func tick(_ dt: Double) { t += dt }

    /// Where a 团子 stands, `w` wide, its feet at `bottom`.
    private func feet(_ x: CGFloat, bottom: CGFloat, w: CGFloat) -> NSRect { NSRect(x: x, y: bottom - w * 110 / 120, width: w, height: w * 110 / 120) }

    /// Who goes where: two desks for working / happy / fuming, a place to
    /// stand for waiting, the sofa's three seats and then the door for idle
    /// and sleeping; off is outside.
    private func arrangement() -> [(Occupant, String, NSRect)] {
        let all = occupants.map { ($0, officeStatus($0, model)) }
        let desk = all.filter { ["working", "happy", "fuming"].contains($0.1) }.prefix(2)
        let stand = all.filter { $0.1 == "waiting" }.prefix(1)
        let lounge = all.filter { ["idle", "sleeping"].contains($0.1) }.prefix(3)
        var out: [(Occupant, String, NSRect)] = []
        let desks: [NSRect] = [feet(218, bottom: 126, w: 70), feet(318, bottom: 126, w: 70)]
        for (i, (o, s)) in desk.enumerated() { out.append((o, s, desks[i])) }
        for (o, s) in stand { out.append((o, s, feet(268, bottom: 118, w: 74))) }
        let seats: [NSRect] = [feet(16, bottom: 136, w: 74), feet(78, bottom: 138, w: 74), feet(138, bottom: 136, w: 74)]
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
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).addClip()
        let people = arrangement()
        walks = walks.filter { id, _ in people.contains { $0.0.job.id == id } }
        drawRoom(people)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDango(_ o: Occupant, _ s: String, _ box: NSRect, phase: Double) {
        let eyes = blinking(s, t + phase * 7) ? "sleeping" : s
        moving(s, t + phase, box) {
            drawRoleDango(box, job: o.job.id, status: eyes)
        }
        stateExtras(s, t + phase, box)
    }

    // The design's picture, the cut-outs, and the picture's sofa seat and
    // desk again in front of them.
    private func drawRoom(_ people: [(Occupant, String, NSRect)]) {
        let room = themeImage("room")
        if let room {
            room.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            color(hex: "#FBF3E4").setFill()
            bounds.fill()
        }
        for (i, (o, s, place)) in people.enumerated() {
            let w = place.width
            let h = roles[o.job.id].map { w * $0.h / $0.w } ?? w * 110 / 120
            let at = now(o.job.id, NSRect(x: place.minX, y: place.maxY - h, width: w, height: h))
            drawDango(o, s, at, phase: Double(i) * 0.41)
        }
        if let room {
            for front in [NSRect(x: 0, y: 130, width: 206, height: 48), NSRect(x: 210, y: 118, width: 182, height: 60)] {
                let k = room.size.width / 392
                let src = NSRect(x: front.minX * k, y: room.size.height - front.maxY * k, width: front.width * k, height: front.height * k)
                room.draw(in: front, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
        }
        // The two laptops on the desk.
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rad: CGFloat, _ c: String) { fill(rrect(x, y, w, h, rad), color(hex: c)) }
        r(236, 120, 42, 18, 3, "#9AA0A8"); r(240, 124, 34, 10, 2, "#E9EEF2")
        for (k, h) in [3.0, 6, 4, 7].enumerated() { r(245 + CGFloat(k) * 6, 133 - CGFloat(h), 3, CGFloat(h), 0, k == 3 ? "#2E8B57" : "#5FBF84") }
        r(332, 120, 42, 18, 3, "#9AA0A8"); r(336, 124, 34, 10, 2, "#E9EEF2")
        strokePath("M345 128l-3 3 3 3M357 128l3 3-3 3", color(hex: "#5B6B8C"), 1.5)
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
            let mark = NSMutableAttributedString(attributedString: V3.sans("DONGO", 17, .heavy))
            mark.addAttribute(.kern, value: -0.34, range: NSRange(location: 0, length: mark.length))
            put(mark, padX, y + 8)
            let mx = padX + mark.size().width + 4
            inDrawing(NSRect(x: mx, y: y + 12, width: 12, height: 12), 16, 16) { strokePath("M3 3l4 3M2 8h5M3 13l4-3", V3.brand, 2.4) }
            put(V3.mono(L("第 \(m.daysTogether) 天", "day \(m.daysTogether)"), 11, .regular, V3.secondary), mx + 22, y + 12)
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

        // 3. Today's number, whether it is the best day, the character's line.
        let beating = m.recordUSD > 0 && m.todayUSD + 1e-9 >= m.recordUSD && m.todayUSD > 0
        let hero = V3.mono(fmtUSD(m.todayUSD), 56, .semibold)
        if draw { put(hero, W / 2, y, align: 1) }
        y += hero.size().height + 2
        let sub = V3.mono(L("今天的产出", "Today's output") + (beating ? L(" · 单日纪录", " · best day") : ""), 12, .regular, V3.secondary)
        if draw {
            let x0 = W / 2 - (sub.size().width + 12) / 2
            V3.today.setFill()
            NSBezierPath(ovalIn: NSRect(x: x0, y: y + 5, width: 6, height: 6)).fill()
            put(sub, x0 + 12, y)
        }
        y += sub.size().height + 8
        if !m.line.isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let line = NSMutableAttributedString(attributedString: V3.sans(m.line, 14, .medium))
            line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
            let fit = line.boundingRect(with: NSSize(width: 280, height: 200), options: [.usesLineFragmentOrigin])
            if draw { line.draw(with: NSRect(x: W / 2 - 140, y: y, width: 280, height: ceil(fit.height)), options: [.usesLineFragmentOrigin]) }
            y += ceil(fit.height)
        }
        y += 20

        // 4. 1D · 7D · 30D.
        let labels = [(1, L("1 天", "1D")), (7, L("7 天", "7D")), (30, L("30 天", "30D"))]
        let widths = labels.map { V3.mono($0.1, 12, .medium).size().width + 32 }
        let groupW = widths.reduce(0, +) + 2 * 2 + 6
        var x = W / 2 - groupW / 2
        if draw {
            V3.control.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: groupW, height: 36), xRadius: 18, yRadius: 18).fill()
        }
        x += 3
        for (i, (days, label)) in labels.enumerated() {
            let r = NSRect(x: x, y: y + 3, width: widths[i], height: 30)
            if draw {
                if days == range {
                    NSGraphicsContext.saveGraphicsState()
                    let sh = NSShadow()
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.08)
                    sh.shadowBlurRadius = 3
                    sh.shadowOffset = NSSize(width: 0, height: -1)
                    sh.set()
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 15, yRadius: 15).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let s = V3.mono(label, 12, .medium, days == range ? V3.ink : V3.secondary)
                put(s, r.midX, r.midY - s.size().height / 2, align: 1)
            }
            v3Hits.append(("range:\(days)", r))
            x += widths[i] + 2
        }
        y += 36 + 20

        // 5. Four numbers.
        let tiles: [(String, Double, Double, Double)] = [(L("今日", "Today"), m.todayUSD, m.todayHours, m.todayCost), (L("本周", "This week"), m.weekUSD, m.weekHours, m.weekCost),
                                                          (L("本月", "This month"), m.monthUSD, m.monthHours, m.monthCost), (L("总计", "Total"), m.totalUSD, m.totalHours, m.totalCost)]
        let tw = (inner - 10) / 2, th: CGFloat = 92
        for (i, t) in tiles.enumerated() {
            let r = NSRect(x: padX + CGFloat(i % 2) * (tw + 10), y: y + CGFloat(i / 2) * (th + 10), width: tw, height: th)
            guard draw else { continue }
            V3.tile.setFill()
            NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
            put(V3.mono(t.0, 11, .regular, V3.secondary), r.minX + 18, r.minY + 16)
            put(V3.mono(fmtUSD(t.1), 24, .semibold), r.minX + 18, r.minY + 33)
            let lev = t.3 >= 0.01 ? "\(fmtUSD(t.3)) · " + String(format: "%.1f×", t.1 / t.3) : fmtHours(t.2)
            put(V3.mono(lev, 11, .regular, V3.secondary), r.minX + 18, r.minY + 64)
        }
        y += th * 2 + 10 + 20

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

        // 7. Claude Code and Codex.
        let toolsSel = (range == 1 ? m.tools1 : range == 7 ? m.tools7 : m.tools).filter { $0.usd > 0 }
        if !toolsSel.isEmpty {
            if draw {
                put(V3.sans("Claude Code " + L("与", "and") + " Codex", 16, .semibold), padX, y)
                put(V3.mono(L("\(range) 天 · 产出 ÷ 花费", "\(range)D · output ÷ cost"), 11, .regular, V3.secondary), W - padX, y + 4, align: 2)
            }
            y += 30
            if draw {
                V3.track.setFill()
                NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: inner, height: 6), xRadius: 3, yRadius: 3).fill()
                V3.ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: max(6, inner * CGFloat(toolsSel[0].share)), height: 6), xRadius: 3, yRadius: 3).fill()
            }
            y += 14
            if draw {
                for (k, t) in toolsSel.prefix(2).enumerated() {
                    let s = NSMutableAttributedString(attributedString: V3.mono(t.name + " ", 11.5, .regular))
                    s.append(V3.mono(String(format: "%.0f%%", t.share * 100) + (t.cost >= 0.01 ? " · " + String(format: "%.1f×", t.usd / t.cost) : ""), 11.5, .regular, V3.secondary))
                    put(s, k == 0 ? padX : W - padX, y, align: k == 0 ? 0 : 2)
                }
            }
            y += 20 + 20
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

        // 9. Export: a square that opens the report window, the main button, a note.
        let share = NSRect(x: padX, y: y, width: 60, height: 56)
        let main = NSRect(x: padX + 70, y: y, width: inner - 70, height: 56)
        if draw {
            V3.control.setFill()
            NSBezierPath(roundedRect: share, xRadius: 20, yRadius: 20).fill()
            let up = NSBezierPath()
            up.move(to: NSPoint(x: share.midX, y: share.midY - 8))
            up.line(to: NSPoint(x: share.midX, y: share.midY + 3))
            up.move(to: NSPoint(x: share.midX - 4, y: share.midY - 4))
            up.line(to: NSPoint(x: share.midX, y: share.midY - 8))
            up.line(to: NSPoint(x: share.midX + 4, y: share.midY - 4))
            up.move(to: NSPoint(x: share.midX - 7, y: share.midY))
            up.line(to: NSPoint(x: share.midX - 7, y: share.midY + 8))
            up.line(to: NSPoint(x: share.midX + 7, y: share.midY + 8))
            up.line(to: NSPoint(x: share.midX + 7, y: share.midY))
            up.lineWidth = 1.8
            up.lineCapStyle = .round
            up.lineJoinStyle = .round
            V3.ink.setStroke()
            up.stroke()
            V3.ink.setFill()
            NSBezierPath(roundedRect: main, xRadius: 20, yRadius: 20).fill()
            // The right end is a ▾ for the week, month and year (and the last ones).
            let label = V3.sans("✓  " + L("导出今日日报", "Export today's report"), 15, .semibold, .white)
            put(label, main.midX - 22, main.midY - label.size().height / 2, align: 1)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x: main.maxX - 52, y: main.minY + 14, width: 1, height: main.height - 28).fill()
            let chev = NSBezierPath()
            chev.move(to: NSPoint(x: main.maxX - 31, y: main.midY - 2.5))
            chev.line(to: NSPoint(x: main.maxX - 26, y: main.midY + 2.5))
            chev.line(to: NSPoint(x: main.maxX - 21, y: main.midY - 2.5))
            chev.lineWidth = 1.8
            chev.lineCapStyle = .round
            chev.lineJoinStyle = .round
            NSColor.white.setStroke()
            chev.stroke()
        }
        v3Hits.append(("folder", share))
        v3Hits.append(("export", NSRect(x: main.minX, y: main.minY, width: main.width - 52, height: main.height)))
        v3Hits.append(("exportMenu", NSRect(x: main.maxX - 52, y: main.minY, width: 52, height: main.height)))
        y += 56 + 14
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let note = NSMutableAttributedString(attributedString: V3.mono("~/Pictures/DONGO · " + L("周报 月报 年报点 ▾", "more under ▾")
            + " · " + L("BLS 中位时薪折算", "BLS median wages"), 10.5, .regular, V3.secondary))
        note.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: note.length))
        let noteH = ceil(note.boundingRect(with: NSSize(width: inner, height: 100), options: [.usesLineFragmentOrigin]).height)
        if draw { note.draw(with: NSRect(x: padX, y: y, width: inner, height: noteH), options: [.usesLineFragmentOrigin]) }
        y += noteH + 24
        return y
    }

    /// A roster card: black while at work, outlined while it needs you,
    /// grey at rest, faded when off (README 员工名册).
    private func rosterCard(_ r: NSRect, job: JobShare, status: String) {
        let busy = ["working", "happy", "fuming"].contains(status)
        let off = status == "off"
        let path = NSBezierPath(roundedRect: status == "waiting" ? r.insetBy(dx: 0.75, dy: 0.75) : r, xRadius: 18, yRadius: 18)
        (busy ? V3.ink : status == "waiting" ? NSColor.white : V3.tile).setFill()
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
        let titleInk = busy ? NSColor.white : off ? V3.secondary : V3.ink
        var x = tx
        if !off && status != "idle" && status != "sleeping" {
            V3.dot(status).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 20, width: 6, height: 6)).fill()
            x += 11
        }
        let title = V3.sans(job.name + " · " + statusName(status), 13, .medium, titleInk)
        title.draw(with: NSRect(x: x, y: r.minY + 14, width: r.maxX - 10 - x, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let sub = V3.mono(fmtHours(job.hours) + " · " + fmtUSD(job.usd), 11, .regular, busy ? NSColor.white.withAlphaComponent(0.6) : V3.secondary)
        put(sub, tx, r.minY + 35)
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
        case "folder":
            ReportWindow.show()
        case "export":
            (NSApp.delegate as? App)?.makeCard(kind: "day")
        case "exportMenu":
            if let app = NSApp.delegate as? App, let r = v3Hits.last(where: { $0.0 == "exportMenu" })?.1 {
                app.exportMenu().popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 4), in: self)
            }
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

// MARK: - The corner card (shared/widget-working)

extension PetView {
    /// The card, 300 × 100 with room for its shadow.
    var cardRect: NSRect { NSRect(x: 6, y: 10, width: bounds.width - 14, height: 84) }

    func drawCard() {
        guard let m = model else { return }
        let card = cardRect
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.10)
        sh.shadowBlurRadius = 12
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.04).setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        edge.lineWidth = 1
        edge.stroke()

        // The 团子: the current job's, in the pet's state, bobbing slowly.
        // The current job's state in the office, else the pet's own mood.
        let mine = m.job.flatMap { j in m.office.first { $0.job.id == j.id } }.map { officeStatus($0, m) }
        let working = m.working > 0
        let status = mine.flatMap { ["working", "waiting", "fuming", "happy"].contains($0) ? $0 : nil }
            ?? (working ? "working" : ["happy", "proud"].contains(m.mood) ? "happy" : m.mood == "sleepy" ? "sleeping" : "idle")
        let bob = CGFloat(-3 * (1 - cos(t / 3 * 2 * .pi)) / 2)
        let face = NSRect(x: card.minX + 10, y: card.midY - 26.5 - bob, width: 58, height: 53)
        themeDango(face, job: m.job?.id ?? "", status: blinking(status, t) ? "sleeping" : status)
        stateExtras(status, t, face)

        let x0 = face.maxX + 10, x1 = card.maxX - 14
        let label = V3.mono(L("今天", "Today"), 11, .regular, V3.secondary)
        let usd = V3.mono(fmtUSD(m.todayUSD), 25, .semibold)
        let top = card.minY + 43
        put(usd, x0 + label.size().width + 6, top)
        put(label, x0, top + 4)
        let beating = m.recordUSD > 0 && m.todayUSD + 1e-9 >= m.recordUSD && m.todayUSD > 0
        if beating {
            let rec = V3.mono(L("纪录", "Best"), 10.5, .medium, V3.today)
            put(rec, x1, top + 5, align: 2)
            V3.today.setFill()
            NSBezierPath(ovalIn: NSRect(x: x1 - rec.size().width - 10, y: top + 8, width: 6, height: 6)).fill()
        }
        // The middle line: a flash or a receipt for a moment, else who it is being.
        let lev = m.todayCost >= 0.01 ? " · " + String(format: "%.1f×", m.todayUSD / m.todayCost) : ""
        var middle = V3.sans((m.job.map { m.name + L("在当", " as ") + $0.name } ?? m.line) + lev, 12, .medium)
        if t < flashUntil {
            middle = V3.sans(flashText, 12, .semibold, V3.workingText)
        } else if let rc = receipts.last {
            middle = V3.mono("+" + fmtUSD(rc.usd) + " · " + rc.name, 12, .medium, V3.workingText)
        }
        middle.draw(with: NSRect(x: x0, y: card.minY + 26, width: x1 - x0, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let states = m.office.map { officeStatus($0, m) }
        let c = { (set: [String]) in states.filter { set.contains($0) }.count }
        let counts = [(c(["working", "happy", "fuming"]), L("在干", "working")), (c(["waiting"]), L("等你批准", "need you")), (c(["idle", "sleeping"]), L("摸鱼", "slacking"))]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        put(V3.mono(counts, 10.5, .regular, V3.secondary), x0, card.minY + 11)
    }
}
