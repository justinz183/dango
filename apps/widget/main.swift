// dango-widget: a small always-on-top panel in the bottom-right corner
// of the screen showing what the agent's output would have cost to hire
// out ($), rank and XP. Click it to expand a dashboard (today / week / month
// / total, 30-day chart, rank road, who you would have hired, recent turns);
// click its header or anywhere else to collapse.
// Reads ~/.dango/widget.json (written by the daemon) every 2 seconds.
// No dock icon, no menu bar item; right-click for the menu.
//
// Build: apps/widget/build.sh (binary) or apps/widget/bundle.sh (Dango.app)
// Snapshots (no window): --snapshot-dashboard out.png
// [--board claude_code|codex] [--range 1|7|30] [--open-jobs] [--office N], --snapshot-office out.png
// [--jobs id,…] [--working K] [--walk SEC], --snapshot-pet out.png [--state S]
// [--job ID] [--helpers N] [--receipt] [--backdrop] (transparent unless --backdrop)

import AppKit
import Foundation

signal(SIGHUP, SIG_IGN)

/// ~/.dango, or $DANGO_HOME; an install from before the rename keeps ~/.shadowcorp.
let home: String = {
    let env = ProcessInfo.processInfo.environment
    if let h = (env["DANGO_HOME"] ?? env["SHADOWCORP_HOME"]).flatMap({ $0.isEmpty ? nil : $0 }) { return h }
    let (new, old) = (NSHomeDirectory() + "/.dango", NSHomeDirectory() + "/.shadowcorp")
    return !FileManager.default.fileExists(atPath: new) && FileManager.default.fileExists(atPath: old) ? old : new
}()
let dataURL = URL(fileURLWithPath: home + "/widget.json")
let agentLabel = "com.dango.widget"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let dashboardWidth: CGFloat = 420
/// The interface language ("zh" / "en"): from widget.json, or from a card's
/// report while it is drawn; remembered for the next launch.
var lang = UserDefaults.standard.string(forKey: "lang") ?? "zh"
/// The Chinese or the English text.
func L(_ zh: String, _ en: String) -> String { lang == "en" ? en : zh }

/// The dango command, wherever it is installed (the old name still works).
func cliPath() -> String? {
    [NSHomeDirectory() + "/.local/bin/dango", "/usr/local/bin/dango", "/opt/homebrew/bin/dango", NSHomeDirectory() + "/.local/bin/shadowcorp"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
let originKey = "petOrigin"

// Output bars: one hue (single series), brighter for today.
let barColor = NSColor(red: 0.47, green: 0.72, blue: 0.65, alpha: 1)
let barToday = NSColor(red: 0.65, green: 0.88, blue: 0.81, alpha: 1)

struct DayPoint { var day = ""; var hours = 0.0; var usd = 0.0; var turns = 0 }
/// The occupation the agent is "being" right now, from activity.job.
struct Job { var id = ""; var name = ""; var color = NSColor.gray; var scene = "desk"; var look: [String] = [] }

/// Hand-held parts: a character holding one does not also get the idle mug.
let handProps: Set<String> = ["magnifier", "chart", "papers", "pencil", "brush", "camera", "guitar", "dumbbell", "pan", "gavel", "calculator", "briefcase",
                              "clipboard", "phone", "house", "globe", "ruler", "tape", "scissors", "comb", "apple", "pill", "notebook", "bone", "book",
                              "flask", "leaf", "atom", "blueprint", "gear", "circuit", "bolt", "hammer", "wrench", "pipe", "can", "teddy", "shield", "frame"]
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
struct ToolShare { var name = ""; var usd = 0.0; var hours = 0.0; var share = 0.0; var color = NSColor.gray; var cost = 0.0 }

/// Economic leverage, as the daemon formats it: "19.7x", "250x", "—".
func fmtLev(_ usd: Double, _ cost: Double) -> String {
    guard cost >= 0.01 else { return "—" }
    let l = usd / cost
    return l >= 100 ? "\(Int(l.rounded()))x" : String(format: "%.1fx", l)
}

func toolShares(_ list: [[String: Any]]) -> [ToolShare] {
    list.map {
        ToolShare(name: $0["name"] as? String ?? "", usd: $0["usd"] as? Double ?? 0, hours: $0["hours"] as? Double ?? 0,
                  share: $0["share"] as? Double ?? 0, color: color(hex: $0["color"] as? String ?? ""), cost: $0["cost"] as? Double ?? 0)
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
    /// What the models cost at API prices, per tile.
    var todayCost = 0.0
    var weekCost = 0.0
    var monthCost = 0.0
    var totalCost = 0.0
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
var boardNames: [String: String] { ["all": L("全部", "All"), "claude_code": "Claude Code", "codex": "Codex"] }

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
    m.todayCost = today["cost"] as? Double ?? 0
    m.weekCost = week["cost"] as? Double ?? 0
    m.monthCost = month["cost"] as? Double ?? 0
    m.totalCost = total["cost"] as? Double ?? 0
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
    if let l = j["lang"] as? String, l != lang {
        lang = l
        UserDefaults.standard.set(l, forKey: "lang")
    }
    let act = obj("activity")
    applyBoard(&m, j)
    m.weekLeverage = obj("week")["leverage"] as? Double
    let ch = obj("character")
    m.name = ch["name"] as? String ?? "Claude"
    m.mood = ch["mood"] as? String ?? "happy"
    m.line = ch["line"] as? String ?? ""
    m.ratesLabel = obj("rates")["label"] as? String ?? ""
    m.recordUSD = obj("record")["day_usd"] as? Double ?? 0
    m.occupations = list("occupations").map {
        Job(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", color: color(hex: $0["color"] as? String ?? ""),
            scene: $0["scene"] as? String ?? "desk", look: $0["look"] as? [String] ?? [])
    }
    /// A job as the table knows it (scene, look), from its id.
    func job(_ j: [String: Any]) -> Job {
        let id = j["id"] as? String ?? ""
        var out = m.occupations.first { $0.id == id } ?? Job(id: id)
        if let n = j["name"] as? String { out.name = n }
        if let c = j["color"] as? String { out.color = color(hex: c) }
        return out
    }
    m.office = list("office").map {
        Occupant(job: job($0), working: $0["working"] as? Bool ?? false, helpers: $0["helpers"] as? Int ?? 0, usd: $0["usd"] as? Double ?? 0,
                 since: $0["since"] as? Double ?? 0)
    }
    m.daysTogether = ch["days_together"] as? Int ?? 0
    if let jb = act["job"] as? [String: Any] { m.job = job(jb) }
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
    if h < 1 { return "\(Int((h * 60).rounded())) " + L("分钟", "min") }
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
    drawCharacter(r.insetBy(dx: inset, dy: inset), mood: mood, look: job?.look ?? [], jobColor: job?.color, flavor: petFlavor)
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
    private var exportRects: [(String, NSRect)] = []
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
            if draw { put(text(L("等待数据…", "Waiting for data…"), size: 13, weight: .medium, color: secondary), pad, y) }
            return 80
        }

        // Header: the character, the total and the job, centred on the
        // badge. Clicking it collapses.
        let tone = accent(base)
        if draw {
            characterBadge(NSRect(x: pad, y: y, width: 48, height: 48), mood: base.mood, ring: tone, job: base.job)
            let total = text(fmtUSD(base.totalUSD), size: 20, weight: .bold, mono: true)
            put(total, pad + 60, y + 11)
            put(text(L("累计", "total"), size: 11, color: secondary), pad + 66 + total.size().width, y + 17)
            if let j = base.job {
                put(text(L("· 在当\(j.name)", "· working as \(j.name)"), size: 11, color: j.color), pad + 66 + total.size().width + 30, y + 17)
            }
            put(text(L("收起 ⌄", "Close ⌄"), size: 11, color: secondary), W - pad, y + 16, align: 2)
        }
        y += 58
        let beating = base.recordUSD > 0 && base.todayUSD + 1e-9 >= base.recordUSD && base.todayUSD > 0
        if draw { bar(NSRect(x: pad, y: y, width: inner, height: 6), base.recordUSD > 0 ? base.todayUSD / base.recordUSD : 0, tone) }
        y += 12
        if draw {
            let s = beating ? L("今天就是单日纪录 ✦ ", "New best day ✦ ") + fmtUSD(base.todayUSD)
                : L("今日 \(fmtUSD(base.todayUSD)) · 单日纪录 \(fmtUSD(base.recordUSD))", "Today \(fmtUSD(base.todayUSD)) · best day \(fmtUSD(base.recordUSD))")
            put(text(s, size: 11, color: beating ? tone : secondary, mono: true), pad, y)
            if base.daysTogether > 0 { put(text(L("一起干活第 \(base.daysTogether) 天", "Day \(base.daysTogether) together"), size: 11, color: secondary), W - pad, y, align: 2) }
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
            let label = L("\(days) 天", days == 1 ? "1 day" : "\(days) days")
            let probe = pill(label, on: days == range, x: 0, draw: false)
            let r = pill(label, on: days == range, x: rx - probe.width, draw: draw)
            rangeRects.append((days, r))
            rx = r.minX - 6
        }
        y += 22 + 14

        // The office: this week's occupations, whoever is at work typing.
        if office.superview == nil { addSubview(office) }
        let staff = base.office
        let atWork = staff.filter(\.working).count
        let slacking = staff.count - atWork
        let who = [atWork > 0 ? L("\(atWork) 人在干", "\(atWork) working") : nil, slacking > 0 ? L("\(slacking) 人摸鱼", "\(slacking) slacking") : nil].compactMap { $0 }.joined(separator: " · ")
        section(L("办公室", "Office"), y, right: who.isEmpty ? nil : who, draw: draw)
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
                put(text(L("只看 \(name) 的", "Only \(name)"), size: 11, weight: .semibold, color: dot), pad + 13, y)
            }
            y += 20
        }
        let tiles: [(String, Double, Double, Double)] = [(L("今日", "Today"), m.todayUSD, m.todayHours, m.todayCost), (L("本周", "This week"), m.weekUSD, m.weekHours, m.weekCost),
                                                          (L("本月", "This month"), m.monthUSD, m.monthHours, m.monthCost), (L("总计", "Total"), m.totalUSD, m.totalHours, m.totalCost)]
        let gap: CGFloat = 8
        let tw = (inner - gap * 3) / 4
        if draw {
            for (i, t) in tiles.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (tw + gap), y: y, width: tw, height: 58)
                NSColor.white.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                put(text(t.0, size: 10, color: secondary), r.minX + 9, r.minY + 8)
                put(text(fmtUSD(t.1), size: 15, weight: .bold, mono: true), r.minX + 9, r.minY + 22)
                // Under the dollars: the model cost and the leverage, else the hours.
                let sub = t.3 >= 0.01 ? L("花 ", "cost ") + "\(fmtUSD(t.3)) · \(fmtLev(t.1, t.3))" : fmtHours(t.2) + L(" 的活", " of work")
                put(text(sub, size: 9, color: secondary, mono: true), r.minX + 9, r.minY + 41)
            }
        }
        y += 58 + 22

        let window = range == 1 ? L("今天", "today") : L("\(range) 天", "\(range) days")
        let jobsSel = (range == 1 ? m.jobs1 : range == 7 ? m.jobs7 : m.jobs).filter { $0.usd > 0 }
        let toolsSel = (range == 1 ? base.tools1 : range == 7 ? base.tools7 : base.tools).filter { $0.usd > 0 }

        // Claude Code and Codex side by side over the window.
        if filter == "all" && !toolsSel.isEmpty {
            section(L("Claude Code 与 Codex（\(window)）", "Claude Code and Codex (\(window))"), y, draw: draw)
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
                    let lev = t.cost >= 0.01 ? " ÷ \(fmtUSD(t.cost)) = \(fmtLev(t.usd, t.cost))" : " · " + fmtHours(t.hours)
                    let detail = String(format: "%@%@ · %.0f%%", fmtUSD(t.usd), lev, t.share * 100)
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
                bars.append((d.usd, "\(shortDay(d.day)) · \(fmtUSD(d.usd)) · \(fmtHours(d.hours)) · " + L("\(d.turns) 个回合", "\(d.turns) turns")))
            }
            if range == 7 {
                ticks = days.indices.map { ($0, $0 == days.count - 1 ? L("今天", "Today") : weekday(days[$0].day)) }
            } else {
                ticks = [(0, shortDay(days.first?.day ?? "")), (days.count / 2, shortDay(days[max(0, days.count / 2)].day)), (days.count - 1, L("今天", "Today"))]
            }
            current = days.count - 1
        }
        let total = bars.map(\.usd).reduce(0, +)
        let rightLabel = range == 1 ? L("共 ", "Total ") + fmtUSD(total) : L("日均 ", "Daily avg ") + fmtUSD(bars.isEmpty ? 0 : total / Double(bars.count))
        let agent = filter == "all" ? "" : (boardNames[filter] ?? filter) + " · "
        section(agent + (range == 1 ? L("今天每小时产出", "Output by hour today") : L("最近 \(range) 天每日产出", "Daily output, last \(range) days")), y, right: rightLabel, draw: draw)
        y += 22
        let chartH: CGFloat = 112
        chartRect = NSRect(x: pad, y: y, width: inner, height: chartH)
        chartCount = bars.count
        if draw { drawChart(bars, ticks: ticks, current: current, chartRect) }
        y += chartH + 20

        // Who the window's work would have needed.
        section(agent + L("都当了谁（\(window)）", "Who you hired (\(window))"), y, draw: draw)
        y += 22
        if jobsSel.isEmpty {
            if draw { put(text(filter == "all" ? L("还没有回合", "No turns yet")
                                     : L("\(boardNames[filter] ?? filter)\(range == 1 ? "今天" : "这 \(range) 天")还没有回合", "No \(boardNames[filter] ?? filter) turns \(range == 1 ? "today" : "in \(range) days")"),
                              size: 11, color: secondary), pad, y) }
            y += 18
        } else {
            let maxU = max(jobsSel.map(\.usd).max() ?? 1, 0.01)
            let rows = jobsSel.prefix(jobsOpen ? jobsSel.count : 6)
            // The bars start after the longest name (English names run longer).
            let nameW = min(130, max(66, (rows.map { text($0.name, size: 11).size().width }.max() ?? 0) + 10))
            for c in rows {
                if draw {
                    put(text(c.name, size: 11), pad, y)
                    let br = NSRect(x: pad + nameW, y: y + 5, width: inner - nameW - 150, height: 6)
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
                let label = text(jobsOpen ? L("收起 ▴", "Less ▴") : L("还有 \(jobsSel.count - 6) 种 · \(fmtUSD(rest))  展开 ▾", "\(jobsSel.count - 6) more · \(fmtUSD(rest))  Show ▾"), size: 10, weight: .medium, color: secondary)
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

        // Export: this period's card, for the agent the board shows; the
        // menu (right click) also has the period before.
        section(L("导出报告", "Export"), y, right: L("存到 图片/Dango · 右键可导上一期", "To Pictures/Dango · right-click for earlier"), draw: draw)
        y += 22
        exportRects = []
        let bw = (inner - gap * 3) / 4
        for (i, (kind, label)) in [("day", L("今日日报", "Today")), ("week", L("本周周报", "This week")), ("month", L("本月月报", "This month")), ("year", L("今年年报", "This year"))].enumerated() {
            let r = NSRect(x: pad + CGFloat(i) * (bw + gap), y: y, width: bw, height: 32)
            exportRects.append((kind, r))
            if draw {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
                put(text(label, size: 12, weight: .semibold, color: barToday), r.midX, r.minY + 8, align: 1)
            }
        }
        y += 32 + 16
        if draw {
            var foot = L("按 BLS 各职业中位时薪折算", "Priced at BLS median wages per job")
            if m.weekLeverage != nil { foot += L(" · 本周杠杆 ", " · leverage this week ") + fmtLev(m.weekUSD, m.weekCost) }
            put(text(foot, size: 10, color: secondary), pad, y)
        }
        y += 30
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
        let i = Calendar.current.component(.weekday, from: date) - 1
        return lang == "en" ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][i] : ["日", "一", "二", "三", "四", "五", "六"][i]
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
        } else if let (kind, _) = exportRects.first(where: { $0.1.contains(p) }) {
            (NSApp.delegate as? App)?.makeCard(kind: kind, tool: filter)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        (NSApp.delegate as? App)?.popMenu(event, in: self)
    }
}


/// A character at work, as the pet and the office draw it: the body (job
/// outfit, blinking, breathing), helpers behind it, and when `working` the
/// job's scene (drawActivity) or, for desk jobs, a desk and laptop in front
/// with hands typing. `c` is the character's box; everything else scales with it.
func drawWorker(_ c: NSRect, job: Job?, mood: String, t: Double, blink: Bool, working: Bool, helpers: Int, desk: Bool? = nil, slump: CGFloat = 0, slab: Bool = true,
                flavor: Flavor? = nil) {
    let s = c.width / 80
    let flavor = flavor ?? petFlavor
    // `slump` lowers the body only (asleep at the desk); the desk stays put.
    let bob = CGFloat(sin(t * (working ? 3.0 : 1.6))) * (working ? 1.3 : 0.9) * s - slump
    NSColor.black.withAlphaComponent(0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.midX - 36 * s, y: c.minY - 10 * s, width: 72 * s, height: 10 * s)).fill()
    for i in 0..<min(helpers, 3) {
        let hb = CGFloat(sin(t * 3.2 + Double(i) * 1.7)) * 1.5 * s
        drawCharacter(NSRect(x: c.minX - 42 * s + CGFloat(i) * 15 * s, y: c.minY + 2 * s + hb, width: 34 * s, height: 34 * s),
                      mood: "focused", flavor: flavorNamed(helperFlavors[i % helperFlavors.count]))
    }
    // At work in a scene other than a desk, the hands are on that scene's
    // equipment: the character goes without what it holds.
    let scene = working ? job?.scene ?? "desk" : "desk"
    let look = (job?.look ?? []).filter { scene == "desk" || !handProps.contains($0) }
    drawCharacter(c.offsetBy(dx: 0, dy: bob), mood: mood, look: look, jobColor: job?.color, blink: blink, flavor: flavor)
    if scene != "desk", let job {
        drawActivity(scene, c, job.color, t, look: job.look, skin: flavor.body)
        return
    }
    guard desk ?? working else { return }
    // Desk and laptop in front of the body; when working the laptop is open
    // with lines scrolling up the screen, a blinking cursor, hands typing.
    if slab {
        NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.4, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: c.minX - 10 * s, y: c.minY - 8 * s, width: c.width + 20 * s, height: 9 * s), xRadius: 3 * s, yRadius: 3 * s).fill()
    }
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
    flavor.body.setFill()
    for (k, dx) in [(0, CGFloat(-16)), (1, CGFloat(6))] {
        let up: CGFloat = sin(t * 11 + Double(k) * .pi) > 0 ? 2.5 : 0
        NSBezierPath(ovalIn: NSRect(x: c.midX + dx * s, y: c.minY + (up - 1) * s, width: 11 * s, height: 7 * s)).fill()
    }
}

// MARK: - Scenes

/// Shapes for scenes and props (unflipped views).
func fillRound(_ r: NSRect, _ rad: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
}

func fillOval(_ r: NSRect, _ c: NSColor) {
    c.setFill()
    NSBezierPath(ovalIn: r).fill()
}

func strokeLine(_ a: NSPoint, _ b: NSPoint, _ width: CGFloat, _ c: NSColor) {
    c.setStroke()
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.move(to: a)
    p.line(to: b)
    p.stroke()
}

func fillPoly(_ pts: [NSPoint], _ c: NSColor) {
    c.setFill()
    let p = NSBezierPath()
    for (i, q) in pts.enumerated() { i == 0 ? p.move(to: q) : p.line(to: q) }
    p.close()
    p.fill()
}

/// Draws `body` turned `deg` degrees counter-clockwise around `pivot`.
func rotated(_ pivot: NSPoint, _ deg: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let tr = NSAffineTransform()
    tr.translateX(by: pivot.x, yBy: pivot.y)
    tr.rotate(byDegrees: deg)
    tr.translateX(by: -pivot.x, yBy: -pivot.y)
    tr.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws `body` at `alpha` as one layer, so overlapping parts don't show through.
func faded(_ alpha: CGFloat, _ body: () -> Void) {
    guard alpha < 1, let cg = NSGraphicsContext.current?.cgContext else { return body() }
    cg.saveGState()
    cg.setAlpha(max(0, alpha))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

let wood = NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.4, alpha: 1)
let woodDark = NSColor(calibratedRed: 0.4, green: 0.33, blue: 0.28, alpha: 1)
let pine = NSColor(calibratedRed: 0.85, green: 0.72, blue: 0.5, alpha: 1)
let steel = NSColor(calibratedWhite: 0.62, alpha: 1)
let coal = NSColor(calibratedWhite: 0.12, alpha: 1)
let leafGreen = NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.38, alpha: 1)
let glassTint = NSColor.white.withAlphaComponent(0.55)

