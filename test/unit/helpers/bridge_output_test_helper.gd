extends RefCounted

var _output_events: Array[Dictionary] = []
var _captured_messages: Array[Dictionary] = []
var _max_output_events: int = 500
var _max_messages: int = 500
var _message_sequence: int = 0
var _state_events: Array[Dictionary] = []

func _append_output_event(event: Dictionary) -> void:
	_message_sequence += 1
	var entry: Dictionary = event.duplicate(true)
	entry["sequence"] = _message_sequence
	entry["timestamp"] = Time.get_unix_time_from_system()
	_output_events.append(entry)
	if _output_events.size() > _max_output_events:
		_output_events = _output_events.slice(_output_events.size() - _max_output_events)

func _append_captured_message(session_id: int, message: String, data: Array) -> void:
	_message_sequence += 1
	_captured_messages.append({
		"sequence": _message_sequence,
		"session_id": session_id,
		"message": message,
		"data": data,
		"timestamp": Time.get_unix_time_from_system()
	})
	if _captured_messages.size() > _max_messages:
		_captured_messages = _captured_messages.slice(_captured_messages.size() - _max_messages)

func _append_state_event(event: Dictionary) -> void:
	_message_sequence += 1
	var entry: Dictionary = event.duplicate(true)
	entry["sequence"] = _message_sequence
	entry["timestamp"] = Time.get_unix_time_from_system()
	_state_events.append(entry)

func _map_output_category(type: int) -> String:
	match type:
		0: return "stdout"
		1: return "stderr"
		2: return "stdout_rich"
		_: return "stdout"

func get_output_events(count: int = 100, offset: int = 0, order: String = "desc", category: String = "") -> Dictionary:
	var events: Array = []
	for entry in _output_events:
		if category.is_empty() or str(entry.get("category", "")) == category:
			events.append(entry.duplicate(true))
	if order == "desc":
		events.reverse()
	var start: int = clampi(offset, 0, events.size())
	var end: int = clampi(start + max(count, 0), start, events.size())
	return {"events": events.slice(start, end), "count": end - start, "total_available": events.size()}

func _capture(message: String, data: Array, session_id: int) -> bool:
	_append_captured_message(session_id, message, data)
	if data.size() > 0 and (message == "error" or message.begins_with("error:") or message.begins_with("error ")):
		var error_msg: String = str(data[0]) if data.size() > 0 else ""
		var error_file: String = str(data[1]) if data.size() > 1 else ""
		var error_line: int = int(data[2]) if data.size() > 2 else 0
		var error_func: String = str(data[3]) if data.size() > 3 else ""
		_append_output_event({"category": "stderr", "message": error_msg, "file": error_file, "line": error_line, "function": error_func, "type": 1})
	elif message == "output" and data.size() >= 2:
		var output_message: String = str(data[0])
		var output_type: int = int(data[1])
		_append_output_event({"category": _map_output_category(output_type), "message": output_message, "type": output_type})
	return true

func _on_breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool) -> void:
	_append_state_event({"state": "breaked" if reallydid else "running", "breaked": reallydid, "can_debug": can_debug, "reason": reason, "has_stackdump": has_stackdump})
	if reallydid and has_stackdump:
		_append_output_event({"category": "stderr", "message": reason, "file": "", "line": 0, "function": "", "type": 1})

func _on_output(message: String, type: int) -> void:
	_append_output_event({"category": _map_output_category(type), "message": message, "type": type})
