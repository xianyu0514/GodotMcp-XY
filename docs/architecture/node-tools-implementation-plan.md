# 节点工具增强实现计划

> 基于 Godot 4.x 最新 API 文档，实现 10 个缺失的节点工具。

---

## 1. duplicate_node - 复制节点及子节点

### Godot 4.x API
```gdscript
func duplicate(flags: int = 15) -> Node
```

### 实现方案

```gdscript
## duplicate_node - 复制节点及子节点
## MCP Tool: duplicate_node
func _duplicate_node(params: Dictionary) -> Dictionary:
    """
    复制指定节点及其所有子节点
    
    Parameters:
        - node_path: String - 节点路径（相对于当前场景根节点）
        - flags: int - 复制标志（默认 15 = DUPLICATE_DEFAULT）
        - add_to_scene: bool - 是否自动添加到场景树（默认 false）
    
    Returns:
        - new_node_path: String - 新节点的路径
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var flags: int = params.get("flags", 15)  # DUPLICATE_DEFAULT
    var add_to_scene: bool = params.get("add_to_scene", false)
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    # 执行复制
    var new_node: Node = target_node.duplicate(flags)
    if not new_node:
        return {"error": "Failed to duplicate node", "success": false}
    
    # 可选：添加到场景树
    if add_to_scene:
        var parent: Node = target_node.get_parent()
        if parent:
            parent.add_child(new_node)
            # 确保节点名唯一
            var base_name: String = target_node.name
            var counter: int = 1
            while parent.has_node(new_node.name):
                new_node.name = base_name + "_" + str(counter)
                counter += 1
    
    return {
        "new_node_path": new_node.get_path(),
        "new_node_name": new_node.name,
        "success": true
    }
```

### 复制标志说明（DuplicateFlags）

| 标志 | 值 | 说明 |
|------|-----|------|
| `DUPLICATE_SCRIPTS` | 0x1 | 复制脚本 |
| `DUPLICATE_SIGNALS` | 0x2 | 复制信号连接 |
| `DUPLICATE_GROUPS` | 0x4 | 复制组成员关系 |
| `DUPLICATE_INTERNAL_STATE` | 0x8 | 复制内部状态（非导出变量） |
| `DUPLICATE_DEFAULT` | 0xF | 默认标志（所有上述标志） |

### 使用示例

```gdscript
# 基本复制
duplicate_node({"node_path": "Player"})
# 返回: { "new_node_path": "Node2D/Player2", "success": true }

# 复制并添加到场景
duplicate_node({"node_path": "Enemy", "add_to_scene": true})

# 仅复制属性（不复制脚本和信号）
duplicate_node({"node_path": "UI", "flags": 0})
```

---

## 2. move_node - 移动/重新设置父节点

### Godot 4.x API

```gdscript
# 方法 1: reparent（推荐）
func reparent(new_parent: Node, keep_global_transform: bool = true) -> void

# 方法 2: remove_child + add_child
func remove_child(node: Node) -> void
func add_child(node: Node, force_readable_name: bool = false, internal: int = 0) -> void
```

### 实现方案

```gdscript
## move_node - 移动节点到新父节点
## MCP Tool: move_node
func _move_node(params: Dictionary) -> Dictionary:
    """
    将节点移动到新父节点下
    
    Parameters:
        - node_path: String - 要移动的节点路径
        - new_parent_path: String - 新父节点路径
        - keep_global_transform: bool - 是否保持全局变换（默认 true）
        - position_index: int - 在新父节点中的位置索引（可选）
    
    Returns:
        - new_path: String - 移动后的节点路径
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var new_parent_path: String = params.get("new_parent_path", "")
    var keep_global_transform: bool = params.get("keep_global_transform", true)
    var position_index: int = params.get("position_index", -1)
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    var new_parent: Node = scene_root.get_node_or_null(new_parent_path)
    if not new_parent:
        return {"error": "New parent not found: " + new_parent_path, "success": false}
    
    # 检查不能移动到自己或子节点
    if target_node.is_ancestor_of(new_parent):
        return {"error": "Cannot move node to its own descendant", "success": false}
    
    # 使用 reparent 方法（更安全，保持变换）
    if keep_global_transform:
        target_node.reparent(new_parent, true)
    else:
        # 手动移动：先移除再添加
        var old_parent: Node = target_node.get_parent()
        if old_parent:
            old_parent.remove_child(target_node)
        new_parent.add_child(target_node)
    
    # 设置位置索引
    if position_index >= 0 and position_index < new_parent.get_child_count():
        new_parent.move_child(target_node, position_index)
    
    return {
        "new_path": target_node.get_path(),
        "new_parent": new_parent_path,
        "success": true
    }
```

