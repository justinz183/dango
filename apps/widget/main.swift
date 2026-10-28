// shadowcorp-widget: a small always-on-top panel in the bottom-right corner
// of the screen showing output value ($), rank and XP. Click it to expand a
// dashboard (today / week / month / total, 30-day chart, rank road, task
// types, recent turns); click its header or anywhere else to collapse.
// Reads ~/.shadowcorp/widget.json (written by the daemon) every 2 seconds.
// No dock icon, no menu bar item; right-click for the menu.
//
// Build: apps/widget/build.sh (binary) or apps/widget/bundle.sh (ShadowCorp.app)
// Snapshots (no window): --snapshot out.png, --snapshot-dashboard out.png

import AppKit
import Foundation

signal(SIGHUP, SIG_IGN)

let home = ProcessInfo.processInfo.environment["SHADOWCORP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSHomeDirectory() + "/.shadowcorp"
let dataURL = URL(fileURLWithPath: home + "/widget.json")
let agentLabel = "com.shadowcorp.widget"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let widgetSize = NSSize(width: 256, height: 78)
let dashboardWidth: CGFloat = 420
let originKey = "compactOrigin"

// Output bars: one hue (single series), brighter for today.
let barColor = NSColor(red: 0.47, green: 0.72, blue: 0.65, alpha: 1)
let barToday = NSColor(red: 0.65, green: 0.88, blue: 0.81, alpha: 1)

struct DayPoint { var day = ""; var usd = 0.0; var turns = 0 }
struct RankStep { var name = ""; var xp = 0; var color = NSColor.gray }
struct ClassShare { var name = ""; var usd = 0.0; var turns = 0 }
struct TurnRow { var at = 0.0; var name = ""; var usd = 0.0; var files = 0; var testPassed: Bool? }

struct Model {
    var totalUSD = 0.0
    var totalPD = 0.0
    var todayUSD = 0.0
    var todayPD = 0.0
    var weekUSD = 0.0
    var weekPD = 0.0
    var monthUSD = 0.0
    var monthPD = 0.0
    var weekLeverage: Double?
    var hourlyRate = 0.0
    var xp = 0
    var rankIndex = 0
    var rankLabel = "—"
    var nextLabel: String?
    var rankColor = NSColor.gray
    var progress = 0.0
    var xpToNext: Int?
    var level = 0
    var working = 0
    var subagents = 0
    var generatedAt = 0.0
    var days: [DayPoint] = []
    var ranks: [RankStep] = []
    var classes: [ClassShare] = []
    var turns: [TurnRow] = []
}

func color(hex: String) -> NSColor {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .gray }
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func loadModel() -> Model? {
    guard let data = try? Data(contentsOf: dataURL),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    func obj(_ k: String) -> [String: Any] { j[k] as? [String: Any] ?? [:] }
    func list(_ k: String) -> [[String: Any]] { j[k] as? [[String: Any]] ?? [] }
    var m = Model()
    let total = obj("total"), today = obj("today"), week = obj("week"), month = obj("month")
    let rank = obj("rank"), act = obj("activity")
    m.totalUSD = total["usd"] as? Double ?? 0
    m.totalPD = total["person_days"] as? Double ?? 0
    m.todayUSD = today["usd"] as? Double ?? 0
    m.todayPD = today["person_days"] as? Double ?? 0
    m.weekUSD = week["usd"] as? Double ?? 0
    m.weekPD = week["person_days"] as? Double ?? 0
    m.weekLeverage = week["leverage"] as? Double
    m.monthUSD = month["usd"] as? Double ?? 0
    m.monthPD = month["person_days"] as? Double ?? 0
    m.hourlyRate = j["hourly_rate_usd"] as? Double ?? 0
    m.xp = total["xp"] as? Int ?? 0
    m.rankIndex = rank["index"] as? Int ?? 0
    m.rankLabel = rank["label"] as? String ?? "—"
    m.nextLabel = rank["next_label"] as? String
    m.rankColor = color(hex: rank["color"] as? String ?? "")
    m.progress = rank["progress"] as? Double ?? 0
    m.xpToNext = rank["xp_to_next"] as? Int
    let division = rank["division"] as? Int ?? 0
    m.level = m.rankIndex * 4 + (division == 0 ? 4 : 4 - division)
    m.working = act["working"] as? Int ?? 0
    m.subagents = act["subagents"] as? Int ?? 0
    m.generatedAt = j["generated_at"] as? Double ?? 0
    m.days = list("days").map { DayPoint(day: $0["day"] as? String ?? "", usd: $0["usd"] as? Double ?? 0, turns: $0["turns"] as? Int ?? 0) }
    m.ranks = list("ranks").map { RankStep(name: $0["name"] as? String ?? "", xp: $0["xp"] as? Int ?? 0, color: color(hex: $0["color"] as? String ?? "")) }
    m.classes = list("classes").map { ClassShare(name: $0["name"] as? String ?? "", usd: $0["usd"] as? Double ?? 0, turns: $0["turns"] as? Int ?? 0) }
    m.turns = list("turns").map {
        TurnRow(at: $0["at"] as? Double ?? 0, name: $0["name"] as? String ?? "", usd: $0["usd"] as? Double ?? 0,
                files: $0["files"] as? Int ?? 0, testPassed: $0["test_passed"] as? Bool)
    }
    return m
}

let intFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f
}()

func fmtUSD(_ x: Double) -> String {
    if abs(x) < 10 { return String(format: "$%.1f", x) }
    return "$" + (intFormatter.string(from: NSNumber(value: x.rounded())) ?? "0")
}

