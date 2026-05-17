# 方案D 影响评估：工具执行异步化

> 记录于 2026-05-17
> 目标：将 `_request_runtime_probe_poll` 中的 `OS.delay_msec` 同步忙等改为 `await SceneTree.process_frame`，让编辑器主循环在 poll 期间能推进，使 `EditorDebuggerPlugin._capture()` 能正常调度，解决重量级请求首次 pending 问题。
> 更新于 2026-05-17：补充全量异步 + 仅 HTTP 模式的改动分析

---

## 1. 核心改动

将 `tool.callable.call(arguments)` 从同步改为 `await`，使工具执行期间编辑器主循环可以推进，`_capture()` 能正常调度。

---

## 2. 需要修改的模块（按调用链从外到内）

| 层级 | 文件 | 当前关键代码 | 改动 |
|---|---|---|---|
| **L1 信号入口** | `mcp_server_core.gd:144` | `_transport.message_received.connect(_on_transport_message_received)` | 信号回调改为 lambda 启动协程 |
| **L2 请求处理** | `mcp_server_core.gd:176` | `response = _handle_request(message)` | → `response = await _handle_request(message)` |
| **L3 工具执行** | `mcp_server_core.gd:424` | `result = tool.callable.call(arguments)` | → `result = await tool.callable.call(arguments)` |
| **L4 资源加载** | `mcp_server_core.gd:503` | `content = resource.load_callable.call(params)` | → `content = await resource.load_callable.call(params)` |
| **L5 响应发送** | `mcp_server_core.gd:765` | stdio: 直接 `print(json_string)` | 需确保异步完成后仍能正确发送 |
| **L6 poll 循环** | `debug_tools_native.gd:2813` | `OS.delay_msec(5)` 同步忙等 | → `await get_tree().process_frame` 逐帧轮询 |
| **L7 probe 等待** | `mcp_debugger_bridge.gd:102` | `OS.delay_msec(10)` 同步忙等 | → 同上 |

---

## 3. 受影响的工具

所有使用 `_request_runtime_probe_poll` 的工具都会受益——首次调用不再 pending。但它们不需要修改代码，因为 `_request_runtime_probe_poll` 内部的改动会透明传递。

| 类别 | 工具数量 | 影响 |
|---|---|---|
| Runtime 探针工具 | 34 个 | 透明受益，无需改动 |
| `await_runtime_condition` / `assert_runtime_condition` | 2 个 | 内部 `OS.delay_msec` 也需改为 `await process_frame` |
| 非 runtime 工具（场景/脚本/项目等） | ~118 个 | **不受影响**——它们不调用 `_request_runtime_probe_poll`，也不使用 `await` |

### 34 个 Runtime 探针工具清单

| 工具函数 | 行号 |
|---|---|
| `_tool_get_runtime_info` | 1610 |
| `_tool_get_runtime_performance_snapshot` | 1642 |
| `_tool_get_runtime_memory_trend` | 1687 |
| `_tool_get_runtime_scene_tree` | 1722 |
| `_tool_inspect_runtime_node` | 1747 |
| `_tool_find_runtime_node` | 1780 |
| `_tool_get_runtime_node_property` | 1805 |
| `_tool_set_runtime_node_property` | 1833 |
| `_tool_call_runtime_node_method` | 1861 |
| `_tool_evaluate_runtime_expression` | 1888 |
| `_tool_emit_runtime_signal` | 1916 |
| `_tool_simulate_runtime_input_action` | 1945 |
| `_tool_list_runtime_input_actions` | 1967 |
| `_tool_add_runtime_input_action_event` | 1998 |
| `_tool_erase_runtime_input_action` | 2023 |
| `_tool_get_runtime_input_map` | 2048 |
| `_tool_play_runtime_animation` | 2078 |
| `_tool_stop_runtime_animation` | 2104 |
| `_tool_get_runtime_animation_state` | 2129 |
| `_tool_set_runtime_animation_parameter` | 2154 |
| `_tool_set_runtime_shader_parameter` | 2182 |
| `_tool_get_runtime_animation_tree_state` | 2209 |
| `_tool_request_runtime_animation_tree_transition` | 2236 |
| `_tool_add_runtime_tilemap_tile` | 2266 |
| `_tool_erase_runtime_tilemap_tile` | 2297 |
| `_tool_get_runtime_tilemap_cell` | 2327 |
| `_tool_set_runtime_tilemap_cell` | 2354 |
| `_tool_set_runtime_audio_bus_property` | 2384 |
| `_tool_get_runtime_audio_bus_property` | 2409 |
| `_tool_move_runtime_audio_bus` | 2439 |
| `_tool_update_runtime_theme_override` | 2479 |
| `_tool_list_runtime_audio_buses` | 2499 |
| `_tool_get_runtime_audio_bus_effect` | 2524 |
| `_tool_set_runtime_audio_bus_effect_property` | 2556 |

