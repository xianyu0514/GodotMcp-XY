# Godot MCP Native 系统架构与设计文档

> 适用版本：`1.0.7-pre1`（`addons/godot_mcp/plugin.cfg`）
> 协议版本：`2025-11-25`（向下协商至 `2025-06-18`、`2025-03-26`、`2024-11-05`）
> 配套图：`docs/architecture-diagrams.html`（可打印的完整架构图集）

本文档回答三个问题：**系统由哪些模块构成**、**数据如何在模块间流动**、**为什么这样设计**。
偏"怎么用"的内容见 `docs/getting-started.md`，偏"怎么加工具"的内容见 `docs/contributing.md`，
本文专注架构决策与权衡。

---

## 1. 系统定位

Godot MCP Native 是一个 **Godot 4.7 EditorPlugin**，在编辑器进程内原生实现 MCP（Model Context Protocol）服务器。
它不启动 Node.js 之类的中间层，也不通过外部进程代理编辑器，而是直接把 MCP 协议栈嵌进编辑器，
用 Godot API 作为执行边界，对外暴露 **231 个工具**。

这一定位带来三个硬约束，后续所有设计决策几乎都是它们的推论：

| 约束 | 推论 |
| --- | --- |
| **运行在编辑器主线程** | 不能并发执行工具；必须有串行队列与背压；长任务必须让帧 |
| **与编辑器共享生命周期** | 编辑器卡死 = 服务不可用；任何 O(n) 全量扫描都要被缓存约束 |
| **编辑器的文件可能被外部修改** | 缓存不能只靠"我自己改了才失效"，必须监听编辑器信号 |

### 1.1 三层能力模型

工具被划分为三个层级，这是整个系统的"成本控制"主线：

| 层级 | 数量 | 是否默认暴露 | 用途 |
| --- | --- | --- | --- |
| `core` | 28 | 是 | 覆盖建模主路径：建场景、建节点、读写脚本、跑项目 |
| `supplementary` | 197 | 否 | 深度能力：调试器、资源审计、导出、本地化、瓦片、动画等 |
| `meta` | 6 | 是（始终在线） | 工具发现与工作流编排：`list_tool_catalog` / `search_tools` / `get_tool_details` / `enable_tools` / `plan_game_workflow` / `run_game_workflow` |

**为什么这样分层**：MCP 客户端会把 `tools/list` 的全部 schema 注入模型上下文。231 个工具的完整 schema
会吃掉大量上下文预算，且绝大多数请求用不到。`core + meta` 的 34 个工具足以启动，`enable_tools`
按需补齐缺失能力——这是一个**发现预算**，而不是能力上限。

---

## 2. 整体分层架构

```
┌─ 客户端层 ─────────────────────────────────────────────────┐
│  Claude Desktop / Cursor / Cline / 自定义 MCP 客户端        │
└────────────────────────────────────────────────────────────┘
                          ↓ JSON-RPC 2.0
┌─ 传输与接入层 ─────────────────────────────────────────────┐
│  McpHttpServer (HTTP + SSE)  ·  McpStdioServer (stdio)     │
│  McpAuthManager (Bearer)     ·  McpTunnelManager (隧道)    │
└────────────────────────────────────────────────────────────┘
                          ↓ message_received
┌─ 协议与编排内核 ───────────────────────────────────────────┐
│  MCPServerCore：JSON-RPC 分发 · 串行队列 · 工具注册表        │
│                 结果缓存 · 溢出落盘 · 进度与取消             │
└────────────────────────────────────────────────────────────┘
                          ↓ await tool.callable(args)
┌─ 能力层 · 231 工具 + 7 资源 + 7 prompts ───────────────────┐
│  场景与节点 38 · 脚本 18 · 编辑器控制 27                    │
│  运行与调试 73 · 项目与资源 69 · 元工具 6                   │
└────────────────────────────────────────────────────────────┘
                          ↓
┌─ 执行边界 ─────────────────────────────────────────────────┐
│  EditorInterface 通道   ·   MCPDebuggerBridge（调试器协议）  │
│  ProjectSettings        ·   MCPRuntimeProbe（Autoload）     │
└────────────────────────────────────────────────────────────┘
                          ↓
┌─ 宿主环境 ─────────────────────────────────────────────────┐
│  Godot 编辑器进程        ·      运行中的游戏进程              │
└────────────────────────────────────────────────────────────┘
```

