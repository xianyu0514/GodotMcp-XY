# variant_codec.gd — Godot Variant 与 JSON 的统一编解码
#
# 背景：call_runtime_node_method 之前直接 callv(raw_arguments)，
# JSON 里的 Dictionary 不会自动变成 Vector2i，导致大量 Godot typed API
# （set_cell(Vector2i, ...)、draw_texture_rect_region 等）无法自然调用。
#
# 编码格式（自描述标签，便于跨语言客户端生成）：
#   {"__godot_type": "Vector2i", "x": 30, "y": 10}
#
# 同一个 codec 被所有 runtime 工具共用（属性/方法/表达式/着色器/瓦片），
# 避免每个工具自定义一套序列化规则导致行为不一致。

class_name MCPVariantCodec
extends RefCounted

## 自描述标签键
const TYPE_KEY: String = "__godot_type"

## 支持的类型标签
const TYPE_VECTOR2: String = "Vector2"
const TYPE_VECTOR2I: String = "Vector2i"
const TYPE_VECTOR3: String = "Vector3"
const TYPE_VECTOR3I: String = "Vector3i"
const TYPE_VECTOR4: String = "Vector4"
const TYPE_VECTOR4I: String = "Vector4i"
const TYPE_COLOR: String = "Color"
const TYPE_RECT2: String = "Rect2"
const TYPE_RECT2I: String = "Rect2i"
const TYPE_PLANE: String = "Plane"
const TYPE_QUATERNION: String = "Quaternion"
const TYPE_AABB: String = "AABB"
const TYPE_BASIS: String = "Basis"
const TYPE_TRANSFORM2D: String = "Transform2D"
const TYPE_TRANSFORM3D: String = "Transform3D"
const TYPE_PROJECTION: String = "Projection"
const TYPE_NODE_PATH: String = "NodePath"
const TYPE_STRING_NAME: String = "StringName"
const TYPE_RID: String = "RID"

const SUPPORTED_TYPES: Array[String] = [
	TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I,
	TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_COLOR, TYPE_RECT2, TYPE_RECT2I,
	TYPE_PLANE, TYPE_QUATERNION, TYPE_AABB, TYPE_BASIS,
	TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_PROJECTION,
	TYPE_NODE_PATH, TYPE_STRING_NAME, TYPE_RID
]

## 编码时直接透传、无需转换的 JSON 原生类型
const PASSTHROUGH_TYPES: Array[int] = [
	TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING
]


## 把任意 Godot 值编码成 JSON 安全结构。递归处理 Array / Dictionary。
static func encode(value: Variant) -> Variant:
	var kind: int = typeof(value)
	if kind in PASSTHROUGH_TYPES:
		return value
	match kind:
		TYPE_ARRAY:
			var encoded_array: Array = []
			for item in (value as Array):
				encoded_array.append(encode(item))
			return encoded_array
		TYPE_DICTIONARY:
			var encoded_dict: Dictionary = {}
			for key in (value as Dictionary):
				encoded_dict[str(key)] = encode((value as Dictionary)[key])
			return encoded_dict
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return _tagged(TYPE_VECTOR2, {"x": v2.x, "y": v2.y})
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return _tagged(TYPE_VECTOR2I, {"x": v2i.x, "y": v2i.y})
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return _tagged(TYPE_VECTOR3, {"x": v3.x, "y": v3.y, "z": v3.z})
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return _tagged(TYPE_VECTOR3I, {"x": v3i.x, "y": v3i.y, "z": v3i.z})
		TYPE_VECTOR4:
			var v4: Vector4 = value
			return _tagged(TYPE_VECTOR4, {"x": v4.x, "y": v4.y, "z": v4.z, "w": v4.w})
		TYPE_VECTOR4I:
			var v4i: Vector4i = value
			return _tagged(TYPE_VECTOR4I, {"x": v4i.x, "y": v4i.y, "z": v4i.z, "w": v4i.w})
		TYPE_COLOR:
			var c: Color = value
			return _tagged(TYPE_COLOR, {"r": c.r, "g": c.g, "b": c.b, "a": c.a})
		TYPE_RECT2:
			var r2: Rect2 = value
			return _tagged(TYPE_RECT2, {"x": r2.position.x, "y": r2.position.y,
				"w": r2.size.x, "h": r2.size.y})
		TYPE_RECT2I:
			var r2i: Rect2i = value
			return _tagged(TYPE_RECT2I, {"x": r2i.position.x, "y": r2i.position.y,
				"w": r2i.size.x, "h": r2i.size.y})
		TYPE_PLANE:
			var plane: Plane = value
			return _tagged(TYPE_PLANE, {"x": plane.normal.x, "y": plane.normal.y,
				"z": plane.normal.z, "d": plane.d})
		TYPE_QUATERNION:
			var q: Quaternion = value
			return _tagged(TYPE_QUATERNION, {"x": q.x, "y": q.y, "z": q.z, "w": q.w})
		TYPE_AABB:
			var aabb: AABB = value
			return _tagged(TYPE_AABB, {
				"px": aabb.position.x, "py": aabb.position.y, "pz": aabb.position.z,
				"sx": aabb.size.x, "sy": aabb.size.y, "sz": aabb.size.z})
		TYPE_BASIS:
			var b: Basis = value
			return _tagged(TYPE_BASIS, {"rows": [
				[encode(b.x)], [encode(b.y)], [encode(b.z)]]})
		TYPE_TRANSFORM2D:
			var t2: Transform2D = value
			return _tagged(TYPE_TRANSFORM2D, {
				"xx": t2.x.x, "xy": t2.x.y,
				"yx": t2.y.x, "yy": t2.y.y,
				"ox": t2.origin.x, "oy": t2.origin.y})
		TYPE_TRANSFORM3D:
			var t3: Transform3D = value
			return _tagged(TYPE_TRANSFORM3D, {
				"basis": encode(t3.basis), "origin": encode(t3.origin)})
		TYPE_PROJECTION:
			var proj: Projection = value
			var rows: Array = []
			for row_index in range(4):
				rows.append(encode(_projection_row(proj, row_index)))
			return _tagged(TYPE_PROJECTION, {"rows": rows})
		TYPE_NODE_PATH:
			return _tagged(TYPE_NODE_PATH, {"path": String(value)})
		TYPE_STRING_NAME:
			return _tagged(TYPE_STRING_NAME, {"value": String(value)})
		TYPE_RID:
			return _tagged(TYPE_RID, {"id": (value as RID).get_id()})
	# 其余类型（Object、Callable、Signal...）无法安全 JSON 化，退化为字符串描述
	return _describe_unsupported(value)