/// What each scene is called, on the sign over the stage.
var sceneNames: [String: String] {
    lang == "en"
        ? ["desk": "Desks", "studio": "Studio", "clinic": "Clinic", "gym": "Gym", "kitchen": "Kitchen", "classroom": "Classroom",
           "court": "Court", "lab": "Lab", "workshop": "Workshop", "garden": "Garden", "lounge": "Playroom"]
        : ["desk": "工位", "studio": "工作室", "clinic": "诊室", "gym": "健身房", "kitchen": "后厨", "classroom": "教室",
           "court": "法庭", "lab": "实验室", "workshop": "车间", "garden": "花园", "lounge": "游戏角"]
}

/// A job at work in its scene (`Job.scene`, any but "desk"), around the
/// character in box `c`: the place's equipment, moving. The hands are on
/// the equipment, so the character is drawn without what it holds; studio
/// work depends on that (`look`): a guitar is played, a camera flashes.
func drawActivity(_ scene: String, _ c: NSRect, _ color: NSColor, _ t: Double, look: [String], skin: NSColor = ink) {
    let s = c.width / 80
    /// A point `fx` across and `fy` up the character's box.
    func p(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: c.minX + c.width * fx, y: c.minY + c.height * fy) }
    func hand(_ q: NSPoint) { fillOval(NSRect(x: q.x - 5 * s, y: q.y - 4 * s, width: 10 * s, height: 8 * s), skin) }
    func arm(_ from: NSPoint, _ to: NSPoint) {
        strokeLine(from, to, 7 * s, skin)
        hand(to)
    }
    /// A counter, bench or desk across the front of the body, `top` points up.
    func front(_ fill: NSColor, top: CGFloat, lip: NSColor) {
        fillRound(NSRect(x: c.minX - 12 * s, y: c.minY - 8 * s, width: c.width + 24 * s, height: (top + 8) * s), 3 * s, fill)
        fillRound(NSRect(x: c.minX - 14 * s, y: c.minY + (top - 3) * s, width: c.width + 28 * s, height: 4 * s), 2 * s, lip)
    }
    let shade = color.blended(withFraction: 0.35, of: .black) ?? color
    switch scene {
    case "gym":
        // A barbell pressed overhead, over a rubber mat.
        fillRound(NSRect(x: c.minX - 18 * s, y: c.minY - 10 * s, width: c.width + 36 * s, height: 6 * s), 2 * s, NSColor(calibratedWhite: 0.2, alpha: 1))
        let lift = CGFloat(sin(t * 2.2) + 1) / 2
        let bar = c.minY + c.height * (0.92 + 0.16 * lift)
        arm(p(0.14, 0.55), NSPoint(x: c.minX + c.width * 0.04, y: bar))
        arm(p(0.86, 0.55), NSPoint(x: c.minX + c.width * 0.96, y: bar))
        strokeLine(NSPoint(x: c.minX - 20 * s, y: bar), NSPoint(x: c.maxX + 20 * s, y: bar), 3 * s, steel)
        for x in [c.minX - 17 * s, c.maxX + 9 * s] {
            fillRound(NSRect(x: x, y: bar - 12 * s, width: 8 * s, height: 24 * s), 2 * s, color)
            fillRound(NSRect(x: x < c.midX ? x - 5 * s : x + 8 * s, y: bar - 8 * s, width: 5 * s, height: 16 * s), 1.5 * s, shade)
        }
        if lift > 0.75 {
            // A drop of sweat at the top of the lift.
            fillOval(NSRect(x: c.maxX - 10 * s, y: c.minY + c.height * 0.7 - (lift - 0.75) * 40 * s, width: 4 * s, height: 6 * s),
                     NSColor(calibratedRed: 0.6, green: 0.8, blue: 1, alpha: 0.9))
        }
    case "clinic":
        // A monitor on a stand: the trace runs, the heart beats.
        let mon = NSRect(x: c.maxX + 1 * s, y: c.minY + 26 * s, width: 32 * s, height: 22 * s)
        strokeLine(NSPoint(x: mon.midX, y: c.minY - 7 * s), NSPoint(x: mon.midX, y: mon.minY), 2.5 * s, steel)
        fillRound(NSRect(x: mon.midX - 9 * s, y: c.minY - 9 * s, width: 18 * s, height: 3 * s), 1.5 * s, steel)
        fillRound(mon, 3 * s, coal)
        let inner = mon.insetBy(dx: 3 * s, dy: 4 * s)
        let trace = NSBezierPath()
        trace.lineWidth = 1.3 * s
        trace.lineJoinStyle = .round
        for k in 0...64 {
            let fx = CGFloat(k) / 64
            let ph = fmod(Double(fx) * 1.5 - t * 0.9 + 10, 1.0)
            var v: CGFloat = 0
            if ph > 0.3 && ph < 0.36 { v = 0.18 } else if ph >= 0.4 && ph < 0.43 { v = 1 } else if ph >= 0.43 && ph < 0.46 { v = -0.55 } else if ph > 0.55 && ph < 0.63 { v = 0.25 }
            let q = NSPoint(x: inner.minX + inner.width * fx, y: inner.midY - inner.height * 0.15 + v * inner.height * 0.55)
            k == 0 ? trace.move(to: q) : trace.line(to: q)
        }
        NSColor(calibratedRed: 0.4, green: 0.95, blue: 0.55, alpha: 1).setStroke()
        trace.stroke()
        let beat = CGFloat(max(0, sin(t * 5.6)))
        put(text("♥", size: (7 + 2 * beat) * s, weight: .bold, color: NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.4, alpha: 1)),
            mon.maxX - 6 * s, mon.maxY - (9 + beat) * s, align: 1)
        // A hand checking the readings.
        arm(p(0.86, 0.5), NSPoint(x: mon.minX + 3 * s, y: mon.minY + 4 * s))
    case "kitchen":
        // A stove: the pot steams, the pan tosses.
        front(steel, top: 10, lip: NSColor(calibratedWhite: 0.75, alpha: 1))
        let pot = NSRect(x: c.minX - 4 * s, y: c.minY + 11 * s, width: 28 * s, height: 18 * s)
        fillRound(pot, 4 * s, color)
        fillRound(NSRect(x: pot.minX - 2 * s, y: pot.maxY - 3 * s, width: pot.width + 4 * s, height: 3.5 * s), 1.5 * s, shade)
        for k in 0..<3 {
            let rise = CGFloat(fmod(t * 0.8 + Double(k) * 0.33, 1.0))
            fillOval(NSRect(x: pot.minX + CGFloat(6 + 7 * k) * s + CGFloat(sin(t * 2 + Double(k))) * 2 * s, y: pot.maxY + 2 * s + rise * 20 * s,
                            width: (5 + rise * 4) * s, height: (5 + rise * 4) * s), NSColor.white.withAlphaComponent(0.4 * (1 - rise)))
        }
        let toss = CGFloat(max(0, sin(t * 4.2)))
        let pan = NSRect(x: c.midX + 4 * s, y: c.minY + 15 * s + toss * 3 * s, width: 28 * s, height: 7 * s)
        for k in 0..<3 {
            let f = CGFloat(sin(t * 13 + Double(k) * 2)) * 1.2 * s
            fillOval(NSRect(x: pan.minX + CGFloat(6 + 6 * k) * s, y: c.minY + 10 * s, width: 4 * s, height: 5 * s + f), NSColor(calibratedRed: 1, green: 0.55, blue: 0.2, alpha: 0.9))
        }
        for (k, bit) in [NSColor(calibratedRed: 0.5, green: 0.75, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1),
                         NSColor(calibratedRed: 0.9, green: 0.35, blue: 0.3, alpha: 1)].enumerated() {
            let hop = CGFloat(abs(sin(t * 4.2 + Double(k) * 0.6))) * 14 * s
            fillOval(NSRect(x: pan.minX + CGFloat(6 + 6 * k) * s, y: pan.maxY - 1 * s + hop, width: 5 * s, height: 4 * s), bit)
        }
        fillOval(pan, coal)
        arm(p(0.9, 0.45), NSPoint(x: pan.maxX + 4 * s, y: pan.midY + 2 * s))
        strokeLine(NSPoint(x: pan.maxX - 2 * s, y: pan.midY), NSPoint(x: pan.maxX + 4 * s, y: pan.midY + 2 * s), 2.5 * s, coal)
    case "classroom":
        // A whiteboard: notes written out line by line, then wiped.
        let board = NSRect(x: c.minX - 38 * s, y: c.minY + 14 * s, width: 34 * s, height: 46 * s)
        strokeLine(NSPoint(x: board.minX + 5 * s, y: c.minY - 8 * s), NSPoint(x: board.minX + 8 * s, y: board.minY), 2 * s, steel)
        strokeLine(NSPoint(x: board.maxX - 5 * s, y: c.minY - 8 * s), NSPoint(x: board.maxX - 8 * s, y: board.minY), 2 * s, steel)
        fillRound(board.insetBy(dx: -2 * s, dy: -2 * s), 2 * s, steel)
        fillRound(board, 1.5 * s, NSColor(calibratedWhite: 0.97, alpha: 1))
        let cycle = fmod(t * 0.8, 6.0)
        let n = Int(cycle)
        let widths: [CGFloat] = [0.7, 0.5, 0.8, 0.45, 0.6]
        var tip = NSPoint(x: board.midX, y: board.midY)
        for k in 0..<min(n + 1, 5) {
            let y = board.maxY - CGFloat(7 + k * 8) * s
            let full = (board.width - 8 * s) * widths[k]
            let len = k < n ? full : full * CGFloat(cycle - Double(n))
            strokeLine(NSPoint(x: board.minX + 4 * s, y: y), NSPoint(x: board.minX + 4 * s + len, y: y), 2 * s, k == 0 ? color : ink2)
            if k == n { tip = NSPoint(x: board.minX + 4 * s + len, y: y) }
        }
        arm(p(0.12, 0.5), tip)
    case "court":
        // The bench; the gavel comes down on its block.
        front(wood, top: 16, lip: woodDark)
        let sc = NSPoint(x: c.midX, y: c.minY + 1 * s)
        strokeLine(NSPoint(x: sc.x, y: sc.y - 5 * s), NSPoint(x: sc.x, y: sc.y + 7 * s), 1.2 * s, color)
        strokeLine(NSPoint(x: sc.x - 8 * s, y: sc.y + 6 * s), NSPoint(x: sc.x + 8 * s, y: sc.y + 6 * s), 1.2 * s, color)
        for dx in [-8 * s, 8 * s] {
            strokeLine(NSPoint(x: sc.x + dx, y: sc.y + 6 * s), NSPoint(x: sc.x + dx, y: sc.y + 1 * s), 0.8 * s, color)
            fillOval(NSRect(x: sc.x + dx - 3.5 * s, y: sc.y - 1 * s, width: 7 * s, height: 3 * s), color)
        }
        let block = NSRect(x: c.maxX - 4 * s, y: c.minY + 17 * s, width: 14 * s, height: 5 * s)
        fillRound(block, 1.5 * s, woodDark)
        let beat = fmod(t, 1.8)
        let down = beat > 1.2 && beat < 1.4
        let pivot = p(0.8, 0.45)
        let head = NSPoint(x: block.midX, y: block.maxY + 6 * s)
        rotated(pivot, down ? 0 : 30 + 6 * CGFloat(sin(t * 3))) {
            strokeLine(pivot, head, 3 * s, pine)
            fillRound(NSRect(x: head.x - 4.5 * s, y: head.y - 6 * s, width: 9 * s, height: 12 * s), 2 * s, woodDark)
        }
        hand(pivot)
        if down {
            for side: CGFloat in [-1, 1] {
                let x0 = side < 0 ? block.minX - 2 * s : block.maxX + 2 * s
                strokeLine(NSPoint(x: x0, y: block.maxY + 2 * s), NSPoint(x: x0 + side * 5 * s, y: block.maxY + 6 * s), 1.4 * s, color)
                strokeLine(NSPoint(x: x0, y: block.midY), NSPoint(x: x0 + side * 6 * s, y: block.midY), 1.4 * s, color)
            }
        }
    case "lab":
        // A bench: a flask bubbling over a burner, a tube swirled.
        front(NSColor(calibratedWhite: 0.85, alpha: 1), top: 10, lip: steel)
        let x0 = c.minX + 2 * s
        fillRound(NSRect(x: x0 + 6 * s, y: c.minY + 10 * s, width: 8 * s, height: 6 * s), 1 * s, coal)
        fillOval(NSRect(x: x0 + 7.5 * s, y: c.minY + 15 * s, width: 5 * s, height: (6 + CGFloat(sin(t * 15))) * s), NSColor(calibratedRed: 0.35, green: 0.6, blue: 1, alpha: 0.9))
        let base = c.minY + 20 * s
        fillPoly([NSPoint(x: x0, y: base), NSPoint(x: x0 + 20 * s, y: base), NSPoint(x: x0 + 13 * s, y: base + 14 * s), NSPoint(x: x0 + 13 * s, y: base + 22 * s),
                  NSPoint(x: x0 + 7 * s, y: base + 22 * s), NSPoint(x: x0 + 7 * s, y: base + 14 * s)], glassTint)
        fillPoly([NSPoint(x: x0, y: base), NSPoint(x: x0 + 20 * s, y: base), NSPoint(x: x0 + 15.5 * s, y: base + 9 * s), NSPoint(x: x0 + 4.5 * s, y: base + 9 * s)], color)
        for k in 0..<4 {
            let rise = CGFloat(fmod(t * 0.9 + Double(k) * 0.25, 1.0))
            let r = (1.5 + CGFloat(k % 2)) * s
            fillOval(NSRect(x: x0 + 10 * s - r + CGFloat(sin(t * 3 + Double(k))) * 2 * s, y: base + 4 * s + rise * 30 * s, width: 2 * r, height: 2 * r),
                     color.withAlphaComponent(0.85 * (1 - rise)))
        }
        let rx = c.maxX - 12 * s
        fillRound(NSRect(x: rx - 2 * s, y: c.minY + 10 * s, width: 22 * s, height: 4 * s), 1 * s, steel)
        for (k, tint) in [NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.75, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1)].enumerated() {
            let tube = NSRect(x: rx + CGFloat(k) * 9 * s, y: c.minY + 12 * s, width: 5 * s, height: 16 * s)
            fillRound(tube, 2.5 * s, glassTint)
            fillRound(NSRect(x: tube.minX, y: tube.minY, width: tube.width, height: 8 * s), 2.5 * s, tint)
        }
        let held = p(1.06, 0.6)
        strokeLine(p(0.86, 0.5), held, 7 * s, skin)
        rotated(held, CGFloat(sin(t * 4)) * 15) {
            fillRound(NSRect(x: held.x - 2.5 * s, y: held.y - 2 * s, width: 5 * s, height: 17 * s), 2.5 * s, glassTint)
            fillRound(NSRect(x: held.x - 2.5 * s, y: held.y - 2 * s, width: 5 * s, height: 8 * s), 2.5 * s, color)
        }
        hand(held)
    case "workshop":
        // A workbench: the hammer comes down on a board and sparks fly; a gear turns.
        front(wood, top: 12, lip: woodDark)
        fillRound(NSRect(x: c.midX - 4 * s, y: c.minY + 12 * s, width: 36 * s, height: 5 * s), 1 * s, pine)
        let g = NSPoint(x: c.minX - 2 * s, y: c.minY + 24 * s)
        strokeLine(NSPoint(x: g.x, y: c.minY + 12 * s), g, 2.5 * s, steel)
        rotated(g, CGFloat(fmod(t * 60, 360))) {
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                fillRound(NSRect(x: g.x + cos(a) * 8 * s - 2.5 * s, y: g.y + sin(a) * 8 * s - 2.5 * s, width: 5 * s, height: 5 * s), 1 * s, steel)
            }
            fillOval(NSRect(x: g.x - 8 * s, y: g.y - 8 * s, width: 16 * s, height: 16 * s), steel)
            fillOval(NSRect(x: g.x - 3 * s, y: g.y - 3 * s, width: 6 * s, height: 6 * s), coal)
        }
        let beat = fmod(t * 1.3, 1.0)
        let angle: CGFloat = beat < 0.55 ? 45 * CGFloat(beat / 0.55) : beat < 0.65 ? 45 * CGFloat(1 - (beat - 0.55) / 0.1) : 0
        let pivot = p(0.84, 0.5)
        let head = NSPoint(x: c.maxX + 8 * s, y: c.minY + 23 * s)
        rotated(pivot, angle) {
            strokeLine(pivot, head, 3 * s, pine)
            fillRound(NSRect(x: head.x - 5 * s, y: head.y - 6 * s, width: 10 * s, height: 12 * s), 2 * s, steel)
        }
        hand(pivot)
        if beat >= 0.65 && beat < 0.85 {
            let q = CGFloat((beat - 0.65) / 0.2)
            for (dx, dy) in [(-1.0, 0.6), (-0.4, 1.0), (0.5, 1.0), (1.0, 0.5)] {
                fillOval(NSRect(x: head.x + CGFloat(dx) * q * 14 * s - 1.5 * s, y: c.minY + 17 * s + CGFloat(dy) * q * 12 * s, width: 3 * s, height: 3 * s),
                         NSColor(calibratedRed: 1, green: 0.85, blue: 0.35, alpha: 1 - q))
            }
        }
    case "garden":
        // A planter: sprouts sway; the can tips and waters them.
        fillRound(NSRect(x: c.minX - 14 * s, y: c.minY - 8 * s, width: c.width + 40 * s, height: 16 * s), 2 * s, NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.28, alpha: 1))
        fillRound(NSRect(x: c.minX - 12 * s, y: c.minY + 4 * s, width: c.width + 36 * s, height: 4 * s), 1.5 * s, NSColor(calibratedRed: 0.32, green: 0.22, blue: 0.16, alpha: 1))
        for (k, fx) in [CGFloat(-0.05), 0.45, 1.12].enumerated() {
            let base = NSPoint(x: c.minX + c.width * fx, y: c.minY + 7 * s)
            let sway = CGFloat(sin(t * 1.8 + Double(k))) * 2 * s
            let top = NSPoint(x: base.x + sway, y: base.y + (10 + CGFloat(k % 2) * 6) * s)
            strokeLine(base, top, 1.8 * s, leafGreen)
            for side: CGFloat in [-1, 1] {
                fillOval(NSRect(x: top.x + side * 4 * s - 3 * s, y: top.y - 5 * s, width: 6 * s, height: 4 * s), leafGreen)
            }
            if k == 1 { fillOval(NSRect(x: top.x - 3.5 * s, y: top.y - 1 * s, width: 7 * s, height: 7 * s), color) }
        }
        let tilt = -12 - 22 * CGFloat(max(0, sin(t * 1.4)))
        let hold = p(0.92, 0.5)
        strokeLine(p(0.8, 0.45), hold, 7 * s, skin)
        rotated(hold, tilt) {
            fillRound(NSRect(x: hold.x, y: hold.y - 6 * s, width: 16 * s, height: 12 * s), 2 * s, color)
            fillPoly([NSPoint(x: hold.x + 15 * s, y: hold.y + 2 * s), NSPoint(x: hold.x + 26 * s, y: hold.y + 8 * s),
                      NSPoint(x: hold.x + 26 * s, y: hold.y + 5 * s), NSPoint(x: hold.x + 15 * s, y: hold.y - 2 * s)], color)
        }
        hand(hold)
        if tilt < -26 {
            let a = tilt * .pi / 180
            let tip = NSPoint(x: hold.x + 26 * s * cos(a) - 6.5 * s * sin(a), y: hold.y + 26 * s * sin(a) + 6.5 * s * cos(a))
            for k in 0..<3 {
                let fall = CGFloat(fmod(t * 2.5 + Double(k) * 0.33, 1.0)) * max(0, tip.y - c.minY - 8 * s)
                fillOval(NSRect(x: tip.x - 1 * s + CGFloat(k) * 1.5 * s, y: tip.y - fall, width: 2.2 * s, height: 3.2 * s), NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 0.9))
            }
        }
    case "lounge":
        // A play mat: blocks stacked one by one, then a fresh start; a teddy watching.
        fillRound(NSRect(x: c.minX - 18 * s, y: c.minY - 10 * s, width: c.width + 36 * s, height: 7 * s), 3 * s, color.withAlphaComponent(0.5))
        let tints = [color, NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.4, green: 0.75, blue: 0.75, alpha: 1),
                     NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.6, alpha: 1), NSColor(calibratedRed: 0.6, green: 0.55, blue: 0.9, alpha: 1)]
        let n = Int(fmod(t * 0.9, 6.0))
        let bx = c.maxX + 3 * s
        for k in 0..<min(n, 5) {
            fillRound(NSRect(x: bx + (k % 2 == 0 ? 0 : 1.5 * s), y: c.minY - 3 * s + CGFloat(k) * 9 * s, width: 11 * s, height: 9 * s), 1.5 * s, tints[k])
        }
        if n < 5 {
            let next = NSPoint(x: bx + 5.5 * s, y: c.minY + CGFloat(n) * 9 * s + 8 * s)
            strokeLine(p(0.86, 0.45), next, 7 * s, skin)
            fillRound(NSRect(x: next.x - 5.5 * s, y: next.y - 2 * s, width: 11 * s, height: 9 * s), 1.5 * s, tints[n])
            hand(next)
        }
        let ted = NSPoint(x: c.minX - 10 * s, y: c.minY - 2 * s)
        fillOval(NSRect(x: ted.x - 7 * s, y: ted.y, width: 14 * s, height: 13 * s), pine)
        fillOval(NSRect(x: ted.x - 5.5 * s, y: ted.y + 11 * s, width: 11 * s, height: 10 * s), pine)
        for dx: CGFloat in [-5, 3] { fillOval(NSRect(x: ted.x + dx * s, y: ted.y + 18 * s, width: 3.5 * s, height: 3.5 * s), pine) }
        for dx: CGFloat in [-2.5, 1] { fillOval(NSRect(x: ted.x + dx * s, y: ted.y + 15 * s, width: 1.6 * s, height: 1.6 * s), coal) }
    case "studio":
        if look.contains("guitar") {
            // Strumming; notes float up.
            let body = NSRect(x: c.midX - 2 * s, y: c.minY + 2 * s, width: 26 * s, height: 22 * s)
            let fret = NSPoint(x: c.minX - 8 * s, y: c.minY + 34 * s)
            strokeLine(NSPoint(x: body.midX, y: body.midY), fret, 4 * s, woodDark)
            fillOval(body, color)
            fillOval(NSRect(x: body.midX - 4 * s, y: body.midY - 4 * s, width: 8 * s, height: 8 * s), coal)
            arm(p(0.14, 0.5), fret)
            arm(p(0.86, 0.45), NSPoint(x: body.midX + 3 * s, y: body.midY + CGFloat(sin(t * 9)) * 4 * s))
            for k in 0..<3 {
                let rise = CGFloat(fmod(t * 0.5 + Double(k) / 3, 1.0))
                put(text(k % 2 == 0 ? "♪" : "♫", size: 11 * s, weight: .bold, color: color.withAlphaComponent(1 - rise)),
                    c.maxX + (4 + CGFloat(k) * 6) * s + CGFloat(sin(t * 2 + Double(k))) * 3 * s, c.minY + (30 + rise * 40) * s, align: 1)
            }
        } else if look.contains("camera") {
            // A camera on a tripod; the flash goes off.
            let cam = NSRect(x: c.maxX + 2 * s, y: c.minY + 30 * s, width: 22 * s, height: 15 * s)
            for dx: CGFloat in [-8, 0, 8] { strokeLine(NSPoint(x: cam.midX, y: cam.minY), NSPoint(x: cam.midX + dx * s, y: c.minY - 8 * s), 1.5 * s, steel) }
            fillRound(cam, 2.5 * s, coal)
            fillRound(NSRect(x: cam.minX + 3 * s, y: cam.maxY - 1 * s, width: 7 * s, height: 4 * s), 1 * s, coal)
            fillOval(NSRect(x: cam.midX - 5 * s, y: cam.midY - 5 * s, width: 10 * s, height: 10 * s), color)
            fillOval(NSRect(x: cam.midX - 2.5 * s, y: cam.midY - 2.5 * s, width: 5 * s, height: 5 * s), coal)
            arm(p(0.86, 0.5), NSPoint(x: cam.minX + 1 * s, y: cam.midY))
            let fl = fmod(t, 2.4)
            if fl < 0.2 {
                let a = CGFloat(1 - fl / 0.2)
                let q = NSPoint(x: cam.minX + 6 * s, y: cam.maxY + 4 * s)
                fillOval(NSRect(x: q.x - 9 * s, y: q.y - 9 * s, width: 18 * s, height: 18 * s), NSColor.white.withAlphaComponent(0.5 * a))
                for k in 0..<8 {
                    let ang = CGFloat(k) * .pi / 4
                    strokeLine(NSPoint(x: q.x + cos(ang) * 6 * s, y: q.y + sin(ang) * 6 * s), NSPoint(x: q.x + cos(ang) * 13 * s, y: q.y + sin(ang) * 13 * s), 1.4 * s, NSColor.white.withAlphaComponent(a))
                }
            }
        } else if look.contains("headphones") {
            // Editing: clips on two tracks, the playhead running over them.
            let desk = NSRect(x: c.minX - 14 * s, y: c.minY - 8 * s, width: c.width + 28 * s, height: 24 * s)
            fillRound(desk, 3 * s, coal)
            let lane = desk.insetBy(dx: 4 * s, dy: 4 * s)
            for (row, clips) in [[(0.0, 0.3), (0.34, 0.25), (0.62, 0.36)], [(0.08, 0.4), (0.52, 0.3)]].enumerated() {
                for (k, (x, w)) in clips.enumerated() {
                    let tint = (row + k) % 2 == 0 ? color : NSColor(calibratedRed: 0.55, green: 0.7, blue: 0.9, alpha: 1)
                    fillRound(NSRect(x: lane.minX + lane.width * CGFloat(x), y: lane.maxY - CGFloat(row + 1) * 7 * s, width: lane.width * CGFloat(w), height: 5.5 * s), 1 * s, tint)
                }
            }
            let ph = lane.minX + lane.width * CGFloat(fmod(t * 0.25, 1.0))
            strokeLine(NSPoint(x: ph, y: lane.minY), NSPoint(x: ph, y: lane.maxY + 1 * s), 1.2 * s, .white)
            hand(NSPoint(x: c.minX + 16 * s, y: desk.maxY + 1 * s))
            hand(NSPoint(x: c.maxX - 16 * s + CGFloat(sin(t * 2)) * 3 * s, y: desk.maxY + 1 * s))
        } else if look.contains("scissors") || look.contains("tape") {
            // A dress form: the cloth pinned and cut.
            let fx = c.maxX + 12 * s
            strokeLine(NSPoint(x: fx, y: c.minY - 8 * s), NSPoint(x: fx, y: c.minY + 14 * s), 2 * s, woodDark)
            fillOval(NSRect(x: fx - 8 * s, y: c.minY - 10 * s, width: 16 * s, height: 4 * s), woodDark)
            fillRound(NSRect(x: fx - 10 * s, y: c.minY + 14 * s, width: 20 * s, height: 26 * s), 8 * s, color)
            fillOval(NSRect(x: fx - 3 * s, y: c.minY + 38 * s, width: 6 * s, height: 5 * s), pine)
            let snip = 18 * CGFloat(abs(sin(t * 5)))
            let q = NSPoint(x: fx - 12 * s, y: c.minY + 24 * s)
            for dir: CGFloat in [-1, 1] {
                rotated(q, dir * snip) { strokeLine(NSPoint(x: q.x - 6 * s, y: q.y), NSPoint(x: q.x + 8 * s, y: q.y), 1.8 * s, steel) }
            }
            arm(p(0.86, 0.45), NSPoint(x: q.x - 6 * s, y: q.y - 2 * s))
        } else if look.contains("pencil") || look.contains("bubble") {
            // Writing: a page fills line by line; translating, the second of two.
            front(wood, top: 10, lip: woodDark)
            let two = look.contains("bubble")
            let page = NSRect(x: two ? c.midX - 2 * s : c.midX - 15 * s, y: c.minY + 10 * s, width: 28 * s, height: 26 * s)
            if two {
                let src = page.offsetBy(dx: -31 * s, dy: 0)
                fillRound(src, 1.5 * s, NSColor(calibratedWhite: 0.88, alpha: 1))
                for k in 0..<4 { strokeLine(NSPoint(x: src.minX + 4 * s, y: src.maxY - CGFloat(6 + 5 * k) * s), NSPoint(x: src.maxX - 5 * s, y: src.maxY - CGFloat(6 + 5 * k) * s), 1.5 * s, ink2) }
            }
            fillRound(page, 1.5 * s, NSColor(calibratedWhite: 0.97, alpha: 1))
            let cycle = fmod(t * 0.9, 5.0)
            let n = Int(cycle)
            var tip = NSPoint(x: page.maxX - 4 * s, y: page.minY + 4 * s)
            for k in 0..<min(n + 1, 4) {
                let y = page.maxY - CGFloat(6 + 5 * k) * s
                let len = (page.width - 9 * s) * (k < n ? 1 : CGFloat(cycle - Double(n)))
                strokeLine(NSPoint(x: page.minX + 4 * s, y: y), NSPoint(x: page.minX + 4 * s + len, y: y), 1.5 * s, k == 0 ? color : ink2)
                if k == n { tip = NSPoint(x: page.minX + 4 * s + len, y: y) }
            }
            strokeLine(tip, NSPoint(x: tip.x + 5 * s, y: tip.y + 9 * s), 2.5 * s, color)
            arm(p(0.86, 0.45), NSPoint(x: tip.x + 4 * s, y: tip.y + 6 * s))
        } else {
            // An easel: the canvas fills, stroke by stroke.
            let canvas = NSRect(x: c.maxX - 2 * s, y: c.minY + 18 * s, width: 28 * s, height: 26 * s)
            for (a, b) in [(canvas.minX + 4 * s, canvas.minX - 2 * s), (canvas.maxX - 4 * s, canvas.maxX + 2 * s), (canvas.midX, canvas.midX + 4 * s)] {
                strokeLine(NSPoint(x: a, y: canvas.maxY + 4 * s), NSPoint(x: b, y: c.minY - 8 * s), 2 * s, wood)
            }
            fillRound(canvas, 1.5 * s, NSColor(calibratedWhite: 0.97, alpha: 1))
            let strokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.15, 0.25, 0.55, 0.3), (0.2, 0.55, 0.7, 0.7), (0.5, 0.2, 0.85, 0.45), (0.1, 0.8, 0.45, 0.85), (0.6, 0.65, 0.85, 0.85)]
            let tints = [color, NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.3, alpha: 1), NSColor(calibratedRed: 0.4, green: 0.7, blue: 0.85, alpha: 1), shade, NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.45, alpha: 1)]
            let cycle = fmod(t * 0.9, 6.0)
            let n = Int(cycle)
            var tip = NSPoint(x: canvas.midX, y: canvas.midY)
            for k in 0..<min(n + 1, 5) {
                let (x1, y1, x2, y2) = strokes[k]
                let f = k < n ? 1 : CGFloat(cycle - Double(n))
                let a = NSPoint(x: canvas.minX + canvas.width * x1, y: canvas.minY + canvas.height * y1)
                let b = NSPoint(x: a.x + (canvas.width * x2 - canvas.width * x1) * f, y: a.y + (canvas.height * y2 - canvas.height * y1) * f)
                strokeLine(a, b, 3 * s, tints[k])
                if k == n { tip = b }
            }
            strokeLine(tip, NSPoint(x: tip.x - 6 * s, y: tip.y - 7 * s), 2 * s, pine)
            arm(p(0.86, 0.45), NSPoint(x: tip.x - 6 * s, y: tip.y - 7 * s))
        }
    default:
        break
    }
}

