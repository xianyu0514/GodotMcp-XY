# 《货拉拉模拟器》城市场景升级 — 完整开发总结

> 更新于 2026-05-16，基于MCP源码修复后的实际验证结果

---

## 一、项目最终状态

| 指标 | 数值 |
|------|------|
| 场景节点总数 | 153 |
| GDScript文件 | 37 |
| 资源文件(.tres) | 70 |
| 项目健康审计 | 0错误 / 0警告 / 0缺失依赖 |
| 建筑数量 | 13栋 |
| 路灯数量 | 12盏 |
| 道路系统 | 十字路口(南北+东西主干道) |
| 天空 | 黄昏(ProceduralSkyMaterial) |
| 雾效 | 深度雾(暖橙色) |
| 车辆 | VehicleBody3D, engine_force=4000, mass=4000 |

---

## 二、开发过程分为两大阶段

### 阶段一：MVP基础版（38节点 → 核心循环可玩）
- 场景搭建、脚本编写、输入映射、物理调参
- 核心问题：车辆无法移动 → 修复悬挂参数和初始位置

### 阶段二：城市场景升级（38节点 → 153节点）
- 替换简陋地面为城市街区 + 黄昏光影
- 新增：地面底板、道路、路缘石(后删除)、13栋建筑、12盏路灯
- 环境：黄昏天空、夕阳光照、雾效、泛光

---

## 三、问题全记录（按分类）

### A类 — 设计/考虑不周（9个）

| # | 问题 | 阶段 | 解决办法 |
|---|------|------|----------|
| A1 | engine_force设在VehicleBody3D而非轮子上 | 1 | 改为设置到$RearLeftWheel.engine_force |
| A2 | engine_force方向符号错误(W前进实际后退) | 1 | 前进时设为-engine_force_value |
| A3 | steering输入轴方向反了 | 1 | get_axis参数对调("steer_left","steer_right") |
| A4 | Terrain用BoxShape3D而非PlaneShape3D | 1 | 保留BoxShape3D（Godot 4.6已移除PlaneShape3D，替代为WorldBoundaryShape3D） |
| A5 | UI用%UniqueName语法但节点未设置 | 1 | 改用$路径引用 |
| A6 | Truck初始位置过高(y=1.0)轮子悬空 | 1 | 降至y=0.01 |
| A7 | 车速提升后转弯翻车 | 2 | 降低重心(center_of_mass_mode=1, y=-0.8)、增大mass=4000、降低max_steering=0.35、降低wheel_roll_influence=0.05 |
| A8 | 装货/卸货点与建筑重叠 | 2 | 坐标移到道路上(避免建筑区域) |
| A9 | 路缘石导致车辆卡住 | 2 | 降低高度后仍卡，直接删除路缘石 |

### B类 — MCP工具限制/bug（9个）

| # | 问题 | 严重度 | 阶段 | 状态 | 解决办法 |
|---|------|--------|------|------|----------|
| B1 | execute_editor_script缩进Bug(多行if/for/func失败) | P0 | 1+2 | **已修复** | `_spaces_to_tabs()`修复缩进；提供`get_tree()`/`get_node()`代理方法；`func`定义提升到类级别 |
| B2 | update_node_property无法设置Resource属性 | P0→P1 | 1 | **已修复** | `TYPE_OBJECT`分支：res://→load()，类名→ClassDB.instantiate() |
| B3 | create_resource的properties参数不生效 | P1 | 1+2 | **已修复** | `_convert_value_for_resource()`类型转换 + `_parse_key_value_string()`支持`{x:...,y:...,z:...}`字符串格式 |
| B4 | upsert_project_input_action的events参数 | P1 | 1 | **已修复** | 可正确绑定按键 |
| B5 | update_node_property不支持NodePath类型 | P1 | 1 | **已修复** | `TYPE_NODE_PATH`分支：字符串→NodePath转换 |
| B6 | validate_script的content参数缩进问题 | P2 | 1 | **已修复** | 复用`_spaces_to_tabs()`转换content缩进 |
| B7 | connect_signal持久化与脚本connect冲突 | P2 | 1 | **已修复** | flags含CONNECT_PERSIST时返回warning提醒 |
| B8 | batch_scene_node_edits返回node_path为空 | P2 | 2 | **已修复** | 用parent路径+node_name拼接，不再依赖未添加节点的get_path() |
| B9 | Environment/Sky资源无法通过.tres正确保存 | 新 | 2 | **未修复** | 引擎限制，在game_manager.gd的_ready中运行时配置 |

### C类 — Godot引擎知识盲区（5个）

