# AGENTS.md - Godot MCP Project Guidelines
## PowerShell 7.6.1 Path
- **Install path**: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.1.0_x64__8wekyb3d8bbwe\pwsh.exe
- Before using, verify the path exists:
  - If it exists, use it
  - If not found, fall back to system default
- Always prefer PowerShell 7.6.1 for file writes
## Code Language Policy
- **No Chinese characters allowed in any code files**
- All text in code files must be in English
- Chinese is only allowed in this file and README.zh.md and docs

## Build & Run Commands
- **Run Godot Project**: Open project.godot in Godot Editor

## Code Style Guidelines

### GDScript (Godot)
- Use snake_case for variables, methods, and function names
- Use PascalCase for classes
- Use type hints where possible: `var player: Player`
- Follow Godot singleton conventions (e.g., `Engine`, `OS`)
- Prefer signals for communication between nodes

### General
- Use descriptive names
- Keep functions small and focused
- Add comments for complex logic
- Error handling: use assertions in GDScript

### 测试规范（强制）
每次修改代码必须在 `test/` 中更新或创建对应的测试用例：
- **直接测试**：覆盖本次改动的逻辑（正常路径 + 边界条件 + 错误处理）
- **影响范围测试**：识别并测试可能被本次改动影响的关联模块（如修改了公共方法签名、导出变量、信号、策略类等，需覆盖所有调用方）
- 禁止提交仅有代码改动而无测试更新的 commit

### 临时文件清理（强制）
每次代码修改结束后，必须清理以下临时文件：
1. **CodeArts diff 备份**：`.codeartsdoer/temp/` 下的 `.gd` 文件
   - 这些文件是 CodeArts diff 对比时生成的备份，会被 Godot LSP 误扫描
   - 残留会导致 `Class "XXX" hides a global script class` 错误
2. **测试临时资源**：项目根目录下 `.tmp_*` 文件夹
   - Python 集成测试（`test/integration/`）运行时会创建 `.tmp_*` 临时目录和脚本
   - 残留会被 `detect_broken_scripts` 扫描到并报语法错误
   - 常见临时目录：`.tmp_project_diagnostics/`, `.tmp_script_references/`, `.tmp_script_rename/`, `.tmp_runtime_*/`, `.tmp_export/` 等
   - 清理命令：删除项目根目录下所有 `.tmp_*` 目录
3. **集成测试临时目录**：`test/integration/.tmp_*` 文件夹

**无论是否使用 CodeArts，都需要检查并清理上述临时文件**（测试产生的临时文件与 CodeArts 无关）。

## New Tool Workflow

When creating a new MCP tool, you MUST complete ALL of the following steps:

### Step 1: Implement the tool handler
In the appropriate `*_tools_native.gd` file under `addons/godot_mcp/tools/`:
- Create `_register_<tool_name>(server_core)` and `_tool_<tool_name>(params) -> Dictionary` functions
- Call `server_core.register_tool()` with **8 arguments** (including category and group):
  ```
  server_core.register_tool(
      "tool_name",                    # 1. name
      "Description...",               # 2. description
      input_schema,                   # 3. input schema dict
      Callable(self, "_tool_..."),    # 4. callable
      output_schema,                  # 5. output schema dict
      annotations_dict,               # 6. annotations
      "core"/"supplementary",         # 7. category
      "Group-Name"                    # 8. group (use "X-Advanced" for supplementary)
  )
  ```
  - **core** tools: used for basic operations, always visible
  - **supplementary** tools: advanced features, require opt-in via tool management panel

### Step 2: Register in tool classifier
Edit `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd`:
- Add `{"name": "tool_name", "category": "core"/"supplementary", "group": "Group-Name"}` entry in `_build_classifications()` array
- Then update `test/unit/test_mcp_tool_classifier.gd`:
  - Update `test_all_154_tools_registered` with the new total count (increment by 1)
  - Update `test_core_tools_count_within_limit` or `test_supplementary_tools_count` accordingly
  - If supplementary, add `assert_true(_classifier.is_supplementary_tool("tool_name"), "...")` assertion

