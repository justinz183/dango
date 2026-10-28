# ShadowCorp — 你的 Claude，和它的工作日报

住在屏幕角落的"你的 Claude"：一只桌面宠物，有活就坐在小桌前干、按正在干的活换装；记得自己替你干了多少活、这些活请人来做要花多少钱、相当于请了谁（程序员、文案、视频剪辑、数据分析师……），每天给你一张好看到能发出去的日报卡。不统计 token，不存 prompt、代码或路径。

设计稿：[docs/DESIGN.md](docs/DESIGN.md)（v3，2026-10-29，替代原规格书 [docs/SPEC.md](docs/SPEC.md) 的"影子公司"设定和每回合分钟公式）。取舍与待定：[docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)。

## 日报 / 周报 / 月报卡

```bash
shadowcorp card --day yesterday --names
```

```bash
shadowcorp card --week --names
```

```bash
shadowcorp card --month --names
```

生成 1080 宽的竖图 PNG 到 `~/Pictures/ShadowCorp/`，复制到剪贴板，并打开（高度随内容，介于 4:5 和 9:16 之间）。也可以在仪表盘底部点「生成今日日报」，或右键小部件。日报内容：角色当天的表情和一句话、请人来做要花多少 $、工时与杠杆、24 小时时间线（按职业上色）、做得最多的会话、相当于请了谁（每种职业的工时 × 时薪）、回合 / 文件 / 测试 / 一次过、段位进度。`--names` 才会带上会话标题和项目名（它们只存本机，默认不上卡）；`--day` 接 `YYYY-MM-DD`、`today`、`yesterday`。

周报：每天一根按职业堆叠的 $ 柱子、相当于请了谁、花时间最多的三件事、活跃天数 / 回合 / 测试 / 杠杆、段位从周一到周日的变化。月报：日历热力图（颜色越深这天产出越多）、24 小时作息分布（「你最常在 14–17 点开工」）、相当于请了谁、三件事、段位变化。文字版：`shadowcorp report [--week|--month] …`。

## 产出怎么算

1. **每一步归给"该请谁来做"的职业**，并估这个人要几分钟：改代码 → 程序员（按行数），改网页 → 网页开发，跑测试 / 改测试 → 测试工程师，写 md / docx → 文案写作（500 字/小时），ffmpeg / 配音 / 字幕 → 视频剪辑，出图 → 平面设计，搜索 / 读网页 → 研究员，数据脚本 → 数据分析师，金融数据或聊股票时的研究 → 金融分析师，OCR → 资料录入，装环境 / 改配置 → 运维。每回合再加 5 分钟（读需求、汇报）和每个子 agent 12 分钟；单回合封顶 6 小时，每日 6 人日、每周 30 人日封顶。完整规则见 [docs/DESIGN.md §3](docs/DESIGN.md)。
2. **$ = 每种职业的分钟 × 该职业的时薪**，时薪是美国劳工统计局 2025 年 5 月各职业时薪中位数（`assets/occupations.toml`，只算工资不含福利）。头条就是这个数：「今天这些活，请人来做要花 $951」。
3. **单日纪录**：每天的 $ 和历史最高的一天比，结算框、小部件、日报卡上都有一条"今日 / 单日纪录"的进度；破纪录当场庆祝。没有段位和 XP。
4. **和上次比**：周报、月报写出"上周 $4,492 → 本周 $3,595 · −20%"；角色会记得这些（"这周比上周多 $600"、"一起干活的第 30 天"）。

## 桌面小部件

打开方式：双击 **/Applications/ShadowCorp.app**（Launchpad 里也有），或者在终端运行：

```bash
shadowcorp widget
```

打包：`apps/widget/bundle.sh` 生成 `target/release/ShadowCorp.app`（含图标，ad-hoc 签名），复制到 /Applications 即可。重复打开不会出现第二个面板。

