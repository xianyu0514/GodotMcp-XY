# Goal Playbook — 从一句话目标到完成的正确用法

面向 AI 客户端与开发者的实操手册：如何把一个目标交给 MCP 并可靠推进到 `completed`。架构细节见 [Complete Game Workflows](game-workflows.md)；本文只讲怎么用、什么算完成、出问题时看哪里。

## 两条路径，怎么选

| 场景 | 用法 | 特点 |
| --- | --- | --- |
| 短任务（几分钟内） | `enable_tools({"workflow_query": "<目标>"})` → 直接调用激活的工具 | 一次调用激活 ≤8 个工具；命中配方时响应带 `suggested_prompt` |
| 单项修改（要证据、要可恢复） | `make_game_change` prompt（`prompts/get`）→ 按模板走 7 步循环 | 先验收条件 → 影响分析 → 变更单预览/提交（`expected_content_hash`）→ 编译+行为验证 → 证据报告；中断后同一 `change_set_id` 续跑 |
| 完整功能/整游戏 | `plan_game_workflow` → 循环 `run_game_workflow` 直到 `completed` | 持久目标 DAG、断点续跑、证据门禁；编辑器重启后可恢复 |

**目标措辞**：说清可验证的产出，不要只说领域词。好例：“方向键移动的角色，吃到金币后显示胜利标签；脚本要过校验，项目要过冒烟测试”。差例：“做个好玩的游戏”（无法编译出可验证的步骤时会显式要求澄清，不会假装完成）。

## 完成判定：证据，不是语气

`completed` 要求每个 objective gate 拿到引擎侧证据：

- `assert_no_runtime_errors` — 运行期零报错（`max_errors` 默认 0）
- `assert_performance_budget` — 采样窗口内 `min_p1_fps` / `max_p95_frame_time_ms` 等预算
- `assert_visual_baseline` — 与 `user://visual_baselines/` 黄金图对比，超容差即失败
- `verify_scripts` / `run_project_tests` / 冒烟测试 — 结构化 pass/fail 计数

缺失的度量按失败处理——证明不了就是没达标。故障注入场景用 `expect_fail` 反转门禁（证明检测器真的会拦）。

## 推进循环与状态语义

反复调用 `run_game_workflow`（`max_steps=0` 自适应切片，永不截断目标），按 `state` 行动：

- `running` / 空 → 继续调用
- `waiting`（无 `needs_input`）→ 异步步骤进行中，稍后再调
- `needs_input` → 响应里有步骤 id、缺失字段和 input_schema；创作性内容（如脚本逻辑）用 `step_inputs` 提供：`{"<step_id>": {"content": "..."}}`
- `repairing` / `repair_required` → 引擎正在用步骤声明的修复工具自愈，继续调用即可
- `replan_required` / `blocked` → 看 `blocked_reason`；输入或能力缺失是显式阻塞，不是静默跳过
- `completed` → 每个门禁都有回执摘要与工件路径

## 可执行配方（prompts）

`prompts/list` 提供 10 个即用流程模板；`enable_tools` 命中关键词时会在响应里 `suggested_prompt` 提示：

| 配方 | 用途 |
| --- | --- |
| `plan_game_feature` | GDD → 带门禁的任务图 |
| `make_game_change` | 一条需求 → 可恢复变更循环（影响分析→预览→提交→验证→证据报告） |
| `iterate_play_verify` | 运行→观测→门禁→最小修复循环（3 次同败即停） |
| `debug_runtime_error` | 运行错误端到端排查 |
| `fix_compile_errors` | 编译/校验错误修复循环 |
| `visual_playtest` | 视觉回归试玩 |
| `review_scene` | 场景审计 |
| `run_test_suite` | 测试发现与转绿 |
| `release_export_flow` | 模板→预设→版本→导出→冒烟→报告 |
| `onboard_new_project` | 新项目上手与工具启用 |

## 已知引擎语义（不是 bug，按此设计调用）

- **非 `@export` 脚本变量在编辑器场景节点上不绑定**：批量 `set_property` 会如实回报 `bound:false` 并提示改 `@export`；游戏运行时正常。
- **编辑器失焦可能节流主循环**：长下载等节点驱动任务会临时开启 Update Continuously 保活，结束自动恢复。
- **刚写入的脚本文件是"冷资源"**：工具内部已做编译守卫；自定义脚本若手动 `load()` 刚写的文件，注意 `can_instantiate()`。
- **首场景/首脚本路径自动推导**：不传路径时按 profile 落到 `res://scenes|scripts|themes/<profile>...`；要控制位置就显式传 `scene_path`/`script_path`。
- **目标蓝图**：目标提到移动/收集/胜利（双语）时，`create_script` 自动生成真实控制器（含运行期生成的拾取体与胜利标签）、场景根派生为 `CharacterBody2D`；显式传 `content` 永远优先。