/// The back wall of a stage for a scene, in `r`; the top 20 points are left
/// for the sign. Drawn behind whoever works there.
func drawBackdrop(_ scene: String, _ r: NSRect, _ color: NSColor) {
    fillRound(r, 6, color.withAlphaComponent(0.07))
    let top = r.maxY - 22
    let wide = r.width > 110
    switch scene {
    case "desk":
        // A pinboard of notes; a clock with the time.
        let bw = min(70, r.width - 24)
        let board = NSRect(x: r.midX - bw / 2, y: top - 30, width: bw, height: 28)
        fillRound(board, 2, NSColor(calibratedRed: 0.6, green: 0.46, blue: 0.33, alpha: 0.85))
        let notes = [color, NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.4, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.65, alpha: 1),
                     NSColor(calibratedRed: 0.55, green: 0.8, blue: 0.75, alpha: 1)]
        for (k, n) in notes.enumerated() {
            let q = NSRect(x: board.minX + 4 + CGFloat(k) * (board.width - 8) / 4, y: board.minY + (k % 2 == 0 ? 5 : 12), width: 11, height: 11)
            rotated(NSPoint(x: q.midX, y: q.midY), CGFloat([-6, 4, -3, 7][k])) { fillRound(q, 1, n) }
        }
        if wide {
            let cc = NSPoint(x: r.minX + 18, y: top - 14)
            fillOval(NSRect(x: cc.x - 9, y: cc.y - 9, width: 18, height: 18), NSColor(calibratedWhite: 0.9, alpha: 1))
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let mins = CGFloat(now.minute ?? 0)
            let hA = (CGFloat((now.hour ?? 0) % 12) + mins / 60) * .pi / 6, mA = mins * .pi / 30
            strokeLine(cc, NSPoint(x: cc.x + sin(hA) * 4.5, y: cc.y + cos(hA) * 4.5), 1.6, coal)
            strokeLine(cc, NSPoint(x: cc.x + sin(mA) * 7, y: cc.y + cos(mA) * 7), 1, coal)
        }
    case "studio":
        // A paper backdrop sweeping down to the floor; a softbox.
        let sweep = NSRect(x: r.minX + 10, y: r.minY, width: r.width - 20, height: top - r.minY - 2)
        NSGradient(starting: NSColor(calibratedWhite: 0.25, alpha: 1), ending: NSColor(calibratedWhite: 0.34, alpha: 1))?
            .draw(in: NSBezierPath(roundedRect: sweep, xRadius: 4, yRadius: 4), angle: 90)
        if wide {
            let box = NSRect(x: r.maxX - 30, y: top - 24, width: 20, height: 16)
            strokeLine(NSPoint(x: box.midX, y: r.minY + 2), NSPoint(x: box.midX, y: box.minY), 1.5, steel)
            fillPoly([NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.minX - 26, y: r.minY + 4), NSPoint(x: box.maxX - 30, y: r.minY + 4)], NSColor.white.withAlphaComponent(0.04))
            fillRound(box, 2, NSColor(calibratedWhite: 0.95, alpha: 0.9))
        }
    case "clinic":
        // A cross on the wall, a curtain, an eye chart.
        let cc = NSPoint(x: r.midX, y: top - 14)
        let red = NSColor(calibratedRed: 0.86, green: 0.27, blue: 0.27, alpha: 1)
        fillOval(NSRect(x: cc.x - 11, y: cc.y - 11, width: 22, height: 22), NSColor(calibratedWhite: 0.94, alpha: 1))
        fillRound(NSRect(x: cc.x - 7, y: cc.y - 2.5, width: 14, height: 5), 1, red)
        fillRound(NSRect(x: cc.x - 2.5, y: cc.y - 7, width: 5, height: 14), 1, red)
        let cw = min(24, r.width * 0.2)
        strokeLine(NSPoint(x: r.minX + 4, y: top + 2), NSPoint(x: r.minX + 8 + cw, y: top + 2), 1.5, steel)
        for k in 0..<4 {
            fillRound(NSRect(x: r.minX + 6 + CGFloat(k) * cw / 4, y: r.minY + 2, width: cw / 4 - 1, height: top - r.minY),
                      2, NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.82, alpha: k % 2 == 0 ? 0.55 : 0.4))
        }
        if wide {
            let chart = NSRect(x: r.maxX - 30, y: top - 38, width: 20, height: 30)
            fillRound(chart, 1.5, NSColor(calibratedWhite: 0.94, alpha: 1))
            for (k, size) in [8.0, 6.0, 4.5, 3.5].enumerated() {
                put(text(["E", "Ш", "E", "Ш"][k], size: CGFloat(size), weight: .bold, color: coal), chart.midX, chart.maxY - CGFloat([10, 17, 23, 28][k]), align: 1)
            }
        }
    case "gym":
        // A wall mirror; a rack of dumbbells.
        let mirror = NSRect(x: r.minX + 12, y: top - 40, width: r.width - 24, height: 38)
        NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.7, alpha: 0.28), ending: NSColor(calibratedRed: 0.75, green: 0.8, blue: 0.86, alpha: 0.18))?
            .draw(in: NSBezierPath(roundedRect: mirror, xRadius: 3, yRadius: 3), angle: 70)
        for dx: CGFloat in [0.2, 0.32] {
            strokeLine(NSPoint(x: mirror.minX + mirror.width * dx, y: mirror.minY + 4), NSPoint(x: mirror.minX + mirror.width * dx + 16, y: mirror.maxY - 4), 2, NSColor.white.withAlphaComponent(0.12))
        }
        if wide {
            let rack = NSRect(x: r.minX + 6, y: r.minY + 16, width: 22, height: 3)
            fillRound(rack, 1, steel)
            strokeLine(NSPoint(x: rack.minX + 2, y: r.minY + 2), NSPoint(x: rack.minX + 2, y: rack.maxY), 2, steel)
            strokeLine(NSPoint(x: rack.maxX - 2, y: r.minY + 2), NSPoint(x: rack.maxX - 2, y: rack.maxY), 2, steel)
            for k in 0..<2 {
                let y = rack.maxY + 1
                let x = rack.minX + 2 + CGFloat(k) * 10
                strokeLine(NSPoint(x: x, y: y + 3), NSPoint(x: x + 8, y: y + 3), 2, coal)
                fillRound(NSRect(x: x - 1, y: y, width: 3, height: 6), 1, color)
                fillRound(NSRect(x: x + 6, y: y, width: 3, height: 6), 1, color)
            }
        }
    case "kitchen":
        // Tiles; a range hood; utensils on a rail.
        let tiles = NSRect(x: r.minX + 8, y: r.minY + 2, width: r.width - 16, height: top - r.minY - 34)
        fillRound(tiles, 2, NSColor.white.withAlphaComponent(0.05))
        for x in stride(from: tiles.minX + 10, to: tiles.maxX, by: 10) { strokeLine(NSPoint(x: x, y: tiles.minY), NSPoint(x: x, y: tiles.maxY), 0.6, NSColor.white.withAlphaComponent(0.07)) }
        for y in stride(from: tiles.minY + 10, to: tiles.maxY, by: 10) { strokeLine(NSPoint(x: tiles.minX, y: y), NSPoint(x: tiles.maxX, y: y), 0.6, NSColor.white.withAlphaComponent(0.07)) }
        fillRound(NSRect(x: r.midX - 7, y: top - 8, width: 14, height: 10), 1, NSColor(calibratedWhite: 0.45, alpha: 1))
        fillPoly([NSPoint(x: r.midX - 28, y: top - 30), NSPoint(x: r.midX + 28, y: top - 30), NSPoint(x: r.midX + 12, y: top - 8), NSPoint(x: r.midX - 12, y: top - 8)], NSColor(calibratedWhite: 0.52, alpha: 1))
        if wide {
            let rail = NSPoint(x: r.minX + 8, y: top - 6)
            strokeLine(rail, NSPoint(x: rail.x + 24, y: rail.y), 1.5, steel)
            for (k, x) in [rail.x + 4, rail.x + 12, rail.x + 20].enumerated() {
                strokeLine(NSPoint(x: x, y: rail.y), NSPoint(x: x, y: rail.y - 16), 1.2, steel)
                if k == 1 { fillRound(NSRect(x: x - 3, y: rail.y - 24, width: 6, height: 8), 1, steel) } else { fillOval(NSRect(x: x - 3.5, y: rail.y - 22, width: 7, height: 6), steel) }
            }
        }
    case "classroom":
        // Letters along the top; a bookshelf.
        let letters = ["A", "B", "C", "1", "2", "3"]
        let tints = [color, NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.45, green: 0.75, blue: 0.75, alpha: 1)]
        let n = wide ? letters.count : 3
        for (k, l) in letters.prefix(n).enumerated() {
            put(text(l, size: 10, weight: .heavy, color: tints[k % 3].withAlphaComponent(0.8)), r.minX + (r.width - 16) * (CGFloat(k) + 0.5) / CGFloat(n) + 8, top - 14, align: 1)
        }
        if wide {
            let shelf = NSRect(x: r.maxX - 34, y: r.minY + 2, width: 26, height: 44)
            fillRound(shelf, 2, woodDark)
            let spines = [color, NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.4, alpha: 1), NSColor(calibratedRed: 0.45, green: 0.6, blue: 0.85, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.35, alpha: 1)]
            for row in 0..<2 {
                for k in 0..<4 {
                    fillRound(NSRect(x: shelf.minX + 3 + CGFloat(k) * 5, y: shelf.minY + 4 + CGFloat(row) * 20, width: 4, height: CGFloat(14 - (k + row) % 3 * 2)), 0.5, spines[(k + row) % 4])
                }
            }
        }
    case "court":
        // Panelling; a seal with the scales; a flag.
        fillRound(NSRect(x: r.minX + 4, y: r.minY, width: r.width - 8, height: top - r.minY), 3, wood.withAlphaComponent(0.25))
        for x in stride(from: r.minX + 14, to: r.maxX - 8, by: 14) { strokeLine(NSPoint(x: x, y: r.minY + 2), NSPoint(x: x, y: top - 2), 1, woodDark.withAlphaComponent(0.5)) }
        let cc = NSPoint(x: r.midX, y: top - 16)
        fillOval(NSRect(x: cc.x - 13, y: cc.y - 13, width: 26, height: 26), color.withAlphaComponent(0.55))
        strokeLine(NSPoint(x: cc.x, y: cc.y - 8), NSPoint(x: cc.x, y: cc.y + 7), 1.3, paper)
        strokeLine(NSPoint(x: cc.x - 8, y: cc.y + 5), NSPoint(x: cc.x + 8, y: cc.y + 5), 1.3, paper)
        for dx: CGFloat in [-8, 8] { fillOval(NSRect(x: cc.x + dx - 3.5, y: cc.y - 2, width: 7, height: 3), paper) }
        if wide {
            let pole = NSPoint(x: r.maxX - 16, y: r.minY + 2)
            strokeLine(pole, NSPoint(x: pole.x, y: top - 4), 1.5, steel)
            fillRound(NSRect(x: pole.x - 15, y: top - 22, width: 14, height: 18), 1, color.withAlphaComponent(0.8))
        }
    case "lab":
        // A shelf of bottles; a hazard sign.
        let shelfY = top - 26
        strokeLine(NSPoint(x: r.minX + 10, y: shelfY), NSPoint(x: r.maxX - 10, y: shelfY), 2, woodDark)
        let tints = [color, NSColor(calibratedRed: 0.4, green: 0.75, blue: 0.7, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.3, alpha: 1), NSColor(calibratedRed: 0.75, green: 0.5, blue: 0.85, alpha: 1)]
        let count = Int((r.width - 24) / 14)
        for k in 0..<count {
            let x = r.minX + 14 + CGFloat(k) * 14
            let h = CGFloat([14, 10, 17, 12][k % 4])
            fillRound(NSRect(x: x, y: shelfY + 1, width: 8, height: h), 2, glassTint.withAlphaComponent(0.35))
            fillRound(NSRect(x: x, y: shelfY + 1, width: 8, height: h * 0.55), 2, tints[k % 4].withAlphaComponent(0.85))
        }
        if wide {
            let q = NSPoint(x: r.minX + 18, y: r.minY + 30)
            fillPoly([NSPoint(x: q.x - 9, y: q.y - 7), NSPoint(x: q.x + 9, y: q.y - 7), NSPoint(x: q.x, y: q.y + 9)], NSColor(calibratedRed: 0.98, green: 0.8, blue: 0.2, alpha: 0.9))
            put(text("!", size: 9, weight: .heavy, color: coal), q.x, q.y - 7, align: 1)
        }
    case "workshop":
        // A pegboard with tools; a toolbox.
        let bw = min(84, r.width - 20)
        let board = NSRect(x: r.midX - bw / 2, y: top - 40, width: bw, height: 38)
        fillRound(board, 2, pine.withAlphaComponent(0.35))
        for x in stride(from: board.minX + 6, to: board.maxX, by: 8) {
            for y in stride(from: board.minY + 5, to: board.maxY, by: 8) { fillOval(NSRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6), coal.withAlphaComponent(0.5)) }
        }
        let tool = coal.withAlphaComponent(0.85)
        let x0 = board.minX + 8
        strokeLine(NSPoint(x: x0 + 4, y: board.minY + 6), NSPoint(x: x0 + 4, y: board.maxY - 10), 2.5, tool)
        fillRound(NSRect(x: x0 - 2, y: board.maxY - 12, width: 12, height: 6), 1, tool)
        strokeLine(NSPoint(x: x0 + 22, y: board.minY + 6), NSPoint(x: x0 + 22, y: board.maxY - 12), 2.5, tool)
        fillOval(NSRect(x: x0 + 17, y: board.maxY - 14, width: 10, height: 10), tool)
        fillOval(NSRect(x: x0 + 20, y: board.maxY - 11, width: 4, height: 4), pine.withAlphaComponent(0.35))
        if bw > 60 {
            fillPoly([NSPoint(x: x0 + 36, y: board.minY + 8), NSPoint(x: x0 + 62, y: board.minY + 12), NSPoint(x: x0 + 62, y: board.minY + 22), NSPoint(x: x0 + 36, y: board.minY + 18)], tool)
            fillRound(NSRect(x: x0 + 60, y: board.minY + 9, width: 8, height: 14), 2, color)
        }
        if wide {
            let box = NSRect(x: r.minX + 6, y: r.minY + 2, width: 26, height: 14)
            fillRound(box, 2, NSColor(calibratedRed: 0.8, green: 0.3, blue: 0.28, alpha: 1))
            fillRound(NSRect(x: box.midX - 6, y: box.maxY, width: 12, height: 3), 1, coal)
        }
    case "garden":
        // A greenhouse window with the sun; vines; a fence.
        let win = NSRect(x: r.midX - min(30, r.width * 0.3), y: top - 40, width: min(60, r.width * 0.6), height: 38)
        let path = NSBezierPath(roundedRect: win, xRadius: win.width / 2.4, yRadius: win.width / 2.4)
        NSGradient(starting: NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.95, alpha: 0.75), ending: NSColor(calibratedRed: 0.85, green: 0.93, blue: 0.98, alpha: 0.75))?.draw(in: path, angle: -90)
        fillOval(NSRect(x: win.maxX - 22, y: win.maxY - 20, width: 11, height: 11), NSColor(calibratedRed: 1, green: 0.88, blue: 0.5, alpha: 1))
        strokeLine(NSPoint(x: win.midX, y: win.minY), NSPoint(x: win.midX, y: win.maxY), 1.5, NSColor(calibratedWhite: 0.85, alpha: 0.6))
        for fx: CGFloat in [0.12, 0.88] {
            let x = r.minX + r.width * fx
            for k in 0..<4 { fillOval(NSRect(x: x - 3 + CGFloat(k % 2) * 3, y: top - 6 - CGFloat(k) * 8, width: 6, height: 5), leafGreen.withAlphaComponent(0.9)) }
        }
        for x in stride(from: r.minX + 8, to: r.maxX - 6, by: 10) {
            fillPoly([NSPoint(x: x, y: r.minY), NSPoint(x: x + 6, y: r.minY), NSPoint(x: x + 6, y: r.minY + 22), NSPoint(x: x + 3, y: r.minY + 26), NSPoint(x: x, y: r.minY + 22)], paper.withAlphaComponent(0.18))
        }
    case "lounge":
        // Bunting; a rainbow.
        let tints = [color, NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.4, green: 0.75, blue: 0.75, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.6, alpha: 1)]
        let y0 = top - 2
        strokeLine(NSPoint(x: r.minX + 6, y: y0), NSPoint(x: r.maxX - 6, y: y0), 1, steel)
        for (k, x) in stride(from: r.minX + 10, to: r.maxX - 14, by: 13).enumerated() {
            fillPoly([NSPoint(x: x, y: y0), NSPoint(x: x + 10, y: y0), NSPoint(x: x + 5, y: y0 - 10)], tints[k % 4])
        }
        if wide {
            for (k, tint) in tints.enumerated() {
                tint.withAlphaComponent(0.6).setStroke()
                let arc = NSBezierPath()
                arc.lineWidth = 3
                arc.appendArc(withCenter: NSPoint(x: r.maxX - 26, y: r.minY + 30), radius: CGFloat(16 - k * 4), startAngle: 0, endAngle: 180)
                arc.stroke()
            }
        }
    default:
        break
    }
    // The sign: what the place is.
    let label = text(sceneNames[scene] ?? L("工位", "Desks"), size: 9, weight: .semibold, color: color)
    let w = label.size().width + 14
    let plaque = NSRect(x: r.midX - w / 2, y: r.maxY - 17, width: w, height: 15)
    fillRound(plaque, 7.5, NSColor(calibratedWhite: 0.08, alpha: 0.7))
    put(label, plaque.midX, plaque.minY + 2, align: 1)
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
    /// Wide enough for the caption's line; only the character and the
    /// caption take clicks, the rest is see-through.
    static let size = NSSize(width: 260, height: 168)
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
    var hovering = false
    private var captionRect = NSRect(x: 40, y: 6, width: 96, height: 22)
    private var captionCache: (key: String, image: NSImage, rect: NSRect)?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var characterRect: NSRect { NSRect(x: (Self.size.width - 80) / 2, y: 50, width: 80, height: 80) }
    /// What takes the pointer: the character and the caption.
    var hitRect: NSRect { characterRect.insetBy(dx: -8, dy: -8).union(captionRect) }

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
            let amount = text("+" + fmtUSD(rc.usd), size: 13, weight: .bold, color: ink.withAlphaComponent(alpha), mono: true)
            let name = text(rc.name, size: 9, weight: .medium, color: ink2.withAlphaComponent(alpha))
            // As wide as the longer line ("Software engineer" is), kept inside the view.
            let w = min(bounds.width - 8, max(88, 17 + max(amount.size().width, name.size().width) + 10))
            let card = NSRect(x: min(max(4, c.midX - w / 2), bounds.width - 4 - w), y: c.minY + 50 + CGFloat(ease) * 32, width: w, height: 30)
            NSColor.black.withAlphaComponent(0.18 * alpha).setFill()
            NSBezierPath(roundedRect: card.offsetBy(dx: 0, dy: -2), xRadius: 7, yRadius: 7).fill()
            paper.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7).fill()
            rc.color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: card.minX + 6, y: card.minY + 7, width: 5, height: 16), xRadius: 2.5, yRadius: 2.5).fill()
            put(amount, card.minX + 17, card.minY + 12)
            put(name, card.minX + 17, card.minY + 3)
        }
        // The caption: today's dollars; the line when hovered; the record when just beaten.
        let tone = m.job?.color ?? barColor
        let caption: NSAttributedString
        if t < flashUntil {
            caption = text(flashText, size: 11, weight: .semibold, color: tone, mono: true)
        } else if hovering, !m.line.isEmpty {
            caption = text(m.name + L("：", ": ") + m.line, size: 11, weight: .medium)
        } else {
            caption = text(L("今日 ", "Today ") + fmtUSD(m.todayUSD), size: 11, weight: .medium, color: secondary, mono: true)
        }
        // Text layout is the dearest part of a frame, so the pill is laid
        // out and drawn once per text and then reused.
        let key = "\(caption.string)|\(caption.attribute(.foregroundColor, at: 0, effectiveRange: nil).map { "\($0)" } ?? "")|\(bounds.width)"
        if captionCache?.key != key {
            // One line when it fits, else two (centred), cut only past that.
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            let body = NSMutableAttributedString(attributedString: caption)
            body.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: body.length))
            let maxText = bounds.width - 12 - 20
            let fit = body.boundingRect(with: NSSize(width: maxText, height: 200), options: [.usesLineFragmentOrigin])
            let twoLines = fit.height > 20
            let w = min(bounds.width - 12, ceil(fit.width) + 20)
            let rect = NSRect(x: (bounds.width - w) / 2, y: 6, width: w, height: twoLines ? 36 : 22)
            let image = NSImage(size: rect.size, flipped: false) { r in
                NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
                body.draw(with: NSRect(x: 10, y: 4, width: r.width - 20, height: r.height - 7), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                return true
            }
            captionCache = (key, image, rect)
        }
        if let cache = captionCache {
            captionRect = cache.rect
            cache.image.draw(in: cache.rect)
        }
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

