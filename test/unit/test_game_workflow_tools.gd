extends "res://addons/gut/test.gd"

const BlueprintsScript = preload("res://addons/godot_mcp/native_mcp/goal_blueprints.gd")

func test_goal_blueprint_verbs_bilingual():
	var verbs: Dictionary = BlueprintsScript.match_verbs(
		"arrow-key player movement, collect a coin, show a win label")
	assert_true(bool(verbs.get("movement", false)), "English movement verb matched")
	assert_true(bool(verbs.get("collectible", false)), "English collectible verb matched")
	assert_true(bool(verbs.get("win", false)), "English win verb matched")
	var zh: Dictionary = BlueprintsScript.match_verbs(
		"方向键移动的角色吃到金币后显示胜利")
	assert_true(bool(zh.get("movement", false)), "Chinese movement verb matched")
	assert_true(bool(zh.get("collectible", false)), "Chinese collectible verb matched")
	assert_true(bool(zh.get("win", false)), "Chinese win verb matched")
	var none: Dictionary = BlueprintsScript.match_verbs(
		"a story about tea")
	assert_false(BlueprintsScript.has_any_verb(none),
		"Unrelated objective produces no blueprint")

func test_goal_blueprint_controller_compiles_and_moves():
	var source: String = BlueprintsScript.controller_script(
		"arrow-key movement, collectible coin, win label")
	assert_true(source.contains("move_and_slide()"), "Blueprint contains real movement")
	assert_true(source.contains("_on_coin_touched"), "Blueprint contains pickup logic")
	assert_true(source.contains("You Win!"), "Blueprint contains win condition")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = source
	assert_eq(test_script.reload(), OK, "Composed blueprint must compile cleanly")
	var movement_only: String = BlueprintsScript.controller_script("arrow-key movement only")
	assert_true(movement_only.contains("move_and_slide()"), "Movement-only keeps movement")
	assert_false(movement_only.contains("_on_coin_touched"), "Movement-only drops pickup block")

func test_platformer_objective_matches_movement_blueprint():
	# 插件自带 prompt 示例就是 "2D platformer vertical slice"——
	# platformer/jump 词表缺失会让这类目标拿不到移动蓝图与 CharacterBody2D 根。
	var verbs: Dictionary = BlueprintsScript.match_verbs("2D platformer with jumping")
	assert_true(bool(verbs.get("movement", false)), "platformer counts as movement")
	var source: String = BlueprintsScript.controller_script("2D platformer with coins")
	assert_true(source.contains("move_and_slide()"), "Platformer blueprint keeps real movement")
	var zh: Dictionary = BlueprintsScript.match_verbs("平台跳跃小游戏")
	assert_true(bool(zh.get("movement", false)), "Chinese platformer verb matched")

func test_platformer_goal_gets_sideview_jump_blueprint_not_topdown():
	# 语义修复回归：platformer/jump 目标此前拿到俯视 8 方向蓝图——能编译能跑
	# 但跳不起来，门禁全绿却没达成目标。现在必须生成带重力与跳跃的横版控制器。
	var source: String = BlueprintsScript.controller_script("2D platformer with jumping and coins")
	assert_true(source.contains("JUMP_SPEED"), "Side-view blueprint has a jump impulse")
	assert_true(source.contains("is_on_floor()"), "Side-view blueprint has a ground check")
	assert_true(source.contains("_gravity"), "Side-view blueprint applies gravity")
	assert_false(source.contains("get_vector("), "Side-view blueprint must not be top-down")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = source
	assert_eq(test_script.reload(), OK, "Side-view blueprint must compile cleanly")

func test_jump_verbs_bilingual_and_jump_only_still_activates_blueprint():
	var zh: Dictionary = BlueprintsScript.match_verbs("横版平台跳跃，按空格跳")
	assert_true(bool(zh.get("jump", false)), "Chinese jump verb matched")
	assert_true(bool(zh.get("movement", false)), "Chinese jump implies movement")
	var top_down: Dictionary = BlueprintsScript.match_verbs("arrow-key movement only")
	assert_false(bool(top_down.get("jump", false)), "Top-down goal has no jump verb")
	# side-scroll/gravity 只在 JUMP 词表：不能因此漏掉蓝图（jump 蕴含 movement）。
	var jump_only: Dictionary = BlueprintsScript.match_verbs("side-scrolling gravity game")
	assert_true(BlueprintsScript.has_any_verb(jump_only),
		"Jump-only keywords still activate a blueprint")
	var jump_only_source: String = BlueprintsScript.controller_script("side-scrolling gravity game")
	assert_true(jump_only_source.contains("is_on_floor()"),
		"Jump-only objective gets the side-view controller")