领域分布按 `tools_manifest.gd` 的 group 归并（合计 231）：

| 领域 | 分组 | 工具数 |
| --- | --- | --- |
| 场景与节点 | Node-Read / Node-Write / Node-Advanced / Node-Write-Advanced / Scene / Scene-Advanced | 38 |
| 脚本 | Script / Script-Advanced | 18 |
| 编辑器控制 | Editor / Editor-Advanced | 27 |
| 运行与调试 | Debug / Debug-Advanced | 73 |
| 项目与资源 | Project / Project-Advanced | 69 |
| 元工具 | Meta | 6 |

---

## 3. 核心模块职责

### 3.1 插件入口 `mcp_server_native.gd`

继承 `EditorPlugin`，负责装配与生命周期。关键顺序（顺序本身就是设计）：

```
_enter_tree()
  ├─ _apply_persisted_settings()   读 user://mcp_settings.cfg 覆盖 @export 默认值
  ├─ 创建 MCPServerCore
  ├─ 创建并注册 MCPDebuggerBridge（add_debugger_plugin）
  ├─ 应用传输/端口/日志/安全/限流配置
  ├─ _connect_cache_change_signals()   订阅 9 个编辑器变更信号
  ├─ _register_all_tools()         按 TOOL_SCRIPT_PATHS 顺序实例化 15 个工具模块
  ├─ _ensure_runtime_probe_autoload()
  ├─ _register_all_resources()     7 个 godot:// 资源
  ├─ _register_all_prompts()       7 个可执行工作流 prompt
  ├─ load_tool_states()            必须在建 UI 前恢复启用状态
  └─ _create_main_screen_panel()
```

**配置优先级**：`@export` 默认值 < `mcp_settings.cfg` 持久化值 < 命令行覆盖。
命令行覆盖（`--mcp-port=N` / `--mcp-transport=stdio`）刻意放在**最后**、在 `start()` 绑定端口前才应用，
因为面板的 `_load_settings()` 会在 `_enter_tree` 期间把持久化端口重新推给服务器，提前应用会被覆盖。
这套优先级让多个无头实例能用不同端口并存。

**启动触发**：`--mcp-server` 命令行参数 > `auto_start` 配置 > 面板手动 Start。

一个容易踩的细节：`MCPRuntimeProbe` 若由 `project.godot` 静态声明（当前仓库正是如此），
`_exit_tree()` **不会**删除它；只有本次会话动态新增的 autoload 才会清理。

### 3.2 传输层

`McpTransportBase` 定义契约（4 个信号 + `start/stop/is_running/send_response/send_raw_message`），
两个实现共享同一套上层逻辑，核心只依赖基类。

| 实现 | 场景 | 关键参数 |
| --- | --- | --- |
| `McpHttpServer` | 编辑器内常驻、远程访问、集成测试 | 默认端口 9080；单请求上限 1MB；超时 30s；最大并发连接 64；SSE 心跳 30s；`Mcp-Session-Id` 会话头 |
| `McpStdioServer` | Claude Desktop 等派生进程的客户端 | 独立线程监听 stdin，解析后经 `call_deferred` 编组回主线程 |

两个设计要点：

1. **编组到主线程**。传输层在工作线程收到报文后不直接处理，而是 `call_deferred` 交给主线程。
   所有请求状态因此天然单线程，`_drain_request_queue()` 不需要任何锁。
2. **HTTP 批量请求被显式拒绝**。`is_batch_payload()` 检测到数组载荷时返回固定错误而不是逐个执行——
   批量会让串行队列的背压语义失效，也会让单个超大请求绕过大小限制。

认证只在 HTTP 模式生效（`should_enable_auth()` 是纯函数，便于单测）：Bearer Token，长度低于 16 字符时告警。
远程访问另有 `allow_remote` + `cors_origin` 显式来源控制，配合 `McpTunnelManager` 的 Cloudflare Quick Tunnel
（含独立 `McpTunnelSupervisor` 守护进程，跨编辑器重启存活）。

