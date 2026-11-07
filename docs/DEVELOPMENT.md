# 开发说明

产品介绍在 [README](../README.md)。这里是开发者需要的：仓库结构、怎么构建和测试、怎么接 Claude Code、Codex 和 DeepSeek Harness、怎么打包，以及全部命令。设计和取舍在 [DESIGN.md](DESIGN.md)，待定的问题在 [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md)，给 AI 助手看的项目规则在 [CLAUDE.md](../CLAUDE.md)。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `crates/core` | 纯逻辑，不做 IO：事件格式、话题分类、职业归类与时薪、计分、成就 |
| `crates/daemon` | 守护进程：采集、spool、SQLite、入库、历史导入、跟读 Claude Code、Codex 和 DeepSeek Harness 的记录（`dsh.rs`）、老板人格（`abti.rs`）、报告 |
| `crates/cli` | 单个二进制 `dango` |
| `apps/widget` | 桌面 App（Swift / AppKit）：宠物、面板、办公室、老板人格、报告窗口；`build.sh`、`bundle.sh`、`package.sh` |
| `assets` | 职业表和时薪（`occupations.toml`）、模型单价（`model_prices.toml`）、老板人格的门槛和文案（`abti.json`）、计分单位 |
| `plugins/claude-code` | 可选的 Claude Code 插件（钩子） |
| `fixtures` | 测试用的 hook 事件、Claude Code transcript、Codex rollout、黄金回合 |
| `site` | 老板人格的介绍网站（静态，`python3 -I site/build.py`，还没上线） |

## 构建和测试

```bash
cargo build --release
```

```bash
cargo test --workspace
```

```bash
apps/widget/bundle.sh
```

`bundle.sh` 出 `target/release/Dango.app`，复制到 /Applications 就能用；`build.sh` 只出裸二进制 `target/release/dango-widget`，`SWIFT_TARGET=arm64-apple-macos13.0` 可以指定目标系统。

提交前跑隐私扫描，确认本地数据里没有路径、代码和 prompt：

```bash
cargo run -p cli -- privacy-scan
```

## 不碰真实数据试一下

所有命令都认 `DANGO_HOME`，指向临时目录就和你自己的数据隔开。回放测试用的 hook 事件：

```bash
DANGO_HOME=/tmp/dango-demo DANGO_TZ=+08:00 ./target/release/dango replay fixtures/hooks/claude_code
```

把你的 Claude Code 和 Codex 历史导进临时目录（只读 `~/.claude/projects` 和 `~/.codex/sessions`）：

```bash
DANGO_HOME=/tmp/dango-mine ./target/release/dango backfill
```

```bash
DANGO_HOME=/tmp/dango-mine ./target/release/dango abti
```

模拟一台新装的 Mac：建一个临时家目录，把 `.claude/projects` 和 `.codex/sessions` 软链到真的，然后 `HOME=<临时目录> DANGO_HOME=<临时目录>/.dango dango daemon`。守护进程第一次启动会导入历史，之后跟读两边的记录。

## 打包给别人

```bash
DANGO_RELEASE_URL=https://<放安装包的地址> apps/widget/package.sh
```

除了下面说的 dmg，还出两个给一行命令安装用的文件：`Dango-<版本>.zip`（用 `ditto` 打包，签名保留）和 `install.sh`（从 `apps/widget/install.sh.in` 生成，写进版本号、zip 的 SHA-256 和 `DANGO_RELEASE_URL`）。两个一起传到那个地址，用户运行 `curl -fsSL <地址>/install.sh | sh`：下载、核对校验值（不对就停，什么都不装）、放进 /Applications（不能写就放 ~/Applications）、打开；再跑一次就是更新（先退出正在跑的 Dango）。用 curl 下载的文件没有「来自互联网」的标记，所以 Gatekeeper 不拦；浏览器下载的 dmg 会被拦。安装脚本认 `DANGO_URL`（换下载地址）、`DANGO_APP_DIR`（换安装目录）、`DANGO_NO_OPEN=1`（装完不打开），本机测试就用这三个：

```bash
python3 -m http.server 8790 --directory target/dist
```

```bash
curl -fsSL http://localhost:8790/install.sh | DANGO_URL=http://localhost:8790 DANGO_APP_DIR=/tmp/dango-apps DANGO_NO_OPEN=1 sh
```

