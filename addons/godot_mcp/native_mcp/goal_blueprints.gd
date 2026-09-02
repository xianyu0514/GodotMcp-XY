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
	}

static func has_any_verb(verbs: Dictionary) -> bool:
	# jump 蕴含 movement：side-scroll/gravity 这类词只在 JUMP 词表里，
	# 不能因此漏掉蓝图与 CharacterBody2D 根派生。
	return bool(verbs.get("movement", false)) \
		or bool(verbs.get("jump", false)) \
		or bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false))

## 组合出挂在场景根上的完整控制器脚本；目标未命中任何动词时返回空串。
static func controller_script(objective: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not has_any_verb(verbs):
		return ""
	var needs_pickup: bool = bool(verbs.get("collectible", false)) or bool(verbs.get("win", false))

	var source: String = "# Goal blueprint: minimal playable controller.\n"
	source += "extends CharacterBody2D\n\n"
	source += "signal coins_changed(collected: int)\n\n"
	source += "const SPEED: float = 260.0\n"
	if needs_pickup:
		source += "const COINS_TO_WIN: int = 1\n"
	source += "\nvar coins_collected: int = 0\n"
	if needs_pickup:
		source += "var _coin_area: Area2D\nvar _win_label: Label\n"
	source += "\nfunc _ready() -> void:\n"
	if needs_pickup:
		source += "\t# 运行期生成拾取体与胜利标签，保持编辑场景最小。\n"
		source += "\t_coin_area = Area2D.new()\n"
		source += "\t_coin_area.name = \"Coin\"\n"
		source += "\t_coin_area.position = Vector2(180, 120)\n"
		source += "\tvar coin_collision := CollisionShape2D.new()\n"
		source += "\tvar coin_shape := CircleShape2D.new()\n"
		source += "\tcoin_shape.radius = 14\n"
		source += "\tcoin_collision.shape = coin_shape\n"
		source += "\t_coin_area.add_child(coin_collision)\n"
		source += "\tadd_child(_coin_area)\n"
		source += "\t_coin_area.body_entered.connect(_on_coin_touched)\n"
		source += "\tvar canvas := CanvasLayer.new()\n"
		source += "\tcanvas.name = \"WinCanvas\"\n"
		source += "\tadd_child(canvas)\n"
		source += "\t_win_label = Label.new()\n"
		source += "\t_win_label.name = \"WinLabel\"\n"
		source += "\t_win_label.text = \"\"\n"
		source += "\t_win_label.position = Vector2(40, 20)\n"
		source += "\tcanvas.add_child(_win_label)\n"
	var wants_movement: bool = bool(verbs.get("movement", false)) or bool(verbs.get("jump", false))
	if wants_movement:
		if bool(verbs.get("jump", false)):
			# 横版跳跃：水平移动 + 重力 + 地面检测 + 跳跃（jump 动作存在则用，
			# 否则回退 ui_accept——Space/Enter 内建可用，未 upsert 也能跳）。
			source += "const JUMP_SPEED: float = 420.0\n"
			source += "var _gravity: float = ProjectSettings.get_setting(\"physics/2d/default_gravity\", 980.0) as float\n"
			source += "\nfunc _physics_process(delta: float) -> void:\n"
			source += "\tvar direction := Input.get_axis(\"move_left\", \"move_right\")\n"
			source += "\tif absf(direction) < 0.1:\n"
			source += "\t\tdirection = Input.get_axis(\"ui_left\", \"ui_right\")\n"
			source += "\tvelocity.x = direction * SPEED\n"
			source += "\tif not is_on_floor():\n"
			source += "\t\tvelocity.y += _gravity * delta\n"
			source += "\tvar jump_requested: bool = InputMap.has_action(\"jump\") and Input.is_action_just_pressed(\"jump\")\n"
			source += "\tif not jump_requested:\n"
			source += "\t\tjump_requested = Input.is_action_just_pressed(\"ui_accept\")\n"
			source += "\tif jump_requested and is_on_floor():\n"
			source += "\t\tvelocity.y = -JUMP_SPEED\n"
			source += "\tmove_and_slide()\n"
		else:
			source += "\nfunc _physics_process(_delta: float) -> void:\n"
			source += "\tvar direction := Input.get_vector(\"move_left\", \"move_right\", \"move_up\", \"move_down\")\n"
			source += "\tif direction == Vector2.ZERO:\n"
			source += "\t\tdirection = Vector2(\n"
			source += "\t\t\tInput.get_axis(\"ui_left\", \"ui_right\"),\n"
			source += "\t\t\tInput.get_axis(\"ui_up\", \"ui_down\"))\n"
			source += "\tvelocity = direction * SPEED\n"
			source += "\tmove_and_slide()\n"
	if needs_pickup:
		source += "\nfunc _on_coin_touched(body: Node) -> void:\n"
		source += "\tif body != self:\n"
		source += "\t\treturn\n"
		source += "\tcoins_collected += 1\n"
		source += "\tcoins_changed.emit(coins_collected)\n"
		source += "\t_coin_area.queue_free()\n"
		source += "\tif coins_collected >= COINS_TO_WIN and _win_label != null:\n"
		source += "\t\t_win_label.text = \"You Win!\"\n"
	return source