func fmtInt(_ n: Int) -> String {
    intFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func fmtK(_ n: Int) -> String {
    n >= 1000 ? "\(n / 1000)k" : "\(n)"
}

func roman(_ label: String) -> String {
    label.split(separator: " ").last.map(String.init).flatMap { ["I", "II", "III", "IV"].contains($0) ? $0 : nil } ?? "★"
}

let primary = NSColor.white
let secondary = NSColor.white.withAlphaComponent(0.62)
let faint = NSColor.white.withAlphaComponent(0.14)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = primary, mono: Bool = false) -> NSAttributedString {
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
}

/// Draws `s` at x with `align` 0 = left, 1 = centred, 2 = right.
func put(_ s: NSAttributedString, _ x: CGFloat, _ y: CGFloat, align: Int = 0) {
    let w = s.size().width
    s.draw(at: NSPoint(x: align == 0 ? x : align == 1 ? x - w / 2 : x - w, y: y))
}

func medal(_ r: NSRect, _ c: NSColor, _ numeral: String, size: CGFloat, glow: Bool = false) {
    if glow {
        c.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -5, dy: -5)).fill()
    }
    c.setFill()
    NSBezierPath(ovalIn: r).fill()
    NSColor.black.withAlphaComponent(0.18).setStroke()
    let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
    ring.lineWidth = 1
    ring.stroke()
    let n = text(numeral, size: size, weight: .bold, color: NSColor.black.withAlphaComponent(0.75))
    let ns = n.size()
    n.draw(at: NSPoint(x: r.midX - ns.width / 2, y: r.midY - ns.height / 2 + 0.5))
}

func bar(_ r: NSRect, _ progress: Double, _ c: NSColor) {
    faint.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    let w = max(r.height, r.width * CGFloat(min(1, max(0, progress))))
    c.setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height), xRadius: r.height / 2, yRadius: r.height / 2).fill()
}

// MARK: - Compact widget

