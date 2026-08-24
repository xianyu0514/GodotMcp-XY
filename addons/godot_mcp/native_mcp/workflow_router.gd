extends RefCounted
## Lightweight intent-to-workflow router.
##
## The router never copies tool schemas and never calls a model, embedding API, or
## network service. It scans the small registered catalog once, greedily covers
## the intent terms with the fewest useful tools, then groups the selected names
## into inspect / execute / verify stages. Every non-meta tool participates in the
## adaptive index, while a small curated seed table improves common game workflows.
## Equal-coverage candidates are ranked by semantic value per estimated schema
## token so the enabled tool surface stays useful and small.

const DEFAULT_TOOL_BUDGET: int = 8
const MAX_TOOL_BUDGET: int = 10
const ROUTE_CACHE_MAX: int = 64
const DEFAULT_TOOL_SCHEMA_TOKENS: int = 128
const TOOL_COUNT_TOKEN_PENALTY: int = 32
const MIN_CURATED_SCORE: int = 40
const CURATED_MIN_TOOLS: int = 4

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
var _curated_index: Array = []

const INTENT_ALIASES: Dictionary = {
	"场景": ["scene"], "节点": ["node"], "脚本": ["script"],
	"调试": ["debug", "runtime"], "运行时": ["runtime"], "运行": ["run", "runtime"],
	"信息": ["info", "status", "details"], "状态": ["status", "info"],
	"动画": ["animation"], "音频": ["audio"], "输入": ["input"],
	"导出": ["export"], "资源": ["resource", "asset"], "素材": ["asset", "resource"],
	"测试": ["test", "verify"], "验证": ["verify", "assert", "test", "validate"],
	"截图": ["screenshot"], "着色器": ["shader"], "瓦片": ["tile", "tilemap", "tileset"],
	"信号": ["signal"], "本地化": ["localization"], "翻译": ["translation", "localization"],
	"性能": ["performance"], "项目": ["project"], "界面": ["ui", "control", "theme"],
	"二维": ["2d"], "三维": ["3d"], "创建": ["create", "add"],
	"删除": ["delete", "remove"], "修改": ["update", "modify", "set"],
	"读取": ["get", "read", "list", "inspect"], "游戏": ["game", "runtime"],
	"角色": ["character", "player", "controller"], "控制器": ["controller", "input"],
	"玩法": ["gameplay", "mechanic"], "功能": ["feature", "gameplay"],
	"错误": ["error", "debug"], "修复": ["fix", "debug", "modify"],
	"发布": ["release", "export"], "关卡": ["level", "scene", "tilemap"]
}

const WORKFLOW_STOP_WORDS: Array[String] = [
	"a", "an", "and", "as", "at", "build", "by", "for", "from", "in", "into",
	"make", "of", "on", "please", "the", "then", "to", "use", "with"
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

func normalize_search_text(value: String) -> String:
	var normalized: String = value.strip_edges().to_lower().replace("_", " ").replace("-", " ").replace("\t", " ").replace("\n", " ")
	while normalized.contains("  "):
		normalized = normalized.replace("  ", " ")
	return normalized

func build_query_terms(query_raw: String, drop_stop_words: bool = false) -> Array:
	var terms: Array = []
	var alias_keys: Array = _get_sorted_alias_keys()
	for token_value in normalize_search_text(query_raw).split(" ", false):
		var token: String = String(token_value).strip_edges()
		if token.is_empty() or (drop_stop_words and token in WORKFLOW_STOP_WORDS):
			continue
		var matched_alias: bool = false
		for alias_key_value in alias_keys:
			var alias_key: String = String(alias_key_value)
			if not token.contains(alias_key):
				continue
			var variants: Array[String] = [alias_key]
			for alias_value in INTENT_ALIASES[alias_key]:
				var alias: String = normalize_search_text(String(alias_value))
				if not alias.is_empty() and alias not in variants:
					variants.append(alias)
			if variants not in terms:
				terms.append(variants)
			matched_alias = true
		if not matched_alias:
			terms.append([token])
	return terms

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
			"_routing_texts": routing_texts
		})
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

func get_diagnostics() -> Dictionary:
	return {
		"indexed_revision": _indexed_revision,
		"indexed_tools": _indexed_tools.size(),
		"index_builds": _index_builds,
		"route_computations": _route_computations,
		"route_cache_hits": _route_cache_hits,
		"route_cache_entries": _route_cache.size(),
		"route_cache_capacity": ROUTE_CACHE_MAX
	}

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

	var candidates: Array[Dictionary] = []
	for info_value in atomic_tools:
		var info: Dictionary = info_value
		var name: String = String(info.get("name", ""))
		var matches: Array[int] = []
		var score: int = 0
		for term_index in range(terms.size()):
			var term_score: int = _score_term(info, terms[term_index])
			if term_score > 0:
				matches.append(term_index)
				score += term_score
		if name in curated_names:
			score += 80
		if score > 0:
			candidates.append({
				"name": name,
				"matches": matches,
				"score": score,
				"selection_cost": int(info.get("_selection_cost", DEFAULT_TOOL_SCHEMA_TOKENS + TOOL_COUNT_TOKEN_PENALTY))
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
	if not curated.is_empty() and _has_term_label(terms, ["验证", "测试", "verify", "validate", "assert", "test"]):
		for tool_value in curated_names:
			var verifier_name: String = String(tool_value)
			if (_stage_for_tool(verifier_name) == "verify" and verifier_name not in forced_tools
					and atomic_by_name.has(verifier_name)):
				forced_tools.append(verifier_name)
				break
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
		var best_cost: int = 1
		var best_score: int = 0
		for candidate_value in candidates:
			var candidate: Dictionary = candidate_value
			var candidate_name: String = String(candidate.get("name", ""))
			if candidate_name in selected:
				continue
			var new_coverage: int = 0
			for term_index in candidate.get("matches", []):
				if uncovered.has(term_index):
					new_coverage += 1
			var candidate_cost: int = int(candidate.get("selection_cost", DEFAULT_TOOL_SCHEMA_TOKENS + TOOL_COUNT_TOKEN_PENALTY))
			var candidate_score: int = int(candidate.get("score", 0))
			var better: bool = best.is_empty() or new_coverage > best_new_coverage
			if not better and new_coverage == best_new_coverage:
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
				best_cost = candidate_cost
				best_score = candidate_score
		if best.is_empty() or best_new_coverage == 0 or (uncovered.is_empty() and selected.size() >= 1):
			break
		var best_name: String = String(best.get("name", ""))
		selected.append(best_name)
		for term_index in best.get("matches", []):
			uncovered.erase(term_index)

	# A matched common workflow gets a small deterministic backbone after intent
	# coverage. This keeps plans executable without filling the whole tool budget.
	if not curated.is_empty():
		for tool_value in curated_names:
			if selected.size() >= min(budget, CURATED_MIN_TOOLS):
				break
			var tool_name: String = String(tool_value)
			if tool_name not in selected and atomic_by_name.has(tool_name):
				selected.append(tool_name)

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