---

## 4. 不会导致异常的功能模块

以下模块完全不受影响：

| 模块 | 原因 |
|---|---|
| 场景工具（node_tools_native） | 纯同步操作，不涉及调试器 IPC |
| 脚本工具（script_tools_native） | 纯同步操作 |
| 项目工具（project_tools_native） | 纯同步操作 |
| 资源工具（resource_tools_native） | 纯同步操作 |
| 输入映射工具 | 操作 ProjectSettings，纯同步 |
| 导出工具 | 纯同步 |
| UI 面板 | 已使用 `await`（行 517/524），不受影响 |
| 调试器非 runtime 工具（breakpoint/step/continue 等） | 通过 `session.send_message` 同步发送，不等待响应 |

---

## 5. 可能导致异常的风险点

| 风险 | 严重度 | 说明 | 缓解措施 |
|---|---|---|---|
| **协程中途取消** | 🔴 高 | 如果客户端断开连接（如 MCP 进程被 kill），正在 `await` 的协程会被场景树清理，可能导致工具执行中断 | 在协程中检查 `is_instance_valid()`，或使用 `SceneTree.process_frame` 的 `CONNECT_ONE_SHOT` |
| **并发请求竞态** | 🔴 高 | 当前同步执行保证同一时刻只有一个工具在运行。异步后多个请求可能并发执行，`_pending_runtime_probe_requests` 等共享状态可能出现竞态 | 需要加互斥锁或请求队列，保证串行执行 |
| **Godot 信号连接限制** | 🟡 中 | `_on_transport_message_received` 变为协程后，`signal.connect()` 不能直接连接协程函数，需改为 lambda | `signal.connect(func(msg, ctx): _start_async_handler(msg, ctx))` |
| **stdio 响应顺序** | 🟡 中 | 当前同步保证请求-响应严格有序。异步后多个工具并发完成，响应可能乱序 | MCP JSON-RPC 有 `id` 字段匹配请求-响应，客户端可按 id 匹配。但需确保不会在未完成前发送下一个请求的响应 |
| **HTTP 短连接** | 🟡 中 | 当前 HTTP 模式发送响应后立即 `disconnect_from_host()`。异步后需保持连接直到响应完成 | 改为在 `_handle_tool_call` 完成后再 disconnect，或用 SSE 推送 |
| **`_pending_runtime_probe_requests` 状态** | 🟡 中 | 异步后，同一请求可能在多个帧中处于 pending 状态，如果期间有新的相同请求到来，可能复用错误的缓存 | 请求 key 已包含 command+payload，不同请求不会冲突；但需确保过期清理正确 |

---

## 6. 传输层现状分析

### stdio 模式（`McpStdioServer`）

- **有响应队列机制**：`_response_queue: Array[Dictionary]`（行 25），受 `_mutex` 保护
- `queue_response()`（行 198-203）：将响应追加到队列，`call_deferred("_process_response_queue")` 在主线程处理
- **但实际未使用**：`mcp_server_core.gd` 的 `_send_response()`（行 765-773）在 stdio 模式下直接 `print(json_string)`，没走队列
- **异步后需改为**：异步完成后通过 `queue_response()` 发送响应

### HTTP 模式（`McpHttpServer`）

