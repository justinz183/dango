// ABTI 老板人格 and the reports (the 2026-10-31 handoff "dango-abti-handoff"):
// the boss card in Chinese and English, the 16-type gallery, the two
// explainer pages, the four 4:5 share images and the report window. The
// numbers come from `dango abti --json` / `dango abti --report KIND`
// (crates/daemon/src/abti.rs); the words from assets/abti.json; the pictures
// from apps/widget/assets/abti. Pages are flipped views drawn at the
// design's point sizes and exported at 2×.

import AppKit

// MARK: - JSON

/// A JSON value with forgiving lookups.
struct JV {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }
    subscript(_ k: String) -> JV { JV((raw as? [String: Any])?[k]) }
    subscript(_ i: Int) -> JV { JV((raw as? [Any]).flatMap { i >= 0 && i < $0.count ? $0[i] : nil }) }
    var s: String { raw as? String ?? (raw as? NSNumber)?.stringValue ?? "" }
    var d: Double { (raw as? NSNumber)?.doubleValue ?? Double(s) ?? 0 }
    var i: Int { Int(d.rounded()) }
    var arr: [JV] { (raw as? [Any])?.map(JV.init) ?? [] }
    var isNull: Bool { raw == nil }
    var dict: [String: JV] { ((raw as? [String: Any]) ?? [:]).mapValues(JV.init) }

    static func load(_ path: String) -> JV {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return JV(nil) }
        return JV(try? JSONSerialization.jsonObject(with: d))
    }

    static func parse(_ d: Data) -> JV { JV(try? JSONSerialization.jsonObject(with: d)) }
}

// MARK: - Pictures and words

/// The ABTI pictures: in the app, next to a checkout, or $DANGO_ASSETS/abti.
let abtiAssets: URL? = {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let e = ProcessInfo.processInfo.environment["DANGO_ASSETS"] { dirs.append(URL(fileURLWithPath: e).appendingPathComponent("abti")) }
    if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("abti")) }
    dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("apps/widget/assets/abti"))
    dirs.append(URL(fileURLWithPath: "/Applications/Dango.app/Contents/Resources/abti"))
    return dirs.first { fm.fileExists(atPath: $0.appendingPathComponent("scene").path) }
}()

/// assets/abti.json: the types, tiers and roles, for the gallery and the explainers.
let abtiConfig: JV = {
    let fm = FileManager.default
    for p in [abtiAssets?.appendingPathComponent("abti.json").path, fm.currentDirectoryPath + "/assets/abti.json"].compactMap({ $0 }) where fm.fileExists(atPath: p) {
        return JV.load(p)
    }
    return JV(nil)
}()

private var abtiImages: [String: NSImage] = [:]

/// "scene/T-HBGO", "icon/T-MFGO", "hidden/H1-doctor".
func abtiImage(_ name: String) -> NSImage? {
    if let i = abtiImages[name] { return i }
    guard !name.isEmpty, let url = abtiAssets?.appendingPathComponent(name + ".png"), let i = NSImage(contentsOf: url) else { return nil }
    abtiImages[name] = i
    return i
}

/// A crew entry's little 团子: a hidden one's picture, or the role ("R06")
/// put together from the design pack like everywhere else (theme.swift).
func roleArt(_ art: String) -> NSImage? {
    if art.hasPrefix("H") { return abtiImage("hidden/" + art) }
    return art.hasPrefix("R") ? packPicture(art) : nil
}

/// A config entry's words in the language.
/// "工作室级" / "Studio tier" for a company size named in any language.
func scalePill(_ named: String) -> String {
    let tier = abtiConfig["scale_tiers"].arr.first { [$0["name_zh"].s, $0["name_en"].s, cw($0, "name")].contains(named) }
    let n = tier.map { cw($0, "name") } ?? named
    return L(n + "级", n + " tier")
}

func cw(_ v: JV, _ k: String) -> String {
    let zh = v[k + "_zh"].s, en = v[k + "_en"].s
    return L(zh, en.isEmpty ? zh : en)
}

// MARK: - Words in the page's language (the result carries ids and numbers)

enum ABText {
    static var types: JV { abtiConfig["types"] }
    static func typeName(_ code: String) -> String { cw(types[code], "name") }
    static func roast(_ code: String) -> String { cw(types[code], "roast") }
    static func matchLine(_ code: String) -> String { cw(types[code], "match_line") }
    static func scale(_ i: Int) -> JV { abtiConfig["scale_tiers"][i] }
    /// A size threshold, short: 10000 → "10k", 10000000 → "10M".
    static func shortUSD(_ v: Double) -> String { v >= 1e6 ? "\(Int(v / 1e6))M" : v >= 1e3 ? "\(Int(v / 1e3))k" : "\(Int(v))" }
    static func margin(_ i: Int) -> JV { abtiConfig["margin_tiers"][i] }

    /// A crew entry's name: a role, a hidden role, or "other".
    static func role(_ id: String) -> String {
        if id == "other" { return L("其他", "Other") }
        let all = abtiConfig["roles"].arr + abtiConfig["hidden_roles"].arr
        return all.first { $0["id"].s == id }.map { cw($0, "name") } ?? id
    }

    static func dimNames(_ id: String) -> [String] {
        let x = abtiConfig["dimensions"][id]
        return (0..<2).map { L(x["name_zh"][$0].s, x["name_en"][$0].s) }
    }

    /// A check-up line: its label, the value as shown, its tier and colour.
    static func checkup(_ c: JV) -> (label: String, shown: String, tier: String, color: NSColor) {
        let id = c["id"].s, v = c["value"].d
        let x = abtiConfig["checkup"][id]
        let label = cw(x, "label")
        let shown: String
        switch id {
        case "tokens_total": shown = compact(v)
        case "lines_added": shown = L(compact(v) + "行", compact(v))
        case "first_try_pass", "night_shift": shown = AB.pct(v)
        case "longest_streak": shown = L("\(Int(v)) 天", "\(Int(v)) days")
        default: shown = L("\(Int(v)) 个", "\(Int(v))")
        }
        if (c["too_few"].raw as? Bool) == true { return (label, shown, cw(x, "too_few"), AB.gray) }
        let tiers = x["tiers"].arr
        let t = tiers.last { v >= $0[0].d } ?? tiers.first ?? JV(nil)
        return (label, shown, L(t[1].s, t[2].s), t[3].isNull ? AB.ink : color(hex: t[3].s))
    }

    /// 128.4 亿 / 12.8B; 21.6 万 / 216K (万 / 億 in Japanese, 만 / 억 in Korean).
    static func compact(_ v: Double) -> String {
        if !cjk {
            if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
            if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
            if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
            return String(format: "%.0f", v)
        }
        let (wan, yi) = lang == "ja" ? ("万", "億") : lang == "ko" ? ("만", "억") : ("万", "亿")
        if v >= 1e8 { return String(format: "%.1f ", v / 1e8) + yi }
        if v >= 1e4 { return String(format: "%.1f ", v / 1e4) + wan }
        return String(format: "%.0f ", v)
    }
}

// MARK: - Drawing helpers (flipped views)

enum AB {
    static let ink = color(hex: "#1C1C1C")
    static let gray = color(hex: "#6E6E73")
    static let tile = color(hex: "#F6F6F6")
    static let control = color(hex: "#F4F4F4")
    static let line = color(hex: "#E6E6E8")
    static let track = color(hex: "#EBEBED")
    static let green = color(hex: "#16A34A")
    static let greenText = color(hex: "#15803D")
    static let greenSoft = color(hex: "#E5F4EA")
    static let amber = color(hex: "#B45309")
    static let bar = color(hex: "#DADADA")
    static let heat = ["#F2F2F3", "#C9EBD2", "#8ED3A3", "#46B26B", "#15803D"].map { color(hex: $0) }