final class WidgetView: NSView {
    var model: Model?
    var drawBackground = false
    var flashUntil = Date.distantPast
    var flashText = ""
    var tick = 0
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: b, xRadius: 14, yRadius: 14).fill()
        }
        guard let m = model else {
            put(text("等待数据…", size: 12, weight: .medium, color: secondary), 14, 32)
            put(text("在终端运行 shadowcorp widget", size: 10, color: secondary), 14, 16)
            return
        }
        let flashing = Date() < flashUntil
        medal(NSRect(x: 14, y: (b.height - 38) / 2, width: 38, height: 38), m.rankColor, roman(m.rankLabel), size: 13, glow: flashing)
        let x0: CGFloat = 62
        let right = b.width - 14
        put(text(fmtUSD(m.totalUSD), size: 20, weight: .bold, mono: true), x0, 44)
        put(text("今日 " + fmtUSD(m.todayUSD), size: 11, color: secondary, mono: true), right, 48, align: 2)
        if flashing {
            put(text(flashText, size: 12, weight: .semibold, color: m.rankColor), x0, 25)
        } else {
            put(text(m.rankLabel, size: 12, weight: .semibold, color: m.rankColor), x0, 25)
            let xpText = m.xpToNext.map { "\(fmtInt(m.xp)) XP · 还差 \(fmtInt($0))" } ?? "\(fmtInt(m.xp)) XP"
            put(text(xpText, size: 10, color: secondary, mono: true), right, 26, align: 2)
        }
        bar(NSRect(x: x0, y: 14, width: right - x0, height: 4), m.progress, m.rankColor)
        // Working indicator: a pulsing dot while an agent is on a turn.
        if m.working > 0 {
            let pulse = 0.55 + 0.45 * sin(Double(tick) / 4.0)
            NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: CGFloat(pulse)).setFill()
            NSBezierPath(ovalIn: NSRect(x: right - 3, y: b.height - 15, width: 6, height: 6)).fill()
            let label = m.subagents > 0 ? "干活中 +\(m.subagents)" : "干活中"
            put(text(label, size: 9, weight: .medium, color: secondary), right - 8, b.height - 16, align: 2)
        }
    }

    // A click expands the dashboard; a drag moves the widget.
    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let w = window else { return }
        let p = NSEvent.mouseLocation
        let (dx, dy) = (p.x - s.mouse.x, p.y - s.mouse.y)
        if abs(dx) + abs(dy) > 3 { dragged = true }
        if dragged { w.setFrameOrigin(NSPoint(x: s.origin.x + dx, y: s.origin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        (NSApp.delegate as? App)?.popMenu(event, in: self)
    }
}

// MARK: - Dashboard

final class DashboardView: NSView {
    var model: Model?
    var drawBackground = false
    var onCollapse: (() -> Void)?
    private var hover: Int?
    private var chartRect = NSRect.zero
    private var headerBottom: CGFloat = 0
    private let pad: CGFloat = 18

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Height the content needs at the current width.
    func contentHeight() -> CGFloat { layout(draw: false) }

    override func draw(_ dirtyRect: NSRect) {
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        }
        _ = layout(draw: true)
    }

    private func section(_ title: String, _ y: CGFloat, right: String? = nil, draw: Bool) {
        guard draw else { return }
        put(text(title, size: 11, weight: .semibold, color: secondary), pad, y)
        if let r = right { put(text(r, size: 11, color: secondary, mono: true), bounds.width - pad, y, align: 2) }
    }

    /// Lays out (and optionally draws) every block top to bottom; returns
    /// the total height so measuring and drawing can never disagree.
    @discardableResult
    private func layout(draw: Bool) -> CGFloat {
        let W = bounds.width
        let inner = W - 2 * pad
        var y: CGFloat = 16
        guard let m = model else {
            if draw { put(text("等待数据…", size: 13, weight: .medium, color: secondary), pad, y) }
            return 80
        }

        // Header: rank, XP, progress to the next division. Clicking it collapses.
        if draw {
            medal(NSRect(x: pad, y: y, width: 30, height: 30), m.rankColor, roman(m.rankLabel), size: 11)
            let label = text(m.rankLabel, size: 16, weight: .semibold, color: m.rankColor)
            put(label, pad + 40, y + 5)
            put(text("\(fmtInt(m.xp)) XP", size: 12, color: secondary, mono: true), pad + 48 + label.size().width, y + 8)
            put(text("收起 ⌄", size: 11, color: secondary), W - pad, y + 8, align: 2)
        }
        y += 40
        if draw { bar(NSRect(x: pad, y: y, width: inner, height: 6), m.progress, m.rankColor) }
        y += 12
        if draw {
            var next = "已是最高段位"
            if let n = m.xpToNext, let l = m.nextLabel { next = "还差 \(fmtInt(n)) XP 升 \(l)" }
            put(text(next, size: 11, color: secondary), pad, y)
        }
        y += 22
        headerBottom = y

        // Four headline numbers.
        let tiles: [(String, Double, Double)] = [("今日", m.todayUSD, m.todayPD), ("本周", m.weekUSD, m.weekPD),
                                                 ("本月", m.monthUSD, m.monthPD), ("总计", m.totalUSD, m.totalPD)]
        let gap: CGFloat = 8
        let tw = (inner - gap * 3) / 4
        if draw {
            for (i, t) in tiles.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (tw + gap), y: y, width: tw, height: 58)
                NSColor.white.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                put(text(t.0, size: 10, color: secondary), r.minX + 9, r.minY + 8)
                put(text(fmtUSD(t.1), size: 15, weight: .bold, mono: true), r.minX + 9, r.minY + 22)
                put(text(String(format: "%.2f 人日", t.2), size: 9, color: secondary, mono: true), r.minX + 9, r.minY + 41)
            }
        }
        y += 58 + 22

        // 30-day chart: one series, direct labels on the best day and today,
        // hover for any other day.
        let avg = m.days.isEmpty ? 0 : m.days.map(\.usd).reduce(0, +) / Double(m.days.count)
        section("最近 \(max(m.days.count, 1)) 天每日产出", y, right: "日均 " + fmtUSD(avg), draw: draw)
        y += 22
        let chartH: CGFloat = 112
        chartRect = NSRect(x: pad, y: y, width: inner, height: chartH)
        if draw { drawChart(m, chartRect) }
        y += chartH + 20

        // Rank road.
        section("段位之路", y, draw: draw)
        y += 24
        if draw { drawRoad(m, NSRect(x: pad, y: y, width: inner, height: 44)) }
        y += 48 + 14

        // Task types over the same window.
        let classes = Array(m.classes.prefix(5))
        section("任务类型（\(max(m.days.count, 1)) 天）", y, draw: draw)
        y += 22
        if classes.isEmpty {
            if draw { put(text("还没有回合", size: 11, color: secondary), pad, y) }
            y += 18
        } else {
            let maxUSD = max(classes.map(\.usd).max() ?? 1, 0.01)
            for c in classes {
                if draw {
                    put(text(c.name, size: 11), pad, y)
                    let br = NSRect(x: pad + 64, y: y + 5, width: inner - 64 - 104, height: 6)
                    bar(br, c.usd / maxUSD, barColor)
                    put(text("\(fmtUSD(c.usd)) · \(c.turns) 次", size: 10, color: secondary, mono: true), W - pad, y + 1, align: 2)
                }
                y += 19
            }
        }
        y += 14

        // Recent turns.
        section("最近回合", y, draw: draw)
        y += 22
        let rows = Array(m.turns.prefix(6))
        if rows.isEmpty {
            if draw { put(text("还没有回合", size: 11, color: secondary), pad, y) }
            y += 18
        }
        for t in rows {
            if draw {
                put(text(when(t.at), size: 10, color: secondary, mono: true), pad, y + 1)
                let name = text(t.name, size: 11)
                put(name, pad + 78, y)
                var tags: [String] = []
                if t.files > 0 { tags.append("\(t.files) 个文件") }
                if let p = t.testPassed { tags.append(p ? "测试通过" : "测试未过") }
                if !tags.isEmpty {
                    put(text(tags.joined(separator: " · "), size: 10, color: secondary), pad + 86 + name.size().width, y + 1)
                }
                put(text(fmtUSD(t.usd), size: 11, weight: .medium, mono: true), W - pad, y, align: 2)
            }
            y += 20
        }
        y += 10

        if draw {
            var foot = "按 \(fmtUSD(m.hourlyRate))/小时折算"
            if let l = m.weekLeverage { foot += String(format: " · 本周杠杆 %.1fx", l) }
            put(text(foot, size: 10, color: secondary), pad, y)
            put(text("~/.shadowcorp/config.toml", size: 10, color: secondary.withAlphaComponent(0.4), mono: true), W - pad, y, align: 2)
        }
        y += 28
        return y
    }

    private func when(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    private func drawChart(_ m: Model, _ r: NSRect) {
        let n = m.days.count
        guard n > 0 else { return }
        let labelH: CGFloat = 16
        let plotTop = r.minY + 14
        let base = r.maxY - labelH
        let maxUSD = max(m.days.map(\.usd).max() ?? 0, 1)
        let slot = r.width / CGFloat(n)
        let bw = max(2, slot - 2)
        let peak = m.days.indices.max { m.days[$0].usd < m.days[$1].usd } ?? 0
        faint.setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: base, width: r.width, height: 1)).fill()
        for (i, d) in m.days.enumerated() {
            let h = CGFloat(d.usd / maxUSD) * (base - plotTop)
            guard h > 0 else { continue }
            let x = r.minX + CGFloat(i) * slot + (slot - bw) / 2
            let isToday = i == n - 1
            var c = isToday ? barToday : barColor
            if let hv = hover, hv != i { c = c.withAlphaComponent(0.45) }
            c.setFill()
            let rad = min(2, h / 2, bw / 2)
            NSBezierPath(roundedRect: NSRect(x: x, y: base - h, width: bw, height: h), xRadius: rad, yRadius: rad).fill()
            // Square off the baseline end.
            NSBezierPath(rect: NSRect(x: x, y: base - min(h, rad), width: bw, height: min(h, rad))).fill()
        }
        func label(_ i: Int, _ bold: Bool) {
            let d = m.days[i]
            let h = CGFloat(d.usd / maxUSD) * (base - plotTop)
            let cx = r.minX + CGFloat(i) * slot + slot / 2
            let s = text(fmtUSD(d.usd), size: 9, weight: bold ? .semibold : .regular, color: bold ? primary : secondary, mono: true)
            let x = min(max(cx, r.minX + s.size().width / 2), r.maxX - s.size().width / 2)
            put(s, x, base - h - 13, align: 1)
        }
        if let hv = hover, m.days.indices.contains(hv) {
            let d = m.days[hv]
            let tip = text("\(shortDay(d.day)) · \(fmtUSD(d.usd)) · \(d.turns) 个回合", size: 10, weight: .medium, mono: true)
            put(tip, r.maxX, r.minY - 2, align: 2)
            label(hv, true)
        } else {
            if m.days[peak].usd > 0 { label(peak, peak == n - 1) }
            if peak != n - 1 && m.days[n - 1].usd > 0 { label(n - 1, true) }
        }
        let ticks = [0, n / 2, n - 1]
        for i in ticks {
            let cx = r.minX + CGFloat(i) * slot + slot / 2
            let s = text(i == n - 1 ? "今天" : shortDay(m.days[i].day), size: 9, color: secondary)
            put(s, min(max(cx, r.minX + s.size().width / 2), r.maxX - s.size().width / 2), base + 3, align: 1)
        }
    }

    private func shortDay(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3, let mo = Int(p[1]), let da = Int(p[2]) else { return d }
        return "\(mo)/\(da)"
    }

    private func drawRoad(_ m: Model, _ r: NSRect) {
        let n = m.ranks.count
        guard n > 1 else { return }
        let lineY = r.minY + 8
        let xs = (0..<n).map { r.minX + 8 + CGFloat($0) * (r.width - 16) / CGFloat(n - 1) }
        faint.setFill()
        NSBezierPath(rect: NSRect(x: xs[0], y: lineY - 1.5, width: xs[n - 1] - xs[0], height: 3)).fill()
        let i = min(m.rankIndex, n - 1)
        var here = xs[i]
        if i < n - 1 {
            let span = Double(m.ranks[i + 1].xp - m.ranks[i].xp)
            let f = span > 0 ? min(1, max(0, Double(m.xp - m.ranks[i].xp) / span)) : 0
            here = xs[i] + CGFloat(f) * (xs[i + 1] - xs[i])
        }
        m.rankColor.setFill()
        NSBezierPath(rect: NSRect(x: xs[0], y: lineY - 1.5, width: here - xs[0], height: 3)).fill()
        for (k, step) in m.ranks.enumerated() {
            let dot = NSRect(x: xs[k] - 6, y: lineY - 6, width: 12, height: 12)
            if k <= i {
                step.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
                NSBezierPath(ovalIn: dot).fill()
                step.color.withAlphaComponent(0.7).setStroke()
                let p = NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1))
                p.lineWidth = 1.5
                p.stroke()
            }
            put(text(step.name, size: 10, weight: k == i ? .semibold : .regular, color: k <= i ? primary : secondary), xs[k], lineY + 10, align: 1)
            put(text(fmtK(step.xp), size: 9, color: secondary, mono: true), xs[k], lineY + 24, align: 1)
        }
        // "You are here" marker between ranks.
        if i < n - 1 {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: here - 4, y: lineY - 4, width: 8, height: 8)).fill()
            m.rankColor.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: here - 4, y: lineY - 4, width: 8, height: 8))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    // MARK: interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var h: Int?
        if let m = model, !m.days.isEmpty, chartRect.contains(p) {
            h = min(m.days.count - 1, max(0, Int((p.x - chartRect.minX) / (chartRect.width / CGFloat(m.days.count)))))
        }
        if h != hover {
            hover = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil {
            hover = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < headerBottom { onCollapse?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        (NSApp.delegate as? App)?.popMenu(event, in: self)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var compact: NSView!
    var widget: WidgetView!
    var expanded: NSView!
    var scroll: NSScrollView!
    var dashboard: DashboardView!
    var last: Model?
    var isExpanded = false
    var outsideClick: Any?

    private func glass(_ size: NSSize, radius: CGFloat) -> NSVisualEffectView {
        let e = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        e.material = .hudWindow
        e.state = .active
        e.blendingMode = .behindWindow
        e.wantsLayer = true
        e.layer?.cornerRadius = radius
        e.layer?.masksToBounds = true
        return e
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: widgetSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        compact = glass(widgetSize, radius: 14)
        widget = WidgetView(frame: compact.bounds)
        widget.autoresizingMask = [.width, .height]
        widget.onClick = { [weak self] in self?.expand() }
        widget.onMoved = { [weak self] in self?.saveOrigin() }
        compact.addSubview(widget)

        expanded = glass(NSSize(width: dashboardWidth, height: 600), radius: 16)
        scroll = NSScrollView(frame: expanded.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: dashboardWidth, height: 600))
        dashboard.onCollapse = { [weak self] in self?.collapse() }
        scroll.documentView = dashboard
        expanded.addSubview(scroll)

        panel.contentView = compact
        panel.setFrame(NSRect(origin: savedOrigin() ?? defaultOrigin(), size: widgetSize), display: true)
        panel.orderFrontRegardless()

        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self, !self.isExpanded, let m = self.widget.model else { return }
            if m.working > 0 || Date() < self.widget.flashUntil {
                self.widget.tick += 1
                self.widget.needsDisplay = true
            }
        }
    }

    // Position of the compact widget, remembered across launches.
    private func defaultOrigin() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - widgetSize.width - 16, y: vf.minY + 16)
    }

    private func savedOrigin() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
        let p = NSPoint(x: a[0], y: a[1])
        let r = NSRect(origin: p, size: widgetSize)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } ? p : nil
    }

    func saveOrigin() {
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: originKey)
    }

    @objc func resetPosition() {
        if isExpanded { collapse() }
        panel.setFrameOrigin(defaultOrigin())
        saveOrigin()
    }

    // MARK: expand / collapse

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        let anchor = panel.frame
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        dashboard.frame.size.width = dashboardWidth
        let h = min(dashboard.contentHeight(), vf.height - 32)
        dashboard.frame.size.height = dashboard.contentHeight()
        // Grow up and to the left from the widget's bottom-right corner,
        // then keep the whole panel on screen.
        var f = NSRect(x: anchor.maxX - dashboardWidth, y: anchor.minY, width: dashboardWidth, height: h)
        f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
        f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        expanded.frame.size = f.size
        panel.contentView = expanded
        dashboard.scroll(NSPoint.zero)
        panel.setFrame(f, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapse()
        }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        if let m = outsideClick { NSEvent.removeMonitor(m) }
        outsideClick = nil
        panel.contentView = compact
        let o = savedOrigin() ?? defaultOrigin()
        panel.setFrame(NSRect(origin: o, size: widgetSize), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @objc func toggle() { isExpanded ? collapse() : expand() }

    // MARK: menu

    func popMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isExpanded ? "收起仪表盘" : "打开仪表盘", action: #selector(toggle), keyEquivalent: ""))
        let auto = NSMenuItem(title: "登录时自动启动", action: #selector(toggleAutostart), keyEquivalent: "")
        auto.state = FileManager.default.fileExists(atPath: agentPlist) ? .on : .off
        menu.addItem(auto)
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleAutostart() {
        let uid = getuid()
        if FileManager.default.fileExists(atPath: agentPlist) {
            run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
            try? FileManager.default.removeItem(atPath: agentPlist)
        } else {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(atPath: (agentPlist as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: agentPlist))
                run("/bin/launchctl", ["enable", "gui/\(uid)/\(agentLabel)"])
            }
        }
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: data

    func reload() {
        guard let m = loadModel() else { return }
        if let old = last, m.level > old.level {
            widget.flashText = "晋级 → \(m.rankLabel)"
            widget.flashUntil = Date().addingTimeInterval(5)
        }
        if last.map({ $0.generatedAt != m.generatedAt }) ?? true {
            widget.model = m
            widget.needsDisplay = true
            dashboard.model = m
            dashboard.frame.size.height = dashboard.contentHeight()
            dashboard.needsDisplay = true
        }
        last = m
    }
}

// MARK: - Character

/// The character (DESIGN.md §2): a round ink blob with big eyes. `mood`
/// is one of waiting / focused / happy / proud / sleepy / missing. Works in
/// flipped and unflipped views: positions are given as fractions from the
/// top of `r`.
func drawCharacter(_ r: NSRect, mood: String, ink: NSColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.16, alpha: 1)) {
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let w = r.width, h = r.height
    /// Rect whose top edge sits `fromTop` of the way down `r`.
    func box(_ fx: CGFloat, _ fromTop: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> NSRect {
        let y = flipped ? r.minY + h * fromTop : r.maxY - h * fromTop - h * fh
        return NSRect(x: r.minX + w * fx, y: y, width: w * fw, height: h * fh)
    }
    /// Baseline-ish y for text whose top is `fromTop` down.
    func ty(_ fromTop: CGFloat, size: CGFloat) -> CGFloat { flipped ? r.minY + h * fromTop : r.maxY - h * fromTop - size * 1.2 }

    // Body: a soft blob, slightly flatter at the bottom.
    let bodyRect = box(0.04, 0.04, 0.92, 0.94)
    let body = NSBezierPath(ovalIn: bodyRect)
    ink.setFill()
    body.fill()
    NSBezierPath(roundedRect: box(0.08, flipped ? 0.62 : 0.62, 0.84, 0.36), xRadius: w * 0.2, yRadius: w * 0.2).fill()
    // Cheeks
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 0.35).setFill()
    NSBezierPath(ovalIn: box(0.16, 0.58, 0.14, 0.08)).fill()
    NSBezierPath(ovalIn: box(0.70, 0.58, 0.14, 0.08)).fill()
    // Eyes
    let white = NSColor.white
    let pupil = NSColor(calibratedWhite: 0.08, alpha: 1)
    for fx in [CGFloat(0.28), CGFloat(0.55)] {
        let e = box(fx, 0.32, 0.17, 0.22)
        switch mood {
        case "happy":
            white.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = max(2, w * 0.045)
            arc.lineCapStyle = .round
            // An arch (∩) in either coordinate system.
            let (a0, a1): (CGFloat, CGFloat) = flipped ? (200, 340) : (20, 160)
            arc.appendArc(withCenter: NSPoint(x: e.midX, y: e.midY + (flipped ? e.height * 0.15 : -e.height * 0.15)),
                          radius: e.width * 0.5, startAngle: a0, endAngle: a1, clockwise: false)
            arc.stroke()
        case "focused", "sleepy":
            white.setFill()
            NSBezierPath(ovalIn: e).fill()
            // Lid over the top part of the eye.
            let lid = mood == "sleepy" ? 0.5 : 0.4
            ink.setFill()
            NSBezierPath(rect: box(fx - 0.01, 0.32 - 0.05, 0.19, 0.05 + 0.22 * lid)).fill()
            pupil.setFill()
            NSBezierPath(ovalIn: box(fx + 0.045, 0.32 + 0.22 * lid, 0.08, 0.22 * (1 - lid) * 0.8)).fill()
        case "proud":
            white.setFill()
            let star = NSBezierPath()
            let c = NSPoint(x: e.midX, y: e.midY)
            let rOut = e.width * 0.62, rIn = e.width * 0.26
            for k in 0..<10 {
                let a = CGFloat(k) * .pi / 5 + .pi / 2
                let rr = k % 2 == 0 ? rOut : rIn
                let p = NSPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                k == 0 ? star.move(to: p) : star.line(to: p)
            }
            star.close()
            star.fill()
        default:
            white.setFill()
            NSBezierPath(ovalIn: e).fill()
            pupil.setFill()
            let dx: CGFloat = mood == "waiting" ? 0.03 : 0
            NSBezierPath(ovalIn: box(fx + 0.045 + dx, 0.37, 0.08, 0.11)).fill()
            white.setFill()
            NSBezierPath(ovalIn: box(fx + 0.085 + dx, 0.385, 0.03, 0.035)).fill()
        }
    }
    // Mood extras
    switch mood {
    case "sleepy":
        put(text("z", size: h * 0.18, weight: .bold, color: ink), r.minX + w * 0.86, ty(-0.1, size: h * 0.18), align: 1)
        put(text("z", size: h * 0.12, weight: .bold, color: ink), r.minX + w * 1.0, ty(-0.18, size: h * 0.12), align: 1)
    case "proud":
        NSColor(calibratedRed: 0.83, green: 0.69, blue: 0.22, alpha: 1).setFill()
        for (sx, sy, ss) in [(0.0, 0.08, 0.08), (0.9, 0.02, 0.06), (0.98, 0.36, 0.05)] {
            let c = box(CGFloat(sx), CGFloat(sy), 0.001, 0.001).origin
            let rad = w * CGFloat(ss)
            let sp = NSBezierPath()
            sp.move(to: NSPoint(x: c.x, y: c.y - rad)); sp.line(to: NSPoint(x: c.x + rad * 0.3, y: c.y - rad * 0.3))
            sp.line(to: NSPoint(x: c.x + rad, y: c.y)); sp.line(to: NSPoint(x: c.x + rad * 0.3, y: c.y + rad * 0.3))
            sp.line(to: NSPoint(x: c.x, y: c.y + rad)); sp.line(to: NSPoint(x: c.x - rad * 0.3, y: c.y + rad * 0.3))
            sp.line(to: NSPoint(x: c.x - rad, y: c.y)); sp.line(to: NSPoint(x: c.x - rad * 0.3, y: c.y - rad * 0.3))
            sp.close(); sp.fill()
        }
    case "waiting":
        let mug = NSColor(calibratedRed: 0.79, green: 0.71, blue: 0.54, alpha: 1)
        mug.setFill()
        NSBezierPath(roundedRect: box(0.98, 0.64, 0.16, 0.18), xRadius: 3, yRadius: 3).fill()
        mug.setStroke()
        let handle = NSBezierPath(ovalIn: box(1.12, 0.68, 0.07, 0.09))
        handle.lineWidth = 2
        handle.stroke()
    case "missing":
        // A little lamp held up.
        NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.43, alpha: 1).setFill()
        NSBezierPath(ovalIn: box(1.0, 0.2, 0.14, 0.14)).fill()
        ink.setFill()
        NSBezierPath(rect: box(1.06, 0.34, 0.02, 0.3)).fill()
    default:
        break
    }
}

