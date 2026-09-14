extends RefCounted
## Lightweight intent-to-workflow router.
##
## The router never copies tool schemas and never calls a model, embedding API, or
## network service. It scans the small registered catalog once, precomputes compact
## name signatures, then groups selected names into inspect / execute / verify
## stages. Every non-meta tool participates in the adaptive index, while a small
## curated seed table improves common game workflows. High-confidence action/object
## signatures run before a fallback ranked by new semantic evidence, coverage and
## estimated schema cost, keeping the enabled surface useful and small.

const DEFAULT_TOOL_BUDGET: int = 8
const MAX_TOOL_BUDGET: int = 10
const ROUTE_CACHE_MAX: int = 64
const DEFAULT_TOOL_SCHEMA_TOKENS: int = 128
const TOOL_COUNT_TOKEN_PENALTY: int = 32
const MIN_CURATED_SCORE: int = 40
const SIGNATURE_TOOL_LIMIT: int = 6
const SIGNATURE_MIN_MATCHES: int = 2
const SIGNATURE_MIN_RATIO_PERCENT: int = 60
const MIN_FALLBACK_NEW_SCORE: int = 60

var _indexed_revision: int = -1
var _indexed_tools: Array = []
var _indexed_by_name: Dictionary = {}
var _indexed_exact_by_intent: Dictionary = {}
var _indexed_full_load_schema_tokens: int = 0
var _route_cache: Dictionary = {}
var _route_lru: Array[String] = []
var _sorted_alias_keys: Array = []
var _index_builds: int = 0
var _route_computations: int = 0
var _route_cache_hits: int = 0
var _route_cache_misses: int = 0
var _route_cache_evictions: int = 0
var _curated_index: Array = []

const INTENT_ALIASES: Dictionary = {
	"场景": ["scene"], "节点": ["node"], "脚本": ["script"],
	"调试": ["debug", "runtime"], "运行时": ["runtime"], "运行": ["run", "runtime"],
	"信息": ["info", "status", "details"], "状态": ["state", "status", "info"],
	"动画树": ["animation", "tree"], "动画": ["animation"], "音频": ["audio"],
	"输入动作": ["input", "action", "upsert"], "输入": ["input"],
	"导出": ["export"], "资源": ["resource", "asset"], "素材": ["asset", "resource"],
	"测试": ["test", "verify"], "验证": ["verify", "assert", "test", "validate"],
	"截图": ["screenshot"], "着色器": ["shader"], "瓦片": ["tile", "tilemap", "tileset"],
	"信号": ["signal"], "本地化": ["localization"], "翻译": ["translation", "localization"],
	"性能": ["performance"], "项目": ["project"], "界面": ["ui", "control", "theme", "node"],
	"二维": ["2d"], "三维": ["3d"], "创建": ["create", "add"],
	"删除": ["delete", "remove"], "修改": ["update", "modify", "set"],
	"读取": ["get", "read", "list", "inspect"], "游戏": ["game", "runtime"],
	"角色": ["character", "player", "controller"], "控制器": ["controller", "input"],
	"玩法": ["gameplay", "mechanic"], "功能": ["feature", "gameplay"],
	"错误": ["error", "debug"], "修复": ["fix", "debug", "modify"],
	"发布": ["release", "export"], "关卡": ["level", "scene", "tilemap"],
	"制作": ["create", "build"], "生成": ["generate", "create"],
	"挂载": ["attach"], "挂到": ["attach"], "保存": ["save"],
	"检查": ["inspect", "get", "validate"], "确认": ["verify", "assert"],
	"配置": ["configure", "set"], "设置": ["set", "configure"],
	"调整": ["update", "set"], "默认": ["default"], "控件": ["control", "ui"],
	"锚点": ["anchor"], "执行": ["run"], "回归": ["regression", "baseline"],
	"贴图": ["texture", "asset"], "导入": ["import", "reimport"],
	"引用": ["reference", "usage"], "未使用": ["unused"],
	"启用": ["enable", "active", "set"], "切换": ["travel", "set"],
	"总线": ["bus"], "碰撞": ["collision"], "多边形": ["polygon"],
	"绘制": ["paint", "set"], "单元": ["cell"], "断点": ["breakpoint"],
	"计算": ["evaluate"], "局部": ["local"], "变量": ["variable"],
	"继续": ["continue"], "等待": ["wait", "await"], "帧率": ["fps", "performance"],
	"内存": ["memory", "performance"], "趋势": ["trend"],
	"采集": ["capture", "get", "snapshot", "metrics"],
	"预算": ["budget"], "分析器": ["profiler"], "冒烟": ["smoke", "test"],
	"安装包": ["android", "export"], "产物": ["artifact", "export", "smoke"],
	"启动": ["launch", "run"], "缺失": ["missing"], "循环": ["cyclic"],
	"反向": ["reverse"], "递增": ["bump"], "自动加载": ["autoload"],
	"发光": ["shader", "parameter"], "强度": ["parameter"],
	"损坏": ["broken", "error"], "重新": ["reimport", "reload"],
	"编辑器": ["editor"], "日志": ["log", "output"], "表达式": ["expression"],
	"视觉": ["visual"], "基准": ["baseline"], "比较": ["compare", "verify"],
	"搜索": ["search"], "文件": ["file"], "图层": ["layer"],
	"打包": ["pack", "package"], "动作": ["action"], "注册": ["upsert", "add"],
	"连接": ["connect"], "试玩": ["play", "verify"], "健康": ["health"],
	"审计": ["audit"], "数值": ["value", "condition"], "检测": ["detect", "scan"],
	"版本": ["version"], "pck": ["pck"], "uid": ["uid"]
}

