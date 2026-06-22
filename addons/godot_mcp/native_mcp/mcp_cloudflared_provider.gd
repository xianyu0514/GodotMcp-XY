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

## Directory (under user://) where the managed binary is stored.
const INSTALL_DIR: String = "user://cloudflared"

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

## Local path the downloaded asset is written to (archive or raw binary).
static func download_target(key: String) -> String:
	return "%s/%s" % [INSTALL_DIR, asset_name(key)]

## Local path of the runnable binary after install (post-extraction on macOS).
static func binary_path(key: String) -> String:
	if key.begins_with("windows"):
		return "%s/cloudflared.exe" % INSTALL_DIR
	return "%s/cloudflared" % INSTALL_DIR

## Verifies a file on disk against the expected SHA256 for the platform key.
static func verify_checksum(file_path: String, key: String) -> bool:
	var expected: String = checksum(key)
	if expected.is_empty():
		return false
	if not FileAccess.file_exists(file_path):
		return false
	var actual: String = FileAccess.get_sha256(file_path)
	return actual.to_lower() == expected.to_lower()

## True when a verified runnable binary is already installed for this platform.
static func is_installed(key: String) -> bool:
	var bin: String = binary_path(key)
	if not FileAccess.file_exists(bin):
		return false
	# Raw single-binary assets carry the verifiable checksum; for archives the
	# checksum applies to the tarball, so presence of the extracted binary is the
	# install signal (the tarball was verified before extraction).
	if is_archive(key):
		return true
	return verify_checksum(bin, key)