### 3.3 协议内核 `MCPServerCore`

系统的中枢。支持的 JSON-RPC 方法：`initialize` / `ping` / `tools/list` / `tools/call` /
`resources/list` / `resources/read` / `resources/subscribe` / `resources/unsubscribe` /
`prompts/list` / `prompts/get`，以及通知 `notifications/initialized` / `notifications/cancelled`。

**串行队列 + 背压**（这是"主线程"约束的直接产物）：

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `MAX_REQUEST_QUEUE_SIZE` | 256 | 队列容量，超出则进入准入等待 |
| `MAX_WAITING_REQUESTS` | 256 | 同时等待的协程上限，超出立即拒绝 |
| `MAX_QUEUE_WAIT_SECONDS` | 30 | 等待槽位的超时，超时返回 "server busy" |

等待者通过 `_admission_waiters` 的**单调票号**按 FIFO 放行，避免协程恢复顺序不确定导致的饥饿。
队列逐条执行，`_drain_request_queue()` 在两条请求之间 `await process_frame` 让出帧，
保证持续负载下编辑器仍能渲染和响应输入。

`notifications/cancelled` **绕过队列**直接标记 `_cancelled_requests`——它要取消的正是正在排队的那个请求，
排队就永远轮不到它。

**列表缓存**：`tools/list` 结果按工具名排序后缓存（`_tool_list_cache`），只在注册/注销/启用状态变化时重建。
排序保证确定性输出，有利于客户端的 prompt cache。响应带 `_meta.ttlMs`（30s）与 `cacheScope`，
这是 2026-07-28 MCP 规范的要求，Claude Code 会校验。

**进度与取消**：`_execution_context` 记录当前请求的 `{tool_name, request_id, progress_token}`，
工具可通过 `is_current_tool_cancelled()` 与 `send_progress_notification()` 感知取消并上报进度，
无需把 request id 塞进工具签名。

### 3.4 工具注册表与分类体系

`tools_manifest.gd` 是**唯一真相**（single source of truth）：一张 `工具名 → {category, group}` 的表。
`mcp_tool_classifier.gd` 从它生成查询 API，`test_mcp_tool_classifier.gd` 强制
manifest / classifier / `register_tool` 调用三方一致。

> 这是从"5 处重复维护工具清单"重构而来的。此前工具名与分类散落在各 `tools/*.gd` 的注册调用、
> 分类器手写列表、文档表格、翻译 JSON、测试断言里，漂移风险极高。

工具注册走 8 参数 `register_tool(name, desc, input_schema, Callable, output_schema, annotations, category, group)`。
15 个工具模块按域拆分（`debug_tools_native.gd` 拆出 bridge/runtime/verify 三个子模块，
`project_tools_native.gd` 拆出 resources/assets/tileset/verification/workflow 五个子模块），
避免单文件上万行。

另有 `mcp_tool_preset_manager.gd` 提供 12 个预设（`minimal_core` / `game_2d` / `game_3d` /
`ui_localization` / `gameplay_scripting` / `animation_audio` / `release_export` / `level_design` /
`debugging` / `automation_qa` / `art_resources` / `all`），支持分组一键启用。

### 3.5 结果缓存与依赖 revision ⭐

这是本项目最有价值的设计。朴素做法是"变更就清缓存"，代价是每次写入后所有昂贵扫描（场景结构、
项目资源清单、脚本依赖）全部失效重算。这里改为**依赖标签 + 单调版本号 + 惰性失效**：

```
读取：snapshot(依赖标签) → 执行 → 存 {value, formatted, snapshot, size}
校验：is_current(snapshot) —— 逐个标签比对当前 revision，O(标签数)
失效：advance(受影响标签)  —— 每个标签 +1，O(受影响标签数)，绝不扫描缓存
```

`cache_revision_index.gd` 定义 14 个静态标签，外加动态路径标签：

