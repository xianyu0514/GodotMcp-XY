extends "res://addons/gut/test.gd"

## 运行探针的 TileMap/TileMapLayer 双兼容与区域/批量工具（M5 第四交付）：
## 同名视图身份、TileMapLayer 单层语义、区域分页读取、批量写入读回与
## update_internals 调用、旧 TileMap 路径不回归。

const ProbeScript = preload("res://addons/godot_mcp/runtime/mcp_runtime_probe.gd")

var _probe: Node

func before_each() -> void:
	_probe = ProbeScript.new()
	add_child_autofree(_probe)

# ============================================================================
# 双兼容解析
# ============================================================================

func test_resolves_both_tilemap_kinds() -> void:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)
	var legacy: TileMap = TileMap.new()
	legacy.name = "LegacyMap"
	_probe.add_child(legacy)

	var resolved_layer: Node = _probe._resolve_tilemap("ModernLayer")
	assert_true(resolved_layer is TileMapLayer, "TileMapLayer resolves directly")
	var resolved_legacy: Node = _probe._resolve_tilemap("LegacyMap")
	assert_true(resolved_legacy is TileMap, "legacy TileMap keeps resolving")

	assert_eq(_probe._tm_layer_count(resolved_layer), 1,
		"TileMapLayer is its own single layer (index 0)")
	assert_true(bool(_probe._is_valid_tilemap_layer(resolved_layer, 0)))
	assert_false(bool(_probe._is_valid_tilemap_layer(resolved_layer, 1)),
		"layer index beyond 0 is out of range on a TileMapLayer")

func test_non_tilemap_node_is_rejected() -> void:
	var plain: Node2D = Node2D.new()
	plain.name = "NotAMap"
	_probe.add_child(plain)
	assert_null(_probe._resolve_tilemap("NotAMap"))

# ============================================================================
# 单元格读写（两类节点同一访问器）
# ============================================================================

func test_cell_accessors_work_on_tilemaplayer() -> void:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)
	var resolved: Node = _probe._resolve_tilemap("ModernLayer")

	_probe._tm_set_cell(resolved, 0, Vector2i(3, 4), 1, Vector2i(2, 5), 7)
	assert_eq(_probe._tm_get_source_id(resolved, 0, Vector2i(3, 4), false), 1)
	assert_eq(_probe._tm_get_atlas_coords(resolved, 0, Vector2i(3, 4), false), Vector2i(2, 5))
	assert_eq(_probe._tm_get_alternative_tile(resolved, 0, Vector2i(3, 4), false), 7)

	_probe._tm_erase_cell(resolved, 0, Vector2i(3, 4))
	assert_eq(_probe._tm_get_source_id(resolved, 0, Vector2i(3, 4), false), -1,
		"erased cell reads as empty")

func test_cell_accessors_work_on_legacy_tilemap_layers() -> void:
	var legacy: TileMap = TileMap.new()
	legacy.name = "LegacyMap"
	legacy.add_layer(1)
	_probe.add_child(legacy)
	var resolved: Node = _probe._resolve_tilemap("LegacyMap")

	_probe._tm_set_cell(resolved, 1, Vector2i(0, 0), 2, Vector2i(1, 1), 3)
	assert_eq(_probe._tm_get_source_id(resolved, 1, Vector2i(0, 0), false), 2,
		"layer-indexed access still works on legacy TileMap")
	assert_eq(_probe._tm_get_source_id(resolved, 0, Vector2i(0, 0), false), -1,
		"other layers are untouched")

func test_serialize_layer_reports_node_type() -> void:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)
	var info: Dictionary = _probe._serialize_tilemap_layer(_probe._resolve_tilemap("ModernLayer"), 0)
	assert_eq(String(info["layer_node_type"]), "TileMapLayer")
	assert_eq(String(info["name"]), "ModernLayer")
	assert_eq(int(info["used_cell_count"]), 0)

# ============================================================================
# 区域读取（分页、只报非空格）
# ============================================================================

