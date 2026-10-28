# 影子公司（ShadowCorp）开发文档 — 衡量产出的 AI 编码成就系统

Oct 28, 2026 · @XX

## 1. 产品概述与定位

ShadowCorp（影子公司）是一个和 orank、ClaudeXP、claude-usage-pet 同类的产品：XP、徽章、连续天数、可分享的开发者档案、一个住在屏幕上的像素伙伴。唯一的不同是计分依据——它们衡量你花了多少 token，我们衡量你产出了多少工作，单位是人日。

**目标用户**：每天使用 Claude Code 或 Codex CLI 的个人开发者。首发 macOS，Windows 和 Linux 第二期。

**核心幻想**：你是一家影子公司的创始人，每个 agent 回合都是员工在替你干活。累计人日决定公司规模，徽章是公司里程碑，办公室是你能看见的公司本身。

**要制造的三种感觉**

| 感觉 | 用户心里的话 | 产品机制 |
| --- | --- | --- |
| 被看见 | "凌晨两点干的活，有人注意到了" | 回合完成即时结算、时刻徽章 |
| 在变强 | "我在变成一个能指挥一支队伍的人" | 公司阶段、称号、杠杆率 |
| 有陪伴 | "agent 跑长任务时，办公室里有人在动" | 影子办公室动画、托盘常驻 |

