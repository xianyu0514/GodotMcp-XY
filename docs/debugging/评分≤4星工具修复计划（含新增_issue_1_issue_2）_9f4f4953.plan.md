---
name: 评分≤4星工具修复计划（含新增 Issue 1 / Issue 2）
overview: 对 godot_mcp_tools_summary.md 中评分 ≤4 星的工具进行系统性修复，按优先级和可行性分阶段推进。基于对 node_tools_native.gd、scene_tools_native.gd、debug_tools_native.gd、script_tools_native.gd、project_tools_native.gd、resource_tools_native.gd 及 mcp_debugger_bridge.gd 的源码调查，结合 context7 Godot API 查询验证。新增 Issue 1（Runtime Probe 场景切换死亡）和 Issue 2（get_editor_screenshot 截取过时帧）。
todos:
  - id: phase1-1-create-node
    content: 1.1 create_node：修复嵌套实例的 owner 计算 + 包装 EditorUndoRedoManager
    status: completed
  - id: phase1-2-update-property
    content: 1.2 update_node_property：在 load() 前添加 ResourceLoader.exists() 验证
    status: completed
  - id: phase1-3-get-node-props
    content: 1.3 get_node_properties：添加正确的 Resource 序列化（替代 str(Object)）
    status: completed
  - id: phase1-4-add-resource
    content: 1.4 add_resource：添加可选的 properties 参数字典，支持原子化创建+配置
    status: completed
  - id: phase1-5-bridge-stderr
    content: 1.5 get_debug_output(stderr)：将 script_error/gdscript EngineDebugger 消息桥接到 output_events
    status: completed
  - id: phase1-6-await-polling
    content: 1.6 await_runtime_condition：实现真实轮询循环（使用 poll_interval_ms、timeout_ms）
    status: completed
  - id: phase1-7-probe-autoload
    content: 1.7 MCPRuntimeProbe 挂在 SceneTree.root 下，避免场景切换时死亡
    status: completed
  - id: phase2-1-editor-logs
    content: 2.1 get_editor_logs：添加 EditorLog 文件回退读取器捕获 Script Errors
    status: completed
  - id: phase2-2-execute-script
    content: 2.2 execute_script：自动检测多行代码并通过 execute_editor_script 机制包装
    status: completed
  - id: phase2-3-symbol-references
    content: 2.3 find_script_symbol_references：交叉引用 Autoload 列表以实现更好的符号解析
    status: completed
  - id: phase2-4-rename-symbol
    content: 2.4 rename_script_symbol：将 .tscn 加入默认 include_extensions
    status: completed
  - id: phase2-5-create-resource
    content: 2.5 create_resource：添加 Array/Dict 递归子属性转换
    status: completed
  - id: phase2-6-editor-screenshot
    content: 2.6 get_editor_screenshot：捕获前调用 RenderingServer.force_draw() 刷新视图
    status: completed
  - id: update-docs
    content: 更新 docs/debugging/godot_mcp_tools_summary.md 中的评分和修复状态
    status: completed
  - id: run-tests
    content: 运行 GUT 全量测试套件 — 必须 0 失败
    status: completed
isProject: false
---

评分≤4星工具修复计划（含新增 Issue 1 / Issue 2）

## 状态标记说明

| 标记 | 含义 |
|---|---|
| FIXED | 修复已在代码库中实现，可能需要验证 |
| ARCH | 架构限制，需要根本性重新设计，优先级低 |
| fixable | 有明确范围的针对性代码修改 |
| wont-fix | 预期设计行为或 Godot API 限制 |

## Phase 0：已修复（仅需验证）

以下修复已有代码实现，但需要验证测试确认可用。

1. **validate_script / detect_broken_scripts / audit_project_health**（原 ★★☆☆☆）
   - 文件：`script_tools_native.gd` L1964-1981、`project_tools_native.gd` L2373-2382
   - 修复：首次验证失败后注入 Autoload 声明重试；autoload_aware=true 脚本降级为 warning 级别
   - 状态：FIXED
   - 剩余问题：重试失败后的回退错误检测依赖启发式关键词匹配，不够健壮但很少触发

2. **update_node_property / batch_update_node_properties** TYPE_OBJECT 分支（原 ★★★☆☆）— B5 #3
   - 文件：`node_tools_native.gd` L533-543（`_convert_value_for_property`）
   - 修复：支持 `res://` 路径加载 Resource，支持 ClassDB.instantiate 类名实例化
   - 状态：FIXED
   - 剩余缺口：`load()` 在路径无效时静默返回 null → 应先用 `ResourceLoader.exists()` 验证

