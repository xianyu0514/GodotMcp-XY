# Godot MCP 工具限制与问题报告

> 基于货拉拉模拟器MVP项目实施过程中发现的问题，记录于 2026-05-15
> 修复状态更新于 2026-05-15

---

## P0 — 严重阻塞

### 1. `execute_editor_script` 缩进Bug ✅ 已修复

**现象**：任何包含缩进块（`if`/`for`/`while`/`func`）的多行代码都无法编译，报错：

```
Script compilation failed. Check syntax.
```

**根因**：传入的代码中缩进空格未被正确转换为GDScript所需的制表符（`\t`）。单行简单语句（如 `print("test")`）可以执行，但只要涉及缩进块就失败。

**影响**：无法通过MCP执行任何复杂的编辑器操作，如：
- 创建Shape/Mesh资源并赋值给节点
- 实例化子场景到当前场景
- 批量设置复杂属性
- 任何需要条件判断或循环的逻辑

**修复方案**：在 `_normalize_indentation()` 之后新增 `_spaces_to_tabs()` 函数，将行首连续空格按 4空格=1tab 规则自动转换为制表符。

**修复代码**：`addons/godot_mcp/tools/debug_tools_native.gd:3272-3292`
- 新增 `_spaces_to_tabs(code: String) -> String` 函数
- 在 `execute_editor_script` 流程中调用：`_normalize_indentation(code)` → `_spaces_to_tabs(normalized_code)`
- 更新错误消息，去掉误导性的 tab 提示

**修复后行为**：以下代码现在可以正常执行：
```python
# 以下代码现在可成功执行（空格缩进自动转换）：
var r = edited_scene
if r:
    _custom_print(r.name)
    for child in r.get_children():
        _custom_print(child.name)
```

---

### 2. `update_node_property` 无法设置 Resource 类型属性 ✅ 已修复

**现象**：尝试设置 `shape`（BoxShape3D）、`mesh`（BoxMesh）、`material`（StandardMaterial3D）等 Resource 类型属性时，传入的字符串路径被当作纯字符串值而非资源引用，最终赋值为 null。

**修复前尝试的方式及结果**：

| 传入值 | 修复前结果 | 修复后结果 |
|--------|-----------|-----------|
| `"res://assets/truck_collision.tres"` | null（当作字符串） | `load()` 加载资源后赋值 |
| `"BoxShape3D"` | null（当作字符串） | `ClassDB.instantiate()` 创建实例后赋值 |
| `{"x":2.5,"y":2,"z":6}` | 不适用于 Resource 类型 | 不适用于 Resource 类型 |

**修复方案**：在 `_convert_value_for_property()` 中新增 `TYPE_OBJECT` 分支：
- 当属性类型是 Resource 且 value 是 `res://` 路径字符串时，自动调用 `load()` 加载资源后赋值
- 当 value 是已注册的 Resource 类名（如 `"BoxShape3D"`）时，自动调用 `ClassDB.instantiate()` 创建实例后赋值

**修复代码**：`addons/godot_mcp/tools/node_tools_native.gd:1035-1042`

---

## P1 — 功能受限

### 3. `create_resource` 的 properties 参数未生效 ✅ 已修复

**现象**：通过 `properties` 参数传入的属性值未被正确应用到创建的资源中。

**示例**：

```json
{
  "resource_type": "BoxShape3D",
  "resource_path": "res://assets/truck_collision.tres",
  "properties": {
    "size": {"x": 2.5, "y": 2.0, "z": 6.0}
  }
}
```

**修复前结果**：创建的 .tres 文件中 `size = Vector3(0, 0, 0)`，均为默认值。

**修复方案**：新增 `_convert_value_for_resource()` 函数，复用与 `_convert_value_for_property()` 相同的类型转换逻辑，支持：
- `Vector2`/`Vector3`：从 Dictionary 或字符串转换
- `Color`：从 Dictionary 或 `"#hex"` 字符串转换
- `bool`/`int`/`float`：字符串自动转换
- `Resource`：`res://` 路径 → `load()`，类名 → `ClassDB.instantiate()`

**修复代码**：`addons/godot_mcp/tools/project_tools_native.gd:1412-1466`

**修复后结果**：上述示例现在正确创建 `size = Vector3(2.5, 2, 6)` 的 BoxShape3D 资源。

---

### 4. `update_node_property` 无法设置 NodePath / NodeReference 类型属性 ✅ 已修复

**现象**：尝试设置 export 的 Node 引用变量（如 `pickup_point: Area3D`）时，传入字符串路径不会被转换为 NodePath，属性值仍为 null。

**修复前尝试的方式**：

| 传入值 | 修复前结果 | 修复后结果 |
|--------|-----------|-----------|
| `"../PickupPoint"` | null | NodePath("../PickupPoint") |
| `"PickupPoint"` | null | NodePath("PickupPoint") |

