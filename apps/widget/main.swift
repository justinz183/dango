// shadowcorp-widget: a small always-on-top panel in the bottom-right corner
// of the screen showing what the agent's output would have cost to hire
// out ($), rank and XP. Click it to expand a dashboard (today / week / month
// / total, 30-day chart, rank road, who you would have hired, recent turns);
// click its header or anywhere else to collapse.
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

struct DayPoint { var day = ""; var hours = 0.0; var usd = 0.0; var turns = 0 }
struct RankStep { var name = ""; var xp = 0; var color = NSColor.gray }
struct JobShare { var name = ""; var hours = 0.0; var usd = 0.0; var rate = 0.0; var share = 0.0; var color = NSColor.gray }
struct TurnRow { var at = 0.0; var tool = ""; var name = ""; var hours = 0.0; var usd = 0.0; var color = NSColor.gray; var files = 0; var testPassed: Bool? }
/// Claude Code or Codex: what each agent's work would have cost.
struct ToolShare { var name = ""; var usd = 0.0; var hours = 0.0; var share = 0.0; var color = NSColor.gray }

func toolShares(_ list: [[String: Any]]) -> [ToolShare] {
    list.map {
        ToolShare(name: $0["name"] as? String ?? "", usd: $0["usd"] as? Double ?? 0, hours: $0["hours"] as? Double ?? 0,
                  share: $0["share"] as? Double ?? 0, color: color(hex: $0["color"] as? String ?? ""))
    }
}

