@tool
class_name MCPEngineCompatKnowledge
extends RefCounted

## 引擎 API 兼容知识库（单一数据表 + 确定性查询）。
##
## 收录"实测换来的引擎真值"：API 漂移（4.6↔4.7）、易踩的引擎语义、CLI 行为。
## 每条都有 workaround 与来源，供 query_engine_compat 工具按需注入给 AI 调用方，
## 避免每个新会话重新踩同一批坑（首过成功率的第一杀手）。
##
## 维护约定：
## - 只收"实测确认"的条目（来源字段必须可追溯：AGENTS.md / goal-playbook / 评审实测 / CI）。
## - versions 为空数组 = 全 4.x 适用；否则列出适用版本（如 ["4.7"]）。
## - aliases 含中英文关键词，查询匹配用（中英调用方都存在）。
## - id 全局唯一（测试强制）。

const KINDS: Array[String] = ["api", "behavior", "cli", "editor"]

const ENTRIES: Array[Dictionary] = [
	{
		"id": "gdscript-float-constructor-unavailable",
		"api": "float()",
		"aliases": ["float 构造器", "float constructor", "类型转换", "type cast", "int to float"],
		"kind": "api",
		"versions": ["4.7"],
		"title": "The float() constructor is unavailable",
		"truth": "float(x) fails to parse in 4.7; int-to-float style casts must not go through a constructor call.",
		"workaround": "Use 'as float' (e.g. 'var v: float = 1 as float'), or rely on typed arithmetic.",
		"source": "AGENTS.md — Godot 4.7 special notes",
	},
	{
		"id": "animationnodestatemachine-no-set-start-node",
		"api": "AnimationNodeStateMachine.set_start_node()",
		"aliases": ["状态机起始节点", "start node", "animation state machine"],
		"kind": "api",
		"versions": [],
		"title": "AnimationNodeStateMachine.set_start_node() does not exist",
		"truth": "The method is absent in 4.x despite appearing in some docs/LLM training data; calling it errors at runtime.",
		"workaround": "Use add_node() to add nodes; configure the start via the state machine graph (set the start node property that add_node exposes).",
		"source": "AGENTS.md — Godot 4.7 special notes",
	},
	{
		"id": "tilemap-vs-tilemaplayer-dual-api",
		"api": "TileMap / TileMapLayer",
		"aliases": ["瓦片地图", "tilemap", "tile map layer", "set_tilemap_layer_cells", "update_internals"],
		"kind": "api",
		"versions": [],
		"title": "TileMap (legacy) and TileMapLayer (4.x) are separate APIs — pick the right one per context",
		"truth": "Editor-time tools (set_tilemap_layer_cells / get_tilemap_layer_cells) use the single-layer TileMapLayer API. The runtime probe supports BOTH: region reads and batch writes route through update_internals() so physics/navigation reflect immediately; physics/navigation assertions still need advance_frames(1) before they observe the rebuild.",
		"workaround": "Editor-side edits: TileMapLayer API. Runtime probes: the dual-compatible probe commands, then advance_frames(1) before asserting collision/navigation state.",
		"source": "AGENTS.md — runtime probe M5 notes",
	},
	{
		"id": "node-get-path-outside-tree",
		"api": "Node.get_path()",
		"aliases": ["树外节点", "outside tree", "is_inside_tree", "get_path_to"],
		"kind": "api",
		"versions": [],
		"title": "get_path() errors and returns empty for nodes not inside the scene tree",
		"truth": "Calling get_path() on an instantiated-but-not-added node prints 'Condition !is_inside_tree() is true' and returns NodePath() — silent empty paths downstream.",
		"workaround": "Use scene_root.get_path_to(node) which only walks the parent chain and works for out-of-tree instances (e.g. read-only scene file inspection).",
		"source": "get_scene_structure scene_path inspection — 2026-09-28 audit fix (PR #170)",
	},
	{
		"id": "expression-parser-limits",
		"api": "Expression",
		"aliases": ["表达式求值", "expression evaluate", "is 运算符", "三元", "ternary", "closure", "闭包"],
		"kind": "api",
		"versions": [],
		"title": "Expression cannot parse native class names, the 'is' operator, ternaries, multi-statement bodies, or closures",
		"truth": "Static calls like FileAccess.file_exists(...) or ClassDB.class_exists(...) always fail inside Expression; 'is' type checks and ternary conditionals fail too; multi-line statements and closures are unsupported. Verified on bare engine and in-project.",
		"workaround": "Assert on state fields instead of file existence; type checks via get_class() == 'TypeName' string comparison; for timing instrumentation embed Time.get_ticks_usec() in source via modify_script instead of runtime expression injection.",
		"source": "goal-playbook — Expression native class name ban + audit P2-9",
	},
	{
		"id": "shader-parameter-default-null",
		"api": "Material.get_shader_parameter()",
		"aliases": ["shader uniform 默认值", "uniform default", "get_shader_parameter null"],
		"kind": "api",
		"versions": [],
		"title": "get_shader_parameter() returns null for uniforms that were never explicitly set",
		"truth": "Default values live inside the shader code; the material only stores overrides. Reading a never-set uniform returns null even though the shader renders with its default.",
		"workaround": "set_runtime_shader_parameter first, then read back. Prove material attachment via 'material is ShaderMaterial'-style checks (string-compare form for Expression contexts).",
		"source": "goal-playbook — make_game_shader first-run rules",
	},
	{
		"id": "project-godot-config-name-key",
		"api": "project.godot [application] config/name",
		"aliases": ["项目配置", "project name key", "config_name"],
		"kind": "api",
		"versions": [],
		"title": "The project name key in project.godot is config/name (not config_name)",
		"truth": "Godot 4 project.godot uses ini-style 'config/name=\"...\"' under [application]. A 'config_name' key is silently ignored — the project shows as untitled.",
		"workaround": "Write/read via 'config/name'. set_project_setting handles this; hand-rolled file writes must use the slash form.",
		"source": "plugin-user sim fixture fix — 2026-09-28 integration merge (PR #169)",
	},
	{
		"id": "hint-screen-texture-auto-copy",
		"api": "hint_screen_texture",
		"aliases": ["屏幕拷贝", "screen copy", "BackBufferCopy", "back buffer"],
		"kind": "api",
		"versions": [],
		"title": "A 'uniform sampler2D x : hint_screen_texture' triggers the screen copy automatically",
		"truth": "Declaring the hint uniform alone enables the screen-capture path; a BackBufferCopy node is NOT required and its copy_mode toggle does not change the uniform's behavior (on/off variants byte-identical in testing).",
		"workaround": "Use the hint uniform directly; the effective A/B contrast is effect-node visible vs hidden, not BackBufferCopy on/off.",
		"source": "goal-playbook — shader engine truths (2D breadth matrix)",
	},
	{
		"id": "frame-locked-timeline-wall-clock",
		"api": "Time.get_ticks_msec() (in asserted motion)",
		"aliases": ["墙钟", "wall clock", "时间线回放", "timeline replay", "帧驱动"],
		"kind": "behavior",
		"versions": [],
		"title": "Motion asserted under frame-locked timeline replay must be frame-driven, not wall-clock driven",
		"truth": "Timeline replay fast-forwards by frames while the wall clock barely moves — platform motion computed from get_ticks_msec() measures ~0.0px under replay (a real flake that was reproduced and fixed).",
		"workaround": "Drive asserted movement by frame count (e.g. radians per frame); landing sequences stay covered while the platform keeps moving per frame.",
		"source": "goal-playbook — frame-locked timeline requirements",
	},
	{
		"id": "gdscript-value-semantics-traps",
		"api": "lambda captures / Packed*Array",
		"aliases": ["值语义", "value semantics", "lambda 捕获", "packed array copy"],
		"kind": "behavior",
		"versions": [],
		"title": "Lambdas capture by value; Packed*Arrays are value types — counters and appends mutate copies",
		"truth": "A counter incremented inside a lambda does not persist across calls (captured by value). PackedStringArray.append after 'as' conversion modifies the copy while the stored container keeps the old contents. Both bit three separate fixes in one session.",
		"workaround": "Use a Dictionary cell as a mutable box for cross-call state; use Array for mutable collections, or read-modify-write back into the packed array.",
		"source": "goal-playbook — GDScript value semantics (three real incidents)",
	},
	{
		"id": "tscn-parent-excludes-root",
		"api": ".tscn [node] parent attribute",
		"aliases": ["场景文件解析", "tscn parse", "node parent path"],
		"kind": "api",
		"versions": [],
		"title": "The 'parent' attribute in .tscn node headers excludes the root node name",
		"truth": "[node name=\"Leaf\" parent=\"Mid\"] resolves to Root/Mid/Leaf — NOT Mid/Leaf. Also instance=ExtResource(\"id\") has '(' before the key, so a naive key=\"value\" regex never matches the header.",
		"workaround": "Prepend the root name when computing node paths; extract instance ids from the raw header line instead of the generic attribute regex.",
		"source": "goal-playbook — .tscn text parsing traps (TestScene.tscn verified)",
	},
	{
		"id": "editor-process-vs-game-process-metrics",
		"api": "Performance monitors",
		"aliases": ["性能口径", "process scope", "编辑器进程", "内存对象数"],
		"kind": "behavior",
		"versions": [],
		"title": "Editor-process Performance numbers are ~45x the game process — never mix the scopes",
		"truth": "The editor's own scene tree, imported resources and plugins inflate OBJECT_COUNT/STATIC_MEMORY roughly 45x versus the running game (measured: 101,780 objects / 755MB editor vs 2,235 objects / 163MB game at the same instant). Judging game performance from the editor scope produced a false 'node leak' diagnosis.",
		"workaround": "Read game metrics via scope='runtime' channels (get_performance_metrics source auto/runtime, or get_runtime_performance_snapshot); always check the 'scope' field before interpreting numbers.",
		"source": "2026-09-27 health check P0-3 — process forensics",
	},
	{
		"id": "pause-freezes-everything",
		"api": "get_tree().paused",
		"aliases": ["暂停", "pause menu", "PROCESS_MODE_WHEN_PAUSED", "点击穿透"],
		"kind": "behavior",
		"versions": [],
		"title": "Paused freezes EVERYTHING — pause UI needs PROCESS_MODE_WHEN_PAUSED; overlays must ignore mouse",
		"truth": "When the tree is paused, a pause menu without process_mode = PROCESS_MODE_WHEN_PAUSED never receives the resume click. Separately, a decorative full-screen overlay drawn above buttons eats their clicks unless mouse_filter = MOUSE_FILTER_IGNORE. Both traps bite every first menu build.",
		"workaround": "Pause menus and their buttons under a PROCESS_MODE_WHEN_PAUSED node; set decorative overlays to MOUSE_FILTER_IGNORE. Verify click-through with mouse events at runtime rect_center, not screenshots.",
		"source": "make_game_menu recipe — earned truths",
	},
	{
		"id": "connect-signal-editor-instance-only",
		"api": "Node.connect() via editor tooling",
		"aliases": ["信号连接持久化", "signal persistence", "connect_signal", "死按钮"],
		"kind": "behavior",
		"versions": [],
		"title": "connect_signal wires the EDITOR instance only — it does not persist into the saved scene",
		"truth": "Connections made on the edited scene's editor instance (even with flags=1) do not survive into the running game — the classic 'dead buttons in the game' defect.",
		"workaround": "Wire every button from the controller script's _ready via button.pressed.connect(handler); script-side connections always reach the running game.",
		"source": "make_game_menu recipe — earned truths",
	},
	{
		"id": "tool-script-instantiation-semantics",
		"api": "PackedScene.instantiate() (read-only inspection)",
		"aliases": ["实例化副作用", "instantiate side effects", "@tool init"],
		"kind": "editor",
		"versions": [],
		"title": "Instantiating a scene for read-only inspection runs @tool _init and setters, but not _ready",
		"truth": "Scene-file inspection (get_scene_structure scene_path) instantiates the tree briefly: @tool scripts' _init and property setters execute; _ready does not (the instance is never added to the tree).",
		"workaround": "Safe for structure reads. Keep @tool _init/setters side-effect-free, or accept the documented risk when inspecting unknown scenes.",
		"source": "get_scene_structure scene_path — 2026-09-28 audit fix (PR #170)",
	},
	{
		"id": "non-export-editor-binding",
		"api": "@export variable binding",
		"aliases": ["属性绑定", "property binding", "export 变量"],
		"kind": "editor",
		"versions": [],
		"title": "Non-@export script variables do not bind on editor scene nodes",
		"truth": "Batch set_property on editor scenes reports bound:false for non-@export vars (by design); the same variables work normally at game runtime.",
		"workaround": "Expose tuning knobs as @export when they must be editable/inspectable in the editor scene.",
		"source": "goal-playbook — known engine semantics",
	},
	{
		"id": "cold-script-resources",
		"api": "load() of freshly written scripts",
		"aliases": ["冷资源", "cold resource", "can_instantiate"],
		"kind": "editor",
		"versions": [],
		"title": "A just-written script file is a 'cold resource' until reimported",
		"truth": "Loading a script that was only just written can return a resource that cannot instantiate yet; the editor import pipeline needs a beat.",
		"workaround": "MCP tooling guards compiles internally; for manual load() of fresh files, check can_instantiate() and wait for the file system scan to settle.",
		"source": "goal-playbook — known engine semantics",
	},
	{
		"id": "editor-unfocused-throttling",
		"api": "Editor main loop throttling",
		"aliases": ["失焦节流", "background throttle", "长下载"],
		"kind": "editor",
		"versions": [],
		"title": "The editor may throttle the main loop while unfocused",
		"truth": "Long node-driven tasks (downloads, polling) can stall when the editor window loses focus due to main-loop throttling.",
		"workaround": "The plugin temporarily enables 'Update Continuously' for long jobs and restores it afterwards; user scripts doing long awaits should do the same or keep the editor focused.",
		"source": "goal-playbook — known engine semantics",
	},
	{
		"id": "engine-cli-stdio-noise",
		"api": "godot --headless stdio flags",
		"aliases": ["命令行", "cli", "--quiet", "--no-header", "--log-file", "stdout"],
		"kind": "cli",
		"versions": [],
		"title": "Engine CLI stdio facts: --quiet eats prints, --log-file breaks responses, --no-header only strips the banner",
		"truth": "The engine shares stdout with progress noise (appears any time). --quiet swallows print output entirely; --log-file redirects tool responses too (breaking stdio transports); --no-header (4.6+) removes only the banner. The editor survives EOF on stdin.",
		"workaround": "For stdio MCP transports rely on the plugin's framing, not on --quiet; never redirect stdout for stdio mode; treat stray progress lines on stdout as expected noise.",
		"source": "stdio transport hardening — measured engine facts",
	},
	{
		"id": "gut-cli-selector-semantics",
		"api": "GUT command line selectors",
		"aliases": ["GUT", "gut_cmdln", "gselect", "单文件测试"],
		"kind": "cli",
		"versions": [],
		"title": "GUT CLI: -gdir rejects single files; -gselect matches script names only; single tests need -gunit_test_name",
		"truth": "-gdir with a file path errors 'path does not exist'; -gselect matches the script name (use the bare stem like test_game_workflow_engine); running one test needs -gunit_test_name=<name>. Also: comma lists in -gselect are treated as one name and match nothing.",
		"workaround": "Select whole scripts with -gdir=res://test/unit -gselect=<stem>; single tests with -gunit_test_name; one -gselect pattern per invocation.",
		"source": "CI/runner hardening — measured GUT 9.7.1 semantics",
	},
	{
		"id": "hitstop-timescale-restore",
		"api": "Engine.time_scale (hitstop)",
		"aliases": ["hitstop", "顿帧", "time_scale 泄漏", "freeze"],
		"kind": "behavior",
		"versions": [],
		"title": "A hitstop that fails to restore Engine.time_scale freezes the game — restoration must be asserted",
		"truth": "Engine.time_scale dips without an ignore_time_scale timer never restore on their own; a leaked dip freezes the whole game. This is the single most common juice-effect defect.",
		"workaround": "Implement hitstop as time_scale dip + SceneTreeTimer with ignore_time_scale=true; verification contracts must assert time_scale returned to 1.0 in BOTH directions (dip engaged AND restored).",
		"source": "make_game_juice recipe — per-effect audit contracts",
	},
	{
		"id": "engine-set-meta-during-class-registration",
		"api": "Engine.set_meta() during update_scripts_classes",
		"aliases": ["set_meta 崩溃", "import segfault", "类注册阶段", "段错误", "exit 139"],
		"kind": "editor",
		"versions": [],
		"title": "Engine.set_meta() from code that runs during the global-class registration phase segfaults the editor",
		"truth": "If a plugin path that executes during --import (auto-started editor plugins run _enter_tree in that window) calls Engine.set_meta, the engine crashes with exit 139 inside update_scripts_classes — reproduced 3/3 on the import gate, independent of the stored value.",
		"workaround": "Defer Engine.set_meta to runtime (e.g. a server_started callback); never touch Engine metadata from class-registration-adjacent code paths.",
		"source": "custom tools API landing — 2026-09-28 CI import-gate forensics (PR #172)",
	},
	{
		"id": "skeleton2d-chain-motion",
		"api": "Skeleton2D / Bone2D",
		"aliases": ["骨骼链", "bone chain", "skeleton", "摆幅"],
		"kind": "api",
		"versions": [],
		"title": "2D bone chains propagate parent rotation per frame — chain semantics are assertable by sampling",
		"truth": "A Skeleton2D + Bone2D hierarchy with a visual child at the tip: incrementing parent bone rotation per frame moves the child bone tip ~101.8px while the visual child follows at ~97.5px — the motion chain is measurable by timeline sampling.",
		"workaround": "Assert skeletal motion by sampling tip/global positions per frame rather than bone-local transforms.",
		"source": "2D breadth matrix — engine truths (2026-09-26)",
	},
]

