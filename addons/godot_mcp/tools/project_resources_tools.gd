# project_resources_tools.gd - Project resource-domain tools (split from project_tools_native.gd)
# Resource create/read/update/batch/dependencies/migration/deprecated-API/UID/reverse-deps/unused.

@tool
class_name ProjectResourcesTools
extends RefCounted

const ScriptCompileMemoScript = preload("res://addons/godot_mcp/utils/script_compile_memo.gd")
const GeneratedCacheFilterScript = preload("res://addons/godot_mcp/utils/generated_cache_filter.gd")

var _editor_interface: EditorInterface = null
var _server_core: RefCounted = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func _get_editor_interface() -> EditorInterface:
	if _editor_interface:
		return _editor_interface
	if Engine.has_meta("GodotMCPPlugin"):
		var plugin = Engine.get_meta("GodotMCPPlugin")
		if plugin and plugin.has_method("get_editor_interface"):
			return plugin.get_editor_interface()
	return null

# ============================================================================
# Tool registration
# ============================================================================

func register_tools(server_core: RefCounted) -> void:
	_server_core = server_core
	_register_list_project_resources(server_core)
	_register_create_resource(server_core)
	_register_create_custom_resource(server_core)
	_register_batch_create_resources(server_core)
	_register_update_resource_properties(server_core)
	_register_read_resource_properties(server_core)
	_register_reimport_resources(server_core)
	_register_get_import_metadata(server_core)
	_register_get_resource_uid_info(server_core)
	_register_fix_resource_uid(server_core)
	_register_get_resource_dependencies(server_core)
	_register_scan_missing_resource_dependencies(server_core)
	_register_scan_cyclic_resource_dependencies(server_core)
	_register_detect_broken_scripts(server_core)
	_register_audit_project_health(server_core)
	_register_find_resource_usages(server_core)
	_register_list_unused_resources(server_core)
	_register_scan_migration_compatibility(server_core)
	_register_apply_migration_fixes(server_core)
	_register_find_deprecated_api_usage(server_core)
	_register_detect_gdextension_addons(server_core)

static func _add_pagination_output_schema(output_schema: Dictionary) -> void:
	var properties: Dictionary = output_schema.get("properties", {})
	properties["offset"] = {"type": "integer"}
	properties["limit"] = {"type": "integer"}
	properties["returned_count"] = {"type": "integer"}
	properties["has_more"] = {"type": "boolean"}
	properties["next_offset"] = {"type": "integer"}

static func _sorted_unique_strings(values: Array[String]) -> Array[String]:
	var seen: Dictionary = {}
	for value in values:
		seen[value] = true
	var result: Array[String] = []
	for value in seen:
		result.append(String(value))
	result.sort()
	return result

func _paginate_snapshot(snapshot: Dictionary, items_key: String, limit: int,
		offset: int) -> Dictionary:
	var result: Dictionary = snapshot.duplicate()
	var page: Dictionary = PayloadUtils.paginate_list(
		snapshot.get(items_key, []), limit, offset)
	result[items_key] = page["items"]
	for field in ["total_count", "truncated", "offset", "limit", "returned_count", "has_more"]:
		result[field] = page[field]
	if page.has("next_offset"):
		result["next_offset"] = page["next_offset"]
	else:
		result.erase("next_offset")
	return result

func _get_or_compute_read_snapshot(tool_name: String, arguments: Dictionary,
		producer: Callable) -> Dictionary:
	if _server_core and _server_core.has_method("get_or_compute_read_snapshot"):
		return _server_core.get_or_compute_read_snapshot(tool_name, arguments, producer)
	var produced: Variant = producer.call()
	return produced if produced is Dictionary else {}

# ============================================================================
# list_project_resources - 列出项目资源
# ============================================================================

func _register_list_project_resources(server_core: RefCounted) -> void:
	var tool_name: String = "list_project_resources"
	var description: String = "List project resource files with lossless limit/offset pagination. Follow next_offset while has_more is true; every page reuses one revision-safe scan snapshot."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Optional subpath to search. Default is 'res://'.",
				"default": "res://"
			},
			"resource_types": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Optional list of file extensions to filter (e.g. ['.tres', '.png']). Returns all if not provided."
			},
			"limit": {"type": "integer", "description": "Maximum resources per page. Default is 1000.", "default": 1000},
			"offset": {"type": "integer", "description": "Zero-based offset. Continue with next_offset while has_more is true.", "default": 0}
		}
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resources": {
				"type": "array",
				"items": {"type": "string"}
			},
			"count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"}
		}
	}
	_add_pagination_output_schema(output_schema)
	
	# annotations - readOnlyHint = true
	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_project_resources"),
						  output_schema, annotations,
						  "core", "Project")

func _tool_list_project_resources(params: Dictionary) -> Dictionary:
	# 参数提取
	var search_path: String = params.get("search_path", "res://")
	var resource_types: Array = params.get("resource_types", [])
	var limit: int = int(params.get("limit", 1000))
	var offset: int = int(params.get("offset", 0))
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	search_path = validation["sanitized"]
	
	# 常见资源扩展名
	var default_extensions: Array[String] = [
		".tres", ".res", ".otr", ".font", ".theme",
		".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".hdr",
		".ogg", ".wav", ".mp3", ".oggstr",
		".obj", ".glb", ".gltf", ".mesh", ".fbx",
		".material", ".shader", ".gdshader",
		".tscn", ".gd", ".cfg", ".json",
		".ttf", ".otf", ".woff", ".woff2"
	]
	
	# 如果提供了resource_types，使用它；否则使用默认扩展名
	var extensions: Array[String] = []
	if resource_types.size() > 0:
		for ext in resource_types:
			var ext_str: String = str(ext).strip_edges().to_lower()
			if ext_str.is_empty():
				continue
			if not ext_str.begins_with("."):
				ext_str = "." + ext_str
			extensions.append(ext_str)
	else:
		extensions = default_extensions
	extensions = _sorted_unique_strings(extensions)
	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"list_project_resources", {"search_path": search_path, "resource_types": extensions},
		func() -> Dictionary: return _scan_project_resources(search_path, extensions))
	return _paginate_snapshot(snapshot, "resources", limit, offset)

func _scan_project_resources(search_path: String, extensions: Array[String]) -> Dictionary:
	var resources: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, extensions, resources)
	resources.sort()
	return {
		"resources": resources,
		"count": resources.size(),
		"total_count": resources.size()
	}


# ============================================================================
# create_resource - 创建资源
# ============================================================================

func _register_create_resource(server_core: RefCounted) -> void:
	var tool_name: String = "create_resource"
	var description: String = "Create a new Godot resource file (.tres). Supports common resource types."
	
	# inputSchema
	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Path where the resource will be saved (e.g. 'res://resources/my_curve.tres')"
			},
			"resource_type": {
				"type": "string",
				"description": "Type of resource to create (e.g. 'Curve', 'Gradient', 'StyleBoxFlat', 'Animation')"
			},
			"properties": {
				"type": "object",
				"description": "Optional dictionary of property values to set on the resource"
			}
		},
		"required": ["resource_path", "resource_type"]
	}
	
	# outputSchema
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_type": {"type": "string"}
		}
	}
	
	# annotations
	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}
	
	# 注册工具
	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_resource(params: Dictionary) -> Dictionary:
	# 参数提取
	var resource_path: String = params.get("resource_path", "")
	var resource_type: String = params.get("resource_type", "")
	var properties: Dictionary = params.get("properties", {})
	
	# 参数验证
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}
	if resource_type.is_empty():
		return {"error": "Missing required parameter: resource_type"}
	
	# 使用PathValidator验证路径安全性
	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	
	# 使用清理后的路径
	resource_path = validation["sanitized"]
	
	# 验证资源类型
	if not ClassDB.class_exists(resource_type):
		return {"error": "Invalid resource type: " + resource_type}
	
	if not ClassDB.is_parent_class(resource_type, "Resource"):
		return {"error": "Type '%s' is not a Resource type" % resource_type}
	
	# 创建资源实例
	var resource: RefCounted = ClassDB.instantiate(resource_type)
	
	if not resource:
		return {"error": "Failed to create resource of type: " + resource_type}
	
	# 设置属性（如果有）
	for prop_name in properties:
		if prop_name in resource:
			var converted_val: Variant = _convert_value_for_resource(resource, prop_name, properties[prop_name])
			resource.set(prop_name, converted_val)
	
	# 保存资源
	var error: Error = ResourceSaver.save(resource, resource_path)
	
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}
	
	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_type": resource_type
	}

func _convert_value_for_resource(resource: Resource, property_name: String, value: Variant) -> Variant:
	if value == null:
		return value
	var property_type: int = TYPE_NIL
	for prop in resource.get_property_list():
		if prop["name"] == property_name:
			property_type = prop["type"]
			break
	if property_type == TYPE_NIL:
		return value
	match property_type:
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
			if value is String:
				var parsed: Dictionary = _parse_key_value_string(value)
				if not parsed.is_empty():
					return Vector2(float(parsed.get("x", 0.0)), float(parsed.get("y", 0.0)))
				var parts: PackedStringArray = value.replace("Vector2", "").replace("(", "").replace(")", "").replace(" ", "").split(",")
				if parts.size() >= 2:
					return Vector2(float(parts[0]), float(parts[1]))
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
			if value is String:
				var parsed: Dictionary = _parse_key_value_string(value)
				if not parsed.is_empty():
					return Vector3(float(parsed.get("x", 0.0)), float(parsed.get("y", 0.0)), float(parsed.get("z", 0.0)))
				var parts: PackedStringArray = value.replace("Vector3", "").replace("(", "").replace(")", "").replace(" ", "").split(",")
				if parts.size() >= 3:
					return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		TYPE_COLOR:
			if value is Dictionary:
				return Color(float(value.get("r", 0.0)), float(value.get("g", 0.0)), float(value.get("b", 0.0)), float(value.get("a", 1.0)))
			if value is String:
				if value.begins_with("#") or value.begins_with("Color"):
					return Color(value)
		TYPE_BOOL:
			if value is String:
				return value.to_lower() == "true"
			if value is int or value is float:
				return value != 0
		TYPE_INT:
			if value is String:
				return int(value)
			if value is float:
				return int(value)
		TYPE_FLOAT:
			if value is String:
				return float(value)
			if value is int:
				return float(value)
		TYPE_OBJECT:
			if value is String:
				if value.begins_with("res://"):
					var loaded_res: Resource = load(value)
					if loaded_res:
						return loaded_res
				if ClassDB.class_exists(value) and ClassDB.is_parent_class(value, "Resource"):
					return ClassDB.instantiate(value)
		TYPE_ARRAY:
			if value is Array:
				var result: Array = []
				for item in value:
					result.append(_convert_value_for_resource(resource, property_name, item))
				return result
		TYPE_DICTIONARY:
			if value is Dictionary:
				var result: Dictionary = {}
				for key in value:
					result[key] = _convert_value_for_resource(resource, property_name, value[key])
				return result
	return value