## 解码：把带标签（或可推断）的 JSON 结构还原为 Godot Variant。
## 未识别的结构原样返回，保证向后兼容。
static func decode(value: Variant) -> Variant:
	var kind: int = typeof(value)
	if kind == TYPE_ARRAY:
		var decoded_array: Array = []
		for item in (value as Array):
			decoded_array.append(decode(item))
		return decoded_array
	if kind == TYPE_DICTIONARY:
		var data: Dictionary = value
		if data.has(TYPE_KEY):
			return _decode_tagged(data)
		var decoded_dict: Dictionary = {}
		for key in data:
			decoded_dict[key] = decode(data[key])
		return decoded_dict
	return value


## 解码方法调用参数数组。这是 call_runtime_node_method 的主入口。
static func decode_arguments(arguments: Variant) -> Array:
	if arguments == null:
		return []
	if not (arguments is Array):
		return [decode(arguments)]
	var decoded: Array = []
	for item in (arguments as Array):
		decoded.append(decode(item))
	return decoded


## 是否已经是带标签的编码值
static func is_encoded(value: Variant) -> bool:
	return value is Dictionary and (value as Dictionary).has(TYPE_KEY)


## 供错误信息使用：把值转成可读类型名
static func describe(value: Variant) -> String:
	var kind: int = typeof(value)
	if kind == TYPE_DICTIONARY and (value as Dictionary).has(TYPE_KEY):
		return String((value as Dictionary)[TYPE_KEY])
	return type_string(kind)


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

static func _tagged(type_name: String, fields: Dictionary) -> Dictionary:
	var result: Dictionary = {TYPE_KEY: type_name}
	for key in fields:
		result[key] = fields[key]
	return result


