# goal_blueprints.gd
# 目标感知的代码蓝图：当目标语句提到移动/收集/胜利等动词时，为
# create_script 步骤生成真实可运行的 GDScript，而不是占位脚本——
# 闭环的产出因此是"能玩的最小游戏"。调用方显式提供的 content 永远优先。
#
# 有界设计：只覆盖少量高频动词，按块组合；不追求通用代码生成。

class_name GoalBlueprints
extends RefCounted

# 目标动词（双语）→ 蓝图块开关。
# platformer/jump/player 与引擎 PROFILE_KEYWORDS 同步：插件自带 prompt 示例
# 就是 "2D platformer vertical slice"，缺这些词会让规划漏掉移动蓝图。
const MOVEMENT_KEYWORDS: Array[String] = [
	"movement", "arrow-key", "arrow key", "move", "controller", "wasd",
	"platformer", "jump", "player", "playable", "character",
	"移动", "方向键", "移动控制", "平台跳跃", "跳跃", "玩家", "角色", "可玩",
]
# 横版跳跃子类：同样命中 movement，但控制器必须带重力与跳跃——
# 俯视 8 方向蓝图对 platformer/jump 目标是语义性假完成（能编译能跑但跳不起来）。
const JUMP_KEYWORDS: Array[String] = [
	"jump", "platformer", "side-scroll", "side scroll", "side-scroller",
	"side scroller", "gravity",
	"跳跃", "平台跳跃", "横版",
]
const COLLECTIBLE_KEYWORDS: Array[String] = [
	"collectible", "collect", "coin", "pickup", "pick up", "item",
	"收集", "金币", "拾取", "道具",
]
const WIN_KEYWORDS: Array[String] = [
	"win", "victory", "goal reached", "success screen", "win label", "win text",
	"胜利", "获胜", "通关",
]
# 敌人：追逐者块。射击类只做分类（客户端凭内容简报创作，服务端蓝图不硬造
# 弹道/朝向逻辑）；计分蕴含收集（没有可收集物就没有可计的分）。
const ENEMY_KEYWORDS: Array[String] = [
	"enemy", "enemies", "monster", "foe", "chase", "patrol",
	"敌人", "怪物", "追击", "追逐", "巡逻",
]
const SHOOT_KEYWORDS: Array[String] = [
	"shoot", "shooter", "fire", "bullet", "projectile", "laser",
	"射击", "子弹", "发射", "激光",
]
const SCORE_KEYWORDS: Array[String] = [
	"score", "scoring", "points",
	"计分", "得分", "分数",
]

static func _mentions(objective: String, keywords: Array[String]) -> bool:
	var text: String = objective.to_lower()
	for keyword in keywords:
		if text.contains(keyword.to_lower()):
			return true
	return false

## 目标命中的动词集合。
static func match_verbs(objective: String) -> Dictionary:
	return {
		"movement": _mentions(objective, MOVEMENT_KEYWORDS),
		"jump": _mentions(objective, JUMP_KEYWORDS),
		"collectible": _mentions(objective, COLLECTIBLE_KEYWORDS),
		"win": _mentions(objective, WIN_KEYWORDS),
		"enemy": _mentions(objective, ENEMY_KEYWORDS),
		"shoot": _mentions(objective, SHOOT_KEYWORDS),
		"score": _mentions(objective, SCORE_KEYWORDS),
	}

static func has_any_verb(verbs: Dictionary) -> bool:
	# jump 蕴含 movement：side-scroll/gravity 这类词只在 JUMP 词表里，
	# 不能因此漏掉蓝图与 CharacterBody2D 根派生。
	return bool(verbs.get("movement", false)) \
		or bool(verbs.get("jump", false)) \
		or bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false)) \
		or bool(verbs.get("enemy", false)) \
		or bool(verbs.get("shoot", false)) \
		or bool(verbs.get("score", false))