- `send_response()`（行 639-645）：获取 `context`（StreamPeerTCP），直接 `_send_http_response()`
- `_send_http_response()`（行 650-669）：构建响应头，`peer.put_data(full_response)`，然后**立即 `peer.disconnect_from_host()`**
- **无缓冲/队列机制**，每个请求-响应是独立的短连接
- **异步后需改为**：保持连接直到响应完成，或改用 SSE 长连接推送

---

## 7. 架构建议：分阶段实施

### 阶段 1（最小改动，解决核心问题）

仅将 `_request_runtime_probe_poll` 和 `wait_for_probe_ready` 改为异步，使用 `await get_tree().process_frame`。同时将 `_handle_tool_call` 改为异步。**限制为仅 runtime 工具走异步路径**——非 runtime 工具仍同步执行。

```gdscript
# _handle_tool_call 中区分同步/异步
if tool.is_async:
    result = await tool.callable.call(arguments)
else:
    result = tool.callable.call(arguments)
```

需要修改的文件：
- `mcp_server_core.gd`：L1 信号入口、L2 请求处理、L3 工具执行
- `debug_tools_native.gd`：L6 poll 循环
- `mcp_debugger_bridge.gd`：L7 probe 等待

风险：低（runtime 工具独立路径，非 runtime 工具不受影响）

### 阶段 2

解决并发竞态，添加请求队列/互斥锁。

### 阶段 3

传输层适配（HTTP 长连接、stdio 响应排序）。

---

## 8. 与现有方案的对比

| 维度 | 方案A（已实现） | 方案C（当前降级） | 方案D（异步化） |
|---|---|---|---|
| 轻量级请求首次成功 | ✅ | ✅ | ✅ |
| 重量级请求首次成功 | ❌ 需重试 | ❌ 需重试 | ✅ |
| 代码改动量 | 小（~30 行） | 无额外改动 | 大（~100+ 行，3 个核心文件） |
| 架构风险 | 无 | 无 | 🔴 并发竞态 + 协程取消 |
| 对非 runtime 工具的影响 | 无 | 无 | 无（阶段 1 隔离） |
| 传输层改动 | 无 | 无 | 阶段 3 需要 |

---

## 9. 结论（原方案，保留参考）

- 需修改 **3 个核心文件**（`mcp_server_core.gd`、`debug_tools_native.gd`、`mcp_debugger_bridge.gd`）+ 传输层微调
- **118 个非 runtime 工具不受影响**，无需任何改动
- **34 个 runtime 工具透明受益**，无需改动工具函数本身
- **主要风险**：并发竞态（🔴）和协程中途取消（🔴），需请求队列和有效性检查来缓解
- **建议**：阶段 1 仅异步化 runtime 工具执行路径，非 runtime 工具保持同步，风险可控

---

## 10. 全量异步 + 仅 HTTP 模式：改动分析

> 前提：所有工具都支持异步并发执行，不再保留同步路径，且只考虑 HTTP 传输模式。

### 10.1 核心思路

当前 HTTP 模式的调用链：

```
HTTP线程: _http_server_loop → _handle_http_request → _handle_post_request
    → call_deferred("_emit_message_received", message, peer)  ← 跨线程到主线程

主线程: _emit_message_received → message_received.emit(message, peer)
    → _on_transport_message_received(message, peer)
    → _handle_request(message)                              ← 同步
    → _handle_tool_call(message)                            ← 同步
    → tool.callable.call(arguments)                         ← 同步
    → _send_response(response, context)                     ← 同步
    → _send_http_response(peer, response)                   ← 同步
    → peer.put_data() → peer.disconnect_from_host()         ← 同步
```

全量异步后：

```
HTTP线程: (不变) → call_deferred("_emit_message_received", message, peer)

主线程: _emit_message_received → message_received.emit(message, peer)
    → _on_transport_message_received(message, peer)
    → _handle_request_async(message, peer)                  ← 异步协程启动
    → _handle_tool_call_async(message)                      ← await
    → await tool.callable.call(arguments)                   ← await
    → _send_response(response, peer)                        ← 协程完成后
    → _send_http_response(peer, response)                   ← 同步（peer 仍在连接）
    → peer.put_data() → peer.disconnect_from_host()
```