/// The office in the dashboard, one room: the break room on the left (door,
/// coffee machine, sofa), the stage in the middle, a window and a plant in
/// the right corner. Whoever's job a running turn is doing works on the
/// stage, in that job's scene — the doctor in a clinic, the trainer in a
/// gym — with helpers. The rest slack off in the break room: coffee right
/// after a turn, then the sofa (phone, a chat, asleep after two quiet
/// hours) or the corner (window, plant). They walk to wherever they go
/// next: onto the stage when their job comes up, back when it is done, and
/// out of the door and in again when there are more of them than places,
/// so the faces change.
final class OfficeView: NSView {
    static let height: CGFloat = 178
    var occupants: [Occupant] = []
    var t = 0.0
    override var isFlipped: Bool { false }

    enum Pastime { case working, coffee, phone, chat, sleep, window, plant }
    private enum Spot: Equatable { case coffee, seat(Int), corner }

    /// Someone in the room: where (the x of their centre), how far through
    /// the door (alpha), and whether they are on their way out.
    private struct Walker { var o: Occupant; var x: CGFloat; var alpha: CGFloat; var leaving: Bool }
    private var walkers: [String: Walker] = [:]
    private var seeded = false
    /// Walking speed, points a second.
    private let speed: CGFloat = 40

    // The room's places, from the left wall: door, coffee, sofa, the corner
    // with the window and the flowers, then the stage to the right wall.
    private let floorH: CGFloat = 50
    private let doorX: CGFloat = 16
    private let coffeeX: CGFloat = 58
    private let seats: [CGFloat] = [90, 124]
    private let cornerX: CGFloat = 160
    /// The flower pot's centre, right of whoever waters it, under the spout.
    private var plantX: CGFloat { cornerX + 40 }
    private var stage: NSRect { NSRect(x: 212, y: floorH + 4, width: max(80, bounds.width - 212 - 8), height: bounds.height - floorH - 12) }

    /// Part of the stage: the people working in one scene. Everyone at a
    /// desk shares one long desk.
    private struct Bay { var scene: String; var rect: NSRect; var color: NSColor; var members: [(Occupant, CGFloat)] }

    /// Workers on the stage, grouped by scene into bays as wide as their
    /// people need (spare room shared out), three people at most; whoever
    /// does not fit is named on the stage's edge. Characters shrink as the
    /// stage fills.
    private func stageLayout() -> (bays: [Bay], size: CGFloat, overflow: [Occupant]) {
        let st = stage
        let working = occupants.filter(\.working)
        let first = Array(working.prefix(3))
        let size: CGFloat = first.count <= 1 ? 54 : first.count == 2 ? 48 : 42
        func need(_ scene: String, _ n: Int) -> CGFloat { scene == "desk" ? CGFloat(n) * (size - 10) + 28 : CGFloat(n) * (size + 4) + 22 }
        var groups: [(String, [Occupant])] = []
        for o in first {
            if let i = groups.firstIndex(where: { $0.0 == o.job.scene }) { groups[i].1.append(o) } else { groups.append((o.job.scene, [o])) }
        }
        while groups.map({ need($0.0, $0.1.count) }).reduce(0, +) > st.width, let last = groups.indices.last {
            groups[last].1.removeLast()
            if groups[last].1.isEmpty { groups.removeLast() }
        }
        let spare = (st.width - groups.map { need($0.0, $0.1.count) }.reduce(0, +)) / CGFloat(max(groups.count, 1))
        var x = st.minX
        var bays: [Bay] = []
        for (scene, members) in groups {
            let w = need(scene, members.count) + spare
            let r = NSRect(x: x, y: st.minY, width: w, height: st.height)
            let step = (w - 20) / CGFloat(members.count)
            bays.append(Bay(scene: scene, rect: r, color: members[0].job.color,
                            members: members.enumerated().map { i, o in (o, r.minX + 10 + step * (CGFloat(i) + 0.5)) }))
            x += w
        }
        let shown = Set(bays.flatMap { $0.members.map(\.0.job.id) })
        return (bays, size, working.filter { !shown.contains($0.job.id) })
    }

    /// Where everyone should be now. Workers take the stage (three at most,
    /// see `stageLayout`); the rest share the break room's four places, in
    /// turns every two minutes when there are more of them, each with a
    /// pastime that changes every three.
    private func plan(_ now: Double) -> [(Occupant, Pastime, CGFloat)] {
        var idle = occupants.filter { !$0.working }
        if idle.count > 4 {
            let k = Int(now / 120_000) % idle.count
            idle = Array((idle + idle)[k..<k + 4])
        }
        var out: [(Occupant, Pastime, CGFloat)] = stageLayout().bays.flatMap { $0.members.map { ($0.0, Pastime.working, $0.1) } }
        let wants: [(Occupant, Pastime)] = idle.map { o in
            let mins = (now - o.since) / 60_000
            if mins < 15 { return (o, .coffee) }
            if mins > 120 { return (o, .sleep) }
            return (o, [Pastime.plant, .coffee, .phone][stableHash(o.job.id + "\(Int(now / 180_000))") % 3])
        }
        // Sleepers choose first: they need the sofa.
        var free: [Spot] = [.coffee, .seat(0), .seat(1), .corner]
        var placed: [(Occupant, Pastime, Spot)] = []
        for (o, want) in wants.filter({ $0.1 == .sleep }) + wants.filter({ $0.1 != .sleep }) {
            let prefs: [Spot]
            switch want {
            case .coffee: prefs = [.coffee, .seat(0), .seat(1), .corner]
            case .window, .plant: prefs = [.corner, .seat(1), .seat(0), .coffee]
            default: prefs = [.seat(0), .seat(1), .coffee, .corner]
            }
            guard let spot = prefs.first(where: free.contains) else { break }
            free.removeAll { $0 == spot }
            // What the place allows.
            let p: Pastime
            switch spot {
            case .coffee: p = .coffee
            case .corner: p = .plant
            case .seat: p = want == .sleep ? .sleep : .phone
            }
            placed.append((o, p, spot))
        }
        // Two awake on the sofa talk instead.
        let chatting = placed.filter { $0.1 == .phone }.count == 2
        for (o, p, spot) in placed {
            let x: CGFloat
            switch spot {
            case .coffee: x = coffeeX
            case .seat(let i): x = seats[i]
            case .corner: x = cornerX
            }
            out.append((o, chatting && p == .phone ? .chat : p, x))
        }
        return out
    }

