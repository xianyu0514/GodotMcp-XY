# MCP 审计修复与增强实施计划

> **协作提示：** 建议按 Phase 顺序实施，每个 Phase 可独立 PR。

**目标：** 基于实际项目使用中发现的 10 个 Bug、8 个局限性和 7 个功能需求，分阶段修复和改进 Godot MCP Native 插件。
**技术栈：** GDScript（Godot 4.6 EditorPlugin）、GUT（单元测试）
**评估基准：** 实施完成后运行 `test/unit/` 全量 GUT 测试，0 failure。

---

## 当前进度总览（2026-06-15 更新）

| 状态 | 数量 | 说明 |
|------|------|------|
| ✅ **已完成** | **6 项** | C# 工具增强（5 工具）、_sanitize_cli_output 增强、19080→9080 端口修正 |
| 🔧 **待实施** | **12 项** | Phase 1-4 中剩余任务 |
| 💡 **新增发现** | **1 项** | `mcp_panel_native.gd:915` — `append_text` 不存在于 TextEdit |

### 已完成项目详情

| 任务 | 对应文件 | 日期 |
|------|---------|------|
| `read_script` C# 支持 | `script_tools_native.gd` | 2026-06-15 |
| `attach_script` C# 支持 | `script_tools_native.gd` | 2026-06-15 |
| `create_script` C# 模板 | `script_tools_native.gd`（新增 `_get_csharp_script_template`） | 2026-06-15 |
| `list_project_scripts` 收集 .cs | `script_tools_native.gd` | 2026-06-15 |
| `modify_script` 描述更新 | `script_tools_native.gd` | 2026-06-15 |
| `_sanitize_cli_output` 增强 ANIS 转义 | `project_tools_native.gd` | 2026-06-15 |
| 端口 19080→9080 修正 | README 系列 + 测试文件 | 2026-06-15 |
| C# 兼容性审计文档 | `docs/architecture/csharp-compatibility-audit.md` | 2026-06-15 |

### 新增发现 Bug

| Bug | 文件 | 行 | 描述 | 严重度 |
|-----|------|----|------|--------|
| `append_text` 不存在 | `mcp_panel_native.gd` | 915 | TextEdit 在 Godot 4.x 无 `append_text()` 方法，应改用 `text +=` | 中（UI 面板持续刷 ERROR） |

## Phase 1：高优先级 Bug 修复

### Task 1.1: save_scene 增加 scene_path 参数

- **审计条目：** P1 Bug — save_scene 保存到当前激活场景而非目标场景；F6 功能需求
- **复杂度：** 小（2-3 步）

**文件：**
- 修改：`addons/godot_mcp/tools/scene_tools_native.gd`
- 修改：`docs/current/tools-reference.md`（工具参考）
- 测试：`test/unit/tools/test_scene_tools.gd`

**修改内容：**

在 `_register_save_scene` 的 input_schema 中已有 `file_path` 可选参数。当前实现只在无 `file_path` 时使用当前场景路径。问题是：**即使传了 `file_path`，如果场景已打开，编辑器仍可能把内存版本写到原文件**。

**方案：** 当传了 `file_path` 且与当前场景路径不同时，先 `close_scene_tab` 关闭当前场景（不保存），创建 PackedScene 后 `ResourceSaver.save` 到目标路径，然后 `open_scene_from_path` 重新打开目标场景。