## Phase 1：高影响修复

### 1.1 create_node：Owner 计算 + UndoRedo 包装（原 ★★★★☆）

- **文件**：`addons/godot_mcp/tools/node_tools_native.gd`，`_tool_create_node` ~L152
- **问题**：Owner 始终设为 `scene_root`，不关心父节点深度。`PackedScene.pack()` 会丢弃 owner 关系不正确的节点。没有 UndoRedo 包装。
- **修复**：
  - 遍历父链：如果父节点的 owner != scene_root，则父节点的 owner 就是正确 owner
  - 用 EditorUndoRedoManager 包装：`add_do_method(parent, "add_child", node)` / `add_undo_method(parent, "remove_child", node)`
  - 加上 `add_do_method(node, "set_owner", correct_owner)` / `add_undo_property(node, "owner", null)`
- **Godot API 证据**（context7）：`PackedScene.pack()` 只保存 root 拥有的节点。Owner 必须是场景根节点或将被 pack 的节点。`class_packedscene.md` 中的示例明确显示，对嵌套层次结构应设置 `body.owner = node` 而不是 `node.owner = node`。
- **测试**：在实例化子场景下创建节点 → save_scene → 验证节点持久化

### 1.2 update_node_property：Resource 错误处理增强（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/node_tools_native.gd`，`_convert_value_for_property` 在 L533-543
- **问题**：`load(value)` 在 `res://` 路径无效时静默返回 null，不给用户任何错误反馈。
- **修复**：添加验证：
  ```gdscript
  if value.begins_with("res://"):
      if not ResourceLoader.exists(value):
          return {"error": "Resource path does not exist: " + value}
  ```
- **Godot API 证据**（context7）：`ResourceLoader.exists(path)` 返回 bool，Godot 4.6 可用。
- **测试**：用不存在的 res:// 路径调用 update_node_property → 返回 error

### 1.3 get_node_properties：Resource 序列化（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/node_tools_native.gd`，`_serialize_value` 在 L596-622
- **问题**：`str(Object)` 对无效引用输出 `<Object#null>`，对有效 Resource 输出不可读的调试 ID。
- **修复**：对 TYPE_OBJECT 进行 Resource 检测：
  ```gdscript
  var resource := value as Resource
  if resource:
      result = {
          "type": "Resource",
          "resource_type": resource.get_class(),
          "resource_path": resource.resource_path,
          "resource_name": resource.resource_name
      }
  ```
- **测试**：在包含 CollisionShape2D 的节点上调用 get_node_properties → shape 字段显示结构化数据而非 `<Object#null>`

### 1.4 add_resource：添加 properties 参数（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/node_tools_native.gd`，`_tool_add_resource` 在 L680-722
- **问题**：创建子节点（如 CollisionShape2D）后 shape 属性为 null，没有方式原子地设置属性。
- **修复**：在输入 schema 中添加可选的 `properties: Dictionary` 参数；`add_child` 后遍历并用 `_convert_value_for_property` 设置属性。
- **测试**：用 `{"shape": "RectangleShape2D"}` 作为 properties 调用 add_resource "CollisionShape2D" → shape 已设置

### 1.5 get_debug_output(stderr)：桥接 script_error 消息（原 ★☆☆☆☆）— B5 #4

- **文件**：`addons/godot_mcp/tools/mcp_debugger_bridge.gd`，`_capture()` 在 ~L52-78
- **问题**：`_capture()` 只将 `message == "error"` 和 `message == "output"` 桥接到 `_output_events`。运行时 GDScript 错误使用 `"script_error"` 和 `"gdscript"` 消息名，这些消息记录到 `_captured_messages`，但**没有**桥接到 output。
- **修复**：在 `_capture()` 中添加分支：
  ```gdscript
  if message == "script_error" or message.begins_with("script_error:"):
      var error_msg: String = str(data[0]) if data.size() > 0 else ""
      var error_file: String = str(data[1]) if data.size() > 1 else ""
      var error_line: int = int(data[2]) if data.size() > 2 else 0
      _append_output_event({...}, "stderr")
  ```