static func _decode_tagged(data: Dictionary) -> Variant:
	var type_name: String = String(data.get(TYPE_KEY, ""))
	match type_name:
		TYPE_VECTOR2:
			return Vector2(_f(data, "x"), _f(data, "y"))
		TYPE_VECTOR2I:
			return Vector2i(_i(data, "x"), _i(data, "y"))
		TYPE_VECTOR3:
			return Vector3(_f(data, "x"), _f(data, "y"), _f(data, "z"))
		TYPE_VECTOR3I:
			return Vector3i(_i(data, "x"), _i(data, "y"), _i(data, "z"))
		TYPE_VECTOR4:
			return Vector4(_f(data, "x"), _f(data, "y"), _f(data, "z"), _f(data, "w"))
		TYPE_VECTOR4I:
			return Vector4i(_i(data, "x"), _i(data, "y"), _i(data, "z"), _i(data, "w"))
		TYPE_COLOR:
			return _decode_color(data)
		TYPE_RECT2:
			return Rect2(_f(data, "x"), _f(data, "y"), _f(data, "w"), _f(data, "h"))
		TYPE_RECT2I:
			return Rect2i(_i(data, "x"), _i(data, "y"), _i(data, "w"), _i(data, "h"))
		TYPE_PLANE:
			return Plane(_f(data, "x"), _f(data, "y"), _f(data, "z"), _f(data, "d"))
		TYPE_QUATERNION:
			return Quaternion(_f(data, "x"), _f(data, "y"), _f(data, "z"), _f(data, "w"))
		TYPE_AABB:
			return AABB(
				Vector3(_f(data, "px"), _f(data, "py"), _f(data, "pz")),
				Vector3(_f(data, "sx"), _f(data, "sy"), _f(data, "sz")))
		TYPE_BASIS:
			return _decode_basis(data)
		TYPE_TRANSFORM2D:
			return Transform2D(
				Vector2(_f(data, "xx"), _f(data, "xy")),
				Vector2(_f(data, "yx"), _f(data, "yy")),
				Vector2(_f(data, "ox"), _f(data, "oy")))
		TYPE_TRANSFORM3D:
			var decoded_basis: Variant = decode(data.get("basis", {}))
			var basis: Basis = decoded_basis if decoded_basis is Basis else Basis()
			var decoded_origin: Variant = decode(data.get("origin", {}))
			var origin: Vector3 = decoded_origin if decoded_origin is Vector3 else Vector3()
			return Transform3D(basis, origin)
		TYPE_PROJECTION:
			return _decode_projection(data)
		TYPE_NODE_PATH:
			return NodePath(String(data.get("path", "")))
		TYPE_STRING_NAME:
			return StringName(String(data.get("value", "")))
		TYPE_RID:
			return RID()
	# 未知标签：原样返回，不抛错，保证旧客户端不受影响
	return data


static func _decode_color(data: Dictionary) -> Color:
	if data.has("hex"):
		var hex: String = String(data.get("hex", "")).strip_edges()
		if not hex.is_empty():
			return Color(hex)
	return Color(_f(data, "r"), _f(data, "g"), _f(data, "b"), _f(data, "a", 1.0))


static func _decode_basis(data: Dictionary) -> Basis:
	var rows_value: Variant = data.get("rows", [])
	if not (rows_value is Array):
		return Basis()
	var rows: Array = rows_value
	var vectors: Array[Vector3] = []
	for index in range(3):
		if index < rows.size():
			var decoded_row: Variant = decode(rows[index])
			if decoded_row is Vector3:
				vectors.append(decoded_row)
				continue
		vectors.append(Vector3())
	return Basis(vectors[0], vectors[1], vectors[2])


static func _decode_projection(data: Dictionary) -> Projection:
	var rows_value: Variant = data.get("rows", [])
	var projection: Projection = Projection()
	if not (rows_value is Array):
		return projection
	var rows: Array = rows_value
	for index in range(mini(4, rows.size())):
		var decoded_row: Variant = decode(rows[index])
		if decoded_row is Vector4:
			projection = _projection_with_row(projection, index, decoded_row)
	return projection


static func _projection_row(proj: Projection, index: int) -> Vector4:
	match index:
		0: return Vector4(proj.x.x, proj.x.y, proj.x.z, proj.x.w)
		1: return Vector4(proj.y.x, proj.y.y, proj.y.z, proj.y.w)
		2: return Vector4(proj.z.x, proj.z.y, proj.z.z, proj.z.w)
		_: return Vector4(proj.w.x, proj.w.y, proj.w.z, proj.w.w)


static func _projection_with_row(proj: Projection, index: int, row: Vector4) -> Projection:
	var result: Projection = proj
	match index:
		0: result.x = row
		1: result.y = row
		2: result.z = row
		_: result.w = row
	return result


static func _f(data: Dictionary, key: String, fallback: float = 0.0) -> float:
	if not data.has(key):
		return fallback
	var value: Variant = data[key]
	if value is bool:
		return 1.0 if value else 0.0
	if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
		return float(value)
	if value is String:
		return (value as String).to_float()
	return fallback


static func _i(data: Dictionary, key: String, fallback: int = 0) -> int:
	if not data.has(key):
		return fallback
	var value: Variant = data[key]
	if value is bool:
		return 1 if value else 0
	if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
		return int(value)
	if value is String:
		return int((value as String).to_float())
	return fallback


static func _describe_unsupported(value: Variant) -> String:
	return "<unsupported:%s>" % type_string(typeof(value))