## 原生行为验收（F1，验证队列直接驱动运行）

`run_verification_queue` 新增 `behavior_check` 项：队列本身编排探针安装 →
`run_project`（allow_window）→ 会话就绪 → `play_and_verify` 输入步骤与断言 →
停止，产出 `evidence_level=native_run` 的证据（场景、逐断言实际/期望值、
运行错误、截图、会话标识），受 `watch_paths` 指纹漂移保护。`strict=true`
的队列拒绝外部声明（record 报错）——完成必须有原生执行证据；非 strict
队列的外部回填显式标记 `external_claim`。

示例：给"冲刺后撞墙仍停止"建队列——
`{"command":"create","goal":"dash keeps collision","strict":true,"items":[{"kind":"behavior_check","label":"wall","detail":{"scene_path":"res://scenes/arena.tscn","steps":[{"action":"move_right","pressed":true,"wait_ms":1500,"assert":{"expression":"get_node('Player').position.x","expected":544,"operator":"lte","description":"wall blocks"}}]}}],"watch_paths":["res://scripts/player.gd"]}`
（运算符规范名：eq/ne/gt/gte/lt/lte；未知运算符显式报错。）

## 角色外观与受击反馈工作流（包 01+02，可复用）

一键接入既有玩家（首个目标 slice_b，已验证；其他项目改 config 即可）：

```bash
python scripts/apply_character_visual.py slice_b --with-regression   --godot <editor-console-exe> --port <free-port>
```

行为（全部经 MCP 调用，幂等——复跑只更新不重复）：
1. 定位声明的玩家（缺失即停并列出缺项）；2. `Skin`（Sprite2D+脚本）：
精灵表 idle/move 动画 + 朝向翻转 + 支点对齐，原色块保留可随时切回
（`use_block_visual`）；3. `HitFeedback`：闪白自恢复 + 一次性粒子 +
可配零的镜头反馈，音效走 SoundBus 既有入口不重复播放；
4. 缺素材时编辑器内程序化生成 .tres 精灵表（无二进制入仓）；
5. `take_hit` 接线经 apply_change_set（哈希保护，已接线则跳过）；
6. `--with-regression` 跑 strict 队列：移动保留、单次扣血、无敌窗
防双扣、闪白恢复（直接驱动 take_hit，不依赖地图布局）。

可调参数（@export，运行中即可经 MCP set_property 改）：
Skin: `idle_frames / move_frames / animation_fps / pixel_offset / use_block_visual`；
HitFeedback: `flash_color / flash_seconds / particle_amount / camera_shake_pixels / camera_shake_seconds`。
覆盖默认用 `--config my.json`（见脚本头部 DEFAULT_CONFIG）。

前后画面：`slice_b/build/character_polish/`（sprite / block / hit_flash 三图）。

## 插件热同步循环（边用边修的标准机制）

仓库侧一键脚本 `scripts/hot_sync_plugin.py <目标工程> --port 9080`：
按内容差异同步 `addons/godot_mcp` → 触发编辑器文件系统扫描 → 等待主线程
稳定（扫描期间派发看门狗会 503，这是设计保护）→ 健康探针。

实测边界（一次真实事故换来的）：
- **不要对服务中的工具模块显式 `.reload()`** —— 实例方法分派错位，下一次
  behavior_check 直接断连。编辑器自己的外部变更热重载是唯一安全路径。
- 扫描/导入期间 503 = 主线程忙（"Retry shortly"），等稳定即可，不是故障。
- 行为变更可靠生效 = 编辑器重启；大多数情况编辑器自动热重载即可生效；
  数据文件（csv/json）立即生效。

循环形态：用 MCP 做游戏 → 撞缺陷 → 仓库修复（先失败测试）→ hot_sync →
编辑器自动重载 → 重跑 strict behavior_check 验证 → 继续。

## 做可玩内容的实测要点（first-playable 冒烟沉淀）

