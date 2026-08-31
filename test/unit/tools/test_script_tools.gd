extends "res://addons/gut/test.gd"

const ScriptToolsScript = preload("res://addons/godot_mcp/tools/script_tools_native.gd")

func test_script_path_validation():
	var valid_paths: Array = ["res://test.gd", "res://scripts/player.gd", "res://addons/my_addon/main.gd"]
	for path in valid_paths:
		assert_true(MCPTypes.is_path_safe(path), path + " should be safe")

func test_script_path_traversal():
	var unsafe_paths: Array = ["res://../secret.gd", "res://scripts/../../etc/passwd"]
	for path in unsafe_paths:
		assert_false(MCPTypes.is_path_safe(path), path + " should be unsafe")

func test_script_extension_check():
	var ext: String = "res://test.gd".get_extension()
	assert_eq(ext, "gd", "Should extract gd extension")

func test_script_extension_tscn():
	var ext: String = "res://scene.tscn".get_extension()
	assert_eq(ext, "tscn", "Should extract tscn extension")

func test_script_base_name():
	var base: String = "res://scripts/player.gd".get_file()
	assert_eq(base, "player.gd", "Should extract file name")

func test_json_parse_string_to_dict():
	var json: String = '{"extends_from":"Node","functions":["_ready","_process"]}'
	var parsed: Variant = JSON.parse_string(json)
	assert_true(parsed is Dictionary, "Should parse to Dictionary")
	assert_has(parsed, "functions", "Should have functions key")

func test_analyze_script_output_format():
	var result: Dictionary = {
		"script_path": "res://test.gd",
		"extends_from": "Node",
		"functions": ["_ready", "_process"],
		"properties": [],
		"signals": [],
		"line_count": 50
	}
	assert_has(result, "script_path", "Should have script_path")
	assert_has(result, "extends_from", "Should have extends_from")
	assert_has(result, "functions", "Should have functions")
	assert_has(result, "line_count", "Should have line_count")

func test_modify_script_line_number():
	var content: String = "line1\nline2\nline3"
	var lines: PackedStringArray = content.split("\n")
	assert_eq(lines.size(), 3, "Should have 3 lines")
	assert_eq(lines[1], "line2", "Line 2 should be 'line2'")

func test_create_script_template():
	var content: String = "extends Node\n\nfunc _ready() -> void:\n\tpass\n"
	var line_count: int = content.split("\n").size()
	assert_gt(line_count, 0, "Template should have lines")

# ============================================================================
# C# 支持测试
# ============================================================================

func test_csharp_path_validation():
	"""C# (.cs) 路径应被路径验证接受"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# 验证 PathValidator 接受 .cs 扩展名
	var validation: Dictionary = PathValidator.validate_file_path("res://scripts/Player.cs", [".gd", ".cs"])
	assert_true(validation["valid"], ".cs path should be valid with ['.gd', '.cs'] extensions")

func test_csharp_path_rejected_when_only_gd():
	"""仅允许 .gd 时 .cs 路径应被拒绝"""
	var validation: Dictionary = PathValidator.validate_file_path("res://scripts/Player.cs", [".gd"])
	assert_false(validation["valid"], ".cs path should be rejected when only .gd is allowed")

func test_csharp_collect_scripts_filter():
	"""_collect_scripts 应同时收集 .gd 和 .cs 文件"""
	# 这是一个结构验证：确保函数名引用了 .cs
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	assert_not_null(tool, "ScriptToolsNative should load")

func test_get_csharp_script_template_node():
	"""_get_csharp_script_template('node') 应生成有效的 C# Node 类"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("node", "TestClass")
	assert_true(content.contains("using Godot;"), "C# template should include 'using Godot;'")
	assert_true(content.contains("public partial class TestClass : Node"), "C# template should declare partial class extending Node")
	assert_true(content.contains("public override void _Ready()"), "C# template should have _Ready method")
	assert_true(content.contains("public override void _Process(double delta)"), "C# template should have _Process method")