### 使用示例

```gdscript
# 移动节点到新父节点（保持全局位置）
move_node({
    "node_path": "UI/Panel",
    "new_parent_path": "Main/Containers"
})

# 移动并改变位置
move_node({
    "node_path": "Enemy1",
    "new_parent_path": "Enemies",
    "position_index": 0
})

# 移动但不保持全局变换
move_node({
    "node_path": "Player",
    "new_parent_path": "Level1/Characters",
    "keep_global_transform": false
})
```

---

## 3. rename_node - 重命名场景中的节点

### Godot 4.x API

```gdscript
# 直接设置 name 属性
node.name = "NewName"

# 或使用 set_name（返回错误码）
func set_name(name: StringName) -> Error
```

### 实现方案

```gdscript
## rename_node - 重命名节点
## MCP Tool: rename_node
func _rename_node(params: Dictionary) -> Dictionary:
    """
    重命名场景中的节点
    
    Parameters:
        - node_path: String - 节点路径
        - new_name: String - 新名称
    
    Returns:
        - old_name: String - 原名称
        - new_name: String - 新名称
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var new_name: String = params.get("new_name", "")
    
    if new_name.is_empty():
        return {"error": "New name cannot be empty", "success": false}
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    var old_name: String = target_node.name
    
    # 检查名称是否已被同一父节点的子节点使用
    var parent: Node = target_node.get_parent()
    if parent and parent.has_node(new_name) and new_name != old_name:
        return {"error": "Name '" + new_name + "' already exists in parent", "success": false}
    
    # 重命名
    target_node.name = new_name
    
    return {
        "old_name": old_name,
        "new_name": new_name,
        "node_path": target_node.get_path(),
        "success": true
    }
```

### 使用示例

```gdscript
# 基本重命名
rename_node({
    "node_path": "Node2D/Player",
    "new_name": "Hero"
})

# 批量重命名（添加前缀）
rename_node({
    "node_path": "Enemies/Enemy1",
    "new_name": "Goblin_01"
})
```

---

## 4. add_resource - 向节点添加资源（Shape/Material 等）

### Godot 4.x API

```gdscript
# 添加子节点（资源通常作为子节点，如 CollisionShape3D）
func add_child(node: Node, force_readable_name: bool = false, internal: int = 0) -> void

# 设置节点属性（资源作为属性值）
func set(property: StringName, value: Variant) -> void
```

### 实现方案

```gdscript
## add_resource - 向节点添加资源
## MCP Tool: add_resource
func _add_resource(params: Dictionary) -> Dictionary:
    """
    向节点添加资源（形状、材质、动画等）
    
    Parameters:
        - node_path: String - 目标节点路径
        - resource_type: String - 资源类型（"CollisionShape2D", "CollisionShape3D", 
                                   "MeshInstance3D", "Sprite2D", 等）
        - resource_params: Dictionary - 资源参数
            - shape: String - 形状资源路径（可选）
            - mesh: String - 网格资源路径（可选）
            - texture: String - 纹理资源路径（可选）
            - set_property: String - 要设置的属性名（可选）
            - property_value: Variant - 属性值（可选）
    
    Returns:
        - resource_node_path: String - 添加的资源节点路径
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var resource_type: String = params.get("resource_type", "")
    var resource_params: Dictionary = params.get("resource_params", {})
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    # 创建资源节点
    var resource_node: Node = null
    
    match resource_type:
        "CollisionShape2D":
            resource_node = CollisionShape2D.new()
            if resource_params.has("shape"):
                var shape: Shape2D = load(resource_params.shape)
                if shape:
                    (resource_node as CollisionShape2D).shape = shape
        
        "CollisionShape3D":
            resource_node = CollisionShape3D.new()
            if resource_params.has("shape"):
                var shape: Shape3D = load(resource_params.shape)
                if shape:
                    (resource_node as CollisionShape3D).shape = shape
        
        "MeshInstance3D":
            resource_node = MeshInstance3D.new()
            if resource_params.has("mesh"):
                var mesh: Mesh = load(resource_params.mesh)
                if mesh:
                    (resource_node as MeshInstance3D).mesh = mesh
        
        "Sprite2D":
            resource_node = Sprite2D.new()
            if resource_params.has("texture"):
                var texture: Texture2D = load(resource_params.texture)
                if texture:
                    (resource_node as Sprite2D).texture = texture
        
        "Area2D":
            resource_node = Area2D.new()
        
        "StaticBody3D":
            resource_node = StaticBody3D.new()
        
        _:
            # 尝试实例化任意节点类型
            var class_db_exists: bool = ClassDB.class_exists(resource_type)
            if class_db_exists:
                resource_node = ClassDB.instantiate(resource_type)
            else:
                return {"error": "Unknown resource type: " + resource_type, "success": false}
    
    # 设置自定义属性
    if resource_params.has("set_property") and resource_params.has("property_value"):
        resource_node.set(
            resource_params.set_property as StringName,
            resource_params.property_value
        )
    
    # 添加到目标节点
    target_node.add_child(resource_node)
    
    return {
        "resource_node_path": resource_node.get_path(),
        "resource_node_name": resource_node.name,
        "resource_type": resource_type,
        "success": true
    }
```

