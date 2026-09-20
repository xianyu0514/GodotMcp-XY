extends "res://addons/gut/test.gd"

## 门槛 B M2 单元测试：CombatRules 纯函数（击退抗性/无敌帧/死亡判定）
## 与共享/特例数据的存在性护栏（grunt 抗性 0、Boss 特例 0.9——审计剧本
## "改共享敌人、保留 Boss 特例"的数据锚点）。

const CombatRulesScript = preload("res://slice_b/scripts/combat/combat_rules.gd")
const EnemyStatsScript = preload("res://slice_b/scripts/combat/enemy_stats.gd")

const GRUNT_PATH: String = "res://slice_b/data/grunt_stats.tres"
const BOSS_PATH: String = "res://slice_b/data/boss_stats.tres"

func test_knockback_scales_with_resistance() -> void:
	var impulse: Vector2 = Vector2(200, 0)
	assert_eq(CombatRulesScript.knockback_displacement(impulse, 0.0), Vector2(200, 0),
		"zero resistance takes the full impulse")
	assert_eq(CombatRulesScript.knockback_displacement(impulse, 0.5), Vector2(100, 0),
		"half resistance halves the displacement")
	assert_eq(CombatRulesScript.knockback_displacement(impulse, 1.0), Vector2.ZERO,
		"full resistance is immune")
	assert_eq(CombatRulesScript.knockback_displacement(impulse, 1.7), Vector2.ZERO,
		"out-of-range resistance clamps to immune")

func test_damage_respects_invuln_and_clamps() -> void:
	assert_eq(CombatRulesScript.damage_after_invuln(12, false), 12)
	assert_eq(CombatRulesScript.damage_after_invuln(12, true), 0,
		"invulnerable frames negate contact damage")
	assert_eq(CombatRulesScript.damage_after_invuln(-5, false), 0,
		"negative damage clamps to zero")

func test_apply_hit_floor_and_death() -> void:
	var hit: Dictionary = CombatRulesScript.apply_hit(100, 30)
	assert_eq(int(hit["hp"]), 70)
	assert_false(bool(hit["dead"]))
	var lethal: Dictionary = CombatRulesScript.apply_hit(10, 99)
	assert_eq(int(lethal["hp"]), 0)
	assert_true(bool(lethal["dead"]), "hp floors at zero and flags death")

func test_resistance_clamp_domain() -> void:
	assert_eq(CombatRulesScript.clamp_resistance(-0.3), 0.0)
	assert_eq(CombatRulesScript.clamp_resistance(0.4), 0.4)
	assert_eq(CombatRulesScript.clamp_resistance(2.0), 1.0)

func test_shared_and_boss_data_anchors() -> void:
	# 审计剧本的数据锚点：共享敌人抗性从 0 起步（被修改的目标），
	# Boss 特例为高抗性（不被共享修改覆盖）。slice_b 是嵌套项目——
	# 其 .tres 内部路径只在 slice_b 项目上下文可解析，主仓库侧用
	# 文本断言守锚点（运行时值由 m2 集成流在切片编辑器里验证）。
	var grunt_text: String = FileAccess.get_file_as_string(GRUNT_PATH)
	assert_false(grunt_text.is_empty(), "grunt stats resource exists")
	assert_true(grunt_text.contains("knockback_resistance = 0.0"),
		"the shared grunt starts with no knockback resistance")
	assert_true(grunt_text.contains("contact_damage = 10"))
	var boss_text: String = FileAccess.get_file_as_string(BOSS_PATH)
	assert_false(boss_text.is_empty(), "boss stats resource exists")
	assert_true(boss_text.contains("knockback_resistance = 0.9"),
		"the boss keeps its special-case resistance")
	assert_true(boss_text.contains("contact_damage = 25"))
	assert_true(boss_text.contains("display_name = \"Boss\""))