## Exact-token equivalents keep natural phrasing compact without adding schemas,
## embeddings or a second catalog. They are expanded once per query and feed both
## semantic scoring and the high-confidence tool-name signature matcher.
const TOKEN_ALIASES: Dictionary = {
	"add": ["create", "set"], "apply": ["set"], "approved": ["baseline"],
	"build": ["create"], "capture": ["get"],
	"check": ["inspect", "get", "validate", "verify"],
	"collect": ["get"], "compare": ["verify"], "configure": ["set"],
	"confirm": ["verify", "assert"], "controller": ["script", "input"],
	"debugger": ["debug"], "enforce": ["assert"], "enable": ["set", "active"],
	"fail": ["assert"], "fix": ["apply", "modify", "update"], "golden": ["baseline"],
	"image": ["screenshot"], "inspect": ["get", "list", "read"],
	"interface": ["node", "control"],
	"instance": ["instantiate"], "instancing": ["instantiate"],
	"launch": ["run"], "make": ["create"], "measure": ["get", "performance"],
	"localized": ["localization", "translation", "manage"],
	"localize": ["localization", "translation", "manage"],
	"localization": ["manage"], "menu": ["node", "control"],
	"multiple": ["batch"], "panel": ["node", "control"],
	"several": ["batch"],
	"paint": ["set", "cell"], "preview": ["inspect"], "read": ["get"],
	"reference": ["usage"], "references": ["reference", "usage"],
	"reject": ["assert"], "repair": ["apply", "fix", "modify", "update"],
	"restyle": ["theme", "set"], "review": ["inspect"], "run": ["play"],
	"scan": ["find"], "switch": ["travel", "set"], "test": ["verify", "assert"],
	"tilemaplayer": ["tilemap", "layer"], "tileset": ["resource"], "value": ["condition"],
	"verify": ["validate", "assert"], "wire": ["attach", "instantiate"]
}

const TOOL_SIGNATURE_STOP_WORDS: Array[String] = ["and", "or", "no"]
const TOOL_SIGNATURE_GENERIC_TERMS: Array[String] = [
	"add", "assert", "batch", "create", "debug", "debugger", "detect", "find",
	"active", "capture", "get", "inspect", "list", "modify", "node", "play",
	"project", "read", "resource", "run", "runtime", "scan", "scene", "script",
	"set", "update", "validate", "verify"
]
const ACTION_QUERY_MARKERS: Dictionary = {
	"add": [" add ", "添加", "加入", "注册"],
	"assert": [" assert ", "confirm", "确认", "门禁"],
	"attach": [" attach ", "wire", "挂载", "挂到"],
	"configure": [" configure ", "配置"],
	"connect": [" connect ", "连接"],
	"create": [" create ", " build ", " make ", "创建", "制作", "生成"],
	"detect": [" detect ", "检测"],
	"evaluate": [" evaluate ", "计算"],
	"find": [" find ", "查找", "搜索"],
	"get": [" get ", " read ", " capture ", " collect ", "读取", "获取", "采集"],
	"inspect": [" inspect ", "检查", "审计"],
	"insert": [" insert ", "插入"],
	"list": [" list ", "列出"],
	"modify": [" modify ", "修改", "修复"],
	"pack": [" pack ", "打包"],
	"play": [" play ", "试玩", "播放"],
	"run": [" run ", " launch ", "运行", "执行", "启动"],
	"save": [" save ", "保存"],
	"scan": [" scan ", "扫描"],
	"set": [" set ", " apply ", " add ", " restyle ", "设置", "配置", "修改", "调整"],
	"toggle": [" toggle ", "开启", "关闭"],
	"travel": [" travel ", "切换"],
	"update": [" update ", " adjust ", "更新", "调整"],
	"upsert": [" upsert ", "输入动作", "注册"],
	"validate": [" validate ", "验证", "校验"],
	"verify": [" verify ", " test ", "验证", "测试"]
}
const DIRECT_TERM_MARKERS: Dictionary = {
	"animation": [" animation ", "动画"], "audio": [" audio ", "音频"],
	"bus": [" bus ", " buses ", "总线"], "cell": [" cell ", " cells ", "单元"],
	"export": [" export ", "导出"], "input": [" input ", "输入"],
	"node": [" node ", " nodes ", "节点"], "parameter": [" parameter ", " parameters ", "参数", "强度"],
	"performance": [" performance ", " fps ", "frame performance", "性能", "帧率"],
	"resource": [" resource ", " resources ", "资源"], "runtime": [" runtime ", "运行时"],
	"scene": [" scene ", " scenes ", "场景"], "script": [" script ", " scripts ", "脚本"],
	"shader": [" shader ", "着色器"], "signal": [" signal ", " signals ", "信号"],
	"theme": [" theme ", " restyle ", "主题"],
	"tilemap": [" tilemap ", " tilemaplayer ", "瓦片地图"],
	"tileset": [" tileset ", "瓦片集"],
	"usage": [" usage ", " usages ", " reference ", " references ", "引用"]
}

const WORKFLOW_STOP_WORDS: Array[String] = [
	"a", "an", "and", "as", "at", "by", "for", "from", "in", "into",
	"goal", "it", "its", "of", "on", "please", "sample", "task", "that",
	"the", "their", "them", "then", "this", "to", "use", "with",
	"workflow", "任务", "工作流", "目标", "示例"
]

