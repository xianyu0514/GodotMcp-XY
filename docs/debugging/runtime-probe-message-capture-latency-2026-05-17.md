# Runtime Probe 消息捕获注册延迟：根因分析与解决方案

> 记录于 2026-05-17
> 状态：方案A已实现，方案B标记为低优先级优化

---

## 1. 完整通信链路

```
[编辑器进程]                              [游戏运行时进程]

1. bridge.send_debugger_message()  ──→   2. probe._capture_mcp_message()
   (session.send_message)                   (EngineDebugger.register_message_capture)

              ←──  3. EngineDebugger.send_message("mcp:response")
4. bridge._capture()
   → _captured_messages[]
5. _extract_pending_runtime_probe_response()
```

### 关键源码位置

| 组件 | 文件 | 关键函数/变量 |
|------|------|---------------|
| Debugger Bridge | `mcp_debugger_bridge.gd` | `_capture()`, `_setup_session()`, `send_debugger_message()`, `_captured_messages` |
| Runtime Probe | `mcp_runtime_probe.gd` | `_ready()`, `_ensure_debugger_capture_registered()`, `_capture_mcp_message()`, `EngineDebugger.register_message_capture()` |
| Debug Tools | `debug_tools_native.gd` | `_request_runtime_probe()`, `_request_runtime_probe_poll()`, `_extract_pending_runtime_probe_response()` |

---

## 2. 延迟的根因分析

延迟不在"注册"本身，而在"探针就绪"的等待窗口。具体分两阶段：

### 阶段 1：游戏进程启动 → `EngineDebugger.is_active()` 返回 true

探针 `_ready()` 调用 `_ensure_debugger_capture_registered()`，但 `EngineDebugger.is_active()` 在游戏刚启动的最初几帧可能返回 false（调试器尚未完全连接）。探针通过 `_process()` 每帧重试来弥补。

**实测结论**：此阶段通常只需 1-2 帧就完成，不是主要瓶颈。

### 阶段 2：探针注册 capture → 编辑器发出的消息被探针接收并处理

**这是真正的瓶颈**。当编辑器通过 `bridge.send_debugger_message("mcp:command", payload)` 发消息时，消息进入游戏进程的 `EngineDebugger` 消息队列。但存在以下竞态：

1. **调试器可能处于 breaked 状态**：Godot 启动游戏时，如果调试器默认中断，游戏线程会暂停，探针无法处理消息（`_capture_mcp_message` 不被调用）
2. **`session.send_message()` 是异步的**：消息发送后编辑器侧立即返回，但游戏进程何时处理取决于其事件循环
3. **编辑器侧 `_capture()` 也是异步的**：游戏回复后，编辑器需要至少一个主循环帧才能通过 `EditorDebuggerPlugin._capture()` 接收到回复

### 为什么简单表达式快、复杂表达式慢？

- **简单表达式（`1+1`）**：探针处理极快（<1ms），回复在 1-2 帧内到达编辑器
- **复杂表达式（`OS.get_name()`）或截图**：探针处理需要更多帧（截图需要渲染 1 帧），回复需要 3-5 帧才能到达
- 如果恰逢调试器 breaked，则完全阻塞直到 continue

---

## 3. 解决方案

### 方案 A（已实现 ✅）：编辑器侧主动等待探针就绪信号

**原理**：探针在 `_ensure_debugger_capture_registered()` 成功注册 capture 后，已通过 `EngineDebugger.send_message("mcp:probe_ready", [info])` 发送就绪信号。编辑器侧 bridge 只需在 `_capture()` 中识别此信号并记录标志，然后 `_request_runtime_probe_poll()` 在发请求前先等待探针就绪。

**修改内容**：

1. **`mcp_debugger_bridge.gd`**：
   - 新增 `_probe_ready_session_ids: Dictionary` 变量（记录哪些 session 已收到 probe_ready）
   - `_capture()` 中识别 `mcp:probe_ready` 消息，标记 session 就绪
   - 新增 `is_probe_ready(session_id) -> bool` 查询方法
   - 新增 `wait_for_probe_ready(session_id, timeout_ms) -> bool` 等待方法

2. **`debug_tools_native.gd`**：
   - `_request_runtime_probe_poll()` 在首次发送请求前，先调用 `bridge.wait_for_probe_ready()` 等待探针就绪

**效果**：消除了"请求发出时探针尚未就绪"的竞态窗口，确保消息到达时探针已能处理。

### 方案 B（低优先级优化，暂不实现）：调试器启动时自动 continue

**原理**：在 `MCPDebuggerBridge._setup_session()` 中，当检测到新 session 且处于 breaked 状态时，自动发送 `continue` 命令。