    func tick(_ dt: Double) {
        t += dt
        let now = Date().timeIntervalSince1970 * 1000
        let plan = plan(now)
        // The first look finds everyone in place; later arrivals come in by the door.
        let snap = !seeded
        if !plan.isEmpty { seeded = true }
        let step = speed * CGFloat(dt)
        var here = Set<String>()
        for (o, _, x) in plan {
            here.insert(o.job.id)
            var w = walkers[o.job.id] ?? Walker(o: o, x: snap ? x : doorX, alpha: snap ? 1 : 0, leaving: false)
            w.o = o
            w.leaving = false
            if w.alpha < 1 {
                w.alpha = min(1, w.alpha + CGFloat(dt) * 2.5)
            } else {
                w.x += max(-step, min(step, x - w.x))
            }
            walkers[o.job.id] = w
        }
        for (id, var w) in walkers where !here.contains(id) {
            w.leaving = true
            if abs(w.x - doorX) > 0.5 {
                w.x += max(-step, min(step, doorX - w.x))
            } else {
                w.alpha -= CGFloat(dt) * 2.5
            }
            walkers[id] = w.alpha > 0 ? w : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !seeded { tick(0) }
        let b = bounds
        let now = Date().timeIntervalSince1970 * 1000
        let plan = plan(now)
        let layout = stageLayout()
        stageSize = layout.size
        // Names only once people stand too close for a second line.
        let xs = layout.bays.flatMap { $0.members.map(\.1) }.sorted()
        crowded = xs.count > 2 || zip(xs, xs.dropFirst()).contains { $1 - $0 < 92 }
        sharing = Set(layout.bays.filter { $0.scene == "desk" && $0.members.count > 1 }.flatMap { $0.members.map(\.0.job.id) })
        drawRoom(b, layout: layout, doorOpen: walkers.values.contains { $0.alpha < 1 })
        if walkers.isEmpty {
            put(text(L("现在没人在干活", "Nobody is working right now"), size: 12, color: secondary), b.midX, floorH + 40, align: 1)
            put(text(L("有 agent 开工，它就会走上舞台。", "When an agent starts, someone walks on stage."), size: 10, color: secondary), b.midX, floorH + 22, align: 1)
            return
        }
        let target = Dictionary(plan.map { ($0.0.job.id, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        /// What a walker is doing once there; nil while walking.
        func doing(_ w: Walker) -> Pastime? {
            guard !w.leaving, w.alpha >= 1, let (p, x) = target[w.o.job.id], abs(w.x - x) < 0.5 else { return nil }
            return p
        }
        let all = walkers.values.sorted { $0.o.job.id < $1.o.job.id }
        let seated = all.filter { [.phone, .chat, .sleep].contains(doing($0)) }
        // The seated, then the sofa's front over their laps, then everyone else.
        for w in seated { person(w, doing(w)) }
        drawSofaFront()
        for w in all where !seated.contains(where: { $0.o.job.id == w.o.job.id }) { person(w, doing(w)) }
        // A shared desk goes in front of everyone sitting at it.
        let s = stageSize / 80
        for bay in layout.bays where bay.scene == "desk" && bay.members.count > 1 {
            let (x0, x1) = (bay.members.first!.1 - stageSize / 2 - 10 * s, bay.members.last!.1 + stageSize / 2 + 10 * s)
            fillRound(NSRect(x: x0, y: floorH + 8 - 8 * s, width: x1 - x0, height: 9 * s), 3 * s, NSColor(calibratedRed: 0.55, green: 0.47, blue: 0.4, alpha: 1))
        }
        // Names on the floor in two rows, never on top of each other. Whoever
        // is on the stage also says what they do and earn.
        var taken: [[ClosedRange<CGFloat>]] = [[], []]
        let onStage = all.filter { doing($0) == .working }.sorted { $0.x < $1.x }
        for w in onStage {
            if crowded {
                // A full stage: names only, in whichever row is free.
                let name = text(truncate(w.o.job.name, size: 9, weight: .semibold, width: 86), size: 9, weight: .semibold, color: w.o.job.color)
                let half = name.size().width / 2 + 3
                let span = w.x - half...w.x + half
                guard let row = [0, 1].first(where: { r in !taken[r].contains { $0.overlaps(span) } }) else { continue }
                taken[row].append(span)
                put(name, w.x, row == 0 ? 22 : 8, align: 1)
                continue
            }
            let width = onStage.count > 1 ? stage.width / 2 - 6 : stage.width - 12
            let name = text(truncate(w.o.job.name, size: 10, weight: .semibold, width: width), size: 10, weight: .semibold, color: w.o.job.color)
            let sub = L("在干", "working") + (w.o.helpers > 0 ? " · +\(w.o.helpers)" : "") + " · " + fmtUSD(w.o.usd)
            let line = text(truncate(sub, size: 9, weight: .regular, width: width), size: 9, color: secondary, mono: true)
            put(name, w.x, 22, align: 1)
            put(line, w.x, 8, align: 1)
            let half = max(name.size().width, line.size().width) / 2 + 4
            taken[0].append(w.x - half...w.x + half)
            taken[1].append(w.x - half...w.x + half)
        }
        // Everyone else is named only when the pointer is on them: a bubble
        // over the head with who, what they are up to, and this week's $.
        hitRects = all.map { w in
            let p = doing(w)
            let size: CGFloat = p == .working ? stageSize : 42
            let lift: CGFloat = [.phone, .chat, .sleep].contains(p) ? 6 : 0
            return (w.o.job.id, NSRect(x: w.x - size / 2, y: floorH + 2 + lift, width: size, height: size + 4))
        }
        if let id = hovered, let w = all.first(where: { $0.o.job.id == id }), let r = hitRects.first(where: { $0.0 == id })?.1 {
            let what: String
            switch doing(w) {
            case .working: what = L("在干", "working")
            case .coffee: what = L("喝咖啡", "having coffee")
            case .phone: what = L("刷手机", "on the phone")
            case .chat: what = L("聊天", "chatting")
            case .sleep: what = L("睡着了", "asleep")
            case .plant: what = L("浇花", "watering the flowers")
            case .window: what = L("看窗外", "looking outside")
            case nil: what = L("在走动", "walking")
            }
            let name = text(w.o.job.name, size: 10, weight: .semibold, color: w.o.job.color)
            let sub = text(what + " · " + L("本周 ", "this week ") + fmtUSD(w.o.usd), size: 9, color: primary.withAlphaComponent(0.85))
            let bw = max(name.size().width, sub.size().width) + 16
            var box = NSRect(x: r.midX - bw / 2, y: r.maxY + 6, width: bw, height: 32)
            box.origin.x = min(max(box.minX, 4), bounds.width - bw - 4)
            box.origin.y = min(box.minY, bounds.height - box.height - 4)
            fillRound(box, 7, NSColor(calibratedWhite: 0.05, alpha: 0.92))
            fillPoly([NSPoint(x: r.midX - 4, y: box.minY), NSPoint(x: r.midX + 4, y: box.minY), NSPoint(x: r.midX, y: box.minY - 4)], NSColor(calibratedWhite: 0.05, alpha: 0.92))
            put(name, box.minX + 8, box.minY + 17)
            put(sub, box.minX + 8, box.minY + 4)
        }
    }

    // MARK: hover

    /// Who is under the pointer, and where everyone is (set on each draw).
    private var hovered: String?
    private var hitRects: [(String, NSRect)] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The nearest character whose box holds the pointer.
        let hit = hitRects.filter { $0.1.contains(p) }.min { abs($0.1.midX - p.x) < abs($1.1.midX - p.x) }?.0
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
        super.mouseExited(with: event)
    }

    /// For snapshots: show the bubble over this occupation's character.
    func hover(_ id: String?) { hovered = id }

    /// Set from the stage layout on each draw.
    private var stageSize: CGFloat = 54
    private var crowded = false
    private var sharing: Set<String> = []

    /// One person: walking, at work on the stage, or at a pastime.
    private func person(_ w: Walker, _ p: Pastime?) {
        let job = w.o.job
        let fl = flavor(forJob: job.id)
        let phase = t + Double(stableHash(job.id) % 100) * 0.07
        let blink = fmod(phase, 4.3) < 0.12
        let size: CGFloat = p == .working ? stageSize : 42
        var c = NSRect(x: w.x - size / 2, y: floorH + (p == .working ? 8 : 4), width: size, height: size)
        faded(w.alpha) {
            switch p {
            case nil:
                let hop = CGFloat(abs(sin(phase * 9))) * 3
                drawWorker(c.offsetBy(dx: 0, dy: hop), job: job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false, flavor: fl)
            case .working:
                // Helpers stand behind the worker unless the stage is full.
                drawWorker(c, job: job, mood: "focused", t: phase, blink: blink, working: true, helpers: crowded ? 0 : w.o.helpers,
                           slab: !sharing.contains(job.id), flavor: fl)
            case .coffee:
                drawWorker(c, job: job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false, flavor: fl)
                // A mug in the hand toward the machine, steam rising.
                let sip = CGFloat(max(0, sin(phase * 0.9))) * 6
                let mug = NSRect(x: c.minX - 6, y: c.minY + 10 + sip, width: 10, height: 11)
                fillRound(mug, 2, NSColor(calibratedRed: 0.79, green: 0.71, blue: 0.54, alpha: 1))
                fillOval(NSRect(x: mug.minX - 4, y: mug.minY + 3, width: 6, height: 6), NSColor(calibratedRed: 0.79, green: 0.71, blue: 0.54, alpha: 1))
                for k in 0..<2 {
                    let rise = CGFloat(fmod(phase * 9 + Double(k) * 7, 14))
                    fillOval(NSRect(x: mug.minX + 2 + CGFloat(k) * 4 + CGFloat(sin(phase * 3 + Double(k))) * 1.5, y: mug.maxY + 1 + rise, width: 3, height: 5),
                             NSColor.white.withAlphaComponent(0.35 * (1 - rise / 14)))
                }
            case .phone, .chat:
                c.origin.y += 6
                drawWorker(c, job: job, mood: p == .chat ? "happy" : "focused", t: phase, blink: blink, working: false, helpers: 0, desk: false, flavor: fl)
                if p == .phone {
                    fillRound(NSRect(x: c.midX - 6, y: c.minY + 8, width: 12, height: 18), 2, coal)
                    fillRound(NSRect(x: c.midX - 4.5, y: c.minY + 10, width: 9, height: 14), 1, job.color.withAlphaComponent(0.55 + 0.3 * CGFloat(sin(phase * 2.6))))
                } else if Int(t / 2.2) % 2 == (w.x < (seats[0] + seats[1]) / 2 ? 0 : 1) {
                    // Taking turns to talk.
                    let words = (lang == "en" ? ["haha", "really?", "…", "no way"] : ["哈哈", "真的？", "…", "绝了"])[Int(t / 4.4 + Double(stableHash(job.id) % 4)) % 4]
                    let label = text(words, size: 8, weight: .medium, color: ink)
                    let bw = label.size().width + 10
                    let bubble = NSRect(x: c.midX - bw / 2, y: c.maxY + 4, width: bw, height: 14)
                    fillRound(bubble, 7, paper)
                    fillPoly([NSPoint(x: c.midX - 3, y: bubble.minY), NSPoint(x: c.midX + 3, y: bubble.minY), NSPoint(x: c.midX, y: bubble.minY - 4)], paper)
                    put(label, bubble.midX, bubble.minY + 2, align: 1)
                }
            case .sleep:
                c.origin.y += 6
                drawWorker(c, job: job, mood: "sleepy", t: phase * 0.5, blink: true, working: false, helpers: 0, desk: false, slump: 3, flavor: fl)
                for k in 0..<2 {
                    let rise = CGFloat(fmod(phase * 0.5 + Double(k) * 0.5, 1.0))
                    put(text("z", size: 8 + CGFloat(k) * 2, weight: .bold, color: secondary.withAlphaComponent(0.85 * (1 - rise))),
                        c.maxX - 4 + rise * 8, c.maxY - 8 + rise * 14, align: 1)
                }
            case .window:
                drawWorker(c, job: job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false, flavor: fl)
            case .plant:
                drawWorker(c, job: job, mood: "idle", t: phase, blink: blink, working: false, helpers: 0, desk: false, flavor: fl)
                // Watering, in a loop: lift the can, tip it over the pot and
                // pour a stream onto the soil (a splash where it lands),
                // then set it upright again.
                let cycle = CGFloat(fmod(phase * 0.45, 1.0))
                let pour = cycle < 0.25 ? cycle / 0.25 : cycle < 0.75 ? 1 : 1 - (cycle - 0.75) / 0.25
                let tilt = -8 - 40 * pour
                let hold = NSPoint(x: c.maxX + 4, y: c.minY + 24 + 2 * pour)
                let can = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.78, alpha: 1)
                let dark = can.blended(withFraction: 0.25, of: .black) ?? can
                strokeLine(NSPoint(x: c.maxX - 8, y: c.minY + 15), hold, 5, fl.body)
                // A small can: body, handle, a thin spout with a rose.
                rotated(hold, tilt) {
                    fillRound(NSRect(x: hold.x - 2, y: hold.y - 5, width: 11, height: 9), 2, can)
                    fillRound(NSRect(x: hold.x, y: hold.y + 4, width: 7, height: 2), 1, dark)
                    fillPoly([NSPoint(x: hold.x + 8, y: hold.y), NSPoint(x: hold.x + 18, y: hold.y + 4.5), NSPoint(x: hold.x + 18, y: hold.y + 2.5), NSPoint(x: hold.x + 8, y: hold.y - 2.5)], can)
                    fillRound(NSRect(x: hold.x + 17, y: hold.y + 1.5, width: 3, height: 4), 1, dark)
                }
                if pour > 0.7 {
                    let a = tilt * .pi / 180
                    let tip = NSPoint(x: hold.x + 20 * cos(a) - 3.5 * sin(a), y: hold.y + 20 * sin(a) + 3.5 * cos(a))
                    let soil = floorH + 8
                    let water = NSColor(calibratedRed: 0.58, green: 0.8, blue: 1, alpha: 0.95)
                    // A light shower from the rose straight down onto the soil.
                    for k in 0..<6 {
                        let f = CGFloat(fmod(phase * 2.6 + Double(k) / 6, 1.0))
                        let spread = CGFloat(k % 3 - 1) * (0.8 + 1.6 * f)
                        fillOval(NSRect(x: tip.x + spread + 1.5 * f - 1, y: tip.y - f * max(0, tip.y - soil) - 1.4, width: 2, height: 2.8),
                                 water.withAlphaComponent(0.95 - 0.35 * f))
                    }
                    // A splash where it lands.
                    let s = CGFloat(fmod(phase * 2.6, 1.0))
                    for side: CGFloat in [-1, 1] {
                        fillOval(NSRect(x: tip.x + 1.5 + side * (2 + 4 * s) - 1, y: soil + 1 + 2.5 * sin(s * .pi), width: 2, height: 2), water.withAlphaComponent(1 - s))
                    }
                }
            }
        }
    }

    /// Walls, floor, the break room, the stage with each worker's scene, the corner.
    private func drawRoom(_ b: NSRect, layout: (bays: [Bay], size: CGFloat, overflow: [Occupant]), doorOpen: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: b, xRadius: 12, yRadius: 12).addClip()
        NSColor(calibratedWhite: 0.165, alpha: 1).setFill()
        b.fill()
        NSColor(calibratedWhite: 0.125, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: b.width, height: floorH)).fill()
        for x in stride(from: CGFloat(13), to: b.width, by: 26) {
            fillRound(NSRect(x: x, y: 0, width: 1, height: floorH), 0, NSColor.white.withAlphaComponent(0.035))
        }
        fillRound(NSRect(x: 0, y: floorH, width: b.width, height: 2), 0, NSColor.white.withAlphaComponent(0.07))

        // The door, ajar while someone comes or goes.
        let door = NSRect(x: doorX - 12, y: floorH, width: 24, height: 70)
        fillRound(door.insetBy(dx: -2, dy: -1).offsetBy(dx: 0, dy: 1), 2, NSColor(calibratedWhite: 0.28, alpha: 1))
        if doorOpen {
            fillRound(door, 1, NSColor(calibratedWhite: 0.05, alpha: 1))
            fillRound(NSRect(x: door.minX, y: door.minY, width: 8, height: door.height), 1, woodDark)
        } else {
            fillRound(door, 1, woodDark)
            fillRound(door.insetBy(dx: 4, dy: 8).offsetBy(dx: 0, dy: 8), 1, wood.withAlphaComponent(0.35))
            fillOval(NSRect(x: door.maxX - 7, y: door.minY + 30, width: 4, height: 4), steel)
        }
        // A counter with the coffee machine; its light blinks while it brews.
        let counter = NSRect(x: 30, y: floorH - 2, width: 18, height: 30)
        fillRound(counter, 2, wood)
        fillRound(NSRect(x: counter.minX - 2, y: counter.maxY - 3, width: counter.width + 4, height: 4), 1, woodDark)
        let machine = NSRect(x: counter.minX + 1, y: counter.maxY, width: 16, height: 22)
        fillRound(machine, 3, coal)
        fillRound(NSRect(x: machine.minX + 3, y: machine.maxY - 8, width: 10, height: 5), 1, NSColor(calibratedWhite: 0.3, alpha: 1))
        fillOval(NSRect(x: machine.maxX - 6, y: machine.maxY - 7, width: 3, height: 3),
                 fmod(t, 1.4) < 0.7 ? NSColor(calibratedRed: 0.95, green: 0.4, blue: 0.35, alpha: 1) : NSColor(calibratedRed: 0.4, green: 0.25, blue: 0.25, alpha: 1))
        fillRound(NSRect(x: machine.midX - 3, y: machine.minY + 2, width: 6, height: 6), 1, paper)
        // The sofa's back, and the room's name above it.
        fillRound(NSRect(x: 72, y: floorH + 6, width: 70, height: 30), 8, NSColor(calibratedRed: 0.24, green: 0.33, blue: 0.36, alpha: 1))

        // The stage: one scene per worker, or an empty one waiting.
        let st = stage
        fillRound(NSRect(x: st.minX - 2, y: floorH - 8, width: st.width + 4, height: 12), 3, NSColor(calibratedWhite: 0.21, alpha: 1))
        fillRound(NSRect(x: st.minX - 2, y: floorH + 1, width: st.width + 4, height: 3), 1.5, NSColor.white.withAlphaComponent(0.08))
        // Anyone at work who does not fit is named on the stage's edge.
        let more = layout.overflow
        if let first = more.first {
            let note = more.count == 1 ? L("\(first.job.name) 也在干", "\(first.job.name) is working too") : L("还有 \(more.count) 人也在干", "\(more.count) more are working")
            put(text(truncate(note, size: 8, weight: .medium, width: st.width - 8), size: 8, weight: .medium, color: secondary), st.midX, floorH - 7, align: 1)
        }
        if layout.bays.isEmpty {
            fillRound(st, 6, NSColor.white.withAlphaComponent(0.025))
            put(text(L("舞台空着", "The stage is empty"), size: 10, weight: .medium, color: secondary.withAlphaComponent(0.7)), st.midX, st.midY + 4, align: 1)
            put(text(L("有活就有人上来", "Someone steps up when there's work"), size: 9, color: secondary.withAlphaComponent(0.5)), st.midX, st.midY - 10, align: 1)
        }
        for bay in layout.bays {
            drawBackdrop(bay.scene, bay.rect.insetBy(dx: 1, dy: 0), bay.color)
            // A spotlight over the bay.
            let (x0, x1) = (bay.members.first!.1, bay.members.last!.1)
            fillPoly([NSPoint(x: (x0 + x1) / 2 - 8, y: bay.rect.maxY - 20), NSPoint(x: (x0 + x1) / 2 + 8, y: bay.rect.maxY - 20),
                      NSPoint(x: x1 + 30, y: floorH + 2), NSPoint(x: x0 - 30, y: floorH + 2)], NSColor.white.withAlphaComponent(0.035))
        }

        // The corner: the window shows the hour's sky; the plant below.
        let hour = Calendar.current.component(.hour, from: Date())
        let win = NSRect(x: cornerX - 22, y: b.maxY - 66, width: 56, height: 46)
        let night = hour < 6 || hour >= 19
        let sky = NSGradient(starting: night ? NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.3, alpha: 1) : NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.92, alpha: 1),
                             ending: night ? NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.4, alpha: 1) : NSColor(calibratedRed: 0.82, green: 0.9, blue: 0.96, alpha: 1))
        sky?.draw(in: NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4), angle: 90)
        if night {
            fillOval(NSRect(x: win.maxX - 22, y: win.maxY - 20, width: 11, height: 11), NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.8, alpha: 1))
            for (sx, sy) in [(10.0, 28.0), (22.0, 16.0), (34.0, 32.0)] {
                fillOval(NSRect(x: win.minX + CGFloat(sx), y: win.minY + CGFloat(sy), width: 2, height: 2), NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.8, alpha: 1))
            }
        } else {
            fillOval(NSRect(x: win.maxX - 24, y: win.maxY - 22, width: 13, height: 13), NSColor(calibratedRed: 1, green: 0.9, blue: 0.55, alpha: 1))
            // A cloud drifting across.
            let cx = win.minX + CGFloat(fmod(t * 3, Double(win.width + 30))) - 15
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4).addClip()
            for (dx, dy, d) in [(0.0, 0.0, 10.0), (7.0, 3.0, 12.0), (15.0, 0.0, 9.0)] {
                fillOval(NSRect(x: cx + CGFloat(dx), y: win.minY + 12 + CGFloat(dy), width: CGFloat(d), height: CGFloat(d) * 0.8), NSColor.white.withAlphaComponent(0.85))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(calibratedWhite: 0.3, alpha: 1).setStroke()
        let frame = NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4)
        frame.lineWidth = 3
        frame.stroke()
        strokeLine(NSPoint(x: win.midX, y: win.minY), NSPoint(x: win.midX, y: win.maxY), 2, NSColor(calibratedWhite: 0.3, alpha: 1))
        strokeLine(NSPoint(x: win.minX, y: win.midY), NSPoint(x: win.maxX, y: win.midY), 2, NSColor(calibratedWhite: 0.3, alpha: 1))
        drawFlowers(NSPoint(x: plantX, y: floorH - 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The sofa's seat and arms, drawn over whoever sits on it.
    private func drawSofaFront() {
        let sofa = NSColor(calibratedRed: 0.3, green: 0.41, blue: 0.44, alpha: 1)
        fillRound(NSRect(x: 70, y: floorH - 4, width: 74, height: 18), 6, sofa)
        fillRound(NSRect(x: 72, y: floorH + 9, width: 70, height: 4), 2, NSColor.white.withAlphaComponent(0.06))
        for x: CGFloat in [66, 138] { fillRound(NSRect(x: x, y: floorH - 4, width: 10, height: 26), 4, sofa.blended(withFraction: 0.15, of: .black) ?? sofa) }
        for x: CGFloat in [76, 134] { fillRound(NSRect(x: x, y: floorH - 8, width: 4, height: 5), 1, coal) }
    }

    /// A pot of flowers standing at `base` (bottom centre): three stems with
    /// leaves, each with a five-petal bloom, swaying a little.
    private func drawFlowers(_ base: NSPoint) {
        let pot = NSRect(x: base.x - 10, y: base.y, width: 20, height: 12)
        fillPoly([NSPoint(x: pot.minX, y: pot.maxY), NSPoint(x: pot.maxX, y: pot.maxY), NSPoint(x: pot.maxX - 3, y: pot.minY), NSPoint(x: pot.minX + 3, y: pot.minY)],
                 NSColor(calibratedRed: 0.72, green: 0.42, blue: 0.3, alpha: 1))
        fillRound(NSRect(x: pot.minX - 1, y: pot.maxY - 4, width: pot.width + 2, height: 4), 1.5, NSColor(calibratedRed: 0.62, green: 0.35, blue: 0.25, alpha: 1))
        let blooms: [(CGFloat, CGFloat, NSColor)] = [(-6, 22, NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.65, alpha: 1)),
                                                     (1, 30, NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.35, alpha: 1)),
                                                     (7, 19, NSColor(calibratedRed: 0.92, green: 0.45, blue: 0.4, alpha: 1))]
        for (k, (dx, h, petal)) in blooms.enumerated() {
            let sway = CGFloat(sin(t * 0.9 + Double(k) * 1.3)) * 1.5
            let foot = NSPoint(x: base.x + dx * 0.4, y: pot.maxY - 1)
            let head = NSPoint(x: base.x + dx + sway, y: pot.maxY + h)
            strokeLine(foot, head, 1.6, leafGreen)
            // A leaf half way up.
            let mid = NSPoint(x: (foot.x + head.x) / 2, y: (foot.y + head.y) / 2)
            rotated(mid, k % 2 == 0 ? 35 : -35) {
                fillOval(NSRect(x: mid.x + (k % 2 == 0 ? -8 : 0), y: mid.y - 2, width: 8, height: 4), leafGreen)
            }
            for p in 0..<5 {
                let a = CGFloat(p) * 2 * .pi / 5 + CGFloat(t * 0.2)
                fillOval(NSRect(x: head.x + cos(a) * 3.2 - 2.6, y: head.y + sin(a) * 3.2 - 2.6, width: 5.2, height: 5.2), petal)
            }
            fillOval(NSRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6), NSColor(calibratedRed: 0.98, green: 0.9, blue: 0.55, alpha: 1))
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
        // Scrolls with the trackpad or wheel; no scroll bar is drawn.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
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
        // 8 bits a channel is plenty for flat colours, and far cheaper to
        // composite than the 16-bit float the screen would otherwise get.
        petPanel.depthLimit = .twentyfourBitRGB
        let v = PetView(frame: NSRect(origin: .zero, size: PetView.size))
        v.wantsLayer = true
        v.layer?.contentsFormat = .RGBA8Uint
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
            // 24 frames a second; nothing while the pet is covered or hidden.
            if let pet = self.pet, self.petPanel.isVisible {
                pet.tick(1.0 / 24.0)
                if self.petPanel.occlusionState.contains(.visible) { pet.needsDisplay = true }
            }
            if self.isExpanded {
                let office = self.dashboard.office
                office.tick(1.0 / 24.0)
                office.needsDisplay = true
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
        // Saved by a window of another width: keep the character's centre.
        let was = UserDefaults.standard.object(forKey: "petWidth") as? Double ?? 176
        let p = NSPoint(x: a[0] - (PetView.size.width - was) / 2, y: a[1])
        let r = NSRect(origin: p, size: PetView.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } ? p : nil
    }

    func saveOrigin() {
        let o = petPanel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: originKey)
        UserDefaults.standard.set(Double(PetView.size.width), forKey: "petWidth")
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

    /// Runs `dango card` for a day, week, month or year — this one, or
    /// with `back` 1 the one before — for one agent or all. The CLI renders
    /// the card, saves it, copies it and opens it; the pet says when.
    func makeCard(kind: String, back: Int = 0, tool: String = "all") {
        let name = lang == "en" ? (["day": "day card", "week": "week card", "month": "month card", "year": "year card"][kind] ?? "day card")
                                : (["day": "日报", "week": "周报", "month": "月报", "year": "年报"][kind] ?? "日报")
        guard let cli = cliPath() else {
            pet?.flash(L("没找到 dango 命令", "Can't find the dango command"))
            return
        }
        let unit: Calendar.Component = ["week": .weekOfYear, "month": .month, "year": .year][kind] ?? .day
        let date = Calendar.current.date(byAdding: unit, value: -back, to: Date()) ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["card", "--day", f.string(from: date)] + (kind == "day" ? [] : ["--\(kind)"]) + (tool == "all" ? [] : ["--tool", tool])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.pet?.flash(proc.terminationStatus == 0 ? L("\(name)已复制到剪贴板", "\(name.prefix(1).uppercased() + name.dropFirst()) copied") : L("\(name)没生成出来", "Couldn't make the \(name)"))
            }
        }
        pet?.flash(L("正在生成\(name)…", "Making the \(name)…"))
        try? p.run()
        collapse()
    }

    /// From the menu: "week:1" is last week's card.
    @objc func exportFromMenu(_ sender: NSMenuItem) {
        let parts = (sender.representedObject as? String ?? "day:0").split(separator: ":")
        makeCard(kind: String(parts[0]), back: parts.count > 1 ? Int(parts[1]) ?? 0 : 0, tool: isExpanded ? dashboard.filter : "all")
    }

    // MARK: menu

    func popMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isExpanded ? L("收起仪表盘", "Close dashboard") : L("打开仪表盘", "Open dashboard"), action: #selector(toggle), keyEquivalent: ""))
        let export = NSMenu()
        for (i, (kind, now, before)) in [("day", L("今日日报", "Today"), L("昨日日报", "Yesterday")), ("week", L("本周周报", "This week"), L("上周周报", "Last week")),
                                         ("month", L("本月月报", "This month"), L("上月月报", "Last month")), ("year", L("今年年报", "This year"), L("去年年报", "Last year"))].enumerated() {
            if i > 0 { export.addItem(.separator()) }
            for (back, title) in [(0, now), (1, before)] {
                let item = NSMenuItem(title: title, action: #selector(exportFromMenu(_:)), keyEquivalent: "")
                item.representedObject = "\(kind):\(back)"
                item.target = self
                export.addItem(item)
            }
        }
        let exportItem = NSMenuItem(title: L("导出报告", "Export report"), action: nil, keyEquivalent: "")
        exportItem.submenu = export
        menu.addItem(exportItem)
        let langs = NSMenu()
        for (code, title) in [("zh", "中文"), ("en", "English")] {
            let item = NSMenuItem(title: title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.state = lang == code ? .on : .off
            item.target = self
            langs.addItem(item)
        }
        let langItem = NSMenuItem(title: "语言 / Language", action: nil, keyEquivalent: "")
        langItem.submenu = langs
        menu.addItem(langItem)
        let flav = NSMenu()
        for f in flavors {
            let item = NSMenuItem(title: f.name, action: #selector(setFlavor(_:)), keyEquivalent: "")
            item.representedObject = f.id
            item.state = petFlavor.id == f.id ? .on : .off
            item.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
                f.body.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
                NSColor.black.withAlphaComponent(0.3).setStroke()
                NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).stroke()
                return true
            }
            item.target = self
            flav.addItem(item)
        }
        let flavItem = NSMenuItem(title: L("团子口味", "Flavor"), action: nil, keyEquivalent: "")
        flavItem.submenu = flav
        menu.addItem(flavItem)
        let auto = NSMenuItem(title: L("登录时自动启动", "Start at login"), action: #selector(toggleAutostart), keyEquivalent: "")
        auto.state = FileManager.default.fileExists(atPath: agentPlist) ? .on : .off
        menu.addItem(auto)
        let snd = NSMenuItem(title: L("结算提示音", "Sounds"), action: #selector(toggleSound), keyEquivalent: "")
        snd.state = Sounds.enabled ? .on : .off
        menu.addItem(snd)
        menu.addItem(NSMenuItem(title: L("回到右下角", "Back to the corner"), action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出", "Quit"), action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleSound() { Sounds.enabled.toggle() }

    /// The flavour menu: the pet, its dashboard badge and new cards.
    @objc func setFlavor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "flavor")
        pet?.needsDisplay = true
        dashboard.needsDisplay = true
    }

    /// The language menu: switches here at once and tells the daemon
    /// (`dango lang`), which rewrites widget.json in that language.
    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, code != lang else { return }
        lang = code
        UserDefaults.standard.set(code, forKey: "lang")
        dashboard.needsDisplay = true
        pet?.needsDisplay = true
        guard let cli = cliPath() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["lang", code]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
        try? p.run()
    }

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
            pet?.flash(L("单日新高 ✦ ", "New best day ✦ ") + fmtUSD(m.todayUSD))
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

// MARK: - Flavors

/// A 团子's flavour: the body colour and its name. Light flavours get dark
/// bead eyes and an outline; dark ones keep white eyes.
struct Flavor {
    var id: String
    var zh: String
    var en: String
    var body: NSColor
    var name: String { L(zh, en) }
    var light: Bool { luminance(body) > 0.5 }
}

func luminance(_ c: NSColor) -> CGFloat {
    let x = c.usingColorSpace(.deviceRGB) ?? c
    return 0.299 * x.redComponent + 0.587 * x.greenComponent + 0.114 * x.blueComponent
}

let flavors: [Flavor] = [
    Flavor(id: "sesame", zh: "黑芝麻", en: "Black sesame", body: NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.16, alpha: 1)),
    Flavor(id: "plain", zh: "原味", en: "Plain", body: NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.91, alpha: 1)),
    Flavor(id: "sakura", zh: "樱花", en: "Sakura", body: NSColor(calibratedRed: 0.97, green: 0.73, blue: 0.78, alpha: 1)),
    Flavor(id: "matcha", zh: "抹茶", en: "Matcha", body: NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.47, alpha: 1)),
    Flavor(id: "kinako", zh: "黄豆粉", en: "Kinako", body: NSColor(calibratedRed: 0.89, green: 0.76, blue: 0.52, alpha: 1)),
    Flavor(id: "pumpkin", zh: "南瓜", en: "Pumpkin", body: NSColor(calibratedRed: 0.96, green: 0.65, blue: 0.33, alpha: 1)),
    Flavor(id: "taro", zh: "紫薯", en: "Taro", body: NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.80, alpha: 1)),
    Flavor(id: "azuki", zh: "红豆", en: "Red bean", body: NSColor(calibratedRed: 0.55, green: 0.29, blue: 0.29, alpha: 1)),
]

