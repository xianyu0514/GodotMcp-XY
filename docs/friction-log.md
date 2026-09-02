# Friction log — Godot MCP Native

滚动记录真实客户端使用中的痛点、意外与缺陷（参考 godot-ai 的实践：最新的条目放在最上面，方便下一个人看到当前状态）。
每次与真实 AI 客户端（Claude Code / Cursor / Cline / Codex 等）跑完一个任务后，若遇到摩擦就在此追加一条。
条目格式：日期、客户端、现象、根因（若已知）、状态（open / fixed / by-design）与对应提交。

修复一个 open 条目时，把它改为 fixed 并附提交号；"已知引擎语义"（见
[goal-playbook.md](goal-playbook.md)）类条目标注 by-design，不重复登记。

---

## 2026-09-03 — 平台跳跃目标"假完成"（fixed）

- **客户端**：目标级集成回归（test_game_goal_flow.py 语义分析）
- **现象**：目标说 "2D platformer / jump / 跳跃"，工作流生成的是俯视 8 方向
  移动控制器——没有重力、不能跳跃，但所有门禁（编译、无运行错误、移动演练）
  全绿，目标 `completed`。`completed` 证明的是"没出错"，不是"目标达成"。
- **根因**：`goal_blueprints.gd` 只有单一移动块；`platformer/jump` 关键词与
  俯视移动共用同一蓝图；门禁没有目标语义证据。
- **状态**：fixed（本次提交加入横版重力+跳跃蓝图变体与语义区分）。
  语义证据门禁的系统性解法见游戏测试框架（后续条目）。

## 2026-09-03 — needs_input 只返回裸 schema，客户端盲写内容（open）

- **客户端**：任意客户端提交创作性内容（脚本 content 等）时
- **现象**：`needs_input` 响应只有 `step_id/tool_name/missing_inputs/input_schema`。
  客户端模型看不到当前场景树、已有脚本、之前步骤产出、下游门禁会验什么，
  只能凭空写，多轮质量不稳定。
- **期望**：needs_input 附带"内容简报"（目标子句、目标文件、场景摘要、被改
  脚本现状、已产出工件、下游验证清单）。
- **状态**：open。

## 2026-09-03 — 编辑器未启动时 MCP 不存在（open）

- **客户端**：客户端先启动、后开 Godot 的任何场景
- **现象**：服务器活在编辑器进程里，编辑器没开时客户端连接直接失败，没有
  "降级可用 + 自动拉起编辑器"的路径。竞品（godot-ai attach）已验证该体验
  的价值。
- **候选方案**：轻量 stdio shim：客户端启动 shim → shim 拉起 Godot 编辑器
  （带 --mcp-server）并代理 stdio。
- **状态**：open。
