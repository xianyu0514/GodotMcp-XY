extends "res://addons/gut/test.gd"

# Unit tests for external asset-provider presets: the AssetProviderPresets
# catalog plus generate_asset's _resolve_external_config / _subst_placeholders
# layering (explicit params > preset template > config defaults) and the
# {prompt}/{width}/{height} substitution. No network calls are made.

const TOOL_SCRIPT: String = "res://addons/godot_mcp/tools/project_tools_native.gd"

var _tools: RefCounted = null

func before_each():
	_tools = load(TOOL_SCRIPT).new()

func after_each():
	_tools = null

# --- catalog ---------------------------------------------------------------

func test_preset_ids_are_known():
	var ids: Array = AssetProviderPresets.preset_ids()
	assert_eq(ids.size(), 4, "Four built-in presets are exposed")
	for preset_id in ids:
		assert_true(AssetProviderPresets.has_preset(preset_id), "preset_ids() entry should exist: " + str(preset_id))

func test_get_preset_returns_independent_copy():
	var a: Dictionary = AssetProviderPresets.get_preset("openai_image")
	a["endpoint"] = "mutated"
	var b: Dictionary = AssetProviderPresets.get_preset("openai_image")
	assert_eq(b.get("endpoint"), "https://api.openai.com/v1/images/generations", "Mutating a returned copy must not affect the catalog")

func test_label_for_unknown_returns_id():
	assert_eq(AssetProviderPresets.label_for("nope"), "nope")
	assert_true(AssetProviderPresets.label_for("openai_image").length() > 0)

# --- substitution ----------------------------------------------------------

func test_subst_placeholders_string():
	assert_eq(_tools._subst_placeholders("a {prompt} b", "hero", 64, 32), "a hero b")

func test_subst_placeholders_pure_numeric_become_int():
	assert_eq(_tools._subst_placeholders("{width}", "x", 128, 256), 128)
	assert_eq(_tools._subst_placeholders("{height}", "x", 128, 256), 256)

func test_subst_placeholders_mixed_size_stays_string():
	assert_eq(_tools._subst_placeholders("{width}x{height}", "x", 64, 48), "64x48")

func test_subst_placeholders_recurses_dict_and_array():
	var out: Variant = _tools._subst_placeholders({"p": "{prompt}", "list": ["{width}"]}, "cat", 10, 20)
	assert_eq(out["p"], "cat")
	assert_eq(out["list"][0], 10)

# --- resolution ------------------------------------------------------------

func test_resolve_preset_fills_template():
	var cfg: Dictionary = _tools._resolve_external_config({"preset": "openai_image", "prompt": "a knight", "width": 256, "height": 256}, "image")
	assert_false(cfg.has("error"), "valid preset should resolve without error")
	assert_eq(cfg["endpoint"], "https://api.openai.com/v1/images/generations")
	assert_eq(cfg["api_key_env"], "OPENAI_API_KEY")
	assert_eq(cfg["response_field"], "data.0.b64_json")
	assert_eq(cfg["preset"], "openai_image")
	assert_eq(cfg["request_body"]["prompt"], "a knight", "prompt placeholder substituted")
	assert_eq(cfg["request_body"]["size"], "256x256", "size placeholder substituted")

func test_resolve_unknown_preset_errors():
	var cfg: Dictionary = _tools._resolve_external_config({"preset": "does_not_exist", "prompt": "x"}, "image")
	assert_true(cfg.has("error"), "unknown preset must error")

func test_resolve_category_mismatch_errors():
	var cfg: Dictionary = _tools._resolve_external_config({"preset": "elevenlabs_tts", "prompt": "x"}, "image")
	assert_true(cfg.has("error"), "audio preset for an image request must error")

func test_resolve_explicit_params_override_preset():
	var cfg: Dictionary = _tools._resolve_external_config({
		"preset": "openai_image", "prompt": "x",
		"endpoint": "https://example.com/custom", "api_key_env": "MY_KEY"
	}, "image")
	assert_eq(cfg["endpoint"], "https://example.com/custom", "explicit endpoint overrides preset")
	assert_eq(cfg["api_key_env"], "MY_KEY", "explicit api_key_env overrides preset")

func test_resolve_local_preset_keeps_numeric_size():
	var cfg: Dictionary = _tools._resolve_external_config({"preset": "local_sd_webui", "prompt": "tree", "width": 96, "height": 72}, "image")
	assert_eq(cfg["api_key_env"], "", "local preset needs no api key")
	assert_eq(cfg["request_body"]["width"], 96, "width substituted as int for local SD")
	assert_eq(cfg["request_body"]["height"], 72, "height substituted as int for local SD")

# --- end-to-end fallbacks --------------------------------------------------

func test_external_without_endpoint_or_preset_is_unconfigured():
	var res: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": "res://.test_tmp_xx/a.png", "provider": "external"})
	assert_eq(res.get("status", ""), "unconfigured", "external with no preset/endpoint falls back to unconfigured")

func test_external_preset_missing_key_errors_before_network():
	var res: Dictionary = _tools._tool_generate_asset({"type": "sprite", "prompt": "x", "resource_path": "res://.test_tmp_xx/a.png", "provider": "external", "preset": "openai_image", "api_key_env": "DEVIN_TEST_UNSET_KEY_XYZ"})
	assert_true(res.has("error"), "missing env var should error")
	assert_true(str(res["error"]).find("DEVIN_TEST_UNSET_KEY_XYZ") != -1, "error names the missing env var")
