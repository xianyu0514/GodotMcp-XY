extends "res://addons/gut/test.gd"

var _sm = null

func before_each():
	_sm = load("res://addons/godot_mcp/native_mcp/settings_manager.gd").new()

func after_each():
	if _sm:
		var path: String = _sm.get_storage_path()
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_sm = null

func test_settings_manager_initializes():
	assert_ne(_sm, null, "Settings manager should initialize")

func test_default_settings_contain_language():
	var defaults = _sm.DEFAULT_SETTINGS
	assert_true(defaults.has("language"), "Default settings should contain 'language'")
	assert_eq(defaults["language"], "en", "Default language should be 'en'")

func test_load_settings_returns_defaults():
	var settings: Dictionary = _sm.load_settings()
	assert_eq(settings["transport_mode"], "http", "Default transport_mode should be 'http'")
	assert_eq(settings["http_port"], 9080, "Default http_port should be 9080")
	assert_eq(settings["log_level"], 2, "Default log_level should be 2")
	assert_eq(settings["rate_limit"], 1000, "Default rate_limit should be 1000")
	assert_eq(settings["language"], "en", "Default language should be 'en'")

func test_default_cloudflared_path_is_empty():
	var settings: Dictionary = _sm.load_settings()
	assert_true(settings.has("cloudflared_path"), "Default settings should contain 'cloudflared_path'")
	assert_eq(settings["cloudflared_path"], "", "Default cloudflared_path should be empty")

func test_cloudflared_path_persists():
	_sm.save_settings({"cloudflared_path": "/opt/cloudflared"})
	var loaded: Dictionary = _sm.load_settings()
	assert_eq(loaded["cloudflared_path"], "/opt/cloudflared", "Saved cloudflared_path should round-trip")

func test_save_and_load_settings():
	var test_settings: Dictionary = {
		"transport_mode": "stdio",
		"http_port": 9999,
		"auth_enabled": true,
		"language": "zh"
	}
	var saved: bool = _sm.save_settings(test_settings)
	assert_true(saved, "Save should succeed")

	var loaded: Dictionary = _sm.load_settings()
	assert_eq(loaded["transport_mode"], "stdio", "transport_mode should be 'stdio'")
	assert_eq(loaded["http_port"], 9999, "http_port should be 9999")
	assert_eq(loaded["auth_enabled"], true, "auth_enabled should be true")
	assert_eq(loaded["language"], "zh", "language should be 'zh'")

func test_load_settings_merges_with_defaults():
	var partial: Dictionary = {"http_port": 8000}
	_sm.save_settings(partial)
	var loaded: Dictionary = _sm.load_settings()
	assert_eq(loaded["http_port"], 8000, "Saved http_port should override default")
	assert_eq(loaded["transport_mode"], "http", "Default transport_mode should remain")
	assert_eq(loaded["rate_limit"], 1000, "Default rate_limit should remain")

func test_default_settings_not_modified_by_load():
	var orig_defaults = _sm.DEFAULT_SETTINGS.duplicate(true)
	var loaded: Dictionary = _sm.load_settings()
	# Verify original defaults unchanged
	assert_eq(_sm.DEFAULT_SETTINGS, orig_defaults, "DEFAULT_SETTINGS should not be mutated")

func test_config_file_name_is_mcp_settings():
	assert_eq(_sm.config_file_name, "mcp_settings.cfg", "Config file name should be mcp_settings.cfg")

func test_config_section_is_settings():
	assert_eq(_sm.config_section, "settings", "Config section should be 'settings'")