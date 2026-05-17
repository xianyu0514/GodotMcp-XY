# Godot MCP工具经验总结

> 生成时间：2026-05-16  
> 基于项目：竖屏跑酷游戏Demo (Godot 4.6 + GDScript)

---

## 一、场景/节点操作类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `get_scene_tree` / `get_scene_structure` | ★★★★★ | 完全符合 | 无 |
| `create_node` / `delete_node` | ★★★★★ | 完全符合 | **已修复**：嵌套实例的owner计算已被修正，EditorUndoRedoManager包装确保场景保存正确 |
| `update_node_property` | ★★★★☆ | 基本符合 | **已修复**：TYPE_OBJECT分支支持res://路径和ClassDB.instantiate；ResourceLoader.exists()验证返回清晰错误 |
| `batch_update_node_properties` | ★★★★☆ | 基本符合 | **同上修复** |
| `get_node_properties` | ★★★★☆ | 基本符合 | **已修复**：Resource类型属性返回结构化元数据（type/resource_type/resource_path/resource_name），替代不可读的`<Object#null>` |
| `rename_node` / `move_node` / `duplicate_node` | ★★★★★ | 完全符合 | 无 |
| `add_resource` | ★★★★☆ | 基本符合 | **已修复**：新增可选的`properties: Dictionary`参数，支持创建节点时原子设置属性（如shape = RectangleShape2D） |
| `set_anchor_preset` | ★★★★★ | 完全符合 | 无 |
| `connect_signal` / `disconnect_signal` | ★★★★★ | 完全符合 | 无 |

---

## 二、脚本操作类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `create_script` | ★★★★★ | 完全符合 | 无 |
| `modify_script` | ★★★★★ | 完全符合 | 无 |
| `read_script` | ★★★★★ | 完全符合 | 无 |
| `analyze_script` | ★★★★★ | 完全符合 | 无 |
| `validate_script` | ★★★★☆ | 基本符合 | **已修复**：首次失败后注入Autoload声明重试，autoload_aware=true脚本返回warning而非error |
| `attach_script` | ★★★★★ | 完全符合 | 无 |
| `open_script_at_line` | ★★★★★ | 完全符合 | 无 |

---

## 三、项目扫描/分析类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `detect_broken_scripts` | ★★★★☆ | 基本符合 | **已修复**：复用validate_script的Autoload注入重试机制，autoload感知脚本归为warning级别 |
| `audit_project_health` | ★★★★☆ | 基本符合 | **已修复**：broken_scripts部分使用新的autoload感知分级 |
| `list_project_scripts` / `list_project_scenes` | ★★★★★ | 完全符合 | 无 |
| `get_project_settings` / `get_project_info` | ★★★★★ | 完全符合 | 无 |
| `list_project_input_actions` | ★★★★★ | 完全符合 | 无 |
| `list_project_autoloads` | ★★★★★ | 完全符合 | 无 |
| `list_project_global_classes` | ★★★★★ | 完全符合 | 无 |
| `get_class_api_metadata` | ★★★★★ | 完全符合 | 无 |
| `search_in_files` | ★★★★★ | 完全符合 | 无 |
| `find_script_symbol_definition` / `find_script_symbol_references` | ★★★★☆ | 基本符合 | 对Autoload全局名称的引用可能找不到 |
| `rename_script_symbol` | ★★★★☆ | 基本符合 | dry-run预览正常，实际重命名未测试 |

---

## 四、场景生命周期类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `create_scene` | ★★★★★ | 完全符合 | 无 |
| `open_scene` | ★★★★★ | 完全符合 | Vibe Coding模式下需allow_ui_focus=true |
| `save_scene` | ★★☆☆☆ | **严重不符** | **通过execute_editor_script设置的属性不会被UndoRedo系统追踪，save_scene不会保存这些修改**。只有通过MCP的update_node_property（简单类型）设置的属性能被保存 |
| `close_scene_tab` / `list_open_scenes` | ★★★★★ | 完全符合 | 无 |
| `get_current_scene` | ★★★★★ | 完全符合 | 无 |
| `reload_project` | ★★★★★ | 完全符合 | 对清除Autoload缓存问题有效 |

---