```gdscript
func _tool_save_scene(params: Dictionary) -> Dictionary:
    if _scene_operation_in_progress:
        return {"error": "Scene operation in progress, please retry"}

    var editor_interface: EditorInterface = _get_editor_interface()
    if not editor_interface:
        return {"error": "Editor interface not available"}

    var file_path: String = params.get("file_path", "")
    var scene_root: Node = _get_user_scene_root()
    if not scene_root:
        return {"error": "No scene is currently open"}

    # 如果没有传路径，用当前场景路径
    if file_path.is_empty():
        file_path = scene_root.scene_file_path
        if file_path.is_empty():
            return {"error": "Scene has no file path. Please provide a file_path parameter."}

    # 验证路径
    var validation: Dictionary = PathValidator.validate_file_path(file_path, [".tscn"])
    if not validation["valid"]:
        return {"error": "Invalid path: " + validation["error"]}
    file_path = validation["sanitized"]

    # 如果目标路径与当前场景路径不同，需要特殊处理
    var current_path: String = scene_root.scene_file_path
    if current_path != file_path and not current_path.is_empty():
        # 打包场景树
        var packed_scene: PackedScene = PackedScene.new()
        var pack_error: Error = packed_scene.pack(scene_root)
        if pack_error != OK:
            return {"error": "Failed to pack scene: " + error_string(pack_error)}

        # 保存到目标路径
        var save_error: Error = ResourceSaver.save(packed_scene, file_path)
        if save_error != OK:
            return {"error": "Failed to save scene: " + error_string(save_error)}

        # 返回值中标记这是另存为操作
        return {
            "status": "success",
            "saved_path": file_path,
            "operation": "save_as"
        }

    # 同路径保存，保持原有行为
    var packed_scene: PackedScene = PackedScene.new()
    var error: Error = packed_scene.pack(scene_root)
    if error != OK:
        return {"error": "Failed to pack scene: " + error_string(error)}

    error = ResourceSaver.save(packed_scene, file_path)
    if error != OK:
        return {"error": "Failed to save scene: " + error_string(error)}

    return {
        "status": "success",
        "saved_path": file_path
    }
```

规范输出增加 `operation` 字段："save"（同路径）或 "save_as"（另存为）。

**测试：**
```gdscript
func test_save_scene_with_different_path():
    # 模拟 save_scene 传不同路径
    var result = tool._tool_save_scene({"file_path": "res://test_export.tscn"})
    assert_eq(result.get("operation"), "save_as", "Should return save_as for different path")

func test_save_scene_same_path():
    var result = tool._tool_save_scene({})
    assert_true(result.get("status") == "success", "Same-path save should succeed")
```

---

### Task 1.2: open_scene 增加错误检测

- **审计条目：** P1 Bug — open_scene 场景损坏时无声失败
- **复杂度：** 小（2 步）

**文件：**
- 修改：`addons/godot_mcp/tools/scene_tools_native.gd`
- 测试：`test/unit/tools/test_scene_tools.gd`

**修改内容：**

在 `_tool_open_scene` 中，打开场景后增加编辑器错误日志检测：

```gdscript
func _tool_open_scene(params: Dictionary) -> Dictionary:
    # ... 现有参数验证代码 ...

    editor_interface.open_scene_from_path(scene_path)

    var opened_scene_root: Node = _get_user_scene_root()
    if not opened_scene_root:
        _scene_operation_in_progress = false
        return {"error": "Failed to open scene: " + scene_path}

    # === 新增：检测编辑器日志中的错误 ===
    var errors: Array[Dictionary] = _check_recent_editor_errors()
    if errors.size() > 0:
        _scene_operation_in_progress = false
        # 仍然返回 root_node_type，但增加 error/warning 信息
        var scene_root: Node = _get_user_scene_root()
        var root_type: String = scene_root.get_class() if scene_root else "Unknown"
        return {
            "status": "warning",
            "scene_path": scene_path,
            "root_node_type": root_type,
            "warnings": errors,
            "message": "Scene opened with errors. Check 'warnings' field for details."
        }

    var scene_root: Node = _get_user_scene_root()
    var root_type: String = scene_root.get_class() if scene_root else "Unknown"

    _scene_operation_in_progress = false
    return {
        "status": "success",
        "scene_path": scene_path,
        "root_node_type": root_type
    }

# 新增辅助方法
func _check_recent_editor_errors() -> Array[Dictionary]:
    var editor_interface: EditorInterface = _get_editor_interface()
    if not editor_interface:
        return []
    # 通过 EditorInterface 读取最近日志中的 Error 记录
    # 由于 Godot 4.x 没有直接的 API 读取日志行，
    # 这里监听 editor_log 信号或借助 config_manager
    # 具体实现取决于可用的编辑器 API
    # ...
    return []  # 暂未实现，需验证 Godot 4.6 的 API 支持
```

**注意：** Godot 4.6 的 `EditorInterface` 没有直接读取日志缓存的 API。需要调研是否有其他方式（如 `EditorLog` 节点反射、`DisplayServer` 日志回调等）。如果不可行，则改为在返回值中增加 `suggested_verification` 字段，提醒调用方手动检查 `get_editor_logs`。

