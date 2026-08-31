extends "res://addons/gut/test.gd"

## Salvaged write-verification / typed-encoding / sampling / scan-filter pieces.

const PathNormalizerScript = preload("res://addons/godot_mcp/utils/path_normalizer.gd")
const CacheFilterScript = preload("res://addons/godot_mcp/utils/generated_cache_filter.gd")
const NodeToolsScript = preload("res://addons/godot_mcp/tools/node_tools_native.gd")
const VerifyToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")
const ProbeScript = preload("res://addons/godot_mcp/runtime/mcp_runtime_probe.gd")

func test_path_normalizer_collapses_equivalent_forms() -> void:
	assert_eq(PathNormalizerScript.canonical("res://test"), PathNormalizerScript.canonical("res://test/"),
		"Trailing-slash variants normalize identically")
	assert_true(PathNormalizerScript.equivalent("res://a/b/../c", "res://a/c"),
		"Dotted segments collapse for comparison")

func test_cache_filter_skips_generated_keeps_sources() -> void:
	assert_true(CacheFilterScript.is_generated("res://.godot/imported/foo.ctex"),
		"Editor import cache is generated")
	assert_false(CacheFilterScript.is_generated("res://scenes/main.tscn"),
		"Source assets stay in audits by default")
	var partitioned: Dictionary = CacheFilterScript.partition(
		["res://scenes/a.tscn", "res://.godot/x", "res://addons/godot_mcp/plugin.gd"], false)
	assert_false((partitioned.get("kept", []) as Array).has("res://.godot/x"),
		"Generated cache is filtered out of the kept set")
	assert_true((partitioned.get("kept", []) as Array).has("res://scenes/a.tscn"),
		"Source assets are kept")

func test_values_equivalent_detects_clamped_writes() -> void:
	assert_true(NodeToolsScript._values_equivalent(5, 5), "Equal values verify")
	assert_false(NodeToolsScript._values_equivalent(200, 100),
		"A clamped write-back is reported as unverified, never as success")

func test_percentile_math_is_deterministic() -> void:
	var values: Array[float] = [10.0, 20.0, 30.0, 40.0, 50.0]
	assert_eq(VerifyToolsScript._percentile(values, 50.0), 30.0,
		"Median of five sorted values")
	assert_eq(VerifyToolsScript._percentile(values, 100.0), 50.0,
		"Top percentile takes the maximum")
	assert_eq(VerifyToolsScript._percentile([], 50.0), 0.0,
		"Empty samples never divide by zero")

func test_probe_typed_encoding_roundtrip() -> void:
	var probe: Node = ProbeScript.new()
	var encoded: Dictionary = probe._serialize_value(Vector2i(30, 10))
	assert_eq(String(encoded.get("__godot_type", "")), "Vector2i")
	assert_true(probe._values_equivalent(Vector2i(30, 10), Vector2i(30, 10)))
	assert_false(probe._values_equivalent(Vector2i(30, 10), Vector2i(31, 10)))
	probe.free()