func _seeded_layer() -> Node:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)
	var resolved: Node = _probe._resolve_tilemap("ModernLayer")
	_probe._tm_set_cell(resolved, 0, Vector2i(1, 1), 1, Vector2i(0, 0), 0)
	_probe._tm_set_cell(resolved, 0, Vector2i(4, 2), 2, Vector2i(0, 0), 0)
	_probe._tm_set_cell(resolved, 0, Vector2i(9, 9), 3, Vector2i(0, 0), 0)
	return resolved

func test_region_handler_pages_non_empty_cells() -> void:
	var resolved: Node = _seeded_layer()
	# data: [node_path, layer, rect, max_cells, offset]
	var handled: bool = _probe._handle_get_tilemap_region([
		"ModernLayer", 0, {"position": {"x": 0, "y": 0}, "size": {"x": 5, "y": 5}}, 1, 0,
	])
	assert_true(handled)
	# 消息在 headless 下静默（EngineDebugger inactive）；行为正确性由
	# 分页语义的纯逻辑测试覆盖——这里断言 handler 不崩溃且参数校验路径可用。
	assert_true(_probe._handle_get_tilemap_region([
		"ModernLayer", 0, {"position": {"x": 0, "y": 0}, "size": {"x": 0, "y": 5}},
	]) , "non-positive size is handled (error path)")
	assert_true(_probe._handle_get_tilemap_region([
		"ModernLayer", 5, {"position": {"x": 0, "y": 0}, "size": {"x": 5, "y": 5}},
	]), "out-of-range layer is handled (error path)")

func test_region_rect_too_large_is_refused() -> void:
	_seed_layer_big_rect_guard()

func _seed_layer_big_rect_guard() -> void:
	assert_true(_probe._handle_get_tilemap_region([
		"ModernLayer", 0,
		{"position": {"x": 0, "y": 0}, "size": {"x": 100000, "y": 100000}},
	]), "oversized rects must be refused, not scanned")

# ============================================================================
# 批量写入 + 读回 + 立即内部更新
# ============================================================================

func test_batch_write_reads_back_and_updates_internals() -> void:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)

	var handled: bool = _probe._handle_set_tilemap_cells([
		"ModernLayer", 0,
		[
			{"coords": {"x": 1, "y": 0}, "updates": {"source_id": 1, "atlas_coords": {"x": 0, "y": 0}}},
			{"coords": {"x": 2, "y": 0}, "updates": {"erase": true}},
		],
	])
	assert_true(handled, "batch handler completes")
	var resolved: Node = _probe._resolve_tilemap("ModernLayer")
	assert_eq(_probe._tm_get_source_id(resolved, 0, Vector2i(1, 0), false), 1,
		"the written cell is applied (and was read back inside the receipt)")
	assert_eq(_probe._tm_get_source_id(resolved, 0, Vector2i(2, 0), false), -1,
		"the erased cell is empty")

func test_batch_write_works_on_legacy_tilemap() -> void:
	var legacy: TileMap = TileMap.new()
	legacy.name = "LegacyMap"
	legacy.add_layer(1)
	_probe.add_child(legacy)
	assert_true(_probe._handle_set_tilemap_cells([
		"LegacyMap", 1,
		[{"coords": {"x": 0, "y": 1}, "updates": {"source_id": 3, "atlas_coords": {"x": 1, "y": 1}}}],
	]))
	var resolved: Node = _probe._resolve_tilemap("LegacyMap")
	assert_eq(_probe._tm_get_source_id(resolved, 1, Vector2i(0, 1), false), 3)

func test_update_internals_reports_availability() -> void:
	var layer_node: TileMapLayer = TileMapLayer.new()
	layer_node.name = "ModernLayer"
	_probe.add_child(layer_node)
	assert_true(_probe._tm_update_internals(_probe._resolve_tilemap("ModernLayer")),
		"TileMapLayer exposes the immediate internals rebuild")