func flavorNamed(_ id: String) -> Flavor { flavors.first { $0.id == id } ?? flavors[0] }

/// Snapshots set this instead of the saved choice.
var petFlavorOverride: String?

/// The pet's own flavour (the menu's 团子口味 / Flavor), black sesame at first.
var petFlavor: Flavor { flavorNamed(petFlavorOverride ?? UserDefaults.standard.string(forKey: "flavor") ?? "sesame") }

/// Every job's 团子 in the office has its own flavour, so a room of
/// colleagues is not a row of black blobs; the usual crowd all differ.
let jobFlavors = ["swe": "sesame", "data": "taro", "writer": "plain", "research": "pumpkin", "video": "azuki", "qa": "matcha", "web": "sakura",
                  "ops": "kinako", "fin": "kinako", "doctor": "plain", "trainer": "pumpkin", "counselor": "sakura", "designer": "sakura",
                  "musician": "taro", "chef": "azuki", "mathematician": "matcha", "physicist": "taro", "chemist": "matcha", "biologist": "matcha",
                  "architect": "kinako", "lawyer": "sesame", "entry": "plain"]

func flavor(forJob id: String) -> Flavor { flavorNamed(jobFlavors[id] ?? flavors[stableHash(id) % flavors.count].id) }

/// The three colours of a hanami skewer, for the helpers behind a worker.
let helperFlavors = ["sakura", "plain", "matcha"]

// MARK: - Character

