extends "res://addons/gut/test.gd"

# Tests for prompts/get and resources/subscribe + resources/unsubscribe +
# notifications/resources/updated handling in mcp_server_core.gd, plus the
# real workflow prompts registered by native_mcp/prompt_workflows.gd.

var _core: RefCounted = null

class FakeTransport extends McpTransportBase:
	var sent: Array = []
	func send_raw_message(message: Dictionary) -> void:
		sent.append(message)
	func is_running() -> bool:
		return false

func before_each():
	_core = load("res://addons/godot_mcp/native_mcp/mcp_server_core.gd").new()

func after_each():
	if _core and _core.is_running():
		_core.stop()
	_core = null

func _register_dummy_resource(uri: String) -> void:
	_core.register_resource(uri, "Dummy", "application/json", func(_params): return {"text": "{}"}, "dummy resource")

# ---------------------------------------------------------------------------
# prompts/get
# ---------------------------------------------------------------------------

func test_prompt_get_missing_name_returns_error():
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {}})
	assert_true(resp.has("error"), "Empty name should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_INVALID_PARAMS, "Should be invalid params")

func test_prompt_get_unknown_returns_error():
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "does_not_exist"}})
	assert_true(resp.has("error"), "Unknown prompt should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_INVALID_PARAMS, "Should be invalid params")

func test_prompt_get_returns_callable_content():
	var no_args: Array[Dictionary] = []
	_core.register_prompt("greet", "Greet prompt", no_args, func(_args): return {"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}]})
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "greet"}})
	assert_true(resp.has("result"), "Should return a result")
	assert_eq(resp["result"]["messages"].size(), 1, "Should pass through callable messages")
	assert_eq(resp["result"]["description"], "Greet prompt", "Should default description to prompt description")

func test_prompt_get_missing_required_argument_errors():
	var args: Array[Dictionary] = [{"name": "topic", "description": "t", "required": true}]
	_core.register_prompt("topical", "Topical", args, func(_a): return {"messages": []})
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "topical", "arguments": {}}})
	assert_true(resp.has("error"), "Missing required argument should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_INVALID_PARAMS, "Should be invalid params")

func test_prompt_get_with_required_argument_present():
	var args: Array[Dictionary] = [{"name": "topic", "required": true}]
	_core.register_prompt("topical", "Topical", args, func(a): return {"messages": [{"role": "user", "content": {"type": "text", "text": a.get("topic", "")}}]})
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "topical", "arguments": {"topic": "dogs"}}})
	assert_true(resp.has("result"), "Should return a result")
	assert_eq(resp["result"]["messages"][0]["content"]["text"], "dogs", "Argument should reach the callable")

func test_prompt_get_without_callable_falls_back_to_description():
	var no_args: Array[Dictionary] = []
	_core.register_prompt("plain", "Plain description", no_args, Callable())
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "plain"}})
	assert_true(resp.has("result"), "Should return a result")
	assert_eq(resp["result"]["messages"], [], "Should default to empty messages")
	assert_eq(resp["result"]["description"], "Plain description", "Should use prompt description")

func test_prompt_get_callable_non_dictionary_errors():
	var no_args: Array[Dictionary] = []
	_core.register_prompt("bad", "Bad", no_args, func(_a): return "not a dict")
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "bad"}})
	assert_true(resp.has("error"), "Non-dictionary callable result should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_INTERNAL_ERROR, "Should be internal error")

func test_prompt_get_awaits_async_callable():
	var no_args: Array[Dictionary] = []
	_core.register_prompt("async_prompt", "Async", no_args, func(_a):
		await get_tree().process_frame
		return {"messages": [{"role": "user", "content": {"type": "text", "text": "async-ok"}}]})
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "async_prompt"}})
	assert_true(resp.has("result"), "Async callable should resolve to a result")
	assert_eq(resp["result"]["messages"][0]["content"]["text"], "async-ok", "Async message should pass through")

# ---------------------------------------------------------------------------
# resources/subscribe + unsubscribe
# ---------------------------------------------------------------------------

