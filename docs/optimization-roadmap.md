# Godot MCP Native — 优化路线图（定稿）

> 目标：把本项目从"功能最多"优化为"协议最合规、agent 体验最好、闭环最完整"的编辑器型 MCP 服务器。
> 本文档为研究综合稿，基于：代码第一手审计（含 3 子代理交叉验证）+ 竞品调研（`docs/competitive-analysis.md`）+ MCP 规范研究（`docs/research/mcp-spec-research-2025-2026.md`）+ Godot 引擎能力研究（`docs/research/godot-engine-mcp-capability-gap-report.md`）。
> 状态：定稿（v1）。

---

## 0. 现状总结（第一手确认）

| 维度 | 现状 | 评价 |
| --- | --- | --- |
| 工具面 | 221 工具（28 core + 189 supplementary + 4 meta），6 大类 + Meta（S4 已降级 execute_*；已加 search_tools/get_tool_details/verify_scripts/undo/redo/get_undo_history） | 业界最广，远超 Coding-Solo(~14)/MCP4Godot(38)/Unity-MCP(47) |
| 架构 | 纯 GDScript 原生 EditorPlugin，零外部依赖 | 结构性优势：无"进程启动器+抓 stdout"的假成功问题 |
| 传输 | HTTP/SSE(:9080) + stdio，手写 HTTP 服务器（独立线程 + call_deferred 回主线程） | 可用但未跟上 2025 标准 Streamable HTTP |
| 协议面 | initialize/tools/resources/prompts 四组方法 + instructions 渐进披露 | prompts 已实现（7 工作流 prompt）；缺 completion/sampling/elicitation/分页 |
| 安全 | Bearer 认证、路径校验、脚本沙箱（能力黑名单）、速率限制、工具分级 | 分层合理；路径校验用黑名单而非规范化 |
| 验证闭环 | play_and_verify / assert_performance_budget / assert_no_runtime_errors / assert_visual_baseline / smoke_test_export / manage_task_plan(DoD gates) | 业界领先的"工业化"闭环 |
| 测试 | ~100 GUT 单测 + 40 集成测试 + CI（headless import + GUT） | 全量 0 失败（Godot 4.7.2 + GUT 9.7.1）；含 schema lint |
| 文档 | 全套 docs + 中英双语 + 翻译文件 | 优秀；计数一致（221/28/189 已核对） |

---

## 1. 必须修复的协议缺陷（高优先，影响合规与客户端兼容）

> 规范情报：已迭代到 **2026-07-28（draft）**：stateless MCP、`server/discover`、MRTR、Tasks 扩展、**Roots/Sampling/Logging 正式弃用（SEP-2577）**、HTTP+SSE 正式废弃、列表结果要求 `ttlMs`/`cacheScope`。**Claude Code 已按 2026-07-28 校验列表响应**（缺 `ttlMs`/`cacheScope` 被拒，issue #88128）。