### 使用示例

```gdscript
# 添加碰撞形状
add_resource({
    "node_path": "Player/Body",
    "resource_type": "CollisionShape2D",
    "resource_params": {
        "shape": "res://shapes/player_shape.tres"
    }
})

# 添加网格实例
add_resource({
    "node_path": "World/Objects",
    "resource_type": "MeshInstance3D",
    "resource_params": {
        "mesh": "res://meshes/cube.tres"
    }
})

# 添加 Area2D 并设置碰撞层
add_resource({
    "node_path": "Player",
    "resource_type": "Area2D",
    "resource_params": {
        "set_property": "collision_layer",
        "property_value": 1
    }
})
```

---

## 5. set_anchor_preset - 设置 Control 锚点预设

### Godot 4.x API

```gdscript
# 设置锚点预设
func set_anchors_preset(preset: LayoutPreset, keep_offsets: bool = false) -> void

# 设置锚点和偏移预设
func set_anchors_and_offsets_preset(
    preset: LayoutPreset,
    resize_mode: LayoutPresetMode = 0,
    margin: int = 0
) -> void
```

### LayoutPreset 枚举

| 预设 | 值 | 说明 |
|------|-----|------|
| `PRESET_TOP_LEFT` | 0 | 左上角 |
| `PRESET_TOP_RIGHT` | 1 | 右上角 |
| `PRESET_BOTTOM_LEFT` | 2 | 左下角 |
| `PRESET_BOTTOM_RIGHT` | 3 | 右下角 |
| `PRESET_CENTER_LEFT` | 4 | 左边居中 |
| `PRESET_CENTER_TOP` | 5 | 顶部居中 |
| `PRESET_CENTER_RIGHT` | 6 | 右边居中 |
| `PRESET_CENTER_BOTTOM` | 7 | 底部居中 |
| `PRESET_CENTER` | 8 | 完全居中 |
| `PRESET_LEFT_WIDE` | 9 | 左侧宽 |
| `PRESET_TOP_WIDE` | 10 | 顶部宽 |
| `PRESET_RIGHT_WIDE` | 11 | 右侧宽 |
| `PRESET_BOTTOM_WIDE` | 12 | 底部宽 |
| `PRESET_VCENTER_WIDE` | 13 | 垂直居中宽 |
| `PRESET_HCENTER_WIDE` | 14 | 水平居中宽 |
| `PRESET_FULL_RECT` | 15 | 填满父节点 |

### 实现方案

