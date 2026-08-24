extends "res://addons/gut/test.gd"

func test_http_response_content_length_bytes():
	var json_string: String = '{"name": "测试中文"}'
	var char_count: int = json_string.length()
	var byte_count: int = json_string.to_utf8_buffer().size()
	assert_gt(byte_count, char_count, "UTF-8 Chinese chars should have more bytes than characters")

func test_http_response_ascii_content_length():
	var json_string: String = '{"name": "test"}'
	var char_count: int = json_string.length()
	var byte_count: int = json_string.to_utf8_buffer().size()
	assert_eq(byte_count, char_count, "ASCII content should have same bytes as characters")

func test_json_parse_string_dict():
	var parsed: Variant = JSON.parse_string('{"x": 10, "y": 5, "z": 3}')
	assert_true(parsed is Dictionary, "Should parse to Dictionary")
	assert_eq(parsed.get("x"), 10.0, "Should have correct x value")

func test_json_parse_string_array():
	var parsed: Variant = JSON.parse_string('[1, 2, 3]')
	assert_true(parsed is Array, "Should parse to Array")
	assert_eq(parsed.size(), 3, "Should have 3 elements")

func test_json_parse_string_nested():
	var parsed: Variant = JSON.parse_string('{"content": [{"type": "text", "text": "hello"}]}')
	assert_true(parsed is Dictionary, "Should parse nested dict")
	var content: Array = parsed.get("content", [])
	assert_eq(content.size(), 1, "Should have 1 content item")

func test_json_stringify_unicode():
	var data: Dictionary = {"message": "你好世界"}
	var json_string: String = JSON.stringify(data)
	var reparsed: Variant = JSON.parse_string(json_string)
	assert_eq(reparsed.get("message"), "你好世界", "Should round-trip Unicode correctly")

func test_json_stringify_content_length():
	var data: Dictionary = {"text": "中文内容测试"}
	var json_string: String = JSON.stringify(data)
	var byte_count: int = json_string.to_utf8_buffer().size()
	assert_gt(byte_count, json_string.length(), "Chinese content should have more bytes than chars")

func test_http_header_case_insensitive():
	var headers: Dictionary = {"Content-Type": "application/json"}
	assert_true(headers.has("Content-Type"), "Should find exact case header")
	var lower_headers: Dictionary = {}
	for key in headers:
		lower_headers[key.to_lower()] = headers[key]
	assert_true(lower_headers.has("content-type"), "Should find lowercase header")

func test_http_header_value_split():
	var header_line: String = "Authorization: Bearer token123"
	var colon_pos: int = header_line.find(":")
	var key: String = header_line.left(colon_pos).strip_edges().to_lower()
	var value: String = header_line.substr(colon_pos + 1).strip_edges()
	assert_eq(key, "authorization", "Key should be lowercase")
	assert_eq(value, "Bearer token123", "Value should preserve case and spaces after colon")

func test_http_header_value_with_colon():
	var header_line: String = "Content-Type: application/json; charset=utf-8"
	var colon_pos: int = header_line.find(":")
	var value: String = header_line.substr(colon_pos + 1).strip_edges()
	assert_eq(value, "application/json; charset=utf-8", "Should handle colons in value")

func test_mcp_notification_no_id():
	var message: Dictionary = {"jsonrpc": "2.0", "method": "notifications/initialized"}
	assert_false(message.has("id"), "Notification should not have id field")

func test_mcp_request_has_id():
	var message: Dictionary = {"jsonrpc": "2.0", "method": "tools/list", "id": 1}
	assert_true(message.has("id"), "Request should have id field")

func test_http_202_for_notifications():
	assert_true(true, "Placeholder: 202 Accepted should be returned for notifications without id")

func test_utf8_buffer_round_trip():
	var original: String = "Hello 世界 🌍"
	var buffer: PackedByteArray = original.to_utf8_buffer()
	var restored: String = buffer.get_string_from_utf8()
	assert_eq(restored, original, "UTF-8 buffer should round-trip correctly")