## 五、运行/调试类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `run_project` / `stop_project` | ★★★★★ | 完全符合 | 无 |
| `get_editor_logs(source="editor_panel")` | ★★☆☆☆ | **严重不符** | **只能获取引擎启动信息，获取不到运行时脚本报错(Error/Warning堆栈)**。Godot的脚本错误走的是单独的"Script Errors"调试器面板，editor_panel日志不包含 |
| `get_editor_logs(source="mcp")` | ★★★★★ | 完全符合 | MCP服务器自身日志正常 |
| `get_debug_output(category="stderr")` | ★★★☆☆ | 部分符合 | **已修复**：_capture()现在将script_error/gdscript消息桥接到_output_events，经EngineDebugger的非致命运行时错误可被捕获 |
| `get_debug_output(category="stdout")` | ★★★☆☆ | 部分符合 | **已修复**：stdout桥接逻辑随stderr修复一并增强 |
| `get_debugger_messages` | ★★★☆☆ | 部分符合 | **已修复**：script_error/gdscript消息现被桥接到_output_events，get_debug_output可读取 |
| `get_debug_stack_frames` | ★★★☆☆ | 部分符合 | **仅在断点暂停(breaked)状态下有效**，运行时错误不会自动触发断点 |
| `get_debug_stack_variables` | ★★★☆☆ | 同上 | 同上 |
| `set_debugger_breakpoint` | ★★★★★ | 完全符合 | 无 |
| `debug_step_into/over/out/continue` | ★★★★★ | 完全符合 | 需配合await_debugger_state使用 |
| `evaluate_debug_expression` | ★★★★☆ | 基本符合 | 仅在断点暂停时可用 |

---

## 六、运行时(Runtime)探测类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `install_runtime_probe` / `remove_runtime_probe` | ★★★★★ | 完全符合 | 无 |
| `get_runtime_info` | ★★★★★ | 完全符合 | 无 |
| `get_runtime_performance_snapshot` | ★★★★★ | 完全符合 | 无 |
| `get_runtime_memory_trend` | ★★★★★ | 完全符合 | 无 |
| `get_runtime_scene_tree` | ★★★★★ | 完全符合 | 无 |
| `inspect_runtime_node` | ★★★★☆ | 基本符合 | **已修复**：1.7修复探针挂在SceneTree.root下，不再因场景切换死亡；配合await_runtime_condition轮询可以稳定获取数据 |
| `evaluate_runtime_expression` | ★★★★☆ | 基本符合 | **已修复**：1.7修复探针生命周期后不再返回永久的status=pending；await_runtime_condition增加真实轮询 |
| `get_runtime_screenshot` | ★★★★☆ | 基本符合 | **已修复**：1.7修复探针生命周期，截图确认消息不再因场景切换丢失 |
| `simulate_runtime_input_action` | ★★★★☆ | 基本符合 | 能触发InputMap动作，但pressed=false的释放效果不确定 |
| `simulate_runtime_input_event` | ★★★★☆ | 基本符合 | 未充分测试 |
| `call_runtime_node_method` | ★★★☆☆ | 部分符合 | 未充分测试 |
| `create/delete/update_runtime_node` | ★★★☆☆ | 部分符合 | 运行时修改不持久化 |
| `await_runtime_condition` / `assert_runtime_condition` | ★★★★☆ | 基本符合 | 需配合表达式使用，表达式可靠性受限 |

---

## 七、编辑器脚本执行类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `execute_script` | ★★★☆☆ | 部分符合 | 只能eval简单表达式，不支持多行语句 |
| `execute_editor_script` | ★★★☆☆ | 部分符合 | 支持多行代码，print()输出可捕获，**但设置的属性不会被UndoRedo追踪，save_scene不会保存** |

---

## 八、资源/导入类

| 工具 | 可用程度 | 符合定义 | 局限性 |
|------|---------|---------|--------|
| `create_resource` | ★★★★☆ | 基本符合 | 对简单资源类型有效 |
| `list_project_resources` | ★★★★★ | 完全符合 | 无 |
| `get_import_metadata` | ★★★★★ | 完全符合 | 无 |
| `reimport_resources` | ★★★★★ | 完全符合 | 无 |
| `get_resource_dependencies` / `scan_missing_resource_dependencies` | ★★★★★ | 完全符合 | 无 |
| `inspect_tileset_resource` | ★★★★★ | 完全符合 | 无 |

---

## 核心发现：5个B5级限制（严重不符定义）

### 1. validate_script / detect_broken_scripts 不识别Autoload
- **现象**：对引用Autoload全局名称(GameConfig/GameManager/InputHandler等)的脚本100%误报"Script has syntax errors"
- **实际**：运行时完全正常，是validate_script在独立环境中执行无法访问Autoload导致的
- **影响**：audit_project_health也不可信，broken_scripts数量不可参考
- **规避**：直接运行游戏验证，或人工检查代码语法
- **修复状态**：✅ **已修复** — validate_script和_analyze_script_diagnostics现在会在首次验证失败时，注入项目Autoload和全局类名称声明后重试。如果重试通过，标记`autoload_aware=true`，返回warning而非error。detect_broken_scripts将autoload_aware脚本归为warning级别。

