# Godot MCP 工具使用 Skill

> 基于货拉拉模拟器完整开发过程提炼的工作流方法论

---

## 工作流总览

```
需求分析 → 制定计划 → 工具清单 → 用户确认启用 → 分步执行 → 验证反馈 → 总结归档
```

每个阶段都有明确的输入、输出和检查点，不可跳步。

---

## 阶段一：需求分析

### 目标
将用户模糊的需求转化为具体的技术任务列表。

### 步骤
1. **读取用户提供的文档**（plan.md / scene_plan.md 等）
2. **检查当前项目状态**
   - `get_scene_structure` — 了解当前场景树
   - `audit_project_health` — 检查项目健康
   - `list_project_scripts` — 查看已有脚本
3. **识别变更范围**
   - 需要新增/修改/删除的节点
   - 需要创建的资源文件
   - 需要修改的脚本
   - 需要调整的属性

### 输出
一份结构化的任务清单，标注优先级和依赖关系。

---

## 阶段二：制定计划

### 目标
将任务清单转化为可执行的实施步骤，每步可验证。

### 原则
- **每步独立可验证** — 完成后可立即检查结果
- **先基础设施后上层** — 资源文件 → 节点结构 → 属性设置 → 脚本逻辑
- **批量操作优先** — 用batch工具减少调用次数
- **记录假设和风险** — 标注不确定的API/参数

### 计划文档模板

```markdown
# 实施计划

## 变更范围
| 变更项 | 操作类型 | 复杂度 |
|--------|----------|--------|

## 实施步骤
### Step 1: [描述]
- 操作：...
- 验证：...

### Step 2: [描述]
- ...

## 风险点
- ...
```

### 步骤拆分经验

| 拆分策略 | 说明 | 示例 |
|----------|------|------|
| 按层级拆分 | 资源→节点→属性→脚本 | 先创建所有.tres，再创建节点树 |
| 按区域拆分 | 独立模块分别实施 | 地面→道路→建筑→路灯 |
| 按风险拆分 | 高风险操作单独一步 | Environment配置单独一步 |
| 按验证拆分 | 每步完成后可验证 | 保存→运行→用户反馈 |

---

## 阶段三：工具清单与启用确认

### 目标
明确本次实施需要哪些MCP工具，交给用户确认启用。

### 工具分类模板

```markdown
## 必须开启的工具
| 工具 | 用途 | 备注 |
|------|------|------|

## 推荐开启的工具
| 工具 | 用途 |
|------|------|

## 不需要的工具
| 工具 | 原因 |
|------|------|
```

### 常用工具速查

**场景构建类（几乎每次都需要）：**
- `create_node` — 创建节点
- `add_resource` — 添加CollisionShape3D等子节点
- `delete_node` — 删除节点
- `update_node_property` — 设置单个属性
- `batch_update_node_properties` — 批量设置属性（**优先使用**）
- `rename_node` — 重命名节点
- `save_scene` — 保存场景

**资源创建类：**
- `create_resource` — 创建.tres文件（注意：properties可能不生效）
- `execute_editor_script` — 修正资源属性（单行模式）

**脚本类：**
- `create_script` / `modify_script` — 创建/修改脚本
- `validate_script` — 验证语法（仅用script_path方式）
- `attach_script` — 挂载脚本到节点

**验证类：**
- `get_scene_structure` — 查看场景树
- `get_node_properties` — 查看节点属性
- `detect_broken_scripts` / `audit_project_health` — 项目健康检查

**运行测试类：**
- `run_project` / `stop_project` — 运行/停止游戏

### 关键提醒
执行前必须向用户展示工具清单并等待确认：
> "请确认以上工具已开启，我即可开始实施。"

---

## 阶段四：分步执行

### 核心原则

1. **每步完成即验证** — 不要攒到最后一起检查
2. **保存要及时** — 每个Step完成后save_scene
3. **用todo跟踪进度** — todowrite记录每个步骤状态
4. **批量优于逐个** — batch_update_node_properties > N次update_node_property
5. **单行execute_editor_script** — 避免多行缩进问题

### 4.1 资源创建最佳实践

**问题**：`create_resource`的properties参数不生效(B3未修复)

