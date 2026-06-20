extends "res://addons/gut/test.gd"

func test_returns_all_items_when_under_limit():
	var result: Dictionary = PayloadUtils.truncate_list(["a", "b", "c"], 10)
	assert_eq(result["items"], ["a", "b", "c"], "All items returned when under the limit")
	assert_eq(result["total_count"], 3, "total_count reflects the full size")
	assert_false(result["truncated"], "Not truncated when under the limit")

func test_returns_all_items_when_exactly_at_limit():
	var result: Dictionary = PayloadUtils.truncate_list(["a", "b", "c"], 3)
	assert_eq(result["items"].size(), 3, "All items returned when exactly at the limit")
	assert_false(result["truncated"], "Not truncated when exactly at the limit")

func test_truncates_when_over_limit():
	var result: Dictionary = PayloadUtils.truncate_list(["a", "b", "c", "d", "e"], 2)
	assert_eq(result["items"], ["a", "b"], "Only the first `limit` items are returned")
	assert_eq(result["total_count"], 5, "total_count reflects the full pre-truncation size")
	assert_true(result["truncated"], "Truncated flag set when over the limit")

func test_non_positive_limit_falls_back_to_default():
	var items: Array = []
	for i in range(1500):
		items.append(i)
	var zero: Dictionary = PayloadUtils.truncate_list(items, 0)
	assert_eq(zero["items"].size(), 1000, "Zero limit falls back to the default of 1000")
	assert_true(zero["truncated"], "Truncated against the default limit")
	var negative: Dictionary = PayloadUtils.truncate_list(items, -5)
	assert_eq(negative["items"].size(), 1000, "Negative limit falls back to the default of 1000")

func test_custom_default_limit_used_for_non_positive_limit():
	var result: Dictionary = PayloadUtils.truncate_list([1, 2, 3, 4], 0, 2)
	assert_eq(result["items"].size(), 2, "Non-positive limit uses the provided default_limit")
	assert_true(result["truncated"], "Truncated against the custom default limit")

func test_empty_list_is_not_truncated():
	var result: Dictionary = PayloadUtils.truncate_list([], 1000)
	assert_eq(result["items"], [], "Empty input yields empty output")
	assert_eq(result["total_count"], 0, "total_count is zero for empty input")
	assert_false(result["truncated"], "Empty list is never truncated")