| # | 问题 | 证据 | 修复 |
| --- | --- | --- | --- |
| P0 | **tools/list 等列表响应缺 `ttlMs`/`cacheScope`/`resultType`** | 2026-07-28 规范 + Claude Code issue #88128（缺字段被拒） | `tools/list`/`resources/list`/`prompts/list` 结果补 `_meta.ttlMs` 与 `cacheScope`；**最高紧急** |
| P1 | `ping` 未处理 → 返回 -32601 Method not found | `mcp_server_core.gd` `_handle_request` 的 match 无 `ping` 分支（Claude Desktop 等会发 ping） | 增加 `ping` → 返回 `{}`，并加单测 |
| P1b | **未知方法/通知被错误地回响应** | 无 id 的通知（如 notifications/cancelled、notifications/progress）在 `_handle_request` 落到 `_` 分支返回错误响应；`_drain_request_queue`（L284-288）对非空字典一律发送 → 违反"通知不应有响应" | 无 id 的消息永不回响应；未知方法仅对带 id 的请求回 -32601 |
| P1c | **速率限制作用于通知**（对通知返回错误响应） | `_handle_request` L401 对通知也做 `_check_rate_limit` | 仅对请求（带 id）限流 |
| P1d | **JSON-RPC 批处理请求崩溃** | `mcp_http_server.gd` L496 `json.get_data()` 直接赋给 `Dictionary`，数组（batch）会类型断言崩溃 | batch 返回 -32600 Invalid Request（MCP 不支持 batch，官方以并发+Tasks 覆盖） |
| P2 | prompts 空壳：capabilities 声明 `prompts.listChanged` 但 `register_prompt` 零调用，`prompts/list` 返回空 | grep 全仓无 `register_prompt(` 调用点；`test_mcp_prompts_resources.gd` 存在但无真实 prompt | 注册 6~8 个高价值工作流 prompt（见 §3） |
| P3 | 无 `completion/complete`（capabilities.completion 缺失） | 规范提供；对 prompts 参数/资源 URI 补全有用（支持面窄，P1 优先级） | 为 prompts 参数实现 completion |
| P4 | 无 `notifications/progress`、无 `notifications/cancelled` | 长任务（export/烘焙/外部生成）无进度反馈，无法取消 | 长工具加 progress 上报；处理 cancelled；分钟级任务演进为 Tasks 扩展（`io.modelcontextprotocol/tasks`，适配 generate_3d_asset/play_and_verify/smoke_test_export） |
| P5 | tools/list、resources/list、prompts/list 无分页（`nextCursor`） | 221 工具全量返回；规范支持分页 | 加 cursor 分页（>100 项时启用），配合 P0 的 ttlMs |
| P6 | 无 `resources/templates/list` | 适合 `godot://scene/{path}` 模板 | 注册 URI 模板 |
| P7 | `serverInfo.version` 为 `"2.0.0"`、HTTP GET / 返回 `"1.0.0"` + `"MCP 2025-03-26"`，与插件 1.0.7-pre1 不一致 | `mcp_server_core.gd` L460 / `mcp_http_server.gd` L517 | 统一从 plugin.cfg 读版本 |
| P8 | stdio 传输 `stop()` 潜在死锁：线程阻塞在 `OS.read_string_from_stdin()` 时 `wait_to_finish()` 挂起 | `mcp_stdio_server.gd` L64-66 + L95 | 非阻塞读或超时退出机制；单测覆盖 |
| P9 | **缺少 `search_tools`/`get_tool_details` 元工具** | 官方渐进发现三层模式：catalog（search_tools）→ details（get_tool_details）→ execute；现有 `list_tool_catalog` 已对齐第一层 | meta 工具补齐三层；`tools/list` 保持确定性排序（利于 prompt cache） |

---

## 2. 传输层升级：Streamable HTTP（高优先）

现状：手写 HTTP 服务器实现经典 SSE（GET 建立流 + POST 请求）；规范自 2025-06-18 起以 **Streamable HTTP**（单端点 POST + `Accept: application/json, text/event-stream` 协商 + `Mcp-Session-Id` 会话头）为唯一 HTTP 形态，2026-07-28 已**正式废弃 HTTP+SSE**；同路线竞品 MCP4Godot 已按新标准实现。

影响面：
- Codex CLI 加载失败（issue #1/#24）与 -32601（issue #21）疑与此相关；
- 注意 2026-07-28 draft 的 **stateless MCP** 方向（去 session/握手）——实施时优先走 stateless 风格，避免在 session 管理上过度投入。

方案：
1. 同一端口双轨：POST /mcp 按 `Accept` 头协商（application/json → 单响应；text/event-stream → SSE 流式响应）；
2. 保留现有 GET SSE 端点做向后兼容（老客户端）；
3. 会话管理按 stateless 方向简化（若实现 Mcp-Session-Id，同步支持 DELETE 终止）；
4. 版本协商：`server/discover`（新）+ 旧握手双兼容（`mcp_types.gd` 已有 4 版本协商可扩展）。

## 3. 补齐 agent 体验的"最后一环"

### 3.1 编译错误反馈（最高价值缺口 — issue #9/#12/#32）

第一手确认的根因：
- `get_editor_logs` 的 `source=editor_panel` 依赖 **UI 节点名查找**（`base_control.find_child('*Output*')` / `'*Errors*'`）——非英语编辑器界面下节点名是翻译后的，直接失败（#32）；
- 回退路径硬编码 `editor_log-4.6.stable.txt`（目标引擎 4.7，此文件名不存在）；
- `validate_script` 虽做 `GDScript.reload()` 编译，但错误详情提取靠 `_error_text` meta 或关键词启发式（`_is_syntax_error_line`），行号/列号不可靠。