```gdscript
## set_anchor_preset - 设置 Control 节点锚点预设
## MCP Tool: set_anchor_preset
func _set_anchor_preset(params: Dictionary) -> Dictionary:
    """
    设置 Control 节点的锚点预设
    
    Parameters:
        - node_path: String - Control 节点路径
        - preset: int - LayoutPreset 枚举值（0-15）
        - keep_offsets: bool - 是否保持当前偏移（默认 false）
        - margin: int - 边距（可选，用于 set_anchors_and_offsets_preset）
        - use_full_method: bool - 是否使用 set_anchors_and_offsets_preset（默认 false）
    
    Returns:
        - preset_name: String - 预设名称
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var preset: int = params.get("preset", 0)
    var keep_offsets: bool = params.get("keep_offsets", false)
    var margin: int = params.get("margin", 0)
    var use_full_method: bool = params.get("use_full_method", false)
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    # 检查是否为 Control 节点
    if not target_node is Control:
        return {"error": "Node is not a Control: " + node_path, "success": false}
    
    var control: Control = target_node as Control
    
    # 预设名称映射
    var preset_names: Dictionary = {
        0: "TOP_LEFT", 1: "TOP_RIGHT", 2: "BOTTOM_LEFT", 3: "BOTTOM_RIGHT",
        4: "CENTER_LEFT", 5: "CENTER_TOP", 6: "CENTER_RIGHT", 7: "CENTER_BOTTOM",
        8: "CENTER", 9: "LEFT_WIDE", 10: "TOP_WIDE", 11: "RIGHT_WIDE",
        12: "BOTTOM_WIDE", 13: "VCENTER_WIDE", 14: "HCENTER_WIDE", 15: "FULL_RECT"
    }
    
    # 执行预设设置
    if use_full_method:
        control.set_anchors_and_offsets_preset(preset, 0, margin)
    else:
        control.set_anchors_preset(preset, keep_offsets)
    
    return {
        "preset_name": preset_names.get(preset, "UNKNOWN"),
        "preset_value": preset,
        "success": true
    }
```

### 使用示例

```gdscript
# 居中显示
set_anchor_preset({
    "node_path": "UI/Panel",
    "preset": 8  # CENTER
})

# 填满父节点
set_anchor_preset({
    "node_path": "UI/Background",
    "preset": 15,  # FULL_RECT
    "use_full_method": true
})

# 顶部宽（如顶部栏）
set_anchor_preset({
    "node_path": "UI/TopBar",
    "preset": 10  # TOP_WIDE
})
```

---

## 6. connect_signal - 连接节点间的信号

### Godot 4.x API

```gdscript
# 使用 connect 方法（推荐）
signal.connect(callable, flags: int = 0) -> void

# 或使用 add_to_group 风格的连接
func connect(signal: Signal, callable: Callable, flags: int = 0) -> Error

# 连接标志
CONNECT_DEFERRED = 1    # 延迟调用
CONNECT_PERSIST = 2     # 持久连接
CONNECT_ONE_SHOT = 4    # 一次性连接
```

### 实现方案

```gdscript
## connect_signal - 连接节点信号
## MCP Tool: connect_signal
func _connect_signal(params: Dictionary) -> Dictionary:
    """
    连接信号到接收方法
    
    Parameters:
        - emitter_path: String - 发射信号的节点路径
        - signal_name: String - 信号名称
        - receiver_path: String - 接收方法的节点路径
        - receiver_method: String - 接收方法名
        - flags: int - 连接标志（默认 0）
        - bound_args: Array - 绑定参数（可选）
    
    Returns:
        - connection_id: String - 连接标识
        - success: bool
    """
    var emitter_path: String = params.get("emitter_path", "")
    var signal_name: String = params.get("signal_name", "")
    var receiver_path: String = params.get("receiver_path", "")
    var receiver_method: String = params.get("receiver_method", "")
    var flags: int = params.get("flags", 0)
    var bound_args: Array = params.get("bound_args", [])
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var emitter: Node = scene_root.get_node_or_null(emitter_path)
    if not emitter:
        return {"error": "Emitter not found: " + emitter_path, "success": false}
    
    var receiver: Node = scene_root.get_node_or_null(receiver_path)
    if not receiver:
        return {"error": "Receiver not found: " + receiver_path, "success": false}
    
    # 获取信号
    var signals: Array = emitter.get_signal_list()
    var target_signal: Dictionary = {}
    for sig in signals:
        if sig.name == signal_name:
            target_signal = sig
            break
    
    if target_signal.is_empty():
        return {"error": "Signal '" + signal_name + "' not found on " + emitter_path, "success": false}
    
    # 创建 Callable
    var callable: Callable
    if receiver.has_method(receiver_method):
        callable = Callable(receiver, receiver_method)
    else:
        return {"error": "Method '" + receiver_method + "' not found on " + receiver_path, "success": false}
    
    # 绑定参数
    if not bound_args.is_empty():
        for arg in bound_args:
            callable = callable.bind(arg)
    
    # 连接信号
    emitter.connect(signal_name, callable, flags)
    
    return {
        "emitter": emitter_path,
        "signal": signal_name,
        "receiver": receiver_path,
        "method": receiver_method,
        "flags": flags,
        "success": true
    }
```

