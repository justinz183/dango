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
import UserNotifications

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
/// The dashboard's width: the v3 themes' panel is 440.
let dashboardWidth: CGFloat = 440
/// The interface language ("zh" / "en"): from widget.json, or from a card's
/// report while it is drawn; remembered for the next launch.
var lang = UserDefaults.standard.string(forKey: "lang") ?? "zh"
/// The Chinese or the English text.
func L(_ zh: String, _ en: String) -> String { lang == "en" ? en : zh }

/// The dango the app carries (a packaged install, apps/widget/package.sh).
/// In Contents/Helpers: next to the app's own "Dango" in Contents/MacOS it
/// would be the same file, the disk not telling the two names apart.
let bundledCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dango").path

/// The dango command: the one the app carries, else wherever a developer
/// installed it (the old name still works).
func cliPath() -> String? {
    [bundledCLI, NSHomeDirectory() + "/.local/bin/dango", "/usr/local/bin/dango", "/opt/homebrew/bin/dango", NSHomeDirectory() + "/.local/bin/shadowcorp"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// The daemon's LaunchAgent (it records Claude Code and Codex in the
/// background, and imports the history on its first start).
let daemonLabel = "com.dango.daemon"
let daemonPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(daemonLabel).plist"

/// The LaunchAgent a packaged install writes: the dango it carries, run at
/// login, restarted if it dies, logging next to its data.
func daemonAgent(cli: String) -> Data? {
    let log = home + "/daemon.log"
    let plist: [String: Any] = [
        "Label": daemonLabel,
        "ProgramArguments": [cli, "daemon"],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "StandardOutPath": log,
        "StandardErrorPath": log,
    ]
    return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}
let originKey = "petOrigin"

/// A receipt's colour when the job brings none (snapshots).
let barColor = NSColor(red: 0.47, green: 0.72, blue: 0.65, alpha: 1)

struct DayPoint { var day = ""; var hours = 0.0; var usd = 0.0; var turns = 0 }
/// The occupation the agent is "being" right now, from activity.job.
struct Job { var id = ""; var name = ""; var color = NSColor.gray; var scene = "desk"; var look: [String] = [] }

/// Someone in the office: an occupation that worked this week.
struct Occupant {
    var job = Job()
    var working = false
    var helpers = 0
    /// Earned this week.
    var usd = 0.0
    /// Last worked at, unix ms.
    var since = 0.0
    /// An event-driven state from the daemon (waiting, fuming, happy) or a
    /// snapshot (--statuses), and when it began; else officeStatus decides.
    var status: String? = nil
    var statusSince = 0.0
}

struct JobShare { var id = ""; var name = ""; var hours = 0.0; var usd = 0.0; var rate = 0.0; var share = 0.0; var color = NSColor.gray }
struct TurnRow { var at = 0.0; var tool = ""; var name = ""; var hours = 0.0; var usd = 0.0; var color = NSColor.gray; var files = 0; var testPassed: Bool? }
/// Claude Code or Codex: what each agent's work would have cost.
struct ToolShare { var name = ""; var usd = 0.0; var hours = 0.0; var share = 0.0; var color = NSColor.gray; var cost = 0.0 }

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
}

/// Reads the dashboard numbers (tiles, 30 days, jobs, turns) from widget.json.
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
                 since: $0["since"] as? Double ?? 0, status: $0["status"] as? String, statusSince: $0["status_since"] as? Double ?? 0)
    }
    m.daysTogether = ch["days_together"] as? Int ?? 0
    if let jb = act["job"] as? [String: Any] { m.job = job(jb) }
    m.working = act["working"] as? Int ?? 0
    m.subagents = act["subagents"] as? Int ?? 0
    m.generatedAt = j["generated_at"] as? Double ?? 0
    m.tools = toolShares(list("tools"))
    m.tools7 = toolShares(list("tools_7d"))
    m.tools1 = toolShares(list("tools_1d"))
    return m
}

let intFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f
}()

func fmtUSD(_ x: Double) -> String {
    // A counter's float dust (−0.0, 1e-13) is no money: "$0.0", never "$-0.0".
    let x = abs(x) < 0.05 ? 0 : x
    if abs(x) < 10 { return String(format: "$%.1f", x) }
    return "$" + (intFormatter.string(from: NSNumber(value: x.rounded())) ?? "0")
}

