extends "res://addons/gut/test.gd"

## 大规模依赖索引夹具（大型 2D 审计 2026-09-19 门槛 A 的第一份实测）：
## 合成项目约 2504 个脚本（跨过 gather_task_context 的 2000 扫描上限）、
## 242 个场景（嵌套实例链）、10000 个资源（.tres 引用 .png），并包含
## 100 组 ×5 目录的同名脚本、共享预制场景传递链、双向循环依赖与动态
## load 疑点。验证：
##   1. 完整性——共享脚本的传递闭包覆盖全部嵌套引用（不因规模截断）
##   2. 同名不混淆——同名脚本各自的 dependents 互不渗漏
##   3. 分页连续性——工具级 limit/offset 跨页拼接 == 全集（无损）
##   4. 增量更新范围——改一个文件只重解析一个；结构新增走对账
##   5. 循环可终止；动态依赖如实披露
##   6. 性能基线——build/查询耗时实测记录（软门禁防退化，不锁死阈值）
##
## 生成与构建在 before_all 一次性完成（全脚本共享）；夹具写在 res:// 的
## 隐藏目录（.tmp_ 前缀），引擎导入扫描不触碰，after_all 清理。

const DependencyIndexScript = preload("res://addons/godot_mcp/tools/dependency_index.gd")
const DependencyImpactToolsScript = preload("res://addons/godot_mcp/tools/dependency_impact_tools.gd")

const FIXTURE: String = "res://.tmp_scale_fixture"
const SAME_NAME_DIRS: Array = ["actors", "ui", "hud", "menus", "debug"]
const SAME_NAME_COUNT: int = 100
const SYSTEM_SCRIPTS: int = 2000
const LEVEL_SCENES: int = 240
const TRES_COUNT: int = 3000
const PNG_COUNT: int = 7000

var _index: RefCounted
var _tools: RefCounted
var _build_msec: int = -1
var _generate_msec: int = -1

func before_all() -> void:
	var generate_start: int = Time.get_ticks_msec()
	_generate_fixture()
	_generate_msec = Time.get_ticks_msec() - generate_start
	_index = DependencyIndexScript.new()
	var build_start: int = Time.get_ticks_msec()
	var build_stats: Dictionary = _index.build(FIXTURE)
	_build_msec = Time.get_ticks_msec() - build_start
	_tools = DependencyImpactToolsScript.new()
	_tools._index_root = FIXTURE
	print("[ScaleFixture] generate=%dms build=%dms stats=%s" % [
		_generate_msec, _build_msec, JSON.stringify(build_stats)])

func after_all() -> void:
	_remove_tree(FIXTURE)

# ============================================================================
# 生成器
# ============================================================================