func test_topdown_goal_keeps_eight_direction_blueprint():
	var source: String = BlueprintsScript.controller_script("arrow-key movement, collect coins")
	assert_true(source.contains("get_vector("), "Top-down blueprint keeps 8-direction movement")
	assert_false(source.contains("JUMP_SPEED"), "Top-down blueprint has no jump impulse")

func test_collectible_only_controller_extends_character_body():
	# 金币/胜利蓝图同样依赖物理体：任意动词命中的控制器都必须 extends CharacterBody2D，
	# 根节点派生条件（game_workflow_tools.gd）与这里保持一致。
	var source: String = BlueprintsScript.controller_script("collect a coin and show a win label")
	assert_true(source.contains("extends CharacterBody2D"),
		"Collectible-only controller still extends CharacterBody2D")

func test_goal_semantic_test_script_compiles_and_targets_verbs():
	# 移动+收集目标：断言位移与"走到并吃到 + 胜利标签"。
	var source: String = BlueprintsScript.semantic_test_script(
		"arrow-key movement, collect a coin, show a win label",
		"res://scenes/gameplay-feature.tscn")
	assert_true(source.contains("test_goal_semantics"), "Semantic suite has a test method")
	assert_true(source.contains("collects the coin"), "Collection is asserted for collectible goals")
	assert_true(source.contains("win label appears"), "Win label is asserted")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "Semantic suite must compile cleanly")

func test_goal_semantic_test_jump_variant_asserts_upward_launch():
	var source: String = BlueprintsScript.semantic_test_script(
		"2D platformer with jumping and coins", "res://scenes/gameplay-feature.tscn")
	assert_true(source.contains("jump input launches"), "Jump goals assert upward motion")
	assert_true(source.contains("horizontal input moves"), "Jump goals assert horizontal movement")
	var script: GDScript = GDScript.new()
	script.source_code = source
	assert_eq(script.reload(), OK, "Jump semantic suite must compile cleanly")

func test_goal_semantic_test_collect_only_skips_reach_assertion():
	# 纯收集目标（无移动动词）不能断言"走到并吃到"——玩家不会动，只能断言
	# 拾取体与标签存在。
	var source: String = BlueprintsScript.semantic_test_script(
		"a win label after collecting", "res://scenes/gameplay-feature.tscn")
	assert_false(source.contains("reaches and collects"),
		"Collect-only goals must not assert unreachable collection")
	assert_true(source.contains("contains the collectible"), "Existence checks remain")

func test_goal_semantic_test_empty_for_unrelated_objectives():
	assert_eq(BlueprintsScript.semantic_test_script("a story about tea", "res://scenes/x.tscn"),
		"", "Unrelated goals generate no semantic suite")
	assert_eq(BlueprintsScript.semantic_test_script("arrow-key movement", ""),
		"", "Missing scene path generates no semantic suite")

# ---------------------------------------------------------------------------
# needs_input 内容简报
# ---------------------------------------------------------------------------


func _typed(values: Array) -> Array[String]:
	var typed: Array[String] = []
	for value in values:
		typed.append(String(value))
	return typed

func _brief_plan() -> Dictionary:
	return {
		"goal": "Create an enemy AI patrol script",
		"workflow": {
			"artifacts": {"scene": "res://scenes/gameplay-feature.tscn"},
		},
		"tasks": [
			{"id": "wf_001", "tool_name": "get_project_info", "objective_gate": false, "status": "done"},
			{"id": "wf_002", "tool_name": "create_scene", "objective_gate": false, "status": "done"},
			{"id": "wf_003", "tool_name": "create_script", "objective_gate": false, "status": "pending"},
			{"id": "wf_004", "tool_name": "verify_scripts", "objective_gate": true, "status": "pending"},
			{"id": "wf_005", "tool_name": "game_semantics", "objective_gate": true, "status": "done"},
			{"id": "wf_006", "tool_name": "play_and_verify", "objective_gate": true, "status": "pending"},
		],
	}