func _parse_key_value_string(value: String) -> Dictionary:
	if not (value.begins_with("{") and value.ends_with("}")):
		return {}
	var inner: String = value.substr(1, value.length() - 2).replace(" ", "")
	var result: Dictionary = {}
	var entries: PackedStringArray = inner.split(",")
	for entry in entries:
		var kv: PackedStringArray = entry.split(":")
		if kv.size() == 2:
			result[kv[0]] = kv[1]
	return result


# ============================================================================
# Shared helpers for data-driven resource tools
# ============================================================================

# Resolve a Resource instance from an explicit script path, a built-in ClassDB
# type, or a project global class_name. Returns {"resource": Resource} on
# success or {"error": String} on failure.
func _instantiate_resource_for_write(resource_type: String, script_path: String) -> Dictionary:
	if not script_path.is_empty():
		if not ResourceLoader.exists(script_path):
			return {"error": "Script not found: " + script_path}
		var script: Resource = load(script_path)
		if not (script is Script):
			return {"error": "Path is not a script: " + script_path}
		var instance: Variant = script.new()
		if not (instance is Resource):
			return {"error": "Script does not extend Resource: " + script_path}
		return {"resource": instance}

	if resource_type.is_empty():
		return {"error": "Provide resource_type (built-in type or class_name) or script_path"}

	if ClassDB.class_exists(resource_type):
		if not ClassDB.is_parent_class(resource_type, "Resource"):
			return {"error": "Type '%s' is not a Resource type" % resource_type}
		if not ClassDB.can_instantiate(resource_type):
			return {"error": "Cannot instantiate Resource class: " + resource_type}
		return {"resource": ClassDB.instantiate(resource_type)}

	var global_entry: Dictionary = ProjectToolsNative._find_project_global_class_entry(resource_type)
	if global_entry.is_empty():
		return {"error": "Unknown resource type or class_name: " + resource_type}
	var global_script_path: String = str(global_entry.get("path", ""))
	var global_script: Resource = load(global_script_path)
	if not (global_script is Script):
		return {"error": "Failed to load class script: " + global_script_path}
	var global_instance: Variant = global_script.new()
	if not (global_instance is Resource):
		return {"error": "Class '%s' does not extend Resource" % resource_type}
	return {"resource": global_instance}

# Apply a properties dict onto a resource, converting each value to the target
# property's declared type. Records applied/skipped property names in place.
func _apply_properties_to_resource(resource: Resource, properties: Dictionary, applied: Array, skipped: Array) -> void:
	for prop_name in properties:
		if prop_name in resource:
			var converted_val: Variant = _convert_value_for_resource(resource, prop_name, properties[prop_name])
			resource.set(prop_name, converted_val)
			applied.append(prop_name)
		else:
			skipped.append(prop_name)

# Convert a resource property value into a JSON-friendly representation.
func _serialize_resource_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(_serialize_resource_value(item))
			return arr
		TYPE_DICTIONARY:
			var dict: Dictionary = {}
			for key in value:
				dict[str(key)] = _serialize_resource_value(value[key])
			return dict
		TYPE_OBJECT:
			if value is Resource:
				var res_path: String = value.resource_path
				if not res_path.is_empty():
					return res_path
				return "<SubResource:%s>" % value.get_class()
			return str(value)
		_:
			return str(value)


# ============================================================================
# create_custom_resource - create a custom/script-backed Resource instance
# ============================================================================

func _register_create_custom_resource(server_core: RefCounted) -> void:
	var tool_name: String = "create_custom_resource"
	var description: String = "Create a .tres/.res file for a custom class_name Resource (or a Resource script by path), setting exported properties. Unlike create_resource, this resolves project global classes (e.g. CardData) and explicit script paths, not just built-in engine types."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Save path (.tres or .res), e.g. res://data/cards/strike.tres."},
			"resource_type": {"type": "string", "description": "Built-in Resource type or a project class_name (e.g. CardData). Provide this or script_path."},
			"script_path": {"type": "string", "description": "Path to a Resource script to instantiate (e.g. res://data/card_data.gd). Takes precedence over resource_type."},
			"properties": {"type": "object", "description": "Exported properties to set on the new resource."}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_type": {"type": "string"},
			"script_path": {"type": "string"},
			"applied_properties": {"type": "array", "items": {"type": "string"}},
			"skipped_properties": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_create_custom_resource"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_create_custom_resource(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var resource_type: String = str(params.get("resource_type", "")).strip_edges()
	var script_path: String = str(params.get("script_path", "")).strip_edges()
	var properties: Dictionary = params.get("properties", {})

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var instantiated: Dictionary = _instantiate_resource_for_write(resource_type, script_path)
	if instantiated.has("error"):
		return {"error": instantiated["error"]}
	var resource: Resource = instantiated["resource"]

	var applied: Array = []
	var skipped: Array = []
	_apply_properties_to_resource(resource, properties, applied, skipped)

	var dir_path: String = resource_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK:
			return {"error": "Failed to create directory: " + dir_path}

	var error: Error = ResourceSaver.save(resource, resource_path)
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_type": resource_type,
		"script_path": script_path,
		"applied_properties": applied,
		"skipped_properties": skipped
	}


# ============================================================================
# batch_create_resources - create many resources from a list spec
# ============================================================================

