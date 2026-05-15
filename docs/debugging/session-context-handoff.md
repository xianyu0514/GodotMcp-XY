# Godot MCP Native — 会话上下文交接文档

> 生成于 2026-05-15，用于跨会话交接工作进度

---

## 项目路径

`F:/gitProjects/Godot-MCP-Native`

## 项目概况

Godot 4.6.1 MCP（Model Context Protocol）工具插件，提供 154 个工具远程操控 Godot 编辑器。

---

## 本轮已完成的工作

### 一、MCP 工具限制修复（B类 8 个问题，全部已修复）

| # | 问题 | 修复方案 | 修改文件 | 实测状态 |
|---|------|---------|---------|---------|
| B1 | `execute_editor_script` 缩进Bug（P0） | `_spaces_to_tabs()`缩进转换 + `get_tree()`/`get_node()`代理方法 + `func`/`class`/`enum`自动提升到类级别 | `debug_tools_native.gd:3186-3224,3263-3272` | ✅ |
| B2 | `update_node_property` 无法设Resource（P0） | `_convert_value_for_property` 新增 `TYPE_OBJECT` 分支：`res://`→`load()`，类名→`ClassDB.instantiate()` | `node_tools_native.gd:1035-1042` | ✅ |
| B3 | `create_resource` properties未生效（P1） | 新增 `_convert_value_for_resource()` 类型转换 + `_parse_key_value_string()` 支持`{x:...,y:...,z:...}`字符串格式 | `project_tools_native.gd:1412-1484` | ✅ |
| B4 | `upsert_project_input_action` events（P1） | 已有修复（之前版本） | — | ✅ |
| B5 | `update_node_property` 无法设NodePath（P1） | `_convert_value_for_property` 新增 `TYPE_NODE_PATH` 分支 | `node_tools_native.gd:1032-1034` | ✅ |
| B6 | `validate_script` content缩进（P2） | 复用 `_spaces_to_tabs()` | `script_tools_native.gd:1947-1948,2033-2053` | ✅ |
| B7 | `connect_signal` PERSIST冲突（P2） | flags含CONNECT_PERSIST时返回warning | `node_tools_native.gd:1727-1736` | ✅ |
| B8 | `batch_scene_node_edits` 返回node_path为空（P2） | 用parent路径+node_name拼接替代`_make_friendly_path(created_node)` | `node_tools_native.gd:574-578` | ✅ |

**额外发现并修正**：Godot 4 中 `CONNECT_PERSIST=2`（非4），`CONNECT_ONE_SHOT=4`（非2），文档已全部修正。

### 二、其他问题澄清

| 问题 | 结论 |
|------|------|
| C3: push_warning/print 不输出到 editor_panel | 引擎架构限制（编辑器与运行时独立进程），替代方案：`get_editor_logs(source="runtime")` |
| D1: get_editor_screenshot 无法截运行时窗口 | 已有工具 `get_runtime_screenshot`（Runtime Probe 机制） |
| A4: PlaneShape3D 不在支持列表 | **Godot 4.6 已移除 PlaneShape3D**，替代为 `WorldBoundaryShape3D`，`create_resource` 可正常创建 |
| execute_script Expression 类限制 | 引擎设计限制，不可修复，用 `execute_editor_script` 替代 |

### 三、新增测试文件

- `test/unit/test_spaces_to_tabs.gd` — `_spaces_to_tabs()` 9个用例
- `test/unit/test_convert_resource_nodepath.gd` — Resource/NodePath转换 4个用例
- `test/unit/test_convert_resource_properties.gd` — `_convert_value_for_resource()` 14+7个用例（含`_parse_key_value_string`7个+KV/CSV字符串转换7个）
- `test/unit/test_add_resource_naming.gd` — 自动命名+冲突后缀 2个用例
- `test/unit/test_node_tools_convert.gd` — 22个用例（`_make_friendly_path`+`_convert_value_for_property`含NodePath+`_parse_key_value_string`+`_append_child_path`+KV字符串转换）
- `test/unit/test_execute_editor_script_split.gd` — 22个用例（`_count_indent`7个+`_spaces_to_tabs`8个+代码分离逻辑4个+`_normalize_indentation`1个）

### 四、更新的文档

- `docs/debugging/mcp-limitations.md` — 7个问题全部标注已修复，补充修复方案+代码位置+修复后行为+修复前后对比表
- `docs/debugging/development-summary.md` — 全面重写：B类7/7已修复、C3/D1已有替代方案、A4认知更新、工具评估表更新、效率瓶颈更新、经验教训更新、实测验证结果
- `docs/current/tools-reference.md` — 6个工具文档更新：update_node_property（NodePath+Resource）、add_resource（自动命名）、connect_signal（warning字段+flags修正）、validate_script（缩进转换）、execute_editor_script（缩进转换）、create_resource（properties类型转换）
- `docs/architecture/node-tools-implementation-plan.md` — CONNECT_PERSIST/ONE_SHOT 常量值修正

