extends "res://addons/gut/test.gd"

# Unit tests for bump_version (ship-loop ⑦). Covers the pure semantic-version
# bump and changelog composition helpers, plus the tool's dry_run path (which
# computes the next version without writing project.godot or any file).

var _tools: RefCounted = null

func before_each() -> void:
	_tools = load("res://addons/godot_mcp/tools/project_tools_native.gd").new()

func after_each() -> void:
	_tools = null

# --- _bump_semver (pure) --------------------------------------------------

func test_bump_patch():
	assert_eq(str(_tools._bump_semver("1.2.3", "patch")["version"]), "1.2.4", "patch increments last")

func test_bump_minor_resets_patch():
	assert_eq(str(_tools._bump_semver("1.2.3", "minor")["version"]), "1.3.0", "minor resets patch")

func test_bump_major_resets_minor_and_patch():
	assert_eq(str(_tools._bump_semver("1.2.3", "major")["version"]), "2.0.0", "major resets minor+patch")

func test_bump_preserves_suffix():
	assert_eq(str(_tools._bump_semver("1.0.7-pre1", "patch")["version"]), "1.0.8-pre1", "suffix preserved")

func test_bump_pads_short_version():
	assert_eq(str(_tools._bump_semver("1", "patch")["version"]), "1.0.1", "short version padded")

func test_bump_rejects_non_numeric():
	assert_true(_tools._bump_semver("1.x.0", "patch").has("error"), "non-numeric component errors")

func test_bump_rejects_bad_part():
	assert_true(_tools._bump_semver("1.0.0", "nope").has("error"), "invalid part errors")

# --- _compose_changelog (pure) --------------------------------------------

func test_compose_inserts_after_title():
	var existing: String = "# Changelog\n\n## 1.0.0 - 2020-01-01\n\n- old\n"
	var out: String = _tools._compose_changelog(existing, "1.0.1", "2026-06-23", "new thing")
	var idx_new: int = out.find("## 1.0.1 - 2026-06-23")
	var idx_old: int = out.find("## 1.0.0 - 2020-01-01")
	assert_true(idx_new != -1, "new entry present")
	assert_true(idx_new < idx_old, "new entry inserted before old one")
	assert_true(out.find("# Changelog") < idx_new, "title stays on top")

func test_compose_seeds_when_empty():
	var out: String = _tools._compose_changelog("", "1.0.0", "2026-06-23", "first")
	assert_true(out.find("# Changelog") != -1, "seeds a Changelog title")
	assert_true(out.find("## 1.0.0 - 2026-06-23") != -1, "includes the new version")

func test_compose_default_bullet_when_no_entry():
	var out: String = _tools._compose_changelog("# Changelog\n", "2.0.0", "2026-06-23", "")
	assert_true(out.find("Release 2.0.0") != -1, "default bullet used when entry empty")

# --- tool dry_run ---------------------------------------------------------

func test_dry_run_computes_without_writing():
	var prev: String = str(ProjectSettings.get_setting("application/config/version", ""))
	var r: Dictionary = _tools._tool_bump_version({"bump": "minor", "dry_run": true})
	assert_true(bool(r.get("success", false)), "dry_run succeeds")
	assert_false(bool(r.get("version_written", true)), "dry_run does not write version")
	assert_false(bool(r.get("changelog_written", true)), "dry_run does not write changelog")
	assert_eq(str(ProjectSettings.get_setting("application/config/version", "")), prev, "project version unchanged")

func test_explicit_version_overrides_bump():
	var r: Dictionary = _tools._tool_bump_version({"version": "9.9.9", "bump": "major", "dry_run": true})
	assert_eq(str(r.get("new_version", "")), "9.9.9", "explicit version wins over bump")