/// The character (DESIGN.md §2): a round ink blob with big eyes. `mood`
/// is one of waiting / focused / happy / proud / sleepy / missing. Works in
/// flipped and unflipped views: positions are given as fractions from the
/// top of `r`.
func drawCharacter(_ r: NSRect, mood: String, ink: NSColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.16, alpha: 1),
                   look: [String] = [], jobColor: NSColor? = nil, blink: Bool = false, flavor: Flavor? = nil) {
    let flipped = NSGraphicsContext.current?.isFlipped ?? false
    let w = r.width, h = r.height
    let cream = NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.89, alpha: 1)
    // The flavour's colour (or `ink`), and what goes with it.
    let skin = flavor?.body ?? ink
    let light = luminance(skin) > 0.5
    let shade = skin.blended(withFraction: light ? 0.32 : 0.0, of: .black) ?? skin
    let pupil = NSColor(calibratedWhite: 0.08, alpha: 1)
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

    // Body: a soft mochi, slightly flatter at the bottom. Light flavours
    // get a darker rim so they read on paper and on light walls.
    let bodyRect = box(0.04, 0.04, 0.92, 0.94)
    let base = box(0.08, 0.62, 0.84, 0.36)
    if light {
        shade.setFill()
        let o = max(1, w * 0.025)
        NSBezierPath(ovalIn: bodyRect.insetBy(dx: -o, dy: -o)).fill()
        NSBezierPath(roundedRect: base.insetBy(dx: -o, dy: -o), xRadius: w * 0.2 + o, yRadius: w * 0.2 + o).fill()
    }
    skin.setFill()
    NSBezierPath(ovalIn: bodyRect).fill()
    NSBezierPath(roundedRect: base, xRadius: w * 0.2, yRadius: w * 0.2).fill()
    // A soft shine, top left.
    NSColor.white.withAlphaComponent(light ? 0.5 : 0.1).setFill()
    NSBezierPath(ovalIn: box(0.2, 0.13, 0.2, 0.1)).fill()
    // Flavour marks: sesame seeds, kinako dust, a sakura petal.
    switch flavor?.id {
    case "sesame":
        for (fx, ft) in [(0.62, 0.12), (0.7, 0.2), (0.55, 0.19)] {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: box(CGFloat(fx), CGFloat(ft), 0.045, 0.028)).fill()
        }
    case "kinako":
        for (fx, ft) in [(0.6, 0.12), (0.7, 0.18), (0.52, 0.2), (0.78, 0.27), (0.25, 0.26), (0.66, 0.26)] {
            shade.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: box(CGFloat(fx), CGFloat(ft), 0.03, 0.03)).fill()
        }
    case "sakura":
        let c0 = pt(0.74, 0.17)
        for k in 0..<5 {
            let a = CGFloat(k) * 2 * .pi / 5
            NSColor.white.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: NSRect(x: c0.x + cos(a) * w * 0.035 - w * 0.03, y: c0.y + sin(a) * w * 0.035 - w * 0.03, width: w * 0.06, height: w * 0.06)).fill()
        }
        NSColor(calibratedRed: 0.93, green: 0.45, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c0.x - w * 0.018, y: c0.y - w * 0.018, width: w * 0.036, height: w * 0.036)).fill()
    default:
        break
    }
    // Cheeks
    NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.55, alpha: light ? 0.5 : 0.35).setFill()
    NSBezierPath(ovalIn: box(0.16, 0.58, 0.14, 0.08)).fill()
    NSBezierPath(ovalIn: box(0.70, 0.58, 0.14, 0.08)).fill()
    // A small mouth between the cheeks, by mood.
    let mouthInk = light ? pupil.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.75)
    let m = box(0.45, 0.585, 0.1, 0.06)
    mouthInk.setStroke()
    let mouth = NSBezierPath()
    mouth.lineWidth = max(1, w * 0.022)
    mouth.lineCapStyle = .round
    let down: CGFloat = flipped ? 1 : -1
    switch mood {
    case "happy", "proud":
        // Open and smiling.
        mouthInk.setFill()
        let o = NSBezierPath()
        o.move(to: NSPoint(x: m.minX, y: m.midY - down * m.height * 0.3))
        o.curve(to: NSPoint(x: m.maxX, y: m.midY - down * m.height * 0.3),
                controlPoint1: NSPoint(x: m.minX, y: m.midY + down * m.height * 0.9), controlPoint2: NSPoint(x: m.maxX, y: m.midY + down * m.height * 0.9))
        o.close()
        o.fill()
    case "sleepy":
        mouth.appendOval(in: NSRect(x: m.midX - w * 0.02, y: m.midY - w * 0.02, width: w * 0.04, height: w * 0.04))
        mouth.stroke()
    case "focused", "missing":
        mouth.move(to: NSPoint(x: m.minX + m.width * 0.2, y: m.midY))
        mouth.line(to: NSPoint(x: m.maxX - m.width * 0.2, y: m.midY))
        mouth.stroke()
    default:
        mouth.move(to: NSPoint(x: m.minX, y: m.midY - down * m.height * 0.2))
        mouth.curve(to: NSPoint(x: m.maxX, y: m.midY - down * m.height * 0.2),
                    controlPoint1: NSPoint(x: m.minX + m.width * 0.25, y: m.midY + down * m.height * 0.5),
                    controlPoint2: NSPoint(x: m.maxX - m.width * 0.25, y: m.midY + down * m.height * 0.5))
        mouth.stroke()
    }
    // Eyes: white with dark pupils on dark flavours; dark beads with a
    // glint on light ones.
    let white = light ? pupil : NSColor.white
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
            let lid = mood == "sleepy" ? 0.5 : 0.4
            if light {
                // A bead with the lid half down.
                pupil.setFill()
                NSBezierPath(ovalIn: box(fx + 0.025, 0.34, 0.12, 0.17)).fill()
                skin.setFill()
                NSBezierPath(rect: box(fx, 0.32, 0.17, 0.02 + 0.17 * lid)).fill()
                continue
            }
            white.setFill()
            NSBezierPath(ovalIn: e).fill()
            // Lid over the top part of the eye.
            skin.setFill()
            NSBezierPath(rect: box(fx - 0.01, 0.32 - 0.05, 0.19, 0.05 + 0.22 * lid)).fill()
            pupil.setFill()
            NSBezierPath(ovalIn: box(fx + 0.045, 0.32 + 0.22 * lid, 0.08, 0.22 * (1 - lid) * 0.8)).fill()
        case "proud":
            (light ? NSColor(calibratedRed: 0.85, green: 0.62, blue: 0.1, alpha: 1) : white).setFill()
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
        case _ where light:
            // A dark bead with a glint.
            let dx: CGFloat = mood == "waiting" ? 0.02 : 0
            pupil.setFill()
            NSBezierPath(ovalIn: box(fx + 0.025 + dx, 0.34, 0.12, 0.17)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box(fx + 0.085 + dx, 0.365, 0.04, 0.045)).fill()
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
    // Outfit: the look's parts, drawn by name in the job's colour. Unknown
    // names are ignored, so the table can name parts before they are drawn.
    if let c = jobColor, !look.isEmpty {
        // On light flavours every part gets a soft dark halo, so a white
        // lab coat still shows on a white mochi.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if light {
            let halo = NSShadow()
            halo.shadowColor = shade.withAlphaComponent(0.85)
            halo.shadowBlurRadius = max(1, w * 0.025)
            halo.shadowOffset = .zero
            halo.set()
        }
        let head = pt(0.5, 0.47)
        let dark = NSColor(calibratedWhite: 0.12, alpha: 1)
        let tan = NSColor(calibratedRed: 0.85, green: 0.72, blue: 0.5, alpha: 1)
        func rr(_ b: NSRect, _ rad: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: b, xRadius: rad, yRadius: rad).fill()
        }
        func oval(_ b: NSRect, _ color: NSColor) {
            color.setFill()
            NSBezierPath(ovalIn: b).fill()
        }
        func line(_ a: NSPoint, _ b: NSPoint, _ width: CGFloat, _ color: NSColor) {
            color.setStroke()
            let p = NSBezierPath()
            p.lineWidth = width
            p.lineCapStyle = .round
            p.move(to: a); p.line(to: b)
            p.stroke()
        }
        func poly(_ pts: [NSPoint], _ color: NSColor) {
            color.setFill()
            let p = NSBezierPath()
            for (i, q) in pts.enumerated() { i == 0 ? p.move(to: q) : p.line(to: q) }
            p.close()
            p.fill()
        }
        for part in look {
            switch part {
            // ---- on the head
            case "hood": arch(head, w * 0.47, 5, 175, width: w * 0.14, c)
            case "cap":
                rr(box(0.2, -0.02, 0.6, 0.24), w * 0.2, c)
                rr(box(0.46, 0.17, 0.5, 0.06), h * 0.03, c)
            case "beret":
                oval(box(0.08, 0.0, 0.62, 0.2), c)
                oval(box(0.37, -0.06, 0.06, 0.09), c)
            case "hardhat":
                oval(box(0.17, -0.03, 0.66, 0.3), c)
                rr(box(0.09, 0.2, 0.82, 0.065), h * 0.03, c)
                rr(box(0.44, 0.0, 0.12, 0.2), w * 0.04, NSColor.white.withAlphaComponent(0.35))
            case "toque":
                rr(box(0.26, -0.3, 0.48, 0.4), w * 0.1, cream)
                oval(box(0.2, -0.36, 0.6, 0.2), cream)
                rr(box(0.24, 0.05, 0.52, 0.08), h * 0.02, cream)
            case "headphones":
                arch(head, w * 0.49, 15, 165, width: w * 0.06, c)
                rr(box(-0.04, 0.35, 0.16, 0.24), w * 0.04, c)
                rr(box(0.88, 0.35, 0.16, 0.24), w * 0.04, c)
            case "headband": rr(box(0.05, 0.19, 0.9, 0.09), h * 0.045, c)
            case "mortarboard":
                rr(box(0.28, 0.12, 0.44, 0.1), w * 0.03, c)
                poly([pt(0.08, 0.1), pt(0.5, -0.04), pt(0.92, 0.1), pt(0.5, 0.24)], NSColor(calibratedWhite: 0.4, alpha: 1))
                line(pt(0.5, 0.1), pt(0.84, 0.3), w * 0.025, c)
                oval(box(0.8, 0.27, 0.08, 0.08), c)
            case "visor": rr(box(0.06, 0.15, 0.88, 0.1), h * 0.05, c.withAlphaComponent(0.6))
            case "strawhat":
                oval(box(-0.1, 0.08, 1.2, 0.14), tan)
                rr(box(0.2, -0.12, 0.6, 0.26), w * 0.08, tan)
                rr(box(0.2, 0.06, 0.6, 0.05), 0, c)
            // ---- on the face
            case "glasses":
                c.setStroke()
                for fx in [CGFloat(0.28), CGFloat(0.55)] {
                    let g = NSBezierPath(ovalIn: box(fx - 0.03, 0.29, 0.23, 0.28))
                    g.lineWidth = w * 0.035
                    g.stroke()
                }
                line(pt(0.48, 0.43), pt(0.52, 0.43), w * 0.035, c)
            case "goggles":
                for fx in [CGFloat(0.25), CGFloat(0.53)] {
                    rr(box(fx, 0.3, 0.22, 0.26), w * 0.05, c.withAlphaComponent(0.35))
                    c.setStroke()
                    let g = NSBezierPath(roundedRect: box(fx, 0.3, 0.22, 0.26), xRadius: w * 0.05, yRadius: w * 0.05)
                    g.lineWidth = w * 0.03
                    g.stroke()
                }
                rr(box(0.0, 0.38, 0.26, 0.05), 0, c)
                rr(box(0.74, 0.38, 0.26, 0.05), 0, c)
            case "sunglasses":
                rr(box(0.24, 0.31, 0.24, 0.2), w * 0.05, dark)
                rr(box(0.52, 0.31, 0.24, 0.2), w * 0.05, dark)
                line(pt(0.48, 0.38), pt(0.52, 0.38), w * 0.03, dark)
            // ---- at the neck and on the body
            case "tie":
                poly([pt(0.45, 0.66), pt(0.55, 0.66), pt(0.58, 0.9), pt(0.5, 0.97), pt(0.42, 0.9)], c)
                rr(box(0.455, 0.69, 0.09, 0.03), 0, cream)
            case "scarf":
                rr(box(0.18, 0.62, 0.64, 0.11), h * 0.05, c)
                rr(box(0.56, 0.7, 0.16, 0.22), h * 0.04, c)
            case "labcoat":
                poly([pt(0.2, 0.62), pt(0.44, 0.62), pt(0.28, 0.98), pt(0.12, 0.98)], cream)
                poly([pt(0.8, 0.62), pt(0.56, 0.62), pt(0.72, 0.98), pt(0.88, 0.98)], cream)
                line(pt(0.44, 0.62), pt(0.5, 0.74), w * 0.02, ink2)
                line(pt(0.56, 0.62), pt(0.5, 0.74), w * 0.02, ink2)
            case "apron":
                rr(box(0.3, 0.64, 0.4, 0.34), w * 0.04, cream)
                line(pt(0.32, 0.64), pt(0.26, 0.5), w * 0.02, cream)
                line(pt(0.68, 0.64), pt(0.74, 0.5), w * 0.02, cream)
                rr(box(0.36, 0.78, 0.28, 0.12), w * 0.02, c.withAlphaComponent(0.6))
            case "vest":
                rr(box(0.1, 0.64, 0.8, 0.16), h * 0.02, NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1))
                rr(box(0.1, 0.7, 0.8, 0.035), 0, NSColor(calibratedWhite: 0.85, alpha: 1))
            case "stethoscope":
                arch(pt(0.5, 0.74), w * 0.3, 190, 350, width: w * 0.035, dark)
                line(pt(0.8, 0.74), pt(0.9, 0.86), w * 0.035, dark)
                oval(box(0.84, 0.84, 0.12, 0.1), c)
            case "badge":
                rr(box(0.6, 0.66, 0.16, 0.18), w * 0.02, cream)
                rr(box(0.6, 0.66, 0.16, 0.05), 0, c)
            // ---- in a hand: right side (x ≥ 0.7) or left (x ≤ 0.3)
            case "pin":
                rr(box(0.31, 0.74, 0.38, 0.15), h * 0.075, c)
                put(text("</>", size: h * 0.1, weight: .bold, color: .white, mono: true), r.minX + w * 0.5, ty(0.755, size: h * 0.1), align: 1)
            case "magnifier":
                let lens = box(0.74, 0.4, 0.3, 0.3)
                oval(lens, NSColor.white.withAlphaComponent(0.25))
                c.setStroke()
                let ring = NSBezierPath(ovalIn: lens)
                ring.lineWidth = w * 0.05
                ring.stroke()
                line(pt(0.98, 0.67), pt(1.1, 0.84), w * 0.07, c)
            case "chart":
                rr(box(0.7, 0.6, 0.38, 0.36), w * 0.04, cream)
                for (i, bh) in [0.1, 0.2, 0.15].enumerated() {
                    rr(box(0.75 + CGFloat(i) * 0.1, 0.9 - CGFloat(bh), 0.07, CGFloat(bh)), 0, c)
                }
            case "shield":
                poly([pt(0.74, 0.5), pt(1.06, 0.5), pt(1.06, 0.72), pt(0.9, 0.9), pt(0.74, 0.72)], c)
                line(pt(0.84, 0.7), pt(0.89, 0.77), w * 0.035, cream)
                line(pt(0.89, 0.77), pt(0.98, 0.62), w * 0.035, cream)
            case "calculator":
                rr(box(0.74, 0.6, 0.28, 0.36), w * 0.03, cream)
                rr(box(0.78, 0.63, 0.2, 0.08), 0, c.withAlphaComponent(0.5))
                for i in 0..<6 { rr(box(0.78 + CGFloat(i % 3) * 0.07, 0.75 + CGFloat(i / 3) * 0.09, 0.05, 0.06), 0, c) }
            case "briefcase":
                rr(box(0.74, 0.66, 0.34, 0.26), w * 0.03, c)
                rr(box(0.85, 0.6, 0.12, 0.08), w * 0.02, c)
                rr(box(0.74, 0.76, 0.34, 0.03), 0, cream.withAlphaComponent(0.6))
            case "clipboard":
                rr(box(-0.06, 0.56, 0.3, 0.4), w * 0.02, tan)
                rr(box(-0.03, 0.6, 0.24, 0.33), 0, cream)
                rr(box(0.03, 0.53, 0.12, 0.07), w * 0.02, dark)
                for k in 0..<3 { rr(box(0.0, 0.66 + CGFloat(k) * 0.07, 0.18, 0.025), 0, c) }
            case "phone":
                rr(box(0.78, 0.6, 0.18, 0.3), w * 0.03, dark)
                rr(box(0.8, 0.63, 0.14, 0.24), w * 0.015, c.withAlphaComponent(0.7))
            case "house":
                rr(box(0.76, 0.72, 0.3, 0.24), 0, cream)
                poly([pt(0.72, 0.72), pt(0.91, 0.52), pt(1.1, 0.72)], c)
                rr(box(0.86, 0.82, 0.1, 0.14), 0, c)
            case "globe":
                oval(box(0.74, 0.58, 0.32, 0.32), NSColor(calibratedRed: 0.4, green: 0.65, blue: 0.9, alpha: 1))
                oval(box(0.78, 0.64, 0.12, 0.1), c)
                oval(box(0.9, 0.72, 0.1, 0.12), c)
            case "pencil":
                let c0 = pt(0.84, 0.12)
                c.setFill()
                turned(c0, w * 0.34, w * 0.075, 35).fill()
                cream.setFill()
                let a: CGFloat = 35 * .pi / 180 * (flipped ? 1 : -1)
                turned(NSPoint(x: c0.x + cos(a) * w * 0.13, y: c0.y + sin(a) * w * 0.13), w * 0.07, w * 0.075, 35).fill()
            case "brush":
                let c0 = pt(0.9, 0.62)
                tan.setFill()
                turned(c0, w * 0.08, w * 0.34, -20).fill()
                c.setFill()
                let a: CGFloat = -110 * .pi / 180 * (flipped ? 1 : -1)
                turned(NSPoint(x: c0.x + cos(a) * w * 0.17, y: c0.y + sin(a) * w * 0.17), w * 0.1, w * 0.1, -20).fill()
            case "frame":
                rr(box(0.74, 0.58, 0.34, 0.3), 0, tan)
                rr(box(0.78, 0.62, 0.26, 0.22), 0, c.withAlphaComponent(0.5))
            case "camera":
                rr(box(0.72, 0.62, 0.36, 0.26), w * 0.03, NSColor(calibratedWhite: 0.5, alpha: 1))
                oval(box(0.82, 0.64, 0.18, 0.22), c)
                oval(box(0.86, 0.69, 0.1, 0.12), dark)
                rr(box(0.76, 0.58, 0.1, 0.05), 0, NSColor(calibratedWhite: 0.5, alpha: 1))
            case "ruler":
                let c0 = pt(0.9, 0.7)
                NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1).setFill()
                turned(c0, w * 0.4, w * 0.09, 60).fill()
            case "guitar":
                oval(box(-0.12, 0.62, 0.3, 0.3), c)
                oval(box(-0.02, 0.5, 0.22, 0.22), c)
                oval(box(0.0, 0.7, 0.08, 0.08), dark)
                line(pt(0.1, 0.5), pt(0.3, 0.08), w * 0.04, tan)
            case "tape":
                oval(box(0.76, 0.66, 0.26, 0.26), NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1))
                oval(box(0.84, 0.74, 0.1, 0.1), dark)
                rr(box(1.0, 0.76, 0.1, 0.05), 0, cream)
            case "scissors":
                line(pt(0.76, 0.56), pt(1.0, 0.84), w * 0.035, c)
                line(pt(1.0, 0.56), pt(0.76, 0.84), w * 0.035, c)
                oval(box(0.7, 0.82, 0.1, 0.1), c)
                oval(box(0.96, 0.82, 0.1, 0.1), c)
            case "comb":
                rr(box(-0.08, 0.62, 0.26, 0.08), w * 0.02, c)
                for k in 0..<5 { rr(box(-0.06 + CGFloat(k) * 0.05, 0.7, 0.025, 0.12), 0, c) }
            case "apple":
                oval(box(0.76, 0.62, 0.28, 0.28), NSColor(calibratedRed: 0.86, green: 0.25, blue: 0.25, alpha: 1))
                oval(box(0.88, 0.56, 0.1, 0.08), c)
            case "pill":
                rr(box(0.74, 0.7, 0.3, 0.14), h * 0.07, cream)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: box(0.74, 0.7, 0.15, 0.14)).addClip()
                rr(box(0.74, 0.7, 0.3, 0.14), h * 0.07, c)
                NSGraphicsContext.restoreGraphicsState()
            case "papers":
                for k in 0..<3 { rr(box(-0.08 + CGFloat(k) * 0.03, 0.6 - CGFloat(k) * 0.03, 0.28, 0.34), w * 0.015, k == 2 ? cream : cream.withAlphaComponent(0.7)) }
                for k in 0..<3 { rr(box(0.02, 0.6 + CGFloat(k) * 0.07, 0.18, 0.025), 0, c) }
            case "bubble":
                rr(box(0.7, -0.14, 0.44, 0.26), h * 0.08, cream)
                poly([pt(0.78, 0.1), pt(0.88, 0.1), pt(0.76, 0.22)], cream)
                put(text("文A", size: h * 0.12, weight: .bold, color: c), r.minX + w * 0.92, ty(-0.09, size: h * 0.12), align: 1)
            case "notebook":
                rr(box(0.74, 0.62, 0.3, 0.32), w * 0.02, c)
                rr(box(0.78, 0.66, 0.22, 0.24), 0, cream)
                for k in 0..<3 { rr(box(0.81, 0.7 + CGFloat(k) * 0.06, 0.16, 0.02), 0, ink2) }
            case "bone":
                rr(box(0.78, 0.74, 0.24, 0.06), h * 0.03, cream)
                for fx in [CGFloat(0.74), CGFloat(0.96)] {
                    oval(box(fx, 0.69, 0.1, 0.08), cream)
                    oval(box(fx, 0.77, 0.1, 0.08), cream)
                }
            case "dumbbell":
                rr(box(0.72, 0.72, 0.38, 0.05), 0, steel)
                rr(box(0.7, 0.64, 0.08, 0.2), w * 0.015, c)
                rr(box(1.04, 0.64, 0.08, 0.2), w * 0.015, c)
            case "pan":
                oval(box(0.72, 0.74, 0.34, 0.16), NSColor(calibratedWhite: 0.5, alpha: 1))
                oval(box(0.76, 0.76, 0.26, 0.1), NSColor(calibratedWhite: 0.33, alpha: 1))
                line(pt(1.04, 0.82), pt(1.2, 0.76), w * 0.04, steel)
            case "book":
                rr(box(-0.1, 0.62, 0.3, 0.3), w * 0.02, c)
                rr(box(-0.06, 0.65, 0.22, 0.24), 0, cream)
            case "gavel":
                let c0 = pt(0.9, 0.56)
                tan.setFill()
                turned(c0, w * 0.3, w * 0.12, -30).fill()
                line(pt(0.9, 0.6), pt(1.0, 0.88), w * 0.05, tan)
            case "flask":
                poly([pt(0.82, 0.56), pt(0.94, 0.56), pt(0.94, 0.68), pt(1.08, 0.92), pt(0.68, 0.92), pt(0.82, 0.68)], cream.withAlphaComponent(0.85))
                poly([pt(0.76, 0.8), pt(1.0, 0.8), pt(1.08, 0.92), pt(0.68, 0.92)], c)
            case "leaf":
                let leaf = NSBezierPath(ovalIn: NSRect(x: -w * 0.07, y: -w * 0.16, width: w * 0.14, height: w * 0.32))
                leaf.transform(using: AffineTransform(rotationByDegrees: flipped ? 30 : -30))
                let q = pt(0.9, 0.72)
                leaf.transform(using: AffineTransform(translationByX: q.x, byY: q.y))
                c.setFill()
                leaf.fill()
            case "atom":
                oval(box(0.84, 0.54, 0.1, 0.1), c)
                c.setStroke()
                for deg in [0.0, 60.0, 120.0] {
                    let o = NSBezierPath(ovalIn: NSRect(x: -w * 0.18, y: -w * 0.07, width: w * 0.36, height: w * 0.14))
                    o.transform(using: AffineTransform(rotationByDegrees: deg))
                    let q = pt(0.89, 0.59)
                    o.transform(using: AffineTransform(translationByX: q.x, byY: q.y))
                    o.lineWidth = w * 0.025
                    o.stroke()
                }
            case "blueprint":
                rr(box(0.74, 0.68, 0.36, 0.14), h * 0.07, NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.85, alpha: 1))
                oval(box(1.04, 0.68, 0.1, 0.14), cream)
            case "gear":
                let q = pt(0.9, 0.72)
                for k in 0..<8 {
                    let a = CGFloat(k) * .pi / 4
                    rr(NSRect(x: q.x + cos(a) * w * 0.13 - w * 0.035, y: q.y + sin(a) * w * 0.13 - w * 0.035, width: w * 0.07, height: w * 0.07), w * 0.01, c)
                }
                oval(NSRect(x: q.x - w * 0.12, y: q.y - w * 0.12, width: w * 0.24, height: w * 0.24), c)
                oval(NSRect(x: q.x - w * 0.05, y: q.y - w * 0.05, width: w * 0.1, height: w * 0.1), skin)
            case "circuit":
                rr(box(0.72, 0.62, 0.36, 0.3), w * 0.02, NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.3, alpha: 1))
                for k in 0..<3 { line(pt(0.76, 0.68 + CGFloat(k) * 0.08), pt(1.04, 0.68 + CGFloat(k) * 0.08), w * 0.02, c) }
                rr(box(0.84, 0.7, 0.12, 0.12), 0, dark)
            case "bolt":
                poly([pt(0.92, 0.3), pt(0.8, 0.56), pt(0.9, 0.56), pt(0.82, 0.8), pt(1.02, 0.5), pt(0.92, 0.5), pt(1.0, 0.3)], c)
            case "hammer":
                line(pt(0.9, 0.9), pt(1.0, 0.56), w * 0.05, tan)
                rr(box(0.88, 0.48, 0.24, 0.12), w * 0.02, dark)
            case "wrench":
                let c0 = pt(0.94, 0.74)
                c.setFill()
                turned(c0, w * 0.36, w * 0.08, 50).fill()
                let a: CGFloat = 50 * .pi / 180 * (flipped ? 1 : -1)
                let tip = NSPoint(x: c0.x + cos(a) * w * 0.2, y: c0.y + sin(a) * w * 0.2)
                oval(NSRect(x: tip.x - w * 0.09, y: tip.y - w * 0.09, width: w * 0.18, height: w * 0.18), c)
                oval(NSRect(x: tip.x - w * 0.04, y: tip.y - w * 0.04, width: w * 0.08, height: w * 0.08), skin)
            case "pipe":
                rr(box(0.74, 0.74, 0.3, 0.09), 0, c)
                rr(box(0.98, 0.56, 0.09, 0.27), 0, c)
                rr(box(0.96, 0.54, 0.13, 0.05), 0, c)
            case "can":
                rr(box(0.74, 0.66, 0.26, 0.22), w * 0.03, c)
                poly([pt(0.98, 0.72), pt(1.14, 0.62), pt(1.14, 0.66), pt(1.0, 0.78)], c)
                arch(pt(0.87, 0.66), w * 0.1, 0, 180, width: w * 0.025, c)
            case "teddy":
                oval(box(-0.1, 0.68, 0.26, 0.26), tan)
                oval(box(-0.04, 0.56, 0.16, 0.16), tan)
                oval(box(-0.08, 0.52, 0.07, 0.07), tan)
                oval(box(0.09, 0.52, 0.07, 0.07), tan)
                oval(box(0.0, 0.6, 0.03, 0.03), dark)
                oval(box(0.05, 0.6, 0.03, 0.03), dark)
            default:
                break
            }
        }
    }
    // Mood extras
    switch mood {
    case "sleepy":
        let zc = light ? shade : skin
        put(text("z", size: h * 0.18, weight: .bold, color: zc), r.minX + w * 0.86, ty(-0.1, size: h * 0.18), align: 1)
        put(text("z", size: h * 0.12, weight: .bold, color: zc), r.minX + w * 1.0, ty(-0.18, size: h * 0.12), align: 1)
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
    case "waiting" where !look.contains(where: { handProps.contains($0) }):
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
        NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
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
        put(text(L("打工团子", "Dango"), size: 22, weight: .semibold, color: ink2.withAlphaComponent(0.6)), W - pad, 68, align: 2)
        let top = r.l("jobs").first
        drawCharacter(NSRect(x: pad, y: 130, width: 150, height: 150), mood: ch.s("mood"),
                      look: top?["look"] as? [String] ?? [], jobColor: (top?["color"] as? String).map { color(hex: $0) }, flavor: petFlavor)
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
        title(L("都当了谁", "Who you hired"), y, right: all.isEmpty ? nil : L("\(all.count) 种工作", "\(all.count) jobs"))
        y += 42
        let shown = Array(all.prefix(6))
        let maxU = max(shown.map { ($0["usd"] as? Double) ?? 0 }.max() ?? 1, 0.1)
        // The bars start after the longest name (English names run longer).
        let nameW = min(270, max(150, (shown.map { text(($0["name"] as? String) ?? "", size: 26, weight: .semibold).size().width }.max() ?? 0) + 20))
        for c in shown {
            let cr = Report(j: c)
            put(text(cr.s("name"), size: 26, weight: .semibold, color: ink), pad, y)
            let br = NSRect(x: pad + nameW, y: y + 10, width: inner - nameW - 300, height: 16)
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
            put(text(L("还有 \(all.count - shown.count) 种 · \(fmtUSD(rest))", "\(all.count - shown.count) more · \(fmtUSD(rest))"), size: 22, color: ink2), pad, y)
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
        put(text(beating ? L("今天就是单日纪录 ✦", "New best day ✦") : L("单日纪录 ", "Best day ") + fmtUSD(best), size: 26, weight: .semibold, color: tone), pad, y)
        let before = Report(j: r.o("prev"))
        let label = before.s("label")
        var right = (label.isEmpty || label == "昨天" || label == "Yesterday" ? L("比昨天 ", "vs yesterday ") : L("比 \(label) ", "vs \(label) ")) + delta(today - before.d("usd"))
        if r.i("streak") > 1 { right += L(" · 连续 \(r.i("streak")) 天", " · \(r.i("streak"))-day streak") }
        put(text(right, size: 24, color: ink2, mono: true), W - pad, y + 2, align: 2)
        let track = NSRect(x: pad, y: y + 46, width: inner, height: 12)
        paper2.setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
        tone.setFill()
        let f = best > 0 ? min(1, today / best) : 0
        NSBezierPath(roundedRect: NSRect(x: pad, y: y + 46, width: max(12, inner * CGFloat(f)), height: 12), xRadius: 6, yRadius: 6).fill()
        put(text(standingLine(r), size: 22, color: ink2), pad, y + 72)
        return y + 118
    }

    /// Against your own history and in full-time people: "超过你 95% 的日子
    /// · 相当于 4.3 个人全职干一天".
    func standingLine(_ r: Report) -> String {
        let s = Report(j: r.o("standing")), p = Report(j: r.o("people"))
        let unit = s.s("unit").isEmpty ? r.s("kind") : s.s("unit")
        let (zhUnit, zhOne, enUnit) = ["week": ("周", "一周", "week"), "month": ("个月", "一个月", "month"), "year": ("年", "一年", "year")][unit] ?? ("天", "一天", "day")
        let (count, rank) = (s.i("count"), s.i("rank"))
        var parts: [String] = []
        if count <= 1 {
            parts.append(L("这是你的第一\(zhUnit)", "Your first \(enUnit)"))
        } else if rank == 1 {
            parts.append(L("你最好的\(zhOne)（共 \(count) \(zhUnit)）", "Your best \(enUnit) of \(count)"))
        } else if unit == "day", let beats = s.j["beats"] as? Double {
            let pct = Int((beats * 100).rounded())
            parts.append(L("超过你 \(pct)% 的日子", "Better than \(pct)% of your days"))
        } else {
            parts.append(L("你第 \(rank) 好的\(zhOne)（共 \(count) \(zhUnit)）", "Your #\(rank) \(enUnit) of \(count)"))
        }
        let n = p.d("people")
        if n > 0 {
            let x = n >= 10 ? "\(Int(n.rounded()))" : (n == n.rounded() ? "\(Int(n))" : String(format: "%.1f", n))
            parts.append(L("相当于 \(x) 个人全职干\(zhOne)", "≈ \(x) full-time people for a \(enUnit)"))
        }
        return parts.joined(separator: " · ")
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
        let name = r.s("now_label").isEmpty ? (r.s("kind") == "week" ? L("本周", "This week") : L("本月", "This month")) : r.s("now_label")
        put(text("\(name) \(fmtUSD(now))", size: 28, weight: .bold, color: ink), x, y + 8)
        let d = now - before
        var s = delta(d)
        if before > 0 { s += String(format: " · %@%.0f%%", d >= 0 ? "+" : "−", abs(d / before * 100)) }
        put(text(s, size: 28, weight: .semibold, color: d >= 0 ? ink : ink2, mono: true), W - pad, y + 8, align: 2)
        put(text(standingLine(r), size: 22, color: ink2), pad, y + 52)
        return y + 96
    }

    func signoff(_ r: Report, _ y: CGFloat) -> CGFloat {
        contentBottom = y + 96
        let ch = Report(j: r.o("character"))
        let bubble = NSRect(x: pad, y: y, width: inner, height: 96)
        NSColor.white.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 20, yRadius: 20).fill()
        put(text(L("「\(ch.s("signoff"))」", "“\(ch.s("signoff"))”"), size: 30, weight: .medium, color: ink), pad + 28, y + 20)
        put(text("— \(ch.s("name"))", size: 22, color: ink2), W - pad - 28, y + 58, align: 2)
        return y + 96
    }

    func footer(_ r: Report) {
        let foot = (r.o("rates")["label"] as? String) ?? ""
        put(text(foot + L(" · 不含福利 · 模型花费按官方 API 价", " · wages only · model cost at official API prices"), size: 20, color: ink2.withAlphaComponent(0.7)), pad, bounds.height - 58)
    }

    func leverageText(_ r: Report) -> String { fmtLev(r.d("usd"), r.d("cost")) }
}

