// The ABTI story (故事模式, handoff README "0 故事模式"): six screens like
// a year-in-review, then the boss card as the seventh. No guessing first:
// it is a read-out, not a test (user, 2026-11-07). 540 × 960, white (the
// scan is black), a seven-part progress bar, the word mark and a close
// button on top. Click the right of the screen for the next one, the left
// third or ‹ for the one before, ← → on the keyboard; closing jumps to the
// card and copies it. Each screen can be shared as 1080 × 1920, the card
// too. The story speaks the app's language: every word comes in Chinese and
// English (the English is ours; the handoff only drew the Chinese).

import AppKit

final class StoryView: NSView {
    var data = JV(nil)
    /// 1–7; 7 is the boss card.
    var screen = 1
    /// Seconds since the screen came up (for the scan and the reveal).
    var t = 0.0
    /// Sharing draws the screen bare: no progress, no buttons, a link at the bottom.
    var bare = false
    var onClose: (() -> Void)?
    private var hits: [(String, NSRect)] = []
    private var timer: Timer?
    private var toast: (String, Double)?
    private var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let W: CGFloat = 540, H: CGFloat = 960, x0: CGFloat = 30

    func go(_ n: Int) {
        screen = min(7, max(1, n))
        t = 0
        timer?.invalidate()
        if !reduce && (screen == 1 || screen == 2) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] tm in
                guard let self else { return tm.invalidate() }
                self.t += 1.0 / 30.0
                self.needsDisplay = true
                if self.t > 3.4 { tm.invalidate() }
            }
        } else {
            t = 10
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        let dark = screen == 1
        (dark ? AB.ink : .white).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        if screen == 7 {
            let card = BossCardView(size: NSSize(width: W, height: H), data: data)
            if bare { card.render(); return }
            // The story's top row stays; the card sits under it, a little smaller.
            chrome(false)
            let k = (H - 62 - 8) / H
            let frame = NSRect(x: (W - W * k) / 2, y: 62, width: W * k, height: H * k)
            AB.stroke(frame.insetBy(dx: -0.5, dy: -0.5), 14, AB.line, 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
            let tr = NSAffineTransform()
            tr.translateX(by: frame.minX, yBy: frame.minY)
            tr.scale(by: k)
            tr.concat()
            card.render()
            NSGraphicsContext.restoreGraphicsState()
            drawToast()
            return
        }
        if !bare { chrome(dark) }
        switch screen {
        case 1: scanScreen()
        case 2: revealScreen()
        case 3: payScreen()
        case 4: momentsScreen()
        case 5: checkupScreen()
        default: matchScreen()
        }
        drawToast()
    }

    // MARK: chrome

    private func chrome(_ dark: Bool) {
        let ink = dark ? NSColor.white : AB.ink
        let seg = (W - 30 - 6 * 4) / 7
        for k in 0..<7 {
            AB.round(NSRect(x: 15 + CGFloat(k) * (seg + 4), y: 9, width: seg, height: 2.5), 1.25, k < screen ? ink : (dark ? NSColor.white.withAlphaComponent(0.2) : AB.line))
        }
        let sub = dark ? NSColor.white.withAlphaComponent(0.6) : AB.gray
        if screen == 7 {
            // On the card: ‹ back to the sixth screen in place of the word mark.
            let back = NSRect(x: 15, y: 18, width: 36, height: 36)
            AB.round(back, 18, AB.control)
            put(AB.sans("‹", 18, .medium), back.midX, back.minY + 7, align: 1)
            hits.append(("prev", back))
            put(AB.sans(L("ABTI 人格", "ABTI"), 11, .regular, sub), back.maxX + 10, 29)
        } else {
            let mw = AB.wordmark(15, 27, size: 13, color: ink)
            put(AB.sans(L("ABTI 人格", "ABTI"), 11, .regular, sub), 15 + mw + 10, 29)
        }
        var rx = W - 15 - 36 - 12
        if screen == 7 {
            // The card is the thing to send: its own share button up here.
            let s = AB.sans(L("⇪  分享总卡", "⇪  Share card"), 12, .semibold, .white)
            let r = NSRect(x: rx - s.size().width - 24, y: 18, width: s.size().width + 24, height: 36)
            AB.round(r, 18, AB.ink)
            put(s, r.midX, r.midY - s.size().height / 2, align: 1)
            hits.append(("shareCard", r))
            rx = r.minX - 12
        }
        put(AB.mono("\(screen) / 7", 11, .regular, sub), rx, 29, align: 2)
        let close = NSRect(x: W - 15 - 36, y: 18, width: 36, height: 36)
        AB.round(close, 18, dark ? NSColor.white.withAlphaComponent(0.12) : AB.control)
        put(AB.sans("×", 17, .medium, ink), close.midX, close.minY + 7, align: 1)
        hits.append(("close", close))
    }

    /// ‹, "点一下继续 →", and on the right replay and share.
    private func nav(next: String = L("点一下继续 →", "Tap to continue →"), replay: Bool = false, share: Bool = true) {
        guard !bare else { return }
        let y = H - 24 - 40
        let back = NSRect(x: x0, y: y, width: 40, height: 40)
        AB.round(back, 14, AB.control)
        put(AB.sans("‹", 18, .medium), back.midX, back.minY + 8, align: 1)
        hits.append(("prev", back))
        let n = AB.sans(next, 12.5, .semibold)
        put(n, back.maxX + 14, y + 20 - n.size().height / 2)
        hits.append(("next", NSRect(x: back.maxX + 8, y: y, width: n.size().width + 12, height: 40)))
        var rx = W - x0
        if share {
            let s = AB.sans(L("⇪  分享这一屏", "⇪  Share this screen"), 12.5, .semibold)
            let r = NSRect(x: rx - s.size().width - 28, y: y, width: s.size().width + 28, height: 40)
            AB.round(r, 14, AB.control)
            put(s, r.midX, r.midY - s.size().height / 2, align: 1)
            hits.append(("share", r))
            rx = r.minX - 8
        }
        if replay {
            let s = AB.sans(L("重播", "Replay"), 12.5, .semibold)
            let r = NSRect(x: rx - s.size().width - 28, y: y, width: s.size().width + 28, height: 40)
            AB.round(r, 14, AB.control)
            put(s, r.midX, r.midY - s.size().height / 2, align: 1)
            hits.append(("replay", r))
        }
    }

    private func label(_ s: String, _ y: CGFloat, dark: Bool = false) {
        put(AB.mono(s, 11, .regular, dark ? NSColor.white.withAlphaComponent(0.6) : AB.gray), x0, y)
    }

    private func title(_ s: String, _ y: CGFloat, size: CGFloat = 32, color c: NSColor = AB.ink) -> CGFloat {
        AB.para(AB.sans(s, size, .bold, c), x0, y, W - 60, lineHeight: size * 1.25)
    }

    private var code: String { data["code"].s }
    private var dims: [JV] { data["dims"].arr }

    // MARK: 1 · 扫描 (black)

    private func scanScreen() {
        let p = reduce ? 1 : min(1, t / 3.0)
        let days = data["scan_days"].i
        label(L("01 · 扫描", "01 · SCAN"), 104, dark: true)
        _ = title(p < 1 ? L("团子们正在\n翻你的历史", "Your dangos are going\nthrough your history") : L("翻完了，\n一共 \(days) 天", "Done.\n\(days) days in all"), 122, color: .white)
        let shown = Int((Double(days) * p).rounded())
        let n = AB.mono("\(shown)", 84, .semibold, .white, kern: -2)
        put(n, x0 - 3, 206)
        put(AB.sans(L("天", "days"), 18, .semibold, .white), x0 + n.size().width + 6, 206 + n.size().height - 30)
        let from = data["since"].s, to = data["date"].s
        let span = p < 1 ? L("从 \(AB.monthDay(from)) 开始", "From \(AB.monthDay(from))") : L("从 \(AB.monthDay(from)) 翻到 \(AB.monthDay(to))", "From \(AB.monthDay(from)) to \(AB.monthDay(to))")
        put(AB.mono(span, 11, .regular, NSColor.white.withAlphaComponent(0.55)), x0, 316)
        // Every day a cell, lighting up as the scan goes.
        let heat = data["heat"].arr
        let rows = 8
        let cols = max(1, (heat.count + rows - 1) / rows)
        let gap: CGFloat = 3
        let cell = min(13, (W - 60 - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let dim = [color(hex: "#2C2C2E"), color(hex: "#1F5130"), color(hex: "#2E7D46"), color(hex: "#3FA35E"), color(hex: "#5DD07F")]
        for (i, v) in heat.enumerated() where Double(i) < Double(heat.count) * p {
            let r = NSRect(x: x0 + CGFloat(i / rows) * (cell + gap), y: 346 + CGFloat(i % rows) * (cell + gap), width: cell, height: cell)
            AB.round(r, 2, dim[min(4, max(0, v.i))])
        }
        // The number of jobs comes from the table (data "jobs"), never written in.
        let jobs = data["jobs"].i
        let jobsLine = jobs > 0 ? L("\(jobs) 种职业各自的计时分钟", "Minutes on the clock for each of \(jobs) jobs") : L("每种职业各自的计时分钟", "Minutes on the clock for each job")
        let lines = [L("\(fmtInt(data["sessions"].i)) 个会话", "\(fmtInt(data["sessions"].i)) sessions"), L("每个回合 AI 自己动手几步", "How many steps the AI took on its own each turn"),
                     jobsLine, L("模型一共花了多少钱", "What the models cost in all")]
        var y: CGFloat = 346 + CGFloat(rows) * (cell + gap) + 26
        for (k, l) in lines.enumerated() where p >= Double(k + 1) / 4.0 - 0.001 {
            put(AB.sans("✓", 13, .bold, AB.green), x0, y)
            put(AB.sans(l, 13.5, .regular, .white), x0 + 24, y)
            y += 32
        }
        let box = NSRect(x: x0, y: H - 24 - 40 - 22 - 58, width: W - 60, height: 58)
        AB.stroke(box, 12, NSColor.white.withAlphaComponent(0.22), 1)
        AB.para(AB.sans(L("🔒  只看数字：回合数、时长、改了几行、花了多少钱。不读代码，不读 prompt，什么都不上传。", "🔒  Numbers only: turns, time, lines changed, money spent. Never reads your code or prompts. Nothing is uploaded."), 11.5, .regular, NSColor.white.withAlphaComponent(0.7)), box.minX + 16, box.minY + 12, box.width - 32, lineHeight: 17)
        guard !bare else { return }
        let y2 = H - 24 - 40
        var rp = NSRect(x: x0, y: y2, width: 60, height: 40)
        let rt = AB.sans(L("重播", "Replay"), 12.5, .semibold, .white)
        rp.size.width = rt.size().width + 28
        AB.round(rp, 14, NSColor.white.withAlphaComponent(0.12))
        put(rt, rp.midX, rp.minY + 11, align: 1)
        hits.append(("replay", rp))
        let go = AB.sans(p < 1 ? L("扫描中 \(Int(p * 100))%", "Scanning \(Int(p * 100))%") : L("看结果 →", "See the result →"), 13, .semibold, AB.ink)
        let gr = NSRect(x: W - x0 - go.size().width - 40, y: y2, width: go.size().width + 40, height: 40)
        AB.round(gr, 14, .white)
        put(go, gr.midX, gr.midY - go.size().height / 2, align: 1)
        if p >= 1 { hits.append(("next", gr)) }
    }

    // MARK: 2 · 揭晓

    private func revealScreen() {
        label(L("02 · 揭晓", "02 · REVEAL"), 104)
        put(AB.sans(L("你是", "You are"), 15, .regular, AB.gray), x0, 132)
        let tw = (W - 60 - 30) / 4
        for (k, ch) in code.enumerated() {
            let start = 0.35 * Double(k), p = reduce ? 1 : min(1, max(0, (t - start) / 0.5))
            let r = NSRect(x: x0 + CGFloat(k) * (tw + 10), y: 158, width: tw, height: 108)
            if p > 0 {
                // A flip: the tile grows from its middle line.
                let h = r.height * CGFloat(abs(cos((1 - p) * .pi / 2)))
                let fr = NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
                AB.round(fr, 14, AB.ink)
                if p > 0.5 { put(AB.mono(String(ch), 56, .bold, .white), r.midX, r.midY - 34, align: 1) }
            }
            guard p >= 1, k < dims.count else { continue }
            let dm = dims[k]
            let name = ABText.dimNames(dm["id"].s)[dm["winner"].i]
            let v = dm["id"].s == "range" ? L("\(dm["roles"].i) 个", "\(dm["roles"].i) roles") : AB.pct(dm["pct"].d)
            put(AB.join([AB.sans(name + " ", 11.5, .semibold), AB.mono(v, 10.5, .regular, AB.gray)]), r.midX, r.maxY + 8, align: 1)
        }
        if reduce || t >= 1.6 {
            AB.fit(abtiImage("scene/T-" + code), NSRect(x: 120, y: 316, width: 300, height: 228))
            put(AB.sans(ABText.typeName(code), 30, .bold), W / 2, 556, align: 1)
            put(AB.sans(ABText.roast(code), 14, .regular), W / 2, 600, align: 1)
        }
        nav(replay: true)
    }

    // MARK: 3 · 发工资

    private func payScreen() {
        label(L("03 · 发工资", "03 · PAYDAY"), 104)
        put(AB.sans(L("团子们替你打了", "Your dangos did"), 17, .medium), x0, 128)
        let big = AB.mono(fmtUSD(data["usd"].d), 54, .semibold, kern: -1.5)
        put(big, x0 - 2, 150)
        put(AB.sans(L("的工", "of work"), 19, .semibold), x0 + big.size().width + 8, 150 + big.size().height - 30)
        let box = NSRect(x: x0, y: 232, width: W - 60, height: 196)
        AB.round(box, 18, AB.tile)
        let bx = box.minX + 18, bw = box.width - 36
        put(AB.sans(L("团子工资条", "Dango payslip"), 13, .semibold), bx, box.minY + 16)
        let span = AB.short(data["since"].s).replacingOccurrences(of: "-", with: "/") + " – " + AB.short(data["date"].s).replacingOccurrences(of: "-", with: "/") + L(" · \(data["scan_days"].i) 天", " · \(data["scan_days"].i) days")
        put(AB.mono(span, 10, .regular, AB.gray), bx + bw, box.minY + 18, align: 2)
        let usd = data["usd"].d, cost = data["cost"].d
        for (k, (a, b, v)) in [(L("应发", "Owed"), L("按 BLS 各职业中位时薪", "BLS median wage per job"), usd), (L("实发", "Paid"), L("模型花费", "model cost"), cost)].enumerated() {
            let y = box.minY + 48 + CGFloat(k) * 38
            put(AB.join([AB.sans(a + "  ", 13, .semibold), AB.sans(b, 10.5, .regular, AB.gray)]), bx, y)
            put(AB.mono(fmtUSD(v), 14, .semibold), bx + bw, y, align: 2)
        }
        AB.round(NSRect(x: bx, y: box.minY + 122, width: bw, height: 7), 3.5, AB.ink)
        AB.round(NSRect(x: bx, y: box.minY + 133, width: max(6, bw * CGFloat(usd > 0 ? cost / usd : 0)), height: 7), 3.5, AB.green)
        AB.line.setFill()
        NSRect(x: bx, y: box.minY + 152, width: bw, height: 1).fill()
        put(AB.join([AB.sans(L("被你压榨  ", "Squeezed out  "), 13, .bold), AB.sans(L("应发 − 实发", "owed − paid"), 10.5, .regular, AB.gray)]), bx, box.minY + 164)
        put(AB.mono(fmtUSD(usd - cost), 16, .bold), bx + bw, box.minY + 162, align: 2)
        // The margin.
        var y = box.maxY + 26
        put(AB.sans(L("压榨率", "Margin"), 11, .regular, AB.gray), x0, y)
        let m = AB.mono(String(format: "%.1f%%", data["margin"].d * 100), 34, .semibold)
        put(m, x0 - 1, y + 14)
        let tier = ABText.margin(data["margin_tier"]["index"].i)
        let pr = AB.pill(cw(tier, "name"), x0 + m.size().width + 12, y + 18, dark: true, size: 11.5)
        let lev = data["leverage"].isNull ? "—" : AB.lev(data["leverage"].d)
        put(AB.mono(L("杠杆 \(lev)", "\(lev) leverage"), 11, .regular, AB.gray), pr.maxX + 8, y + 21)
        put(AB.sans(cw(tier, "line"), 12.5, .regular), x0 + m.size().width + 12, y + 44)
        y += 90
        // The five company sizes as steps, "you are here" on yours.
        y += AB.header(L("公司规模", "Company size"), L("按团子打的工，固定门槛，不和别人比", "by work done; fixed bars, not a ranking"), x0, y, W - 60) + 18
        let tiers = abtiConfig["scale_tiers"].arr
        let mine = data["scale"]["index"].i
        guard tiers.indices.contains(mine) else { return nav() }
        let sw = (W - 60 - 4 * 10) / 5
        let base = y + 92
        for (k, tr) in tiers.enumerated() {
            let h = CGFloat(18 + k * 16)
            let r = NSRect(x: x0 + CGFloat(k) * (sw + 10), y: base - h, width: sw, height: h)
            AB.round(r, 6, k == mine ? AB.ink : (k < mine ? color(hex: "#C9C9CE") : color(hex: "#EDEDED")))
            if k == mine {
                let pw = AB.pill(L("你在这", "You're here"), 0, 0, dark: true, size: 10, padX: 7, padY: 1.5, draw: false).width
                AB.pill(L("你在这", "You're here"), r.midX - pw / 2, r.minY - 22, dark: true, size: 10, padX: 7, padY: 1.5)
            }
            put(AB.sans(cw(tr, "name"), 11.5, k == mine ? .semibold : .regular, k == mine ? AB.ink : AB.gray), r.midX, base + 8, align: 1)
            let th = k == 0 ? "< $" + ABText.shortUSD(tiers[1]["min_usd"].d) : "$" + ABText.shortUSD(tr["min_usd"].d)
            put(AB.mono(th, 9, .regular, AB.gray), r.midX, base + 26, align: 1)
        }
        y = base + 52
        put(AB.sans(cw(tiers[mine], "line"), 12.5, .regular), x0, y)
        if !data["scale"]["next"].isNull {
            let nextName = cw(tiers[min(mine + 1, tiers.count - 1)], "name"), need = fmtUSD(data["scale"]["next_need"].d)
            put(AB.mono(L("离\(nextName)还差 \(need)", "\(need) to \(nextName)"), 11, .regular, AB.gray), W - x0, y + 24, align: 2)
        }
        nav()
    }

    // MARK: 4 · 名场面

    private func momentsScreen() {
        let days = data["scan_days"].i
        label(L("04 · 名场面", "04 · MOMENTS"), 104)
        _ = title(L("这 \(days) 天里，\n团子们记得这些", "In these \(days) days,\nyour dangos remember"), 122, size: 28)
        let mo = data["moments"]
        var cards: [(String, String, String)] = []
        let ln = mo["latest_night"]
        if !ln.isNull {
            let hour = Int(ln["time"].s.prefix(2)) ?? 0
            cards.append((ln["time"].s, L("最晚的一夜", "Latest night"), L("\(AB.monthDay(ln["date"].s))\(hour < 6 ? "凌晨" : "")，最后一个回合在这时收工", "\(AB.monthDay(ln["date"].s)): the last turn wrapped up at this hour")))
        }
        let bd = mo["best_day"]
        if !bd.isNull { cards.append((fmtUSD(bd["usd"].d), L("最拼的一天", "Biggest day"), L("\(AB.monthDay(bd["date"].s))，一天干出 \(AB.hours(bd["hours"].d))的活", "\(AB.monthDay(bd["date"].s)): \(AB.hours(bd["hours"].d)) of work in one day"))) }
        let st = mo["longest_streak"]
        if st["days"].i > 0 { cards.append((L("\(st["days"].i) 天", "\(st["days"].i) days"), L("最长连续开工", "Longest streak"), L("\(AB.monthDay(st["from"].s))到\(AB.monthDay(st["to"].s))，一天没歇", "\(AB.monthDay(st["from"].s)) to \(AB.monthDay(st["to"].s)), no day off"))) }
        let lt = mo["longest_turn"]
        if !lt.isNull { cards.append((L("\(Int(lt["minutes"].d.rounded())) 分钟", "\(Int(lt["minutes"].d.rounded())) min"), L("最长的一回合", "Longest turn"), L("AI 自己连续干，你一句话没插", "The AI kept going; you didn't say a word"))) }
        var y: CGFloat = 214
        for c in cards {
            let r = NSRect(x: x0, y: y, width: W - 60, height: 58)
            AB.round(r, 16, AB.tile)
            put(AB.mono(c.0, 24, .semibold), r.minX + 18, r.midY - 15)
            put(AB.sans(c.1, 13, .semibold), r.minX + 150, r.minY + 11)
            put(AB.sans(c.2, 11, .regular, AB.gray), r.minX + 150, r.minY + 32)
            y += 58 + 10
        }
        y += 10
        y += AB.header(L("\(days) 天每天的产出", "Every one of the \(days) days"), L("黑框 = 最拼的一天", "outline = biggest day"), x0, y, W - 60) + 10
        let heat = data["heat"].arr
        let cols = max(1, (heat.count + 6) / 7)
        let gap: CGFloat = 2.5
        let cell = min(12, (W - 60 - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let best = data["best_day"].s
        for (i, v) in heat.enumerated() {
            let r = NSRect(x: x0 + CGFloat(i / 7) * (cell + gap), y: y + CGFloat(i % 7) * (cell + gap), width: cell, height: cell)
            AB.round(r, 2, AB.heatColor(v.i))
            if dayString(data["since"].s, plus: i) == best { AB.stroke(r.insetBy(dx: -1, dy: -1), 3, AB.ink, 1.3) }
        }
        y += 7 * (cell + gap) + 10
        put(AB.sans(L("只记时间和数字，不记你在做什么项目。", "Only times and numbers, nothing about what you were working on."), 11, .regular, AB.gray), x0, y)
        nav()
    }

    // MARK: 5 · 体检

    private func checkupScreen() {
        label(L("05 · 体检", "05 · CHECKUP"), 104)
        put(AB.sans(L("DANGO 体检报告", "DANGO Lab Report"), 24, .heavy), x0, 124)
        let date = data["date"].s
        let no = "No. ABTI-" + date.suffix(5).replacingOccurrences(of: "-", with: "") + String(format: "-%04d", data["scan_days"].i)
        put(AB.mono(no, 10, .regular, AB.gray), W - x0, 136, align: 2)
        let info = NSRect(x: x0, y: 168, width: W - 60, height: 32)
        AB.stroke(info, 10, AB.line, 1)
        put(AB.join([AB.sans("ABTI ", 11, .regular, AB.gray), AB.mono(code, 11, .semibold),
                     AB.sans(L("    样本 \(data["scan_days"].i) 天 · \(fmtInt(data["sessions"].i)) 会话", "    Sample \(data["scan_days"].i) days · \(fmtInt(data["sessions"].i)) sessions"), 11, .regular, AB.gray)]), info.minX + 12, info.minY + 9)
        put(AB.sans(L("日期 ", "Date ") + date, 11, .regular, AB.gray), info.maxX - 12, info.minY + 9, align: 2)
        var y: CGFloat = 218
        let cols: [CGFloat] = [x0, x0 + 116, x0 + 214, W - x0]
        for (k, h) in [L("指标", "Measure"), L("结果", "Result"), L("参考范围", "Reference"), L("结论", "Verdict")].enumerated() { put(AB.sans(h, 10.5, .regular, AB.gray), cols[k], y, align: k == 3 ? 2 : 0) }
        y += 18
        AB.ink.setFill()
        NSRect(x: x0, y: y, width: W - 60, height: 1.5).fill()
        y += 2
        let ck = data["checkup"].arr
        let refs = ["tokens_total": L("1 亿 · 10 亿 · 100 亿", "100M · 1B · 10B"), "lines_added": L("1 万 · 10 万 · 100 万", "10K · 100K · 1M"), "first_try_pass": "≥ 80%", "night_shift": "≤ 15%",
                    "longest_streak": L("7 · 30 · 100 天", "7 · 30 · 100 days"), "max_subagents": L("≥ 5 个", "≥ 5")]
        var rows: [(String, String, String, String, NSColor)] = ck.map { c in
            let x = ABText.checkup(c)
            return (x.label, x.shown, refs[c["id"].s] ?? "", x.tier, x.color)
        }
        rows.insert((L("模型花费", "Model cost"), fmtUSD(data["cost"].d), "—", L("只看看", "FYI"), AB.ink), at: 1)
        for r in rows {
            AB.fitLine({ AB.sans(r.0, $0, .regular) }, 12, cols[0], y + 8, cols[1] - cols[0] - 8, least: 9.5)
            put(AB.mono(r.1, 12, .semibold), cols[1], y + 8)
            put(AB.mono(r.2, 9.5, .regular, AB.gray), cols[2], y + 10)
            put(AB.sans(r.3, 11, .semibold, r.4), cols[3], y + 9, align: 2)
            y += 30
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W - 60, height: 1).fill()
        }
        y += 18
        put(AB.sans(L("医嘱", "Doctor's orders"), 13, .bold), x0, y)
        y += 24
        for (k, a) in data["story"]["advice"].arr.enumerated() {
            y += AB.para(AB.sans("\(k + 1). " + a.s, 12.5, .regular), x0, y, W - 60 - 130, lineHeight: 19) + 4
        }
        // The stamp, a little crooked.
        let c = NSPoint(x: W - x0 - 60, y: y - 30)
        rotated(c, 12) {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 56, y: c.y - 56, width: 112, height: 112))
            ring.lineWidth = 2.2
            color(hex: "#C2410C").withAlphaComponent(0.85).setStroke()
            ring.stroke()
            put(AB.sans("★", 13, .bold, color(hex: "#C2410C")), c.x, c.y - 34, align: 1)
            put(AB.sans("DANGO", 15, .heavy, color(hex: "#C2410C")), c.x, c.y - 16, align: 1)
            put(AB.sans(L("体检专用章", "LAB APPROVED"), 11, .semibold, color(hex: "#C2410C")), c.x, c.y + 4, align: 1)
        }
        y = max(y, c.y + 40) + 14
        AB.ink.setFill()
        NSRect(x: x0, y: y, width: W - 60, height: 1).fill()
        y += 14
        put(AB.join([AB.sans(L("总评  ", "Verdict  "), 13, .bold), AB.sans(data["story"]["verdict"].s, 13, .regular)]), x0, y)
        y += 28
        put(AB.sans(L("参考范围是 Dango 自定的分档，不和别人比，也不是医学建议。", "Reference ranges are Dango's own tiers: not a ranking, not medical advice."), 10.5, .regular, AB.gray), x0, y)
        nav()
    }

    // MARK: 6 · 绝配

    private func matchScreen() {
        let m = data["match"]["code"].s
        label(L("06 · 绝配", "06 · MATCH"), 104)
        put(AB.sans(L("你的绝配是", "Your perfect match"), 17, .medium), x0, 128)
        put(AB.join([AB.mono(m + " ", 30, .bold), AB.sans(ABText.typeName(m), 30, .bold)]), x0, 152)
        let iw = (W - 60 - 30) / 2
        for (k, (c, who)) in [(code, L("你", "You")), (m, L("TA", "Them"))].enumerated() {
            let r = NSRect(x: x0 + CGFloat(k) * (iw + 30), y: 214, width: iw, height: 170)
            AB.fit(abtiImage("scene/T-" + c), r)
            put(AB.join([AB.sans(who + " ", 11.5, .regular, AB.gray), AB.mono(c, 11.5, .semibold), AB.sans(" " + ABText.typeName(c), 11.5, .regular)]), r.midX, r.maxY + 8, align: 1)
        }
        put(AB.sans("×", 20, .regular, AB.gray), W / 2, 288, align: 1)
        _ = AB.para(AB.sans(ABText.matchLine(code) + L("。", ""), 21, .bold), x0, 424, W - 60, lineHeight: 27, align: .center)
        var y: CGFloat = 486
        let rel = data["story"]["relations"].arr
        let pairs = ["H ↔ M", "B ↔ F", code.count == 4 ? "\(Array(code)[2]) = \(Array(code)[2])" : "", code.count == 4 ? "\(Array(code)[3]) = \(Array(code)[3])" : ""]
        for (k, r) in rel.enumerated() {
            put(AB.mono(pairs[min(k, 3)], 12, .bold), x0, y + 8)
            put(AB.sans(r.s, 12.5, .regular), x0 + 76, y + 7)
            y += 34
            AB.line.setFill()
            NSRect(x: x0, y: y - 1, width: W - 60, height: 1).fill()
        }
        y += 22
        let box = NSRect(x: x0, y: y, width: W - 60, height: 74)
        AB.round(box, 18, AB.tile)
        put(AB.sans(L("@ 一个这样的朋友来看看", "@ a friend who's like this"), 14, .bold), box.minX + 18, box.minY + 18)
        put(AB.sans(L("TA 装上团子看完自己的，你们俩可以合成一张合盘卡", "Once they've seen theirs, you two get a pair card"), 11.5, .regular, AB.gray), box.minX + 18, box.minY + 42)
        let b = NSRect(x: box.maxX - 16 - 96, y: box.midY - 20, width: 96, height: 40)
        AB.round(b, 12, AB.ink)
        put(AB.sans(L("复制邀请", "Copy invite"), 13, .semibold, .white), b.midX, b.midY - 9, align: 1)
        if !bare { hits.append(("invite", b)) }
        nav(next: L("最后一屏：你的总卡 →", "Last one: your card →"))
    }

    // MARK: input

    private func drawToast() {
        guard let (msg, until) = toast, Date().timeIntervalSince1970 < until, !bare else { return }
        let t = AB.sans(msg, 12, .medium, .white)
        let r = NSRect(x: W / 2 - t.size().width / 2 - 16, y: H - 130, width: t.size().width + 32, height: 34)
        AB.round(r, 17, AB.ink.withAlphaComponent(0.92))
        put(t, r.midX, r.midY - t.size().height / 2, align: 1)
    }

    private func say(_ s: String) {
        toast = (s, Date().timeIntervalSince1970 + 2.5)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.needsDisplay = true }
    }

    // A click acts on mouse-up; a drag moves the window instead.
    private var downAt: NSPoint?
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { downAt = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - d.x, p.y - d.y) > 4 {
            downAt = nil
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = downAt else { return }
        downAt = nil
        if let (id, _) = hits.last(where: { $0.1.contains(p) }) {
            act(id)
        } else if screen != 7 {
            if p.x < W / 3 { if screen > 1 { go(screen - 1) } } else if screen != 1 || t >= 3 || reduce { go(screen + 1) }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: if screen > 1 { go(screen - 1) }
        case 124: go(screen + 1)
        case 53: act("close")
        default: super.keyDown(with: event)
        }
    }

    private func act(_ id: String) {
        switch id {
        case "close":
            if screen == 7 { onClose?() } else { go(7); copyCard() }
        case "prev": if screen > 1 { go(screen - 1) }
        case "next": go(screen + 1)
        case "replay": go(screen)
        case "share": shareScreen()
        case "shareCard": copyCard()
        case "invite":
            let m = data["match"]["code"].s
            // No link: the domain isn't ours (user 2026-11-07: 「不需要二维码dango.app，啥都不需要」).
            let line = L("我是 \(code) \(ABText.typeName(code))，你的绝配可能是 \(m) \(ABText.typeName(m))。",
                         "I got \(code) \(ABText.typeName(code)). My perfect match might be \(m) \(ABText.typeName(m)).")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            say(L("邀请复制好了，可以直接粘贴", "Invite copied; paste it anywhere"))
        default: break
        }
    }

    /// This screen at 1080 × 1920, bare, saved and copied.
    private func shareScreen() {
        let v = StoryView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.data = data
        v.screen = screen
        v.t = 10
        v.bare = true
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        let path = exportDir + "/abti-\(code)-\(screen).png"
        if exportPage(v, path, copy: true) { say(L("这一屏存好了，图片也复制好了，可以直接粘贴", "Saved and copied; paste it anywhere")) }
    }

    /// The card at 1080 × 1920: saved and on the clipboard.
    func copyCard() {
        let v = BossCardView(size: NSSize(width: W, height: H), data: data)
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        if exportPage(v, exportDir + "/abti-\(code).png", copy: true) { say(L("总卡存好了，也复制到剪贴板了", "Card saved to ~/Pictures/DANGO and copied")) }
    }
}