struct Model {
    var totalHours = 0.0
    var totalUSD = 0.0
    var todayHours = 0.0
    var todayUSD = 0.0
    var weekHours = 0.0
    var weekUSD = 0.0
    var monthHours = 0.0
    var monthUSD = 0.0
    var name = "Claude"
    var mood = "happy"
    var line = ""
    var weekLeverage: Double?
    var ratesLabel = ""
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
    var jobs: [JobShare] = []
    var tools: [ToolShare] = []
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
    m.totalHours = total["hours"] as? Double ?? 0
    m.totalUSD = total["usd"] as? Double ?? 0
    m.todayHours = today["hours"] as? Double ?? 0
    m.todayUSD = today["usd"] as? Double ?? 0
    m.weekHours = week["hours"] as? Double ?? 0
    m.weekUSD = week["usd"] as? Double ?? 0
    m.weekLeverage = week["leverage"] as? Double
    m.monthHours = month["hours"] as? Double ?? 0
    m.monthUSD = month["usd"] as? Double ?? 0
    let ch = obj("character")
    m.name = ch["name"] as? String ?? "Claude"
    m.mood = ch["mood"] as? String ?? "happy"
    m.line = ch["line"] as? String ?? ""
    m.ratesLabel = obj("rates")["label"] as? String ?? ""
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
    m.days = list("days").map {
        DayPoint(day: $0["day"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0, turns: $0["turns"] as? Int ?? 0)
    }
    m.ranks = list("ranks").map { RankStep(name: $0["name"] as? String ?? "", xp: $0["xp"] as? Int ?? 0, color: color(hex: $0["color"] as? String ?? "")) }
    m.jobs = list("jobs").map {
        JobShare(name: $0["name"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0,
                 rate: $0["rate"] as? Double ?? 0, share: $0["share"] as? Double ?? 0, color: color(hex: $0["color"] as? String ?? ""))
    }
    m.tools = toolShares(list("tools"))
    m.turns = list("turns").map {
        TurnRow(at: $0["at"] as? Double ?? 0, tool: $0["tool"] as? String ?? "", name: $0["name"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0,
                color: color(hex: $0["color"] as? String ?? ""), files: $0["files"] as? Int ?? 0, testPassed: $0["test_passed"] as? Bool)
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

/// "25 分钟" under an hour, "3.4h" under a hundred, "123h" above.
func fmtHours(_ h: Double) -> String {
    if h < 1 { return "\(Int((h * 60).rounded())) 分钟" }
    if h < 100 { return String(format: "%.1fh", h) }
    return fmtInt(Int(h.rounded())) + "h"
}

/// The character sitting on a paper disc ringed in the rank colour, so the
/// dark body reads on the dark widget.
func characterBadge(_ r: NSRect, mood: String, ring: NSColor, glow: Bool = false) {
    if glow {
        ring.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -5, dy: -5)).fill()
    }
    ring.setFill()
    NSBezierPath(ovalIn: r).fill()
    NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.89, alpha: 1).setFill()
    NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5)).fill()
    let inset = r.width * 0.2
    drawCharacter(r.insetBy(dx: inset, dy: inset).offsetBy(dx: 0, dy: 0), mood: mood)
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
    private var hovering = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hovering shows what the character has to say.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

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
        characterBadge(NSRect(x: 12, y: (b.height - 44) / 2, width: 44, height: 44), mood: flashing ? "proud" : m.mood, ring: m.rankColor, glow: flashing)
        let x0: CGFloat = 66
        let right = b.width - 14
        put(text(fmtUSD(m.totalUSD), size: 20, weight: .bold, mono: true), x0, 44)
        put(text("今日 " + fmtUSD(m.todayUSD), size: 11, color: secondary, mono: true), right, 48, align: 2)
        if flashing {
            put(text(flashText, size: 12, weight: .semibold, color: m.rankColor), x0, 25)
        } else if hovering && !m.line.isEmpty {
            put(text("\(m.name)：\(m.line)", size: 11, weight: .medium, color: primary), x0, 25)
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
    private var reportRect = NSRect.zero
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

        // Header: the character, what it says, rank and XP, progress to the
        // next division. Clicking it collapses.
        if draw {
            characterBadge(NSRect(x: pad, y: y, width: 48, height: 48), mood: m.mood, ring: m.rankColor)
            let label = text(m.rankLabel, size: 16, weight: .semibold, color: m.rankColor)
            put(label, pad + 60, y + 2)
            put(text("\(fmtInt(m.xp)) XP", size: 12, color: secondary, mono: true), pad + 68 + label.size().width, y + 5)
            put(text("\(m.name)：\(m.line)", size: 12, color: primary), pad + 60, y + 26)
            put(text("收起 ⌄", size: 11, color: secondary), W - pad, y + 5, align: 2)
        }
        y += 58
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
        let tiles: [(String, Double, Double)] = [("今日", m.todayUSD, m.todayHours), ("本周", m.weekUSD, m.weekHours),
                                                  ("本月", m.monthUSD, m.monthHours), ("总计", m.totalUSD, m.totalHours)]
        let gap: CGFloat = 8
        let tw = (inner - gap * 3) / 4
        if draw {
            for (i, t) in tiles.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (tw + gap), y: y, width: tw, height: 58)
                NSColor.white.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                put(text(t.0, size: 10, color: secondary), r.minX + 9, r.minY + 8)
                put(text(fmtUSD(t.1), size: 15, weight: .bold, mono: true), r.minX + 9, r.minY + 22)
                put(text(fmtHours(t.2) + " 的活", size: 9, color: secondary, mono: true), r.minX + 9, r.minY + 41)
            }
        }
        y += 58 + 22

        // Claude Code and Codex side by side over the same 30 days.
        let tools = m.tools.filter { $0.usd > 0 }
        if !tools.isEmpty {
            section("Claude Code 与 Codex（\(max(m.days.count, 1)) 天）", y, draw: draw)
            y += 22
            if draw {
                var x = pad
                for t in tools {
                    let w = max(3, inner * CGFloat(t.share))
                    t.color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: min(w, pad + inner - x), height: 8), xRadius: 4, yRadius: 4).fill()
                    x += w + 2
                }
            }
            y += 16
            for t in tools {
                if draw {
                    t.color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: pad, y: y + 5, width: 7, height: 7)).fill()
                    put(text(t.name, size: 11), pad + 13, y)
                    let detail = String(format: "%@ · %@ · %.0f%%", fmtUSD(t.usd), fmtHours(t.hours), t.share * 100)
                    put(text(detail, size: 10, color: secondary, mono: true), W - pad, y + 1, align: 2)
                }
                y += 19
            }
            y += 14
        }

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

        // Who the same window's work would have needed.
        let jobs = m.jobs.filter { $0.usd > 0 }
        section("相当于请了谁（\(max(m.days.count, 1)) 天）", y, draw: draw)
        y += 22
        if jobs.isEmpty {
            if draw { put(text("还没有回合", size: 11, color: secondary), pad, y) }
            y += 18
        } else {
            let maxU = max(jobs.map(\.usd).max() ?? 1, 0.01)
            for c in jobs.prefix(6) {
                if draw {
                    put(text(c.name, size: 11), pad, y)
                    let br = NSRect(x: pad + 66, y: y + 5, width: inner - 66 - 150, height: 6)
                    bar(br, c.usd / maxU, c.color)
                    let detail = String(format: "%@ × $%.0f = %@", fmtHours(c.hours), c.rate, fmtUSD(c.usd))
                    put(text(detail, size: 10, color: secondary, mono: true), W - pad, y + 1, align: 2)
                }
                y += 19
            }
            if jobs.count > 6 {
                let rest = jobs.dropFirst(6).map(\.usd).reduce(0, +)
                if draw { put(text("还有 \(jobs.count - 6) 种 · \(fmtUSD(rest))", size: 10, color: secondary), pad, y) }
                y += 17
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
                t.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: pad + 76, y: y + 5, width: 6, height: 6)).fill()
                let name = text(t.name, size: 11)
                put(name, pad + 88, y)
                var tags: [String] = [t.tool == "Codex" ? "Codex" : "Claude", fmtHours(t.hours)]
                if t.files > 0 { tags.append("\(t.files) 个文件") }
                if let p = t.testPassed { tags.append(p ? "测试通过" : "测试未过") }
                put(text(tags.joined(separator: " · "), size: 10, color: secondary), pad + 96 + name.size().width, y + 1)
                put(text(fmtUSD(t.usd), size: 11, weight: .medium, mono: true), W - pad, y, align: 2)
            }
            y += 20
        }
        y += 10

        let button = text("生成今日日报 →", size: 12, weight: .semibold, color: NSColor(red: 0.65, green: 0.88, blue: 0.81, alpha: 1))
        let bs = button.size()
        reportRect = NSRect(x: W - pad - bs.width - 16, y: y - 6, width: bs.width + 16, height: bs.height + 12)
        if draw {
            var foot = "按 BLS 各职业中位时薪折算"
            if let l = m.weekLeverage { foot += String(format: " · 本周杠杆 %.1fx", l) }
            put(text(foot, size: 10, color: secondary), pad, y + 1)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: reportRect, xRadius: 8, yRadius: 8).fill()
            put(button, reportRect.midX, reportRect.minY + 6, align: 1)
        }
        y += 34
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
            let sz = s.size()
            let x = min(max(cx, r.minX + sz.width / 2 + 3), r.maxX - sz.width / 2 - 3)
            NSColor(calibratedWhite: 0.13, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - sz.width / 2 - 3, y: base - h - 14, width: sz.width + 6, height: sz.height + 1), xRadius: 3, yRadius: 3).fill()
            put(s, x, base - h - 13, align: 1)
        }
        if let hv = hover, m.days.indices.contains(hv) {
            let d = m.days[hv]
            let tip = text("\(shortDay(d.day)) · \(fmtUSD(d.usd)) · \(fmtHours(d.hours)) · \(d.turns) 个回合", size: 10, weight: .medium, mono: true)
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
        let p = convert(event.locationInWindow, from: nil)
        if p.y < headerBottom {
            onCollapse?()
        } else if reportRect.contains(p) {
            (NSApp.delegate as? App)?.makeTodayCard()
        }
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

    /// Runs `shadowcorp card --day today`, which renders the day card,
    /// copies it to the clipboard and opens it.
    @objc func makeTodayCard() {
        let candidates = [NSHomeDirectory() + "/.local/bin/shadowcorp", "/usr/local/bin/shadowcorp", "/opt/homebrew/bin/shadowcorp"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["card", "--day", "today"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        collapse()
    }

    // MARK: menu

    func popMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isExpanded ? "收起仪表盘" : "打开仪表盘", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "生成今日日报", action: #selector(makeTodayCard), keyEquivalent: ""))
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

// MARK: - Share cards

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

/// Shared drawing for the share cards: warm paper, charcoal ink, the
/// occupation colours only on data, system fonts.
class CardView: NSView {
    var report: Report?
    /// How far down the last block reached on the most recent draw.
    var contentBottom: CGFloat = 0
    let pad: CGFloat = 72
    override var isFlipped: Bool { true }
    var W: CGFloat { bounds.width }
    var inner: CGFloat { bounds.width - pad * 2 }

    func title(_ s: String, _ y: CGFloat, right: String? = nil) {
        put(text(s, size: 24, weight: .semibold, color: ink2), pad, y)
        if let r = right { put(text(r, size: 22, color: ink2, mono: true), W - pad, y + 2, align: 2) }
    }

    /// Date, mark, character and the big number. Returns the y below it.
    func header(_ r: Report) -> CGFloat {
        paper.setFill()
        bounds.fill()
        let ch = Report(j: r.o("character"))
        put(text(r.s("label"), size: 30, weight: .medium, color: ink2), pad, 64)
        put(text("ShadowCorp", size: 22, weight: .semibold, color: ink2.withAlphaComponent(0.6)), W - pad, 68, align: 2)
        drawCharacter(NSRect(x: pad, y: 130, width: 150, height: 150), mood: ch.s("mood"), ink: ink)
        let tx = pad + 200
        put(text(ch.s("headline"), size: 36, color: ink2), tx, 128)
        if !ch.s("number").isEmpty {
            put(text(ch.s("number"), size: 92, weight: .bold, color: ink, mono: true), tx - 4, 166)
        }
        put(text(ch.s("sub"), size: 28, color: ink2, mono: true), tx, 284)
        // Who did it: Claude Code and Codex, each with its dollars and share.
        let tools = toolShares(r.l("tools")).filter { $0.usd > 0 }
        guard !tools.isEmpty else { return 356 }
        var x = tx
        for t in tools {
            t.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 336, width: 16, height: 16)).fill()
            let label = text(String(format: "%@ %@ · %.0f%%", t.name, fmtUSD(t.usd), t.share * 100), size: 24, color: ink2)
            put(label, x + 24, 330)
            x += 24 + label.size().width + 32
        }
        return 388
    }

    func sessions(_ r: Report, _ y0: CGFloat, empty: String) -> CGFloat {
        var y = y0
        let rows = Array(r.l("sessions").prefix(3))
        for s in rows {
            let sr = Report(j: s)
            color(hex: sr.s("color")).setFill()
            NSBezierPath(ovalIn: NSRect(x: pad, y: y + 10, width: 14, height: 14)).fill()
            let span = sr.s("from") == sr.s("to") ? sr.s("from") : "\(sr.s("from"))–\(sr.s("to"))"
            put(text(span, size: 24, color: ink2, mono: true), pad + 28, y + 2)
            var t = sr.s("title")
            if let p = s["project"] as? String, !p.isEmpty { t = "\(p) · \(t)" }
            let h = text(fmtUSD(sr.d("usd")), size: 26, weight: .semibold, color: ink, mono: true)
            let titleW = W - pad - (pad + 236) - h.size().width - 24
            put(text(truncate(t, size: 26, weight: .medium, width: titleW), size: 26, weight: .medium, color: ink), pad + 236, y)
            put(h, W - pad, y, align: 2)
            y += 46
        }
        if rows.isEmpty {
            put(text(empty, size: 24, color: ink2), pad, y)
            y += 46
        }
        return y + 22
    }

    /// Who you would have hired: hours × that job's median wage, per job.
    func jobs(_ r: Report, _ y0: CGFloat) -> CGFloat {
        var y = y0
        let all = r.l("jobs").filter { (($0["usd"] as? Double) ?? 0) > 0 }
        title("相当于请了谁", y, right: all.isEmpty ? nil : "\(all.count) 种工作")
        y += 42
        let shown = Array(all.prefix(6))
        let maxU = max(shown.map { ($0["usd"] as? Double) ?? 0 }.max() ?? 1, 0.1)
        for c in shown {
            let cr = Report(j: c)
            put(text(cr.s("name"), size: 26, weight: .semibold, color: ink), pad, y)
            let br = NSRect(x: pad + 150, y: y + 10, width: inner - 150 - 300, height: 16)
            paper2.setFill()
            NSBezierPath(roundedRect: br, xRadius: 8, yRadius: 8).fill()
            color(hex: cr.s("color")).setFill()
            let fw = max(16, br.width * CGFloat(cr.d("usd") / maxU))
            NSBezierPath(roundedRect: NSRect(x: br.minX, y: br.minY, width: fw, height: 16), xRadius: 8, yRadius: 8).fill()
            let usd = text(fmtUSD(cr.d("usd")), size: 26, weight: .semibold, color: ink, mono: true)
            put(usd, W - pad, y, align: 2)
            let how = String(format: "%@ × $%.0f", fmtHours(cr.d("hours")), cr.d("rate"))
            put(text(how, size: 22, color: ink2, mono: true), W - pad - usd.size().width - 16, y + 3, align: 2)
            y += 48
        }
        if all.count > shown.count {
            let rest = all.dropFirst(shown.count).map { ($0["usd"] as? Double) ?? 0 }.reduce(0, +)
            put(text("还有 \(all.count - shown.count) 种 · \(fmtUSD(rest))", size: 22, color: ink2), pad, y)
            y += 40
        }
        if all.isEmpty {
            put(text("—", size: 24, color: ink2), pad, y)
            y += 48
        }
        return y + 26
    }

    func tiles(_ items: [(String, String)], _ y: CGFloat) -> CGFloat {
        let gap: CGFloat = 16
        let tw = (inner - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        for (i, t) in items.enumerated() {
            let tr = NSRect(x: pad + CGFloat(i) * (tw + gap), y: y, width: tw, height: 124)
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: tr, xRadius: 16, yRadius: 16).fill()
            put(text(t.0, size: 22, color: ink2), tr.minX + 20, tr.minY + 18)
            put(text(t.1, size: 44, weight: .bold, color: ink, mono: true), tr.minX + 20, tr.minY + 52)
        }
        return y + 124 + 40
    }

    /// Current rank with progress to the next division.
    func rankProgress(_ r: Report, _ y: CGFloat) -> CGFloat {
        let rk = Report(j: r.o("rank"))
        let rc = color(hex: rk.s("color"))
        medal(NSRect(x: pad, y: y, width: 56, height: 56), rc, roman(rk.s("label")), size: 20)
        put(text(rk.s("label"), size: 30, weight: .bold, color: rc), pad + 76, y - 2)
        var xpLine = "\(fmtInt(rk.i("xp"))) XP"
        if let n = rk.j["xp_to_next"] as? Int, let nl = rk.j["next_label"] as? String { xpLine += " · 还差 \(fmtInt(n)) 升 \(nl)" }
        if r.i("streak") > 0 { xpLine += " · 连续 \(r.i("streak")) 天" }
        put(text(xpLine, size: 24, color: ink2, mono: true), pad + 76, y + 34)
        paper2.setFill()
        NSBezierPath(roundedRect: NSRect(x: pad + 76, y: y + 70, width: inner - 76, height: 10), xRadius: 5, yRadius: 5).fill()
        rc.setFill()
        NSBezierPath(roundedRect: NSRect(x: pad + 76, y: y + 70, width: max(10, (inner - 76) * CGFloat(rk.d("progress"))), height: 10), xRadius: 5, yRadius: 5).fill()
        return y + 120
    }

    /// Rank at the start of the period → at its end, and the XP gained.
    func rankChange(_ r: Report, _ y: CGFloat) -> CGFloat {
        let a = Report(j: r.o("rank_start")), b = Report(j: r.o("rank_end"))
        let ca = color(hex: a.s("color")), cb = color(hex: b.s("color"))
        medal(NSRect(x: pad, y: y, width: 56, height: 56), ca, roman(a.s("label")), size: 20)
        let la = text(a.s("label"), size: 28, weight: .semibold, color: ink2)
        put(la, pad + 72, y + 12)
        var x = pad + 72 + la.size().width + 20
        put(text("→", size: 28, color: ink2), x, y + 12)
        x += 44
        medal(NSRect(x: x, y: y, width: 56, height: 56), cb, roman(b.s("label")), size: 20)
        put(text(b.s("label"), size: 28, weight: .bold, color: ink), x + 72, y + 12)
        let gained = max(0, b.i("xp") - a.i("xp"))
        put(text("+\(fmtInt(gained)) XP", size: 28, weight: .semibold, color: ink, mono: true), W - pad, y + 12, align: 2)
        return y + 96
    }

    func signoff(_ r: Report, _ y: CGFloat) -> CGFloat {
        contentBottom = y + 96
        let ch = Report(j: r.o("character"))
        let bubble = NSRect(x: pad, y: y, width: inner, height: 96)
        NSColor.white.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 20, yRadius: 20).fill()
        put(text("「\(ch.s("signoff"))」", size: 30, weight: .medium, color: ink), pad + 28, y + 20)
        put(text("— \(ch.s("name"))", size: 22, color: ink2), W - pad - 28, y + 58, align: 2)
        return y + 96
    }

    func footer(_ r: Report) {
        let foot = (r.o("rates")["label"] as? String) ?? ""
        put(text(foot + " · 不含福利", size: 20, color: ink2.withAlphaComponent(0.7)), pad, bounds.height - 58)
    }

    func leverageText(_ r: Report) -> String {
        (r.j["leverage"] as? Double).map { String(format: "%.1fx", $0) } ?? "—"
    }
}

