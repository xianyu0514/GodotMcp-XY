extends "res://addons/gut/test.gd"

# Unit tests for manage_localization (⑥ localization workflow).
# Covers the four actions (list/extract/import/export) over normal paths,
# edge cases (merge/dry_run/CJK round-trip) and error handling. All file I/O
# uses user:// and register=false so tests never mutate the repo's
# project.godot or res:// tree.

var _tools: RefCounted = null
var _base: String = "user://i18n_test_%d" % (Time.get_ticks_usec())

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	_base = "user://i18n_test_%d" % (Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_base)

func after_each() -> void:
	_tools = null
	_remove_recursive(_base)

func _remove_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var full: String = path.path_join(name)
		if dir.current_is_dir():
			_remove_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write_text(path: String, content: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()

func _write_csv(path: String, rows: Array) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	for row in rows:
		f.store_csv_line(PackedStringArray(row))
	f.close()

# --- dispatch / errors -----------------------------------------------------

func test_missing_action_errors():
	assert_true(_tools._tool_manage_localization({}).has("error"), "missing action errors")

func test_unknown_action_errors():
	assert_true(_tools._tool_manage_localization({"action": "frobnicate"}).has("error"), "unknown action errors")

# --- list (read-only) ------------------------------------------------------

func test_list_returns_structure():
	var r: Dictionary = _tools._tool_manage_localization({"action": "list"})
	assert_true(bool(r.get("success", false)), "list succeeds")
	assert_true(r.has("translations"), "list has translations array")
	assert_true(r.has("count"), "list has count")

# --- extract ---------------------------------------------------------------

func test_extract_finds_scene_properties():
	_write_text(_base + "/menu.tscn", "[gd_scene format=3]\n[node name=\"L\" type=\"Label\"]\ntext = \"Start Game\"\ntooltip_text = \"Begin\"\n")
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": _base + "/tr.csv", "include_scripts": false})
	assert_true(bool(r.get("success", false)), "extract succeeds")
	var keys: Array = r.get("new_keys", [])
	assert_true(keys.has("Start Game"), "found text property")
	assert_true(keys.has("Begin"), "found tooltip_text property")

func test_extract_finds_tr_in_scripts():
	_write_text(_base + "/x.gd", "func _ready():\n\tvar s = tr(\"Greeting\")\n\tprint(atr(\"Farewell\"))\n")
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": _base + "/tr.csv"})
	var keys: Array = r.get("new_keys", [])
	assert_true(keys.has("Greeting"), "found tr() call")
	assert_true(keys.has("Farewell"), "found atr() call")

func test_extract_skips_scripts_when_disabled():
	_write_text(_base + "/x.gd", "func _ready():\n\tvar s = tr(\"ShouldSkip\")\n")
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": _base + "/tr.csv", "include_scripts": false})
	assert_false(Array(r.get("new_keys", [])).has("ShouldSkip"), "scripts skipped when include_scripts=false")

func test_extract_extracts_cjk():
	_write_text(_base + "/menu.tscn", "[gd_scene format=3]\n[node name=\"L\" type=\"Label\"]\ntext = \"开始游戏\"\n")
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": _base + "/tr.csv", "include_scripts": false})
	var keys: Array = r.get("new_keys", [])
	assert_true(keys.has("开始游戏"), "CJK source string extracted intact")

func test_extract_merges_and_preserves_existing():
	_write_csv(_base + "/tr.csv", [["keys", "en", "zh_CN"], ["Existing", "Existing EN", "已存在"]])
	_write_text(_base + "/menu.tscn", "[gd_scene format=3]\n[node name=\"L\" type=\"Label\"]\ntext = \"NewKey\"\n")
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": _base + "/tr.csv", "include_scripts": false})
	var new_keys: Array = r.get("new_keys", [])
	assert_true(new_keys.has("NewKey"), "new key reported")
	assert_false(new_keys.has("Existing"), "pre-existing key not re-added")
	# verify the existing translation survived in the rewritten CSV
	var f: FileAccess = FileAccess.open(_base + "/tr.csv", FileAccess.READ)
	var found_zh: bool = false
	while not f.eof_reached():
		var cols: PackedStringArray = f.get_csv_line()
		if cols.size() >= 3 and cols[0] == "Existing" and cols[2] == "已存在":
			found_zh = true
	f.close()
	assert_true(found_zh, "existing translation preserved after merge")

func test_extract_dry_run_does_not_write():
	_write_text(_base + "/menu.tscn", "[gd_scene format=3]\ntext = \"X\"\n")
	var csv: String = _base + "/tr.csv"
	var r: Dictionary = _tools._tool_manage_localization({"action": "extract", "scan_dir": _base, "csv_path": csv, "include_scripts": false, "dry_run": true})
	assert_true(bool(r.get("success", false)), "dry_run succeeds")
	assert_false(FileAccess.file_exists(csv), "dry_run writes no CSV")

func test_extract_missing_dir_errors():
	assert_true(_tools._tool_manage_localization({"action": "extract", "scan_dir": "user://does_not_exist_dir_xyz"}).has("error"), "missing scan_dir errors")

# --- unescape (string-literal decoding) ------------------------------------

func test_unescape_basic_escapes():
	assert_eq(_tools._i18n_unescape("a\\nb"), "a\nb", "\\n -> newline")
	assert_eq(_tools._i18n_unescape("a\\tb"), "a\tb", "\\t -> tab")
	assert_eq(_tools._i18n_unescape("say \\\"hi\\\""), "say \"hi\"", "\\\" -> quote")
	assert_eq(_tools._i18n_unescape("it\\'s"), "it's", "\\' -> apostrophe")

func test_unescape_escaped_backslash_before_n():
	# `\\n` is an escaped backslash followed by the letter n; it must stay a
	# literal backslash + n, NOT collapse into a newline.
	assert_eq(_tools._i18n_unescape("C:\\\\new_folder"), "C:\\new_folder", "escaped backslash + n stays literal")
	assert_eq(_tools._i18n_unescape("\\\\t"), "\\t", "escaped backslash + t stays literal")

func test_unescape_unknown_escape_is_preserved():
	assert_eq(_tools._i18n_unescape("a\\xb"), "a\\xb", "unknown escape kept verbatim")

func test_unescape_trailing_backslash():
	assert_eq(_tools._i18n_unescape("end\\"), "end\\", "trailing lone backslash kept")

# --- import ----------------------------------------------------------------

func test_import_builds_translation_files():
	var csv: String = _base + "/tr.csv"
	_write_csv(csv, [["keys", "en", "zh_CN"], ["TITLE", "My Game", "我的游戏"], ["HELLO", "Hello", "你好"]])
	var r: Dictionary = _tools._tool_manage_localization({"action": "import", "csv_path": csv, "out_dir": _base, "register": false})
	assert_true(bool(r.get("success", false)), "import succeeds")
	assert_eq(Array(r.get("locales", [])), ["en", "zh_CN"], "locales from header")
	assert_eq(int(r.get("key_count", 0)), 2, "two keys imported")
	assert_false(bool(r.get("registered", true)), "register=false skips registration")
	assert_true(FileAccess.file_exists(_base + "/zh_CN.translation"), "zh_CN.translation written")

func test_import_cjk_roundtrip():
	var csv: String = _base + "/tr.csv"
	_write_csv(csv, [["keys", "zh_CN"], ["TITLE", "我的游戏"]])
	_tools._tool_manage_localization({"action": "import", "csv_path": csv, "out_dir": _base, "register": false})
	var zh: Resource = ResourceLoader.load(_base + "/zh_CN.translation")
	assert_true(zh is Translation, "loads a Translation")
	assert_eq(zh.get_message("TITLE").length(), 4, "CJK value intact (4 chars)")

func test_import_dry_run_writes_nothing():
	var csv: String = _base + "/tr.csv"
	_write_csv(csv, [["keys", "en"], ["A", "a"]])
	var r: Dictionary = _tools._tool_manage_localization({"action": "import", "csv_path": csv, "out_dir": _base, "register": false, "dry_run": true})
	assert_true(bool(r.get("success", false)), "dry_run import succeeds")
	assert_false(FileAccess.file_exists(_base + "/en.translation"), "dry_run writes no .translation")

func test_import_missing_csv_errors():
	assert_true(_tools._tool_manage_localization({"action": "import", "csv_path": "user://no_such_file.csv"}).has("error"), "missing CSV errors")

func test_import_bad_header_errors():
	var csv: String = _base + "/bad.csv"
	_write_csv(csv, [["notkeys", "en"], ["A", "a"]])
	assert_true(_tools._tool_manage_localization({"action": "import", "csv_path": csv}).has("error"), "header not starting with 'keys' errors")

func test_import_single_column_errors():
	var csv: String = _base + "/one.csv"
	_write_csv(csv, [["keys"], ["A"]])
	assert_true(_tools._tool_manage_localization({"action": "import", "csv_path": csv}).has("error"), "no locale columns errors")

# --- export ----------------------------------------------------------------

func test_export_roundtrips_csv():
	var csv: String = _base + "/in.csv"
	_write_csv(csv, [["keys", "en", "zh_CN"], ["TITLE", "My Game", "我的游戏"]])
	var im: Dictionary = _tools._tool_manage_localization({"action": "import", "csv_path": csv, "out_dir": _base, "register": false})
	var out_csv: String = _base + "/out.csv"
	var r: Dictionary = _tools._tool_manage_localization({"action": "export", "csv_path": out_csv, "translations_paths": im.get("written", [])})
	assert_true(bool(r.get("success", false)), "export succeeds")
	assert_eq(int(r.get("key_count", 0)), 1, "one key exported")
	assert_true(FileAccess.file_exists(out_csv), "export wrote CSV")
	# verify CJK present in exported CSV
	var f: FileAccess = FileAccess.open(out_csv, FileAccess.READ)
	var ok: bool = false
	while not f.eof_reached():
		var cols: PackedStringArray = f.get_csv_line()
		if cols.size() >= 1 and cols[0] == "TITLE":
			ok = cols.has("我的游戏")
	f.close()
	assert_true(ok, "exported CSV keeps CJK translation")

func test_export_dry_run_writes_nothing():
	var csv: String = _base + "/in.csv"
	_write_csv(csv, [["keys", "en"], ["A", "a"]])
	var im: Dictionary = _tools._tool_manage_localization({"action": "import", "csv_path": csv, "out_dir": _base, "register": false})
	var out_csv: String = _base + "/out.csv"
	var r: Dictionary = _tools._tool_manage_localization({"action": "export", "csv_path": out_csv, "translations_paths": im.get("written", []), "dry_run": true})
	assert_true(bool(r.get("success", false)), "dry_run export succeeds")
	assert_false(FileAccess.file_exists(out_csv), "dry_run export writes no CSV")

func test_export_no_paths_errors():
	assert_true(_tools._tool_manage_localization({"action": "export", "translations_paths": ["user://missing_xyz.translation"]}).has("error"), "missing translation path errors")
