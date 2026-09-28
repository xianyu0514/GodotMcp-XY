extends "res://addons/gut/test.gd"

## verify_change_effect（P0-2 公共能力）单测：.tscn 实体解析（外部脚本 vs
## 内嵌副本）、读回表达式构造、数值宽容比较、清单判定与自愈 needs。
## 运行编排（FRESH 启动读回 / 行为执行）通过 _effect_readback_override 与
## _effect_behavior_override 注入——真实编排复用验证队列的原生执行器，
## 由集成层覆盖。

const ToolsScript = preload("res://addons/godot_mcp/tools/debug_verify_tools.gd")

const TMP: String = "res://.tmp_vce"
const SCENE_EXTERNAL: String = TMP + "/player_external.tscn"
const SCENE_EMBEDDED: String = TMP + "/player_embedded.tscn"

const FIXTURE_EXTERNAL: String = """[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/player/player.gd" id="1_abcd"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_xyz"]
size = Vector2(16, 24)

[node name="Player" type="CharacterBody2D"]
script = ExtResource("1_abcd")

[node name="Attack" type="Node" parent="."]
cooldown_seconds = 0.55

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
shape = SubResource("RectangleShape2D_xyz")
"""

## 内嵌脚本形态：script/source 在真实 .tscn 里是单行、以字面 \n 转义序列化。
const FIXTURE_EMBEDDED: String = """[gd_scene load_steps=2 format=3]

[sub_resource type="GDScript" id="GDScript_dqkch"]
script/source = "extends Node\\nvar cooldown_seconds := 0.55\\n"

[node name="Player" type="CharacterBody2D"]

[node name="Attack" type="Node" parent="."]
script = SubResource("GDScript_dqkch")
cooldown_seconds = 0.55
"""

var _tools: RefCounted

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(TMP)
	_write(SCENE_EXTERNAL, FIXTURE_EXTERNAL)
	_write(SCENE_EMBEDDED, FIXTURE_EMBEDDED)
	_write(SCENE_HOST, FIXTURE_HOST)
	_write(SCENE_HOST_PLAIN, FIXTURE_HOST_PLAIN)
	_write(SCENE_DEEP, FIXTURE_DEEP)
	_tools = ToolsScript.new()

func after_each() -> void:
	_tools = null
	_remove_tree(TMP)

# ---------------------------------------------------------------------------
# 实体解析（纯函数）
# ---------------------------------------------------------------------------

func test_resolve_external_script_and_property() -> void:
	# 外部脚本挂在根 Player 上；属性序列化在子节点 Attack 段里。
	var root_entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EXTERNAL, "Player", "speed")
	assert_true(bool(root_entity.get("found", false)), "root node must be found")
	assert_eq(String(root_entity.get("script_mode", "")), "external", "root script is an ExtResource reference")
	assert_eq(String(root_entity.get("script_path", "")), "res://scripts/player/player.gd")
	var child_entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EXTERNAL, "Player/Attack", "cooldown_seconds")
	assert_eq(String(child_entity.get("script_mode", "")), "none", "Attack itself carries no script")
	assert_true(bool(child_entity.get("has_property", false)), "cooldown_seconds serialized in the node section")
	assert_eq(String(child_entity.get("root_name", "")), "Player")

func test_resolve_embedded_script_names_the_killer() -> void:
	var entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EMBEDDED, "Player/Attack", "cooldown_seconds")
	assert_true(bool(entity.get("found", false)))
	assert_eq(String(entity.get("script_mode", "")), "embedded", "SubResource GDScript is an embedded copy")
	assert_eq(String(entity.get("embedded_id", "")), "GDScript_dqkch")
	assert_eq(String(entity.get("embedded_extends", "")), "extends Node", "first source line extracted from escaped serialization")