/// Day card, 1080 × 1350.
final class DayCardView: CardView {
    override func draw(_ dirtyRect: NSRect) {
        guard let r = report else { return }
        var y = header(r)
        title("时间线", y)
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
            put(text("\(h)", size: 20, color: ink2, mono: true), x, track.maxY + 8, align: h == 0 ? 0 : h == 24 ? 2 : 1)
        }
        y = track.maxY + 48
        y = sessions(r, y, empty: "今天没有回合")
        y = jobs(r, y)
        y = tiles([("回合", "\(r.i("turns"))"), ("改动文件", "\(r.i("files"))"),
                   ("测试通过", "\(r.i("tests_passed"))/\(r.i("tests_run"))"), ("一次过", "\(r.i("clean_turns"))/\(r.i("turns"))")], y)
        y = rankProgress(r, y)
        _ = signoff(r, y)
        footer(r)
    }
}

/// Week card, 1080 × 1920: a stacked bar per day by occupation, in dollars.
final class WeekCardView: CardView {
    override func draw(_ dirtyRect: NSRect) {
        guard let r = report else { return }
        var y = header(r)
        title("每天", y, right: "活跃 \(r.i("active_days"))/7 天")
        y += 48
        let days = r.l("days")
        let chart = NSRect(x: pad, y: y, width: inner, height: 300)
        let base = chart.maxY - 40
        let top = chart.minY + 40
        let maxU = max(days.map { ($0["usd"] as? Double) ?? 0 }.max() ?? 0, 1)
        let slot = inner / CGFloat(max(days.count, 1))
        let bw = min(84, slot - 28)
        let best = r.j["best_day"] as? Int
        paper2.setFill()
        NSBezierPath(rect: NSRect(x: chart.minX, y: base, width: inner, height: 2)).fill()
        for (i, d) in days.enumerated() {
            let dr = Report(j: d)
            let cx = chart.minX + slot * CGFloat(i) + slot / 2
            var yTop = base
            // Stack each occupation bottom-up, with a paper gap between parts.
            for part in dr.l("parts") {
                let h = CGFloat((part["usd"] as? Double ?? 0) / maxU) * (base - top)
                guard h > 0.5 else { continue }
                color(hex: part["color"] as? String ?? "").setFill()
                let rect = NSRect(x: cx - bw / 2, y: yTop - h, width: bw, height: max(h - 3, 2))
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                yTop -= h
            }
            if dr.d("usd") > 0 {
                let isBest = best == i
                put(text(fmtUSD(dr.d("usd")), size: 22, weight: isBest ? .bold : .regular, color: isBest ? ink : ink2, mono: true), cx, yTop - 32, align: 1)
            }
            let today = dr.j["today"] as? Bool ?? false
            put(text(dr.s("label"), size: 24, weight: today ? .bold : .regular, color: today ? ink : ink2), cx, base + 10, align: 1)
        }
        y = chart.maxY + 30
        y = jobs(r, y)
        title("花时间最多的事", y)
        y += 42
        y = sessions(r, y, empty: "这周没有回合")
        y = tiles([("活跃天数", "\(r.i("active_days"))/7"), ("回合", "\(r.i("turns"))"),
                   ("测试通过", "\(r.i("tests_passed"))/\(r.i("tests_run"))"), ("杠杆", leverageText(r))], y)
        y = rankChange(r, y)
        _ = signoff(r, y + 20)
        footer(r)
    }
}