**修复方案**：在 `_convert_value_for_property()` 中新增 `TYPE_NODE_PATH` 分支，当属性类型是 NodePath 且 value 是字符串时，自动调用 `NodePath(value)` 转换后赋值。

**修复代码**：`addons/godot_mcp/tools/node_tools_native.gd:1032-1034`

---

## P2 — 体验问题

### 5. `validate_script` 的 content 参数缩进问题 ✅ 已修复

**现象**：通过 `content` 参数直接传入脚本文本验证时，总是报语法错误（`"Script has syntax errors"` at line 0），即使内容完全正确。

**根因**：与 `execute_editor_script` 同样的缩进转换问题——空格未被识别为有效缩进。

**修复方案**：复用 `_spaces_to_tabs()` 函数，在 `_tool_validate_script()` 中对 `content` 参数进行缩进转换。

**修复代码**：`addons/godot_mcp/tools/script_tools_native.gd:2033-2053`（`_spaces_to_tabs` 函数）+ 第1947-1948行（调用处）

**修复后行为**：使用空格缩进的脚本内容现在可以正常验证。

---

### 6. `add_resource` 节点命名不稳定 ✅ 已修复

**现象**：使用 `add_resource` 创建子节点时，如果不提供 `resource_name`，或提供的名称与同层级已有名称冲突，Godot 会生成 `@TypeName@数字` 格式的临时名（如 `@CollisionShape3D@21725`）。

**修复方案**：
- 当 `resource_name` 为空时，使用 `resource_type` 作为节点名称（如 `"CollisionShape3D"`）
- 当名称与同级已有子节点冲突时，自动添加数字后缀（如 `"CollisionShape3D2"`、`"CollisionShape3D3"`）

**修复代码**：`addons/godot_mcp/tools/node_tools_native.gd:1533-1541`

---

### 7. `connect_signal` 持久化与脚本内 connect 的冲突 ✅ 已缓解

**现象**：MCP 的 `connect_signal` 使用 `CONNECT_PERSIST` 标志（flags=2）将连接保存到场景文件中。但如果脚本 `_ready()` 中也有 `signal.connect()` 代码，运行时会导致**重复连接**，信号回调被触发两次。

**修复方案**：当 `flags` 包含 `CONNECT_PERSIST` 标志时，在返回结果中添加 `warning` 字段提示用户注意重复连接风险。

**修复代码**：`addons/godot_mcp/tools/node_tools_native.gd:1734-1735`

**返回示例**：
```json
{
  "status": "success",
  "emitter": "/root/Scene/Button",
  "signal": "pressed",
  "receiver": "/root/Scene/Handler",
  "method": "_on_button_pressed",
  "warning": "PERSIST flag is set. If the receiver script also connects this signal in _ready(), it will fire twice at runtime."
}
```

---

## 附录：修复前后受限制操作对比

修复前以下操作**无法仅通过MCP完成**，修复后大部分已可用：

| 操作 | 修复前 | 修复后 |
|------|--------|--------|
| 设置 CollisionShape3D.shape | ❌ 无法赋值 Resource | ✅ 传 `"BoxShape3D"` 自动实例化 |
| 设置 MeshInstance3D.mesh | ❌ 无法赋值 Resource | ✅ 传 `"BoxMesh"` 自动实例化 |
| 设置 MeshInstance3D.material_override | ❌ 无法赋值 Resource | ✅ 传 `"StandardMaterial3D"` 或 `res://` 路径 |
| 使用 execute_editor_script 执行复杂代码 | ❌ 缩进报错 | ✅ 空格自动转 tab |
| 使用 validate_script 验证 content | ❌ 缩进报错 | ✅ 空格自动转 tab |
| 创建带属性的 .tres 资源 | ❌ properties 被忽略 | ✅ 类型转换后正确设置 |
| 设置 NodePath 属性 | ❌ 字符串不转换 | ✅ 自动转 NodePath |
| add_resource 批量创建节点 | ❌ 名称不可预测 | ✅ 自动命名+冲突后缀 |
| 设置 Environment 到 WorldEnvironment | ❌ 无法赋值 Resource | ✅ 传 `res://` 路径 |

仍需替代方式的操作：
1. **实例化 .tscn 子场景到当前场景** — 需要 `load().instantiate()` 逻辑（可通过 `execute_editor_script` 实现）
2. **批量创建带完整资源的节点树** — 现在可通过 `execute_editor_script` 中的循环+条件实现

替代方式：
- `execute_editor_script` 执行复杂编辑器操作（现已修复缩进问题）
- 直接编辑 .tscn 场景文件添加 `sub_resource` 或 `ext_resource` 引用
- 在 GDScript 中用 `@tool` 标记 + `_ready()` 动态创建