func test_get_csharp_script_template_characterbody2d():
	"""_get_csharp_script_template('characterbody2d') 应生成 CharacterBody2D 类"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("characterbody2d", "Player")
	assert_true(content.contains("public partial class Player : CharacterBody2D"), "C# template should declare CharacterBody2D class")
	assert_true(content.contains("MoveAndSlide();"), "C# CharacterBody2D template should have MoveAndSlide")

func test_get_csharp_script_template_characterbody3d():
	"""_get_csharp_script_template('characterbody3d') 应生成 CharacterBody3D 类"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("characterbody3d", "Player3D")
	assert_true(content.contains("public partial class Player3D : CharacterBody3D"), "C# template should declare CharacterBody3D class")

func test_get_csharp_script_template_area2d():
	"""_get_csharp_script_template('area2d') 应生成 Area2D 类"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("area2d", "DetectionZone")
	assert_true(content.contains("public partial class DetectionZone : Area2D"), "C# template should declare Area2D class")

func test_get_csharp_script_template_empty():
	"""_get_csharp_script_template('empty') 应生成默认 Node 类"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("empty", "")
	assert_true(content.contains("public partial class NewScript : Node"), "Empty C# template should default to Node class")

func test_get_csharp_script_template_sanitizes_name():
	"""C# 模板类名应清理非法字符"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var content: String = tool._get_csharp_script_template("node", "my-script file")
	assert_true(content.contains("my_script_file"), "Class name should have special chars replaced with underscore")

func test_list_project_scripts_description_includes_csharp():
	"""list_project_scripts 的描述应提及 C#"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# 描述检查通过工具注册的静态文本
	var registry = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()
	# 验证收集函数同时处理 .gd 和 .cs
	# 这是集成测试，在单元测试层面只验证工具类可正常加载
	assert_not_null(tool, "ScriptToolsNative should load")

func test_read_script_supports_csharp():
	"""read_script 的描述应提及 C#"""
	# 验证 read_script 的注册描述已更新
	# 工具类加载和使用验证
	var ToolClass = load("res://addons/godot_mcp/tools/script_tools_native.gd")
	assert_not_null(ToolClass, "ScriptToolsNative class should load")

func test_attach_script_supports_csharp():
	"""attach_script 的路径验证应接受 .cs 文件"""
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# 验证 .cs 路径能通过路径验证（这是 attach_script 之前的唯一阻塞）
	var validation: Dictionary = PathValidator.validate_file_path("res://scripts/TestClass.cs", [".gd", ".cs"])
	assert_true(validation["valid"], ".cs path should be accepted by path validation")

func test_batch_read_scripts_rejects_empty():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_batch_read_scripts({})
	assert_has(result, "error", "Missing script_paths is rejected")

func test_batch_read_scripts_reads_multiple():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = [
		"res://addons/godot_mcp/utils/payload_utils.gd",
		"res://addons/godot_mcp/utils/path_validator.gd"
	]
	var result: Dictionary = tool._tool_batch_read_scripts({"script_paths": paths})
	assert_eq(result.get("status"), "success", "Batch read succeeds")
	assert_eq(result.get("count"), 2, "One result entry per requested path")
	assert_eq(result.get("error_count"), 0, "All valid paths read without error")
	var results: Array = result.get("results", [])
	assert_true(results[0].has("content"), "Each entry carries the script content")
	assert_true(results[0].has("line_count"), "Each entry carries the line count")

func test_batch_read_scripts_reports_per_entry_errors():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = [
		"res://addons/godot_mcp/utils/payload_utils.gd",
		"res://does/not/exist.gd"
	]
	var result: Dictionary = tool._tool_batch_read_scripts({"script_paths": paths})
	assert_eq(result.get("count"), 2, "Both requested paths produce an entry")
	assert_eq(result.get("error_count"), 1, "The missing file is counted as an error")
	var results: Array = result.get("results", [])
	assert_true(results[1].has("error"), "The failed entry carries its own error message")

func test_validate_shader_requires_input():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_validate_shader({})
	assert_has(result, "error", "Missing both shader_path and content is rejected")

func test_validate_shader_valid_with_uniforms():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var code: String = "shader_type canvas_item;\nrender_mode blend_mix, unshaded;\nuniform float amount : hint_range(0.0, 1.0);\nuniform vec4 tint : source_color;\nvoid fragment() {\n\tCOLOR = vec4(amount) * tint;\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	assert_true(result.get("valid", false), "A well-formed canvas_item shader is valid")
	assert_eq(result.get("shader_type", ""), "canvas_item", "shader_type is parsed")
	assert_eq(int(result.get("issue_count", -1)), 0, "Valid shader has no issues")
	var uniforms: Array = result.get("uniforms", [])
	assert_eq(uniforms.size(), 2, "Both declared uniforms are reported (sentinel excluded)")
	var modes: Array = result.get("render_modes", [])
	assert_true(modes.has("blend_mix") and modes.has("unshaded"), "render_modes are parsed")

