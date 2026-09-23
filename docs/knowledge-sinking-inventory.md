# E-3 知识下沉清单（存量文本真理 → 工具检测分支）v1 · 2026-09-23

> 依据 `docs/ai-capability-spec.md` E-3：知识注入是权宜，环境自披露是正解。
> 本清单盘点全部配方内联的"环境意外"类文本真理，标注下沉状态与候选分支；
> 目标：配方瘦成"入口 + 价值观"，AI 零先验也不会被静默陷阱咬。
> K-1 审计结论（同日首扫）：未发现教科书式通用常识填充——现有 signal/Area2D
> 表述均带具体操作语义（如"body_entered 信号收集，绝不轮询"），属 K-4 设计价值观。

## 已下沉（工具已自披露，配方文本降级为一句提醒）

| 文本真理 | 承载工具 | 状态 |
| --- | --- | --- |
| 内嵌脚本副本（attach_script 嵌入陷阱） | verify_change_effect entity 步：点名 sub_resource + attach_script 修复调用 | ✅ 已下沉 |
| 未保存编辑器缓冲（run_project 从磁盘启动） | verify_change_effect entity 步：点名 + save_scene 修复 | ✅ 已下沉 |
| 宿主实例覆盖遮蔽基值 | verify_change_effect hosts 步：点名宿主文件/节点 + 带 expect_current 的批量修复 | ✅ 已下沉 |
| `.tscn` parent 不含根名 | entity/hosts/batch 三个解析器编码；深度路径测试钉死 | ✅ 已下沉（纯解析层） |
| instance=ExtResource 正则陷阱 | hosts 解析器从原始头行提取；单测钉死 | ✅ 已下沉 |
| 位移断言必须相对值 | play_and_verify displacement_min/max 语义 | ✅ 已下沉 |
| 陈旧快照 = 测量造假 | await/assert runtime condition 的 stale 显式拒绝 | ✅ 已下沉 |
| 只在内存生效的假象 | verify_change_effect persist 步（二次磁盘启动） | ✅ 已下沉 |

## 下沉候选（有明确工具分支可落）

| 文本真理 | 现配方 | 候选分支 |
| --- | --- | --- |
| 死亡窗口 0.22s（queue_free 后读不到） | melee/boss/pickup 配方内联 | assert_runtime_condition：表达式含已 free 节点路径失败时，报错附带 "node not found — if it queue_frees itself, assert the COUNTER or read inside the free window"（自愈报错，S-2） |
| 存档必须 user://（res:// 导出后只读） | save 配方内联 | audit_project_health / 脚本诊断：扫描用户脚本中 FileAccess 写 res:// 的调用，发现即报 "user:// required (res:// is read-only in exported builds)" |
| 输入映射先建（缺 action 全契约失败） | first_game 配方内联 | play_and_verify 输入步失败消息附 "action '<x>' unbound — upsert_project_input_action first"（若尚未如此） |
| TileSet 未赋给图层则不渲染 | map 配方内联 | set_tilemap_layer_cells：图层无 TileSet 时的返回已带提示则视为下沉；否则补自愈提示 |
| 投射物泄漏（命中/TTL 都要 free） | ranged 配方内联 | 候选：运行时性能/节点计数断言模板；属半价值观，文本保留 + 工具辅助 |

## 永驻文本（K-4 设计价值观，无工具可持有）

- 无前摇的射击 = 不可闪避 = 缺陷（公平性判断）
- 最小完整闭环：胜负都可达才算 first-playable
- 品类是数据不是分支（grunt/boss=stats、genre=旋钮组、feel=方案字典）
- 按钮不接线就是缺陷，不是风格选择
- 音频验证断言状态（听不到就断言播放器/总线），缺文件点名
- 收尾必须点名未验证项（诚实收尾价值观）

## 执行建议

1. 候选清单按上表顺序落（自愈报错类最小成本、最先做）；
2. 每落一条：同提交删除/缩短配方对应文本（防止僵尸知识，K-5）；
3. 落完后重跑短语存活测试（断言的是价值观短语，应全部保持）。
