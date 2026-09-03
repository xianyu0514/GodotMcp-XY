# Goal Playbook — 从一句话目标到完成的正确用法

面向 AI 客户端与开发者的实操手册：如何把一个目标交给 MCP 并可靠推进到 `completed`。架构细节见 [Complete Game Workflows](game-workflows.md)；本文只讲怎么用、什么算完成、出问题时看哪里。

## 两条路径，怎么选

| 场景 | 用法 | 特点 |
| --- | --- | --- |
| 短任务（几分钟内） | `enable_tools({"workflow_query": "<目标>"})` → 直接调用激活的工具 | 一次调用激活 ≤8 个工具；命中配方时响应带 `suggested_prompt` |
| 完整功能/整游戏 | `plan_game_workflow` → 循环 `run_game_workflow` 直到 `completed` | 持久目标 DAG、断点续跑、证据门禁；编辑器重启后可恢复 |

**目标措辞**：说清可验证的产出，不要只说领域词。好例：“方向键移动的角色，吃到金币后显示胜利标签；脚本要过校验，项目要过冒烟测试”。差例：“做个好玩的游戏”（无法编译出可验证的步骤时会显式要求澄清，不会假装完成）。

## 完成判定：证据，不是语气

`completed` 要求每个 objective gate 拿到引擎侧证据：

- `assert_no_runtime_errors` — 运行期零报错（`max_errors` 默认 0）
- `assert_performance_budget` — 采样窗口内 `min_p1_fps` / `max_p95_frame_time_ms` 等预算
- `assert_visual_baseline` — 与 `user://visual_baselines/` 黄金图对比，超容差即失败
- `verify_scripts` / `run_project_tests` / 冒烟测试 — 结构化 pass/fail 计数

缺失的度量按失败处理——证明不了就是没达标。故障注入场景用 `expect_fail` 反转门禁（证明检测器真的会拦）。

## 推进循环与状态语义

反复调用 `run_game_workflow`（`max_steps=0` 自适应切片，永不截断目标），按 `state` 行动：

- `running` / 空 → 继续调用
- `waiting`（无 `needs_input`）→ 异步步骤进行中，稍后再调
- `needs_input` → 响应里有步骤 id、缺失字段和 input_schema；创作性字段（content/patches 等）额外附带 `content_brief`：目标原文、目标文件、被改文件现状（锚点编辑而非盲写）、已产出工件、下游门禁清单——按简报生成再提交，一次写对。内容用 `step_inputs` 提供：`{"<step_id>": {"content": "..."}}`
- `repairing` / `repair_required` → 引擎正在用步骤声明的修复工具自愈，继续调用即可
- `replan_required` / `blocked` → 看 `blocked_reason`；输入或能力缺失是显式阻塞，不是静默跳过
- `completed` → 每个门禁都有回执摘要与工件路径

## 可执行配方（prompts）

`prompts/list` 提供 9 个即用流程模板；`enable_tools` 命中关键词时会在响应里 `suggested_prompt` 提示：

| 配方 | 用途 |
| --- | --- |
| `plan_game_feature` | GDD → 带门禁的任务图 |
| `iterate_play_verify` | 运行→观测→门禁→最小修复循环（3 次同败即停） |
| `debug_runtime_error` | 运行错误端到端排查 |
| `fix_compile_errors` | 编译/校验错误修复循环 |
| `visual_playtest` | 视觉回归试玩 |
| `review_scene` | 场景审计 |
| `run_test_suite` | 测试发现与转绿 |
| `release_export_flow` | 模板→预设→版本→导出→冒烟→报告 |
| `onboard_new_project` | 新项目上手与工具启用 |

## 迭代目标与项目记忆

第一个目标 `completed` 后，工件与语义测试套件会记入 `res://.mcp/project_state.json`（项目状态账本，有界历史 50 条）。第二个 gameplay 目标默认进入**迭代模式**：打开既有场景 → 读取既有控制器 → 按 `content_brief`（含现有脚本内容与下游门禁）修改 → 编译/语义/运行验证——上一目标留下的语义套件会重跑一遍，证明原行为没被改坏。`replace=true` 明确从零开始；账本损坏时静默降级为首次使用（读侧永不报错）。只有场景+脚本齐备才进迭代模式，残缺上下文宁可新建。

