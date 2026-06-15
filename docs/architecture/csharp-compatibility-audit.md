# 工具 C# 适配分析报告

检查了所有工具源码，按 C# 支持程度分类。

## 1. 已有 C# 支持的工具（✅ 良好）

| 工具 | 文件 | 支持情况 |
|------|------|---------|
| `modify_script` | `script_tools_native.gd:1495` | `PathValidator.validate_file_path(..., [".gd", ".cs"])` — 路径验证已包含 .cs |
| `open_script_at_line` | `script_tools_native.gd:1793` | `validate_file_path(..., [".gd", ".cs"])` — 支持 .cs |
| `analyze_script` | `script_tools_native.gd` | `validate_file_path(..., [".gd", ".cs"])` — 支持 .cs |
| `search_in_files` | `script_tools_native.gd` | 可配置 `include_extensions`，默认含 `.cs` |
| `list_project_script_symbols` | `script_tools_native.gd` | 有独立的 `_index_csharp_symbols()` 解析器 |
| `find_script_symbol_definition` | `script_tools_native.gd` | 有独立的 `_find_csharp_symbol_definitions()` |
| `find_script_symbol_references` | `script_tools_native.gd` | 搜索 .cs 文件 |
| `rename_script_symbol` | `script_tools_native.gd` | 支持 .cs 文件中的符号重命名 |

## 2. 工具当前状态

| 工具 | 状态 | 文件 | 说明 |
|------|------|------|------|
| **`attach_script`** | ✅ 2026-06-15 已修复 | `script_tools_native.gd:1898` | 路径验证 `[.gd]` → `[.gd, .cs]`，`load() + set_script()` 对 CSharpScript 同样有效 |
| **`create_script`** | ✅ 2026-06-15 已修复 | `script_tools_native.gd:1343` | 路径验证 + 新增 `_get_csharp_script_template()` 6 种模板 |
| **`read_script`** | ✅ 2026-06-15 已修复 | `script_tools_native.gd:1252` | 纯文本读取，路径验证 `[.gd]` → `[.gd, .cs]` |
| **`list_project_scripts`** | ✅ 2026-06-15 已修复 | `script_tools_native.gd:614` | `_collect_scripts()` 增加 `or file_name.ends_with(".cs")` |
| **`get_current_script`** | ✅ 已验证无需修改 | `script_tools_native.gd` | 描述已是通用文案，`ScriptEditor.get_current_script()` 对 .gd 和 .cs 均有效 |
| **`modify_script`** | ✅ 2026-06-15 描述更新 | `script_tools_native.gd:1436` | 一直就支持 .cs，只更新了描述文本 |
| **`validate_script`** | ❌ 架构限制 | `script_tools_native.gd:1935` | 使用 `GDScript.new().reload()` 做语法检查，C# 需 `dotnet build` |
| **`execute_editor_script`** | ❌ 架构限制 | `debug_tools_native.gd:3251` | 内部用 `GDScript` 类编译执行 |
| **`evaluate_runtime_expression`** | ❌ 架构限制 | `debug_tools_native.gd` | Godot `Expression` 类只支持 GDScript |
| **`call_runtime_node_method`** | ❌ 架构限制 | `debug_tools_native.gd` | 对 C# 方法参数传递不稳定，`int→float` 自动转型 |

## 3. 核心问题分析

### 3.1 路径验证阻塞

`PathValidator.validate_file_path(path, allowed_extensions)` 是 5 个工具被阻塞的直接原因。解决方式是修改第 2 个参数。但部分工具有更深层依赖：

### 3.2 attach_script — 已修复 ✅

`_tool_attach_script` 的**实际逻辑**（1908-1927 行）对 `.cs` 和 `.gd` 文件是一样的：
```gdscript
var script_res: Script = load(script_path)  # load() 对 C# 和 GDScript 都有效
target_node.set_script(script_res)           # set_script() 对 C# 脚本也有效
```

**修复：** 1898 行 `[".gd"]` → `[".gd", ".cs"]`。实测验证通过。

