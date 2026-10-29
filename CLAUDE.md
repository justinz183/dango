# 打工团子 Dango — 衡量 AI 编码产出

"团子"（英文 Dango，旧名 ShadowCorp）是一只桌面宠物，有活就在那个职业的场景里干（工位、诊室、健身房……）、按正在干的活换装；每一步按"该请谁来做"计时、按该职业的 BLS 时薪折成 $，和单日纪录、上周比，每天出一张日报卡。没有段位和 XP（v4 删了）。当前设计：docs/DESIGN.md v6（2026-10-29：每个领域一个代表、共 21 种职业（2026-10-29 去掉了文案写作：文字按 2,000 字/小时算研究员）（程序员下按步骤分网页 / 测试 / 运维），话题关键词分大类，场景，舞台 + 茶水间办公室；并掉的旧 id 走 `[alias]`）；不封顶（2026-10-29 起，回合 / 日 / 周都不封，assets/scoring.toml 只剩单位）；"影子公司 / 办公室 / 徽章"设定已收起，成就目录 assets/achievements.json 仍在但不是主界面。

## 命令
- 构建：`cargo build --workspace`（发布：`cargo build --release`，二进制 `target/release/dango`）
- 小部件：`apps/widget/bundle.sh`（Swift/AppKit → `target/release/Dango.app`，装到 /Applications；`build.sh` 只出裸二进制；`--snapshot out.png` 离屏渲染用于验证）
- 安装到本机：`install -m 0755 target/release/dango target/release/dango-widget ~/.local/bin/`，然后 `launchctl kickstart -k gui/$(id -u)/com.dango.daemon`
- 测试：`cargo test --workspace`（黄金回合 fixtures/scoring/golden.toml，由 occupation.rs 的 golden_turns 读；成就用例 crates/daemon/tests/achievements.rs）
- 回放：`DANGO_HOME=/tmp/sc DANGO_TZ=+08:00 cargo run -p cli -- replay fixtures/hooks/claude_code`
- 报告：`dango report [--week|--month|--year] --day yesterday --names [--tool claude|codex]`（`--day` 选哪天所在的周期）；卡片：`dango card …同上… --out /tmp/x.png --no-open`（渲染走 /Applications/Dango.app，改了 Swift 要先 bundle.sh + 重装；`card` 会覆盖剪贴板，只看渲染就 `report --json > x.json` 再 `dango-widget --card x.json out.png`）
- 仪表盘截图：`dango-widget --snapshot-dashboard out.png [--board claude_code|codex] [--range 1|7|30] [--open-jobs] [--office N]`（`--office N` 编 N 个人进办公室看效果）（读 $DANGO_HOME/widget.json；按工具的数据在 widget.json 的 `views`）；宠物截图：`--snapshot-pet out.png --state working|waiting|happy|proud|sleepy|missing --job <职业id> [--helpers N] [--receipt] [--backdrop]`（透明 PNG，`--backdrop` 加深色底）；办公室截图：`--snapshot-office out.png --jobs id,id,… [--working K] [--walk 秒]`（前 K 个在干；`--walk` 把活交给下一个人，渲染走到一半的样子）。改角色 / 装扮 / 场景要把 21 种职业 × 在干 / 闲着都截一遍、每个场景截一张办公室看。
- 隐私扫描：`cargo run -p cli -- privacy-scan`（提交前必跑）
- 语言：`dango lang zh|en`（写 config.toml `general.locale`，守护进程看到改动就按新语言重写 widget.json）；截图在 `DANGO_HOME` 里先 `dango lang en` 再截，就是英文版。
- 旧名兼容：仓库在 `~/dango`（GitHub justinz183/dango），本机插件是 `dango@dango`（目录市场指向 ~/dango，装的是 git HEAD，改了钩子要先提交再 `claude plugin marketplace update dango` + `claude plugin update dango@dango` + 重启 Claude Code）。Codex 不用钩子：守护进程每秒跟读 `~/.codex/sessions` 的 rollout（crates/daemon/src/codex_tail.rs，和回填共用 backfill.rs 的 `Rollout`，事件 id 相同所以不会重复计）；`dango hook --codex` 只是给旧的 ~/.codex/hooks.json 留的空操作。为了过渡还留着几个链接：`~/shadowcorp` → `~/dango`、`~/.shadowcorp` → `~/.dango`、`~/.local/bin/shadowcorp` → `dango`；代码也认 `SHADOWCORP_HOME` / `SHADOWCORP_TZ`。
- 本地试验一律设 `DANGO_HOME` 指向临时目录，不要碰 ~/.dango 或 ~/.claude/settings.json。