**回退方案（如果无法直接读取日志）：**
```gdscript
# 在返回值中增加验证提示：
var verification_note: Dictionary = {
    "note": "Scene may have loading errors. Call get_editor_logs(source='editor_panel', type=['Error']) to verify.",
    "verification_tip": "After opening the scene, always check get_current_scene() to confirm the correct scene is active."
}
```

---

### Task 1.3: create_node 增加 on_name_conflict 参数

- **审计条目：** P1 Bug — create_node 重名时静默生成 @NodeType@XXXXX；F7 功能需求
- **复杂度：** 小（2 步）

**文件：**
- 修改：`addons/godot_mcp/tools/node_tools_native.gd`
- 测试：`test/unit/tools/test_node_tools.gd`

**修改内容：**

在 input_schema 中增加 `on_name_conflict` 参数：

```gdscript
func _register_create_node(server_core: RefCounted) -> void:
    server_core.register_tool(
        "create_node",
        "Create a new node in the Godot scene tree. Returns the node path and type.",
        {
            "type": "object",
            "properties": {
                "parent_path": {
                    "type": "string",
                    "description": "Path to the parent node where the new node will be created (e.g. '/root', '/root/MainScene')"
                },
                "node_type": {
                    "type": "string",
                    "description": "Type of node to create (e.g. 'Node2D', 'Sprite2D', 'CharacterBody2D')"
                },
                "node_name": {
                    "type": "string",
                    "description": "Name for the new node"
                },
                # === 新增参数 ===
                "on_name_conflict": {
                    "type": "string",
                    "description": "Behavior when node_name already exists in parent: 'error' (return error), 'rename' (auto-rename with unique suffix), 'auto' (allow Godot to assign @NodeType@XXXXX name). Default: 'error'.",
                    "default": "error",
                    "enum": ["error", "rename", "auto"]
                }
                # === 新增结束 ===
            },
            "required": ["parent_path", "node_type", "node_name"]
        },
        Callable(self, "_tool_create_node"),
        # ...
    )
```

在 `_tool_create_node` 中增加冲突检测逻辑：

```gdscript
func _tool_create_node(params: Dictionary) -> Dictionary:
    var parent_path: String = params.get("parent_path", "")
    var node_type: String = params.get("node_type", "Node")
    var node_name: String = params.get("node_name", "NewNode")
    var on_name_conflict: String = params.get("on_name_conflict", "error")  # 新增

    # ... 现有验证代码 ...

    # === 新增：冲突检测 ===
    # 检查父节点下是否已存在同名节点
    if parent and parent.has_node(node_name):
        match on_name_conflict:
            "error":
                return {"error": "A node named '" + node_name + "' already exists under " + parent_path + ". Use a different name or set on_name_conflict='rename'."}
            "rename":
                var counter: int = 1
                var new_name: String = node_name + "_" + str(counter)
                while parent.has_node(new_name):
                    counter += 1
                    new_name = node_name + "_" + str(counter)
                node_name = new_name
            "auto":
                # 保持现有行为，让 Godot 自动命名
                pass
    # === 新增结束 ===

    var node: Node = ClassDB.instantiate(node_type)
    node.name = node_name

    # ... 现有代码 ...
```

---

### Task 1.4: stop_project 增加进程退出等待

- **审计条目：** P3 Bug — stop_project → run_project 间隔需要等待
- **复杂度：** 小（2 步）

**文件：**
- 修改：`addons/godot_mcp/tools/editor_tools_native.gd`
- 测试：`test/unit/tools/test_editor_tools.gd`

**修改内容：**

在 `_tool_stop_project` 中，调用 `stop_playing_scene()` 后等待进程完全退出再返回：

```gdscript
func _tool_stop_project(params: Dictionary) -> Dictionary:
    var policy_result: Dictionary = VIBE_CODING_POLICY.evaluate_runtime_window(_is_vibe_coding_mode(), params)
    if policy_result.get("blocked", false):
        return policy_result

    var editor_interface: EditorInterface = _get_editor_interface()
    if not editor_interface:
        return {"error": "Editor interface not available"}

    if not editor_interface.is_playing_scene():
        return {"error": "Project is not currently running."}

    editor_interface.stop_playing_scene()

    # === 新增：等待进程完全退出 ===
    var max_wait_ms: int = 5000
    var wait_interval_ms: int = 200
    var waited_ms: int = 0
    while editor_interface.is_playing_scene() and waited_ms < max_wait_ms:
        OS.delay_msec(wait_interval_ms)
        waited_ms += wait_interval_ms
    # === 新增结束 ===

    return {
        "status": "success",
        "mode": "editor"
    }
```

