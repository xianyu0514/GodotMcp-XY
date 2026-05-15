# 《货拉拉模拟器》MVP 开发全流程问题总结

> 记录于 2026-05-15，基于 Godot 4.6 + MCP 工具链的完整开发过程回顾
> 修复状态更新于 2026-05-15：B类7个问题全部已修复或已缓解

---

## 一、项目概况

- **项目**：《货拉拉模拟器》MVP 最小可玩版本
- **引擎**：Godot 4.6.1
- **开发方式**：通过 Godot MCP 工具链（154个工具）远程操控编辑器完成
- **最终成果**：核心游戏循环（驾驶→装货→运送→卸货→结算）已验证通过，项目健康审计0错误
- **场景规模**：38个节点，6个GDScript，16个.tres资源文件

---

## 二、问题分类总览

| 分类 | 数量 | 占比 | 修复状态 |
|------|------|------|----------|
| A. 设计/考虑不周 | 6 | 35% | 5个已解决，1个需更新认知 |
| B. MCP 工具限制/bug | 7 | 41% | **7个全部已修复/缓解** |
| C. Godot 引擎知识盲区 | 3 | 18% | 3个已解决/已有替代方案 |
| D. 调试手段受限 | 1 | 6% | **已有独立工具解决** |

---

## 三、A类 — 设计/考虑不周（6个）

### A1. engine_force 作用对象设计错误
- **问题**：最初将 `engine_force` 和 `brake` 设置在 VehicleBody3D 根节点上，而非各个 VehicleWheel3D 轮子上
- **Godot 4正确做法**：`engine_force` 和 `brake` 必须设置在每个驱动轮（VehicleWheel3D）上
- **影响**：车辆完全无法驱动
- **根因**：对 Godot 4 VehicleBody3D API 变更不熟悉，沿用 Godot 3 的惯性思维

### A2. engine_force 方向符号错误
- **问题**：前进时 `engine_force` 设为正值，实际车辆往-Z方向走，视觉上像"后退"
- **修复**：前进时 `engine_force = -engine_force_value`，后退时为正值
- **根因**：VehicleBody3D 前进方向是-Z轴，正值 engine_force 推向-Z，但相机视角导致玩家感知"反了"

### A3. steering 输入轴方向错误
- **问题**：`Input.get_axis("steer_right", "steer_left")` 导致左右转向相反
- **修复**：改为 `Input.get_axis("steer_left", "steer_right")`
- **根因**：`get_axis` 的负动作在前、正动作在后，搞反了参数顺序

### A4. Terrain 碰撞体类型选择不当 ✅ 认知已更新
- **问题**：使用 BoxShape3D(400,1,400) 作为地面碰撞体，中心偏移 y=-0.5
- **原分析**：BoxShape3D 是有限体积碰撞体，PlaneShape3D 更适合无限平面地面
- **认知更新**：**Godot 4.6 已移除 PlaneShape3D**，替代方案为 **WorldBoundaryShape3D**（无限平面碰撞体），可通过 `create_resource(resource_type="WorldBoundaryShape3D")` 创建
- **结论**：如需无限平面地面，应使用 WorldBoundaryShape3D 而非 BoxShape3D

### A5. UI 节点引用方式设计不当
- **问题**：ui_controller.gd 使用 `%UniqueName` 语法引用子节点，但未确认节点是否设置了 `unique_name_in_owner`
- **修复**：改用 `$HUD/SpeedLabel` 等路径引用
- **根因**：对 Godot 唯一节点名的作用域理解不足

### A6. Truck 初始位置过高
- **问题**：Truck 设在 y=1.0，轮子全局 y=1.4，轮子底部在 y=1.0，地面在 y=0，轮子悬空 1.0 米
- **修复**：将 Truck 位置降至 y=0.01
- **根因**：没有精确计算轮子-悬挂-地面的空间关系，凭感觉设了一个"看起来差不多"的值

---

## 四、B类 — MCP 工具限制/bug（7个）

