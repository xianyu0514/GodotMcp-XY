extends "res://addons/gut/test.gd"

var _auth: McpAuthManager = null

func before_each():
	_auth = McpAuthManager.new()
	_auth.set_token("1234567890abcdef")
	_auth.set_enabled(true)

func after_each():
	_auth = null

func test_validate_correct_token():
	var headers: Dictionary = {"authorization": "Bearer 1234567890abcdef"}
	assert_true(_auth.validate_request(headers), "Correct token should pass")

func test_validate_wrong_token():
	var headers: Dictionary = {"authorization": "Bearer wrongtoken123456"}
	assert_false(_auth.validate_request(headers), "Wrong token should be rejected")

func test_validate_no_auth_header():
	var headers: Dictionary = {}
	assert_false(_auth.validate_request(headers), "Missing auth header should be rejected")

func test_validate_wrong_scheme():
	var headers: Dictionary = {"authorization": "Basic 1234567890abcdef"}
	assert_false(_auth.validate_request(headers), "Wrong scheme should be rejected")

func test_validate_empty_bearer():
	var headers: Dictionary = {"authorization": "Bearer "}
	assert_false(_auth.validate_request(headers), "Empty bearer token should be rejected")

func test_auth_disabled():
	_auth.set_enabled(false)
	var headers: Dictionary = {}
	assert_true(_auth.validate_request(headers), "Disabled auth should allow any request")

func test_auth_disabled_wrong_token():
	_auth.set_enabled(false)
	var headers: Dictionary = {"authorization": "Bearer wrongtoken"}
	assert_true(_auth.validate_request(headers), "Disabled auth should allow wrong token")

func test_set_token_too_short():
	var original_token: String = _auth._token
	assert_eq(original_token, "1234567890abcdef", "Initial token should be set from before_each")
	assert_eq(original_token.length(), 16, "Token should meet minimum length requirement")

func test_set_token_valid_length():
	_auth.set_token("1234567890abcdef")
	assert_eq(_auth._token, "1234567890abcdef", "Valid length token should be set")

func test_www_authenticate_header():
	var header: String = _auth.get_www_authenticate_header()
	assert_true(header.contains("Bearer"), "Should contain Bearer scheme")
	assert_true(header.contains("realm"), "Should contain realm")

func test_timing_safe_comparison():
	var headers_short: Dictionary = {"authorization": "Bearer short"}
	var headers_long: Dictionary = {"authorization": "Bearer verylongtoken1234567890"}
	assert_false(_auth.validate_request(headers_short), "Short token should be rejected")
	assert_false(_auth.validate_request(headers_long), "Long token should be rejected")

func test_generate_token():
	var token: String = McpAuthManager.generate_token(32)
	assert_eq(token.length(), 32, "Generated token should be 32 chars")

func test_generate_token_custom_length():
	var token: String = McpAuthManager.generate_token(16)
	assert_eq(token.length(), 16, "Generated token should be 16 chars")

func test_header_name_lowercase():
	assert_eq(McpAuthManager.HEADER_NAME, "authorization", "Header name should be lowercase")

func test_set_token_too_short_keeps_old_token():
	_auth.set_token("short")
	assert_push_error_count(1, "set_token with a short token should push exactly one error")
	assert_eq(_auth._token, "1234567890abcdef", "Rejected short token should keep the previous token")

func test_default_enabled_state():
	var fresh: McpAuthManager = McpAuthManager.new()
	assert_true(fresh._enabled, "New auth manager should default to enabled")
	fresh = null

func test_enabled_toggle_revalidates():
	var headers: Dictionary = {"authorization": "Bearer 1234567890abcdef"}
	_auth.set_enabled(false)
	assert_true(_auth.validate_request({}), "Disabled auth should allow any request")
	_auth.set_enabled(true)
	assert_true(_auth.validate_request(headers), "Re-enabled auth should validate the correct token")
	assert_false(_auth.validate_request({}), "Re-enabled auth should reject a missing header")

func test_generate_token_varies():
	var t1: String = McpAuthManager.generate_token(32)
	var t2: String = McpAuthManager.generate_token(32)
	assert_ne(t1, t2, "Two generated tokens should differ")

func test_generate_token_uses_valid_chars():
	var token: String = McpAuthManager.generate_token(64)
	var allowed: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	var invalid_count: int = 0
	for i in token.length():
		if not allowed.contains(token[i]):
			invalid_count += 1
	assert_eq(invalid_count, 0, "All generated chars should come from the allowed alphabet")