出 `target/dist/Dango-<版本>.dmg`：Dango.app 里带着小部件和 `dango` 命令（放在 `Contents/Helpers/dango`，因为磁盘不分大小写，放进 `Contents/MacOS` 会和 App 自己的 `Dango` 撞成一个文件），Apple 芯片和 Intel 的通用二进制，macOS 13 起。只有 ad hoc 签名，没有公证，对方第一次打开要去「系统设置 → 隐私与安全性」点「仍要打开」。

第一次打开时 App 写 `~/Library/LaunchAgents/com.dango.daemon.plist`（指向 App 里的 `dango`）并启动守护进程，打开宠物的「登录时自动启动」。已经有指向别处的 agent（比如开发机的 `~/.local/bin/dango`）就不动。App 原地更新后会把守护进程重启一次。想看 App 会写什么：

```bash
/Applications/Dango.app/Contents/MacOS/Dango --print-daemon-agent
```

## 接 Claude Code

默认不用装任何东西：守护进程每 2 秒读一次 Claude Code 自己写的会话记录（`~/.claude/projects/<项目>/<会话>.jsonl` 和子 agent 的记录，只读最近 36 小时动过的文件、只读新写完的整行），和历史导入用同一个读法，事件 id 相同，所以只算一次。

同时读 Claude Code 给每个运行中的进程写的状态文件 `~/.claude/sessions/<pid>.json`：`status` 在这一行之后变成 idle，回合马上结算；`waitingFor` 有值（权限确认、提问之类的对话框开着），那个会话就是「等你批准」，只记一条通知事件，对话框里的字（比如要跑的命令）不存。这个文件不是 Claude Code 公开的接口：读不到、字段没有、进程已经不在，都当作不知道，退回只看会话记录（Claude 说完 20 秒后结算，有命令还在跑的等它跑完）。子 agent 也从会话记录里数：Task / Agent 调用发出去算一个在干的帮手，结果回来算干完。

装了插件就由钩子实时报，跟读自动关掉，钩子报过的会话也不再读。插件唯一多给的是 Claude Code 界面里每回合结束时的结算框；不装插件可以在团子的右键菜单里打开「结算时发系统通知」代替。开发机上装插件：

1. 把 `dango` 放到 PATH 上，例如 `install -m 0755 target/release/dango ~/.local/bin/`。
2. `claude plugin marketplace add ~/dango`，再 `claude plugin install dango@dango`。
3. 可选状态栏，写进 `~/.claude/settings.json`：`{ "statusLine": { "type": "command", "command": "dango status --claude" } }`。

插件装的是这个仓库的 git HEAD：改了钩子要先提交，再 `claude plugin marketplace update dango`、`claude plugin update dango@dango`，然后重启 Claude Code。

## 接 Codex

不用装，也不用在 Codex 里信任任何东西：守护进程每秒读一次 Codex 自己写的会话日志（`~/.codex/sessions/年/月/日/*.jsonl`，同样只读最近 36 小时、只读整行），和导入历史用同一个读法。Codex 的每一步按和 Claude Code 一样的规则归给职业：命令、`apply_patch`（按文件拆开）、MCP 工具、子 agent。以前装过的 `~/.codex/hooks.json` 可以删掉，`dango hook --codex` 现在什么都不做。

## 接 DeepSeek Harness

也不用装（`crates/daemon/src/dsh.rs`）。DeepSeek Harness 把每个会话记成一个只追加的事件日志 `~/.dsh/sessions/<项目>/session-<id>/session.v4.jsonl.zstd`：一个接一个的 zstd 帧，里面是一行行 JSON（`turn/start`、`user/message`、`tool/call`、`tool/result`、带 token 用量的 `assistant/message`、`turn/end` 等）。守护进程第一次见到它时把全部历史导一次（meta `history_imported:deepseek`），之后每秒读新写完的整帧（写到一半的帧等下次），事件 id 和导入时一样，所以只算一次。它的工具就是 Claude Code 那一套换成小写（`bash`、`read`、`write`、`edit`、`glob`、`grep`、`web_fetch`、`web_search`、`subagent`），参数同名，所以每一步走和 Claude Code 一样的归职业规则；它自己的杂务（`job_*`、`schedule_*`、目标、插件）不算谁的活。模型花费按 `assistant/message` 里的 token 和 DeepSeek 官方价格算（`assets/model_prices.toml`，按高峰价，非高峰时段实际只要一半）。DeepSeek 以子 agent 身份跑的会话（`delegationDepth` > 0）暂时不读：里面没写它属于父会话的哪个回合，父会话那边照样记「帮手出去 / 回来」。`config.toml` 里 `[sources] deepseek = false` 可以关掉。