func test_resolve_non_script_subresource_is_not_embedded_script() -> void:
	# CollisionShape2D 的 shape=SubResource(...) 不得被误判为内嵌脚本。
	var entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EXTERNAL, "Player/CollisionShape2D", "shape")
	assert_true(bool(entity.get("found", false)))
	assert_eq(String(entity.get("script_mode", "")), "none")

func test_resolve_missing_node_reports_not_found() -> void:
	var entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EXTERNAL, "Player/Bow", "cooldown_seconds")
	assert_false(bool(entity.get("found", false)))

func test_resolve_bare_name_falls_back_to_name_match() -> void:
	var entity: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_EXTERNAL, "Attack", "cooldown_seconds")
	assert_true(bool(entity.get("found", false)))
	assert_true(bool(entity.get("matched_by_name", false)), "single-segment target matches by name and says so")

# ---------------------------------------------------------------------------
# 读回表达式与数值比较（纯函数）
# ---------------------------------------------------------------------------

func test_build_readback_expression_is_expression_legal() -> void:
	# 实测铁律：Expression 不支持三元/self——所有生成式必须可直接 parse。
	var deep: String = ToolsScript._build_readback_expression("Arena/Player/Attack", "cooldown_seconds", "Arena")
	assert_eq(deep, "get_node('Player/Attack').cooldown_seconds", "root stripped, no ternary")
	var child: String = ToolsScript._build_readback_expression("Ball", "launch_power", "Golf")
	assert_eq(child, "get_node('Ball').launch_power", "child resolves relative to current_scene")
	var root_case: String = ToolsScript._build_readback_expression("Golf", "level", "Golf")
	assert_eq(root_case, "level", "node-is-root uses the bare property (no self in Expression)")
	# 全部生成式在真实 Expression 引擎下可解析（防止再引入三元类语法）。
	var probe: Expression = Expression.new()
	for expr in [deep, child, root_case]:
		assert_eq(probe.parse(expr, []), OK, "parseable: %s" % expr)

func test_values_match_is_numeric_tolerant() -> void:
	assert_true(ToolsScript._values_match(0.25, 0.25))
	assert_true(ToolsScript._values_match(1, 1.0), "int/float equivalence")
	assert_true(ToolsScript._values_match("0.25", 0.25), "string vs number coercion")
	assert_false(ToolsScript._values_match(0.25, 0.26))
	assert_false(ToolsScript._values_match(true, false))
	assert_false(ToolsScript._values_match(null, 0.0), "null never matches")

# ---------------------------------------------------------------------------
# 工具层（注入编排）
# ---------------------------------------------------------------------------

func _ok_readback(detail: Dictionary) -> Dictionary:
	return {"value": 0.25}

func test_happy_path_reports_effective() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"check_persistence": false, "check_instance_hosts": false})
	assert_false(result.has("error"), str(result))
	assert_eq(String(result.get("overall", "")), "effective", str(result.get("checklist", [])))
	var statuses: Dictionary = {}
	for entry in result.get("checklist", []):
		statuses[String(entry.get("step", ""))] = String(entry.get("status", ""))
	assert_eq(String(statuses.get("target", "")), "verified")
	assert_eq(String(statuses.get("entity", "")), "verified", "external script + no unsaved buffers => verified")
	assert_eq(String(statuses.get("applied", "")), "verified")
	assert_eq(String(statuses.get("behaved", "")), "skipped", "no behavior spec => skipped, not failed")

func test_persistence_step_runs_second_boot_by_default() -> void:
	var calls: Array = []
	_tools._effect_readback_override = func(detail: Dictionary) -> Dictionary:
		calls.append(detail)
		return {"value": 0.25}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25, "check_instance_hosts": false})
	assert_eq(String(result.get("overall", "")), "effective")
	assert_eq(calls.size(), 2, "persist step boots a second time by default")
	var persist_status: String = ""
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "persist":
			persist_status = String(entry.get("status", ""))
	assert_eq(persist_status, "verified")

