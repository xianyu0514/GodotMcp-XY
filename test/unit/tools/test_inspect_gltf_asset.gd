extends "res://addons/gut/test.gd"

# Unit tests for inspect_gltf_asset in project_tools_native.gd. Writes a minimal
# valid glTF 2.0 document to a temp dir under user:// and parses it with the
# engine's GLTFDocument, so the happy path runs headless (no game required).

var _tools: RefCounted = null
var _tmp_dir: String = "user://.tmp_inspect_gltf_test"

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()
	var dir: DirAccess = DirAccess.open("user://")
	if dir and not dir.dir_exists(_tmp_dir):
		dir.make_dir_recursive(_tmp_dir)
	_clear_tmp()

func after_each() -> void:
	_clear_tmp()
	_tools = null

func _clear_tmp() -> void:
	var dir: DirAccess = DirAccess.open(_tmp_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func _write_minimal_gltf() -> String:
	var doc: Dictionary = {
		"asset": {"version": "2.0", "generator": "godot-mcp-test"},
		"scene": 0,
		"scenes": [{"name": "Scene", "nodes": [0]}],
		"nodes": [{"name": "EmptyNode"}]
	}
	var path: String = _tmp_dir + "/empty.gltf"
	var f: FileAccess = FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	return path

func test_missing_path():
	assert_true(_tools._tool_inspect_gltf_asset({}).has("error"), "missing path errors")

func test_invalid_extension():
	var result: Dictionary = _tools._tool_inspect_gltf_asset({"path": _tmp_dir + "/model.png"})
	assert_true(result.has("error"), "non-gltf extension errors")

func test_nonexistent_file():
	var result: Dictionary = _tools._tool_inspect_gltf_asset({"path": _tmp_dir + "/missing.glb"})
	assert_true(result.has("error"), "missing file errors")

func test_parses_minimal_gltf():
	var path: String = _write_minimal_gltf()
	var result: Dictionary = _tools._tool_inspect_gltf_asset({"path": path})
	assert_eq(str(result.get("status", "")), "success", "minimal glTF parses")
	assert_eq(int(result["mesh_count"]), 0, "no meshes in minimal doc")
	assert_eq(int(result["material_count"]), 0, "no materials in minimal doc")
	assert_eq(int(result["animation_count"]), 0, "no animations in minimal doc")
	assert_true(int(result["node_count"]) >= 1, "at least the empty node is reported")
	var warnings: Array = result["warnings"]
	assert_true(warnings.has("No meshes found in the glTF asset"), "warns about missing meshes")
	assert_true(warnings.has("No animations found in the glTF asset"), "warns about missing animations")

func test_include_names_false_omits_lists():
	var path: String = _write_minimal_gltf()
	var result: Dictionary = _tools._tool_inspect_gltf_asset({"path": path, "include_names": false})
	assert_false(result.has("meshes"), "name lists omitted when include_names=false")
	assert_eq(str(result.get("status", "")), "success", "still succeeds")
