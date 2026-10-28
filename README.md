# ShadowCorp — 你的 Claude，和它的工作日报

住在屏幕角落的"你的 Claude"：记得自己替你干了多少活（按人类等价工时算）、什么时候干的、干的是哪一类事，攒 XP、升段位（青铜 → 王者），每天给你一张好看到能发出去的日报卡。不统计 token，不存 prompt、代码或路径。

设计稿：[docs/DESIGN.md](docs/DESIGN.md)（2026-10-29，替代原规格书 [docs/SPEC.md](docs/SPEC.md) 的"影子公司"设定；计分引擎沿用）。取舍与待定：[docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)。

## 日报卡

```bash
shadowcorp card --day yesterday --names
```

生成 1080×1350 的 PNG 到 `~/Pictures/ShadowCorp/`，复制到剪贴板，并打开。内容：角色当天的表情和一句话、人类等价工时与杠杆、24 小时时间线、做得最多的三个会话、四类工作（建造 / 修缮 / 守护 / 沉淀）的工时占比、回合 / 文件 / 测试 / 一次过、段位进度。`--names` 才会带上会话标题和项目名（它们只存本机，默认不上卡）；`--day` 接 `YYYY-MM-DD`、`today`、`yesterday`。文字版：`shadowcorp report --day …`。

## 产出怎么算

1. 每个回合估一个"人类工程师做同样的事要多少分钟"H（规格书 §5.3 的公式：任务类型基础分钟 + 文件数 + 改动行数 + 跑了测试 + 子 agent 数 + 提交/合并，单回合封顶 360 分钟，每日 6 人日、每周 30 人日封顶）。头条就是这个数：「我替你干了 16.5 小时的活」。
2. **金额默认不显示**。想看的话在 `~/.shadowcorp/config.toml` 填 `[value] hourly_rate_usd = <你的时薪>`，报告里会多一行 ≈ $。
3. **XP = 封顶后的人类等价分钟数**，只增不减，不受时薪影响。
4. **段位**按累计 XP：青铜 0 · 白银 1,000 · 黄金 5,000 · 铂金 15,000 · 钻石 40,000 · 大师 100,000 · 王者 250,000。每个段位分 IV → I 四个小段，王者不分段。一周重度使用约 4,000–10,000 XP，所以黄金在第一两周、铂金在第一个月、王者大约一年。

## 桌面小部件

打开方式：双击 **/Applications/ShadowCorp.app**（Launchpad 里也有），或者在终端运行：

```bash
shadowcorp widget
```

打包：`apps/widget/bundle.sh` 生成 `target/release/ShadowCorp.app`（含图标，ad-hoc 签名），复制到 /Applications 即可。重复打开不会出现第二个面板。

一个 256×78 的悬浮面板停在屏幕右下角，置顶、不占 Dock、不抢焦点：总产出 $、今日 $、段位徽章、XP 和距下一小段的差距、进度条；agent 干活时右上角有绿点在闪；晋级时徽章发光并显示"晋级 → 黄金 IV"。可以拖到任何位置，右键菜单：打开仪表盘 / 登录时自动启动 / 回到右下角 / 退出。

**单击小部件**展开成仪表盘（从右下角向左上长出来）：

- 段位、XP、到下一小段的进度
- 今日 / 本周 / 本月 / 总计的 $ 和人日
- 最近 30 天每日 $ 柱图（标出最高的一天和今天，鼠标悬停看任意一天）
- 段位之路：青铜 → 王者，标出你现在的位置
- 最近 30 天按任务类型的 $ 分布
- 最近 6 个回合的明细

点仪表盘顶部或屏幕上任何别的地方就收回去。纯本地：读 `~/.shadowcorp/widget.json`（守护进程有新活动就重写），每 2 秒刷新。

原生 Swift（AppKit），150 KB。`apps/widget/build.sh` 只出裸二进制；`apps/widget/bundle.sh` 出 .app。

## 当前进度

| 部分 | 状态 |
| --- | --- |
| 采集：Claude Code 插件 hooks、spool、SQLite、历史回填 | ✅ |
| 计分：分类器 v1、人日公式、$ 价值、XP 与段位 | ✅ |
| 展示：桌面小部件、终端结算框、状态栏、`stats` | ✅ |
| 旧设定（成就、公司阶段、网页面板 `shadowcorp panel`） | 仍可用，不再是主界面 |
| Codex / git 接入、安装脚本、Windows / Linux | 未开始 |

## 构建与试用

```bash
cargo build --release
```

不碰真实数据，回放 fixtures 看结算框：

```bash
SHADOWCORP_HOME=/tmp/sc-demo SHADOWCORP_TZ=+08:00 ./target/release/shadowcorp replay fixtures/hooks/claude_code
```

把你的 Claude Code 历史导入一个临时目录（只读 `~/.claude/projects`）：

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
