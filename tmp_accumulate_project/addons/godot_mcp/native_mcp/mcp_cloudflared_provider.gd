class_name MCPCloudflaredProvider
extends RefCounted

## Resolves, downloads and verifies the official Cloudflare connector (`cloudflared`)
## so the panel can start a free Quick Tunnel without the user installing anything.
##
## 解析 / 下载 / 校验官方 cloudflared 连接器，让面板一键开免费隧道、用户无需手动安装。
## 版本钉死 + 官方 SHA256 校验，避免供应链风险；下载逻辑由调用方（面板）用 HTTPRequest 驱动，
## 本类只负责纯映射（平台→资源/URL/校验和）、本地路径与校验，便于单元测试。

## Pinned cloudflared release. Bumping this requires updating CHECKSUMS below with
## the official values from the matching GitHub release notes.
const VERSION: String = "2026.5.2"
const RELEASE_BASE: String = "https://github.com/cloudflare/cloudflared/releases/download"

## platform key -> release asset file name (only single-binary / extractable assets).
const ASSETS: Dictionary = {
	"windows-amd64": "cloudflared-windows-amd64.exe",
	"windows-386": "cloudflared-windows-386.exe",
	"linux-amd64": "cloudflared-linux-amd64",
	"linux-arm64": "cloudflared-linux-arm64",
	"linux-arm": "cloudflared-linux-arm",
	"linux-386": "cloudflared-linux-386",
	"macos-amd64": "cloudflared-darwin-amd64.tgz",
	"macos-arm64": "cloudflared-darwin-arm64.tgz",
}

## platform key -> official SHA256 of the asset above (release VERSION).
const CHECKSUMS: Dictionary = {
	"windows-amd64": "20b9638f685333d623798e733effbad2487093f15ba592f6c7752360ff3b7ab7",
	"windows-386": "6736615e8d2b3b61e868e32907e85641b4ec7b2b8c26bd3361ec15e56e53e242",
	"linux-amd64": "5286698547f03df745adb2355f04c12dde52ef425491e81f433642d695521886",
	"linux-arm64": "5a4e8ce2701105271412059f44b6a0bf1ae4542b4d98ff3180c0c019443a5815",
	"linux-arm": "70a4c869a037bd69af6ce2ad0c4da4a7680d94fcfb8d4c70ecddae24d560762f",
	"linux-386": "ad82d1dbed8bbb9d702807cbd97df932cc774d29e9da5c109b7a3c7f7aee2065",
	"macos-amd64": "c4fdc6021cd63003e32e70b577e17d47d493c6df4e24c7c97169ed74b67a715d",
	"macos-arm64": "cd9f764abfd06757b4def10ee5ba3d862381ed9fc02d6c1f06086c23d88695c6",
}

## Managed downloads must not live under user://: that directory belongs to the
## currently open Godot project and caused the same connector to be downloaded
## again for every test project. The absolute OS data directory is shared by all
## Godot projects for the current user. LEGACY_INSTALL_DIR remains readable so
## verified downloads made by older plugin versions can be migrated once.
const SHARED_APP_DIR: String = "GodotMcp-XY"
const SHARED_COMPONENT_DIR: String = "cloudflared"
const LEGACY_INSTALL_DIR: String = "user://cloudflared"

## Maps an OS name + architecture to a platform key used by the tables above.
## os_name follows OS.get_name() ("Windows" / "Linux" / "macOS"). arch is one of
## "amd64" / "arm64" / "arm" / "386". Returns "" for unsupported combinations.
static func platform_key(os_name: String, arch: String) -> String:
	var os_slug: String = ""
	match os_name:
		"Windows":
			os_slug = "windows"
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			os_slug = "linux"
		"macOS":
			os_slug = "macos"
		_:
			return ""
	var key: String = "%s-%s" % [os_slug, arch]
	if ASSETS.has(key):
		return key
	return ""

