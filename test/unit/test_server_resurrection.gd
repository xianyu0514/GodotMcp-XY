extends "res://addons/gut/test.gd"

## 服务器运行状态持久化：reload/重启后自动复活的标记位读写契约。

const PluginScript = preload("res://addons/godot_mcp/mcp_server_native.gd")

const STATE_FILE: String = "user://mcp_server_running.json"

func test_running_state_round_trip() -> void:
	var had_file: bool = FileAccess.file_exists(STATE_FILE)
	var backup: String = ""
	if had_file:
		backup = FileAccess.get_file_as_string(STATE_FILE)
	PluginScript._write_server_running_state(true)
	assert_true(PluginScript._read_server_running_state(),
		"Start 成功后写入 running=true，重载后据此复活")
	PluginScript._write_server_running_state(false)
	assert_false(PluginScript._read_server_running_state(),
		"显式 Stop 写入 false，保持停止")
	# 还原测试前状态，避免污染真实运行标记
	if had_file:
		var file: FileAccess = FileAccess.open(STATE_FILE, FileAccess.WRITE)
		if file:
			file.store_string(backup)
			file.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE_FILE))
