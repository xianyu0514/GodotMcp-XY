# 轻松制作优质游戏 — 产品路线图（v1，2026-09-22）

> 北极星：用户装上插件、连上任意 MCP 客户端后，**一句自然语言进，可玩、可验证、可发布的游戏内容出**；
> 每一步的"完成"都有证据，用户永远不需要猜"到底生效了没有"。
>
> 本文档与 `docs/optimization-roadmap.md`（协议合规/agent 体验向）互补，专注**游戏制作的产品体验**。
> 规划基于第一手事实：240 工具 / 13 配方 / 12 生产 profile / 本会话已验证的链路（见 §0）。

---

## 0. 已站稳的地基（规划起点，全部有验证证据）

| 能力 | 现状 | 证据 |
| --- | --- | --- |
| 诚实完成判定 | 需求契约：`run_verification_queue(requirements)` 逐项 verified/smoke/partial/unverified，缺任何必需项 => overall=incomplete | 故障注入单测（12/12）+ slice_b 6/6 实测 |
| 修改生效确认 | `verify_change_effect` 六步链：target/entity（内嵌副本+未保存缓冲）/hosts（实例覆盖点名宿主）/applied/behaved/persist | 27/27 单测（含遮蔽/自动扫描/深度路径钉死） |
| 原生行为验收 | behavior_check 项由队列原生驱动 FRESH 运行（探针→运行→断言→停止），strict 队列拒绝零断言 | 队列单测 + 集成测试 |
| 制作配方 | 13 个 prompt：character / melee_enemy / menu / change / plan / debug / visual / release / iterate / tests / onboard / review / fix_compile | 32/32 短语存活测试 + first_contact 13 配方契约 |
| 批量与守卫 | `batch_update_scene_files`（expect_current 保留特殊配置 + 类型跟随 + dry_run） | 12/12 单测（含字节一致性） |
| 目标级编排 | `plan_game_workflow` 12 生产 profile 组装持久 DAG；BGM/游戏结束等关键词已入蓝图 | goal 蓝图单测 + game_goal_flow 集成 |
| 全链路验证 | plugin-user release（只装插件做出一个游戏，契约 COMPLETE）+ first_playable（scratch 项目到可玩切片） | 两条集成测试（CI 慢门） |

**结论**：信任层（不假报完成）与验证层（可观测、可测量）已经建成。剩余风险集中在
**表达层覆盖**（用户想说的话没有对应配方）与**冷启动**（第一句话该说什么）。

---

## 1. 分层模型："轻松 × 优质" 的拆解

```
轻松 = 发现对（说什么都有配方）   × 默认对（无需配置即可正确）  × 证据对（不用猜）
优质 = 玩法完整（支柱全覆盖）     × 手感达标（数据化 + 门禁）  × 无回归（契约验收） × 可发布（导出冒烟）
```

五个里程碑按杠杆率排序：配方是纯模板+测试（零引擎风险、每个都直接放大用户产能）→
冷启动把已验证链路产品化 → 变体解锁规模 → 硬门槛把"优质"变成默认 → 收尾把长会话/团队场景接上。

---

## 2. M1 — 配方补全：游戏支柱全覆盖（最高杠杆，优先做）

**目标**：用户描述任何常见游戏内容，都命中一个随插件分发的配方。13 → 20 个配方。

| 新配方 | 支柱 | 复用的既有能力（尽量零新工具） | 契约（每条必须 FRESH 运行 + ≥1 断言） |
| --- | --- | --- | --- |
| `make_game_map` | 关卡 | create_scene/create_tileset/configure_tileset_layers/set_tile_collision_polygon/set_tilemap_layer_cells | 玩家可通行、墙体阻挡、出生点/终点可达 |
| `make_game_pickup` | 道具 | item_pickup 模式（slice_b 已证）+ gather_task_context | 拾取计数增加、拾取后消失、（可选）持久化 |
| `make_game_save` | 存档 | 存档点/自动存档 + slice_b continue-game 已证链路 | 存档 → FRESH 重启 → 状态还原 |
| `make_game_juice` | 手感 | feel_schemes（punchy/snappy/heavy.json 已在 slice_b 验证）数据化套用 | flash/shake/hitstop/particles 逐项审计字段断言 |
| `make_game_audio` | 音画 | BGM 关键词已入 goal 蓝图 + 音频总线工具 | 总线激活、BGM 播放中、SFX 触发 |
| `make_game_boss` | 高潮 | melee_enemy 配方 + "boss 是 stats 数据不是代码分支" + 阶段切换（50% 血量） | 阶段切换发生、抗击退生效、死亡停止攻击 |
| `make_game_ranged_enemy` | 对抗多样性 | 投射物节点池 + melee_brain 同构 | 弹丸命中扣血、射程外不发射、朝向正确 |

**每个配方的出厂标准（不变量 A）**：双语触发关键词（与既有配方关键词不冲突，路由测试把关）、
操作真理内联（实测陷阱写进正文，参照 melee/menu 先例）、内嵌契约 JSON 形状、
改动后 `verify_change_effect` 收尾、短语存活单测、playbook 沉淀一节。

**DoD**：20 个配方全部通过出厂标准；first_contact 计数更新为 20；全量 GUT 0 失败；
plugin-user release 流程改用配方路径重跑一遍（契约 COMPLETE）。