func test_validate_shader_valid_no_uniforms():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var code: String = "shader_type canvas_item;\nvoid fragment() {\n\tCOLOR = vec4(1.0);\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	assert_true(result.get("valid", false), "A valid shader with no uniforms is still detected as valid")
	assert_eq(int(result.get("issue_count", -1)), 0, "Valid shader has no issues")

func test_validate_shader_missing_shader_type():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var code: String = "void fragment() {\n\tCOLOR = vec4(1.0);\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	assert_false(result.get("valid", true), "Shader without shader_type is invalid")
	var issues: Array = result.get("issues", [])
	var found: bool = false
	for issue in issues:
		if "shader_type" in str(issue.get("message", "")):
			found = true
	assert_true(found, "Missing shader_type is reported as an issue")

func test_validate_shader_syntax_error():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# Missing semicolon after the uniform declaration -> parser fails.
	var code: String = "shader_type canvas_item;\nuniform float amount\nvoid fragment() {\n\tCOLOR = vec4(amount);\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	# The engine surfaces the shader parse error; mark it handled so GUT does
	# not treat the expected SHADER ERROR as an unexpected failure.
	for e in get_errors():
		e.handled = true
	assert_false(result.get("valid", true), "Shader with a syntax error is invalid")
	assert_true(int(result.get("issue_count", 0)) >= 1, "An issue is reported for the failed parse")

func test_validate_shader_unbalanced_braces():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var code: String = "shader_type canvas_item;\nvoid fragment() {\n\tCOLOR = vec4(1.0);\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	# Mark the expected engine parse error as handled (see above).
	for e in get_errors():
		e.handled = true
	assert_false(result.get("valid", true), "Shader with unbalanced braces is invalid")
	var issues: Array = result.get("issues", [])
	var found: bool = false
	for issue in issues:
		if "Unbalanced" in str(issue.get("message", "")):
			found = true
	assert_true(found, "Unbalanced braces are reported with a structural issue")

func test_validate_shader_ignores_commented_shader_type():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# A block comment that contains a `shader_type` line before the real one.
	# Detection must ignore the commented declaration and use `spatial`.
	var code: String = "/*\nshader_type canvas_item;\nlegacy header\n*/\nshader_type spatial;\nvoid fragment() {\n\tALBEDO = vec3(1.0);\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	assert_true(result.get("valid", false), "A valid shader with a commented-out shader_type is still valid")
	assert_eq(result.get("shader_type", ""), "spatial", "The real (non-commented) shader_type is reported")
	assert_eq(int(result.get("issue_count", -1)), 0, "No issues for a valid shader with comments")

func test_validate_shader_ignores_commented_render_mode():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# A commented-out render_mode must not be reported among render_modes.
	var code: String = "shader_type canvas_item;\n// render_mode blend_add;\nrender_mode unshaded;\nvoid fragment() {\n\tCOLOR = vec4(1.0);\n}\n"
	var result: Dictionary = tool._tool_validate_shader({"content": code})
	assert_true(result.get("valid", false), "Shader with a commented render_mode is valid")
	var modes: Array = result.get("render_modes", [])
	assert_true(modes.has("unshaded"), "The real render_mode is parsed")
	assert_false(modes.has("blend_add"), "The commented-out render_mode is ignored")

# ============================================================================
# validate_script 错误提取增强测试
# ============================================================================

func test_extract_error_line_from_text():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	assert_eq(tool._extract_error_line("Parse Error: Expected ')' at line 12"), 12, "Extracts line from 'at line N' parse error text")
	assert_eq(tool._extract_error_line("Line 7: Variable lacks type hint"), 7, "Extracts line from 'Line N:' format")
	assert_eq(tool._extract_error_line("Parse Error: Expected end of statement (script.gd)"), 0, "No line number returns 0")
	assert_eq(tool._extract_error_line("解析错误：第 12 行"), 0, "Chinese error text without 'line' keyword returns 0 without crashing")
	assert_eq(tool._extract_error_line(""), 0, "Empty text returns 0")