/// Day card, 1080 × 1350.
final class DayCardView: CardView {
    override func draw(_ dirtyRect: NSRect) {
        guard let r = report else { return }
        var y = header(r)
        title(L("时间线", "Timeline"), y)
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
        y = sessions(r, y, empty: L("今天没有回合", "No turns this day"))
        y = jobs(r, y)
        y = tiles([(L("回合", "Turns"), "\(r.i("turns"))"), (L("改动文件", "Files changed"), "\(r.i("files"))"),
                   (L("测试通过", "Tests passed"), "\(r.i("tests_passed"))/\(r.i("tests_run"))"), (L("一次过", "First try"), "\(r.i("clean_turns"))/\(r.i("turns"))")], y)
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
        title(L("每天", "Each day"), y, right: L("活跃 \(r.i("active_days"))/7 天", "active \(r.i("active_days"))/7 days"))
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
        title(L("花时间最多的事", "Where the time went"), y)
        y += 42
        y = sessions(r, y, empty: L("这周没有回合", "No turns this week"))
        y = tiles([(L("活跃天数", "Active days"), "\(r.i("active_days"))/7"), (L("回合", "Turns"), "\(r.i("turns"))"),
                   (L("测试通过", "Tests passed"), "\(r.i("tests_passed"))/\(r.i("tests_run"))"), (L("杠杆", "Leverage"), leverageText(r))], y)
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
        title(L("日历", "Calendar"), y, right: L("活跃 \(r.i("active_days")) 天 · 最长连续 \(r.i("longest_run")) 天", "active \(r.i("active_days")) days · longest run \(r.i("longest_run"))"))
        y += 46
        let gap: CGFloat = 8
        let cw = (inner - gap * 6) / 7
        let chH: CGFloat = 56
        for (i, w) in (lang == "en" ? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] : ["一", "二", "三", "四", "五", "六", "日"]).enumerated() {
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
            // Days before tracking began are blank, not idle.
            let untracked = dr.j["untracked"] as? Bool ?? false
            var fill = paper2
            var label = ink2
            if usd > 0 {
                // One hue, light → dark by dollars (square-rooted so small days still show).
                let f = sqrt(min(1, usd / maxU))
                fill = NSColor(calibratedRed: light.0 + (dark.0 - light.0) * f, green: light.1 + (dark.1 - light.1) * f,
                               blue: light.2 + (dark.2 - light.2) * f, alpha: 1)
                label = f > 0.55 ? NSColor.white : ink
            } else if future || untracked {
                fill = paper2.withAlphaComponent(untracked ? 0.3 : 0.45)
            }
            fill.setFill()
            NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10).fill()
            if dr.j["first_tracked"] as? Bool ?? false {
                put(text(L("开始记录", "Started"), size: 14, weight: .medium, color: ink2.withAlphaComponent(0.8)), cell.minX + 10, cell.maxY - 22)
            }
            if dr.j["today"] as? Bool ?? false {
                ink.setStroke()
                let o = NSBezierPath(roundedRect: cell.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
                o.lineWidth = 3
                o.stroke()
            }
            put(text("\(dr.i("day"))", size: 18, color: label.withAlphaComponent(future || untracked ? 0.4 : 0.8), mono: true), cell.minX + 10, cell.minY + 6)
            if usd > 0 {
                put(text(fmtUSD(usd), size: 18, weight: .semibold, color: label, mono: true), cell.maxX - 10, cell.maxY - 26, align: 2)
            }
        }
        y += CGFloat(rows) * (chH + gap) + 30

        // When the work happens.
        title(L("你的作息", "Your hours"), y, right: (r.j["peak_window"] as? String).map { L("最常在 \($0)开工", "usually starts \($0)") })
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
        title(L("花时间最多的事", "Where the time went"), y)
        y += 42
        y = sessions(r, y, empty: L("这个月没有回合", "No turns this month"))
        y = compare(r, y)
        _ = signoff(r, y + 10)
        footer(r)
    }
}

/// "$9,235" under ten thousand, "$12.6k" above: month labels stay narrow.
func fmtK(_ usd: Double) -> String {
    usd >= 10_000 ? String(format: "$%.1fk", usd / 1000) : fmtUSD(usd)
}

/// Year card, 1080 × up to 1920: the twelve months stacked by occupation,
/// every day of the year as a heatmap, the year against the one before.
final class YearCardView: CardView {
    override func draw(_ dirtyRect: NSRect) {
        guard let r = report else { return }
        var y = header(r)
        let months = r.l("months")
        let best = r.j["best_month"] as? Int
        title(L("每个月", "Each month"), y, right: best.map { L("最好的是 \($0 + 1) 月", "best: " + DateFormatter().monthSymbols[$0]) })
        y += 48
        let chart = NSRect(x: pad, y: y, width: inner, height: 270)
        let base = chart.maxY - 40, top = chart.minY + 36
        let maxU = max(months.map { ($0["usd"] as? Double) ?? 0 }.max() ?? 0, 1)
        let slot = inner / 12
        let bw = slot - 22
        paper2.setFill()
        NSBezierPath(rect: NSRect(x: chart.minX, y: base, width: inner, height: 2)).fill()
        for (i, m) in months.enumerated() {
            let mr = Report(j: m)
            let cx = chart.minX + slot * CGFloat(i) + slot / 2
            var yTop = base
            for part in mr.l("parts") {
                let h = CGFloat((part["usd"] as? Double ?? 0) / maxU) * (base - top)
                guard h > 0.5 else { continue }
                color(hex: part["color"] as? String ?? "").setFill()
                NSBezierPath(roundedRect: NSRect(x: cx - bw / 2, y: yTop - h, width: bw, height: max(h - 3, 2)), xRadius: 6, yRadius: 6).fill()
                yTop -= h
            }
            if mr.d("usd") > 0 {
                put(text(fmtK(mr.d("usd")), size: 19, weight: best == i ? .bold : .regular, color: best == i ? ink : ink2, mono: true), cx, yTop - 30, align: 1)
            }
            let current = mr.j["current"] as? Bool ?? false, future = mr.j["future"] as? Bool ?? false
            put(text(mr.s("label"), size: 22, weight: current ? .bold : .regular, color: current ? ink : ink2.withAlphaComponent(future ? 0.4 : 1)), cx, base + 10, align: 1)
        }
        y = chart.maxY + 26

        // Every day, a column per week from the first Monday on or before 1 January.
        title(L("全年", "The year"), y, right: L("活跃 \(r.i("active_days")) 天 · 最长连续 \(r.i("longest_run")) 天", "active \(r.i("active_days")) days · longest run \(r.i("longest_run"))"))
        y += 46
        let heat = (r.j["heat"] as? [Double]) ?? []
        let first = r.i("first_weekday")
        let todayIndex = r.j["today_index"] as? Int
        let firstIndex = r.j["first_index"] as? Int
        let cols = (first + heat.count + 6) / 7
        let gap: CGFloat = 3
        let cw = (inner - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let maxH = max(heat.max() ?? 0, 1)
        let light = (0.85, 0.92, 0.89), dark = (0.24, 0.42, 0.37)
        // Month names over the first week that starts in the month.
        var dayOfYear = 0
        let year = Int(r.s("date")) ?? 2026
        for mth in 1...12 {
            let col = (first + dayOfYear + 6) / 7
            put(text(lang == "en" ? ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][mth - 1] : "\(mth)月", size: 17, color: ink2), pad + CGFloat(col) * (cw + gap), y, align: 0)
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            dayOfYear += [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mth - 1]
        }
        y += 28
        for (k, usd) in heat.enumerated() {
            let slotIndex = first + k
            let cell = NSRect(x: pad + CGFloat(slotIndex / 7) * (cw + gap), y: y + CGFloat(slotIndex % 7) * (cw + gap), width: cw, height: cw)
            var fill = paper2
            if usd > 0 {
                let f = sqrt(min(1, usd / maxH))
                fill = NSColor(calibratedRed: light.0 + (dark.0 - light.0) * f, green: light.1 + (dark.1 - light.1) * f, blue: light.2 + (dark.2 - light.2) * f, alpha: 1)
            } else if let ti = todayIndex, k > ti {
                fill = paper2.withAlphaComponent(0.45)
            } else if let fi = firstIndex, k < fi {
                fill = paper2.withAlphaComponent(0.3)
            }
            fill.setFill()
            NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3).fill()
            if k == todayIndex {
                ink.setStroke()
                let o = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                o.lineWidth = 2
                o.stroke()
            }
        }
        y += 7 * (cw + gap) + 12
        // Legend: less → more.
        let legend = text(L("多", "More"), size: 17, color: ink2)
        var lx = W - pad - legend.size().width
        put(legend, lx, y)
        for f in [1.0, 0.7, 0.45, 0.2] {
            lx -= 22
            NSColor(calibratedRed: light.0 + (dark.0 - light.0) * f, green: light.1 + (dark.1 - light.1) * f, blue: light.2 + (dark.2 - light.2) * f, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: y + 3, width: 16, height: 16), xRadius: 3, yRadius: 3).fill()
        }
        put(text(L("少", "Less"), size: 17, color: ink2), lx - 8, y, align: 2)
        if let bd = r.j["best_day"] as? [String: Any] {
            put(text(L("最好的一天 ", "Best day ") + "\(bd["date"] as? String ?? "") · \(fmtUSD((bd["usd"] as? Double) ?? 0))", size: 20, color: ink2, mono: true), pad, y)
        }
        y += 52
        y = jobs(r, y)
        y = tiles([(L("活跃天数", "Active days"), "\(r.i("active_days"))"), (L("回合", "Turns"), "\(r.i("turns"))"),
                   (L("测试通过", "Tests passed"), "\(r.i("tests_passed"))/\(r.i("tests_run"))"), (L("杠杆", "Leverage"), leverageText(r))], y)
        y = compare(r, y)
        _ = signoff(r, y + 10)
        footer(r)
    }
}

func renderCard(_ jsonPath: String, _ outPath: String, copy: Bool) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    let kind = j["kind"] as? String ?? "day"
    if let l = j["lang"] as? String { lang = l }
    let tall = NSSize(width: 1080, height: 2400)
    let v: CardView = kind == "week" ? WeekCardView(frame: NSRect(origin: .zero, size: tall))
        : kind == "month" ? MonthCardView(frame: NSRect(origin: .zero, size: tall))
        : kind == "year" ? YearCardView(frame: NSRect(origin: .zero, size: tall))
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
    petFlavorOverride = flagv("--flavor")
    if let n = flagv("--helpers").flatMap({ Int($0) }) { m.subagents = n }
    let v = PetView(frame: NSRect(origin: .zero, size: PetView.size))
    v.drawBackground = args.contains("--backdrop")
    v.model = m
    v.t = 0.9
    v.hovering = args.contains("--hover")
    if args.contains("--receipt") { v.receipts = [Receipt(usd: 78.4, name: m.job?.name ?? "软件工程师", color: m.job?.color ?? barColor, born: 0)] }
    snapshot(v, PetView.size, args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot-flavors"), args.count > i + 1 {
    // Every flavour (rows) in each mood and two outfits (columns), on the
    // widget's dark ground; --paper draws it on the cards' paper instead.
    _ = NSApplication.shared
    final class FlavorSheet: NSView {
        let onPaper: Bool
        init(onPaper: Bool) {
            self.onPaper = onPaper
            super.init(frame: NSRect(x: 0, y: 0, width: 130 + 8 * 96, height: CGFloat(flavors.count) * 100 + 30))
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            (onPaper ? paper : NSColor(calibratedWhite: 0.13, alpha: 1)).setFill()
            bounds.fill()
            let tone = onPaper ? ink2 : secondary
            let cols: [(String, [String], NSColor?)] = [("waiting", [], nil), ("focused", [], nil), ("happy", [], nil), ("proud", [], nil), ("sleepy", [], nil),
                ("idle", ["labcoat", "stethoscope"], color(hex: "#e35d6a")), ("idle", ["toque", "apron", "pan"], color(hex: "#d98a3a")), ("idle", ["hood"], color(hex: "#4a78c4"))]
            for (k, c) in cols.enumerated() {
                put(text(c.1.isEmpty ? c.0 : c.1[0], size: 10, color: tone), 130 + CGFloat(k) * 96 + 40, 8, align: 1)
            }
            for (row, f) in flavors.enumerated() {
                let y = 26 + CGFloat(row) * 100
                put(text("\(f.zh) \(f.en)", size: 11, weight: .medium, color: tone), 12, y + 36)
                for (k, c) in cols.enumerated() {
                    drawCharacter(NSRect(x: 130 + CGFloat(k) * 96 + 6, y: y + 6, width: 68, height: 68), mood: c.0, look: c.1, jobColor: c.2, flavor: f)
                }
            }
        }
    }
    let v = FlavorSheet(onPaper: args.contains("--paper"))
    snapshot(v, v.bounds.size, args[i + 1])
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

if let i = args.firstIndex(of: "--snapshot-office"), args.count > i + 1 {
    // [--jobs id,id,…] [--working K] [--walk SEC]: made-up staff, the first K
    // at work; --walk hands the work on to the next one and renders SEC later.
    _ = NSApplication.shared
    let m = loadModel() ?? Model()
    let flagv = { (f: String) -> String? in args.firstIndex(of: f).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let ids = flagv("--jobs")?.split(separator: ",").map(String.init) ?? m.occupations.prefix(5).map(\.id)
    let k = flagv("--working").flatMap { Int($0) } ?? 1
    let now = Date().timeIntervalSince1970 * 1000
    var staff = ids.enumerated().compactMap { n, id -> Occupant? in
        m.occupations.first { $0.id == id }.map {
            Occupant(job: $0, working: n < k, helpers: n == 0 ? 2 : 0, usd: Double(140 * (n + 1)), since: now - [1.0, 5, 40, 200, 70, 30, 90, 10][n % 8] * 60_000)
        }
    }
    let size = NSSize(width: dashboardWidth - 36, height: OfficeView.height)
    let v = OfficeView(frame: NSRect(origin: .zero, size: size))
    v.occupants = staff
    v.tick(0.9)
    v.hover(flagv("--hover"))
    if let sec = flagv("--walk").flatMap({ Double($0) }), let a = staff.firstIndex(where: \.working), staff.count > k {
        staff[a].working = false
        staff[a].since = now
        staff[k].working = true
        v.occupants = staff
        for _ in 0..<Int(sec * 24) { v.tick(1.0 / 24.0) }
    }
    snapshot(v, size, args[i + 1])
    exit(0)
}

// One instance at a time: a second launch (double-clicking the app again,
// `dango widget`) just exits while the first keeps the lock.
let lockFD = open(home + "/widget.lock", O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
