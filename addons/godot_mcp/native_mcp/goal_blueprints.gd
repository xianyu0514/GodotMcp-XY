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
const COLLECTIBLE_KEYWORDS: Array[String] = [
	"collectible", "collect", "coin", "pickup", "pick up", "item",
	"收集", "金币", "拾取", "道具",
]
const WIN_KEYWORDS: Array[String] = [
	"win", "victory", "goal reached", "success screen", "win label", "win text",
	"胜利", "获胜", "通关",
]
# 暂停动词：命中即生成 Esc 暂停/恢复逻辑 + PauseLayer 菜单层。
# 用内置 ui_cancel（默认 Esc）——不需要额外 InputMap 配置。
const PAUSE_KEYWORDS: Array[String] = [
	"pause", "paused", "esc menu", "pause menu",
	"暂停", "暂停菜单",
]
# 存档动词：命中即生成 save/load（user:// JSON）+ 自动读档 + save_game 动作
# 触发（F5，由工作流 upsert）。存档暗含移动：没有会变化的状态就没有可
# 持久化的东西——位置与金币数即被保存的状态。
const SAVE_KEYWORDS: Array[String] = [
	"save/load", "save game", "saving", "存档", "读档", "保存进度", "持久化",
]
# 敌人动词：巡逻敌人（触碰重置玩家 + 计数），行为可断言。
const ENEMY_KEYWORDS: Array[String] = [
	"enemy", "enemies", "hazard", "patrol", "death", "respawn",
	"敌人", "巡逻", "危险", "死亡", "重生",
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
		"pause": _mentions(objective, PAUSE_KEYWORDS),
		"save": _mentions(objective, SAVE_KEYWORDS),
		"enemy": _mentions(objective, ENEMY_KEYWORDS),
	}

static func has_any_verb(verbs: Dictionary) -> bool:
	return bool(verbs.get("movement", false)) \
		or bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false)) \
		or bool(verbs.get("pause", false)) \
		or bool(verbs.get("save", false)) \
		or bool(verbs.get("enemy", false))