### 使用示例

```gdscript
# 连接按钮点击信号
connect_signal({
    "emitter_path": "UI/StartButton",
    "signal_name": "pressed",
    "receiver_path": "Game",
    "receiver_method": "_on_start_button_pressed"
})

# 连接带绑定参数的信号
connect_signal({
    "emitter_path": "UI/LevelSelect/Button1",
    "signal_name": "pressed",
    "receiver_path": "GameManager",
    "receiver_method": "load_level",
    "bound_args": [1]
})

# 一次性连接
connect_signal({
    "emitter_path": "Player",
    "signal_name": "health_changed",
    "receiver_path": "UI/HealthBar",
    "receiver_method": "update",
    "flags": 2  # CONNECT_ONE_SHOT
})
```

---

## 7. disconnect_signal - 断开信号连接

### Godot 4.x API

```gdscript
# 断开信号连接
signal.disconnect(callable: Callable) -> void

# 检查是否已连接
signal.is_connected(callable: Callable) -> bool

# 或使用 disconnect 方法
func disconnect(signal: StringName, callable: Callable) -> Error
```

### 实现方案

```gdscript
## disconnect_signal - 断开信号连接
## MCP Tool: disconnect_signal
func _disconnect_signal(params: Dictionary) -> Dictionary:
    """
    断开信号连接
    
    Parameters:
        - emitter_path: String - 发射信号的节点路径
        - signal_name: String - 信号名称
        - receiver_path: String - 接收方法的节点路径
        - receiver_method: String - 接收方法名
    
    Returns:
        - disconnected: bool - 是否成功断开
        - success: bool
    """
    var emitter_path: String = params.get("emitter_path", "")
    var signal_name: String = params.get("signal_name", "")
    var receiver_path: String = params.get("receiver_path", "")
    var receiver_method: String = params.get("receiver_method", "")
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var emitter: Node = scene_root.get_node_or_null(emitter_path)
    if not emitter:
        return {"error": "Emitter not found: " + emitter_path, "success": false}
    
    var receiver: Node = scene_root.get_node_or_null(receiver_path)
    if not receiver:
        return {"error": "Receiver not found: " + receiver_path, "success": false}
    
    # 创建 Callable
    var callable: Callable = Callable(receiver, receiver_method)
    
    # 检查是否已连接
    if not emitter.is_connected(signal_name, callable):
        return {
            "emitter": emitter_path,
            "signal": signal_name,
            "receiver": receiver_path,
            "method": receiver_method,
            "disconnected": false,
            "message": "Connection does not exist",
            "success": true
        }
    
    # 断开连接
    emitter.disconnect(signal_name, callable)
    
    return {
        "emitter": emitter_path,
        "signal": signal_name,
        "receiver": receiver_path,
        "method": receiver_method,
        "disconnected": true,
        "success": true
    }
```

### 使用示例

```gdscript
# 断开按钮连接
disconnect_signal({
    "emitter_path": "UI/StartButton",
    "signal_name": "pressed",
    "receiver_path": "Game",
    "receiver_method": "_on_start_button_pressed"
})
```

---

## 8. get_node_groups - 获取节点所属的组

### Godot 4.x API

```gdscript
# 获取节点所属的所有组
func get_groups() -> Array[StringName]
```

### 实现方案

```gdscript
## get_node_groups - 获取节点的组成员关系
## MCP Tool: get_node_groups
func _get_node_groups(params: Dictionary) -> Dictionary:
    """
    获取节点所属的所有组
    
    Parameters:
        - node_path: String - 节点路径
    
    Returns:
        - groups: Array - 组名列表
        - group_count: int - 组数量
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    var groups: Array[StringName] = target_node.get_groups()
    var groups_array: Array = []
    for group in groups:
        groups_array.append(str(group))
    
    return {
        "node_path": node_path,
        "node_name": target_node.name,
        "groups": groups_array,
        "group_count": groups_array.size(),
        "success": true
    }
```