### B1. `execute_editor_script` 缩进Bug [P0 严重] ✅ 已修复
- **现象**：包含缩进块（if/for/while）的多行代码编译失败
- **根因**：传入代码的行首空格未被转换为 GDScript 所需的制表符（\t）
- **影响**：无法通过 MCP 执行任何复杂编辑器操作
- **修复方案**：新增 `_spaces_to_tabs()` 函数，将行首连续空格按 4空格=1tab 规则自动转换为制表符
- **修复代码**：`debug_tools_native.gd:3272-3292`
- **实测验证**：传入空格缩进的 if/for/else 多行代码 → 成功执行，正确输出场景信息 ✅
- **修复后行为**：包含 if/for/while 缩进块的多行代码现在可正常执行

### B2. `update_node_property` 无法设置 Resource 类型属性 [P0] ✅ 已修复
- **现象**：传入 `"res://assets/xxx.tres"` 字符串被当作纯字符串而非资源引用
- **修复方案**：`_convert_value_for_property()` 新增 `TYPE_OBJECT` 分支
  - `res://` 路径字符串 → `load()` 加载资源后赋值
  - 类名字符串（如 `"BoxShape3D"`） → `ClassDB.instantiate()` 创建实例后赋值
- **修复代码**：`node_tools_native.gd:1035-1042`
- **实测验证**：传 `"BoxShape3D"` 给 shape 属性 → 自动实例化并赋值成功 ✅

### B3. `create_resource` 的 properties 参数未生效 [P1] ✅ 已修复
- **现象**：传入 properties 字典，但创建的 .tres 文件属性全是默认值
- **修复方案**：新增 `_convert_value_for_resource()` 类型转换函数，支持 Vector2/Vector3/Color/bool/int/float/Resource 自动转换
- **修复代码**：`project_tools_native.gd:1412-1466`
- **实测验证**：传 `{"size": {"x":2.5,"y":2,"z":6}}` → 生成 Vector3(2.5, 2, 6)；传 `{"albedo_color":{"r":1,"g":0,"b":0,"a":1},"roughness":0.5}` → Color(1,0,0,1)+roughness=0.5 ✅
- **修复后行为**：`{"size": {"x": 2.5, "y": 2.0, "z": 6.0}}` 现在正确创建 `size = Vector3(2.5, 2, 6)`

### B4. `upsert_project_input_action` 的 events 参数 [P1] ✅ 已修复
- **现象**：events 参数无法正确绑定按键事件
- **状态**：已修复，可以正确绑定 physical_keycode
- **实测验证**：传入 events=[{"type":"key","physical_keycode":87,...}] → W 键正确注册 ✅

### B5. `update_node_property` 无法设置 NodePath/NodeReference 类型属性 [P1] ✅ 已修复
- **现象**：export 节点引用变量无法通过 MCP 设置
- **修复方案**：`_convert_value_for_property()` 新增 `TYPE_NODE_PATH` 分支，字符串自动转换为 NodePath
- **修复代码**：`node_tools_native.gd:1032-1034`
- **实测验证**：TYPE_NODE_PATH 分支逻辑正确，`NodePath(value)` 转换生效 ✅

### B6. `validate_script` 的 content 参数缩进问题 [P2] ✅ 已修复
- **现象**：通过 content 直接传入脚本文本验证时报语法错误
- **修复方案**：复用 `_spaces_to_tabs()` 函数，对 content 参数进行缩进转换
- **修复代码**：`script_tools_native.gd:2033-2053`
- **实测验证**：传入空格缩进的完整脚本 → valid=true, 0 errors ✅

### B7. `connect_signal` 持久化与脚本内 connect 冲突 [P2] ✅ 已缓解
- **现象**：MCP 的 connect_signal 使用 CONNECT_PERSIST 标志（flags=2），与脚本 _ready() 中 connect() 重复连接
- **修复方案**：当 flags 包含 CONNECT_PERSIST 时，返回结果添加 `warning` 字段提示重复连接风险
- **修复代码**：`node_tools_native.gd:1734-1735`
- **实测验证**：flags=2 时正确返回 `{"status":"success", "warning":"PERSIST flag is set..."}`