func _generate_fixture() -> void:
	for dir_name in SAME_NAME_DIRS:
		_make_dir(FIXTURE + "/scripts/" + dir_name)
	_make_dir(FIXTURE + "/scripts/sys")
	_make_dir(FIXTURE + "/scripts/shared")
	_make_dir(FIXTURE + "/scripts/cyclic")
	_make_dir(FIXTURE + "/scenes/prefabs")
	_make_dir(FIXTURE + "/scenes/levels")
	_make_dir(FIXTURE + "/scenes/ui")
	_make_dir(FIXTURE + "/data")
	_make_dir(FIXTURE + "/art")

	# 100 组同名脚本 ×5 个目录（同名不混淆验收的素材）。
	for name_index in range(SAME_NAME_COUNT):
		var base_name: String = "entity_%03d" % name_index
		for dir_index in SAME_NAME_DIRS.size():
			var dir_name: String = SAME_NAME_DIRS[dir_index]
			_write(FIXTURE + "/scripts/%s/%s.gd" % [dir_name, base_name],
				"extends Node\nvar marker := \"%s/%s\"\n" % [dir_name, base_name])
	# 只有 ui/ 的同名脚本被场景引用（其余同名者必须零 dependents）。
	_write(FIXTURE + "/scenes/ui/player_hud.tscn", _scene_ext(
		"Script", FIXTURE + "/scripts/ui/entity_000.gd"))

	# 共享核心脚本：500 个 sys 脚本 preload 它；enemy 预制经 enemy.gd 传递
	# 引用它；240 个 level 场景实例化 enemy 预制 → 闭包深度 3、条目 740+。
	_write(FIXTURE + "/scripts/shared/core.gd",
		"extends Node\nconst CORE_VERSION := 1\n")
	for sys_index in range(SYSTEM_SCRIPTS):
		var content: String = "extends Node\nvar id := %d\n" % sys_index
		if sys_index < 500:
			content += 'const Core = preload("%s/scripts/shared/core.gd")\n' % FIXTURE
		_write(FIXTURE + "/scripts/sys/system_%04d.gd" % sys_index, content)
	_write(FIXTURE + "/scripts/shared/enemy.gd",
		'extends CharacterBody2D\nconst Core = preload("%s/scripts/shared/core.gd")\nvar hp := 10\n' % FIXTURE)
	_write(FIXTURE + "/scenes/prefabs/enemy.tscn", _scene_ext(
		"Script", FIXTURE + "/scripts/shared/enemy.gd"))
	for level_index in range(LEVEL_SCENES):
		_write(FIXTURE + "/scenes/levels/level_%03d.tscn" % level_index, _scene_ext(
			"PackedScene", FIXTURE + "/scenes/prefabs/enemy.tscn"))

	# 双向循环依赖。
	_write(FIXTURE + "/scripts/cyclic/a.gd",
		'extends Node\nconst B = preload("%s/scripts/cyclic/b.gd")\n' % FIXTURE)
	_write(FIXTURE + "/scripts/cyclic/b.gd",
		'extends Node\nconst A = preload("%s/scripts/cyclic/a.gd")\n' % FIXTURE)

	# 动态 load 疑点。
	_write(FIXTURE + "/scripts/shared/dyn_loader.gd",
		'extends Node\nvar res = load("res://" + name)\n')

	# 资源层：3000 个 .tres 各引用 1-3 张纹理；7000 张 1KB 占位纹理。
	for png_index in range(PNG_COUNT):
		var file: FileAccess = FileAccess.open(
			FIXTURE + "/art/tex_%04d.png" % png_index, FileAccess.WRITE)
		file.store_buffer(PackedByteArray())
		file.resize(1024)
		file.close()
	for tres_index in range(TRES_COUNT):
		var refs: String = ""
		var ref_count: int = 1 + (tres_index % 3)
		for ref_index in range(ref_count):
			refs += '[ext_resource type="Texture2D" path="%s/art/tex_%04d.png" id="%d"]\n' % [
				FIXTURE, (tres_index * 3 + ref_index) % PNG_COUNT, ref_index + 1]
		_write(FIXTURE + "/data/res_%04d.tres" % tres_index,
			"[gd_resource type=\"Resource\" format=3]\n\n%s\n[resource]\n" % refs)

func _scene_ext(resource_type: String, target_path: String) -> String:
	return '[gd_scene format=2]\n[ext_resource type="%s" path="%s" id="1"]\n[node name="Main" type="Node"]\n' % [
		resource_type, target_path]

# ============================================================================
# 验收 1：完整性（规模不截断传递闭包）
# ============================================================================

func test_index_scale_and_completeness() -> void:
	var stats: Dictionary = _index.stats()
	# owner 集 = 2504 个 .gd + 242 个 .tscn + 3000 个 .tres
	assert_gt(int(stats["indexed_files"]), 5700,
		"every owner file is indexed regardless of the 2000-script scan cap")
	assert_gt(int(stats["edge_count"]), 6700,
		"scene/resource/script edges are all present (got %s)" % str(stats))

	# 共享核心脚本的传递闭包：500 sys(直接) + enemy.gd(直接) +
	# enemy.tscn(depth2) + 240 levels(depth3) = 742 项，不因规模截断。
	var closure: Array = _index.dependents_of(FIXTURE + "/scripts/shared/core.gd")
	assert_eq(closure.size(), 742,
		"the full transitive closure survives at scale (got %d)" % closure.size())
	var depth_counts: Dictionary = {}
	for entry in closure:
		var depth: int = int((entry as Dictionary)["depth"])
		depth_counts[depth] = int(depth_counts.get(depth, 0)) + 1
	assert_eq(int(depth_counts.get(1, 0)), 501, "direct dependents: 500 sys + enemy.gd")
	assert_eq(int(depth_counts.get(2, 0)), 1, "enemy.tscn")
	assert_eq(int(depth_counts.get(3, 0)), 240, "levels via the nested prefab")

# ============================================================================
# 验收 2：同名不混淆（100 组 ×5 目录）
# ============================================================================

func test_same_names_do_not_leak_at_scale() -> void:
	var ui_dependents: Array = _index.dependents_of(FIXTURE + "/scripts/ui/entity_000.gd")
	assert_eq(ui_dependents.size(), 1,
		"the only scene referencing ui/entity_000.gd is found")
	assert_eq(String((ui_dependents[0] as Dictionary)["path"]),
		FIXTURE + "/scenes/ui/player_hud.tscn")

	# 其余 4 个同名者必须零 dependents（文件名子串匹配会漏出 5 个引用者）。
	for dir_name in ["actors", "hud", "menus", "debug"]:
		var leaked: Array = _index.dependents_of(
			FIXTURE + "/scripts/%s/entity_000.gd" % dir_name)
		assert_eq(leaked.size(), 0,
			"%s/entity_000.gd is referenced by nothing (got %d)" % [dir_name, leaked.size()])