### 使用示例

```gdscript
# 获取玩家所属的组
get_node_groups({
    "node_path": "Player"
})
# 返回: { "groups": ["player", "character", "interactive"], "group_count": 3 }
```

---

## 9. set_node_groups - 设置节点的组成员关系

### Godot 4.x API

```gdscript
# 添加到组
func add_to_group(group: StringName, persistent: bool = false) -> void

# 从组移除
func remove_from_group(group: StringName) -> void

# 检查是否在组中
func is_in_group(group: StringName) -> bool
```

### 实现方案

```gdscript
## set_node_groups - 设置节点的组成员关系
## MCP Tool: set_node_groups
func _set_node_groups(params: Dictionary) -> Dictionary:
    """
    设置节点的组成员关系
    
    Parameters:
        - node_path: String - 节点路径
        - groups: Array - 要添加的组名列表
        - remove_groups: Array - 要移除的组名列表（可选）
        - persistent: bool - 是否持久化（默认 false）
        - clear_existing: bool - 是否先清除所有现有组（默认 false）
    
    Returns:
        - added_groups: Array - 已添加的组
        - removed_groups: Array - 已移除的组
        - current_groups: Array - 当前所有组
        - success: bool
    """
    var node_path: String = params.get("node_path", "")
    var groups: Array = params.get("groups", [])
    var remove_groups: Array = params.get("remove_groups", [])
    var persistent: bool = params.get("persistent", false)
    var clear_existing: bool = params.get("clear_existing", false)
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    var target_node: Node = scene_root.get_node_or_null(node_path)
    if not target_node:
        return {"error": "Node not found: " + node_path, "success": false}
    
    var added_groups: Array = []
    var removed_groups: Array = []
    
    # 清除现有组
    if clear_existing:
        var current_groups: Array[StringName] = target_node.get_groups()
        for group in current_groups:
            target_node.remove_from_group(group)
            removed_groups.append(str(group))
    
    # 移除指定组
    for group_name in remove_groups:
        if target_node.is_in_group(group_name):
            target_node.remove_from_group(group_name)
            removed_groups.append(group_name)
    
    # 添加指定组
    for group_name in groups:
        if not target_node.is_in_group(group_name):
            target_node.add_to_group(group_name, persistent)
            added_groups.append(group_name)
    
    # 获取当前所有组
    var current_groups: Array[StringName] = target_node.get_groups()
    var current_groups_array: Array = []
    for group in current_groups:
        current_groups_array.append(str(group))
    
    return {
        "node_path": node_path,
        "added_groups": added_groups,
        "removed_groups": removed_groups,
        "current_groups": current_groups_array,
        "success": true
    }
```

### 使用示例

```gdscript
# 添加节点到多个组
set_node_groups({
    "node_path": "Player",
    "groups": ["player", "character", "interactive"]
})

# 替换所有组
set_node_groups({
    "node_path": "Enemy",
    "groups": ["enemy", "targetable"],
    "clear_existing": true
})

# 移除特定组
set_node_groups({
    "node_path": "Player",
    "remove_groups": ["temporary"]
})

# 持久化组（保存到场景）
set_node_groups({
    "node_path": "Player",
    "groups": ["saveable"],
    "persistent": true
})
```

---

## 10. find_nodes_in_group - 查找组中的所有节点

### Godot 4.x API

```gdscript
# 通过 SceneTree 获取组中所有节点
func get_tree() -> SceneTree
func SceneTree.get_nodes_in_group(group: StringName) -> Array[Node]
```

### 实现方案