| 类别 | 标签 |
| --- | --- |
| 全局 | `global`（保守兜底）、`tool_catalog` |
| 场景 | `scene_content`、`scene_catalog`、`scene_tabs` |
| 脚本 | `script_all`、`script_aggregate`、`script_catalog`、`script:<路径>` |
| 资源 | `resource_all`、`resource_aggregate`、`resource_catalog`、`resource:<路径>` |
| 项目 | `project_settings`、`project_tree`、`import_state` |

**只有 27 个确定性只读工具**进入缓存（`CACHEABLE_READ_TOOLS`），每个都必须在 `read_tags()` 中有覆盖，
由单测强制。写入侧由 `mutation_tags(tool_name, group, arguments)` 映射到最小标签集：

- `create_script` → `script_catalog` + `script_aggregate` + `resource_catalog` + `project_tree` + `script:<路径>`；
  若 `attach_to_node` 非空，追加 `scene_content`
- `Node-*` / `Scene*` 分组 → 只推进 `scene_content`
- `EDITOR_ONLY_MUTATIONS`（`clear_output`、`select_node`、`run_project` …）→ 空集，完全不失效
- `Runtime-*`（`Debug` / `Debug-Advanced`）→ 空集，运行时探针不改编辑器状态
- 未知工具 → 保守退化为 `global`

**两条失效来源**：

1. **MCP 自身写入**：`_handle_tool_call` 成功后调用 `mutation_tags()` → `advance()`
2. **编辑器/外部变更**：插件订阅 9 个信号（`filesystem_changed`、`resources_reload`、
   `resources_reimporting/imported`、`script_classes_updated`、`sources_changed`、
   `resource_saved`、`scene_saved`、`ProjectSettings.settings_changed`），
   由 `cache_change_tracker.gd` **每帧合并为一个确定性批次**，递归路径快照做增删差分，
   再通过 `external_change_tags()` 映射为标签

第 2 条是关键：`filesystem_changed` 不带路径，因此 tracker 会对比前后快照得出增删集合；
确认无路径的事件则安全退化为所有文件相关域，但**刻意保留** `tool_catalog`（工具发现结果是不可变的）。

容量与兜底：

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `RESULT_CACHE_MAX` | 64 条 | LRU 上限 |
| `RESULT_CACHE_MAX_BYTES` | 32 MB | 字节上限（条目数不足以约束大扫描） |
| `RESULT_CACHE_TTL_MS` | 60 s | 兜底陈旧上限，防止 MCP 之外的编辑造成无限陈旧 |
| `READ_SNAPSHOT_CACHE_MAX` | 8 条 / 4 MB | 分页扫描快照，各 limit/offset 视图共享一次全量扫描 |
| `RESULT_CACHE_SINGLE_FLIGHT_WAIT_MS` | 30 s | 同 key 并发合并，等待"孪生"请求的结果 |

> 为什么 TTL 只有 60 秒：revision 机制在 MCP 已知路径内是精确的，但用户在编辑器外改文件
> （如 git checkout、外部编辑器保存）只能靠信号差分覆盖。TTL 是这条链路的兜底，
> 因此刻意比早期版本的 5 分钟场景结构 TTL 短得多。

### 3.6 大结果溢出（spill, don't fail）

工具结果 JSON 超过 **50 KB** 时，不再内联进响应，而是写入 `res://.mcp/out/`，
返回首尾预览（head 4096 字符 + tail 1024 字符）+ 一个 `godot-mcp://result/<sha256>` 资源链接。
客户端用标准的 `resources/read` 分页取回全部内容（每页 16 KB，按码点边界切分）。

几个关键细节：

- 句柄是**内容寻址**的 SHA-256（64 位 hex），路径不可穿越，且相同内容复用同一文件
- `read_script` / `batch_read_scripts` / `get_editor_logs` 豁免——spill 只会重复同样的文本
- 溢出时省略 `structuredContent`，否则等于绕过了大小限制
- 这是"溢出而非失败"原则：结果大是常态（场景结构、依赖扫描），不该变成错误

### 3.7 工作流路由与游戏工作流引擎

两个互补的编排层，解决"模型不知道该用哪些工具"的问题。

