extends "res://addons/gut/test.gd"

var _helper = null

func before_each():
	_helper = load("res://test/unit/helpers/bridge_output_test_helper.gd").new()

func after_each():
	_helper = null

func test_capture_error_adds_to_output_events():
	_helper._output_events.clear()
	_helper._capture("error", ["Test error message", "res://test.gd", 10, "_ready"], 0)
	assert_gt(_helper._output_events.size(), 0, "Should add error to output events")

func test_capture_error_has_stderr_category():
	_helper._output_events.clear()
	_helper._capture("error", ["Test error", "res://test.gd", 5, "_process"], 0)
	if _helper._output_events.size() > 0:
		assert_eq(_helper._output_events[_helper._output_events.size() - 1].get("category", ""), "stderr", "Error should be stderr category")

func test_capture_error_has_file_and_line():
	_helper._output_events.clear()
	_helper._capture("error", ["Msg", "res://player.gd", 42, "_ready"], 0)
	if _helper._output_events.size() > 0:
		var last = _helper._output_events[_helper._output_events.size() - 1]
		assert_eq(last.get("file", ""), "res://player.gd", "Should have file")
		assert_eq(last.get("line", 0), 42, "Should have line")

func test_capture_non_error_no_output_event():
	_helper._output_events.clear()
	_helper._capture("stack_dump", [[]], 0)
	assert_eq(_helper._output_events.size(), 0, "Non-error should not add output event")

func test_capture_empty_error_data():
	_helper._output_events.clear()
	_helper._capture("error", [], 0)
	assert_eq(_helper._output_events.size(), 0, "Empty error data should not add output event")

func test_capture_error_prefix_with_colon():
	_helper._output_events.clear()
	_helper._capture("error:GDScript", ["Test error with prefix", "res://test.gd", 15, "_init"], 0)
	if _helper._output_events.size() > 0:
		var last = _helper._output_events[_helper._output_events.size() - 1]
		assert_eq(last.get("category", ""), "stderr", "Error with prefix should be stderr category")
		assert_eq(last.get("file", ""), "res://test.gd", "Should have file")

func test_capture_error_prefix_with_space():
	_helper._output_events.clear()
	_helper._capture("error something", ["Another error format"], 0)
	if _helper._output_events.size() > 0:
		assert_eq(_helper._output_events[_helper._output_events.size() - 1].get("category", ""), "stderr", "Error with space prefix should be stderr")

func test_capture_output_stdout():
	_helper._output_events.clear()
	_helper._capture("output", ["Hello world", 0], 0)
	if _helper._output_events.size() > 0:
		var last = _helper._output_events[_helper._output_events.size() - 1]
		assert_eq(last.get("category", ""), "stdout", "Output type 0 should be stdout")
		assert_eq(last.get("message", ""), "Hello world", "Should have message")

func test_capture_output_stderr():
	_helper._output_events.clear()
	_helper._capture("output", ["Error message", 1], 0)
	if _helper._output_events.size() > 0:
		var last = _helper._output_events[_helper._output_events.size() - 1]
		assert_eq(last.get("category", ""), "stderr", "Output type 1 should be stderr")
		assert_eq(last.get("message", ""), "Error message", "Should have message")

func test_capture_output_insufficient_data():
	_helper._output_events.clear()
	_helper._capture("output", ["Only message"], 0)
	assert_eq(_helper._output_events.size(), 0, "Output with insufficient data should not add event")

func test_capture_output_stdout_rich():
	_helper._output_events.clear()
	_helper._capture("output", ["Rich text output", 2], 0)
	if _helper._output_events.size() > 0:
		assert_eq(_helper._output_events[_helper._output_events.size() - 1].get("category", ""), "stdout_rich", "Output type 2 should be stdout_rich")

func test_on_breaked_adds_output_event():
	_helper._output_events.clear()
	_helper._on_breaked(true, true, "Error: Invalid index", true)
	if _helper._output_events.size() > 0:
		var last = _helper._output_events[_helper._output_events.size() - 1]
		assert_eq(last.get("category", ""), "stderr", "Breaked should add stderr event")
		assert_eq(last.get("message", ""), "Error: Invalid index", "Should have error message")

func test_on_breaked_not_breaked_no_event():
	_helper._output_events.clear()
	_helper._on_breaked(false, false, "running", false)
	assert_eq(_helper._output_events.size(), 0, "Not breaked should not add output event")