同时返回值增加 `stopped_after_ms` 字段报告实际等待时间。

---

## Phase 2：Bug 修复 + 现有工具增强

### Task 2.1: 增强 assert_runtime_condition 支持 expected 参数

- **审计条目：** F2 功能需求 — assert_runtime_condition 断言工具；现有的工具只检查 truthy，不支持 expected 值比较
- **复杂度：** 中（3 步）

**文件：**
- 修改：`addons/godot_mcp/tools/debug_tools_native.gd`
- 修改：`addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`（如果 count 变化）
- 测试：`test/unit/tools/test_debug_tools.gd`

**修改内容：**

现有 `_register_assert_runtime_condition` 只检查表达式的 truthy 值。在 input_schema 中增加 `expected` 和 `operator` 参数：

```gdscript
# input_schema 增加字段：
"expected": {
    "type": "string",
    "description": "Expected value to compare against. If provided, the tool asserts 'expression == expected' instead of truthiness."
},
"operator": {
    "type": "string",
    "description": "Comparison operator: 'eq' (default), 'ne', 'gt', 'gte', 'lt', 'lte'. Only used when expected is provided.",
    "default": "eq",
    "enum": ["eq", "ne", "gt", "gte", "lt", "lte"]
}
```

输出 schema 增加：
```gdscript
"expected": {"type": "string"},
"actual": {},  # 实际值
"passed": {"type": "boolean"}
```

`_tool_assert_runtime_condition` 的修改：

```gdscript
func _tool_assert_runtime_condition(params: Dictionary) -> Dictionary:
    var wait_result: Dictionary = await _tool_await_runtime_condition(params)
    if wait_result.has("error"):
        return wait_result

    var last_value = wait_result.get("last_value", null)
    var expected_raw = params.get("expected", null)

    # 如果没有 expected 参数，保持原有 truthy 行为
    if expected_raw == null:
        var passed: bool = wait_result.get("condition_met", false)
        return {
            "status": "passed" if passed else "failed",
            "description": params.get("description", params.get("expression", "")),
            "passed": passed,
            "actual": last_value,
            "attempts": wait_result.get("attempts", 0),
            "elapsed_ms": wait_result.get("elapsed_ms", 0)
        }

    # === 新增：expected 比较 ===
    var operator: String = params.get("operator", "eq")
    var expected_str: String = str(expected_raw)
    var actual_str: String = str(last_value) if last_value != null else "null"
    var passed: bool = _compare_values(actual_str, expected_str, operator)

    return {
        "status": "passed" if passed else "failed",
        "description": params.get("description", params.get("expression", "")),
        "passed": passed,
        "expected": expected_str,
        "actual": actual_str,
        "attempts": wait_result.get("attempts", 0),
        "elapsed_ms": wait_result.get("elapsed_ms", 0)
    }

func _compare_values(actual: String, expected: String, operator: String) -> bool:
    match operator:
        "eq":
            return actual == expected
        "ne":
            return actual != expected
        "gt":
            return float(actual) > float(expected)
        "gte":
            return float(actual) >= float(expected)
        "lt":
            return float(actual) < float(expected)
        "lte":
            return float(actual) <= float(expected)
    return false
```

**输出示例**（成功时）：
```json
{"status": "passed", "passed": true, "description": "Gold label shows 200", "expected": "200 G", "actual": "200 G", "attempts": 3, "elapsed_ms": 1200}
```

---

### Task 2.2: await_scene_ready 工具

- **审计条目：** F1 功能需求 — await_scene_ready 工具
- **复杂度：** 小（2 步）

**文件：**
- 修改：`addons/godot_mcp/tools/debug_tools_native.gd`
- 修改：`addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`
- 测试：`test/unit/tools/test_debug_tools.gd`
- 文档：`docs/current/tools-reference.md`