/// "25 分钟" under an hour, "3.4h" / "3.4 小时" under a hundred, "123h" above.
func fmtHours(_ h: Double) -> String {
    if h < 1 { return "\(Int((h * 60).rounded())) " + L("分钟", "min") }
    if h < 100 { return String(format: "%.1f", h) + L(" 小时", "h") }
    return fmtInt(Int(h.rounded())) + L(" 小时", "h")
}

func fmtInt(_ n: Int) -> String {
    intFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}


/// Draws `s` at x with `align` 0 = left, 1 = centred, 2 = right.
func put(_ s: NSAttributedString, _ x: CGFloat, _ y: CGFloat, align: Int = 0) {
    let w = s.size().width
    s.draw(at: NSPoint(x: align == 0 ? x : align == 1 ? x - w / 2 : x - w, y: y))
}

// MARK: - Dashboard

/// The panel the pet opens into: the design handoff's layout (theme.swift
/// `layoutV3`), with the illustrated office on top.
final class DashboardView: NSView {
    var model: Model?
    /// Snapshots draw the panel's white back themselves.
    var drawBackground = false
    var onCollapse: (() -> Void)?
    /// The window the middle blocks cover: 1, 7 or 30 days.
    var range: Int = {
        let r = UserDefaults.standard.integer(forKey: "range")
        return [1, 7, 30].contains(r) ? r : 30
    }()
    /// The office, a subview so it can animate on its own.
    let officeV3 = V3OfficeView(frame: .zero)
    /// What can be clicked on the panel.
    var v3Hits: [(String, NSRect)] = []
    /// The staff roster shows everyone, not just the first six.
    var jobsOpen = false
    /// Called when the content changes height (the roster opening).
    var onResize: (() -> Void)?

