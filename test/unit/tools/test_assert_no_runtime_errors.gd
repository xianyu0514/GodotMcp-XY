extends "res://addons/gut/test.gd"

# Unit tests for the assert_no_runtime_errors hard gate. Uses a fake debugger
# bridge (injected via the GodotMCPPlugin meta) supplying captured output
# events, so it runs headless without a real game.

class FakeOutputBridge:
	extends RefCounted

	var events: Array = []

	func _init(output_events: Array) -> void:
		events = output_events

	func get_output_events(count: int = 100, offset: int = 0, order: String = "desc", category: String = "") -> Dictionary:
		var out: Array = []
		for entry in events:
			if category.is_empty() or str(entry.get("category", "")) == category:
				out.append(entry.duplicate(true))
		return {"events": out, "count": out.size(), "total_available": out.size()}

class FakePlugin:
	extends RefCounted

	var bridge: RefCounted

	func _init(b: RefCounted) -> void:
		bridge = b

	func get_debugger_bridge() -> RefCounted:
		return bridge

var _tools: RefCounted = null

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/debug_tools_native.gd").new()
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func after_each() -> void:
	_tools = null
	if Engine.has_meta("GodotMCPPlugin"):
		Engine.remove_meta("GodotMCPPlugin")

func _install(events: Array) -> void:
	Engine.set_meta("GodotMCPPlugin", FakePlugin.new(FakeOutputBridge.new(events)))

func test_passes_with_no_error_events():
	_install([
		{"sequence": 1, "category": "stdout", "message": "hello"},
		{"sequence": 2, "category": "stdout", "message": "world"}
	])
	var result: Dictionary = _tools._tool_assert_no_runtime_errors({})
	assert_true(bool(result["passed"]), "No stderr => passes")
	assert_eq(int(result["error_count"]), 0)

func test_fails_with_stderr_event():
	_install([
		{"sequence": 1, "category": "stdout", "message": "ok"},
		{"sequence": 2, "category": "stderr", "message": "Null instance", "file": "res://p.gd", "line": 10}
	])
	var result: Dictionary = _tools._tool_assert_no_runtime_errors({})
	assert_false(bool(result["passed"]), "An stderr event fails the gate")
	assert_eq(int(result["error_count"]), 1)
	var err: Dictionary = (result["errors"] as Array)[0]
	assert_eq(str(err["message"]), "Null instance")
	assert_eq(int(err["line"]), 10)

func test_since_sequence_filters_old_events():
	_install([
		{"sequence": 1, "category": "stderr", "message": "old error"},
		{"sequence": 5, "category": "stderr", "message": "new error"}
	])
	var result: Dictionary = _tools._tool_assert_no_runtime_errors({"since_sequence": 3})
	assert_false(bool(result["passed"]), "Newer error still fails")
	assert_eq(int(result["error_count"]), 1, "Only events after sequence 3 counted")
	assert_eq(str((result["errors"] as Array)[0]["message"]), "new error")

func test_custom_categories():
	_install([
		{"sequence": 1, "category": "stdout", "message": "tracked"},
		{"sequence": 2, "category": "stderr", "message": "ignored here"}
	])
	var result: Dictionary = _tools._tool_assert_no_runtime_errors({"categories": ["stdout"]})
	assert_false(bool(result["passed"]), "stdout treated as error when requested")
	assert_eq(int(result["error_count"]), 1)

func test_missing_bridge_errors():
	var result: Dictionary = _tools._tool_assert_no_runtime_errors({})
	assert_true(result.has("error"), "No bridge available => error")