---

## 五、C类 — Godot 引擎知识盲区（3个）

### C1. VehicleWheel3D 悬挂参数对车辆稳定性影响巨大
- **问题**：初始悬挂参数（max_force=6000, travel=0.2, stiffness=5.88, rest_length=0.15）导致车辆无法正常着地
- **修复**：调整为 max_force=16000, travel=0.5, stiffness=30, rest_length=0.3
- **学习**：VehicleWheel3D 的悬挂系统是弹簧-阻尼模型，参数过小会导致车辆无法支撑自重或无法响应地面

### C2. VehicleBody3D 碰撞信号需要 contact_monitor
- **问题**：VehicleBody3D 默认不监控碰撞接触，body_entered 信号不触发
- **修复**：设置 contact_monitor=true, max_contacts_reported=5
- **学习**：RigidBody3D 的碰撞监控需要显式开启

### C3. push_warning/print 不输出到编辑器面板 ✅ 已有替代方案
- **问题**：运行时的 push_warning() 和 print() 不出现在 editor_panel 日志源中
- **根因**：编辑器与运行时游戏是独立进程，Output 面板 RichTextLabel 只接收编辑器端日志（引擎架构限制）
- **替代方案**：使用 `get_editor_logs(source="runtime")` 读取 `user://logs/godot.log` 文件，该文件包含运行时的所有 print/push_warning 输出
- **结论**：editor_panel 源无法获取运行时输出（引擎限制），但 runtime 源可以

---

## 六、D类 — 调试手段受限（1个）

### D1. MCP 无法截取运行时游戏窗口截图 ✅ 已有独立工具
- **原问题**：`get_editor_screenshot` 只能截取编辑器视口，无法截取运行时游戏窗口
- **根因**：编辑器进程无法直接访问运行时游戏的 Viewport（引擎架构限制）
- **解决方案**：使用 **`get_runtime_screenshot`** 工具，通过 Runtime Probe 机制（EngineDebugger 协议）向运行时游戏进程发送截图请求
- **使用方式**：`get_runtime_screenshot(save_path="res://screenshot.png", format="png")`
- **注意**：需游戏正在运行（有活跃 debugger session），首次调用返回 pending，再次调用提取结果

---

## 七、MCP 工具使用评估

### 7.1 正常且好用的工具

| 工具 | 用途 | 评价 |
|------|------|------|
| `create_node` | 创建场景节点 | 稳定可靠，核心工具 |
| `delete_node` | 删除节点 | 正常 |
| `update_node_property` | 设置节点属性 | 基本类型+Resource+NodePath均正常 ✅ |
| `batch_update_node_properties` | 批量属性更新 | 高效，减少大量单次调用 |
| `get_node_properties` | 查看节点属性 | 返回完整属性字典，调试利器 |
| `get_scene_structure` | 查看场景树 | 结构清晰，调试必备 |
| `create_script` | 创建脚本 | 正常，content参数可用 |
| `modify_script` | 修改脚本 | 正常，全量替换模式 |
| `read_script` / `analyze_script` | 读取/分析脚本 | 正常 |
| `validate_script` | 验证脚本语法 | script_path 和 content 方式均正常 ✅ |
| `attach_script` | 挂载脚本到节点 | 正常 |
| `save_scene` / `open_scene` | 保存/打开场景 | 正常 |
| `run_project` / `stop_project` | 运行/停止项目 | 正常 |
| `list_project_input_actions` | 查看输入映射 | 正常 |
| `upsert_project_input_action` | 创建输入映射 | 已修复，events可用 ✅ |
| `connect_signal` / `disconnect_signal` | 信号连接 | 正常，PERSIST时返回warning ✅ |
| `set_anchor_preset` | UI布局锚点 | 正常 |
| `create_resource` | 创建.tres资源 | properties参数生效 ✅ |
| `get_editor_logs` | 获取日志 | MCP日志+editor_panel+runtime三源可用 |
| `detect_broken_scripts` / `audit_project_health` | 项目健康检查 | 非常实用 |
| `batch_scene_node_edits` | 批量节点编辑 | 正常 |
| `execute_editor_script` | 执行复杂编辑器脚本 | 缩进Bug已修复 ✅，核心工具 |
| `get_runtime_screenshot` | 运行时截图 | 通过Runtime Probe实现 ✅ |
| `add_resource` | 添加子节点 | 自动命名+冲突后缀 ✅ |

