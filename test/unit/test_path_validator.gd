extends "res://addons/gut/test.gd"

var _validator: PathValidator = null

func before_each():
	_validator = PathValidator.new()

func after_each():
	_validator = null

func test_validate_res_path():
	var result: Dictionary = PathValidator.validate_path("res://test.tscn")
	assert_true(result["valid"], "res:// path should be valid")
	assert_eq(result["sanitized"], "res://test.tscn", "Sanitized path should match")

func test_validate_res_subdir():
	var result: Dictionary = PathValidator.validate_path("res://scripts/player.gd")
	assert_true(result["valid"], "res:// subdirectory path should be valid")

func test_validate_user_path():
	var result: Dictionary = PathValidator.validate_path("user://save.dat")
	assert_true(result["valid"], "user:// path should be valid")

func test_reject_empty_path():
	var result: Dictionary = PathValidator.validate_path("")
	assert_false(result["valid"], "Empty path should be rejected")
	assert_ne(result["error"], "", "Should have error message")

func test_reject_path_traversal():
	var result: Dictionary = PathValidator.validate_path("res://../etc/passwd")
	assert_false(result["valid"], "Path traversal should be rejected")

func test_reject_absolute_linux_path():
	var result: Dictionary = PathValidator.validate_path("/etc/passwd")
	assert_false(result["valid"], "Absolute Linux path should be rejected")

func test_reject_windows_path():
	var result: Dictionary = PathValidator.validate_path("C:\\Windows\\System32")
	assert_false(result["valid"], "Windows path should be rejected")

func test_reject_home_directory():
	var result: Dictionary = PathValidator.validate_path("~/secret")
	assert_false(result["valid"], "Home directory path should be rejected")

func test_reject_macos_users_path():
	var result: Dictionary = PathValidator.validate_path("/Users/admin/.ssh")
	assert_false(result["valid"], "macOS Users path should be rejected")

func test_reject_macos_library_path():
	var result: Dictionary = PathValidator.validate_path("/Library/Preferences")
	assert_false(result["valid"], "macOS Library path should be rejected")

func test_reject_macos_applications_path():
	var result: Dictionary = PathValidator.validate_path("/Applications/Xcode.app")
	assert_false(result["valid"], "macOS Applications path should be rejected")

func test_dangerous_patterns_includes_macos():
	var has_users: bool = PathValidator.DANGEROUS_PATTERNS.has("/Users/")
	var has_library: bool = PathValidator.DANGEROUS_PATTERNS.has("/Library/")
	var has_applications: bool = PathValidator.DANGEROUS_PATTERNS.has("/Applications/")
	assert_true(has_users, "Should include /Users/ in dangerous patterns")
	assert_true(has_library, "Should include /Library/ in dangerous patterns")
	assert_true(has_applications, "Should include /Applications/ in dangerous patterns")

func test_non_strict_allows_more():
	var result: Dictionary = PathValidator.validate_path("res://../escape.tscn", false)
	assert_true(result["valid"], "Non-strict mode should allow traversal patterns")

func test_validate_file_path_with_extension():
	var result: Dictionary = PathValidator.validate_file_path("res://script.gd", ["gd"])
	assert_true(result["valid"], "Allowed extension should pass")

func test_validate_file_path_wrong_extension():
	var result: Dictionary = PathValidator.validate_file_path("res://data.json", ["gd", "tscn"])
	assert_false(result["valid"], "Disallowed extension should be rejected")

func test_validate_directory_path():
	var result: Dictionary = PathValidator.validate_directory_path("res://scripts")
	assert_true(result["valid"], "Directory path should be valid")

func test_validate_directory_path_adds_slash():
	var result: Dictionary = PathValidator.validate_directory_path("res://scripts")
	assert_true(result["sanitized"].ends_with("/"), "Directory path should end with /")

func test_validate_paths_batch():
	var result: Dictionary = PathValidator.validate_paths([
		"res://test.tscn",
		"/etc/passwd",
		"user://save.dat"
	])
	assert_eq(result["valid"].size(), 2, "Should have 2 valid paths")
	assert_eq(result["invalid"].size(), 1, "Should have 1 invalid path")

func test_validate_path_with_signal_approved():
	watch_signals(_validator)
	_validator.set_strict_mode(true)
	var result: bool = _validator.validate_path_with_signal("res://test.tscn")
	assert_true(result, "Should return true for valid path")
	assert_signal_emitted(_validator, "path_approved")

func test_validate_path_with_signal_rejected():
	watch_signals(_validator)
	_validator.set_strict_mode(true)
	var result: bool = _validator.validate_path_with_signal("C:\\Windows")
	assert_false(result, "Should return false for invalid path")
	assert_signal_emitted(_validator, "path_rejected")

func test_set_strict_mode():
	_validator.set_strict_mode(false)
	assert_false(_validator._strict_mode, "Strict mode should be false")
	_validator.set_strict_mode(true)
	assert_true(_validator._strict_mode, "Strict mode should be true")

func test_add_allowed_extension():
	_validator.add_allowed_extension(".gd")
	assert_has(_validator._allowed_extensions, ".gd", "Should contain .gd")

func test_add_allowed_extension_no_duplicate():
	_validator.add_allowed_extension(".gd")
	_validator.add_allowed_extension(".gd")
	var count: int = 0
	for ext in _validator._allowed_extensions:
		if ext == ".gd":
			count += 1
	assert_eq(count, 1, "Should not have duplicates")

func test_clear_allowed_extensions():
	_validator.add_allowed_extension(".gd")
	_validator.clear_allowed_extensions()
	assert_eq(_validator._allowed_extensions.size(), 0, "Should be empty after clear")

# --- P2-16 回归（2026-09-30 体检）：绝对路径曾被兜底前缀洗成 res://C:/...
# 而通过校验 → 空成功伪装。现显式拒绝。 ---
func test_rejects_drive_letter_absolute_path():
	var result: Dictionary = PathValidator.validate_directory_path("C:/Users")
	assert_false(result["valid"], "盘符绝对路径必须拒绝")
	assert_true(str(result["error"]).contains("Absolute paths are not allowed"))

func test_rejects_unc_and_double_slash_paths():
	assert_false(PathValidator.validate_path("//server/share")["valid"], "UNC 路径必须拒绝")
	assert_false(PathValidator.validate_path("server" + String.chr(92) + String.chr(92) + "share")["valid"], "UNC 路径必须拒绝")

func test_res_and_user_paths_still_valid():
	assert_true(PathValidator.validate_path("res://scenes/main.tscn")["valid"])
	assert_true(PathValidator.validate_path("user://settings.cfg")["valid"])

func test_traversal_inside_res_still_sanitized():
	var result: Dictionary = PathValidator.validate_directory_path("res://../outside")
	assert_true(result["valid"], "res:// 内的 ../ 由既有清洗处理")
	assert_false(str(result["sanitized"]).contains(".."), "清洗后不得残留 ..")