| # | 问题 | 阶段 | 解决办法 |
|---|------|------|----------|
| C1 | VehicleWheel3D悬挂参数过小导致车辆无法着地 | 1 | max_force=16000, travel=0.5, stiffness=40, rest_length=0.3 |
| C2 | VehicleBody3D需开启contact_monitor才能触发body_entered | 1 | 设置contact_monitor=true |
| C3 | push_warning/print不输出到编辑器面板 | 1 | 引擎架构限制（编辑器与运行时独立进程），替代：`get_editor_logs(source="runtime")` 或 UI Label可视化 |
| C4 | Environment的glow_threshold属性名不存在 | 2 | 改为glow_bloom |
| C5 | ResourceSaver保存Environment时丢失sky子对象和部分属性 | 2 | 改为运行时脚本动态配置Environment |

### D类 — 调试手段受限（2个）

| # | 问题 | 阶段 | 变通方案 |
|---|------|------|----------|
| D1 | MCP无法截取运行时游戏窗口截图 | 1 | 已有 `get_runtime_screenshot`（Runtime Probe机制）替代 |
| D2 | 运行时日志(editor_panel/runtime)无法获取push_warning输出 | 1 | `get_editor_logs(source="runtime")` 可获取运行时日志 |

---

## 四、MCP工具使用详细评估

### 4.1 工具调用统计（估算）

| 工具 | 调用次数 | 评价 |
|------|----------|------|
| create_node | ~90次 | 核心工具，稳定可靠 |
| add_resource | ~30次 | 正常，但命名不稳定 |
| update_node_property | ~20次 | 基本类型正常，Resource已修复 |
| batch_update_node_properties | ~25次 | 高效，大幅减少调用次数 |
| delete_node | ~8次 | 正常 |
| rename_node | ~4次 | 用于修正@前缀命名 |
| create_script / modify_script | ~15次 | 正常 |
| read_script / validate_script | ~15次 | script_path方式正常 |
| attach_script | ~3次 | 正常 |
| save_scene | ~15次 | 正常 |
| run_project / stop_project | ~10次 | 正常 |
| get_node_properties | ~10次 | 调试必备 |
| get_scene_structure | ~5次 | 正常 |
| create_resource | ~26次 | 创建文件+properties均生效（支持Dictionary/CSV/{x:...}格式） |
| execute_editor_script | ~30次 | 单行+多行if/for可用；func/get_tree不可用（引擎限制） |
| list_project_input_actions | ~3次 | 正常 |
| connect_signal | ~2次 | 正常(注意持久化冲突) |
| set_anchor_preset | ~2次 | 正常 |
| detect_broken_scripts / audit_project_health | ~5次 | 非常实用 |
| batch_scene_node_edits | ~3次 | node_path返回已修复，命名按node_name参数正确 |
| reload_project | ~1次 | 正常 |
| **总计** | **~310次** | |

### 4.2 工具可靠性评级

| 评级 | 工具 |
|------|------|
| ★★★★★ 完全可靠 | create_node, delete_node, batch_update_node_properties, get_node_properties, get_scene_structure, create_script, modify_script, read_script, validate_script(含content参数), attach_script, save_scene, open_scene, run_project, stop_project, list_project_input_actions, upsert_project_input_action, set_anchor_preset, detect_broken_scripts, audit_project_health, reload_project, update_node_property(Resource+NodePath已修复), create_resource(properties已修复,支持Dictionary/CSV/{x:...}格式), connect_signal(含PERSIST warning), batch_scene_node_edits(node_path返回已修复), execute_editor_script(缩进+get_tree()+get_node()+func/class/enum全部修复) |
| ★★★★☆ 基本可靠 | add_resource(命名不稳定) |
| ★★★☆☆ 受限可用 | (空) |
| ★★☆☆☆ 基本不可用 | execute_script(Expression类限制多), get_editor_screenshot(只截编辑器不截运行时) |

---

## 五、关键经验与教训

### 5.1 资源创建策略

**问题**：create_resource的properties不生效(B3) → **已修复**。

**修复方案**：
- `_convert_value_for_resource()` 类型转换函数（project_tools_native.gd:1412），支持 Vector3/Color/float/bool/String 等类型自动转换
- `_parse_key_value_string()` 函数（project_tools_native.gd:1474），支持 `{x:2.5,y:2,z:6}` 字符串格式解析

**修复后支持的properties值格式**：
- Dictionary：`{"x": 2.5, "y": 2, "z": 6}` — JSON原生对象，最推荐
- CSV字符串：`"2.5,2,6"` — 简洁
- Key-Value字符串：`"{x:2.5,y:2,z:6}"` — 类JSON但无引号，LLM常用格式
- 构造函数字符串：`"Vector3(2.5, 2, 6)"` — GDScript风格

**限制**：Environment/Sky等包含子资源的复杂嵌套资源，仍建议运行时脚本配置（见5.2节）。