func _register_batch_create_resources(server_core: RefCounted) -> void:
	var tool_name: String = "batch_create_resources"
	var description: String = "Create many resource files (.tres) in one call from a list spec. Shared resource_type/script_path/base_path/properties act as defaults that each item may override. Ideal for generating data-driven content such as card, relic, or enemy resource sets."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resources": {"type": "array", "description": "List of items. Each item: {resource_path|name, resource_type?, script_path?, properties?}.", "items": {"type": "object"}},
			"base_path": {"type": "string", "description": "Directory prefix combined with each item's name to build resource_path (e.g. res://data/cards/)."},
			"resource_type": {"type": "string", "description": "Default built-in type or class_name for items that omit it."},
			"script_path": {"type": "string", "description": "Default Resource script path for items that omit it."},
			"properties": {"type": "object", "description": "Default properties merged beneath each item's properties (item values win)."}
		},
		"required": ["resources"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"created_count": {"type": "integer"},
			"failed_count": {"type": "integer"},
			"created": {"type": "array", "items": {"type": "string"}},
			"failed": {"type": "array", "items": {"type": "object"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_batch_create_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_batch_create_resources(params: Dictionary) -> Dictionary:
	var items: Array = params.get("resources", [])
	if items.is_empty():
		return {"error": "Missing required parameter: resources (non-empty array)"}

	var base_path: String = str(params.get("base_path", "")).strip_edges()
	var default_type: String = str(params.get("resource_type", "")).strip_edges()
	var default_script: String = str(params.get("script_path", "")).strip_edges()
	var default_props: Dictionary = params.get("properties", {})

	var created: Array = []
	var failed: Array = []

	for index in items.size():
		var item: Variant = items[index]
		if not (item is Dictionary):
			failed.append({"index": index, "error": "Item must be an object"})
			continue

		var resource_path: String = str(item.get("resource_path", "")).strip_edges()
		if resource_path.is_empty():
			var item_name: String = str(item.get("name", "")).strip_edges()
			if item_name.is_empty() or base_path.is_empty():
				failed.append({"index": index, "error": "Item needs resource_path, or name + base_path"})
				continue
			resource_path = base_path.path_join(item_name)
			if not (resource_path.ends_with(".tres") or resource_path.ends_with(".res")):
				resource_path += ".tres"

		var item_type: String = str(item.get("resource_type", default_type)).strip_edges()
		var item_script: String = str(item.get("script_path", default_script)).strip_edges()

		var merged_props: Dictionary = default_props.duplicate(true)
		var item_props: Dictionary = item.get("properties", {})
		for key in item_props:
			merged_props[key] = item_props[key]

		var single_params: Dictionary = {
			"resource_path": resource_path,
			"resource_type": item_type,
			"script_path": item_script,
			"properties": merged_props
		}
		var result: Dictionary = _tool_create_custom_resource(single_params)
		if result.has("error"):
			failed.append({"index": index, "resource_path": resource_path, "error": result["error"]})
		else:
			created.append(resource_path)

	return {
		"status": "success" if failed.is_empty() else "partial",
		"created_count": created.size(),
		"failed_count": failed.size(),
		"created": created,
		"failed": failed
	}


# ============================================================================
# update_resource_properties - edit an existing resource file in place
# ============================================================================

func _register_update_resource_properties(server_core: RefCounted) -> void:
	var tool_name: String = "update_resource_properties"
	var description: String = "Load an existing resource file (.tres/.res), set/merge exported properties, and re-save it. Use to tweak data such as card cost or enemy HP without rewriting the file by hand."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to an existing resource file."},
			"properties": {"type": "object", "description": "Properties to set on the resource."}
		},
		"required": ["resource_path", "properties"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"updated_properties": {"type": "array", "items": {"type": "string"}},
			"skipped_properties": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_update_resource_properties"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_update_resource_properties(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var properties: Dictionary = params.get("properties", {})

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}
	if properties.is_empty():
		return {"error": "Missing required parameter: properties (non-empty object)"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not ResourceLoader.exists(resource_path):
		return {"error": "Resource not found: " + resource_path}
	var resource: Resource = ResourceLoader.load(resource_path)
	if not resource:
		return {"error": "Failed to load resource: " + resource_path}

	var applied: Array = []
	var skipped: Array = []
	_apply_properties_to_resource(resource, properties, applied, skipped)

	var error: Error = ResourceSaver.save(resource, resource_path)
	if error != OK:
		return {"error": "Failed to save resource: " + error_string(error)}

	return {
		"status": "success",
		"resource_path": resource_path,
		"updated_properties": applied,
		"skipped_properties": skipped
	}


# ============================================================================
# read_resource_properties - dump a resource's exported properties as JSON
# ============================================================================

func _register_read_resource_properties(server_core: RefCounted) -> void:
	var tool_name: String = "read_resource_properties"
	var description: String = "Read a resource file (.tres/.res) and return its exported (script-declared) properties as JSON-friendly values. Optionally include built-in base Resource properties. Use to inspect or verify data-driven content."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string", "description": "Path to an existing resource file."},
			"include_built_in": {"type": "boolean", "description": "Include built-in base Resource storage properties (default false).", "default": false}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"resource_class": {"type": "string"},
			"script_path": {"type": "string"},
			"properties": {"type": "object"},
			"property_count": {"type": "integer"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_read_resource_properties"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_read_resource_properties(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var include_built_in: bool = bool(params.get("include_built_in", false))

	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_file_path(resource_path, [".tres", ".res"])
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not ResourceLoader.exists(resource_path):
		return {"error": "Resource not found: " + resource_path}
	var resource: Resource = ResourceLoader.load(resource_path)
	if not resource:
		return {"error": "Failed to load resource: " + resource_path}

	var script_path: String = ""
	var script: Variant = resource.get_script()
	if script is Script:
		script_path = script.resource_path

	var properties: Dictionary = {}
	for prop in resource.get_property_list():
		var prop_name: String = str(prop.get("name", ""))
		var usage: int = int(prop.get("usage", 0))
		if prop_name.is_empty() or prop_name == "script":
			continue
		var is_script_var: bool = (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
		var is_storage: bool = (usage & PROPERTY_USAGE_STORAGE) != 0
		if is_script_var:
			properties[prop_name] = _serialize_resource_value(resource.get(prop_name))
		elif include_built_in and is_storage:
			properties[prop_name] = _serialize_resource_value(resource.get(prop_name))

	return {
		"status": "success",
		"resource_path": resource_path,
		"resource_class": resource.get_class(),
		"script_path": script_path,
		"properties": properties,
		"property_count": properties.size()
	}


# ============================================================================
# reimport_resources - 重新导入指定资源
# ============================================================================

func _register_reimport_resources(server_core: RefCounted) -> void:
	var tool_name: String = "reimport_resources"
	var description: String = "Reimport existing project resources using Godot's EditorFileSystem import pipeline."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Resource source file paths to reimport, e.g. ['res://icon.png']"
			},
			"refresh_metadata": {
				"type": "boolean",
				"description": "Whether to refresh EditorFileSystem metadata with update_file() before reimport. Default is true.",
				"default": true
			}
		},
		"required": ["resource_paths"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"requested_count": {"type": "integer"},
			"reimported_count": {"type": "integer"},
			"resource_paths": {"type": "array"},
			"invalid_paths": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_reimport_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_reimport_resources(params: Dictionary) -> Dictionary:
	var raw_paths: Array = params.get("resource_paths", [])
	if raw_paths.is_empty():
		return {"error": "Missing required parameter: resource_paths"}

	var refresh_metadata: bool = params.get("refresh_metadata", true)
	var editor_interface: EditorInterface = _get_editor_interface()
	if not editor_interface:
		return {"error": "Editor interface not available"}

	var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
	if not fs:
		return {"error": "Failed to get EditorFileSystem"}

	if fs.is_scanning():
		return {
			"status": "busy",
			"requested_count": raw_paths.size(),
			"reimported_count": 0,
			"resource_paths": [],
			"invalid_paths": [],
			"scan_progress": fs.get_scanning_progress()
		}

	var valid_paths: Array[String] = []
	var invalid_paths: Array[Dictionary] = []
	for raw_path in raw_paths:
		var resource_path: String = str(raw_path).strip_edges()
		var validation: Dictionary = PathValidator.validate_path(resource_path)
		if not validation["valid"]:
			invalid_paths.append({"path": resource_path, "error": validation["error"]})
			continue
		resource_path = validation["sanitized"]
		if not FileAccess.file_exists(resource_path):
			invalid_paths.append({"path": resource_path, "error": "File not found"})
			continue
		valid_paths.append(resource_path)

	if valid_paths.is_empty():
		return {
			"status": "no_valid_paths",
			"requested_count": raw_paths.size(),
			"reimported_count": 0,
			"resource_paths": [],
			"invalid_paths": invalid_paths
		}

	if refresh_metadata:
		for resource_path in valid_paths:
			fs.update_file(resource_path)

	var packed_paths: PackedStringArray = PackedStringArray()
	for resource_path in valid_paths:
		packed_paths.append(resource_path)
	fs.reimport_files(packed_paths)

	return {
		"status": "success",
		"requested_count": raw_paths.size(),
		"reimported_count": valid_paths.size(),
		"resource_paths": valid_paths,
		"invalid_paths": invalid_paths
	}


# ============================================================================
# get_import_metadata - 读取 .import 元数据
# ============================================================================

func _register_get_import_metadata(server_core: RefCounted) -> void:
	var tool_name: String = "get_import_metadata"
	var description: String = "Read Godot import metadata for a source asset, including importer settings and imported artifact paths."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Source asset path such as 'res://icon.png'"
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"import_config_path": {"type": "string"},
			"exists": {"type": "boolean"},
			"importer": {"type": "string"},
			"resource_type": {"type": "string"},
			"uid": {"type": "string"},
			"imported_path": {"type": "string"},
			"sections": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_import_metadata"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_import_metadata(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	var import_config_path: String = resource_path + ".import"
	if not FileAccess.file_exists(import_config_path):
		return {
			"resource_path": resource_path,
			"import_config_path": import_config_path,
			"exists": false
		}

	var config: ConfigFile = ConfigFile.new()
	var load_error: Error = config.load(import_config_path)
	if load_error != OK:
		return {"error": "Failed to load import metadata: " + error_string(load_error)}

	var sections: Dictionary = {}
	for raw_section in config.get_sections():
		var section_name: String = str(raw_section)
		var section_values: Dictionary = {}
		for raw_key in config.get_section_keys(section_name):
			var key_name: String = str(raw_key)
			section_values[key_name] = config.get_value(section_name, key_name)
		sections[section_name] = section_values

	var remap: Dictionary = sections.get("remap", {})
	var deps: Dictionary = sections.get("deps", {})
	var params_section: Dictionary = sections.get("params", {})

	return {
		"resource_path": resource_path,
		"import_config_path": import_config_path,
		"exists": true,
		"importer": str(remap.get("importer", "")),
		"resource_type": str(remap.get("type", "")),
		"uid": str(remap.get("uid", "")),
		"imported_path": str(remap.get("path", "")),
		"dependencies": deps,
		"params": params_section,
		"sections": sections
	}


# ============================================================================
# get_resource_uid_info - 读取资源 UID 信息
# ============================================================================

func _register_get_resource_uid_info(server_core: RefCounted) -> void:
	var tool_name: String = "get_resource_uid_info"
	var description: String = "Inspect Godot ResourceUID mappings for a resource path or uid:// identifier."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to inspect."
			},
			"uid": {
				"type": "string",
				"description": "Optional uid:// identifier to resolve."
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"uid": {"type": "string"},
			"uid_id": {"type": "string"},
			"editor_uid": {"type": "string"},
			"resolved_path": {"type": "string"},
			"exists": {"type": "boolean"},
			"has_uid_mapping": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_resource_uid_info"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_resource_uid_info(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	var uid_text: String = str(params.get("uid", "")).strip_edges()
	if resource_path.is_empty() and uid_text.is_empty():
		return {"error": "Provide resource_path or uid"}

	if not resource_path.is_empty():
		var validation: Dictionary = PathValidator.validate_path(resource_path)
		if not validation["valid"]:
			return {"error": "Invalid path: " + validation["error"]}
		resource_path = validation["sanitized"]
		if uid_text.is_empty():
			var mapped_uid: String = ResourceUID.path_to_uid(resource_path)
			if mapped_uid.begins_with("uid://"):
				uid_text = mapped_uid

	if not uid_text.is_empty() and not uid_text.begins_with("uid://"):
		return {"error": "uid must start with uid://"}

	var resolved_path: String = ""
	if not uid_text.is_empty():
		resolved_path = ResourceUID.uid_to_path(uid_text)
		if resource_path.is_empty():
			resource_path = resolved_path

	if not resource_path.is_empty() and uid_text.is_empty():
		var remapped_uid: String = ResourceUID.path_to_uid(resource_path)
		if remapped_uid.begins_with("uid://"):
			uid_text = remapped_uid
			resolved_path = ResourceUID.uid_to_path(uid_text)

	var effective_path: String = resource_path if not resource_path.is_empty() else resolved_path
	var exists: bool = not effective_path.is_empty() and FileAccess.file_exists(effective_path)
	var has_uid_mapping: bool = uid_text.begins_with("uid://")

	return {
		"resource_path": resource_path,
		"uid": uid_text,
		"uid_id": "",
		"resolved_path": resolved_path,
		"exists": exists,
		"has_uid_mapping": has_uid_mapping,
		"editor_uid": ""
	}


# ============================================================================
# fix_resource_uid - 生成或修复资源 UID
# ============================================================================

func _register_fix_resource_uid(server_core: RefCounted) -> void:
	var tool_name: String = "fix_resource_uid"
	var description: String = "Ensure a resource file has a persisted UID and refresh the editor filesystem mapping."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to repair, e.g. 'res://resources/example.tres'"
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"resource_path": {"type": "string"},
			"previous_uid": {"type": "string"},
			"uid": {"type": "string"},
			"uid_id": {"type": "string"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_fix_resource_uid"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_fix_resource_uid(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var previous_uid: String = ResourceUID.path_to_uid(resource_path)
	if not previous_uid.begins_with("uid://"):
		previous_uid = ""

	var uid_id: int = ResourceSaver.get_resource_id_for_path(resource_path, true)
	if uid_id == ResourceUID.INVALID_ID:
		return {"error": "Failed to generate resource UID for: " + resource_path}

	var set_error: Error = ResourceSaver.set_uid(resource_path, uid_id)
	if set_error != OK:
		return {"error": "Failed to persist resource UID: " + error_string(set_error)}

	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface:
		var fs: EditorFileSystem = editor_interface.get_resource_filesystem()
		if fs:
			fs.update_file(resource_path)

	var uid_text: String = ResourceUID.path_to_uid(resource_path)
	return {
		"status": "success",
		"resource_path": resource_path,
		"previous_uid": previous_uid,
		"uid": uid_text,
		"uid_id": str(uid_id)
	}


# ============================================================================
# get_resource_dependencies - 读取资源依赖
# ============================================================================

func _register_get_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "get_resource_dependencies"
	var description: String = "List parsed resource dependencies using Godot's ResourceLoader dependency metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Resource path to inspect."
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"dependency_count": {"type": "integer"},
			"dependencies": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_get_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_get_resource_dependencies(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var dependencies: Array = _parse_resource_dependencies(resource_path)
	return {
		"resource_path": resource_path,
		"dependency_count": dependencies.size(),
		"dependencies": dependencies
	}


# ============================================================================
# scan_missing_resource_dependencies - 扫描缺失依赖
# ============================================================================

func _register_scan_missing_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "scan_missing_resource_dependencies"
	var description: String = "Scan project resources for broken or missing dependency references."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum missing dependency issues to return. Default is 200.",
				"default": 200
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"issue_count": {"type": "integer"},
			"issues": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_missing_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_scan_missing_resource_dependencies(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var dependency_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var resources: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, dependency_extensions, resources)
	resources.sort()

	var issues: Array = []
	for resource_path in resources:
		var dependencies: Array = _parse_resource_dependencies(resource_path)
		for dependency in dependencies:
			if bool(dependency.get("missing", false)):
				issues.append({
					"owner_path": resource_path,
					"dependency": dependency
				})
				if issues.size() >= max_results:
					return {
						"search_path": search_path,
						"scanned_resources": resources.size(),
						"issue_count": issues.size(),
						"issues": issues,
						"truncated": true
					}

	return {
		"search_path": search_path,
		"scanned_resources": resources.size(),
		"issue_count": issues.size(),
		"issues": issues,
		"truncated": false
	}

func _register_scan_cyclic_resource_dependencies(server_core: RefCounted) -> void:
	var tool_name: String = "scan_cyclic_resource_dependencies"
	var description: String = "Scan project resources for cyclic dependency chains based on parsed ResourceLoader dependency metadata."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum cyclic dependency issues to return. Default is 100.",
				"default": 100
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"issue_count": {"type": "integer"},
			"issues": {"type": "array"},
			"truncated": {"type": "boolean"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_cyclic_resource_dependencies"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_scan_cyclic_resource_dependencies(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var max_results: int = max(1, int(params.get("max_results", 100)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var dependency_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var resources: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, dependency_extensions, resources)
	resources.sort()

	var graph: Dictionary = {}
	for resource_path in resources:
		graph[resource_path] = _collect_existing_dependency_paths(resource_path)

	var issues: Array = []
	var seen_cycles: Dictionary = {}
	for resource_path in resources:
		var stack: Array = []
		var visiting: Dictionary = {}
		var cycle_paths: Array = []
		_find_cycles_from_resource(resource_path, graph, stack, visiting, seen_cycles, cycle_paths, max_results - issues.size())
		for cycle_path in cycle_paths:
			issues.append({
				"owner_path": resource_path,
				"cycle_path": cycle_path,
				"cycle_length": cycle_path.size() - 1
			})
			if issues.size() >= max_results:
				return {
					"search_path": search_path,
					"scanned_resources": resources.size(),
					"issue_count": issues.size(),
					"issues": issues,
					"truncated": true
				}

	return {
		"search_path": search_path,
		"scanned_resources": resources.size(),
		"issue_count": issues.size(),
		"issues": issues,
		"truncated": false
	}

func _parse_resource_dependencies(resource_path: String) -> Array:
	var dependencies: Array = []
	for raw_dependency in ResourceLoader.get_dependencies(resource_path):
		var raw_text: String = str(raw_dependency)
		var entry: Dictionary = {
			"raw": raw_text,
			"uid": "",
			"fallback_path": "",
			"resolved_path": "",
			"exists": false,
			"missing": false
		}

		if raw_text.contains("::"):
			entry["uid"] = raw_text.get_slice("::", 0)
			entry["fallback_path"] = raw_text.get_slice("::", 2)
			var resolved_path: String = ""
			if str(entry["uid"]).begins_with("uid://"):
				resolved_path = ResourceUID.uid_to_path(str(entry["uid"]))
			if resolved_path.is_empty():
				resolved_path = str(entry["fallback_path"])
			entry["resolved_path"] = resolved_path
		else:
			entry["fallback_path"] = raw_text
			entry["resolved_path"] = raw_text

		var resolved_exists: bool = false
		var resolved_path_str: String = str(entry["resolved_path"])
		var fallback_path_str: String = str(entry["fallback_path"])
		if not resolved_path_str.is_empty():
			resolved_exists = FileAccess.file_exists(resolved_path_str)
		if not resolved_exists and not fallback_path_str.is_empty():
			resolved_exists = FileAccess.file_exists(fallback_path_str)

		entry["exists"] = resolved_exists
		entry["missing"] = not resolved_exists
		dependencies.append(entry)

	return dependencies

func _collect_existing_dependency_paths(resource_path: String) -> Array:
	var paths: Array = []
	for dependency in _parse_resource_dependencies(resource_path):
		if bool(dependency.get("missing", false)):
			continue
		var resolved_path: String = str(dependency.get("resolved_path", ""))
		var fallback_path: String = str(dependency.get("fallback_path", ""))
		var effective_path: String = resolved_path if not resolved_path.is_empty() else fallback_path
		if effective_path.is_empty():
			continue
		if not paths.has(effective_path):
			paths.append(effective_path)
	return paths

func _find_cycles_from_resource(current_path: String, graph: Dictionary, stack: Array, visiting: Dictionary, seen_cycles: Dictionary, issues: Array, remaining_budget: int) -> void:
	if remaining_budget <= 0:
		return
	if bool(visiting.get(current_path, false)):
		var cycle_start: int = stack.find(current_path)
		if cycle_start >= 0:
			var cycle_path: Array = stack.slice(cycle_start)
			cycle_path.append(current_path)
			var cycle_key: String = _canonicalize_cycle_path(cycle_path)
			if not seen_cycles.has(cycle_key):
				seen_cycles[cycle_key] = true
				issues.append(cycle_path)
		return
	if stack.has(current_path):
		return

	visiting[current_path] = true
	stack.append(current_path)
	for dependency_path in graph.get(current_path, []):
		if not graph.has(dependency_path):
			continue
		_find_cycles_from_resource(dependency_path, graph, stack, visiting, seen_cycles, issues, remaining_budget - issues.size())
		if issues.size() >= remaining_budget:
			break
	stack.pop_back()
	visiting.erase(current_path)

func _canonicalize_cycle_path(cycle_path: Array) -> String:
	if cycle_path.size() <= 1:
		return JSON.stringify(cycle_path)
	var nodes: Array = cycle_path.slice(0, cycle_path.size() - 1)
	if nodes.is_empty():
		return JSON.stringify(cycle_path)
	var best_rotation: Array = []
	for start_index in range(nodes.size()):
		var rotated: Array = []
		for offset in range(nodes.size()):
			rotated.append(nodes[(start_index + offset) % nodes.size()])
		if best_rotation.is_empty() or JSON.stringify(rotated) < JSON.stringify(best_rotation):
			best_rotation = rotated
	best_rotation.append(best_rotation[0])
	return JSON.stringify(best_rotation)


# ============================================================================
# detect_broken_scripts - 批量检测脚本诊断
# ============================================================================

func _register_detect_broken_scripts(server_core: RefCounted) -> void:
	var tool_name: String = "detect_broken_scripts"
	var description: String = "Scan GDScript files for syntax errors and lightweight warnings."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_warnings": {
				"type": "boolean",
				"description": "Whether to include lightweight warnings such as untyped var declarations. Default is true.",
				"default": true
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of script issue entries to return. Default is 200.",
				"default": 200
			},
				"include_tooling": {
					"type": "boolean",
					"description": "Include tooling directories (addons/, test/, docs/). Default false — a project-health scan compiles user code, not third-party plugin internals (set true or pass search_path=res://addons to audit tooling).",
					"default": false
				}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_scripts": {"type": "integer"},
			"broken_count": {"type": "integer"},
			"warning_count": {"type": "integer"},
			"issues": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_detect_broken_scripts"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_detect_broken_scripts(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var include_warnings: bool = params.get("include_warnings", true)
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var scripts: Array[String] = []
	# 默认只编译用户代码：addons/（第三方插件，本项目下即插件自身约 5 万行）
	# 不属于"项目健康"要诊断的范围；显式 include_tooling 或把 search_path
	# 指进工具目录仍可全量审计。与 verify_scripts 的默认收集口径保持一致。
	var include_tooling: bool = params.get("include_tooling",
		GeneratedCacheFilterScript.domain_of(search_path) == GeneratedCacheFilterScript.Domain.TOOLING)
	ProjectToolsNative._collect_resources(search_path, [".gd"], scripts, false, include_tooling)
	scripts.sort()

	var issues: Array = []
	var broken_count: int = 0
	var warning_count: int = 0

	for script_path in scripts:
		var diagnostics: Dictionary = _analyze_script_diagnostics(script_path, include_warnings)
		if diagnostics.has("error"):
			issues.append({
				"script_path": script_path,
				"severity": "error",
				"errors": [{"line": 0, "column": 0, "message": str(diagnostics["error"])}],
				"warnings": []
			})
			broken_count += 1
		else:
			var has_errors: bool = int(diagnostics.get("error_count", 0)) > 0
			var has_warnings: bool = int(diagnostics.get("warning_count", 0)) > 0
			var is_autoload_aware: bool = bool(diagnostics.get("autoload_aware", false))
			if is_autoload_aware and not has_errors:
				if has_warnings or include_warnings:
					issues.append({
						"script_path": script_path,
						"severity": "warning",
						"errors": diagnostics.get("errors", []),
						"warnings": diagnostics.get("warnings", [])
					})
					warning_count += 1
			elif has_errors or has_warnings:
				issues.append({
					"script_path": script_path,
					"severity": "error" if has_errors else "warning",
					"errors": diagnostics.get("errors", []),
					"warnings": diagnostics.get("warnings", [])
				})
				if has_errors:
					broken_count += 1
				if has_warnings:
					warning_count += 1

		if issues.size() >= max_results:
			break

	return {
		"search_path": search_path,
		"scanned_scripts": scripts.size(),
		"broken_count": broken_count,
		"warning_count": warning_count,
		"issues": issues,
		"truncated": issues.size() >= max_results and scripts.size() > issues.size()
	}


# ============================================================================
# audit_project_health - 汇总项目健康诊断
# ============================================================================

func _register_audit_project_health(server_core: RefCounted) -> void:
	var tool_name: String = "audit_project_health"
	var description: String = "Run a lightweight project health audit covering broken scripts and missing resource dependencies."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_warnings": {
				"type": "boolean",
				"description": "Whether to include lightweight script warnings. Default is true.",
				"default": true
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum issue entries per category. Default is 200.",
				"default": 200
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"status": {"type": "string"},
			"search_path": {"type": "string"},
			"summary": {"type": "object"},
			"broken_scripts": {"type": "array"},
			"missing_dependencies": {"type": "array"},
			"cyclic_dependencies": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_audit_project_health"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_audit_project_health(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var include_warnings: bool = params.get("include_warnings", true)
	var max_results: int = max(1, int(params.get("max_results", 200)))

	var broken_scripts_result: Dictionary = _tool_detect_broken_scripts({
		"search_path": search_path,
		"include_warnings": include_warnings,
		"max_results": max_results
	})
	if broken_scripts_result.has("error"):
		return broken_scripts_result

	var missing_dependencies_result: Dictionary = _tool_scan_missing_resource_dependencies({
		"search_path": search_path,
		"max_results": max_results
	})
	if missing_dependencies_result.has("error"):
		return missing_dependencies_result

	var cyclic_dependencies_result: Dictionary = _tool_scan_cyclic_resource_dependencies({
		"search_path": search_path,
		"max_results": max_results
	})
	if cyclic_dependencies_result.has("error"):
		return cyclic_dependencies_result

	var summary: Dictionary = {
		"scanned_scripts": int(broken_scripts_result.get("scanned_scripts", 0)),
		"broken_scripts": int(broken_scripts_result.get("broken_count", 0)),
		"script_warnings": int(broken_scripts_result.get("warning_count", 0)),
		"scanned_resources": int(missing_dependencies_result.get("scanned_resources", 0)),
		"missing_dependencies": int(missing_dependencies_result.get("issue_count", 0)),
		"cyclic_dependencies": int(cyclic_dependencies_result.get("issue_count", 0))
	}
	var hard_failures: int = summary["broken_scripts"] + summary["missing_dependencies"] + summary["cyclic_dependencies"]
	var status: String = "healthy"
	if hard_failures > 0:
		status = "failing"
	elif summary["script_warnings"] > 0:
		status = "warning"

	return {
		"status": status,
		"search_path": broken_scripts_result.get("search_path", search_path),
		"summary": summary,
		"broken_scripts": broken_scripts_result.get("issues", []),
		"missing_dependencies": missing_dependencies_result.get("issues", []),
		"cyclic_dependencies": cyclic_dependencies_result.get("issues", []),
		"truncated": bool(broken_scripts_result.get("truncated", false)) or bool(missing_dependencies_result.get("truncated", false)) or bool(cyclic_dependencies_result.get("truncated", false))
	}


# ============================================================================
# find_resource_usages - reverse dependency lookup: who references a resource
# ============================================================================

func _register_find_resource_usages(server_core: RefCounted) -> void:
	var tool_name: String = "find_resource_usages"
	var description: String = "Find resources that reference a target. Supports lossless limit/offset pages backed by one revision-safe scan."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {
				"type": "string",
				"description": "Target resource path to find usages of, e.g. 'res://art/player.png'."
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan for referencing resources. Default is res://.",
				"default": "res://"
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of referencing resources to return. Default is 1000.",
				"default": 1000
			},
			"offset": {
				"type": "integer",
				"description": "Zero-based usage offset. Continue with next_offset while has_more is true.",
				"default": 0
			}
		},
		"required": ["resource_path"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"resource_path": {"type": "string"},
			"search_path": {"type": "string"},
			"target_uid": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"usage_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"usages": {"type": "array"}
		}
	}
	_add_pagination_output_schema(output_schema)

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_resource_usages"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_find_resource_usages(params: Dictionary) -> Dictionary:
	var resource_path: String = str(params.get("resource_path", "")).strip_edges()
	if resource_path.is_empty():
		return {"error": "Missing required parameter: resource_path"}

	var validation: Dictionary = PathValidator.validate_path(resource_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	resource_path = validation["sanitized"]

	if not FileAccess.file_exists(resource_path):
		return {"error": "File not found: " + resource_path}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var limit: int = int(params.get("limit", 1000))
	var offset: int = int(params.get("offset", 0))
	var target_uid: String = ResourceUID.path_to_uid(resource_path)
	if not target_uid.begins_with("uid://"):
		target_uid = ""
	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"find_resource_usages",
		{"resource_path": resource_path, "search_path": search_path},
		func() -> Dictionary: return _scan_resource_usages(resource_path, search_path, target_uid))
	return _paginate_snapshot(snapshot, "usages", limit, offset)

func _scan_resource_usages(resource_path: String, search_path: String,
		target_uid: String) -> Dictionary:
	var owner_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var owners: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, owner_extensions, owners)
	owners.sort()

	var usages: Array = []
	for owner_path in owners:
		if owner_path == resource_path:
			continue
		var references: Array = []
		for dependency in _parse_resource_dependencies(owner_path):
			var resolved_path: String = str(dependency.get("resolved_path", ""))
			var fallback_path: String = str(dependency.get("fallback_path", ""))
			var dependency_uid: String = str(dependency.get("uid", ""))
			var matched_via: String = ""
			if resolved_path == resource_path or fallback_path == resource_path:
				matched_via = "path"
			elif not target_uid.is_empty() and dependency_uid == target_uid:
				matched_via = "uid"
			if not matched_via.is_empty():
				var reference: Dictionary = dependency.duplicate()
				reference["matched_via"] = matched_via
				references.append(reference)
		if not references.is_empty():
			usages.append({
				"owner_path": owner_path,
				"reference_count": references.size(),
				"references": references
			})

	return {
		"resource_path": resource_path,
		"search_path": search_path,
		"target_uid": target_uid,
		"scanned_resources": owners.size(),
		"usage_count": usages.size(),
		"total_count": usages.size(),
		"usages": usages
	}


# ============================================================================
# list_unused_resources - list orphaned resources nothing references
# ============================================================================

func _register_list_unused_resources(server_core: RefCounted) -> void:
	var tool_name: String = "list_unused_resources"
	var description: String = "List unreferenced resources in lossless limit/offset pages backed by one revision-safe scan. Entry points count as used; class_name-only script references are not tracked."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan for candidate resources. Default is res://.",
				"default": "res://"
			},
			"extensions": {
				"type": "array",
				"description": "Optional override of candidate file extensions (e.g. ['.tres', '.png']). Defaults to asset resources and excludes scripts."
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of unused resources to return. Default is 1000.",
				"default": 1000
			},
			"offset": {
				"type": "integer",
				"description": "Zero-based unused-resource offset. Continue with next_offset while has_more is true.",
				"default": 0
			}
		}
	}
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_resources": {"type": "integer"},
			"unused_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"unused_resources": {"type": "array"}
		}
	}
	_add_pagination_output_schema(output_schema)

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_list_unused_resources"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_list_unused_resources(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not validation["valid"]:
		return {"error": "Invalid path: " + validation["error"]}
	search_path = validation["sanitized"]

	var limit: int = int(params.get("limit", 1000))
	var offset: int = int(params.get("offset", 0))

	var candidate_extensions: Array[String] = []
	var override_extensions = params.get("extensions", null)
	if override_extensions is Array and not (override_extensions as Array).is_empty():
		for ext in override_extensions:
			var ext_text: String = str(ext).strip_edges().to_lower()
			if not ext_text.is_empty():
				if not ext_text.begins_with("."):
					ext_text = "." + ext_text
				candidate_extensions.append(ext_text)
	else:
		candidate_extensions = [
			".tres", ".res", ".tscn", ".scn", ".material", ".gdshader",
			".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga",
			".ogg", ".wav", ".mp3",
			".ttf", ".otf",
			".glb", ".gltf", ".obj", ".fbx"
		]
	candidate_extensions = _sorted_unique_strings(candidate_extensions)
	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"list_unused_resources",
		{"search_path": search_path, "extensions": candidate_extensions},
		func() -> Dictionary: return _scan_unused_resources(search_path, candidate_extensions))
	return _paginate_snapshot(snapshot, "unused_resources", limit, offset)