### 3.3 create_script — 已修复 ✅

`create_script` 的模板系统原有只生成 GDScript 语法。

**修复：** 新增 `_get_csharp_script_template()`，支持 6 种 C# 模板（empty/node/characterbody2d/characterbody3d/area2d/area3d）。`_tool_create_script` 根据 `.cs` 扩展名自动选择模板。

### 3.4 read_script — 已修复 ✅

`read_script` 就是 `FileAccess.open` + `file.get_as_text()`。不依赖脚本类型。

**修复：** 路径验证 `[".gd"]` → `[".gd", ".cs"]`。实测验证通过。

### 3.5 validate_script — GDScript 专用

`validate_script` 使用 `GDScript.new().source_code = content` 然后调用 `reload()` 来检查语法错误。C# 无法在 Godot 编辑器 GDScript 环境中编译。**需要用 `dotnet build` 间接验证**。

### 3.6 execute_editor_script — 架构限制

`execute_editor_script` 通过创建 `GDScript` 实例来编译执行代码。C# 代码不能在 GDScript 引擎中运行。但可以换个思路：在 Godot .NET 中，可以用 `execute_editor_script` 执行 GDScript 来加载/保存场景，然后用现有的 `modify_script` 编辑 `.cs` 文件。

### 3.7 list_project_scripts — 已修复 ✅

`_collect_scripts`（614 行）原有只检查 `.ends_with(".gd")`。

**修复：** 增加 `or file_name.ends_with(".cs")`。描述和文档也已更新。

---

## 4. 修改方案

### 4.1 简单修复（路径验证 + 收集过滤）— ✅ 已完成

| 工具 | 改动 | 状态 |
|------|------|------|
| `attach_script` | `[".gd"]` → `[".gd", ".cs"]` | ✅ 实测验证通过 |
| `read_script` | `[".gd"]` → `[".gd", ".cs"]` | ✅ 实测验证通过 |
| `list_project_scripts` | 增加 `or file_name.ends_with(".cs")` | ✅ 实测验证通过 |
| `get_current_script` | 描述已是通用文案，无需修改 | ✅ 已验证 |

### 4.2 中等修复（create_script 增加 C# 模板）— ✅ 已完成

`create_script` 已完成的修改：
1. ✅ 路径验证 `[".gd"]` → `[".gd", ".cs"]`
2. ✅ 新增 `_get_csharp_script_template(template_name, script_class_name)` 方法
3. ✅ 在 `_tool_create_script` 中根据 `.cs` 扩展名自动选择 C# 模板
4. ✅ 描述和参数文档更新

支持 6 种 C# 模板：`empty`(Node), `node`(Node含_Ready+_Process), `characterbody2d`(含MoveAndSlide), `characterbody3d`(含MoveAndSlide), `area2d`, `area3d`。

实测验证：`create_script` → `read_script` → `modify_script` 全链路通过。

### 4.3 低优先级（架构限制）

| 工具 | 建议 |
|------|------|
| `validate_script` | 对 `.cs` 文件返回说明信息："C# validation requires dotnet build. Run 'dotnet build' in the project directory." |
| `execute_editor_script` | 保持 GDScript-only。在文档中标注。 |

---

## 5. 最终状态（2026-06-15 更新）

| 类别 | 数量 | 工具 |
|------|------|------|
| 已有 + 已修复 C# 支持 | **14** | modify_script, open_script_at_line, analyze_script, search_in_files, 4 个符号索引工具, **attach_script** ✅, **read_script** ✅, **create_script** ✅, **list_project_scripts** ✅, **get_current_script** ✅ |
| 架构限制（GDScript-only）| 3 | validate_script, execute_editor_script, evaluate_runtime_expression |

**一句话结论：** 所有 10 个 `script_tools` 中 7 个已获得 C# 支持（包括本次新增的 `attach_script`、`read_script`、`create_script`、`list_project_scripts`）。仅剩 3 个 Godot 架构限制的工具保持 GDScript-only。