**关键**：HTTP 线程收到请求后通过 `call_deferred` 传给主线程，主线程启动一个协程来处理。协程中可以 `await get_tree().process_frame` 等待主循环推进。协程完成后，通过 peer 发送响应并关闭连接。

**HTTP 模式天然支持异步**：每个请求有独立的 `StreamPeerTCP` peer 作为 context，响应通过 peer 发送——不像 stdio 模式共用一个 stdout 流，需要担心响应顺序。

### 10.2 需要修改的文件和改动量

| # | 文件 | 改动 | 改动量 | 说明 |
|---|---|---|---|---|
| 1 | `mcp_server_core.gd` | `_on_transport_message_received` 改为启动协程 | ~15 行 | 信号回调不能直接是协程，需要用 lambda 包装启动 |
| 2 | `mcp_server_core.gd` | `_handle_request` 改为 async | ~5 行 | 函数签名加返回类型声明，内部 `await` |
| 3 | `mcp_server_core.gd` | `_handle_tool_call` 改为 async | ~3 行 | `tool.callable.call()` → `await tool.callable.call()` |
| 4 | `mcp_server_core.gd` | `_handle_resource_read` 改为 async | ~3 行 | `resource.load_callable.call()` → `await` |
| 5 | `debug_tools_native.gd` | `_request_runtime_probe_poll` poll 循环改为 `await process_frame` | ~10 行 | 替换 `OS.delay_msec` + `process_events` |
| 6 | `debug_tools_native.gd` | `wait_for_probe_ready` 改为 async | ~5 行 | 同上 |
| 7 | `mcp_debugger_bridge.gd` | `wait_for_probe_ready` 改为 async | ~5 行 | 同上 |
| 8 | `mcp_debugger_bridge.gd` | `request_runtime_message` 改为 async | ~5 行 | 同上 |
| **总计** | | | **~51 行** | |

### 10.3 不需要修改的文件

| 文件 | 原因 |
|---|---|
| `mcp_http_server.gd` | HTTP 传输层无需修改——`call_deferred("_emit_message_received")` 已正确跨线程传递消息和 peer；响应通过 `_send_http_response(peer, response)` 发送，peer 是每个请求独立的，协程完成后调用即可 |
| `mcp_transport_base.gd` | 信号定义不变 |
| 所有 `*_tools_native.gd` 中的工具函数 | 工具函数本身不需要改为 async——只有内部调用的 `_request_runtime_probe_poll` 需要。对于非 runtime 工具，`tool.callable.call(arguments)` 加 `await` 后同步函数的返回值会直接返回（await 同步值 = 值本身），**行为完全不变** |
| `mcp_server_native.gd`（EditorPlugin） | 不涉及请求处理链路 |
| UI 面板 | 已使用 `await`，不受影响 |

### 10.4 为什么改动比"分阶段方案"更小

| 对比维度 | 分阶段方案（§7） | 全量异步 + 仅 HTTP |
|---|---|---|
| 需要区分同步/异步路径？ | 是（`tool.is_async` 判断） | **否**——所有工具统一 `await`，同步函数 await 后行为不变 |
| 传输层改动 | stdio 需要响应队列 | **不需要**——只保留 HTTP 模式，无需改动 |
| 并发控制 | 需要加互斥锁保证串行 | **可选**——HTTP 模式下每个请求有独立 peer，天然支持并发。如需串行可在 `_handle_request_async` 中加队列 |
| 信号连接 | 需要处理协程不能直接 connect 的问题 | **同一问题**，但解决方案相同且只需改一处 |
| 总改动量 | ~100+ 行（L1-L7 全改 + 传输层 + 同步/异步分流） | **~51 行**（只改 L1-L4 + L6-L7，无传输层改动，无分流逻辑） |

### 10.5 GDScript 中 `await` 同步函数的行为

```gdscript
# 同步函数
func sync_tool(params: Dictionary) -> Dictionary:
    return {"status": "ok"}

# 异步调用同步函数
var result = await sync_tool(params)  # 等价于 sync_tool(params)，直接返回
# result == {"status": "ok"}
```