func _scan_unused_resources(search_path: String,
		candidate_extensions: Array[String]) -> Dictionary:
	var candidates: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, candidate_extensions, candidates)
	candidates.sort()

	var owner_extensions: Array[String] = [
		".tscn", ".scn", ".tres", ".res", ".gd", ".cs", ".gdshader", ".material"
	]
	var owners: Array[String] = []
	ProjectToolsNative._collect_resources("res://", owner_extensions, owners)
	# Also scan the requested search_path subtree directly so owners living
	# inside it are counted even when it is a hidden dir (DirAccess skips
	# hidden directories during the recursive res:// walk).
	if search_path != "res://":
		var extra_owners: Array[String] = []
		ProjectToolsNative._collect_resources(search_path, owner_extensions, extra_owners)
		for extra_owner in extra_owners:
			if not owners.has(extra_owner):
				owners.append(extra_owner)

	var referenced: Dictionary = {}
	for owner_path in owners:
		for dependency in _parse_resource_dependencies(owner_path):
			var resolved_path: String = str(dependency.get("resolved_path", ""))
			var fallback_path: String = str(dependency.get("fallback_path", ""))
			if not resolved_path.is_empty():
				referenced[resolved_path] = true
			if not fallback_path.is_empty():
				referenced[fallback_path] = true

	for root_path in _collect_project_resource_roots():
		referenced[root_path] = true

	var unused: Array = []
	for candidate_path in candidates:
		if not referenced.has(candidate_path):
			unused.append(candidate_path)

	return {
		"search_path": search_path,
		"scanned_resources": candidates.size(),
		"unused_count": unused.size(),
		"total_count": unused.size(),
		"unused_resources": unused
	}

