class_name EnemyStats
extends Resource
## 共享敌人数据（门槛 B M2）：普通敌人与 Boss 共用同一实现（enemy.gd），
## 行为差异全部来自这份 Resource——"修改共享敌人、保留 Boss 特例"的
## 审计剧本以数据文件为验证对象（MCP 变更单改 grunt_stats，boss_stats
## 锚点不变）。

@export var move_speed: float = 120.0
@export var contact_damage: int = 10
## 击退抗性 0..1：0 = 完全被击退，1 = 免疫。普通敌人默认 0（剧本中被
## 用户要求提高的目标属性），Boss 特例 0.9。
@export_range(0.0, 1.0) var knockback_resistance: float = 0.0
@export var patrol_range: float = 120.0
@export var display_name: String = "Grunt"
