class_name ProjectContextTools
extends RefCounted

# 面向任务的项目上下文（M4 首版）：把一句自然语言修改目标
# （"给玩家加冲刺" / "add a dash to the player"）装配成有界的上下文包——
# 入口脚本、引用它的场景、相关输入动作、脚本引用的资源、受影响的测试，
# 每项都带来源说明与内容指纹，供 AI 定位"该改哪里、关联什么"。
#
# 设计约束（路线图 M4）：
# - 确定性筛选：关键词 → 名称/符号/路径匹配，不引入向量库或语义猜测；
#   中文目标经小型种子词表映射到 ASCII 检索词（词表可随语料扩充）。
# - 有界输出：每个桶有 max_items_per_bucket 预算与 truncated 标记，
#   并给出精确的后续读取入口（follow_up），避免一次读取整个项目。
# - 可解释：keywords 桶公开 ASCII 提取结果与中文映射，why 字段说明
#   每个条目因什么而入选；读不到/匹配不到都如实说明，不编造依赖。
# - 复用现有约定：资源收集沿用 ProjectToolsNative._collect_resources 的
#   范围口径（默认跳过 addons/ 等工具目录，include_tooling 显式打开）。

# ============================================================================
# 中文 → ASCII 检索词种子表（常见游戏开发词汇；按需扩充，键为子串匹配）
# ============================================================================
const ZH_TERM_MAP: Dictionary = {
	"冲刺": ["dash"],
	"跳跃": ["jump"],
	"移动": ["move", "movement"],
	"暂停": ["pause"],
	"恢复": ["resume"],
	"存档": ["save"],
	"读档": ["load", "save"],
	"分数": ["score"],
	"计分": ["score"],
	"金币": ["coin"],
	"收集": ["collect"],
	"敌人": ["enemy"],
	"射击": ["shoot", "fire"],
	"血量": ["health"],
	"生命": ["health", "life"],
	"速度": ["speed", "velocity"],
	"玩家": ["player"],
	"角色": ["character"],
	"菜单": ["menu"],
	"按钮": ["button"],
	"界面": ["ui"],
	"关卡": ["level"],
	"场景": ["scene"],
	"相机": ["camera"],
	"动画": ["anim", "animation"],
	"音效": ["audio", "sound"],
	"音乐": ["music"],
	"背包": ["inventory"],
	"物品": ["item"],
	"胜利": ["win"],
	"重力": ["gravity"],
	"碰撞": ["collision"],
	"输入": ["input"],
}

## 目标句中的英语虚词/制作动词：不作为检索词
const ASCII_STOPWORDS: Array = [
	"the", "a", "an", "to", "of", "and", "or", "with", "for", "in", "on", "into",
	"add", "adding", "make", "making", "create", "change", "update", "modify",
	"give", "existing", "current", "this", "that", "new", "some", "please",
]

## 扫描上限：超过时置 truncated 并停止（防止在大项目上失控读取）
const MAX_SCRIPT_SCAN: int = 2000
const MAX_SCENE_SCAN: int = 4000
const MAX_TEST_SCAN: int = 2000

var _editor_interface: EditorInterface = null

