extends "res://addons/gut/test.gd"

## 文档计数漂移门禁：manifest 是唯一真相，计数字样必须在全部计数承载文件
## 中同步出现。M8 实测：一次新工具要手工改 7 处计数，server-instructions
## 门禁抓到了漏改的 248，但 README/docs 无门禁——本测试补上这个缺口，
## 让"新增工具忘改 README"在 CI 就失败。

const ManifestScript = preload("res://addons/godot_mcp/native_mcp/tools_manifest.gd")
const ServerCoreScript = preload("res://addons/godot_mcp/native_mcp/mcp_server_core.gd")

const COUNT_FILES: Array[String] = [
	"res://README.md",
	"res://README.zh.md",
	"res://addons/godot_mcp/README.md",
	"res://addons/godot_mcp/README.zh.md",
	"res://docs/tools/README.md",
	"res://AGENTS.md",
]

func test_manifest_counts_are_the_truth() -> void:
	assert_eq(ManifestScript.TOOLS.size(), 249, "manifest total (update this gate with every tool)")
	assert_eq(ManifestScript.count_by_category("supplementary"), 215, "supplementary count follows the manifest")

func test_total_count_appears_in_every_count_file() -> void:
	var total: int = ManifestScript.TOOLS.size()
	for file_path in COUNT_FILES:
		var text: String = _read(file_path)
		assert_false(text.is_empty(), "%s must be readable" % file_path)
		assert_true(text.contains(str(total)),
			"%s must cite the manifest total %d — count drift, run the doc-sync checklist" % [file_path, total])

func test_stale_counts_do_not_linger() -> void:
	# 上一次的实际漂移样本：248。任何"旧总数"都不应再出现（214/215 同理，
	# 但旧值随历史增长，这里只钉最近一代，保持测试可维护）。
	for file_path in COUNT_FILES:
		var text: String = _read(file_path)
		assert_false(text.contains("248"),
			"%s still cites the stale 248 total — update to the manifest count" % file_path)

func test_server_instructions_cite_the_catalog_truth() -> void:
	var text: String = String(ServerCoreScript.SERVER_INSTRUCTIONS)
	assert_true(text.contains(str(ManifestScript.TOOLS.size())),
		"SERVER_INSTRUCTIONS must cite the live manifest total")

func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var content: String = f.get_as_text()
	f.close()
	return content
