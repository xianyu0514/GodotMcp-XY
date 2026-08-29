extends "res://addons/gut/test.gd"

const ProviderScript = preload("res://addons/godot_mcp/native_mcp/mcp_cloudflared_provider.gd")

var _tmp_root: String = ""

func before_each() -> void:
	_tmp_root = ProjectSettings.globalize_path(
		"user://.tmp_cloudflared_provider_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	)
	DirAccess.make_dir_recursive_absolute(_tmp_root)

func after_each() -> void:
	_remove_recursive(_tmp_root)

func _remove_recursive(path: String) -> void:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full_path: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(full_path)
		else:
			DirAccess.remove_absolute(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

func _write_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file, "Test fixture should be writable")
	if file != null:
		file.store_string(content)
		file.close()

func test_platform_key_windows_amd64():
	assert_eq(ProviderScript.platform_key("Windows", "amd64"), "windows-amd64")

func test_platform_key_linux_arm64():
	assert_eq(ProviderScript.platform_key("Linux", "arm64"), "linux-arm64")

func test_platform_key_macos_arm64():
	assert_eq(ProviderScript.platform_key("macOS", "arm64"), "macos-arm64")

func test_platform_key_unknown_os_is_empty():
	assert_eq(ProviderScript.platform_key("Haiku", "amd64"), "", "Unsupported OS should map to empty key")

func test_platform_key_unknown_arch_is_empty():
	assert_eq(ProviderScript.platform_key("Windows", "riscv"), "", "Unsupported arch should map to empty key")

func test_asset_name_matches_official_filenames():
	assert_eq(ProviderScript.asset_name("windows-amd64"), "cloudflared-windows-amd64.exe")
	assert_eq(ProviderScript.asset_name("linux-amd64"), "cloudflared-linux-amd64")
	assert_eq(ProviderScript.asset_name("macos-arm64"), "cloudflared-darwin-arm64.tgz")

func test_download_url_is_pinned_release():
	var url: String = ProviderScript.download_url("windows-amd64")
	var expected: String = "%s/%s/cloudflared-windows-amd64.exe" % [ProviderScript.RELEASE_BASE, ProviderScript.VERSION]
	assert_eq(url, expected, "URL should point at the pinned release asset")

func test_download_url_unknown_key_is_empty():
	assert_eq(ProviderScript.download_url("solaris-sparc"), "", "Unknown key should produce no URL")

func test_download_urls_first_is_official_direct():
	var urls: PackedStringArray = ProviderScript.download_urls("windows-amd64")
	assert_true(urls.size() >= 1, "Should have at least the official URL")
	assert_eq(urls[0], ProviderScript.download_url("windows-amd64"), "First candidate should be the direct official URL")

func test_download_urls_appends_mirror_prefixes():
	var urls: PackedStringArray = ProviderScript.download_urls("windows-amd64")
	var official: String = ProviderScript.download_url("windows-amd64")
	assert_eq(urls.size(), ProviderScript.MIRROR_PREFIXES.size(), "One candidate per mirror prefix")
	for i in range(1, urls.size()):
		var prefix: String = ProviderScript.MIRROR_PREFIXES[i]
		assert_eq(urls[i], prefix + official, "Mirror candidate should prepend its prefix to the official URL")
		assert_true(urls[i].ends_with(official), "Mirror candidate should still target the official asset URL")

func test_download_urls_unknown_key_is_empty():
	assert_eq(ProviderScript.download_urls("solaris-sparc").size(), 0, "Unknown key should produce no candidates")

func test_checksums_are_64_hex_chars():
	for key in ProviderScript.ASSETS.keys():
		var sum: String = ProviderScript.checksum(key)
		assert_eq(sum.length(), 64, "SHA256 for %s should be 64 hex chars" % key)
		assert_true(sum.is_valid_hex_number(false), "SHA256 for %s should be hex" % key)

func test_every_asset_has_a_checksum():
	for key in ProviderScript.ASSETS.keys():
		assert_true(ProviderScript.CHECKSUMS.has(key), "Asset %s must have a checksum entry" % key)

func test_is_archive_only_for_tgz():
	assert_true(ProviderScript.is_archive("macos-amd64"), "macOS asset is a tarball")
	assert_false(ProviderScript.is_archive("linux-amd64"), "Linux asset is a raw binary")
	assert_false(ProviderScript.is_archive("windows-amd64"), "Windows asset is a raw .exe")

func test_binary_path_extension_by_os():
	assert_true(ProviderScript.binary_path("windows-amd64").ends_with("cloudflared.exe"))
	assert_true(ProviderScript.binary_path("linux-amd64").ends_with("cloudflared"))
	assert_false(ProviderScript.binary_path("linux-amd64").ends_with(".exe"))

func test_managed_install_dir_is_absolute_and_shared_between_projects():
	var install_dir: String = ProviderScript.install_dir("linux-amd64")
	assert_true(install_dir.is_absolute_path(), "Managed downloads should use a machine-wide absolute path")
	assert_false(install_dir.begins_with("user://"), "Managed downloads must not follow the current project's user://")
	assert_eq(ProviderScript.binary_path("linux-amd64").get_base_dir(), install_dir)
	assert_true(install_dir.contains(ProviderScript.VERSION), "Pinned versions should not overwrite one another")
	assert_ne(
		ProviderScript.install_dir("linux-amd64"),
		ProviderScript.install_dir("linux-arm64"),
		"Different architectures should not overwrite one another"
	)

func test_legacy_install_dir_keeps_the_old_project_local_location():
	assert_eq(
		ProviderScript.legacy_install_dir(),
		ProjectSettings.globalize_path("user://cloudflared"),
		"Legacy downloads should remain discoverable for migration"
	)

func test_legacy_install_dirs_find_other_godot_project_caches():
	var app_userdata: String = _tmp_root.path_join("app_userdata")
	var current_project: String = app_userdata.path_join("project-a")
	var other_project: String = app_userdata.path_join("project-b")
	DirAccess.make_dir_recursive_absolute(current_project)
	DirAccess.make_dir_recursive_absolute(other_project)

	var legacy_dirs: PackedStringArray = ProviderScript.legacy_install_dirs(current_project)
	assert_eq(legacy_dirs[0], current_project.path_join("cloudflared"), "Current project cache should be checked first")
	assert_true(
		legacy_dirs.has(other_project.path_join("cloudflared")),
		"A verified download from another Godot project should be reusable"
	)

func test_download_target_uses_asset_name():
	var target: String = ProviderScript.download_target("linux-amd64")
	assert_true(target.ends_with("cloudflared-linux-amd64"), "Target path should keep the asset file name")
	assert_eq(target.get_base_dir(), ProviderScript.install_dir("linux-amd64"), "Downloads should land in the shared cache")

func test_path_binary_candidates_parse_and_deduplicate_unix_path():
	var first: String = _tmp_root.path_join("first")
	var second: String = _tmp_root.path_join("second")
	var candidates: PackedStringArray = ProviderScript.path_binary_candidates(
		"%s:%s:%s" % [first, second, first], "Linux"
	)
	assert_eq(candidates.size(), 2, "Equivalent PATH entries should not be probed twice")
	assert_eq(candidates[0], first.path_join("cloudflared"))
	assert_eq(candidates[1], second.path_join("cloudflared"))

func test_path_binary_candidates_support_quoted_windows_entries():
	var candidates: PackedStringArray = ProviderScript.path_binary_candidates(
		'"C:\\Program Files\\Cloudflare";C:\\Tools', "Windows"
	)
	assert_eq(candidates.size(), 2)
	assert_eq(candidates[0], "C:/Program Files/Cloudflare/cloudflared.exe")
	assert_eq(candidates[1], "C:/Tools/cloudflared.exe")

func test_path_binary_candidates_remove_trailing_windows_separators():
	var candidates: PackedStringArray = ProviderScript.path_binary_candidates(
		"C:\\Program Files (x86)\\cloudflared\\;C:/Tools/cloudflared/", "Windows"
	)
	assert_eq(candidates.size(), 2)
	assert_eq(candidates[0], "C:/Program Files (x86)/cloudflared/cloudflared.exe")
	assert_eq(candidates[1], "C:/Tools/cloudflared/cloudflared.exe")
	assert_false(candidates[0].contains("\\/"), "Windows PATH reuse must never emit the observed mixed separator")

func test_find_existing_user_binary_prefers_explicit_path_over_path_env():
	var manual: String = _tmp_root.path_join("manual/cloudflared")
	var system_dir: String = _tmp_root.path_join("system")
	var system_binary: String = system_dir.path_join("cloudflared")
	_write_file(manual, "manual")
	_write_file(system_binary, "system")

	var found: Dictionary = ProviderScript.find_existing_user_binary(manual, system_dir, "Linux")
	assert_eq(found.get("path", ""), manual)
	assert_eq(found.get("source", ""), "configured")

func test_find_existing_user_binary_falls_back_to_path_env():
	var system_dir: String = _tmp_root.path_join("system")
	var system_binary: String = system_dir.path_join("cloudflared")
	_write_file(system_binary, "system")

	var found: Dictionary = ProviderScript.find_existing_user_binary(
		_tmp_root.path_join("missing/cloudflared"), system_dir, "Linux"
	)
	assert_eq(found.get("path", ""), system_binary)
	assert_eq(found.get("source", ""), "system_path")

func test_migrate_verified_binary_copies_only_matching_content():
	var source: String = _tmp_root.path_join("legacy/cloudflared")
	var destination: String = _tmp_root.path_join("shared/cloudflared")
	_write_file(source, "verified cloudflared fixture")
	var expected: String = FileAccess.get_sha256(source)

	assert_true(ProviderScript.migrate_verified_binary(source, destination, expected))
	assert_true(FileAccess.file_exists(destination))
	assert_eq(FileAccess.get_sha256(destination), expected)
	assert_false(
		ProviderScript.migrate_verified_binary(source, destination, "0".repeat(64)),
		"A mismatched legacy file must never replace the shared binary"
	)
	assert_eq(FileAccess.get_sha256(destination), expected, "Failed migration should preserve the good destination")

func test_verify_checksum_unknown_key_is_false():
	assert_false(ProviderScript.verify_checksum("user://nope", "no-such-key"))