### 5.2 Environment配置策略

**问题**：Environment.tres通过ResourceSaver保存时丢失sky子对象和大部分属性。

**最终方案**：在game_manager.gd的_ready()中运行时动态配置Environment：
```gdscript
func _setup_environment():
    var env = we.environment
    env.background_mode = Environment.BG_SKY
    var sk = Sky.new()
    sk.sky_material = load("res://assets/sky_material.tres")
    env.sky = sk
    env.fog_enabled = true
    # ...
```

**教训**：Environment/Sky这类包含子资源的复杂资源，不适合用.tres外部文件存储，运行时配置更可靠。

### 5.3 VehicleBody3D物理调参

**问题链**：无法移动 → 能动但方向反 → 转弯翻车 → 车速慢

**最终参数**：
| 参数 | 值 | 说明 |
|------|-----|------|
| mass | 4000 | 增大质量提高稳定性 |
| engine_force_value | 4000 | 足够动力 |
| max_steering | 0.35 | 限制转向角防止翻车 |
| steering_speed | 1.5 | 降低转向速度 |
| center_of_mass_mode | 1(自定义) | |
| center_of_mass | (0, -0.8, 0) | 降低重心 |
| suspension_stiffness | 40 | 硬悬挂提高响应 |
| suspension_max_force | 16000 | 足够支撑力 |
| suspension_travel | 0.5 | 足够行程 |
| wheel_roll_influence | 0.05 | 降低翻滚影响 |

### 5.4 城市场景构建效率

**耗时最长的操作**：
1. 建筑群创建(13栋 × 3子节点 = 39个节点 + 属性设置) — 用Task子代理并行处理
2. 路灯创建(12盏 × 4子节点 = 48个节点 + 属性设置) — 用Task子代理
3. 资源文件创建(26+个.tres) — execute_editor_script逐行创建

**效率提升手段**：
- batch_update_node_properties一次设置多个属性
- Task子代理批量创建节点
- execute_editor_script单行多语句批量创建资源

---

## 六、B1/B3/B8修复验证结论（2026-05-16实测）

### B1: execute_editor_script 缩进Bug → **已修复**

| 测试用例 | 结果 |
|----------|------|
| 单行 `_custom_print("hello")` | ✅ |
| 单行多语句 `var a = 1+2; _custom_print(str(a))` | ✅ |
| 多行if/else块 | ✅ |
| 多行for循环 | ✅ |
| 多行while循环 | ✅ |
| `var t = get_tree()` | ✅ 通过`edited_scene.get_tree()`代理 |
| `get_tree().root` 遍历节点 | ✅ |
| `edited_scene` 访问编辑场景 | ✅ |
| `func add(a,b): return a+b` 函数定义 | ✅ 提升到类级别 |
| 递归函数 `func fibonacci(n)` | ✅ |
| 混合func定义+执行语句 | ✅ |
| `class Vec2:` 类定义 | ✅ |
| `enum Direction {NORTH,SOUTH,EAST,WEST}` | ✅ |
| `match` 语句 | ✅ |
| 嵌套缩进(多级if/for) | ✅ |
| 前导4空格缩进代码 | ✅ `_spaces_to_tabs()`自动转换 |

**根因与修复**：
1. **缩进**：4空格缩进在Godot中不合法 → `_spaces_to_tabs()` 将行首4空格→1tab
2. **`get_tree()`不可用**：`extends RefCounted`没有`get_tree()` → 新增代理方法`get_tree()`→`edited_scene.get_tree()`，`get_node(path)`→`edited_scene.get_node_or_null(path)`
3. **`func`不可用**：用户代码在`execute()`方法内，方法内不能定义func → 自动识别`func`/`class`/`enum`定义及其缩进体，提升到类级别；执行语句留在`execute()`方法内

### B3: create_resource properties参数 → **已修复**

| 测试 | 结果 |
|------|------|
| create_resource BoxShape3D with properties={"size":{"x":2.5,"y":2,"z":6}} (Dictionary) | ✅ size=Vector3(2.5, 2, 6) |
| create_resource BoxShape3D with properties={"size":"2.5,2,6"} (CSV字符串) | ✅ size=Vector3(2.5, 2, 6) |
| create_resource BoxShape3D with properties={"size":"{x:2.5,y:2,z:6}"} (Key-Value字符串) | ✅ size=Vector3(2.5, 2, 6) — 需重启编辑器使新代码生效 |

**结论**：**已修复**。`_convert_value_for_resource()` 支持类型自动转换，`_parse_key_value_string()` 支持LLM常用的`{x:...,y:...,z:...}`字符串格式。

### B8: batch_scene_node_edits 返回node_path为空 → **已修复**

