class_name LayoutVerifier
extends RefCounted

# E3 离线布局验证：按 .tscn 中 Control 节点的锚点/偏移，在多种视口尺寸下
# 确定性解算控件矩形——越界与兄弟重叠即违规。无需真机即可证明
# "锚点布局在三种分辨率下成立"（锚点布局的本意就是分辨率无关）；
# 真机侧只需在当前尺寸做可见性/交互抽查（由 play 演练承担）。
#
# 纯逻辑静态实现，可单测；不注册 MCP 工具。

## 锚点预设 → 锚点值（anchors_preset 单独出现、无显式 anchor_* 时的近似）
const PRESET_ANCHORS: Dictionary = {
	0: [0.0, 0.0, 0.0, 0.0],   # top-left
	1: [0.5, 0.0, 0.5, 0.0],   # top-center
	2: [1.0, 0.0, 1.0, 0.0],   # top-right
	3: [0.0, 1.0, 0.0, 1.0],   # bottom-left
	4: [0.5, 1.0, 0.5, 1.0],   # bottom-center
	5: [1.0, 1.0, 1.0, 1.0],   # bottom-right
	6: [0.0, 0.5, 0.0, 0.5],   # center-left
	7: [1.0, 0.5, 1.0, 0.5],   # center-right
	8: [0.5, 0.5, 0.5, 0.5],   # center
	9: [0.0, 0.0, 1.0, 0.5],   # left-wide
	10: [0.5, 0.0, 1.0, 0.5],  # right-wide
	11: [0.0, 0.5, 1.0, 1.0],  # bottom-wide
	12: [0.0, 0.0, 1.0, 0.5],  # top-wide
	13: [0.0, 0.0, 0.5, 1.0],  # v-center-wide（近似）
	14: [0.5, 0.0, 0.5, 1.0],  # h-center-wide（近似）
	15: [0.0, 0.0, 1.0, 1.0],  # full-rect
}

const CONTROL_TYPES: Array = [
	"Control", "Button", "Label", "Panel", "PanelContainer", "TextureRect",
	"LineEdit", "TextEdit", "CheckButton", "CheckBox", "HSlider", "VSlider",
	"ProgressBar", "ColorRect", "Container", "CenterContainer", "VBoxContainer",
	"HBoxContainer", "MarginContainer", "ScrollContainer", "ItemList", "TabContainer",
]

## 验证场景的根级 Control 布局在给定尺寸下是否成立。
## @returns: {checked: int, sizes: Array, violations: Array[{node, size, issue}]}
static func verify_scene_layout(scene_path: String, sizes: Array) -> Dictionary:
	var controls: Array = _parse_root_controls(scene_path)
	var violations: Array = []
	for size_value in sizes:
		var size: Vector2i = size_value
		var rects: Array = []
		for control in controls:
			var rect: Rect2 = _resolve_rect(control, size)
			if rect.size.x <= 0.5 or rect.size.y <= 0.5:
				continue
			if rect.position.x < -0.5 or rect.position.y < -0.5 \
					or rect.end.x > float(size.x) + 0.5 or rect.end.y > float(size.y) + 0.5:
				violations.append({
					"node": control["name"],
					"size": "%dx%d" % [size.x, size.y],
					"issue": "out of viewport bounds: rect=%s" % [ _format_rect(rect) ],
				})
			rects.append({"node": control["name"], "rect": rect})
		for i in range(rects.size()):
			for j in range(i + 1, rects.size()):
				var intersection: Rect2 = (rects[i]["rect"] as Rect2).intersection(rects[j]["rect"] as Rect2)
				if intersection.size.x > 1.0 and intersection.size.y > 1.0:
					# 完全包含 = 容器语义（面板承载内容），不是互相遮挡；
					# 只标记部分交叠（互相遮挡出不可点击区域）。
					var rect_a: Rect2 = rects[i]["rect"]
					var rect_b: Rect2 = rects[j]["rect"]
					if rect_a.encloses(rect_b) or rect_b.encloses(rect_a):
						continue
					violations.append({
						"node": "%s <-> %s" % [rects[i]["node"], rects[j]["node"]],
						"size": "%dx%d" % [size.x, size.y],
						"issue": "controls overlap (unclickable region): intersection=%s" % _format_rect(intersection),
					})
	return {"checked": controls.size(), "sizes": sizes.duplicate(), "violations": violations}