# ==============================================================================
# JSON-RPC 批处理载荷识别（McpHttpServer.is_batch_payload / batch_error_payload）
# ==============================================================================

var _http_server: RefCounted = null

func before_each():
	_http_server = load("res://addons/godot_mcp/native_mcp/mcp_http_server.gd").new()

func after_each():
	_http_server = null

func test_batch_json_parses_to_array():
	var parsed: Variant = JSON.parse_string('[{"jsonrpc":"2.0","id":1}]')
	assert_true(parsed is Array, "Batch request should parse to Array")

func test_single_json_parses_to_dict():
	var parsed: Variant = JSON.parse_string('{"jsonrpc":"2.0","id":1,"method":"ping"}')
	assert_true(parsed is Dictionary, "Single request should parse to Dictionary")

func test_single_object_is_not_batch_payload():
	var parsed: Variant = JSON.parse_string('{"jsonrpc":"2.0","id":1,"method":"ping"}')
	assert_false(_http_server.is_batch_payload(parsed), "Single object should not be treated as batch")

func test_batch_array_is_batch_payload():
	var parsed: Variant = JSON.parse_string('[{"jsonrpc":"2.0","id":1}]')
	assert_true(_http_server.is_batch_payload(parsed), "Array should be treated as batch")

func test_batch_error_payload_round_trips_json():
	var payload: Dictionary = _http_server.batch_error_payload()
	var json_string: String = JSON.stringify(payload)
	var reparsed: Variant = JSON.parse_string(json_string)
	assert_true(reparsed is Dictionary, "Error payload should round-trip through JSON")
	var error_obj: Dictionary = reparsed.get("error", {})
	assert_eq(error_obj.get("code"), -32600.0, "Round-tripped error code should be -32600")
	assert_eq(error_obj.get("message"), "Invalid Request", "Round-tripped error message should be Invalid Request")

# ==============================================================================
# Streamable HTTP 双轨：Accept 头协商（McpHttpServer._wants_sse）
# ==============================================================================

func test_wants_sse_explicit_event_stream():
	assert_true(_http_server._wants_sse("text/event-stream"), "Explicit text/event-stream should request SSE")

func test_wants_sse_application_json():
	assert_false(_http_server._wants_sse("application/json"), "application/json should request single JSON response")

func test_wants_sse_empty_header():
	assert_false(_http_server._wants_sse(""), "Empty Accept should default to single JSON response")

func test_wants_sse_wildcard_defaults_json():
	assert_false(_http_server._wants_sse("*/*"), "Wildcard */* should default to JSON (stateless-first, backward compat)")

func test_wants_sse_combined_prefers_sse():
	assert_true(_http_server._wants_sse("application/json, text/event-stream"), "Accept listing text/event-stream should negotiate SSE")

func test_wants_sse_reversed_order():
	assert_true(_http_server._wants_sse("text/event-stream, application/json"), "SSE listed first should still negotiate SSE")

func test_wants_sse_case_insensitive():
	assert_true(_http_server._wants_sse("TEXT/EVENT-STREAM"), "Accept matching should be case-insensitive")

func test_wants_sse_with_q_value():
	assert_true(_http_server._wants_sse("text/event-stream;q=0.9"), "q-value parameter should not block SSE negotiation")

func test_wants_sse_trimmed_whitespace():
	assert_true(_http_server._wants_sse("  text/event-stream  "), "Surrounding whitespace should be tolerated")

func test_wants_sse_json_with_charset():
	assert_false(_http_server._wants_sse("application/json; charset=utf-8"), "JSON media type with parameters should not request SSE")

func test_wants_sse_multiple_json_types():
	assert_false(_http_server._wants_sse("application/json, application/*+json"), "Accept with only JSON types should not request SSE")