---

## 之前已完成的工作（本轮之前）

- 154 工具全量 MCP 验证：100% 通过
- Bug修复：`_serialize_animation_tree_state` 中 5 处 `float()` → `as float`
- Bug修复：`travel_runtime_animation_tree` 的 `match_fields` 积极修复
- 跨平台修复（6处）：`mcp_http_server.gd`、`editor_tools_native.gd`、`project_tools_native.gd`、`mcp_server_native.gd`、`resource_tools_native.gd`、`path_validator.gd`
- `get_editor_logs` 增强：新增 `source="editor_panel"` 获取 Godot 输出面板日志
- Tool Manager 描述多语言适配：`mcp_tool_item.gd`、`mcp_tool_group_item.gd`（代码完成，CSV翻译条目未生成）
- 验证报告归档：`docs/debugging/full-mcp-verification-154-tools/`（5份报告）
- 测试知识库：`docs/debugging/full-mcp-verification-154-tools/mcp-tool-testing-knowledge-base.md`

---

## 未完成的工作

### 高优先级

1. **Tool Manager 描述翻译 CSV 生成**：代码已支持翻译，但 `mcp_panel.csv` 尚未添加 154 个 `tool.desc.*` 翻译条目
   - 需从 7 个 `*_tools_native.gd` 提取所有 `register_tool()` 的 tool_name + description
   - 生成 `tool.desc.{tool_name}` 格式 key + 英文原文 + 中文翻译
   - 追加到 `addons/godot_mcp/translations/mcp_panel.csv`
2. **GUT 单元测试**：为 `mcp_tool_item.gd` 的 `_get_display_description` 新增测试

### 中优先级

3. **所有修改尚未提交 Git**

---

## 关键文件索引

### 源码
- 工具实现：`addons/godot_mcp/tools/*_tools_native.gd`（7个文件）
- 工具分类：`addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`
- 翻译CSV：`addons/godot_mcp/translations/mcp_panel.csv`
- UI组件：`addons/godot_mcp/ui/mcp_tool_item.gd`、`mcp_tool_group_item.gd`
- MCP核心：`addons/godot_mcp/mcp_server_native.gd`
- HTTP服务器：`addons/godot_mcp/native_mcp/mcp_http_server.gd`
- 运行时探针：`addons/godot_mcp/runtime/mcp_runtime_probe.gd`
- 路径验证：`addons/godot_mcp/utils/path_validator.gd`

### 文档
- 工具文档：`docs/current/tools-reference.md`
- 限制文档：`docs/debugging/mcp-limitations.md`
- 开发总结：`docs/debugging/development-summary.md`
- 跨平台报告：`docs/architecture/cross-platform-compatibility-report.md`
- 发布说明：`docs/architecture/release-notes.md`
- 测试知识库：`docs/debugging/full-mcp-verification-154-tools/mcp-tool-testing-knowledge-base.md`

### 测试
- GUT测试命令：`"f:/Godot/Godot_v4.6.1-stable_win64.exe" --headless --path "F:/gitProjects/Godot-MCP-Native" -s addons/gut/gut_cmdln.gd -gdir=res://test/unit/ -ginclude_subdirs -gexit`
- 新增测试：`test/unit/test_spaces_to_tabs.gd`、`test_convert_resource_nodepath.gd`、`test_convert_resource_properties.gd`、`test_add_resource_naming.gd`
- 已有测试：`test/unit/test_node_tools_convert.gd`、`test_mcp_runtime_probe.gd`、`test_editor_panel_logs.gd`、`test_mcp_http_server.gd`、`test_path_validator.gd`

---

## 关键注意事项

- **Godot 4.6 不支持 `float()` 构造函数**，必须用 `as float`
- **`AnimationNodeStateMachine.set_start_node()` 在 Godot 4.x 不存在**
- **PlaneShape3D 在 Godot 4.6 中已移除**，用 WorldBoundaryShape3D 替代
- **CONNECT_PERSIST=2, CONNECT_ONE_SHOT=4**（Godot 4 常量值，之前文档写反已修正）
- **`_request_runtime_probe` 首次调用返回 pending**，再次调用提取缓存响应
- **`execute_editor_script` 中**：用 `edited_scene` 访问场景，用 `_custom_print()` 输出，不能用 `get_tree()`
- **RichTextLabel.get_text() 返回空**，正确方法：`get_parsed_text()`
- **每次修改代码后必须**：更新测试、运行GUT验证、清理 `.codeartsdoer/temp/` 下的 `.gd` 文件和 `.tmp_*` 目录
- **全量GUT测试在headless模式下可能因内存不足崩溃**，建议用 `-gscript=` 参数逐个运行测试文件