    /// For snapshots: a window, and/or the roster open.
    func preset(jobsOpen: Bool, range: Int = 30) {
        self.jobsOpen = jobsOpen
        self.range = range
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Height the content needs at the current width.
    func contentHeight() -> CGFloat { layoutV3(draw: false) }

    override func draw(_ dirtyRect: NSRect) {
        _ = layoutV3(draw: true)
    }

    /// "2026-10-29" → "10/29".
    func shortDay(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3, let mo = Int(p[1]), let da = Int(p[2]) else { return d }
        return "\(mo)/\(da)"
    }

    override func mouseDown(with event: NSEvent) {
        v3MouseDown(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let app = NSApp.delegate as? App else { return }
        if let r = exportButton, r.contains(convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(app.exportButtonMenu(), with: event, for: self)
        } else {
            app.popMenu(event, in: self)
        }
    }
}

// MARK: - Drawing helpers

func strokeLine(_ a: NSPoint, _ b: NSPoint, _ width: CGFloat, _ c: NSColor) {
    c.setStroke()
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.move(to: a)
    p.line(to: b)
    p.stroke()
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

/// The desktop pet — the whole collapsed UI: a white card with the dango
/// dressed for the job at hand, today's dollars, a receipt for every
/// finished turn (theme.swift `drawCard`). Lives in a transparent panel;
/// only the card takes clicks.
final class PetView: NSView {
    static let size = NSSize(width: 230, height: 140)
    var model: Model?
    var drawBackground = false
    /// Seconds since launch, advanced by the app's frame timer.
    var t = 0.0
    var receipts: [Receipt] = []
    var flashText = ""
    var flashUntil = -1.0
    var onClick: (() -> Void)?
    /// A turn settled: the receipt is out (the app may also notify).
    var onSettle: ((TurnRow, Model) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var blinkAt = 3.0
    private var blinking = false
    private var lastTurnAt = 0.0
    private var lastMouse: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What takes the pointer: the card.
    var hitRect: NSRect { cardRect }

    /// New data: a newer last turn means a receipt.
    func take(_ m: Model) {
        if let first = m.turns.first {
            if lastTurnAt > 0, first.at > lastTurnAt {
                receipts.append(Receipt(usd: first.usd, name: first.name, color: first.color, born: t))
                Sounds.play("Tink")
                onSettle?(first, m)
            }
            lastTurnAt = max(lastTurnAt, first.at)
        }
        model = m
        needsDisplay = true
    }

    func celebrate() {
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

    override func draw(_ dirtyRect: NSRect) {
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
            bounds.fill()
        }
        drawCard()
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
        panel.appearance = NSAppearance(named: .aqua)
        // The panel's white back, rounded as the design has it.
        expanded = NSView(frame: NSRect(origin: .zero, size: NSSize(width: dashboardWidth, height: 600)))
        expanded.wantsLayer = true
        expanded.layer?.backgroundColor = NSColor.white.cgColor
        expanded.layer?.cornerRadius = 36
        expanded.layer?.masksToBounds = true
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
        v.onSettle = { turn, m in SettleNotice.post(turn, m) }
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
        fitPanel()

        ensureDaemon()
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
                self.dashboard.officeV3.tick(1.0 / 24.0)
                self.dashboard.officeV3.needsDisplay = true
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

    /// Sizes the panel to its content and draws the pet.
    func fitPanel() {
        dashboard.frame.size.width = dashboardWidth
        dashboard.frame.size.height = dashboard.contentHeight()
        dashboard.needsDisplay = true
        pet?.needsDisplay = true
    }

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

    /// Exports a period's 4:5 share image (the report window's design) to
    /// ~/Pictures/DANGO. `back` counts periods back. With `shareFrom` (a view
    /// and a spot in it) the system share menu opens there; without, the
    /// image goes on the clipboard and the panel closes.
    func makeCard(kind: String, back: Int = 0, shareFrom: (NSView, NSRect)? = nil) {
        let name = ReportText.kindName(kind, share: true)
        let unit: Calendar.Component = ["week": .weekOfYear, "month": .month, "year": .year][kind] ?? .day
        let day = ReportView.fmt.string(from: Calendar.current.date(byAdding: unit, value: -back, to: Date()) ?? Date())
        let failed = L("\(name)没生成出来", "Couldn't make the \(name.lowercased()) image")
        guard cliPath() != nil else {
            pet?.flash(L("没找到 dango 命令", "Can't find the dango command"))
            return
        }
        pet?.flash(L("正在生成\(name)…", "Making the \(name.lowercased()) image…"))
        DispatchQueue.global().async {
            let j = dangoJSON(["abti", "--report", kind, "--day", day])
            DispatchQueue.main.async {
                guard let j else { return self.pet?.flash(failed) ?? () }
                try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
                let path = exportDir + "/dango-\(kind)-\(j["from"].s).png"
                guard exportPage(ShareView(size: NSSize(width: 540, height: 675), data: j), path, copy: shareFrom == nil) else {
                    return self.pet?.flash(failed) ?? ()
                }
                if let (view, spot) = shareFrom, view.window?.isVisible == true {
                    NSSharingServicePicker(items: [URL(fileURLWithPath: path)]).show(relativeTo: spot, of: view, preferredEdge: .minY)
                } else {
                    self.pet?.flash(L("\(name)已导出并复制", "\(name) image saved and copied"))
                }
            }
        }
        if shareFrom == nil { collapse() }
    }

    /// Day, week, month and year: this one and the last one of each.
    /// `share` opens the share menu at the panel's share button, else copies.
    func exportMenu(share: Bool = false) -> NSMenu {
        let export = NSMenu()
        for (i, (kind, now, before)) in [("day", L("今日日报", "Today"), L("昨日日报", "Yesterday")), ("week", L("本周周报", "This week"), L("上周周报", "Last week")),
                                         ("month", L("本月月报", "This month"), L("上月月报", "Last month")), ("year", L("今年年报", "This year"), L("去年年报", "Last year"))].enumerated() {
            if i > 0 { export.addItem(.separator()) }
            for (back, title) in [(0, now), (1, before)] {
                let item = NSMenuItem(title: title, action: #selector(exportFromMenu(_:)), keyEquivalent: "")
                item.representedObject = "\(kind):\(back):\(share ? "share" : "copy")"
                item.target = self
                export.addItem(item)
            }
        }
        return export
    }

    /// From the menu: "week:1:copy" copies last week's card.
    @objc func exportFromMenu(_ sender: NSMenuItem) {
        let parts = (sender.representedObject as? String ?? "day:0").split(separator: ":")
        let share = parts.count > 2 && parts[2] == "share" ? dashboard.exportButton.map { (dashboard as NSView, $0) } : nil
        makeCard(kind: String(parts[0]), back: parts.count > 1 ? Int(parts[1]) ?? 0 : 0, shareFrom: share)
    }

    /// Right-click on the panel's share button: copy instead, the other
    /// periods, and the folder the images go to.
    func exportButtonMenu() -> NSMenu {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L("复制今日日报", "Copy today's report"), action: #selector(exportFromMenu(_:)), keyEquivalent: "")
        copy.representedObject = "day:0:copy"
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        for (title, share) in [(L("分享其他报告", "Share another report"), true), (L("复制其他报告", "Copy another report"), false)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = exportMenu(share: share)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: L("打开 ~/Pictures/DANGO", "Open ~/Pictures/DANGO"), action: #selector(openExportFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        return menu
    }

    @objc func openExportFolder() {
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: exportDir))
    }

    // MARK: menu

    func popMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isExpanded ? L("收起仪表盘", "Close dashboard") : L("打开仪表盘", "Open dashboard"), action: #selector(toggle), keyEquivalent: ""))
        let boss = NSMenu()
        for (id, title) in [("story", L("我的老板人格", "My boss type")), ("types", L("16 型图鉴", "All 16 types")),
                            ("scale", L("规模和压榨率怎么算", "How scale and margin work")), ("roles", L("团子构成怎么算", "How the crew works"))] {
            let item = NSMenuItem(title: title, action: #selector(openBoss(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            boss.addItem(item)
        }
        let bossItem = NSMenuItem(title: L("老板人格", "AI Boss Type"), action: nil, keyEquivalent: "")
        bossItem.submenu = boss
        menu.addItem(bossItem)
        menu.addItem(NSMenuItem(title: L("报告", "Reports"), action: #selector(openReports), keyEquivalent: ""))
        let exportItem = NSMenuItem(title: L("导出报告", "Export report"), action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu()
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
        let auto = NSMenuItem(title: L("登录时自动启动", "Start at login"), action: #selector(toggleAutostart), keyEquivalent: "")
        auto.state = FileManager.default.fileExists(atPath: agentPlist) ? .on : .off
        menu.addItem(auto)
        let snd = NSMenuItem(title: L("结算提示音", "Sounds"), action: #selector(toggleSound), keyEquivalent: "")
        snd.state = Sounds.enabled ? .on : .off
        menu.addItem(snd)
        if SettleNotice.available {
            let note = NSMenuItem(title: L("结算时发系统通知", "Notify when a turn settles"), action: #selector(toggleSettleNotice), keyEquivalent: "")
            note.state = SettleNotice.enabled ? .on : .off
            menu.addItem(note)
        }
        menu.addItem(NSMenuItem(title: L("回到右下角", "Back to the corner"), action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出", "Quit"), action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func quit() { NSApp.terminate(nil) }

    /// The boss-type menu: the story (ending on the card) or one of its pages.
    @objc func openBoss(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String ?? "story"
        if id == "story" { StoryWindow.show() } else { PageWindow.show(id) }
    }

    @objc func openReports() { ReportWindow.show() }

    @objc func toggleSound() { Sounds.enabled.toggle() }

    @objc func toggleSettleNotice() {
        if SettleNotice.enabled {
            SettleNotice.enabled = false
            return
        }
        SettleNotice.enable { [weak self] granted in
            if !granted {
                self?.pet?.flash(L("通知没打开：去「系统设置 → 通知 → Dango」允许", "Notifications are off: allow Dango in System Settings → Notifications"))
            }
        }
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

    /// A packaged app sets up its daemon itself: on the first launch (or
    /// after the app moved) it writes the LaunchAgent for the dango inside
    /// the app and starts it, turns the pet's start-at-login on, and says
    /// the history is being read; after an update in place it restarts the
    /// daemon once on the new binary. A developer's own agent, pointing at
    /// a dango that exists elsewhere, is left alone, and so is a bare build.
    func ensureDaemon() {
        let fm = FileManager.default
        let cli = bundledCLI
        guard Bundle.main.bundleURL.pathExtension == "app", fm.isExecutableFile(atPath: cli) else { return }
        let uid = getuid()
        let current = (NSDictionary(contentsOfFile: daemonPlist)?["ProgramArguments"] as? [String])?.first
        // launchd loads the agent at login, except when "Allow in the
        // Background" is off for it in System Settings; then nothing
        // records until the app, opened by hand, loads it here.
        let loaded = run("/bin/launchctl", ["print", "gui/\(uid)/\(daemonLabel)"]) == 0
        if let current, current != cli, fm.isExecutableFile(atPath: current) {
            if !loaded { run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlist]) }
            return
        }
        let stamp = ((try? fm.attributesOfItem(atPath: cli))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if current == cli {
            if !loaded {
                run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlist])
                UserDefaults.standard.set(stamp, forKey: "daemonStamp")
            } else if UserDefaults.standard.double(forKey: "daemonStamp") != stamp {
                run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(daemonLabel)"])
                UserDefaults.standard.set(stamp, forKey: "daemonStamp")
            }
            return
        }
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        guard let data = daemonAgent(cli: cli) else { return }
        try? fm.createDirectory(atPath: (daemonPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: daemonPlist))) != nil else { return }
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(daemonLabel)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", daemonPlist])
        UserDefaults.standard.set(stamp, forKey: "daemonStamp")
        if !fm.fileExists(atPath: agentPlist) { toggleAutostart() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pet?.flash(L("团子们在翻你的 Claude Code、Codex 和 DeepSeek 历史…", "Your dangos are reading your Claude Code, Codex and DeepSeek history…"))
        }
    }

    /// Runs a command to the end; its exit status, -1 if it could not start.
    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: data

    private var storyTried = false

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
        // The first scan with anything in it opens the story: one try per
        // launch until the window has shown once (StoryWindow sets the flag).
        if m.totalUSD > 0 && !storyTried && !UserDefaults.standard.bool(forKey: "abtiShown") {
            storyTried = true
            DispatchQueue.main.async { StoryWindow.show() }
        }
    }
}

// MARK: - Settle notices

/// A macOS notification when a turn settles, in place of the box Claude
/// Code shows when Dango's hooks are installed. Off until the person turns
/// it on (right-click menu), which asks macOS for permission. Only an app
/// bundle can post one; a bare build has no menu item.
enum SettleNotice {
    static let key = "settleNotice"
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func enable(_ done: @escaping (Bool) -> Void) {
        guard available else { return done(false) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async {
                enabled = granted
                done(granted)
            }
        }
    }

    /// "+$78 · Software engineer", and today's total underneath.
    static func post(_ turn: TurnRow, _ m: Model) {
        guard enabled, available else { return }
        let c = UNMutableNotificationContent()
        c.title = "+" + fmtUSD(turn.usd) + (turn.name.isEmpty ? "" : " · " + turn.name)
        c.body = L("今天累计 \(fmtUSD(m.todayUSD))", "\(fmtUSD(m.todayUSD)) so far today")
        let req = UNNotificationRequest(identifier: "settle-\(Int(turn.at))", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
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
    if args.contains("--receipt") { v.receipts = [Receipt(usd: 78.4, name: m.job?.name ?? "软件工程师", color: m.job?.color ?? barColor, born: 0)] }
    snapshot(v, PetView.size, args[i + 1])
    exit(0)
}
if args.contains("--print-daemon-agent") {
    // The LaunchAgent a fresh install of this app would write, and nothing
    // else: for checking a package without touching the running daemon.
    if let d = daemonAgent(cli: bundledCLI) { FileHandle.standardOutput.write(d) }
    exit(0)
}
if let i = args.firstIndex(of: "--abti"), args.count > i + 2 {
    // --abti RESULT.json out.png [--page card|types|scale|roles] [--lang zh|en] [--copy]:
    // the boss card and its pages, from `dango abti --json`.
    _ = NSApplication.shared
    let d = JV.load(args[i + 1])
    let flagv = { (f: String) -> String? in args.firstIndex(of: f).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    lang = flagv("--lang") ?? (d["lang"].s.isEmpty ? lang : d["lang"].s)
    if flagv("--page") == "story" {
        // --screen N (1–7) [--t SEC] [--bare]: one story screen.
        let s = StoryView(frame: NSRect(x: 0, y: 0, width: 540, height: 960))
        s.data = d
        s.screen = flagv("--screen").flatMap { Int($0) } ?? 1
        s.t = flagv("--t").flatMap { Double($0) } ?? 10
        s.bare = args.contains("--bare")
        exit(exportPage(s, args[i + 2]) ? 0 : 1)
    }
    let v: ABPage
    switch flagv("--page") ?? "card" {
    case "types": v = TypesView(size: NSSize(width: 540, height: 960), data: d)
    case "scale": v = ScaleView(size: NSSize(width: 540, height: 604), data: d)
    case "roles": v = RolesView(size: NSSize(width: 540, height: 724), data: d)
    case "share": v = ShareView(size: NSSize(width: 540, height: 675), data: d)
    case "report":
        let r = ReportView(size: NSSize(width: 560, height: 822), data: d)
        r.kind = d["kind"].s
        r.section = flagv("--section") ?? "crew"
        v = r
    default: v = BossCardView(size: NSSize(width: 540, height: 960), data: d)
    }
    exit(exportPage(v, args[i + 2], copy: args.contains("--copy")) ? 0 : 1)
}
if let i = args.firstIndex(of: "--snapshot-dashboard"), args.count > i + 1 {
    _ = NSApplication.shared
    let v = DashboardView(frame: NSRect(x: 0, y: 0, width: dashboardWidth, height: 600))
    v.drawBackground = true
    v.model = loadModel()
    let range = args.firstIndex(of: "--range").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 30
    v.preset(jobsOpen: args.contains("--open-jobs"), range: range)
    // --office N fills the room with N made-up occupants, for a look.
    if let n = args.firstIndex(of: "--office").flatMap({ args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }), var m = v.model, !m.occupations.isEmpty {
        m.office = (0..<n).map { i in
            Occupant(job: m.occupations[(i * 3) % m.occupations.count], working: i == 0 || i == 3, helpers: i == 0 ? 2 : 0,
                     usd: Double(140 * (i + 1)), since: Date().timeIntervalSince1970 * 1000 - [2.0, 40, 200, 1, 5, 70][i % 6] * 60_000)
        }
        let flagv = { (f: String) -> String? in args.firstIndex(of: f).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        for (k, st) in (flagv("--statuses")?.split(separator: ",") ?? []).enumerated() where k < m.office.count { m.office[k].status = String(st) }
        v.model = m
    }
    v.officeV3.instant = true
    v.officeV3.t = 0.9
    let h = v.contentHeight()
    snapshot(v, NSSize(width: dashboardWidth, height: h), args[i + 1])
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot-office"), args.count > i + 1 {
    // [--jobs id,id,…] [--working K] [--statuses s,s,…] [--t SEC]: made-up
    // staff, the first K at work, each in a given state, at a given moment.
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
    for (n, st) in (flagv("--statuses")?.split(separator: ",") ?? []).enumerated() where n < staff.count { staff[n].status = String(st) }
    let size = NSSize(width: 392, height: V3OfficeView.height)
    let v = V3OfficeView(frame: NSRect(origin: .zero, size: size))
    v.model = m
    v.occupants = staff
    v.instant = true
    // --t SEC: the moment to render (4.35 catches the first one's blink).
    v.tick(flagv("--t").flatMap { Double($0) } ?? 0.9)
    snapshot(v, size, args[i + 1])
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot-roles"), args.count > i + 1 {
    // [--statuses s,s,…]: every role in dango.json (the pack's R01–R12 and
    // the ones drawn for other jobs, R13–R21), then the plain 团子, in each
    // state, one row each, for checking the art.
    _ = NSApplication.shared
    let flagv = { (f: String) -> String? in args.firstIndex(of: f).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let states = (flagv("--statuses") ?? "idle,working,waiting,happy,fuming,sleeping").split(separator: ",").map(String.init)
    let roles: [String?] = ((packLayoutJSON["roles"] as? [String: Any])?.keys.sorted() ?? []).map { Optional($0) } + [nil]
    let cell = NSSize(width: 120, height: 104)
    let size = NSSize(width: 44 + cell.width * CGFloat(states.count), height: cell.height * CGFloat(roles.count))
    final class Sheet: NSView {
        var paint: () -> Void = {}
        override var isFlipped: Bool { true }
        override func draw(_ r: NSRect) { paint() }
    }
    let v = Sheet(frame: NSRect(origin: .zero, size: size))
    v.paint = {
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (r, role) in roles.enumerated() {
            put(V3.mono(role ?? "—", 11, .regular, V3.secondary), 6, CGFloat(r) * cell.height + cell.height / 2 - 7)
            for (c, st) in states.enumerated() {
                let box = NSRect(x: 44 + CGFloat(c) * cell.width + 10, y: CGFloat(r) * cell.height + 8, width: cell.width - 20, height: cell.height - 16)
                drawFittedDango(box, role: role, status: st)
            }
        }
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
