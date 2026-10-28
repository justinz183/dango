# ShadowCorp — 衡量 AI 编码产出

把 Claude Code 的回合折算成 $ 产出、XP 和段位（青铜 → 王者），桌面右下角小部件常驻显示。原规格书 docs/SPEC.md 的"影子公司 / 办公室 / 徽章"设定已于 2026-10-28 收起（见 docs/OPEN_QUESTIONS.md 第 0 条）：计分引擎沿用 SPEC §5，展示层只讲产出。成就目录 assets/achievements.json 仍在，但不是主界面。

## 命令
- 构建：`cargo build --workspace`（发布：`cargo build --release`，二进制 `target/release/shadowcorp`）
- 小部件：`apps/widget/bundle.sh`（Swift/AppKit → `target/release/ShadowCorp.app`，装到 /Applications；`build.sh` 只出裸二进制；`--snapshot out.png` 离屏渲染用于验证）
- 安装到本机：`install -m 0755 target/release/shadowcorp target/release/shadowcorp-widget ~/.local/bin/`，然后 `launchctl kickstart -k gui/$(id -u)/com.shadowcorp.daemon`
- 测试：`cargo test --workspace`（黄金用例 fixtures/scoring/golden.toml；成就用例 crates/daemon/tests/achievements.rs）
- 回放：`SHADOWCORP_HOME=/tmp/sc SHADOWCORP_TZ=+08:00 cargo run -p cli -- replay fixtures/hooks/claude_code`
- 隐私扫描：`cargo run -p cli -- privacy-scan`（提交前必跑）
- 本地试验一律设 `SHADOWCORP_HOME` 指向临时目录，不要碰 ~/.shadowcorp 或 ~/.claude/settings.json。

## 结构
- crates/core：事件 schema、分类器、计分、进度、成就引擎、终端文案。纯逻辑，无 IO。
- crates/daemon：capture（hook JSON → 事件）、spool、SQLite、ingest、backfill、socket、snapshot。
- crates/cli：单二进制 `shadowcorp`（hook / status / stats / badges / backfill / daemon / replay / rebuild / privacy-scan）。
- plugins/claude-code + .claude-plugin/marketplace.json：Claude Code 插件。

## 规则
- crates/core 不做任何 IO；所有计分、进度、成就逻辑只在这里。
- 事件表只追加；任何让用户历史总数变少的改动都不允许（SPEC 5.5）。
- 不落盘、不上传 prompt / 代码 / 路径 / 仓库名 / token / 费用（SPEC 14）。
- 改计分常数、段位阈值（core/rank.rs）或成就阈值前先问我，并同步更新 golden.toml。
- $ 只是 H × 时薪的展示；XP 只增不减，不随时薪变。
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