修复方案：
1. 新增 `verify_scripts` 工具（或增强 validate_script）：批量解析/编译指定脚本，返回**带行号的结构化错误/警告**；
2. `get_editor_logs` 增加与 UI 无关的日志源：`user://logs/godot.log`（含 `SCRIPT ERROR`/`PARSE ERROR` 且带行号，版本无关）；
3. 把"修改脚本 → 自动编译校验"串进写工具（modify_script 后自动 reload 校验并回读）；
4. i18n 修复：`*Output*`/`*Errors*` 节点名不再硬编码。

### 3.2 真实 prompts（把工业化 playbook 变成协议资产）

现有 `docs/industrialization/` 的 playbook（GDD→任务图、单切片 PLAN→EXECUTE→RUN→VERIFY→FIX）已经是"即调即用"的工作流模板——直接注册为 MCP prompts：

- `plan_game_feature`（GDD → manage_task_plan 任务图）
- `debug_runtime_error`（拿到报错 → 定位 → 修复 → 复验）
- `review_scene`（场景结构审计）
- `run_test_suite`（发现 + 运行 + 结构化结果）
- `visual_playtest`（运行 → 截图 → 基线对比 → 判定）
- `onboard_new_project`（新项目接入引导）
- `fix_compile_errors`（编译错误反馈 → 修复循环）

零常驻 token（prompts 只在调用时展开），直接兑现 capabilities.prompts 承诺。

### 3.3 写后自校验（防假成功）

对齐 Coding-Solo #55 的教训：每个写操作后做"操作后读回断言"并返回证据：
- `create_node` → 读回节点存在性 + 类型；
- `modify_script` → 重新解析编译；
- `update_node_property` → 读回属性值。

### 3.4 视觉 playtest 一键编排

把 screenshot + play_and_verify + assert_visual_baseline + 差异热力图编排为高内聚流程（对齐 Unity/UE 同行的 Visual Review Loop 与 Coding-Solo #88）。

## 4. 工具面与 schema 优化

### 4.1 Schema 严格化 + 客户端兼容矩阵

第一手确认：221 工具 schema 中 `default` 关键字出现 **250+ 次**（`minimum`/`pattern` 等亦有）。Coding-Solo #55 实证 Copilot 会因不支持的关键字直接弃用工具。

方案：
1. 新增 GUT 回归：遍历全部工具 schema，断言只含 MCP JSON Schema 允许的关键字（或显式维护"允许关键字"白名单）；
2. 建立客户端兼容矩阵（Claude Desktop / Claude Code / Cursor / Cline / Copilot / Codex）并写进 README 徽章；
3. 描述重写模板："何时用 / 何时别用 / 前置条件 / 示例 / 返回体积预估"（回应 Coding-Solo #103 与 Anthropic 工具写作规范）。

### 4.2 核心工具再收敛 + 目录语义化（对齐官方渐进发现三层模式）

- 默认 tools/list 目标 ≤ 20（当前 28 core + 4 meta）；
- **补齐三层发现**：`list_tool_catalog`（已有，名称+一行描述）→ `search_tools`（新增，关键词匹配+分组过滤）→ `get_tool_details`（新增，单工具完整 schema）→ `enable_tools`（已有）+ list_changed；
- `tools/list` **确定性排序**（利于 prompt cache）；描述按"何时用/何时别用/前置条件/示例/返回体积"模板重写（回应 #103、#128 与 Anthropic 工具写作规范）；
- 命名审计按 **SEP-986**（ASCII 字母数字 `_-.`、1-128 字符、动词开头、分组前缀一致、名字里不放参数）；inputSchema 避免 oneOf/anyOf，能用 enum 用 enum，`additionalProperties: false`；
- 错误统一 `isError:true` + "当前值/期望值/修复建议"（SEP-1303：业务/校验错误不走 JSON-RPC error，请求畸形才用）；工具执行前 fail-fast 参数校验。

## 5. 引擎能力扩展（Godot 侧 — 已整合 godot-docs 研究报告）

> 完整差距表见 `docs/research/godot-engine-mcp-capability-gap-report.md`（Top 20 工具建议 + 引用 URL）。

### 5.1 四大核心发现

1. **3D 制作闭环缺失**：无 GI 烘焙（LightmapGI/VoxelGI）、NavMesh 烘焙、物理体/关节/射线查询、GridMap/MultiMesh 工具；
2. **撤销/回滚不成体系**：内部已用 EditorUndoRedoManager 6 处，但无 undo/redo/get_undo_history 工具、属性微调不合并（无 MERGE_ENDS）、脚本/资源文件直写绕过撤销栈、version_changed 信号未通知 AI；
3. **长任务异步化只有点状实现**：run_project_test/generate_3d_asset 已有 pending→poll，但无统一 async_job（start/poll/cancel/progress）；
4. **官方语言服务未利用**：--lsp-port/GDScriptLanguageProtocol/--dap-port/--gdscript-docs/--check-only 全部未用，脚本验证停留在文本级。