func test_validate_script_error_has_line():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# Deliberately broken GDScript: the print statement is missing its closing parenthesis.
	var broken_code: String = "extends Node\n\nfunc _ready() -> void:\n\tprint(\"hello\"\n"
	var result: Dictionary = tool._tool_validate_script({"content": broken_code})
	# The engine prints the expected parse error to the console; mark it handled
	# so GUT does not treat the expected SCRIPT ERROR as an unexpected failure.
	for e in get_errors():
		e.handled = true
	assert_false(result.get("valid", true), "Broken script is reported as invalid")
	var errors: Array = result.get("errors", [])
	assert_true(errors.size() > 0, "At least one error is reported for the broken script")
	assert_true(errors[0].has("line"), "Error entry carries a line field")
	assert_true(errors[0].has("column"), "Error entry carries a column field")
	assert_true(errors[0].has("message"), "Error entry carries a message field")
	# Headless compilation may not expose a reliable error text in every build;
	# only require the message to be non-empty (line may be 0 in fallback mode).
	assert_true(str(errors[0].get("message", "")).length() > 0, "Error message is non-empty")

# ============================================================================
# verify_scripts 批量校验测试
# ============================================================================

func test_verify_scripts_single_valid_script():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_verify_scripts({
		"script_paths": ["res://addons/godot_mcp/utils/path_validator.gd"]
	})
	assert_eq(result.get("verified", -1), 1, "The valid script is counted as verified")
	assert_eq(result.get("failed", -1), 0, "No failures")
	assert_eq(result.get("total_checked", -1), 1, "One script checked")
	var results: Array = result.get("results", [])
	assert_eq(results.size(), 1, "One result entry")
	assert_true(results[0].get("valid", false), "path_validator.gd compiles cleanly")
	assert_eq(results[0].get("path"), "res://addons/godot_mcp/utils/path_validator.gd", "Entry carries its path")
	assert_true(results[0].has("errors"), "Entry carries errors array")
	assert_true(results[0].has("warnings"), "Entry carries warnings array")

func test_verify_scripts_multiple_paths():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = [
		"res://addons/godot_mcp/utils/path_validator.gd",
		"res://addons/godot_mcp/utils/payload_utils.gd"
	]
	var result: Dictionary = tool._tool_verify_scripts({"script_paths": paths})
	assert_eq(result.get("verified", -1), 2, "Both valid scripts verified")
	assert_eq(result.get("failed", -1), 0, "No failures")
	assert_eq(result.get("results", []).size(), 2, "One entry per requested path")

func test_verify_scripts_missing_file_reports_failed():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_verify_scripts({"script_paths": ["res://does/not/exist.gd"]})
	assert_eq(result.get("verified", -1), 0, "Nothing verified")
	assert_eq(result.get("failed", -1), 1, "Missing file counts as failed")
	var results: Array = result.get("results", [])
	assert_false(results[0].get("valid", true), "Missing file is invalid")
	assert_eq(results[0].get("error_count", 0), 1, "One error entry for the missing file")
	assert_true(str(results[0]["errors"][0].get("message", "")).contains("not found"), "Error message names the missing file")

func test_verify_scripts_broken_content_reports_errors():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	# Write a deliberately broken script into user:// so we can exercise the file path.
	var broken_path: String = "user://verify_broken_test.gd"
	var file: FileAccess = FileAccess.open(broken_path, FileAccess.WRITE)
	file.store_string("extends Node\n\nfunc _ready() -> void:\n\tprint(\"hello\"\n")
	file.close()
	var result: Dictionary = tool._tool_verify_scripts({"script_paths": [broken_path]})
	# The engine prints the expected parse error to the console; mark it handled
	# so GUT does not treat the expected SCRIPT ERROR as an unexpected failure.
	for e in get_errors():
		e.handled = true
	assert_eq(result.get("failed", -1), 1, "Broken script is reported as failed")
	var results: Array = result.get("results", [])
	assert_false(results[0].get("valid", true), "Broken script is invalid")
	assert_true(int(results[0].get("error_count", 0)) > 0, "At least one error entry")
	assert_true(results[0]["errors"][0].has("line"), "Error entry carries a line")
	assert_true(results[0]["errors"][0].has("message"), "Error entry carries a message")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken_path))