**`workflow_router.gd`（短任务 / 能力发现）**
纯函数式路由，不复制 schema、不调模型、不联网。扫描已注册目录，预计算紧凑的名称签名，
把选中工具分组成 inspect / execute / verify 三段。

- 预算：默认 8 个工具，硬上限 10
- 双语意图别名表（`INTENT_ALIASES` 覆盖"场景/节点/瓦片/着色器…"，`TOKEN_ALIASES` 覆盖 `add→create,set` 等）
- 高置信度的"动作 + 对象"签名优先，回退到按语义证据 + 覆盖率 + schema token 成本排序
- 64 条路线 LRU 缓存，按 `_tool_registry_revision` 失效

**`game_workflow_engine.gd`（完整目标 / 持久 DAG）**
面向"给我做一个能跑的 2D 平台跳跃"这类多阶段目标。

- 12 个生产 profile：`gameplay_feature` / `ui_screen` / `script_repair` / `asset_pipeline` /
  `animation_audio` / `level_design` / `runtime_debug` / `localization` / `performance` /
  `quality_assurance` / `project_health` / `release_export`
- 按中英文关键词分类 profile，按 `PROFILE_COMPOSITION_ORDER` 合成步骤，按 `STAGE_RANK` 排序
  （`offline_inspect` 10 → `build_*` 20 → `static_verify` 30 → `runtime_*` 40~70 → `release_*` 80~100）
- 状态机持久化在 `task_plan_store.gd`，`run_game_workflow` 每次推进默认 4 步（自适应切片）
- **证据门禁**：`needs_input` / `waiting` / `retry_required` / `blocked` / `replan_required` /
  `recovery_required` 一律不算完成。目标门禁步骤必须由 `GATE_EVIDENCE_KEYS` 的证据判定通过
- 有界修复：`DEFAULT_REPAIR_ATTEMPTS` 默认 0；同一失败 3 次（`SAME_FAILURE_REPLAN_THRESHOLD`）触发 replan
- 路径护栏：`res://addons/godot_mcp` 与 `res://.mcp` 默认受保护，工作流不能改插件自身

### 3.8 调试器桥接与运行时探针 ⭐

这套机制让 AI 能**在游戏运行时**读写场景树、模拟输入、采样性能——"自己试玩并验证"的基础。

```
编辑器进程                          游戏进程
MCPServerCore                    MCPRuntimeProbe (Autoload)
     │                                  │
     ▼                                  ▼
MCPDebuggerBridge  ── Godot 调试器协议 ──  _capture("mcp", ...)
(EditorDebuggerPlugin)
```

- **请求方向**：工具 → `send_debugger_message("mcp:xxx", data)` → 探针 `_capture_mcp_message()` 处理并回传
- **响应方向**：探针在 `_ready()` 注册 `mcp` 捕获前缀 → 桥接记录消息与自增 sequence →
  工具用 `get_captured_message_after_sequence()` 轮询取回
- 桥接维护"变量引用表"（`get_scope_variables_reference` / `get_variables_by_reference`），
  让深层对象可以按引用惰性展开，而不是一次性序列化整棵树
- 会话管理：`_setup_session()` / `_for_each_session()` 支持多调试会话；`wait_for_probe_ready()` 等待探针就绪

注意 `mcp_runtime_probe.gd` 是 **Autoload 单例**，会进入导出的游戏包。生产构建前需要评估是否移除，
或者在导出时通过特性标记裁剪。

---

## 4. 数据流

### 4.1 单次 `tools/call` 生命周期

```
① 客户端 tools/call
        ↓
② 传输层解析与鉴权            HTTP+SSE 或 stdio；Bearer 校验；拒绝批量载荷
        ↓
③ 背压准入 + 串行队列          FIFO 票号放行，最多等 30s；每帧执行一条
        ↓
④ 缓存键与 revision 校验 ──命中──→ 跳过执行，直接返回缓存
        ↓ 未命中
⑤ 执行工具处理器              await tool.callable(args)；可感知取消与进度
        ↓
⑥ 格式化与溢出判定             >50KB → 落盘 res://.mcp/out，返回预览 + 资源链接
        ↓
⑦ 写回缓存或推进 revision      只读落缓存；变更只推进受影响的依赖标签
        ↓
   返回 JSON-RPC 响应
```