func _collect_project_resource_roots() -> Array:
	var roots: Array = []
	var main_scene: String = _resolve_resource_root_path(str(ProjectSettings.get_setting("application/run/main_scene", "")))
	if not main_scene.is_empty() and not roots.has(main_scene):
		roots.append(main_scene)
	for property in ProjectSettings.get_property_list():
		var property_name: String = str(property.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var value: String = _resolve_resource_root_path(str(ProjectSettings.get_setting(property_name, "")))
		if not value.is_empty() and not roots.has(value):
			roots.append(value)
	return roots

# Normalize a project entry-point setting (main scene / autoload) to a res:// path.
# Strips the autoload "*" prefix and resolves uid:// values to their res:// path.
func _resolve_resource_root_path(raw_value: String) -> String:
	var value: String = raw_value.strip_edges()
	if value.begins_with("*"):
		value = value.substr(1)
	if value.begins_with("uid://"):
		value = ResourceUID.uid_to_path(value)
	if value.begins_with("res://"):
		return value
	return ""

func _analyze_script_diagnostics(script_path: String, include_warnings: bool) -> Dictionary:
	# 按路径记忆编译结果：全项目诊断重扫只重编译真正变化的文件。
	return ScriptCompileMemoScript.diagnostics_for(script_path,
		"analyze|%s" % str(include_warnings),
		func() -> Dictionary: return _analyze_script_diagnostics_uncached(script_path, include_warnings))

func _analyze_script_diagnostics_uncached(script_path: String, include_warnings: bool) -> Dictionary:
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open file"}
	var content: String = file.get_as_text()
	file.close()

	var validation_content: String = _strip_class_names(content)
	var test_script: GDScript = GDScript.new()
	test_script.source_code = validation_content
	var reload_error: Error = test_script.reload()

	var errors: Array = []
	var warnings: Array = []
	var autoload_aware: bool = false

	if reload_error != OK:
		var autoload_decls: String = _build_autoload_declarations()
		if not autoload_decls.is_empty():
			var retry_content: String = autoload_decls + "\n" + validation_content
			var retry_script: GDScript = GDScript.new()
			retry_script.source_code = retry_content
			var retry_err: Error = retry_script.reload()
			if retry_err == OK:
				autoload_aware = true
				if include_warnings:
					warnings.append({
						"line": 0,
						"column": 0,
						"message": "Script validates successfully with Autoload/global class awareness"
					})
		if not autoload_aware:
			var source_lines: PackedStringArray = content.split("\n")
			for i in range(source_lines.size()):
				var line: String = source_lines[i].strip_edges()
				if line.is_empty():
					continue
				if _is_likely_script_error_line(line):
					errors.append({
						"line": i + 1,
						"column": 0,
						"message": "Syntax error near: " + line
					})
					break
			if errors.is_empty():
				errors.append({
					"line": 0,
					"column": 0,
					"message": "Script has syntax errors"
				})

	if include_warnings and reload_error == OK:
		var source_lines_for_warning: PackedStringArray = content.split("\n")
		for i in range(source_lines_for_warning.size()):
			var warning_line: String = source_lines_for_warning[i].strip_edges()
			if warning_line.begins_with("var ") and not ":" in warning_line and not "=" in warning_line:
				warnings.append({
					"line": i + 1,
					"column": 0,
					"message": "Variable lacks type hint"
				})

	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"error_count": errors.size(),
		"warning_count": warnings.size(),
		"autoload_aware": autoload_aware
	}