/// The story window: one at a time, scaled down to fit a small screen.
final class StoryWindow {
    static var shared: NSWindow?

    static func show() {
        if let w = shared, let v = w.contentView as? StoryView {
            // Closed earlier: straight to the card, on fresh numbers.
            if !w.isVisible {
                v.data = dangoJSON(["abti", "--json"]) ?? v.data
                v.go(7)
            }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
            return
        }
        guard let data = dangoJSON(["abti", "--json"]) else { return }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let k = min(1, (vf.height - 40) / 960)
        let size = NSSize(width: 540 * k, height: 960 * k)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        let v = StoryView(frame: NSRect(origin: .zero, size: size))
        v.setBoundsSize(NSSize(width: 540, height: 960))
        v.data = data
        v.onClose = { w.orderOut(nil) }
        w.contentView = v
        w.center()
        shared = w
        // The story plays once; after that the result is the card, and ‹
        // walks back through the story.
        let seen = UserDefaults.standard.bool(forKey: "abtiShown")
        UserDefaults.standard.set(true, forKey: "abtiShown")
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        v.go(seen ? 7 : 1)
    }
}

/// The card's explainer pages (16 types, scale and margin, the crew) in a
/// plain window, with a button that saves the page as an image and copies it.
final class PageWindow: NSObject {
    static var open: [String: PageWindow] = [:]
    let id: String
    let data: JV
    let window: NSWindow