**实现方案：** 基于现有的 `await_runtime_condition` 实现，但封装成更友好的工具。本质上是 `await_runtime_condition` 的便捷封装：轮询 `get_runtime_info()` 的 `current_scene` 字段。

```gdscript
func _register_await_scene_ready(server_core: RefCounted) -> void:
    server_core.register_tool(
        "await_scene_ready",
        "Poll the runtime until the specified scene is loaded and ready. Internally checks get_runtime_info().current_scene until it matches the requested scene name.",
        {
            "type": "object",
            "properties": {
                "scene_name": {
                    "type": "string",
                    "description": "The expected scene name (e.g. 'Main', 'GameLevel'). The tool waits until current_scene contains this name."
                },
                "timeout_sec": {
                    "type": "number",
                    "description": "Maximum time to wait in seconds.",
                    "default": 10
                },
                "session_id": {"type": "integer"}
            },
            "required": ["scene_name"]
        },
        Callable(self, "_tool_await_scene_ready"),
        {
            "type": "object",
            "properties": {
                "status": {"type": "string"},
                "scene_name": {"type": "string"},
                "elapsed_sec": {"type": "number"},
                "timeout": {"type": "boolean"}
            }
        },
        {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
        "supplementary", "Debug-Advanced"
    )

func _tool_await_scene_ready(params: Dictionary) -> Dictionary:
    var scene_name: String = params.get("scene_name", "")
    if scene_name.is_empty():
        return {"error": "Missing required parameter: scene_name"}

    var timeout_sec: float = float(params.get("timeout_sec", 10.0))
    var timeout_ms: int = int(timeout_sec * 1000)
    var poll_interval_ms: int = 200
    var deadline_ms: int = Time.get_ticks_msec() + timeout_ms
    var attempts: int = 0

    while Time.get_ticks_msec() < deadline_ms:
        attempts += 1
        var runtime_info: Dictionary = await _tool_get_runtime_info(params)

        if runtime_info.has("error"):
            # Non-fatal: probe might not be ready yet, wait and retry
            if Time.get_ticks_msec() + poll_interval_ms < deadline_ms:
                var tree: SceneTree = Engine.get_main_loop() as SceneTree
                if tree:
                    await tree.process_frame
                else:
                    OS.delay_msec(poll_interval_ms)
                continue
            else:
                return {
                    "status": "timeout",
                    "scene_name": scene_name,
                    "elapsed_sec": timeout_sec,
                    "timeout": true,
                    "error": "Timeout waiting for scene: " + runtime_info.get("error", "probe not available"),
                    "attempts": attempts
                }

        var current_scene_path: String = runtime_info.get("current_scene", "")
        if not current_scene_path.is_empty() and current_scene_path.contains(scene_name):
            return {
                "status": "success",
                "scene_name": scene_name,
                "elapsed_sec": (Time.get_ticks_msec() - (deadline_ms - timeout_ms)) / 1000.0,
                "timeout": false,
                "attempts": attempts
            }

        # Wait before next poll
        if Time.get_ticks_msec() + poll_interval_ms < deadline_ms:
            var tree: SceneTree = Engine.get_main_loop() as SceneTree
            if tree:
                await tree.process_frame
            else:
                OS.delay_msec(poll_interval_ms)

    return {
        "status": "timeout",
        "scene_name": scene_name,
        "elapsed_sec": timeout_sec,
        "timeout": true,
        "attempts": attempts,
        "error": "Timeout: scene '" + scene_name + "' not ready after " + str(timeout_sec) + " seconds"
    }
```

**分类器注册：**
```gdscript
# 在 _build_classifications() 中增加：
{"name": "await_scene_ready", "category": "supplementary", "group": "Debug-Advanced"}
```

---

### Task 2.3: simulate_runtime_input_event position 修复

- **审计条目：** P2 Bug — simulate_runtime_input_event release 坐标被覆盖
- **复杂度：** 中（需要在 Runtime Probe 端修改）

**文件：**
- 修改：`addons/godot_mcp/runtime/mcp_runtime_probe.gd`
- 测试：`test/unit/test_mcp_runtime_probe.gd`

**问题分析：** 输入事件模拟是通过 Runtime Probe 转发到运行游戏的。Release 事件的 position 被 press 时的值覆盖，说明 Probe 端缓存了 press 的 position 并应用到 release 上。