func initialize(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func register_tools(server_core: RefCounted) -> void:
	_register_gather_task_context(server_core)

# ============================================================================
# gather_task_context
# ============================================================================

func _register_gather_task_context(server_core: RefCounted) -> void:
	var tool_name: String = "gather_task_context"
	var description: String = "Assemble a bounded, sourced task context for a natural-language modification goal (EN/ZH, e.g. 'add a dash to the player' / '给玩家加冲刺'): entry scripts (name/symbol keyword matches with content hashes), scenes referencing them, related InputMap actions, resources preloaded by those scripts, and tests referencing them. Deterministic keyword filtering with an explainable zh->en term map; every bucket is budgeted with truncated flags and exact follow-up reads. Read-only."

	var input_schema: Dictionary = {
		"type": "object",
		"properties": {
			"goal": {
				"type": "string",
				"description": "The modification goal in natural language (English or Chinese)."
			},
			"search_path": {
				"type": "string",
				"description": "Directory root to scan. Default res://.",
				"default": "res://"
			},
			"max_items_per_bucket": {
				"type": "integer",
				"description": "Budget per context bucket. Default 5.",
				"default": 5
			},
			"include_tooling": {
				"type": "boolean",
				"description": "Also scan addons/ and test/ internals. Default false.",
				"default": false
			}
		},
		"required": ["goal"]
	}

	var output_schema: Dictionary = {
		"type": "object",
		"properties": {
			"goal": {"type": "string"},
			"keywords": {"type": "object", "description": "ascii terms + zh->en mappings actually used"},
			"entry_scripts": {"type": "array", "items": {"type": "object"}},
			"referencing_scenes": {"type": "array", "items": {"type": "object"}},
			"input_actions": {"type": "array", "items": {"type": "object"}},
			"related_resources": {"type": "array", "items": {"type": "object"}},
			"affected_tests": {"type": "array", "items": {"type": "object"}},
			"truncated": {"type": "object"},
			"follow_up": {"type": "array", "items": {"type": "string"}},
			"notes": {"type": "array", "items": {"type": "string"}}
		}
	}

	var annotations: Dictionary = {
		"readOnlyHint": true,
		"destructiveHint": false,
		"idempotentHint": true,
		"openWorldHint": false
	}

	server_core.register_tool(tool_name, description, input_schema,
		Callable(self, "_tool_gather_task_context"),
		output_schema, annotations,
		"supplementary", "Project-Advanced")

func _tool_gather_task_context(params: Dictionary) -> Dictionary:
	var goal: String = str(params.get("goal", "")).strip_edges()
	if goal.is_empty():
		return {"error": "Missing required parameter: goal"}

	var search_path: String = str(params.get("search_path", "res://")).strip_edges()
	var path_validation: Dictionary = PathValidator.validate_directory_path(search_path)
	if not path_validation["valid"]:
		return {"error": "Invalid path: " + path_validation["error"]}
	search_path = path_validation["sanitized"]

	var max_items: int = clampi(int(params.get("max_items_per_bucket", 5)), 1, 20)
	var include_tooling: bool = bool(params.get("include_tooling", false))

	# —— 关键词：ASCII 词 + 中文映射（全部可解释、可复现） ——
	var keywords: Dictionary = _extract_keywords(goal)
	var ascii_terms: Array = keywords["ascii"]
	var zh_mappings: Dictionary = keywords["zh_mappings"]
	var terms: Array = keywords["terms"]
	var notes: Array = []
	if terms.is_empty():
		notes.append("No usable search term was extracted from the goal; buckets will be empty. Rephrase with concrete names (e.g. 'dash', 'player', '冲刺').")
		return {
			"goal": goal,
			"keywords": keywords,
			"entry_scripts": [],
			"referencing_scenes": [],
			"input_actions": [],
			"related_resources": [],
			"affected_tests": [],
			"truncated": {},
			"follow_up": [],
			"notes": notes,
		}

	# —— 收集脚本（沿用 _collect_resources 的范围口径） ——
	var script_paths: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, [".gd", ".cs"], script_paths,
		false, include_tooling)
	var scripts_scanned: int = script_paths.size()
	var scripts_truncated: bool = false
	if script_paths.size() > MAX_SCRIPT_SCAN:
		script_paths = script_paths.slice(0, MAX_SCRIPT_SCAN)
		scripts_truncated = true

	# —— 入口脚本：文件名命中 > 符号命中，命中词多者优先（同级按路径排序） ——
	var entry_scripts: Array = []
	var entry_by_path: Dictionary = {}
	for script_path in script_paths:
		var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
		if file == null:
			continue
		var content: String = file.get_as_text()
		file.close()
		var base_name: String = String(script_path).get_file().get_basename().to_lower()
		var name_hits: Array = _matching_terms(base_name, terms)
		var symbols: Dictionary = _index_symbols(content)
		var symbol_hits: Dictionary = {}
		for symbol_name in symbols.keys():
			for hit in _matching_terms(symbol_name.to_lower(), terms):
				symbol_hits[symbol_name] = hit
		if name_hits.is_empty() and symbol_hits.is_empty():
			continue
		entry_by_path[String(script_path)] = {
			"path": String(script_path),
			"name_keyword_matches": name_hits,
			"symbol_matches": symbol_hits.keys(),
			"rank": (2 if not name_hits.is_empty() else 0) + symbol_hits.size(),
			"content_hash": content.sha256_text(),
			"line_count": content.split("\n").size(),
			"symbols": symbols,
		}
	entry_scripts = _top_ranked(entry_by_path, max_items)
	var entry_truncated: bool = entry_by_path.size() > entry_scripts.size()

	# —— 引用入口脚本的场景（ext_resource 路径文本匹配） ——
	var scene_paths: Array[String] = []
	ProjectToolsNative._collect_resources(search_path, [".tscn"], scene_paths,
		false, include_tooling)
	var scenes_scanned: int = scene_paths.size()
	var scenes_truncated: bool = false
	if scene_paths.size() > MAX_SCENE_SCAN:
		scene_paths = scene_paths.slice(0, MAX_SCENE_SCAN)
		scenes_truncated = true
	var entry_paths: Array = []
	for entry in entry_scripts:
		entry_paths.append(String(entry["path"]))
	var referencing_scenes: Array = _find_referencing_scenes(scene_paths, entry_paths, max_items)

	# —— 相关输入动作（ProjectSettings InputMap，动作名命中检索词） ——
	var input_actions: Array = []
	for action_entry in _project_input_action_names():
		var action_name: String = String(action_entry).to_lower()
		var hits: Array = _matching_terms(action_name, terms)
		if not hits.is_empty():
			input_actions.append({"action": String(action_entry), "keyword_matches": hits})
		if input_actions.size() >= max_items:
			break

	# —— 入口脚本 preload/load 的资源 ——
	var related_resources: Array = []
	var resource_seen: Dictionary = {}
	for entry in entry_scripts:
		var entry_path: String = String(entry["path"])
		var script_file: FileAccess = FileAccess.open(entry_path, FileAccess.READ)
		if script_file == null:
			continue
		var content: String = script_file.get_as_text()
		script_file.close()
		for res_path in _preload_paths(content):
			if resource_seen.has(res_path):
				continue
			resource_seen[res_path] = true
			related_resources.append({
				"path": res_path,
				"referenced_from": entry_path,
				"exists": FileAccess.file_exists(res_path),
			})
			if related_resources.size() >= max_items:
				break
		if related_resources.size() >= max_items:
			break

	# —— 受影响的测试（测试文件名或内容引用入口脚本名） ——
	var test_paths: Array[String] = []
	ProjectToolsNative._collect_resources("res://test", [".gd", ".py"], test_paths,
		false, true)
	var tests_scanned: int = test_paths.size()
	var tests_truncated: bool = false
	if test_paths.size() > MAX_TEST_SCAN:
		test_paths = test_paths.slice(0, MAX_TEST_SCAN)
		tests_truncated = true
	var affected_tests: Array = _find_affected_tests(test_paths, entry_paths, max_items)

	# —— 后续读取入口（确定性、可执行） ——
	var follow_up: Array = []
	for entry in entry_scripts.slice(0, 2):
		follow_up.append("read_script %s (expected_content_hash=%s pins the version you read)" % [entry["path"], entry["content_hash"]])
	for scene in referencing_scenes.slice(0, 1):
		follow_up.append("get_scene_structure %s" % scene["path"])
	if not entry_scripts.is_empty():
		follow_up.append("find_script_symbol_references for the symbols you plan to change before editing")
		# 本工具的桶是有界候选摘要；完整传递影响（含嵌套场景链与动态 load
		# 疑点）必须走索引化的 query_change_impact —— 扫描上限截断时同样
		# 只有它能把结果续查完整。
		var impact_targets: Array = []
		for entry in entry_scripts:
			impact_targets.append(String(entry["path"]))
		follow_up.append("query_change_impact {\"target_paths\": %s} for the complete transitive impact set (index-backed, no scan cap; page with limit/offset)" % JSON.stringify(impact_targets))

	var result: Dictionary = {
		"goal": goal,
		"keywords": keywords,
		"entry_scripts": entry_scripts,
		"referencing_scenes": referencing_scenes,
		"input_actions": input_actions,
		"related_resources": related_resources,
		"affected_tests": affected_tests,
		"truncated": {
			"scripts_scanned": scripts_truncated,
			"entry_scripts": entry_truncated,
			"scenes_scanned": scenes_truncated,
			"referencing_scenes": referencing_scenes.is_empty() and not entry_scripts.is_empty() and scenes_scanned > 0,
			"tests_scanned": tests_truncated,
		},
		"follow_up": follow_up,
		"notes": notes,
	}
	if entry_scripts.is_empty():
		result["notes"].append("No script matched the extracted terms; if the goal names a concept rather than code, use search_tools/list_project_global_classes to discover the right entry first.")
	return result