## Only tool names are stored here. Schemas and descriptions remain in the
## canonical MCP registry. The adaptive fallback still indexes every atomic tool.
const CURATED_WORKFLOWS: Array = [
	{
		"id": "gameplay_feature",
		"title": "Build gameplay feature",
		"keywords": ["game", "gameplay", "feature", "mechanic", "2d", "3d", "character", "player", "controller", "游戏", "玩法", "功能", "角色"],
		"tools": ["get_project_info", "get_current_scene", "create_scene", "create_node", "create_script", "attach_script", "modify_script", "validate_script", "run_project", "assert_no_runtime_errors"]
	},
	{
		"id": "ui_screen",
		"title": "Build and verify UI",
		"keywords": ["ui", "interface", "screen", "menu", "control", "theme", "界面", "菜单", "主题"],
		"tools": ["get_scene_structure", "create_theme", "set_default_theme", "create_node", "set_anchor_preset", "set_theme_item", "run_project", "assert_visual_baseline"]
	},
	{
		"id": "asset_pipeline",
		"title": "Create and import assets",
		"keywords": ["asset", "resource", "texture", "sprite", "gltf", "model", "素材", "资源", "贴图", "模型"],
		"tools": ["list_project_resources", "generate_asset", "generate_3d_asset", "slice_sprite_sheet", "inspect_gltf_asset", "reimport_resources", "get_import_status", "audit_project_health"]
	},
	{
		"id": "animation_audio",
		"title": "Build animation and audio behavior",
		"keywords": ["animation", "audio", "sound", "music", "timeline", "动画", "音频", "音乐"],
		"tools": ["create_animation", "insert_animation_keys", "list_runtime_animations", "play_runtime_animation", "get_runtime_animation_state", "list_runtime_audio_buses", "get_runtime_audio_bus", "play_and_verify"]
	},
	{
		"id": "level_tileset",
		"title": "Build a level or tilemap",
		"keywords": ["level", "tile", "tilemap", "tileset", "terrain", "collision", "关卡", "瓦片", "地形", "碰撞"],
		"tools": ["create_scene", "create_tileset", "configure_tileset_layers", "set_tile_collision_polygon", "set_tile_terrain", "set_tilemap_layer_cells", "get_tilemap_layer_cells", "play_and_verify"]
	},
	{
		"id": "runtime_debug",
		"title": "Diagnose and fix runtime behavior",
		"keywords": ["debug", "runtime", "error", "crash", "breakpoint", "stack", "调试", "运行时", "错误", "崩溃"],
		"tools": ["get_editor_logs", "install_runtime_probe", "get_runtime_scene_tree", "inspect_runtime_node", "get_debug_stack_frames", "evaluate_runtime_expression", "play_and_verify", "assert_no_runtime_errors"]
	},
	{
		"id": "performance_optimization",
		"title": "Measure and optimize performance",
		"keywords": ["performance", "fps", "memory", "frame", "profiler", "optimize", "性能", "帧率", "内存", "优化"],
		"tools": ["get_performance_metrics", "get_runtime_performance_snapshot", "get_runtime_memory_trend", "toggle_debugger_profiler", "assert_performance_budget", "play_and_verify"]
	},
	{
		"id": "quality_assurance",
		"title": "Run automated verification",
		"keywords": ["test", "verify", "quality", "regression", "baseline", "assert", "测试", "验证", "回归"],
		"tools": ["list_project_tests", "run_project_tests", "verify_scripts", "play_and_verify", "assert_no_runtime_errors", "assert_performance_budget", "assert_visual_baseline"]
	},
	{
		"id": "localization",
		"title": "Localize a game",
		"keywords": ["localization", "translation", "locale", "language", "本地化", "翻译", "语言"],
		"tools": ["get_project_structure", "search_in_files", "manage_localization", "run_project", "assert_visual_baseline"]
	},
	{
		"id": "release_export",
		"title": "Prepare and verify a release",
		"keywords": ["release", "export", "build", "package", "android", "pck", "发布", "导出", "打包"],
		"tools": ["bump_version", "list_export_presets", "validate_export_preset", "configure_android_export", "run_export", "smoke_test_export", "pack_pck"]
	},
	{
		"id": "project_health",
		"title": "Audit and repair project health",
		"keywords": ["audit", "health", "dependency", "migration", "unused", "broken", "项目", "健康", "依赖", "迁移"],
		"tools": ["audit_project_health", "scan_missing_resource_dependencies", "scan_cyclic_resource_dependencies", "find_deprecated_api_usage", "detect_broken_scripts", "list_unused_resources", "apply_migration_fixes"]
	}
]

const READ_PREFIXES: Array[String] = [
	"analyze_", "await_", "detect_", "find_", "get_", "inspect_", "list_", "read_", "scan_", "search_"
]
const VERIFY_PREFIXES: Array[String] = ["assert_", "compare_", "smoke_test_", "validate_", "verify_"]
const VERIFY_TOOL_NAMES: Array[String] = ["audit_project_health", "play_and_verify", "run_project_test", "run_project_tests"]
const READ_ACTION_TERMS: Dictionary = {
	"detect": true, "find": true, "get": true, "inspect": true,
	"list": true, "read": true, "scan": true, "search": true
}

func normalize_search_text(value: String) -> String:
	var normalized: String = value.strip_edges().to_lower().replace("_", " ").replace("-", " ").replace("\t", " ").replace("\n", " ")
	for separator in [",", ".", ";", ":", "!", "?", "(", ")", "[", "]", "{", "}", "/", "\\", "，", "。", "；", "：", "！", "？", "、"]:
		normalized = normalized.replace(separator, " ")
	while normalized.contains("  "):
		normalized = normalized.replace("  ", " ")
	return normalized

func _append_unique(values: Array[String], value: String) -> void:
	if not value.is_empty() and value not in values:
		values.append(value)

func _word_forms(word: String) -> Array[String]:
	var forms: Array[String] = []
	_append_unique(forms, word)
	if word.length() > 4 and word.ends_with("ies"):
		_append_unique(forms, word.left(word.length() - 3) + "y")
	elif word.length() > 4 and word.ends_with("ing"):
		var stem_ing: String = word.left(word.length() - 3)
		_append_unique(forms, stem_ing)
		_append_unique(forms, stem_ing + "e")
	elif word.length() > 3 and word.ends_with("ed"):
		var stem_ed: String = word.left(word.length() - 2)
		_append_unique(forms, stem_ed)
		_append_unique(forms, stem_ed + "e")
	if word.length() > 3 and word.ends_with("es"):
		_append_unique(forms, word.left(word.length() - 2))
		_append_unique(forms, word.left(word.length() - 1))
	elif word.length() > 3 and word.ends_with("s") and not word.ends_with("ss") and word != "status":
		_append_unique(forms, word.left(word.length() - 1))
	return forms

func _token_variants(token: String) -> Array[String]:
	var variants: Array[String] = []
	for form in _word_forms(token):
		_append_unique(variants, form)
		for alias_value in TOKEN_ALIASES.get(form, []):
			for alias_form in _word_forms(normalize_search_text(String(alias_value))):
				_append_unique(variants, alias_form)
	return variants

