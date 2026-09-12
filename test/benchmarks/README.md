# Godot MCP 真实任务评测（M2 基架）

定位：用**真实游戏制作任务**度量"一句自然语言目标 → AI 靠谱完成游戏功能"的首过成功率与诚实度，用实际失败决定下一轮投入。本目录是评测协议与任务清单的单一真相；不建设评测平台服务。

## 与既有测试的关系

- `test/integration/` 是**固定工具调用**的确定性测试（回放已知正确的调用序列）。
- 本目录是**真实代理运行**评测：同一模型版本自由选择工具完成任务，oracle 独立验收。工具返回 completed 只是待核验声明，不等于通过。
- 两者不得混用结论：回放通过 ≠ 代理能独立完成。

## 对照协议（必须全部相同，缺一不可）

| 维度 | 要求 |
| --- | --- |
| 模型 | 同一具体模型版本（含采样参数） |
| 客户端/代理框架 | 同一 harness，仅 MCP server 配置不同 |
| Godot | 同一可执行文件、同一渲染器、同语言（UI 文案） |
| 初始项目 | 每次运行使用新的干净副本（同一定义，见 tasks/manifest.json） |
| 预算 | 正式对照前固定（模型 token、工具调用数、墙钟时间）；耗尽记失败或超时，**不从样本删除** |
| 验收目标 | 同一 oracle 程序，对两个产品一视同仁；不能给一个产品标准答案而只给另一个用户需求 |

先运行 3 个代表任务校准预算（N1、E4、R3），再按每任务重复 3 次（12×3 = 每产品 36 次，双产品 72 次）。小样本仅用于方向判断，报告分任务给出结果与不确定性，不得宣称统计意义的全面领先。

## 诚实规则（硬性）

1. **oracle 必须先自证**：对故意损坏的项目运行 oracle，必须失败；oracle 失效即本轮评测作废。
2. 代理修改 oracle、删除既有测试、或在禁改范围内改动 → 该次记 0 分并披露。
3. 工具/工作流报告的 completed 不计分，只计 oracle 独立验收结果。
4. "错误的完成声明"（agent 声称完成但 oracle 验收失败）单独计数——这是诚实度核心指标。
5. 数据缺失记 `null`，禁止填 0（成本/耗时取不到真实值时）。
6. 保留失败、超时、unsupported 样本；报告必须能由原始 JSONL 事件重算。

## 事件记录（JSONL，每次运行一个文件）

每行一个事件，写入 `runs/<run_id>.jsonl`：

```json
{"t": "iso8601", "run_id": "...", "task_id": "N1", "product": "godot-mcp-native", "model": "...", "godot": "4.7.2", "event": "run_started", "payload": {"objective": "..."}}
{"t": "...", "event": "tool_call", "payload": {"tool": "create_node", "args_digest": "sha256:...", "tokens_in": 1234, "tokens_out": 56}}
{"t": "...", "event": "tool_result", "payload": {"tool": "create_node", "ok": true, "duration_ms": 42}}
{"t": "...", "event": "agent_statement", "payload": {"claims_completed": true, "text_digest": "sha256:..."}}
{"t": "...", "event": "oracle_check", "payload": {"check": "pause-world-stopped", "passed": true, "evidence": "get_tree().paused==true at t+2s"}}
{"t": "...", "event": "run_ended", "payload": {"outcome": "pass|fail|timeout|unsupported|budget_exhausted", "oracle_passed": true, "human_interventions": 0, "wall_clock_s": 610, "tool_calls": 38, "tokens_in": 210000, "tokens_out": 18000, "recovery_s": null}}
```

## 指标

独立验收通过率、错误完成声明数、人工介入次数、恢复耗时、工具调用数、模型输入/输出 token、墙钟耗时、失败原因分类。聚合按任务分组报告。

## 任务清单

见 `tasks/manifest.json`（12 项：新建 N1–N4、修改 E1–E4、恢复 R1–R4）。每个任务定义：用户目标（原话，中英各一）、初始项目规格、禁止改动范围、oracle 验收步骤（尽量落到可执行的 MCP 工具序列）、必须留存的证据。

## 报告

每次对照产出 `report-<date>.md`（模板见 `report_template.md`），含：分任务通过率表、错误完成声明、人工介入、成本、主要失败模式与不确定性说明、原始事件文件清单。
