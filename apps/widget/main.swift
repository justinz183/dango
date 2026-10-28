// shadowcorp-widget: a small always-on-top panel in the bottom-right corner
// of the screen showing what the agent's output would have cost to hire
// out ($), rank and XP. Click it to expand a dashboard (today / week / month
// / total, 30-day chart, rank road, who you would have hired, recent turns);
// click its header or anywhere else to collapse.
// Reads ~/.shadowcorp/widget.json (written by the daemon) every 2 seconds.
// No dock icon, no menu bar item; right-click for the menu.
//
// Build: apps/widget/build.sh (binary) or apps/widget/bundle.sh (ShadowCorp.app)
// Snapshots (no window): --snapshot-dashboard out.png
// [--board claude_code|codex] [--range 1|7|30] [--open-jobs] [--office N], --snapshot-pet out.png [--state S]
// [--job ID] [--helpers N] [--receipt] [--backdrop] (transparent unless --backdrop)

import AppKit
import Foundation

signal(SIGHUP, SIG_IGN)

let home = ProcessInfo.processInfo.environment["SHADOWCORP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSHomeDirectory() + "/.shadowcorp"
let dataURL = URL(fileURLWithPath: home + "/widget.json")
let agentLabel = "com.shadowcorp.widget"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let dashboardWidth: CGFloat = 420
let originKey = "petOrigin"

// Output bars: one hue (single series), brighter for today.
let barColor = NSColor(red: 0.47, green: 0.72, blue: 0.65, alpha: 1)
let barToday = NSColor(red: 0.65, green: 0.88, blue: 0.81, alpha: 1)

struct DayPoint { var day = ""; var hours = 0.0; var usd = 0.0; var turns = 0 }
/// The occupation the agent is "being" right now, from activity.job.
struct Job { var id = ""; var name = ""; var color = NSColor.gray }
/// Someone in the office: an occupation that worked this week.
struct Occupant {
    var job = Job()
    var working = false
    var helpers = 0
    /// Earned this week.
    var usd = 0.0
    /// Last worked at, unix ms.
    var since = 0.0
}

/// A hash that is the same on every launch (Swift's hashValue is not).
func stableHash(_ s: String) -> Int {
    s.unicodeScalars.reduce(5381) { (($0 &* 33) &+ Int($1.value)) & 0x7fff_ffff }
}
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
    var office: [Occupant] = []
    var working = 0
    var subagents = 0
    var generatedAt = 0.0
    var days: [DayPoint] = []
    /// Today's dollars by local hour (24 values).
    var hours: [Double] = []
    /// Who the work would have needed, over 30 / 7 days and today.
    var jobs: [JobShare] = []
    var jobs7: [JobShare] = []
    var jobs1: [JobShare] = []
    var tools: [ToolShare] = []
    var tools7: [ToolShare] = []
    var tools1: [ToolShare] = []
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
    func jobShares(_ k: String) -> [JobShare] {
        list(k).map {
            JobShare(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", hours: $0["hours"] as? Double ?? 0, usd: $0["usd"] as? Double ?? 0,
                     rate: $0["rate"] as? Double ?? 0, share: $0["share"] as? Double ?? 0, color: color(hex: $0["color"] as? String ?? ""))
        }
    }
    m.jobs = jobShares("jobs")
    m.jobs7 = jobShares("jobs_7d")
    m.jobs1 = jobShares("jobs_1d")
    m.hours = (j["hours"] as? [Double]) ?? []
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
    m.office = list("office").map {
        Occupant(job: Job(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", color: color(hex: $0["color"] as? String ?? "")),
                 working: $0["working"] as? Bool ?? false, helpers: $0["helpers"] as? Int ?? 0, usd: $0["usd"] as? Double ?? 0,
                 since: $0["since"] as? Double ?? 0)
    }
    m.daysTogether = ch["days_together"] as? Int ?? 0
    if let jb = act["job"] as? [String: Any] {
        m.job = Job(id: jb["id"] as? String ?? "", name: jb["name"] as? String ?? "", color: color(hex: jb["color"] as? String ?? ""))
    }
    m.working = act["working"] as? Int ?? 0
    m.subagents = act["subagents"] as? Int ?? 0
    m.generatedAt = j["generated_at"] as? Double ?? 0
    m.tools = toolShares(list("tools"))
    m.tools7 = toolShares(list("tools_7d"))
    m.tools1 = toolShares(list("tools_1d"))
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
    /// The window the three middle blocks cover: 1, 7 or 30 days.
    private(set) var range: Int = {
        let r = UserDefaults.standard.integer(forKey: "range")
        return [1, 7, 30].contains(r) ? r : 30
    }()
    private var rangeRects: [(Int, NSRect)] = []
    /// How many bars the chart currently has (for hover).
    private var chartCount = 0
    /// The office scene, a subview so it can animate on its own.
    let office = OfficeView(frame: .zero)
    /// The "还有 N 种" line under the jobs; clicking it opens the full list.
    private var jobsOpen = false
    private var moreRect = NSRect.zero
    /// Called when the content changes height (switch, jobs list).
    var onResize: (() -> Void)?

    /// For snapshots: start on one agent, a window, and/or with the jobs list open.
    func preset(filter: String, jobsOpen: Bool, range: Int = 30) {
        self.filter = filter
        self.jobsOpen = jobsOpen
        self.range = range
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

        // 全部 · Claude Code · Codex at the left, 1 天 · 7 天 · 30 天 at the
        // right: the three blocks below follow both.
        pillRects = []
        rangeRects = []
        func pill(_ s: String, on: Bool, x: CGFloat, draw: Bool) -> NSRect {
            let label = text(s, size: 11, weight: on ? .semibold : .regular, color: on ? primary : secondary)
            let r = NSRect(x: x, y: y, width: label.size().width + 20, height: 22)
            if draw {
                NSColor.white.withAlphaComponent(on ? 0.16 : 0.05).setFill()
                NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
                put(label, r.midX, r.minY + 4, align: 1)
            }
            return r
        }
        if base.boards.count > 1 {
            var x = pad
            for id in ["all"] + base.boards.keys.sorted() {
                let r = pill(boardNames[id] ?? id, on: id == filter, x: x, draw: draw)
                pillRects.append((id, r))
                x = r.maxX + 6
            }
        }
        var rx = W - pad
        for days in [30, 7, 1] {
            let probe = pill("\(days) 天", on: days == range, x: 0, draw: false)
            let r = pill("\(days) 天", on: days == range, x: rx - probe.width, draw: draw)
            rangeRects.append((days, r))
            rx = r.minX - 6
        }
        y += 22 + 14

        // The office: this week's occupations, whoever is at work typing.
        if office.superview == nil { addSubview(office) }
        let staff = base.office
        let atWork = staff.filter(\.working).count
        let slacking = staff.count - atWork
        let who = [atWork > 0 ? "\(atWork) 人在干" : nil, slacking > 0 ? "\(slacking) 人摸鱼" : nil].compactMap { $0 }.joined(separator: " · ")
        section("办公室", y, right: who.isEmpty ? nil : who, draw: draw)
        y += 22
        office.frame = NSRect(x: pad, y: y, width: inner, height: OfficeView.height)
        office.occupants = staff
        if draw { office.needsDisplay = true }
        y += OfficeView.height + 22

        // Four headline numbers; a caption when they are one agent's.
        if filter != "all" {
            let name = boardNames[filter] ?? filter
            let dot = base.tools.first { $0.name == name }?.color ?? secondary
            if draw {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: pad, y: y + 4, width: 7, height: 7)).fill()
                put(text("只看 \(name) 的", size: 11, weight: .semibold, color: dot), pad + 13, y)
            }
            y += 20
        }
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

        let window = range == 1 ? "今天" : "\(range) 天"
        let jobsSel = (range == 1 ? m.jobs1 : range == 7 ? m.jobs7 : m.jobs).filter { $0.usd > 0 }
        let toolsSel = (range == 1 ? base.tools1 : range == 7 ? base.tools7 : base.tools).filter { $0.usd > 0 }

        // Claude Code and Codex side by side over the window.
        if filter == "all" && !toolsSel.isEmpty {
            section("Claude Code 与 Codex（\(window)）", y, draw: draw)
            y += 22
            if draw {
                var x = pad
                for t in toolsSel {
                    let w = max(3, inner * CGFloat(t.share))
                    t.color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: min(w, pad + inner - x), height: 8), xRadius: 4, yRadius: 4).fill()
                    x += w + 2
                }
            }
            y += 16
            for t in toolsSel {
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

        // The chart: today by hour, or the last 7 / 30 days, one series with
        // direct labels on the best bar and the current one, hover for any.
        var bars: [(usd: Double, tip: String)] = []
        var ticks: [(Int, String)] = []
        var current = -1
        if range == 1 {
            let hour = Calendar.current.component(.hour, from: Date())
            for h in 0..<24 {
                let usd = h < m.hours.count ? m.hours[h] : 0
                bars.append((usd, String(format: "%02d:00–%02d:00 · %@", h, h + 1, fmtUSD(usd))))
            }
            ticks = [(0, "0"), (6, "6"), (12, "12"), (18, "18"), (23, "23")]
            current = hour
        } else {
            let days = Array(m.days.suffix(range))
            for d in days {
                bars.append((d.usd, "\(shortDay(d.day)) · \(fmtUSD(d.usd)) · \(fmtHours(d.hours)) · \(d.turns) 个回合"))
            }
            if range == 7 {
                ticks = days.indices.map { ($0, $0 == days.count - 1 ? "今天" : weekday(days[$0].day)) }
            } else {
                ticks = [(0, shortDay(days.first?.day ?? "")), (days.count / 2, shortDay(days[max(0, days.count / 2)].day)), (days.count - 1, "今天")]
            }
            current = days.count - 1
        }
        let total = bars.map(\.usd).reduce(0, +)
        let rightLabel = range == 1 ? "共 " + fmtUSD(total) : "日均 " + fmtUSD(bars.isEmpty ? 0 : total / Double(bars.count))
        let agent = filter == "all" ? "" : (boardNames[filter] ?? filter) + " · "
        section(agent + (range == 1 ? "今天每小时产出" : "最近 \(range) 天每日产出"), y, right: rightLabel, draw: draw)
        y += 22
        let chartH: CGFloat = 112
        chartRect = NSRect(x: pad, y: y, width: inner, height: chartH)
        chartCount = bars.count
        if draw { drawChart(bars, ticks: ticks, current: current, chartRect) }
        y += chartH + 20

        // Who the window's work would have needed.
        section(agent + "都当了谁（\(window)）", y, draw: draw)
        y += 22
        if jobsSel.isEmpty {
            if draw { put(text(filter == "all" ? "还没有回合" : "\(boardNames[filter] ?? filter)\(range == 1 ? "今天" : "这 \(range) 天")还没有回合", size: 11, color: secondary), pad, y) }
            y += 18
        } else {
            let maxU = max(jobsSel.map(\.usd).max() ?? 1, 0.01)
            for c in jobsSel.prefix(jobsOpen ? jobsSel.count : 6) {
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
            if jobsSel.count > 6 {
                // A dropdown: "还有 N 种 ▾" opens the rest, "收起 ▴" closes it.
                let rest = jobsSel.dropFirst(6).map(\.usd).reduce(0, +)
                let label = text(jobsOpen ? "收起 ▴" : "还有 \(jobsSel.count - 6) 种 · \(fmtUSD(rest))  展开 ▾", size: 10, weight: .medium, color: secondary)
                moreRect = NSRect(x: pad - 4, y: y - 3, width: label.size().width + 8, height: label.size().height + 6)
                if draw {
                    NSColor.white.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: moreRect, xRadius: 5, yRadius: 5).fill()
                    put(label, pad, y)
                }
                y += 19
            }
        }
        y += 18

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

    private func drawChart(_ bars: [(usd: Double, tip: String)], ticks: [(Int, String)], current: Int, _ r: NSRect) {
        let n = bars.count
        guard n > 0 else { return }
        let labelH: CGFloat = 16
        let plotTop = r.minY + 14
        let base = r.maxY - labelH
        let maxUSD = max(bars.map(\.usd).max() ?? 0, 1)
        let slot = r.width / CGFloat(n)
        let bw = max(2, slot - 2)
        let peak = bars.indices.max { bars[$0].usd < bars[$1].usd } ?? 0
        faint.setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: base, width: r.width, height: 1)).fill()
        for (i, d) in bars.enumerated() {
            let h = CGFloat(d.usd / maxUSD) * (base - plotTop)
            guard h > 0 else { continue }
            let x = r.minX + CGFloat(i) * slot + (slot - bw) / 2
            var c = i == current ? barToday : barColor
            if let hv = hover, hv != i { c = c.withAlphaComponent(0.45) }
            c.setFill()
            let rad = min(2, h / 2, bw / 2)
            NSBezierPath(roundedRect: NSRect(x: x, y: base - h, width: bw, height: h), xRadius: rad, yRadius: rad).fill()
            // Square off the baseline end.
            NSBezierPath(rect: NSRect(x: x, y: base - min(h, rad), width: bw, height: min(h, rad))).fill()
        }
        func label(_ i: Int, _ bold: Bool) {
            let h = CGFloat(bars[i].usd / maxUSD) * (base - plotTop)
            let cx = r.minX + CGFloat(i) * slot + slot / 2
            let s = text(fmtUSD(bars[i].usd), size: 9, weight: bold ? .semibold : .regular, color: bold ? primary : secondary, mono: true)
            let sz = s.size()
            let x = min(max(cx, r.minX + sz.width / 2 + 3), r.maxX - sz.width / 2 - 3)
            NSColor(calibratedWhite: 0.13, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - sz.width / 2 - 3, y: base - h - 14, width: sz.width + 6, height: sz.height + 1), xRadius: 3, yRadius: 3).fill()
            put(s, x, base - h - 13, align: 1)
        }
        if let hv = hover, bars.indices.contains(hv) {
            put(text(bars[hv].tip, size: 10, weight: .medium, mono: true), r.maxX, r.minY - 2, align: 2)
            if bars[hv].usd > 0 { label(hv, true) }
        } else {
            if bars[peak].usd > 0 { label(peak, peak == current) }
            if peak != current, bars.indices.contains(current), bars[current].usd > 0 { label(current, true) }
        }
        for (i, name) in ticks where bars.indices.contains(i) {
            let cx = r.minX + CGFloat(i) * slot + slot / 2
            let s = text(name, size: 9, color: secondary)
            put(s, min(max(cx, r.minX + s.size().width / 2), r.maxX - s.size().width / 2), base + 3, align: 1)
        }
    }

    /// 一 … 日 for a YYYY-MM-DD day.
    private func weekday(_ d: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: d) else { return d }
        return ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1]
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
        if chartCount > 0, chartRect.contains(p) {
            h = min(chartCount - 1, max(0, Int((p.x - chartRect.minX) / (chartRect.width / CGFloat(chartCount)))))
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
        } else if let (days, _) = rangeRects.first(where: { $0.1.contains(p) }) {
            guard days != range else { return }
            range = days
            UserDefaults.standard.set(days, forKey: "range")
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


/// A character at work, as the pet and the office draw it: the body (job
/// outfit, blinking, breathing), helpers behind it, and when `working` a
/// desk and laptop in front with hands typing. `c` is the character's box;
/// everything else scales with it.
func drawWorker(_ c: NSRect, job: Job?, mood: String, t: Double, blink: Bool, working: Bool, helpers: Int, desk: Bool? = nil, slump: CGFloat = 0) {
    let s = c.width / 80
    // `slump` lowers the body only (asleep at the desk); the desk stays put.
    let bob = CGFloat(sin(t * (working ? 3.0 : 1.6))) * (working ? 1.3 : 0.9) * s - slump
    NSColor.black.withAlphaComponent(0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.midX - 36 * s, y: c.minY - 10 * s, width: 72 * s, height: 10 * s)).fill()
    for i in 0..<min(helpers, 3) {
        let hb = CGFloat(sin(t * 3.2 + Double(i) * 1.7)) * 1.5 * s
        drawCharacter(NSRect(x: c.minX - 42 * s + CGFloat(i) * 15 * s, y: c.minY + 2 * s + hb, width: 34 * s, height: 34 * s),
                      mood: "focused", ink: ink.withAlphaComponent(0.9))
    }
    drawCharacter(c.offsetBy(dx: 0, dy: bob), mood: mood, ink: ink, job: job?.id, jobColor: job?.color, blink: blink)
    guard desk ?? working else { return }
    // Desk and laptop in front of the body; when working the laptop is open
    // with lines scrolling up the screen, a blinking cursor, hands typing.
    NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.4, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: c.minX - 10 * s, y: c.minY - 8 * s, width: c.width + 20 * s, height: 9 * s), xRadius: 3 * s, yRadius: 3 * s).fill()
    NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: c.midX - 24 * s, y: c.minY, width: 48 * s, height: 5 * s), xRadius: 2 * s, yRadius: 2 * s).fill()
    guard working else {
        NSBezierPath(roundedRect: NSRect(x: c.midX - 22 * s, y: c.minY + 5 * s, width: 44 * s, height: 3 * s), xRadius: 1.5 * s, yRadius: 1.5 * s).fill()
        return
    }
    NSBezierPath(roundedRect: NSRect(x: c.midX - 20 * s, y: c.minY + 4 * s, width: 40 * s, height: 27 * s), xRadius: 3 * s, yRadius: 3 * s).fill()
    (job?.color ?? barColor).withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: c.midX - 17 * s, y: c.minY + 7 * s, width: 34 * s, height: 21 * s), xRadius: 2 * s, yRadius: 2 * s).fill()
    NSColor.white.withAlphaComponent(0.7).setFill()
    for k in 0..<4 {
        let yy = c.minY + (10 + CGFloat(k) * 5 + CGFloat(fmod(t * 6, 5))) * s
        guard yy < c.minY + 25 * s else { continue }
        NSBezierPath(rect: NSRect(x: c.midX - 14 * s, y: yy, width: CGFloat([14, 22, 10, 18][k]) * s, height: 1.5 * s)).fill()
    }
    if fmod(t, 1.0) < 0.5 { NSBezierPath(rect: NSRect(x: c.midX - 14 * s, y: c.minY + 8 * s, width: 2 * s, height: 3 * s)).fill() }
    ink.setFill()
    for (k, dx) in [(0, CGFloat(-16)), (1, CGFloat(6))] {
        let up: CGFloat = sin(t * 11 + Double(k) * .pi) > 0 ? 2.5 : 0
        NSBezierPath(ovalIn: NSRect(x: c.midX + dx * s, y: c.minY + (up - 1) * s, width: 11 * s, height: 7 * s)).fill()
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

/// The desktop pet — the whole collapsed UI: the character at its desk,
/// typing whenever an agent is on a turn, dressed for the job it is doing,
/// with a helper per sub-agent, a receipt for every finished turn, and one
/// quiet caption under it (today's dollars; its line when hovered). Lives
/// in a transparent panel; only the character and the caption take clicks.
final class PetView: NSView {
    static let size = NSSize(width: 176, height: 168)
    var model: Model?
    var drawBackground = false
    /// Seconds since launch, advanced by the app's frame timer.
    var t = 0.0
    var receipts: [Receipt] = []
    var sparkleUntil = -1.0
    var flashText = ""
    var flashUntil = -1.0
    var onClick: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var blinkAt = 3.0
    private var blinking = false
    private var lastTurnAt = 0.0
    private var lastMouse: NSPoint?
    private var dragged = false
    private var hovering = false
    private var captionRect = NSRect(x: 40, y: 6, width: 96, height: 22)

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var characterRect: NSRect { NSRect(x: 48, y: 50, width: 80, height: 80) }
    /// What takes the pointer: the character and the caption.
    var hitRect: NSRect { characterRect.insetBy(dx: -8, dy: -8).union(captionRect) }

    var animating: Bool {
        guard let m = model else { return false }
        return m.working > 0 || !receipts.isEmpty || t < sparkleUntil || t < flashUntil
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

    func flash(_ s: String) {
        flashText = s
        flashUntil = t + 6
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
            bounds.fill()
        }
        guard let m = model else { return }
        let working = m.working > 0
        let mood = t < sparkleUntil ? "proud" : (working ? "focused" : m.mood)
        let c = characterRect
        drawWorker(c, job: m.job, mood: mood, t: t, blink: blinking, working: working, helpers: m.subagents)
        // Receipts rising from the desk and fading out.
        for rc in receipts {
            let p = min(1, (t - rc.born) / 2.8)
            let ease = 1 - pow(1 - p, 2)
            let alpha = p < 0.65 ? 1 : max(0, 1 - (p - 0.65) / 0.35)
            let card = NSRect(x: c.midX - 44, y: c.minY + 50 + CGFloat(ease) * 32, width: 88, height: 30)
            NSColor.black.withAlphaComponent(0.18 * alpha).setFill()
            NSBezierPath(roundedRect: card.offsetBy(dx: 0, dy: -2), xRadius: 7, yRadius: 7).fill()
            paper.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
            rc.color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: card.minX + 6, y: card.minY + 7, width: 5, height: 16), xRadius: 2.5, yRadius: 2.5).fill()
            put(text("+" + fmtUSD(rc.usd), size: 13, weight: .bold, color: ink.withAlphaComponent(alpha), mono: true), card.minX + 17, card.minY + 12)
            put(text(rc.name, size: 9, weight: .medium, color: ink2.withAlphaComponent(alpha)), card.minX + 17, card.minY + 3)
        }
        // The caption: today's dollars; the line when hovered; the record when just beaten.
        let tone = m.job?.color ?? barColor
        let caption: NSAttributedString
        if t < flashUntil {
            caption = text(flashText, size: 11, weight: .semibold, color: tone, mono: true)
        } else if hovering, !m.line.isEmpty {
            caption = text(truncate("\(m.name)：\(m.line)", size: 11, weight: .medium, width: bounds.width - 28), size: 11, weight: .medium)
        } else {
            caption = text("今日 " + fmtUSD(m.todayUSD), size: 11, weight: .medium, color: secondary, mono: true)
        }
        let w = min(bounds.width - 8, caption.size().width + 20)
        captionRect = NSRect(x: (bounds.width - w) / 2, y: 6, width: w, height: 22)
        NSColor(calibratedWhite: 0.1, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: captionRect, xRadius: 11, yRadius: 11).fill()
        put(caption, captionRect.midX, captionRect.minY + 4, align: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitRect.contains(convert(point, from: superview)) ? self : nil
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

// MARK: - Office

/// The office in the dashboard: the occupations that worked this week,
/// one character each in its outfit. Whoever's job a running turn is doing
/// types at a desk, with helpers; the rest slack off — coffee right after
/// a turn, then phone, window or watering the plant, asleep after two
/// quiet hours — each with its own motion and a plate saying what it is up to.
final class OfficeView: NSView {
    static let height: CGFloat = 178
    var occupants: [Occupant] = []
    var t = 0.0
    override var isFlipped: Bool { false }
    var animating: Bool { !occupants.isEmpty }

    enum Pastime { case typing, coffee, phone, window, plant, sleep }

    func tick(_ dt: Double) { t += dt }

    /// What each occupant is doing: from work and idle time, with the
    /// pastime rotating every three minutes; one at the window, one at the plant.
    private func plan() -> [(Occupant, Pastime)] {
        let now = Date().timeIntervalSince1970 * 1000
        var windowTaken = false, plantTaken = false
        return occupants.prefix(5).map { o in
            if o.working { return (o, .typing) }
            let idle = (now - o.since) / 60_000
            if idle < 15 { return (o, .coffee) }
            if idle > 120 { return (o, .sleep) }
            switch stableHash(o.job.id + "\(Int(now / 180_000))") % 4 {
            case 0 where !windowTaken:
                windowTaken = true
                return (o, .window)
            case 1 where !plantTaken:
                plantTaken = true
                return (o, .plant)
            case 2: return (o, .coffee)
            default: return (o, .phone)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let floorH: CGFloat = 50
        let room = NSBezierPath(roundedRect: b, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        room.addClip()
        NSColor(calibratedWhite: 0.165, alpha: 1).setFill()
        b.fill()
        NSColor(calibratedWhite: 0.125, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: b.width, height: floorH)).fill()
        NSColor.white.withAlphaComponent(0.035).setFill()
        for x in stride(from: CGFloat(13), to: b.width, by: 26) {
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 1, height: floorH)).fill()
        }
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: floorH, width: b.width, height: 2)).fill()
        // The window: the sky of the hour.
        let hour = Calendar.current.component(.hour, from: Date())
        let win = NSRect(x: b.maxX - 92, y: b.maxY - 70, width: 68, height: 48)
        let night = hour < 6 || hour >= 19
        let sky = NSGradient(starting: night ? NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.3, alpha: 1) : NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.92, alpha: 1),
                             ending: night ? NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.4, alpha: 1) : NSColor(calibratedRed: 0.82, green: 0.9, blue: 0.96, alpha: 1))
        sky?.draw(in: NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4), angle: 90)
        if night {
            NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.8, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: win.maxX - 24, y: win.maxY - 22, width: 12, height: 12)).fill()
            for (sx, sy) in [(12.0, 30.0), (26.0, 18.0), (40.0, 34.0)] {
                NSBezierPath(ovalIn: NSRect(x: win.minX + sx, y: win.minY + sy, width: 2, height: 2)).fill()
            }
        } else {
            NSColor(calibratedRed: 1, green: 0.9, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: win.maxX - 26, y: win.maxY - 24, width: 14, height: 14)).fill()
        }
        NSColor(calibratedWhite: 0.3, alpha: 1).setStroke()
        let frame = NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4)
        frame.lineWidth = 3
        frame.stroke()
        let cross = NSBezierPath()
        cross.lineWidth = 2
        cross.move(to: NSPoint(x: win.midX, y: win.minY)); cross.line(to: NSPoint(x: win.midX, y: win.maxY))
        cross.move(to: NSPoint(x: win.minX, y: win.midY)); cross.line(to: NSPoint(x: win.maxX, y: win.midY))
        cross.stroke()
        // A plant by the wall.
        NSColor(calibratedRed: 0.62, green: 0.4, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: b.maxX - 44, y: floorH - 2, width: 20, height: 16), xRadius: 3, yRadius: 3).fill()
        NSColor(calibratedRed: 0.36, green: 0.6, blue: 0.4, alpha: 1).setFill()
        for (dx, dy, rot) in [(-6.0, 14.0, -30.0), (6.0, 16.0, 30.0), (0.0, 22.0, 0.0)] {
            let leaf = NSBezierPath(ovalIn: NSRect(x: -5, y: -10, width: 10, height: 22))
            leaf.transform(using: AffineTransform(rotationByDegrees: rot))
            leaf.transform(using: AffineTransform(translationByX: b.maxX - 34 + dx, byY: floorH + dy))
            leaf.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let plan = plan()
        if plan.isEmpty {
            put(text("现在没人在干活", size: 12, color: secondary), b.midX, floorH + 34, align: 1)
            put(text("有 agent 开工，它就会坐到这里。", size: 10, color: secondary), b.midX, floorH + 16, align: 1)
            return
        }
        // Desks from the left wall (room for helpers) up to whoever stands at
        // the window or the plant.
        let deskers = plan.filter { $0.1 != .window && $0.1 != .plant }.count
        let windowX = b.maxX - 128, plantX = b.maxX - 76
        var right = b.width - 56
        if plan.contains(where: { $0.1 == .window }) { right = min(right, windowX - 30) }
        if plan.contains(where: { $0.1 == .plant }) { right = min(right, plantX - 30) }
        let left: CGFloat = 30
        let slot = deskers > 0 ? (right - left) / CGFloat(deskers) : 0
        var di = 0
        for (o, p) in plan {
            let cx: CGFloat
            switch p {
            case .window: cx = windowX
            case .plant: cx = plantX
            default:
                cx = left + slot * (CGFloat(di) + 0.5)
                di += 1
            }
            let phase = t + Double(stableHash(o.job.id) % 100) * 0.07
            let blink = fmod(phase, 4.3) < 0.12
            // Characters shrink a little when the desks get close.
            let size = min(56, max(44, slot - 10))
            let c = NSRect(x: cx - size / 2, y: floorH + 6, width: size, height: size)
            let state: String
            switch p {
            case .typing:
                drawWorker(c, job: o.job, mood: "focused", t: phase, blink: blink, working: true, helpers: o.helpers)
                state = "在干" + (o.helpers > 0 ? " · +\(o.helpers)" : "")
            case .coffee:
                drawWorker(c, job: o.job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: true)
                // A mug in front, steam rising.
                NSColor(calibratedRed: 0.79, green: 0.71, blue: 0.54, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: c.minX - 12, y: c.minY + 2, width: 11, height: 12), xRadius: 2, yRadius: 2).fill()
                NSBezierPath(ovalIn: NSRect(x: c.minX - 16, y: c.minY + 5, width: 6, height: 6)).fill()
                for k in 0..<2 {
                    let rise = CGFloat(fmod(phase * 9 + Double(k) * 7, 14))
                    NSColor.white.withAlphaComponent(0.35 * (1 - rise / 14)).setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.minX - 9 + CGFloat(k) * 4 + CGFloat(sin(phase * 3 + Double(k))) * 1.5, y: c.minY + 15 + rise, width: 3, height: 5)).fill()
                }
                state = "喝咖啡"
            case .phone:
                drawWorker(c, job: o.job, mood: "focused", t: phase, blink: blink, working: false, helpers: 0, desk: true)
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: c.midX - 6, y: c.minY + 10, width: 12, height: 18), xRadius: 2, yRadius: 2).fill()
                o.job.color.withAlphaComponent(0.55 + 0.3 * CGFloat(sin(phase * 2.6))).setFill()
                NSBezierPath(roundedRect: NSRect(x: c.midX - 4.5, y: c.minY + 12, width: 9, height: 14), xRadius: 1, yRadius: 1).fill()
                state = "刷手机"
            case .sleep:
                drawWorker(c, job: o.job, mood: "sleepy", t: phase * 0.5, blink: true, working: false, helpers: 0, desk: true, slump: 5)
                state = "睡着了"
            case .window:
                drawWorker(c, job: o.job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false)
                state = "看窗外"
            case .plant:
                drawWorker(c, job: o.job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false)
                // A watering can that tips toward the plant; drops when tipped.
                let tilt = -20 - 15 * CGFloat(sin(phase * 1.5))
                let can = NSBezierPath(roundedRect: NSRect(x: -7, y: -5, width: 14, height: 10), xRadius: 2, yRadius: 2)
                can.move(to: NSPoint(x: 6, y: 3)); can.line(to: NSPoint(x: 14, y: 7)); can.line(to: NSPoint(x: 14, y: 5)); can.line(to: NSPoint(x: 7, y: 0))
                can.close()
                can.transform(using: AffineTransform(rotationByDegrees: tilt))
                can.transform(using: AffineTransform(translationByX: c.maxX + 2, byY: c.minY + 20))
                NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.75, alpha: 1).setFill()
                can.fill()
                if tilt < -28 {
                    NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 0.9).setFill()
                    for k in 0..<2 {
                        let fall = CGFloat(fmod(phase * 24 + Double(k) * 6, 14))
                        NSBezierPath(ovalIn: NSRect(x: c.maxX + 14 + CGFloat(k) * 3, y: c.minY + 16 - fall, width: 2, height: 3)).fill()
                    }
                }
                state = "浇花"
            }
            // Plate on the floor: the occupation in its colour, then what it is
            // doing · what it earned this week (the dollars only when they fit).
            let width = (p == .window || p == .plant) ? CGFloat(64) : slot - 6
            let fs: CGFloat = slot < 72 ? 9 : 10
            put(text(truncate(o.job.name, size: fs, weight: .semibold, width: width), size: fs, weight: .semibold, color: o.job.color), cx, 24, align: 1)
            let sub = width >= 66 ? state + " · " + fmtUSD(o.usd) : state
            put(text(truncate(sub, size: fs - 1, weight: .regular, width: width + 8), size: fs - 1, color: secondary, mono: true), cx, 9, align: 1)
        }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var expanded: NSView!
    var scroll: NSScrollView!
    var dashboard: DashboardView!
    var last: Model?
    var isExpanded = false
    var outsideClick: Any?
    var petPanel: NSPanel!
    var pet: PetView?
    private var frame = 0

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
        // The dashboard panel: shown only while expanded.
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: dashboardWidth, height: 600)),
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
        panel.contentView = expanded

        // The pet: the whole collapsed UI, in a transparent panel that takes
        // clicks only on the character and its caption.
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
            self.petPanel.setFrameOrigin(NSPoint(x: self.petPanel.frame.minX + dx, y: self.petPanel.frame.minY + dy))
        }
        v.onDragEnd = { [weak self] in self?.saveOrigin() }
        petPanel.contentView = v
        pet = v
        petPanel.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        petPanel.orderFrontRegardless()
        watchPointer()

        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frame += 1
            // Full frame rate only while something moves; otherwise just blinks.
            if let pet = self.pet, self.petPanel.isVisible {
                pet.tick(1.0 / 24.0)
                if pet.animating || self.frame % 6 == 0 { pet.needsDisplay = true }
            }
            if self.isExpanded {
                let office = self.dashboard.office
                office.tick(1.0 / 24.0)
                if office.animating || self.frame % 6 == 0 { office.needsDisplay = true }
            }
        }
    }

    func showPet() {
        guard !isExpanded else { return }
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
        let r = pet.hitRect.offsetBy(dx: petPanel.frame.minX, dy: petPanel.frame.minY)
        petPanel.ignoresMouseEvents = !r.contains(NSEvent.mouseLocation)
    }

    // Where the pet stands, remembered across launches.
    private func defaultOrigin() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - PetView.size.width - 12, y: vf.minY + 4)
    }

    private func savedOrigin() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
        let p = NSPoint(x: a[0], y: a[1])
        let r = NSRect(origin: p, size: PetView.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } ? p : nil
    }

    func saveOrigin() {
        let o = petPanel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: originKey)
    }

    @objc func resetPosition() {
        if isExpanded { collapse() }
        petPanel.setFrameOrigin(defaultOrigin())
        saveOrigin()
    }

    // MARK: expand / collapse

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        let anchor = petPanel.frame
        let vf = (petPanel.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        dashboard.frame.size.width = dashboardWidth
        let h = min(dashboard.contentHeight(), vf.height - 32)
        dashboard.frame.size.height = dashboard.contentHeight()
        // Grow up and to the left from where the pet stands, then keep the
        // whole panel on screen.
        var f = NSRect(x: anchor.maxX - dashboardWidth, y: anchor.minY, width: dashboardWidth, height: h)
        f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
        f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        expanded.frame.size = f.size
        dashboard.scroll(NSPoint.zero)
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()
        petPanel.orderOut(nil)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapse()
        }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        if let m = outsideClick { NSEvent.removeMonitor(m) }
        outsideClick = nil
        panel.orderOut(nil)
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
            pet?.flash("单日新高 ✦ \(fmtUSD(m.todayUSD))")
            pet?.celebrate()
        }
        if last.map({ $0.generatedAt != m.generatedAt }) ?? true {
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
        if blink {
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
        title("都当了谁", y, right: all.isEmpty ? nil : "\(all.count) 种工作")
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
    let range = args.firstIndex(of: "--range").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 30
    v.preset(filter: board, jobsOpen: args.contains("--open-jobs"), range: range)
    // --office N fills the room with N made-up occupants, for a look.
    if let n = args.firstIndex(of: "--office").flatMap({ args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }), var m = v.model, !m.occupations.isEmpty {
        m.office = (0..<n).map { i in
            Occupant(job: m.occupations[(i * 3) % m.occupations.count], working: i == 0 || i == 3, helpers: i == 0 ? 2 : 0,
                     usd: Double(140 * (i + 1)), since: Date().timeIntervalSince1970 * 1000 - [2.0, 40, 200, 1, 5, 70][i % 6] * 60_000)
        }
        v.model = m
    }
    v.office.t = 0.9
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
