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
// [--board claude_code|codex] [--open-jobs], --snapshot-pet out.png [--state S]
// [--job ID] [--helpers N] [--receipt] [--backdrop] (transparent unless --backdrop)

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
/// The occupation the agent is "being" right now, from activity.job.
struct Job { var id = ""; var name = ""; var color = NSColor.gray }
struct JobShare { var id = ""; var name = ""; var hours = 0.0; var usd = 0.0; var rate = 0.0; var share = 0.0; var color = NSColor.gray }
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
    /// The best day so far, in dollars.
    var recordUSD = 0.0
    var daysTogether = 0
    var job: Job?
    /// Every occupation, for outfits by id.
    var occupations: [Job] = []
    var working = 0
    var subagents = 0
    var generatedAt = 0.0
    var days: [DayPoint] = []
    var jobs: [JobShare] = []
    var tools: [ToolShare] = []
    var turns: [TurnRow] = []
    /// The same dashboard for one agent ("claude_code", "codex"), from
    /// widget.json `views`: tiles, 30 days, jobs and turns are that agent's.
    var boards: [String: Model] = [:]
}

/// Display name of an agent id for the dashboard switch.
let boardNames = ["all": "全部", "claude_code": "Claude Code", "codex": "Codex"]

/// Reads the dashboard numbers (tiles, 30 days, jobs, turns) from the top
/// level of widget.json or from one of its `views`.
func applyBoard(_ m: inout Model, _ j: [String: Any]) {
    func obj(_ k: String) -> [String: Any] { j[k] as? [String: Any] ?? [:] }
    func list(_ k: String) -> [[String: Any]] { j[k] as? [[String: Any]] ?? [] }
    let total = obj("total"), today = obj("today"), week = obj("week"), month = obj("month")
    m.totalHours = total["hours"] as? Double ?? 0
    m.totalUSD = total["usd"] as? Double ?? 0
    m.todayHours = today["hours"] as? Double ?? 0
    m.todayUSD = today["usd"] as? Double ?? 0
    m.weekHours = week["hours"] as? Double ?? 0
    m.weekUSD = week["usd"] as? Double ?? 0
    m.monthHours = month["hours"] as? Double ?? 0
    m.monthUSD = month["usd"] as? Double ?? 0
    m.days = list("days").map {
        DayPoint(day: $0["day"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0, turns: $0["turns"] as? Int ?? 0)
    }
    m.jobs = list("jobs").map {
        JobShare(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0,
                 rate: $0["rate"] as? Double ?? 0, share: $0["share"] as? Double ?? 0, color: color(hex: $0["color"] as? String ?? ""))
    }
    m.turns = list("turns").map {
        TurnRow(at: $0["at"] as? Double ?? 0, tool: $0["tool"] as? String ?? "", name: $0["name"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0,
                color: color(hex: $0["color"] as? String ?? ""), files: $0["files"] as? Int ?? 0, testPassed: $0["test_passed"] as? Bool)
    }
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
    let act = obj("activity")
    applyBoard(&m, j)
    m.weekLeverage = obj("week")["leverage"] as? Double
    let ch = obj("character")
    m.name = ch["name"] as? String ?? "Claude"
    m.mood = ch["mood"] as? String ?? "happy"
    m.line = ch["line"] as? String ?? ""
    m.ratesLabel = obj("rates")["label"] as? String ?? ""
    m.recordUSD = obj("record")["day_usd"] as? Double ?? 0
    m.occupations = list("occupations").map { Job(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", color: color(hex: $0["color"] as? String ?? "")) }
    m.daysTogether = ch["days_together"] as? Int ?? 0
    if let jb = act["job"] as? [String: Any] {
        m.job = Job(id: jb["id"] as? String ?? "", name: jb["name"] as? String ?? "", color: color(hex: jb["color"] as? String ?? ""))
    }
    m.working = act["working"] as? Int ?? 0
    m.subagents = act["subagents"] as? Int ?? 0
    m.generatedAt = j["generated_at"] as? Double ?? 0
    m.tools = toolShares(list("tools"))
    for (id, view) in obj("views") {
        guard let view = view as? [String: Any] else { continue }
        var v = m
        applyBoard(&v, view)
        m.boards[id] = v
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
func characterBadge(_ r: NSRect, mood: String, ring: NSColor, glow: Bool = false, job: Job? = nil) {
    if glow {
        ring.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: -5, dy: -5)).fill()
    }
    ring.setFill()
    NSBezierPath(ovalIn: r).fill()
    NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.89, alpha: 1).setFill()
    NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5)).fill()
    let inset = r.width * 0.2
    drawCharacter(r.insetBy(dx: inset, dy: inset), mood: mood, job: job?.id, jobColor: job?.color)
}

/// The accent for "this moment": the current job's colour, else the teal.
func accent(_ m: Model) -> NSColor { m.job?.color ?? barColor }

func fmtInt(_ n: Int) -> String {
    intFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
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
        let x0: CGFloat = 18
        let right = b.width - 16
        let tone = accent(m)
        // Line 1: everything so far, and today.
        put(text(fmtUSD(m.totalUSD), size: 22, weight: .bold, mono: true), x0, 42)
        put(text("今日 " + fmtUSD(m.todayUSD), size: 11, color: secondary, mono: true), right, 47, align: 2)
        // Line 2: what it is being right now (or what it has to say).
        if flashing {
            put(text(flashText, size: 12, weight: .semibold, color: tone), x0, 24)
        } else if hovering && !m.line.isEmpty {
            put(text("\(m.name)：\(m.line)", size: 11, weight: .medium, color: primary), x0, 24)
        } else {
            if let j = m.job {
                j.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x0, y: 27, width: 7, height: 7)).fill()
                put(text(j.name, size: 12, weight: .semibold, color: primary), x0 + 12, 24)
            } else {
                put(text(m.name, size: 12, weight: .semibold, color: primary), x0, 24)
            }
            let beating = m.recordUSD > 0 && m.todayUSD + 1e-9 >= m.recordUSD && m.todayUSD > 0
            put(text(beating ? "单日新高 ✦" : "单日纪录 " + fmtUSD(m.recordUSD), size: 10, color: beating ? tone : secondary, mono: true), right, 26, align: 2)
        }
        // Line 3: today against the best day so far.
        bar(NSRect(x: x0, y: 14, width: right - x0, height: 4), m.recordUSD > 0 ? m.todayUSD / m.recordUSD : 0, tone)
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
    /// Which agent the dashboard shows: "all", "claude_code" or "codex".
    private(set) var filter = "all"
    private var pillRects: [(String, NSRect)] = []
    /// The "还有 N 种" line under the jobs; clicking it opens the full list.
    private var jobsOpen = false
    private var moreRect = NSRect.zero
    /// Called when the content changes height (switch, jobs list).
    var onResize: (() -> Void)?

    /// For snapshots: start on one agent and/or with the jobs list open.
    func preset(filter: String, jobsOpen: Bool) {
        self.filter = filter
        self.jobsOpen = jobsOpen
    }

    /// The model for the selected agent (all of them by default).
    private var shown: Model? {
        guard let m = model else { return nil }
        return filter == "all" ? m : m.boards[filter] ?? m
    }
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
        guard let base = model, let m = shown else {
            if draw { put(text("等待数据…", size: 13, weight: .medium, color: secondary), pad, y) }
            return 80
        }

        // Header: the character, what it says, rank and XP, progress to the
        // next division. Clicking it collapses.
        let tone = accent(base)
        if draw {
            characterBadge(NSRect(x: pad, y: y, width: 48, height: 48), mood: base.mood, ring: tone, job: base.job)
            let total = text(fmtUSD(base.totalUSD), size: 20, weight: .bold, mono: true)
            put(total, pad + 60, y)
            put(text("累计", size: 11, color: secondary), pad + 66 + total.size().width, y + 6)
            if let j = base.job {
                put(text("· 在当\(j.name)", size: 11, color: j.color), pad + 66 + total.size().width + 30, y + 6)
            }
            put(text("\(base.name)：\(base.line)", size: 12, color: primary), pad + 60, y + 27)
            put(text("收起 ⌄", size: 11, color: secondary), W - pad, y + 5, align: 2)
        }
        y += 58
        let beating = base.recordUSD > 0 && base.todayUSD + 1e-9 >= base.recordUSD && base.todayUSD > 0
        if draw { bar(NSRect(x: pad, y: y, width: inner, height: 6), base.recordUSD > 0 ? base.todayUSD / base.recordUSD : 0, tone) }
        y += 12
        if draw {
            let s = beating ? "今天就是单日纪录 ✦ \(fmtUSD(base.todayUSD))" : "今日 \(fmtUSD(base.todayUSD)) · 单日纪录 \(fmtUSD(base.recordUSD))"
            put(text(s, size: 11, color: beating ? tone : secondary, mono: true), pad, y)
            if base.daysTogether > 0 { put(text("一起干活第 \(base.daysTogether) 天", size: 11, color: secondary), W - pad, y, align: 2) }
        }
        y += 22
        headerBottom = y

        // 全部 · Claude Code · Codex: every block below follows the switch.
        pillRects = []
        let ids = ["all"] + base.boards.keys.sorted()
        if base.boards.count > 1 {
            var x = pad
            for id in ids {
                let on = id == filter
                let label = text(boardNames[id] ?? id, size: 11, weight: on ? .semibold : .regular, color: on ? primary : secondary)
                let r = NSRect(x: x, y: y, width: label.size().width + 20, height: 22)
                if draw {
                    NSColor.white.withAlphaComponent(on ? 0.16 : 0.05).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
                    put(label, r.midX, r.minY + 4, align: 1)
                }
                pillRects.append((id, r))
                x = r.maxX + 6
            }
            y += 22 + 14
        }

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
        if filter == "all" && !tools.isEmpty {
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

        // Who the same window's work would have needed.
        let jobs = m.jobs.filter { $0.usd > 0 }
        section("相当于请了谁（\(max(m.days.count, 1)) 天）", y, draw: draw)
        y += 22
        if jobs.isEmpty {
            if draw { put(text("还没有回合", size: 11, color: secondary), pad, y) }
            y += 18
        } else {
            let maxU = max(jobs.map(\.usd).max() ?? 1, 0.01)
            for c in jobs.prefix(jobsOpen ? jobs.count : 6) {
                if draw {
                    put(text(c.name, size: 11), pad, y)
                    let br = NSRect(x: pad + 66, y: y + 5, width: inner - 66 - 150, height: 6)
                    bar(br, c.usd / maxU, c.color)
                    let detail = String(format: "%@ × $%.0f = %@", fmtHours(c.hours), c.rate, fmtUSD(c.usd))
                    put(text(detail, size: 10, color: secondary, mono: true), W - pad, y + 1, align: 2)
                }
                y += 19
            }
            moreRect = .zero
            if jobs.count > 6 {
                // A dropdown: "还有 N 种 ▾" opens the rest, "收起 ▴" closes it.
                let rest = jobs.dropFirst(6).map(\.usd).reduce(0, +)
                let label = text(jobsOpen ? "收起 ▴" : "还有 \(jobs.count - 6) 种 · \(fmtUSD(rest))  展开 ▾", size: 10, weight: .medium, color: secondary)
                moreRect = NSRect(x: pad - 4, y: y - 3, width: label.size().width + 8, height: label.size().height + 6)
                if draw {
                    NSColor.white.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: moreRect, xRadius: 5, yRadius: 5).fill()
                    put(label, pad, y)
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
        if let m = shown, !m.days.isEmpty, chartRect.contains(p) {
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
        } else if let (id, _) = pillRects.first(where: { $0.1.contains(p) }) {
            guard id != filter else { return }
            filter = id
            jobsOpen = false
            hover = nil
            onResize?()
        } else if moreRect.contains(p) {
            jobsOpen.toggle()
            onResize?()
        } else if reportRect.contains(p) {
            (NSApp.delegate as? App)?.makeCard(tool: filter)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        (NSApp.delegate as? App)?.popMenu(event, in: self)
    }
}


// MARK: - Desktop pet

/// Sounds for moments: a receipt, a record. Off in the quiet hours and
/// when turned off in the menu.
enum Sounds {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }
    static func play(_ name: String) {
        let hour = Calendar.current.component(.hour, from: Date())
        guard enabled, hour >= 8, hour < 23 else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

struct Receipt { var usd: Double; var name: String; var color: NSColor; var born: Double }

/// The desktop pet: the character at its desk, typing whenever an agent is
/// on a turn, dressed for the job it is doing, with a helper per sub-agent
/// and a receipt for every finished turn. Lives in a transparent panel that
/// sits on the top edge of the widget card.
final class PetView: NSView {
    static let size = NSSize(width: 176, height: 150)
    var model: Model?
    var drawBackground = false
    /// Seconds since launch, advanced by the app's frame timer.
    var t = 0.0
    var receipts: [Receipt] = []
    var sparkleUntil = -1.0
    var onClick: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var blinkAt = 3.0
    private var blinking = false
    private var lastTurnAt = 0.0
    private var lastMouse: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The character's box; only this part takes clicks.
    var characterRect: NSRect { NSRect(x: 48, y: 36, width: 80, height: 80) }

    var animating: Bool {
        guard let m = model else { return false }
        return m.working > 0 || !receipts.isEmpty || t < sparkleUntil
    }

    /// New data: a newer last turn means a receipt.
    func take(_ m: Model) {
        if let first = m.turns.first {
            if lastTurnAt > 0, first.at > lastTurnAt {
                receipts.append(Receipt(usd: first.usd, name: first.name, color: first.color, born: t))
                Sounds.play("Tink")
            }
            lastTurnAt = max(lastTurnAt, first.at)
        }
        model = m
        needsDisplay = true
    }

    func celebrate() {
        sparkleUntil = t + 4
        Sounds.play("Glass")
    }

    func tick(_ dt: Double) {
        t += dt
        if !blinking, t >= blinkAt { blinking = true }
        if blinking, t >= blinkAt + 0.13 {
            blinking = false
            blinkAt = t + Double.random(in: 2.5...5.5)
        }
        receipts.removeAll { t - $0.born > 2.8 }
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
            bounds.fill()
        }
        guard let m = model else { return }
        let working = m.working > 0
        let mood = t < sparkleUntil ? "proud" : (working ? "focused" : m.mood)
        let c = characterRect
        let breathe = CGFloat(sin(t * (working ? 3.0 : 1.6))) * (working ? 1.3 : 0.9)
        // Shadow on the floor.
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.midX - 36, y: 26, width: 72, height: 10)).fill()
        // Helpers: one small blob per sub-agent, behind and to the left.
        for i in 0..<min(m.subagents, 3) {
            let bob = CGFloat(sin(t * 3.2 + Double(i) * 1.7)) * 1.5
            drawCharacter(NSRect(x: 6 + CGFloat(i) * 15, y: 38 + bob, width: 34, height: 34), mood: "focused", ink: ink.withAlphaComponent(0.9))
        }
        drawCharacter(c.offsetBy(dx: 0, dy: breathe), mood: mood, ink: ink, job: m.job?.id, jobColor: m.job?.color, blink: blinking)
        if working {
            // Desk and laptop in front of the body; hands typing.
            NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: c.minX - 10, y: 28, width: c.width + 20, height: 9), xRadius: 3, yRadius: 3).fill()
            NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: c.midX - 24, y: 36, width: 48, height: 5), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: c.midX - 20, y: 40, width: 40, height: 27), xRadius: 3, yRadius: 3).fill()
            (m.job?.color ?? barColor).withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: c.midX - 17, y: 43, width: 34, height: 21), xRadius: 2, yRadius: 2).fill()
            // Lines scrolling up the screen, and a blinking cursor.
            NSColor.white.withAlphaComponent(0.7).setFill()
            for k in 0..<4 {
                let yy = 46 + CGFloat(k) * 5 + CGFloat(fmod(t * 6, 5))
                guard yy < 61 else { continue }
                NSBezierPath(rect: NSRect(x: c.midX - 14, y: yy, width: CGFloat([14, 22, 10, 18][k]), height: 1.5)).fill()
            }
            if fmod(t, 1.0) < 0.5 { NSBezierPath(rect: NSRect(x: c.midX - 14, y: 44, width: 2, height: 3)).fill() }
            ink.setFill()
            for (k, dx) in [(0, CGFloat(-16)), (1, CGFloat(6))] {
                let up: CGFloat = sin(t * 11 + Double(k) * .pi) > 0 ? 2.5 : 0
                NSBezierPath(ovalIn: NSRect(x: c.midX + dx, y: 35 + up, width: 11, height: 7)).fill()
            }
        }
        // Receipts rising from the desk and fading out.
        for rc in receipts {
            let p = min(1, (t - rc.born) / 2.8)
            let ease = 1 - pow(1 - p, 2)
            let alpha = p < 0.65 ? 1 : max(0, 1 - (p - 0.65) / 0.35)
            let card = NSRect(x: c.midX - 44, y: 86 + CGFloat(ease) * 32, width: 88, height: 30)
            NSColor.black.withAlphaComponent(0.18 * alpha).setFill()
            NSBezierPath(roundedRect: card.offsetBy(dx: 0, dy: -2), xRadius: 7, yRadius: 7).fill()
            paper.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
            rc.color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: card.minX + 6, y: card.minY + 7, width: 5, height: 16), xRadius: 2.5, yRadius: 2.5).fill()
            put(text("+" + fmtUSD(rc.usd), size: 13, weight: .bold, color: ink.withAlphaComponent(alpha), mono: true), card.minX + 17, card.minY + 12)
            put(text(rc.name, size: 9, weight: .medium, color: ink2.withAlphaComponent(alpha)), card.minX + 17, card.minY + 3)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let q = convert(point, from: superview)
        return characterRect.insetBy(dx: -8, dy: -8).contains(q) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        lastMouse = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let l = lastMouse else { return }
        let p = NSEvent.mouseLocation
        if dragged || abs(p.x - l.x) + abs(p.y - l.y) > 2 {
            dragged = true
            onDrag?(p.x - l.x, p.y - l.y)
            lastMouse = p
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() } else { onClick?() }
        lastMouse = nil
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
    var petPanel: NSPanel!
    var pet: PetView?
    private var frame = 0
    var petEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "pet") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pet") }
    }

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
        widget.onMoved = { [weak self] in
            self?.saveOrigin()
            self?.placePet()
        }
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
        dashboard.onResize = { [weak self] in self?.refit() }
        scroll.documentView = dashboard
        expanded.addSubview(scroll)

        panel.contentView = compact
        panel.setFrame(NSRect(origin: savedOrigin() ?? defaultOrigin(), size: widgetSize), display: true)
        panel.orderFrontRegardless()

        // The pet: its own transparent panel, clicks only on the character.
        petPanel = NSPanel(contentRect: NSRect(origin: .zero, size: PetView.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        petPanel.level = .floating
        petPanel.isOpaque = false
        petPanel.backgroundColor = .clear
        petPanel.hasShadow = false
        petPanel.hidesOnDeactivate = false
        petPanel.isFloatingPanel = true
        petPanel.becomesKeyOnlyIfNeeded = true
        petPanel.ignoresMouseEvents = true
        petPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = PetView(frame: NSRect(origin: .zero, size: PetView.size))
        v.onClick = { [weak self] in self?.toggle() }
        v.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.panel.setFrameOrigin(NSPoint(x: self.panel.frame.minX + dx, y: self.panel.frame.minY + dy))
            self.placePet()
        }
        v.onDragEnd = { [weak self] in self?.saveOrigin() }
        petPanel.contentView = v
        pet = v
        showPet()
        watchPointer()

        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frame += 1
            if !self.isExpanded, let m = self.widget.model, m.working > 0 || Date() < self.widget.flashUntil {
                self.widget.tick += 1
                self.widget.needsDisplay = true
            }
            if let pet = self.pet, self.petPanel.isVisible {
                pet.tick(1.0 / 24.0)
                // Full frame rate only while something moves; otherwise just blinks.
                if pet.animating || self.frame % 6 == 0 { pet.needsDisplay = true }
            }
        }
    }

    /// The pet sits on the top edge of the widget card.
    func placePet() {
        guard let petPanel, !isExpanded else { return }
        let f = panel.frame
        petPanel.setFrameOrigin(NSPoint(x: f.minX + 6, y: f.maxY - 16))
    }

    func showPet() {
        guard petEnabled, !isExpanded else { return }
        placePet()
        petPanel.orderFrontRegardless()
    }

    private func watchPointer() {
        let update: (NSEvent) -> Void = { [weak self] _ in self?.updatePetHit() }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: update)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { e in
            update(e)
            return e
        }
    }

    /// Clicks pass through the transparent panel except on the character.
    private func updatePetHit() {
        guard let pet, petPanel.isVisible else { return }
        let r = pet.characterRect.insetBy(dx: -8, dy: -8).offsetBy(dx: petPanel.frame.minX, dy: petPanel.frame.minY)
        petPanel.ignoresMouseEvents = !r.contains(NSEvent.mouseLocation)
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
        placePet()
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
        petPanel?.orderOut(nil)
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
        showPet()
    }

    @objc func toggle() { isExpanded ? collapse() : expand() }

    /// Re-fits the open dashboard after its content changed height,
    /// keeping its bottom edge where it is.
    func refit() {
        dashboard.frame.size.height = dashboard.contentHeight()
        dashboard.needsDisplay = true
        guard isExpanded else { return }
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var f = panel.frame
        f.size.height = min(dashboard.frame.height, vf.height - 32)
        f.origin.y = min(f.minY, vf.maxY - f.height - 8)
        expanded.frame.size = f.size
        panel.setFrame(f, display: true)
    }

    /// Runs `shadowcorp card --day today` (for one agent when the dashboard
    /// is switched to it), which renders the day card, copies it to the
    /// clipboard and opens it.
    @objc func makeTodayCard() { makeCard(tool: "all") }

    func makeCard(tool: String) {
        let candidates = [NSHomeDirectory() + "/.local/bin/shadowcorp", "/usr/local/bin/shadowcorp", "/opt/homebrew/bin/shadowcorp"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["card", "--day", "today"] + (tool == "all" ? [] : ["--tool", tool])
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
        let petItem = NSMenuItem(title: "显示桌面宠物", action: #selector(togglePet), keyEquivalent: "")
        petItem.state = petEnabled ? .on : .off
        menu.addItem(petItem)
        let snd = NSMenuItem(title: "结算提示音", action: #selector(toggleSound), keyEquivalent: "")
        snd.state = Sounds.enabled ? .on : .off
        menu.addItem(snd)
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func togglePet() {
        petEnabled.toggle()
        if petEnabled { showPet() } else { petPanel.orderOut(nil) }
    }

    @objc func toggleSound() { Sounds.enabled.toggle() }

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
        if let old = last, old.recordUSD > 0, old.todayUSD < old.recordUSD, m.todayUSD >= m.recordUSD, m.recordUSD > 0 {
            widget.flashText = "单日新高 ✦ \(fmtUSD(m.todayUSD))"
            widget.flashUntil = Date().addingTimeInterval(6)
            pet?.celebrate()
        }
        if last.map({ $0.generatedAt != m.generatedAt }) ?? true {
            widget.model = m
            widget.needsDisplay = true
            pet?.take(m)
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
func drawCharacter(_ r: NSRect, mood: String, ink: NSColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.16, alpha: 1),
                   job: String? = nil, jobColor: NSColor? = nil, blink: Bool = false) {
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let w = r.width, h = r.height
    let cream = NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.89, alpha: 1)
    /// A point `fromTop` of the way down and `fx` across `r`.
    func pt(_ fx: CGFloat, _ fromTop: CGFloat) -> NSPoint {
        NSPoint(x: r.minX + w * fx, y: flipped ? r.minY + h * fromTop : r.maxY - h * fromTop)
    }
    /// A rectangle of `rw` × `rh` turned `deg` degrees (clockwise on screen) around `c`.
    func turned(_ c: NSPoint, _ rw: CGFloat, _ rh: CGFloat, _ deg: CGFloat) -> NSBezierPath {
        let a = deg * .pi / 180 * (flipped ? 1 : -1)
        let (ca, sa) = (cos(a), sin(a))
        let p = NSBezierPath()
        for (i, (dx, dy)) in [(-rw / 2, -rh / 2), (rw / 2, -rh / 2), (rw / 2, rh / 2), (-rw / 2, rh / 2)].enumerated() {
            let q = NSPoint(x: c.x + dx * ca - dy * sa, y: c.y + dx * sa + dy * ca)
            i == 0 ? p.move(to: q) : p.line(to: q)
        }
        p.close()
        return p
    }
    /// An arc over the top of the head (∩) in either coordinate system.
    func arch(_ c: NSPoint, _ radius: CGFloat, _ from: CGFloat, _ to: CGFloat, width: CGFloat, _ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        let (a0, a1): (CGFloat, CGFloat) = flipped ? (180 + from, 180 + to) : (from, to)
        p.appendArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        p.stroke()
    }
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
        if blink && mood != "sleepy" {
            // A closed eye: a short soft line where the eye was.
            white.setStroke()
            let l = NSBezierPath()
            l.lineWidth = max(2, w * 0.04)
            l.lineCapStyle = .round
            l.move(to: NSPoint(x: e.minX + e.width * 0.15, y: e.midY))
            l.line(to: NSPoint(x: e.maxX - e.width * 0.15, y: e.midY))
            l.stroke()
            continue
        }
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
    // Outfit: what the job it is doing right now would wear or hold.
    if let job, let c = jobColor {
        let head = pt(0.5, 0.47)
        switch job {
        case "swe":
            // A hoodie: a thick hood around the head with a drawstring.
            arch(head, w * 0.47, 5, 175, width: w * 0.14, c)
        case "web":
            // A "</>" pin on the chest.
            c.setFill()
            NSBezierPath(roundedRect: box(0.31, 0.74, 0.38, 0.15), xRadius: h * 0.075, yRadius: h * 0.075).fill()
            put(text("</>", size: h * 0.1, weight: .bold, color: .white, mono: true), r.minX + w * 0.5, ty(0.755, size: h * 0.1), align: 1)
        case "qa":
            // A magnifying glass, held up on the right.
            let lens = box(0.74, 0.4, 0.3, 0.3)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: lens).fill()
            c.setStroke()
            let ring = NSBezierPath(ovalIn: lens)
            ring.lineWidth = w * 0.05
            ring.stroke()
            let handle = NSBezierPath()
            handle.lineWidth = w * 0.07
            handle.lineCapStyle = .round
            handle.move(to: pt(0.98, 0.67))
            handle.line(to: pt(1.1, 0.84))
            handle.stroke()
        case "ops":
            // A hard hat.
            c.setFill()
            NSBezierPath(ovalIn: box(0.17, -0.03, 0.66, 0.3)).fill()
            NSBezierPath(roundedRect: box(0.09, 0.2, 0.82, 0.065), xRadius: h * 0.03, yRadius: h * 0.03).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: box(0.44, 0.0, 0.12, 0.2), xRadius: w * 0.04, yRadius: w * 0.04).fill()
        case "data":
            // A little bar chart held at the right.
            cream.setFill()
            NSBezierPath(roundedRect: box(0.7, 0.6, 0.38, 0.36), xRadius: w * 0.04, yRadius: w * 0.04).fill()
            c.setFill()
            for (i, bh) in [0.1, 0.2, 0.15].enumerated() {
                NSBezierPath(rect: box(0.75 + CGFloat(i) * 0.1, 0.9 - CGFloat(bh), 0.07, CGFloat(bh))).fill()
            }
        case "fin":
            // A necktie.
            c.setFill()
            let tie = NSBezierPath()
            tie.move(to: pt(0.45, 0.66)); tie.line(to: pt(0.55, 0.66)); tie.line(to: pt(0.58, 0.9)); tie.line(to: pt(0.5, 0.97)); tie.line(to: pt(0.42, 0.9))
            tie.close()
            tie.fill()
            cream.setFill()
            NSBezierPath(rect: box(0.455, 0.69, 0.09, 0.03)).fill()
        case "research":
            // Round glasses.
            c.setStroke()
            for fx in [CGFloat(0.28), CGFloat(0.55)] {
                let g = NSBezierPath(ovalIn: box(fx - 0.03, 0.29, 0.23, 0.28))
                g.lineWidth = w * 0.035
                g.stroke()
            }
            let bridge = NSBezierPath()
            bridge.lineWidth = w * 0.035
            bridge.move(to: pt(0.48, 0.43)); bridge.line(to: pt(0.52, 0.43))
            bridge.stroke()
        case "writer":
            // A pencil tucked at the side of the head.
            let c0 = pt(0.84, 0.12)
            c.setFill()
            turned(c0, w * 0.34, w * 0.075, 35).fill()
            cream.setFill()
            let a: CGFloat = 35 * .pi / 180 * (flipped ? 1 : -1)
            turned(NSPoint(x: c0.x + cos(a) * w * 0.13, y: c0.y + sin(a) * w * 0.13), w * 0.07, w * 0.075, 35).fill()
        case "translator":
            // A speech bubble saying 译.
            let b = box(0.72, -0.08, 0.36, 0.26)
            cream.setFill()
            NSBezierPath(roundedRect: b, xRadius: w * 0.07, yRadius: w * 0.07).fill()
            let tail = NSBezierPath()
            tail.move(to: pt(0.8, 0.16)); tail.line(to: pt(0.74, 0.26)); tail.line(to: pt(0.88, 0.18))
            tail.close()
            tail.fill()
            put(text("译", size: h * 0.15, weight: .bold, color: c), r.minX + w * 0.9, ty(-0.045, size: h * 0.15), align: 1)
        case "designer":
            // A beret, worn to one side.
            c.setFill()
            NSBezierPath(ovalIn: box(0.08, 0.0, 0.62, 0.2)).fill()
            NSBezierPath(ovalIn: box(0.37, -0.06, 0.06, 0.09)).fill()
        case "video":
            // Headphones.
            arch(head, w * 0.49, 15, 165, width: w * 0.06, c)
            c.setFill()
            NSBezierPath(roundedRect: box(-0.04, 0.35, 0.16, 0.24), xRadius: w * 0.04, yRadius: w * 0.04).fill()
            NSBezierPath(roundedRect: box(0.88, 0.35, 0.16, 0.24), xRadius: w * 0.04, yRadius: w * 0.04).fill()
        case "entry":
            // A stack of forms at the left.
            for i in 0..<3 {
                cream.setFill()
                NSBezierPath(roundedRect: box(-0.06 + CGFloat(i) * 0.03, 0.72 - CGFloat(i) * 0.035, 0.3, 0.3), xRadius: w * 0.02, yRadius: w * 0.02).fill()
            }
            c.setFill()
            for k in 0..<3 {
                NSBezierPath(rect: box(0.04, 0.74 + CGFloat(k) * 0.06, 0.16, 0.025)).fill()
            }
        default:
            break
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
    case "waiting" where !["qa", "data", "entry"].contains(job ?? ""):
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
let gold = NSColor(calibratedRed: 0.83, green: 0.69, blue: 0.22, alpha: 1)

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
        let top = r.l("jobs").first
        drawCharacter(NSRect(x: pad, y: 130, width: 150, height: 150), mood: ch.s("mood"), ink: ink,
                      job: top?["id"] as? String, jobColor: (top?["color"] as? String).map { color(hex: $0) })
        let tx = pad + 200
        put(text(ch.s("headline"), size: 36, color: ink2), tx, 128)
        if !ch.s("number").isEmpty {
            put(text(ch.s("number"), size: 92, weight: .bold, color: ink, mono: true), tx - 4, 166)
        }
        put(text(ch.s("sub"), size: 28, color: ink2, mono: true), tx, 284)
        // Who did it: Claude Code and Codex, each with its dollars and share.
        let tools = toolShares(r.l("tools")).filter { $0.usd > 0 }
        guard tools.count > 1 else { return 356 }
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

    /// "+$724" / "−$120".
    func delta(_ d: Double) -> String { (d >= 0 ? "+" : "−") + fmtUSD(abs(d)) }

    /// Today against the best day so far, and against yesterday.
    func dayRecord(_ r: Report, _ y: CGFloat) -> CGFloat {
        let today = r.d("usd"), best = r.d("record_day_usd")
        let beating = today > 0 && best > 0 && today + 1e-9 >= best
        let tone = beating ? gold : (r.l("jobs").first?["color"] as? String).map { color(hex: $0) } ?? ink
        put(text(beating ? "今天就是单日纪录 ✦" : "单日纪录 \(fmtUSD(best))", size: 26, weight: .semibold, color: tone), pad, y)
        var right = "比昨天 " + delta(today - Report(j: r.o("prev")).d("usd"))
        if r.i("streak") > 1 { right += " · 连续 \(r.i("streak")) 天" }
        put(text(right, size: 24, color: ink2, mono: true), W - pad, y + 2, align: 2)
        let track = NSRect(x: pad, y: y + 46, width: inner, height: 12)
        paper2.setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
        tone.setFill()
        let f = best > 0 ? min(1, today / best) : 0
        NSBezierPath(roundedRect: NSRect(x: pad, y: y + 46, width: max(12, inner * CGFloat(f)), height: 12), xRadius: 6, yRadius: 6).fill()
        return y + 90
    }

    /// This period against the previous one, and the best day so far.
    func compare(_ r: Report, _ y: CGFloat) -> CGFloat {
        let p = Report(j: r.o("prev"))
        let now = r.d("usd"), before = p.d("usd")
        let a = text("\(p.s("label")) \(fmtUSD(before))", size: 28, weight: .semibold, color: ink2)
        put(a, pad, y + 8)
        var x = pad + a.size().width + 20
        put(text("→", size: 28, color: ink2), x, y + 8)
        x += 44
        put(text("\(r.s("kind") == "week" ? "本周" : "本月") \(fmtUSD(now))", size: 28, weight: .bold, color: ink), x, y + 8)
        let d = now - before
        var s = delta(d)
        if before > 0 { s += String(format: " · %@%.0f%%", d >= 0 ? "+" : "−", abs(d / before * 100)) }
        put(text(s, size: 28, weight: .semibold, color: d >= 0 ? ink : ink2, mono: true), W - pad, y + 8, align: 2)
        put(text("单日纪录 \(fmtUSD(r.d("record_day_usd")))", size: 22, color: ink2, mono: true), pad, y + 52)
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
        y = dayRecord(r, y)
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
        y = compare(r, y)
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
        y = compare(r, y)
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
if let i = args.firstIndex(of: "--snapshot-pet"), args.count > i + 1 {
    // --state working|waiting|happy|proud|sleepy|missing, --job ID, --helpers N, --receipt
    _ = NSApplication.shared
    var m = loadModel() ?? Model()
    let flagv = { (f: String) -> String? in args.firstIndex(of: f).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    if let state = flagv("--state") {
        m.working = state == "working" ? 1 : 0
        if state != "working" { m.mood = state }
    }
    if let id = flagv("--job"), let j = m.occupations.first(where: { $0.id == id }) { m.job = j }
    if let n = flagv("--helpers").flatMap({ Int($0) }) { m.subagents = n }
    let v = PetView(frame: NSRect(origin: .zero, size: PetView.size))
    v.drawBackground = args.contains("--backdrop")
    v.model = m
    v.t = 0.9
    if args.contains("--receipt") { v.receipts = [Receipt(usd: 78.4, name: m.job?.name ?? "程序员", color: m.job?.color ?? barColor, born: 0)] }
    snapshot(v, PetView.size, args[i + 1])
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
    let board = args.firstIndex(of: "--board").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "all"
    v.preset(filter: board, jobsOpen: args.contains("--open-jobs"))
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
