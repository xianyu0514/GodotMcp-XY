class_name CombatRules
extends RefCounted
## 战斗数值的纯函数层（门槛 B M2）：可单测的确定性规则，节点层保持薄。
## 所有输入输出都是纯值——不在节点上做数值决策。

## 击退位移：基础冲量被受体的抗性线性削减（1 - resistance）。
static func knockback_displacement(base_impulse: Vector2,
		knockback_resistance: float) -> Vector2:
	var factor: float = 1.0 - clampf(knockback_resistance, 0.0, 1.0)
	return base_impulse * factor

## 接触伤害经无敌帧判定：无敌期内不造成伤害。
static func damage_after_invuln(contact_damage: int,
		invulnerable: bool) -> int:
	return 0 if invulnerable else maxi(0, contact_damage)

## 受击后的生命与死亡判定。
static func apply_hit(hp: int, damage: int) -> Dictionary:
	var new_hp: int = maxi(0, hp - damage)
	return {"hp": new_hp, "dead": new_hp <= 0}

## 抗性变更的合法域（MCP 修改回执/断言共用同一上界）。
static func clamp_resistance(value: float) -> float:
	return clampf(value, 0.0, 1.0)