## 3. M2 — 冷启动：五分钟第一个可玩切片

**目标**：新用户的**第一句话**就有满意答案。把已验证的 first_playable 链路产品化为入口配方。

1. `make_first_game(goal, genre=platformer|top_down|shooter)`：脚手架（输入映射→玩家→一张图→一个敌人→胜负条件）→
   严格契约（移动/撞墙/击败/胜负全部 FRESH 断言）→ 截图汇报。内嵌 genre 差异作为数据（同 melee 的 stats 先例）。
2. `onboard_new_project` 升级：项目体检（主场景/输入映射/渲染设置）+ 给出"你接下来该说的三句话"。
3. 配方目录自描述：`first_contact` 返回每个配方的一句话场景，客户端能展示"我能做什么"。

**DoD**：plugin-user release 流程**只用配方**走通（脚本里不再有 ad-hoc 原子调用知识）；
从装插件到契约 COMPLETE 的代理耗时作为 TTFP 指标写入测试输出（目标 < 5 分钟代理时间）。

## 4. M3 — 变体与规模：几十种敌人不返工

**目标**：从"一个杂兵"到"一个怪物图鉴"是一条链，不是 N 次重复劳动。

1. `create_scene_variant(base, overrides)` 新工具：基于场景继承生成 boss.tscn ← enemy.tscn
   （`audit_scene_inheritance` 已有审计能力，缺创建端）。
2. 数值即资源：EnemyStats 一族 .tres（`batch_create_resources` 已有），配方里"强化版/敏捷版"= 数据差异。
3. 跨变体调参：`batch_update_scene_files`（已交付，expect_current 守卫保留特殊配置）。

**DoD**："从 grunt 派生 5 个变体"一次配方链完成；变体间仅 stats/外观差异（审计断言无代码分支）；
批量重调后特殊配置原样保留（沿用既有 12/12 单测口径）。

## 5. M4 — 优质硬门槛：把"好玩可发布"变成默认

**目标**：用户不主动要求质量，质量也在。

1. 所有配方契约默认附加：`assert_no_runtime_errors`（stderr 全程零报错）。
2. 平台性能画像：desktop/mobile 两档 `assert_performance_budget`（p1_fps / p95 帧时间），
   配方按目标平台选档。
3. 关键画面 `assert_visual_baseline`（差异热力图 + 容差），菜单/主玩法/HUD 三屏。
4. `game_quality_report` 一次调用：跑齐全部门禁 → 红绿灯报告 + 每个红灯附 needs 式精确修复。

**DoD**：plugin-user release 流程包含全部门禁且绿；故障注入（故意加一个每帧报错脚本）必须让报告变红并点名。

## 6. M5 — 持续开发与团队

既有能力接入配方收尾：`manage_task_plan`（DoD 门禁）跨会话续跑、`manage_localization` 双语打包、
`bump_version` + changelog、`smoke_test_export` 发布冒烟。配方在"完成"一步自动给出下一步建议清单。

---

## 7. 横切工程纪律（每包必须过，违反即返工）

1. **零假完成不变量**：任何配方/工具不得出现无证据的 completed（队列已强制；新配方必须走 strict 契约）。
2. **关键词无冲突**：新增配方的触发词与既有 13 个两两不重叠，路由质量门禁测试同步扩充。
3. **token 预算诚实**：新工具超 400 token 需登记 `KNOWN_OVER_BUDGET_TOOLS` 并注明原因（先例已立）。
4. **测试分层省钱**：配方改动跑定向 prompts 测试 + 全量 GUT；集成测试只在里程碑收口跑。
5. **四条强制申报**：每包收尾回答最浪费往返（自愈/门禁/沉淀）、更好候选、插件影响、逐项证据归属。
6. **提交即安全**：验证绿立即提交（外部进程曾强 reset 工作区的教训）。
7. **计数同步**：配方数/工具数改动必须同步 first_contact、classifier、README、AGENTS.md、system-design。

## 8. 指标与验收汇总

| 指标 | 现值 | M1 后 | M2 后 | M4 后 |
| --- | --- | --- | --- | --- |
| 配方数（游戏支柱覆盖） | 13 | 20 | 21 | 21 |
| 支柱覆盖 | 4/10 | 10/10 | 10/10 | 10/10 |
| TTFP（装插件→契约 COMPLETE） | 有链路无入口配方 | — | 有配方 + 计时 | — |
| 假完成率（故障注入下） | 0 | 0 | 0 | 0 |
| 全量 GUT | 2307/0 | 0 失败 | 0 失败 | 0 失败 |

## 9. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 配方膨胀导致路由误命中 | 关键词两两正交 + 路由质量门禁扩充为每配方一测 |
| 配方与 12 profile 语义漂移 | 配方是"人话入口"，profile 是"目标编排"；交叉引用测试锁住映射 |
| 新工具引入回归 | 优先零新工具配方；新工具走八步出厂流程 + over-budget 登记 |
| 集成测试环境漂移（GODOT_EXE 路径） | 已文档化环境变量；CI 提供固定环境 |

---

*规划基于 2026-09-22 的 main + devin/1790023311-delivery-coverage（240 工具 / 13 配方 / 全量 GUT 2307 通过 0 失败）。*