# ============================================================================
# 关键词提取（确定性）
# ============================================================================

## ASCII 词直接用；中文经种子表映射；terms = 去重后的全部检索词。
static func _extract_keywords(goal: String) -> Dictionary:
	var ascii_regex: RegEx = RegEx.new()
	ascii_regex.compile("[A-Za-z_][A-Za-z0-9_]+")
	var ascii_terms: Array = []
	for match_result in ascii_regex.search_all(goal):
		var word: String = String(match_result.get_string()).to_lower()
		if word in ASCII_STOPWORDS or word in ascii_terms:
			continue
		if word.length() < 2:
			continue
		if word.is_valid_int():
			continue
		ascii_terms.append(word)

	var zh_mappings: Dictionary = {}
	for zh_key in ZH_TERM_MAP.keys():
		if goal.contains(zh_key):
			zh_mappings[zh_key] = ZH_TERM_MAP[zh_key]

	var terms: Array = ascii_terms.duplicate()
	for mapped in zh_mappings.values():
		for term_value in mapped:
			var term: String = String(term_value)
			if not terms.has(term):
				terms.append(term)
	return {"ascii": ascii_terms, "zh_mappings": zh_mappings, "terms": terms}

static func _matching_terms(haystack_lower: String, terms: Array) -> Array:
	var hits: Array = []
	for term_value in terms:
		var term: String = String(term_value)
		if term.length() < 2:
			continue
		if haystack_lower.contains(term):
			hits.append(term)
	return hits