func _strip_class_names(source: String) -> String:
	var lines: PackedStringArray = source.split("\n")
	var result: PackedStringArray = []
	for line in lines:
		var stripped: String = line.strip_edges()
		if stripped.begins_with("class_name "):
			result.append("")
		else:
			result.append(line)
	return "\n".join(result)

func _build_autoload_declarations() -> String:
	var decls: PackedStringArray = []
	for property_info in ProjectSettings.get_property_list():
		var property_name: String = str(property_info.get("name", ""))
		if not property_name.begins_with("autoload/"):
			continue
		var autoload_name: String = property_name.trim_prefix("autoload/")
		decls.append("var %s" % autoload_name)
	var global_classes: PackedStringArray = ProjectSettings.get_global_class_list()
	for class_name_str in global_classes:
		if not class_name_str.is_empty():
			decls.append("var %s" % class_name_str)
	return "\n".join(decls)

func _is_likely_script_error_line(line: String) -> bool:
	var line_lower: String = line.to_lower()
	if line_lower.contains("unexpected") or line_lower.contains("expected") or line_lower.contains("indent"):
		return true
	if line.ends_with("(") or line.ends_with(",") or line.count("\"") % 2 == 1:
		return true
	return false


# ============================================================================
# scan_migration_compatibility / apply_migration_fixes
# Engine-version migration assistant. Scans project source for usages of APIs
# changed by a target Godot release and (optionally) auto-applies the safe,
# mechanical rewrites. Rules below are derived from the official
# "Upgrading to Godot 4.7" migration guide.
# ============================================================================

func _migration_rules(target_version: String) -> Array:
	if target_version != "4.7":
		return []
	return [
		{
			"id": "rtl_image_update_mask_rename",
			"severity": "must_fix",
			"category": "GUI",
			"kind": "enum_rename",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\bUPDATE_WIDTH_IN_PERCENT\\b",
			"replacement": "UPDATE_WIDTH_UNIT",
			"auto_fixable": true,
			"gh": "GH-112617",
			"message": "RichTextLabel.ImageUpdateMask.UPDATE_WIDTH_IN_PERCENT was renamed to UPDATE_WIDTH_UNIT in Godot 4.7."
		},
		{
			"id": "audio_spectrum_tap_back_pos_removed",
			"severity": "must_fix",
			"category": "Audio",
			"kind": "removed",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\btap_back_pos\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-114355",
			"message": "AudioEffectSpectrumAnalyzer.tap_back_pos was removed in Godot 4.7."
		},
		{
			"id": "editor_scene_import_flags_enum",
			"severity": "must_fix",
			"category": "Editor",
			"kind": "enum_move",
			"languages": ["cs"],
			"behavior": false,
			"pattern": "\\bIMPORT_(ANIMATION|DISCARD_MESHES_AND_MATERIALS|FAIL_ON_MISSING_DEPENDENCIES|FORCE_DISABLE_MESH_COMPRESSION|GENERATE_TANGENT_ARRAYS|SCENE|USE_NAMED_SKIN_BINDS)\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-115788",
			"message": "EditorSceneFormatImporter.IMPORT_* constants moved into the ImportFlags enum in Godot 4.7 (C# source-incompatible)."
		},
		{
			"id": "rtl_add_image_unit_params",
			"severity": "review",
			"category": "GUI",
			"kind": "signature_change",
			"languages": ["gd", "cs"],
			"behavior": false,
			"pattern": "\\b(add_image|update_image)\\s*\\(",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-112617",
			"message": "RichTextLabel.add_image/update_image: the width_in_percent/height_in_percent params changed from bool to RichTextLabel.ImageUnit (default false->0) in Godot 4.7. Review these call sites."
		},
		{
			"id": "input_device_id_zero",
			"severity": "review",
			"category": "Input",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\.device\\s*==\\s*0\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-116274",
			"message": "Mouse/keyboard device IDs changed from 0 to InputEvent.DEVICE_ID_MOUSE/DEVICE_ID_KEYBOARD in Godot 4.7. Compare InputEvent.device against those constants instead of 0."
		},
		{
			"id": "audio_stream_player_area_mask_default",
			"severity": "review",
			"category": "Audio",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\baudio_bus_override\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-107679",
			"message": "AudioStreamPlayer default area_mask changed from 1 to 0 in Godot 4.7. If you rely on audio_bus_override with the default mask, set area_mask to layer 1 explicitly."
		},
		{
			"id": "canvasitem_line_antialiasing",
			"severity": "review",
			"category": "2D",
			"kind": "behavior",
			"languages": ["gd", "cs"],
			"behavior": true,
			"pattern": "\\bdraw_(line|polyline|multiline)\\b",
			"replacement": "",
			"auto_fixable": false,
			"gh": "GH-105122",
			"message": "CanvasItem no longer adds an antialiasing feather to lines in Godot 4.7; lines may appear thinner. Increase line width if you relied on the old behavior."
		}
	]

func _migration_lang_for_path(path: String) -> String:
	if path.ends_with(".cs"):
		return "cs"
	return "gd"

func _compile_migration_rules(rules: Array) -> Array:
	var compiled: Array = []
	for rule in rules:
		var re: RegEx = RegEx.new()
		if re.compile(str(rule.get("pattern", ""))) != OK:
			continue
		compiled.append({"rule": rule, "re": re})
	return compiled