## 组合出挂在场景根上的完整控制器脚本；目标未命中任何动词时返回空串。
static func controller_script(objective: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not has_any_verb(verbs):
		return ""
	var needs_pickup: bool = bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false)) or bool(verbs.get("score", false))
	var wants_jump: bool = bool(verbs.get("jump", false))
	var wants_enemy: bool = bool(verbs.get("enemy", false))
	var wants_score: bool = bool(verbs.get("score", false))

	var source: String = "# Goal blueprint: minimal playable controller.\n"
	source += "extends CharacterBody2D\n\n"
	source += "signal coins_changed(collected: int)\n\n"
	source += "const SPEED: float = 260.0\n"
	if wants_enemy:
		source += "const ENEMY_SPEED: float = 120.0\n"
	if needs_pickup:
		source += "const COINS_TO_WIN: int = 1\n"
	if wants_jump:
		source += "const JUMP_SPEED: float = 420.0\n"
		source += "var _gravity: float = ProjectSettings.get_setting(\"physics/2d/default_gravity\", 980.0) as float\n"
	source += "\nvar coins_collected: int = 0\n"
	if needs_pickup:
		source += "var _coin_area: Area2D\nvar _win_label: Label\n"
	if wants_score:
		source += "var _score_label: Label\n"
	if wants_enemy:
		source += "var _enemy: CharacterBody2D\n"
	source += "\nfunc _ready() -> void:\n"
	# 玩家碰撞形状：没有它，拾取区 body_entered 永远不会触发（无形状的物理体
	# 不参与 Area2D 检测）——金币在旧蓝图里事实上不可被收集。
	if needs_pickup:
		source += "\tvar body_collision := CollisionShape2D.new()\n"
		source += "\tvar body_shape := RectangleShape2D.new()\n"
		source += "\tbody_shape.size = Vector2(32, 32)\n"
		source += "\tbody_collision.shape = body_shape\n"
		source += "\tadd_child(body_collision)\n"
	# 横版目标补一块地面（挂到世界父节点，不能挂玩家身上否则随人移动）。
	if wants_jump:
		source += "\tvar floor_parent: Node = get_parent() if get_parent() != null else self\n"
		source += "\tvar floor_body := StaticBody2D.new()\n"
		source += "\tfloor_body.name = \"Floor\"\n"
		source += "\tfloor_body.position = Vector2(0, 240)\n"
		source += "\tvar floor_collision := CollisionShape2D.new()\n"
		source += "\tvar floor_shape := RectangleShape2D.new()\n"
		source += "\tfloor_shape.size = Vector2(2000, 20)\n"
		source += "\tfloor_collision.shape = floor_shape\n"
		source += "\tfloor_body.add_child(floor_collision)\n"
		source += "\tfloor_parent.add_child(floor_body)\n"
	if needs_pickup:
		# 俯视金币放在测试的右下对角线上（走直线就能碰到）；横版金币贴近地面
		# 高度（沿地面走可碰）。金币必须挂世界父节点：挂玩家身上会随人同步
		# 移动，相对距离永不变，拾取永远不可能触发（语义测试抓出的旧缺陷）。
		var coin_pos: String = "180, 196" if wants_jump else "150, 150"
		source += "\tvar world_parent: Node = get_parent() if get_parent() != null else self\n"
		source += "\t# 运行期生成拾取体与胜利标签，保持编辑场景最小。\n"
		source += "\t_coin_area = Area2D.new()\n"
		source += "\t_coin_area.name = \"Coin\"\n"
		source += "\t_coin_area.position = Vector2(%s)\n" % coin_pos
		source += "\tvar coin_collision := CollisionShape2D.new()\n"
		source += "\tvar coin_shape := CircleShape2D.new()\n"
		source += "\tcoin_shape.radius = 14\n"
		source += "\tcoin_collision.shape = coin_shape\n"
		source += "\t_coin_area.add_child(coin_collision)\n"
		source += "\tworld_parent.add_child(_coin_area)\n"
		source += "\t_coin_area.body_entered.connect(_on_coin_touched)\n"
		source += "\tvar canvas := CanvasLayer.new()\n"
		source += "\tcanvas.name = \"WinCanvas\"\n"
		source += "\tadd_child(canvas)\n"
		source += "\t_win_label = Label.new()\n"
		source += "\t_win_label.name = \"WinLabel\"\n"
		source += "\t_win_label.text = \"\"\n"
		source += "\t_win_label.position = Vector2(40, 20)\n"
		source += "\tcanvas.add_child(_win_label)\n"
	# 计分标签：score 蕴含收集（needs_pickup 恒真），复用胜利画布，随
	# coins_changed 实时更新。
	if wants_score:
		source += "\t_score_label = Label.new()\n"
		source += "\t_score_label.name = \"ScoreLabel\"\n"
		source += "\t_score_label.text = \"Score: 0\"\n"
		source += "\t_score_label.position = Vector2(40, 60)\n"
		source += "\tcanvas.add_child(_score_label)\n"
		source += "\tcoins_changed.connect(_on_score_changed)\n"
	# 追逐者敌人：世界父节点生成（与金币同理不能挂玩家），每物理帧向玩家移动。
	if wants_enemy:
		source += "\tvar enemy_parent: Node = get_parent() if get_parent() != null else self\n"
		source += "\t_enemy = CharacterBody2D.new()\n"
		source += "\t_enemy.name = \"Enemy\"\n"
		source += "\t_enemy.position = Vector2(260, -60)\n"
		source += "\tvar enemy_collision := CollisionShape2D.new()\n"
		source += "\tvar enemy_shape := RectangleShape2D.new()\n"
		source += "\tenemy_shape.size = Vector2(24, 24)\n"
		source += "\tenemy_collision.shape = enemy_shape\n"
		source += "\t_enemy.add_child(enemy_collision)\n"
		source += "\tenemy_parent.add_child(_enemy)\n"
	# 兜底：没有任何 _ready 块时补 pass，避免空函数体解析错误。
	if not needs_pickup and not wants_jump and not wants_score and not wants_enemy:
		source += "\tpass\n"
	# shoot 蕴含 movement：射击游戏必然要能移动（弹道/发射逻辑由客户端经
	# 内容简报创作，服务端给可移动载体）。
	var wants_movement: bool = bool(verbs.get("movement", false)) or wants_jump \
		or bool(verbs.get("shoot", false))
	var needs_physics: bool = wants_movement or wants_enemy
	if needs_physics:
		if wants_jump:
			# 横版跳跃：水平移动 + 重力 + 地面检测 + 跳跃（jump 动作存在则用，
			# 否则回退 ui_accept——Space/Enter 内建可用，未 upsert 也能跳）。
			# JUMP_SPEED/_gravity 声明已挪到头部（含 win-only 跳跃目标）。
			source += "\nfunc _physics_process(delta: float) -> void:\n"
			source += "\tvar direction := Input.get_axis(\"move_left\", \"move_right\")\n"
			source += "\tif absf(direction) < 0.1:\n"
			source += "\t\tdirection = Input.get_axis(\"ui_left\", \"ui_right\")\n"
			source += "\tvelocity.x = direction * SPEED\n"
			source += "\tif not is_on_floor():\n"
			source += "\t\tvelocity.y += _gravity * delta\n"
			source += "\tvar jump_requested: bool = (InputMap.has_action(\"jump\") and Input.is_action_pressed(\"jump\")) or Input.is_action_pressed(\"ui_accept\")\n"
			source += "\tif jump_requested and is_on_floor():\n"
			source += "\t\tvelocity.y = -JUMP_SPEED\n"
			source += "\tmove_and_slide()\n"
		elif wants_movement:
			source += "\nfunc _physics_process(_delta: float) -> void:\n"
			source += "\tvar direction := Input.get_vector(\"move_left\", \"move_right\", \"move_up\", \"move_down\")\n"
			source += "\tif direction == Vector2.ZERO:\n"
			source += "\t\tdirection = Vector2(\n"
			source += "\t\t\tInput.get_axis(\"ui_left\", \"ui_right\"),\n"
			source += "\t\t\tInput.get_axis(\"ui_up\", \"ui_down\"))\n"
			source += "\tvelocity = direction * SPEED\n"
			source += "\tmove_and_slide()\n"
		else:
			# 纯敌人目标（无移动动词）也要有物理循环驱动追逐。
			source += "\nfunc _physics_process(_delta: float) -> void:\n"
		if wants_enemy:
			source += "\tif _enemy != null:\n"
			source += "\t\t_enemy.velocity = _enemy.global_position.direction_to(global_position) * ENEMY_SPEED\n"
			source += "\t\t_enemy.move_and_slide()\n"
	if needs_pickup:
		source += "\nfunc _on_coin_touched(body: Node) -> void:\n"
		source += "\tif body != self:\n"
		source += "\t\treturn\n"
		source += "\tcoins_collected += 1\n"
		source += "\tcoins_changed.emit(coins_collected)\n"
		source += "\t_coin_area.queue_free()\n"
		source += "\tif coins_collected >= COINS_TO_WIN and _win_label != null:\n"
		source += "\t\t_win_label.text = \"You Win!\"\n"
	if wants_score:
		source += "\nfunc _on_score_changed(collected: int) -> void:\n"
		source += "\tif _score_label != null:\n"
		source += "\t\t_score_label.text = \"Score: %d\" % collected\n"
	return source

