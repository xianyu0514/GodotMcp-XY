extends CanvasLayer
## HUD（门槛 B M4）：常驻 autoload——hp、金币、当前任务提示。
## 数据源是存档/玩家实况（每帧轮询，切片规模下成本可忽略）。

var _hp_label: Label
var _coins_label: Label
var _quest_label: Label

func _ready() -> void:
	layer = 10
	_hp_label = _make_label(Vector2(16, 8))
	_coins_label = _make_label(Vector2(16, 30))
	_quest_label = _make_label(Vector2(16, 52))
	_quest_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.5))
	add_child(_hp_label)
	add_child(_coins_label)
	add_child(_quest_label)

func _process(_delta: float) -> void:
	var player: Node = _current_player()
	var hp_value: int = int(GameSave.current.get("hp", 100)) if GameSave != null else 100
	if player != null and "hp" in player:
		hp_value = int(player.hp)
	_hp_label.text = "HP %d" % hp_value
	_coins_label.text = "Coins %d" % (int(GameSave.current.get("coins", 0)) if GameSave != null else 0)
	_quest_label.text = _quest_hint()

func _quest_hint() -> String:
	if GameSave == null:
		return ""
	if GameSave.quest_log.is_completed("quest_hearts"):
		return "Quest: Hearts for the Shrine — done"
	if GameSave.quest_log.is_active("quest_hearts"):
		var hearts: int = GameSave.inventory.count("heart")
		return "Quest: bring 2 hearts to the shrine (%d/2)" % hearts
	return "Quest: touch the shrine on L1 to accept"

func _current_player() -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("Player")

func _make_label(position: Vector2) -> Label:
	var label: Label = Label.new()
	label.position = position
	label.add_theme_font_size_override("font_size", 16)
	return label