- **`create_scene` 写文件但不打开**：建完先 `open_scene`（Vibe Coding 模式下带 `allow_ui_focus=true`）再 `create_node`，否则报 "No active edited scene"。
- **抢焦点/开窗口的动作要显式授权**：`open_scene` 带 `allow_ui_focus`，`run_project`/`stop_project` 带 `allow_window` —— 这是 Vibe Coding 守卫的设计行为，报错文本会说明。
- **坐标接受 JSON 数组**：`set_property` 的 `property_value` 用 `[320, 288]` 即可（也接受 `{"x":..,"y":..}` 与字符串形式）。
- **WASD 绑定用物理键码**：`upsert_project_input_action` 事件形如 `{"type":"key","physical_keycode":65}`（跨键盘布局稳定；keycode 是当前布局逻辑键，二者至少其一）。
- **运行时探针先装后跑**：`install_runtime_probe`（persistent）→ `run_project` → 等 debugger 会话激活 → 再驱动输入；`await_runtime_condition` 会真等到条件成立或超时（新鲜但为假会继续轮询）。
- **表达式相对当前场景解析**：`evaluate_runtime_expression` 的 base 默认是 current_scene，`get_node('Player').position.x` 这类相对写法最稳；裸 `node_path` 从探针根解析。
- **改脚本后要确认场景引用的是外部文件**：`create_script` 挂载按外部路径引用；若手工内嵌过源码，改 .gd 文件不会影响场景 —— 用 read_script 与运行实测对照。
- **传错参数名不会再静默**：调度层会在结果里附 `_schema_warnings` 指出未知键与 schema 实际键集，一次往返即可自纠。

## 修改生效确认链（verify_change_effect 的实测要点）

"代码/属性改了，玩起来没变化" 的四类真凶与逐项证据（verify_change_effect 已固化，这里记录口径）：

1. **内嵌脚本副本**：节点段写 `script = SubResource("GDScript_xxx")` 时，对外部 .gd 的任何修改都到不了游戏（attach_script 曾在保存时嵌入副本——已修，但历史场景仍可能带着内嵌副本）。修复：`attach_script` 换回外部引用 + `save_scene`。
2. **未保存缓冲**：`run_project` 从磁盘启动，编辑器缓冲里的修改永远不进游戏。修复：`save_scene` / `save_all_scripts`。
3. **实例覆盖（最隐蔽）**：直跑基场景全通过，但真实游戏跑的是宿主场景——宿主里 `[node name="X" parent="." instance=ExtResource(...)]` 的属性覆盖值胜过基值。verify_change_effect 的 hosts 步会点名宿主文件+节点，needs 直接给出带 `expect_current` 的 `batch_update_scene_files` 修复调用。
4. **只在内存生效**：第二次磁盘启动读回不一致 => 改动没落盘。

**GDScript 值语义三连坑**（本会话实测三次，写 GDScript 前先想引用还是值）：
- lambda 按值捕获局部变量——计数器/状态跨调用不持久，用 Dictionary 单元格当可变盒子；
- `PackedStringArray` 等打包数组是值类型——`as` 转换后 append 改的是副本，容器里存的
  不变；要可变集合用 `Array`，或取值-修改-写回。

**.tscn 文本解析的两个实测陷阱**（解析器已按此实现，改动前先读这里）：
- `parent` 属性**不含根名**：`[node name="Leaf" parent="Mid"]` 的完整路径是 `Root/Mid/Leaf`，不是 `Mid/Leaf`（TestScene.tscn 实测）。
- `instance=ExtResource("id")` 的 id 前面是 `(`，键值正则 `key="value"` 匹配不到——必须从原始头部行直接提取，否则宿主实例永远识别不出。

## M1 三配方的实测要点（地图 / 道具 / 存档）

- **地图**：TileSet 必须显式赋给 TileMapLayer，否则刷了格子不渲染；碰撞层先于涂画配置；
  位移断言用 displacement_min/max（相对值），起点非原点的关卡会被绝对阈值误杀；
  批量写瓦片后物理要等一帧再断言。关卡实例化玩家/敌人 => 对关卡场景验收，宿主覆盖胜过基值。
- **道具**：Area2D + body_entered 信号收集（绝不轮询）；节点 queue_free 后读不到——
  断言计数器而不是节点；防双拾取要在同一次回调里处理。
- **存档**：存 user://（res:// 在导出后只读——只在出货时才咬人的陷阱）；显式字段清单 +
  版本号；跨 FRESH 项的持久证据只有 user:// 文件本身（运行时状态不跨项）——
  项1 玩+存盘断言文件存在，项2 FRESH 启动断言还原。

- **手感**：feel 即数据（一个方案=一组旋钮）；hitstop 必须 ALWAYS 恢复 time_scale
  （泄漏的 hitstop 冻结游戏）；闪光要"设置且恢复"双向审计；震屏断言相机真的动了。
- **音频**：MCP 不能合成音频文件——诚实边界是"系统全接好、文件你来放、缺文件点名"；
  SFX 用小池（单播放器放长音效会掐断 BGM）；验证靠播放器/总线状态（听不到就断言状态）。
- **Boss**：= 近战脑 + stats 数据（击退抗性）+ 阶段表（阈值→旋钮覆盖行），
  行为脚本里没有 if-boss；竞技场实例化 Boss => 对竞技场验收。
- **远程敌人**：每次射击前必须有前摇（无前摇=不可闪避=缺陷）；投射物命中**和**超时
  都要 free（泄漏静默拖垮性能，断言活跃数回到基线）。