/// `--moods out.png`: every mood, drawn in a flipped and an unflipped view.
final class MoodSheet: NSView {
    let flip: Bool
    init(flip: Bool) { self.flip = flip; super.init(frame: NSRect(x: 0, y: 0, width: 6 * 120, height: 130)) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { flip }
    override func draw(_ dirtyRect: NSRect) {
        paper.setFill()
        bounds.fill()
        for (i, m) in ["waiting", "focused", "happy", "proud", "sleepy", "missing"].enumerated() {
            drawCharacter(NSRect(x: CGFloat(i) * 120 + 20, y: 25, width: 80, height: 80), mood: m, ink: ink)
            put(text(m, size: 10, color: ink2), CGFloat(i) * 120 + 60, flip ? 112 : 8, align: 1)
        }
    }
}

// MARK: - Day card (1080 × 1350)

struct Report {
    var j: [String: Any]
    func s(_ k: String) -> String { j[k] as? String ?? "" }
    func d(_ k: String) -> Double { (j[k] as? Double) ?? Double(j[k] as? Int ?? 0) }
    func i(_ k: String) -> Int { (j[k] as? Int) ?? Int(j[k] as? Double ?? 0) }
    func o(_ k: String) -> [String: Any] { j[k] as? [String: Any] ?? [:] }
    func l(_ k: String) -> [[String: Any]] { j[k] as? [[String: Any]] ?? [] }
}

let paper = NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.89, alpha: 1)
let paper2 = NSColor(calibratedRed: 0.91, green: 0.88, blue: 0.82, alpha: 1)
let ink = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.16, alpha: 1)
let ink2 = NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.36, alpha: 1)