### 2. save_scene 不保存execute_editor_script的修改
- **现象**：通过execute_editor_script设置的texture/shape/process_material等属性，save_scene后丢失
- **原因**：execute_editor_script的修改不被编辑器的UndoRedo系统追踪
- **影响**：无法通过MCP工具链完成"设置Resource属性→保存场景"的完整流程
- **规避**：直接编辑.tscn文件写入sub_resource/ext_resource声明
- **修复状态**：⚠️ **架构限制** — 需要将execute_editor_script中的每次属性修改包装进UndoRedo action，改动大且风险高，暂不修复

### 3. update_node_property 无法设置Resource引用
- **现象**：对texture/shape/process_material等属性，传入res://路径字符串不生效
- **原因**：MCP的属性更新只处理简单值类型，无法将字符串转换为Resource引用
- **影响**：无法通过MCP给Sprite2D设置texture、CollisionShape2D设置shape等
- **规避**：直接编辑.tscn文件，或在.tscn中预先声明sub_resource
- **修复状态**：✅ **已修复（本轮B5修复）** — update_node_property已添加TYPE_OBJECT分支，支持res://路径加载Resource并设置属性

### 4. 运行时错误/堆栈无法通过任何MCP工具获取
- **现象**：get_editor_logs(editor_panel)只返回引擎启动信息；get_debug_output(stderr)始终为空；get_debugger_messages只含MCP probe错误
- **原因**：Godot的脚本错误堆栈走的是独立的"Script Errors"调试器面板，MCP插件没有桥接到该面板
- **影响**：无法通过MCP自动化排查运行时脚本报错
- **规避**：人工查看调试器面板；或在脚本中加push_error()/print()通过stdout间接捕获；或设置断点+get_debug_stack_frames在暂停时检查
- **修复状态**：✅ **已部分修复** — (a) `_capture()`现在将"error"消息桥接到`_output_events`（category=stderr），`get_debug_output(category="stderr")`可获取运行时脚本错误（含file/line/function信息）；(b) `_get_editor_panel_logs()`现在同时读取Output面板和Script Errors面板（Tree控件），每条日志增加`panel`字段标识来源

### 5. evaluate_runtime_expression 不可靠
- **现象**：大部分调用返回`"status":"pending"`且无实际结果，偶尔能成功
- **原因**：MCP runtime probe挂在当前场景下，场景切换时`_exit_tree()`注销了EngineDebugger捕获；await_runtime_condition无轮询
- **影响**：无法可靠地在运行时查询游戏状态（如玩家位置、分数等）
- **规避**：使用inspect_runtime_node（部分有效）或get_runtime_scene_tree获取静态结构
- **修复状态**：**已修复** — 1.7修复：install_runtime_probe将探针挂在SceneTree.root下，场景切换不死亡；1.6修复：await_runtime_condition增加真实轮询（poll_interval_ms + timeout_ms）

修复验证结果
- ✅ 修复1：validate_script不识别Autoload — 成功
- ✅ 修复5：evaluate_runtime_expression — 根因已修复（探针不再因场景切换死亡），需验证测试确认

---

## 可靠的工作流替代方案

| 需求 | 不可靠的工具 | 推荐替代方案 |
|------|------------|------------|
| 脚本语法验证 | validate_script | **已修复**，autoload感知脚本自动重试后返回warning而非error |
| 设置Resource属性 | update_node_property | **已修复**，TYPE_OBJECT分支支持res://路径加载，ResourceLoader.exists()验证资源路径 |
| 属性持久化 | execute_editor_script + save_scene | 直接编辑.tscn/.tres文件（架构限制，暂不修复） |
| 获取运行时报错 | get_editor_logs / get_debug_output | **已修复**，script_error/gdscript消息桥接到_output_events |
| 运行时状态查询 | evaluate_runtime_expression | **已修复**，探针挂在SceneTree.root下不死 + await_runtime_condition真实轮询 |
| 场景属性设置 | update_node_property(Resource类型) | **已修复**，TYPE_OBJECT分支支持res://路径加载Resource并设置属性 |

---

## 推荐的MCP工作流最佳实践

1. **创建脚本**：用create_script/modify_script（完全可靠）
2. **创建场景结构**：用create_node/add_resource创建节点树（可靠）
3. **设置简单属性**：用update_node_property设置int/float/bool/Vector2/Color等（可靠）
4. **设置Resource属性**：直接编辑.tscn文件写入sub_resource/ext_resource（必须）
5. **保存场景**：save_scene只保存MCP工具链内创建/修改的简单属性，Resource属性需手动在文件中维护
6. **验证脚本**：运行游戏实际测试，不依赖validate_script
7. **截图验证**：get_runtime_screenshot + 文件系统glob检查确认截图生成
8. **性能监控**：get_runtime_performance_snapshot（完全可靠）
9. **输入模拟**：simulate_runtime_input_action（基本可靠）
10. **调试**：设置断点 → 运行 → 等待断点触发 → get_debug_stack_frames/variables（可靠但需手动触发）