func build_query_terms(query_raw: String, drop_stop_words: bool = false) -> Array:
	var terms: Array = []
	var alias_keys: Array = _get_sorted_alias_keys()
	for token_value in normalize_search_text(query_raw).split(" ", false):
		var token: String = String(token_value).strip_edges()
		if (token.is_empty() or token.is_valid_int()
				or (drop_stop_words and token in WORKFLOW_STOP_WORDS)):
			continue
		var matched_alias: bool = false
		for alias_key_value in alias_keys:
			var alias_key: String = String(alias_key_value)
			if not token.contains(alias_key):
				continue
			var variants: Array[String] = _token_variants(alias_key)
			for alias_value in INTENT_ALIASES[alias_key]:
				var alias: String = normalize_search_text(String(alias_value))
				for alias_form in _token_variants(alias):
					_append_unique(variants, alias_form)
			if variants not in terms:
				terms.append(variants)
			matched_alias = true
		if not matched_alias:
			terms.append(_token_variants(token))
	return terms

func _build_tool_signature(name: String) -> Array[String]:
	var signature: Array[String] = []
	for token_value in normalize_search_text(name).split(" ", false):
		var token: String = String(token_value)
		if token.is_empty() or token in TOOL_SIGNATURE_STOP_WORDS:
			continue
		var canonical: String = token
		if token.length() > 4 and token.ends_with("ies"):
			canonical = token.left(token.length() - 3) + "y"
		elif token == "buses" or (token.length() > 4 and (
				token.ends_with("xes") or token.ends_with("ches")
				or token.ends_with("shes") or token.ends_with("sses")
				or token.ends_with("zes"))):
			canonical = token.left(token.length() - 2)
		elif (token.length() > 3 and token.ends_with("s")
				and not token.ends_with("ss") and token != "status"):
			canonical = token.left(token.length() - 1)
		_append_unique(signature, canonical)
	return signature

func _query_concepts(terms: Array) -> Dictionary:
	var concepts: Dictionary = {}
	for variants_value in terms:
		for variant_value in variants_value:
			for form in _word_forms(String(variant_value)):
				concepts[form] = true
	return concepts

func _direct_query_terms(padded_query: String) -> Dictionary:
	var direct_terms: Dictionary = {}
	for token_value in padded_query.strip_edges().split(" ", false):
		for form in _word_forms(String(token_value)):
			direct_terms[form] = true
	for action_value in ACTION_QUERY_MARKERS:
		var action: String = String(action_value)
		for marker_value in ACTION_QUERY_MARKERS[action]:
			if padded_query.contains(String(marker_value)):
				direct_terms[action] = true
				break
	for term_value in DIRECT_TERM_MARKERS:
		var term: String = String(term_value)
		for marker_value in DIRECT_TERM_MARKERS[term]:
			if padded_query.contains(String(marker_value)):
				direct_terms[term] = true
				break
	return direct_terms

func _has_direct_action(action: String, direct_terms: Dictionary) -> bool:
	if direct_terms.has(action):
		return true
	if not READ_ACTION_TERMS.has(action):
		return false
	for family_action in READ_ACTION_TERMS:
		if direct_terms.has(family_action):
			return true
	return false

func _signature_score_for_concepts(
	signature: Array,
	rare_terms: Array,
	term_weights: Dictionary,
	concepts: Dictionary
) -> int:
	var matched: int = 0
	var matched_specific: int = 0
	var matched_rare: int = 0
	var specificity_score: int = 0
	for term_value in signature:
		var term: String = String(term_value)
		if concepts.has(term):
			matched += 1
			if term not in TOOL_SIGNATURE_GENERIC_TERMS:
				matched_specific += 1
			if term in rare_terms:
				matched_rare += 1
			specificity_score += int(term_weights.get(term, 1))
	var ratio_percent: int = int(floor(float(matched * 100) / float(signature.size())))
	var complete: bool = matched == signature.size() and matched >= SIGNATURE_MIN_MATCHES
	var strong_partial: bool = (matched >= SIGNATURE_MIN_MATCHES
		and matched_specific > 0 and ratio_percent >= SIGNATURE_MIN_RATIO_PERCENT)
	var rare_partial: bool = (signature.size() <= 3 and matched_rare > 0
		and ratio_percent >= 40)
	if not complete and not strong_partial and not rare_partial:
		return 0
	# More matched name segments increase confidence through ratio/specificity, but
	# do not receive an unbounded raw-length bonus. Otherwise a broad, long tool
	# name can crowd out a shorter exact operation such as create_script.
	var score: int = (min(matched, 2) * 300 + matched_specific * 120 + matched_rare * 180
		+ specificity_score * 24 + ratio_percent * 4)
	if complete:
		score += 600
	return score

func _signature_score(info: Dictionary, concepts: Dictionary, direct_terms: Dictionary) -> int:
	var signature: Array = info.get("_signature_terms", [])
	if signature.is_empty():
		return 0
	var rare_terms: Array = info.get("_rare_signature_terms", [])
	var score: int = _signature_score_for_concepts(
		signature, rare_terms, info.get("_signature_term_weights", {}), concepts)
	if score <= 0:
		return 0
	var action: String = String(signature[0])
	var matched_terms: int = 0
	for term_value in signature:
		if concepts.has(String(term_value)):
			matched_terms += 1
	var direct_objects: int = 0
	for term_index in range(1, signature.size()):
		if direct_terms.has(String(signature[term_index])):
			direct_objects += 1
	var direct_action: bool = _has_direct_action(action, direct_terms)
	if matched_terms < signature.size():
		if not concepts.has(action) and not direct_action:
			return 0
		# Alias-only actions are useful when every object segment is explicit, but
		# must not bind an unrelated verb to a partial object (for example,
		# "check the UI" plus "import CSV" must not imply get_import_status).
		if not direct_action and direct_objects < signature.size() - 1:
			return 0
	if direct_terms.has(action):
		score += 700
	elif direct_action:
		score += 240
	score += direct_objects * 300
	if signature.size() > 1 and direct_objects == signature.size() - 1:
		score += 500
	return score