func test_embedded_copy_with_expected_script_fails_entity_with_fix() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EMBEDDED, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"script_path": "res://scripts/player/player.gd",
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var entity_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "entity":
			entity_entry = entry
	assert_eq(String(entity_entry.get("status", "")), "not_met")
	assert_true(String(entity_entry.get("evidence", "")).contains("EMBEDDED"),
		"evidence must name the embedded copy: %s" % entity_entry.get("evidence", ""))
	var needs: Array = result.get("needs", [])
	var fix_named: bool = false
	for need in needs:
		if String(need).contains("attach_script"):
			fix_named = true
	assert_true(fix_named, "needs must name the attach_script fix: %s" % str(needs))

func test_wrong_external_script_is_a_mismatch() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player",
		"property": "speed", "expected_value": 200.0,
		"script_path": "res://scripts/combat/melee_brain.gd",
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var found: bool = false
	for need in result.get("needs", []):
		if String(need).contains("never loads"):
			found = true
	assert_true(found, "needs must say the node never loads the edited file: %s" % str(result.get("needs", [])))

func test_readback_mismatch_fails_applied() -> void:
	_tools._effect_readback_override = func(_detail: Dictionary) -> Dictionary:
		return {"value": 0.55}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var applied: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "applied":
			applied = entry
	assert_eq(String(applied.get("status", "")), "not_met")
	assert_true(String(applied.get("evidence", "")).contains("0.55"), "evidence carries the live value")

func test_readback_error_fails_applied_with_error_evidence() -> void:
	_tools._effect_readback_override = func(_detail: Dictionary) -> Dictionary:
		return {"error": "runtime never became observable"}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var applied: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "applied":
			applied = entry
	assert_true(String(applied.get("evidence", "")).contains("never became observable"))

func test_persistence_drift_fails_persist_step() -> void:
	# 计数用 Dictionary 单元格：GDScript lambda 按值捕获局部变量，int 计数
	# 不跨调用持久（本会话实测踩坑）。
	var state: Dictionary = {"count": 0}
	_tools._effect_readback_override = func(_detail: Dictionary) -> Dictionary:
		state["count"] = int(state["count"]) + 1
		return {"value": 0.25 if int(state["count"]) == 1 else 0.55}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var persist: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "persist":
			persist = entry
	assert_eq(String(persist.get("status", "")), "not_met")
	assert_true(String(persist.get("evidence", "")).contains("in-memory") or String(persist.get("evidence", "")).contains("second"),
		"evidence explains the in-memory illusion")

func test_behavior_without_assertions_is_rejected_as_smoke() -> void:
	_tools._effect_readback_override = _ok_readback
	_tools._effect_behavior_override = func(_detail: Dictionary) -> Dictionary:
		return {"passed": true, "assertions_total": 0, "assertions_passed": 0}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"behavior": {"steps": [{"wait_ms": 200}]},
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective")
	var behaved: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "behaved":
			behaved = entry
	assert_eq(String(behaved.get("status", "")), "not_met")
	assert_true(String(behaved.get("evidence", "")).contains("smoke"), "zero-assertion behavior is smoke, not proof")

func test_behavior_with_assertions_passes_when_all_assertions_pass() -> void:
	_tools._effect_readback_override = _ok_readback
	_tools._effect_behavior_override = func(_detail: Dictionary) -> Dictionary:
		return {"passed": true, "assertions_total": 2, "assertions_passed": 2}
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"behavior": {"steps": [{"action": "attack", "assert": {"expression": "1 == 1"}}],
			"assertions": [{"expression": "get_node('Attack').cooldown_seconds < 0.5"}]},
		"check_persistence": false, "check_instance_hosts": false})
	assert_eq(String(result.get("overall", "")), "effective", str(result.get("checklist", [])))

func test_missing_scene_fails_target_only() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": "res://.tmp_vce/missing.tscn", "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25})
	assert_eq(String(result.get("overall", "")), "not_effective")
	assert_eq(result.get("checklist", []).size(), 1, "target failure short-circuits the chain")
	assert_eq(String(result.get("checklist", [])[0].get("step", "")), "target")