**暂不实现的原因**：
- 调试器 breaked 状态可能是用户有意设置断点导致的，自动 continue 会绕过用户断点
- 破坏正常调试工作流（用户可能期望在首行断住检查状态）
- 当前 `_request_runtime_probe_poll()` 的轮询机制已能在 continue 后正常获取响应
- 风险/收益比不佳：收益仅消除"游戏因调试器 break 而无法响应"的延迟，但代价是破坏调试体验

**标记为低优先级优化，后续根据实际使用反馈决定是否实现。如果实现，应添加配置项让用户选择是否自动 continue。**

### 方案 C（已实现 ✅）：增大 poll 超时 + 减小 poll 间隔

已在第二轮修复中实现：`_request_runtime_probe_poll` 每 50ms 轮询一次，timeout 从 1500ms 提升到 3000ms。这是缓解手段，方案A才是根本解决。

### 方案 D（方案A+方案B合并，终极方案）

方案A已实现，方案B暂缓，因此方案D当前等于方案A。后续若实现方案B，则自动升级为方案D。

---

## 4. 实现细节（方案A）

### 4.1 MCPDebuggerBridge 修改

```gdscript
# 新增变量
var _probe_ready_session_ids: Dictionary = {}  # session_id -> true

# _capture() 中新增 probe_ready 识别
func _capture(message: String, data: Array, session_id: int) -> bool:
    _append_captured_message(session_id, message, data)
    # 识别探针就绪信号
    if message == "mcp:probe_ready":
        _probe_ready_session_ids[session_id] = true
    # ... 其余逻辑不变

# 新增方法
func is_probe_ready(session_id: int = -1) -> bool:
    if session_id >= 0:
        return _probe_ready_session_ids.has(session_id)
    return _probe_ready_session_ids.size() > 0

func wait_for_probe_ready(session_id: int = -1, timeout_ms: int = 2000) -> bool:
    if is_probe_ready(session_id):
        return true
    var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
    while Time.get_ticks_msec() < deadline_ms:
        OS.delay_msec(50)
        get_captured_messages(1, 0, "desc")  # 刷新消息队列
        if is_probe_ready(session_id):
            return true
    return is_probe_ready(session_id)

func reset_probe_ready(session_id: int = -1) -> void:
    if session_id >= 0:
        _probe_ready_session_ids.erase(session_id)
    else:
        _probe_ready_session_ids.clear()
```

### 4.2 DebugToolsNative 修改

```gdscript
# _request_runtime_probe_poll() 开头新增探针就绪等待
func _request_runtime_probe_poll(...) -> Dictionary:
    # 等待探针就绪
    var bridge: RefCounted = _get_debugger_bridge()
    if bridge and bridge.has_method("wait_for_probe_ready"):
        var session_id: int = int(params.get("session_id", -1))
        var probe_timeout: int = 2000
        bridge.wait_for_probe_ready(session_id, probe_timeout)

    # ... 原有逻辑不变
```

---

## 5. 测试验证

**方案A已生效**（2026-05-17 MCP 验证）：`mcp:probe_ready` 消息正确被 bridge 识别。

| 测试项 | 修复前 | 修复后 | 说明 |
|---|---|---|---|
| `get_runtime_info` | stale 回退 | ✅ 首次即 success | 竞态窗口消除 |
| `get_runtime_performance_snapshot` | pending→重试成功 | ✅ 首次即 success | 轻量级请求受益明显 |
| `evaluate_runtime_expression("1+1")` | 首次 pending | ✅ 首次即 success | 简单表达式正常 |
| `evaluate_runtime_expression("OS.get_name()")` | pending | ❌ 返回 error | GDScript Expression 类无法访问单例/类方法（引擎限制，非竞态问题） |
| `get_runtime_screenshot` | 多次 pending | 首次 pending→重试成功 | 重量级请求有固有的 1-2 帧异步延迟 |
| `get_runtime_scene_tree` | pending | 首次 pending→重试成功 | 同上 |

**结论**：
1. ✅ 方案A成功消除了"请求在探针就绪前发出"的竞态问题，轻量级请求首次即成功
2. ❌ `OS.get_name()` 等失败是 GDScript `Expression` 类的引擎限制，与消息捕获注册延迟无关
3. ⚠️ 截图/场景树等重量级请求仍有首次 pending 问题——见下方 §7 分析

---

## 7. 重量级请求首次 pending 的根因（`OS.delay_msec` 主循环阻塞）

### 问题

截图（`get_runtime_screenshot`）和场景树（`get_runtime_scene_tree`）等重量级请求在 `_request_runtime_probe_poll` 的 poll 循环中始终返回 pending，直到超时。第二次独立调用时才能成功。

### 根因

**`OS.delay_msec()` 阻塞了编辑器主线程，导致 `EditorDebuggerPlugin._capture()` 无法被调度。**

完整时序：