    static func mono(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, _ c: NSColor = ink, kern: CGFloat = 0) -> NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [.font: V3.monoFont(size, w), .foregroundColor: c]
        if kern != 0 { a[.kern] = kern }
        return NSAttributedString(string: s, attributes: a)
    }

    static func sans(_ s: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, _ c: NSColor = ink, kern: CGFloat = 0) -> NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c]
        if kern != 0 { a[.kern] = kern }
        return NSAttributedString(string: s, attributes: a)
    }

    /// Pieces of text one after another on one baseline.
    static func join(_ parts: [NSAttributedString]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        parts.forEach { m.append($0) }
        return m
    }

    /// Wrapped text in a column `w` wide from (x, y); returns its height.
    @discardableResult
    static func para(_ s: NSAttributedString, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, lineHeight: CGFloat? = nil, align: NSTextAlignment = .left, draw: Bool = true) -> CGFloat {
        let m = NSMutableAttributedString(attributedString: s)
        let p = NSMutableParagraphStyle()
        p.alignment = align
        if let lh = lineHeight { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        let h = ceil(m.boundingRect(with: NSSize(width: w, height: 2000), options: [.usesLineFragmentOrigin]).height)
        if draw { m.draw(with: NSRect(x: x, y: y, width: w, height: h + 2), options: [.usesLineFragmentOrigin]) }
        return h
    }

    static func round(_ r: NSRect, _ rad: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
    }

    static func stroke(_ r: NSRect, _ rad: CGFloat, _ c: NSColor, _ w: CGFloat = 1, dash: Bool = false) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), xRadius: rad, yRadius: rad)
        p.lineWidth = w
        if dash { p.setLineDash([3, 3], count: 2, phase: 0) }
        c.setStroke()
        p.stroke()
    }

    /// The word mark: D, the 团子 as its A (theme-b/logo-dango.png, the app
    /// icon's), NGO; returns the width. On a dark ground (`c` light) the 团子
    /// gets a white edge so it does not vanish. No blue mark after it any more
    /// (user, 2026-11-10: 「logo的这个部分都不需要了」).
    @discardableResult
    static func wordmark(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 18, color c: NSColor = ink) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let d = sans("D", size, .heavy, c, kern: -size * 0.02), rest = sans("NGO", size, .heavy, c, kern: -size * 0.02)
        put(d, x, y)
        let baseline = y + font.ascender
        // About as tall as the capitals, sitting on the line.
        let ow = font.capHeight * 1.42, oh = ow * 240 / 352
        let o = NSRect(x: x + d.size().width + size * 0.04, y: baseline - oh + size * 0.02, width: ow, height: oh)
        if let img = themeImage("logo-dango") {
            if (c.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5 {
                let rim = NSImage(size: img.size, flipped: false) { b in
                    img.draw(in: b)
                    NSColor.white.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                rim.draw(in: o.insetBy(dx: -size * 0.06, dy: -size * 0.06), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            img.draw(in: o, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            put(sans("A", size, .heavy, c), o.minX, y)
        }
        put(rest, o.maxX + size * 0.05, y)
        return o.maxX + size * 0.05 + rest.size().width - x
    }

    /// The website at the bottom of every exported image (user, 2026-11-11:
    /// 「每一个分享截图的底下要写官网地址」); nothing on screen in the app.
    /// After a footer note `noteW` wide at `x0`: on its line, right-aligned at
    /// `x0 + w`, or on the line under it when both don't fit; `center` puts it
    /// in the middle of the `w` from `x0`.
    static func siteMark(_ x0: CGFloat, _ y: CGFloat, _ w: CGFloat, noteW: CGFloat = 0, center: Bool = false, color c: NSColor = ink) {
        guard exportingImage else { return }
        let s = mono("dangoai.org", 11, .semibold, c)
        if center { return put(s, x0 + w / 2, y, align: 1) }
        put(s, x0 + w, noteW + 16 + s.size().width <= w ? y : y + 17, align: 2)
    }

    /// A pill: dark (black, white words) or light (white, outlined); returns its rect.
    @discardableResult
    static func pill(_ text: String, _ x: CGFloat, _ y: CGFloat, dark: Bool, size: CGFloat = 12, padX: CGFloat = 10, padY: CGFloat = 3, draw: Bool = true,
                     fill: NSColor? = nil, ink inkColor: NSColor? = nil) -> NSRect {
        let t = sans(text, size, .semibold, inkColor ?? (dark ? .white : ink))
        let r = NSRect(x: x, y: y, width: t.size().width + padX * 2, height: t.size().height + padY * 2)
        guard draw else { return r }
        if let fill {
            round(r, r.height / 2, fill)
        } else if dark {
            round(r, r.height / 2, ink)
        } else {
            round(r, r.height / 2, .white)
            stroke(r, r.height / 2, color(hex: "#D4D4D8"))
        }
        put(t, r.minX + padX, r.minY + padY)
        return r
    }

    /// An image fitted into `r` (aspect kept), centred or to one side.
    @discardableResult
    static func fit(_ img: NSImage?, _ r: NSRect, align: Int = 1, alpha: CGFloat = 1) -> NSRect {
        guard let img, img.size.width > 0, img.size.height > 0 else { return .zero }
        let k = min(r.width / img.size.width, r.height / img.size.height)
        let sz = NSSize(width: img.size.width * k, height: img.size.height * k)
        let x = align == 0 ? r.minX : align == 2 ? r.maxX - sz.width : r.midX - sz.width / 2
        let out = NSRect(x: x, y: r.midY - sz.height / 2, width: sz.width, height: sz.height)
        img.draw(in: out, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        return out
    }

    /// A section title with an optional note on the right; returns its height.
    @discardableResult
    static func header(_ title: String, _ right: String?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, size: CGFloat = 13, rightMono: Bool = false) -> CGFloat {
        let t = sans(title, size, .semibold)
        put(t, x, y)
        if let right, !right.isEmpty {
            let r = rightMono ? mono(right, 10.5, .regular, gray) : sans(right, 10.5, .regular, gray)
            // Beside the title when both fit (long in French and Spanish), else under it.
            if t.size().width + 12 + r.size().width <= w {
                put(r, x + w, y + t.size().height - r.size().height - 1, align: 2)
            } else {
                put(r, x, y + t.size().height + 2)
                return t.size().height + r.size().height + 2
            }
        }
        return t.size().height
    }

    /// One line of text at `size`, smaller (down to `least`) until it is
    /// `w` wide, then cut with "…": translations run longer than the design.
    static func fitLine(_ make: (CGFloat) -> NSAttributedString, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, least: CGFloat) {
        var s = size
        while make(s).size().width > w && s > least { s -= 0.5 }
        let t = make(s)
        t.draw(with: NSRect(x: x, y: y + (size - s) * 0.5, width: w, height: t.size().height + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    static func lev(_ v: Double) -> String { v >= 100 ? "\(Int(v.rounded()))×" : String(format: "%.1f×", v) }

    /// "≈ 32 小时": whole hours from ten up, one decimal below.
    static func hours(_ h: Double) -> String {
        let n = h >= 10 ? String(format: "%.0f", h) : String(format: "%.1f", h)
        return "≈ " + n + L(" 小时", " h")
    }

    /// "10 月 29 日" / "Oct 29".
    static func monthDay(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return day }
        return Dates.monthDay(p[1], p[2])
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: day)
    }

    /// 周四 / Thu.
    static func weekday(_ day: String) -> String {
        guard let d = date(day) else { return "" }
        let k = (Calendar(identifier: .gregorian).component(.weekday, from: d) + 5) % 7
        return Dates.weekday(k)
    }

    static func short(_ day: String) -> String { day.count >= 10 ? String(day.dropFirst(5)) : day }

    /// The colours of a crew: a segmented bar `w` wide.
    static func crewBar(_ crew: [JV], _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, h: CGFloat = 8) {
        let gap: CGFloat = 2
        let shown = crew.filter { $0["share"].d > 0.004 }
        let avail = w - gap * CGFloat(max(0, shown.count - 1))
        var cx = x
        for c in shown {
            let cw = max(2, avail * CGFloat(c["share"].d))
            round(NSRect(x: cx, y: y, width: cw, height: h), h / 2, color(hex: c["color"].s))
            cx += cw + gap
        }
    }

    /// A swatch, with a little star for the hidden ones.
    static func swatch(_ c: JV, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10) {
        round(NSRect(x: x, y: y, width: size, height: size), 2, color(hex: c["color"].s))
        if c["id"].s != "other" && c["hidden"].i == 1 || (c["hidden"].raw as? Bool) == true && c["id"].s != "other" {
            put(sans("★", size * 0.8, .bold, .white), x + size / 2, y + size * 0.05, align: 1)
        }
    }

    /// Each role in a row: the 团子, swatch, name, ≈ hours, dollars (and share).
    static func crewRows(_ crew: [JV], _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, max n: Int, rowH: CGFloat = 31, showHours: Bool = true, showShare: Bool = false,
                         nameSize: CGFloat = 14, numSize: CGFloat = 14) -> CGFloat {
        var yy = y
        for c in crew.prefix(n) {
            fit(roleArt(c["art"].s), NSRect(x: x, y: yy + 2, width: 30, height: rowH - 6), align: 0)
            swatch(c, x + 40, yy + rowH / 2 - 5)
            let name = sans(ABText.role(c["id"].s), nameSize, .regular)
            put(name, x + 58, yy + rowH / 2 - name.size().height / 2)
            if showHours {
                let hh = mono(hours(c["hours"].d), nameSize - 2, .regular, gray)
                put(hh, x + 58 + name.size().width + 12, yy + rowH / 2 - hh.size().height / 2)
            }
            let usd = mono(fmtUSD(c["usd"].d), numSize, .semibold)
            if showShare {
                put(usd, x + w - 48, yy + rowH / 2 - usd.size().height / 2, align: 2)
                let p = mono(pct(c["share"].d), 11, .regular, gray)
                put(p, x + w, yy + rowH / 2 - p.size().height / 2, align: 2)
            } else {
                put(usd, x + w, yy + rowH / 2 - usd.size().height / 2, align: 2)
            }
            yy += rowH
            line.setFill()
            NSRect(x: x, y: yy - 1, width: w, height: 1).fill()
        }
        return yy - y
    }

    /// A heat level's colour.
    static func heatColor(_ level: Int) -> NSColor { heat[min(4, max(0, level))] }

    /// 少 ■■■■■ 多.
    static func heatLegend(_ x: CGFloat, _ y: CGFloat, cell: CGFloat = 10) -> CGFloat {
        let a = sans(L("少", "Less"), 10.5, .regular, gray)
        put(a, x, y)
        var cx = x + a.size().width + 6
        for k in 0..<5 {
            round(NSRect(x: cx, y: y + (a.size().height - cell) / 2, width: cell, height: cell), 2, heat[k])
            cx += cell + 3
        }
        let b = sans(L("多", "More"), 10.5, .regular, gray)
        put(b, cx + 3, y)
        return cx + 3 + b.size().width - x
    }
}

/// A page drawn top-down at the design's size.
class ABPage: NSView {
    var data = JV(nil)
    override var isFlipped: Bool { true }
    /// How tall the page needs to be for everything it drew, the website line
    /// under the last words included; an exported image grows to it (French
    /// and Spanish run longer than the page). Nil: the page always fits.
    var neededHeight: CGFloat?

    convenience init(size: NSSize, data: JV) {
        self.init(frame: NSRect(origin: .zero, size: size))
        self.data = data
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        render()
    }

    func render() {}
}

// MARK: - The boss card (总卡, 540 × 960)

final class BossCardView: ABPage {
    override func render() {
        let d = data
        let x0: CGFloat = 32, W: CGFloat = 476
        var y: CGFloat = 28
        // 1. Top: the word mark, what this is, the date.
        let mw = AB.wordmark(x0, y)
        put(AB.sans(L("ABTI 人格", "ABTI"), 14, .medium, AB.gray), x0 + mw + 10, y + 3)
        put(AB.mono("ABTI · " + d["date"].s, 12, .regular, AB.gray), x0 + W, y + 4, align: 2)
        y += 22 + 10

        // 2. The reveal: the type's scene, and who you are.
        let code = d["code"].s
        AB.fit(abtiImage("scene/T-" + code), NSRect(x: x0, y: y, width: 232, height: 186), align: 1)
        let tx = x0 + 232 + 16, tw = W - 232 - 16
        let youAre = AB.mono(L("你是", "YOU ARE"), 11, .regular, AB.gray)
        let codeT = AB.mono(code, 42, .semibold, kern: 1.6)
        let nameT = AB.sans(ABText.typeName(code), cjk ? 30 : 26, .semibold, kern: cjk ? -0.6 : -0.5)
        let nameH = AB.para(nameT, tx, 0, tw, lineHeight: (cjk ? 30 : 26) * 1.12, draw: false)
        let colH = youAre.size().height + 3 + 46 + 3 + nameH + 11 + 22
        var cy = y + (186 - colH) / 2
        put(youAre, tx, cy)
        cy += youAre.size().height + 3
        put(codeT, tx - 1, cy - 4)
        cy += 46 + 3
        AB.para(nameT, tx, cy, tw, lineHeight: (cjk ? 30 : 26) * 1.12)
        cy += nameH + 11
        let scaleName = cw(ABText.scale(d["scale"]["index"].i), "name")
        let p1 = AB.pill(L(scaleName + "级", scaleName + " tier"), tx, cy, dark: true)
        AB.pill(L("压榨率 ", "Margin ") + String(format: "%.1f%%", d["margin"].d * 100), p1.maxX + 6, cy, dark: false)
        y += 186 + 14

        // 3. The roast.
        put(NSAttributedString(string: "“", attributes: [.font: NSFont(name: "Georgia-Bold", size: 40) ?? NSFont.boldSystemFont(ofSize: 40), .foregroundColor: color(hex: "#D4D4D8")]), x0, y - 6)
        let roastSize: CGFloat = cjk ? 16 : 14
        y += AB.para(AB.sans(ABText.roast(code), roastSize, .medium), x0 + 30, y + 2, W - 30, lineHeight: roastSize * 1.45) + 2 + 14

        // 4. The four dimensions.
        y += AB.header(L("你的 ABTI", "Your ABTI"), L("≈ 两边都沾 · 格子 = 占一成以上的角色", "≈ on the fence · squares = roles at 10%+"), x0, y, W) + 8
        let dims = d["dims"].arr
        var lw: CGFloat = 54
        for dm in dims {
            let names = ABText.dimNames(dm["id"].s)
            for k in 0..<2 {
                lw = max(lw, AB.sans(dm["letters"][k].s + " " + names[k], 12.5, .semibold).size().width + 2)
            }
        }
        let vw: CGFloat = cjk ? 48 : 62
        let barX = x0 + lw + 10, barW = W - lw * 2 - vw - 30
        for dm in dims {
            let win = dm["winner"].i
            let rowH: CGFloat = 18
            for k in 0..<2 {
                let on = k == win
                let names = ABText.dimNames(dm["id"].s)
                let label = k == 0 ? dm["letters"][0].s + " " + names[0] : names[1] + " " + dm["letters"][1].s
                let t = AB.sans(label, 12.5, on ? .semibold : .regular, on ? AB.ink : AB.gray)
                put(t, k == 0 ? x0 : barX + barW + 10 + lw, y + (rowH - t.size().height) / 2, align: k == 0 ? 0 : 2)
            }
            let by = y + (rowH - 8) / 2
            if dm["id"].s == "range" {
                let n = dm["roles"].i
                let gap: CGFloat = 3, cell = (barW - gap * 7 - 4) / 8
                var cx = barX
                for k in 0..<8 {
                    AB.round(NSRect(x: cx, y: by, width: cell, height: 8), 2, k < n ? AB.ink : AB.track)
                    cx += cell + gap
                    if k == 1 {
                        AB.gray.withAlphaComponent(0.5).setFill()
                        NSRect(x: cx - 1, y: by - 3, width: 1.5, height: 14).fill()
                        cx += 4
                    }
                }
                put(AB.mono(L("\(n) 个", "\(n) roles"), 12.5, .semibold), x0 + W, y + 1, align: 2)
            } else {
                AB.round(NSRect(x: barX, y: by, width: barW, height: 8), 4, AB.track)
                let fw = barW * CGFloat(dm["pct"].d)
                AB.round(NSRect(x: win == 0 ? barX : barX + barW - fw, y: by, width: fw, height: 8), 4, AB.ink)
                NSColor.white.setFill()
                NSRect(x: barX + barW / 2 - 1, y: by - 2, width: 2, height: 12).fill()
                let tie = dm["tie"].raw as? Bool == true
                put(AB.mono((tie ? "≈ " : "") + AB.pct(dm["pct"].d), 12.5, .semibold, tie ? AB.gray : AB.ink), x0 + W, y + 1, align: 2)
            }
            y += rowH + 8
        }
        y += 6

        // 5. The money: the only big number on the card.
        AB.line.setFill()
        NSRect(x: x0, y: y, width: W, height: 1).fill()
        y += 12
        put(AB.sans(L("团子们替你打了", "Your dangos did"), 15, .medium), x0, y)
        y += 22
        let big = AB.mono(fmtUSD(d["usd"].d), 50, .semibold, kern: -1.5)
        put(big, x0 - 2, y)
        let tail = AB.sans(L("的工", "of work"), 19, .semibold)
        put(tail, x0 + big.size().width + 8, y + big.size().height - tail.size().height - 6)
        y += big.size().height + 2
        let lv = d["leverage"].isNull ? "—" : AB.lev(d["leverage"].d)
        let tierName = cw(ABText.margin(d["margin_tier"]["index"].i), "name")
        let paid = L("你只发了 \(fmtUSD(d["cost"].d)) 工资 · 杠杆 \(lv) · \(tierName)", "You paid them \(fmtUSD(d["cost"].d)) · \(lv) leverage · \(tierName)")
        put(AB.mono(paid, 11.5, .regular, AB.gray), x0, y)
        y += 16 + 14

        // 6. The check-up.
        y += AB.header(L("体检单", "Lab results"), L("参考范围是 Dango 自定的分档，不和别人比", "Dango's own tiers, not a ranking"), x0, y, W) + 6
        let cwid = (W - 12) / 3, ch: CGFloat = 47
        for (k, c) in d["checkup"].arr.enumerated() {
            let r = NSRect(x: x0 + CGFloat(k % 3) * (cwid + 6), y: y + CGFloat(k / 3) * (ch + 6), width: cwid, height: ch)
            AB.round(r, 12, AB.tile)
            let ck = ABText.checkup(c)
            put(AB.sans(ck.label, 10.5, .regular, AB.gray), r.minX + 10, r.minY + 7)
            put(AB.mono(ck.shown, 15, .semibold), r.minX + 10, r.minY + 22)
            let tier = AB.sans(ck.tier, 10.5, .semibold, ck.color)
            put(tier, r.maxX - 10, r.minY + 26, align: 2)
        }
        y += ch * 2 + 6 + 14

        // 7. The crew.
        let crew = d["crew"].arr
        let right = L("\(d["scan_days"].i) 天 · \(fmtInt(d["sessions"].i)) 个会话", "\(d["scan_days"].i) days · \(fmtInt(d["sessions"].i)) sessions")
        y += AB.header(L("团子构成", "Your crew"), right, x0, y, W, rightMono: true) + 6
        AB.crewBar(crew, x0, y, W)
        y += 8 + 7
        var lx = x0
        for c in crew where c["share"].d >= 0.1 && c["id"].s != "other" {
            let label = AB.sans(ABText.role(c["id"].s) + " " + AB.pct(c["share"].d), 12)
            let iw: CGFloat = 10 + 6 + 26 + 6 + label.size().width
            if lx + iw > x0 + W { lx = x0; y += 22 }
            AB.swatch(c, lx, y + 4)
            AB.fit(roleArt(c["art"].s), NSRect(x: lx + 16, y: y - 2, width: 26, height: 22))
            put(label, lx + 48, y + 1)
            lx += iw + 16
        }
        y += 22 + 12

        // 8. The perfect match.
        let box = NSRect(x: x0, y: y, width: W, height: 53)
        AB.round(box, 16, AB.tile)
        AB.fit(abtiImage("icon/T-" + d["match"]["code"].s), NSRect(x: box.minX + 10, y: box.minY + 6, width: 58, height: 41))
        let mx = box.minX + 78
        let mcode = d["match"]["code"].s
        put(AB.join([AB.sans(L("你的绝配：", "Your perfect match: "), 13.5, .semibold), AB.mono(mcode, 13.5, .semibold), AB.sans(" " + ABText.typeName(mcode), 13.5, .semibold)]), mx, box.minY + 8)
        let line = ABText.matchLine(code)
        let tag = L(line + "。@ 一个这样的朋友来看看", line + " Tag one.")
        AB.sans(tag, 12, .regular, AB.gray).draw(with: NSRect(x: mx, y: box.minY + 28, width: box.maxX - 12 - mx, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // 9. How it's counted, at the bottom, and in an exported image the
        // website (dangoai.org; 2026-11-07 the user wanted no link because
        // the address then was dango.app, not ours). A footer like the share
        // images': a rule, then the line.
        let fy = bounds.height - 72
        AB.line.setFill()
        NSRect(x: x0, y: fy, width: W, height: 1).fill()
        let note = AB.sans(L("全在本机算 · 不读代码和 prompt · 不上传", "Runs on your Mac · never reads code or prompts · nothing uploaded"), 11, .regular, AB.gray)
        put(note, x0, fy + 26)
        AB.siteMark(x0, fy + 26, W, noteW: note.size().width)
    }
}

// MARK: - The 16 types (图鉴, 540 × 960)

final class TypesView: ABPage {
    override func render() {
        let c = abtiConfig
        let x0: CGFloat = 28, W: CGFloat = 484
        var y: CGFloat = 28
        let mw = AB.wordmark(x0, y)
        put(AB.sans(L("16 种 ABTI 人格", "The 16 ABTI types"), 14, .medium, AB.gray), x0 + mw + 10, y + 3)
        put(AB.mono("ABTI", 12, .regular, AB.gray), x0 + W, y + 4, align: 2)
        y += 34
        put(AB.sans(L("你是哪一种老板？", "Which boss are you?"), 22, .semibold), x0, y)
        y += 36
        let intro = AB.join([AB.sans(L("左边放权派，右边微操派。", "Hands-off on the left, micro on the right. "), 12, .regular, AB.gray),
                             AB.sans(L("同一行就是绝配", "Same row = perfect match"), 12, .semibold),
                             AB.sans(L("：一个放手开荒，一个盯着收尾。", ": one breaks ground, one sees it through."), 12, .regular, AB.gray)])
        y += AB.para(intro, x0, y, W) + 6
        put(AB.mono(L("B 开荒 / F 修缮 · S 专精 / G 跨界 · L 早鸟 / O 夜猫", "B build / F fix · S specialist / G generalist · L lark / O owl"), 10.5, .regular, AB.gray), x0, y)
        y += 24
        let colW = (W - 10) / 2
        for (k, t) in [(0, L("H · 放权派", "H · Hands-off")), (1, L("M · 微操派", "M · Micro"))] {
            let x = x0 + CGFloat(k) * (colW + 10)
            put(AB.mono(t, 12, .semibold), x + 2, y)
            AB.ink.setFill()
            NSRect(x: x, y: y + 22, width: colW, height: 1.5).fill()
        }
        y += 31
        let left = ["HBSL", "HBSO", "HBGL", "HBGO", "HFSL", "HFSO", "HFGL", "HFGO"]
        let rowH: CGFloat = 85, gap: CGFloat = 7
        for (row, code) in left.enumerated() {
            let pair = [code, c["types"][code]["match"].s]
            for (k, cd) in pair.enumerated() {
                let t = c["types"][cd]
                let r = NSRect(x: x0 + CGFloat(k) * (colW + 10), y: y + CGFloat(row) * (rowH + gap), width: colW, height: rowH)
                AB.round(r, 16, AB.tile)
                AB.fit(abtiImage("icon/T-" + cd), NSRect(x: r.minX + 10, y: r.minY + 12, width: 66, height: rowH - 24))
                let tx = r.minX + 82, tw = r.maxX - 12 - tx
                // One language: the code, the name and the roast in the reader's.
                let nh = AB.para(AB.join([AB.mono(cd + " ", 13, .semibold), AB.sans(cw(t, "name"), 14, .semibold)]), tx, r.minY + 10, tw, lineHeight: 18)
                AB.para(AB.sans(cw(t, "roast"), 10.5, .regular, AB.gray), tx, r.minY + 14 + nh, tw, lineHeight: 15)
            }
        }
        y += CGFloat(left.count) * (rowH + gap) + 4
        put(AB.sans(L("每种 ABTI 人格一个招牌动作；你的职业角色在结果卡「团子构成」里另外显示", "One signature move per ABTI type; your job roles show on the card's crew"), 10.5, .regular, AB.gray), x0, y)
        neededHeight = y + 47
        AB.siteMark(x0, bounds.height - 26, W)
    }
}

// MARK: - Scale and margin (540 × 604)

final class ScaleView: ABPage {
    override func render() {
        let c = abtiConfig
        let x0: CGFloat = 32, W: CGFloat = 476
        var y: CGFloat = 28
        let mw = AB.wordmark(x0, y)
        put(AB.sans(L("公司规模 · 压榨率", "Company size · Margin"), 14, .medium, AB.gray), x0 + mw + 10, y + 3)
        y += 44
        y += AB.header(L("你的公司多大", "How big is your company"), L("按团子替你打的工，固定门槛，不和别人比", "By your dangos' work, fixed thresholds, no ranking"), x0, y, W, size: 16) + 12
        let tiers = c["scale_tiers"].arr
        let mine = data["scale"]["index"].i
        // The ranges from abti.json's thresholds, e.g. "$10k – 100k".
        let mins = tiers.map { ABText.shortUSD($0["min_usd"].d) }
        let ranges = mins.indices.map { i in
            i == 0 ? "< $" + mins[1] : i == mins.count - 1 ? "≥ $" + mins[i] : "$" + mins[i] + " – " + mins[i + 1]
        }
        for (k, t) in tiers.enumerated() {
            let rowH: CGFloat = 51
            // Signal bars: k + 1 of 5 dark.
            for b in 0..<5 {
                let h = CGFloat(5 + b * 4)
                AB.round(NSRect(x: x0 + CGFloat(b) * 7, y: y + 30 - h, width: 5, height: h), 1.5, b <= k ? AB.ink : AB.track)
            }
            let name = AB.sans(cw(t, "name"), 15, .semibold)
            put(name, x0 + 46, y + 4)
            if k == mine {
                AB.pill(L("你在这", "You're here"), x0 + 46 + name.size().width + 8, y + 4, dark: true, size: 10.5, padX: 7, padY: 1.5)
            }
            let range = AB.mono(ranges[k], 12, .semibold)
            AB.fitLine({ AB.sans(cw(t, "line"), $0, .regular, AB.gray) }, 11.5, x0 + 46, y + 25, W - 46 - range.size().width - 12, least: 9.5)
            put(range, x0 + W, y + 14, align: 2)
            y += rowH
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W, height: 1).fill()
        }
        y += 22
        y += AB.header(L("你有多黑心", "How ruthless are you"), L("压榨率 = 1 − 模型花费 ÷ 团子打的工", "margin = 1 − model cost ÷ dangos' work"), x0, y, W, size: 16) + 10
        let mi = data["margin_tier"]["index"].i
        let bands = ["≥ 95%", "80–95%", "50–80%", "0–50%", "< 0"]
        for (k, t) in c["margin_tiers"].arr.enumerated() {
            let rowH: CGFloat = 31
            put(AB.mono(bands[min(k, 4)], 12, .semibold), x0, y + 8)
            let nm = AB.sans(cw(t, "name"), 13, .semibold)
            put(nm, x0 + 76, y + 7)
            let lx = max(x0 + 172, x0 + 76 + nm.size().width + 12)
            let pillW = k == mi ? AB.pill(L("你在这", "You're here"), 0, 0, dark: true, size: 10.5, padX: 7, padY: 1.5, draw: false).width + 8 : 0
            AB.sans(cw(t, "line"), 11.5, .regular, AB.gray).draw(with: NSRect(x: lx, y: y + 8, width: x0 + W - pillW - lx, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if k == mi { AB.pill(L("你在这", "You're here"), x0 + W - pillW + 8, y + 7, dark: true, size: 10.5, padX: 7, padY: 1.5) }
            y += rowH
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W, height: 1).fill()
        }
        y += 8
        put(AB.sans(L("只看比例：花 $5 的个体户也能是黑心老板。", "Only the ratio counts: a $5 solo stall can be ruthless too."), 10.5, .regular, AB.gray), x0, y)
        neededHeight = y + 47
        AB.siteMark(x0, bounds.height - 26, W)
    }
}

// MARK: - The crew roles (540 × 724)

final class RolesView: ABPage {
    override func render() {
        let c = abtiConfig
        let x0: CGFloat = 32, W: CGFloat = 476
        var y: CGFloat = 28
        let mw = AB.wordmark(x0, y)
        put(AB.sans(L("团子构成 · 8 个角色", "Your crew · 8 roles"), 14, .medium, AB.gray), x0 + mw + 10, y + 3)
        y += 42
        y += AB.para(AB.sans(L("写代码统称程序员。角色只看团子在干什么活，和 ABTI 类型无关；颜色跟角色走，不跟名次走。右边的小团子是同一角色的备用造型。",
                                "All coding is the coder. A role is about the work, not your ABTI; colours follow the role, not the rank. Small ones on the right are the same role's alternates."),
                                12, .regular, AB.gray), x0, y, W, lineHeight: 17) + 14
        for r in c["roles"].arr {
            let rowH: CGFloat = 58
            AB.fit(roleArt(r["art"].s), NSRect(x: x0, y: y + 2, width: 56, height: rowH - 8), align: 0)
            AB.round(NSRect(x: x0 + 68, y: y + 13, width: 10, height: 10), 2, color(hex: r["color"].s))
            let name = AB.sans(cw(r, "name"), 15, .semibold)
            put(name, x0 + 85, y + 9)
            put(AB.mono(r["art"].s, 10.5, .regular, AB.gray), x0 + 85 + name.size().width + 8, y + 12)
            put(AB.sans(cw(r, "covers"), 11.5, .regular, AB.gray), x0 + 68, y + 32)
            var ax = x0 + W
            for alt in r["alt_art"].arr.reversed() {
                let got = AB.fit(roleArt(alt.s), NSRect(x: ax - 30, y: y + 14, width: 30, height: 26), align: 2)
                ax = got.minX - 4
            }
            y += rowH
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W, height: 1).fill()
        }
        y += 12
        let box = NSRect(x: x0, y: y, width: W, height: 100)
        AB.round(box, 16, AB.tile)
        AB.fitLine({ AB.join([AB.sans(L("隐藏款  ", "Hidden  "), $0, .semibold), AB.sans(L("占到 10% 以上才出现，算一个工种 · 金色闪光是隐藏款标记", "appear at 10%+ and count as a role · the gold sparkle marks them"), $0, .regular, AB.gray)]) }, 11.5, box.minX + 14, box.minY + 12, box.width - 28, least: 9)
        let hidden = c["hidden_roles"].arr
        let cell = (box.width - 28) / CGFloat(max(1, hidden.count))
        for (k, h) in hidden.enumerated() {
            let cx = box.minX + 14 + CGFloat(k) * cell
            let art = h["art"].s.split(separator: "/").last.map { String($0).replacingOccurrences(of: ".png", with: "") } ?? ""
            AB.fit(abtiImage("hidden/" + art), NSRect(x: cx, y: box.minY + 32, width: cell, height: 40))
            put(AB.sans(cw(h, "name"), 11, .regular), cx + cell / 2, box.minY + 76, align: 1)
        }
        y += 100 + 8
        let jobs = data["jobs"].i
        let note = jobs > 0 ? L("跨界 = 有 3 个以上角色各占 10% 以上。算钱仍按 \(jobs) 个职业各自的 BLS 时薪。", "Generalist = 3+ roles at 10% or more each. Money still uses each of the \(jobs) jobs' BLS wage.")
                            : L("跨界 = 有 3 个以上角色各占 10% 以上。算钱仍按每个职业各自的 BLS 时薪。", "Generalist = 3+ roles at 10% or more each. Money still uses each job's BLS wage.")
        AB.fitLine({ AB.sans(note, $0, .regular, AB.gray) }, 10.5, x0, y, W, least: 8.5)
        neededHeight = y + 47
        AB.siteMark(x0, bounds.height - 26, W)
    }
}

// MARK: - Export

/// True while `exportPage` draws: pages then put the website at the bottom.
var exportingImage = false

/// Renders a page at 2× into a PNG; copies it to the clipboard when asked.
@discardableResult
func exportPage(_ v: NSView, _ path: String, copy: Bool = false) -> Bool {
    exportingImage = true
    defer { exportingImage = false }
    // Drawn once to see whether its words run past the bottom; then taller.
    if let p = v as? ABPage, let rep = p.bitmapImageRepForCachingDisplay(in: p.bounds) {
        p.cacheDisplay(in: p.bounds, to: rep)
        if let need = p.neededHeight, need > p.bounds.height { p.setFrameSize(NSSize(width: p.bounds.width, height: ceil(need))) }
    }
    let size = v.bounds.size
    v.frame = NSRect(origin: .zero, size: NSSize(width: size.width * 2, height: size.height * 2))
    v.scaleUnitSquare(to: NSSize(width: 2, height: 2))
    defer {
        v.scaleUnitSquare(to: NSSize(width: 0.5, height: 0.5))
        v.frame = NSRect(origin: v.frame.origin, size: size)
    }
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { return false }
    if copy, let img = NSImage(data: png) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
    return true
}

// MARK: - Report words

enum ReportText {
    static func kindName(_ kind: String, share: Bool) -> String {
        switch kind {
        case "week": return L("周报", "Week")
        case "month": return L("月报", "Month")
        case "year": return L("年报", "Year")
        case "total": return share ? L("总报", "All-time") : L("总计", "All-time")
        default: return L("日报", "Day")
        }
    }

    /// The period: "10 月 29 日 · 周四", "10/26 – 11/01", "2026 年 10 月", "6 月 11 日至今".
    static func period(_ d: JV, compact: Bool = false) -> String {
        let from = d["from"].s, to = d["to"].s
        switch d["kind"].s {
        case "week": return AB.short(from).replacingOccurrences(of: "-", with: "/") + " – " + AB.short(to).replacingOccurrences(of: "-", with: "/")
        case "month":
            let p = from.split(separator: "-")
            guard p.count >= 2 else { return from }
            return Dates.yearMonth(Int(p[0]) ?? 0, Int(p[1]) ?? 1)
        case "year": return Dates.year(Int(from.prefix(4)) ?? 0)
        case "total": return L(AB.monthDay(from) + "至今", "Since " + AB.monthDay(from))
        default: return compact ? from + " · " + AB.weekday(from) : AB.monthDay(from) + " · " + AB.weekday(from)
        }
    }

    /// "这一天，团子们替你打了".
    static func lead(_ d: JV, share: Bool) -> String {
        switch d["kind"].s {
        case "week": return L("这一周，团子们替你打了", "This week, your dangos did")
        case "month":
            let m = Int(d["from"].s.split(separator: "-").dropFirst().first ?? "") ?? 0
            return share ? L("\(m) 月，团子们替你打了", "This month, your dangos did") : L("这个月，团子们替你打了", "This month, your dangos did")
        case "year":
            let y = d["from"].s.prefix(4)
            return share ? L("\(y) 年，团子们替你打了", "In \(y), your dangos did") : L("这一年，团子们替你打了", "This year, your dangos did")
        case "total":
            let n = d["days"].i
            return share ? L("\(n) 天，团子们一共替你打了", "In \(n) days, your dangos did") : L("一起干活 \(n) 天，团子们一共替你打了", "In \(n) days together, your dangos did")
        default:
            return share ? L("\(AB.monthDay(d["from"].s))，团子们替你打了", "On \(AB.monthDay(d["from"].s)), your dangos did") : L("这一天，团子们替你打了", "That day, your dangos did")
        }
    }

    /// "比昨天" / "比上周" / "比 9 月".
    static func prevName(_ d: JV) -> String {
        switch d["kind"].s {
        case "week": return L("比上周", "vs last week")
        case "month":
            let m = (Int(d["from"].s.split(separator: "-").dropFirst().first ?? "") ?? 1) - 1
            return L("比 \(m == 0 ? 12 : m) 月", "vs last month")
        case "year": return L("比去年", "vs last year")
        default: return L("比昨天", "vs yesterday")
        }
    }

    static func change(_ v: JV) -> String {
        guard !v.isNull else { return "—" }
        return (v.d >= 0 ? "↑ " : "↓ ") + String(format: "%.0f%%", abs(v.d) * 100)
    }

    /// 单日纪录 / 进行中 4 / 7 天.
    static func chip(_ d: JV) -> String? {
        if d["kind"].s == "day", (d["is_record"].raw as? Bool) == true { return L("单日纪录", "Best day") }
        if d["kind"].s == "week", d["elapsed"].i < 7 { return L("进行中 \(d["elapsed"].i) / 7 天", "In progress \(d["elapsed"].i) / 7 days") }
        if d["kind"].s == "year", d["elapsed"].i < 12 { return L("进行中 \(d["elapsed"].i) / 12 月", "In progress \(d["elapsed"].i) / 12 months") }
        return nil
    }

    /// A month by its index (0 = January): "1月" / "Jan".
    static func month(_ k: Int) -> String {
        Dates.monthShort(k % 12 + 1)
    }

    static func moneyLine(_ d: JV) -> String {
        let lv = d["leverage"].isNull ? "—" : AB.lev(d["leverage"].d)
        if d["kind"].s == "total" {
            let tier = cw(ABText.margin(abtiMarginIndex(d)), "name")
            return L("实发 \(fmtUSD(d["cost"].d)) · 杠杆 \(lv) · \(tier)", "Paid \(fmtUSD(d["cost"].d)) · \(lv) leverage · \(tier)")
        }
        return L("模型花了 \(fmtUSD(d["cost"].d)) · 杠杆 \(lv) · ", "Model cost \(fmtUSD(d["cost"].d)) · \(lv) leverage · ") + prevName(d) + " " + change(d["vs_prev"]).replacingOccurrences(of: " ", with: "")
    }

    static func wd(_ k: Int) -> String { Dates.weekday(k) }
}

/// The margin tier's index for a total report (from its boss summary).
func abtiMarginIndex(_ d: JV) -> Int {
    let m = d["boss"]["margin"].d
    let tiers = abtiConfig["margin_tiers"].arr
    return tiers.firstIndex { !$0["min"].isNull && m >= $0["min"].d } ?? max(0, tiers.count - 1)
}

/// Bars for a chart: values (nil = not yet), the one to mark green, labels.
func drawBars(_ vals: [Double?], _ r: NSRect, mark: Int?, labels: [(Int, String)], gap: CGFloat = 4, labelSize: CGFloat = 10, valueLabel: Bool = true) {
    let n = max(1, vals.count)
    let bw = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)
    let maxV = max(vals.compactMap { $0 }.max() ?? 1, 0.01)
    let base = r.maxY
    for (i, v) in vals.enumerated() {
        let x = r.minX + CGFloat(i) * (bw + gap)
        guard let v else {
            AB.stroke(NSRect(x: x, y: base - 14, width: bw, height: 14), 3, color(hex: "#C9C9CE"), 1, dash: true)
            continue
        }
        let h = v > 0 ? max(4, (r.height - 18) * CGFloat(v / maxV)) : 3
        let bar = NSRect(x: x, y: base - h, width: bw, height: h)
        AB.round(bar, min(3, bw / 2), i == mark ? AB.green : v > 0 ? AB.bar : color(hex: "#EDEDED"))
        if i == mark, valueLabel, v > 0 {
            put(AB.mono(fmtUSD(v), 10.5, .semibold), bar.midX, bar.minY - 15, align: 1)
        }
    }
    AB.line.setFill()
    NSRect(x: r.minX, y: base, width: r.width, height: 1).fill()
    for (i, t) in labels {
        let x = r.minX + CGFloat(i) * (bw + gap) + bw / 2
        put(AB.mono(t, labelSize, .regular, AB.gray), x, base + 5, align: 1)
    }
}

/// A month as a calendar of heat cells (Monday first).
func drawCalendar(_ d: JV, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, cellH: CGFloat, gap: CGFloat = 5) -> CGFloat {
    let daily = d["daily"].arr
    let vals = daily.compactMap { $0.isNull ? nil : $0.d }.filter { $0 > 0 }.sorted()
    func level(_ v: Double) -> Int {
        guard v > 0, !vals.isEmpty else { return 0 }
        let below = vals.filter { $0 < v }.count
        return 1 + min(3, 4 * below / vals.count)
    }
    let cw = (w - gap * 6) / 7
    var yy = y
    for k in 0..<7 { put(AB.sans(L(["一", "二", "三", "四", "五", "六", "日"][k], ["M", "T", "W", "T", "F", "S", "S"][k]), 11, .regular, AB.gray), x + CGFloat(k) * (cw + gap) + cw / 2, yy, align: 1) }
    yy += 20
    let first = d["first_weekday"].i
    let today = d["today"].s
    for (i, v) in daily.enumerated() {
        let slot = first + i
        let r = NSRect(x: x + CGFloat(slot % 7) * (cw + gap), y: yy + CGFloat(slot / 7) * (cellH + gap), width: cw, height: cellH)
        let day = i + 1
        let isToday = d["from"].s.count >= 8 && String(d["from"].s.prefix(8)) + String(format: "%02d", day) == today
        if v.isNull {
            AB.stroke(r, 6, color(hex: "#C9C9CE"), 1, dash: true)
            put(AB.mono("\(day)", 10, .regular, color(hex: "#B5B5BA")), r.minX + 7, r.minY + 5)
            continue
        }
        let lv = level(v.d)
        AB.round(r, 6, AB.heatColor(lv))
        if isToday { AB.stroke(r, 6, AB.ink, 1.5) }
        put(AB.mono("\(day)", 10, .regular, lv >= 3 ? .white : AB.ink), r.minX + 7, r.minY + 5)
    }
    let rows = (first + daily.count + 6) / 7
    return 20 + CGFloat(rows) * (cellH + gap) - gap
}

// MARK: - Share images (4:5, 540 × 675)

final class ShareView: ABPage {
    override func render() {
        let d = data
        let kind = d["kind"].s
        let x0: CGFloat = 30, W: CGFloat = 480
        var y: CGFloat = 28
        let mw = AB.wordmark(x0, y)
        put(AB.sans(ReportText.kindName(kind, share: true), 15, .medium, AB.gray), x0 + mw + 12, y + 2)
        let right = kind == "total" ? L("一起干活 \(d["days"].i) 天", "\(d["days"].i) days together") : ReportText.period(d, compact: true)
        put(kind == "total" ? AB.sans(right, 12, .regular, AB.gray) : AB.mono(right, 12, .regular, AB.gray), x0 + W, y + 4, align: 2)
        y += 36
        switch kind {
        case "total": y = total(d, y)
        default:
            if kind == "day" { y = crewPanel(d, y, compact: !d["boss"].isNull) }
            put(AB.sans(ReportText.lead(d, share: true), 15, .medium), x0, y)
            y += 20
            let big = AB.mono(fmtUSD(d["usd"].d), 52, .semibold, kern: -1.5)
            put(big, x0 - 2, y - 4)
            if let chip = ReportText.chip(d) {
                AB.pill(chip, x0 + big.size().width + 12, y + 16, dark: false, size: 12.5, padX: 11, padY: 4, fill: AB.greenSoft, ink: AB.greenText)
            }
            y += 56
            AB.fitLine({ AB.mono(ReportText.moneyLine(d), $0, .regular, AB.gray) }, 11.5, x0, y, W, least: 9)
            y += 26
            let boss = !d["boss"].isNull
            if boss { y = bossStrip(d, y) + 16 }
            y = chart(d, y, x0, W, compact: boss)
            y += 10
            let who = kind == "week" ? L("这周谁干的", "Who worked this week") : kind == "month" ? L("这个月谁干的", "Who worked this month")
                : kind == "year" ? L("这一年谁干的", "Who worked this year") : L("今天谁干的", "Who worked today")
            y += AB.header(who, L("按 BLS 时薪折成请人干的工时", "hours at BLS wages"), x0, y, W, size: 13.5) + 8
            // As many rows as fit above the footer.
            let fit = Int((bounds.height - 82 - 8 - y) / 31)
            _ = AB.crewRows(d["crew"].arr, x0, y, W, max: min(kind == "month" || kind == "year" ? 5 : 4, max(1, fit)))
        }
        footer(kind == "total")
    }

    /// The day's top crew standing on a dotted panel; lower with the boss
    /// strip under it.
    private func crewPanel(_ d: JV, _ y: CGFloat, compact: Bool = false) -> CGFloat {
        let r = NSRect(x: 30, y: y, width: 480, height: compact ? 104 : 138)
        AB.round(r, 24, AB.tile)
        color(hex: "#DEDEE2").setFill()
        var dy = r.minY + 12
        while dy < r.maxY - 6 {
            var dx = r.minX + 14
            while dx < r.maxX - 6 { NSBezierPath(ovalIn: NSRect(x: dx, y: dy, width: 2, height: 2)).fill(); dx += 16 }
            dy += 16
        }
        put(AB.sans(L("今天上班的团子", "On shift today"), 11, .regular, AB.gray), r.minX + 16, r.minY + 14)
        let crew = d["crew"].arr.filter { !$0["art"].s.isEmpty }.prefix(3).map { $0["art"].s }
        let order = crew.count >= 3 ? [crew[1], crew[0], crew[2]] : crew
        let k: CGFloat = compact ? 0.72 : 1
        let sizes: [CGFloat] = (order.count == 3 ? [84, 120, 84] : order.map { _ in 104 }).map { $0 * k }
        var x = r.midX - (sizes.reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * 4) / 2
        for (k, art) in order.enumerated() {
            let w = sizes[k]
            AB.fit(roleArt(art), NSRect(x: x, y: r.maxY - 16 - w * 0.8, width: w, height: w * 0.8), align: 1)
            x += w + 4
        }
        return r.maxY + 14
    }

    /// The period's boss type, from its own turns: picture, code and name,
    /// and the type's line.
    private func bossStrip(_ d: JV, _ y: CGFloat) -> CGFloat {
        let r = NSRect(x: 30, y: y, width: 480, height: 66)
        AB.round(r, 18, AB.tile)
        let code = d["boss"]["code"].s
        AB.fit(abtiImage("scene/T-" + code), NSRect(x: r.minX + 10, y: r.minY + 6, width: 66, height: 54), align: 1)
        let tx = r.minX + 88, tw = r.maxX - 16 - tx
        let kind = d["kind"].s
        let who = kind == "week" ? L("这一周，你是", "This week you were") : kind == "month" ? L("这个月，你是", "This month you were")
            : kind == "year" ? L("这一年，你是", "This year you were") : L("今天，你是", "Today you were")
        put(AB.sans(who, 11, .regular, AB.gray), tx, r.minY + 9)
        put(AB.join([AB.mono(code + "  ", 16, .semibold, kern: 1), AB.sans(ABText.typeName(code), 15, .semibold)]), tx, r.minY + 24)
        AB.sans(ABText.roast(code), 11.5, .regular, AB.gray).draw(with: NSRect(x: tx, y: r.minY + 46, width: tw, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return r.maxY
    }

    /// The period's chart: hours, the week's days, or the month's calendar.
    /// `compact` leaves room for the boss strip.
    private func chart(_ d: JV, _ y0: CGFloat, _ x0: CGFloat, _ W: CGFloat, compact: Bool = false) -> CGFloat {
        var y = y0
        let barsH: CGFloat = compact ? 110 : 170
        switch d["kind"].s {
        case "week":
            let daily = d["daily"].arr
            let vals: [Double?] = daily.map { $0.isNull ? nil : $0.d }
            let best = vals.enumerated().compactMap { (i, v) -> (Int, Double)? in v.map { (i, $0) } }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            y += AB.header(L("每天产出", "Each day"), best.map { L("最拼的一天：", "Best day: ") + ReportText.wd($0.0) }, x0, y, W, size: 13.5) + 10
            drawBars(vals, NSRect(x: x0, y: y, width: W, height: barsH), mark: best?.0, labels: (0..<7).map { ($0, ReportText.wd($0)) }, gap: 20, labelSize: 10.5)
            return y + barsH + 20
        case "year":
            let vals: [Double?] = d["monthly"].arr.map { $0.isNull ? nil : $0.d }
            let best = vals.enumerated().compactMap { (i, v) -> (Int, Double)? in v.map { (i, $0) } }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            y += AB.header(L("每月产出", "Each month"), best.map { L("最拼的一个月：", "Best month: ") + ReportText.month($0.0) }, x0, y, W, size: 13.5) + 10
            drawBars(vals, NSRect(x: x0, y: y, width: W, height: barsH), mark: best?.0, labels: (0..<12).map { ($0, ReportText.month($0)) }, gap: 10, labelSize: 10)
            return y + barsH + 20
        case "month":
            let h = d["highlights"]
            y += AB.header(L("每天产出", "Each day"), L("开工 \(h["active_days"].i) 天 · 最长连续 \(h["longest_streak"].i) 天", "\(h["active_days"].i) days on · longest streak \(h["longest_streak"].i)"), x0, y, W, size: 13.5) + 8
            y += drawCalendar(d, x0, y, W, cellH: compact ? 18 : 26, gap: compact ? 4 : 5) + 8
            let lw = AB.heatLegend(x0, y)
            _ = lw
            put(AB.sans(L("黑框 = 今天 · 虚线 = 还没到", "outline = today · dashed = not yet"), 10.5, .regular, AB.gray), x0 + W, y, align: 2)
            return y + 18
        default:
            let hours = d["hourly"].arr.map { $0.d }
            let busiest = d["highlights"]["busiest_hour"]
            y += AB.header(L("每小时产出", "Each hour"), busiest.isNull ? nil : L("\(busiest.i) 点最忙", "busiest at \(busiest.i):00"), x0, y, W, size: 13.5) + 8
            drawBars(hours.map { Optional($0) }, NSRect(x: x0, y: y, width: W, height: 62), mark: busiest.isNull ? nil : busiest.i,
                     labels: [(0, "0"), (6, "6"), (12, "12"), (18, "18"), (23, "23")], gap: 4)
            return y + 62 + 18
        }
    }

    /// The all-time share: who you are, the money, every day, the crew.
    private func total(_ d: JV, _ y0: CGFloat) -> CGFloat {
        let x0: CGFloat = 30, W: CGFloat = 480
        var y = y0
        let code = d["boss"]["code"].s
        AB.fit(abtiImage("scene/T-" + code), NSRect(x: x0, y: y + 30, width: 196, height: 170), align: 1)
        let tx = x0 + 212, tw = W - 212
        put(AB.mono(L("你是", "YOU ARE"), 11, .regular, AB.gray), tx, y)
        put(AB.mono(code, 30, .semibold, kern: 1.2), tx, y + 14)
        var cy = y + 52
        cy += AB.para(AB.sans(ABText.typeName(code), 21, .semibold), tx, cy, tw) + 8
        let p1 = AB.pill(scalePill(d["boss"]["scale"].s), tx, cy, dark: true, size: 11.5)
        AB.pill(L("压榨率 ", "Margin ") + String(format: "%.1f%%", d["boss"]["margin"].d * 100), p1.maxX + 6, cy, dark: false, size: 11.5)
        cy += 30
        cy += AB.para(AB.sans("“" + ABText.roast(code) + "”", 12.5, .medium), tx, cy, tw, lineHeight: 18) + 10
        AB.line.setFill()
        NSRect(x: tx, y: cy, width: tw, height: 1).fill()
        cy += 12
        put(AB.sans(ReportText.lead(d, share: true), 12.5, .medium), tx, cy)
        cy += 18
        let big = AB.mono(fmtUSD(d["usd"].d), 38, .semibold, kern: -1)
        put(big, tx - 1, cy)
        cy += big.size().height + 1
        AB.para(AB.mono(ReportText.moneyLine(d), 10.5, .regular, AB.gray), tx, cy, tw)
        y = max(y + 230, cy + 26)
        // Every day since the start, one column a week, Monday on top.
        y += AB.header(L("\(d["days"].i) 天每天的产出", "Every day of \(d["days"].i)"), L("颜色越深，那天团子干得越多", "darker = more work that day"), x0, y, W, size: 13.5) + 10
        let heat = d["heat"].arr
        let first = d["first_weekday"].i
        let cols = (first + heat.count + 6) / 7
        let gridW: CGFloat = 278
        let cell = min(11, (gridW - CGFloat(cols - 1) * 2) / CGFloat(max(1, cols)))
        // Long histories get taller rows so the grid still reads.
        let rowCell = max(cell, min(9, cell * 1.4))
        let best = d["best_day"]["date"].s
        for (i, v) in heat.enumerated() {
            let slot = first + i
            let r = NSRect(x: x0 + CGFloat(slot / 7) * (cell + 2), y: y + CGFloat(slot % 7) * (rowCell + 2), width: cell, height: rowCell)
            AB.round(r, 2, v.isNull ? .white : AB.heatColor(v.i))
            if !best.isEmpty, dayString(d["since"].s, plus: i) == best { AB.stroke(r.insetBy(dx: -1, dy: -1), 3, AB.ink, 1.2) }
        }
        let sx = x0 + gridW + 22
        var sy = y
        for (k, v) in [(L("开工", "Days on"), L("\(d["active_days"].i) 天", "\(d["active_days"].i)")), (L("最长连续", "Longest streak"), L("\(d["longest_streak"].i) 天", "\(d["longest_streak"].i) days")),
                       (L("最拼的一天", "Best day"), AB.short(best) + " · " + fmtUSD(d["best_day"]["usd"].d))] {
            // The value right-aligned: an English label is wider than a
            // fixed column ("Longest streak" ran into its value).
            put(AB.sans(k, 11, .regular, AB.gray), sx, sy + 3)
            put(AB.mono(v, 13, .semibold), x0 + W, sy, align: 2)
            sy += 24
        }
        _ = AB.heatLegend(sx, sy + 2, cell: 9)
        y += max(7 * (rowCell + 2), sy + 18 - y) + 14
        y += AB.header(L("\(d["days"].i) 天里谁干的", "Who worked, \(d["days"].i) days"), L("按 BLS 时薪折成请人干的工时", "hours at BLS wages"), x0, y, W, size: 13.5) + 6
        // As many rows as fit above the footer (a two-line roast in English
        // pushed the fifth into it).
        let rows = Swift.max(1, Swift.min(5, Int((bounds.height - 82 - y) / 25)))
        return y + AB.crewRows(d["crew"].arr, x0, y, W, max: rows, rowH: 25)
    }

    private func footer(_ total: Bool) {
        let y = bounds.height - 82
        AB.line.setFill()
        NSRect(x: 30, y: y, width: 480, height: 1).fill()
        // How it's counted, and the website (dangoai.org; 2026-11-07 the user
        // wanted no link because the address then was dango.app, not ours).
        let note = AB.sans(total ? L("全在本机算 · 不读代码和 prompt · 不上传", "Runs on your Mac · never reads code or prompts · nothing uploaded")
                                 : L("全在本机算 · 按 BLS 各职业中位时薪折算 · 不含项目名", "Runs on your Mac · BLS median wages · no project names"), 11, .regular, AB.gray)
        put(note, 30, y + 30)
        AB.siteMark(30, y + 30, 480, noteW: note.size().width)
    }
}

/// "2026-06-11" + n days.
func dayString(_ from: String, plus n: Int) -> String {
    guard let d = AB.date(from), let x = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: d) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: x)
}

// MARK: - The report window (560 × 822 under the title bar)

/// Runs `dango ARGS` and returns its stdout as JSON (nil when it fails).
func dangoJSON(_ args: [String]) -> JV? {
    guard let cli = cliPath() else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let j = JV.parse(data)
    return p.terminationStatus == 0 && !j.isNull ? j : nil
}

/// Where exported images go (the same folder as the other cards).
let exportDir = NSHomeDirectory() + "/Pictures/DANGO"

final class ReportView: ABPage {
    var kind = "day"
    /// Any day in the period shown.
    var anchor = Date()
    private var hits: [(String, NSRect)] = []
    private var toast: (String, Double)?
    private var loading = false
    /// Under the chart: the crew, or what got done (titles and folders,
    /// on this Mac only).
    var section = "crew"

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Loads the page for `kind` and `anchor` in the background.
    func reload() {
        loading = true
        let args = ["abti", "--report", kind, "--day", Self.fmt.string(from: anchor)]
        DispatchQueue.global().async {
            let j = dangoJSON(args)
            DispatchQueue.main.async {
                self.loading = false
                if let j { self.data = j }
                self.needsDisplay = true
            }
        }
    }

    override func render() {
        hits = []
        let d = data
        let x0: CGFloat = 24, W: CGFloat = bounds.width - 48
        var y: CGFloat = 20
        if !d["lang"].s.isEmpty { lang = d["lang"].s }
        // Tabs, and the period with arrows.
        let tabs = ["day", "week", "month", "year", "total"].map { ($0, ReportText.kindName($0, share: false)) }
        let tw: CGFloat = cjk ? 50 : 60
        let cap = NSRect(x: x0, y: y, width: tw * CGFloat(tabs.count) + 6, height: 34)
        AB.round(cap, 17, AB.control)
        for (k, (id, name)) in tabs.enumerated() {
            let r = NSRect(x: cap.minX + 3 + CGFloat(k) * tw, y: cap.minY + 3, width: tw, height: 28)
            if id == kind {
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowColor = NSColor.black.withAlphaComponent(0.1)
                sh.shadowBlurRadius = 3
                sh.shadowOffset = NSSize(width: 0, height: -1)
                sh.set()
                AB.round(r, 14, .white)
                NSGraphicsContext.restoreGraphicsState()
            }
            let t = AB.sans(name, 13, id == kind ? .semibold : .regular, id == kind ? AB.ink : AB.gray)
            put(t, r.midX, r.midY - t.size().height / 2, align: 1)
            hits.append(("tab:" + id, r))
        }
        if !d.isNull {
            let label = AB.mono(ReportText.period(d), 12.5, .regular)
            let next = NSRect(x: x0 + W - 28, y: y + 3, width: 28, height: 28)
            let prev = NSRect(x: next.minX - label.size().width - 24 - 28, y: y + 3, width: 28, height: 28)
            let canNext = kind != "total" && d["to"].s < d["today"].s
            for (r, glyph, on) in [(prev, "‹", kind != "total"), (next, "›", canNext)] {
                AB.stroke(r, 14, AB.line, 1)
                let g = AB.sans(glyph, 16, .medium, on ? AB.ink : color(hex: "#C9C9CE"))
                put(g, r.midX, r.midY - g.size().height / 2 - 1, align: 1)
            }
            put(label, prev.maxX + 12, y + 17 - label.size().height / 2)
            if kind != "total" { hits.append(("prev", prev)) }
            if canNext { hits.append(("next", next)) }
        }
        y += 56
        guard !d.isNull else {
            put(AB.sans(loading ? L("正在算…", "Working it out…") : L("还没有数据", "No data yet"), 13, .regular, AB.gray), x0, y)
            return
        }
        // The big number.
        put(AB.sans(ReportText.lead(d, share: false), 14, .regular, AB.gray), x0, y)
        y += 20
        let big = AB.mono(fmtUSD(d["usd"].d), 52, .semibold, kern: -1.5)
        put(big, x0 - 2, y - 4)
        if let chip = ReportText.chip(d) {
            AB.pill(chip, x0 + big.size().width + 12, y + 16, dark: false, size: 12.5, padX: 11, padY: 4, fill: AB.greenSoft, ink: AB.greenText)
        }
        y += 62
        // Three numbers.
        let lv = d["leverage"].isNull ? "—" : AB.lev(d["leverage"].d)
        let tiles: [(String, String)] = kind == "total"
            ? [(L("实发", "Paid"), fmtUSD(d["cost"].d)), (L("杠杆", "Leverage"), lv), (L("活跃", "Active"), L("\(d["active_days"].i) 天", "\(d["active_days"].i) days"))]
            : [(L("模型花了", "Model cost"), fmtUSD(d["cost"].d)), (L("杠杆", "Leverage"), lv), (ReportText.prevName(d), ReportText.change(d["vs_prev"]))]
        let tW = (W - 20) / 3
        for (k, t) in tiles.enumerated() {
            let r = NSRect(x: x0 + CGFloat(k) * (tW + 10), y: y, width: tW, height: 54)
            AB.round(r, 16, AB.tile)
            put(AB.sans(t.0, 11, .regular, AB.gray), r.minX + 14, r.minY + 9)
            put(AB.mono(t.1, 17, .semibold), r.minX + 14, r.minY + 25)
        }
        y += 54 + 22
        // The chart.
        switch kind {
        case "week":
            let vals: [Double?] = d["daily"].arr.map { $0.isNull ? nil : $0.d }
            let todayIdx = d["elapsed"].i - 1
            y += AB.header(L("每天产出", "Each day"), L("虚线 = 还没到", "dashed = not yet"), x0, y, W, size: 13) + 12
            drawBars(vals, NSRect(x: x0, y: y, width: W, height: 150), mark: d["to"].s >= d["today"].s ? todayIdx : nil, labels: (0..<7).map { ($0, ReportText.wd($0)) }, gap: 24)
            y += 150 + 30
        case "month":
            y += AB.header(L("每天产出", "Each day"), L("开工 \(d["highlights"]["active_days"].i) 天", "\(d["highlights"]["active_days"].i) days on"), x0, y, W, size: 13) + 10
            y += drawCalendar(d, x0, y, W, cellH: 22, gap: 5) + 8
            _ = AB.heatLegend(x0, y)
            put(AB.sans(L("黑框 = 今天 · 虚线 = 还没到", "outline = today · dashed = not yet"), 10.5, .regular, AB.gray), x0 + W, y, align: 2)
            y += 28
        case "year":
            let vals: [Double?] = d["monthly"].arr.map { $0.isNull ? nil : $0.d }
            let best = d["highlights"]["best_month"]
            let cur = d["to"].s >= d["today"].s ? d["elapsed"].i - 1 : nil
            y += AB.header(L("每月产出", "Each month"), L("虚线 = 还没到", "dashed = not yet"), x0, y, W, size: 13) + 12
            drawBars(vals, NSRect(x: x0, y: y, width: W, height: 150), mark: cur ?? (best.isNull ? nil : (Int(best["month"].s.suffix(2)) ?? 1) - 1),
                     labels: (0..<12).map { ($0, ReportText.month($0)) }, gap: 10)
            y += 150 + 30
        case "total":
            let months = d["monthly"].arr
            let vals: [Double?] = months.map { $0[1].d }
            let best = months.indices.max { months[$0][1].d < months[$1][1].d }
            let note = best.map { L("\(Int(months[$0][0].s.suffix(2)) ?? 0) 月是开工以来最多的一个月", "\(months[$0][0].s) was the biggest month") }
            y += AB.header(L("每月产出", "Each month"), note, x0, y, W, size: 13) + 12
            let shown = Array(vals.suffix(8))
            drawBars(shown, NSRect(x: x0, y: y, width: W, height: 150), mark: shown.count - 1,
                     labels: Array(months.suffix(8).enumerated().map { ($0.0, L("\(Int($0.1[0].s.suffix(2)) ?? 0) 月", String($0.1[0].s.suffix(5)))) }), gap: 16)
            y += 150 + 30
        default:
            let hours = d["hourly"].arr.map { Optional($0.d) }
            let b = d["highlights"]["busiest_hour"]
            y += AB.header(L("每小时产出", "Each hour"), b.isNull ? nil : L("\(b.i) 点最忙", "busiest at \(b.i):00"), x0, y, W, size: 13) + 12
            drawBars(hours, NSRect(x: x0, y: y, width: W, height: 150), mark: b.isNull ? nil : b.i, labels: [(0, "0"), (6, "6"), (12, "12"), (18, "18"), (23, "23")], gap: 4)
            y += 150 + 30
        }
        // The crew, or what got done: a switch in the section's header.
        var sx = x0
        for (id, name) in [("crew", L("团子构成", "Your crew")), ("work", L("做了哪些事", "What got done"))] {
            let t = AB.sans(name, 13, .semibold, id == section ? AB.ink : AB.gray)
            let r = NSRect(x: sx, y: y - 5, width: t.size().width + 22, height: 28)
            if id == section { AB.round(r, 14, AB.control) }
            put(t, r.midX, r.midY - t.size().height / 2, align: 1)
            hits.append(("sec:" + id, r))
            sx = r.maxX + 4
        }
        let secNote = section == "crew" ? L("按各职业计时分钟 × BLS 时薪", "minutes per job × BLS wage") : L("只在本机显示，不进分享图", "this Mac only, never on share images")
        put(AB.sans(secNote, 11, .regular, AB.gray), x0 + W, y, align: 2)
        y += 30
        let rowsMax = kind == "total" ? 5 : 4
        if section == "crew" {
            AB.crewBar(d["crew"].arr, x0, y, W)
            y += 12
            y += AB.crewRows(d["crew"].arr, x0, y, W, max: rowsMax, rowH: 30, showHours: false, showShare: true, nameSize: 13, numSize: 13)
        } else {
            y += 12
            y += max(CGFloat(min(rowsMax, max(1, d["crew"].arr.count))) * 30, workRows(d, x0, y, W, max: rowsMax))
        }
        y += 16
        // Highlights, or who you are for the total.
        if kind == "total" {
            let box = NSRect(x: x0, y: y, width: W, height: 100)
            AB.round(box, 20, AB.tile)
            let code = d["boss"]["code"].s
            AB.fit(abtiImage("scene/T-" + code), NSRect(x: box.minX + 12, y: box.minY + 8, width: 110, height: 84))
            let tx = box.minX + 134
            put(AB.join([AB.mono(code + " ", 16, .semibold), AB.sans(ABText.typeName(code), 16, .semibold)]), tx, box.minY + 14)
            let p1 = AB.pill(scalePill(d["boss"]["scale"].s), tx, box.minY + 40, dark: true, size: 11)
            AB.pill(L("压榨率 ", "Margin ") + String(format: "%.1f%%", d["boss"]["margin"].d * 100) + " · " + cw(ABText.margin(abtiMarginIndex(d)), "name"), p1.maxX + 6, box.minY + 40, dark: false, size: 11)
            AB.sans(ABText.roast(code), 12, .regular, AB.gray).draw(with: NSRect(x: tx, y: box.minY + 68, width: box.maxX - 14 - tx, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            let h = d["highlights"]
            let cards: [(String, String, String)]
            switch kind {
            case "week":
                let best = h["best_day"].s
                cards = [(L("最拼的一天", "Best day"), best.isEmpty ? "—" : AB.weekday(best), best.isEmpty ? "" : AB.short(best)),
                         (L("开工", "Days on"), L("\(h["active_days"].i) / \(d["elapsed"].i) 天", "\(h["active_days"].i) / \(d["elapsed"].i) days"), h["active_days"].i >= d["elapsed"].i ? L("这周一天没歇", "not a day off") : ""),
                         (L("最晚收工", "Latest finish"), h["latest_end"].isNull ? "—" : h["latest_end"].s, "")]
            case "year":
                let bm = h["best_month"]
                cards = [(L("最拼的一个月", "Best month"), bm.isNull ? "—" : ReportText.month((Int(bm["month"].s.suffix(2)) ?? 1) - 1), bm.isNull ? "" : fmtUSD(bm["usd"].d)),
                         (L("开工", "Days on"), L("\(h["active_days"].i) 天", "\(h["active_days"].i) days"), ""),
                         (L("最长连续", "Longest streak"), L("\(h["longest_streak"].i) 天", "\(h["longest_streak"].i) days"), "")]
            case "month":
                let best = h["best_day"].s
                cards = [(L("开工", "Days on"), L("\(h["active_days"].i) 天", "\(h["active_days"].i) days"), L("一共 \(d["elapsed"].i) 天", "of \(d["elapsed"].i)")),
                         (L("最长连续", "Longest streak"), L("\(h["longest_streak"].i) 天", "\(h["longest_streak"].i) days"), ""),
                         (L("最拼的一天", "Best day"), best.isEmpty ? "—" : AB.short(best), "")]
            default:
                let b = h["busiest_hour"]
                let hourly = d["hourly"].arr
                cards = [(L("最长一回合", "Longest turn"), L("\(Int(h["longest_turn_min"].d.rounded())) 分钟", "\(Int(h["longest_turn_min"].d.rounded())) min"), L("AI 自己连续干", "the AI on its own")),
                         (L("最忙的一小时", "Busiest hour"), b.isNull ? "—" : L("\(b.i) 点", "\(b.i):00"), b.isNull ? "" : fmtUSD(hourly[b.i].d)),
                         (L("最晚收工", "Last finish"), h["last_end"].isNull ? "—" : h["last_end"].s, L("这天最后一个回合", "the day's last turn"))]
            }
            for (k, c) in cards.enumerated() {
                let r = NSRect(x: x0 + CGFloat(k) * (tW + 10), y: y, width: tW, height: 74)
                AB.stroke(r, 16, AB.line, 1)
                put(AB.sans(c.0, 11, .regular, AB.gray), r.minX + 14, r.minY + 11)
                put(AB.mono(c.1, 17, .semibold), r.minX + 14, r.minY + 27)
                put(AB.sans(c.2, 11, .regular, AB.gray), r.minX + 14, r.minY + 52)
            }
        }
        // The bottom bar: a note, copy, export.
        let by = bounds.height - 24 - 44
        let expW = max(124, AB.sans("⇪  " + L("导出", "Export ") + ReportText.kindName(kind, share: true), 14, .semibold).size().width + 36)
        let exp = NSRect(x: x0 + W - expW, y: by, width: expW, height: 44)
        let copyR = NSRect(x: exp.minX - 54, y: by, width: 44, height: 44)
        // The note wraps to a second line rather than run under the buttons.
        let note = AB.sans(L("分享图 4:5 · 全在本机生成 · 不含项目名和会话标题", "4:5 image · made on your Mac · no project names or titles"), 11, .regular, AB.gray)
        let noteW = copyR.minX - 12 - x0
        let noteH = AB.para(note, x0, 0, noteW, lineHeight: 15, draw: false)
        _ = AB.para(note, x0, by + 22 - noteH / 2, noteW, lineHeight: 15)
        AB.round(copyR, 14, AB.control)
        for (dx, dy) in [(CGFloat(-2), CGFloat(-2)), (2, 2)] {
            AB.stroke(NSRect(x: copyR.midX - 6 + dx, y: copyR.midY - 6 + dy, width: 12, height: 12), 3, AB.ink, 1.4)
        }
        AB.round(exp, 14, AB.ink)
        let et = AB.sans("⇪  " + L("导出", "Export ") + ReportText.kindName(kind, share: true), 14, .semibold, .white)
        put(et, exp.midX, exp.midY - et.size().height / 2, align: 1)
        hits.append(("copy", copyR))
        hits.append(("export", exp))
        // A toast after exporting.
        if let (msg, until) = toast, Date().timeIntervalSince1970 < until {
            let t = AB.sans(msg, 12, .medium, .white)
            let r = NSRect(x: bounds.midX - t.size().width / 2 - 16, y: by - 50, width: t.size().width + 32, height: 34)
            AB.round(r, 17, AB.ink.withAlphaComponent(0.92))
            put(t, r.midX, r.midY - t.size().height / 2, align: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (id, _) = hits.last(where: { $0.1.contains(p) }) else { return }
        let cal = Calendar(identifier: .gregorian)
        switch id {
        case "prev", "next":
            let step = id == "prev" ? -1 : 1
            let unit: Calendar.Component = kind == "week" ? .weekOfYear : kind == "month" ? .month : kind == "year" ? .year : .day
            anchor = cal.date(byAdding: unit, value: step, to: anchor) ?? anchor
            reload()
        case "copy":
            share(save: false)
        case "export":
            share(save: true)
        default:
            if id.hasPrefix("sec:") { section = String(id.dropFirst(4)) }
            if id.hasPrefix("tab:") {
                kind = String(id.dropFirst(4))
                anchor = Date()
                data = JV(nil)
                reload()
            }
        }
        needsDisplay = true
    }

    /// What got done: the top sessions for a day or a week (their titles,
    /// folder, tool and time), the top project folders for longer periods.
    private func workRows(_ d: JV, _ x0: CGFloat, _ y0: CGFloat, _ W: CGFloat, max n: Int) -> CGFloat {
        let bySession = kind == "day" || kind == "week"
        let rows = Array((bySession ? d["sessions"] : d["projects"]).arr.prefix(n))
        let rowH: CGFloat = 30
        guard !rows.isEmpty else {
            put(AB.sans(L("这段时间还没干活", "Nothing done in this stretch yet"), 12.5, .regular, AB.gray), x0, y0 + 6)
            return rowH
        }
        var y = y0
        for r in rows {
            let hours = AB.hours(r["minutes"].d / 60)
            let title: String, sub: String
            if bySession {
                title = r["title"].isNull ? L("没起标题的会话", "Untitled session") : r["title"].s
                sub = ([r["project"].isNull ? nil : r["project"].s, r["tool"].s, hours] as [String?]).compactMap { $0 }.joined(separator: " · ")
            } else {
                title = r["project"].s
                sub = L("\(r["sessions"].i) 个会话", r["sessions"].i == 1 ? "1 session" : "\(r["sessions"].i) sessions") + " · " + hours
            }
            let usd = AB.mono(fmtUSD(r["usd"].d), 13, .semibold)
            put(usd, x0 + W, y + (rowH - usd.size().height) / 2, align: 2)
            let line = AB.join([AB.sans(title, 13, .medium), AB.sans("   " + sub, 11.5, .regular, AB.gray)])
            let m = NSMutableAttributedString(attributedString: line)
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
            m.draw(with: NSRect(x: x0, y: y + (rowH - 18) / 2, width: W - usd.size().width - 18, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += rowH
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W, height: 1).fill()
        }
        return y - y0
    }

    /// The page's 4:5 image: copied, and saved too when exporting.
    private func share(save: Bool) {
        guard !data.isNull else { return }
        let v = ShareView(size: NSSize(width: 540, height: 675), data: data)
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        let name = "dango-\(kind)-\(data["from"].s).png"
        let path = save ? exportDir + "/" + name : NSTemporaryDirectory() + name
        guard exportPage(v, path, copy: true) else { return }
        let msg = save ? L("已导出到 ~/Pictures/DANGO，图片也复制好了，可以直接粘贴", "Saved to ~/Pictures/DANGO and copied; paste it anywhere")
            : L("图片复制好了，可以直接粘贴", "Copied; paste it anywhere")
        toast = (msg, Date().timeIntervalSince1970 + 2.5)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.needsDisplay = true }
    }
}

/// The report window: one at a time.
final class ReportWindow {
    static var shared: NSWindow?

    static func show(kind: String = "day") {
        let size = NSSize(width: 560, height: 822)
        if let w = shared {
            (w.contentView as? ReportView)?.kind = kind
            (w.contentView as? ReportView)?.reload()
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("DANGO 报告", "DANGO Reports")
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        let v = ReportView(size: size, data: JV(nil))
        v.kind = kind
        w.contentView = v
        w.center()
        shared = w
        v.reload()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
