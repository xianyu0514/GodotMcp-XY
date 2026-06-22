extends "res://addons/gut/test.gd"

const ProviderScript = preload("res://addons/godot_mcp/native_mcp/mcp_cloudflared_provider.gd")

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

func test_download_target_uses_asset_name():
	var target: String = ProviderScript.download_target("linux-amd64")
	assert_true(target.ends_with("cloudflared-linux-amd64"), "Target path should keep the asset file name")

func test_verify_checksum_unknown_key_is_false():
	assert_false(ProviderScript.verify_checksum("user://nope", "no-such-key"))
