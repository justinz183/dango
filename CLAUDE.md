# 打工团子 Dango — 衡量 AI 编码产出

"团子"（英文 Dango，旧名 ShadowCorp）是一只桌面宠物，有活就在办公室工位上干、按正在干的活换装；每一步按"该请谁来做"计时、按该职业的 BLS 时薪折成 $，和单日纪录、上周比，每天出一张日报卡。没有段位和 XP（v4 删了）。当前设计：docs/DESIGN.md v6（2026-10-29：每个领域一个代表、共 23 种职业（2026-10-31 按 ABTI 设计包加回文案 writer（含翻译）和产品经理 pm；文字按 2,000 字/小时，文件名带 prd / roadmap / 需求 / 规划 / 排期的算产品经理）（程序员下按步骤分网页 / 测试 / 运维），话题关键词分大类，插画办公室（2026-11-06 删掉了经典主题，11-07 删掉了矢量办公室）；并掉的旧 id 走 `[alias]`）；不封顶（2026-10-29 起，回合 / 日 / 周都不封，assets/scoring.toml 只剩单位）；"影子公司 / 办公室 / 徽章"设定已收起，成就目录 assets/achievements.json 仍在但不是主界面。

## 命令
- 构建：`cargo build --workspace`（发布：`cargo build --release`，二进制 `target/release/dango`）
- 小部件：`apps/widget/bundle.sh`（Swift/AppKit → `target/release/Dango.app`，装到 /Applications；`build.sh` 只出裸二进制；`--snapshot out.png` 离屏渲染用于验证）
- 安装到本机：`install -m 0755 target/release/dango target/release/dango-widget ~/.local/bin/`，然后 `launchctl kickstart -k gui/$(id -u)/com.dango.daemon`
- 测试：`cargo test --workspace`（黄金回合 fixtures/scoring/golden.toml，由 occupation.rs 的 golden_turns 读；成就用例 crates/daemon/tests/achievements.rs）
- 回放：`DANGO_HOME=/tmp/sc DANGO_TZ=+08:00 cargo run -p cli -- replay fixtures/hooks/claude_code`
- 报告（文字）：`dango report [--week|--month|--year] --day yesterday --names [--tool claude|codex]`（`--day` 选哪天所在的周期）。分享图：`dango card [--week|--month|--year] [--day D] [--out /tmp/x.png] [--no-open]`（2026-11-01 起出的是报告窗口那套 4:5 分享图，从不带项目名和会话标题；渲染走 /Applications/Dango.app 的 `--abti … --page share`，改了 Swift 要先 bundle.sh + 重装；`card` 会覆盖剪贴板，只看渲染就 `dango abti --report KIND > x.json` 再 `dango-widget --abti x.json out.png --page share`）。
- 仪表盘截图：`dango-widget --snapshot-dashboard out.png [--range 1|7|30] [--open-jobs] [--office N]`（`--office N` 编 N 个人进办公室看效果；读 $DANGO_HOME/widget.json）；宠物截图（右下角的卡片）：`--snapshot-pet out.png --state working|… --job <职业id> [--helpers N] [--receipt] [--backdrop]`（透明 PNG，`--backdrop` 加深色底）；办公室截图：`--snapshot-office out.png --jobs id,id,… [--working K]`（前 K 个在干）。改角色或办公室要截一张办公室和面板看（职业有设计包抠图的用抠图，没有的画成矢量团子，两种都要看）。
- 办公室：只有设计稿的插画办公室（方案 B），没有主题菜单了。2026-11-06 删掉了经典主题（深色面板、舞台 + 茶水间办公室、大宠物、团子口味、旧分享卡，用户：「那我觉得你可以删掉这个版本的ui」），11-07 删掉了矢量办公室 A（用户：「请你把矢量办公室的也删掉」）；没有抠图的职业仍画成矢量团子（theme.swift `drawVectorDango`）。代码在 apps/widget/theme.swift（build.sh 把 main / theme / abti / story 四个文件一起编），插画和抠图在 apps/widget/assets/theme-b（bundle.sh 拷进 Dango.app/Contents/Resources）。`--snapshot-office … --statuses working,happy,fuming,waiting,idle,sleeping` 和 `--snapshot-dashboard --office N --statuses …` 指定每个人的状态；`--t 秒` 看某一时刻。设计稿原件在用户的 dango-ui-handoff 包（README、tokens.json）。办公室状态：守护进程写 `office[].status`（waiting / fuming / happy，见 widget.rs `office`），其余由小部件按 `since` 算（theme.swift `officeStatus`）。
- 老板人格测试 ABTI（2026-10-31，设计包 ~/Downloads/dango-abti-handoff）：`dango abti [--json]` 出结果，`dango abti --report day|week|month|year|total [--day D]` 出报告窗口 / 分享图的数据（含 `sessions` / `projects`：这段时间做了哪些事，会话标题和项目文件夹名，Claude Code 和 Codex 都有，只给报告窗口用）。门槛和文案全在 assets/abti.json（= 设计包的 config/abti.json），调门槛、改文案只改它；计算在 crates/daemon/src/abti.rs（四维、规模、压榨率、团子构成、体检单、热力图按自己的四分位、故事的名场面）。界面在 apps/widget/abti.swift（总卡、16 型图鉴、规模 / 构成说明页、4 张分享图、报告窗口）和 story.swift（故事 8 屏、说明页窗口）；图片在 apps/widget/assets/abti（bundle.sh 拷进 Resources）。截图：`dango-widget --abti result.json out.png --page card|types|scale|roles|share|report|story [--screen N --guess HMSL|skip --t 秒 --bare] [--section crew|work] [--lang zh|en]`（要在仓库根目录跑，才读得到 assets/abti.json）。入口：右键「老板人格测试」（看测试结果 / 16 型图鉴 / 两张说明页）和「报告」，面板「导出今日日报」左边的方块开报告窗口；第一次有数据时自动打开故事一次（UserDefaults `abtiShown`）。故事、总卡和各页都跟界面语言走（英文文案是我们写的：abti.json 里各处 `*_en`，story 下的 `guess_lines_en` / `verdict_en` / `relations_en`、医嘱 `en`）。面板导出键右端 ▾ 选日报 / 周报 / 月报 / 年报（本期和上一期），出的都是 4:5 分享图。所有导出存 ~/Pictures/DONGO（2026-11-01 按设计包统一字标 DONGO 和文件夹）。
- 一行命令安装：`package.sh` 同时出 `Dango-<版本>.zip` 和 `install.sh`（模板 apps/widget/install.sh.in，写进版本、SHA-256 和 `DANGO_RELEASE_URL`，默认 https://dongo.app 还没上线）；用户 `curl -fsSL <地址>/install.sh | sh`，curl 下载不带 quarantine 所以 Gatekeeper 不拦。脚本里变量后面紧跟中文要写成 `${VAR}`（sh 会把中文字节当成变量名）；更新时用 `pkill -x Dango` 退出旧的，别用 AppleScript（会弹自动化权限）。本机测：起 `python3 -m http.server 8790 --directory target/dist`，再 `DANGO_URL=http://localhost:8790 DANGO_APP_DIR=<临时目录> DANGO_NO_OPEN=1`。
- 打包给别人：`apps/widget/package.sh` → `target/dist/Dango-<版本>.dmg`（通用二进制，macOS 13 起，ad hoc 签名；本机没有 Developer ID，没做公证）。`dango` 命令放在 `Dango.app/Contents/Helpers/dango`——放进 Contents/MacOS 会和 App 自己的 `Dango` 撞成同一个文件（磁盘不分大小写）。第一次打开时 App 写 `~/Library/LaunchAgents/com.dango.daemon.plist` 指向 Helpers 里的 dango 并启动（main.swift `ensureDaemon`）；已有指向别处、文件还在的 agent（开发机的 ~/.local/bin/dango）不动；App 原地更新后按二进制时间戳 kickstart 一次。看 App 会写什么 agent：`Dango.app/Contents/MacOS/Dango --print-daemon-agent`。`build.sh` 认 `SWIFT_TARGET`（如 `arm64-apple-macos13.0`）；不设就是本机系统版本，别的 Mac 打不开。
- 守护进程第一次启动先导入历史（server.rs `import_history`，meta `history_imported`，和 `dango backfill` 一样的截止规则，backfill 模式），之后靠跟读：Codex 读 rollout（codex_tail.rs），Claude Code 读 transcript（claude_tail.rs，和回填共用 backfill.rs 的 `Transcript`，事件 id 相同）。装了 Dango 插件或 settings.json 里有 `dango hook` 时不读 Claude 的 transcript（`claude_tail::hooked`），钩子报过的会话也丢掉（server.rs `drop_hooked_sessions`）。跟读时还读 Claude Code 自己的 `~/.claude/sessions/<pid>.json`（`claude_tail::live_sessions`，内部文件不是公开接口，读不到就退回老规则）：idle → 回合马上结算，`waitingFor` → 记一条 `permission_prompt` 通知事件（不存对话框的字）。子 agent 从 transcript 记 `subagent_start` / `subagent_stop`，在干的帮手 = 开始 − 结束（`snapshot::running_helpers`）。团子的「最近动静」算所有事件（不只是钩子的）。右键「结算时发系统通知」（UserDefaults `settleNotice`，main.swift `SettleNotice`）代替钩子才有的结算框。测新用户：`HOME=<临时目录，里面 .claude/projects、.codex/sessions 软链到真的> DANGO_HOME=<临时>/.dango dango daemon`。
- 隐私扫描：`cargo run -p cli -- privacy-scan`（提交前必跑）
- 语言：`dango lang zh|en`（写 config.toml `general.locale`，守护进程看到改动就按新语言重写 widget.json）；截图在 `DANGO_HOME` 里先 `dango lang en` 再截，就是英文版。
- 旧名兼容：仓库在 `~/dango`（GitHub justinz183/dango），本机插件是 `dango@dango`（目录市场指向 ~/dango，装的是 git HEAD，改了钩子要先提交再 `claude plugin marketplace update dango` + `claude plugin update dango@dango` + 重启 Claude Code）。Codex 不用钩子：守护进程每秒跟读 `~/.codex/sessions` 的 rollout（crates/daemon/src/codex_tail.rs，和回填共用 backfill.rs 的 `Rollout`，事件 id 相同所以不会重复计）；`dango hook --codex` 只是给旧的 ~/.codex/hooks.json 留的空操作。为了过渡还留着几个链接：`~/shadowcorp` → `~/dango`、`~/.shadowcorp` → `~/.dango`、`~/.local/bin/shadowcorp` → `dango`；代码也认 `SHADOWCORP_HOME` / `SHADOWCORP_TZ`。
- 本地试验一律设 `DANGO_HOME` 指向临时目录，不要碰 ~/.dango 或 ~/.claude/settings.json。

