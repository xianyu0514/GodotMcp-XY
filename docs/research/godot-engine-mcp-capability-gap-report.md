# Godot 4.7 引擎能力 × MCP 工具差距研究报告

> 研究目标：找出 **尚未被现有 215 个 MCP 工具覆盖** 的高价值 Godot 4.x 引擎能力，产出能力差距表、Top 20 工具建议与四个特别关注专题。
> 研究基线：`addons/godot_mcp/`（215 工具，6 大类，GDScript 原生 MCP 服务器，GL Compatibility）。
> 研究方法：本地浅克隆 [godot-docs](https://github.com/godotengine/godot-docs)（tutorials + classes 全量物化），逐类核对 `classes/class_*.rst` API 方法表与 tutorials 教程；抓取官方 [4.4/4.5/4.6/4.7 发布页](https://godotengine.org/releases/) 正文；读取 4.4–4.7 迁移指南；与插件 `docs/tools/*.md` 工具清单、`mcp_runtime_probe.gd`、`mcp_debugger_bridge.gd` 逐项交叉核对。
> 日期：基于 godot-docs master（4.7 后段）+ 官方 release 4.7 页。

---

## 0. 总览（Executive Summary）

现有插件已形成"节点/脚本/场景/编辑器/调试/项目"六大闭环，且已具备**高质量的验证层**（`play_and_verify` 确定性帧步进、`assert_no_runtime_errors`、`assert_visual_baseline` 视觉门禁、`assert_performance_budget` 性能门禁、`smoke_test_export`）与**异步轮询模式**（`run_project_test`、`generate_3d_asset`）。这与官方 4.6 "polish and workflow"、4.7 "Director's Cut" 的迭代方向高度一致。

**最大差距集中在四个方向：**

1. **3D 制作闭环缺失**：没有 GI 烘焙（LightmapGI/VoxelGI）、NavMesh 烘焙、物理体/关节/射线查询、GridMap/MultiMesh 工具 —— AI 可以"搭 3D 场景"但无法"烘焙光照与导航、验证碰撞可达性"，3D 工作流是半成品。
2. **撤销/回滚不成体系**：插件已在 6 处内部使用 `EditorUndoRedoManager`（节点 CRUD、属性、实例化、TileMap 单元格、子资源），但**没有 `undo`/`redo`/`get_undo_history` 工具**、属性微调不合并（无 MERGE_ENDS）、脚本/资源文件直写绕过撤销栈、`version_changed` 信号未通知 AI。
3. **长任务异步化只有"点状"实现**：烘焙（GI/NavMesh/GridMap bake）、导出、PCK、导入扫描、录制等重活没有统一的异步作业框架（start/poll/cancel/progress）。
4. **语言服务与诊断未利用官方 LSP**：`--lsp-port`/`GDScriptLanguageProtocol`/`--dap-port`/`--gdscript-docs`/`--check-only` 全部未用，脚本验证停留在"手动 reload + 文本解析"，缺结构化诊断（错误/警告/补全）。

**4.4–4.7 值得立刻暴露的新 API**（详见 §2.10）：ObjectDB 快照泄漏检测（4.6）、IK 框架与 RetargetModifier3D（4.6）、MeshLibrary 编辑器（4.7）、DrawableTexture2D（4.7，**已被插件覆盖** ✅）、HDR 输出（4.7，configure_render_output 部分覆盖）、自定义快捷键 EditorSettings.add_shortcut（4.6）、custom loggers（4.5）、MovieWriter 确定性录制（4.7 增强）、单平台导出模板下载（4.7，manage_export_templates 部分覆盖）。

---

## 1. 能力差距表

覆盖标记：✅ 已覆盖 | 🟡 部分覆盖 | ❌ 未覆盖。价值 = 对 AI 自主开发的实际增益。

### 1.1 3D 相关工作流

| 引擎能力（官方文档依据） | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| **LightmapGI 烘焙**（[class_lightmapgi](https://docs.godotengine.org/en/latest/classes/class_lightmapgi.html)，4.4 新增 shadowmask、bicubic；注意 4.7 master 文档 Methods 段为空，`bake()` 疑似在 4.7 周期移除，实施前必须按目标版本验证） | ❌ | 高 | `bake_lightmap` — 配置 LightmapGI 参数（quality/bounces/texel_scale/shadowmask）→ 异步烘焙 → 进度 → 烘焙后截图门禁；4.7 若 bake() 移除则回退编辑器驱动或 LightmapGIData 手工装配 |
| **VoxelGI 烘焙**（`bake()`/`debug_bake()` 存在） | ❌ | 高 | `bake_voxel_gi` — 程序化场景实时 GI 的烘焙入口（VoxelGI 支持运行时烘焙，适合 AI 生成关卡） |
| **NavigationMesh 烘焙**（[NavigationRegion3D.bake_navigation_mesh(on_thread)](https://docs.godotengine.org/en/latest/classes/class_navigationregion3d.html)、[NavigationServer3D.parse_source_geometry_data / bake_from_source_geometry_data_async](https://docs.godotengine.org/en/latest/classes/class_navigationserver3d.html)、NavigationMeshSourceGeometryData3D/2D） | ❌ | 高 | `bake_navigation_mesh` — 2D/3D NavMesh 烘焙：region 烘焙 + server 级 parse→bake（支持 async、复用 source geometry、chunk 边界/border） |
| **物理体与形状**（StaticBody/RigidBody/CharacterBody3D、CollisionShape3D/2D、Area3D、物理材质；4.6 起网格→碰撞形状一键生成；Jolt 为 4.6 新项目默认 3D 引擎） | ❌ | 高 | `setup_physics_body` — 创建/配置刚体、生成并对齐碰撞形状（含 4.6 mesh→shape）、设置 layer/mask 位掩码、物理材质 |
| **关节与约束**（Generic6DOF/Pin/ConeTwist/Hinge/SliderJoint3D、Joint3D） | ❌ | 中高 | `create_joint` — 连接两个物理体并配置关节参数/轴锁定 |
| **射线/空间查询**（[PhysicsDirectSpaceState3D.intersect_ray / intersect_shape / intersect_point](https://docs.godotengine.org/en/latest/classes/class_physicsdirectspacestate3d.html)、RayCast3D 节点） | ❌ | 高 | `physics_query` — 对场景空间状态做 ray/shape/point 查询，AI 验证"子弹能否打到目标""角色脚下是否有地面" |
| **GridMap 编辑**（[GridMap.set_cell_item/make_baked_meshes](https://docs.godotengine.org/en/latest/classes/class_gridmap.html)、MeshLibrary；4.6 Bresenham 连线、4.7 专用 MeshLibrary 编辑器） | ❌ | 中高 | `edit_gridmap` — 批量 set/erase 单元格 + `make_baked_meshes` 烘焙合并网格；`manage_mesh_library` 管理 MeshLibrary（配合 4.7 新编辑器） |
| **MultiMesh 实例化**（[MultiMesh.set_instance_transform / set_instance_color / custom_data](https://docs.godotengine.org/en/latest/classes/class_multimesh.html)） | ❌ | 中 | `edit_multimesh` — 批量设置实例变换/颜色/自定义数据，AI 一键铺草、人群、粒子替代 |
| **反射探针/雾/环境**（ReflectionProbe 4.6 octahedral、Environment volumetric fog、WorldEnvironment） | 🟡 通用属性可改 | 中 | `setup_environment` — 环境/雾/SSR/glow/tonemap 一键配置 + ReflectionProbe 创建刷新 |
| **材质/网格细节**（StandardMaterial3D、ArrayMesh 程序化、LOD、OccluderInstance3D 遮挡剔除） | 🟡 子资源读写 | 中 | `build_array_mesh` — 从顶点/索引/法线数组程序化构建 ArrayMesh 并落盘（AI 生成几何） |
| CSG（4.4 起 Manifold 实现、4.7 Autosmooth） | 🟡 节点可建 | 低 | （可选）`bake_csg_mesh` — CSG→MeshInstance 烘焙 |

### 1.2 动画

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| Animation 资源 + 关键帧 | ✅ `create_animation` / `insert_animation_keys` | — | — |
| **AnimationTree 编辑**（[AnimationNodeStateMachine.add_node/add_transition/rename_node/set_node_position](https://docs.godotengine.org/en/latest/classes/class_animationnodestatemachine.html)、BlendSpace1D/2D add_blend_point（4.7 增加 name 参数）、AnimationNodeBlend2、AnimationNodeOneShot 等） | ❌ 编辑期 | 高 | `author_animation_tree` — 状态机/混合空间/转换表编辑 + 保存；`preview_animation_tree` 运行时联动预览 |
| **骨骼编辑**（[Skeleton3D](https://docs.godotengine.org/en/latest/classes/class_skeleton3d.html) bone rest/pose、bone 增删、`set_bone_pose`；SkeletonProfile 导出） | ❌ | 中高 | `edit_skeleton` — 骨骼层级/rest/pose 读写，配置骨架配置文件 |
| **骨骼重定向**（[retargeting_3d_skeletons](https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/retargeting_3d_skeletons.html)：导入期 BoneMap+SkeletonProfile（Humanoid 预设）+ 导入选项；运行时 [RetargetModifier3D](https://docs.godotengine.org/en/latest/classes/class_retargetmodifier3d.html)（4.6+）） | ❌ | 中高 | `retarget_animation` — 生成 BoneMap、自动映射、设置 glTF 导入 retarget 选项、运行时 modifier 挂载 |
| **程序动画**（4.4 LookAtModifier3D/SpringBoneSimulator3D；4.6 全新 IK：IKModifier3D + TwoBoneIK3D/SplineIK3D/FABRIK3D/CCDIK3D/JacobianIK3D + BoneConstraint3D/AimModifier3D/CopyTransformModifier3D） | ❌ | 中 | `configure_procedural_animation` — 挂载/配置 IK 链与约束，设置目标节点（AI 摆"手臂够到武器"这类姿势） |
| BlendShape 权重/导入 | ❌/🟡 | 低中 | `set_blend_shape` — 网格表面 BlendShape 权重（可走 Animation 值轨道，但无直连） |
| Animation markers（4.4） | ❌ | 低 | （并入 author_animation_tree） |
| AnimationMixer 运行时（advance/capture/deterministic） | 🟡 probe | — | — |

### 1.3 UI 系统

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| Theme 创建/条目/项目默认 | ✅ create_theme/set_theme_item/set_default_theme | — | 建议补 `get_theme_summary`（回读+差异） |
| 布局/锚点 | 🟡 set_anchor_preset + 属性工具 | — | 中 | `layout_control` — 容器排序/偏移/尺寸/锚点批量布局 + 多分辨率截图验证（配合 4.7 offset_transform 视觉变换） |
| **UI 运行时自动化**（[Input.parse_input_event/flush_buffered_events](https://docs.godotengine.org/en/latest/classes/class_input.html)、Viewport.push_input、Control 焦点） | ✅ 输入注入 + scene_tree probe | — | 建议补 `ui_widget_query` — 运行时按类型/文本定位 Control、读几何、断言可见/聚焦状态 |
| 编辑器内 UI 测试（点击编辑视图） | ❌ | 低 | — |
| 4.7 Control `offset_transform_*`、VirtualJoystick（4.7 新节点）、AccessKit 无障碍（4.5） | ❌ | 低 | （可选）create_ui_node 扩展现有节点创建即覆盖 |

### 1.4 资源管线

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| .tres/.res 序列化读写 | ✅ create/read/update/batch | — | — |
| **导入选项编辑**（[importing_images](https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/importing_images.html) 纹理压缩/VRAM/Betsy（4.4）/mipmaps、[importing_audio_samples](https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/importing_audio_samples.html)、glTF 导入选项；4.5 批量编辑 Import dock） | ❌ | 高 | `set_import_options` — 按文件/扩展名/批量设置 .import 选项 + `EditorFileSystem.reimport_files` 重导入 |
| **自定义导入器**（[EditorImportPlugin](https://docs.godotengine.org/en/latest/classes/class_editorimportplugin.html) 虚拟方法、[EditorPlugin.add_import_plugin](https://docs.godotengine.org/en/latest/classes/class_editorplugin.html)；4.3+ [EditorScenePostImportPlugin](https://docs.godotengine.org/en/latest/classes/class_editorscenepostimportplugin.html) 导入后处理 _pre_process/_post_process） | ❌ | 中高 | `create_import_plugin` — 生成导入器/后处理脚本骨架 + 注册 + 验证导入链路 |
| 导入状态/扫描 | ✅ get_import_status（4.7 is_importing）/reload_project/reimport_resources | — | 建议补 `EditorFileSystem.update_file`（单文件增量） |
| UID 管理 | ✅ get/fix resource uid | — | — |
| AudioStream/VideoStream 运行时 | 🟡 | 低中 | 并入 set_import_options |
| ResourceSaver/Loader 自定义格式（add_resource_format_saver） | ❌ | 低 | — |

### 1.5 编辑器扩展 API（[EditorInterface 全方法](https://docs.godotengine.org/en/latest/classes/class_editorinterface.html)）

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| 场景打开/保存/关闭/运行/停止 | ✅ | — | — |
| **编辑器导航定位**（`edit_node`/`edit_resource`/`edit_script(line,column)`/`inspect_object`/`set_main_screen_editor`/`get_selection`） | ❌ | 高 | `editor_navigate` — AI 改完代码/节点后把编辑器"指到"对应位置（人机协同）；`switch_editor_screen`（2D/3D/Script/AssetLib） |
| **场景重载/未保存**（`reload_scene_from_path`、`save_all_scenes`、`get_unsaved_scenes`、`mark_scene_as_unsaved`、`restart_editor(save)`） | 🟡 部分（get_unsaved_changes 4.7） | 中高 | `reload_scene` — 外部/脚本修改后从磁盘重载场景；`restart_editor` 兜底 |
| **资源缩略图**（[EditorResourcePreview.queue_resource_preview](https://docs.godotengine.org/en/latest/classes/class_editorresourcepreview.html)（异步回调）、[EditorInterface.make_mesh_previews](https://docs.godotengine.org/en/latest/classes/class_editorinterface.html)（网格预览图）） | ❌ | 高 | `resource_preview` — AI 生成 3D 资产后立刻拿到缩略图自检，无需打开编辑器 |
| 检查器刷新（`inspect_object`、`EditorInspector`） | 🟡 get_inspector_properties | 中 | 并入 editor_navigate |
| EditorFileSystem（`scan`/`scan_sources`/`reimport_files`/`update_file`/`is_importing`） | 🟡 | 中 | 并入 import 工具组 |
| **EditorUndoRedoManager 工具化**（见 §4.1） | 🟡 内部使用 | 高 | undo/redo/get_undo_history/事务合并 |
| EditorSettings 快捷键（[add_shortcut 4.6](https://docs.godotengine.org/en/latest/classes/class_editorsettings.html)）、set_builtin_action_override | 🟡 set_editor_setting | 低中 | `manage_editor_shortcuts` |
| EditorToaster（push_toast）、EditorCommandPalette（add_command） | ❌ | 低 | `notify_editor` — AI 操作完成后给编辑器弹提示 |
| **EditorVCSInterface（git 集成）**（commit/stage/unstage/pull/push/branch/remote） | ❌（bump_version 无 git） | 中 | `editor_vcs` — 经编辑器 VCS 接口做 git 状态/暂存/提交（与 bump_version 联动，形成"改代码→验证→提交"闭环） |
| **EditorDebuggerPlugin/Session**（编辑侧调试会话定制：send_message/set_breakpoint/toggle_profiler/add_session_tab） | 🟡 运行时侧 EngineDebugger 已用 | 中 | `debugger_session` — 订阅/驱动调试会话（与既有 mcp_debugger_bridge 互补） |

### 1.6 GDScript 语言服务

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| 脚本读写/分析/验证 | ✅ script_tools（analyze/verify/符号索引） | — | — |
| **结构化诊断（LSP）**：GDScript LSP 服务器（`--lsp-port`）、[GDScriptLanguageProtocol.notify_client](https://docs.godotengine.org/en/latest/classes/class_gdscriptlanguageprotocol.html)；4.6 BBCode→Markdown 改进 | ❌ | 高 | `get_script_diagnostics` — 编辑后拉取解析/类型错误+警告（含 file/line/column/严重级），替代文本 grep；`lsp_hover/complete` 查询类型与补全建议 |
| **脚本编译校验**（`Script.reload()` 返回 Error；`--check-only --script` CLI；EditorFileSystem 扫描错误） | 🟡 verify 有 | 中高 | `assert_script_compiles` — reload 脚本并返回结构化编译错误 + 自动 reload_open_scripts 防覆盖 |
| 代码补全（LSP completion；无公开 EditorCodeCompletion 类） | ❌ | 中 | 并入 get_script_diagnostics（LSP completion 响应） |
| **文档生成 GDScriptDocGen**（[`--gdscript-docs <path>`](https://docs.godotengine.org/en/latest/tutorials/editor/command_line_tutorial.html) 从 GDScript 注释生成 API 参考） | ❌ | 中 | `generate_script_docs` — 为项目脚本生成 HTML/XML API 文档 |
| **DAP 调试适配**（`--dap-port`，外部编辑器调试） | ❌ | 中 | `start_dap_server` — 暴露 DAP 端口供外部 IDE 接入（与内部调试桥互补） |

### 1.7 headless / CI 工具链

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| 导出/模板管理/PCK | ✅ run_export/smoke_test_export/manage_export_templates（4.6+；4.7 单平台模板下载部分覆盖）/pack_pck | — | — |
| `--headless`/`--script`/`--import` 通用任务 | 🟡 run_export 用 CLI | 中 | `headless_task` — 后台跑自定义 `-s` 脚本（批量转换/校验/导入），复用异步框架 |
| 测试运行器（GUT + Python） | ✅ run_project_test(s) | — | — |
| `--write-movie` / MovieWriter（[class_moviewriter](https://docs.godotengine.org/en/latest/classes/class_moviewriter.html)、`--fixed-fps` 确定性帧） | ❌ | 高 | `record_movie` — 确定性帧录制（.avi/PNG 序列）+ 抽帧对比，强化视觉回归与回放调试 |
| `--benchmark`、引擎 `--test`（需自编译） | ❌ | 低 | — |
| `--convert-3to4` / `--validate-conversion-3to4` | 🟡（4.x 迁移扫描已有） | 低 | — |

### 1.8 运行时引擎能力

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| 运行/停止/截图/选择 | ✅ | — | — |
| **SceneTree 生命周期控制**（[paused](https://docs.godotengine.org/en/latest/classes/class_scenetree.html)、current_scene 切换、quit） | ❌ | 中高 | `control_runtime` — pause/resume/quit/切场景（并入 runtime_control） |
| **Engine 时间控制**（[Engine.time_scale/max_fps/physics_ticks_per_second/max_physics_steps_per_frame](https://docs.godotengine.org/en/latest/classes/class_engine.html)） | ❌ | 中高 | `set_time_scale` — 慢放/快进/固定物理步长（4.6 编辑器已加时间缩放控件，MCP 应跟上） |
| 确定性帧步进 | ✅ play_and_verify（frame-stepped） | — | — |
| **WorkerThreadPool / 通用线程池**（[add_task/add_group_task](https://docs.godotengine.org/en/latest/classes/class_workerthreadpool.html)） | 🟡 测试后台线程 | 高 | 见 §4.3 `async_job` 统一框架 |
| **多人/RPC**（[ENetMultiplayerPeer](https://docs.godotengine.org/en/latest/classes/class_enetmultiplayerpeer.html)、[MultiplayerAPI](https://docs.godotengine.org/en/latest/classes/class_multiplayerapi.html)、MultiplayerSynchronizer/Spawner、`@rpc`、服务器权威、SceneTree.multiplayer_poll） | ❌ | 中高 | `multiplayer_harness` — 起 ENet 会话、鉴权测试、调用 rpc、断言同步状态（AI 测试联机玩法） |
| 输入注入 | ✅ | — | — |

### 1.9 性能与调试

| 引擎能力 | 插件现状 | 价值 | 建议 MCP 工具形态 |
|---|---|---|---|
| Performance 快照/预算门禁 | ✅ get_runtime_performance_snapshot/assert_performance_budget | — | — |
| **自定义监控项**（[Performance.add_custom_monitor](https://docs.godotengine.org/en/latest/classes/class_performance.html)，4.6 增加 type 参数） | ❌ | 中 | `register_performance_monitor` — 注册自定义指标并接入预算门禁 |
| Profiler 帧数据（EngineDebugger.profiler_enable/profiler_add_frame_data、4.6 Tracy/Perfetto/Instruments 外部 profiler） | 🟡 toggle + 快照 | 中 | `profile_frame` — 采集单帧/区间脚本+渲染剖析数据返回 JSON |
| **ObjectDB 快照与泄漏检测**（[4.6 debugger ObjectDB snapshots and diffing](https://godotengine.org/releases/4.6/)：捕获全量存活对象、两次快照 diff 出 created/destroyed/left-behind） | ❌（仅 memory_trend 曲线） | 高 | `memory_snapshot_diff` — 运行时两时刻对象快照对比，AI 定位泄漏/对象爆炸 |
| EditorDebuggerRemoteSceneTree（远程场景树/远程检查器，4.7 支持折叠组、非导出枚举显示） | 🟡 自研 probe 替代 | 中 | 保持自研（更结构化），可选补充远程检查器属性写入 |
| GDShader 校验 | ✅ validate_shader | — | — |
| 调试器步进（4.6 新增 Step Out） | 🟡 断点/栈帧/变量有；步进命令未确认 | 中 | `debugger_step` — step over/into/out/continue 显式工具 |

### 1.10 Godot 4.4–4.7 新 API 值得暴露清单

| 版本 | 新能力 | 插件现状 | 价值 | 建议 |
|---|---|---|---|---|
| 4.4 | LightmapGI **shadowmask**（静态远距+动态近距阴影） | ❌ | 高 | 并入 bake_lightmap 参数 |
| 4.4 | **表达求值器 REPL**（断点处本地状态求值） | ✅ evaluate_debug_expression | — | — |
| 4.4 | Animation markers、LookAtModifier3D、SpringBoneSimulator3D | ❌ | 中 | 并入动画工具组 |
| 4.4 | glTF 自定义属性动画（属性↔JSON 指针映射，GDScript 定义） | ❌ | 中 | `configure_gltf_custom_anim` |
| 4.4 | 通用 UID（全资源类型 + 升级工具） | ✅ uid 工具 | — | — |
| 4.5 | **custom loggers**（拦截日志/错误，4.5 发布页） | ❌ | 中 | `install_custom_logger` — 注入日志钩子供 AI 收集运行时输出 |
| 4.5 | 专用 2D 导航服务器（独立于 3D）、async 导航区域 | ❌ | 中高 | 并入 navigation_bake |
| 4.5 | shader baker（导出期预编译管线）、stencil buffer | ❌ | 低中 | 并入 export 设置工具 |
| 4.5 | 批量导入编辑（Import dock） | ❌ | 中 | 并入 set_import_options |
| 4.6 | **ObjectDB 快照 diff**（泄漏检测） | ❌ | 高 | memory_snapshot_diff |
| 4.6 | **全新 IK 框架**（IKModifier3D + 5 求解器 + 约束） | ❌ | 中 | configure_procedural_animation |
| 4.6 | **唯一 Node ID**（tscn 保存，重命名/重构安全） | ✅（依赖引擎） | — | 提示：批量改节点名后建议 re-save 场景 |
| 4.6 | Jolt 默认（新 3D 项目）、D3D12 默认（Windows） | 🟡 set_project_setting | 低 | — |
| 4.6 | EditorSettings.add_shortcut 自定义快捷键 | ❌ | 低 | manage_editor_shortcuts |
| 4.6 | delta Patch PCK（增量补丁） | ❌ | 低中 | 并入 export/PCK 工具 |
| 4.6 | GDExtension JSON 接口、required 参数 | ❌ | 低 | — |
| 4.7 | **AreaLight3D**（矩形面光源） | ❌ | 低中 | 节点创建即覆盖（建议加进 3D 场景向导） |
| 4.7 | **DrawableTexture2D**（GPU 可绘制纹理） | ✅ create_drawable_texture/draw_on_texture | — | — |
| 4.7 | **HDR 输出**（Windows/macOS/iOS/visionOS/Linux Wayland） | 🟡 configure_render_output（hdr_2d） | 低中 | 补 display HDR 项目设置项 |
| 4.7 | **MeshLibrary 专用编辑器** | ❌ | 中 | manage_mesh_library |
| 4.7 | Control offset_transform、VirtualJoystick、Tween.tween_await | ❌ | 低 | 节点创建/运行时工具顺带覆盖 |
| 4.7 | 导出模板单平台下载器 | 🟡 manage_export_templates | 低中 | 补按平台下载 |
| 4.7 | ScriptEditor.save_all_scripts / reload_open_files / EditorFileSystem.is_importing / EditorInterface.get_unsaved_scenes | ✅ 已用 | — | — |
| 4.7 | 键盘/鼠标设备 ID（InputEvent.DEVICE_ID_*） | 🟡 输入注入 | 低 | — |
| 4.7 | GDExtensions 显示于 Project Settings | ✅ detect_gdextension_addons | — | — |

---

## 2. Top 20 最值得新增/增强的工具（按价值排序）

| # | 工具名（建议） | 一句话描述 | 依托引擎 API | 关联专题 |
|---|---|---|---|---|
| 1 | `bake_lightmap` / `bake_voxel_gi` | 配置并**异步**烘焙 LightmapGI（quality/bounces/texel_scale/shadowmask）或 VoxelGI，返回进度+产物+烘焙后截图门禁 | [LightmapGI](https://docs.godotengine.org/en/latest/classes/class_lightmapgi.html)、[VoxelGI.bake()](https://docs.godotengine.org/en/latest/classes/class_voxelgi.html) | 长任务/3D 烘焙 |
| 2 | `bake_navigation_mesh` | 2D/3D NavMesh 烘焙：NavigationRegion3D.bake_navigation_mesh 或 NavigationServer3D parse→bake_from_source_geometry_data_async，支持复用 source geometry 与 chunk 边界 | [NavigationRegion3D](https://docs.godotengine.org/en/latest/classes/class_navigationregion3d.html)、[NavigationServer3D](https://docs.godotengine.org/en/latest/classes/class_navigationserver3d.html)、[NavigationMesh](https://docs.godotengine.org/en/latest/classes/class_navigationmesh.html) | 长任务 |
| 3 | `undo` / `redo` / `get_undo_redo_state` | 显式撤销/重做工具 + 历史栈查询（undoable 步数、当前 action 名），并订阅 `version_changed` 通知 AI | [EditorUndoRedoManager](https://docs.godotengine.org/en/latest/classes/class_editorundoredomanager.html) | 撤销/重做 |
| 4 | `async_job`（start/poll/cancel/progress） | **统一异步作业框架**：把现有 pending/poll 模式（run_project_test、generate_3d_asset）抽成通用 start_job/poll_job/cancel_job，烘焙/导出/录制/导入全部接入 | [WorkerThreadPool](https://docs.godotengine.org/en/latest/classes/class_workerthreadpool.html)、现有轮询模式 | 长任务异步化 |
| 5 | `memory_snapshot_diff` | 运行时两次 ObjectDB 快照对比，报告 created/destroyed/left-behind，AI 定位泄漏与对象爆炸 | 4.6 debugger ObjectDB snapshots（[release 4.6](https://godotengine.org/releases/4.6/)） | 性能/调试 |
| 6 | `resource_preview` | 用 EditorResourcePreview（异步回调）或 EditorInterface.make_mesh_previews 为资源/网格生成缩略图，AI 自检生成资产 | [EditorResourcePreview](https://docs.godotengine.org/en/latest/classes/class_editorresourcepreview.html)、[EditorInterface.make_mesh_previews](https://docs.godotengine.org/en/latest/classes/class_editorinterface.html) | 反馈循环 |
| 7 | `editor_navigate` | edit_node / edit_script(path,line,col) / edit_resource / inspect_object / set_main_screen_editor，把编辑器"指到" AI 改动处 | [EditorInterface](https://docs.godotengine.org/en/latest/classes/class_editorinterface.html) | 人机协同 |
| 8 | `set_import_options` | 按文件/扩展名/批量设置 .import 导入选项（纹理压缩/Betsy/音频/glTF）并 reimport | [importing_images](https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/importing_images.html)、[EditorFileSystem.reimport_files](https://docs.godotengine.org/en/latest/classes/class_editorfilesystem.html) | 资源管线 |
| 9 | `author_animation_tree` | 编辑 AnimationTree 状态机/混合空间/转换（add_node/add_transition/add_blend_point）并保存，运行时 travel 联动预览 | [AnimationNodeStateMachine](https://docs.godotengine.org/en/latest/classes/class_animationnodestatemachine.html)、[AnimationNodeBlendSpace2D](https://docs.godotengine.org/en/latest/classes/class_animationnodeblendspace2d.html) | 动画 |
| 10 | `physics_query` | 对 PhysicsDirectSpaceState3D/2D 做 ray/shape/point 查询，返回命中对象与交点，AI 验证玩法假设 | [PhysicsDirectSpaceState3D](https://docs.godotengine.org/en/latest/classes/class_physicsdirectspacestate3d.html) | 3D 工作流 |
| 11 | `setup_physics_body` | 创建/配置物理体与碰撞形状（含 4.6 mesh→shape 生成）、layer/mask、物理材质、关节 | [PhysicsBody3D](https://docs.godotengine.org/en/latest/classes/class_physicsbody3d.html)、[CollisionShape3D](https://docs.godotengine.org/en/latest/classes/class_collisionshape3d.html) | 3D 工作流 |
| 12 | `control_runtime` | 运行时 pause/resume/quit、Engine.time_scale/max_fps/physics_ticks 控制（慢放/快进/固定物理步长） | [SceneTree.paused](https://docs.godotengine.org/en/latest/classes/class_scenetree.html)、[Engine](https://docs.godotengine.org/en/latest/classes/class_engine.html) | 运行时 |
| 13 | `record_movie` | MovieWriter/--write-movie 确定性帧录制（--fixed-fps）+ 抽帧截图，回放调试与视频级视觉回归 | [MovieWriter](https://docs.godotengine.org/en/latest/classes/class_moviewriter.html)、[command_line_tutorial](https://docs.godotengine.org/en/latest/tutorials/editor/command_line_tutorial.html) | 反馈循环/CI |
| 14 | `get_script_diagnostics` | 通过 GDScript LSP（--lsp-port / GDScriptLanguageProtocol）拉取结构化诊断（错误/警告/补全建议），替代文本级验证 | [GDScriptLanguageProtocol](https://docs.godotengine.org/en/latest/classes/class_gdscriptlanguageprotocol.html) | 语言服务/反馈循环 |
| 15 | `retarget_animation` | BoneMap 生成与自动映射、glTF 导入 retarget 选项、运行时 RetargetModifier3D 挂载 | [BoneMap](https://docs.godotengine.org/en/latest/classes/class_bonemap.html)、[SkeletonProfileHumanoid](https://docs.godotengine.org/en/latest/classes/class_skeletonprofilehumanoid.html)、[RetargetModifier3D](https://docs.godotengine.org/en/latest/classes/class_retargetmodifier3d.html) | 动画 |
| 16 | `create_import_plugin` | 生成 EditorImportPlugin / EditorScenePostImportPlugin 脚本骨架 + EditorPlugin.add_import_plugin 注册 + 验证导入 | [EditorImportPlugin](https://docs.godotengine.org/en/latest/classes/class_editorimportplugin.html)、[EditorScenePostImportPlugin](https://docs.godotengine.org/en/latest/classes/class_editorscenepostimportplugin.html)、[EditorPlugin](https://docs.godotengine.org/en/latest/classes/class_editorplugin.html) | 资源管线 |
| 17 | `edit_gridmap` | GridMap 单元格批量 set/erase + make_baked_meshes 烘焙合并 + MeshLibrary 管理 | [GridMap](https://docs.godotengine.org/en/latest/classes/class_gridmap.html)、[MeshLibrary](https://docs.godotengine.org/en/latest/classes/class_meshlibrary.html) | 3D 工作流 |
| 18 | `edit_multimesh` | MultiMeshInstance3D 实例变换/颜色/自定义数据批量写入 | [MultiMesh](https://docs.godotengine.org/en/latest/classes/class_multimesh.html) | 3D 工作流 |
| 19 | `register_performance_monitor` | Performance.add_custom_monitor（4.6 type 参数）注册自定义指标，接入 assert_performance_budget | [Performance](https://docs.godotengine.org/en/latest/classes/class_performance.html) | 性能门禁 |
| 20 | `multiplayer_harness` | ENetMultiplayerPeer/MultiplayerAPI 会话启动、@rpc 调用、MultiplayerSynchronizer 状态断言，AI 测试联机/服务器权威玩法 | [ENetMultiplayerPeer](https://docs.godotengine.org/en/latest/classes/class_enetmultiplayerpeer.html)、[MultiplayerAPI](https://docs.godotengine.org/en/latest/classes/class_multiplayerapi.html)、[high_level_multiplayer](https://docs.godotengine.org/en/latest/tutorials/networking/high_level_multiplayer.html) | 运行时 |

**荣誉提名（价值中，按需补充）**：`editor_vcs`（git 集成）、`generate_script_docs`（--gdscript-docs）、`install_custom_logger`（4.5 custom loggers）、`profile_frame`（Profiler 帧数据）、`notify_editor`（EditorToaster/命令面板）、`debugger_step`（step out 等显式步进）、`edit_skeleton`（骨骼 pose/rest）、`configure_procedural_animation`（IK 框架）。

---

## 3. 特别关注专题

### 3.1 撤销 / 重做集成（现状 → 差距 → 建议）

**现状（已做对的部分）**：插件在 6 处内部使用 `EditorUndoRedoManager`（节点创建/删除/重命名/移动、属性更新、批量操作、场景实例化、TileMapLayer 单元格、子资源设置），说明"编辑器感知写入"的骨架已在。

**差距**：
1. **无显式 undo/redo 工具**：AI 无法主动 `undo` 上一次工具调用；`execute_editor_script` 的任意修改、脚本/资源**文件直写**（write_script、create_resource）完全绕过撤销栈。
2. **无合并（merge）**：AI 连续微调同一属性 N 次会生成 N 条撤销记录（`create_action` 默认 merge_mode=0 不合并；可用 `UndoRedo.MERGE_ENDS`/`MERGE_ALL`）。
3. **无状态回读与通知**：未暴露 `get_history_undo_redo().has_undo()/get_undo_name()`、`get_object_history_id`、`is_committing_action`；`version_changed`/`history_changed` 信号未桥接给 AI（MCP 通知）。
4. **文件级写入的撤销**：场景 .tscn 直写可由 `EditorUndoRedoManager` + `EditorInterface.mark_scene_as_unsaved` + `reload_scene_from_path` 组合兜底，但脚本文件只能靠外部版本控制。

**建议**：
- 工具：`undo`（带 history_id 参数）、`redo`、`get_undo_redo_state`（每条历史的 undoable/redoable 数、下一条 action 名）、`transaction`（把一个 MCP 工具调用序列包成一个可整体撤销的 action，支持 custom_context）。
- 策略：所有"编辑器内对象变更"类工具（含 execute_editor_script 的推荐路径）统一走 `EditorUndoRedoManager`，并为脚本/资源写入提供 `undo_snapshot`（改前复制文件到 res://.mcp/undo/ 并在 undo 工具中恢复）+ 文档提示"文件写入优先走版本控制"。
- 通知：订阅 `version_changed`，作为 MCP notification 推给 AI（撤销后自动重读场景）。

### 3.2 错误反馈循环（AI 修改后如何验证）

**现状（强项）**：`play_and_verify`（确定性帧步进+运行时断言+错误捕获）、`assert_no_runtime_errors`、`assert_visual_baseline`（黄金文件）、`assert_performance_budget`、`smoke_test_export`、`validate_shader`、脚本 analyze/verify —— 反馈闭环已相当完整，是插件的差异化优势。

**差距**：
1. **编辑期脚本诊断不结构化**：脚本写入后没有主动触发 `EditorFileSystem.update_file`+`reload_open_scripts`+`Script.reload()` 拿结构化编译错误（file/line/column/warning）；`get_import_status` 只报"是否在扫描"。
2. **缺少"编译-加载-实例化"三级断言**：`assert_script_compiles`（reload 返回 Error）、`assert_scene_loads`（PackedScene.instantiate 冒烟）、`assert_resource_loads`（load + 类型断言）没有作为独立工具；目前依赖运行时 play_and_verify 兜底，编辑期错误反馈偏慢。
3. **LSP 未接入**：官方 LSP（`--lsp-port`）能给出比 `Script.reload()` 更丰富的诊断（未使用变量、类型不匹配、弃用 API），且与 4.6 的 BBCode→Markdown 文档提示、4.4 的 GDScript tooltips 同源 —— 插件已有 `scan_migration_compatibility`/`find_deprecated_api_usage` 可与之互补。
4. **烘焙/导入类错误**（LightmapGI "no meshes with GI_MODE_STATIC"、UV2 缺失）没有预检工具。

**建议**：
- 新增 `assert_script_compiles`（结构化编译错误）、`assert_scene_loads`（含 gi_mode/UV2/导航网格预检）、`get_script_diagnostics`（LSP 级）；把"编辑→reload_open_scripts→update_file→断言"做成 `edit_and_verify` 编排工具，复用既有 play_and_verify 的"plan→execute→run→verify→fix"任务图（manage_task_plan 已有 gate 概念：no_runtime_errors/performance_budget/visual_baseline，可新增 `script_compiles`/`scene_loads` gate 类型）。

### 3.3 长任务异步化（导出 / 烘焙 / 导入 / 录制）

**现状**：`run_project_test` 与 `generate_3d_asset` 已实现 "首次调用返回 pending → 再次调用轮询结果" 模式（后台线程/外部 HTTP 轮询），`assert_performance_budget` 支持传入已缓存 snapshot。但该模式是**每工具手写**的，且没有 cancel/progress/超时。

**建议**：新增统一 `async_job` 工具族（`start_job(kind, params)` / `poll_job(job_id)` / `cancel_job(job_id)` / `list_jobs`），内部用 `WorkerThreadPool.add_group_task` + 信号回调，把以下重活全部接入并返回 `{status, progress, result_path, validation}`：
- `bake_lightmap` / `bake_voxel_gi` / `bake_navigation_mesh`（GI 与导航烘焙都是秒~分钟级，必须异步 + 可取消）
- `run_export`（CLI 子进程化 + 退出码断言，已有 smoke_test_export 接续）
- `pack_pck`、`reimport_resources`（大项目扫描）、`record_movie`、`generate_asset`（外部 API）
- 每个作业完成后**自动接续既有门禁**（截图→visual baseline、产物存在→smoke test），形成"任务→门禁"的管线化返回值。

### 3.4 3D 烘焙类耗时操作（GI / 导航 / GridMap）

- **LightmapGI**：参数面广（quality/bounces/texel_scale/supersampling/denoiser/shadowmask_mode/generate_probes_subdiv），烘焙前必须预检：mesh 的 `gi_mode == GI_MODE_STATIC` 且存在合法 UV2（无 UV2 是官方文档明确列出的失败原因）、Forward+/Mobile 渲染器限制（[using_lightmap_gi](https://docs.godotengine.org/en/latest/tutorials/3d/global_illumination/using_lightmap_gi.html)）。**⚠️ 版本注意**：4.7 master 文档中 LightmapGI 的 Methods 段为空（4.3–4.6 有 `bake()`），疑似 4.7 周期移除/迁移了脚本化烘焙入口 —— 实现时必须按目标引擎版本实测，必要时回退为"编辑期驱动 bake 按钮"或手工装配 `LightmapGIData`（`add_user`），并把该差异写进工具描述。
- **VoxelGI**：`bake()`/`debug_bake()` 存在且支持运行时烘焙（适合 AI 程序化关卡），价值高于 LightmapGI 的实现确定性。
- **NavMesh**：`NavigationRegion3D.bake_navigation_mesh(on_thread)` 最简；`NavigationServer3D.parse_source_geometry_data`（主线程）→ `bake_from_source_geometry_data_async`（后台线程）支持 source geometry 复用（多 agent 尺寸烘多次）、chunk 烘焙（filter_baking_aabb + border 对齐边缘）；2D 走 NavigationServer2D（4.5 起独立服务器）。烘焙参数（cell_size/agent_radius 等）需防"过小 cell 冻结崩溃"（官方文档有警告）。
- **GridMap.make_baked_meshes**：把格子烘焙成合并网格，AI 铺完场景后一键产出低 DrawCall 版本。
- 所有烘焙工具统一输出：进度、耗时、产物路径、错误清单，并自动接 `assert_visual_baseline`（烘焙后截图做黄金文件，防"改了光照参数导致烘焙结果漂移"）。

---

## 4. 方法学与局限

- 本地资料 = godot-docs **master**（对应 4.7 发布后、4.8 开发前），与官方 4.7 存在少量漂移风险（例：LightmapGI.bake() 在 master 已消失，见 §3.4）；已用官方 release 4.4–4.7 页面与迁移指南交叉校正。
- 插件覆盖判定基于 `docs/tools/*.md` 工具清单与 `mcp_runtime_probe.gd`/`mcp_debugger_bridge.gd` 源码抽查，未逐一执行 215 个工具。
- 工具建议中的类 API 均出自本地 classes 物化文件的方法/属性表，URL 指向 docs.godotengine.org 对应页（latest）。

---

## 5. 参考来源

**官方文档站（docs.godotengine.org）**
- 命令行动手教程（--lsp-port/--dap-port/--check-only/--gdscript-docs/--doctool/--import/--export-patch/--write-movie/--test）：https://docs.godotengine.org/en/latest/tutorials/editor/command_line_tutorial.html
- 在编辑器中运行代码（EditorScript/EditorPlugin）：https://docs.godotengine.org/en/latest/tutorials/plugins/running_code_in_the_editor.html
- LightmapGI 使用教程（UV2 预检/渲染器限制/烘焙失败原因）：https://docs.godotengine.org/en/latest/tutorials/3d/global_illumination/using_lightmap_gi.html
- 导航网格使用（region 烘焙 + NavigationServer 管线 + chunk）：https://docs.godotengine.org/en/latest/tutorials/navigation/navigation_using_navigationmeshes.html
- 骨骼重定向教程（BoneMap/SkeletonProfile/导入选项）：https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/retargeting_3d_skeletons.html
- 图像导入/纹理压缩：https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/importing_images.html
- 音频导入：https://docs.godotengine.org/en/latest/tutorials/assets_pipeline/importing_audio_samples.html
- 高层多人（RPC/权威）：https://docs.godotengine.org/en/latest/tutorials/networking/high_level_multiplayer.html
- 类参考：EditorInterface https://docs.godotengine.org/en/latest/classes/class_editorinterface.html ｜ EditorUndoRedoManager https://docs.godotengine.org/en/latest/classes/class_editorundoredomanager.html ｜ EditorFileSystem https://docs.godotengine.org/en/latest/classes/class_editorfilesystem.html ｜ EditorSettings https://docs.godotengine.org/en/latest/classes/class_editorsettings.html ｜ EditorResourcePreview https://docs.godotengine.org/en/latest/classes/class_editorresourcepreview.html ｜ EditorPlugin https://docs.godotengine.org/en/latest/classes/class_editorplugin.html ｜ EditorImportPlugin https://docs.godotengine.org/en/latest/classes/class_editorimportplugin.html ｜ EditorScenePostImportPlugin https://docs.godotengine.org/en/latest/classes/class_editorscenepostimportplugin.html ｜ EditorVCSInterface https://docs.godotengine.org/en/latest/classes/class_editorvcsinterface.html ｜ GDScriptLanguageProtocol https://docs.godotengine.org/en/latest/classes/class_gdscriptlanguageprotocol.html ｜ EngineDebugger https://docs.godotengine.org/en/latest/classes/class_enginedebugger.html ｜ EditorDebuggerPlugin https://docs.godotengine.org/en/latest/classes/class_editordebuggerplugin.html ｜ LightmapGI https://docs.godotengine.org/en/latest/classes/class_lightmapgi.html ｜ VoxelGI https://docs.godotengine.org/en/latest/classes/class_voxelgi.html ｜ NavigationServer3D https://docs.godotengine.org/en/latest/classes/class_navigationserver3d.html ｜ NavigationRegion3D https://docs.godotengine.org/en/latest/classes/class_navigationregion3d.html ｜ GridMap https://docs.godotengine.org/en/latest/classes/class_gridmap.html ｜ MultiMesh https://docs.godotengine.org/en/latest/classes/class_multimesh.html ｜ AnimationNodeStateMachine https://docs.godotengine.org/en/latest/classes/class_animationnodestatemachine.html ｜ RetargetModifier3D https://docs.godotengine.org/en/latest/classes/class_retargetmodifier3d.html ｜ IKModifier3D https://docs.godotengine.org/en/latest/classes/class_ikmodifier3d.html ｜ PhysicsDirectSpaceState3D https://docs.godotengine.org/en/latest/classes/class_physicsdirectspacestate3d.html ｜ SceneTree https://docs.godotengine.org/en/latest/classes/class_scenetree.html ｜ Engine https://docs.godotengine.org/en/latest/classes/class_engine.html ｜ WorkerThreadPool https://docs.godotengine.org/en/latest/classes/class_workerthreadpool.html ｜ MultiplayerAPI https://docs.godotengine.org/en/latest/classes/class_multiplayerapi.html ｜ ENetMultiplayerPeer https://docs.godotengine.org/en/latest/classes/class_enetmultiplayerpeer.html ｜ Performance https://docs.godotengine.org/en/latest/classes/class_performance.html ｜ Input https://docs.godotengine.org/en/latest/classes/class_input.html ｜ MovieWriter https://docs.godotengine.org/en/latest/classes/class_moviewriter.html ｜ Theme https://docs.godotengine.org/en/latest/classes/class_theme.html ｜ Skeleton3D https://docs.godotengine.org/en/latest/classes/class_skeleton3d.html ｜ BoneMap https://docs.godotengine.org/en/latest/classes/class_bonemap.html ｜ SkeletonProfileHumanoid https://docs.godotengine.org/en/latest/classes/class_skeletonprofilehumanoid.html ｜ AnimationMixer https://docs.godotengine.org/en/latest/classes/class_animationmixer.html ｜ Tween https://docs.godotengine.org/en/latest/classes/class_tween.html

**官方发布页（godotengine.org）**
- Godot 4.7 "Lights, Camera, Action!"：https://godotengine.org/releases/4.7/
- Godot 4.6 "All about your flow"：https://godotengine.org/releases/4.6/
- Godot 4.5 "Making dreams accessible"：https://godotengine.org/releases/4.5/
- Godot 4.4 "A unified experience"：https://godotengine.org/releases/4.4/

**迁移指南（godot-docs / tutorials/migrating）**
- 4.4→4.7：https://docs.godotengine.org/en/latest/tutorials/migrating/upgrading_to_godot_4.7.html ｜ 4.6：https://docs.godotengine.org/en/latest/tutorials/migrating/upgrading_to_godot_4.6.html ｜ 4.5：https://docs.godotengine.org/en/latest/tutorials/migrating/upgrading_to_godot_4.5.html ｜ 4.4：https://docs.godotengine.org/en/latest/tutorials/migrating/upgrading_to_godot_4.4.html
- 关键 PR（迁移指南引用）：Jolt 默认 3D 物理 https://github.com/godotengine/godot/pull/105737 ｜ 唯一 Node ID https://github.com/godotengine/godot/pull/106837 ｜ Performance.add_custom_monitor type 参数 https://github.com/godotengine/godot/pull/110433 ｜ ScriptEditor StringName 变更 https://github.com/godotengine/godot/pull/110767 ｜ Tween/Animation 4.7 细节 https://github.com/godotengine/godot/pull/110369 等（详见迁移指南内 GH-* 链接）

**godot-docs 仓库**
- 仓库主页：https://github.com/godotengine/godot-docs
- tutorials 目录结构：https://github.com/godotengine/godot-docs/tree/master/tutorials
- classes 目录结构：https://github.com/godotengine/godot-docs/tree/master/classes
- 本地物化路径：`D:\ai\godot-docs`（浅克隆 + sparse checkout tutorials/classes，供本报告核验）

**项目内部依据**
- `docs/tools/*.md`（editor/scene/node/script/project/debug/meta 工具清单与覆盖判定）
- `addons/godot_mcp/runtime/mcp_runtime_probe.gd`、`addons/godot_mcp/native_mcp/mcp_debugger_bridge.gd`（EngineDebugger 使用面核对）
- 本报告：`docs/research/godot-engine-mcp-capability-gap-report.md`