func truncate(_ s: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat) -> String {
    var t = s
    while !t.isEmpty && text(t + "…", size: size, weight: weight).size().width > width { t.removeLast() }
    return t == s ? s : t + "…"
}

final class DayCardView: NSView {
    var report: Report?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill()
        bounds.fill()
        guard let r = report else { return }
        let W = bounds.width
        let pad: CGFloat = 72
        let inner = W - pad * 2
        let ch = Report(j: r.o("character"))
        let mono = true

        // Date and mark
        put(text(r.s("label"), size: 30, weight: .medium, color: ink2), pad, 64)
        put(text("ShadowCorp", size: 22, weight: .semibold, color: ink2.withAlphaComponent(0.6)), W - pad, 68, align: 2)

        // Character + headline
        drawCharacter(NSRect(x: pad, y: 130, width: 150, height: 150), mood: ch.s("mood"), ink: ink)
        let tx = pad + 200
        put(text(ch.s("headline"), size: 36, color: ink2), tx, 128)
        if !ch.s("number").isEmpty {
            let num = text(ch.s("number"), size: 92, weight: .bold, color: ink, mono: mono)
            put(num, tx - 4, 166)
            put(text("的活", size: 36, color: ink2), tx + num.size().width + 8, 212)
        }
        put(text(ch.s("sub"), size: 28, color: ink2, mono: mono), tx, 284)