## Detects the architecture of the running editor via export feature tags.
static func detect_arch() -> String:
	if OS.has_feature("arm64"):
		return "arm64"
	if OS.has_feature("x86_64"):
		return "amd64"
	if OS.has_feature("arm32"):
		return "arm"
	if OS.has_feature("x86_32"):
		return "386"
	# Desktop default; most editors run on 64-bit x86.
	return "amd64"

## Detects the platform key for the running editor. "" if unsupported.
static func detect_platform_key() -> String:
	return platform_key(OS.get_name(), detect_arch())

static func asset_name(key: String) -> String:
	return ASSETS.get(key, "")

static func checksum(key: String) -> String:
	return CHECKSUMS.get(key, "")

## Full download URL for a platform key, or "" when unsupported.
static func download_url(key: String) -> String:
	var asset: String = asset_name(key)
	if asset.is_empty():
		return ""
	return "%s/%s/%s" % [RELEASE_BASE, VERSION, asset]

## Mirror prefixes tried (in order) when the direct GitHub download fails. Each
## prefix is prepended to the official release URL; an empty prefix means the
## direct official URL. The SHA256 checksum is still verified after download, so
## a tampered or wrong mirror payload is rejected. Mirrors help networks where
## github.com release downloads are blocked or throttled (e.g. mainland China).
const MIRROR_PREFIXES: Array = [
	"",
	"https://gh-proxy.com/",
	"https://ghfast.top/",
]

## Ordered list of candidate download URLs for a platform key: the official
## GitHub URL first, then each mirror prefix applied to it. Empty when the key
## is unsupported.
static func download_urls(key: String) -> PackedStringArray:
	var urls: PackedStringArray = []
	var official: String = download_url(key)
	if official.is_empty():
		return urls
	for prefix in MIRROR_PREFIXES:
		var p: String = String(prefix)
		urls.append(official if p.is_empty() else p + official)
	return urls

## True when the asset is a gzipped tarball that must be extracted (macOS).
static func is_archive(key: String) -> bool:
	return asset_name(key).ends_with(".tgz")

## Absolute machine-local directory shared by every project using this plugin.
## Version and platform isolation prevents two plugin/architecture variants from
## overwriting one another while retaining one download per compatible variant.
static func install_dir(key: String = "") -> String:
	var root: String = OS.get_data_dir().path_join(SHARED_APP_DIR).path_join(SHARED_COMPONENT_DIR).path_join(VERSION)
	return root.simplify_path() if key.is_empty() else root.path_join(key).simplify_path()

## The pre-1.0.7 location for the currently open project.
static func legacy_install_dir() -> String:
	return ProjectSettings.globalize_path(LEGACY_INSTALL_DIR).simplify_path()

## Returns the old per-project cloudflared directories that may contain a
## verified download. Besides the current project, shallow sibling discovery
## recovers downloads made while testing the plugin in another Godot project.
static func legacy_install_dirs(current_user_dir: String = "") -> PackedStringArray:
	var user_dir: String = current_user_dir.strip_edges()
	if user_dir.is_empty():
		user_dir = ProjectSettings.globalize_path("user://")
	user_dir = user_dir.trim_suffix("/").trim_suffix("\\").simplify_path()
	var result: PackedStringArray = []
	var seen: Dictionary = {}
	var current_legacy: String = user_dir.path_join("cloudflared")
	result.append(current_legacy)
	seen[current_legacy] = true

	var projects_root: String = user_dir.get_base_dir()
	var root: DirAccess = DirAccess.open(projects_root)
	if root == null:
		return result
	root.list_dir_begin()
	var entry: String = root.get_next()
	while not entry.is_empty():
		if root.current_is_dir() and entry != "." and entry != "..":
			var candidate: String = projects_root.path_join(entry).path_join("cloudflared").simplify_path()
			if not seen.has(candidate):
				result.append(candidate)
				seen[candidate] = true
		entry = root.get_next()
	root.list_dir_end()
	return result