## 本地集成验证的三个实测坑（2026-09-23 首次本地跑通全链路）

- **嵌套项目残留会杀掉整个插件**：仓库根下未跟踪的 stress_game/（含插件全量副本，
  连 .uid 一起复制）被编辑器扫描 → 同名全局类 "hides a global script class" →
  真插件编译链失败 → MCP 服务器起不来。CI 绿是因为干净 checkout 无残留；
  本地"服务器没起来"先查根目录嵌套项目。移出后还要清 .godot/（UID 缓存仍指向
  已移走的副本路径）。
- **project.godot 的键是 `config/name=` 不是 `config_name=`**：写错时项目名静默为空，
  不报错——plugin_user_release 的项目名断言就是这么挂的（测试自身的键名笔误）。
- **集成测试里的硬编码计数会静默漂移**：first_contact 的 "238-tool" 历经五次工具
  计数递增都没更新（本机"跑不了"就没人看它）。凡是 pin 计数的测试，计数变更的
  同步清单必须包含集成层。

## L3 终局验收实测出的两条铁律（2026-09-23，俯视迷你高尔夫首跑）

- **Godot 的 Expression 类不支持三元语法**：`x if c else y` 连 `(1 if true else 2)`
  都是 parse error 31；`self` 标识符同样非法。任何要送进探针求值的表达式只能用
  裸属性/方法调用/比较。verify_change_effect 的读回表达式已按"根名已知"重写
  （根=>裸属性，子=>get_node 相对路径），并有单测钉死"生成式必须可 parse"。
- **connect_signal 连的是编辑器实例**：连接不写进 .tscn 的 [connection]，
  flags=1（CONNECT_PERSIST）经此保存路径也不落盘——运行时游戏里是死按钮。
  可靠持久路径是脚本侧 `_ready` 里 `signal.connect(...)`（代码即持久）。
  工具现会在缺 PERSIST 位时自愈警告；menu 配方已改为教脚本侧接线。

## 文本级 .tscn 改写与编辑器缓存（M6 真机验证实测）

- 文本改写绕过编辑器 → **资源缓存仍是旧场景**；batch_update_scene_files 已在写盘后
  做 `ResourceLoader.load(..., CACHE_MODE_REPLACE)` 自行刷新（答案同行）。
- 已打开的场景标签聚焦的是**旧实例**（open_scene 的 already_open 路径）——
  完整调用流是"改盘 → close_scene_tab → open_scene"重新实例化。
- create_scene_variant 生成的继承场景经真引擎加载验证（零错误、覆盖可读回）；
  变体节点段 parent 语义与解析器一致（相对根，"."=根的直接子级）。

## 着色器两条实测铁律（make_game_shader 首跑）

- **uniform 默认值读回是 null**：`get_shader_parameter` 只读材质上显式 set 过的值，
  默认值活在着色器代码里。运行时读值必须先 `set_runtime_shader_parameter` 再读回；
  挂载证明用 `material is ShaderMaterial` + `material.shader != null`。
- **Expression 不支持 is 运算符**（同禁三元）：类型断言用
  `material.get_class() == 'ShaderMaterial'` 这类字符串比较。
- **无效着色器先拒后写**：create_script 的 .gdshader 分支在落盘前做文本校验
  （shader_type/括号/结构），无效内容不写盘——坏文件不进项目，也避开导入器噪音。

## 出问题时的取证顺序

0. 工具返回 "Tool is disabled" 时先 `enable_tools`（supplementary 工具默认关闭，
   这是设计行为而非故障；大型项目上 `list_project_tests` 实测 <0.1s，慢的错觉
   常来自把禁用报错当成了超时）
1. `run_game_workflow` 响应的 `blocked_reason` + 最后一个 `executed` 条目
2. `manage_task_plan` / 计划文件（`.mcp/<plan>.json`）里的回执摘要
3. `get_editor_logs`（`source='runtime'` 看运行错误，`source='editor_panel'` 看引擎报错）
4. 目标级回归 `test/integration/test_game_goal_flow.py`（全新项目 → completed 全链路）可当作行为基线

## 自动提交的回归保障

- `test_first_contact_flow.py` — 首次接入契约（initialize 指引、惰性工具面、项目识别、自愈报错、workflow_query 路由、prompt 配方）
- `test_first_playable_flow.py` — 可玩切片冒烟（纯原子工具：建输入/场景/脚本 → 运行验证移动+撞墙 → apply_change_set 改参数实测生效 → 编辑器重启持久性）
- `test_game_goal_flow.py` — 目标级闭环（scratch 项目 → plan → run → completed）
- `test_batch_scene_node_edits_flow.py` — 单调用脚本化节点组装 + 真值断言
- 1784 项单元测试覆盖路由、门禁语义、缓存一致性与工具校验