        // Timeline
        var y: CGFloat = 356
        put(text("时间线", size: 24, weight: .semibold, color: ink2), pad, y)
        y += 42
        let track = NSRect(x: pad, y: y, width: inner, height: 60)
        paper2.setFill()
        NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
        for b in r.l("blocks") {
            let from = CGFloat((b["from_min"] as? Int) ?? 0), to = CGFloat((b["to_min"] as? Int) ?? 0)
            let x0 = track.minX + inner * from / 1440, x1 = track.minX + inner * to / 1440
            color(hex: b["color"] as? String ?? "").setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: track.minY + 8, width: max(3, x1 - x0), height: track.height - 16), xRadius: 3, yRadius: 3).fill()
        }
        for h in stride(from: 0, through: 24, by: 6) {
            let x = track.minX + inner * CGFloat(h) / 24
            put(text("\(h)", size: 20, color: ink2, mono: mono), x, track.maxY + 8, align: h == 0 ? 0 : h == 24 ? 2 : 1)
        }
        y = track.maxY + 48

        // Sessions
        let sessions = Array(r.l("sessions").prefix(3))
        for s in sessions {
            let sr = Report(j: s)
            color(hex: sr.s("color")).setFill()
            NSBezierPath(ovalIn: NSRect(x: pad, y: y + 10, width: 14, height: 14)).fill()
            put(text("\(sr.s("from"))–\(sr.s("to"))", size: 24, color: ink2, mono: mono), pad + 28, y + 2)
            var title = sr.s("title")
            if let p = s["project"] as? String, !p.isEmpty { title = "\(p) · \(title)" }
            let hoursText = text(String(format: "%.1fh", sr.d("hours")), size: 26, weight: .semibold, color: ink, mono: mono)
            let titleW = W - pad - (pad + 236) - hoursText.size().width - 24
            put(text(truncate(title, size: 26, weight: .medium, width: titleW), size: 26, weight: .medium, color: ink), pad + 236, y)
            put(hoursText, W - pad, y, align: 2)
            y += 46
        }
        if sessions.isEmpty {
            put(text("今天没有回合", size: 24, color: ink2), pad, y)
            y += 46
        }
        y += 22

        // Categories
        put(text("做了哪些事", size: 24, weight: .semibold, color: ink2), pad, y)
        y += 42
        let cats = r.l("categories").filter { (($0["hours"] as? Double) ?? 0) > 0 }
        let maxH = max(cats.map { ($0["hours"] as? Double) ?? 0 }.max() ?? 1, 0.1)
        for c in cats {
            let cr = Report(j: c)
            put(text(cr.s("name"), size: 26, weight: .semibold, color: ink), pad, y)
            let br = NSRect(x: pad + 110, y: y + 10, width: inner - 110 - 230, height: 16)
            paper2.setFill()
            NSBezierPath(roundedRect: br, xRadius: 8, yRadius: 8).fill()
            color(hex: cr.s("color")).setFill()
            let fw = max(16, br.width * CGFloat(cr.d("hours") / maxH))
            NSBezierPath(roundedRect: NSRect(x: br.minX, y: br.minY, width: fw, height: 16), xRadius: 8, yRadius: 8).fill()
            put(text(String(format: "%.1fh · %.0f%%", cr.d("hours"), cr.d("share") * 100), size: 24, color: ink2, mono: mono), W - pad, y + 2, align: 2)
            y += 48
        }
        if cats.isEmpty {
            put(text("—", size: 24, color: ink2), pad, y)
            y += 48
        }
        y += 26

        // Stat tiles
        let tiles: [(String, String)] = [
            ("回合", "\(r.i("turns"))"),
            ("改动文件", "\(r.i("files"))"),
            ("测试通过", "\(r.i("tests_passed"))/\(r.i("tests_run"))"),
            ("一次过", "\(r.i("clean_turns"))/\(r.i("turns"))"),
        ]
        let gap: CGFloat = 16
        let tw = (inner - gap * 3) / 4
        for (i, t) in tiles.enumerated() {
            let tr = NSRect(x: pad + CGFloat(i) * (tw + gap), y: y, width: tw, height: 124)
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: tr, xRadius: 16, yRadius: 16).fill()
            put(text(t.0, size: 22, color: ink2), tr.minX + 20, tr.minY + 18)
            put(text(t.1, size: 44, weight: .bold, color: ink, mono: mono), tr.minX + 20, tr.minY + 52)
        }
        y += 124 + 40

        // Rank
        let rk = Report(j: r.o("rank"))
        let rc = color(hex: rk.s("color"))
        medal(NSRect(x: pad, y: y, width: 56, height: 56), rc, roman(rk.s("label")), size: 20)
        put(text(rk.s("label"), size: 30, weight: .bold, color: rc), pad + 76, y - 2)
        var xpLine = "\(fmtInt(rk.i("xp"))) XP"
        if let n = rk.j["xp_to_next"] as? Int, let nl = rk.j["next_label"] as? String { xpLine += " · 还差 \(fmtInt(n)) 升 \(nl)" }
        if r.i("streak") > 0 { xpLine += " · 连续 \(r.i("streak")) 天" }
        put(text(xpLine, size: 24, color: ink2, mono: mono), pad + 76, y + 34)
        paper2.setFill()
        NSBezierPath(roundedRect: NSRect(x: pad + 76, y: y + 70, width: inner - 76, height: 10), xRadius: 5, yRadius: 5).fill()
        rc.setFill()
        NSBezierPath(roundedRect: NSRect(x: pad + 76, y: y + 70, width: max(10, (inner - 76) * CGFloat(rk.d("progress"))), height: 10), xRadius: 5, yRadius: 5).fill()
        y += 120

        // Sign-off bubble
        let bubble = NSRect(x: pad, y: y, width: inner, height: 96)
        NSColor.white.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 20, yRadius: 20).fill()
        put(text("「\(ch.s("signoff"))」", size: 30, weight: .medium, color: ink), pad + 28, y + 20)
        put(text("— \(ch.s("name"))", size: 22, color: ink2), W - pad - 28, y + 58, align: 2)

        // Footer
        var foot = "按人类等价工时估算 · 参考 Anthropic Economic Index"
        if let usd = r.j["usd"] as? Double { foot = "≈ \(fmtUSD(usd)) · " + foot }
        put(text(foot, size: 20, color: ink2.withAlphaComponent(0.7)), pad, bounds.height - 58)
    }
}