- **Godot API 证据**：GDScript 运行时错误通过 `EngineDebugger` 发送，消息名类似 `"script_error"`、`"gdscript"`。它们与 `"error"`（C++ 引擎错误）不同。Bridge 已通过前缀匹配将它们捕获到 `_captured_messages`，差距仅在于 `_output_events` 桥接。
- **测试**：运行游戏触发 GD.print_err("test") → get_debug_output(stderr) 捕获该错误

### 1.6 await_runtime_condition：实现真实轮询（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/debug_tools_native.gd`，`_tool_await_runtime_condition` 在 ~L2628
- **问题**：输入 schema 声明了 `poll_interval_ms` 和 `timeout_ms` 参数，但实现只调用一次 `_tool_evaluate_runtime_expression` 就立刻返回。没有轮询循环。
- **修复**：实现轮询循环：
  ```
  1. timeout_ms 默认值：10000（10 秒）
  2. poll_interval_ms 默认值：500
  3. 循环：调用 _request_runtime_probe("evaluate_expression", ...)
  4. 若 status="success" 且为真值 → 返回 condition_met=true
  5. 若 pending → OS.delay_msec(poll_interval_ms) 并重试
  6. 若超时 → 返回 condition_met=false, error="timeout"
  ```
- **测试**：await_runtime_condition("1 + 1 == 2") → 立即返回 true。await_runtime_condition("false") 设 timeout=1000 → 超时后返回 false

### 1.7 MCPRuntimeProbe 改为 Autoload —— **NEW (Issue 1)**

**影响所有 runtime 工具**（get_runtime_info / get_runtime_scene_tree / inspect_runtime_node / evaluate_runtime_expression / get_runtime_screenshot 等），原 B5 #5 从 wont-fix 升级为 fixable。

- **文件**：`addons/godot_mcp/runtime/mcp_runtime_probe.gd`，`_ready()` 在 L7-9，`_exit_tree()` 在 L16-20
- **根因**：`install_runtime_probe` 将探针作为当前场景的子节点添加（`debug_tools_native.gd` L1290-1310）。探针是一个 `extends Node`，在 `_ready()` 中通过 `EngineDebugger.register_message_capture("mcp", ...)` 注册，在 `_exit_tree()` 中通过 `EngineDebugger.unregister_message_capture("mcp")` 注销。当场景切换时（用户手动切换或编辑器场景操作），该节点被释放 → 捕获注册丢失 → 所有 `mcp:*` 消息静默丢弃 → runtime 工具永远返回 `status: pending`。
- **修复方案（二选一）**：

  **方案 A（推荐）**：在 `install_runtime_probe` 工具中，将探针添加为 `Engine.get_main_loop().root`（即 SceneTree root）的子节点，而不是 `scene_root`。SceneTree root 在场景切换时不会被释放。
  ```gdscript
  # debug_tools_native.gd _tool_install_runtime_probe 中
  # 改为：
  var tree := Engine.get_main_loop() as SceneTree
  if tree:
      tree.root.add_child(probe)  # 挂在 SceneTree root 下，不死
  else:
      scene_root.add_child(probe)  # 降级方案
  ```

  **方案 B（更彻底）**：在 `mcp_runtime_probe.gd` 中增加 `_enter_tree()` 重注册逻辑：
  ```gdscript
  func _enter_tree():
      _ensure_debugger_capture_registered()
      
  func _exit_tree():
      if EngineDebugger.is_active() and EngineDebugger.has_capture(CAPTURE_PREFIX):
          EngineDebugger.unregister_message_capture(CAPTURE_PREFIX)
      _capture_registered = false
      # 不要丢 _probe_ready_sent，以便重新加入树后重发
  ```
  这种方案能处理探针被移动到不同父节点的情况，但无法解决根场景卸载的问题。

- **影响范围**（原表 B5 #5 → 改为 fixable）：
  - evaluate_runtime_expression → 从 wont-fix 改为受本修复影响
  - inspect_runtime_node → 不再永远 pending
  - get_runtime_screenshot → 不再永远 pending
  - call_runtime_node_method → 不再永远 pending
  - get_runtime_info / get_runtime_scene_tree → 不再永远 pending
  - await/assert_runtime_condition → 不再永远 pending
- **测试**：install_runtime_probe → 切换场景 → 调用任何 runtime 工具 → 应该返回成功而非 pending

## Phase 2：低影响修复

### 2.1 get_editor_logs：Script Errors 面板回退方案（原 ★★☆☆☆）

