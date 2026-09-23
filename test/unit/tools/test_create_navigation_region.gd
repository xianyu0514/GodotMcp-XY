extends "res://addons/gut/test.gd"

## create_navigation_region 单测：烘焙内核（轮廓->顶点/多边形，headless 可跑）、
## 输入形状宽容（[x,y]/{x,y}/Vector2）、参数校验、无编辑器时的诚实报错。

const ToolsScript = preload("res://addons/godot_mcp/tools/scene_tools_native.gd")

func test_bake_core_rectangle_outline() -> void:
	var result: Dictionary = ToolsScript._bake_navigation_outlines(
		[[[0, 0], [400, 0], [400, 300], [0, 300]]], 1.0, true)
	assert_false(result.has("error"), str(result))
	assert_eq(int(result.get("vertices_count", -1)), 4, "rectangle bakes to 4 vertices")
	assert_eq(int(result.get("polygons_count", -1)), 1)
	assert_true(bool(result.get("baked", false)))
	var poly: NavigationPolygon = result.get("navigation_polygon", null)
	assert_not_null(poly)
	assert_eq(poly.get_outline_count(), 1)

func test_bake_core_point_shapes_and_multi_outline() -> void:
	var result: Dictionary = ToolsScript._bake_navigation_outlines([
		[Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)],
		[{"x": 200, "y": 0}, {"x": 300, "y": 0}, {"x": 300, "y": 80}, {"x": 200, "y": 80}],
	], 0.0, true)
	assert_false(result.has("error"), str(result))
	assert_eq(int(result.get("outlines_used", -1)), 2)
	assert_eq(int(result.get("vertices_count", -1)), 8, "two separate rooms bake separately")

func test_bake_core_rejects_bad_outlines() -> void:
	for bad in [[], [[0, 0], [1, 1]], ["nope"], [[0, 0], [1, 1], [2, 2], "bad point"]]:
		var result: Dictionary = ToolsScript._bake_navigation_outlines(bad, 1.0, true)
		assert_true(result.has("error"), "must reject: %s" % str(bad))

func test_no_bake_leaves_outline_only() -> void:
	var result: Dictionary = ToolsScript._bake_navigation_outlines(
		[[[0, 0], [50, 0], [50, 50], [0, 50]]], 1.0, false)
	assert_false(bool(result.get("baked", true)))
	assert_eq(int(result.get("vertices_count", -1)), 0, "no bake => no vertices yet")

func test_agent_radius_is_data() -> void:
	var tight: NavigationPolygon = ToolsScript._bake_navigation_outlines(
		[[[0, 0], [100, 0], [100, 100], [0, 100]]], 0.0, true)["navigation_polygon"]
	var padded: NavigationPolygon = ToolsScript._bake_navigation_outlines(
		[[[0, 0], [100, 0], [100, 100], [0, 100]]], 20.0, true)["navigation_polygon"]
	assert_true(padded.get_vertices().size() > 0)
	# agent_radius 收缩可让窄轮廓烘成空（诚实报告 0 多边形，不报错）
	assert_eq(tight.get_polygon_count(), 1)

func test_tool_requires_editor_scene() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_navigation_region({
		"outlines": [[[0, 0], [10, 0], [10, 10], [0, 10]]]})
	assert_true(result.has("error"), "headless has no edited scene — honest error, not a fake success")
	assert_true(String(result.get("error", "")).contains("scene"), str(result))

func test_tool_validates_outlines_first() -> void:
	var tools: RefCounted = ToolsScript.new()
	var result: Dictionary = tools._tool_create_navigation_region({"outlines": []})
	assert_true(result.has("error"))
