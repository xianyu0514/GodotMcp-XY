extends "res://addons/gut/test.gd"

# 资源重组域：move/remove_project_resource 的引用闭包、边界守卫、副车迁移、
# 缓冲守卫与真操作链路（GUT headless 下 DirAccess/FileAccess 全可用）。

const ResourcesScript = preload("res://addons/godot_mcp/tools/project_resources_tools.gd")

var _fixture_root: String = ""
var _tools: RefCounted = null

func before_each() -> void:
	_tools = ResourcesScript.new()
	_fixture_root = "res://.tmp_reorg_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_root))

func after_each() -> void:
	var absolute: String = ProjectSettings.globalize_path(_fixture_root)
	if DirAccess.dir_exists_absolute(absolute):
		_remove_recursive(absolute)
	_fixture_root = ""
	_tools = null

func _remove_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	var text: String = file.get_as_text()
	file.close()
	return text

# --- 纯核心：计数与重写的边界守卫 ---

func test_occurrence_counting_respects_boundary():
	var text: String = "path=\"res://a/old.png\"\nload(\"res://a/old.png\")\nref=\"res://a/old.png.import\"\nother=\"res://a/old.png2\"\n"
	assert_eq(ResourcesScript._count_path_occurrences(text, "res://a/old.png"), 2,
		".import 与 png2 前缀碰撞不算引用")
	var rewrite: Dictionary = ResourcesScript._rewrite_path_occurrences(text, "res://a/old.png", "res://a/new/old.png")
	assert_eq(int(rewrite["count"]), 2)
	var rewritten: String = String(rewrite["text"])
	assert_true(rewritten.contains("res://a/old.png.import"), "边界守卫：.import 后缀串原样保留（它随文件整体迁移）")
	assert_true(rewritten.contains("res://a/old.png2"), "边界守卫：png2 不被误改")
	assert_eq(ResourcesScript._count_path_occurrences(rewritten, "res://a/old.png"), 0, "旧路径清零")

# --- move：引用重写 + 副车迁移 ---

func test_move_rewrites_references_and_moves_sidecars():
	var asset: String = _fixture_root.path_join("old.png")
	var sidecar: String = asset + ".import"
	var uid_sidecar: String = asset + ".uid"
	_write(asset, "PNGDATA")
	_write(sidecar, "[remap]\nimporter=\"texture\"\nuid=\"uid://fixture1\"\n\n[deps]\nsource_file=\"%s\"\n" % asset)
	_write(uid_sidecar, "uid://fixture1")
	var scene_ref: String = _fixture_root.path_join("user_scene.tscn")
	_write(scene_ref, "[ext_resource type=\"Texture2D\" path=\"%s\" id=\"1\"]\n" % asset)
	var script_ref: String = _fixture_root.path_join("user_loader.gd")
	_write(script_ref, "var tex := load(\"%s\")\n" % asset)

	var to_path: String = _fixture_root.path_join("moved/renamed.png")
	var result: Dictionary = _tools._tool_move_project_resource({"from_path": asset, "to_path": to_path})
	assert_false(result.has("error"), str(result))
	assert_true(bool(result["moved"]))
	assert_eq(int(result["total_replacements"]), 3, "tscn 1 处 + gd 1 处 + .import source_file 1 处")
	assert_true(FileAccess.file_exists(to_path), "新路径文件存在")
	assert_false(FileAccess.file_exists(asset), "旧路径文件已移走")
	assert_true(FileAccess.file_exists(to_path + ".import"), ".import 副车随迁")
	assert_true(FileAccess.file_exists(to_path + ".uid"), ".uid 副车随迁")
	assert_true(str(_read(to_path + ".import")).contains("source_file=\"%s\"" % to_path),
		".import 的 source_file 指向新路径")
	assert_true(str(_read(scene_ref)).contains(to_path), "场景引用已重写")
	assert_true(str(_read(script_ref)).contains(to_path), "脚本引用已重写")
	var scan: Dictionary = result["scan"]
	assert_true(scan.has("scan_triggered"), "响应必须报告扫描状态")