## Local path the downloaded asset is written to (archive or raw binary).
static func download_target(key: String) -> String:
	return install_dir(key).path_join(asset_name(key))

## Local path of the runnable binary after install (post-extraction on macOS).
static func binary_path(key: String) -> String:
	if key.begins_with("windows"):
		return install_dir(key).path_join("cloudflared.exe")
	return install_dir(key).path_join("cloudflared")

static func _binary_filename(os_name: String) -> String:
	return "cloudflared.exe" if os_name == "Windows" else "cloudflared"

static func _unquote_path(path: String) -> String:
	var clean: String = path.strip_edges()
	if clean.length() >= 2:
		var first: String = clean.substr(0, 1)
		var last: String = clean.substr(clean.length() - 1, 1)
		if (first == '"' and last == '"') or (first == "'" and last == "'"):
			clean = clean.substr(1, clean.length() - 2).strip_edges()
	return clean

static func _normalize_platform_path(path: String, os_name: String) -> String:
	var clean: String = _unquote_path(path)
	if os_name == "Windows":
		clean = clean.replace("\\", "/")
		var minimum_length: int = 3 if clean.length() >= 3 and clean.substr(1, 2) == ":/" else 1
		while clean.ends_with("/") and clean.length() > minimum_length:
			clean = clean.trim_suffix("/")
	return clean

static func _absolute_candidate(path: String, os_name: String = "") -> String:
	var clean: String = _normalize_platform_path(path, os_name)
	if clean.begins_with("user://") or clean.begins_with("res://"):
		return ProjectSettings.globalize_path(clean).simplify_path()
	return clean.simplify_path()

## Expands PATH into deterministic executable candidates without executing any
## untrusted file. The platform argument keeps this helper fully testable.
static func path_binary_candidates(path_env: String, os_name: String) -> PackedStringArray:
	var result: PackedStringArray = []
	var seen: Dictionary = {}
	var separator: String = ";" if os_name == "Windows" else ":"
	var filename: String = _binary_filename(os_name)
	for raw_entry in path_env.split(separator, false):
		var directory: String = _normalize_platform_path(String(raw_entry), os_name)
		if directory.is_empty():
			continue
		var candidate: String = directory.path_join(filename)
		var identity: String = candidate.to_lower() if os_name == "Windows" else candidate
		if not seen.has(identity):
			result.append(candidate)
			seen[identity] = true
	return result

## Finds user-managed installations before consulting the managed download
## cache. Explicit configuration wins, then the editor process PATH.
static func find_existing_user_binary(configured_path: String, path_env: String, os_name: String) -> Dictionary:
	var configured: String = _absolute_candidate(configured_path, os_name)
	if not configured.is_empty():
		if DirAccess.dir_exists_absolute(configured):
			configured = configured.path_join(_binary_filename(os_name))
		if FileAccess.file_exists(configured):
			return {"path": configured, "source": "configured"}
	for candidate in path_binary_candidates(path_env, os_name):
		if FileAccess.file_exists(candidate):
			return {"path": candidate, "source": "system_path"}
	return {}

## Verifies a file on disk against the expected SHA256 for the platform key.
static func verify_checksum(file_path: String, key: String) -> bool:
	var expected: String = checksum(key)
	if expected.is_empty():
		return false
	if not FileAccess.file_exists(file_path):
		return false
	var actual: String = FileAccess.get_sha256(file_path)
	return actual.to_lower() == expected.to_lower()

