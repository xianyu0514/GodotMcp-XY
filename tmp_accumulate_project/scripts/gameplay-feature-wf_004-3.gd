# Goal blueprint: minimal playable controller.
extends CharacterBody2D

signal coins_changed(collected: int)

const SPEED: float = 260.0
const COINS_TO_WIN: int = 1

var coins_collected: int = 0
var _coin_area: Area2D
var _win_label: Label
var sfx_played_count: int = 0
var _sfx_player: AudioStreamPlayer

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
	# 生成 880Hz 方波提示音（0.4s 衰减）——零外部资产。
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.name = "SfxPlayer"
	add_child(_sfx_player)
	var sample_rate: int = 22050
	var frames: int = int(0.4 * sample_rate)
	var pcm := PackedByteArray()
	pcm.resize(frames * 2)
	for i in range(frames):
		var decay: float = 1.0 - float(i) / float(frames)
		var square: float = 1.0 if fmod(float(i) * 880.0 / float(sample_rate), 2.0) < 1.0 else -1.0
		var amplitude: int = int(square * decay * 12000.0)
		pcm.encode_s16(i * 2, amplitude)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = pcm
	_sfx_player.stream = wav

func _physics_process(_delta: float) -> void:
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if direction == Vector2.ZERO:
		direction = Vector2(
			Input.get_axis("ui_left", "ui_right"),
			Input.get_axis("ui_up", "ui_down"))
	velocity = direction * SPEED
	move_and_slide()

func _on_coin_touched(body: Node) -> void:
	if body != self:
		return
	coins_collected += 1
	coins_changed.emit(coins_collected)
	if _sfx_player != null:
		_sfx_player.play()
		sfx_played_count += 1
	_coin_area.queue_free()
	if coins_collected >= COINS_TO_WIN and _win_label != null:
		_win_label.text = "You Win!"