# ============================================================================
# 验收 3：分页连续性（工具级跨页拼接 == 全集）
# ============================================================================

func test_tool_paging_is_lossless_at_scale() -> void:
	var target: String = FIXTURE + "/scripts/shared/core.gd"
	var collected: Dictionary = {}
	var offset: int = 0
	var pages: int = 0
	while true:
		var page: Dictionary = await _tools._tool_query_change_impact({
			"target_paths": [target], "limit": 100, "offset": offset,
		})
		assert_false(page.has("error"), str(page.get("error", "")))
		for entry in page["impact"]:
			collected[String((entry as Dictionary)["path"])] = true
		pages += 1
		if not bool(page["has_more"]):
			break
		offset = int(page["next_offset"])
	assert_eq(pages, 8, "742 entries at limit=100 span 8 pages")
	assert_eq(collected.size(), 742, "paged reads reassemble the full closure")

# ============================================================================
# 验收 4：增量更新范围
# ============================================================================

func test_incremental_update_scope_at_scale() -> void:
	# 内容变化：只重解析目标文件。
	var level_path: String = FIXTURE + "/scenes/levels/level_000.tscn"
	_write(level_path, _scene_ext("Script", FIXTURE + "/scripts/ui/entity_001.gd"))
	var change: Dictionary = _index.apply_changes([level_path])
	assert_eq(int(change["reparsed"]), 1, "one changed file re-parses exactly one entry")
	assert_eq(int(change["skipped"]), 0)
	var new_dependents: Array = _index.dependents_of(FIXTURE + "/scripts/ui/entity_001.gd")
	assert_eq(new_dependents.size(), 1, "the new edge is visible immediately")

	# 结构性新增：对账捡起全新文件。
	_write(FIXTURE + "/scenes/levels/level_new.tscn",
		_scene_ext("PackedScene", FIXTURE + "/scenes/prefabs/enemy.tscn"))
	var structural: Dictionary = _index.apply_changes([], FIXTURE, true)
	assert_gt(int(structural["reconciled"]), 0, "new files enter via reconcile")
	# 本测试前半段把 level_000 改写为引用 entity_001（闭包 -1），新增
	# level_new 又 +1——断言聚焦本质：新场景确实进入闭包。
	var closure_after: Array = _index.dependents_of(FIXTURE + "/scripts/shared/core.gd")
	var found_new: bool = false
	for entry in closure_after:
		if String((entry as Dictionary)["path"]) == FIXTURE + "/scenes/levels/level_new.tscn":
			found_new = true
	assert_true(found_new, "the new level joins the transitive closure")
	assert_eq(closure_after.size(), 742, "net closure stays consistent (-1 rewritten, +1 added)")

# ============================================================================
# 验收 5：循环与动态披露
# ============================================================================

func test_cycles_terminate_at_scale() -> void:
	var dependents: Array = _index.dependents_of(FIXTURE + "/scripts/cyclic/a.gd")
	assert_eq(dependents.size(), 1)
	assert_eq(String((dependents[0] as Dictionary)["path"]),
		FIXTURE + "/scripts/cyclic/b.gd")

func test_dynamic_loads_disclosed_at_scale() -> void:
	var hints: Array = _index.dynamic_load_hints([FIXTURE + "/scripts/shared/dyn_loader.gd"])
	assert_eq(hints.size(), 1)

# ============================================================================
# 验收 6：性能基线（实测记录 + 软门禁）
# ============================================================================

func test_performance_baseline_recorded() -> void:
	# 软门禁：只防数量级退化（阈值宽松），真实基线数字在测试输出里记录。
	assert_lt(_build_msec, 120000, "full build over ~12.7k files stays under 2 minutes")
	var query_start: int = Time.get_ticks_msec()
	var closure: Array = _index.dependents_of(FIXTURE + "/scripts/shared/core.gd")
	var query_msec: int = Time.get_ticks_msec() - query_start
	assert_lt(query_msec, 3000, "a 742-entry closure query stays under 3 seconds")
	print("[ScaleFixture] baseline: generate=%dms build=%dms closure_query(%d entries)=%dms" % [
		_generate_msec, _build_msec, closure.size(), query_msec])

# ============================================================================
# 夹具辅助
# ============================================================================

func _make_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub_name: String in DirAccess.get_directories_at(path):
		if sub_name == "." or sub_name == "..":
			continue
		_remove_tree(path.path_join(sub_name))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