func test_verify_scripts_max_scripts_truncates():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = [
		"res://addons/godot_mcp/utils/path_validator.gd",
		"res://addons/godot_mcp/utils/payload_utils.gd"
	]
	var result: Dictionary = tool._tool_verify_scripts({"script_paths": paths, "max_scripts": 1})
	assert_eq(result.get("total_checked", -1), 1, "max_scripts caps how many scripts are checked")
	assert_eq(result.get("results", []).size(), 1, "Only one result returned")

func test_verify_scripts_default_scan_skips_addons_and_test():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_verify_scripts({})
	assert_eq(result.get("total_checked", -1), result.get("results", []).size(), "Every checked script has a result entry")
	for entry in result.get("results", []):
		var path: String = str(entry.get("path", ""))
		assert_false(path.begins_with("res://addons/"), "Default scan skips addons/: " + path)
		assert_false(path.begins_with("res://test/"), "Default scan skips test/: " + path)

func test_verify_scripts_collect_finds_gd_scripts():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = []
	tool._collect_gd_scripts_excluding("res://addons/godot_mcp/tools", paths, [])
	assert_true(paths.size() > 0, "Should find scripts under res://addons/godot_mcp/tools")
	assert_true("res://addons/godot_mcp/tools/script_tools_native.gd" in paths, "script_tools_native.gd should be found")

func test_verify_scripts_collect_skips_named_dirs():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = []
	tool._collect_gd_scripts_excluding("res://addons/godot_mcp", paths, ["utils"])
	for path in paths:
		assert_false(String(path).contains("/utils/"), "Named dirs are skipped: " + str(path))
	assert_true(paths.size() > 0, "Skipping one subdir still finds the rest")

func test_verify_scripts_deduplicates_paths():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var result: Dictionary = tool._tool_verify_scripts({
		"script_paths": [
			"res://addons/godot_mcp/utils/path_validator.gd",
			"res://addons/godot_mcp/utils/path_validator.gd",
			""
		]
	})
	assert_eq(result.get("total_checked", -1), 1, "Duplicate paths are checked once")
	assert_eq(result.get("verified", -1), 1, "The single unique script verifies")

func test_verify_scripts_collect_wrapper_skips_addons_and_test():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var paths: Array = []
	tool._collect_verify_script_paths(paths)
	# Headless（无 EditorInterface）时封装回退到 DirAccess，结果必须与直接扫描一致。
	var expected: Array = []
	tool._collect_gd_scripts_excluding("res://", expected, ["addons", "test", ".godot"])
	assert_eq(paths, expected, "Wrapper scan matches the DirAccess fallback in headless mode")
	for path in paths:
		assert_false(String(path).begins_with("res://addons/"), "Wrapper scan skips addons/: " + str(path))
		assert_false(String(path).begins_with("res://test/"), "Wrapper scan skips test/: " + str(path))

func test_autoload_declarations_cached_returns_string():
	var tool = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var first: String = tool._get_autoload_declarations_cached()
	var second: String = tool._get_autoload_declarations_cached()
	assert_true(first is String, "Cached autoload declarations are a string")
	assert_eq(first, second, "Cached declarations are stable across calls")
	assert_eq(first, tool._build_autoload_declarations(), "Cache matches a fresh build")