/// Month card, 1080 × 1920: a calendar heatmap and when the work happens.
final class MonthCardView: CardView {
    override func draw(_ dirtyRect: NSRect) {
        guard let r = report else { return }
        var y = header(r)
        title("日历", y, right: "活跃 \(r.i("active_days")) 天 · 最长连续 \(r.i("longest_run")) 天")
        y += 46
        let gap: CGFloat = 8
        let cw = (inner - gap * 6) / 7
        let chH: CGFloat = 56
        for (i, w) in ["一", "二", "三", "四", "五", "六", "日"].enumerated() {
            put(text(w, size: 20, color: ink2), pad + CGFloat(i) * (cw + gap) + cw / 2, y, align: 1)
        }
        y += 34
        let days = r.l("days")
        let first = r.i("first_weekday")
        let maxU = max(days.map { ($0["usd"] as? Double) ?? 0 }.max() ?? 0, 1)
        let light = (0.85, 0.92, 0.89), dark = (0.24, 0.42, 0.37)
        var rows = 0
        for (k, d) in days.enumerated() {
            let dr = Report(j: d)
            let slot = first + k
            let (row, col) = (slot / 7, slot % 7)
            rows = max(rows, row + 1)
            let cell = NSRect(x: pad + CGFloat(col) * (cw + gap), y: y + CGFloat(row) * (chH + gap), width: cw, height: chH)
            let usd = dr.d("usd")
            let future = dr.j["future"] as? Bool ?? false
            var fill = paper2
            var label = ink2
            if usd > 0 {
                // One hue, light → dark by dollars (square-rooted so small days still show).
                let f = sqrt(min(1, usd / maxU))
                fill = NSColor(calibratedRed: light.0 + (dark.0 - light.0) * f, green: light.1 + (dark.1 - light.1) * f,
                               blue: light.2 + (dark.2 - light.2) * f, alpha: 1)
                label = f > 0.55 ? NSColor.white : ink
            } else if future {
                fill = paper2.withAlphaComponent(0.45)
            }
            fill.setFill()
            NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10).fill()
            if dr.j["today"] as? Bool ?? false {
                ink.setStroke()
                let o = NSBezierPath(roundedRect: cell.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
                o.lineWidth = 3
                o.stroke()
            }
            put(text("\(dr.i("day"))", size: 18, color: label.withAlphaComponent(future ? 0.4 : 0.8), mono: true), cell.minX + 10, cell.minY + 6)
            if usd > 0 {
                put(text(fmtUSD(usd), size: 18, weight: .semibold, color: label, mono: true), cell.maxX - 10, cell.maxY - 26, align: 2)
            }
        }
        y += CGFloat(rows) * (chH + gap) + 30

        // When the work happens.
        title("你的作息", y, right: (r.j["peak_window"] as? String).map { "最常在 \($0)开工" })
        y += 46
        let hist = (r.j["by_hour"] as? [Double]) ?? []
        let hh: CGFloat = 110
        let maxB = max(hist.max() ?? 0, 0.1)
        let slot = inner / 24
        for (i, v) in hist.enumerated() {
            let h = CGFloat(v / maxB) * hh
            (v > 0 ? color(hex: "#5b8c7e") : paper2).setFill()
            let bh = max(h, 4)
            NSBezierPath(roundedRect: NSRect(x: pad + CGFloat(i) * slot + 3, y: y + hh - bh, width: slot - 6, height: bh), xRadius: 4, yRadius: 4).fill()
        }
        for hour in stride(from: 0, through: 24, by: 6) {
            put(text("\(hour)", size: 20, color: ink2, mono: true), pad + inner * CGFloat(hour) / 24, y + hh + 8, align: hour == 0 ? 0 : hour == 24 ? 2 : 1)
        }
        y += hh + 60
        y = jobs(r, y)
        title("花时间最多的事", y)
        y += 42
        y = sessions(r, y, empty: "这个月没有回合")
        y = rankChange(r, y)
        _ = signoff(r, y + 10)
        footer(r)
    }
}

func renderCard(_ jsonPath: String, _ outPath: String, copy: Bool) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    let kind = j["kind"] as? String ?? "day"
    let tall = NSSize(width: 1080, height: 2400)
    let v: CardView = kind == "week" ? WeekCardView(frame: NSRect(origin: .zero, size: tall))
        : kind == "month" ? MonthCardView(frame: NSRect(origin: .zero, size: tall))
        : DayCardView(frame: NSRect(origin: .zero, size: tall))
    v.report = Report(j: j)
    // Measure on a tall canvas, then fit: content plus the footer, never
    // shorter than 4:5, never taller than 9:16.
    if let probe = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: probe) }
    let h = min(1920, max(1350, (v.contentBottom + 130).rounded()))
    v.setFrameSize(NSSize(width: 1080, height: h))
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
