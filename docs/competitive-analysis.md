# Godot MCP 竞品分析与"编辑器型 MCP 服务器"最佳形态研究报告

> 用于指导 **Godot-MCP-Native**（纯 GDScript、Godot 4.7 编辑器内原生 MCP 服务器，215 工具）的优化。
> 数据采集日期：2026-08（GitHub API 实时抓取 star / push / issue）。
> 本项目公开仓库：github.com/yurineko73/Godot-MCP-Native（716⭐，66 forks，MIT，最后推送 2026-08-03）。

---

## 目录

1. [竞品对比总表](#1-竞品对比总表)
2. [逐实现要点](#2-逐实现要点)
3. [用户痛点与期望清单（issue 实证）](#3-用户痛点与期望清单issue-实证)
4. ["理想编辑器 MCP 服务器"能力清单与本项目差距](#4-理想编辑器-mcp-服务器能力清单与本项目差距)
5. [Top 15 差异化优化建议](#5-top-15-差异化优化建议)
6. [参考 URL 全集](#6-参考-url-全集)

---

## 1. 竞品对比总表

| 实现 | 架构 | 工具数 | 传输 | 资源/提示支持 | 安全 | 活跃度（⭐ / 最后推送） |
|---|---|---|---|---|---|---|
| **Coding-Solo/godot-mcp**（最流行 Godot MCP） | Node/TS bridge：`npx @coding-solo/godot-mcp` 启动 Godot CLI + 内置 `godot_operations.gd` JSON 驱动脚本 | **~14**（launch_editor / run_project / get_debug_output / stop_project / create_scene / add_node / load_sprite / save_scene / get_uid 等） | stdio | 无 resources / 无 prompts | ⚠️ 曾报 RCE（#64 未消毒 projectPath）、autoload 注入（#112）；无 auth | **5301⭐ / 460F**，2026-04 仍在推 |
| **yurineko73/Godot-MCP-Native（本项目）** | 纯 GDScript `EditorPlugin` 原生实现，无任何外部依赖 | **215**（28 核心 + 185 补充 + 2 meta，6 大类 + meta） | HTTP/SSE `:9080` + stdio | resources ✓；prompts **capability 已声明但 0 个已注册**；`instructions` ✓（渐进披露引导，业界罕见） | Bearer Token（HTTP）；path_validator 路径校验；原生插件不引入额外攻击面 | **716⭐ / 66F**，16 open issues，2026-08 活跃 |
| **IvanMurzak/Godot-MCP** | C# 编辑器 addon（NuGet 反射栈与 Unity-MCP 共享）+ 云端 ai-game.dev 或自托管 MCP server | **42**（12 families） | stdio / 云端 HTTP（OAuth 2.1 设备登录） | 无独立 prompts；有"自然对话" | 云端账号体系；自托管可选 | 220⭐，2026-08 活跃 |
| **smalldy/MCP4Godot** | GDScript 原生 EditorPlugin（与本项目同构，最接近的"同路线"竞品） | **38**（6 类：Node 8 / Property 5 / Editor 12 / File 8 / Script 2 / Settings 3） | **Streamable HTTP** `:9876/mcp`（单端点 POST） | 无 | README 未提及认证（本地监听风险） | 0⭐（2026-06 新建），更新中 |
| **yanhuifair/Godot-MCP** | TypeScript | 未披露 | stdio | 无 | — | 16⭐，AGPL-3.0，2026-08 |
| **alexmeckes/godot-mcp** | TypeScript | 未披露 | stdio | 无 | — | 30⭐，MIT，2026-08 |
| **Rizzpect/Godot-MCP** | TypeScript | 未披露 | stdio | 无 | — | 1⭐，2026-02 新建 |
| **spardanviro/Godot_AI** | **C++ 原生模块**（编译进引擎，非 addon）；编辑器内 AI 面板，非 MCP | —（不是 MCP） | 编辑器内直连 LLM | 按需注入 API 文档 + **401 条 gotchas 索引**（省 ~90% 上下文）、领域提示词、ASK/AGENT/PLAN 三模式 | 权限/检查点系统 | 54⭐，2026-04 |
| **CoplayDev/unity-mcp**（原 justinpbarnett/unity-mcp） | Unity C# 包（UPM）+ Python(`uv`) bridge；多实例路由 | **47** tool entrypoints（分 vfx/animation/ui/testing 等工具组） | stdio / 远程 HTTP + auth | 工具组渐进披露；Roslyn 脚本校验（编译级验证） | 远程服务器认证；SECURITY.md | **13572⭐ / 1442F**，v10.0.0（2026-06） |
| **aadeshrao123/Unreal-MCP** | UE C++ 插件 + Python MCP server（stdio）+ `unrealcli`（TCP） | **288** commands / 15 类（社区版）；Pro 900+ / 28 类 | stdio（MCP）/ TCP（CLI） | 无 | — | 37⭐，MPL-2.0，2026-08 |
| **jeebus87/ultimateunrealenginemcp** | TS server + 可选 C++ 插件；运行时反射，模块缺失优雅降级 | **133** / 26 域 | stdio | 无 | — | 3⭐（概念前沿：**Visual Review Loop** + **自动自校验** + 1021 测试 + headless/live 双模式） |
| **ahujasid/blender-mcp** | Python（`uvx blender-mcp`）+ Blender addon | ~40+ 建模/场景命令 | stdio | 无 | — | **26150⭐ / 2483F**，2026-08 |
| **github/github-mcp-server**（官方参考实现） | Go 单体 | 100+ | stdio / Streamable HTTP / SSE | resources + prompts 全支持 | GitHub 身份 + 权限作用域 | **32422⭐**，327 open issues，2026-08 |

**结论速览**：竞品格局 = "**桥梁派**"（Node/Python/C++ 外部进程 + 引擎内插件，靠 `run_project` + 抓 stdout 反馈，工具少、无原生资源/提示）vs "**原生派**"（MCP4Godot、本项目 —— 零依赖、编辑器内直连、工具多）。本项目在"工具数量、验证闭环（play_and_verify / assert_* / smoke_test_export / 视觉回归）、instructions、认证"上遥遥领先；但 **prompts 空壳、Streamable HTTP 缺失、Codex 兼容性问题、AssetLib 缺席、编译错误反馈盲区** 是实打实的短板（见 §3、§4）。

---

## 2. 逐实现要点

### 2.1 Godot 生态

**Coding-Solo/godot-mcp（5301⭐，事实标准）**
- 全部能力只有两招：① 直接调 Godot CLI（launch_editor / run_project / stop_project / get_debug_output）；② 一个打包的 `godot_operations.gd`，按 JSON 参数执行 create_scene / add_node / load_sprite / save_scene / get_uid 等。
- 架构上它**不是"编辑器内服务器"**——是"进程启动器 + stdout 抓取器"。反馈闭环依赖解析 Godot 命令行输出；这正是其 issue 里"连接不稳定 / 假成功"的根源。
- README 提供 Claude Code / Cline / Cursor 三种客户端的一键配置片段，还有 Cline `autoApprove` 白名单——**客户端 onboarding 体验是它的强项**。

**IvanMurzak/Godot-MCP（220⭐，C#）**
- 与 Unity-MCP 共享同一套反射/桥接栈（NuGet），主打"AI Game Developer"：C# + GDScript 双语言读写、场景/资源操作、**视口/相机/孤立节点截图**（视觉反馈）、ReflectorNet **反射逃生舱**（任意 C# 方法）、`godot-cli` 一键装插件 + OAuth 登录 + 按项目生成各客户端 MCP 配置。
- 商业化云端（ai-game.dev）+ 可自托管；Docker 镜像。设计取向：**"编辑器可被 AI 完全驱动 + 视觉验证"**，与本项目意图最接近，但依赖 C#/.NET 与云端。

**smalldy/MCP4Godot（0⭐，同路线新秀）**
- 与本项目同构的 GDScript 原生插件，38 工具 6 类，**显式采用 2025 标准的 Streamable HTTP**（`http://localhost:9876/mcp` 单端点），并明确在 README 里对比："不是老的 WebSocket 方案"。这是对我们的直接提醒：**传输层规范迭代要跟上**。
- 中文/英文双语文档；无认证（本地监听，安全上弱于我们的 Bearer）。

**spardanviro/Godot_AI（54⭐，C++ 模块）**
- 不是 MCP，但对"编辑器 AI 集成"的上下文工程最有启发性：**按需注入**（AIAPIDocLoader 检测提及的类名只注入相关 API 文档；gotchas 索引把 3100 行静态规则压缩成 401 条关键词命中、每次请求省 ~90% 上下文）；@ 提及场景节点；Fix Errors / Performance 快捷动作。它的核心思想 = **"别把所有知识塞进 prompt，按任务检索"**——与我们的 `list_tool_catalog` + `enable_tools` 渐进披露同源。

### 2.2 其他引擎/编辑器 MCP

**Unity MCP（CoplayDev，13572⭐）**
- 47 个"高内聚入口点"（刻意少而精），UPM 一键安装 + "Configure All Detected Clients" 自动写 Claude/Cursor/VS Code/Cline 等配置。
- 三个值得抄的设计：**Tool Groups**（vfx/animation/ui/testing，按域折叠，类似我们的分组预设）、**Roslyn 脚本校验**（改完 C# 立刻编译校验 → 把"编译错误"变成工具返回的一部分，正是 AI 循环的 verify 环节）、**多实例路由**（一个 MCP 服务对多个 Unity 编辑器实例）。
- 由 Aura 赞助维护，v10.0.0（2026-06-30），发布节奏极快（~2-4 周一个 minor）。

**Unreal MCP（aadeshrao123，288 命令）**
- C++ 插件在编辑器内执行 + Python/CLI 桥；命令按 15 类组织；社区版/Pro 双轨。值得注意的是 README 提到 **UE 5.8 官方开始内置 Experimental MCP server**（localhost only）——引擎厂商自研 MCP 是趋势，Godot 官方尚无，这是原生插件的窗口期。

**ultimateunrealenginemcp（jeebus87，133 工具，概念最前沿）**
- 三个设计亮点直接可抄：**Visual Review Loop**（"生成灯光 → 截图 → 让 AI 看图修正强度"的编排）、**Automatic Self-Verification**（每个写操作后自动校验）、**Headless vs Live 双模式**（无插件时文件级工具仍可用，模块缺失优雅报错）。1021 个测试，工具即文档。

**Blender MCP（26150⭐）**
- 最流行的"创作工具 MCP"：Python server + Blender addon，prompt 驱动建模。验证了"**编辑器 MCP + 视觉反馈**"的普适需求；star 数说明创作者对"让 LLM 直接操作编辑器"的强烈诉求。

**github/github-mcp-server（官方，32422⭐）**
- 最佳"标准合规"参考：Go 实现、stdio + Streamable HTTP + SSE 三传输、resources + prompts 全支持、以 GitHub 身份做权限边界。协议完整度是官方服务器的标配。

---

## 3. 用户痛点与期望清单（issue 实证）

> 全部为真实 GitHub issue，编号可直接点击跳转（链接见 §6）。

### 3.1 Coding-Solo/godot-mcp（社区最大样本）

| 痛点 | 证据 | 对我们的启示 |
|---|---|---|
| **假成功（最伤体验）**：工具返回成功但实际没生效 | [#55](https://github.com/Coding-Solo/godot-mcp/issues/55) "Falsely thinks using add_node or create_scene worked (but didnt!)"——且日志显示 **Copilot 因 schema 含 `default`/`minimum` 关键字直接拒绝加载工具**（JSON Schema 严格性问题，通用性极强） | ①每个写操作后必须**真实验证**（读回节点/文件）；②schema 必须严格符合 MCP 子集，禁止额外关键字 |
| **不稳定**：用着用着突然报错 | [#20](https://github.com/Coding-Solo/godot-mcp/issues/20) "Creating scene does not work (json parse error) — It was working for a day then suddenly stopped working" | 传输/解析层要有明确错误码与自愈 |
| **进程状态耦合**：工具依赖"编辑器已由 MCP 启动" | [#37](https://github.com/Coding-Solo/godot-mcp/issues/37) "Error: No active Godot process"；[#23](https://github.com/Coding-Solo/godot-mcp/issues/23) "unable to launch editor"；[#84](https://github.com/Coding-Solo/godot-mcp/issues/84) "MCP stuck on connecting" | 原生插件**天然无此问题**——这是我们的结构性优势，要在 README/对比中讲清楚 |
| **验证环节缺失**：AI 只能看终端日志，看不见画面 | [#88](https://github.com/Coding-Solo/godot-mcp/issues/88) Feature Request: Visual Debugging / Automated Playtest Capture——"游戏开发里大部分 bug 是**视觉异常**而非崩溃/报错" | 视觉验证闭环（截图/录屏 + 基线对比）是刚需——我们已有 screenshot / assert_visual_baseline，应编排成开箱即用流程 |
| **缺测试反馈** | [#29](https://github.com/Coding-Solo/godot-mcp/issues/29) 请求集成 Godot GUT，把 pass/fail 结果回传给 agent | 我们已有 test runner 工具，但应输出结构化结果 + 与任务计划联动 |
| **安全** | [#64](https://github.com/Coding-Solo/godot-mcp/issues/64) RCE via unsanitized projectPath（已修复）；[#112](https://github.com/Coding-Solo/godot-mcp/issues/112) autoload 注入 | 路径/参数校验 + 工作区边界是原生服务器的生命线 |
| **省 token 意识** | [#128](https://github.com/Coding-Solo/godot-mcp/issues/128) "Add token usage estimation structure for operations" | 工具目录里给出**每个工具的预估 token 成本/返回体积** |
| **文档与排障** | [#103](https://github.com/Coding-Solo/godot-mcp/issues/103) load_sprite 需已导入纹理（前置条件不明）；[#77](https://github.com/Coding-Solo/godot-mcp/issues/77) MCP 初始化说明不足 | 描述里写清前置条件（Prerequisites），提供 init 检查工具 |

### 3.2 本项目（yurineko73/Godot-MCP-Native）自身 issue（16 open，最直接）

| 痛点 | 证据 | 解读 |
|---|---|---|
| **Codex CLI 兼容性** | [#1](https://github.com/yurineko73/Godot-MCP-Native/issues/1) "Can not use in Codex Cli"；[#24](https://github.com/yurineko73/Godot-MCP-Native/issues/24) "codex 无法加载mcp" | 客户端兼容矩阵要显式测试并写文档（stdio 与 streamable http 两种接法） |
| **编译错误对 agent 不可见（验证盲区）** | [#9](https://github.com/yurineko73/Godot-MCP-Native/issues/9) "godot控制台里的类如编译错误或解析错误之类的,大模型调用mcp工具能感知到吗?"；[#12](https://github.com/yurineko73/Godot-MCP-Native/issues/12) "大模型写的GDScript编译会报错,但是 mcp 的 get_editor_logs 好像拿不到编译时的问题" | **最高优先级的体验缺口**：改代码 → 编译失败 → agent 看不到 → 无从 fix |
| **稳定性** | [#4](https://github.com/yurineko73/Godot-MCP-Native/issues/4) "启动后过几秒godot崩溃"；[#29](https://github.com/yurineko73/Godot-MCP-Native/issues/29) 插件脚本加载报错（安装问题） | 需崩溃诊断/自检（端口冲突、配置损坏、依赖缺失） |
| **协议错误** | [#21](https://github.com/yurineko73/Godot-MCP-Native/issues/21) "MCP error -32601"（method not found） | 检查客户端发来的方法名（如 streamable http 握手差异），补日志 |
| **可发现性** | [#27](https://github.com/yurineko73/Godot-MCP-Native/issues/27) "AssetLib里搜不到" | 发布到 Godot Asset Library（同 MCP4Godot 已上架） |
| **i18n 破坏功能** | [#32](https://github.com/yurineko73/Godot-MCP-Native/issues/32) "编辑器非英语界面下 Debugger Errors 面板日志读取失败" | 内部逻辑绝不能依赖编辑器 UI 的显示字符串 |
| **跨 agent 复用** | [#67](https://github.com/yurineko73/Godot-MCP-Native/issues/67) "skill通用其他agent吗?" | 用户想要"技能/工作流"在 Claude Code / Cursor / Copilot 间可移植 → **Agent Skills（SKILL.md）** |
| **平台覆盖** | [#56](https://github.com/yurineko73/Godot-MCP-Native/issues/56) "Godot mcp cli没有mac版本" | CLI/安装器跨平台 |

---

## 4. "理想编辑器 MCP 服务器"能力清单与本项目差距

按 **协议视角**（标准合规、客户端兼容）与 **用户视角**（连上后能否完整开发一个游戏）两条线。

### 4.1 协议/标准视角

| 能力 | 理想形态 | 本项目现状 | 差距 |
|---|---|---|---|
| 严格 JSON Schema（MCP 2020-12 子集，无额外关键字） | 所有客户端（含 Copilot）可加载全部工具 | 未审计（#55 证明 Copilot 会因 `default`/`minimum` 弃用工具） | **高**：加 schema lint 测试 |
| `instructions`（初始化即下发使用引导） | 渐进披露引导（先小工具集→按需启用） | ✅ 已有 SERVER_INSTRUCTIONS（罕见优点） | 无 |
| `tools/list` 保持小 + listChanged 通知 | 默认 10~30 个，启用后推送变更 | ✅ 28 核心 + meta；listChanged 已声明 | 低：验证 listChanged 真的推送 |
| resources + 订阅 | 项目上下文（场景摘要/项目设置/类表）可低成本"读取" | ✅ resource manager 存在 | 中：内容策划（有哪些资源）不足 |
| prompts/list + prompts/get | 工作流提示（plan→debug→review→test）即调即用，**零常驻 token** | ⚠️ **capability 声明了但 0 个 prompt 注册**（register_prompt 无调用点） | **高**：空壳能力 = 协议缺陷 |
| logging（服务端日志给客户端） | agent 可查询服务端状态 | 面板有日志，协议级 logging 未见 | 中 |
| 传输：Streamable HTTP（2025-06-18/2025-11-25） | 单端点 POST + Accept 协商 | ⚠️ 现为经典 SSE（GET + POST 分离） | **高**：MCP4Godot 已按新标准做；Codex 兼容问题可能与此相关 |
| 协议版本协商 | 支持 2024-11-05 → 2025-11-25 | ✅ 4 个版本 | 无 |
| 认证 | 本地默认免密 + 远程/共享场景 Bearer | ✅ Bearer Token | 低：补"绑定本机回环"选项 |
| 采样/根目录（sampling/roots） | 可选；editor 服务器通常不需要 | 未实现（合理） | 无 |

### 4.2 用户/自主开发视角（read → plan → edit → verify → fix 闭环）

| 环节 | 理想形态 | 本项目现状 | 差距 |
|---|---|---|---|
| **read** | 低成本读场景/脚本/资源/项目状态 | ✅ 30+ 读工具 + resources | 低 |
| **plan** | 任务清单持久化、依赖、DoD、进度 | ✅ manage_task_plan（落盘 res://.mcp/task_plan.json） | 低：可加"计划→执行→验证"一键编排 prompt |
| **edit** | 节点/脚本/场景/项目设置写操作 + 写后读回 | ✅ 100+ 写工具 | 低 |
| **verify（编译/静态）** | 改完立刻拿到解析/编译错误 | ⚠️ script_validate 存在，但 **get_editor_logs 拿不到编译错误**（#9/#12）；编辑语言非英文时 Debugger 面板读取失败（#32） | **最高** |
| **verify（运行/测试）** | 运行游戏、跑测试、收结构化结果 | ✅ play_and_verify / test runner / assert_no_runtime_errors / assert_performance_budget / smoke_test_export | 低：结果结构化+与计划联动 |
| **verify（视觉）** | 截图/录屏 → 基线对比 → 差异热力图 | ✅ screenshot / assert_visual_baseline（黄金文件+容差+热力图） | 中：编排成"视觉 playtest 循环" |
| **fix** | 拿错误反馈再编辑 | ✅ 闭环工具已齐 | 取决于 verify 质量 |
| **上下文经济** | 渐进披露、目录+检索、按需启用、token 成本可见 | ✅ list_tool_catalog + enable_tools + 分组/预设（领先）；instructions 引导（领先） | 中：30 核心仍偏多；描述未按"路由友好"重写；无 token 估算（#128） |
| **技能/工作流** | SKILL.md 技能包，跨 agent 可移植 | ❌ 无 skills 交付物；用户已在问跨 agent 复用（#67） | **高** |
| **视觉/多模态** | 截图直接可被多模态模型查看 | ✅ 有截图（回传路径需确认） | 中 |

---

## 5. Top 15 差异化优化建议

按"性价比 × 差异化"排序。目标是让本项目从"功能最多"变成"**体验最好**"。

1. **补上验证闭环的最后一环：编译/解析错误反馈（最高优先）**
   新增 `verify_scripts`（或升级 script_validate）：对指定脚本（默认全部已修改）做解析 + 依赖检查，返回**带行号的错误/警告列表**；同时修 `get_editor_logs` 使其**不依赖编辑器 UI 语言**地抓取 ScriptServer/DebuggerErrors 的编译诊断（修复 #9/#12/#32）。改完代码 agent 立刻能拿到编译反馈，自主修复。
2. **实现真正的 prompts（现在是空壳）**
   `prompts/list` 已声明 capability 却返回空——这是协议层面的"未完成承诺"。注册 6~8 个高价值 prompt：`plan_game_feature`、`debug_runtime_error`、`review_scene`、`run_test_suite`、`visual_playtest`、`onboard_new_project`。把本项目的编排工具（manage_task_plan → play_and_verify → assert_*）串成即调即用的工作流模板，**零常驻 token**。
3. **schema 严格化 + 自动化回归**
   加一条 GUT 用例：遍历 215 个工具的 input/output schema，断言只含 MCP JSON Schema 允许的关键字（拒绝 `default`/`minimum` 等，Copilot 会直接弃用工具——#55 实证）；发布"已在 Claude Code / Cursor / Cline / Copilot / Codex 测试"的兼容矩阵徽章。
4. **修复 Codex 兼容并补全客户端 onboarding**
   用 Codex CLI 实测 stdio 与 Streamable HTTP 两种接法，修掉 #1/#24；UI 增加"一键生成 Claude Desktop / Claude Code / Cursor / Cline / Codex / Copilot 配置"（参考 Unity MCP 的 Configure All Detected Clients 与 Coding-Solo 的配置片段）。
5. **发布到 Godot Asset Library + 一键安装脚本**
   解决 #27（AssetLib 搜不到）；提供 `mcp_setup.gd` 或 CLI（含 macOS 版，解决 #56）自动下载插件 + 写各客户端配置 + 健康检查。
6. **迁移/双轨支持 Streamable HTTP**
   在现有 SSE 之外按 2025-06-18 规范补单端点 POST /mcp（含 Mcp-Session-Id），版本协商里把 2025-11-25 走 Streamable HTTP；保持 SSE 兼容老客户端。这大概率同时修复 Codex 与部分 -32601（#21）问题。
7. **把核心工具再收敛 + 目录语义化**
   默认 `tools/list` 目标 ≤20 个；`list_tool_catalog` 增加语义检索（query→排序命中）与**每工具预估 token 成本/返回体积**（回应 #128）；工具描述按"何时用/何时别用/前置条件/示例"模板重写（回应 #103 与 Anthropic 工具写作规范）。
8. **发布 Agent Skills 技能包（跨 agent 可移植）**
   在仓库提供 `skills/` 目录：`SKILL.md` 格式的 godot-playtest / godot-debug-loop / godot-scene-building / godot-asset-pipeline。Claude Code、Copilot（已支持 agent skills）、Cursor 均可加载——直接回应 #67 的跨 agent 诉求，且不依赖 MCP 协议扩展。
9. **视觉 playtest 一键编排**
   把 screenshot + play_and_verify + assert_visual_baseline + 差异热力图串成一个 `visual_playtest` 高内聚工具/流程（对齐 Coding-Solo #88 的诉求与 ultimateunrealenginemcp 的 Visual Review Loop）：运行 → 截图 → 与基线对比 → 返回判定+热力图路径。
10. **写后自校验（防假成功）**
    对所有写工具做"操作后读回断言"（如 add_node 后 get_scene_tree 验证节点存在、write_script 后重新解析），返回带证据的结果（对齐 #55 教训）；失败时返回具体原因而非成功。
11. **崩溃/启动自诊断**
    针对 #4：启动时预检（端口占用、配置损坏、依赖缺失、GL 兼容性），失败时给出可操作建议而非崩溃；健康检查端点返回插件自检报告；把"启动 5 秒后崩溃"类问题接入日志导出工具。
12. **资源层内容策划**
    注册一批高价值只读资源：`godot://project/settings`、`godot://project/autoloads`、`godot://project/classes`、`godot://scene/current/digest`、`godot://input/map`，让 agent"读项目"不再靠一串工具调用；支持订阅 + 变更通知。
13. **连接会话体验**
    每个客户端会话独立 session + 心跳/超时优雅处理；连接状态作为资源暴露给 agent；配置变更（端口/token）后自动通知客户端（listChanged + 会话提示），减少"stuck on connecting"类体验。
14. **结构化测试输出与计划联动**
    GUT/测试运行结果返回结构化 JSON（用例级 pass/fail/time/error line），并写回 manage_task_plan 的任务状态（DoD 勾选），让"计划→执行→验证"在数据层面闭环。
15. **多实例与文档站**
    参考 Unity MCP：支持多 Godot 编辑器实例路由（不同端口/会话标签）；把 docs/tools/* 渲染成可搜索的工具目录站（含 schema 示例、token 估算、客户端配置），让"215 个工具"从负担变成卖点。

---

## 6. 参考 URL 全集

### 竞品仓库
- [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp)（5301⭐，JS/TS bridge）
- [yurineko73/Godot-MCP-Native（本项目公开仓库）](https://github.com/yurineko73/Godot-MCP-Native)（716⭐）
- [IvanMurzak/Godot-MCP](https://github.com/IvanMurzak/Godot-MCP)（C# + ai-game.dev 云）
- [smalldy/MCP4Godot](https://github.com/smalldy/MCP4Godot)（GDScript 原生，Streamable HTTP）
- [yanhuifair/Godot-MCP](https://github.com/yanhuifair/Godot-MCP)
- [alexmeckes/godot-mcp](https://github.com/alexmeckes/godot-mcp)
- [Rizzpect/Godot-MCP](https://github.com/Rizzpect/Godot-MCP)
- [spardanviro/Godot_AI](https://github.com/spardanviro/Godot_AI)（C++ 编辑器 AI 模块）
- [CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp)（13572⭐，原 justinpbarnett/unity-mcp）
- [MCP Registry - unity-mcp](https://github.com/mcp/coplaydev/unity-mcp)
- [aadeshrao123/Unreal-MCP](https://github.com/aadeshrao123/Unreal-MCP)（288 命令）
- [jeebus87/ultimateunrealenginemcp](https://github.com/jeebus87/ultimateunrealenginemcp)（133 工具，Visual Review Loop）
- [ahujasid/blender-mcp](https://github.com/ahujasid/blender-mcp)（26150⭐）
- [github/github-mcp-server](https://github.com/github/github-mcp-server)（官方参考实现，32422⭐）
- [Godot MCP - Godot Asset Library（Coding-Solo 上架条目）](https://www.godotengine.org/asset-library/asset/5305)

### 关键 issue（痛点实证）
- Coding-Solo/godot-mcp：[#55 假成功 + Copilot schema 拒绝](https://github.com/Coding-Solo/godot-mcp/issues/55)、[#20 场景创建 json 解析错误](https://github.com/Coding-Solo/godot-mcp/issues/20)、[#37 No active Godot process](https://github.com/Coding-Solo/godot-mcp/issues/37)、[#23 无法启动编辑器](https://github.com/Coding-Solo/godot-mcp/issues/23)、[#88 视觉调试/自动试玩录制 Feature Request](https://github.com/Coding-Solo/godot-mcp/issues/88)、[#29 GUT 测试支持](https://github.com/Coding-Solo/godot-mcp/issues/29)、[#64 RCE 安全公告](https://github.com/Coding-Solo/godot-mcp/issues/64)、[#112 autoload 注入](https://github.com/Coding-Solo/godot-mcp/issues/112)、[#102 update_project_uids 路径 bug](https://github.com/Coding-Solo/godot-mcp/issues/102)、[#103 load_sprite 前置条件不明](https://github.com/Coding-Solo/godot-mcp/issues/103)、[#128 token 用量估算](https://github.com/Coding-Solo/godot-mcp/issues/128)、[#84 MCP 卡在 connecting](https://github.com/Coding-Solo/godot-mcp/issues/84)、[#77 初始化说明](https://github.com/Coding-Solo/godot-mcp/issues/77)
- yurineko73/Godot-MCP-Native：[#1 Codex CLI 不可用](https://github.com/yurineko73/Godot-MCP-Native/issues/1)、[#24 codex 无法加载 MCP](https://github.com/yurineko73/Godot-MCP-Native/issues/24)、[#9/#12 编译错误 agent 感知不到](https://github.com/yurineko73/Godot-MCP-Native/issues/9)、[#4 启动崩溃](https://github.com/yurineko73/Godot-MCP-Native/issues/4)、[#21 MCP error -32601](https://github.com/yurineko73/Godot-MCP-Native/issues/21)、[#27 AssetLib 搜不到](https://github.com/yurineko73/Godot-MCP-Native/issues/27)、[#32 非英语界面 Debugger Errors 读取失败](https://github.com/yurineko73/Godot-MCP-Native/issues/32)、[#56 无 macOS CLI](https://github.com/yurineko73/Godot-MCP-Native/issues/56)、[#67 skill 跨 agent 通用性](https://github.com/yurineko73/Godot-MCP-Native/issues/67)

### 最佳实践 / 协议 / 上下文工程
- [Anthropic: Writing effective tools for AI agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
- [Anthropic: Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
- [anthropics/skills（官方技能仓库 + Agent Skills 规范）](https://github.com/anthropics/skills)
- [Claude: Skills explained（vs prompts/Projects/MCP/subagents）](https://claude.com/blog/skills-explained)
- [MCP 官方：Understanding MCP servers（capabilities：tools/resources/prompts/logging/sampling/roots）](https://modelcontextprotocol.io/docs/draft/learn/server-concepts)
- [MCP 官方规范 - server/tools](https://modelcontextprotocol.io/specification/latest/server/tools)
- [MCP Progressive Disclosure: Save Tokens, Retrieve Schemas | Solo.io](https://www.solo.io/blog/mcp-progressive-disclosure)
- [MCP Servers Are Eating Your Context Window. Catalog Mode Fixes That.](https://www.strayspark.studio/blog/mcp-server-context-costs-catalog-mode-progressive-disclosure)
- [Writer Engineering: When too many tools become too much context（context rot / RAG-MCP，检索式工具选择 +50% token 节省）](https://writer.com/engineering/rag-mcp/)
- [delta-mcp: Token-efficient MCP（78%+ token 缩减）](https://github.com/norhther/delta-mcp)
- [Klavis: Less is More — 4 design patterns for better MCP servers](https://www.klavis.ai/blog/less-is-more-mcp-design-patterns-for-ai-agents)
- [aptu-coder: MCP, Agents, and Orchestration — Best Practices（agentic loop 四阶段）](https://github.com/clouatre-labs/aptu-coder/blob/main/docs/MCP-BEST-PRACTICES.md)
- [ai-infra-curriculum/ai-agent-guidebook: The Agentic Coding Workflow](https://github.com/ai-infra-curriculum/ai-agent-guidebook/blob/main/best-practices/agentic-workflow.md)
- [GitHub Copilot: Using MCP servers with the Copilot SDK](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/mcp)
- [GitHub Copilot CLI: Add MCP servers](https://docs.github.com/zh/enterprise-cloud@latest/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers)
- [GitHub: Remote GitHub MCP Server GA（远程 MCP 支持）](https://github.blog/changelog/2025-09-04-remote-github-mcp-server-is-now-generally-available/)
- [Microsoft Open Source Blog: 9 open-source projects GitHub Copilot/VSCode teams sponsor](https://opensource.microsoft.com/blog/2025/10/16/9-open-source-projects-the-github-copilot-and-visual-studio-code-teams-are-sponsoring-and-why-they-matter/)
- [DEV.co: Godot MCP overview](https://dev.co/ai/mcp/godot-mcp)
- [DeepWiki: Coding-Solo/godot-mcp 架构与开发指南](https://deepwiki.com/Coding-Solo/godot-mcp/2-architecture)

---

*报告由 MCP 生态调研生成；star/issue 数据来自 GitHub API 实时抓取（2026-08），工具数量来自各仓库 README。*