在 GDScript 中，`await` 一个非协程的返回值会立即得到结果。因此**对所有 154 个工具统一使用 `await tool.callable.call(arguments)` 是安全的**：
- 同步工具：行为不变，直接返回
- 异步工具（内部使用 `await process_frame`）：主循环可以推进，`_capture()` 能被调度

### 10.6 协程启动方式

Godot 4.x 中，信号连接的回调不能直接是协程。需要用 lambda 包装：

```gdscript
# 当前（同步）
_transport.message_received.connect(_on_transport_message_received)

# 改为（异步启动）
_transport.message_received.connect(func(message: Dictionary, context: Variant):
    _on_transport_message_received(message, context)
)
```

在 lambda 中直接调用异步函数 `_on_transport_message_received`，Godot 会自动将其作为协程执行。

### 10.7 并发安全性分析

**HTTP 模式天然支持并发**：每个 HTTP 请求有独立的 `StreamPeerTCP` peer，响应通过各自的 peer 发送，不会混淆。

**需要关注的共享状态**：

| 共享状态 | 并发风险 | 是否需要保护 |
|---|---|---|
| `_pending_runtime_probe_requests` | 多个 runtime 工具并发执行时可能同时读写 | **是**——但 GDScript 在主线程中执行，协程也是主线程，不存在真正的线程并发。多个协程在 `await` 点交替执行，是协作式并发，不会同时进入临界区 |
| `_captured_messages` | 多个协程可能同时读取 | **否**——只读操作，写入由引擎的 `_capture()` 同步完成 |
| `ProjectSettings` | 多个工具可能同时修改 | **否**——ProjectSettings 操作是同步的，协程式并发不会同时执行 |
| `_probe_ready_session_ids` | 读写 | **否**——同上，协作式并发 |

**结论**：GDScript 的协程是**协作式并发**（cooperative），不是抢占式多线程。两个协程不会同时执行——一个在 `await` 挂起后，另一个才能运行。因此**不需要互斥锁**，共享状态的并发风险为 **零**。

### 10.8 仍然存在的风险

| 风险 | 严重度 | 说明 | 缓解 |
|---|---|---|---|
| 协程中途取消 | 🟡 中 | 如果 HTTP 连接在协程 `await` 期间断开，协程继续执行但 peer 已失效 | `_send_http_response` 中检查 `peer.get_status()`，失败时静默忽略 |
| 长时间运行的工具阻塞其他请求 | 🟡 中 | 如果一个工具在 `await process_frame` 循环中运行 5 秒，其他请求会排队 | 这是预期行为——MCP 协议本身是请求-响应模式，客户端通常串行调用 |
| stdio 模式不可用 | 🟢 低 | 移除 stdio 支持后，通过命令行启动的 MCP 客户端无法连接 | 在文档中明确仅支持 HTTP 模式；或保留 stdio 但仍走同步路径 |

### 10.9 最终改动清单

```
mcp_server_core.gd:
  - _on_transport_message_received: 信号连接改为 lambda 启动协程 (~5 行)
  - _on_transport_message_received: 函数体改为 async，await _handle_request (~5 行)
  - _handle_request: 函数签名改为 async (~1 行)
  - _handle_tool_call: 函数签名改为 async，tool.callable.call → await (~3 行)
  - _handle_resource_read: 函数签名改为 async，load_callable.call → await (~3 行)

debug_tools_native.gd:
  - _request_runtime_probe_poll: OS.delay_msec + process_events → await process_frame (~10 行)

mcp_debugger_bridge.gd:
  - wait_for_probe_ready: OS.delay_msec → await process_frame (~5 行)
  - request_runtime_message: OS.delay_msec → await process_frame (~5 行)

总计: ~51 行改动
```

### 10.10 与原分阶段方案的对比结论

**全量异步 + 仅 HTTP 模式的改动确实更小**，原因：

1. **无需同步/异步分流逻辑**——`await` 同步函数行为不变，所有工具统一走 `await` 路径
2. **无需传输层改动**——HTTP 模式的 peer-per-request 天然支持异步响应
3. **无需互斥锁**——GDScript 协程式并发不存在真正的线程并发
4. **总改动 ~51 行 vs 分阶段 ~100+ 行**

**建议**：直接采用全量异步 + 仅 HTTP 方案实施。
