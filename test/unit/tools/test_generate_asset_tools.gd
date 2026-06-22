extends "res://addons/gut/test.gd"

# Unit tests for the generate_asset asset-generation adapter tool in
# project_tools_native.gd. Covers parameter validation, offline procedural
# image/audio generation, deterministic seeding, the external-provider
# unconfigured fall-back, byte validation, and the prompt manifest.
#
# Tests run headlessly (no editor), so reimport is always skipped with a
# reason; success-path tests only assert the file lands on disk.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"
const TMP_DIR: String = "res://.test_tmp_generate_asset"

var _tools: RefCounted = null

func before_each():
	_tools = load(TOOL_SCRIPT).new()
	_cleanup_tmp_dir()

func after_each():
	_cleanup_tmp_dir()
	_tools = null

func _cleanup_tmp_dir():
	if not DirAccess.dir_exists_absolute(TMP_DIR):
		return
	var dir: DirAccess = DirAccess.open(TMP_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(TMP_DIR)

func _tmp_path(file_name: String) -> String:
	return TMP_DIR.path_join(file_name)

# --- parameter validation ---------------------------------------------------

func test_missing_type():
	var result: Dictionary = _tools._tool_generate_asset({"prompt": "x", "resource_path": _tmp_path("a.png")})
	assert_has(result, "error", "Missing type should error")

func test_invalid_type():
	var result: Dictionary = _tools._tool_generate_asset({"type": "mesh", "prompt": "x", "resource_path": _tmp_path("a.png")})
	assert_has(result, "error", "Unknown type should error")

func test_missing_prompt():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "resource_path": _tmp_path("a.png")})
	assert_has(result, "error", "Missing prompt should error")

func test_missing_resource_path():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x"})
	assert_has(result, "error", "Missing resource_path should error")

func test_image_type_rejects_audio_extension():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": _tmp_path("a.wav")})
	assert_has(result, "error", "Image asset with .wav path should error")

func test_audio_type_rejects_image_extension():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sfx", "prompt": "x", "resource_path": _tmp_path("a.png")})
	assert_has(result, "error", "Audio asset with .png path should error")

func test_invalid_provider():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": _tmp_path("a.png"), "provider": "bogus"})
	assert_has(result, "error", "Unknown provider should error")

# --- placeholder image generation -------------------------------------------

func test_placeholder_image_success():
	var path: String = _tmp_path("hero.png")
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "blue hero", "resource_path": path})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(result.get("category"), "image", "Category should be image")
	assert_true(FileAccess.file_exists(path), "PNG file should be written")
	assert_gt(int(result.get("size_bytes", 0)), 0, "Should report non-zero size")
	assert_eq(result.get("generator", {}).get("mode"), "procedural_image", "Generator mode should be procedural_image")

func test_placeholder_image_explicit_pattern():
	var path: String = _tmp_path("frame.png")
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "texture", "prompt": "ui frame", "resource_path": path,
		"pattern": "frame", "width": 32, "height": 32
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(result.get("generator", {}).get("pattern"), "frame", "Pattern should be honored")
	assert_eq(result.get("generator", {}).get("width"), 32, "Width should be honored")

func test_placeholder_image_is_loadable_texture():
	var path: String = _tmp_path("load_me.png")
	_tools._tool_generate_asset({"type": "icon", "prompt": "coin icon", "resource_path": path})
	var img: Image = Image.new()
	var err: Error = img.load(path)
	assert_eq(err, OK, "Generated PNG should load as a valid Image")
	assert_eq(img.get_width(), 64, "Default width should be 64")

func test_placeholder_image_deterministic():
	var a: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "same prompt", "resource_path": _tmp_path("a.png")})
	var b: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "same prompt", "resource_path": _tmp_path("b.png")})
	assert_eq(a.get("generator", {}).get("pattern"), b.get("generator", {}).get("pattern"), "Same prompt should pick same pattern")
	assert_eq(a.get("generator", {}).get("seed"), b.get("generator", {}).get("seed"), "Same prompt should produce same seed")

# --- placeholder audio generation -------------------------------------------

func test_placeholder_audio_tres_success():
	var path: String = _tmp_path("zap.tres")
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "sfx", "prompt": "laser zap", "resource_path": path, "duration": 0.2
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_eq(result.get("category"), "audio", "Category should be audio")
	assert_true(FileAccess.file_exists(path), "Audio resource should be written")
	var stream: Resource = load(path)
	assert_true(stream is AudioStreamWAV, "Saved .tres should load as AudioStreamWAV")