## 结构
- crates/core：事件 schema、分类器、职业归类与时薪（occupation.rs + assets/occupations.toml）、计分、进度、成就引擎、终端文案。纯逻辑，无 IO。
- crates/daemon：capture（hook JSON → 事件）、spool、SQLite、ingest、backfill、socket、snapshot。
- crates/cli：单二进制 `dango`（hook [--codex] / status / stats / badges / backfill / daemon / replay / rebuild / privacy-scan / lang / report / card / widget）。
- plugins/claude-code + .claude-plugin/marketplace.json：Claude Code 插件。Codex 没有插件或钩子，靠守护进程跟读它的会话日志。
- fixtures/codex/sessions：Codex 回填用例（主线程、子 agent、Codex 自己的 guardian 线程）。

## 规则
- crates/core 不做任何 IO；所有计分、进度、成就逻辑只在这里。
- 事件表只追加；任何让用户历史总数变少的改动都不允许（SPEC 5.5）。
- 不落盘、不上传 prompt / 代码 / 路径 / 仓库名（SPEC 14）。v5 起本地会存每个回合的 token 数（按模型）和按官方 API 价算出的模型花费——只有数字，永不上传（用户 2026-10-29 决定）。
- 改职业表、时薪、每步分钟数（core/occupation.rs）、计分规则或成就阈值前先问我，并同步更新 golden.toml。不要再加封顶（用户 2026-10-29："就记数值就行了，不要封顶"）。
- 话题先分大类（occupations.toml `[[family]]`，每类一个代表职业）再按 `tell` 认专科；strong / weak 只给大类记分。中文是子串匹配，不收单字（白名单见 occupation.rs `no_single_character_keywords`），泛用词（怎么做、解释一下、经济、需求……）只能当弱词，tell 只收专科独有的词；加了词先跑 `echo '一句话' | cargo run -q -p dango-core --example topic`、`families_then_specialties` 和 `everyday_prompts_have_no_topic`。泛用词藏在别的词里也会命中（"提供给"含"供给"、"帮我查查"），所以强词必须是只在那个行当出现的词，改完先跑 `python3 tools/topic_calibrate.py`（本机真实提示过一遍，只打印前 64 字、不落盘）和 `--why`（看每条命中了哪些词）。几个大类打平时（各命中一个强词），钩子把并列的都写进 `topic_ties`，守护进程沿用会话当前话题（replay.rs `a_tied_prompt_stays_on_the_sessions_topic`）。
- 时薪只能来自可查的来源（目前是 BLS OEWS API），写明序列和日期；模型单价只能抄官方价格页（assets/model_prices.toml 写明 URL 和日期）。不凭记忆填数。
- $ = 各职业分钟 × 该职业时薪；累计只增不减。例外只有用户明确同意时的 `dango rebuild --allow-lower`（2026-10-29：文字改成 2,000 字/小时、去掉文案写作，用户同意历史重算变少）。
- 新增成就 = 改 achievements.json + achievements.rs 里一对用例（刚好解锁 / 差一点）+ 一句解锁语（≤ 18 字），不改引擎代码。
- 团子口味：八种（`flavors`），宠物用 `petFlavor`（UserDefaults `flavor`），办公室按 `jobFlavors`；改角色画法要跑 `dango-widget --snapshot-flavors out.png` 和 `--paper` 两张看，浅色口味要描边、装扮要有光晕。
- 所有界面文字中英两份：Rust 用 `Lang::t(中, 英)` / `cfg.lang()`，职业名 `Table::name_in`；Swift 用 `L(中, 英)`（全局 `lang` 来自 widget.json 或报告 JSON 的 `lang`）。新加文字不许只写一种语言。旧的成就 / 公司页（badges、stats 里的阶段金币）只有中文，英文模式下 stats 只出产出几行。
- 文案遵守 SPEC 8.5：说产出不说节省，永远向上；可以说"模型花费"和"杠杆"（= 产出 $ ÷ 模型花费 $），不在界面上列 token 数。
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