### 5.2 Top 20 新增工具建议（按价值排序）

| # | 工具 | 说明 | 注意 |
| --- | --- | --- | --- |
| 1 | `bake_lightmap` / `bake_voxel_gi` | GI 烘焙，异步+进度+截图门禁 | ⚠️ 4.7 master 文档 LightmapGI.bake() 疑似移除，实施前按版本实测 |
| 2 | `bake_navigation_mesh` | NavigationRegion3D + NavigationServer3D 异步烘焙 | 防 cell_size 过小冻结 |
| 3 | `undo` / `redo` / `get_undo_history` | 显式撤销 + 历史查询（✅ 已实现，editor_tools Editor-Advanced） | 属性编辑用 MERGE_ENDS 合并（后续优化） |
| 4 | `async_job` | start/poll/cancel/progress 统一异步框架（✅ 已实现 utils/async_job_manager，长工具接入） | WorkerThreadPool.add_group_task + 信号 |
| 5 | `memory_snapshot_diff` | ObjectDB 两时刻快照对比，泄漏检测 | 4.6 新增 |
| 6 | `resource_preview` | EditorResourcePreview 异步缩略图 / make_mesh_previews | |
| 7 | `editor_navigate` | edit_node/edit_script(line,col)/inspect_object/切换主屏 | |
| 8 | `set_import_options` | 按文件/批量设置导入选项 + reimport_files | 4.5 批量导入 |
| 9 | `author_animation_tree` | 状态机/混合空间/转换编辑 | 4.7 用 add_node 而非 set_start_node |
| 10 | `physics_query` | ray/shape/point 空间查询 | PhysicsDirectSpaceState3D |
| 11 | `setup_physics_body` | 碰撞形状生成（4.6 mesh→shape）、layer/mask、关节 | |
| 12 | `control_runtime` | pause/quit、time_scale/max_fps/physics_ticks | |
| 13 | `record_movie` | --write-movie --fixed-fps 确定性录制 + 抽帧 | 强化视觉回归 |
| 14 | `get_script_diagnostics` | LSP 结构化诊断替代文本 grep | GDScriptLanguageProtocol |
| 15 | `retarget_animation` | BoneMap 自动映射 + RetargetModifier3D | |
| 16 | `create_import_plugin` | EditorImportPlugin/EditorScenePostImportPlugin 骨架+注册 | |
| 17 | `edit_gridmap` | 单元格批量 + make_baked_meshes + MeshLibrary | |
| 18 | `edit_multimesh` | 实例变换/颜色/自定义数据 | |
| 19 | `register_performance_monitor` | 自定义指标接入预算门禁 | Performance.add_custom_monitor |
| 20 | `multiplayer_harness` | ENet 会话 + rpc + 同步断言 | |

### 5.3 引擎侧约束（4.7 注意事项）

- 耗时操作（烘焙/导出/重导入/录制）必须在统一 async_job 中运行 + MCP progress 通知上报（当前串行队列会冻结编辑器）；
- 优先使用 EditorInterface/编辑器单例 API，避免依赖 UI 节点名（i18n 教训 #32）；
- LightmapGI 烘焙前预检 GI_MODE_STATIC + 合法 UV2 + Forward+/Mobile 渲染器限制；
- 错误反馈增强：`assert_script_compiles`（Script.reload 结构化错误）、`assert_scene_loads`（gi_mode/UV2/navmesh 预检）、`get_script_diagnostics`；"编辑→reload_open_scripts→断言"编排为 edit_and_verify；
- manage_task_plan 可新增 script_compiles / scene_loads gate 类型。

## 6. 安全加固（含审计确认的严重问题）

### 6.1 严重（必须立即修）