**修复方案：** 在 `_on_simulate_input_event` 处理函数中，不对 release 事件的 position 做特殊处理，直接使用传入的值：

```gdscript
# 在 mcp_runtime_probe.gd 中找到输入事件处理函数
# 确保 release 事件使用传入的 position，而不是从状态缓存中读取
```

> **由于 Runtime Probe 代码结构复杂，具体修复需要：**
> 1. 找到 `simulate_input_event` 的处理函数
> 2. 定位到哪一步将 release position 替换为 press position
> 3. 移除该替换逻辑，让 release 使用传入的 position

---

## Phase 3：工具增强 + 文档

### Task 3.1: batch_update_node_properties 值格式统一

- **审计条目：** L2 局限性 — batch_update_node_properties 值格式不一致
- **复杂度：** 中（3 步）

**文件：**
- 修改：`addons/godot_mcp/tools/node_tools_native.gd`
- 文档：`docs/current/tools-reference.md`

**修改内容：**

在 `_tool_batch_update_node_properties` 中，为每个属性值增加类型自检测和格式转换：

```gdscript
func _tool_batch_update_node_properties(params: Dictionary) -> Dictionary:
    var node_path: String = params.get("node_path", "")
    var properties: Dictionary = params.get("properties", {})

    # ... 现有验证代码 ...

    var results: Array[Dictionary] = []
    var errors: Array[Dictionary] = []

    for property_name: String in properties:
        var raw_value = properties[property_name]
        var converted_value = _convert_property_value(property_name, raw_value)
        if converted_value.has("error"):
            errors.append({"property": property_name, "error": converted_value.error})
            continue

        # 获取该属性的实际类型并尝试转换
        var prop_info: Dictionary = _get_node_property_info(node, property_name)
        var typed_value = _coerce_value_to_type(converted_value.value, prop_info)

        # 设置属性
        node.set(property_name, typed_value)
        # ... 记录结果 ...

    # ... 返回结果 ...
```

**核心辅助函数：**
```gdscript
# 将多种输入格式统一转换为内部值
func _convert_property_value(property_name: String, value) -> Dictionary:
    if value is String:
        # 尝试解析 Vector2/StringName 格式 "(x, y)"
        # 尝试解析 Color hex "#RRGGBB"
        # 尝试解析数字字符串 "123"
        ...
    elif value is Dictionary:
        # Vector2: {"x": 1, "y": 2}
        # Color: {"r": 1.0, "g": 0.5, "b": 0.2}
        ...
    elif typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL]:
        return {"value": value}
    return {"value": value}

# 根据属性实际类型做类型强制转换
func _coerce_value_to_type(value, prop_info: Dictionary):
    var prop_type: int = prop_info.get("type", TYPE_NIL)
    match prop_type:
        TYPE_INT:
            return int(value) if value != null else 0
        TYPE_FLOAT:
            return float(value) if value != null else 0.0
        TYPE_BOOL:
            return bool(value)
        TYPE_VECTOR2:
            if value is Dictionary:
                return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
            if value is String:
                ...
        TYPE_COLOR:
            if value is String:
                return Color(value)
            ...
    return value
```

同时在返回值中增加 `property_types` 字段，返回每个属性检测到的 Godot 类型，方便调用方了解正确格式。

---

### Task 3.2: execute_editor_script 输出捕获增强

- **审计条目：** L2 局限性 — execute_editor_script 不返回 print 输出
- **复杂度：** 中（3 步）

**文件：**
- 修改：`addons/godot_mcp/tools/debug_tools_native.gd`
- 测试：`test/unit/tools/test_debug_tools.gd`

**方案：** 在执行脚本后自动调用 `get_editor_logs(source="editor_panel")` 并嵌入返回值：

```gdscript
func _tool_execute_editor_script(params: Dictionary) -> Dictionary:
    # ... 现有代码 ...

    # 执行脚本
    var output: Array = []
    var result: Variant = _execute_script_in_editor(code, output)

    # === 新增：自动捕获编辑器日志中的 print 输出 ===
    var print_output: Array = _capture_recent_print_output(editor_interface)
    # === 新增结束 ===

    return {
        "status": "success",
        "result": result,
        "output": output,
        "print_output": print_output,  # 新增字段
        "exec_duration_ms": duration_ms
    }

func _capture_recent_print_output(editor_interface: EditorInterface) -> Array:
    # 通过编辑器日志系统获取最近的 print 输出
    # 实现方式取决于 Godot 4.6 的 API 支持
    # 可能的方案：在脚本执行前后分别读取日志，对比差异
    return []
```