### Step 3: Add unit tests
In `test/unit/tools/` or `test/unit/`:
- Create or extend a test file following `extends "res://addons/gut/test.gd"`
- Use `load("res://addons/godot_mcp/tools/...").new()` instead of class_name (GUT CLI mode limitation)
- Cover: missing params → returns error, invalid params → returns error, edge cases
- Reference GUT patterns in `.trae/skills/gut-mcp-testing/SKILL.md`
- Run tests: `& "f:/Godot/Godot_v4.6.1-stable_win64.exe" --headless --path "F:/gitProjects/Godot-MCP-Native" -s addons/gut/gut_cmdln.gd -gdir=res://test/unit/ -ginclude_subdirs -gexit`

### Step 4: Update tool documentation
Edit `docs/current/tools-reference.md`:
- Update the overview table with new tool count (adjust rows as needed)
- Add a new tool entry following the existing format:

### Step 4b: Update addon READMEs
Edit `addons/godot_mcp/README.md` and `addons/godot_mcp/README.zh.md`:
- Update the tool counts and descriptions in the overview section to match the new total
- If a new tool category group was added, add a corresponding section row in the feature table
- Ensure English and Chinese versions stay in sync

### Step 4c: Write the tool entry
  ```
  ### N. tool_name
  
  Description...
  
  **参数**：
  | 参数 | 类型 | 必需 | 描述 |
  ...
  
  **返回值**：
  | 字段 | 类型 | 描述 |
  ...
  
  **注解**：`readOnlyHint=...`, `destructiveHint=...`, `idempotentHint=...`, `openWorldHint=...`
  
  ---
  ```
- Update the summary line at the end with the correct total count

### Step 5: Verify
- Run full GUT test suite (command in Step 3)
- Verify 0 failures before committing

## PR 审查与合并流程

参见完整规范文档：
- **Skill 文件：** `.cursor/skills/pr-review-merge/SKILL.md`
- **规范文档：** `docs/development/pr-review-merge-spec.md`

核心步骤：
1. 创建集成分支 `integration/pr-review`，合并 PR 代码
2. 逐文件审查代码、测试覆盖、规范
3. 运行 GUT 全量测试（0 failures 为硬性要求）
4. 阻断问题 → Request Changes 退回 PR 作者；小修复 → 直接推送到 PR head 分支
5. 修复后重新验证，记录审查文档
6. 通过 GitHub Squash Merge 合并 PR（PR 自动关闭）
7. 清理本地集成分支

注意：`_debounce_save()` 必须在 UI toggle handler 中调用，否则设置无法持久化。

## 154 工具 MCP 测试知识库

**文档入口：** `docs/debugging/full-mcp-verification-154-tools/mcp-tool-testing-knowledge-base.md`

包含：测试环境要求、154 工具分组与测试参数、遇到的问题与解决方案、Godot 版本兼容性矩阵、Runtime Probe 通信机制、测试技巧。

验证报告归档目录：`docs/debugging/full-mcp-verification-154-tools/`
- `core-tools-mcp-verification-2026-05-12.md` — 30 核心 + 35 补充工具验证
- `project-advanced-mcp-verification-2026-05-13.md` — 23 Project-Advanced 工具验证
- `debug-advanced-mcp-verification-2026-05-13.md` — 67 Debug-Advanced 工具验证
- `full-verification-supplement-2026-05-13.md` — 补充验证 + 最终汇总（154/154 = 100%）

### 关键注意事项

- **Godot 4.6 不支持 `float()` 构造函数**，必须用 `as float` 进行类型转换
- **`AnimationNodeStateMachine.set_start_node()` 在 Godot 4.x 不存在**，用 `add_node()` 替代
- **Runtime Probe TileMap 工具仅支持旧式 `TileMap` 节点**，不支持 Godot 4.3+ 的 `TileMapLayer`
- **`_request_runtime_probe` 首次调用返回 pending**，再次调用提取已缓存响应
- **`match_fields` 必须与实际响应数据匹配**，不要包含异步更新的字段
- **`execute_editor_script` 中**：用 `edited_scene` 访问场景，用 `_custom_print()` 输出，不能用 `get_tree()`
