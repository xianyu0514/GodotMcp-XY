@tool
class_name PayloadUtils
extends RefCounted

# Helpers for bounding the size of read tool responses so a single call cannot
# return an unbounded payload that is expensive to serialize and transfer.

# Truncate a list to at most `limit` items. A non-positive limit falls back to
# the default. Returns the (possibly truncated) items plus the full size and a
# flag indicating whether truncation occurred, so callers can surface metadata.
static func truncate_list(items: Array, limit: int, default_limit: int = 1000) -> Dictionary:
	var effective_limit: int = limit if limit > 0 else default_limit
	var total_count: int = items.size()
	var truncated: bool = total_count > effective_limit
	var page: Array = items if not truncated else items.slice(0, effective_limit)
	return {
		"items": page,
		"total_count": total_count,
		"truncated": truncated
	}

# Paginate a list with unified limit/offset semantics for high-volume read
# tools. `offset` is applied before `limit`; `truncated` means entries remain
# after the returned page. A non-positive limit falls back to the default.
static func paginate_list(items: Array, limit: int, offset: int = 0, default_limit: int = 1000) -> Dictionary:
	var effective_limit: int = limit if limit > 0 else default_limit
	var total_count: int = items.size()
	var start: int = clampi(offset, 0, total_count)
	var end: int = mini(total_count, start + effective_limit)
	var page: Array = items.slice(start, end)
	var result: Dictionary = {
		"items": page,
		"total_count": total_count,
		"truncated": end < total_count,
		"offset": start,
		"limit": effective_limit,
		"returned_count": page.size(),
		"has_more": end < total_count
	}
	if end < total_count:
		result["next_offset"] = end
	return result
