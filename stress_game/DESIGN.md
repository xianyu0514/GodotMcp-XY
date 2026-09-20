# Stress Game — 日常使用全场景压力测试游戏

版本：0.1（设计基线）· 目标：一个真正可玩的 2D 游戏，同时是 MCP 日常使用场景的完整验收夹具。

## 0. 定位与原则

本工程是合并 ease-of-use 分支后的**第一款游戏**，设计目标只有一个：
让"AI 通过 MCP 做游戏的日常"中会遇到的每一类场景，都在一个真实工程里
有对应的房间、对应的行为验收、对应的回归测试。

原则（继承自主仓库 AGENTS.md 与 goal-playbook）：

- **先验收条件，后动工**：每个场景先写可观察的通过标准（M1.2 模板的具体化）。
- **只改相关内容**：每个场景的修改走 `make_game_change` 循环（影响分析→预览→提交→验证→回执）。
- **证据不是语气**：完成判定只看引擎侧证据（运行时表达式、日志、截图、基线、性能采样）。
- **不重造 slice_b**：slice_b 已深度覆盖保存/继续/三地图/导出；本工程复用其模式与脚本结构，场景不重复建设（见 §3 对照表）。
- **内容入库、插件不入库**：与 slice_b 相同，`stress_game/addons/` 由 setup 同步（gitignore），无二进制素材。

## 1. 游戏设计（它首先得是个游戏）

**《STRESS ARENA》**：单屏房间制 2D 动作游戏。玩家在一个训练设施里逐间
通过"考核房间"，每间房间考察一种能力（对应一个 MCP 场景）：

- 房间 1「热身走廊」：移动 + 边界（S01）
- 房间 2「收集考核」：拾取金币入库（S02）
- 房间 3「受击训练」：训练假人、无敌帧、击退、死亡重生（S03）
- 房间 4「控制台」：HUD、暂停、开始/继续菜单（S04）
- 房间 5+「换区」：关卡切换与跨区状态（S05）
- 全程：存档/继续（S06，模式沿用 slice_b game_save）
- 换装间：素材替换 + 动画 + 音频（S07/S08）

玩法定位刻意简单——它是**夹具优先**的游戏：每个房间 = 一个可参数化验收的
行为单元。手感与美术的"好玩/好看"由人判断，自动验收只锁定客观行为。

## 2. 场景目录（MCP 能力 × 行为验收）

| # | 日常场景 | 主要 MCP 能力 | 行为验收（可观察） |
|---|---|---|---|
| S01 | 移动/手感/碰撞 | gather_task_context、create_node/batch、upsert_project_input_action、create_script、run+probe、simulate_input_action、await_runtime_condition、apply_change_set 参数迭代 | 固定输入位移=预期；撞墙停在精确内沿；冲刺有冷却；参数改动实测生效（前后值+轨迹） |
| S02 | 交互/拾取/背包 | batch connect_signal、HUD 节点、运行时表达式断言 | 接触→对象消失+计数+1；重复接触不重复计；背包状态与世界状态一致 |
| S03 | 战斗/受击 | 上述+计时器/信号 | 伤害数值正确；无敌帧窗口内不重复受伤；击退向量方向正确；死亡→重生位置正确 |
| S04 | UI/暂停/焦点 | Control 节点、theme 工具、暂停语义 | 菜单可见可焦点导航；暂停时 get_tree().paused 下玩家静止；恢复继续 |
| S05 | 切场景/出生状态 | 场景工具、run_project(scene_path) | 目标地图加载；出生点正确；跨场景状态保留；切换无运行错误 |
| S06 | 保存/继续 | 复用 slice_b game_save 模式 | 非默认地图/位置/生命/物品完整恢复；二次继续不重复奖励；损坏回退（slice_b 已证模式） |
| S07 | 素材替换 | generate_asset/create_drawable_texture、引用更新、assert_visual_baseline | 引用正确；动画帧数/尺寸/碰撞同步；画面差异在容差内或有认可记录 |
| S08 | 音频 | 音频总线、播放状态断言 | 总线存在；播放状态可断言；音量调整生效 |
| S09 | 性能预算 | assert_performance_budget、performance_snapshot | 固定场景下 p95 帧时间/内存/节点数在预算内 |
| S10 | 视觉回归 | assert_visual_baseline、compare_render_screenshots | 无基线→bootstrap 并标注；超容差→红；认可记录区分客观缺陷与主观选择 |
| S11 | 错误定位 | get_editor_logs、make_game_change 修复循环 | 注入错误被检测→定位→修复→复验通过（故障演练） |
| S12 | 导出/冒烟 | export preset CRUD、run_export、smoke_test_export | PCK 产物存在+启动退出码；EXE 腿按模板前提显式判定（缺模板=未验收非通过） |
| S13 | 长会话迭代 | make_game_change 循环 ×N | ≥10 项连续修改互不破坏；手工编辑受保护；中断恢复同 change_set_id |
| S14 | 中断恢复 | apply_change_set 同 ID 续跑 | 第 N 文件中断→续跑跳过已应用→冲突显式停止（已有 change_set recovery 测试模式，游戏内实景重演） |

## 3. 与既有资产的关系（不重复建设）

| 已有资产 | 覆盖 | 本工程动作 |
|---|---|---|
| slice_b（三地图/存档/导出/素材自检） | S06 深度、S12 部分 | 复用 game_save.gd 模式与 prepare_assets 幂等合成思路 |
| test_first_playable_flow.py | S01 的冒烟级 | 升级为 tracked 工程上的实景验收（内容入库，不再每次从零建） |
| test_first_contact_flow.py | 客户端接入契约 | 直接复用，不改 |
| goal-flow / slice-b CI 腿 | 目标引擎与切片链路 | 不动；本工程 E2E 进 fast 集（runner 自动发现） |

## 4. 工程结构与构建方式

```
stress_game/
├── DESIGN.md            # 本文件
├── project.godot        # 独立工程（StressGame）
├── scenes/              # 房间场景（MCP 原子调用构建，入库）
├── scripts/             # 玩家/房间/验收脚本（MCP 写入，入库）
├── data/                # 场景参数与验收清单（JSON）
├── build/               # 导出产物（gitignore）
└── test/                # 验收 E2E（主仓库 test/integration 调用）
```

- 插件同步：`stress_game/addons/`（gitignore）由测试 setup 从主仓库拷贝 —— 与
  slice_b setup.ps1 相同的幂等模式。
- **内容由 MCP 构建**：每个房间的场景/脚本通过 make_game_change 循环产生，
  产物入库；这本身就是对"日常使用"的持续实测。
- 每场景一个验收流：`test/integration/test_stress_s<NN>_flow.py`（fast 集自动接线）。

## 5. 里程碑（G 门禁沿用主仓库规划）

- **SG0**：工程脚手架 + 房间 1 内容入库 + S01 验收 E2E 绿（本轮）。
- **SG1**：S02–S05（拾取/战斗/UI/切场景）内容+验收全绿；连续 10 项修改演练（S13）通过。
- **SG2**：S06–S10（存档/素材/音频/性能/视觉）+ 认可记录流程。
- **SG3**：S11–S14（故障演练/导出/中断恢复）+ 发布包玩家验收（对齐 G3）。

## 6. 验收记录约定

每个场景的验收产物统一记录：目标、验收条件原文、修改清单（change_set_id）、
实测值（运行时表达式回执）、截图/基线路径、未验证项。存于
`stress_game/data/acceptance/<scenario>.json`，由验收流写入 —— 证据绑定当次
运行的场景内容哈希，内容变更后旧记录显式过期。