- **文件**：`addons/godot_mcp/tools/debug_tools_native.gd`，`_get_editor_panel_logs()` 在 ~L3455
- **问题**：B5 #4 的修复部分实现（读取 Script Errors Tree 面板），但验证失败。
- **修复**：添加 `EditorLog` 文件读取器作为二级来源：
  ```
  读取 %appdata%/Godot/editor_log.txt 获取错误条目
  按项目 UUID 和时间戳过滤
  ```
- **替代方案**：添加 source_code="editor_log_file" 参数
- **注意**：这是回退方案。Script Errors 面板读取代码已存在，但可能有 UI 路径问题。

### 2.2 execute_script：多行支持（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/debug_tools_native.gd`，`_tool_execute_script` 在 L2956-2996
- **问题**：使用 `Expression` 类只支持单表达式——不支持 `for`/`if`/多个语句。
- **修复**：当代码包含换行或块关键字时，自动包装为 `execute_editor_script` 的方式：
  - 通过 `"\n" in code` 检测多行代码
  - 多行 → 委托给 `execute_editor_script` 包装机制
  - 单行 → 继续用 `Expression`（更快）
- **Godot API 证据**（context7）：`Expression.parse()` + `execute()` 只处理单表达式。`evaluating_expressions.md` 教程明确显示不支持多行。
- **测试**：execute_script 多行代码 → 成功；execute_script 简单表达式 → 快速路径

### 2.3 find_script_symbol_references：Autoload 感知（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/script_tools_native.gd`，`_tool_find_script_symbol_references` 在 ~L700-750
- **问题**：基于正则的搜索不理解 Autoload 单例概念。
- **修复**：在引用搜索中注入 Autoload 信息：
  ```
  收集匹配结果后，与 ProjectSettings 中的 Autoload 列表交叉引用
  如果符号以 "AutoloadName.method()" 形式引用，包含 Autoload 脚本路径
  ```
- **测试**：对 Autoload 脚本上的函数进行引用搜索 → 返回正确引用

### 2.4 rename_script_symbol：默认包含 .tscn（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/script_tools_native.gd`，`_tool_rename_script_symbol` 在 ~L830-890
- **问题**：`include_extensions` 默认值为 `[".gd", ".cs"]` — 漏掉了 .tscn 文件中的引用。
- **修复**：将默认值改为 `[".gd", ".cs", ".tscn"]`
- **测试**：对导出变量进行 dry-run 重命名 → .tscn 引用被包含

### 2.5 create_resource：数组/字典子属性支持（原 ★★★☆☆）

- **文件**：`addons/godot_mcp/tools/project_tools_native.gd`，`_tool_create_resource` 在 ~L590-670
- **问题**：`_convert_value_for_resource()` 不处理嵌套的 Array 或 Dictionary。
- **修复**：在 `_convert_value_for_resource()` 中增加递归转换：
  ```
  若 value 是 Array → 转换每个元素
  若 value 是 Dictionary → 转换每个值
  ```
- **测试**：用嵌套字典属性 create_resource → 正确保存

### 2.6 get_editor_screenshot 强制刷新视图 —— **NEW (Issue 2)**

- **文件**：`addons/godot_mcp/tools/editor_tools_native.gd`，`_tool_get_editor_screenshot` 在 L907-931
- **根因**：`viewport.get_texture().get_image()` 读取的是**当前已渲染**的帧缓冲内容。Godot 的视口渲染是异步的——在 `open_scene_from_path()` 之后，编辑器在下一帧空闲时才会重新绘制 3D/2D 视口。因此截图拿到的是前一个场景的旧帧缓冲。
- **修复**：在 `_tool_get_editor_screenshot` 中捕获前强制刷新渲染：
  ```gdscript
  # 在 viewport.get_texture() 之前插入：
  RenderingServer.force_draw()  # 强制 Godot 渲染管线刷新所有视口
  # 或：
  await get_tree().process_frame  # 等一帧
  # 然后才截取：
  var texture: ViewportTexture = viewport.get_texture()
  var image: Image = texture.get_image()
  ```
- **影响测试**：open_scene(SceneB) → get_editor_screenshot → 验证图片内容为 SceneB 而非 SceneA
- **替代方案**：在 `_tool_open_scene` 的 `open_scene_from_path()` 之后加 `RenderingServer.force_draw()`（能修复更多类似时序问题，但风险稍高）

## Phase 3：不修复/架构限制