```gdscript
## find_nodes_in_group - 查找组中的所有节点
## MCP Tool: find_nodes_in_group
func _find_nodes_in_group(params: Dictionary) -> Dictionary:
    """
    查找组中的所有节点
    
    Parameters:
        - group: String - 组名
        - node_type: String - 节点类型过滤（可选，如 "Node2D", "Control"）
        - include_paths: bool - 是否包含节点路径（默认 true）
    
    Returns:
        - nodes: Array - 节点信息列表
        - node_count: int - 节点数量
        - success: bool
    """
    var group: String = params.get("group", "")
    var node_type: String = params.get("node_type", "")
    var include_paths: bool = params.get("include_paths", true)
    
    if group.is_empty():
        return {"error": "Group name cannot be empty", "success": false}
    
    var scene_root: Node = _editor_interface.get_edited_scene_root()
    if not scene_root:
        return {"error": "No scene root", "success": false}
    
    # 获取组中所有节点
    var nodes_array: Array[Node] = scene_root.get_tree().get_nodes_in_group(group)
    
    var result_nodes: Array = []
    for node in nodes_array:
        var node_info: Dictionary = {
            "name": node.name,
            "type": node.get_class()
        }
        
        # 类型过滤
        if not node_type.is_empty() and node.get_class() != node_type:
            continue
        
        if include_paths:
            node_info["path"] = str(node.get_path())
        
        result_nodes.append(node_info)
    
    return {
        "group": group,
        "nodes": result_nodes,
        "node_count": result_nodes.size(),
        "success": true
    }
```

### 使用示例

```gdscript
# 查找所有敌人
find_nodes_in_group({
    "group": "enemy"
})
# 返回: { "nodes": [{ "name": "Enemy1", "type": "CharacterBody2D", "path": "..." }, ...] }

# 查找所有可交互节点
find_nodes_in_group({
    "group": "interactive"
})

# 仅查找 Control 类型的节点
find_nodes_in_group({
    "group": "ui_elements",
    "node_type": "Control"
})

# 不包含路径
find_nodes_in_group({
    "group": "player",
    "include_paths": false
})
```

---

## 实现文件结构

```
addons/godot_mcp/tools/
└── node_tools_native.gd  # 扩展现有文件

新增工具方法注册：
```

### 在 `node_tools_native.gd` 中添加

```gdscript
# ===========================================
# 节点工具增强 - 新增方法
# ===========================================

## 复制节点
func _node_duplicate(params: Dictionary) -> Dictionary:
    return duplicate_node(params)

## 移动节点
func _node_move(params: Dictionary) -> Dictionary:
    return move_node(params)

## 重命名节点
func _node_rename(params: Dictionary) -> Dictionary:
    return rename_node(params)

## 添加资源
func _node_add_resource(params: Dictionary) -> Dictionary:
    return add_resource(params)

## 设置锚点预设
func _control_set_anchor_preset(params: Dictionary) -> Dictionary:
    return set_anchor_preset(params)

## 连接信号
func _node_connect_signal(params: Dictionary) -> Dictionary:
    return connect_signal(params)

## 断开信号
func _node_disconnect_signal(params: Dictionary) -> Dictionary:
    return disconnect_signal(params)

## 获取节点组
func _node_get_groups(params: Dictionary) -> Dictionary:
    return get_node_groups(params)

## 设置节点组
func _node_set_groups(params: Dictionary) -> Dictionary:
    return set_node_groups(params)

## 查找组中节点
func _find_nodes_in_group(params: Dictionary) -> Dictionary:
    return find_nodes_in_group(params)

# 注册到 MCP Server
func register_tools(server_core: RefCounted) -> void:
    # ... 现有注册代码 ...
    
    # 新增工具注册
    server_core.register_tool(
        "duplicate_node",
        "Duplicate Node",
        "Duplicate a node and its children",
        Callable(self, "_node_duplicate")
    )
    
    server_core.register_tool(
        "move_node",
        "Move Node",
        "Move a node to a new parent",
        Callable(self, "_node_move")
    )
    
    server_core.register_tool(
        "rename_node",
        "Rename Node",
        "Rename a node in the scene",
        Callable(self, "_node_rename")
    )
    
    server_core.register_tool(
        "add_resource",
        "Add Resource",
        "Add a resource (shape, material, etc.) to a node",
        Callable(self, "_node_add_resource")
    )
    
    server_core.register_tool(
        "set_anchor_preset",
        "Set Anchor Preset",
        "Set anchor preset for Control nodes",
        Callable(self, "_control_set_anchor_preset")
    )
    
    server_core.register_tool(
        "connect_signal",
        "Connect Signal",
        "Connect a signal to a receiver method",
        Callable(self, "_node_connect_signal")
    )
    
    server_core.register_tool(
        "disconnect_signal",
        "Disconnect Signal",
        "Disconnect a signal connection",
        Callable(self, "_node_disconnect_signal")
    )
    
    server_core.register_tool(
        "get_node_groups",
        "Get Node Groups",
        "Get the groups a node belongs to",
        Callable(self, "_node_get_groups")
    )
    
    server_core.register_tool(
        "set_node_groups",
        "Set Node Groups",
        "Set the groups a node belongs to",
        Callable(self, "_node_set_groups")
    )
    
    server_core.register_tool(
        "find_nodes_in_group",
        "Find Nodes in Group",
        "Find all nodes in a specific group",
        Callable(self, "_find_nodes_in_group")
    )
```

