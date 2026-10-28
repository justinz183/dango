# 影子公司（ShadowCorp）

衡量产出的 AI 编码成就系统：把 Claude Code 每个回合完成的工作折算成**人日**，配上徽章、连续天数、公司阶段和回合结束时的结算框。不统计 token，不存 prompt、代码或路径。

需求：[docs/SPEC.md](docs/SPEC.md)。实现取舍与待定问题：[docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)。

## 当前进度

| 里程碑 | 状态 |
| --- | --- |
| M0 骨架：事件 schema、spool、`shadowcorp hook`、SQLite、插件清单 | ✅ |
| M1 计分与回填：分类器 v1、人日公式、sessions / turns / daily、transcript 回填、`stats` | ✅ |
| M2 成就与进度：53 个成就 + 引擎、四作用域计数器、阶段 / 金币 / 周环 / 连续 / 纪录、状态栏、结算框 | ✅ |
| M3–M8（桌面应用、办公室、分享卡、Codex/git、社交、安装发布） | 未开始 |

M0–M2 是纯终端产品（SPEC 16）。

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

## 命令

| 命令 | 作用 |
| --- | --- |
| `shadowcorp hook` | 所有 hook 的入口：读 stdin，写 spool，永远 exit 0 |
| `shadowcorp status [--claude]` | 一行状态 |
| `shadowcorp stats` / `badges` | 公司页 / 成就与职业图鉴 |
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