缓存键 = `工具名 + ":" + 规范化参数 JSON`（key 排序后序列化），
因此参数顺序不同也共享同一条目。

有一个微妙的正确性处理：若只读工具执行期间发生了相关变更，它捕获的 snapshot 已不再匹配当前 revision，
`_result_cache_put` 前的 `is_current()` 检查会**拒绝回填缓存**，避免用陈旧数据污染缓存。

### 4.2 缓存失效链路

```
来源 A：MCP 写入工具                来源 B：编辑器 / 文件系统
mutation_tags(工具, 分组, 参数)      cache_change_tracker 每帧合并
        ↓                                    ↓
        └──────────── CacheRevisionIndex ─────┘
                     依赖标签 → 单调 revision
                            ↓
                    结果缓存 LRU（64 条 / 32MB / TTL 60s）
                   snapshot 一致 → 命中   |   revision 失配 → 惰性逐出
```

两条来源的**退化策略不同**，这点很重要：MCP 侧未知工具退化为 `global`（最保守，
因为它确实动了我们不知道的东西）；外部侧无路径事件退化为所有文件域，但保留 `tool_catalog`
（文件系统变化不可能改变工具定义）。

### 4.3 跨进程运行时通道

```
工具 → send_message("mcp:*") → 探针执行 → 回传
探针注册 mcp 捕获前缀 → 桥接按 sequence 匹配 → 工具轮询取回
```

`request_runtime_message()` 是统一的请求-等待封装：给定期望的响应消息名与错误消息名，
在超时窗口内轮询捕获缓冲，命中即返回。

### 4.4 配置数据流

```
@export 默认值
  ↓ 覆盖
user://mcp_settings.cfg（MCPSettingsManager）
  ↓ 覆盖（最后、在 start() 绑定端口前）
--mcp-port=N / --mcp-transport=stdio
```

`user://` 会跟随 `--user-data-dir` 解析，因此每个并行实例读自己的配置。

---

## 5. 关键设计决策与权衡

| # | 决策 | 替代方案 | 为什么选它 |
| --- | --- | --- | --- |
| 1 | 标签化 revision 惰性失效 | 变更即清空缓存 | 写入路径 O(受影响标签) 而非 O(缓存)；昂贵扫描的命中率显著提升。代价是 `mutation_tags` 表需要人工维护，遗漏会导致陈旧读 |
| 2 | 串行请求队列 | 并发执行工具 | Godot 编辑器 API 非线程安全，主线程并发会直接崩编辑器。代价是吞吐，用"每帧让出 + 单飞合并"缓解 |
| 3 | 三层工具 + 按需发现 | 全量暴露 231 工具 | `tools/list` schema 直接占用模型上下文。代价是多一次 `enable_tools` 往返 |
| 4 | 溢出落盘而非截断 | 截断或报错 | 大结果是常态（依赖扫描、场景结构）。截断会静默丢数据，报错会让 AI 无从下手 |
| 5 | 60 秒 TTL 兜底 | 长 TTL 或纯 revision | 覆盖 MCP 之外的编辑路径；短 TTL 保证最坏情况下的陈旧有界 |
| 6 | manifest 单一真相 | 各处重复维护 | 消除 5 处清单漂移；一致性由单测强制 |
| 7 | 拒绝 HTTP 批量请求 | 逐个处理 | 批量会绕过背压与大小限制，破坏串行语义 |
| 8 | 证据门禁判定完成 | 步骤跑完即完成 | 防止"声称完成但实际没跑通"；`waiting`/`blocked` 等状态不被误判为成功 |
| 9 | 路由不依赖模型或嵌入 | 语义检索 / 向量库 | 零外部依赖、零延迟、可确定性单测。代价是长尾 query 的召回率 |
| 10 | 双通道（编辑器 + 运行时） | 仅编辑器 API | 运行时通道让"改完自己试玩验证"闭环成为可能，这是纯编辑器方案做不到的 |

---

## 6. 并发、性能与安全

### 6.1 性能护栏