func _register_scan_migration_compatibility(server_core: RefCounted) -> void:
	var tool_name: String = "scan_migration_compatibility"
	var description: String = "Scan project .gd/.cs for Godot-version migration issues. Results use lossless limit/offset pages backed by one revision-safe scan; plugin sources are excluded."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {
				"type": "string",
				"description": "Target Godot version to check migration against. Only '4.7' is currently supported.",
				"default": "4.7"
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"include_behavior": {
				"type": "boolean",
				"description": "Include behavioral/default-value changes (compile-clean but runtime behavior differs). Default true.",
				"default": true
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of issues to return. Default is 1000.",
				"default": 1000
			},
			"offset": {
				"type": "integer",
				"description": "Zero-based issue offset. Continue with next_offset while has_more is true.",
				"default": 0
			}
		}
	}
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {"type": "string"},
			"search_path": {"type": "string"},
			"scanned_files": {"type": "integer"},
			"must_fix_count": {"type": "integer"},
			"review_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"issues": {"type": "array"}
		}
	}
	_add_pagination_output_schema(output_schema)

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_scan_migration_compatibility"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _migration_plugin_root() -> String:
	var script: Script = get_script()
	if script == null:
		return "res://addons/godot_mcp/"
	var tools_dir: String = script.resource_path.get_base_dir()
	return tools_dir.get_base_dir() + "/"

func _migration_exclude_plugin_sources(files: Array[String]) -> Array[String]:
	var plugin_root: String = _migration_plugin_root()
	var kept: Array[String] = []
	for path in files:
		if path.begins_with(plugin_root):
			continue
		kept.append(path)
	return kept

func _tool_scan_migration_compatibility(params: Dictionary) -> Dictionary:
	var target_version: String = str(params.get("target_version", "4.7")).strip_edges()
	var rules: Array = _migration_rules(target_version)
	if rules.is_empty():
		return {"error": "Unsupported target_version: " + target_version + " (supported: 4.7)"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var include_behavior: bool = bool(params.get("include_behavior", true))
	var limit: int = int(params.get("limit", 1000))
	var offset: int = int(params.get("offset", 0))
	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"scan_migration_compatibility",
		{"target_version": target_version, "search_path": search_path,
			"include_behavior": include_behavior},
		func() -> Dictionary:
			return _scan_migration_compatibility(
				target_version, search_path, include_behavior, rules))
	return _paginate_snapshot(snapshot, "issues", limit, offset)

func _scan_migration_compatibility(target_version: String, search_path: String,
		include_behavior: bool, rules: Array) -> Dictionary:
	var files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, [".gd", ".cs"], files)
	files = _migration_exclude_plugin_sources(files)
	files.sort()

	var active_rules: Array = []
	for rule in rules:
		if bool(rule.get("behavior", false)) and not include_behavior:
			continue
		active_rules.append(rule)
	var compiled: Array = _compile_migration_rules(active_rules)

	var issues: Array = []
	var must_fix_count: int = 0
	var review_count: int = 0
	for path in files:
		var lang: String = _migration_lang_for_path(path)
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var line_no: int = 0
		while not file.eof_reached():
			line_no += 1
			var line: String = file.get_line()
			for entry in compiled:
				var rule: Dictionary = entry["rule"]
				if not (lang in rule["languages"]):
					continue
				var re: RegEx = entry["re"]
				for match_obj in re.search_all(line):
					var auto_fixable: bool = bool(rule.get("auto_fixable", false))
					var issue: Dictionary = {
						"file": path,
						"line": line_no,
						"column": match_obj.get_start() + 1,
						"rule_id": str(rule.get("id", "")),
						"severity": str(rule.get("severity", "review")),
						"category": str(rule.get("category", "")),
						"kind": str(rule.get("kind", "")),
						"language": lang,
						"matched_text": match_obj.get_string(),
						"message": str(rule.get("message", "")),
						"gh": str(rule.get("gh", "")),
						"auto_fixable": auto_fixable
					}
					if auto_fixable:
						issue["suggested_replacement"] = str(rule.get("replacement", ""))
					if issue["severity"] == "must_fix":
						must_fix_count += 1
					else:
						review_count += 1
					issues.append(issue)
		file.close()

	return {
		"target_version": target_version,
		"search_path": search_path,
		"scanned_files": files.size(),
		"must_fix_count": must_fix_count,
		"review_count": review_count,
		"total_count": issues.size(),
		"issues": issues
	}

func _register_apply_migration_fixes(server_core: RefCounted) -> void:
	var tool_name: String = "apply_migration_fixes"
	var description: String = "Apply the safe, mechanical migration rewrites (e.g. enum/identifier renames) for a target Godot release. Defaults to a dry run that previews diffs without writing files. The plugin's own source under res://addons/godot_mcp/ is excluded."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {
				"type": "string",
				"description": "Target Godot version. Only '4.7' is currently supported.",
				"default": "4.7"
			},
			"search_path": {
				"type": "string",
				"description": "Directory to scan and rewrite. Default is res://.",
				"default": "res://"
			},
			"rule_ids": {
				"type": "array",
				"description": "Optional list of rule ids to restrict the fixes to. Empty means all auto-fixable rules.",
				"items": {"type": "string"}
			},
			"dry_run": {
				"type": "boolean",
				"description": "When true (default), preview changes without writing files.",
				"default": true
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of changes to return. Default is 1000.",
				"default": 1000
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"target_version": {"type": "string"},
			"search_path": {"type": "string"},
			"dry_run": {"type": "boolean"},
			"scanned_files": {"type": "integer"},
			"files_changed": {"type": "array"},
			"change_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"changes": {"type": "array"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": false,
		"destructiveHint": false,
		"idempotentHint": false,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_apply_migration_fixes"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_apply_migration_fixes(params: Dictionary) -> Dictionary:
	var target_version: String = str(params.get("target_version", "4.7")).strip_edges()
	var all_rules: Array = _migration_rules(target_version)
	if all_rules.is_empty():
		return {"error": "Unsupported target_version: " + target_version + " (supported: 4.7)"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var dry_run: bool = bool(params.get("dry_run", true))
	var limit: int = int(params.get("limit", 1000))

	var rule_id_filter: Array = []
	for rid in params.get("rule_ids", []):
		rule_id_filter.append(str(rid))

	var fix_rules: Array = []
	for rule in all_rules:
		if not bool(rule.get("auto_fixable", false)):
			continue
		if not rule_id_filter.is_empty() and not (str(rule.get("id", "")) in rule_id_filter):
			continue
		fix_rules.append(rule)
	if fix_rules.is_empty():
		return {"error": "No auto-fixable rules selected for target_version " + target_version}

	var compiled: Array = _compile_migration_rules(fix_rules)

	var files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, [".gd", ".cs"], files)
	files = _migration_exclude_plugin_sources(files)
	files.sort()

	var changes: Array = []
	var files_changed: Array = []
	for path in files:
		var lang: String = _migration_lang_for_path(path)
		var applicable: Array = []
		for entry in compiled:
			if lang in entry["rule"]["languages"]:
				applicable.append(entry)
		if applicable.is_empty():
			continue

		var read_file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if read_file == null:
			continue
		var content: String = read_file.get_as_text()
		read_file.close()

		var lines: PackedStringArray = content.split("\n")
		var file_changed: bool = false
		for i in range(lines.size()):
			var original_line: String = lines[i]
			var new_line: String = original_line
			for entry in applicable:
				var rule: Dictionary = entry["rule"]
				var re: RegEx = entry["re"]
				if re.search(new_line) == null:
					continue
				var replaced: String = re.sub(new_line, str(rule.get("replacement", "")), true)
				if replaced != new_line:
					changes.append({
						"file": path,
						"line": i + 1,
						"rule_id": str(rule.get("id", "")),
						"gh": str(rule.get("gh", "")),
						"before": new_line,
						"after": replaced
					})
					new_line = replaced
					file_changed = true
			if new_line != original_line:
				lines[i] = new_line

		if file_changed:
			files_changed.append(path)
			if not dry_run:
				var write_file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
				if write_file == null:
					return {"error": "Failed to open file for writing: " + path}
				write_file.store_string("\n".join(lines))
				write_file.close()

	var bounded: Dictionary = PayloadUtils.truncate_list(changes, limit)
	return {
		"target_version": target_version,
		"search_path": search_path,
		"dry_run": dry_run,
		"scanned_files": files.size(),
		"files_changed": files_changed,
		"change_count": changes.size(),
		"total_count": int(bounded["total_count"]),
		"truncated": bool(bounded["truncated"]),
		"changes": bounded["items"]
	}

# ============================================================================
# find_deprecated_api_usage - scan scripts for removed/deprecated Godot 4.x APIs
# ============================================================================

# Version-agnostic table of well-known removed/deprecated Godot 4.x symbols.
# Each rule is matched against source lines with a RegEx; `engine_class` /
# `replacement_class` (when present) are cross-checked against the running
# engine's ClassDB so the report reflects the actual editor, not just a guess.
func _deprecated_api_rules() -> Array:
	return [
		{"id": "pooled_arrays", "kind": "class", "status": "removed", "pattern": "\\bPool(String|Byte|Int|Real|Vector2|Vector3|Color)Array\\b", "replacement": "Packed*Array (e.g. PackedStringArray)", "engine_class": "PoolStringArray", "replacement_class": "PackedStringArray", "since": "4.0", "message": "Pool*Array types were renamed to Packed*Array in Godot 4.0."},
		{"id": "reference_class", "kind": "class", "status": "removed", "pattern": "\\bextends\\s+Reference\\b", "replacement": "RefCounted", "engine_class": "Reference", "replacement_class": "RefCounted", "since": "4.0", "message": "Reference was renamed to RefCounted in Godot 4.0."},
		{"id": "visual_server", "kind": "class", "status": "removed", "pattern": "\\bVisualServer\\b", "replacement": "RenderingServer", "engine_class": "VisualServer", "replacement_class": "RenderingServer", "since": "4.0", "message": "VisualServer was renamed to RenderingServer in Godot 4.0."},
		{"id": "file_class", "kind": "class", "status": "removed", "pattern": "\\bextends\\s+File\\b|\\bFile\\.new\\(\\)", "replacement": "FileAccess", "engine_class": "File", "replacement_class": "FileAccess", "since": "4.0", "message": "The File class was replaced by FileAccess in Godot 4.0."},
		{"id": "directory_class", "kind": "class", "status": "removed", "pattern": "\\bDirectory\\.new\\(\\)", "replacement": "DirAccess", "engine_class": "Directory", "replacement_class": "DirAccess", "since": "4.0", "message": "The Directory class was replaced by DirAccess in Godot 4.0."},
		{"id": "yield_keyword", "kind": "keyword", "status": "removed", "pattern": "\\byield\\s*\\(", "replacement": "await", "since": "4.0", "message": "The yield() coroutine function was replaced by the await keyword in Godot 4.0."},
		{"id": "export_old_syntax", "kind": "keyword", "status": "removed", "pattern": "(^|[^@\\w])export\\s*\\(", "replacement": "@export annotation", "since": "4.0", "message": "The export(...) hint syntax was replaced by the @export annotation in Godot 4.0."},
		{"id": "onready_old_syntax", "kind": "keyword", "status": "removed", "pattern": "(^|[^@\\w])onready\\s+var\\b", "replacement": "@onready", "since": "4.0", "message": "The onready keyword was replaced by the @onready annotation in Godot 4.0."},
		{"id": "setget_keyword", "kind": "keyword", "status": "removed", "pattern": "\\bsetget\\b", "replacement": "property setters/getters (set/get on var)", "since": "4.0", "message": "The setget keyword was removed in Godot 4.0; use inline set/get on the variable."},
		{"id": "editor_hint_property", "kind": "property", "status": "removed", "pattern": "\\bEngine\\.editor_hint\\b", "replacement": "Engine.is_editor_hint()", "since": "4.0", "message": "Engine.editor_hint was replaced by Engine.is_editor_hint() in Godot 4.0."},
		{"id": "empty_method", "kind": "method", "status": "removed", "pattern": "\\.empty\\(\\)", "replacement": ".is_empty()", "since": "4.0", "message": "Container .empty() was renamed to .is_empty() in Godot 4.0."},
		{"id": "instance_method", "kind": "method", "status": "removed", "pattern": "\\.instance\\(\\)", "replacement": ".instantiate()", "since": "4.0", "message": "PackedScene.instance() was renamed to instantiate() in Godot 4.0."}
	]

func _register_find_deprecated_api_usage(server_core: RefCounted) -> void:
	var tool_name: String = "find_deprecated_api_usage"
	var description: String = "Scan scripts for removed/deprecated Godot 4.x APIs and replacements. Results use lossless limit/offset pages backed by one revision-safe scan; class/property rules are checked against ClassDB."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			},
			"languages": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Script extensions to scan (without dot). Default is ['gd', 'cs'].",
				"default": ["gd", "cs"]
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of findings to return. Default is 1000.",
				"default": 1000
			},
			"offset": {
				"type": "integer",
				"description": "Zero-based finding offset. Continue with next_offset while has_more is true.",
				"default": 0
			}
		}
	}
	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"scanned_files": {"type": "integer"},
			"rules_evaluated": {"type": "integer"},
			"finding_count": {"type": "integer"},
			"total_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"findings": {"type": "array"}
		}
	}
	_add_pagination_output_schema(output_schema)

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_find_deprecated_api_usage"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_find_deprecated_api_usage(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var languages: Array = params.get("languages", ["gd", "cs"])
	var extensions: Array[String] = []
	for language in languages:
		var ext: String = str(language).strip_edges().to_lower()
		if ext.is_empty():
			continue
		if not ext.begins_with("."):
			ext = "." + ext
		extensions.append(ext)
	if extensions.is_empty():
		extensions = [".gd", ".cs"]

	var limit: int = int(params.get("limit", 1000))
	var offset: int = int(params.get("offset", 0))
	extensions = _sorted_unique_strings(extensions)
	var snapshot: Dictionary = _get_or_compute_read_snapshot(
		"find_deprecated_api_usage",
		{"search_path": search_path, "languages": extensions},
		func() -> Dictionary: return _scan_deprecated_api_usage(search_path, extensions))
	return _paginate_snapshot(snapshot, "findings", limit, offset)