## 数据在哪

都在 `~/.dango`（`DANGO_HOME` 可改）：

| 文件 | 内容 |
| --- | --- |
| `data.db` | SQLite：事件（只追加）、回合、会话、计数器 |
| `widget.json` | 守护进程给 App 写的面板数据，有新活动就重写 |
| `spool/` | 钩子写的事件，守护进程没跑时也不丢 |
| `config.toml` | 语言等设置（`dango lang zh|en`） |
| `daemon.log` | 守护进程日志 |

导出的图片存在 `~/Pictures/DANGO`。

## 命令

| 命令 | 作用 |
| --- | --- |
| `dango widget` | 打开桌面 App |
| `dango status [--claude]` | 一行状态（`--claude` 给 Claude Code 的状态栏用） |
| `dango abti [--json]` | 老板人格的结果 |
| `dango abti --report day\|week\|month\|year\|total [--day DATE]` | 报告窗口一页的数据（JSON） |
| `dango card [--week\|--month\|--year] [--day DATE] [--out PNG] [--no-open]` | 导出 4:5 分享图到 `~/Pictures/DANGO` 并复制（会覆盖剪贴板） |
| `dango report [--week\|--month\|--year] [--day DATE] [--names] [--tool claude\|codex\|deepseek] [--json]` | 文字版报告 |
| `dango lang [zh\|en]` | 查看或切换语言 |
| `dango stats` / `dango badges` | 产出总览 / 旧的成就图鉴 |
| `dango panel` | 旧的网页面板（`~/.dango/panel.html`） |
| `dango backfill [--claude-dir DIR] [--codex-dir DIR] [--dsh-dir DIR]` | 导入历史（守护进程要先停；可以重复跑，不会重复计） |
| `dango daemon` | 前台跑守护进程 |
| `dango hook [--codex]` | 插件钩子的入口：读 stdin，写 spool，永远 exit 0 |
| `dango replay PATH…` | 回放 hook fixtures |
| `dango rebuild [--allow-lower]` | 从事件表重建全部派生数据（总数会变少时要 `--allow-lower`） |
| `dango privacy-scan` | 检查本地数据里没有路径、代码、prompt |

`--day` 接 `YYYY-MM-DD`、`today`、`yesterday`，选的是那一天所在的周期。

App 的截图和调试参数（`--snapshot-dashboard`、`--snapshot-pet`、`--abti … --page …` 等）见 [CLAUDE.md](../CLAUDE.md) 的「命令」一节。

## 验证记录

2026-11-04：

- `cargo test --workspace` 126 个测试通过，隐私扫描通过。新用例 `a_followed_session_without_hooks_shows_live`：没有钩子时，团子心情是「在干」、帮手出去 1 个回来 0 个、对话框开着时办公室显示等你批准（只记一次，不存命令）、状态文件一变 idle 回合马上结算、进程不在的状态文件不算。
- 打包版守护进程按没装插件的新用户跑：团子从「我在，随时开工」变成「在当研究员，别催」，在干的会话数和 `~/.claude/sessions` 里 busy 的进程数一致（3 个）。

2026-11-02：

- `cargo test --workspace` 125 个测试通过，隐私扫描通过。
- 打包版守护进程按新用户跑：导入真实历史约 4 秒（Claude Code 28 个会话、348 个回合，Codex 20 个会话、133 个回合）；之后几秒内跟读到新写的回合。
- 开发机上同一个守护进程第一次启动的导入：$ 总数和事件数前后一样（只会找到已经算过的）。

2026-10-28：

- hook 耗时 1000 次：p95 3.5 ms，p99 4.1 ms；Stop 含结算框 p95 4.0 ms。
- 守护进程 `kill -9` 后钩子继续写 spool，重启后 18/18 事件入库；常驻 10 MB，空闲 CPU 0.1%。
- 真实历史回填：22 个 transcript、110 MB，0.18 秒；重跑新增 0。