func _get_sorted_alias_keys() -> Array:
	if _sorted_alias_keys.is_empty():
		_sorted_alias_keys = INTENT_ALIASES.keys()
		_sorted_alias_keys.sort_custom(func(a: String, b: String) -> bool:
			return a.length() > b.length()
		)
	return _sorted_alias_keys

func _has_token_match(haystack: String, needle: String, first_match: int) -> bool:
	var start: int = first_match
	while start >= 0:
		var end: int = start + needle.length()
		if (start == 0 or haystack.unicode_at(start - 1) == 32) and (
				end == haystack.length() or haystack.unicode_at(end) == 32):
			return true
		start = haystack.find(needle, start + 1)
	return false

func _score_term(info: Dictionary, variants: Array) -> int:
	var name: String = String(info.get("_name_text", ""))
	if name.is_empty():
		name = normalize_search_text(String(info.get("name", "")))
	var group: String = String(info.get("_group_text", ""))
	if group.is_empty():
		group = normalize_search_text(String(info.get("group", "")))
	var description: String = String(info.get("_description_text", ""))
	if description.is_empty():
		description = normalize_search_text(String(info.get("description", "")))
	var routing_texts: Array = info.get("_routing_texts", [])
	var best: int = 0
	for variant_value in variants:
		var variant: String = String(variant_value)
		if name == variant:
			best = max(best, 300)
		else:
			var name_match: int = name.find(variant)
			if name_match >= 0:
				best = max(best, 160 if _has_token_match(name, variant, name_match) else 120)
			elif group.find(variant) >= 0:
				best = max(best, 50)
			elif description.find(variant) >= 0:
				best = max(best, 20)
			else:
				for routing_text_value in routing_texts:
					if String(routing_text_value).find(variant) >= 0:
						best = max(best, 20)
						break
	return best

func score_tool_match(info: Dictionary, query_raw: String, terms: Array) -> int:
	var name: String = normalize_search_text(String(info.get("name", "")))
	var normalized_query: String = normalize_search_text(query_raw)
	var score: int = 0
	if name == normalized_query:
		score += 1000
	elif name.begins_with(normalized_query):
		score += 500
	for term_value in terms:
		var best_term_score: int = _score_term(info, term_value)
		if best_term_score == 0:
			return -1
		score += best_term_score
	if bool(info.get("enabled", false)):
		score += 5
	return score

func _sorted_atomic_tools(registered: Array) -> Array:
	var tools: Array = []
	for info_value in registered:
		var info: Dictionary = info_value
		if String(info.get("category", "")) == "meta":
			continue
		tools.append(info)
	tools.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return tools

func _build_capability_index(registered: Array, routing_hints: Dictionary) -> Array:
	var tools: Array = []
	for info_value in registered:
		var info: Dictionary = info_value
		if String(info.get("category", "")) == "meta":
			continue
		var name: String = String(info.get("name", ""))
		var category: String = String(info.get("category", ""))
		var schema_tokens: int = max(1, int(info.get("schema_tokens", DEFAULT_TOOL_SCHEMA_TOKENS)))
		var routing_texts: Array[String] = []
		var hint_value: Variant = routing_hints.get(name, "")
		if hint_value is Array:
			for hint_item in hint_value:
				var normalized_hint: String = normalize_search_text(String(hint_item))
				if not normalized_hint.is_empty() and normalized_hint not in routing_texts:
					routing_texts.append(normalized_hint)
		else:
			var normalized_hint: String = normalize_search_text(String(hint_value))
			if not normalized_hint.is_empty():
				routing_texts.append(normalized_hint)
		tools.append({
			"name": name,
			"category": category,
			"group": String(info.get("group", "")),
			"description": String(info.get("description", "")),
			"schema_tokens": schema_tokens,
			"_incremental_schema_tokens": 0 if category == "core" else schema_tokens,
			"_selection_cost": TOOL_COUNT_TOKEN_PENALTY if category == "core" else schema_tokens + TOOL_COUNT_TOKEN_PENALTY,
			"_name_text": normalize_search_text(name),
			"_group_text": normalize_search_text(String(info.get("group", ""))),
			"_description_text": normalize_search_text(String(info.get("description", ""))),
			"_routing_texts": routing_texts,
			"_signature_terms": _build_tool_signature(name)
		})
	var signature_term_counts: Dictionary = {}
	for info_value in tools:
		for term_value in (info_value as Dictionary).get("_signature_terms", []):
			var term: String = String(term_value)
			signature_term_counts[term] = int(signature_term_counts.get(term, 0)) + 1
	for info_value in tools:
		var info: Dictionary = info_value
		var rare_terms: Array[String] = []
		var term_weights: Dictionary = {}
		for term_value in info.get("_signature_terms", []):
			var term: String = String(term_value)
			var frequency: int = int(signature_term_counts.get(term, 0))
			if frequency <= 2:
				rare_terms.append(term)
			term_weights[term] = max(1, 16 - frequency)
		info["_rare_signature_terms"] = rare_terms
		info["_signature_term_weights"] = term_weights
	tools.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	return tools

func _ensure_capability_index(registered: Array, registry_revision: int, routing_hints: Dictionary) -> Array:
	if registry_revision < 0:
		return _build_capability_index(registered, routing_hints)
	if _indexed_revision != registry_revision:
		_indexed_tools = _build_capability_index(registered, routing_hints)
		var cost_index: Dictionary = _build_cost_index(_indexed_tools)
		_indexed_by_name = cost_index.get("by_name", {})
		_indexed_exact_by_intent = cost_index.get("exact_by_intent", {})
		_indexed_full_load_schema_tokens = int(cost_index.get("full_load_schema_tokens", 0))
		_indexed_revision = registry_revision
		_index_builds += 1
		_route_cache.clear()
		_route_lru.clear()
	return _indexed_tools