# ============================================================================
# 轻量符号索引（只取声明名，供关键词匹配；不做完整语义分析）
# ============================================================================

static func _index_symbols(content: String) -> Dictionary:
	var symbols: Dictionary = {}
	var declaration_regex: RegEx = RegEx.new()
	# (?m)：Godot RegEx 的 ^ 默认只匹配主题串开头，必须显式开启多行模式
	declaration_regex.compile("(?m)^[\\t ]*(?:@export[^\\n]*\\s+)?(func|var|const|signal)\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for match_result in declaration_regex.search_all(content):
		var kind: String = match_result.get_string(1)
		var symbol_name: String = match_result.get_string(2)
		if symbol_name.begins_with("_") and kind != "func":
			continue
		symbols[symbol_name] = kind
	return symbols

# ============================================================================
# 场景引用 / 资源引用 / 测试影响
# ============================================================================

static func _find_referencing_scenes(scene_paths: Array[String], entry_paths: Array,
		max_items: int) -> Array:
	if entry_paths.is_empty():
		return []
	# 完整 res:// 路径 + UID 双匹配：场景 ext_resource 的 path="res://<完整路径>"
	# 才算引用。文件名子串匹配会让不同目录的同名脚本（actors/player.gd vs
	# ui/player.gd）互相混淆——大型 2D 审计（2026-09-19）确认的第一缺口。
	var entry_uids: Array = []
	for entry_value in entry_paths:
		var uid: String = ResourceUID.path_to_uid(String(entry_value))
		if uid.begins_with("uid://"):
			entry_uids.append(uid)
	var matches: Array = []
	for scene_path in scene_paths:
		if matches.size() >= max_items:
			break
		var file: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
		if file == null:
			continue
		var content: String = file.get_as_text()
		file.close()
		var referenced: Array = []
		for entry_value in entry_paths:
			if content.contains(String(entry_value)):
				referenced.append(String(entry_value))
				continue
			for uid in entry_uids:
				if content.contains(String(uid)):
					referenced.append(String(entry_value))
					break
		if referenced.is_empty():
			continue
		matches.append({
			"path": String(scene_path),
			"references_scripts": referenced,
			"match": "exact_path_or_uid",
		})
	return matches

static func _preload_paths(content: String) -> Array:
	var paths: Array = []
	var preload_regex: RegEx = RegEx.new()
	preload_regex.compile("(?:preload|load)\\(\\s*\"(res://[^\"]+)\"")
	for match_result in preload_regex.search_all(content):
		var res_path: String = match_result.get_string(1)
		if not paths.has(res_path):
			paths.append(res_path)
	return paths

static func _find_affected_tests(test_paths: Array[String], entry_paths: Array,
		max_items: int) -> Array:
	if entry_paths.is_empty():
		return []
	var base_names: Array = []
	for entry_value in entry_paths:
		base_names.append(String(entry_value).get_file().get_basename().to_lower())
	var matches: Array = []
	for test_path in test_paths:
		if matches.size() >= max_items:
			break
		var file_name: String = String(test_path).get_file().get_basename().to_lower()
		var name_hit: bool = false
		for base_name in base_names:
			if file_name.contains(base_name):
				name_hit = true
				break
		if name_hit:
			matches.append({"path": String(test_path), "why": "test file name references an entry script"})
			continue
		var file: FileAccess = FileAccess.open(test_path, FileAccess.READ)
		if file == null:
			continue
		var content: String = file.get_as_text().to_lower()
		file.close()
		var content_hit: bool = false
		for base_name in base_names:
			if content.contains(base_name):
				content_hit = true
				break
		if content_hit:
			matches.append({"path": String(test_path), "why": "test content references an entry script"})
	return matches

static func _project_input_action_names() -> Array:
	var names: Array = []
	for setting in ProjectSettings.get_property_list():
		var name: String = String(setting.get("name", ""))
		if name.begins_with("input/"):
			names.append(name.trim_prefix("input/"))
	return names

# ============================================================================
# 预算内排序（确定性：rank 降序、同 rank 按路径字典序）
# ============================================================================

static func _top_ranked(by_path: Dictionary, max_items: int) -> Array:
	var ranked: Array = by_path.values()
	ranked.sort_custom(func(a, b) -> bool:
		var rank_a: int = int(a["rank"])
		var rank_b: int = int(b["rank"])
		if rank_a != rank_b:
			return rank_a > rank_b
		return String(a["path"]) < String(b["path"])
	)
	if ranked.size() > max_items:
		ranked = ranked.slice(0, max_items)
	for entry in ranked:
		entry.erase("rank")
	return ranked