func test_content_brief_covers_creative_params_with_goal_and_gates():
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var plan: Dictionary = _brief_plan()
	var task: Dictionary = (plan["tasks"] as Array)[2]
	task["profile"] = "gameplay_feature"
	task["step_key"] = "create_script"
	var brief: Dictionary = tools._content_brief(plan, task, "create_script",
		{"script_path": "res://scripts/enemy.gd"}, _typed(["content"]))
	assert_eq(String(brief.get("goal", "")), "Create an enemy AI patrol script",
		"The brief carries the original goal text")
	assert_eq(String(brief.get("target_file", "")), "res://scripts/enemy.gd",
		"The brief names the target file")
	assert_true((brief.get("artifacts", {}) as Dictionary).has("scene"),
		"Produced artifacts are included as reference context")
	var gates: Array = brief.get("downstream_gates", [])
	assert_has(gates, "verify_scripts", "Pending gates after this step are listed")
	assert_has(gates, "play_and_verify", "All pending gates are listed")
	assert_does_not_have(gates, "game_semantics",
		"Already-done gates are excluded from the brief")

func test_content_brief_includes_existing_content_for_edits():
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var temp_path: String = "res://test/unit/.tmp_brief_edit.gd"
	var file: FileAccess = FileAccess.open(
		ProjectSettings.globalize_path(temp_path), FileAccess.WRITE)
	file.store_string("extends Node\n\nfunc patrol() -> void:\n\tpass\n")
	file.close()
	var plan: Dictionary = _brief_plan()
	var task: Dictionary = (plan["tasks"] as Array)[2]
	var brief: Dictionary = tools._content_brief(plan, task, "modify_script",
		{"script_path": temp_path}, _typed(["content"]))
	assert_true(String(brief.get("existing_content", "")).contains("func patrol"),
		"Edits include the current file content for anchored changes")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))

func test_content_brief_truncates_oversized_files():
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var temp_path: String = "res://test/unit/.tmp_brief_big.gd"
	var file: FileAccess = FileAccess.open(
		ProjectSettings.globalize_path(temp_path), FileAccess.WRITE)
	var filler: String = "# line\n".repeat(1200)
	file.store_string(filler)
	file.close()
	var plan: Dictionary = _brief_plan()
	var task: Dictionary = (plan["tasks"] as Array)[2]
	var brief: Dictionary = tools._content_brief(plan, task, "modify_script",
		{"script_path": temp_path}, _typed(["content"]))
	assert_true(bool(brief.get("existing_content_truncated", false)),
		"Oversized content is flagged as truncated")
	assert_lt(String(brief.get("existing_content_head", "")).length(), 4200,
		"The head stays bounded")
	assert_gt(int(brief.get("existing_content_lines", 0)), 1000,
		"Total line count is reported for orientation")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))

func test_content_brief_skips_non_creative_params():
	var tools: RefCounted = preload("res://addons/godot_mcp/tools/game_workflow_tools.gd").new()
	var plan: Dictionary = _brief_plan()
	var task: Dictionary = (plan["tasks"] as Array)[2]
	assert_true(tools._content_brief(plan, task, "create_scene",
		{}, _typed(["scene_name", "root_type"])).is_empty(),
		"Path/number inputs keep the bare schema without a brief")

func test_enemy_and_score_verbs_bilingual_and_compose():
	var verbs: Dictionary = BlueprintsScript.match_verbs("an enemy chases the player and coins award score")
	assert_true(bool(verbs.get("enemy", false)), "English enemy verb matched")
	assert_true(bool(verbs.get("score", false)), "English score verb matched")
	var zh: Dictionary = BlueprintsScript.match_verbs("敌人追击玩家，金币计分")
	assert_true(bool(zh.get("enemy", false)), "Chinese enemy verb matched")
	assert_true(bool(zh.get("score", false)), "Chinese score verb matched")
	assert_true(bool(zh.get("collectible", false)), "Chinese score goal still collects coins")
	# score 蕴含收集：score-only 目标也要生成可玩的拾取循环。
	var score_only: Dictionary = BlueprintsScript.match_verbs("add a scoring system")
	assert_true(BlueprintsScript.has_any_verb(score_only), "Score-only activates a blueprint")
	var controller: String = BlueprintsScript.controller_script("add a scoring system")
	assert_true(controller.contains("_on_coin_touched"), "Score implies a collectible loop")
	assert_true(controller.contains("ScoreLabel"), "Score controller renders a score label")