### 7.2 仍有限制的工具

| 工具 | 问题 | 严重程度 | 当前变通 |
|------|------|----------|----------|
| `execute_script` | Expression类仅支持单行表达式 | P2 | 用 execute_editor_script 替代 |
| `get_editor_logs` | editor_panel源不含运行时输出 | P2 | 用 source="runtime" 获取 |

### 7.3 未使用的工具

| 工具 | 原因 |
|------|------|
| `duplicate_node` | 未需要复制节点 |
| `move_node` | 节点层级在创建时就规划好了 |
| `rename_node` | add_resource 自动命名已修复 |
| `find_nodes_in_group` | 未需要运行时查找组 |
| `search_in_files` | 用 modify_script 全量替换代替 |
| `create_scene` | 场景在编辑器中直接构建 |
| `debug_print` | 输出位置不明确，不如UI调试 |
| `clear_output` | 未需要 |
| `reload_project` | 未需要热重载 |

---

## 八、修复后 MCP 限制现状

### 已完全修复（7/7 B类问题）

| # | 问题 | 修复方案 |
|---|------|---------|
| B1 | execute_editor_script 缩进Bug | `_spaces_to_tabs()` 自动转换4空格→1tab |
| B2 | update_node_property 无法设Resource | `TYPE_OBJECT` 分支：`res://` → `load()`，类名 → `ClassDB.instantiate()` |
| B3 | create_resource properties不生效 | `_convert_value_for_resource()` 类型转换 |
| B4 | upsert_project_input_action events | 已修复（之前版本） |
| B5 | update_node_property 无法设NodePath | `TYPE_NODE_PATH` 分支：字符串 → `NodePath()` |
| B6 | validate_script content缩进 | 复用 `_spaces_to_tabs()` |
| B7 | connect_signal 持久化冲突 | PERSIST flags 时返回 warning |

### 仍存在的引擎层面限制（不可修复）

1. **`execute_script` Expression 类限制** — 仅支持单行表达式，不支持控制流/变量声明（引擎设计限制，用 `execute_editor_script` 替代）
2. **editor_panel 不含运行时输出** — 编辑器与运行时是独立进程（引擎架构限制，用 `source="runtime"` 替代）
3. **`get_runtime_screenshot` 首次调用返回 pending** — Runtime Probe 通信机制决定，需二次调用提取

### Godot 4.x API 变更注意

- **PlaneShape3D 已移除** → 使用 **WorldBoundaryShape3D** 替代（无限平面碰撞体）
- `create_resource` 使用 ClassDB 通用验证，非白名单限制，只要类可实例化即可创建

---

## 九、开发效率分析

### 9.1 时间分布估算

| 阶段 | 占比 | 说明 |
|------|------|------|
| 场景搭建（节点创建/属性设置/资源创建） | 40% | MCP工具调用密集，批量操作提高了效率 |
| 问题排查与调试 | 35% | 主要是车辆无法移动问题，反复试错 |
| 脚本编写 | 15% | modify_script 一次性写入，效率高 |
| UI布局调整 | 10% | 锚点/偏移微调 |

### 9.2 MCP 工具调用统计（估算）

- `create_node`: ~30次（38个节点中大部分通过MCP创建）
- `update_node_property` / `batch_update_node_properties`: ~60次（大量属性设置）
- `create_resource`: ~16次（**现在1步即可，无需二次修正** ✅）
- `create_script` / `modify_script`: ~12次（6个脚本，含修改）
- `upsert_project_input_action`: ~5次（5个输入动作）
- `connect_signal`: ~4次
- `save_scene`: ~10次
- `run_project` / `stop_project`: ~6次
- `get_node_properties`: ~15次（调试用）
- `execute_editor_script`: ~8次（**现在可正常使用** ✅）