| 问题 | 原因 |
|---|---|
| **save_scene** 不保存 execute_editor_script 的修改 (B5 #2) | execute_editor_script 需要把每次修改包装进 UndoRedoManager action。debug_tools_native.gd 和 scene_tools_native.gd 都需要做根本性架构改动。风险高，收益有限，直接用 .tscn 编辑更可行。 |
| **get_debug_stack_frames/variables** 仅在断点暂停时有效 | Godot ScriptEditorDebugger 只在 `is_breaked()==true` 时处理堆栈转储请求。运行时错误不会自动进入断点状态。这是 Godot 编辑器 API 的约束。 |
| **运行时 node create/delete/update** 不持久 | 设计如此——runtime probe 修改的是正在运行的游戏进程内存。持久化需要编辑器端保存场景，这是不同的工具。 |
| **simulate_runtime_input_action** 释放效果不确定 | 没有游戏侧反馈循环。Probe 确认消息已发送，但不能确认游戏已处理。添加确认需要游戏代码通过 EngineDebugger 回复。 |

## 工具状态汇总

| 原评分 | 工具 | 阶段 | 修复复杂度 |
|---|---|---|---|
| ★★★★☆ | create_node / delete_node | 1.1 | 中 |
| ★★★☆☆ | update_node_property | FIXED（1.2 小缺口） | 小 |
| ★★★☆☆ | batch_update_node_properties | FIXED（1.2 小缺口） | 小 |
| ★★★☆☆ | get_node_properties | 1.3 | 小 |
| ★★★☆☆ | add_resource | 1.4 | 小 |
| ★★☆☆☆ | save_scene | WONT FIX (B5 #2) | — |
| ★★☆☆☆ | validate_script | FIXED | — |
| ★★☆☆☆ | detect_broken_scripts | FIXED | — |
| ★★☆☆☆ | audit_project_health | FIXED | — |
| ★★☆☆☆ | get_editor_logs(editor_panel) | 2.1 | 中 |
| ★☆☆☆☆ | get_debug_output(stderr) | 1.5 (B5 #4) | 小 |
| ★★☆☆☆ | get_debug_output(stdout) | 1.5（一并处理） | 小 |
| ★★☆☆☆ | get_debugger_messages | 1.5（一并处理） | 小 |
| ★★★☆☆ | get_debug_stack_frames/variables | WONT FIX | — |
| ★★★☆☆ | inspect_runtime_node | 1.7（SceneTree root） | 中 |
| ★★☆☆☆ | evaluate_runtime_expression | **改：1.7（原 B5 #5）** | 中 |
| ★★★☆☆ | get_runtime_screenshot | 1.7（SceneTree root） | 中 |
| ★★★☆☆ | call_runtime_node_method | 1.7（SceneTree root） | 中 |
| ★★★☆☆ | create/delete/update_runtime_node | WONT FIX（设计如此） | — |
| ★★★☆☆ | simulate_runtime_input_action/event | WONT FIX | — |
| ★★★☆☆ | await/assert_runtime_condition | 1.6 + 1.7 | 中 |
| ★★★☆☆ | execute_script | 2.2 | 中 |
| ★★★☆☆ | execute_editor_script | WONT FIX (B5 #2) | — |
| ★★★☆☆ | find_script_symbol_def/ref | 2.3 | 小 |
| ★★★☆☆ | rename_script_symbol | 2.4 | 小 |
| ★★★☆☆ | create_resource | 2.5 | 小 |
| ★★★☆☆ | get_editor_screenshot | **NEW：2.6** | 小 |
| ★★★★☆ | evaluate_debug_expression | WONT FIX（需要断点） | — |
| ★★★★★ | get_runtime_info | **改：1.7（之前未标注）** | 中 |
| ★★★★★ | get_runtime_scene_tree | **改：1.7（之前未标注）** | 中 |
| ★★★★★ | get_runtime_performance_snapshot | **改：1.7（之前未标注）** | 中 |
| ★★★★★ | get_runtime_memory_trend | **改：1.7（之前未标注）** | 中 |

## 验证策略

对每个 Phase 1 修复：
1. 在 `test/unit/tools/` 或 `test/unit/` 下创建/更新单元测试
2. 修复覆盖：正常路径 + 错误路径 + 边界情况
3. 运行 GUT 全量测试套件（必须 0 失败）
4. 更新 `docs/debugging/godot_mcp_tools_summary.md` 中的评分
