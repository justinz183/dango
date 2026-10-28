// shadowcorp-widget: a small always-on-top panel in the bottom-right corner
// of the screen showing output value ($), rank and XP. Reads
// ~/.shadowcorp/widget.json (written by the daemon) every 2 seconds.
// No dock icon, no menu bar item; right-click for the menu.
//
// Build: apps/widget/build.sh (binary) or apps/widget/bundle.sh (ShadowCorp.app)
// Snapshot (no window): --snapshot out.png

import AppKit
import Foundation

signal(SIGHUP, SIG_IGN)

let home = ProcessInfo.processInfo.environment["SHADOWCORP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSHomeDirectory() + "/.shadowcorp"
let dataURL = URL(fileURLWithPath: home + "/widget.json")
let agentLabel = "com.shadowcorp.widget"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let widgetSize = NSSize(width: 256, height: 78)

struct Model {
    var totalUSD = 0.0
    var todayUSD = 0.0
    var weekUSD = 0.0
    var xp = 0
    var rankLabel = "—"
    var nextLabel: String?
    var rankColor = NSColor.gray
    var progress = 0.0
    var xpToNext: Int?
    var level = 0
    var working = 0
    var subagents = 0
    var generatedAt = 0.0
}

func color(hex: String) -> NSColor {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .gray }
    h = ""
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func loadModel() -> Model? {
    guard let data = try? Data(contentsOf: dataURL),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var m = Model()
    let total = j["total"] as? [String: Any] ?? [:]
    let today = j["today"] as? [String: Any] ?? [:]
    let week = j["week"] as? [String: Any] ?? [:]
    let rank = j["rank"] as? [String: Any] ?? [:]
    let act = j["activity"] as? [String: Any] ?? [:]
    m.totalUSD = total["usd"] as? Double ?? 0
    m.todayUSD = today["usd"] as? Double ?? 0
    m.weekUSD = week["usd"] as? Double ?? 0
    m.xp = total["xp"] as? Int ?? 0
    m.rankLabel = rank["label"] as? String ?? "—"
    m.nextLabel = rank["next_label"] as? String
    m.rankColor = color(hex: rank["color"] as? String ?? "")
    m.progress = rank["progress"] as? Double ?? 0
    m.xpToNext = rank["xp_to_next"] as? Int
    let index = rank["index"] as? Int ?? 0
    let division = rank["division"] as? Int ?? 0
    m.level = index * 4 + (division == 0 ? 4 : 4 - division)
    m.working = act["working"] as? Int ?? 0
    m.subagents = act["subagents"] as? Int ?? 0
    m.generatedAt = j["generated_at"] as? Double ?? 0
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

func roman(_ label: String) -> String {
    label.split(separator: " ").last.map(String.init).flatMap { ["I", "II", "III", "IV"].contains($0) ? $0 : nil } ?? "★"
}

final class WidgetView: NSView {
    var model: Model?
    var drawBackground = false
    var flashUntil = Date.distantPast
    var flashText = ""
    var tick = 0

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSAttributedString {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private func draw(_ s: NSAttributedString, x: CGFloat, baseline y: CGFloat, rightAligned: Bool = false) {
        let w = s.size().width
        s.draw(at: NSPoint(x: rightAligned ? x - w : x, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if drawBackground {
            NSColor(calibratedWhite: 0.11, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: b, xRadius: 14, yRadius: 14).fill()
        }
        let primary = NSColor.white
        let secondary = NSColor.white.withAlphaComponent(0.62)
        guard let m = model else {
            draw(text("等待数据…", size: 12, weight: .medium, color: secondary), x: 14, baseline: 32)
            draw(text("在终端运行 shadowcorp widget", size: 10, weight: .regular, color: secondary), x: 14, baseline: 16)
            return
        }
        let flashing = Date() < flashUntil
        // Medal
        let medal = NSRect(x: 14, y: (b.height - 38) / 2, width: 38, height: 38)
        if flashing {
            m.rankColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: medal.insetBy(dx: -5, dy: -5)).fill()
        }
        m.rankColor.setFill()
        NSBezierPath(ovalIn: medal).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(ovalIn: medal.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let numeral = text(roman(m.rankLabel), size: 13, weight: .bold, color: NSColor.black.withAlphaComponent(0.75))
        let ns = numeral.size()
        numeral.draw(at: NSPoint(x: medal.midX - ns.width / 2, y: medal.midY - ns.height / 2 + 0.5))

        let x0: CGFloat = 62
        let right = b.width - 14
        // Row 1: total value, today's value
        draw(text(fmtUSD(m.totalUSD), size: 20, weight: .bold, color: primary, mono: true), x: x0, baseline: 44)
        draw(text("今日 " + fmtUSD(m.todayUSD), size: 11, weight: .regular, color: secondary, mono: true), x: right, baseline: 48, rightAligned: true)
        // Row 2: rank + XP
        if flashing {
            draw(text(flashText, size: 12, weight: .semibold, color: m.rankColor), x: x0, baseline: 25)
        } else {
            draw(text(m.rankLabel, size: 12, weight: .semibold, color: m.rankColor), x: x0, baseline: 25)
            let xpText: String
            if let n = m.xpToNext { xpText = "\(fmtInt(m.xp)) XP · 还差 \(fmtInt(n))" } else { xpText = "\(fmtInt(m.xp)) XP" }
            draw(text(xpText, size: 10, weight: .regular, color: secondary, mono: true), x: right, baseline: 26, rightAligned: true)
        }
        // Row 3: progress bar through the division
        let bar = NSRect(x: x0, y: 14, width: right - x0, height: 4)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let fill = NSRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(min(1, max(0, m.progress)))), height: 4)
        m.rankColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        // Working indicator: a pulsing dot while an agent is on a turn.
        if m.working > 0 {
            let pulse = 0.55 + 0.45 * sin(Double(tick) / 4.0)
            NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: CGFloat(pulse)).setFill()
            NSBezierPath(ovalIn: NSRect(x: right - 3, y: b.height - 15, width: 6, height: 6)).fill()
            let label = m.subagents > 0 ? "干活中 +\(m.subagents)" : "干活中"
            draw(text(label, size: 9, weight: .medium, color: secondary), x: right - 8, baseline: b.height - 16, rightAligned: true)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let auto = NSMenuItem(title: "登录时自动启动", action: #selector(toggleAutostart), keyEquivalent: "")
        auto.state = FileManager.default.fileExists(atPath: agentPlist) ? .on : .off
        menu.addItem(auto)
        menu.addItem(NSMenuItem(title: "回到右下角", action: #selector(reposition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func reposition() { (window as? NSPanel).map(placeBottomRight) }

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
}

func placeBottomRight(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let vf = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(x: vf.maxX - widgetSize.width - 16, y: vf.minY + 16))
}

final class App: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var view: WidgetView!
    var last: Model?

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: widgetSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: widgetSize))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        view = WidgetView(frame: effect.bounds)
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        panel.contentView = effect

        panel.setFrameAutosaveName("shadowcorp-widget")
        if !panel.setFrameUsingName("shadowcorp-widget") || !onScreen(panel.frame) {
            placeBottomRight(panel)
        }
        panel.setContentSize(widgetSize)
        panel.orderFrontRegardless()

        reload()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self, let m = self.view.model else { return }
            if m.working > 0 || Date() < self.view.flashUntil {
                self.view.tick += 1
                self.view.needsDisplay = true
            }
        }
    }

    private func onScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    func reload() {
        guard let m = loadModel() else { return }
        if let old = last, m.level > old.level {
            view.flashText = "晋级 → \(m.rankLabel)"
            view.flashUntil = Date().addingTimeInterval(5)
        }
        if last.map({ $0.generatedAt != m.generatedAt }) ?? true {
            view.model = m
            view.needsDisplay = true
        }
        last = m
    }
}

// --snapshot out.png: render the view offscreen and exit (for verification).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    let v = WidgetView(frame: NSRect(origin: .zero, size: NSSize(width: widgetSize.width * 2, height: widgetSize.height * 2)))
    v.drawBackground = true
    v.model = loadModel()
    v.scaleUnitSquare(to: NSSize(width: 2, height: 2))
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
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