**桌面宠物**：一个圆滚滚的墨团站在卡片上。有 agent 在跑的时候它就坐到小桌子前敲键盘（屏幕上有代码在滚、光标在闪、两只手在打字），带子 agent 时身后多出几个小帮手；回合结算时从桌上递出一张小票「+$78 · 程序员」往上飘，伴一声轻响。它会**按正在干的活换装**：程序员连帽衫、网页开发胸前 `</>`、测试工程师举放大镜、运维安全帽、数据分析师抱图表、金融分析师领带、研究员圆眼镜、文案耳朵上夹铅笔、翻译顶着「译」、平面设计贝雷帽、视频剪辑耳机、资料录入抱一摞表格。没活的时候端杯咖啡等你、会眨眼、会呼吸；凌晨还在干就犯困；破了单日纪录就星星眼。只有角色本身接受点击，透明的部分点穿到桌面；拖它卡片一起走。

**卡片**（256×78，置顶、不占 Dock、不抢焦点）：总产出 $，今日 $，现在在当什么（职业色的圆点），今日 / 单日纪录进度条；agent 干活时右上角有绿点在闪；破纪录时显示"单日新高 ✦"。可以拖到任何位置，右键菜单：打开仪表盘 / 生成今日日报 / 登录时自动启动 / 显示桌面宠物 / 结算提示音 / 回到右下角 / 退出。提示音在 23:00–8:00 自动静音。

鼠标停在卡片上，它会说一句话，内容来自真实数据：在当谁、带几个帮手、刚干完什么值多少钱、这周比上周多多少、一起干活的第几天、破了纪录、太晚了。

**单击**展开成仪表盘（从右下角向左上长出来）：

- 累计 $、在当谁、今日 / 单日纪录进度、一起干活第几天
- 全部 / Claude Code / Codex 切换
- 今日 / 本周 / 本月 / 总计的 $ 和工时
- 最近 30 天每日 $ 柱图（标出最高的一天和今天，鼠标悬停看任意一天）
- 相当于请了谁（30 天），超过 6 种可展开
- 最近 6 个回合的明细

点仪表盘顶部或屏幕上任何别的地方就收回去。纯本地：读 `~/.shadowcorp/widget.json`（守护进程有新活动就重写），每 2 秒刷新。

原生 Swift（AppKit），150 KB。`apps/widget/build.sh` 只出裸二进制；`apps/widget/bundle.sh` 出 .app。

## 当前进度

| 部分 | 状态 |
| --- | --- |
| 采集：Claude Code 插件 hooks、Codex hooks、spool、SQLite、两边的历史回填 | ✅ |
| 计分：按职业计时、BLS 时薪折算 $、单日纪录与同比 | ✅ |
| 展示：桌面小部件、终端结算框、状态栏、`stats`；Claude Code 和 Codex 分开显示 | ✅ |
| 旧设定（成就、公司阶段、网页面板 `shadowcorp panel`） | 仍可用，不再是主界面 |
| git 接入、安装脚本、Windows / Linux | 未开始 |

## 构建与试用

```bash
cargo build --release
```

不碰真实数据，回放 fixtures 看结算框：

```bash
SHADOWCORP_HOME=/tmp/sc-demo SHADOWCORP_TZ=+08:00 ./target/release/shadowcorp replay fixtures/hooks/claude_code
```

把你的 Claude Code 和 Codex 历史导入一个临时目录（只读 `~/.claude/projects` 和 `~/.codex/sessions`）：

```bash
SHADOWCORP_HOME=/tmp/sc-mine ./target/release/shadowcorp backfill
```

```bash
SHADOWCORP_HOME=/tmp/sc-mine ./target/release/shadowcorp stats
```

```bash
SHADOWCORP_HOME=/tmp/sc-mine ./target/release/shadowcorp badges
```

## 接入 Claude Code（手动，M8 前没有安装脚本）

1. 把二进制放到 PATH 上，例如 `cp target/release/shadowcorp ~/.local/bin/`。
2. 导入历史：`shadowcorp backfill`。
3. 运行守护进程：`shadowcorp daemon`（开机自启的 LaunchAgent 属于 M8）。
4. 装插件：`claude plugin marketplace add ~/shadowcorp`，再 `claude plugin install shadowcorp@shadowcorp`。
5. 可选状态栏，加进 `~/.claude/settings.json`：`{ "statusLine": { "type": "command", "command": "shadowcorp status --claude" } }`

守护进程没运行时事件照样落盘，下次启动补算；结算框只在守护进程运行时出现。

## 接入 Codex