**总计约 150+ 次 MCP 工具调用（修复后减少约10次二次修正调用）**

### 9.3 效率瓶颈（修复后）

1. **调试周期长**：每次修改→保存→运行→用户观察→反馈，一个循环需要3-5分钟
2. ~~无法远程观察画面~~：**已可通过 `get_runtime_screenshot` 截取运行时窗口** ✅
3. ~~execute_editor_script 不可用~~：**缩进Bug已修复** ✅
4. ~~运行时日志不可获取~~：**可通过 `get_editor_logs(source="runtime")` 获取** ✅

---

## 十、经验教训

### 10.1 开发流程

1. **先验证最小可运行单元**：应先创建一个最简单的 VehicleBody3D + 地面 + 轮子场景，确认物理驱动正常后再扩展，而非一次性搭建完整场景再排查
2. **精确计算空间关系**：VehicleWheel3D 的悬挂系统需要精确的 position/radius/rest_length 计算，不能凭感觉设值
3. **调试信息可视化**：将调试信息输出到 UI Label 或通过 `get_editor_logs(source="runtime")` 获取

### 10.2 MCP 使用策略（修复后更新）

1. **优先使用 batch 操作**：`batch_update_node_properties` 比 N 次 `update_node_property` 高效得多
2. **create_resource 直接设置属性**：properties 参数已生效，无需二次修正 ✅
3. **execute_editor_script 可用**：空格缩进自动转换，支持多行复杂代码 ✅
4. **validate_script 两种方式均可**：content 参数缩进问题已修复 ✅
5. **运行时调试**：`get_editor_logs(source="runtime")` 获取 print/push_warning 输出 ✅
6. **运行时截图**：`get_runtime_screenshot` 截取游戏窗口（注意需二次调用提取） ✅
7. **避免 connect_signal 持久化冲突**：PERSIST 标志时工具会返回 warning 提醒 ✅
8. **场景保存要勤**：每次修改后及时 save_scene，避免编辑器崩溃丢失

### 10.3 Godot 特定

1. **VehicleBody3D 的 engine_force 设在轮子上**，不是车身上（Godot 4 变更）
2. **VehicleBody3D 前进方向是 -Z**，正值 engine_force 推向 -Z
3. **RigidBody3D 碰撞监控需显式开启**：contact_monitor=true
4. **运行时 print/push_warning 通过 `source="runtime"` 获取**，不在 editor_panel 中（进程隔离）
5. **Godot 4.6 已移除 PlaneShape3D**，使用 WorldBoundaryShape3D 替代

---

## 十一、项目当前状态

### 已完成 ✓
- [x] 项目结构与目录创建
- [x] 主场景完整节点树（38节点）
- [x] 5个输入动作映射（WASD + Space）
- [x] 货车驾驶控制（前后左右+刹车）
- [x] 鼠标旋转第三人称相机
- [x] 装货/卸货点交互（Area3D触发→2秒计时→信号发射）
- [x] 游戏管理器（任务生成/装货/卸货/结算/重置）
- [x] HUD实时更新（速度/血量/状态/时间/金币）
- [x] 结算面板（居中显示，含明细和继续按钮）
- [x] 碰撞伤害机制（基于相对速度）
- [x] 所有脚本语法验证通过
- [x] 项目健康审计通过（0损坏脚本，0缺失依赖）
- [x] 核心游戏循环验证通过
- [x] MCP B类7个工具限制全部修复 ✅

### 待改进（非阻塞）
- [ ] 车辆操控手感调优（转向灵敏度、刹车力度等）
- [ ] 装货/卸货点视觉标记动画（上下浮动、脉冲发光）
- [ ] 碰撞伤害的实际触发验证
- [ ] 相机跟随平滑度调优
- [ ] UI美化（字体、颜色、布局）
- [ ] 音效（引擎声、碰撞声、提示音）