func _build_cost_index(atomic_tools: Array) -> Dictionary:
	var by_name: Dictionary = {}
	var exact_by_intent: Dictionary = {}
	var full_load_schema_tokens: int = 0
	for info_value in atomic_tools:
		var info: Dictionary = info_value
		var name: String = String(info.get("name", ""))
		by_name[name] = info
		var exact_intents: Array = [
			String(info.get("_name_text", "")),
			String(info.get("_description_text", "")),
		]
		exact_intents.append_array(info.get("_routing_texts", []))
		for intent_value in exact_intents:
			var intent: String = String(intent_value)
			if not intent.is_empty() and not exact_by_intent.has(intent):
				exact_by_intent[intent] = name
		full_load_schema_tokens += int(info.get("_incremental_schema_tokens", 0))
	return {
		"by_name": by_name,
		"exact_by_intent": exact_by_intent,
		"full_load_schema_tokens": full_load_schema_tokens
	}

func _route_cache_key(query: String, budget: int) -> String:
	return normalize_search_text(query) + "|" + str(budget)

func _get_cached_route(cache_key: String) -> Dictionary:
	if not _route_cache.has(cache_key):
		return {}
	_route_lru.erase(cache_key)
	_route_lru.append(cache_key)
	_route_cache_hits += 1
	return (_route_cache[cache_key] as Dictionary).duplicate(true)

func _store_cached_route(cache_key: String, result: Dictionary) -> void:
	if _route_cache.has(cache_key):
		_route_lru.erase(cache_key)
	_route_cache[cache_key] = result.duplicate(true)
	_route_lru.append(cache_key)
	while _route_lru.size() > ROUTE_CACHE_MAX:
		var oldest_key: String = _route_lru.pop_front()
		_route_cache.erase(oldest_key)
		_route_cache_evictions += 1

func get_diagnostics() -> Dictionary:
	var route_requests: int = _route_cache_hits + _route_cache_misses
	return {
		"indexed_revision": _indexed_revision,
		"indexed_tools": _indexed_tools.size(),
		"index_builds": _index_builds,
		"route_computations": _route_computations,
		"route_cache_hits": _route_cache_hits,
		"route_cache_misses": _route_cache_misses,
		"route_cache_requests": route_requests,
		"route_cache_hit_rate": float(_route_cache_hits) / float(maxi(1, route_requests)),
		"route_cache_evictions": _route_cache_evictions,
		"route_cache_entries": _route_cache.size(),
		"route_cache_capacity": ROUTE_CACHE_MAX
	}


## 测试接口：清零路由缓存计数（不触碰缓存内容），用于干净窗口内测量命中率。
func reset_diagnostics() -> void:
	_route_computations = 0
	_route_cache_hits = 0
	_route_cache_misses = 0
	_route_cache_evictions = 0

func _score_curated_workflow(workflow: Dictionary, terms: Array, normalized_query: String) -> int:
	var haystack: String = String(workflow.get("_search_text", ""))
	var score: int = 0
	for variants_value in terms:
		var variants: Array = variants_value
		for variant_value in variants:
			var variant: String = String(variant_value)
			if haystack.contains(variant):
				score += 25
				break
	for keyword_value in workflow.get("_normalized_keywords", []):
		var keyword: String = String(keyword_value)
		if keyword.length() >= 2 and normalized_query.contains(keyword):
			score += 5
	return score

func _get_curated_index() -> Array:
	if _curated_index.is_empty():
		for workflow_value in CURATED_WORKFLOWS:
			var workflow: Dictionary = (workflow_value as Dictionary).duplicate(true)
			workflow["_search_text"] = normalize_search_text(
				String(workflow.get("id", "")) + " " + String(workflow.get("title", "")) + " " +
				" ".join(workflow.get("keywords", [])))
			var normalized_keywords: Array[String] = []
			for keyword_value in workflow.get("keywords", []):
				normalized_keywords.append(normalize_search_text(String(keyword_value)))
			workflow["_normalized_keywords"] = normalized_keywords
			_curated_index.append(workflow)
	return _curated_index

func _best_curated_workflow(terms: Array, normalized_query: String) -> Dictionary:
	var best: Dictionary = {}
	var best_score: int = 0
	for workflow_value in _get_curated_index():
		var workflow: Dictionary = workflow_value
		var score: int = _score_curated_workflow(workflow, terms, normalized_query)
		if score > best_score or (score == best_score and score > 0 and String(workflow.get("id", "")) < String(best.get("id", ""))):
			best = workflow
			best_score = score
	if best_score < MIN_CURATED_SCORE:
		return {}
	var result: Dictionary = best.duplicate(true)
	result["score"] = best_score
	return result

func _term_label(variants: Array) -> String:
	return String(variants[0]) if not variants.is_empty() else ""

func _has_term_label(terms: Array, labels: Array[String]) -> bool:
	for variants_value in terms:
		if _term_label(variants_value) in labels:
			return true
	return false

func _stage_for_tool(tool_name: String) -> String:
	if tool_name in VERIFY_TOOL_NAMES:
		return "verify"
	for prefix in VERIFY_PREFIXES:
		if tool_name.begins_with(prefix):
			return "verify"
	for prefix in READ_PREFIXES:
		if tool_name.begins_with(prefix):
			return "inspect"
	return "execute"

func _build_stages(selected: Array[String]) -> Array[Dictionary]:
	var buckets: Dictionary = {"inspect": [], "execute": [], "verify": []}
	for tool_name in selected:
		buckets[_stage_for_tool(tool_name)].append(tool_name)
	var stages: Array[Dictionary] = []
	for phase in ["inspect", "execute", "verify"]:
		if not buckets[phase].is_empty():
			stages.append({"phase": phase, "tools": buckets[phase]})
	return stages

func _build_cost_metrics(
	selected: Array[String],
	atomic_by_name: Dictionary,
	full_load_schema_tokens: int
) -> Dictionary:
	var added_schema_tokens: int = 0
	for tool_name in selected:
		var info: Dictionary = atomic_by_name.get(tool_name, {})
		added_schema_tokens += int(info.get("_incremental_schema_tokens", 0))
	var savings_ratio: float = 1.0
	if full_load_schema_tokens > 0:
		savings_ratio = clamp(
			1.0 - float(added_schema_tokens) / float(full_load_schema_tokens), 0.0, 1.0)
		savings_ratio = round(savings_ratio * 10000.0) / 10000.0
	return {
		"estimated_added_schema_tokens": added_schema_tokens,
		"estimated_full_load_schema_tokens": full_load_schema_tokens,
		"estimated_token_savings_ratio": savings_ratio
	}