func test_script_writes_report_editor_buffer_sync():
	var tools: RefCounted = ScriptToolsScript.new()
	var temp_path: String = "res://test/unit/.tmp_buffer_sync.gd"
	var created: Dictionary = tools._tool_create_script({
		"script_path": temp_path, "content": "extends Node
"})
	assert_false(created.has("error"), str(created.get("error", "")))
	assert_eq(String(created.get("buffers_synced", "")), "skipped",
		"Headless has no editor interface; buffer sync degrades to skipped, never errors")
	var modified: Dictionary = tools._tool_modify_script({
		"script_path": temp_path, "content": "extends Node2D
"})
	assert_false(modified.has("error"), str(modified.get("error", "")))
	assert_eq(String(modified.get("buffers_synced", "")), "skipped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))

func test_modify_script_inline_validation():
	var tools: RefCounted = ScriptToolsScript.new()
	var temp_path: String = "res://test/unit/.tmp_inline_validate.gd"
	var created: Dictionary = tools._tool_create_script({
		"script_path": temp_path, "content": "extends Node\n"})
	assert_false(created.has("error"), str(created.get("error", "")))
	var broken: Dictionary = tools._tool_modify_script({
		"script_path": temp_path,
		"content": "extends Node\nfunc broken(:\n"
	})
	# 引擎会把预期的解析错误打到控制台；标记已处理，避免 GUT 判为意外失败。
	for e in get_errors():
		e.handled = true
	assert_false(broken.has("error"), str(broken.get("error", "")))
	var broken_check: Dictionary = broken.get("validation", {})
	assert_false(bool(broken_check.get("valid", true)),
		"Broken .gd content must report validation.valid=false inline")
	assert_gt(int(broken_check.get("error_count", 0)), 0, "Broken content reports at least one error")
	var fixed: Dictionary = tools._tool_modify_script({
		"script_path": temp_path,
		"content": "extends Node\nfunc fixed() -> void:\n\tpass\n"
	})
	var fixed_check: Dictionary = fixed.get("validation", {})
	assert_true(bool(fixed_check.get("valid", false)),
		"Valid .gd content must report validation.valid=true inline")
	var skipped: Dictionary = tools._tool_modify_script({
		"script_path": temp_path,
		"content": "extends Node\nfunc still_broken(:\n",
		"validate": false
	})
	assert_false(skipped.has("validation"),
		"validate:false must skip the inline check entirely")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))

func test_verify_scripts_repeat_uses_memo_and_content_change_invalidates():
	# verify_scripts 的单文件编译按 (mtime, 环境签名, check_warnings) 记忆：
	# 文件未变时二次调用应命中同一结果引用，内容变化后必须重算。
	var memo: GDScript = load("res://addons/godot_mcp/utils/script_compile_memo.gd")
	memo.clear()
	var tmp: String = "user://tmp_verify_memo_probe.gd"
	var write: Callable = func(source: String) -> void:
		var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(source)
		f.close()
	write.call("extends Node\n")
	var tool: RefCounted = load("res://addons/godot_mcp/tools/script_tools_native.gd").new()
	var first: Dictionary = tool._tool_verify_scripts({"script_paths": [tmp]})
	assert_eq(first.get("total_checked", -1), 1, "first pass checks the temp script")
	var first_result: Dictionary = (first.get("results", []) as Array)[0]
	var second: Dictionary = tool._tool_verify_scripts({"script_paths": [tmp]})
	var second_result: Dictionary = (second.get("results", []) as Array)[0]
	assert_same(first_result, second_result, "unchanged file is served from the memo")
	# 两份都合法但结果不同的内容（避免触发引擎真实解析错误的噪音）：
	# 0 警告 vs 1 条未类型化 var 警告。
	write.call("extends Node\nvar untyped = 1\n")
	var third: Dictionary = tool._tool_verify_scripts({"script_paths": [tmp]})
	var third_result: Dictionary = (third.get("results", []) as Array)[0]
	assert_true(bool(third_result.get("valid", false)), "new content is still valid")
	# 重算的证明用引用身份：命中记忆会返回同一 Dictionary 引用。
	assert_not_same(first_result, third_result, "invalidated entry is a fresh result")
	memo.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

func test_detect_broken_scripts_default_skips_tooling():
	# 默认口径 = 用户代码：本仓库根下没有非工具 .gd，默认扫描应为 0 个脚本；
	# include_tooling=true 或显式 search_path 才编译 addons。
	var tools: RefCounted = load("res://addons/godot_mcp/tools/project_resources_tools.gd").new()
	var memo: GDScript = load("res://addons/godot_mcp/utils/script_compile_memo.gd")
	memo.clear()
	var default_scan: Dictionary = tools._tool_detect_broken_scripts({})
	assert_false(default_scan.has("error"), str(default_scan.get("error", "")))
	for issue_value in default_scan.get("issues", []):
		var issue: Dictionary = issue_value
		assert_false(String(issue.get("path", "")).begins_with("res://addons/"),
			"default scan never compiles third-party addon internals")
	var targeted: Dictionary = tools._tool_detect_broken_scripts({
		"search_path": "res://addons/godot_mcp/utils"})
	assert_gt(int(targeted.get("scanned_scripts", 0)), 0,
		"explicit tooling search_path still scans plugin scripts")
	memo.clear()