## 结构
- crates/core：事件 schema、分类器、职业归类与时薪（occupation.rs + assets/occupations.toml）、计分、进度、成就引擎、终端文案。纯逻辑，无 IO。
- crates/daemon：capture（hook JSON → 事件）、spool、SQLite、ingest、backfill、socket、snapshot。
- crates/cli：单二进制 `dango`（hook [--codex] / status / stats / badges / backfill / daemon / replay / rebuild / privacy-scan / lang / report / card / widget / abti）。
- plugins/claude-code + .claude-plugin/marketplace.json：Claude Code 插件（可选：结算框、状态栏；不装时守护进程跟读 transcript）。Codex 没有插件或钩子，靠守护进程跟读它的会话日志。
- fixtures/codex/sessions：Codex 回填用例（主线程、子 agent、Codex 自己的 guardian 线程）。

## 规则
- crates/core 不做任何 IO；所有计分、进度、成就逻辑只在这里。
- 事件表只追加；任何让用户历史总数变少的改动都不允许（SPEC 5.5）。
- 不落盘、不上传 prompt / 代码 / 路径 / 仓库名（SPEC 14）。v5 起本地会存每个回合的 token 数（按模型）和按官方 API 价算出的模型花费——只有数字，永不上传（用户 2026-10-29 决定）。
- 改职业表、时薪、每步分钟数（core/occupation.rs）、计分规则或成就阈值前先问我，并同步更新 golden.toml。不要再加封顶（用户 2026-10-29："就记数值就行了，不要封顶"）。
- 话题先分大类（occupations.toml `[[family]]`，每类一个代表职业）再按 `tell` 认专科；strong / weak 只给大类记分。中文是子串匹配，不收单字（白名单见 occupation.rs `no_single_character_keywords`），泛用词（怎么做、解释一下、经济、需求……）只能当弱词，tell 只收专科独有的词；加了词先跑 `echo '一句话' | cargo run -q -p dango-core --example topic`、`families_then_specialties` 和 `everyday_prompts_have_no_topic`。泛用词藏在别的词里也会命中（"提供给"含"供给"、"帮我查查"），所以强词必须是只在那个行当出现的词，改完先跑 `python3 tools/topic_calibrate.py`（本机真实提示过一遍，只打印前 64 字、不落盘）和 `--why`（看每条命中了哪些词）。几个大类打平时（各命中一个强词），钩子把并列的都写进 `topic_ties`，守护进程沿用会话当前话题（replay.rs `a_tied_prompt_stays_on_the_sessions_topic`）。
- 时薪只能来自可查的来源（目前是 BLS OEWS API），写明序列和日期；模型单价只能抄官方价格页（assets/model_prices.toml 写明 URL 和日期）。不凭记忆填数。
- $ = 各职业分钟 × 该职业时薪；累计只增不减。例外只有用户明确同意时的 `dango rebuild --allow-lower`（2026-10-29：文字改成 2,000 字/小时、去掉文案写作，用户同意历史重算变少）。2026-10-31 按设计包加回文案和产品经理后，历史没有重算（重算会把一部分研究员的钱挪到时薪更低的文案，总数会变少，要用户同意才能 `--allow-lower`）。
- 新增成就 = 改 achievements.json + achievements.rs 里一对用例（刚好解锁 / 差一点）+ 一句解锁语（≤ 18 字），不改引擎代码。
- 所有界面文字中英两份：Rust 用 `Lang::t(中, 英)` / `cfg.lang()`，职业名 `Table::name_in`；Swift 用 `L(中, 英)`（全局 `lang` 来自 widget.json 或报告 JSON 的 `lang`）。新加文字不许只写一种语言。一屏只有一种语言（用户 2026-11-01："中文就是中文内容，英文就是英文内容"）：中文界面不出现英文词（产品名 Claude Code / Codex、类型代码 MBGO、数字和 token 这类设计稿原词除外），英文界面不出现中文；设计稿里中英并排的地方（16 型、规模档、角色名）按当前语言只留一种。旧的成就 / 公司页（badges、stats 里的阶段金币）只有中文，英文模式下 stats 只出产出几行。
- 文案遵守 SPEC 8.5：说产出不说节省，永远向上；可以说"模型花费"和"杠杆"（= 产出 $ ÷ 模型花费 $），不在界面上列 token 数——唯一例外是 ABTI 体检单的「累计 token」一格（设计包要求，只有这一处）。
- Claude Code hooks / statusline / 插件清单的字段名，每次使用前核对官方文档，不凭记忆。
  - async hook 的 stdout 会在下一回合交给 Claude，所以 async hook 什么都不打印。
  - 结算框只能走同步 Stop hook 的 `{"systemMessage": ...}`；exit 0 的 stderr 不显示。
- Codex notify 载荷同样先核对当前版本文档，并保留链式转发。

## 工作方式
- 一个里程碑一个分支（m3-desktop…），过 SPEC 16 的门槛才合并。
- 先写 fixtures 和测试，再写实现。
- 美术资源（精灵表、音效、分享卡模板）单独开子任务，不和核心逻辑混在一个 PR。
- 提交信息用 Conventional Commits；每个 PR 附上跑过的测试命令和结果。
- 不确定的产品决策写进 docs/OPEN_QUESTIONS.md，不要自行决定后埋进代码。