> **注意：** Godot 4.6 没有直接获取 Editor Output Panel 内容的公开 API。替代方案：在工具文档中明确标注此局限，并推荐用户在 `execute_editor_script` 后调用 `get_editor_logs`。

---

### Task 3.3: get_runtime_scene_tree stale 检测

- **审计条目：** P2 Bug — get_runtime_scene_tree 在 Godot 崩溃后返回 stale 缓存
- **复杂度：** 小（1 步）

**文件：**
- 修改：`addons/godot_mcp/tools/debug_tools_native.gd`
- 测试：`test/unit/tools/test_debug_tools.gd`

**修改内容：**

在 `_tool_get_runtime_scene_tree` 的返回值中增加 `stale` 字段：

```gdscript
func _tool_get_runtime_scene_tree(params: Dictionary) -> Dictionary:
    var result: Dictionary = await _request_runtime_probe_poll("get_scene_tree", [], ["mcp:scene_tree"], params)

    if result.get("status", "") in ["pending", "stale"]:
        # 检查运行时信息确认 game session 活性
        var runtime_info: Dictionary = await _tool_get_runtime_info(params)
        var is_stale: bool = runtime_info.get("stale", false)

        if is_stale or result.get("status", "") == "stale":
            return {
                "status": "stale",
                "stale": true,
                "scene_tree": {},
                "message": "Game session is no longer active. The returned scene tree may be cached data from a previous session.",
                "node_count": 0
            }

    return result
```

---

## Phase 4：低优先级 + 文档完善

### Task 4.1: connect_signal 全参数验证

- **审计条目：** P3 Bug — connect_signal 参数验证提示不完整
- **复杂度：** 极小（1 步）

**文件：**
- 修改：`addons/godot_mcp/tools/node_tools_native.gd`

**修改内容：**

在 `_tool_connect_signal` 中一次性收集所有缺失参数：

```gdscript
func _tool_connect_signal(params: Dictionary) -> Dictionary:
    # === 改为一次性收集所有缺失参数 ===
    var missing_params: Array[String] = []
    if not params.has("emitter_path") or params.get("emitter_path", "").is_empty():
        missing_params.append("emitter_path")
    if not params.has("signal_name") or params.get("signal_name", "").is_empty():
        missing_params.append("signal_name")
    if not params.has("receiver_path") or params.get("receiver_path", "").is_empty():
        missing_params.append("receiver_path")
    if not params.has("receiver_method") or params.get("receiver_method", "").is_empty():
        missing_params.append("receiver_method")

    if missing_params.size() > 0:
        return {"error": "Missing required parameters: " + ", ".join(missing_params)}
    # === 修改结束 ===

    # ... 继续执行 ...
```

---

### Task 4.2: 文档更新

- **审计条目：** 全部 — 修复和增强后需要更新文档
- **复杂度：** 小

**文件：**
- 修改：`docs/current/tools-reference.md`
- 修改：`addons/godot_mcp/README.md` 和 `README.zh.md`

**内容：**
1. `save_scene` — 更新文档说明新增的 `operation` 返回值字段
2. `open_scene` — 更新文档说明 `warnings` 返回值和验证建议
3. `create_node` — 更新文档说明 `on_name_conflict` 参数
4. `assert_runtime_condition` — 更新文档说明 `expected` 和 `operator` 参数
5. `await_scene_ready` — 新增工具条目，说明用法和返回值
6. `stop_project` — 更新文档说明进程退出等待行为
7. `simulate_runtime_input_event` — 更新 position 问题的已知局限

---

## 实施路线图