## Copies a legacy file through a checksum-verified temporary path, then swaps
## it into place. A failed copy or checksum never destroys an existing good
## destination. This is also used as the tested atomic migration primitive.
static func migrate_verified_binary(source: String, destination: String, expected_sha256: String) -> bool:
	var expected: String = expected_sha256.strip_edges().to_lower()
	if expected.length() != 64 or not expected.is_valid_hex_number(false):
		return false
	if not FileAccess.file_exists(source):
		return false
	if FileAccess.get_sha256(source).to_lower() != expected:
		return false
	if FileAccess.file_exists(destination) and FileAccess.get_sha256(destination).to_lower() == expected:
		return true
	var destination_dir: String = destination.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(destination_dir) != OK:
		return false
	var suffix: String = "%d" % OS.get_process_id()
	var temporary: String = "%s.migrating-%s" % [destination, suffix]
	var backup: String = "%s.backup-%s" % [destination, suffix]
	if FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if DirAccess.copy_absolute(source, temporary) != OK:
		return false
	if FileAccess.get_sha256(temporary).to_lower() != expected:
		DirAccess.remove_absolute(temporary)
		return false

	var had_destination: bool = FileAccess.file_exists(destination)
	if had_destination and DirAccess.rename_absolute(destination, backup) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	if DirAccess.rename_absolute(temporary, destination) != OK:
		if had_destination:
			DirAccess.rename_absolute(backup, destination)
		DirAccess.remove_absolute(temporary)
		return false
	if had_destination:
		DirAccess.remove_absolute(backup)
	return true

static func _legacy_binary_path(directory: String, key: String) -> String:
	return directory.path_join("cloudflared.exe" if key.begins_with("windows") else "cloudflared")

static func _legacy_download_target(directory: String, key: String) -> String:
	return directory.path_join(asset_name(key))

## Migrates the first checksum-valid download found in the current or another
## Godot project's old user:// cache. Files are copied, never deleted.
static func migrate_legacy_install(key: String) -> String:
	var expected: String = checksum(key)
	if expected.is_empty():
		return ""
	for directory in legacy_install_dirs():
		var legacy_dir: String = String(directory)
		if is_archive(key):
			var legacy_archive: String = _legacy_download_target(legacy_dir, key)
			if not verify_checksum(legacy_archive, key):
				continue
			if not migrate_verified_binary(legacy_archive, download_target(key), expected):
				continue
			var output: Array = []
			var extract_code: int = OS.execute(
				"tar",
				PackedStringArray(["-xzf", download_target(key), "-C", install_dir(key)]),
				output,
				true
			)
			if extract_code != 0 or not FileAccess.file_exists(binary_path(key)):
				continue
		else:
			var legacy_binary: String = _legacy_binary_path(legacy_dir, key)
			if not migrate_verified_binary(legacy_binary, binary_path(key), expected):
				continue
		if OS.get_name() != "Windows":
			OS.execute("chmod", PackedStringArray(["+x", binary_path(key)]), [], true)
		if is_installed(key):
			return binary_path(key)
	return ""

## True when a verified runnable binary is already installed for this platform.
static func is_installed(key: String) -> bool:
	var bin: String = binary_path(key)
	if not FileAccess.file_exists(bin):
		return false
	# Raw single-binary assets carry the verifiable checksum; for archives the
	# checksum applies to the retained tarball. Rechecking it makes the shared
	# cache safe to reuse across projects and editor restarts.
	if is_archive(key):
		return verify_checksum(download_target(key), key)
	return verify_checksum(bin, key)

## Resolves all reusable local sources before any network request:
## configured path -> system PATH -> shared verified cache -> verified legacy
## caches from this or sibling Godot projects.
static func resolve_local_binary(key: String, configured_path: String = "") -> Dictionary:
	var user_binary: Dictionary = find_existing_user_binary(
		configured_path,
		OS.get_environment("PATH"),
		OS.get_name()
	)
	if not user_binary.is_empty():
		return user_binary
	if not key.is_empty() and is_installed(key):
		return {"path": binary_path(key), "source": "shared_cache"}
	if not key.is_empty():
		var migrated: String = migrate_legacy_install(key)
		if not migrated.is_empty():
			return {"path": migrated, "source": "legacy_migrated"}
	return {}