**方案**：用`execute_editor_script`单行多语句创建资源：

```
execute_editor_script: "var m = BoxMesh.new(); m.size = Vector3(10, 15, 10); ResourceSaver.save(m, 'res://assets/bldg01_body_mesh.tres')"
```

**限制**：
- 单行最多5-6个分号分隔语句
- 不能包含`func`定义
- 不能调用`get_tree()`等编辑器API
- 字符串用双引号，路径用单引号或双引号

**批量创建技巧**：每次execute_editor_script调用创建3-5个资源，按类型分组：

```
// 一组相关的资源
var m = BoxMesh.new(); m.size = Vector3(10, 15, 10); ResourceSaver.save(m, "res://assets/bldg_mesh.tres")
var s = BoxShape3D.new(); s.size = Vector3(10, 15, 10); ResourceSaver.save(s, "res://assets/bldg_shape.tres")
var mat = StandardMaterial3D.new(); mat.albedo_color = Color("#d4b895"); mat.roughness = 0.7; ResourceSaver.save(mat, "res://assets/bldg_mat.tres")
```

### 4.2 节点创建最佳实践

**优先用create_node**而非batch_scene_node_edits（后者命名不稳定）：

```
create_node: parent=/root/main/City/Buildings, name=Bldg01_NW, type=StaticBody3D
add_resource: node_path=/root/main/City/Buildings/Bldg01_NW, type=CollisionShape3D
create_node: parent=/root/main/City/Buildings/Bldg01_NW, name=BodyMesh, type=MeshInstance3D
```

**批量属性设置用batch_update_node_properties**：

```
batch_update_node_properties: {
  changes: [
    {node_path, property_name: "position", property_value: {x:-20, y:7.5, z:-20}},
    {node_path, property_name: "shape", property_value: "res://assets/bldg01_shape.tres"},
    {node_path, property_name: "mesh", property_value: "res://assets/bldg01_mesh.tres"},
    ...
  ]
}
```

### 4.3 资源引用设置

`update_node_property`支持res://路径字符串设置Resource引用：

```
update_node_property: {
  node_path: "/root/main/City/Buildings/Bldg01_NW/CollisionShape3D",
  property_name: "shape",
  property_value: "res://assets/bldg01_body_shape.tres"  // 直接传路径字符串
}
```

### 4.4 Environment/Sky配置

**问题**：Environment.tres通过ResourceSaver保存时丢失sky子对象。

**方案**：在脚本_ready()中运行时动态配置：

```gdscript
func _setup_environment():
    var we = get_node_or_null("WorldEnvironment")
    if not we: return
    var env = we.environment
    if not env:
        env = Environment.new()
        we.environment = env
    env.background_mode = Environment.BG_SKY
    var sk = Sky.new()
    sk.sky_material = load("res://assets/sky_material.tres")
    env.sky = sk
    env.fog_enabled = true
    env.fog_density = 0.008
    # ...
```

**教训**：嵌套子资源的复杂类型不适合.tres外部文件，运行时配置更可靠。

### 4.5 批量节点创建（大量同类节点）

当需要创建大量同类节点（如10+栋建筑、10+盏路灯），**使用Task子代理**：

```
Task(subagent_type="general", prompt="
  在 /root/main/City/Buildings 下创建8个建筑...
  每个建筑包含 StaticBody3D + CollisionShape3D + MeshInstance3D...
  [详细列出每个建筑的位置、资源引用]
")
```

**优势**：子代理可以连续执行大量create_node/add_resource调用，不会因上下文长度受限。

### 4.6 VehicleBody3D物理调参参考值

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| mass | 3000-5000 | 货车级别 |
| engine_force | 3000-5000 | 设在每个驱动轮上(非车身) |
| max_steering | 0.3-0.4 | 过大易翻车 |
| steering_speed | 1.0-2.0 | |
| center_of_mass_mode | 1(自定义) | |
| center_of_mass.y | -0.5 ~ -1.0 | 降低重心防翻车 |
| suspension_max_force | 12000-20000 | |
| suspension_travel | 0.3-0.5 | |
| suspension_stiffness | 30-50 | |
| wheel_roll_influence | 0.03-0.05 | 低值防翻车 |