func test_placeholder_audio_wav_success():
	var path: String = _tmp_path("coin.wav")
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "audio", "prompt": "coin", "resource_path": path,
		"waveform": "square", "frequency": 880.0, "duration": 0.1
	})
	assert_eq(result.get("status"), "success", "Should succeed")
	assert_true(FileAccess.file_exists(path), "WAV file should be written")
	assert_eq(result.get("generator", {}).get("waveform"), "square", "Waveform should be honored")

func test_audio_default_frequency_from_prompt():
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "sfx", "prompt": "explosion", "resource_path": _tmp_path("boom.tres"), "duration": 0.1
	})
	assert_gt(float(result.get("generator", {}).get("frequency", 0.0)), 0.0, "Frequency should auto-derive to > 0")

# --- prompt manifest --------------------------------------------------------

func test_manifest_written_by_default():
	var path: String = _tmp_path("with_manifest.png")
	_tools._tool_generate_asset({"type": "sprite", "prompt": "recorded prompt", "resource_path": path})
	assert_true(FileAccess.file_exists(path + ".gen.json"), "Manifest should be written by default")
	var text: String = FileAccess.get_file_as_string(path + ".gen.json")
	assert_string_contains(text, "recorded prompt", "Manifest should contain the prompt")

func test_manifest_suppressed_when_disabled():
	var path: String = _tmp_path("no_manifest.png")
	_tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": path, "record_prompt": false})
	assert_false(FileAccess.file_exists(path + ".gen.json"), "Manifest should not be written when disabled")

# --- reimport behavior (headless) -------------------------------------------

func test_reimport_skipped_headless():
	var result: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": _tmp_path("ri.png")})
	assert_false(bool(result.get("reimported")), "Reimport should be skipped without an editor interface")
	assert_has(result, "reimport_skipped_reason", "Should report why reimport was skipped")

# --- external provider ------------------------------------------------------

func test_external_unconfigured_without_endpoint():
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "texture", "prompt": "x", "resource_path": _tmp_path("ext.png"), "provider": "external"
	})
	assert_eq(result.get("status"), "unconfigured", "External provider without endpoint should be unconfigured")
	assert_has(result, "message", "Unconfigured result should include guidance")
	assert_false(FileAccess.file_exists(_tmp_path("ext.png")), "No file should be written when unconfigured")

func test_external_missing_api_key_env():
	var result: Dictionary = _tools._tool_generate_asset({
		"type": "texture", "prompt": "x", "resource_path": _tmp_path("ext.png"),
		"provider": "external", "endpoint": "https://example.com/gen",
		"api_key_env": "DEFINITELY_UNSET_ENV_VAR_FOR_TEST"
	})
	assert_has(result, "error", "Missing api key env var should error")

# --- byte validation helper -------------------------------------------------

func test_validate_png_bytes():
	var png: PackedByteArray = PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
	assert_true(_tools._validate_asset_bytes(png, "image"), "PNG magic should validate as image")
	assert_false(_tools._validate_asset_bytes(png, "audio"), "PNG magic should not validate as audio")

func test_validate_wav_bytes():
	var wav: PackedByteArray = PackedByteArray([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0])
	assert_true(_tools._validate_asset_bytes(wav, "audio"), "RIFF magic should validate as audio")
	assert_false(_tools._validate_asset_bytes(wav, "image"), "RIFF magic should not validate as image")

func test_validate_rejects_short_or_garbage():
	assert_false(_tools._validate_asset_bytes(PackedByteArray([1, 2]), "image"), "Too-short buffer should fail")
	assert_false(_tools._validate_asset_bytes(PackedByteArray([1, 2, 3, 4]), "image"), "Garbage bytes should fail")

# --- byte landing helper ----------------------------------------------------

func test_land_asset_bytes_rejects_invalid():
	var result: Dictionary = _tools._land_asset_bytes(PackedByteArray([1, 2, 3, 4]), _tmp_path("bad.png"), "image")
	assert_has(result, "error", "Invalid bytes should not land")
	assert_false(FileAccess.file_exists(_tmp_path("bad.png")), "Invalid bytes should not write a file")

func test_land_asset_bytes_writes_valid():
	var png: PackedByteArray = PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	var result: Dictionary = _tools._land_asset_bytes(png, _tmp_path("ok.png"), "image")
	assert_false(result.has("error"), "Valid bytes should land without error")
	assert_true(FileAccess.file_exists(_tmp_path("ok.png")), "Valid bytes should be written to disk")
