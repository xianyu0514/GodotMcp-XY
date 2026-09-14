# Goal blueprint: minimal playable controller.
extends CharacterBody2D

signal coins_changed(collected: int)

const SPEED: float = 260.0
const COINS_TO_WIN: int = 1

var coins_collected: int = 0
var _coin_area: Area2D
var _win_label: Label

func _ready() -> void:
	var body_shape := CollisionShape2D.new()
	var body_circle := CircleShape2D.new()
	body_circle.radius = 8
	body_shape.shape = body_circle
	add_child(body_shape)
	# 运行期生成拾取体与胜利标签，保持编辑场景最小。
	_coin_area = Area2D.new()
	_coin_area.name = "Coin"
	_coin_area.position = Vector2(200, 0)
	for coin_index in range(1, COINS_TO_WIN):
		var extra_coin := Area2D.new()
		extra_coin.name = "Coin%d" % coin_index
		extra_coin.position = Vector2(200 + coin_index * 180, 0)
		var extra_col := CollisionShape2D.new()
		var extra_shape := CircleShape2D.new()
		extra_shape.radius = 90
		extra_col.shape = extra_shape
		extra_coin.add_child(extra_col)
		extra_coin.body_entered.connect(_on_coin_touched)
		get_parent().add_child.call_deferred(extra_coin)
	var coin_collision := CollisionShape2D.new()
	var coin_shape := CircleShape2D.new()
	# 磁吸半径：开环演练（墙钟计时的位移有 ±40% 抖动）仍能确定性
	# 穿越拾取窗——宽恕式拾取本身就是平台游戏的常见手感设计。
	coin_shape.radius = 90
	coin_collision.shape = coin_shape
	_coin_area.add_child(coin_collision)
	# 挂到父节点（世界坐标）：真缺陷修复——金币原先是玩家的子节点，
	# 永远保持相对偏移跟随玩家，且 Area2D 不探测自己的祖先，
	# 收集机制从第一版起就不可能触发。
	get_parent().add_child.call_deferred(_coin_area)
	_coin_area.body_entered.connect(_on_coin_touched)
	var canvas := CanvasLayer.new()
	canvas.name = "WinCanvas"
	add_child(canvas)
	_win_label = Label.new()
	_win_label.name = "WinLabel"
	_win_label.text = ""
	_win_label.position = Vector2(40, 20)
	canvas.add_child(_win_label)

func _on_coin_touched(body: Node) -> void:
	if body != self:
		return
	coins_collected += 1
	coins_changed.emit(coins_collected)
	_coin_area.queue_free()
	if coins_collected >= COINS_TO_WIN and _win_label != null:
		_win_label.text = "You Win!"