| 护栏 | 位置 | 参数 |
| --- | --- | --- |
| 请求队列 | `MCPServerCore` | 256 条 / 等待 30s / 等待者 256 |
| 速率限制 | `_check_rate_limit` | 1000 次 / 60s 窗口（按 client_id） |
| 结果缓存 | LRU | 64 条 / 32MB / TTL 60s |
| 扫描快照缓存 | 分页共享 | 8 条 / 4MB |
| 结果溢出 | `_maybe_spill_result` | 50KB 内联上限 |
| HTTP | `McpHttpServer` | 1MB 请求体 / 30s 超时 / 64 连接 |
| 外部生成预算 | `generation_budget.gd` | 滑动窗口限流 |
| 异步任务 | `async_job_manager.gd` | start / poll / cancel / progress |

诊断口径统一收敛在 `get_cache_diagnostics()` / `reset_cache_diagnostics()`，
覆盖命中、未命中、逐出、惰性失效、单飞、超限拒绝、spill 写入与复用、外部变更批次等指标，
无需为了可观测性膨胀工具 schema。

### 6.2 安全边界

| 层 | 机制 |
| --- | --- |
| 传输 | Bearer Token（仅 HTTP，长度 < 16 告警）；`allow_remote` 默认关；CORS 显式来源 |
| 溢出文件 | 内容寻址 SHA-256 句柄，不可路径穿越；固定落在 `res://.mcp/out` |
| 脚本执行 | `script_sandbox.gd` 能力黑名单（防误操作，非对抗性沙箱） |
| 远程资产生成 | `asset_provider_presets.gd` 的 endpoint / 密钥白名单 + SSRF 护栏 |
| 路径校验 | `path_validator.gd` / `path_normalizer.gd` 统一归一化 |
| 工作流 | 受保护路径默认禁止（`res://addons/godot_mcp`、`res://.mcp`） |
| Vibe Coding | `vibe_coding_policy.gd` 守卫 `allow_ui_focus` / `allow_window` |

需要明确的边界：`script_sandbox.gd` 是**护栏而非安全沙箱**——它阻止误操作，不防御恶意输入。
`execute_script` 具备 Godot 进程的完整权限。

---

## 7. 可观测性

- **信号**：`server_started` / `server_stopped` / `message_received` / `response_sent` /
  `tool_execution_started` / `tool_execution_completed` / `tool_execution_failed` / `log_message`
  全部由插件入口转发到 UI 面板
- **日志分级**：`ERROR(0) / WARN(1) / INFO(2) / DEBUG(3)`，默认 INFO
- **工具日志**：`_append_tool_log()` 记录每次调用，`flush_tool_log()` 落盘
- **缓存指标**：`get_cache_diagnostics()` 返回 17 项计数器
- **路由指标**：`_route_computations` / `_route_cache_hits` / `_route_cache_misses`

---

## 8. 测试策略

| 层级 | 位置 | 工具 | 覆盖重点 |
| --- | --- | --- | --- |
| 单元 | `test/unit/`（98 个 .gd） | GUT | 纯逻辑：`cache_revision_index`、`workflow_router`、`game_workflow_engine`、`path_validator`、manifest/classifier/注册三方一致性 |
| 集成 | `test/integration/`（38 个 .py） | Python + HTTP MCP（9080） | 真实 Godot 进程上的端到端流程、运行时探针往返 |

项目规范要求**每次代码变更必须同步更新测试**，包括直接影响与关联影响（签名变更、导出变量、信号）。

---

## 9. 扩展指南

### 9.1 新增工具

1. 在对应 `tools/*_tools_native.gd` 实现 `_register_<name>()` 与 `_tool_<name>()`，
   用 8 参数调用 `server_core.register_tool(...)`
2. 在 `tools_manifest.gd` 的 `MCPToolsManifest.TOOLS` 添加条目（`{name: {category, group}}`）
3. 更新 `test_mcp_tool_classifier.gd` 的总数与 supplementary 计数（三方一致性由 manifest 测试强制）
4. 在 `test/unit/tools/` 补单测（缺失参数 / 无效参数 / 边界）
5. 更新翻译文件与 `docs/tools/*.md`