func test_move_rejects_extension_mismatch_and_missing_dest_rules():
	var asset: String = _fixture_root.path_join("a.tres")
	_write(asset, "[resource]\n")
	var bad_ext: Dictionary = _tools._tool_move_project_resource({
		"from_path": asset, "to_path": _fixture_root.path_join("b.png")})
	assert_true(bad_ext.has("error"), "跨扩展名必须拒绝（移动不做格式转换）")
	var same: Dictionary = _tools._tool_move_project_resource({
		"from_path": asset, "to_path": asset})
	assert_true(same.has("error"))

func test_move_self_protects_plugin_and_cache_paths():
	var plugin_file: String = "res://addons/godot_mcp/tools/project_resources_tools.gd"
	var r1: Dictionary = _tools._tool_move_project_resource({
		"from_path": plugin_file, "to_path": _fixture_root.path_join("stolen.gd")})
	assert_true(r1.has("error"), "拒绝移动运行中插件自身文件")
	var r2: Dictionary = _tools._tool_move_project_resource({
		"from_path": "res://.godot/global_script_class_cache.cfg", "to_path": _fixture_root.path_join("cache.cfg")})
	assert_true(r2.has("error"), "拒绝动引擎缓存")
	var r3: Dictionary = _tools._tool_remove_project_resource({"path": "res://.godot/uid_cache.bin"})
	assert_true(r3.has("error"), "删除同样拒绝引擎缓存")

# --- remove：引用拒绝 / force 诚实 / 副车清理 ---

func test_remove_refuses_referenced_file_and_lists_them():
	var asset: String = _fixture_root.path_join("keep.png")
	_write(asset, "DATA")
	_write(_fixture_root.path_join("scene.tscn"), "[ext_resource path=\"%s\" id=\"1\"]\n" % asset)
	var result: Dictionary = _tools._tool_remove_project_resource({"path": asset})
	assert_true(result.has("error"), "被引用时必须拒绝")
	assert_true(str(result["error"]).contains("force=true"), "拒绝信息给出 force 出路")
	var listed: Array = result.get("referencers", [])
	assert_eq(listed.size(), 1)
	assert_eq(String((listed[0] as Dictionary)["path"]), _fixture_root.path_join("scene.tscn"))

func test_remove_force_trashes_with_sidecars_and_reports_dangles():
	var asset: String = _fixture_root.path_join("doomed.png")
	var sidecar: String = asset + ".import"
	_write(asset, "DATA")
	_write(sidecar, "[remap]\nimporter=\"texture\"\n")
	_write(_fixture_root.path_join("scene.tscn"), "[ext_resource path=\"%s\" id=\"1\"]\n" % asset)
	var result: Dictionary = _tools._tool_remove_project_resource({"path": asset, "force": true})
	assert_false(result.has("error"), str(result))
	assert_true(bool(result["removed"]))
	assert_true(str(result.get("removal_method", "")).contains("trash"), "默认走回收站（可恢复）")
	assert_true((result.get("sidecars_removed", []) as Array).has(sidecar))
	assert_false(FileAccess.file_exists(asset))
	assert_eq((result.get("referencers", []) as Array).size(), 1, "force 删除仍如实上报悬空引用")
	assert_true(str(result.get("hint", "")).contains("dangle"))

func test_remove_unreferenced_goes_straight_to_trash():
	var asset: String = _fixture_root.path_join("lonely.tres")
	_write(asset, "[resource]\n")
	var result: Dictionary = _tools._tool_remove_project_resource({"path": asset})
	assert_false(result.has("error"), str(result))
	assert_false(FileAccess.file_exists(asset))
	assert_false(result.has("referencers"), "无引用时不应出现 referencer 字段噪音")
