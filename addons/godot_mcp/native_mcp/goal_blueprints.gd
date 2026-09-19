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
# 3D 动词：CharacterBody3D + 地面 + Area3D 金币（N4 最小支持）。
const THREE_D_KEYWORDS: Array[String] = [
	"3d", "3D", "three dimensional", "first person", "third person",
	"三维", "3 维",
]

# 墙动词：StaticBody2D 边界墙（N1 的"撞墙停止"、Q2 内容深度起点）。
const WALL_KEYWORDS: Array[String] = [
	"wall", "walls", "blocked by", "stops when hitting",
	"墙", "墙壁", "撞墙",
]

# 迭代/调参动词：闭环的"玩→调→再玩"——基线→调 SPEED→对比位移。
const TUNING_KEYWORDS: Array[String] = [
	"tune", "tuning", "faster", "slower", "snappier", "more responsive", "too fast", "too slow",
	"更跟手", "手感", "调快", "调慢", "太快", "太慢", "更灵敏", "调参", "迭代",
]

# 音效动词：事件（收集）触发生成的提示音——juice 维度，行为可断言。
const AUDIO_KEYWORDS: Array[String] = [
	"sound", "sfx", "sound effect", "audio", "beep", "juice",
	"音效", "声音", "提示音",
]

# 打磨动词（juice）：拾取粒子爆闪——视觉反馈的质量维度。
const JUICE_KEYWORDS: Array[String] = [
	"particle", "sparkle", "confetti", "burst effect", "visual effect",
	"粒子", "特效", "爆闪",
]

# 游戏流状态机动词：标题→玩法→胜利→重开，状态转移可断言（P4）。
const STATE_MACHINE_KEYWORDS: Array[String] = [
	"title screen", "start menu", "game state", "game flow", "restart", "state machine",
	"标题", "开始菜单", "游戏状态", "重新开始", "状态机",
]

# 敌人动词：巡逻敌人（触碰重置玩家 + 计数），行为可断言。
const ENEMY_KEYWORDS: Array[String] = [
	"enemy", "enemies", "hazard", "patrol", "death", "respawn",
	"敌人", "巡逻", "危险", "死亡", "重生",
]

# 游戏结束动词：死亡有意义——生命数、失败画面、Enter 重开（全重置）。
# 蕴含状态机（游戏结束是一个状态）与敌人（要有东西能杀）。
const GAME_OVER_KEYWORDS: Array[String] = [
	"game over", "gameover", "game-over", "death screen", "lose condition", "lives",
	"游戏结束", "失败画面", "生命数",
]

# 多关卡动词：通关第一关后进入下一关（不同金币布局），最终关胜利才是
# 完整通关。蕴含状态机（关卡切换走 win 态的 Enter 转移）。
const LEVEL_KEYWORDS: Array[String] = [
	"level", "levels", "stage", "second level", "next level",
	"关卡", "第二关", "下一关", "多关卡",
]

# 背景音乐动词：程序生成 chiptune 循环（零外部资产），_ready 自动播放。
# 纯叠加层——不与任何计数器/状态语义交互（关卡/存档/反馈等值不受影响）。
const BGM_KEYWORDS: Array[String] = [
	"background music", "bgm", "soundtrack", "music",
	"背景音乐", "配乐", "音乐",
]

## 解析目标中的金币数量："3 coins" / "3 collectible coins" / "three coins" /
## "3 金币" / "再加 3 个金币"。数字与名词之间允许一个常见修饰词
## （collectible/golden/gold/more）——差距分析：旧正则要求数字紧贴
## "coin"，"Add 3 collectible coins." 的 3 会被吞掉退化为 1。
## 无数字默认 1（单金币最小可玩）。
static func _coin_count(objective: String) -> int:
	var text: String = objective.to_lower()
	var number_regex: RegEx = RegEx.new()
	if number_regex.compile("(\\d+)\\s*个?\\s*(?:(?:collectible|golden|gold|more)\\s+)?coins?\\b|(\\d+)\\s*个?\\s*金币") != OK:
		return 1
	var match_result: RegExMatch = number_regex.search(text)
	if match_result:
		var captured: String = match_result.get_string(1) if match_result.get_string(1) != "" else match_result.get_string(2)
		if captured != "":
			return clampi(int(captured), 1, 10)
	if text.contains("three coins") or text.contains("三个金币"):
		return 3
	if text.contains("five coins") or text.contains("五个金币"):
		return 5
	return 1

## 解析目标中的关卡数："a second level" / "2 levels" / "three levels" /
## "第二关"。无数字默认 2（最小可验证的关卡递进）。
static func _level_count(objective: String) -> int:
	var text: String = objective.to_lower()
	if text.contains("third") or text.contains("3 levels") or text.contains("第三关"):
		return 3
	var number_regex: RegEx = RegEx.new()
	if number_regex.compile("(\\d+)\\s*levels?") != OK:
		return 2
	var match_result: RegExMatch = number_regex.search(text)
	if match_result:
		return clampi(int(match_result.get_string(1)), 2, 5)
	return 2

## 解析目标中的敌人数量："2 enemies" / "2 patrolling enemies" / "两个敌人"。
## 无数字默认 1；"再加一个敌人"这类增量语义由 is_additive_request() 表达，
## 合并层（游戏模型）负责 existing + requested。
static func _enemy_count(objective: String) -> int:
	var text: String = objective.to_lower()
	var number_regex: RegEx = RegEx.new()
	if number_regex.compile("(\\d+)\\s*个?\\s*(?:(?:patrolling|more|extra)\\s+)?enem(?:y|ies)\\b|(\\d+)\\s*个?\\s*敌人") != OK:
		return 1
	var match_result: RegExMatch = number_regex.search(text)
	if match_result:
		var captured: String = match_result.get_string(1) if match_result.get_string(1) != "" else match_result.get_string(2)
		if captured != "":
			return clampi(int(captured), 1, 6)
	# 中文数字词（与金币解析口径一致）
	if text.contains("两个敌人") or text.contains("二个敌人"):
		return 2
	if text.contains("三个敌人"):
		return 3
	return 1

