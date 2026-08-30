extends SceneTree

const PATHS: Array[String] = [
	"res://addons/godot_mcp/utils/failure_taxonomy.gd",
	"res://addons/godot_mcp/utils/tool_outcome.gd",
	"res://addons/godot_mcp/utils/variant_codec.gd",
	"res://addons/godot_mcp/native_mcp/evidence_store.gd",
	"res://addons/godot_mcp/native_mcp/capability_dag.gd",
	"res://addons/godot_mcp/native_mcp/semantic_receipt_cache.gd",
	"res://addons/godot_mcp/native_mcp/runtime_session_manager.gd",
	"res://addons/godot_mcp/native_mcp/file_mutation_bus.gd",
	"res://addons/godot_mcp/native_mcp/tool_coverage_tracker.gd",
	"res://addons/godot_mcp/native_mcp/fixture_manager.gd",
	"res://addons/godot_mcp/native_mcp/capability_gap_analyzer.gd",
	"res://addons/godot_mcp/native_mcp/workflow_checkpoint_store.gd",
	"res://addons/godot_mcp/native_mcp/chaos_suite.gd",
]

func _initialize() -> void:
	var failures: Array[String] = []
	for path in PATHS:
		var script: GDScript = load(path)
		if script == null:
			failures.append(path + " -> failed to load")
			continue
		var instance: RefCounted = script.new()
		if instance == null:
			failures.append(path + " -> failed to instantiate")
			continue
		print("[OK] " + path)
	if not failures.is_empty():
		for failure in failures:
			printerr("[FAIL] " + failure)
		quit(1)
		return
	print("ALL SYNTAX CHECKS PASSED")
	quit(0)