## 目标覆盖回归（维护者）

`test/unit/test_goal_coverage_corpus.gd` + `fixtures/goal_coverage_tasks.json` 是首过规划成功率的回归门禁（40 条中英真实目标、12 个 profile 全覆盖、组合目标不断言澄清）。改动 PROFILE_KEYWORDS 或分类逻辑后必须跑它；发现真实用户目标进了 `needs_clarification`，先把目标加进语料（复现），再补词表让它转绿——词表永远跟着真实目标走。

## 已知引擎语义（不是 bug，按此设计调用）

- **非 `@export` 脚本变量在编辑器场景节点上不绑定**：批量 `set_property` 会如实回报 `bound:false` 并提示改 `@export`；游戏运行时正常。
- **编辑器失焦可能节流主循环**：长下载等节点驱动任务会临时开启 Update Continuously 保活，结束自动恢复。
- **刚写入的脚本文件是"冷资源"**：工具内部已做编译守卫；自定义脚本若手动 `load()` 刚写的文件，注意 `can_instantiate()`。
- **首场景/首脚本路径自动推导**：不传路径时按 profile 落到 `res://scenes|scripts|themes/<profile>...`；要控制位置就显式传 `scene_path`/`script_path`。
- **目标蓝图**：目标提到移动/收集/胜利（双语）时，`create_script` 自动生成真实控制器（含运行期生成的拾取体与胜利标签）、场景根派生为 `CharacterBody2D`；显式传 `content` 永远优先。提到跳跃/横版/platformer（双语）时走**横版变体**：水平移动 + 重力 + 地面检测 + 跳跃（`jump` 动作，缺省回退 `ui_accept`），输入动作集也相应只注册 左/右/jump——不会再给跳跃目标生成俯视 8 方向控制器。
- **目标语义门禁**：命中动词的目标会额外生成一个 `McpGameTestSuite`（`res://tests/game/gameplay_semantic.gd`）并作为 objective gate 执行——断言"输入会位移、跳跃会升起、金币被走到并吃到、胜利标签随后出现"。`completed` 因此证明的是目标行为真的发生，而不只是"没有报错"。这些行为测试留在用户项目里，成为可持续回归资产。目标提到 3D/三维时蓝图整体切换 3D 形态（`CharacterBody3D` + 无限地面 + 运行期相机/灯光，语义测试按 3D 坐标系断言）。动词覆盖：移动/跳跃/收集/胜利/**敌人（追逐）**/**计分**——计分蕴含收集循环（ScoreLabel 随拾取实时更新）；**射击**类目标只做分类与移动载体，弹道逻辑由客户端凭 `content_brief` 创作。

## 出问题时的取证顺序

0. 工具返回 "Tool is disabled" 时先 `enable_tools`（supplementary 工具默认关闭，
   这是设计行为而非故障；大型项目上 `list_project_tests` 实测 <0.1s，慢的错觉
   常来自把禁用报错当成了超时）
1. `run_game_workflow` 响应的 `blocked_reason` + 最后一个 `executed` 条目
2. `manage_task_plan` / 计划文件（`.mcp/<plan>.json`）里的回执摘要
3. `get_editor_logs`（`source='runtime'` 看运行错误，`source='editor_panel'` 看引擎报错）
4. 目标级回归 `test/integration/test_game_goal_flow.py`（全新项目 → completed 全链路）可当作行为基线

## 自动提交的回归保障

- `test_game_goal_flow.py` — 目标级闭环（scratch 项目 → plan → run → completed）
- `test_batch_scene_node_edits_flow.py` — 单调用脚本化节点组装 + 真值断言
- 1784 项单元测试覆盖路由、门禁语义、缓存一致性与工具校验