    static func page(_ id: String, _ data: JV) -> ABPage {
        switch id {
        case "scale": return ScaleView(size: NSSize(width: 540, height: 604), data: data)
        case "roles": return RolesView(size: NSSize(width: 540, height: 724), data: data)
        default: return TypesView(size: NSSize(width: 540, height: 960), data: data)
        }
    }

    static func show(_ id: String) {
        if let p = open[id] {
            NSApp.activate(ignoringOtherApps: true)
            p.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let data = dangoJSON(["abti", "--json"]) else { return }
        let p = PageWindow(id: id, data: data)
        open[id] = p
        NSApp.activate(ignoringOtherApps: true)
        p.window.makeKeyAndOrderFront(nil)
    }

    init(id: String, data: JV) {
        self.id = id
        self.data = data
        let v = PageWindow.page(id, data)
        let full = v.bounds.size
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let k = min(1, (vf.height - 80) / full.height)
        let size = NSSize(width: full.width * k, height: full.height * k)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = ["types": L("ABTI 人格图鉴", "All ABTI types"), "scale": L("规模和压榨率怎么算", "How scale and margin work"),
                        "roles": L("团子构成怎么算", "How the crew works")][id] ?? ""
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        v.frame = NSRect(origin: .zero, size: size)
        v.setBoundsSize(full)
        window.contentView = v
        let b = NSButton(title: L("导出图片", "Export image"), target: self, action: #selector(export))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.sizeToFit()
        let acc = NSTitlebarAccessoryViewController()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: b.frame.width + 12, height: 28))
        b.frame.origin = NSPoint(x: 0, y: (28 - b.frame.height) / 2)
        box.addSubview(b)
        acc.view = box
        acc.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(acc)
        window.center()
    }

