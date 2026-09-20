extends Marker2D
## 目标地图的出生点：优先用上一张地图门指定的 pending_spawn，否则本点。

func resolve_spawn() -> Vector2:
	var pending: Variant = GameSave.current.get("pending_spawn", null)
	if pending is Dictionary:
		GameSave.current.erase("pending_spawn")
		return Vector2(float(pending.get("x", position.x)), float(pending.get("y", position.y)))
	return position