---

## 实现难度评估

| 工具 | 难度 | 预估工时 | 依赖 |
|------|------|----------|------|
| `duplicate_node` | 低 | 0.5 小时 | 无 |
| `move_node` | 低 | 1 小时 | 无 |
| `rename_node` | 低 | 0.5 小时 | 无 |
| `add_resource` | 中 | 2 小时 | ClassDB |
| `set_anchor_preset` | 低 | 0.5 小时 | Control 类 |
| `connect_signal` | 中 | 1.5 小时 | Signal 系统 |
| `disconnect_signal` | 低 | 0.5 小时 | Signal 系统 |
| `get_node_groups` | 低 | 0.5 小时 | 无 |
| `set_node_groups` | 低 | 1 小时 | 无 |
| `find_nodes_in_group` | 低 | 0.5 小时 | SceneTree |

**总计预估工时：8 小时（1 个工作日）**

---

## 测试用例

```gdscript
# 测试脚本：test_node_tools.gd

func test_duplicate_node():
    var result = duplicate_node({
        "node_path": "TestNode",
        "add_to_scene": true
    })
    assert(result.success == true)
    assert(result.has("new_node_path"))

func test_move_node():
    var result = move_node({
        "node_path": "Node1/Child",
        "new_parent_path": "Node2"
    })
    assert(result.success == true)

func test_rename_node():
    var result = rename_node({
        "node_path": "OldName",
        "new_name": "NewName"
    })
    assert(result.success == true)
    assert(result.old_name == "OldName")
    assert(result.new_name == "NewName")

func test_set_anchor_preset():
    var result = set_anchor_preset({
        "node_path": "UI/Panel",
        "preset": 8  # CENTER
    })
    assert(result.success == true)
    assert(result.preset_name == "CENTER")

func test_connect_disconnect_signal():
    # 连接
    var connect_result = connect_signal({
        "emitter_path": "Button",
        "signal_name": "pressed",
        "receiver_path": "Game",
        "receiver_method": "_on_pressed"
    })
    assert(connect_result.success == true)
    
    # 断开
    var disconnect_result = disconnect_signal({
        "emitter_path": "Button",
        "signal_name": "pressed",
        "receiver_path": "Game",
        "receiver_method": "_on_pressed"
    })
    assert(disconnect_result.disconnected == true)

func test_groups():
    # 设置组
    var set_result = set_node_groups({
        "node_path": "Player",
        "groups": ["player", "character"]
    })
    assert(set_result.success == true)
    
    # 获取组
    var get_result = get_node_groups({
        "node_path": "Player"
    })
    assert(get_result.groups.has("player"))
    
    # 查找组中节点
    var find_result = find_nodes_in_group({
        "group": "player"
    })
    assert(find_result.node_count >= 1)
```

---

## 注意事项

1. **Undo/Redo 支持**：所有修改场景的操作应通过 `EditorInterface.get_editor_interface().get_editor_undo_redo_manager()` 支持撤销

2. **节点路径**：所有路径应相对于当前编辑的场景根节点

3. **名称唯一性**：添加节点时需确保名称在父节点下唯一

4. **类型检查**：`set_anchor_preset` 需检查节点是否为 `Control` 类型

5. **信号连接**：连接信号时需验证信号存在且接收方法存在

6. **组持久化**：`add_to_group` 的 `persistent` 参数控制是否保存到场景文件

---

*文档生成时间：2026-05-07*
*基于 Godot 4.x API 文档（Context7: /godotengine/godot-docs）*