## 目标语义测试：把目标文字编译成可执行的 McpGameTestSuite —— completed 的
## 证据从"没有报错"升级为"目标描述的行为真的发生了"（移动会位移、跳跃会
## 升起、金币被走到并吃到、胜利标签随后出现）。未命中动词返回空串。
## 用路径形式 extends：不依赖项目的全局类缓存，冷启动子进程也能解析。
static func semantic_test_script(objective: String, scene_path: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not has_any_verb(verbs) or scene_path.is_empty():
		return ""
	var wants_pickup: bool = bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false)) or bool(verbs.get("score", false))
	var wants_enemy: bool = bool(verbs.get("enemy", false))
	var wants_score: bool = bool(verbs.get("score", false))
	# 只有能移动的目标才断言"走到并吃到"；纯收集目标只断言拾取体与标签存在。
	var wants_collection: bool = wants_pickup \
		and (bool(verbs.get("movement", false)) or bool(verbs.get("jump", false)) \
			or bool(verbs.get("shoot", false)))
	var needs_actions: bool = bool(verbs.get("movement", false)) \
		or bool(verbs.get("jump", false)) or bool(verbs.get("shoot", false))

	var source: String = "# Goal semantic test generated from the objective; run via run_game_tests.\n"
	source += "extends \"res://addons/godot_mcp/game_tests/game_test_suite.gd\"\n\n"
	source += "const SCENE_PATH: String = \"%s\"\n\n" % scene_path
	if needs_actions:
		# 子进程 InputMap 可能没有工作流 upsert 的动作（例如套件被单独运行）：
		# 运行期补注册缺失动作，只影响本进程，不写 project.godot。
		source += "func before_all() -> void:\n"
		source += "\t_ensure_input_actions()\n\n"
		source += "func _ensure_input_actions() -> void:\n"
		source += "\tvar fallbacks: Dictionary = {\"move_left\": KEY_LEFT, \"move_right\": KEY_RIGHT, \"move_up\": KEY_UP, \"move_down\": KEY_DOWN, \"jump\": KEY_SPACE}\n"
		source += "\tfor action_name in fallbacks:\n"
		source += "\t\tif InputMap.has_action(action_name):\n"
		source += "\t\t\tcontinue\n"
		source += "\t\tInputMap.add_action(action_name)\n"
		source += "\t\tvar event := InputEventKey.new()\n"
		source += "\t\tevent.physical_keycode = fallbacks[action_name]\n"
		source += "\t\tInputMap.action_add_event(action_name, event)\n\n"
	source += "func test_goal_semantics() -> void:\n"
	source += "\tvar game: Node = load_scene(SCENE_PATH)\n"
	source += "\tcheck_not_null(game, \"goal scene loads and instantiates\")\n"
	source += "\tif game == null or not (game is CharacterBody2D):\n"
	source += "\t\treturn\n"
	source += "\tvar body: CharacterBody2D = game as CharacterBody2D\n"
	source += "\tvar start_position: Vector2 = body.global_position\n"
	if bool(verbs.get("jump", false)):
		source += "\tpress_action(\"move_right\")\n"
		source += "\tvar moved_right: bool = await wait_until(func() -> bool: return body.global_position.x > start_position.x + 8.0, 4000)\n"
		source += "\trelease_action(\"move_right\")\n"
		source += "\tcheck(moved_right, \"horizontal input moves the character\")\n"
		source += "\tpress_action(\"jump\")\n"
		source += "\tvar rose: bool = await wait_until(func() -> bool: return body.velocity.y < -20.0, 4000)\n"
		source += "\trelease_action(\"jump\")\n"
		source += "\tcheck(rose, \"jump input launches the character upward\")\n"
		# 落地稳定后再进入收集阶段：跳跃检查结束时玩家在空中带前向漂移，
		# 会从金币上方飞过并落到其右侧，收集断言就永远等不到。
		source += "\tawait wait_until(func() -> bool: return body.is_on_floor(), 4000)\n"
	elif bool(verbs.get("movement", false)) or bool(verbs.get("shoot", false)):
		source += "\tpress_action(\"move_right\")\n"
		source += "\tvar moved: bool = await wait_until(func() -> bool: return body.global_position.distance_to(start_position) > 8.0, 4000)\n"
		source += "\trelease_action(\"move_right\")\n"
		source += "\tcheck(moved, \"movement input displaces the character\")\n"
	if wants_pickup:
		# 金币挂世界父节点（与玩家同级）：先查兄弟，再回查自身子树。
		source += "\tvar coin: Node = _find_coin(body)\n"
		source += "\tcheck_not_null(coin, \"goal scene contains the collectible\")\n"
		source += "\tvar label: Label = _find_win_label(body)\n"
		source += "\tcheck_not_null(label, \"goal scene contains the win label\")\n"
	if wants_collection:
		source += "\tif coin != null and label != null:\n"
		source += "\t\tpress_action(\"move_right\")\n"
		source += "\t\tpress_action(\"move_down\")\n"
		source += "\t\tvar collected: bool = await wait_until(func() -> bool: return not is_instance_valid(coin), 8000, 10)\n"
		source += "\t\trelease_action(\"move_right\")\n"
		source += "\t\trelease_action(\"move_down\")\n"
		source += "\t\tcheck(collected, \"player reaches and collects the coin\")\n"
		source += "\t\tcheck(label.text != \"\", \"win label appears after collection\")\n"
		if wants_score:
			source += "\t\tvar score_label: Label = _find_score_label(body)\n"
			source += "\t\tcheck_not_null(score_label, \"goal scene contains the score label\")\n"
			source += "\t\tif score_label != null:\n"
			source += "\t\t\tcheck(score_label.text != \"Score: 0\", \"score updates after collection\")\n"
	if wants_enemy:
		source += "\tvar enemy: Node = _find_enemy(body)\n"
		source += "\tcheck_not_null(enemy, \"goal scene contains the enemy\")\n"
		source += "\tif enemy != null:\n"
		source += "\t\tvar enemy_gap: float = (enemy as Node2D).global_position.distance_to(body.global_position)\n"
		source += "\t\tvar closed_in: bool = await wait_until(func() -> bool: return (enemy as Node2D).global_position.distance_to(body.global_position) < enemy_gap - 8.0, 4000)\n"
		source += "\t\tcheck(closed_in, \"the enemy chases the player\")\n"
	if wants_pickup:
		source += "\n\nfunc _find_coin(body: CharacterBody2D) -> Node:\n"
		source += "\tvar parent: Node = body.get_parent()\n"
		source += "\tif parent != null:\n"
		source += "\t\tvar coin: Node = parent.get_node_or_null(\"Coin\")\n"
		source += "\t\tif coin != null:\n"
		source += "\t\t\treturn coin\n"
		source += "\treturn body.get_node_or_null(\"Coin\")\n"
		source += "\n\nfunc _find_win_label(root: Node) -> Label:\n"
		source += "\tfor child in root.get_children():\n"
		source += "\t\tif child is CanvasLayer:\n"
		source += "\t\t\treturn (child as CanvasLayer).get_node_or_null(\"WinLabel\") as Label\n"
		source += "\treturn null\n"
	if wants_score:
		source += "\n\nfunc _find_score_label(root: Node) -> Label:\n"
		source += "\tfor child in root.get_children():\n"
		source += "\t\tif child is CanvasLayer:\n"
		source += "\t\t\treturn (child as CanvasLayer).get_node_or_null(\"ScoreLabel\") as Label\n"
		source += "\treturn null\n"
	if wants_enemy:
		source += "\n\nfunc _find_enemy(body: CharacterBody2D) -> Node:\n"
		source += "\tvar parent: Node = body.get_parent()\n"
		source += "\tif parent != null:\n"
		source += "\t\tvar enemy: Node = parent.get_node_or_null(\"Enemy\")\n"
		source += "\t\tif enemy != null:\n"
		source += "\t\t\treturn enemy\n"
		source += "\treturn body.get_node_or_null(\"Enemy\")\n"
	return source