| Phase | 任务 | 优先级 | 估计步数 | 状态 | 影响工具计数 |
|-------|------|--------|---------|------|------------|
| 0.1 | ~~read_script C# 支持~~ | — | — | ✅ 已完成 | 不变 |
| 0.2 | ~~attach_script C# 支持~~ | — | — | ✅ 已完成 | 不变 |
| 0.3 | ~~create_script C# 模板~~ | — | — | ✅ 已完成 | 不变 |
| 0.4 | ~~list_project_scripts C# 收集~~ | — | — | ✅ 已完成 | 不变 |
| 0.5 | ~~_sanitize_cli_output 增强~~ | — | — | ✅ 已完成 | 不变 |
| 0.6 | ~~19080→9080 端口修正~~ | — | — | ✅ 已完成 | 不变 |
| 0.7 | ~~#915 append_text UI 修复~~ | 中 | 1 | ✅ 已完成 | 不变 |
| 1.1 | save_scene 增加 scene_path | 高 | 3 | 🔜 待实施 | 不变 |
| 1.2 | open_scene 增加错误检测 | 高 | 2 | 🔜 待实施 | 不变 |
| 1.3 | create_node 增加 name_conflict | 高 | 2 | 🔜 待实施 | 不变 |
| 1.4 | stop_project 退出等待 | 高 | 2 | 🔜 待实施 | 不变 |
| 2.1 | assert_runtime_condition 增强 | 中 | 3 | 🔜 待实施 | 不变 |
| 2.2 | await_scene_ready 新工具 | 高 | 4 | 🔜 待实施 | +1（155 → 156） |
| 2.3 | simulate_runtime_input_event 修复 | 中 | 2 | 🔜 待实施 | 不变 |
| 3.1 | batch_update 值格式统一 | 中 | 3 | 🔜 待实施 | 不变 |
| 3.2 | execute_editor_script 输出捕获 | 中 | 3 | 🔜 待实施 | 不变 |
| 3.3 | get_runtime_scene_tree stale 检测 | 中 | 1 | 🔜 待实施 | 不变 |
| 4.1 | connect_signal 全参数验证 | 低 | 1 | 🔜 待实施 | 不变 |
| 4.2 | 文档更新 | 低 | 2 | 🔜 待实施 | 不变 |

**已完成：** 7 项（含新增发现 Bug）
**待实施：** 12 项
**总计新增工具：** 1（`await_scene_ready`）
**工具总数变化：** 154 → 155

---

## 注意事项

1. **await_scene_ready** 依赖 Runtime Probe 的 `get_runtime_info` 响应。如果 probe 未安装或 game 未启动，会超时返回 timeout。
2. **open_scene 错误检测** 依赖 Godot 4.6 的编辑器日志 API。如果无法直接读取日志，需要回退到文档提示方案。
3. **execute_editor_script 输出捕获** 同样受限于 Godot 4.6 的编辑器 API 边界。需要先验证 API 可行性。
4. **simulate_runtime_input_event** 的 position 修复需要在 Runtime Probe（`mcp_runtime_probe.gd`）中定位具体代码，该文件较大（约 2500+ 行），需要仔细查找。
5. 所有修改完成后，运行 `test/unit/` 全量 GUT 测试，确保 0 failure。
6. 如果新增工具（`await_scene_ready`），需要更新 `test_mcp_tool_classifier.gd` 中的工具计数。

---

## 不在此计划中的项目

以下审计条目不在此计划范围内，原因如下：

| 审计条目 | 原因 |
|---------|------|
| P0 断连恢复 | MCP 服务器运行在 Godot 进程内。Godot 被杀死则 MCP 消失。这是架构限制，重连逻辑在客户端侧（Reasonix/MCP client）。 |
| L1 C# 表达式不支持 | Godot `Expression` 类的本质限制，无法绕过。已在 `C# 对象属性运行时读取` 的需求中探讨过替代方案。 |
| L1 batch_update Resource 类型 | Godot Resource 对象需要通过 `new()` 构造，无法通过 set() 直接赋值 dict。已有替代方案（execute_editor_script）。 |
| L2 inspect_runtime_node script=null | 这是 Godot 4 .NET 对动态创建节点的 script 属性处理方式问题，非插件 bug。 |
| L3 场景加载时序 | 由 `await_scene_ready`（Task 2.2）解决。 |
| L3 get_debug_output 跨 session | 需要更复杂的 buffer 管理机制，目前有 sequence 号对比的规避方案。 |
| 3rd party context7 断连 | 非本 MCP 工具问题。 |

---

*本文档基于 `docs/architecture/mcp-audit-optimization-plan.md` 中的审计分析整理。*