## 增量请求检测："再加 3 个金币" / "add 3 more coins" / "another enemy"
## ——数量语义是 existing + requested，而非 max(existing, requested)。
static func is_additive_request(objective: String) -> bool:
	var text: String = " " + objective.to_lower() + " "
	return text.contains(" 再加") or text.contains(" 多加") or text.contains("再加 ") \
		or text.contains("更多") or text.contains(" more ") or text.contains("another ") \
		or text.contains("extra ") or text.contains("additional ")

## 减量请求："把敌人减少到一个"/"reduce to one enemy"——数量语义是
## **集合**（设为请求数）而非相加/取最大。合并层据此走 merged_count
## 的 reduce 模式（差距：合并只有相加/取最大，"减少"无法表达）。
static func is_reduce_request(objective: String) -> bool:
	var text: String = " " + objective.to_lower() + " "
	# 中文词不加空格前缀（"敌人减少到"中间无空格——首版 " 减少" 匹配不到）
	return text.contains("减少") or text.contains("减到") \
		or text.contains(" fewer ") or text.contains(" less ") \
		or text.contains("reduce ") or text.contains("down to ") or text.contains("only ")

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
		"state_machine": _mentions(objective, STATE_MACHINE_KEYWORDS),
		"audio": _mentions(objective, AUDIO_KEYWORDS),
		"juice": _mentions(objective, JUICE_KEYWORDS),
		"game_over": _mentions(objective, GAME_OVER_KEYWORDS),
		"level": _mentions(objective, LEVEL_KEYWORDS),
		"bgm": _mentions(objective, BGM_KEYWORDS),
		"wall": _mentions(objective, WALL_KEYWORDS),
		"three_d": _mentions(objective, THREE_D_KEYWORDS),
	}

static func has_any_verb(verbs: Dictionary) -> bool:
	return bool(verbs.get("movement", false)) \
		or bool(verbs.get("collectible", false)) \
		or bool(verbs.get("win", false)) \
		or bool(verbs.get("pause", false)) \
		or bool(verbs.get("save", false)) \
		or bool(verbs.get("enemy", false)) \
		or bool(verbs.get("state_machine", false)) \
		or bool(verbs.get("audio", false)) \
		or bool(verbs.get("juice", false)) \
		or bool(verbs.get("game_over", false)) \
		or bool(verbs.get("level", false)) \
		or bool(verbs.get("bgm", false)) \
		or bool(verbs.get("wall", false)) \
		or bool(verbs.get("three_d", false))