| # | 问题 | 证据 | 修复 |
| --- | --- | --- | --- |
| S1 | **默认无认证 + 监听 0.0.0.0 = 局域网无口令 RCE** | `auth_enabled` 默认 false；`mcp_http_server.gd` L107 `_tcp_server.listen(_port)` 绑所有网卡；`_allow_remote` 是死配置（从不被读取） | listen 默认绑定 127.0.0.1；`allow_remote=true` 才绑 0.0.0.0；默认开启认证并自动生成 token |
| S2 | **认证运行时开关失效（静默绕过）** | `McpAuthManager` 只在 `_enter_tree` 创建；面板运行中开启认证不生效 | auth manager 创建/重建移入 `start()` 流程；加端到端 401 集成测试 |
| S3 | **CORS `*` 硬编码** | `_send_http_response`/`_send_http_error` 等直接写 `Access-Control-Allow-Origin: *`，`_cors_origin` 未用 | CORS 白名单默认空，仅显式配置的 origin 放行 |
| S4 | **默认启用的 core 工具含 RCE 面** | `execute_script`（绑定 OS/ClassDB/ResourceSaver 单例）与 `execute_editor_script`（完整 GDScript 编译执行）是默认启用；`script_sandbox.gd` 自述"防误操作护栏非对抗性沙箱"，`Engine.get_singleton("OS").execute()`/call() 分发可稳定绕过 | 降级为默认禁用（supplementary）；沙箱升级为白名单式；调用审计日志 |
| S5 | **smoke_test_export 任意程序+参数** | editor_tools L1140 可指定任意可执行文件 | 限制为导出产物路径 + 预设白名单参数 |
| S6 | **generate_asset/generate_3d_asset：环境变量外泄 + SSRF** | `api_key_env` 可读任意环境变量回传；endpoint 可指向内网 | endpoint/api_key_env 白名单（默认仅内置预设）；非阻塞轮询 |
| S7 | **token 明文存 user://mcp_settings.cfg** | 配置文件无加密 | 至少文件权限收紧 + 文档警告；后续考虑 OS keychain |

### 6.2 中/低