1. 把 [plugins/codex/hooks.json](plugins/codex/hooks.json) 复制到 `~/.codex/hooks.json`，把里面的 `shadowcorp` 换成绝对路径（Codex 桌面版不一定能找到 `~/.local/bin`）。
2. 在 Codex 里用 `/hooks` 审阅并信任这些 hook（Codex 要求非托管 hook 先信任才会运行，改过文件要重新信任）。
3. `shadowcorp backfill` 会一起导入 `~/.codex/sessions` 的历史。每个工具各有自己的分界点（第一个实时事件），所以重复跑不会重复计。信任 hook 之后再跑一次，可以补上中间那段。

Codex 的每一步按和 Claude Code 一样的规则归给职业：命令（`Bash` / unified exec）、`apply_patch`（按文件拆开）、MCP 工具、子 agent。

**分开看**：
- 仪表盘顶部有「全部 / Claude Code / Codex」切换，今日 / 本周 / 本月 / 总计、30 天柱图、相当于请了谁、最近回合都会跟着切。"相当于请了谁"超过 6 种时，点「还有 N 种 · 展开 ▾」看全部，「收起 ▴」收回。切到某个工具时点「生成今日日报」，生成的就是那个工具的日报。
- 卡片和文字报告加 `--tool claude` 或 `--tool codex`：`shadowcorp card --week --tool codex`。不加时卡片头部会写出两边各自的 $ 和占比。
- `shadowcorp stats` 在「请了谁」下面分别列出 Claude 和 Codex 各自请了谁。

已知限制：Codex 的结算框会以提示（warning）的样式出现；Codex 内置的网页搜索不触发 hook，只有回填时能看到；Codex 的电脑操作（`cua_repl` 的点击、滚动）不计钱，和 Claude 里点浏览器一样。

## 网页面板（旧）

```bash
shadowcorp panel
```

在浏览器打开 `~/.shadowcorp/panel.html`：像素办公室（员工随 agent 工作打字、子 agent 起身、闲时喝咖啡、久了打盹、夜里只亮台灯）、累计人日与阶段、周环、连续、纪录、成就墙（点开看详情）、职业图鉴、最近 8 周人日。守护进程在有新活动时重写数据，页面每 2 秒刷新；新解锁的成就会弹出庆祝。纯本地文件，不联网、不开端口。这是 SPEC 第 9–10 节桌面面板的网页预览版，菜单栏 App 属于 M3。

## 命令

| 命令 | 作用 |
| --- | --- |
| `shadowcorp hook` | 所有 hook 的入口：读 stdin，写 spool，永远 exit 0 |
| `shadowcorp status [--claude]` | 一行状态 |
| `shadowcorp widget` | 启动桌面小部件（右下角） |
| `shadowcorp report --day DATE [--names] [--json]` | 某天的文字日报 |
| `shadowcorp card --day DATE [--names] [--out PNG]` | 日报分享卡（PNG + 剪贴板） |
| `shadowcorp stats` / `badges` | 产出总览 / 旧的成就图鉴 |
| `shadowcorp panel` | 旧的网页面板 |
| `shadowcorp backfill` | 导入安装前的历史（可重复运行，不会重复计） |
| `shadowcorp daemon` | 守护进程：tail spool，Unix socket 应答 |
| `shadowcorp replay PATH…` | 回放 hook fixtures |
| `shadowcorp rebuild` | 从事件表重建（总数变少则拒绝） |
| `shadowcorp privacy-scan` | 检查本地数据里没有路径、代码、prompt |

## 验证结果（2026-10-28，本机）

- `cargo test --workspace`：83 个测试通过（含 53 个成就各一对“刚好解锁 / 差一点”用例、24 个计分黄金用例、崩溃与重复事件回放）。
- hook 耗时 1000 次：p95 3.5 ms，p99 4.1 ms（目标 < 20 / 50 ms）；Stop 含结算框 p95 4.0 ms（目标 < 300 ms）。
- 守护进程 `kill -9` 后继续写 spool，重启后 18/18 事件入库；常驻 10 MB、空闲 CPU 0.1%。
- 真实历史回填：22 个 transcript、110 MB，0.18 s；重跑新增 0。数据库中无任何 `/Users/` 路径；`privacy-scan` 通过。
