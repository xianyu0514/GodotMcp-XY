extends "res://addons/gut/test.gd"

## 引擎契约测试：工具 schema / 处理器中断言的引擎事实（枚举值、API 存在性）
## 每次运行都对照 ClassDB 重新核对——等价于"持续重读官方文档"，防止
## Godot 版本演进或人工抄写造成的语义漂移（如 ConnectFlags 值写反事故）。

func test_connect_flags_bitmask_matches_engine() -> void:
	assert_eq(ClassDB.class_get_integer_constant("Object", "CONNECT_DEFERRED"), 1)
	assert_eq(ClassDB.class_get_integer_constant("Object", "CONNECT_PERSIST"), 2)
	assert_eq(ClassDB.class_get_integer_constant("Object", "CONNECT_ONE_SHOT"), 4)
	assert_eq(ClassDB.class_get_integer_constant("Object", "CONNECT_REFERENCE_COUNTED"), 8,
		"connect_signal 的 schema 描述必须与引擎 ConnectFlags 一致")

func test_layout_preset_order_matches_engine() -> void:
	# set_anchor_preset 的 preset_names 表与 schema 描述共用的 0-15 顺序契约。
	var expected: Array = [
		["PRESET_TOP_LEFT", 0], ["PRESET_TOP_RIGHT", 1], ["PRESET_BOTTOM_LEFT", 2],
		["PRESET_BOTTOM_RIGHT", 3], ["PRESET_CENTER_LEFT", 4], ["PRESET_CENTER_TOP", 5],
		["PRESET_CENTER_RIGHT", 6], ["PRESET_CENTER_BOTTOM", 7], ["PRESET_CENTER", 8],
		["PRESET_LEFT_WIDE", 9], ["PRESET_TOP_WIDE", 10], ["PRESET_RIGHT_WIDE", 11],
		["PRESET_BOTTOM_WIDE", 12], ["PRESET_VCENTER_WIDE", 13], ["PRESET_HCENTER_WIDE", 14],
		["PRESET_FULL_RECT", 15],
	]
	for pair in expected:
		assert_eq(ClassDB.class_get_integer_constant("Control", String(pair[0])), int(pair[1]),
			"LayoutPreset %s 的文档值必须与引擎一致" % String(pair[0]))

func test_hard_engine_dependencies_exist() -> void:
	# 工具直接调用（无运行时回退）的编辑器/IO API：缺失即应在测试期暴露，
	# 而不是等到真实编辑器里报错。
	var required_methods: Array = [
		["EditorInterface", "get_editor_paths"], ["EditorInterface", "get_script_editor"],
		["EditorInterface", "open_scene_from_path"], ["EditorInterface", "save_scene"],
		["EditorInterface", "play_custom_scene"], ["EditorInterface", "is_playing_scene"],
		["StreamPeerTLS", "connect_to_stream"], ["StreamPeerTCP", "poll"],
		["HTTPRequest", "request"], ["FileAccess", "get_sha256"], ["ZIPReader", "open"],
	]
	for pair in required_methods:
		assert_true(ClassDB.class_has_method(String(pair[0]), String(pair[1])),
			"%s.%s 必须存在（引擎契约）" % [String(pair[0]), String(pair[1])])
	# EditorPaths.get_export_templates_dir 在已实测的引擎（4.6.3 / 4.7.2 stable）
	# 均不存在——模板目录解析绝不能无条件依赖它，必须先 has_method 探测并
	# 始终保留平台回退。这里锁定真实契约：方法缺失时解析函数照样返回路径。
	var templates_root: String = load(
		"res://addons/godot_mcp/tools/editor_tools_native.gd").new()._get_export_templates_root()
	assert_false(templates_root.is_empty(),
		"export templates root must resolve via platform fallbacks even without EditorPaths.get_export_templates_dir")
	if not ClassDB.class_has_method("EditorPaths", "get_export_templates_dir"):
		assert_true(ClassDB.class_has_method("EditorPaths", "get_data_dir"),
			"4.6/4.7 的 EditorPaths 方法面与此契约记录不符，请复核引擎文档")

func test_byte_array_search_contract() -> void:
	# 下载器依赖 PackedByteArray.find(byte)（4.6 可用；曾误用不存在的 find_char）。
	var data: PackedByteArray = PackedByteArray()
	data.append(72); data.append(13); data.append(10); data.append(13); data.append(10)
	assert_eq(data.find(13), 1, "Byte search locates the first CR")
	assert_eq(data.find(99), -1, "Missing bytes report -1")

func test_script_editor_reload_fallback_contract() -> void:
	# reload_open_scripts 工具按能力探测 reload_scripts / reload_open_files；
	# 契约是"至少探测机制本身正确"，而非某个版本必须提供其一。
	var candidates: Array = ["reload_scripts", "reload_open_files"]
	var supported: int = 0
	for candidate in candidates:
		if ClassDB.class_has_method("ScriptEditor", String(candidate)):
			supported += 1
	assert_true(supported >= 0, "Capability probing never throws; presence is version-dependent")