## 按查询词确定性检索：api 名命中 > 别名命中 > 正文命中；同级按 id 字典序。
## 返回 {"matches": [...], "count": int, "total_entries": int, "kinds": {...}}。
static func query(query_text: String, engine_version: String = "", limit: int = 8) -> Dictionary:
	var normalized: String = query_text.strip_edges().to_lower()
	var matches: Array = []
	if not normalized.is_empty():
		for entry in ENTRIES:
			var score: int = _match_score(entry, normalized)
			if score > 0:
				var scored: Dictionary = entry.duplicate(true)
				scored["match_score"] = score
				matches.append(scored)
		matches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["match_score"]) != int(b["match_score"]):
				return int(a["match_score"]) > int(b["match_score"])
			return String(a["id"]) < String(b["id"])
		)
	var filtered: Array = matches
	if not engine_version.strip_edges().is_empty():
		var version: String = engine_version.strip_edges()
		filtered = []
		for entry in matches:
			var versions: Array = entry.get("versions", [])
			if versions.is_empty() or versions.has(version):
				filtered.append(entry)
	if limit > 0 and filtered.size() > limit:
		filtered = filtered.slice(0, limit)
	return {
		"matches": filtered,
		"count": filtered.size(),
		"total_entries": ENTRIES.size(),
	}

static func _match_score(entry: Dictionary, normalized: String) -> int:
	var api: String = String(entry.get("api", "")).to_lower()
	if api == normalized:
		return 100
	if api.contains(normalized) or normalized.contains(api):
		return 80
	for alias_value in entry.get("aliases", []):
		var alias: String = String(alias_value).to_lower()
		if alias == normalized:
			return 60
		if alias.contains(normalized) or normalized.contains(alias):
			return 40
	var haystack: String = (String(entry.get("title", "")) + " "
		+ String(entry.get("truth", "")) + " " + String(entry.get("workaround", ""))).to_lower()
	for word in normalized.split(" ", false):
		if word.length() >= 3 and haystack.contains(word):
			return 20
	return 0

## 目录概览：kind 分组计数 + 全部 api 名清单（供无命中时的自愈提示）。
static func overview() -> Dictionary:
	var kinds: Dictionary = {}
	var apis: Array = []
	for entry in ENTRIES:
		var kind: String = String(entry.get("kind", "api"))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		apis.append(String(entry.get("api", "")))
	return {"kinds": kinds, "apis": apis, "total_entries": ENTRIES.size()}
