# P4 2D Gate Lab — 全 2D 能力真实闭环门禁

## 目标

`P4 2D Gate Lab` 不是演示 Demo，而是 Godot MCP 的系统级验收游戏。每次执行都从一个接近空白的 Godot 4.7 项目开始，通过 MCP 原子工具重新制作、运行、破坏、验证并（环境允许时）导出一个完整 2D 可玩切片。

它解决的问题不是“某个工具是否能单独返回 success”，而是：几十种 2D 制作能力组合以后，目标是否仍然能 100% 完成，并且任何缺失内容、错误证据或环境阻塞都不能被误判为完成。

## 游戏定义：2D Gate Lab

固定玩法用于降低随机性：

- 960×540 2D arena。
- CharacterBody2D 玩家，WASD / 方向键移动，Shift 冲刺，R 重开。
- TileSet + TileMapLayer 地面；TileSet 必须包含 atlas source、physics layer、navigation layer、custom-data layer、terrain set、tile collision polygon 与 terrain 标记。
- 三个可收集物来自同一个可复用 `Pickup.tscn`，通过 `save_branch_as_scene` + `instantiate_scene` 生成。
- 一个移动 Area2D hazard；碰撞后玩家回出生点，已收集计数按游戏设计保留或由测试明确断言。
- 一个 one-way CollisionShape2D 平台。
- HUD / Panel / Label / Button，应用 Theme、StyleBox、anchor、Godot 4.7 Control offset transform。
- AnimationPlayer 播放由 `create_animation` + `insert_animation_keys` 生成的动画。
- AudioStreamPlayer 与 Master bus runtime 读写。
- 数据驱动 Resource：自定义 Resource script + 单项 create + batch create + read/update。
- GradientTexture2D、DrawableTexture2D、draw_on_texture、placeholder 生成图片/音频、sprite-sheet slicing。
- Localization extract/import/list。

## 必须覆盖的 2D 专属工具

覆盖集合直接对齐 `MCPToolDomains.DOMAIN_EXTRAS["2d"]`，不得人工挑选子集：

- `create_tileset`
- `inspect_tileset_resource`
- `configure_tileset_layers`
- `set_tile_collision_polygon`
- `set_tile_terrain`
- `set_tilemap_layer_cells`
- `get_tilemap_layer_cells`
- `list_runtime_tilemap_layers`
- `set_runtime_tilemap_cell`
- `get_runtime_tilemap_cell`
- `slice_sprite_sheet`
- `create_drawable_texture`
- `create_gradient_texture`
- `draw_on_texture`
- `set_collision_one_way`

目标：2D domain coverage = **100%**。以后新增 2D 原子能力时，这个集合增长，门禁必须同步发现未覆盖项。

## 还必须跨域覆盖

### Scene / Node / Script

创建、打开、保存场景；单节点与批量节点编辑；属性更新；inline sub-resource；分组；信号连接/断开；duplicate/move/rename/delete；scene persistence / inheritance audit；脚本 create/attach/analyze/validate/verify。

### UI

`create_theme`、`set_default_theme`、`set_theme_item`、`set_anchor_preset`、`set_control_offset_transform`，运行时 theme read/override/clear，以及 editor/runtime screenshot 与 visual baseline。

### Asset / Animation / Audio

placeholder `generate_asset`、resource import metadata、2D texture generation、Animation resource authoring、runtime animation play/state/stop、runtime audio bus list/read/update。

### Runtime / Debug / QA

runtime probe、scene-ready、scene tree、node inspection、expression、project/runtime InputMap、input simulation、`play_and_verify`、runtime node create/update/delete、screenshot、memory trend、performance snapshot、runtime-condition assertion、no-runtime-error hard gate。

### Project Health

broken script、missing resource dependency、cyclic dependency、deprecated API、migration compatibility、unused resources、resource UID、project health audit。

### Shipping

始终执行 export preset / export template 探针。只有在存在合法 preset + 匹配 export templates 时才进入 validate → run_export → smoke_test_export。环境缺失必须报告 `shipping_gate=blocked/observed`，绝不能被折算成游戏完成成功。

## 故障注入：专门检查假完成

正向游戏完成后，测试必须主动制造并识别以下故障：

1. 语法错误 GDScript。
2. `.tscn` 引用不存在的资源。
3. 两个场景互相 instance 形成循环依赖。
4. 一个必然失败的 runtime assertion（例如 `score > 999`）。
5. 一个必然失败的 performance budget（例如 `min_fps=100000`）。

预期：对应工具必须返回失败证据；`audit_project_health` 必须进入 failing；测试不得把这些结果视作 completed。

随后删除故障 fixture、重新扫描，再要求项目恢复健康。

## 完成判定

### Game Completion Gate

必须同时满足：

- 场景与脚本静态门禁通过。
- 2D domain 100% 被实际调用。
- 至少 60 个不同工具被实际调用（目标是跨域组合，不是最少调用）。
- 玩家实际移动。
- 三个 pickup 实际被收集。
- victory 状态真实发生。
- runtime 断言全部通过。
- runtime error = 0。
- visual baseline 可建立并立即重验。
- performance/memory baseline 被记录。
- 故障注入全部被拦截。
- 故障清除后 project health 恢复。

任何一项失败：`status != passed`。

### Ship Gate

独立于 Game Completion Gate：

- export preset 存在。
- 当前 Godot 版本 export templates 存在。
- preset validate 通过。
- run_export 通过。
- smoke_test_export 通过。

Ship Gate 不能因为 CI 为节省下载而默认忽略。CI 可使用 `P4_2D_GATE_REQUIRE_EXPORT=0` 记录 shipping gap；正式发布门禁必须设为 `1`。

## 输出

测试最后只输出一条机器可读记录：

`P4_2D_GATE_REPORT={...}`

至少包含：

- status
- build_gate
- runtime_gate
- negative_gate
- health_gate
- shipping_gate
- distinct_tools
- total_calls
- 2d_domain_total / called / coverage / missing
- performance snapshot
- memory trend
- capability gaps

## 与 P4.2 / P4.3 / P4.4 的关系

- **P4.2**：开放目标不能因为 Profile 未命中就停止；真正缺失能力必须落入 capability gap。2D Gate Lab 用真实组合目标检验“原子能力可达 ≠ 目标可完成”的差异。
- **P4.3**：游戏制作与验证超过 10/30/60 个不同工具，目标不得因工具数、轮次或 slice 被裁掉；任何负证据都必须阻止 completed。
- **P4.4**：性能阶段先记录 baseline（工具调用数、总时间、内存、帧指标等），而不是通过删除工具、验证或必要步骤换取更低成本。

## 当前已知仓库缺口

截至建立本规范时，`main` 的 shipping 域能够 list/validate/run/smoke export，也能配置 Android，但没有一个已提交的通用安全原子工具负责“从空项目创建/更新桌面 export preset”。因此空项目 Windows ship loop 仍可能真实产生 capability gap；这个 gap 应被门禁报告，而不是用通用 editor-script 写文件来掩盖。