func test_parameter_validation_rejects_bad_input() -> void:
	var cases: Array = [
		{"node_path": "P", "property": "x", "expected_value": 1},
		{"scene_path": "res://a.tscn", "property": "x", "expected_value": 1},
		{"scene_path": "res://a.tscn", "node_path": "P", "expected_value": 1},
		{"scene_path": "res://a.tscn", "node_path": "P", "property": "x"},
		{"scene_path": "res://a.tscn", "node_path": "P", "property": "not an identifier", "expected_value": 1},
	]
	for params in cases:
		var result: Dictionary = await _tools._tool_verify_change_effect(params)
		assert_true(result.has("error"), "must reject: %s" % str(params))


const SCENE_HOST: String = TMP + "/host.tscn"
const SCENE_HOST_PLAIN: String = TMP + "/host_plain.tscn"
const SCENE_DEEP: String = TMP + "/deep.tscn"

## 宿主场景：实例化 player_external.tscn，并在实例根与子节点两处覆盖属性。
const FIXTURE_HOST: String = """[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://.tmp_vce/player_external.tscn" id="1_player"]
[ext_resource type="Script" path="res://scripts/arena.gd" id="2_arena"]

[node name="Arena" type="Node2D"]
script = ExtResource("2_arena")

[node name="Hero" parent="." instance=ExtResource("1_player")]
speed = 320.0

[node name="Attack" parent="Hero"]
cooldown_seconds = 0.9
"""

## 只实例化、不覆盖任何属性的宿主。
const FIXTURE_HOST_PLAIN: String = """[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://.tmp_vce/player_external.tscn" id="1_player"]

[node name="Arena" type="Node2D"]

[node name="Hero" parent="." instance=ExtResource("1_player")]
"""

## 深度 2 钉死 .tscn parent 语义：parent 值不含根名（TestScene.tscn 实测），
## Root/Mid/Leaf 的 Leaf 段写的是 parent="Mid" 而非 parent="Root/Mid"。
const FIXTURE_DEEP: String = """[gd_scene format=3]

[node name="Root" type="Node2D"]

[node name="Mid" type="Node2D" parent="."]

[node name="Leaf" type="Node2D" parent="Mid"]
cooldown_seconds = 0.4
"""

func test_deep_parent_path_resolution_includes_root_name() -> void:
	var leaf: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_DEEP, "Root/Mid/Leaf", "cooldown_seconds")
	assert_true(bool(leaf.get("found", false)), "depth-2 node resolves with the root name in the path")
	assert_true(bool(leaf.get("has_property", false)))
	var mid: Dictionary = ToolsScript._resolve_scene_entity(FIXTURE_DEEP, "Root/Mid", "cooldown_seconds")
	assert_true(bool(mid.get("found", false)), "depth-1 node still resolves")

func test_instance_override_masks_base_change() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"host_scenes": [SCENE_HOST],
		"check_persistence": false})
	assert_eq(String(result.get("overall", "")), "not_effective",
		"a masked change is not effective even when the base-scene readback passes")
	var hosts_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "hosts":
			hosts_entry = entry
	assert_eq(String(hosts_entry.get("status", "")), "not_met")
	assert_true(String(hosts_entry.get("evidence", "")).contains("0.9"),
		"evidence names the masking value: %s" % hosts_entry.get("evidence", ""))
	var fix: String = ""
	for need in result.get("needs", []):
		if String(need).contains("batch_update_scene_files"):
			fix = String(need)
	assert_true(fix.contains(SCENE_HOST) and fix.contains("Hero/Attack") and fix.contains("expect_current: 0.9"),
		"needs names the exact host, node and guard value: %s" % fix)
	var resolved_hosts: Array = result.get("resolved", {}).get("instance_hosts", [])
	assert_eq(resolved_hosts.size(), 1, "resolved carries the discovered host")