**同类产品与我们的位置**（参考：[orank](https://github.com/sedhuait/orank)、[ClaudeXP](https://github.com/EvanPaules/ClaudeXP)、[claude-usage-pet](https://github.com/plugin87/claude-usage-pet)、[buddy-evolution](https://github.com/FrankFMY/buddy-evolution)）

| 产品 | 形态 | 计分依据 | 覆盖工具 |
| --- | --- | --- | --- |
| orank | XP、徽章、连续天数、可分享档案、历史导入 | 会话数、工具调用、编辑字符数 | Claude Code |
| ClaudeXP | Stop hook 弹出 XP 结算框、等级称号、全球排行榜 | 工具调用、文件编辑、会话 | Claude Code |
| claude-usage-pet | 屏幕上的像素宠物、等级/连续/金币、每日任务 | token 用量与套餐额度 | Claude Code |
| buddy-evolution | 伙伴进化、34 个成就、会话日志 | 会话与工具使用 | Claude Code |
| ShadowCorp | 以上形态都要：结算框、徽章、档案、像素办公室 | 产出：人日、杠杆率，来自改动量、测试、合并、任务复杂度 | Claude Code、Codex、git hook 兜底 |

**六条设计原则**（所有功能决策以此为准）

1. 庆祝时刻，不庆祝数字：反馈在事情完成的那一秒发生，不在周报里。
2. 稀有才有情绪：大庆祝一周最多一到两次，否则贬值。
3. 永不减少：没有扣分、没有过期、没有负值、没有"浪费"统计。
4. 奖励产出不奖励用量：计分来自改动、测试、合并和任务复杂度，不来自 token。
5. 不打扰：agent 等待审批时绝不弹出任何东西。
6. 可爱但高级：圆润的像素角色、克制的配色、编辑级排版；像一款精致的独立游戏，不像儿童应用。

**明确不做**：成本分析、企业级团队监控（排行榜只在好友之间，显式加入，见第 11 节）、净值/返工统计、任何需要上传代码内容的功能。

## 2. 核心概念与术语

全文统一使用下表的术语和代码标识符；UI 文案用中文名，代码和数据库用英文标识符。

| 术语 | 标识符 | 定义 | 取值 / 示例 |
| --- | --- | --- | --- |
| 人日 | `person_day` | 1 人日 = 8 小时人类工程师等价工作量，由计分引擎按回合估算后累加 | 保留两位小数，如 2.40 |
| 杠杆率 | `leverage` | 人日折算小时 ÷ 用户活跃小时，会话级和周级各算一次 | 如 7.2x；显示上限 50x |
| 回合 | `turn` | 一次用户输入到 agent 完成响应；Claude Code 的 Stop、Codex 的 agent-turn-complete 各算一个回合 | 计分的最小单位 |
| 会话 | `session` | 一次 CLI 启动到结束；回合归属会话 | 用于"一口气"类成就 |
| 活跃分钟 | `active_minutes` | 会话内回合时长之和，加上相邻回合间小于 10 分钟的间隔 | 杠杆率的分母 |
| 公司阶段 | `stage` | 由累计人日决定的等级，共 7 级，决定办公室大小 | 见第 6 节 |
| 称号 | `title` | 用户可选择展示的头衔，由阶段或成就解锁 | "独角兽创始人" |
| 成就 / 徽章 | `achievement` | 一个可解锁的目标，可分档（tier），有稀有度 | 见第 7 节 |
| 档位 | `tier` | 同一成就的 I / II / III 级，阈值递增 | 夜猫子 I / II / III |
| 稀有度 | `rarity` | common / rare / epic / legendary，决定颜色、音效、庆祝级别 | 灰 / 蓝 / 紫 / 金 |
| 金币 | `coins` | 派生货币，1 人日 = 100 金币，成就另有奖励；只用于购买装饰 | 永不扣除 |
| 周环 | `weekly_ring` | 本周人日对周目标的进度环 | 默认目标 5 人日 |
| 连续 | `streak` | 连续活跃天数；活跃日 = 当日人日 ≥ 0.1 | 周末自动冻结 |
| 影子办公室 | `office` | 随公司阶段扩建的像素场景，员工数 = 阶段编号 | 见第 9 节 |
| 庆祝级别 | `ceremony_level` | micro / mid / grand，三级反馈 | 见第 8 节 |
| 事件 | `event` | 所有采集源归一化后的统一记录 | 见第 4 节 schema |
| 职业卡 | `role_card` | 职业图鉴中的一张卡，按任务类型映射 | 前端、DBA、DevOps… |

## 3. 系统架构

一个 Rust 单二进制 `shadowcorp` 同时扮演 hook 处理器、守护进程和 CLI；桌面界面用 Tauri 2 包在同一个二进制里。所有数据在本地 SQLite，没有服务端。

&#91;embedded content: 系统架构 · 5 个采集源、1 个 spool、4 个引擎、6 个展示面\]

五个采集源只向 spool 追加写入；守护进程 tail 后依次计分、更新进度、评估成就、调度庆祝，结果落 SQLite 并推给六个展示面。

**数据流**：采集源只做一件事——把事件 JSON 追加写入 `~/.shadowcorp/spool/events.jsonl`，然后立刻退出（目标 < 20 ms）。守护进程 tail 这个文件，逐条归一化、计分、更新进度、评估成就，再把结果写进 SQLite 并广播给展示面。守护进程没运行时事件照样落盘，下次启动补算，所以采集永远不丢、永远不阻塞 agent。

**技术选型**

| 组件 | 选型 | 理由 |
| --- | --- | --- |
| hook 处理器 / CLI / 守护进程 | Rust，单二进制 | hook 启动开销最小；一个文件分发；跨平台 |
| 桌面应用（托盘、面板、覆盖层） | Tauri 2 + TypeScript + React | 安装包十几 MB；透明置顶窗口和托盘原生支持 |
| 办公室场景 | Canvas 2D，像素精灵表，整数倍缩放 | 省电；像素风不需要 WebGL |
| 存储 | SQLite（rusqlite） | 单文件、可备份、可被用户直接查询 |
| 守护进程 ↔ 界面 | Unix socket（macOS/Linux）/ 命名管道（Windows），JSON 行协议 | 本地、无端口、无网络 |
| 系统通知 | Tauri notification 插件 | 原生通知中心 |
| 分享卡渲染 | resvg（SVG → PNG），模板在仓库内 | 离线、可复现 |
| 任务分类器 v1 | 规则 + 关键词 | 零延迟、零成本 |
| 任务分类器 v2（可选） | 本地小模型或 `claude -p` / `codex exec` 调用 | 用户显式开启后才用 |
| 安装 | Homebrew tap + `curl \| sh`；Windows 用 winget（第二期） | 一行安装 |

**仓库结构（建议）**

```
shadowcorp/
  crates/core/        # 事件 schema、计分、进度、成就引擎（纯逻辑，无 IO）
  crates/daemon/      # spool tail、SQLite、socket 服务、庆祝调度
  crates/cli/         # shadowcorp hook|status|stats|backfill|install
  apps/desktop/       # Tauri 2：托盘、面板、覆盖层、办公室、分享卡
  assets/achievements.json   # 成就目录，数据驱动
  assets/sprites/     # 办公室精灵表
  assets/sounds/      # 四档稀有度音效
  templates/share/    # 周卡与徽章卡 SVG 模板
  plugins/claude-code/ # .claude-plugin/plugin.json + hooks/hooks.json
  fixtures/           # 测试用 hook JSON、transcript 样本
```

## 4. 数据采集与接入

三条接入路径（Claude Code 插件、Codex notify、git hook）都只做一件事：把事件写进 spool。字段名以官方文档为准，开发时先核对 [Claude Code hooks 参考](https://code.claude.com/docs/en/hooks) 和 [settings 参考](https://docs.claude.com/en/docs/claude-code/settings)，不要凭记忆写。

### 4.1 Claude Code：插件 + hooks

以 Claude Code 插件形式分发（`.claude-plugin/plugin.json` + `hooks/hooks.json`），用户两条命令安装：`/plugin marketplace add <org>/shadowcorp` 和 `/plugin install shadowcorp@shadowcorp`。每个 hook 都是同一条命令 `shadowcorp hook`，从 stdin 读 JSON，写 spool，退出码 0，永不阻塞。

| Hook 事件 | 读取的字段 | 派生信号 |
| --- | --- | --- |
| SessionStart | session\_id、cwd、source、transcript\_path | 会话开始；source = resume 时不算新会话 |
| UserPromptSubmit | prompt（仅本地分类，不落盘原文） | 任务类型、是否纠正（见 5.2）、回合开始时间 |
| PostToolUse（Edit / Write / MultiEdit） | tool\_input 的 old\_string / new\_string / content | 文件数、增删行数 |
| PostToolUse（Bash） | tool\_input.command、tool\_response | 测试命令及结果、git commit / merge / push、CI 命令 |
| PostToolUse（Task） | tool\_name | 子 agent 计数（与 SubagentStop 二选一，取较大） |
| SubagentStop | session\_id | 子 agent 完成 |
| Stop | session\_id、stop\_hook\_active | 回合结束 → 触发计分；stop\_hook\_active 为 true 时跳过 |
| Notification | 通知类型 | 权限等待 → 60 秒内禁止任何弹层 |
| PreCompact | — | 仅记录，不计分 |
| SessionEnd | reason | 会话结束 → 会话级成就评估 |

插件的 `hooks/hooks.json`：

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "shadowcorp hook", "async": true }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "shadowcorp hook", "async": true }] }],
    "PostToolUse":       [{ "matcher": "Edit|Write|MultiEdit|Bash|Task", "hooks": [{ "type": "command", "command": "shadowcorp hook", "async": true }] }],
    "SubagentStop":      [{ "hooks": [{ "type": "command", "command": "shadowcorp hook", "async": true }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "shadowcorp hook" }] }],
    "Notification":      [{ "hooks": [{ "type": "command", "command": "shadowcorp hook", "async": true }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "shadowcorp hook" }] }]
  }
}
```

Stop 不设 async，因为结算框要在回合结束的那一秒打印到 stderr（见第 8 节）；`shadowcorp hook` 在 Stop 事件下会向守护进程请求本回合结算结果，超时 300 ms 则静默退出。`async` 字段是否可用以官方 hooks 参考为准，不可用时全部去掉。

### 4.2 Claude Code：状态栏

插件无法替用户设置 statusLine，安装脚本在用户确认后把这段写进 `~/.claude/settings.json`：

```json
{ "statusLine": { "type": "command", "command": "shadowcorp status --claude" } }
```

`shadowcorp status --claude` 读 stdin 的状态栏 JSON（取 session\_id、工作目录），向守护进程查当前会话与本周数据，输出一行：`▮ 影子公司 Lv.4 部门经理 · 本周 3.2/5 人日 ▓▓▓░░ · 杠杆 6.8x · 🔥 9 天`。守护进程不在时输出缓存的最近一行。

### 4.3 Claude Code：历史回填

安装时扫描 `~/.claude/projects/**/*.jsonl`（会话 transcript）和 `~/.claude/history.jsonl`（提示历史），按 4.1 的规则离线重放，得到安装前的全部人日和成就。回填的成就标记 `backfilled = true`，只在安装庆祝中一次性展示，不逐个弹出。路径以 Claude Code 当前版本为准，安装脚本自动探测，找不到时跳过并提示。

### 4.4 Codex CLI：notify + 回填

Codex 只有一个全局 `notify`，在 agent 完成一个回合时触发，并把一个 JSON 参数追加在命令之后。安装脚本读取 `~/.codex/config.toml`：没有 notify 时写入 `notify = ["shadowcorp", "codex-notify"]`；已有时改写为链式调用 `notify = ["shadowcorp", "codex-notify", "--chain", "<原命令>", "<原参数>…"]`，先处理自己再原样转发。Codex 没有工具级事件，所以回合的改动量从工作目录的 `git diff --numstat` 快照差分得到（回合开始快照由上一次 notify 的结束时间推算）。历史回填读取 `~/.codex/sessions/` 下的 rollout JSONL，路径同样由安装脚本探测。

### 4.5 通用兜底：git post-commit

`shadowcorp install --git` 在全局 `core.hooksPath` 或指定仓库写入 post-commit hook，记录提交的文件数、增删行、是否由 agent 产生（提交信息含 Co-Authored-By 的 agent 署名，或 1 小时内有同目录的 agent 回合）。这让 Cursor、Windsurf 等没有 hook 接口的工具也能至少计入"合并了什么"。

### 4.6 统一事件 schema

所有采集源归一化为下面的记录，spool 中每行一条，`raw` 字段只保留派生值，不保留 prompt、代码或命令原文。

```json
{
  "v": 1,
  "id": "evt_01HZX…",
  "ts": "2026-10-28T14:03:21.512Z",
  "source": "claude_code | codex | git | backfill",
  "kind": "session_start | prompt | tool | subagent_stop | turn_end | notification | session_end | commit",
  "session_id": "…",
  "turn_id": "…",
  "cwd_hash": "sha256 前 12 位",
  "payload": {
    "task_class": "feature | bugfix | refactor | test | docs | infra | data | review | migration | config | research | other",
    "is_correction": false,
    "files_touched": 6,
    "lines_added": 212,
    "lines_removed": 40,
    "test_cmd": true,
    "test_passed": true,
    "git_action": "commit | merge | push | null",
    "subagents": 2,
    "languages": ["ts", "sql"],
    "file_ages_days_max": 1180
  }
}
```

## 5. 计分引擎（人日与杠杆率）

每个回合估一个"如果人来做要多少分钟"，累加成人日；常数放在 `assets/scoring.toml`，带版本号，改动只能让用户的历史总数不变或变多，永远不能变少。

### 5.1 任务分类与基础分钟

分类器 v1 只用规则：先看 prompt 关键词，再看本回合工具信号（有测试命令偏向 test，有 migration 路径偏向 migration）。原文不落盘，只落 `task_class`。

| task\_class | 关键词示例（中英） | 基础分钟 base | 映射职业卡 |
| --- | --- | --- | --- |
| feature | 实现、加一个、新增、add、implement、build | 40 | 按文件类型 |
| bugfix | 修、报错、bug、fix、broken、fails | 30 | 按文件类型 |
| refactor | 重构、整理、抽出、refactor、clean up、extract | 25 | 架构师 |
| test | 测试、用例、test、spec、coverage | 20 | 测试工程师 |
| docs | 文档、README、注释、docs、comment | 15 | 技术写手 |
| infra | 部署、CI、Docker、deploy、pipeline、k8s | 30 | DevOps |
| data | 数据、SQL、迁移、query、schema、ETL | 25 | 数据工程 / DBA |
| review | 看看、解释、review、explain、why | 10 | 架构师 |
| migration | 升级、迁移到、upgrade、migrate、port | 35 | 架构师 |
| config | 配置、环境变量、config、env、settings | 8 | DevOps |
| research | 调研、比较、research、compare、options | 15 | 产品经理 |
| other | 无匹配 | 12 | 不计 |

职业卡按本回合改动文件的路径和扩展名二次判定：`.tsx .vue .css` → 前端；`.sql` 或 `migrations/` → DBA；`Dockerfile .yml .tf` → DevOps；`test/ spec/ __tests__/` → 测试工程师；`.md .mdx` → 技术写手；`.swift .kt .dart` → 移动端；`auth/ crypto/ security` 关键词 → 安全工程师；`.ipynb` 或 pandas/spark → 数据工程；`.py .go .rs .java` 其余 → 后端；跨 3 种以上目录 → 架构师。

### 5.2 纠正检测

`is_correction = true` 当 prompt 前 12 个字符命中：不对、错了、不是、重来、撤销、改回、wrong、no,、not that、undo、revert、that's not。只用于"一次过"和"把关人"成就的计数，不扣任何分。

### 5.3 人日公式

单回合人类等价分钟 H：

```latex
H = \operatorname{clamp}\left(\text{base}_c + 2.5F + 0.45L^{0.8} + 10T + 12S + 20M,\ 2,\ 360\right)
```

其中 F = 触碰文件数，L = 增删行数之和，T = 本回合是否运行了测试（0/1），S = 子 agent 数，M = 是否有 commit / merge（0/1），c = task\_class。人日 = H ÷ 480。

量级校验（用于单元测试的黄金用例）：

| 场景 | 参数 | H（分钟） | 人日 |
| --- | --- | --- | --- |
| 改一个配置项 | config, F=1, L=3 | 8.6 | 0.02 |
| 中等重构并跑测试 | refactor, F=6, L=252, T=1 | 87 | 0.18 |
| 新功能含提交 | feature, F=12, L=800, T=1, M=1 | 175 | 0.36 |
| 大迁移带 3 个子 agent | migration, F=40, L=3000, T=1, S=3, M=1 | 360（封顶） | 0.75 |

封顶：单回合 360 分钟；单日 6 人日；单周 30 人日。超出部分不计，界面上不提示"已封顶"。

### 5.4 杠杆率

活跃分钟 = 会话内各回合时长之和 + 相邻回合间隔中小于 10 分钟的部分。杠杆率 = (ΣH ÷ 60) ÷ (活跃分钟 ÷ 60)，会话级在 SessionEnd 时算一次，周级每日重算。活跃分钟不足 5 时不显示杠杆率；显示上限 50x，超过显示"50x+"。

### 5.5 校准目标

| 指标 | 目标区间 | 用途 |
| --- | --- | --- |
| 1 小时活跃使用 | 0.4 – 0.8 人日 | 常数调参的锚点 |
| 典型会话杠杆率 | 3x – 10x | 可信但值得晒 |
| 一周重度使用 | 8 – 20 人日 | 周卡数字区间 |

常数变更规则：新版本常数算出的总数 ≥ 旧总数时才回溯重算，否则只对新事件生效。分类器 v2（本地小模型或 `claude -p` / `codex exec`）仅在用户设置里显式开启，且只输出 task\_class，不输出其他内容。

## 6. 进度系统（公司阶段、金币、周环、连续）

进度只有一个主轴：累计人日。它决定公司阶段，阶段决定办公室大小和创始人称号；金币、周环、连续都是围绕主轴的节奏器。

### 6.1 公司阶段

| 阶段 | 名称 | 累计人日 | 直觉含义 | 办公室 | 可见员工 | 创始人称号 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 车库 | 0 | 刚开始 | 一张桌子、一盏台灯 | 1 | 车库创客 |
| 2 | 工作室 | 5 | 一个人干了一周 | 两张桌子、一块白板 | 2 | 工作室主理人 |
| 3 | 创业公司 | 22 | 一个人干了一个月 | 开放办公区 | 4 | 创业公司 CEO |
| 4 | 成长期 | 100 | 一个小团队干了一个月 | 两层楼 | 8 | 成长期 CEO |
| 5 | 独角兽 | 250 | 一个人干了一整年 | 整层楼、落地窗 | 12 | 独角兽创始人 |
| 6 | 集团 | 1000 | 一个 4 人团队干了一年 | 园区两栋楼 | 20 | 集团董事长 |
| 7 | 帝国 | 5000 | 一个 20 人团队干了一年 | 塔楼夜景 | 30 | 帝国缔造者 |

升阶触发大庆祝（见第 8 节），办公室当场扩建并播放施工动画。阶段只升不降；称号解锁后永久可选。

### 6.2 金币

每 1 人日入账 100 金币，成就奖励另计。金币只用于商店购买办公室装饰和外观（第 9 节），没有任何扣除场景，没有过期。入账在回合结算时实时显示（`+36 金币`），商店购买时播放收银音效。

### 6.3 周环

每周一 00:00（本地时区）重置。目标值默认 5 人日；从第 5 周起每月第一个周一自动重算：`目标 = clamp(round(1.2 × 最近 4 周人日中位数), 2, 20)`，用户可在设置里手动固定。合环触发中级庆祝；合环后继续累计显示为 `6.4 / 5`，不封顶。周环只在当周显示，上周数据进入周卡，不保留"未合环"的记录。

### 6.4 连续

活跃日定义：当日人日 ≥ 0.1。周六、周日不计入也不中断（周五活跃、下周一活跃视为连续）。每达到 30 天连续发放一张冻结券，"断电"成就也发一张，最多存 3 张，缺勤日自动消耗，用户无需操作。冻结券用尽后连续归零，但界面文案不出现"断了""失去"：显示为 `上一段 23 天 · 新的一段从今天开始`，并保留历史最长连续作为个人纪录。

### 6.5 个人纪录

守护进程维护四项个人纪录：单日最高人日、单会话最高人日、单会话最高杠杆率、最长连续天数。打破纪录触发中级庆祝，文案固定为 `新纪录：<项目> <数值>（之前 <旧值>）`。

## 7. 成就系统

成就是产品的主菜：52 个成就、8 个类别、4 档稀有度，全部数据驱动（`assets/achievements.json`），改目录不用改代码。每个成就有一个可爱的名字、一句解锁语（庆祝时念出来）、一句图鉴描述，以及一件实实在在的奖励。

### 7.1 设计原则

1. 六成进度型，四成发现型。进度型可见、有进度条、显示"还差 2 次"；发现型解锁前显示 `???` 和一句模糊提示，解锁时的惊喜是它的全部价值。
2. 同一成就分档（I / II / III），阈值大约 ×5 递增，让同一件事反复带来小的爽点。
3. 集齐一组有套装奖励，让收集本身成为目标。
4. 奖励必须是"东西"：金币之外，每个稀有以上成就至少附带一件装饰、一个称号、一段音效或一个状态栏主题。
5. 显示全局占比（"只有 3% 的创始人拥有"），上线前用设计值，匿名统计 opt-in 后替换为真实值。
6. 永不羞辱：没有负面成就。看起来像吐槽的行为（同一句话连发三次）也要命名成鼓励（"再来一次"）。
7. 判定只用第 4 节的派生信号，不读代码、prompt 或命令原文。
8. 回填得到的成就一次性静默入账，只在安装庆祝里总览，不逐个弹出。

### 7.2 稀有度

| 稀有度 | 标识符 | 颜色 | 全局占比目标 | 庆祝级别 | 基础金币 | 音效 |
| --- | --- | --- | --- | --- | --- | --- |
| 普通 | common | 奶白 | ≥ 40% | 微 + 结算框一行 | 50 | 短"叮" |
| 稀有 | rare | 天蓝 | 10 – 40% | 中 | 150 | 两音上行 |
| 史诗 | epic | 薰衣草紫 | 2 – 10% | 大 | 500 | 三音和弦 + 粒子 |
| 传说 | legendary | 暖金 | < 2% | 大，全屏金色，停留 5 秒 | 2000 | 四音琶音 + 彩带 |

### 7.3 成就目录

触发条件里的指标都来自第 4 节的事件和第 5 节的计数器。"会话"指单次会话，"累计"指全历史。

**里程碑（公司成长）**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| M01 | 第一位员工 | 累计 1 人日 | — | 普通 | 员工合影相框 |
| M02 | 一个人周 | 累计 5 人日 | — | 普通 | 白板 |
| M03 | 一个人月 | 累计 22 人日 | — | 稀有 | 咖啡机 |
| M04 | 百人日 | 累计 100 人日 | — | 稀有 | 大绿植 |
| M05 | 周年庆 | 累计 250 人日（一个人干了一整年） | — | 史诗 | 落地窗 + 称号「一个人的一年」 |
| M06 | 千人日 | 累计 1000 人日 | — | 传说 | 可自定义文字的霓虹招牌 |
| M07 | 万人日 | 累计 10000 人日 | — | 传说（隐藏） | 天台花园 |

**杠杆（会用 agent）**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| L01 | 四两拨千斤 | 单会话杠杆率 ≥ 5x / 10x / 20x | I / II / III | 普通 / 稀有 / 史诗 | III：称号「杠杆玩家」 |
| L02 | 甩手掌柜 | 单回合 agent 自主运行 ≥ 15 / 30 / 60 分钟 | I / II / III | 普通 / 稀有 / 史诗 | II：躺椅 |
| L03 | 一次过 | 连续未纠正的回合 5 / 20 / 50 次 | I / II / III | 普通 / 稀有 / 史诗 | III：称号「说一次就行」 |
| L04 | 连击 | 单会话连续 5 个回合一次过 | — | 稀有 | 连击音效 |
| L05 | 指挥官 | 单会话子 agent ≥ 3 / 6 / 10 | I / II / III | 稀有 / 史诗 / 传说 | III：指挥台 |

**时刻（氛围）**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| T01 | 夜猫子 | 0–5 点的会话 1 / 10 / 50 次 | I / II / III | 普通 / 稀有 / 史诗 | II：月亮夜灯 |
| T02 | 晨鸟 | 6 点前开始的会话 1 / 10 次 | I / II | 普通 / 稀有 | II：日出窗帘 |
| T03 | 周末战士 | 周末会话 5 / 25 次 | I / II | 普通 / 稀有 | — |
| T04 | 一口气 | 单会话 ≥ 3 小时 | — | 稀有 | 泡面 |
| T05 | 马拉松 | 单会话 ≥ 6 小时 | — | 史诗 | 睡袋 |
| T06 | 首次合并 | 第一次在 agent 回合内 commit 或 merge | — | 普通 | — |
| T07 | 绿灯 | 测试一次通过 1 / 10 / 100 次 | I / II / III | 普通 / 稀有 / 史诗 | III：绿色小交通灯 |

**工程风格**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| S01 | 清道夫 | 单会话净删除 ≥ 500 / 5000 行 | I / II | 稀有 / 史诗 | II：称号「减法大师」 |
| S02 | 考古学家 | 修改了 ≥ 3 年没人碰的文件 | — | 稀有 | 恐龙化石摆件 |
| S03 | 多语者 | 累计 5 / 10 种语言 | I / II | 稀有 / 史诗 | II：称号「巴别塔」 |
| S04 | 拆弹专家 | 测试或 CI 从失败变通过 1 / 10 次 | I / II | 稀有 / 史诗 | II：灭火器 |
| S05 | 把关人 | 纠正 agent 10 / 50 次（解锁语：有判断的老板） | I / II | 普通 / 稀有 | II：印章 |
| S06 | 拆迁队 | 单会话触碰 ≥ 50 个文件 | — | 稀有 | 安全帽 |
| S07 | 外科医生 | 单回合只改 1 个文件、≤ 5 行且测试通过，累计 10 次 | — | 稀有 | 放大镜 |
| S08 | 文档控 | docs 类回合累计 20 次 | — | 普通 | 书架 |

**连续与休息**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| C01 | 习惯 | 连续 7 / 30 / 100 / 365 天 | I – IV | 普通 / 稀有 / 史诗 / 传说 | IV：称号「铁打的」 |
| C02 | 断电 | 整个周末没有会话（周一判定） | — | 普通 | +1 冻结券、吊床 |
| C03 | 深呼吸 | 30 天内 ≥ 4 个休息日且总人日 ≥ 10 | — | 稀有 | 小盆栽 |
| C04 | 回归 | 休息 ≥ 14 天后回来（解锁语：欢迎回来，办公室一直亮着灯） | — | 普通 | — |

**跨工具与社交**

| ID | 名称 | 触发条件 | 档位 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| X01 | 双修 | 同一天用了 Claude Code 和 Codex | — | 普通 | — |
| X02 | 三叉戟 | 三个不同采集源都有事件 | — | 稀有 | — |
| X03 | 分享者 | 第一次导出周卡 | — | 普通 | — |
| X04 | 有朋自远方来 | 添加第一位好友 | — | 普通 | 双人沙发 |
| X05 | 榜首 | 好友周榜第一 1 / 5 次 | I / II | 稀有 / 史诗 | II：奖杯柜 |
| X06 | 送礼人 | 向好友赠送装饰 | — | 普通 | — |
| X07 | 早鸟 | 公测期内安装（限时） | — | 稀有 | 早鸟徽章墙 |

**隐藏成就**（解锁前显示 `???` 和提示语）

| ID | 名称 | 触发条件 | 提示语 | 稀有度 | 奖励 |
| --- | --- | --- | --- | --- | --- |
| H01 | 凌晨四点 | 4:00–4:59 的 commit | 城市还没醒 | 稀有 | 路灯 |
| H02 | 自我否定 | 删除了 7 天内 agent 写的 ≥ 100 行 | 勇于推翻 | 稀有 | 碎纸机 |
| H03 | 再来一次 | 同一句 prompt 连发 3 次（解锁语：坚持是美德） | 第三次总会成的 | 普通 | — |
| H04 | 守岁 | 12 月 31 日 23:00 到 1 月 1 日 1:00 有会话 | 新旧之间 | 史诗 | 烟花窗景 |
| H05 | 愚人节 | 4 月 1 日有会话 | 别信今天的 bug | 普通 | 小丑帽（员工戴） |
| H06 | 一行定乾坤 | 1 行改动让测试由红变绿 | 一字千金 | 史诗 | 金色键盘 |
| H07 | 周年纪念 | 安装满一年 | 时间过得真快 | 史诗 | 周年蛋糕 |
| H08 | 全员到岗 | 单日回合数 ≥ 可见员工数 × 2 | 今天大家都来了 | 稀有 | 集体合照 |
| H09 | 低调 | 连续 7 天活跃且没有任何大庆祝 | 默默耕耘 | 普通 | 小夜灯 |

### 7.4 职业图鉴

12 张职业卡，每张三档（该职业回合累计 1 / 10 / 50 次），解锁卡面从线稿变为上色再变为金边。映射规则见 5.1。

| 卡 | 标识符 | 卡面角色 |
| --- | --- | --- |
| 前端 | frontend | 举着调色板的小影 |
| 后端 | backend | 抱着齿轮的小影 |
| DBA | dba | 坐在数据柜上的小影 |
| DevOps | devops | 戴安全帽推集装箱的小影 |
| 测试工程师 | qa | 拿放大镜的小影 |
| 技术写手 | writer | 握羽毛笔的小影 |
| 安全工程师 | security | 举盾牌的小影 |
| 数据工程 | data | 推着图表小车的小影 |
| 移动端 | mobile | 抱着大手机的小影 |
| 架构师 | architect | 看蓝图的小影 |
| 产品经理 | pm | 贴便利贴的小影 |
| ML 工程 | ml | 戴护目镜调旋钮的小影 |

### 7.5 套装奖励

| 套装 | 条件 | 奖励 | 稀有度 |
| --- | --- | --- | --- |
| 多面手 | 任意 6 张职业卡 I | 称号「多面手」 | 稀有 |
| 全栈 | 12 张职业卡 I | 称号「全栈」+ 办公室技能墙 | 史诗 |
| 万能钥匙 | 12 张职业卡 III | 称号「万能钥匙」+ 金色门牌 | 传说 |
| 夜班组 | T01、T04、T05、H01 全部解锁 | 办公室夜间模式常驻可选 + 称号「夜班组长」 | 史诗 |
| 作息大师 | C01 III、C02、C03 全部解锁 | 称号「作息大师」+ 窗外四季变化 | 史诗 |
| 收藏家 | 任意 30 个成就 | 成就展示柜（可在办公室陈列 5 个徽章） | 史诗 |

### 7.6 定义 schema 与引擎

```json
{
  "id": "T01",
  "name": "夜猫子",
  "category": "moment",
  "hidden": false,
  "hint": null,
  "unlock_line": "凌晨的办公室只有你的灯亮着。",
  "codex_line": "在 0 点到 5 点之间开始的会话。",
  "trigger": { "type": "counter", "metric": "sessions_night" },
  "tiers": [
    { "tier": 1, "threshold": 1,  "rarity": "common", "reward": { "coins": 50 } },
    { "tier": 2, "threshold": 10, "rarity": "rare",   "reward": { "coins": 150, "item": "moon_lamp" } },
    { "tier": 3, "threshold": 50, "rarity": "epic",   "reward": { "coins": 500 } }
  ]
}
```

触发类型四种：`counter`（某个计数器达到阈值）、`event`（单个事件满足谓词，如 `payload.lines_removed - payload.lines_added >= 500` 且作用域为会话）、`window`（时间窗内的条件组合，如 30 天内休息日 ≥ 4 且人日 ≥ 10）、`calendar`（本地时间落在某个区间）。谓词用一个极小的表达式子集（比较、与或、字段读取），在 `crates/core` 内实现，不引入脚本引擎。

引擎流程：事件到达 → 更新相关计数器（按全历史 / 当日 / 当周 / 当会话四个作用域）→ 只评估订阅了这些计数器的成就 → 新解锁写入 `unlocks` 表（幂等，以 `achievement_id + tier` 唯一）→ 发放奖励 → 把庆祝请求交给调度器。回填模式下调度器不发任何庆祝。

### 7.7 展示规则

进度型成就在面板里显示进度条和"还差 N"；距离解锁 ≤ 10% 时，状态栏允许每天一次提示（`夜猫子 III 还差 2 次`）。隐藏成就显示 `???` + 提示语，解锁后显示解锁日期和全局占比。每个成就有一张可分享的徽章卡（第 10 节）。

## 8. 庆祝与反馈

反馈分三级，由守护进程的庆祝调度器统一发出；任何展示面都不自己决定何时庆祝。

### 8.1 三级庆祝

| 级别 | 触发 | 表现 | 时长 | 频率上限 |
| --- | --- | --- | --- | --- |
| 微 micro | 每个回合结束、金币入账 | 状态栏数字跳动；托盘图标上的小影点一下头 | 即时 | 无 |
| 中 mid | 回合结算、普通/稀有成就、合环、新纪录 | 终端结算框 + 系统通知 + 办公室里一个员工跳起来 + 轻音效 | 结算框常驻，通知 4 秒 | 每回合 1 次 |
| 大 grand | 史诗/传说成就、升阶、套装完成 | 全屏透明覆盖层：徽章从中央浮出，解锁语逐字出现，稀有度色粒子；办公室全员欢呼；专属音效 | 3 秒（传说 5 秒），点击或 Esc 关闭 | 每 4 小时 1 次，其余排队 |

### 8.2 调度规则

1. 排队：超出频率上限的大庆祝进入"待领取"托盘，托盘图标显示小红点；用户点开面板时逐个播放，也可以一键全部领取（合并成一张总览卡）。
2. 免打扰：Notification hook 报告权限等待后 60 秒内、系统勿扰模式开启时、全屏应用在前台时，任何中级以上庆祝都延后排队，微级照常。
3. 升阶优先：同一时刻多个大庆祝，升阶先播，然后按稀有度从高到低。
4. 静音时段：设置里可定义（默认 23:00–8:00 不发声音，画面照常）。
5. 回填期间不庆祝，结束后只播一次安装总览（见第 12 节）。

### 8.3 终端结算框

Stop hook 把下面的框打印到 stderr，不进入 Claude Code 的上下文。宽度固定 44 列，超出省略。

```
┌─ 影子公司 ───────────────────────────────┐
│  +0.42 人日   重构 · 6 个文件 · 测试通过   │
│  杠杆 7.1x    本周 3.6 / 5 ▓▓▓▓░          │
│  +42 金币     🔥 9 天                      │
│  ✦ 绿灯 II 解锁 · 还差 90 次到 III         │
└───────────────────────────────────────────┘
```

第四行只在本回合有成就进展时出现。Codex 侧由 notify 命令打印同样的框。

### 8.4 音效

四档稀有度各一段（≤ 1.2 秒），外加：回合结算"叮"、合环"合上"声、升阶施工声、收银声、连击递增音阶。全部用同一套乐器（玩具钢琴 + 木琴），音量跟随系统，默认 60%。所有音效可单独关闭。

### 8.5 文案规范

| 规则 | 写 | 不写 |
| --- | --- | --- |
| 说产出，不说节省 | 你完成了 2.4 个人周的工作 | 你省了 19 小时 |
| 第二人称，短句 | 凌晨的办公室只有你的灯亮着。 | 用户在非工作时间段进行了会话 |
| 永远向上 | 上一段 23 天，新的一段从今天开始 | 连续中断了 |
| 具体数字 | 还差 2 次 | 快了 |
| 不说教 | — | 建议你早点休息 |
| 不提 token、费用、模型 | — | 本回合消耗 12k token |

解锁语每条 ≤ 18 个字，图鉴描述 ≤ 30 个字，全部存在 `achievements.json` 里，英文版同文件 `_en` 后缀字段。

## 9. 影子办公室

办公室是产品的脸：一个随公司阶段扩建的像素场景，住着叫"小影"的员工。它住在菜单栏面板里，agent 跑任务时有人在动，你停下来他们就喝咖啡。

### 9.1 美术方向：可爱但高级

- 角色"小影"：圆滚滚的墨水团，两只大眼睛，半透明边缘，身高 24 像素；靠配件区分职业（安全帽、羽毛笔、盾牌），不靠换脸。原创设计，不参考任何现有 IP。
- 像素风，基础精灵 32 × 32，整数倍缩放（2x / 3x），禁止非整数缩放和抗锯齿。
- 配色克制：全局 ≤ 24 色，底色奶白与炭灰，四种稀有度色只在徽章和特效上出现；夜间模式整体降饱和加暖光。
- 排版编辑级：界面字体用系统无衬线（PingFang / SF / Segoe），数字用等宽；留白多，信息密度低，一屏只讲一件事。
- 动作小而频：眨眼、打哈欠、转椅子、端咖啡，每个 ≤ 8 帧；欢呼动作 12 帧。可爱来自细节，不来自卖萌文案。

### 9.2 场景随阶段扩建

场景资源按 6.1 的七个阶段准备七张底图，升阶时播放 2 秒施工动画（脚手架 → 新区域亮灯），新员工从门口走进来坐下。员工座位数 = 可见员工数；装饰按用户摆放位置渲染在固定锚点上。

### 9.3 状态机

&#91;embedded content: 办公室状态机 · 5 个状态 + 1 个夜间叠加层\]

工作和庆祝由事件触发，休息和离开由静默时长触发；任何事件都把休息或离开拉回空闲，夜间只是叠在上面的灯光层。

| 状态 | 画面 | 进入条件 |
| --- | --- | --- |
| 空闲 idle | 员工喝咖啡、转椅子、偶尔眨眼 | 10 分钟内有事件但当前无回合进行 |
| 工作 working | 与当前并行回合数相同的员工在敲键盘，子 agent 开启时更多人起身 | 收到 prompt 事件且未收到 turn\_end |
| 庆祝 celebrating | 全员举手，纸屑，持续 3 秒后回到之前状态 | 调度器发出中级以上庆祝 |
| 夜间 night | 灯暗，只有工作中的员工桌上台灯亮 | 本地时间 22:00–6:00，叠加在其他状态上 |
| 休息 sleeping | 员工趴在桌上，窗外月亮 | 60 分钟无事件 |
| 离开 away | 办公室空着，门口留一盏灯 | 24 小时无事件；回来时播"回归"动画 |

### 9.4 装饰与商店

金币只花在这里。商品分三类：成就奖励（不可购买，只能解锁）、商店常驻、季节限定。

| 商品 | 来源 | 金币 | 放置位置 |
| --- | --- | --- | --- |
| 小盆栽 / 大绿植 | 商店 / M04 | 200 / — | 桌角、窗边 |
| 咖啡机 | M03 | — | 茶水区 |
| 霓虹招牌（可自定义公司名） | M06 | — | 正门上方 |
| 猫 | 商店 | 800 | 随机在办公室走动 |
| 鱼缸 | 商店 | 500 | 前台 |
| 唱片机（可换四首环境音乐） | 商店 | 600 | 休息区 |
| 白板（可写 20 字） | M02 | — | 墙面 |
| 员工配件（领结、眼镜、小帽子） | 商店 | 100 每件 | 任一员工 |
| 窗景（城市、海边、雪山） | 商店 | 400 | 窗外 |
| 季节限定（中秋灯笼、圣诞树、春节对联） | 商店，限时 | 300 | 固定锚点 |

### 9.5 渲染与性能

Canvas 2D，精灵表一次加载；空闲 12 fps，庆祝 24 fps；面板隐藏时暂停渲染，仅托盘图标按秒更新；CPU 占用目标 < 2%（空闲）、< 8%（庆祝）。所有资源打包进应用，不联网。

## 10. 桌面应用与界面

桌面应用只有三个可见部件：托盘图标、点开的面板、偶尔出现的全屏庆祝层。没有主窗口，没有 Dock 图标（macOS 用 accessory 模式）。

### 10.1 托盘图标

16 × 16 的小影头像，三种状态：静止（无回合）、打字（有回合进行，2 帧循环）、举手（有待领取庆祝，角上红点）。微级反馈时点一下头。点击打开面板，右键菜单：打开面板、生成周卡、暂停一小时、退出。

### 10.2 面板

固定 420 × 640，从托盘下拉，失焦自动收起。五个标签：

| 标签 | 内容 | 主要交互 |
| --- | --- | --- |
| 公司 | 累计人日（大数字）、阶段与称号、周环、连续、本周杠杆率、四项个人纪录 | 点称号切换展示称号 |
| 成就 | 按类别分组的徽章网格，已解锁彩色、进行中带进度条、隐藏显示 ???；顶部筛选：全部 / 进行中 / 已解锁 | 点徽章看详情和分享 |
| 办公室 | Canvas 场景 + 底部商店抽屉 | 拖拽摆放装饰、购买、给员工换配件 |
| 好友 | 周榜、同职业榜、好友动态、互赠（第 11 节） | 添加好友、送礼 |
| 周报 | 最近 8 周的周卡缩略图，当前周实时 | 导出、分享 |

设置在右上角齿轮：周目标、静音时段、音量、免打扰来源、分类器 v2 开关、匿名统计 opt-in、好友功能开关、数据导出与清除、开机自启。

### 10.3 全屏庆祝层

Tauri 透明、置顶、无边框窗口，覆盖当前显示器，除卡片区域外点击穿透。动画：0.3 秒暗角淡入 → 徽章从中心 0.6 倍放大到 1 倍（弹性曲线）→ 解锁语逐字出现（每字 40 ms）→ 稀有度色粒子 → 停留 → 0.3 秒淡出。传说级额外一圈金色光环和彩带。遵循系统"减少动态效果"设置：开启时只淡入淡出，不放大不粒子。任何键或点击立即关闭。

### 10.4 分享卡

三种卡，全部由 `templates/share/*.svg` 用 resvg 离线渲染成 PNG，复制到剪贴板并保存到 `~/Pictures/ShadowCorp/`。

| 卡 | 尺寸 | 内容 |
| --- | --- | --- |
| 周卡 | 1080 × 1350 | 称号、本周人日、杠杆率、合环状态、本周解锁徽章（最多 6）、本周职业卡、办公室快照、一句总结 |
| 徽章卡 | 1080 × 1080 | 单个徽章大图、名称、解锁语、解锁日期、全局占比、办公室快照角标 |
| 年度卡 | 1080 × 1920 | 全年人日、最高阶段、扮演过的职业数、最稀有成就、最长连续、夜猫子次数、十二个月的人日小柱图 |

卡上永远不出现代码、文件路径、仓库名、prompt 内容、token 或费用；页脚一行"按 IMF / Anthropic Economic Index 方法估算"。

### 10.5 周报

每周一 9:00（本地）生成上周周卡并发一条系统通知；点开即面板周报标签。周报里的数字和周卡一致，不另算。

### 10.6 纯终端模式

不装桌面应用的用户也能用全部计分和成就：`shadowcorp stats` 打印公司页，`shadowcorp badges` 打印成就网格（ASCII），`shadowcorp card --week` 生成周卡 PNG，`shadowcorp shop` 文本商店。大庆祝退化为终端内的 ASCII 徽章框 + 系统通知。

## 11. 社交与排行榜

社交是产品唯一联网的部分，默认关闭，用户在好友标签里主动开启。开启后上传的只有周级汇总数字，永远不上传事件、代码、仓库名或 prompt。设计基调是微信运动而不是竞技场：比的是好友，奖励的是互动。

### 11.1 身份

设备生成 ed25519 密钥对作为匿名账号，所有请求签名；用户只需设置展示名和一个小影头像（可用已购配件）。添加好友用 6 位好友码或二维码，必须双向确认。不接任何第三方登录，v2 再考虑 GitHub 作为可选的发现渠道。

### 11.2 榜与动态

| 功能 | 规则 | 情绪目标 |
| --- | --- | --- |
| 好友周榜 | 按本周人日排序，周一重置；并列显示杠杆率；榜首得 X05 | 周一早上看一眼 |
| 好友杠杆榜 | 按本周杠杆率排序，活跃 ≥ 2 小时才上榜 | 让用得巧的人也有榜 |
| 同职业百分位 | 按用户最高档职业卡分组，只显示"你在前端里排前 8%"，不显示名单 | 身份感，不制造对立 |
| 好友动态 | 史诗以上解锁、升阶、周卡；每人每天最多 3 条 | 看见朋友 |
| 鼓掌 | 对动态点一下，双方各得 10 金币（每日上限 50） | 被看见 |
| 送礼 | 用自己的金币给好友买装饰，对方办公室出现礼物盒，拆开有动画；得 X06 | 可爱的社交货币 |
| 串门 | 查看好友办公室的只读快照（每周同步一次） | 炫耀的出口 |
| 组队周环 | 2–5 位好友共用一个周目标（各自目标之和），合环时全员庆祝 | 合作而不只是比较 |

全球榜不做。全球只有百分位和稀有度占比，避免刷榜和挫败。

### 11.3 同步与后端

客户端每小时（有变化时）上传一条签名的周汇总：`{week, person_days, leverage, active_minutes, stage, unlocked_ids, top_role, office_snapshot_hash}`。后端极简：Cloudflare Workers + D1（或 Supabase），五个接口：`POST /sync`、`GET /board`、`POST /friend`、`POST /kudos`、`POST /gift`。办公室快照是客户端渲染的 PNG，经好友请求时才上传，7 天过期。

### 11.4 反作弊

人日本来就是估算，所以只防明显造假：服务端复核日上限 6 人日、周上限 30 人日；客户端上传事件哈希链的根（不传事件本身），抽查时可要求提交最近 7 天的派生事件；超限或校验失败的账号静默移出榜单，本地功能不受影响。没有任何金钱利益，不做更重的机制。

### 11.5 隐私边界

| 上传 | 不上传 |
| --- | --- |
| 周人日、杠杆率、活跃分钟 | 事件、回合、会话 |
| 公司阶段、已解锁成就 ID、最高职业卡 | 仓库名、文件路径、语言明细 |
| 展示名、头像配置 | 邮箱、真实姓名、设备信息 |
| 办公室快照 PNG（按需） | 任何代码或 prompt |

用户可随时拉黑、删除好友、关闭社交；关闭即删除服务端全部数据。企业内部的团队排行不在本产品范围内。

## 12. 安装与上手流程

安装的目标是：装完 60 秒内用户已经是"工作室主理人"，办公室里已经有人在动。回填是整个上手流程里最重要的一步。

### 12.1 安装步骤（`brew install shadowcorp` 或 `curl -fsSL https://<域名>/install.sh | sh`）

1. 下载二进制到 `/usr/local/bin/shadowcorp`，创建 `~/.shadowcorp/`（spool、SQLite、配置）。
2. 探测已安装的工具：`~/.claude/`、`~/.codex/`、`git`；逐项询问是否接入，默认全选。
3. Claude Code：安装插件（或在无插件市场时直接合并 hooks 到 `~/.claude/settings.json`，先备份原文件）；提示用户确认后写入 statusLine。
4. Codex：按 4.4 写入或链式改写 `notify`。
5. git：询问是否安装全局 post-commit hook。
6. 启动守护进程并注册开机自启（macOS LaunchAgent / Windows 计划任务 / systemd user）。
7. 回填：扫描历史，进度条显示"正在整理你的公司历史…"，超过 10 万事件时先算最近 90 天，其余后台继续。
8. 安装桌面应用（可选，默认是）：下载 .app / .msi，首次启动请求通知权限。
9. 安装总览庆祝：一张卡显示"你已经积累了 N 人日，解锁了 M 个徽章，公司阶段 X"，办公室按阶段直接出现，员工走进来坐下。回填得到的所有成就在这一张卡上总览，不逐个弹出。
10. 引导三步：选展示称号、看一眼本周目标、决定是否开启好友功能。全部可跳过。

`shadowcorp doctor` 检查接入状态；`shadowcorp uninstall` 逆序撤销全部改动并保留数据目录（除非加 `--purge`）。

### 12.2 第一周剧本

| 时间 | 发生什么 | 目的 |
| --- | --- | --- |
| 安装当场 | 回填总览卡，多数用户直接落在工作室或创业公司 | 装的时候不是空的 |
| 第一次跑 agent | 状态栏出现，回合结束弹第一个结算框 | 反馈闭环成立 |
| 第一天晚上 | 办公室进入夜间模式，只有一盏台灯亮 | 陪伴感 |
| 第二天 | 第一个微级点头、第一次金币入账动画、商店解锁 | 建立节奏 |
| 第三天前后 | 第一个时刻徽章（大概率是夜猫子或绿灯） | 第一次中级庆祝 |
| 第一个周一 9:00 | 第一张周卡 + 周报通知 | 第一次分享机会 |
| 第七天 | 习惯 I + 合环（如果达标） | 第一次连续奖励 |
| 第一个月 | 一个人月（M03）或升阶创业公司 | 第一次大庆祝 |

### 12.3 更新

守护进程每天检查一次版本，静默下载，下次启动生效；成就目录和计分常数随版本更新，遵守 5.5 的"只增不减"规则。

## 13. 数据模型与存储

一个 SQLite 文件 `~/.shadowcorp/data.db`（WAL 模式），一个 spool 目录，一个 `config.toml`。事件表是唯一事实来源，其余表都可以从事件重建（`shadowcorp rebuild`）。

```sql
-- 事件：唯一事实来源，只追加
CREATE TABLE events (
  id          TEXT PRIMARY KEY,         -- ULID
  ts          INTEGER NOT NULL,         -- Unix ms
  source      TEXT NOT NULL,            -- claude_code | codex | git | backfill
  kind        TEXT NOT NULL,
  session_id  TEXT,
  turn_id     TEXT,
  cwd_hash    TEXT,
  payload     TEXT NOT NULL             -- JSON，仅派生值
);
CREATE INDEX events_ts ON events(ts);
CREATE INDEX events_session ON events(session_id, ts);

CREATE TABLE sessions (
  id             TEXT PRIMARY KEY,
  source         TEXT NOT NULL,
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  active_minutes REAL NOT NULL DEFAULT 0,
  human_minutes  REAL NOT NULL DEFAULT 0,
  leverage       REAL,
  subagents_max  INTEGER NOT NULL DEFAULT 0,
  files_touched  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE turns (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES sessions(id),
  started_at    INTEGER NOT NULL,
  ended_at      INTEGER,
  task_class    TEXT NOT NULL,
  role_card     TEXT,
  is_correction INTEGER NOT NULL DEFAULT 0,
  files_touched INTEGER NOT NULL DEFAULT 0,
  lines_added   INTEGER NOT NULL DEFAULT 0,
  lines_removed INTEGER NOT NULL DEFAULT 0,
  test_run      INTEGER NOT NULL DEFAULT 0,
  test_passed   INTEGER,
  git_action    TEXT,
  subagents     INTEGER NOT NULL DEFAULT 0,
  human_minutes REAL NOT NULL DEFAULT 0,  -- 5.3 的 H
  scoring_version TEXT NOT NULL
);

-- 每日汇总，封顶后的值
CREATE TABLE daily (
  day           TEXT PRIMARY KEY,        -- YYYY-MM-DD 本地
  person_days   REAL NOT NULL,
  active_minutes REAL NOT NULL,
  turns         INTEGER NOT NULL,
  sessions      INTEGER NOT NULL,
  is_active     INTEGER NOT NULL         -- person_days >= 0.1
);

-- 计数器：成就引擎的输入，scope = all | day:<d> | week:<w> | session:<id>
CREATE TABLE counters (
  metric TEXT NOT NULL,
  scope  TEXT NOT NULL,
  value  REAL NOT NULL,
  PRIMARY KEY (metric, scope)
);

CREATE TABLE unlocks (
  achievement_id TEXT NOT NULL,
  tier           INTEGER NOT NULL,
  unlocked_at    INTEGER NOT NULL,
  backfilled     INTEGER NOT NULL DEFAULT 0,
  celebrated     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (achievement_id, tier)
);

CREATE TABLE ceremonies (            -- 待领取队列
  id        TEXT PRIMARY KEY,
  level     TEXT NOT NULL,           -- mid | grand
  kind      TEXT NOT NULL,           -- unlock | stage_up | ring | record | set
  ref       TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  shown_at   INTEGER
);

CREATE TABLE wallet (
  id      INTEGER PRIMARY KEY CHECK (id = 1),
  coins   INTEGER NOT NULL DEFAULT 0,
  freeze_tokens INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE inventory (
  item_id   TEXT PRIMARY KEY,
  acquired_at INTEGER NOT NULL,
  source    TEXT NOT NULL,           -- reward:<id> | shop | gift:<friend>
  placed_at TEXT                     -- 锚点 ID，NULL = 未摆放
);

CREATE TABLE records (
  key   TEXT PRIMARY KEY,            -- max_day | max_session | max_leverage | max_streak
  value REAL NOT NULL,
  at    INTEGER NOT NULL
);

CREATE TABLE friends (
  friend_id  TEXT PRIMARY KEY,
  display    TEXT NOT NULL,
  added_at   INTEGER NOT NULL,
  last_sync  INTEGER
);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- schema_version, installed_at, device_pubkey…
```

`config.toml`（用户可编辑，守护进程监听变化）：

```toml
[general]
locale = "zh-CN"
weekly_target = 5          # 0 = 自动（6.3）
quiet_hours = ["23:00", "08:00"]
autostart = true

[sources]
claude_code = true
codex = true
git_hook = false

[scoring]
version = "1.0"
classifier_v2 = false

[ceremony]
sound = true
volume = 0.6
grand_cooldown_hours = 4
reduce_motion = "system"   # system | always | never

[social]
enabled = false
anonymous_stats = false
```

保留策略：事件永久保留（典型重度用户一年约 50 MB）；spool 文件被守护进程消费后按天轮转，保留 7 天用于重放。`shadowcorp export` 导出全部数据为 JSON，`shadowcorp purge` 清空。

## 14. 隐私与安全

底线：产品碰得到用户的全部代码和 prompt，但一个字都不存、不传。所有判定在 hook 进程内完成，落盘的只有派生数字和分类标签。

1. hook 进程只写 spool，不发网络请求；守护进程默认无任何出站连接，社交开启后只连后端域名，更新检查只连发布域名。
2. 不落盘的内容：prompt 原文、工具输入输出、命令原文、文件路径（只存 `cwd_hash` 和扩展名统计）、仓库名、提交信息、模型名、token 和费用。
3. 分类器 v2 调用外部模型时，只发送 prompt 的前 200 字符且用户已显式开启；返回值只接受 task\_class 枚举。
4. 安装脚本改动 `~/.claude/settings.json` 和 `~/.codex/config.toml` 前先备份到 `~/.shadowcorp/backup/<时间戳>/`，并逐项征得同意；`uninstall` 用备份原样恢复。
5. 链式 notify 转发时，原命令的参数原样传递，错误不影响原命令执行。
6. spool 和数据库文件权限 0600；社交密钥存系统钥匙串（macOS Keychain / Windows Credential Manager），不存文件。
7. 分享卡和办公室快照是纯渲染结果，不含元数据（PNG 不写入任何文本块）。
8. 匿名统计 opt-in 后只上传成就解锁的全局计数，不带账号。
9. 二进制签名与公证（macOS notarization、Windows Authenticode）；安装脚本校验 SHA-256。
10. 守护进程以用户权限运行，不请求任何系统权限；通知权限和辅助功能权限只在首次使用相关功能时请求。

## 15. 非功能要求

| 指标 | 目标 | 测法 |
| --- | --- | --- |
| hook 进程耗时（读 stdin → 写 spool → 退出） | p95 < 20 ms，p99 < 50 ms | fixtures 回放 1000 次 |
| Stop hook 含结算框 | p95 < 300 ms，超时静默退出 | 同上，守护进程开/关两种情况 |
| 回合结算延迟（turn\_end 到状态栏更新） | < 500 ms | 端到端 |
| 回填速度 | ≥ 5000 事件 / 秒 | 90 天真实 transcript |
| 守护进程常驻内存 | < 40 MB | 24 小时运行 |
| 守护进程空闲 CPU | < 0.5% | 24 小时运行 |
| 桌面应用空闲 / 庆祝 CPU | < 2% / < 8% | 面板打开 10 分钟 |
| 安装包体积 | CLI < 15 MB，桌面应用 < 30 MB | 发布产物 |
| 离线可用 | 除社交外 100% 功能离线可用 | 断网测试 |
| 数据可靠性 | 守护进程崩溃或未运行时零事件丢失 | kill -9 后重放 spool |
| 启动 | 开机自启到托盘可用 < 2 秒 | 冷启动 |
| 平台 | macOS 13+（Apple Silicon 与 Intel）首发；Windows 11、Ubuntu 22.04+ 第二期 | CI 矩阵 |
| 本地化 | 简体中文、英文，字符串全部外置 | 切换语言后无硬编码文案 |
| 无障碍 | 面板可键盘操作，庆祝层遵循减少动态效果，所有颜色含义同时有图标 | 手动检查 |

## 16. 开发里程碑与验收标准

九个里程碑，顺序原则是：先有真实数据（计分与回填），再有反馈（成就与结算框），然后才做桌面和办公室，社交最后。每个里程碑有一个可验证的门槛，过了才进下一个。

&#91;embedded content: 路线图 · M0–M8，每个阶段右端的菱形是验收门槛\]

上排五个里程碑是纯终端产品，M2 过门后就能给内测用户；下排从可爱的那一半开始，以公测留存收口。

| 里程碑 | 交付 | 验收门槛 |
| --- | --- | --- |
| M0 骨架 | Rust workspace、事件 schema、spool 写入、`shadowcorp hook`、SQLite 初始化、Claude Code 插件清单 | fixtures 回放全部事件类型无错；hook p95 < 20 ms |
| M1 计分与回填 | 分类器 v1、5.3 公式、sessions / turns / daily、transcript 回填、`shadowcorp stats` | 5.3 黄金用例通过；90 天真实 transcript 回填 < 60 秒且总数落在 5.5 区间 |
| M2 成就与进度 | `achievements.json` + 引擎、计数器四作用域、阶段 / 金币 / 周环 / 连续 / 纪录、状态栏、终端结算框 | 52 个成就各有单测；结算框在 Stop 后 300 ms 内出现 |
| M3 桌面应用 | Tauri 托盘、公司与成就标签、系统通知、全屏庆祝层、四档音效、待领取队列 | 史诗成就端到端触发大庆祝；空闲 CPU < 2% |
| M4 办公室与商店 | Canvas 场景七阶段、状态机、小影精灵、装饰锚点、商店与库存 | 状态机六态转换测试；升阶施工动画可见 |
| M5 分享与周报 | 周卡、徽章卡、年度卡模板与渲染、周报通知 | 模板自动扫描无敏感字段；PNG 无元数据 |
| M6 Codex 与 git | notify 链式写入、Codex 回填、git post-commit、X01 / X02 | 同日 Claude Code + Codex 触发"双修" |
| M7 社交 | 后端五接口、设备身份、好友、周榜、鼓掌、送礼、组队周环 | 反作弊上限生效；11.5 隐私表逐项核对通过 |
| M8 打磨与发布 | 安装脚本、brew tap、doctor / uninstall、签名公证、中英文、早鸟徽章、公测 | 10 位内测用户完成 12.2 剧本；第一周留存 ≥ 60% |

M0–M2 是纯终端产品，已经可以给内测用户用；M3–M5 是可爱的那一半；M6–M7 扩大覆盖；M8 发布。

## 17. 测试策略

核心逻辑全在 `crates/core`，没有 IO，所以大部分测试是纯函数的黄金用例；采集层用录制的真实 hook JSON 回放；界面用截图比对。

### 17.1 fixtures

| 目录 | 内容 | 来源 |
| --- | --- | --- |
| `fixtures/hooks/claude_code/` | 每种 hook 事件各 ≥ 3 个真实 stdin JSON（含 Edit、Write、Bash 测试命令、Task、Notification） | 开发者自己的会话，脱敏脚本去掉内容字段 |
| `fixtures/hooks/codex/` | notify 的 JSON 参数样本、链式调用样本 | 同上 |
| `fixtures/transcripts/` | 一份 90 天的 Claude Code transcript 目录、一份 Codex rollout 目录，全部脱敏 | 回填性能与总量校验 |
| `fixtures/scoring/golden.yaml` | 5.3 的四个黄金用例 + 20 个边界用例（空回合、只读回合、超大 diff、封顶） | 手写 |
| `fixtures/achievements/` | 每个成就一条"刚好解锁"和一条"差一点"的事件序列 | 由 achievements.json 自动生成骨架，人工补充 |
| `fixtures/ui/` | 面板五个标签、庆祝层四档、办公室七阶段的基准截图 | 首次人工确认后锁定 |

### 17.2 测试层级

1. 单元（`crates/core`）：分类器对每个关键词表项命中；公式对黄金用例误差 < 0.5 分钟；封顶；杠杆率在活跃 < 5 分钟时为 None；计数器四作用域的滚动；成就引擎对 52 × 2 条序列的解锁 / 不解锁；连续与冻结券；周环自动目标；"只增不减"的常数升级。
2. 回放（`crates/daemon`）：把 fixtures 按时间顺序写入 spool，断言 SQLite 终态；中途 kill -9 守护进程再启动，终态一致（幂等）；重复事件 ID 只入一次。
3. 性能：hook 进程 1000 次回放的 p95 / p99；回填 90 天 transcript 的耗时与峰值内存。
4. 契约：对官方 hooks 文档和 statusline 文档中的字段名做一个"字段存在性"测试，字段改名时 CI 直接失败并指向文档链接。
5. 界面（Tauri + Playwright）：面板每个标签的截图比对；庆祝层在"减少动态效果"开启时无放大动画；免打扰期间不弹层；待领取队列的顺序。
6. 隐私（自动）：对 spool、SQLite、分享卡 PNG、上传载荷做正则扫描，出现路径、仓库名、常见代码片段特征或 prompt 片段即失败；PNG 文本块为空。
7. 安装（CI 矩阵）：全新 macOS 镜像上跑 install.sh → doctor 全绿 → uninstall → settings.json 与原备份逐字节一致。

### 17.3 发布前手动清单

- [ ] 用真实会话跑完 12.2 第一周剧本，每一步的庆祝级别和文案与第 8 节一致
- [ ] 四档音效在 23:00 后静音、画面照常
- [ ] agent 等待权限时触发一个史诗成就，确认它进入待领取而不是弹出
- [ ] 关闭社交后服务端无该账号数据（调用 `GET /me` 返回 404）
- [ ] 中英文切换后无硬编码文案
- [ ] 断网状态下安装、回填、计分、庆祝全部正常

## 18. 给 Claude Code（Opus 5.5）的开发指引

这份文档导出为 Markdown 后放在仓库 `docs/SPEC.md`，是唯一的需求来源；`CLAUDE.md` 只放工作规则并指向它。开发用 Claude Code，模型选 Opus 5.5（`/model` 切换），每个里程碑先用计划模式过一遍再动手。

### 18.1 CLAUDE.md 草稿

```markdown
# ShadowCorp（影子公司）

衡量产出的 AI 编码成就系统。需求唯一来源：docs/SPEC.md。成就目录唯一来源：assets/achievements.json。

## 命令
- 构建：`cargo build --workspace`；桌面：`pnpm -C apps/desktop tauri dev`
- 测试：`cargo test --workspace`（核心黄金用例在 fixtures/scoring/golden.yaml）
- 回放：`cargo run -p daemon -- replay fixtures/hooks/claude_code`
- 隐私扫描：`cargo run -p cli -- privacy-scan`（提交前必跑）

## 规则
- crates/core 不做任何 IO；所有计分、进度、成就逻辑只在这里。
- 事件表只追加；任何让用户历史总数变少的改动都不允许（SPEC 5.5）。
- 不落盘、不上传 prompt / 代码 / 路径 / 仓库名 / token / 费用（SPEC 14）。
- 改计分常数或成就阈值前先问我，并同步更新 golden.yaml。
- 新增成就 = 改 achievements.json + 两条 fixtures 序列 + 一句解锁语（≤ 18 字），不改引擎代码。
- 文案遵守 SPEC 8.5：说产出不说节省，永远向上，不提 token。
- Claude Code hooks / statusline / 插件清单的字段名，每次使用前核对官方文档，不凭记忆。
- Codex notify 载荷同样先核对当前版本文档，并保留链式转发。

## 工作方式
- 一个里程碑一个分支（m0-skeleton、m1-scoring…），过 SPEC 16 的门槛才合并。
- 先写 fixtures 和测试，再写实现。
- 美术资源（精灵表、音效、分享卡模板）单独开子任务，不和核心逻辑混在一个 PR。
- 提交信息用 Conventional Commits；每个 PR 附上跑过的测试命令和结果。
- 不确定的产品决策写进 docs/OPEN_QUESTIONS.md，不要自行决定后埋进代码。
```

### 18.2 第一个会话怎么开

1. `claude --permission-mode plan`，让它通读 `docs/SPEC.md` 和 `CLAUDE.md`，输出 M0 的文件清单和接口草图，确认后再退出计划模式。
2. 让它先生成 `fixtures/hooks/` 的脱敏脚本，用你自己的 `~/.claude/projects` 跑一遍，得到真实样本。
3. 再做 M0：事件 schema、spool、`shadowcorp hook`、SQLite 初始化，以 17.2 第 2、3 条的回放和性能测试收口。

### 18.3 需要你亲自定的事

产品名与 CLI 名（本文用 ShadowCorp / `shadowcorp` 占位）、小影的最终形象、四档音效的风格样本、好友码的前缀、后端域名。这些在 M3 之前定下即可。

## 19. 开放问题

- [ ] 产品名：ShadowCorp / 影子公司是占位，需要定英文名、中文名和 CLI 命令名
- [ ] 人日的英文展示：person-day 还是 dev-day，影响所有英文文案
- [ ] 分类器 v2 是否值得做：v1 规则上线后看 `other` 类占比，超过 25% 再做
- [ ] 杠杆率显示上限 50x 是否太高：看内测用户周卡的分布再定
- [ ] Codex 侧缺工具级事件，"绿灯""外科医生"等成就在 Codex 用户那里会更难解锁，是否需要按来源降低阈值
- [ ] 组队周环是 M7 做还是推到 v2
- [ ] 季节限定装饰的日历：中秋、春节、圣诞、万圣节，是否要做地区差异
- [ ] 早鸟徽章的公测窗口长度
- [ ] Windows 托盘与透明覆盖层的 Tauri 2 支持程度，M3 前做一次技术验证
- [ ] 是否接 Cursor / Windsurf 的原生接口（如果它们后来提供 hook）

### 参考

- [Claude Code hooks 参考](https://code.claude.com/docs/en/hooks)
- [Claude Code settings 参考](https://docs.claude.com/en/docs/claude-code/settings)
- [Codex CLI 通知机制说明（社区整理）](https://codex.danielvaughan.com/2026/04/10/codex-cli-agent-notifications-desktop-alerts-monitoring/)
- [IMF WP 26/147 摘要，Fan & Nguyen（SSRN）](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=7314760)
- [Anthropic Economic Index 数据集（CC-BY）](https://huggingface.co/datasets/Anthropic/EconomicIndex/blob/main/README.md)
- 同类产品：[orank](https://github.com/sedhuait/orank)、[ClaudeXP](https://github.com/EvanPaules/ClaudeXP)、[claude-usage-pet](https://github.com/plugin87/claude-usage-pet)、[buddy-evolution](https://github.com/FrankFMY/buddy-evolution)