**注意**：engine_force正值推向-Z方向（Godot前进方向为-Z）。

### 4.7 调试策略

**运行时无法获取日志的变通方案**：

1. **UI Label可视化**：将调试信息写到HUD的Label上
2. **用户反馈**：用question工具让用户观察游戏窗口并描述
3. **编辑器验证**：停止游戏后用get_node_properties检查属性

---

## 阶段五：验证反馈循环

### 每步验证

```
save_scene → validate_script → audit_project_health
```

### 运行验证

```
run_project → [等待3-5秒] → question(让用户观察反馈) → stop_project
```

### question模板

```markdown
请观察以下内容：
1. [视觉检查项]
2. [功能检查项]
3. [交互检查项]

选项：
- 全部正常
- [具体问题描述]
```

### 根据反馈迭代

- 如果反馈正常 → 进入下一步
- 如果反馈有问题 → 分析原因 → 修复 → 重新验证
- **不要连续修改多个问题** — 每次只修一个，验证后再修下一个

---

## 阶段六：总结归档

### 必须包含的内容

1. **问题全记录** — 按A/B/C/D分类
2. **MCP工具使用统计** — 每个工具调用次数
3. **工具可靠性评价** — ★评级
4. **仍未解决的限制** — 按优先级排列
5. **B1/B3修复状态** — 带验证用例
6. **关键经验** — 可复用的模式/参数/策略

### 问题分类体系

| 分类 | 含义 | 示例 |
|------|------|------|
| A类 | 设计/考虑不周 | 坐标算错、API用法错误、参数选择不当 |
| B类 | MCP工具限制/bug | properties不生效、缩进Bug、命名不稳定 |
| C类 | Godot引擎知识盲区 | 悬挂参数影响、ResourceSaver限制、属性名错误 |
| D类 | 调试手段受限 | 无法截运行时截图、日志不可获取 |

### 工具使用繁琐度评价标准

| 评级 | 标准 | 示例 |
|------|------|------|
| 高效 | 一次调用完成目标 | batch_update_node_properties设置10个属性 |
| 正常 | 需要预期的调用次数 | create_node创建1个节点 |
| 繁琐 | 需要额外步骤补偿工具缺陷 | create_resource+execute_editor_script两步创建1个资源 |
| 低效 | 大量重复调用完成简单目标 | 逐个rename_node修正@前缀命名 |

---

## 附录：MCP工具已知限制速查表

| ID | 问题 | 严重度 | 当前状态 | 变通方案 |
|----|------|--------|----------|----------|
| B1 | execute_editor_script缩进Bug | P0 | 部分修复 | 单行多语句(分号) |
| B3 | create_resource properties不生效 | P1 | 未修复 | execute_editor_script创建 |
| B5 | update_node_property不支持NodePath | P1 | 未修复 | 脚本get_node_or_null() |
| B6 | validate_script content缩进问题 | P2 | 未修复 | 只用script_path |
| B7 | connect_signal持久化冲突 | P2 | 未修复 | 二选一使用 |
| B8 | add_resource命名不稳定 | P2 | 未修复 | rename_node修正 |
| B9 | Environment/Sky .tres序列化问题 | P1 | 未修复 | 运行时脚本配置 |
| - | 无法截运行时窗口截图 | P2 | 引擎限制 | question用户反馈 |
| - | 运行时日志不可获取 | P2 | 引擎限制 | UI Label可视化 |

---

## 附录：标准工作流Checklist

- [ ] 阶段一：读取需求文档，检查项目状态，识别变更范围
- [ ] 阶段二：制定实施计划，拆分步骤，标注风险点
- [ ] 阶段三：列出工具清单，用户确认启用
- [ ] 阶段四：分步执行
  - [ ] Step 1: 清理旧节点/资源
  - [ ] Step 2: 创建资源文件
  - [ ] Step 3: 创建节点树
  - [ ] Step 4: 设置属性和引用
  - [ ] Step 5: 修改脚本
  - [ ] Step 6: 验证+保存
- [ ] 阶段五：运行验证，用户反馈，迭代修复
- [ ] 阶段六：总结归档，统计工具使用，记录经验教训
