extends "res://addons/gut/test.gd"

# Unit tests for MCPGenerationBudget (external-generation budget guard, ⑧).
# Covers the unlimited default, the call-count/limit window, rejection once the
# limit is reached, and the read-only snapshot. Pure, in-memory, no IO or HTTP.

func before_each() -> void:
	MCPGenerationBudget.reset()
	MCPGenerationBudget.configure(0, 3600)

func after_each() -> void:
	MCPGenerationBudget.reset()
	MCPGenerationBudget.configure(0, 3600)

# --- unlimited (default / backward compatible) ----------------------------

func test_unlimited_when_max_calls_zero():
	MCPGenerationBudget.configure(0, 3600)
	for i in range(100):
		var v: Dictionary = MCPGenerationBudget.try_consume()
		assert_true(bool(v.get("allowed", false)), "unlimited always allows")
		assert_eq(int(v.get("remaining", 0)), -1, "unlimited reports remaining -1")

func test_negative_max_calls_treated_as_unlimited():
	MCPGenerationBudget.configure(-5, 3600)
	var v: Dictionary = MCPGenerationBudget.try_consume()
	assert_true(bool(v.get("allowed", false)), "negative limit -> unlimited")

# --- enforced limit -------------------------------------------------------

func test_allows_up_to_limit_then_rejects():
	MCPGenerationBudget.configure(3, 3600)
	for i in range(3):
		var v: Dictionary = MCPGenerationBudget.try_consume()
		assert_true(bool(v.get("allowed", false)), "call %d within budget" % i)
	var blocked: Dictionary = MCPGenerationBudget.try_consume()
	assert_false(bool(blocked.get("allowed", true)), "4th call over budget is rejected")
	assert_eq(int(blocked.get("remaining", -1)), 0, "rejected call reports 0 remaining")
	assert_true(int(blocked.get("reset_in_sec", -1)) >= 0, "reset_in_sec is non-negative")

func test_rejected_call_does_not_consume():
	MCPGenerationBudget.configure(1, 3600)
	assert_true(bool(MCPGenerationBudget.try_consume().get("allowed", false)), "first allowed")
	MCPGenerationBudget.try_consume()
	MCPGenerationBudget.try_consume()
	# Even after extra rejected attempts, used stays at the limit (no overcount).
	var snap: Dictionary = MCPGenerationBudget.snapshot()
	assert_eq(int(snap.get("used", -1)), 1, "rejections do not increment used")

func test_remaining_counts_down():
	MCPGenerationBudget.configure(2, 3600)
	assert_eq(int(MCPGenerationBudget.try_consume().get("remaining", -99)), 1, "remaining after 1st")
	assert_eq(int(MCPGenerationBudget.try_consume().get("remaining", -99)), 0, "remaining after 2nd")

# --- snapshot -------------------------------------------------------------

func test_snapshot_is_read_only():
	MCPGenerationBudget.configure(5, 3600)
	MCPGenerationBudget.try_consume()
	var a: Dictionary = MCPGenerationBudget.snapshot()
	var b: Dictionary = MCPGenerationBudget.snapshot()
	assert_eq(int(a.get("used", -1)), 1, "snapshot reports used")
	assert_eq(int(b.get("used", -1)), 1, "snapshot does not consume")
	assert_eq(int(a.get("remaining", -99)), 4, "snapshot remaining")

func test_reset_clears_usage():
	MCPGenerationBudget.configure(2, 3600)
	MCPGenerationBudget.try_consume()
	MCPGenerationBudget.reset()
	assert_eq(int(MCPGenerationBudget.snapshot().get("used", -1)), 0, "reset clears timestamps")