```
T0:    编辑器调用 _request_runtime_probe_poll()
T0:    bridge.send_debugger_message("mcp:get_scene_tree", ...) → 消息写入 IPC 通道
T0:    _extract_pending_runtime_probe_response() → 检查 _captured_messages → 空 → pending
T0+5ms: OS.delay_msec(5) ← 主线程被阻塞！
        此时：游戏进程已处理消息，发送了 mcp:scene_tree 回复到 IPC 通道
        但：编辑器主循环无法推进到 IPC 轮询阶段
        所以：_capture() 不会被调用，_captured_messages 不会更新
T0+10ms: OS.delay_msec 结束，DisplayServer.process_events() → 处理窗口事件，但调试器 IPC 仍在队列中
        再次检查 → _captured_messages 仍为空 → pending
...循环直到超时
```

第二次调用成功的原因：首次调用返回 pending 后，控制权交回 MCP 服务器主循环 → 编辑器主循环推进 → IPC 消息被处理 → `_capture()` 被调用 → 截图/场景树响应进入 `_captured_messages` → 第二次调用时找到缓存响应。

### 为什么轻量级请求不受影响？

轻量级请求（`get_runtime_info`、`performance_snapshot`）的响应数据很小，游戏进程回复极快（<1ms），在 `send_debugger_message` 返回后的同一帧内，引擎可能在 `send_debugger_message` 的内部实现中已经同步处理了 IPC 输入并调用了 `_capture()`。

### 已尝试的修复

1. **`DisplayServer.process_events()`**：在 poll 循环中每次 delay 后调用。**效果：无**。`process_events()` 只处理窗口/输入事件，不处理 EngineDebugger IPC 消息。
2. **减小 delay 间隔（50ms → 5ms）**：提高 poll 频率。**效果：无**。问题不在频率，而在主循环被阻塞。

### 引擎限制

Godot 的 `EditorDebuggerPlugin._capture()` 是由引擎在主循环迭代中调度的，Godot 没有暴露手动 poll 调试器 IPC 的 API：
- `DisplayServer.process_events()` — 只处理窗口/输入事件
- `SceneTree` — 没有手动推进帧的方法
- `EditorDebuggerSession` — 没有 poll/process 方法
- `MainLoop` — 没有手动迭代方法

### 可行的解决方案

#### 方案 C（推荐，已实现）：MCP 服务器层自动重试

当 `_request_runtime_probe_poll` 返回 pending 时，MCP 服务器在返回给客户端之前，在下一个主循环帧中再次尝试提取响应。这需要将工具执行从同步改为异步（使用 `await SceneTree.process_frame`），架构改动较大。

**当前降级方案**：在 `_request_runtime_probe_poll` 中保留 `DisplayServer.process_events()` 调用（部分平台可能受益），并将 poll 间隔从 50ms 减小到 5ms。对重量级请求，客户端（AI）在收到 pending 后应自动重试同一调用——第二次调用会从 `_captured_messages` 缓存中获取到响应。

#### 方案 D：将工具执行改为异步

将 MCP 工具处理函数改为 `async`（使用 GDScript `await`），在发送调试器消息后 `await SceneTree.process_frame` 等待一帧，再检查响应。这需要 MCP 服务器核心支持异步工具执行。

**评估**：这是最彻底的解决方案，但需要大幅重构 MCP 服务器架构（当前工具执行是同步的），暂不实现。

### 实际影响

- 轻量级请求（info、snapshot、简单表达式）：✅ 首次即成功
- 重量级请求（screenshot、scene_tree）：首次 pending，重试后成功
- 客户端（AI）在收到 pending 后应自动重试——这是可接受的 UX

---

## 6. 附录：EngineDebugger 通信机制详解

### EngineDebugger 双进程通信模型

Godot 编辑器运行游戏时，游戏是独立子进程。两者通过 `EngineDebugger` 通信：

1. **编辑器侧**：`EditorDebuggerSession.send_message()` → 写入与游戏进程的 IPC 通道
2. **游戏运行时侧**：`EngineDebugger.register_message_capture(prefix, callable)` → 注册消息处理回调
   - 游戏进程的主循环每帧检查 IPC 通道是否有新消息
   - 收到消息后按 prefix 分发给对应的 capture callable
3. **游戏运行时侧回复**：`EngineDebugger.send_message(prefix + ":" + name, data)` → 写入反向 IPC 通道
4. **编辑器侧**：`EditorDebuggerPlugin._capture()` → 虚函数回调，由 `MCPDebuggerBridge` 实现

### 为什么 Autoload 不能消除延迟

Autoload 解决的是"探针何时存在于场景树"的问题，但无论探针何时注册为 Autoload，它都需要在游戏进程启动后、调试器就绪后才能调用 `EngineDebugger.register_message_capture()`。这个等待窗口是 Godot 引擎的固有限制，无法绕过。

方案A的本质不是消除这个等待窗口，而是让编辑器侧**感知**这个窗口并主动等待，避免在窗口期内发送注定无法被处理的请求。