## 3D 控制器蓝图（N4 最小）：CharacterBody3D + WASD 移动 + Area3D 金币。
## 位移/拾取断言复用 2D 的表达式机制（position.x 对 3D 节点同样有效）。
static func controller_script_3d(objective: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not bool(verbs.get("three_d", false)):
		return ""
	var needs_pickup: bool = bool(verbs.get("collectible", false)) or bool(verbs.get("win", false))

	var source: String = "# Goal blueprint: minimal 3D controller.\n"
	source += "extends CharacterBody3D\n\n"
	source += "const SPEED: float = 5.0\n"
	if needs_pickup:
		source += "const COINS_TO_WIN: int = 1\n"
	source += "\nvar coins_collected: int = 0\n"
	source += "var _coin_area: Area3D\n"
	source += "\nfunc _ready() -> void:\n"
	source += "\tvar body_shape := CollisionShape3D.new()\n"
	source += "\tvar body_col := CapsuleShape3D.new()\n"
	source += "\tbody_col.radius = 0.4\n"
	source += "\tbody_col.height = 1.0\n"
	source += "\tbody_shape.shape = body_col\n"
	source += "\tadd_child(body_shape)\n"
	source += "\t# 可见玩家网格（真实审计：无 MeshInstance 则画面全黑）\n"
	source += "\tvar body_mesh := MeshInstance3D.new()\n"
	source += "\tvar body_box := BoxMesh.new()\n"
	source += "\tbody_box.size = Vector3(0.8, 1.0, 0.8)\n"
	source += "\tbody_mesh.mesh = body_box\n"
	source += "\tadd_child(body_mesh)\n"
	source += "\t# 地面：StaticBody3D 大平面\n"
	source += "\tvar ground := StaticBody3D.new()\n"
	source += "\tground.name = \"Ground\"\n"
	source += "\tvar ground_col := CollisionShape3D.new()\n"
	source += "\tvar ground_shape := WorldBoundaryShape3D.new()\n"
	source += "\tground_col.shape = ground_shape\n"
	source += "\tground.add_child(ground_col)\n"
	source += "\tvar ground_mesh := MeshInstance3D.new()\n"
	source += "\tvar ground_plane := PlaneMesh.new()\n"
	source += "\tground_plane.size = Vector2(20, 20)\n"
	source += "\tground_mesh.mesh = ground_plane\n"
	source += "\tground.add_child(ground_mesh)\n"
	source += "\tget_parent().add_child.call_deferred(ground)\n"
	source += "\t# 灯光：DirectionalLight3D（无灯光 3D 全黑）\n"
	source += "\tvar light := DirectionalLight3D.new()\n"
	source += "\tlight.rotation_degrees = Vector3(-45, 30, 0)\n"
	source += "\tget_parent().add_child.call_deferred(light)\n"
	source += "\t# 相机：第三人称跟随\n"
	source += "\tvar camera := Camera3D.new()\n"
	source += "\tcamera.position = Vector3(0, 3, 5)\n"
	source += "\tadd_child(camera)\n"
	if needs_pickup:
		source += "\t_coin_area = Area3D.new()\n"
		source += "\t_coin_area.name = \"Coin\"\n"
		source += "\t_coin_area.position = Vector3(3, 1, 0)\n"
		source += "\tvar coin_col := CollisionShape3D.new()\n"
		source += "\tvar coin_shape := SphereShape3D.new()\n"
		source += "\tcoin_shape.radius = 1.5\n"
		source += "\tcoin_col.shape = coin_shape\n"
		source += "\t_coin_area.add_child(coin_col)\n"
		source += "\tvar coin_mesh := MeshInstance3D.new()\n"
		source += "\tvar coin_sphere := SphereMesh.new()\n"
		source += "\tcoin_sphere.radius = 0.5\n"
		source += "\tcoin_sphere.height = 1.0\n"
		source += "\tcoin_mesh.mesh = coin_sphere\n"
		source += "\t_coin_area.add_child(coin_mesh)\n"
		source += "\t_coin_area.body_entered.connect(_on_coin_touched.bind(_coin_area))\n"
		source += "\tget_parent().add_child.call_deferred(_coin_area)\n"
	source += "\nfunc _physics_process(_delta: float) -> void:\n"
	source += "\tvar direction := Input.get_vector(\"move_left\", \"move_right\", \"move_forward\", \"move_back\")\n"
	source += "\tvar input_dir := Vector3(direction.x, 0, direction.y)\n"
	source += "\tif input_dir == Vector3.ZERO:\n"
	source += "\t\tinput_dir = Vector3(\n"
	source += "\t\t\tInput.get_axis(\"ui_left\", \"ui_right\"),\n"
	source += "\t\t\t0,\n"
	source += "\t\t\tInput.get_axis(\"ui_up\", \"ui_down\"))\n"
	source += "\tvelocity = input_dir * SPEED\n"
	source += "\tmove_and_slide()\n"
	if needs_pickup:
		source += "\nfunc _on_coin_touched(body: Node, coin: Node) -> void:\n"
		source += "\tif body != self:\n"
		source += "\t\treturn\n"
		source += "\t# 一次性守卫：已释放/待释放的道具不再计数（真实审计：多金币时\n"
		source += "\t# 第二、三枚会对已释放的第一枚重复 queue_free 并虚增计数）。\n"
		source += "\tif coin == null or not is_instance_valid(coin) or coin.is_queued_for_deletion():\n"
		source += "\t\treturn\n"
		source += "\tcoins_collected += 1\n"
		source += "\tcoin.queue_free()\n"
	return source

## 组合出挂在场景根上的完整控制器脚本；目标未命中任何动词时返回空串。
static func controller_script(objective: String) -> String:
	var verbs: Dictionary = match_verbs(objective)
	if not has_any_verb(verbs):
		return ""
	# 3D 目标走独立蓝图（引擎/坐标/输入轴都不同）
	if bool(verbs.get("three_d", false)):
		return controller_script_3d(objective)
	# 游戏结束是一个状态（失败画面+Enter 重开），且要有东西能杀玩家：
	# game_over 蕴含 enemy + state_machine（后者再蕴含收集/移动）。
	if bool(verbs.get("game_over", false)):
		verbs["enemy"] = true
		verbs["state_machine"] = true
	# 多关卡：通关切换走 win 态的 Enter 转移——level 蕴含状态机。
	if bool(verbs.get("level", false)):
		verbs["state_machine"] = true
	# 状态机/音效/粒子暗含收集（胜利条件）与移动（玩法本体）——在 needs_*
	# 计算前改写动词，保证 _ready 的金币/胜利结构与移动块同步生成。
	if bool(verbs.get("state_machine", false)) or bool(verbs.get("audio", false)) \
			or bool(verbs.get("juice", false)):
		verbs["collectible"] = true
		verbs["movement"] = true
	var needs_pickup: bool = bool(verbs.get("collectible", false)) or bool(verbs.get("win", false))
	var needs_pause: bool = bool(verbs.get("pause", false))
	var needs_save: bool = bool(verbs.get("save", false))
	var needs_enemy: bool = bool(verbs.get("enemy", false))
	var needs_state: bool = bool(verbs.get("state_machine", false))
	# 存档暗含移动：没有会变化的状态就没有可持久化的东西。
	var needs_movement: bool = bool(verbs.get("movement", false)) or needs_save

	var source: String = "# Goal blueprint: minimal playable controller.\n"
	source += "extends CharacterBody2D\n\n"
	source += "signal coins_changed(collected: int)\n\n"
	source += "const SPEED: float = 260.0\n"
	if needs_pickup:
		source += "const COINS_TO_WIN: int = %d\n" % _coin_count(objective)
		# 拾取半径参数化（磁吸调参目标）：生成器三处创建点共用一个常量，
		# 调参链 modify_script 改这一行即可全量生效。
		source += "const COIN_RADIUS: float = 90.0\n"
	if needs_save:
		source += "const SAVE_PATH := \"user://save_game.json\"\n"
	source += "\nvar coins_collected: int = 0\n"
	if needs_pickup:
		source += "var _coin_area: Area2D\nvar _win_label: Label\n"
		source += "var _hud_label: Label\n"
	if needs_pause:
		source += "var _pause_label: Label\n"
	if needs_save:
		source += "var last_save_ok: bool = false\n"
		source += "var _save_log: String = \"\"\n"
		source += "var _save_was_down: bool = false\n"
		source += "var _last_restored: Dictionary = {}\n"
	if bool(verbs.get("audio", false)):
		source += "var sfx_played_count: int = 0\n"
		source += "var _sfx_player: AudioStreamPlayer\n"
	if bool(verbs.get("juice", false)):
		source += "var burst_count: int = 0\n"
		source += "var _burst_player: CPUParticles2D\n"
	if needs_state:
		source += "var game_state: String = \"title\"\n"
		source += "var _title_label: Label\n"
		source += "var _enter_was_down: bool = false\n"
	if bool(verbs.get("game_over", false)):
		source += "const STARTING_LIVES: int = 3\n"
		source += "var lives: int = STARTING_LIVES\n"
		source += "var _gameover_label: Label\n"
	if bool(verbs.get("level", false)):
		source += "const LEVEL_COUNT: int = %d\n" % _level_count(objective)
		source += "var current_level: int = 1\n"
		source += "var _pickup_log: String = \"\"\n"
	if bool(verbs.get("bgm", false)):
		source += "var _bgm_player: AudioStreamPlayer\n"
	if needs_enemy:
		source += "var deaths_count: int = 0\n"
		source += "var _enemy: Area2D\n"
		source += "var _enemies: Array[Area2D] = []\n"
		source += "var _enemy_time: float = 0.0\n"
		source += "const ENEMY_COUNT: int = %d\n" % _enemy_count(objective)
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
	if needs_save:
		# **读档先行**：恢复 current_level/lives 必须发生在任何生成之前
		# （初始金币按恢复后的关卡布局摆位——差距分析：蓝图存档曾只存
		# 金币数与位置，退出后无法准确继续关卡/生命状态）。
		source += "\t# 自动读档：完全重启进程后状态从磁盘恢复（N3 语义）。\n"
		source += "\tload_game()\n"
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
		source += "\t# 金币聚簇在敌人巡逻带之前（80 + i*60，全部落在 x<210 走廊）：\n"
		source += "\t# 敌人带 [220,380] 会让任何穿越死亡——旧布局 200/380/560 的\n"
		source += "\t# 第二、三枚永远不可达，带敌人的完整通关从几何上不可能。\n"
		if bool(verbs.get("level", false)):
			# 初始布局随恢复后的关卡走（读档已先行）——与 _respawn_coins
			# 的 base_x 公式一致。
			source += "\tvar base_x: float = 110.0 + (current_level - 1) * 40.0\n"
		source += "\t_coin_area = Area2D.new()\n"
		source += "\t_coin_area.name = \"Coin\"\n"
		if bool(verbs.get("level", false)):
			source += "\t_coin_area.position = Vector2(base_x, 0)\n"
		else:
			source += "\t_coin_area.position = Vector2(110.0, 0)\n"
		# 多金币：运行时循环生成（避免生成器侧变量泄漏到产物——
		# 真实审计发现生成代码含非法缩进和 _extra_coin 残留）。
		source += "\tfor coin_index in range(1, COINS_TO_WIN):\n"
		source += "\t\tvar extra_coin := Area2D.new()\n"
		source += "\t\textra_coin.name = \"Coin%d\" % coin_index\n"
		if bool(verbs.get("level", false)):
			source += "\t\textra_coin.position = Vector2(base_x + coin_index * 40.0, 0)\n"
		else:
			source += "\t\textra_coin.position = Vector2(110.0 + coin_index * 40.0, 0)\n"
		source += "\t\tvar extra_col := CollisionShape2D.new()\n"
		source += "\t\tvar extra_shape := CircleShape2D.new()\n"
		source += "\t\textra_shape.radius = COIN_RADIUS\n"
		source += "\t\textra_col.shape = extra_shape\n"
		source += "\t\textra_coin.add_child(extra_col)\n"
		source += "\t\textra_coin.body_entered.connect(_on_coin_touched.bind(extra_coin))\n"
		source += "\t\tget_parent().add_child.call_deferred(extra_coin)\n"
		source += "\tvar coin_collision := CollisionShape2D.new()\n"
		source += "\tvar coin_shape := CircleShape2D.new()\n"
		source += "\t# 磁吸半径：开环演练（墙钟计时的位移有 ±40% 抖动）仍能确定性\n"
		source += "\t# 穿越拾取窗——宽恕式拾取本身就是平台游戏的常见手感设计。\n"
		source += "\tcoin_shape.radius = COIN_RADIUS\n"
		source += "\tcoin_collision.shape = coin_shape\n"
		source += "\t_coin_area.add_child(coin_collision)\n"
		# 挂到父节点（世界坐标）：真缺陷修复——金币原先是玩家的子节点，
		# 永远保持相对偏移跟随玩家，且 Area2D 不探测自己的祖先，
		# 收集机制从第一版起就不可能触发。
		source += "\tget_parent().add_child.call_deferred(_coin_area)\n"
		source += "\t_coin_area.body_entered.connect(_on_coin_touched.bind(_coin_area))\n"
		source += "\tvar canvas := CanvasLayer.new()\n"
		source += "\tcanvas.name = \"WinCanvas\"\n"
		source += "\tadd_child(canvas)\n"
		source += "\t_win_label = Label.new()\n"
		source += "\t_win_label.name = \"WinLabel\"\n"
		source += "\t_win_label.text = \"\"\n"
		source += "\t_win_label.position = Vector2(40, 60)\n"
		source += "\t_win_label.add_theme_font_size_override(\"font_size\", 32)\n"
		source += "\tcanvas.add_child(_win_label)\n"
		source += "\t_hud_label = Label.new()\n"
		source += "\t_hud_label.name = \"HudLabel\"\n"
		source += "\t_hud_label.position = Vector2(10, 10)\n"
		source += "\t_hud_label.text = \"Coins: 0/%d\" % COINS_TO_WIN\n"
		source += "\tcanvas.add_child(_hud_label)\n"
		ready_body_emitted = true
	if bool(verbs.get("audio", false)):
		source += "\t# 生成 880Hz 方波提示音（0.4s 衰减）——零外部资产。\n"
		source += "\t_sfx_player = AudioStreamPlayer.new()\n"
		source += "\t_sfx_player.name = \"SfxPlayer\"\n"
		source += "\tadd_child(_sfx_player)\n"
		source += "\tvar sample_rate: int = 22050\n"
		source += "\tvar frames: int = int(0.4 * sample_rate)\n"
		source += "\tvar pcm := PackedByteArray()\n"
		source += "\tpcm.resize(frames * 2)\n"
		source += "\tfor i in range(frames):\n"
		source += "\t\tvar decay: float = 1.0 - float(i) / float(frames)\n"
		source += "\t\tvar square: float = 1.0 if fmod(float(i) * 880.0 / float(sample_rate), 2.0) < 1.0 else -1.0\n"
		source += "\t\tvar amplitude: int = int(square * decay * 12000.0)\n"
		source += "\t\tpcm.encode_s16(i * 2, amplitude)\n"
		source += "\tvar wav := AudioStreamWAV.new()\n"
		source += "\twav.format = AudioStreamWAV.FORMAT_16_BITS\n"
		source += "\twav.mix_rate = sample_rate\n"
		source += "\twav.stereo = false\n"
		source += "\twav.data = pcm\n"
		source += "\t_sfx_player.stream = wav\n"
	if bool(verbs.get("juice", false)):
		# 拾取粒子爆闪（一次性）：世界坐标挂载——爆闪留在拾取点，不跟
		# 随玩家移动。触发时 restart() 重发（one_shot 粒子完成后
		# emitting=true 不会重发）。
		source += "\t_burst_player = CPUParticles2D.new()\n"
		source += "\t_burst_player.name = \"PickupBurst\"\n"
		source += "\t_burst_player.emitting = false\n"
		source += "\t_burst_player.one_shot = true\n"
		source += "\t_burst_player.amount = 24\n"
		source += "\t_burst_player.lifetime = 0.45\n"
		source += "\t_burst_player.explosiveness = 1.0\n"
		source += "\t_burst_player.direction = Vector2(0, -1)\n"
		source += "\t_burst_player.spread = 180.0\n"
		source += "\t_burst_player.gravity = Vector2(0, 420)\n"
		source += "\t_burst_player.initial_velocity_min = 120.0\n"
		source += "\t_burst_player.initial_velocity_max = 260.0\n"
		source += "\t_burst_player.scale_amount_min = 3.0\n"
		source += "\t_burst_player.scale_amount_max = 6.0\n"
		source += "\t_burst_player.color = Color(1.0, 0.85, 0.2)\n"
		source += "\tget_parent().add_child.call_deferred(_burst_player)\n"
	if bool(verbs.get("bgm", false)):
		# 程序生成 chiptune 循环（C 大调琶音 + 包络方波，2 秒无缝循环）
		# ——零外部资产；_ready 自动播放（常开：不随游戏状态门控）。
		source += "\t_bgm_player = AudioStreamPlayer.new()\n"
		source += "\t_bgm_player.name = \"BgmPlayer\"\n"
		source += "\tadd_child(_bgm_player)\n"
		source += "\tvar bgm_rate: int = 22050\n"
		source += "\tvar bgm_notes: Array = [261.63, 329.63, 392.0, 523.25, 392.0, 329.63, 261.63, 196.0]\n"
		source += "\tvar bgm_frames: int = int(2.0 * bgm_rate)\n"
		source += "\tvar bgm_pcm := PackedByteArray()\n"
		source += "\tbgm_pcm.resize(bgm_frames * 2)\n"
		source += "\tfor i in range(bgm_frames):\n"
		source += "\t\tvar note: float = bgm_notes[int(float(i) / float(bgm_frames) * float(bgm_notes.size()))]\n"
		source += "\t\tvar phase: float = fmod(float(i) * note / float(bgm_rate), 1.0)\n"
		source += "\t\tvar square: float = 1.0 if phase < 0.5 else -1.0\n"
		source += "\t\tvar note_pos: float = fmod(float(i), float(bgm_frames) / float(bgm_notes.size())) / (float(bgm_frames) / float(bgm_notes.size()))\n"
		source += "\t\tvar envelope: float = 0.55 + 0.45 * (1.0 - note_pos)\n"
		source += "\t\tbgm_pcm.encode_s16(i * 2, int(square * envelope * 7000.0))\n"
		source += "\tvar bgm_wav := AudioStreamWAV.new()\n"
		source += "\tbgm_wav.format = AudioStreamWAV.FORMAT_16_BITS\n"
		source += "\tbgm_wav.mix_rate = bgm_rate\n"
		source += "\tbgm_wav.stereo = false\n"
		source += "\tbgm_wav.data = bgm_pcm\n"
		source += "\tbgm_wav.loop_mode = AudioStreamWAV.LOOP_FORWARD\n"
		source += "\tbgm_wav.loop_begin = 0\n"
		source += "\tbgm_wav.loop_end = bgm_frames\n"
		source += "\t_bgm_player.stream = bgm_wav\n"
		source += "\t_bgm_player.volume_db = -6.0\n"
		source += "\t_bgm_player.play()\n"
	if bool(verbs.get("wall", false)):
		source += "\t# 边界墙（世界坐标，延迟挂载）：右墙在 +250，左墙在 -40——\n"
		source += "\t# CharacterBody2D + 碰撞体天然被 StaticBody2D 阻挡。\n"
		source += "\tfor wall_spec in [{\"name\": \"WallRight\", \"x\": 500.0}, {\"name\": \"WallLeft\", \"x\": -40.0}]:\n"
		source += "\t\tvar wall_node := StaticBody2D.new()\n"
		source += "\t\twall_node.name = wall_spec[\"name\"]\n"
		source += "\t\twall_node.position = Vector2(wall_spec[\"x\"], 0.0)\n"
		source += "\t\tvar wall_collision := CollisionShape2D.new()\n"
		source += "\t\tvar wall_shape := RectangleShape2D.new()\n"
		source += "\t\twall_shape.size = Vector2(16.0, 240.0)\n"
		source += "\t\twall_collision.shape = wall_shape\n"
		source += "\t\twall_node.add_child(wall_collision)\n"
		source += "\t\tget_parent().add_child.call_deferred(wall_node)\n"
	if needs_state:
		source += "\tvar title_layer := CanvasLayer.new()\n"
		source += "\ttitle_layer.name = \"TitleLayer\"\n"
		source += "\tadd_child(title_layer)\n"
		source += "\t_title_label = Label.new()\n"
		source += "\t_title_label.name = \"TitleLabel\"\n"
		source += "\t_title_label.text = \"Press Enter to Start\"\n"
		source += "\t_title_label.position = Vector2(40, 100)\n"
		source += "\ttitle_layer.add_child(_title_label)\n"
		if bool(verbs.get("game_over", false)):
			# 失败画面挂在标题层上（同一 UI 层，互不干扰）。
			source += "\t_gameover_label = Label.new()\n"
			source += "\t_gameover_label.name = \"GameOverLabel\"\n"
			source += "\t_gameover_label.text = \"Game Over - press Enter to Restart\"\n"
			source += "\t_gameover_label.position = Vector2(40, 140)\n"
			source += "\t_gameover_label.visible = false\n"
			source += "\ttitle_layer.add_child(_gameover_label)\n"
	if needs_enemy:
		# 敌人数参数化（ENEMY_COUNT）："再加一个敌人"由合并层把数量写进
		# 合成目标，这里循环生成。首敌保持原相位/位置（既有断言校准过）。
		source += "\tfor enemy_index in range(ENEMY_COUNT):\n"
		source += "\t\tvar enemy := Area2D.new()\n"
		source += "\t\tenemy.name = \"Enemy\" if enemy_index == 0 else \"Enemy%d\" % enemy_index\n"
		source += "\t\tenemy.position = Vector2(ENEMY_HOME_X + enemy_index * 160.0, 0.0)\n"
		source += "\t\tvar enemy_collision := CollisionShape2D.new()\n"
		source += "\t\tvar enemy_shape := RectangleShape2D.new()\n"
		source += "\t\t# 纵向高墙：任意纵向偏移的水平穿越都会触发（开环演练确定性）。\n"
		source += "\t\tenemy_shape.size = Vector2(16, 240)\n"
		source += "\t\tenemy_collision.shape = enemy_shape\n"
		source += "\t\tenemy.add_child(enemy_collision)\n"
		source += "\t\t# 同金币：挂到父节点，巡逻才是世界坐标。\n"
		source += "\t\tget_parent().add_child.call_deferred(enemy)\n"
		source += "\t\tenemy.body_entered.connect(_on_enemy_touched)\n"
		source += "\t\t_enemies.append(enemy)\n"
		source += "\t_enemy = _enemies[0]\n"
		ready_body_emitted = true
	if not ready_body_emitted:
		# 纯移动目标没有 _ready 内容：空函数体是非法 GDScript（真机 E2E
		# 抓到——此前所有场景都带收集动词填充了 _ready，从未暴露）。
		source += "\tpass\n"
	if needs_movement or needs_pause:
		# 单一 _physics_process：输入读取一律状态轮询（Input.is_action_*
		# 的 just_pressed 边沿在探针 parse_input_event 模拟下对 ui_accept
		# 不可靠——真机复现：win→title 转移在按住 300ms 内从未触发，
		# 同机制在 title→playing 却工作；状态轮询 + 上一帧锁存把状态转成
		# 可靠边沿。事件派发路径（_unhandled_input）同样不可靠（真机抓到）。
		# 暂停期间提前 return：世界（含本控制器驱动的移动）必须停下。
		source += "\nfunc _physics_process(_delta: float) -> void:\n"
		if needs_state:
			source += "\tif _enter_edge():\n"
			source += "\t\tif game_state == \"title\":\n"
			source += "\t\t\tgame_state = \"playing\"\n"
			source += "\t\t\tif _title_label != null:\n"
			source += "\t\t\t\t_title_label.visible = false\n"
			if bool(verbs.get("game_over", false)):
				# gameover + Enter → title（全重置：位置/金币/生命/画面/金币重生
				# /反馈计数）——再一对 Enter 进 playing（与 win→title 同构）。
				source += "\t\telif game_state == \"gameover\":\n"
				source += "\t\t\tgame_state = \"title\"\n"
				source += "\t\t\tposition = Vector2.ZERO\n"
				source += "\t\t\tcoins_collected = 0\n"
				source += "\t\t\tlives = STARTING_LIVES\n"
				if bool(verbs.get("level", false)):
					source += "\t\t\tcurrent_level = 1\n"
				source += "\t\t\tif _gameover_label != null:\n"
				source += "\t\t\t\t_gameover_label.visible = false\n"
				source += "\t\t\tif _title_label != null:\n"
				source += "\t\t\t\t_title_label.visible = true\n"
				if bool(verbs.get("audio", false)):
					source += "\t\t\tsfx_played_count = 0\n"
				if bool(verbs.get("juice", false)):
					source += "\t\t\tburst_count = 0\n"
				if needs_pickup:
					# 延迟一帧重生：position 传送后 CharacterBody2D 的物理体
					# 下一帧才同步——同帧生成的金币 Area2D 会用**滞后物理体
					# 位置**判定重叠（取证：三笔幽灵拾取全记录在节点位 0，
					# 物理体实际停在 L1 拾取点 ≈92，恰落新币区 [60,240]）。
					source += "\t\t\tcall_deferred(\"_respawn_coins\")\n"
				source += "\t\telif game_state == \"win\":\n"
			else:
				# 无 game_over 也必须发射 elif 行——win 分支体（关卡感知/
				# 朴素）挂在它后面（丢失会让状态机目标的 Enter 换重开整条
				# 转移消失：编译仍过、语义断——单测 contains 断言抓的）。
				source += "\t\telif game_state == \"win\":\n"
			if bool(verbs.get("level", false)):
				# win + Enter：非最终关 → 下一关 playing（换关重置在此发生：
				# 关卡递进/位置/金币/反馈计数/金币按新关布局重生）；最终关 →
				# title（关卡归 1，全重置同既有语义）。elif 行由 game_over
				# 条件块（两个分支）统一发射，这里只发分支体。
				source += "\t\t\tif current_level < LEVEL_COUNT:\n"
				source += "\t\t\t\t_pickup_log = \"\"\n"
				source += "\t\t\t\tcurrent_level += 1\n"
				source += "\t\t\t\tgame_state = \"playing\"\n"
				source += "\t\t\t\tposition = Vector2.ZERO\n"
				source += "\t\t\t\tcoins_collected = 0\n"
				if bool(verbs.get("audio", false)):
					source += "\t\t\t\tsfx_played_count = 0\n"
				if bool(verbs.get("juice", false)):
					source += "\t\t\t\tburst_count = 0\n"
				if needs_pickup:
					source += "\t\t\t\tif _hud_label != null:\n"
					source += "\t\t\t\t\t_hud_label.text = \"Coins: 0/%d\" % COINS_TO_WIN\n"
					source += "\t\t\t\tcall_deferred(\"_respawn_coins\")\n"
				source += "\t\t\telse:\n"
				source += "\t\t\t\t_pickup_log = \"\"\n"
				source += "\t\t\t\tcurrent_level = 1\n"
				source += "\t\t\t\tgame_state = \"title\"\n"
				source += "\t\t\t\tposition = Vector2.ZERO\n"
				source += "\t\t\t\tcoins_collected = 0\n"
				if bool(verbs.get("audio", false)):
					source += "\t\t\t\tsfx_played_count = 0\n"
				if bool(verbs.get("juice", false)):
					source += "\t\t\t\tburst_count = 0\n"
				if bool(verbs.get("game_over", false)):
					source += "\t\t\t\tlives = STARTING_LIVES\n"
					source += "\t\t\t\tif _gameover_label != null:\n"
					source += "\t\t\t\t\t_gameover_label.visible = false\n"
				source += "\t\t\t\tif _title_label != null:\n"
				source += "\t\t\t\t\t_title_label.visible = true\n"
				if needs_pickup:
					source += "\t\t\t\tcall_deferred(\"_respawn_coins\")\n"
			else:
				source += "\t\t\tgame_state = \"title\"\n"
				source += "\t\t\tposition = Vector2.ZERO\n"
				source += "\t\t\tcoins_collected = 0\n"
				# 反馈计数器随回合清零：保持"每拾取一次响一声/爆一次"的
				# 等值证据在重开后的新一轮里依然成立（计数跨回合累积会让
				# sfx_played_count == coins_collected 永假）。
				if bool(verbs.get("audio", false)):
					source += "\t\t\tsfx_played_count = 0\n"
				if bool(verbs.get("juice", false)):
					source += "\t\t\tburst_count = 0\n"
				if bool(verbs.get("game_over", false)):
					# 胜利换轮同样恢复生命并盖掉失败画面（防御性：gameover 期间
					# 不可能胜利，但状态语义保持完备）。
					source += "\t\t\tlives = STARTING_LIVES\n"
					source += "\t\t\tif _gameover_label != null:\n"
					source += "\t\t\t\t_gameover_label.visible = false\n"
				source += "\t\t\tif _title_label != null:\n"
				source += "\t\t\t\t_title_label.visible = true\n"
				# 重开重建金币：收集后的金币被 queue_free，不重建则重开后无物可收
				# （延迟一帧——物理体同步后再生成，防幽灵拾取）
				if needs_pickup:
					source += "\t\t\tcall_deferred(\"_respawn_coins\")\n"
			source += "\tif game_state != \"playing\" and game_state != \"win\":\n"
			source += "\t\treturn\n"
		if needs_save:
			# 状态轮询 + 锁存（与 _enter_edge 同模式）：is_action_just_pressed 的
			# 边沿在探针 action_press 直接状态下会双重触发（写入日志实锤：一次
			# F5 按压 = 2 次落盘）——锁存保证每次按住恰好一次写入。
			source += "\tvar save_down: bool = Input.is_action_pressed(\"save_game\")\n"
			source += "\tif save_down and not _save_was_down:\n"
			source += "\t\tlast_save_ok = save_game()\n"
			source += "\t_save_was_down = save_down\n"
		if needs_enemy:
			source += "\t# 敌人巡逻：相位从生成起累积（墙钟正弦会在整周期处过零，\n"
			source += "\t# 断言窗口踩到过零点会闪断——真机 E2E 抓到）。\n"
			source += "\t_enemy_time += _delta\n"
			source += "\t# ENEMY_SPEED 实际驱动巡逻频率（差距分析：常量存在但不参与\n"
			source += "\t# 公式——调参后行为不变）。速度越快，往返周期越短。\n"
			source += "\t# 首敌相位偏移恒为 0（既有调参断言按此校准）；后续敌人各带\n"
			source += "\t# 独立相位偏移，巡逻互不同步。\n"
			source += "\tfor enemy_index in _enemies.size():\n"
			source += "\t\tvar enemy_home: float = ENEMY_HOME_X + float(enemy_index) * 160.0\n"
			source += "\t\t_enemies[enemy_index].position.x = enemy_home + sin(_enemy_time * (ENEMY_SPEED / 60.0) + float(enemy_index) * 1.7) * ENEMY_RANGE\n"
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
			source += "\nfunc _on_coin_touched(body: Node, coin: Node) -> void:\n"
			source += "\tif body != self:\n"
			source += "\t\treturn\n"
			source += "\t# 道具身份修复（差距分析 P0）：释放实际触发拾取的那一枚，\n"
			source += "\t# 而不是成员 _coin_area（第一枚）——多金币时第二、三枚会对\n"
			source += "\t# 已释放的第一枚重复 queue_free 并虚增计数。一次性守卫\n"
			source += "\t# 保证每枚只计一次。\n"
			source += "\tif coin == null or not is_instance_valid(coin) or coin.is_queued_for_deletion():\n"
			source += "\t\treturn\n"
			if bool(verbs.get("level", false)):
				# 拾取取证（CI 显微镜：L2 进入后 50ms 内 3|win 无输入）——
				# 每笔拾取记录玩家位置，换关清零；失败断言顺带打出。
				source += "\t_pickup_log += str(int(position.x)) + \";\"\n"
			source += "\tcoins_collected += 1\n"
			source += "\tcoins_changed.emit(coins_collected)\n"
			source += "\tif _hud_label != null:\n"
			source += "\t\t_hud_label.text = \"Coins: %d/%d\" % [coins_collected, COINS_TO_WIN]\n"
			if bool(verbs.get("audio", false)):
				source += "\tif _sfx_player != null:\n"
				source += "\t\t_sfx_player.play()\n"
				source += "\t\tsfx_played_count += 1\n"
			if bool(verbs.get("juice", false)):
				source += "\tif _burst_player != null and _burst_player.is_inside_tree():\n"
				source += "\t\t_burst_player.global_position = coin.global_position\n"
				source += "\t\t_burst_player.restart()\n"
				source += "\t\tburst_count += 1\n"
			source += "\tcoin.queue_free()\n"
			source += "\tif coins_collected >= COINS_TO_WIN and _win_label != null:\n"
			if bool(verbs.get("level", false)):
				# 非最终关：显示关卡通关，**不重置任何计数**——收集/反馈
				# 等值断言在关卡合并后的回归语境里必须原样成立（重置会让
				# coins==COINS_TO_WIN 与 sfx==coins 永假）。换关的重置只发
				# 生在 Enter 转移（win→下一关 playing）。
				source += "\t\tif current_level < LEVEL_COUNT:\n"
				source += "\t\t\t_win_label.text = \"Level %d Clear!\" % current_level\n"
				source += "\t\telse:\n"
				source += "\t\t\t_win_label.text = \"You Win!\"\n"
			else:
				source += "\t\t_win_label.text = \"You Win!\"\n"
			if needs_state:
				source += "\t\tgame_state = \"win\"\n"
	if needs_pause:
		source += "\nfunc set_paused(value: bool) -> void:\n"
		source += "\tget_tree().paused = value\n"
		source += "\tif _pause_label != null:\n"
		source += "\t\t_pause_label.visible = value\n"
	if needs_state:
		source += "\nfunc _enter_edge() -> bool:\n"
		source += "\t# 状态轮询转边沿（探针的 parse_input_event 模拟下\n"
		source += "\t# is_action_just_pressed 对 ui_accept 不可靠——真机复现）。\n"
		source += "\tvar down: bool = Input.is_action_pressed(\"ui_accept\")\n"
		source += "\tvar fresh: bool = down and not _enter_was_down\n"
		source += "\t_enter_was_down = down\n"
		source += "\treturn fresh\n"
	if needs_state and needs_pickup:
		source += "\nfunc _respawn_coins() -> void:\n"
		source += "\t# 等一个物理帧：换关/重开转移里 position 传送后，物理体到下一\n"
		source += "\t# 个物理步才同步——不等的话新金币 Area2D 的重叠判定会用滞后\n"
		source += "\t# 物理体位置（CI 取证：三笔拾取记录在节点位 0，物理体实在\n"
		source += "\t# L1 拾取点 ≈92，落在新币窗 [60,240]——幽灵拾取瞬间清空 L2）。\n"
		source += "\t# call_deferred 只隔 idle 帧，不够；必须隔物理帧。\n"
		source += "\tawait get_tree().physics_frame\n"
		source += "\tvar parent := get_parent()\n"
		source += "\tvar dying_index: int = 0\n"
		source += "\tfor child in parent.get_children():\n"
		source += "\t\tif child is Area2D and String(child.name).begins_with(\"Coin\"):\n"
		source += "\t\t\t# 垂死金币先改名再释放：queue_free 到帧尾才生效，同名新金币会撞名拿到自动名（真机复现)。\n"
		source += "\t\t\tchild.name = \"_coin_dying_%d\" % dying_index\n"
		source += "\t\t\tdying_index += 1\n"
		source += "\t\t\tchild.queue_free()\n"
		if bool(verbs.get("level", false)):
			# 关卡布局：每关聚簇基址右移 40px（L1=110 与既有校准一致；
			# L2=150——拾取半径 90 下全簇仍在敌带 [220,380] 前可收）。
			source += "\tvar base_x: float = 110.0 + (current_level - 1) * 40.0\n"
		source += "\tfor coin_index in range(COINS_TO_WIN):\n"
		source += "\t\tvar new_coin := Area2D.new()\n"
		source += "\t\tnew_coin.name = \"Coin\" if coin_index == 0 else \"Coin%d\" % coin_index\n"
		if bool(verbs.get("level", false)):
			source += "\t\tnew_coin.position = Vector2(base_x + coin_index * 40.0, 0)\n"
		else:
			source += "\t\tnew_coin.position = Vector2(110.0 + coin_index * 40.0, 0)\n"
		source += "\t\tvar coin_col := CollisionShape2D.new()\n"
		source += "\t\tvar coin_shape := CircleShape2D.new()\n"
		source += "\t\tcoin_shape.radius = COIN_RADIUS\n"
		source += "\t\tcoin_col.shape = coin_shape\n"
		source += "\t\tnew_coin.add_child(coin_col)\n"
		source += "\t\tnew_coin.body_entered.connect(_on_coin_touched.bind(new_coin))\n"
		source += "\t\tparent.add_child(new_coin)\n"
		source += "\t\tif coin_index == 0:\n"
		source += "\t\t\t_coin_area = new_coin\n"
	if needs_enemy:
		source += "\nfunc _on_enemy_touched(body: Node) -> void:\n"
		source += "\tif body != self:\n"
		source += "\t\treturn\n"
		source += "\tdeaths_count += 1\n"
		if bool(verbs.get("game_over", false)):
			# 死亡有意义：命 -1；命尽 → gameover 态（画面+世界冻结，
			# 移动被状态门挡住）。**gameover 转移只在 playing 态发生**——
			# win 是回合终局，赛后死亡（收集扫收满后继续穿带）计死亡数
			# 但不得用 gameover 覆写刚取得的 win（CI 35416409614）。
			# 反例教训（CI 35417454763）：整块拦掉 win 态死亡会把敌人
			# 演练的证据（扫带致死）一起拦掉——死亡永远计数，只有状态
			# 转移被门控。
			source += "\tlives -= 1\n"
			source += "\tif lives <= 0:\n"
			source += "\t\tgame_state = \"gameover\"\n"
			source += "\t\tif _gameover_label != null:\n"
			source += "\t\t\t_gameover_label.visible = true\n"
			source += "\tposition = Vector2.ZERO\n"
		else:
			source += "\tposition = Vector2.ZERO\n"
	if needs_save:
		source += "\nfunc save_game() -> bool:\n"
		source += "\tvar data := {\"coins\": coins_collected, \"x\": position.x, \"y\": position.y}\n"
		if bool(verbs.get("game_over", false)):
			source += "\tdata[\"lives\"] = lives\n"
		if bool(verbs.get("level", false)):
			source += "\tdata[\"level\"] = current_level\n"
		source += "\tvar file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)\n"
		source += "\tif file == null:\n"
		source += "\t\treturn false\n"
		source += "\tfile.store_string(JSON.stringify(data))\n"
		# 写入取证（毒档猎手）：本会话全部落盘记录（level/coins/lives/x）——
		# 存档演练打印；幽灵写入（重复 F5 边沿等）自报时刻与状态。
		source += "\t_save_log += JSON.stringify(data) + \";\"\n"
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
		source += "\t_last_restored = parsed\n"
		source += "\tcoins_collected = int(parsed.get(\"coins\", 0))\n"
		source += "\tposition = Vector2(float(parsed.get(\"x\", 0.0)), float(parsed.get(\"y\", 0.0)))\n"
		if bool(verbs.get("game_over", false)):
			source += "\tlives = int(parsed.get(\"lives\", STARTING_LIVES))\n"
		if bool(verbs.get("level", false)):
			source += "\tcurrent_level = int(parsed.get(\"level\", 1))\n"
		source += "\treturn true\n"
	return source