### 9.2 新增可缓存只读工具

在 `cache_revision_index.gd` 的 `CACHEABLE_READ_TOOLS` 登记，并在 `read_tags()` 中给出依赖标签。
**漏登记会导致陈旧读或缓存永不失效**，单测会拦截未覆盖的名称。

### 9.3 新增写入工具

在 `mutation_tags()` 中给出最小受影响标签集。判定顺序：
`GLOBAL_MUTATION_TOOLS` → `EDITOR_ONLY_MUTATIONS` → 精确 match → `PROJECT_SETTING_MUTATIONS` →
`RESOURCE_CREATE/UPDATE_MUTATIONS` → group 前缀 → 退化为 `global`。

宁可先保守（多推进几个标签，牺牲一点命中率），也不要激进（漏标签导致陈久读）。

### 9.4 新增工作流 profile

在 `game_workflow_engine.gd` 追加 `PROFILE_IDS`、`PROFILE_KEYWORDS`（中英双语）、
`PROFILE_COMPOSITION_ORDER`、`_profile_specs()` 分支。

---

## 10. 已知约束与改进建议

### 10.1 工具计数漂移（已修正，2026-08-30）

manifest 实际为 **231 个（28 + 197 + 6，非 meta 原子能力 225）**，但多处仍在使用更早的
"223 / 189 / 217" 基数。已全部同步至 231 / 197 / 225：

| 位置 | 影响等级 | 说明 |
| --- | --- | --- |
| `mcp_server_core.gd` 的 `SERVER_INSTRUCTIONS` | **高** | 随 `initialize` 响应注入模型上下文，会直接误导 AI 客户端 |
| `tools_manifest.gd` 头注释 | 中 | 新增工具时的参考基数 |
| `test_tool_schema_lint.gd` 注释与断言消息 | 低 | 断言本身是下界（`MIN_TOOL_COUNT = 218`），未受影响 |
| `AGENTS.md` / `README*.md` / `docs/*.md` / `docs/tools/*.md` | 中 | 对外的能力数量承诺 |

**刻意未改**（时间点信息本身有价值，改动会失真）：
`docs/research/*`（研究快照，记录当时的 215 个工具规模）、`docs/changelog.md`（发布历史）、
`docs/optimization-roadmap.md`（路线图快照，226）。

**建议加一条防回归断言**：从 manifest 计算非 meta 工具数，并校验该数字出现在
`SERVER_INSTRUCTIONS` 中。这类"注入模型上下文的字符串"比普通注释更容易漂移且更难被察觉。

### 10.2 架构层面的观察

| 观察 | 说明 | 建议 |
| --- | --- | --- |
| `mcp_server_native.gd` 职责偏重 | 1243 行，同时承担配置、装配、缓存信号、资源实现 | 可把 7 个 `godot://` 资源实现抽到独立 `resources/` 模块 |
| `editor_tools_native.gd` 3389 行 | 26 个工具，是最大的工具模块 | 按 `debug_*` / `project_*` 的先例按域再拆 |
| `mutation_tags` 人工维护 | 新增写入工具漏登记会静默产生陈旧读 | 考虑加一条测试：遍历所有非只读工具，断言其在 `mutation_tags` 中有显式覆盖或不返回空集 |
| 运行时探针进入导出包 | Autoload 会打进生产构建 | 评估导出时裁剪，或提供 release 构建开关 |
| 单飞等待为轮询 | `while ... await process_frame` 每帧检查一次 | 对绝大多数场景足够，无需优化；仅在高并发同 key 时有 CPU 开销 |

### 10.3 与其他文档的关系

| 文档 | 内容 |
| --- | --- |
| `docs/architecture.md` | 简版架构总览（组件表 + 生命周期） |
| `docs/system-design.md`（本文） | 完整设计：模块职责、数据流、决策权衡 |
| `docs/architecture-diagrams.html` | 可打印的架构图集 |
| `docs/game-workflows.md` | 游戏工作流使用指南 |
| `docs/contributing.md` | 新增工具的完整流程 |
| `docs/tools/*.md` | 各域工具参考 |