1. **路径校验规范化**：`is_path_safe` 黑名单（`..`/`~`/`$`/`|`/`;`/`` ` ``/`&&`/`||`）→ `ProjectSettings.globalize_path()` + 规范化前缀检查（防 URL 编码/Unicode 绕过）；删除与 PathValidator 的重复实现；
2. **速率限制按来源 IP 分桶**（当前 `_check_rate_limit("default")` 全客户端共享一个桶，单客户端可饿死其他客户端）；
3. **OAuth 2.1 authorization**（2025-11-25 规范，远程场景）；
4. cloudflared 隧道暴露公网时强制要求认证（目前可无认证暴露）。

## 7. 架构与工程质量

1. **巨型文件拆分**：project_tools_native.gd（364.5KB/9.1k 行/60+ 工具）按域拆为 4~6 个文件（assets/tileset/localization/task-plan/project-config），debug_tools_native.gd（187.7KB/4.4k 行）同理——保持注册模式不变，纯机械拆分；
2. **单一数据表驱动注册**：工具名/分类/分组/schema 一处定义，分类器与 docs 表格自动生成（当前在 register_tool 调用、分类器、docs、翻译 JSON、测试计数 5 处重复，漂移风险高）；
3. **死代码清理**：`_handle_tool_call` 的 `status = OK` 恒真分支、core 的 `_thread`/`_mutex`（未用）、stdio 响应队列（从未使用）、`MCPResourceManager` 双注册表、`is_path_safe`（从未被调用）、path_validator 实例 API；
4. **协议面测试补齐**：ping、completion、logging、progress、cancelled、分页、batch(-32600)、通知无响应、速率限制跳过通知；
5. **版本号单一来源**：serverInfo.version / HTTP GET / / plugin.cfg 三处统一；
6. **HTTP 服务器健壮性**：连接上限、每连接独立超时、避免单慢连接阻塞全局与每轮 `_connections.duplicate()`；
7. **测试基建**：提交 `.gutconfig.json`（当前缺失）、明确 GUT 依赖获取方式（`addons/gut/` 未随仓库提供 → 全新检出无法跑测试）；补齐高危工具（认证 401、stdio 运行中 stop、execute_script 沙箱拦截）集成测试；**10 个 core 工具零单测引用**（get_node_properties/list_nodes/get_scene_tree/create_scene/get_current_scene/get_current_script/get_editor_logs/get_project_info/get_project_settings/list_project_resources，其中 4 个连集成测试都没有）；97 个工具无行为测试；速率限制拒绝逻辑、JSON-RPC 错误码映射、socket 级 wire 测试（CORS/畸形请求/401）补齐；
8. **工具验证日志**：脱敏 + 按大小轮转（当前全文件重写、含完整参数）。

## 8. 分发与生态

1. **Godot Asset Library 上架**（回应 #27；Coding-Solo 已上架条目 asset/5305）；
2. **一键安装/配置**：`mcp_setup` 脚本 + 各客户端配置生成（Unity MCP 的 "Configure All Detected Clients" 模式）+ macOS 支持（#56）；
3. **Agent Skills 技能包**：`skills/` 目录提供 SKILL.md（godot-playtest / godot-debug-loop / godot-scene-building / godot-asset-pipeline），跨 Claude Code/Cursor/Copilot 可移植（回应 #67）；
4. **工具目录站**：docs/tools/* 渲染为可搜索目录（schema 示例 + token 估算 + 客户端配置）；
5. **文档漂移修复**：plugin.cfg `[mcp]` 死配置（auto_start=true/log_level=3 与代码默认 false/2 矛盾）删除或生效；architecture.md "一文件一分类"补充 execute_script 在 debug 文件的事实；configuration.md 补齐 9 个真实设置键；版本号三处统一（P8）。

---

## 8.5 可选能力取舍（基于 2026-07-28 规范修订）

> ⚠️ 重要修订：SEP-2577 已正式弃用 **Sampling / Roots / Logging**（通知）。新实现不应再依赖这三者——此前"实现 roots"的建议作废。

| 能力 | 建议 | 理由 |
| --- | --- | --- |
| `sampling`（服务端请求客户端调 LLM） | **不实现** | 已弃用（SEP-2577）；编辑器服务器无此需求；安全面 |
| `roots`（客户端告知项目根） | **不实现** | 已弃用（SEP-2577）；官方建议改工具参数/资源 URI 表达项目边界 |
| `logging`（notifications/message） | **不实现** | 已弃用（SEP-2577）；stdio 场景走 stderr 即可 |
| `elicitation`（服务端反问客户端问题） | **暂缓，检测客户端能力后渐进** | Active 但 Claude Desktop 支持弱（issue #41110）；可先做"客户端能力检测 + dry_run/confirm 回退" |
| `completion` | **实现（P1）** | 对 prompts 参数做补全（task 标题、路径、预设名），成本低 |
| `Tasks` 扩展（`io.modelcontextprotocol/tasks`） | **渐进实现（P1-P2）** | 分钟级长任务（generate_3d_asset/play_and_verify/smoke_test_export）轮询/取消/崩溃恢复，与 §5 的 async_job 框架合流 |
| **stateless 对齐** | **设计上对齐（P2）** | 2026-07-28 draft 去 session/握手；当前全局工具状态设计已接近 stateless，勿引入 session 依赖 |

## 9. 分阶段执行建议

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| Phase 0（1-2 天） | **P0 ttlMs/cacheScope/resultType**（Claude Code 已强制）、P1 ping、P7 版本统一、P8 stdio 死锁、死代码清理、editor_log 版本硬编码修复 | GUT 全绿 + curl 冒烟 + Claude Code 实测加载 |
| Phase 1（1 周） | **安全 S1-S7**（127.0.0.1 绑定/默认认证/CORS/execute_* 降级/环境变量白名单）、编译错误反馈（verify_scripts + 日志源修复 + i18n）、schema lint 测试、核心收敛 | GUT 全绿 + 401 端到端测试 + 客户端冒烟 |
| Phase 2（1-2 周） | 真实 prompts、search_tools/get_tool_details、completion、progress/cancelled、分页、资源模板、P1b/P1c/P1d 协议合规 | 协议面测试 + 真实客户端验证 |
| Phase 3（2-4 周） | Streamable HTTP（stateless 风格）+ server/discover 双兼容、错误模型统一（isError+可行动文本）、async_job 统一框架、undo/redo 工具 | Codex/Claude Desktop/Cursor 实测矩阵 |
| Phase 4（1-2 月） | 引擎能力扩展（3D 烘焙/导航/物理/动画树/LSP 诊断，Top 20 清单）、巨型文件拆分 + 单一数据表、Agent Skills、AssetLib 上架、工具目录站、Tasks 扩展 | 完整闭环 demo（GDD→可玩切片→视觉基线） |

---

*研究依据文件：`docs/competitive-analysis.md`、`docs/research/mcp-spec-research-2025-2026.md`、`docs/research/godot-engine-mcp-capability-gap-report.md`。*