func route(
	query_raw: String,
	registered: Array,
	requested_budget: int = DEFAULT_TOOL_BUDGET,
	registry_revision: int = -1,
	routing_hints: Dictionary = {}
) -> Dictionary:
	var query: String = query_raw.strip_edges()
	if query.is_empty():
		return {"error": "Missing required workflow intent"}
	var budget: int = clamp(requested_budget, 1, MAX_TOOL_BUDGET)
	var atomic_tools: Array = _ensure_capability_index(registered, registry_revision, routing_hints)
	var cache_key: String = _route_cache_key(query, budget)
	if registry_revision >= 0 and _route_cache.has(cache_key):
		return _get_cached_route(cache_key)
	_route_cache_misses += 1
	_route_computations += 1
	var atomic_by_name: Dictionary = _indexed_by_name
	var exact_by_intent: Dictionary = _indexed_exact_by_intent
	var full_load_schema_tokens: int = _indexed_full_load_schema_tokens
	if registry_revision < 0:
		var local_cost_index: Dictionary = _build_cost_index(atomic_tools)
		atomic_by_name = local_cost_index.get("by_name", {})
		exact_by_intent = local_cost_index.get("exact_by_intent", {})
		full_load_schema_tokens = int(local_cost_index.get("full_load_schema_tokens", 0))
	var result: Dictionary = _compute_route(
		query, atomic_tools, budget, atomic_by_name, exact_by_intent,
		full_load_schema_tokens)
	if registry_revision >= 0:
		_store_cached_route(cache_key, result)
	return result

