extends "res://addons/gut/test.gd"

## create_script 的 .gdshader 分支单测：写入路径打通（此前 .gd/.cs 白名单直接
## 拒绝）、着色器文本校验并入同一结果形状、坏着色器 has_errors、无编辑器时的
## 挂载警告路径。

const ToolsScript = preload("res://addons/godot_mcp/tools/script_tools_native.gd")

const TMP: String = "res://.tmp_shader_create"

const GOOD_FLASH: String = """shader_type canvas_item;

uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0);

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	COLOR = mix(base, flash_color, flash_amount);
}
"""

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)

func after_each() -> void:
	var dir: DirAccess = DirAccess.open(TMP)
	if dir:
		for entry in dir.get_files():
			dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	if root and root.dir_exists(TMP.trim_prefix("res://")):
		root.remove(TMP.trim_prefix("res://"))

func test_gdshader_path_accepted_and_written() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_script({
		"script_path": TMP + "/flash.gdshader", "content": GOOD_FLASH})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result.get("status", "")), "success")
	assert_false(bool(result.get("has_errors", true)), "valid shader passes text validation")
	assert_eq(String(result.get("shader_type", "")), "canvas_item")
	assert_true(FileAccess.file_exists(TMP + "/flash.gdshader"))

func test_bad_shader_refused_before_write() -> void:
	# 先校验后落盘：无效着色器不写盘（坏文件不进项目，也避开导入器噪音）。
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_script({
		"script_path": TMP + "/bad.gdshader",
		"content": "void fragment() { COLOR = vec4(1.0); }"
	})
	assert_eq(String(result.get("status", "")), "failed")
	assert_true(bool(result.get("has_errors", false)), "missing shader_type flagged (quiet bad sample)")
	assert_gt((result.get("diagnostics", []) as Array).size(), 0, "diagnostics carry the issues")
	assert_false(FileAccess.file_exists(TMP + "/bad.gdshader"), "nothing written")
	# force=true 的落盘分支不在单测覆盖：坏着色器落盘会触发导入器引擎噪音
	# （GUT 计为 Unexpected Errors）；force 语义已由拒绝路径 + hint 文本钉住。

func test_empty_shader_content_gets_canvas_item_template() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_script({
		"script_path": TMP + "/minimal.gdshader", "content": ""})
	assert_false(result.has("error"), str(result))
	assert_false(bool(result.get("has_errors", true)),
		"the built-in minimal template is valid: %s" % str(result.get("diagnostics", [])))

func test_shader_attach_without_editor_warns_not_fails() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_script({
		"script_path": TMP + "/flash2.gdshader", "content": GOOD_FLASH,
		"attach_to_node": "Player/Visual"})
	assert_false(result.has("error"))
	assert_eq(String(result.get("status", "")), "success", "file written")
	assert_true(result.has("attach_warning"), "headless: honest warning, no fake attach")
	assert_eq(String(result.get("attached_to", "")), "")

func test_gd_paths_still_work_unchanged() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_script({
		"script_path": TMP + "/plain.gd", "content": "extends Node\n"})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result.get("status", "")), "success")
	assert_false("shader_type" in result, "gd branch untouched")