func test_subscribe_missing_uri_errors():
	var resp: Dictionary = _core._handle_resource_subscribe({"id": 1, "params": {}})
	assert_true(resp.has("error"), "Missing uri should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_INVALID_PARAMS, "Should be invalid params")

func test_subscribe_unknown_resource_errors():
	var resp: Dictionary = _core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://missing"}})
	assert_true(resp.has("error"), "Unknown resource should error")
	assert_eq(resp["error"]["code"], MCPTypes.ERROR_RESOURCE_NOT_FOUND, "Should be resource not found")

func test_subscribe_registers_subscription():
	_register_dummy_resource("godot://dummy")
	var resp: Dictionary = _core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://dummy"}})
	assert_true(resp.has("result"), "Subscribe should succeed")
	assert_true(_core.is_resource_subscribed("godot://dummy"), "Subscription should be tracked")

func test_unsubscribe_removes_subscription():
	_register_dummy_resource("godot://dummy")
	_core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://dummy"}})
	var resp: Dictionary = _core._handle_resource_unsubscribe({"id": 2, "params": {"uri": "godot://dummy"}})
	assert_true(resp.has("result"), "Unsubscribe should succeed")
	assert_false(_core.is_resource_subscribed("godot://dummy"), "Subscription should be removed")

func test_unregister_resource_drops_subscription():
	_register_dummy_resource("godot://dummy")
	_core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://dummy"}})
	_core.unregister_resource("godot://dummy")
	assert_false(_core.is_resource_subscribed("godot://dummy"), "Unregistering should drop subscription")

func test_stop_clears_subscriptions():
	_register_dummy_resource("godot://dummy")
	_core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://dummy"}})
	# stop() returns early unless the server is active; simulate a running server.
	_core._active = true
	_core.stop()
	assert_false(_core.is_resource_subscribed("godot://dummy"), "stop() should clear per-session subscriptions")

# ---------------------------------------------------------------------------
# notifications/resources/updated
# ---------------------------------------------------------------------------

func test_notify_resource_updated_sends_when_subscribed():
	_register_dummy_resource("godot://dummy")
	_core._handle_resource_subscribe({"id": 1, "params": {"uri": "godot://dummy"}})
	var fake: FakeTransport = FakeTransport.new()
	_core._transport = fake
	var sent: bool = _core.notify_resource_updated("godot://dummy")
	assert_true(sent, "Should report a notification was sent")
	assert_eq(fake.sent.size(), 1, "Exactly one notification should be sent")
	assert_eq(fake.sent[0]["method"], MCPTypes.NOTIFICATION_RESOURCES_UPDATED, "Should use resources/updated method")
	assert_eq(fake.sent[0]["params"]["uri"], "godot://dummy", "Should carry the uri")

func test_notify_resource_updated_skips_when_not_subscribed():
	_register_dummy_resource("godot://dummy")
	var fake: FakeTransport = FakeTransport.new()
	_core._transport = fake
	var sent: bool = _core.notify_resource_updated("godot://dummy")
	assert_false(sent, "Should not notify when not subscribed")
	assert_eq(fake.sent.size(), 0, "No notification should be sent")

# ---------------------------------------------------------------------------
# Real workflow prompts (native_mcp/prompt_workflows.gd)
# ---------------------------------------------------------------------------

func _new_workflows() -> RefCounted:
	return load("res://addons/godot_mcp/native_mcp/prompt_workflows.gd").new()

func test_prompts_registered():
	var workflows: RefCounted = _new_workflows()
	var prompts: Array[Dictionary] = workflows.get_prompts()
	assert_gte(prompts.size(), 6, "Should register at least 6 workflow prompts")
	var names: Array = []
	for p in prompts:
		var pname: String = String(p.get("name", ""))
		assert_false(pname.is_empty(), "Prompt name should not be empty")
		assert_false(String(p.get("description", "")).is_empty(), "Prompt description should not be empty")
		assert_true(p.get("arguments", null) is Array, "Prompt arguments should be an array")
		for arg in p["arguments"]:
			assert_false(String(arg.get("name", "")).is_empty(), "Argument name should not be empty")
			assert_true(arg.has("required"), "Argument should declare 'required'")
		names.append(pname)
	assert_true("plan_game_feature" in names, "plan_game_feature should be registered")
	assert_true("debug_runtime_error" in names, "debug_runtime_error should be registered")
	assert_true("onboard_new_project" in names, "onboard_new_project should be registered")

func test_prompt_plan_game_feature_messages():
	var workflows: RefCounted = _new_workflows()
	var result: Dictionary = workflows.get_callable("plan_game_feature").call({
		"gdd_summary": "A 2D platformer with 3 levels",
		"goal": "2D platformer vertical slice"
	})
	assert_true(result.has("messages"), "Should return messages")
	var messages: Array = result["messages"]
	assert_gte(messages.size(), 1, "Messages should be non-empty")
	var text: String = str(messages[0]["content"]["text"])
	assert_true(text.contains("manage_task_plan"), "Messages should reference manage_task_plan")
	assert_true(text.contains("A 2D platformer with 3 levels"), "gdd_summary should be embedded in the template")

func test_prompt_debug_runtime_error_messages():
	var workflows: RefCounted = _new_workflows()
	var error_text: String = "Invalid get index 'x' (on base: 'Nil')"
	var result: Dictionary = workflows.get_callable("debug_runtime_error").call({"error_text": error_text})
	assert_true(result.has("messages"), "Should return messages")
	var text: String = str(result["messages"][0]["content"]["text"])
	assert_true(text.contains(error_text), "error_text should be embedded in the template")
	assert_true(text.contains("get_editor_logs"), "Template should reference get_editor_logs")

func test_prompt_requires_arguments():
	var workflows: RefCounted = _new_workflows()
	var result: Dictionary = workflows.get_callable("plan_game_feature").call({"goal": "slice"})
	assert_true(result.has("error"), "Missing required argument should produce an error dictionary")
	assert_true(str(result["error"]).contains("gdd_summary"), "Error should name the missing argument")
	# With the argument present the same callable renders normally.
	var ok: Dictionary = workflows.get_callable("plan_game_feature").call({"gdd_summary": "s", "goal": "g"})
	assert_true(ok.has("messages"), "With arguments present the prompt should render")

func test_prompt_get_via_server_core():
	var workflows: RefCounted = _new_workflows()
	var count: int = workflows.register_to_server(_core)
	assert_gte(count, 6, "Should register prompts to the server core")
	var resp: Dictionary = await _core._handle_prompt_get({"id": 1, "params": {"name": "plan_game_feature", "arguments": {"gdd_summary": "s", "goal": "g"}}})
	assert_true(resp.has("result"), "prompts/get should succeed for a workflow prompt")
	assert_gte(resp["result"]["messages"].size(), 1, "prompts/get should return messages")
	assert_eq(resp["result"]["description"], "Turn a one-sentence GDD / feature request into an executable manage_task_plan task graph with gated Definition-of-Done, then hand off the first ready task.", "Description should fall back to the registered prompt description")
	var list_resp: Dictionary = await _core._handle_prompts_list({"id": 2, "params": {}})
	assert_true(list_resp.has("result"), "prompts/list should succeed")
	assert_gte(list_resp["result"]["prompts"].size(), 6, "prompts/list should expose the registered prompts")

func test_prompt_iterate_play_verify_messages():
	var workflows: RefCounted = _new_workflows()
	var result: Dictionary = workflows.get_callable("iterate_play_verify").call({
		"target": "enemy wave spawner holds 55 fps",
		"gates": "min_fps=55, no runtime errors"
	})
	assert_true(result.has("messages"), "Should return messages")
	var text: String = str(result["messages"][0]["content"]["text"])
	assert_true(text.contains("run_project"), "Template should reference run_project")
	assert_true(text.contains("assert_no_runtime_errors"), "Template should reference assert_no_runtime_errors")
	assert_true(text.contains("enemy wave spawner holds 55 fps"), "target should be embedded")
	assert_true(text.contains("min_fps=55"), "gates should be embedded")
	var missing: Dictionary = workflows.get_callable("iterate_play_verify").call({})
	assert_true(missing.has("error"), "Missing required target must fail")

func test_prompt_release_export_flow_messages():
	var workflows: RefCounted = _new_workflows()
	var result: Dictionary = workflows.get_callable("release_export_flow").call({
		"platform": "Windows Desktop", "notes": "patch bump"
	})
	assert_true(result.has("messages"), "Should return messages")
	var text: String = str(result["messages"][0]["content"]["text"])
	assert_true(text.contains("manage_export_templates"), "Template should reference manage_export_templates")
	assert_true(text.contains("smoke_test_export"), "Template should reference smoke_test_export")
	assert_true(text.contains("Windows Desktop"), "platform should be embedded")
	assert_true(text.contains("patch bump"), "notes should be embedded")
	var defaulted: Dictionary = workflows.get_callable("release_export_flow").call({})
	assert_true(defaulted.has("messages"), "No required args; defaults must render")
	assert_true(str(defaulted["messages"][0]["content"]["text"]).contains("default export preset"),
		"Empty platform falls back to the default preset wording")

func test_prompt_keyword_matcher_bilingual():
	var workflows: RefCounted = _new_workflows()
	var export_hit: Dictionary = workflows.match_prompt("帮我导出 Windows 版本并跑冒烟测试")
	assert_eq(String(export_hit.get("name", "")), "release_export_flow",
		"Chinese export/release wording routes to release_export_flow")
	var verify_hit: Dictionary = workflows.match_prompt("iterate the play loop and verify runtime errors stay zero")
	assert_eq(String(verify_hit.get("name", "")), "iterate_play_verify",
		"English iterate/verify wording routes to iterate_play_verify")
	var none_hit: Dictionary = workflows.match_prompt("completely unrelated sentence about tea")
	assert_true(none_hit.is_empty(), "Unrelated text matches no prompt")

func test_longer_keyword_wins_over_generic():
	var workflows: RefCounted = _new_workflows()
	var hit: Dictionary = workflows.match_prompt("fix compile errors then verify runtime error gates")
	assert_eq(String(hit.get("name", "")), "iterate_play_verify",
		"The longer 'runtime error' phrase beats shorter 'compile' for mixed intents")