func test_enemy_controller_and_semantics_compile():
	var controller: String = BlueprintsScript.controller_script(
		"an enemy chases the arrow-key player who collects coins")
	assert_true(controller.contains("_enemy"), "Enemy block present")
	assert_true(controller.contains("ENEMY_SPEED"), "Chase speed constant present")
	assert_true(controller.contains("direction_to"), "Chase uses direction_to toward the player")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = controller
	assert_eq(test_script.reload(), OK, "Enemy controller must compile cleanly")
	var semantic: String = BlueprintsScript.semantic_test_script(
		"an enemy chases the arrow-key player who collects coins", "res://scenes/g.tscn")
	assert_true(semantic.contains("the enemy chases the player"), "Chase behavior is asserted")
	var semantic_script: GDScript = GDScript.new()
	semantic_script.source_code = semantic
	assert_eq(semantic_script.reload(), OK, "Enemy semantic suite must compile cleanly")

func test_enemy_only_goal_gets_physics_loop_without_movement():
	var controller: String = BlueprintsScript.controller_script("spawn a monster that chases")
	assert_true(controller.contains("_physics_process"),
		"Enemy-only goals still get a physics loop to drive the chase")
	assert_false(controller.contains("get_vector("),
		"Enemy-only goals add no top-down movement")

func test_score_semantic_asserts_score_updates():
	var semantic: String = BlueprintsScript.semantic_test_script(
		"arrow-key movement with coins and a score counter", "res://scenes/g.tscn")
	assert_true(semantic.contains("score updates after collection"),
		"Score goals assert the label updates")

func test_shoot_verbs_classify_but_delegate_content():
	# 射击类只做分类与语义基线：不硬造弹道蓝图，走客户端创作 + 内容简报。
	var verbs: Dictionary = BlueprintsScript.match_verbs("a space shooter that fires bullets")
	assert_true(bool(verbs.get("shoot", false)), "English shoot verb matched")
	var zh: Dictionary = BlueprintsScript.match_verbs("太空射击游戏，发射子弹")
	assert_true(bool(zh.get("shoot", false)), "Chinese shoot verb matched")
	assert_true(bool(zh.get("movement", false)) or BlueprintsScript.has_any_verb(zh),
		"Shoot goals still activate the blueprint family")
	var controller: String = BlueprintsScript.controller_script("a space shooter that fires bullets")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = controller
	assert_eq(test_script.reload(), OK, "Shoot-goal controller compiles (movement base)")

func test_three_d_goal_gets_3d_blueprint_and_semantics():
	var verbs: Dictionary = BlueprintsScript.match_verbs("3D game where the player moves and jumps")
	assert_true(bool(verbs.get("three_d", false)), "English 3D keyword matched")
	var zh: Dictionary = BlueprintsScript.match_verbs("三维小游戏，角色移动跳跃")
	assert_true(bool(zh.get("three_d", false)), "Chinese 3D keyword matched")
	var controller: String = BlueprintsScript.controller_script("3D game where the player moves and jumps")
	assert_true(controller.contains("extends CharacterBody3D"), "3D goals get a 3D controller")
	assert_true(controller.contains("WorldBoundaryShape3D"), "3D controller generates the ground plane")
	assert_true(controller.contains("Camera3D"), "3D controller spawns a camera")
	assert_true(controller.contains("DirectionalLight3D"), "3D controller spawns a light")
	assert_false(controller.contains("CharacterBody2D"), "No 2D physics in the 3D blueprint")
	var test_script: GDScript = GDScript.new()
	test_script.source_code = controller
	assert_eq(test_script.reload(), OK, "3D controller must compile cleanly")
	var semantic: String = BlueprintsScript.semantic_test_script(
		"3D game where the player moves and jumps", "res://scenes/g.tscn")
	assert_true(semantic.contains("CharacterBody3D"), "3D semantic suite casts the 3D body")
	assert_true(semantic.contains("jump input launches"), "3D jump semantics asserted")
	assert_true(semantic.contains("settle"), "3D suite waits for grounding first")
	var semantic_script: GDScript = GDScript.new()
	semantic_script.source_code = semantic
	assert_eq(semantic_script.reload(), OK, "3D semantic suite must compile cleanly")

func test_2d_goals_unchanged_by_3d_blueprint():
	var controller: String = BlueprintsScript.controller_script("arrow-key movement with coins")
	assert_true(controller.contains("extends CharacterBody2D"),
		"2D goals still get the 2D controller")
	assert_false(controller.contains("CharacterBody3D"), "No 3D leakage into 2D goals")
