extends "res://addons/gut/test.gd"

# configure_resource_import 的纯核心（.import 补丁 + 白名单）。
# 真实 reimport 走 EditorFileSystem，端到端在 English Rift 真机验收（报告 §14）。

const AssetsScript = preload("res://addons/godot_mcp/tools/project_assets_tools.gd")

var _fixture_root: String = ""

func before_each() -> void:
	_fixture_root = "res://.tmp_import_cfg_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_root))

func after_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(_fixture_root)
	if DirAccess.dir_exists_absolute(absolute):
		DirAccess.remove_absolute(absolute.path_join("sprite.png.import"))
		DirAccess.remove_absolute(absolute)
	_fixture_root = ""

func _write_import(content: String) -> String:
	var path: String = _fixture_root.path_join("sprite.png.import")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path

const TEXTURE_IMPORT: String = """[remap]

importer="texture"
type="CompressedTexture2D"
uid="uid://fixture2"

[deps]

source_file="res://art/sprite.png"

[params]

compress/mode=0
mipmaps/generate=false
detect_3d/compress_to=1
"""

func test_patch_applies_whitelisted_param():
	var import_path: String = _write_import(TEXTURE_IMPORT)
	var result: Dictionary = AssetsScript._patch_import_file(import_path, {"mipmaps/generate": true})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result["importer"]), "texture")
	assert_eq(bool(result["applied"]["mipmaps/generate"]), true)
	var reread: Dictionary = AssetsScript._patch_import_file(import_path, {})
	# ConfigFile 往返：再读验证落盘
	var config: ConfigFile = ConfigFile.new()
	assert_eq(config.load(import_path), OK)
	assert_eq(bool(config.get_value("params", "mipmaps/generate", null)), true, "补丁必须落盘")

func test_patch_refuses_unknown_param_and_lists_allowed():
	var import_path: String = _write_import(TEXTURE_IMPORT)
	var result: Dictionary = AssetsScript._patch_import_file(import_path, {"made_up/key": 1})
	assert_true(result.has("error"))
	assert_true(str(result["error"]).contains("mipmaps/generate"), "错误应列出该 importer 的合法键")

func test_patch_detects_importer_and_routes_whitelist():
	var wav_import: String = _fixture_root.path_join("sfx.wav.import")
	var file: FileAccess = FileAccess.open(wav_import, FileAccess.WRITE)
	file.store_string("[remap]\nimporter=\"wav\"\n\n[params]\nedit/loop_mode=0\n")
	file.close()
	var ok: Dictionary = AssetsScript._patch_import_file(wav_import, {"edit/loop_mode": 2})
	assert_false(ok.has("error"), str(ok))
	var cross: Dictionary = AssetsScript._patch_import_file(wav_import, {"mipmaps/generate": true})
	assert_true(cross.has("error"), "纹理键用在 wav 上必须拒绝")

func test_patch_rejects_non_import_file():
	var path: String = _fixture_root.path_join("garbage.import")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not an ini at all {{{")
	file.close()
	var result: Dictionary = AssetsScript._patch_import_file(path, {"compress/mode": 0})
	assert_true(result.has("error"), "非 INI 结构必须拒绝")
