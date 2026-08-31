extends "res://addons/gut/test.gd"

## ScriptCompileMemo 的失效语义：mtime 变化重算、变体键独立、引用复用。
## 静态记忆跨测试共享，before_each 清零保证窗口干净。

const MemoScript = preload("res://addons/godot_mcp/utils/script_compile_memo.gd")

var _tmp_path: String = "user://test_script_compile_memo.gd"


func before_each() -> void:
	MemoScript.clear()
	_write_script("extends Node\n")


func after_each() -> void:
	MemoScript.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp_path))


func _write_script(source: String) -> void:
	var file: FileAccess = FileAccess.open(_tmp_path, FileAccess.WRITE)
	file.store_string(source)
	file.close()


func _compute_log(calls: Array, valid: bool) -> Callable:
	return func() -> Dictionary:
		calls.append(1)
		return {"valid": valid, "errors": [], "calls": calls.size()}


func test_same_mtime_serves_memoized_reference() -> void:
	var calls: Array = []
	var first: Dictionary = MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	var second: Dictionary = MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	assert_eq(calls.size(), 1, "unchanged file computes exactly once")
	assert_same(first, second, "repeat call returns the memoized Dictionary reference")


func test_mtime_change_recomputes() -> void:
	var calls: Array = []
	# 内容与 mtime 都变化：合法 → 语法错误
	MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	_write_script("extends Node\nfunc broken(:\n")
	var recomputed: Dictionary = MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, false))
	assert_eq(calls.size(), 2, "changed file recomputes")
	assert_false(bool(recomputed["valid"]), "the new compute result is served")


func test_variant_keys_are_independent_entries() -> void:
	var calls: Array = []
	MemoScript.diagnostics_for(_tmp_path, "verify|true", _compute_log(calls, true))
	MemoScript.diagnostics_for(_tmp_path, "verify|false", _compute_log(calls, true))
	assert_eq(calls.size(), 2, "warning variant gets its own memo entry")
	assert_eq(MemoScript.entry_count(), 2)


func test_clear_empties_memo() -> void:
	var calls: Array = []
	MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	MemoScript.clear()
	MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	assert_eq(calls.size(), 2, "cleared memo recomputes")
	assert_eq(MemoScript.entry_count(), 1)


func test_missing_file_bypasses_memo() -> void:
	var calls: Array = []
	var result: Dictionary = MemoScript.diagnostics_for(
		"user://definitely_missing_memo_probe.gd", "v", _compute_log(calls, true))
	assert_eq(calls.size(), 1, "compute always runs for a path without mtime")
	assert_eq(MemoScript.entry_count(), 0, "nothing is memoized for missing files")
	assert_true(bool(result["valid"]))

func test_result_for_domains_are_independent() -> void:
	# 依赖解析与编译诊断共用记忆机制但域独立：同文件两个域各算一次。
	var calls: Array = []
	MemoScript.result_for(_tmp_path, "deps", func() -> Array:
		calls.append("deps")
		return ["res://a.tres"])
	MemoScript.result_for(_tmp_path, "compile|verify|true", func() -> Array:
		calls.append("compile")
		return [])
	assert_eq(calls.size(), 2, "distinct domains compute independently")
	var first: Variant = MemoScript.result_for(_tmp_path, "deps", func() -> Array:
		calls.append("deps-again")
		return ["res://b.tres"])
	assert_eq(calls.size(), 2, "repeat in the same domain is memoized")
	assert_eq((first as Array)[0], "res://a.tres", "memoized value is served")

func test_writer_side_invalidate_forces_recompute() -> void:
	# 同秒等长改写（mtime+长度都不变）是写侧失效存在的理由：
	# invalidate 后必须重算，不受磁盘签名不变的影响。
	# 注意 invalidate 必须用与 diagnostics_for 相同的路径形式（键前缀匹配）。
	var calls: Array = []
	MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	MemoScript.invalidate(_tmp_path)
	var recomputed: Dictionary = MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, false))
	assert_eq(calls.size(), 2, "invalidate forces recompute despite identical signature")
	assert_false(bool(recomputed["valid"]), "the post-invalidate compute result is served")

func test_writer_side_invalidate_only_touches_that_path() -> void:
	var other: String = "user://test_memo_other_probe.gd"
	var f: FileAccess = FileAccess.open(other, FileAccess.WRITE)
	f.store_string("extends Node
")
	f.close()
	var calls: Array = []
	MemoScript.diagnostics_for(_tmp_path, "v", _compute_log(calls, true))
	MemoScript.diagnostics_for(other, "v", _compute_log(calls, true))
	MemoScript.invalidate(_tmp_path)
	MemoScript.diagnostics_for(other, "v", _compute_log(calls, true))
	assert_eq(calls.size(), 2, "other path stays memoized")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(other))