func test_instance_override_matching_expected_verifies_hosts() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.9,
		"host_scenes": [SCENE_HOST],
		"check_persistence": false})
	var hosts_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "hosts":
			hosts_entry = entry
	assert_eq(String(hosts_entry.get("status", "")), "verified",
		"an override equal to the expected value is the wanted state, not a mask")

func test_host_without_override_verifies_hosts() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"host_scenes": [SCENE_HOST_PLAIN],
		"check_persistence": false})
	var hosts_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "hosts":
			hosts_entry = entry
	assert_eq(String(hosts_entry.get("status", "")), "verified")
	assert_true(String(hosts_entry.get("evidence", "")).contains("instanced by 1"))

func test_no_hosts_skipped() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"host_scenes": [SCENE_EMBEDDED],
		"check_persistence": false})
	var hosts_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "hosts":
			hosts_entry = entry
	assert_eq(String(hosts_entry.get("status", "")), "skipped",
		"a standalone scene has no hosts to check")
	assert_true(String(hosts_entry.get("evidence", "")).contains("pinned"))

func test_auto_scan_discovers_host_and_mask() -> void:
	_tools._effect_readback_override = _ok_readback
	var result: Dictionary = await _tools._tool_verify_change_effect({
		"scene_path": SCENE_EXTERNAL, "node_path": "Player/Attack",
		"property": "cooldown_seconds", "expected_value": 0.25,
		"check_persistence": false})
	assert_true(int(result.get("resolved", {}).get("hosts_scanned_files", 0)) > 0,
		"auto scan ran and reports how many scene files it scanned")
	var hosts_entry: Dictionary = {}
	for entry in result.get("checklist", []):
		if String(entry.get("step", "")) == "hosts":
			hosts_entry = entry
	assert_eq(String(hosts_entry.get("status", "")), "not_met",
		"the scan must find host.tscn and its masking override")

func test_instance_root_override_detected_pure() -> void:
	var found: Dictionary = ToolsScript._effect_instance_overrides(
		FIXTURE_HOST, "res://.tmp_vce/player_external.tscn", "", "speed")
	var instances: Array = found.get("instances", [])
	assert_eq(instances.size(), 1, "one instance of the base scene")
	assert_eq(String(instances[0].get("node", "")), "Hero")
	var overrides: Array = found.get("overrides", [])
	assert_eq(overrides.size(), 1, "instance-root override found")
	assert_eq(String(overrides[0].get("node", "")), "Arena/Hero")
	assert_eq(String(overrides[0].get("value", "")), "320.0")

func test_child_override_detected_pure() -> void:
	var found: Dictionary = ToolsScript._effect_instance_overrides(
		FIXTURE_HOST, "res://.tmp_vce/player_external.tscn", "Attack", "cooldown_seconds")
	var overrides: Array = found.get("overrides", [])
	assert_eq(overrides.size(), 1, "child-section override found via instance root + child path")
	assert_eq(String(overrides[0].get("node", "")), "Arena/Hero/Attack")
	assert_eq(String(overrides[0].get("value", "")), "0.9")

func test_instance_detection_ignores_other_scene_references() -> void:
	# SCENE_EMBEDDED 不实例化 base —— 解析结果应为空。
	var found: Dictionary = ToolsScript._effect_instance_overrides(
		FIXTURE_EMBEDDED, "res://.tmp_vce/player_external.tscn", "Attack", "cooldown_seconds")
	assert_eq((found.get("instances", []) as Array).size(), 0)
	assert_eq((found.get("overrides", []) as Array).size(), 0)

# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _write(path: String, content: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for entry in dir.get_files():
		dir.remove(entry)
	var root: DirAccess = DirAccess.open("res://")
	var rel: String = path.trim_prefix("res://").trim_suffix("/")
	if root and root.dir_exists(rel):
		root.remove(rel)