## 解析 .tscn 根级（parent="."）Control 节点的锚点/偏移。
static func _parse_root_controls(scene_path: String) -> Array:
	var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		return []
	var content: String = file.get_as_text()
	file.close()
	var controls: Array = []
	var current: Dictionary = {}
	for raw_line in content.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("[node "):
			if _control_ready(current):
				controls.append(current)
			current = _parse_node_header(line)
			continue
		if line.begins_with("[") or line.is_empty():
			continue
		if not current.is_empty():
			var eq: int = line.find("=" )
			if eq > 0:
				current["props"][line.left(eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	if _control_ready(current):
		controls.append(current)
	return controls

static func _control_ready(current: Dictionary) -> bool:
	return not current.is_empty() and String(current.get("type", "")) in CONTROL_TYPES

static func _parse_node_header(line: String) -> Dictionary:
	var name: String = _extract_attr(line, "name")
	var type: String = _extract_attr(line, "type")
	var parent: String = _extract_attr(line, "parent")
	if type.is_empty() or parent != ".":
		return {}
	return {"name": name, "type": type, "props": {}}

static func _extract_attr(line: String, attr: String) -> String:
	var key: String = attr + '="'
	var start: int = line.find(key)
	if start < 0:
		return ""
	start += key.length()
	var end_index: int = line.find('"', start)
	if end_index < 0:
		return ""
	return line.substr(start, end_index - start)

static func _resolve_rect(control: Dictionary, viewport: Vector2i) -> Rect2:
	var props: Dictionary = control["props"]
	var anchors: Array = PRESET_ANCHORS.get(15, [0.0, 0.0, 1.0, 1.0]) \
		if _preset_value(props) == 15 else PRESET_ANCHORS.get(_preset_value(props), [0.0, 0.0, 0.0, 0.0])
	var a_left: float = _float_prop(props, "anchor_left", float(anchors[0]))
	var a_top: float = _float_prop(props, "anchor_top", float(anchors[1]))
	var a_right: float = _float_prop(props, "anchor_right", float(anchors[2]))
	var a_bottom: float = _float_prop(props, "anchor_bottom", float(anchors[3]))
	var o_left: float = _float_prop(props, "offset_left", 0.0)
	var o_top: float = _float_prop(props, "offset_top", 0.0)
	var o_right: float = _float_prop(props, "offset_right", 0.0)
	var o_bottom: float = _float_prop(props, "offset_bottom", 0.0)
	var width: float = float(viewport.x)
	var height: float = float(viewport.y)
	return Rect2(
		a_left * width + o_left,
		a_top * height + o_top,
		(a_right - a_left) * width + (o_right - o_left),
		(a_bottom - a_top) * height + (o_bottom - o_top))

static func _preset_value(props: Dictionary) -> int:
	var raw: String = String(props.get("anchors_preset", ""))
	if raw.is_empty():
		return -1
	var as_int: String = raw.trim_prefix(" ").split(".")[0]
	if as_int.is_valid_int():
		return int(as_int)
	return -1

static func _float_prop(props: Dictionary, key: String, fallback: float) -> float:
	var raw: Variant = props.get(key, null)
	if raw == null:
		return fallback
	var text: String = String(raw).trim_prefix(" ").split(".")[0]
	if not text.is_valid_float():
		return fallback
	return float(String(raw))

static func _format_rect(rect: Rect2) -> String:
	return "(%.0f, %.0f, %.0f x %.0f)" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