| 测试 | 修复前 | 修复后 |
|------|--------|--------|
| create with node_name="TestNode1" | node_path="" | node_path="/root/main/TestNode1" |
| create with node_name="TestNode2" | node_path="" | node_path="/root/main/TestNode2" |

**根因**：`_make_friendly_path(created_node, scene_root)` 在节点添加到场景树之前调用，`created_node.get_path()` 返回空字符串。
**修复**：改用 `_append_child_path(_make_friendly_path(created_parent, scene_root), prepared["node_name"])` 拼接路径。

---

## 七、仍未解决的MCP限制

### 引擎限制（不可修复）

1. **Environment/Sky无法通过.tres正确序列化** — ResourceSaver对嵌套子资源序列化不完整，需运行时配置

### 已有替代方案

4. **无法截取运行时窗口截图** — 已有 `get_runtime_screenshot`（Runtime Probe机制）
5. **运行时日志获取** — `get_editor_logs(source="runtime")` 可获取运行时日志

### 已修复（历史参考）

6. ~~create_resource properties不生效~~ — **已修复**（B3，`_convert_value_for_resource()` + `_parse_key_value_string()`）
7. ~~update_node_property不支持NodePath类型~~ — **已修复**（B5，`TYPE_NODE_PATH`分支）
8. ~~validate_script content参数缩进问题~~ — **已修复**（B6，`_spaces_to_tabs()`）
9. ~~connect_signal持久化与脚本connect冲突~~ — **已修复**（B7，返回warning提醒）
10. ~~batch_scene_node_edits返回node_path为空~~ — **已修复**（B8，parent路径+node_name拼接）
11. ~~execute_editor_script缩进Bug~~ — **已修复**（B1，`_spaces_to_tabs()` + `get_tree()`/`get_node()`代理 + `func`类级别提升）

---

## 八、场景最终结构

```
Main (Node3D) [game_manager.gd]
├── WorldEnvironment (Environment=黄昏+雾+泛光)
├── DirectionalLight3D (夕阳, 旋转-45,30,0, 色#ffaa66)
├── Camera3D [follow_camera.gd] (鼠标旋转第三人称)
├── City (Node3D)
│   ├── GroundPlane (StaticBody3D, 200×0.1×200, 色#7a7a6e)
│   ├── Roads (Node3D)
│   │   ├── Road_NS (StaticBody3D, 6×0.2×180, 色#333333)
│   │   └── Road_EW (StaticBody3D, 180×0.2×6, 色#333333)
│   ├── Buildings (Node3D)
│   │   ├── Bldg01_NW (10×15×10, 色#d4b895, +屋顶11×2×11, 色#8b4513)
│   │   ├── Bldg02_NE (20×8×10, 色#667788)
│   │   ├── Bldg03a_SW (8×5×8, 色#cc9966)
│   │   ├── Bldg03b_SW (8×5×8, 色#cc9966)
│   │   ├── Bldg04_SE (8×20×8, 色#aaccff, 玻璃幕墙)
│   │   ├── Bldg05_NW2 ~ Bldg08_SE2 (4栋)
│   │   └── Bldg09_NW3 ~ Bldg16_SE4 (8栋)
│   └── StreetLamps (Node3D)
│       └── Lamp_01~12 (OmniLight3D, #ffcc77, energy=2.0)
├── Truck (VehicleBody3D) [truck.gd]
│   ├── CollisionShape3D (2.5×2×6)
│   ├── BodyMesh + CabMesh
│   ├── 4×VehicleWheel3D
│   └── CameraMount
├── PickupPoint (Area3D) [delivery_point.gd]
├── DropoffPoint (Area3D) [delivery_point.gd]
└── UI (CanvasLayer) [ui_controller.gd]
    ├── HUD (速度/血量/状态/时间/金币)
    └── ResultPanel (结算面板)
```

---

## 九、从MVP到城市版的变更对比

| 维度 | MVP基础版 | 城市升级版 |
|------|-----------|------------|
| 节点数 | 38 | 153 (+115) |
| 资源文件 | ~16 | 70 (+54) |
| 场景范围 | 400×400空旷地面 | 200×200城市街区 |
| 天空 | 蓝色纯色 | 黄昏(深蓝+橙黄地平线) |
| 光照 | 白色正午光 | 夕阳(橙黄#ffaa66) |
| 雾效 | 无 | 暖橙深度雾(密度0.008) |
| 建筑 | 0 | 13栋(含碰撞体) |
| 路灯 | 0 | 12盏(OmniLight3D) |
| 道路 | 无 | 十字路口(南北+东西) |
| 车速 | engine_force=800 | engine_force=4000 |
| 车辆稳定性 | 容易翻车 | 低重心+硬悬挂, 稳定 |
| 装货/卸货点 | 随机坐标(可能重叠) | 道路上固定位置 |
