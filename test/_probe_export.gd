extends SceneTree

func _initialize() -> void:
	var names: Array = Engine.get_singleton_list()
	var hits: Array[String] = []
	for n in names:
		var s: String = String(n)
		if s.to_lower().contains("export") or s.to_lower().contains("editor"):
			hits.append(s)
	print("editor/export singletons: ", hits)
	print("export_presets.cfg exists: ", FileAccess.file_exists("res://export_presets.cfg"))
	if FileAccess.file_exists("res://export_presets.cfg"):
		var f: FileAccess = FileAccess.open("res://export_presets.cfg", FileAccess.READ)
		print(f.get_as_text().substr(0, 1500))
	var cf: ConfigFile = ConfigFile.new()
	var err: int = cf.load("res://export_presets.cfg")
	print("configfile load err: ", err)
	print("sections: ", cf.get_sections())
	quit(0)