## 组合出挂在场景根上的完整控制器脚本；目标未命中任何动词时返回空串。
static func controller_script(objective: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not has_any_verb(verbs):
		return ""
	var needs_pickup: bool = bool(verbs.get("collectible", false)) or bool(verbs.get("win", false))
	var needs_pause: bool = bool(verbs.get("pause", false))
	var needs_save: bool = bool(verbs.get("save", false))
	var needs_enemy: bool = bool(verbs.get("enemy", false))
	# 存档暗含移动：没有会变化的状态就没有可持久化的东西。
	var needs_movement: bool = bool(verbs.get("movement", false)) or needs_save

	var source: String = "# Goal blueprint: minimal playable controller.\n"
	source += "extends CharacterBody2D\n\n"
	source += "signal coins_changed(collected: int)\n\n"
	source += "const SPEED: float = 260.0\n"
	if needs_pickup:
		source += "const COINS_TO_WIN: int = 1\n"
	if needs_save:
		source += "const SAVE_PATH := \"user://save_game.json\"\n"
	source += "\nvar coins_collected: int = 0\n"
	if needs_pickup:
		source += "var _coin_area: Area2D\nvar _win_label: Label\n"
	if needs_pause:
		source += "var _pause_label: Label\n"
	if needs_save:
		source += "var last_save_ok: bool = false\n"
	if needs_enemy:
		source += "var deaths_count: int = 0\n"
		source += "var _enemy: Area2D\n"
		source += "const ENEMY_HOME_X: float = 300.0\n"
		source += "const ENEMY_RANGE: float = 80.0\n"
		source += "const ENEMY_SPEED: float = 120.0\n"
	source += "\nfunc _ready() -> void:\n"
	var ready_body_emitted: bool = false
	# 玩家碰撞体（真缺陷修复：无形状的 CharacterBody2D 不会被任何 Area2D
	# 探测到——金币/敌人的 body_entered 在真机上从未触发过）。
	source += "\tvar body_shape := CollisionShape2D.new()\n"
	source += "\tvar body_circle := CircleShape2D.new()\n"
	source += "\tbody_circle.radius = 8\n"
	source += "\tbody_shape.shape = body_circle\n"
	source += "\tadd_child(body_shape)\n"
	ready_body_emitted = true
	if needs_pause:
		# 控制器必须在暂停期间继续接收输入，否则 Esc 无法恢复游戏。
		source += "\tprocess_mode = Node.PROCESS_MODE_ALWAYS\n"
		source += "\t# 运行期生成暂停菜单层：CanvasLayer + PauseLabel，默认隐藏。\n"
		source += "\tvar pause_layer := CanvasLayer.new()\n"
		source += "\tpause_layer.name = \"PauseLayer\"\n"
		source += "\tpause_layer.process_mode = Node.PROCESS_MODE_ALWAYS\n"
		source += "\tadd_child(pause_layer)\n"
		source += "\t_pause_label = Label.new()\n"
		source += "\t_pause_label.name = \"PauseLabel\"\n"
		source += "\t_pause_label.text = \"Paused - press Esc to resume\"\n"
		source += "\t_pause_label.position = Vector2(40, 60)\n"
		source += "\t_pause_label.visible = false\n"
		source += "\tpause_layer.add_child(_pause_label)\n"
		ready_body_emitted = true
	if needs_pickup:
		source += "\t# 运行期生成拾取体与胜利标签，保持编辑场景最小。\n"
		source += "\t_coin_area = Area2D.new()\n"
		source += "\t_coin_area.name = \"Coin\"\n"
		source += "\t_coin_area.position = Vector2(200, 0)\n"
		source += "\tvar coin_collision := CollisionShape2D.new()\n"
		source += "\tvar coin_shape := CircleShape2D.new()\n"
		source += "\t# 磁吸半径：开环演练（墙钟计时的位移有 ±40% 抖动）仍能确定性\n"
		source += "\t# 穿越拾取窗——宽恕式拾取本身就是平台游戏的常见手感设计。\n"
		source += "\tcoin_shape.radius = 90\n"
		source += "\tcoin_collision.shape = coin_shape\n"
		source += "\t_coin_area.add_child(coin_collision)\n"
		source += "\t# 挂到父节点（世界坐标）：真缺陷修复——金币原先是玩家的子节点，\n"
		source += "\t# 永远保持相对偏移跟随玩家，且 Area2D 不探测自己的祖先，\n"
		source += "\t# 收集机制从第一版起就不可能触发。\n"
		source += "\tget_parent().add_child.call_deferred(_coin_area)\n"
		source += "\t_coin_area.body_entered.connect(_on_coin_touched)\n"
		source += "\tvar canvas := CanvasLayer.new()\n"
		source += "\tcanvas.name = \"WinCanvas\"\n"
		source += "\tadd_child(canvas)\n"
		source += "\t_win_label = Label.new()\n"
		source += "\t_win_label.name = \"WinLabel\"\n"
		source += "\t_win_label.text = \"\"\n"
		source += "\t_win_label.position = Vector2(40, 20)\n"
		source += "\tcanvas.add_child(_win_label)\n"
		ready_body_emitted = true
	if needs_save:
		source += "\t# 自动读档：完全重启进程后状态从磁盘恢复（N3 语义）。\n"
		source += "\tload_game()\n"
		ready_body_emitted = true
	if needs_enemy:
		source += "\tvar enemy := Area2D.new()\n"
		source += "\tenemy.name = \"Enemy\"\n"
		source += "\tenemy.position = Vector2(ENEMY_HOME_X, 0.0)\n"
		source += "\tvar enemy_collision := CollisionShape2D.new()\n"
		source += "\tvar enemy_shape := RectangleShape2D.new()\n"
		source += "\t# 纵向高墙：任意纵向偏移的水平穿越都会触发（开环演练确定性）。\n"
		source += "\tenemy_shape.size = Vector2(16, 240)\n"
		source += "\tenemy_collision.shape = enemy_shape\n"
		source += "\tenemy.add_child(enemy_collision)\n"
		source += "\t# 同金币：挂到父节点，巡逻才是世界坐标。\n"
		source += "\tget_parent().add_child.call_deferred(enemy)\n"
		source += "\tenemy.body_entered.connect(_on_enemy_touched)\n"
		source += "\t_enemy = enemy\n"
		ready_body_emitted = true
	if not ready_body_emitted:
		# 纯移动目标没有 _ready 内容：空函数体是非法 GDScript（真机 E2E
		# 抓到——此前所有场景都带收集动词填充了 _ready，从未暴露）。
		source += "\tpass\n"
	if needs_movement or needs_pause:
		# 单一 _physics_process：暂停开关用状态轮询（Input.is_action_just_pressed
		# 依赖动作状态，运行时探针的动作模拟正是设置状态——事件派发路径
		# （_unhandled_input）对模拟动作不可靠，真实编辑器 E2E 实测抓到）。
		# 暂停期间提前 return：世界（含本控制器驱动的移动）必须停下。
		source += "\nfunc _physics_process(_delta: float) -> void:\n"
		if needs_save:
			source += "\tif Input.is_action_just_pressed(\"save_game\"):\n"
			source += "\t\tlast_save_ok = save_game()\n"
		if needs_enemy:
			source += "\t# 敌人巡逻：正弦往返，位置始终可解算（行为可断言）。\n"
			source += "\t_enemy.position.x = ENEMY_HOME_X + sin(Time.get_ticks_msec() / 1000.0 * (TAU / 4.0)) * ENEMY_RANGE\n"
		if needs_pause:
			source += "\tif Input.is_action_just_pressed(\"ui_cancel\"):\n"
			source += "\t\tset_paused(not get_tree().paused)\n"
			source += "\tif get_tree().paused:\n"
			source += "\t\treturn\n"
		if needs_movement:
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
	if needs_pause:
		source += "\nfunc set_paused(value: bool) -> void:\n"
		source += "\tget_tree().paused = value\n"
		source += "\tif _pause_label != null:\n"
		source += "\t\t_pause_label.visible = value\n"
	if needs_enemy:
		source += "\nfunc _on_enemy_touched(body: Node) -> void:\n"
		source += "\tif body != self:\n"
		source += "\t\treturn\n"
		source += "\tdeaths_count += 1\n"
		source += "\tposition = Vector2.ZERO\n"
	if needs_save:
		source += "\nfunc save_game() -> bool:\n"
		source += "\tvar data := {\"coins\": coins_collected, \"x\": position.x, \"y\": position.y}\n"
		source += "\tvar file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)\n"
		source += "\tif file == null:\n"
		source += "\t\treturn false\n"
		source += "\tfile.store_string(JSON.stringify(data))\n"
		source += "\treturn true\n"
		source += "\nfunc load_game() -> bool:\n"
		source += "\tif not FileAccess.file_exists(SAVE_PATH):\n"
		source += "\t\treturn false\n"
		source += "\tvar file := FileAccess.open(SAVE_PATH, FileAccess.READ)\n"
		source += "\tif file == null:\n"
		source += "\t\treturn false\n"
		source += "\tvar parsed: Variant = JSON.parse_string(file.get_as_text())\n"
		source += "\tif not (parsed is Dictionary):\n"
		source += "\t\treturn false\n"
		source += "\tcoins_collected = int(parsed.get(\"coins\", 0))\n"
		source += "\tposition = Vector2(float(parsed.get(\"x\", 0.0)), float(parsed.get(\"y\", 0.0)))\n"
		source += "\treturn true\n"
	return source
