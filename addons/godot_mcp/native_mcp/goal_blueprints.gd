# goal_blueprints.gd
# 目标感知的代码蓝图：当目标语句提到移动/收集/胜利等动词时，为
# create_script 步骤生成真实可运行的 GDScript，而不是占位脚本——
# 闭环的产出因此是"能玩的最小游戏"。调用方显式提供的 content 永远优先。
#
# 有界设计：只覆盖少量高频动词，按块组合；不追求通用代码生成。

class_name GoalBlueprints
extends RefCounted

# 目标动词（双语）→ 蓝图块开关。
const MOVEMENT_KEYWORDS: Array[String] = [
	"movement", "arrow-key", "arrow key", "move", "controller", "wasd",
	"移动", "方向键", "移动控制",
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
		"collectible": _mentions(objective, COLLECTIBLE_KEYWORDS),
		"win": _mentions(objective, WIN_KEYWORDS),
	}

static func has_any_verb(verbs: Dictionary) -> bool:
	return bool(verbs.get("movement", false)) \
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
	if bool(verbs.get("movement", false)):
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