func _compute_route(
	query: String,
	atomic_tools: Array,
	budget: int,
	atomic_by_name: Dictionary,
	exact_by_intent: Dictionary,
	full_load_schema_tokens: int
) -> Dictionary:
	var terms: Array = build_query_terms(query, true)
	if terms.is_empty():
		terms = [[normalize_search_text(query)]]
	var normalized_query: String = normalize_search_text(query)
	# Exact atomic names are an escape hatch with strict priority. This guarantees
	# complete bilingual coverage and avoids adding workflow companions to a
	# one-tool intent when an official capability description is supplied.
	var exact_name: String = String(exact_by_intent.get(normalized_query, ""))
	if not exact_name.is_empty():
		var exact_labels: Array[String] = []
		for variants_value in terms:
			exact_labels.append(_term_label(variants_value))
		var exact_result: Dictionary = {
			"matched_workflow": "adaptive",
			"stages": _build_stages([exact_name]),
			"tool_count": 1,
			"covered_terms": exact_labels,
			"uncovered_terms": [],
			"coverage_ratio": 1.0,
			"tool_budget": budget
		}
		exact_result.merge(_build_cost_metrics(
			[exact_name], atomic_by_name, full_load_schema_tokens))
		return exact_result
	var curated: Dictionary = _best_curated_workflow(terms, normalized_query)
	var curated_names: Array = curated.get("tools", [])
	var concepts: Dictionary = _query_concepts(terms)
	var padded_query: String = " " + normalized_query + " "
	var direct_terms: Dictionary = _direct_query_terms(padded_query)

	var candidates: Array[Dictionary] = []
	for info_value in atomic_tools:
		var info: Dictionary = info_value
		var name: String = String(info.get("name", ""))
		var matches: Array[int] = []
		var term_scores: Dictionary = {}
		var score: int = 0
		for term_index in range(terms.size()):
			var term_score: int = _score_term(info, terms[term_index])
			if term_score > 0:
				matches.append(term_index)
				term_scores[term_index] = term_score
				score += term_score
		if name in curated_names:
			score += 80
		if score > 0:
			# Signature scoring is deliberately the second-stage ranker. A signature
			# can only match concepts produced by the same term variants that made
			# this tool a candidate, so evaluating it for every registry entry wastes
			# uncached-route CPU without changing recall or ordering.
			var signature_score: int = _signature_score(info, concepts, direct_terms)
			candidates.append({
				"name": name,
				"matches": matches,
				"term_scores": term_scores,
				"score": score,
				"selection_cost": int(info.get("_selection_cost", DEFAULT_TOOL_SCHEMA_TOKENS + TOOL_COUNT_TOKEN_PENALTY)),
				"signature_score": signature_score
			})

	var uncovered: Dictionary = {}
	for term_index in range(terms.size()):
		uncovered[term_index] = true
	var selected: Array[String] = []
	var forced_tools: Array[String] = []
	if not curated.is_empty() and _has_term_label(terms, ["运行", "run", "launch", "execute"]):
		for preferred_name in ["run_project", "play_and_verify", "run_export", "run_project_tests"]:
			if preferred_name in curated_names and atomic_by_name.has(preferred_name):
				forced_tools.append(preferred_name)
				break
	if not curated.is_empty() and _has_term_label(terms, ["验证", "测试", "verify", "validate", "assert", "test", "试玩"]):
		for tool_value in curated_names:
			var verifier_name: String = String(tool_value)
			if (_stage_for_tool(verifier_name) == "verify" and verifier_name not in forced_tools
					and atomic_by_name.has(verifier_name)):
				forced_tools.append(verifier_name)
				break
	var signature_candidates: Array[Dictionary] = []
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		if int(candidate.get("signature_score", 0)) > 0:
			signature_candidates.append(candidate)
	signature_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_score: int = int(a.get("signature_score", 0))
		var b_score: int = int(b.get("signature_score", 0))
		var a_cost: int = int(a.get("selection_cost", 0))
		var b_cost: int = int(b.get("selection_cost", 0))
		if a_score != b_score:
			return a_score > b_score
		if a_cost != b_cost:
			return a_cost < b_cost
		return String(a.get("name", "")) < String(b.get("name", ""))
	)
	for candidate_value in signature_candidates:
		if forced_tools.size() >= min(budget, SIGNATURE_TOOL_LIMIT):
			break
		var signature_name: String = String((candidate_value as Dictionary).get("name", ""))
		if _stage_for_tool(signature_name) == "verify":
			var signature_info: Dictionary = atomic_by_name.get(signature_name, {})
			var signature_terms: Array = signature_info.get("_signature_terms", [])
			var verify_family: String = String(signature_terms[-1]) if not signature_terms.is_empty() else signature_name
			var duplicate_verify_family: bool = false
			for forced_name in forced_tools:
				if _stage_for_tool(forced_name) != "verify":
					continue
				var forced_info: Dictionary = atomic_by_name.get(forced_name, {})
				var forced_terms: Array = forced_info.get("_signature_terms", [])
				var forced_family: String = String(forced_terms[-1]) if not forced_terms.is_empty() else forced_name
				if forced_family == verify_family:
					duplicate_verify_family = true
					break
			if duplicate_verify_family:
				continue
		if signature_name not in forced_tools:
			forced_tools.append(signature_name)
	for forced_name in forced_tools:
		if selected.size() >= budget:
			break
		selected.append(forced_name)
		for candidate_value in candidates:
			var candidate: Dictionary = candidate_value
			if String(candidate.get("name", "")) != forced_name:
				continue
			for term_index in candidate.get("matches", []):
				uncovered.erase(term_index)
			break
	while selected.size() < budget:
		var best: Dictionary = {}
		var best_new_coverage: int = 0
		var best_new_score: int = 0
		var best_cost: int = 1
		var best_score: int = 0
		for candidate_value in candidates:
			var candidate: Dictionary = candidate_value
			var candidate_name: String = String(candidate.get("name", ""))
			if candidate_name in selected:
				continue
			var new_coverage: int = 0
			var new_score: int = 0
			var candidate_term_scores: Dictionary = candidate.get("term_scores", {})
			for term_index in candidate.get("matches", []):
				if uncovered.has(term_index):
					new_coverage += 1
					new_score += int(candidate_term_scores.get(term_index, 0))
			var candidate_cost: int = int(candidate.get("selection_cost", DEFAULT_TOOL_SCHEMA_TOKENS + TOOL_COUNT_TOKEN_PENALTY))
			var candidate_score: int = int(candidate.get("score", 0))
			var better: bool = best.is_empty() or new_score > best_new_score
			if not better and new_score == best_new_score:
				better = new_coverage > best_new_coverage
			if not better and new_score == best_new_score and new_coverage == best_new_coverage:
				# Compare score/cost ratios with integer cross multiplication to keep
				# ranking byte-stable across platforms and avoid float noise.
				var candidate_value_ratio: int = candidate_score * best_cost
				var best_value_ratio: int = best_score * candidate_cost
				better = candidate_value_ratio > best_value_ratio
				if candidate_value_ratio == best_value_ratio:
					better = candidate_cost < best_cost
					if candidate_cost == best_cost:
						better = candidate_name < String(best.get("name", ""))
			if better:
				best = candidate
				best_new_coverage = new_coverage
				best_new_score = new_score
				best_cost = candidate_cost
				best_score = candidate_score
		if (best.is_empty() or best_new_coverage == 0
				or (not selected.is_empty() and best_new_score < MIN_FALLBACK_NEW_SCORE)
				or (uncovered.is_empty() and selected.size() >= 1)):
			break
		var best_name: String = String(best.get("name", ""))
		selected.append(best_name)
		for term_index in best.get("matches", []):
			uncovered.erase(term_index)

	var covered_terms: Array[String] = []
	var uncovered_terms: Array[String] = []
	for term_index in range(terms.size()):
		var label: String = _term_label(terms[term_index])
		if uncovered.has(term_index):
			uncovered_terms.append(label)
		else:
			covered_terms.append(label)
	var ratio: float = 1.0
	if not terms.is_empty():
		ratio = float(covered_terms.size()) / float(terms.size())

	var result: Dictionary = {
		"matched_workflow": String(curated.get("id", "adaptive")),
		"stages": _build_stages(selected),
		"tool_count": selected.size(),
		"covered_terms": covered_terms,
		"uncovered_terms": uncovered_terms,
		"coverage_ratio": ratio,
		"tool_budget": budget
	}
	result.merge(_build_cost_metrics(selected, atomic_by_name, full_load_schema_tokens))
	return result

func validate_curated_tool_references(registered: Array) -> Array[String]:
	var registered_names: Dictionary = {}
	for info_value in registered:
		registered_names[String((info_value as Dictionary).get("name", ""))] = true
	var missing: Array[String] = []
	for workflow_value in CURATED_WORKFLOWS:
		for tool_value in (workflow_value as Dictionary).get("tools", []):
			var tool_name: String = String(tool_value)
			if not registered_names.has(tool_name) and tool_name not in missing:
				missing.append(tool_name)
	missing.sort()
	return missing

func get_coverage_report(registered: Array) -> Dictionary:
	var atomic_tools: Array = _sorted_atomic_tools(registered)
	var atomic_names: Dictionary = {}
	for info_value in atomic_tools:
		atomic_names[String((info_value as Dictionary).get("name", ""))] = true
	var curated_names: Dictionary = {}
	for workflow_value in CURATED_WORKFLOWS:
		for tool_value in (workflow_value as Dictionary).get("tools", []):
			var tool_name: String = String(tool_value)
			if atomic_names.has(tool_name):
				curated_names[tool_name] = true
	var total: int = atomic_tools.size()
	return {
		"total_atomic": total,
		"routable_atomic": total,
		"curated_atomic": curated_names.size(),
		"adaptive_atomic": total - curated_names.size(),
		"coverage_ratio": 1.0 if total > 0 else 0.0,
		"uncovered": [],
		"curated_workflows": CURATED_WORKFLOWS.size(),
		"max_tools_per_route": MAX_TOOL_BUDGET
	}
