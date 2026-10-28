# ShadowCorp — 衡量 AI 编码产出

"你的 Claude"是一只桌面宠物，有活就坐在小桌前干、按正在干的活换装；每一步按"该请谁来做"计时、按该职业的 BLS 时薪折成 $，和单日纪录、上周比，每天出一张日报卡。没有段位和 XP（v4 删了）。当前设计：docs/DESIGN.md v4（2026-10-29）；日 / 周封顶沿用 docs/SPEC.md §5；"影子公司 / 办公室 / 徽章"设定已收起，成就目录 assets/achievements.json 仍在但不是主界面。

## 命令
- 构建：`cargo build --workspace`（发布：`cargo build --release`，二进制 `target/release/shadowcorp`）
- 小部件：`apps/widget/bundle.sh`（Swift/AppKit → `target/release/ShadowCorp.app`，装到 /Applications；`build.sh` 只出裸二进制；`--snapshot out.png` 离屏渲染用于验证）
- 安装到本机：`install -m 0755 target/release/shadowcorp target/release/shadowcorp-widget ~/.local/bin/`，然后 `launchctl kickstart -k gui/$(id -u)/com.shadowcorp.daemon`
- 测试：`cargo test --workspace`（黄金回合 fixtures/scoring/golden.toml，由 occupation.rs 的 golden_turns 读；成就用例 crates/daemon/tests/achievements.rs）
- 回放：`SHADOWCORP_HOME=/tmp/sc SHADOWCORP_TZ=+08:00 cargo run -p cli -- replay fixtures/hooks/claude_code`
- 日报：`shadowcorp report --day yesterday --names [--tool claude|codex]`；卡片：`shadowcorp card --day yesterday --names --out /tmp/x.png --no-open`（渲染走 /Applications/ShadowCorp.app，改了 Swift 要先 bundle.sh + 重装）
- 仪表盘截图：`ShadowCorp --snapshot-dashboard out.png [--board claude_code|codex] [--range 1|7|30] [--open-jobs] [--office N]`（`--office N` 编 N 个人进办公室看效果）（读 $SHADOWCORP_HOME/widget.json；按工具的数据在 widget.json 的 `views`）；宠物截图：`--snapshot-pet out.png --state working|waiting|happy|proud|sleepy|missing --job <职业id> [--helpers N] [--receipt] [--backdrop]`（透明 PNG，`--backdrop` 加深色底）。改角色 / 装扮要把 12 种职业 × 主要状态都截一遍看。
- 隐私扫描：`cargo run -p cli -- privacy-scan`（提交前必跑）
- 本地试验一律设 `SHADOWCORP_HOME` 指向临时目录，不要碰 ~/.shadowcorp 或 ~/.claude/settings.json。

## 结构
- crates/core：事件 schema、分类器、职业归类与时薪（occupation.rs + assets/occupations.toml）、计分封顶、进度、成就引擎、终端文案。纯逻辑，无 IO。
- crates/daemon：capture（hook JSON → 事件）、spool、SQLite、ingest、backfill、socket、snapshot。
- crates/cli：单二进制 `shadowcorp`（hook [--codex] / status / stats / badges / backfill / daemon / replay / rebuild / privacy-scan）。
- plugins/claude-code + .claude-plugin/marketplace.json：Claude Code 插件。plugins/codex/hooks.json：Codex hooks 模板（装到 ~/.codex/hooks.json，命令用绝对路径；改了要在 Codex 里重新信任）。
- fixtures/codex/sessions：Codex 回填用例（主线程、子 agent、Codex 自己的 guardian 线程）。

## 规则
- crates/core 不做任何 IO；所有计分、进度、成就逻辑只在这里。
- 事件表只追加；任何让用户历史总数变少的改动都不允许（SPEC 5.5）。
- 不落盘、不上传 prompt / 代码 / 路径 / 仓库名 / token / 费用（SPEC 14）。
- 改职业表、时薪、每步分钟数（core/occupation.rs）、计分封顶或成就阈值前先问我，并同步更新 golden.toml。
- 时薪只能来自可查的来源（目前是 BLS OEWS API），写明序列和日期；不凭记忆填数。
- $ = 各职业分钟 × 该职业时薪；累计只增不减。
- 新增成就 = 改 achievements.json + achievements.rs 里一对用例（刚好解锁 / 差一点）+ 一句解锁语（≤ 18 字），不改引擎代码。
- 文案遵守 SPEC 8.5：说产出不说节省，永远向上，不提 token。
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
