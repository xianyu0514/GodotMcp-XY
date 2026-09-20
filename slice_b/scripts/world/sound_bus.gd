extends Node
## 音频总线（门槛 B 内容充实）：集中的音效/BGM 播放器，脚本与场景
## 通过具名 API 播放（play_sfx/play_bgm），资源由 MCP 资产管线生成。

const SFX_PICKUP := "pickup"
const SFX_HIT := "hit"
const SFX_DOOR := "door"

var _sfx: Dictionary = {}       # 名字 -> AudioStreamPlayer
var _bgm: AudioStreamPlayer = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for sfx_name in [SFX_PICKUP, SFX_HIT, SFX_DOOR]:
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "Sfx" + sfx_name.capitalize()
		player.stream = load("res://audio/%s.wav" % sfx_name)
		player.volume_db = -6.0
		add_child(player)
		_sfx[sfx_name] = player
	_bgm = AudioStreamPlayer.new()
	_bgm.name = "Bgm"
	_bgm.stream = load("res://audio/bgm.wav")
	_bgm.volume_db = -12.0
	add_child(_bgm)

func play_sfx(sfx_name: String) -> void:
	var player: AudioStreamPlayer = _sfx.get(sfx_name)
	if player != null and player.stream != null:
		player.play()

func play_bgm() -> void:
	if _bgm != null and _bgm.stream != null and not _bgm.playing:
		_bgm.play()