    @objc func export() {
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        let path = exportDir + "/abti-\(id).png"
        if exportPage(PageWindow.page(id, data), path, copy: true) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

/// The first time there is a result, a small window asks first instead of
/// the story opening by itself (user, 2026-11-11: 「进入之后，有个小弹窗邀请
/// 用户进入看他的abti结果，然后一页一页看，最后到他的结果」「在安装完第一
/// 次打开的时候有一个abti的过程」): a waving 团子, how much history was read
/// and what the work came to, and “See it” (the story from its first screen,
/// the scan, page by page to the card) or “Later” (asked again at the next
/// launch, until the story has been seen once; the right-click menu has it
/// any time). Return starts, Esc is later.
final class InviteView: NSView {
    var data = JV(nil)
    var onStart: (() -> Void)?
    var onLater: (() -> Void)?
    private var hits: [(String, NSRect)] = []
    private var timer: Timer?
    private var t = 0.0

    static let size = NSSize(width: 360, height: 318)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The waving paw moves; a snapshot draws one still frame.
    func animate() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.t += 1.0 / 30.0
            self.needsDisplay = true
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// The sentence under the title: days read and the work's worth.
    var line: String {
        let days = data["scan_days"].i, usd = fmtUSD(data["usd"].d)
        return days > 1
            ? L("团子们翻完了你 \(days) 天的工作记录，一共替你打了 \(usd) 的工。来看看你是哪一种老板？",
                "Your dangos went through \(days) days of your work with AI: \(usd) of work in all. Want to see what kind of boss you are?")
            : L("团子们翻完了你的工作记录，一共替你打了 \(usd) 的工。来看看你是哪一种老板？",
                "Your dangos went through your work with AI: \(usd) of work in all. Want to see what kind of boss you are?")
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        let W = bounds.width, H = bounds.height
        AB.round(NSRect(x: 0, y: 0, width: W, height: H), 18, .white)
        AB.stroke(NSRect(x: 0, y: 0, width: W, height: H), 18, AB.line)
        // The close cross: later.
        let x = AB.sans("✕", 13, .regular, AB.gray)
        let xr = NSRect(x: W - 34, y: 12, width: 22, height: 22)
        put(x, xr.midX - x.size().width / 2, xr.midY - x.size().height / 2)
        hits.append(("later", xr))
        // A waving 团子 on a soft tile.
        AB.round(NSRect(x: W / 2 - 64, y: 26, width: 128, height: 92), 22, AB.tile)
        Pose.time = t
        drawFittedDango(NSRect(x: W / 2 - 46, y: 32, width: 92, height: 80), role: nil, status: "happy")
        // ABTI, the title, the line.
        let label = AB.mono("ABTI", 11, .semibold, AB.gray, kern: 1.2)
        put(label, W / 2 - label.size().width / 2, 132)
        let title = AB.sans(L("你的 ABTI 出来了", "Your ABTI is ready"), 22, .heavy)
        AB.para(title, 24, 150, W - 48, align: .center)
        AB.para(AB.sans(line, 13, .regular, AB.gray), 30, 184, W - 60, lineHeight: 19, align: .center)
        // See it (dark), later (light).
        let start = AB.pill(L("开始看 →", "See it →"), 0, 0, dark: true, size: 14, padX: 22, padY: 8, draw: false)
        let later = AB.pill(L("稍后", "Later"), 0, 0, dark: false, size: 14, padX: 18, padY: 8, draw: false)
        let gap: CGFloat = 10, y = H - 24 - start.height
        let x0 = W / 2 - (start.width + gap + later.width) / 2
        hits.append(("start", AB.pill(L("开始看 →", "See it →"), x0, y, dark: true, size: 14, padX: 22, padY: 8)))
        hits.append(("later", AB.pill(L("稍后", "Later"), x0 + start.width + gap, y, dark: false, size: 14, padX: 18, padY: 8)))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hits.last(where: { $0.1.insetBy(dx: -4, dy: -4).contains(p) }) else {
            window?.performDrag(with: event)
            return
        }
        hit.0 == "start" ? onStart?() : onLater?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onStart?()
        case 53: onLater?()
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        hits.forEach { addCursorRect($0.1, cursor: .pointingHand) }
    }
}

/// Borderless, so it needs telling that it may take the keyboard (Return, Esc).
private final class InvitePanel: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class InviteWindow {
    static var shared: NSWindow?

    /// Asks once per launch; nothing when the story has been seen or the
    /// result can't be read yet.
    static func show() {
        guard shared == nil, !UserDefaults.standard.bool(forKey: "abtiShown"), let data = dangoJSON(["abti", "--json"]) else { return }
        let v = InviteView(frame: NSRect(origin: .zero, size: InviteView.size))
        v.data = data
        let w = InvitePanel(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = v
        let close = {
            v.stop()
            w.orderOut(nil)
            shared = nil
        }
        v.onLater = close
        v.onStart = {
            close()
            StoryWindow.show()
        }
        w.center()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        v.animate()
    }
}
