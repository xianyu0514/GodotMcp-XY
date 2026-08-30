extends SceneTree

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var module: String = args[0] if args.size() > 0 else ""
	var path: String = "res://addons/godot_mcp/native_mcp/%s.gd" % module
	if module.begins_with("utils/"):
		path = "res://addons/godot_mcp/%s.gd" % module
	elif module.begins_with("tools/"):
		path = "res://addons/godot_mcp/%s.gd" % module
	elif module.begins_with("res://"):
		path = module
	var script: GDScript = load(path)
	if script == null:
		printerr("[FAIL] " + path + " -> load failed")
		quit(1)
		return
	# Node 派生脚本也能实例化，只是不能塞进 RefCounted 变量里。
	var instance: Variant = script.new()
	if instance == null:
		printerr("[FAIL] " + path + " -> instantiate failed")
		quit(1)
		return
	if instance is Node:
		(instance as Node).free()
	print("[OK] " + path)
	quit(0)
