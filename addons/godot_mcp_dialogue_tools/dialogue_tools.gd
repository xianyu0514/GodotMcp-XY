extends RefCounted

## 对话系统工具集（参考 addon 的 handler 实现）。
## 每个 handler 接收 Dictionary 参数、返回 Dictionary 结果——
## 与内置 MCP 工具的 handler 契约完全一致。

## 解析对话图 JSON。期望 {nodes: [{id, text, next: [ids]}], start: id}。
static func _load_graph(path: String) -> Dictionary:
	if not path.begins_with("res://"):
		return {"error": "path must be a res:// path"}
	if not FileAccess.file_exists(path):
		return {"error": "File not found: " + path}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"error": "Could not parse as JSON object: " + path}
	var graph: Dictionary = parsed
	if not (graph.get("nodes", []) is Array):
		return {"error": "Missing or invalid 'nodes' array."}
	return graph

## 收集节点 id 集合。
static func _node_ids(graph: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	for node_value in graph.get("nodes", []):
		if node_value is Dictionary:
			ids[String((node_value as Dictionary).get("id", ""))] = true
	return ids

func validate_dialogue(params: Dictionary) -> Dictionary:
	var graph: Dictionary = _load_graph(str(params.get("path", "")))
	if graph.has("error"):
		return graph
	var nodes: Array = graph.get("nodes", [])
	var ids: Dictionary = _node_ids(graph)
	var dangling: Array = []
	var unreachable: Array = []
	var reachable: Dictionary = {}
	var start: String = str(graph.get("start", ""))
	if not start.is_empty() and ids.has(start):
		var queue: Array = [start]
		reachable[start] = true
		while not queue.is_empty():
			var current: String = queue.pop_front()
			for node_value in nodes:
				var node: Dictionary = node_value
				if String(node.get("id", "")) != current:
					continue
				for next_id in node.get("next", []):
					var nid: String = str(next_id)
					if not ids.has(nid):
						dangling.append(nid)
					elif not reachable.has(nid):
						reachable[nid] = true
						queue.append(nid)
	for node_value in nodes:
		var node: Dictionary = node_value
		var nid: String = String(node.get("id", ""))
		if not reachable.has(nid):
			unreachable.append(nid)
	var valid: bool = dangling.is_empty() and unreachable.is_empty()
	var result: Dictionary = {
		"valid": valid,
		"node_count": nodes.size(),
		"dangling_links": dangling,
		"unreachable_nodes": unreachable
	}
	if not valid:
		result["hint"] = "Fix dangling link targets and unreachable nodes, then re-validate."
	return result

func wordcount_dialogue(params: Dictionary) -> Dictionary:
	var graph: Dictionary = _load_graph(str(params.get("path", "")))
	if graph.has("error"):
		return graph
	var counts: Dictionary = {}
	var total: int = 0
	for node_value in graph.get("nodes", []):
		var node: Dictionary = node_value
		var speaker: String = str(node.get("speaker", "narrator"))
		var text: String = str(node.get("text", ""))
		var words: int = text.split(" ", false).size() if not text.is_empty() else 0
		counts[speaker] = int(counts.get(speaker, 0)) + words
		total += words
	return {"total_words": total, "per_character": counts}

func loc_keys_dialogue(params: Dictionary) -> Dictionary:
	var graph: Dictionary = _load_graph(str(params.get("path", "")))
	if graph.has("error"):
		return graph
	var csv_path: String = str(params.get("csv_path", ""))
	var known: Dictionary = {}
	if not csv_path.is_empty() and FileAccess.file_exists(csv_path):
		var csv_text: String = FileAccess.get_file_as_string(csv_path)
		for line in csv_text.split("\n"):
			var parts: PackedStringArray = line.split(",")
			if parts.size() > 0:
				known[parts[0].strip_edges()] = true
	var referenced: Array = []
	for node_value in graph.get("nodes", []):
		var node: Dictionary = node_value
		var loc_id: String = str(node.get("loc_id", ""))
		if not loc_id.is_empty():
			referenced.append(loc_id)
	var missing: Array = []
	var found: Array = []
	for key in referenced:
		if csv_path.is_empty():
			missing.append(key)
		elif known.has(key):
			found.append(key)
		else:
			missing.append(key)
	return {"referenced": referenced.size(), "found": found, "missing": missing,
		"csv_scanned": not csv_path.is_empty()}