func renderCard(_ jsonPath: String, _ outPath: String, copy: Bool) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    let size = NSSize(width: 1080, height: 1350)
    let v = DayCardView(frame: NSRect(origin: .zero, size: size))
    v.report = Report(j: j)
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
    v.cacheDisplay(in: v.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { return false }
    if copy, let img = NSImage(data: png) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
    return true
}

// MARK: - Entry

/// Renders a view offscreen at 2× to a PNG (for checks without a window).
func snapshot(_ v: NSView, _ size: NSSize, _ path: String) {
    v.frame = NSRect(origin: .zero, size: NSSize(width: size.width * 2, height: size.height * 2))
    v.scaleUnitSquare(to: NSSize(width: 2, height: 2))
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
    _ = NSApplication.shared
    let v = WidgetView(frame: NSRect(origin: .zero, size: widgetSize))
    v.drawBackground = true
    v.model = loadModel()
    snapshot(v, widgetSize, args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--moods"), args.count > i + 1 {
    _ = NSApplication.shared
    for (flip, suffix) in [(true, "flipped"), (false, "plain")] {
        let v = MoodSheet(flip: flip)
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1].replacingOccurrences(of: ".png", with: "-\(suffix).png")))
        }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--card"), args.count > i + 2 {
    _ = NSApplication.shared
    exit(renderCard(args[i + 1], args[i + 2], copy: args.contains("--copy")) ? 0 : 1)
}
if let i = args.firstIndex(of: "--snapshot-dashboard"), args.count > i + 1 {
    _ = NSApplication.shared
    let v = DashboardView(frame: NSRect(x: 0, y: 0, width: dashboardWidth, height: 600))
    v.drawBackground = true
    v.model = loadModel()
    let h = v.contentHeight()
    snapshot(v, NSSize(width: dashboardWidth, height: h), args[i + 1])
    exit(0)
}

// One instance at a time: a second launch (double-clicking the app again,
// `shadowcorp widget`) just exits while the first keeps the lock.
let lockFD = open(home + "/widget.lock", O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