func _scan_deprecated_api_usage(search_path: String,
		extensions: Array[String]) -> Dictionary:
	var rules: Array = _deprecated_api_rules()
	var compiled: Array = []
	for rule in rules:
		var regex: RegEx = RegEx.new()
		if regex.compile(str(rule.get("pattern", ""))) != OK:
			continue
		var enriched: Dictionary = rule.duplicate()
		var engine_class: String = str(rule.get("engine_class", ""))
		if not engine_class.is_empty():
			enriched["present_in_engine"] = ClassDB.class_exists(engine_class)
		var replacement_class: String = str(rule.get("replacement_class", ""))
		if not replacement_class.is_empty():
			enriched["replacement_available"] = ClassDB.class_exists(replacement_class)
		compiled.append({"rule": enriched, "regex": regex})

	var files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, extensions, files)
	files.sort()

	var findings: Array = []
	for file_path in files:
		var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
		if not file:
			continue
		var line_number: int = 0
		while not file.eof_reached():
			var line: String = file.get_line()
			line_number += 1
			var stripped: String = line.strip_edges()
			if stripped.begins_with("#") or stripped.begins_with("//"):
				continue
			for entry in compiled:
				var regex: RegEx = entry["regex"]
				var rule: Dictionary = entry["rule"]
				for found in regex.search_all(line):
					var finding: Dictionary = {
						"file": file_path,
						"line": line_number,
						"column": found.get_start(),
						"rule_id": rule.get("id", ""),
						"kind": rule.get("kind", ""),
						"status": rule.get("status", ""),
						"symbol": found.get_string(),
						"replacement": rule.get("replacement", ""),
						"since": rule.get("since", ""),
						"message": rule.get("message", "")
					}
					if rule.has("present_in_engine"):
						finding["present_in_engine"] = rule["present_in_engine"]
					if rule.has("replacement_available"):
						finding["replacement_available"] = rule["replacement_available"]
					findings.append(finding)
		file.close()

	return {
		"search_path": search_path,
		"scanned_files": files.size(),
		"rules_evaluated": compiled.size(),
		"finding_count": findings.size(),
		"total_count": findings.size(),
		"findings": findings
	}


# ============================================================================
# detect_gdextension_addons - find native GDExtension addons (detect only)
# ============================================================================

func _register_detect_gdextension_addons(server_core: RefCounted) -> void:
	var tool_name: String = "detect_gdextension_addons"
	var description: String = "Detect native GDExtension addons by scanning for .gdextension files, report their entry symbol, compatibility_minimum and per-platform library paths (with a presence check for each .so/.dll/.dylib), and surface any SConstruct build files with suggested scons commands. Detection only; this tool never compiles anything."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {
				"type": "string",
				"description": "Directory to scan. Default is res://.",
				"default": "res://"
			}
		}
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"search_path": {"type": "string"},
			"has_native_extensions": {"type": "boolean"},
			"extension_count": {"type": "integer"},
			"extensions": {"type": "array"},
			"sconstruct_files": {"type": "array", "items": {"type": "string"}},
			"build_hint": {"type": "object"}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
						  Callable(self, "_tool_detect_gdextension_addons"),
						  output_schema, annotations,
						  "supplementary", "Project-Advanced")

func _tool_detect_gdextension_addons(params: Dictionary) -> Dictionary:
	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var search_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not search_validation["valid"]:
		return {"error": "Invalid path: " + search_validation["error"]}
	search_path = search_validation["sanitized"]

	var extension_files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, [".gdextension"], extension_files)
	extension_files.sort()

	var sconstruct_files: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, ["SConstruct"], sconstruct_files)
	sconstruct_files.sort()

	var extensions: Array = []
	for extension_path in extension_files:
		extensions.append(_describe_gdextension(extension_path))

	var has_native: bool = not extensions.is_empty()
	var build_hint: Dictionary = {
		"detected_sconstruct": not sconstruct_files.is_empty(),
		"note": "Detection only; this tool does not run any build. Compile manually with the godot-cpp toolchain.",
		"commands": [
			"scons platform=<platform> target=template_debug",
			"scons platform=<platform> target=template_release"
		],
		"docs": "https://docs.godotengine.org/en/latest/engine_details/development/compiling/"
	}

	return {
		"search_path": search_path,
		"has_native_extensions": has_native,
		"extension_count": extensions.size(),
		"extensions": extensions,
		"sconstruct_files": sconstruct_files,
		"build_hint": build_hint
	}

func _describe_gdextension(extension_path: String) -> Dictionary:
	var config: ConfigFile = ConfigFile.new()
	if config.load(extension_path) != OK:
		return {"path": extension_path, "error": "Failed to parse .gdextension file"}

	var libraries: Array = []
	var missing: int = 0
	if config.has_section("libraries"):
		var keys: PackedStringArray = config.get_section_keys("libraries")
		for tag in keys:
			var lib_path: String = str(config.get_value("libraries", tag, ""))
			var resolved: String = lib_path
			if resolved.begins_with("res://"):
				resolved = ProjectSettings.globalize_path(resolved)
			var exists: bool = FileAccess.file_exists(lib_path) or FileAccess.file_exists(resolved)
			if not exists:
				missing += 1
			libraries.append({"target": tag, "path": lib_path, "exists": exists})

	var dependencies: Array = []
	if config.has_section("dependencies"):
		for tag in config.get_section_keys("dependencies"):
			dependencies.append({"target": tag, "path": str(config.get_value("dependencies", tag, ""))})

	return {
		"path": extension_path,
		"entry_symbol": str(config.get_value("configuration", "entry_symbol", "")),
		"compatibility_minimum": str(config.get_value("configuration", "compatibility_minimum", "")),
		"reloadable": bool(config.get_value("configuration", "reloadable", false)),
		"libraries": libraries,
		"library_count": libraries.size(),
		"missing_library_count": missing,
		"all_libraries_present": libraries.size() > 0 and missing == 0,
		"dependencies": dependencies
	}
