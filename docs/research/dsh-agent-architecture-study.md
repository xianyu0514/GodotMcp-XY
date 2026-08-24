# DSH 强 Agent 能力架构研究报告

> **研究目标**：深挖 DeepSeek Harness（DSH，`D:\ai\de\`，多包 TypeScript/Cordis 项目）的 agent 能力架构——它靠什么实现"强 agent"（持久目标、自主循环、子代理编排、技能复用、多轮续作）——并产出一份可落地的设计参考，供本项目（Godot 编辑器 MCP 插件，221 工具 + `manage_task_plan` 任务图/DoD）借鉴"内置 agent"能力。
>
> **研究日期**：2026（基于 DSH 仓库 `docs/subsystems/*.md` 与 `packages/*` 源码）
>
> **关键结论（TL;DR）**：DSH 的"强 agent"不是靠一个巨大的 prompt，而是靠 **六层正交机制** 组合：
> 1. **事件溯源会话日志**（session log）作为唯一事实源，模型历史是投影而非存储 → 重启/续作/回放免费获得；
> 2. **goal 域**（持久快照 + CAS revision + 严格回放校验）把"目标"变成可审计的持久对象；
> 3. **goal-round-driver**（回合驱动器）在 agent 空闲时自动入队下一轮提示 → 真正的"自主续作"；
> 4. **subagent 缝**（一次性 run / 可持续 child + Activation 驻留 + 冷恢复）→ 隔离上下文委派；
> 5. **workflow 引擎**（模型写 JS 编排脚本）→ 大规模扇出编排；
> 6. **skill/todo/plan 等消费端能力** → 按需加载、进度可见、协作状态。
>
> 对 Godot MCP 的启示高度可操作：MCP 服务器内建"agent 会话"（goal 持久化 + 回合驱动 + 进度投影）、把 read→plan→edit→verify→fix 循环作为一等公民（prompt + 工具 + 资源）、引入回合预算与阻塞语义、错误→诊断→修复→复验的自愈回路。详见第 4 章逐条建议。

---

## 1. DSH 全景：一个 Cordis 插件树，六层能力各自为政又互相咬合

DSH 整体是一个基于 [Cordis](https://github.com/cordiverse/cordis) 的插件树（`docs/architecture.md`）：**每个能力都是一个可替换的插件包**，模型适配器、工具注册表、会话日志、agent 循环本身都是插件。架构文档的扩展点表（`docs/architecture.md` "Where new behavior goes"）是理解全貌的最佳入口：

| 目标 | 机制 |
|---|---|
| 管理同会话目标 | `ctx.goals`；经 `agent/*` 继续 |
| 委派子代理 | `ctx.subagents`（命名 provider 注册表）|
| 脚本化多 agent 编排 | `ctx.workflowEngine` |
| 技能按需加载 | `ctx.skills`（分层 provider 注册表）|
| 记录任务清单 | `todo_write` 工具 → `todo/write` 会话事件 |
| 计划协作状态 | `ctx.planMode`（软性引导）|

### 1.1 核心 spine（agent 循环本体）

`docs/architecture.md` 定义了两个基本单位：

- **step** = 一次模型请求 + 它调用的工具；
- **turn** = 零或多个 step，从认领输入到"不再欠任何东西"关闭。

```text
turn/start
  claim next-step input plus one queued message
  assemble prompt sections + tool schemas
  -> agent/pre-step                   reject | enter(messages)
     step/start → user/message → agent/request → llm/stream
     → assistant/chunk* → assistant/message
     → tool/call* → tools/pre-execute → tools/execute → tools/post-execute → tool/result*
     step/end
     tools owe another request, or next-step input arrived -> claim -> next step
  -> agent/turn-stopping
turn/end
```

关键点（`docs/subsystems/core.md`、`docs/agent-lifecycle.md`）：

- **`Agent` 句柄**（`packages/core/agent/src/types.ts`）是唯一公开面：`followup()`（排队一轮普通回合并唤醒 driver）、`steer()`（投递到最近的 step 边界）、`inject()`（排队模型可见上下文但不唤醒）、`cancel()`、`whenIdle()`、`runMaintenance()`、`send()`。
- **inbox 是唯一的输入队列**：两个有序待处理列表 `next-turn` / `next-step`；`claim` 通过纯删除 splice 取走"所有 next-step + 一个 next-turn"，`agent/inbox/inserted/claimed/discarded` 事件让 UI 和编排层可观察。
- **事件是扩展点**：`agent/pre-step`（瀑布，可改写进入 step 的消息或整体拒绝）、`agent/request-error`（瀑布，可返回 `{kind:'retry'}` 自愈）、`agent/turn-stopping`（串行，可用 `steer()` 阻止 turn 关闭）、`agent/status`（idle/running）。
- **会话日志是唯一事实源**：`Session.deriveMessages()` 从日志投影模型历史，不是独立存储（`docs/subsystems/session.md`）。"模型可见 ⇒ 已入日志"是一条运行时不变量。

### 1.2 六层能力的职责与协作

| 能力 | 包 | 职责 | 与循环的关系 | 持久性 |
|---|---|---|---|---|
| **goal** | `packages/goal/goal` + `goal-round-driver` + `tool-goal` + `command-goal` | 同会话持久目标：创建/续作/分阶段 | 在 agent 空闲时自动 `followup()` 下一轮；模型经 `get_goal/create_goal/update_goal` 操作 | `goal/change` 会话事件（快照或墓碑），随 session 持久化 |
| **subagent** | `packages/subagent/subagent` + 6 个 provider + 3 个工具 | 委派子代理：一次性 run 与可持续 child | 是**可选能力缝**，不在循环里；child 是普通 agent，父经 `followup()` 续作 | child 是独立持久 Session（`subagent/descriptor` 事件） |
| **workflow** | `packages/workflow/workflow` + `workflow-worker-thread` + `tool-workflow` | 模型写 JS 编排脚本批量启子代理 | 每 `agent()` 经 subagent 缝启一个 child，全部挂在调用 `parent` 名下 | 无持久执行状态；只写 `tool-workflow/run-start|run-end` 展示记录 |
| **skill** | `packages/skill/*` | 按需加载可复用指令 | 目录经 `agent.inject()` 注入会话；`skill` 工具加载正文 | 目录消息是会话历史（非 World State） |
| **todo** | `packages/todo/tool-todo` | 整表替换式任务清单 | 每次调用 append 一个 `todo/write` 事件；UI 经 sessionProjections 投影 | `todo/write` 事件 |
| **session** | `packages/core/session` | 追加式事件日志 + fork/resume | 循环的底层载体 | JSONL/SQLite 持久化缝 |

**协作关系**（这是最重要的部分）：
- goal 依赖 session（目标状态写在日志里）与 agent（回合经 inbox 投递）；
- goal-round-driver 监听 `agent/status`、`agent/pre-step`、`goal/changed` 等事件做自动续作，是**唯一把"持久目标"翻译成"模型回合"的组件**；
- subagent 复用 agent/session 全部基础设施——child 就是普通 agent，只是多了"父授权 + 持久描述符 + 驻留/冷恢复"；
- workflow 又叠在 subagent 之上——`agent()` 钩子内部就是 `ctx.subagents.start()`；
- skill/todo/plan 都通过 `agent.inject()` / 会话事件挂到模型可见面上，不侵入循环。

---

## 2. "强 agent"的 8 个关键设计

### 2.1 目标持久化 + CAS revision + 自动续作（goal 域 + round driver）

**目的**：让"目标"从对话上下文的临时承诺变成可审计、可续作、可预算的持久对象。

**机制**（`packages/goal/goal/src/index.ts`、`types.ts`、`fold.ts`；`packages/goal/goal-round-driver/src/index.ts`）：

1. **持久快照 + 墓碑**：每次变更写一条 `goal/change` 会话事件，载荷是完整后置快照（`{id, revision, objective, phase, maxGoalRounds, blockedReason?}`）或 clear 墓碑。`revision` 从 1 起每次变更 +1。
2. **严格回放折叠**（`fold.ts`）：`foldGoal()` 按 seq 重放事件，**校验每一步转移合法**（如 `resume` 只允许从 active/paused/blocked、`roundsStarted` 只能随"被承认的回合消息"单调递增、revision 必须恰好 +1）。这意味着持久文件被篡改会 fail-loud，而不是静默重建错误状态。
3. **回合记账在日志里**：`applyGoalEvent` 对 `user/message` 检查——若消息来源是 `goal` 类型，则必须是"当前 active goal 的下一个回合"（`source.round === roundsStarted + 1` 且 `<= maxGoalRounds`、goal id/revision 精确匹配），通过才把 `roundsStarted` 推进。**回合数不是"执行了多少次"，而是"日志里承认了多少条带正确身份的回合消息"**。
4. **进程内激活与持久阶段分离**：`phase`（active/paused/blocked/complete）是持久的；`activation`（armed/disarmed）是进程本地的。重启后 session 从持久层 resume，goal 折叠恢复但 activation 一定是 `disarmed`——必须经**人类授权**的 `resume` 才能重新武装（`goal/change` 事件 + `agent/session-start` 时 `activation='disarmed'`）。
5. **回合驱动器**（`goal-round-driver/src/index.ts`，`apply()`）：监听 `agent/status===idle` 与 `goal/changed`，在满足 `readyToDrive()`（fiber 活跃、agent 空闲、无竞争消息、非 stopping）时：
   - 若已有 attempt 在途 → 先做持久性检查点 `ctx.sessions.flush(agent.session)`；
   - 读取当前 goal：非 active/armed 直接返回；`roundsStarted >= maxGoalRounds` → 自动 `block()`（`code:'round-limit'`）；
   - 否则渲染下一轮提示（`prompt.ts` 的 `<goal_round>` 块）→ 以 `source:{kind:'goal', goalId, revision, round}` 构造 `UserMessage` → `agent.followup(message)`；
   - **竞态围栏**：`agent/pre-step` 瀑布里对候选回合做 `validReservation()` 双重校验（attempt 仍排队/已认领、未过期、goal 还是同一 revision 且 active+armed、round === roundsStarted+1）；任一条件失败 → 拒绝该 step、恢复其他被认领消息、`block(code:'prompt-rejected')`。`agent/inbox/*` 事件跟踪 attempt 生命周期（queued→claimed→admitted），`turn/end` reason 为 aborted/max-tokens 时取消或解除武装。
6. **工具契约**（`packages/goal/tool-goal/src/index.ts`）：`create_goal`（要求直接人类请求；可省略 `max_goal_rounds` 由部署默认值 256 兜底）、`get_goal`（读完整视图：id/revision/objective/phase/roundsStarted/maxGoalRounds/blockedReason/activation）、`update_goal`（edit/pause/resume/complete/blocked 五种 action；**edit/pause/resume 必须来自直接顶层人类请求**，自动续作回合中只允许 complete/blocked；blocked 有最少连续回合数门禁，默认 3）。工具描述本身就是模型策略（`guidance()` 注入 `systemPrompt.section`）。

**为何有效**：目标状态可从日志重放而无需镜像（崩溃/重启零丢失）；revision CAS 防止模型用陈旧 ref 覆盖新状态；round 记账在日志里使"自动续作"可审计且能被严格回放验证；激活/阶段分离让"机器自主"与"人类授权"边界清晰——**续作是自动的，但武装/解除武装永远是人类或策略的决定**。

### 2.2 事件溯源会话日志：历史即投影

**目的**：让整个对话历史、模型上下文、回放、fork、resume 共享一个不可变事实源。

**机制**（`docs/subsystems/session.md`、`packages/core/session/src/types.ts`）：
- 追加式 `SessionEvent` 日志（`turn/start`、`step/*`、`user/message`、`assistant/chunk`、`assistant/message`、`tool/call`、`tool/result`、`todo/write`、`request/header`、插件合并的 `goal/change`、`compaction/*` 等），`seq` 严格连续、载荷必须无损 JSON。
- `deriveMessages()` 从日志投影模型消息（`assistant/chunk` 不进入投影；`assistant/message` 是权威；compaction 的 `surfaceOp:'replace'` 从投影中移除被摘要遮蔽的节点）。
- fork/resume：`ctx.sessions.fork(source, boundary?, childSessionId?)` 选一个**不落在 open turn 内**的前缀作为 seed；`session/end-seed` 事件标记"此生命周期之前的事件来自 seed"。`ctx.agents.resume()` 从持久化加载 Session 再重建 Agent。
- 持久化缝（`docs/subsystems/persistence.md`）：JSONL/SQLite 后端订阅 `session/event` 异步落盘，`session/flush` 检查点，崩溃恢复闭合孤儿 turn/step/tool 边界。

**为何有效**：模型可见内容与存储内容同构（"Model-visible means logged" 不变量）→ 重放、复现、审计、压缩全部免费；fork 是"选前缀"，resume 是"重放+end-seed"；`todo/write`、`goal/change`、plan 状态这类 UI/协作状态也统一为日志事件，UI 用投影读取，不需要第二份镜像状态。

### 2.3 子代理缝：一次性 run 与可持续 child（独立上下文 + 冷恢复）

**目的**：把"委派"做成与 bash 同级的**可选能力**，且支持"持续对话的远程 worker"。

**机制**（`docs/subsystems/subagent.md`、`packages/subagent/subagent/src/continuation.ts`）：

- **两种形态**：
  - `start()` 一次性 run：`SubagentRun` 句柄，一个前台委派、一个结果、`dispose()` 必调；失败以 `stopReason: 'error'` 解析而不是 reject（消费端映射为 `isError` 工具结果）；
  - `startContinuable()` 可持续 child：返回 `{childId, messageId}`，**立即返回不等回合跑完**。
- **Activation 驻留模型**（`continuation.ts`）：一个可持续 child 是持久 Session；进程内最多一个"驻留期"（Activation）。状态机：`running`（有活动 admit/turn）/ `waiting`（静止但还拥有未处置完的子 Activation）/ `settled`（子孙全部处置 → 释放 `AgentHandle` 并删除 Activation）。**Agent inbox 是唯一 FIFO 队列**：`followup()` 在驻留时直接入队/唤醒，无驻留时**冷恢复**（从持久 Session `ctx.agents.resume()` 重建，然后投递）。
- **授权**：续作必须由"持久父会话"（`SessionHeader.parentSession`）授权；`interrupt()` 支持人类父地址或 live 祖先 agent 两种权威。
- **描述符**：`subagent/descriptor` 事件（log-only、不参与模型历史）持久记录 mode/label/provider/model/persona/toolFilter，冷恢复据此重建。
- **结果回收**：子代理自主 `report`（`tool-subagent-report`，quiet/next-step 两种投递）与运行时"settled 通知"（`subagent-settled`，运行时自己写的账，防止把机器的陈述冒充孩子的话）。
- **发现**：`listChildren/listDescendants` 直接从 session store + 持久化合并枚举，不加载任何 agent。

**为何有效**：子代理是**独立上下文的普通 agent**（独立 session、独立日志、独立 token 预算），父只拿回最终输出或结构化结果（`outputSchema`），天然隔离上下文；"可持续 + 冷恢复"让跨进程/跨会话的长期委派成为可能；"fail loud, no silent degradation"——provider 缺能力就 `UNSUPPORTED_CAPABILITY` 拒绝，绝不假装支持。

### 2.4 脚本化编排：workflow 引擎（模型写 JS 编排脚本）

**目的**：当需要"对 N 个文件做审计 / 多角度研究 / 大批量迁移"这类扇出时，让模型用一段**受控脚本**统一编排几十个子代理，而不是一回合一个。

**机制**（`docs/subsystems/workflow.md`、`packages/workflow/workflow-worker-thread/src/runtime.ts`）：

- 工具 `workflow({script, meta, args})` 启动；`meta`（name/description/whenToUse/phases）是纯 JSON 数据，**引擎先校验再执行**（校验失败在任何代码运行前就拒绝，绝不为了拿 meta 而执行脚本）。
- 脚本在 `node:worker_threads` 的 vm 上下文里运行（每 run 一个 worker），暴露钩子：`agent(prompt, {label, phase, schema, provider, model})`、`parallel(thunks)`、`pipeline(items, ...stages)`、`phase(title)`、`log(message)`、`args`。
- **隔离与契约**：脚本值出 realm 必须物化成纯 JSON（`materializeFromRealm`）；`agent()` 有 `maxTotalAgents` 与 `maxConcurrentAgents` 上限（防 runaway 循环的后盾）；`parallel`/`pipeline` 里**子代理失败映射为 `null`**（脚本 `filter(Boolean)`），但**钩子误用（选项拼错、schema 越界、上限触发）是 `fatal: true` 必须杀死脚本**——"选项拼错必须响亮地死，绝不溶解成看起来像普通子代理失败的东西"。
- `WorkflowRun.result` **永不 reject**：脚本失败解析为 `stopReason:'error'`；取消后引擎在宽限期内强判 `cancelled` 并 terminate worker，消费者 `await result` 永远不被卡死。
- 事件 `workflow/start|phase|log|agent-start|agent-end|end` 只携带**数据快照**（含 id + meta，绝不携带 live run 句柄），观察者拿不到 cancel/dispose。

**为何有效**：把"编排逻辑"与"执行细节"分离——模型写声明式/命令式脚本，引擎负责并发、上限、取消、结果物化；fatal 与 per-item-null 的二分让错误可见性极高；worker 隔离让失控脚本最多杀死自己的 worker 而不是宿主。

### 2.5 技能缝：按需加载、目录即会话、正文即工具结果

**目的**：可复用指令（如 brainstorming、TDD）按需加载，不给每个回合灌爆上下文。

**机制**（`docs/subsystems/skills.md`、`packages/skill/tool-skill/src/index.ts`、`packages/skill/skill/src/index.ts`）：

- 分层 provider 注册表（`ctx.skills`）：host/仓库插件进全局层，agent preset 挂载的进 preset 层；读取时合并作用域链，最近层同名技能胜出。本地 provider 按 rank 扫 `projectRoot/.dsh/skills`、`<root>/.agents/skills`、自定义目录、`<dshHome>/skills`、bundled。
- **目录是模型可见的会话消息**：`dsh-tool-skill` 在首个 `agent/pre-step` 注入 `<system-reminder><available_skills>…`（只含 name + 截断 description，不含正文/路径），之后每次 step 前比对 digest，变化才 `agent.inject()` 全量替换。
- **正文按需加载**：`skill({name})` 工具校验名字、查目录、核对 `modelInvocable` 策略，然后 `ctx.skills.get()` 现读正文（不缓存，磁盘改了下次调用就是新的），以 `<skill_content>` 结构返回。
- 双入口：模型走 `skill` 工具；人类走 `/<name>` 前缀（`agent/pre-step` 里确定性加载，注入在最后、离答案最近）。

**为何有效**：目录（小）常驻会话、正文（大）按需加载——上下文成本与能力体积解耦；digest 驱动保证模型看到的目录永远与注册表一致；正文不缓存让"改技能文件即改行为"。

### 2.6 todo 清单：整表替换 + 日志即 UI

**目的**：任务分解与进度跟踪，且与 DSH 的"一切皆日志"哲学一致。

**机制**（`packages/todo/tool-todo/src/index.ts`、`docs/subsystems/session.md` 的 `TodoItem`）：

- 每次 `todo_write` 调用 append 一个 `todo/write` 事件，载荷是**完整列表快照**（`[{content, status: pending|in_progress|completed}]`），回放时 last-write-wins；故意不设 id/优先级——整表替换所以条目不需要稳定身份。
- 工具描述本身就是纪律：**"send the ENTIRE list every call—it REPLACES the previous list"**；可配置 `allowParallelInProgress`（并发 agent 场景允许多个 in_progress，否则强制单一 active）。
- 校验：content 非空去重、状态枚举、`additionalProperties:false`（模型认为它写的必须与落盘一致）。
- UI 投影：sessionProjections 注册 `todos` 单元（latest whole-list，`turn/start` 清空为 null——结束的清单保留到 turn/end，新回合重新开始）。

**为何有效**：零状态镜像（UI/模型/持久化都从日志投影）；整表替换消除了"部分更新"的合并歧义；校验严格保证"日志快照 = 模型以为它写的"。

### 2.7 会话续作与 fork：resume 语义 + 目标重新武装

**目的**：跨进程/跨会话的"接着干"。

**机制**（`docs/subsystems/persistence.md`、`packages/core/agent-loop` 的 `resume()`、goal 的 `agent/session-start`）：

- `ctx.agents.resume({resumeSessionId, ...})` 从持久化加载 Session → 重建 Agent → 以 `SessionStartSource='resume'` 发 `agent/session-start`。
- goal 服务监听 `agent/session-start` 把 activation 置为 `disarmed`；工具描述明确告知模型：**"After session resume or fork, an active goal is disarmed: when a human asks to continue or resume in any wording or language, use update_goal action resume to rearm it"**——续作必须由人类话语重新授权。
- fork 是选前缀建新会话；`subagent-fork-in-process` 把"完成的回合前缀"作为 seed 喂给孩子（让孩子继承父的完成历史上下文）。

**为何有效**：resume 不是"存下聊天记录"，而是**重放事件日志 + 重建活体**——所有状态（含 goal/todo/plan）都从日志恢复，没有"内存态丢失"问题；但"自动续作权"是进程本地、可被人类随时剥夺/授予。

### 2.8 失败反馈与自愈（agent/request-error + turn 语义 + 门禁工具）

**目的**：模型/传输/工具失败不吞掉，可编程恢复。

**机制**：
- `agent/request-error` 瀑布：失败的 step 关闭后、turn 关闭前运行；监听者可修复持久状态或返回 `{kind:'retry'}`（如 compaction 恢复），默认 `undefined` 让失败终结。
- `turn/end` reason 精确区分 `completed | aborted | blocked | error | max-tokens | interrupted`（`docs/subsystems/session.md`），消费者能区分"干净结束"与"被截断/被取消/出错"。
- 工具结果可携带 `concludesTurn`（提前结束工具循环）、`isError`（失败映射）、`meta`（私有展示载荷）。

**为何有效**：失败是**一等公民的数据**（有类型的 stopReason / LlmFailure / 事件），不是异常崩溃；自愈点是声明的瀑布，可插入策略（重试、压缩、降级），且不阻塞正常路径。

---

## 3. DSH 与 Godot MCP 现状对照

| 维度 | DSH | Godot MCP（现状） |
|---|---|---|
| 目标持久化 | `goal/change` 事件 + CAS revision + 自动续作 | `manage_task_plan`：JSON 落盘（`res://.mcp/task_plan.json`）任务图 + DoD（含 3 类 gate），**但没有"回合"概念、没有自动续作** |
| 回合驱动 | goal-round-driver 在空闲时自动 `followup()` | 无——模型每次被唤醒都要靠会话内上下文回忆"上次做到哪" |
| 任务清单 | `todo_write` 整表替换 + UI 投影 | 无独立 todo 工具（任务图承担一部分） |
| 循环作为一等公民 | step/turn/inbox/pre-step 事件 | `prompt_workflows.gd` 提供 7 个**一次性模板**（plan_game_feature、debug_runtime_error、fix_compile_errors、visual_playtest…），但它们是"静态文本"，不是"服务器内建的循环状态机" |
| 验证门禁 | 工具结果语义化（isError/concludesTurn） | 已有 `assert_performance_budget` / `assert_no_runtime_errors` / `assert_visual_baseline` / `play_and_verify` —— **验证层已经很强** |
| 委派 | 子代理缝 + 可持续 child | 无（Godot 插件内无法起子 LLM agent；但"编排多个验证/探针任务"可类比） |
| 技能 | 目录注入 + 按需加载 | 无（有 prompts 列表，无"技能"概念） |

**结论**：Godot MCP 缺的不是"工具数量"（221 个已经很多），而是 **① 目标/回合的持久状态机（goal 域 + 驱动器）② 自主开发循环的服务器内建形态（而不是静态 prompt 文本）③ 预算/阻塞/自愈语义**。

---

## 4. 对 Godot MCP 的启示：内置 agent 的设计蓝图（重点）

以下每条都标注落地形式（**T**=新增/改造 MCP 工具、**P**=prompt/系统提示、**R**=MCP 资源、**S**=服务器内部机制，对应 `mcp_server_native.gd` / `native_mcp/` 内部模块）。

### 4.1 内建"agent 会话"：goal 持久化 + 多轮续作（S + T）——优先级最高

**借鉴**：`packages/goal/goal`（域） + `goal-round-driver`（驱动器） + `tool-goal`（模型面）三件套。

**建议**：

1. **新建 `agent_goal_store.gd`**（仿 `task_plan_store.gd` 的纯逻辑层），持久化到 `res://.mcp/agent_goal.json`：
   ```json
   {
     "schema_version": 1,
     "goal": { "id": "g1", "revision": 3, "objective": "...", "phase": "active",
               "max_goal_rounds": 20, "rounds_started": 4,
               "blocked_reason": null, "created_at": "...", "updated_at": "..." },
     "history": [ { "revision": 1, "rounds_started": 0, "at": "...", "op": "create" },
                  { "revision": 2, "rounds_started": 2, "at": "...", "op": "edit" } ]
   }
   ```
   - 关键字段照抄 DSH 语义：`revision`（每次变更 +1，CAS）、`phase ∈ {active, paused, blocked, complete}`、`rounds_started`（**只由"被承认的回合"推进**）、`max_goal_rounds`、`blocked_reason {code, message}`。
   - 写变更时做**严格转移校验**（仿 `fold.ts`）：create 必须 revision=1/phase=active/rounds=0；resume 只能从 active/paused/blocked；complete 只能从 active/paused/blocked；blocked 只能从 active 且必须带 reason。文件损坏 → 拒绝加载而非静默重建。
2. **新增一组 goal 工具**（T，注册进 `project_tools_native.gd` 或新建 `agent_tools_native.gd`）：
   - `agent_goal_get` —— 读当前 goal（id/revision/objective/phase/rounds_started/max_goal_rounds/blocked_reason/armed）。工具描述照抄 DSH 策略："Call this before updating a goal."
   - `agent_goal_create {objective, max_rounds?}` —— 仅接受直接人类请求（可在工具内校验来源，DSH 用 `requireDirectHuman`，Godot 侧至少文档/描述里声明）。
   - `agent_goal_update {goal_id, revision, action: edit|pause|resume|complete|blocked, objective?, max_rounds?, blocked_reason?}` —— CAS；edit/pause/resume 要求人类请求；自动回合中只允许 complete/blocked；blocked 要求 `rounds_started >= 3` 且带具体 reason（"难度/不确定性不是 blocked"）。
3. **服务器内部回合驱动器**（S，仿 `goal-round-driver/src/index.ts`，可在 `mcp_server_native.gd` 里用 `Timer`/`call_deferred` 实现）：
   - 不变量："**在一次 goal 回合结束后、且服务器空闲时，若 goal 仍 active + armed，自动向客户端补发一条 `notification`/`resource` 提示继续**"。
   - 具体机制：工具层每次执行后检查 `agent_goal_store`——若 `phase==active && armed && rounds_started < max_goal_rounds`，则在工具结果里附加一个标准字段（如 `"next_round": {"round": n, "instruction": "<goal_round>…</goal_round>"}`），或注册一个 `res://.mcp/` 下的 **MCP 资源** `agent://goal/current`（R），供客户端随时拉取"当前目标 + 回合进度 + 继续指令"。
   - 回合指令模板（P，仿 `prompt.ts` 的 `<goal_round>`）：
     ```
     <goal_round>
     Objective: <objective>
     Round: 5/20
     Continue working toward the objective in this same project session. Treat the current
     editor state, tool results, and task_plan as authoritative; inspect them instead of
     assuming earlier narration is still current. Make concrete progress and verify the result
     (run_project + assert_* gates). Before claiming completion, gather evidence the whole
     objective is achieved, read the current goal, and mark it complete. If work remains,
     leave the goal active for the next round. Report a blocker only after it persists
     across rounds and you can name the concrete condition.
     </goal_round>
     ```
   - **"armed" 语义**：goal 创建后 armed；服务器重启/新会话 → 置为 disarmed；只有人类明确说"继续/接着干"（检测到这类用户消息，或客户端调 `agent_goal_update resume`）才重新 armed。这与 DSH 的"activation 与 phase 分离"完全一致，防止"服务器重启后 AI 自己无限跑下去"。

### 4.2 把"自主开发循环"（read→plan→edit→verify→fix）作为一等公民（P + T + R）

**借鉴**：DSH 的 step/turn/inbox 概念 + `agent/pre-step`/`agent/turn-stopping` 事件 + `request-error` 自愈。Godot 插件不能改客户端的 agent 循环，但可以在**服务器侧把循环状态机做出来**，让任何客户端（Claude/Cursor/任何 MCP 客户端）都能驱动它。

**建议**：

1. **新建 `autonomous_loop.gd`（S）**：服务器内建的"自主开发循环状态机"，状态 ∈ {idle, plan, execute, verify, fix, blocked, done}，配合现有 `manage_task_plan`：
   - **P（plan）**：从 `next_actionable()` 取就绪任务 → 渲染执行指令（读脚本 → 定位改动点 → 编辑）；
   - **E（execute）**：执行 `write_script`/`execute_editor_script`/节点操作；
   - **V（verify）**：执行任务 DoD 里的 gate（`assert_performance_budget` / `assert_no_runtime_errors` / `assert_visual_baseline`），把 `observed` 指标回填 `manage_task_plan set_dod observed=` → 客观计算 `met`/`evidence`（`task_plan_store.evaluate_gate` 已实现，直接复用）；
   - **F（fix）**：gate 失败 → 生成"最小修复指令"（错误 → 诊断 → 修复 → 复验），循环回 E，带重试计数；
   - 状态机暴露为：**`agent_loop_status`（T）** 工具（读当前循环状态、当前任务、重试次数、最后失败原因）+ **`agent_loop_resume`/`agent_loop_pause`（T）**。
2. **升级 `prompt_workflows.gd`（P）**：现有模板是"一次性文本"，升级为**引用上述状态机的模板**：模板里不再是"按顺序调用工具"，而是"读取 `agent_loop_status` → 按其返回的当前阶段指令行动 → 每步之后回写 `agent_loop_status`"。这样模板从"剧本"变成"状态机的翻译层"。
3. **注册 MCP 资源（R）**：`mcp://agent/loop` 返回 `{phase, current_task, retries, last_failure, next_action}`；`mcp://agent/goal` 返回目标视图。客户端 UI 可常驻显示，模型可用 `resources/read` 随时刷新——这正是"进度可见性"（DSH 里 UI 从 `session/event` 投影，MCP 里用资源/通知）。

### 4.3 预算与回合控制（T + S）

**借鉴**：`maxGoalRounds`（goal）与 `maxTotalAgents`/`maxConcurrentAgents`（workflow）。

**建议**：
- `agent_goal_create` 的 `max_rounds` 与部署默认值（如 256 太激进，Godot 场景建议默认 20~50）；
- 驱动器在 `rounds_started >= max_goal_rounds` 时自动 `block(code:'round-limit')`；
- `autonomous_loop.gd` 内建**每任务重试上限**（如 3）与**每会话修复预算**（如 10），超限自动置 `blocked` 并请求人类；
- 循环状态机的 verify 阶段**强制要求客观证据**：`no_runtime_errors` gate 缺 `error_count` 观测 → 判定失败（`task_plan_store` 已实现"can't prove it ⇒ not met"），防止模型自报成功。

### 4.4 失败反馈与自愈（S + T）

**借鉴**：`agent/request-error` 瀑布 + `turn/end reason` + `SubagentResult.stopReason`。

**建议**：
- **工具错误语义化**：所有 gate 断言工具（`assert_*`）返回结构化 `{met, checks[], failures[]}`（已基本如此），并**新增一个统一字段**（如 `"concludes_phase": "fix"`）让客户端模型把"失败"直接路由到循环状态机的 fix 阶段，而不是自己猜；
- **自愈回路模板**（P，升级 `debug_runtime_error`/`fix_compile_errors` 为循环模板）：`collect logs → read_script → validate_script → smallest edit → re-validate → run_project → re-pull logs → (persists? loop : done)`——现有模板已有雏形，补齐"带重试预算 + 每次失败写 journal 到 task"两个点；
- **失败留痕**：循环状态机把每次失败写入任务的 `journal`（`manage_task_plan` 已支持），让"同一个阻塞条件持续 N 轮"成为可判断的事实——这正是 DSH blocked 门禁（`blockedAfterConsecutiveRounds`）的 Godot 版。

### 4.5 技能/手册按需加载（T + R）——可选但收益高

**借鉴**：`ctx.skills` 目录注入 + 按需正文。

**建议**：
- 把项目约定（AGENTS.md 要点、工具用法 cheat-sheet、GDScript 风格、测试规范）做成**服务器内建的资源/工具**：`agent_get_guidance {topic: "gdscript-style"|"testing"|"tool-catalog"|...}`（T），返回正文；同时 `agent_guidance_list`（T）返回摘要目录。让模型"按需加载规范"而不是把 AGENTS.md 全文灌进每轮 prompt（与 DSH 技能目录/正文分离同理）。
- 若嫌工具太多，可合并为 **MCP 资源** `mcp://agent/guidance/<topic>`（R）——资源天然"按需读取"，且不占用工具配额（Godot MCP 有 30 核心上限约束）。

### 4.6 可落地的分阶段路线（建议按此推进）

| 阶段 | 内容 | 主要借鉴 | 改动面 |
|---|---|---|---|
| **P1** | `agent_goal_store.gd` + 3 个 goal 工具 + 回合指令资源 `mcp://agent/goal/current`（无自动驱动，先做"持久目标 + 手动续作"） | goal 域（revision/CAS/phase） | 新文件 + 新工具 + 文档/翻译/测试（按 AGENTS.md 新工具流程） |
| **P2** | `autonomous_loop.gd` 状态机 + `agent_loop_status/resume/pause` + 模板升级（prompt 引用状态机） | 循环状态机 + turn 语义 | 新模块 + prompt_workflows.gd 改造 |
| **P3** | 回合驱动器（工具结果附加 next_round 字段/通知）+ blocked/round-limit 门禁 + 失败 journal 留痕 | goal-round-driver + blocked 门禁 | 服务器内部逻辑 + gate 工具返回字段扩展 |
| **P4** | 指导手册资源 `mcp://agent/guidance/*`（可选） | skills 目录/正文分离 | 资源注册 |

### 4.7 需要避开的坑（从 DSH 学到）

1. **不要为"进度"再造第二份状态**：goal/task/loop 状态都从持久文件 + 会话事件投影（Godot 无事件日志，退化为"JSON 文件 + 内存缓存 + 变更即写盘"，但保持单一事实源，禁止两个模块各存一份）。
2. **续作必须人工授权**：自动驱动回合 ≠ 无限自跑。armed/disarmed 分离是安全底线。
3. **工具结果必须反映"模型以为它写了什么"**：DoD 观测缺失 = 失败（已实现）；工具 schema `additionalProperties:false` 防静默吞字段（已实现，保持）。
4. **fatal 与 per-item 失败分开**：Godot 侧没有脚本钩子，但"参数错误要响亮拒绝，任务失败要可重试"的原则同样适用——工具错误字典区分 `{"error": ...}`（参数/前置条件，模型可修）与 `{"blocked": ...}`（预算耗尽/环境问题，需要人类）。
5. **回合提示要"重读现场"**：DSH 的 `<goal_round>` 明确要求"treat current workspace/tool results as authoritative; inspect instead of assuming"——Godot 场景下模型容易凭记忆继续，回合指令必须强制 `get_project_info`/`get_scene_structure`/`read_script` 等现场读取。

---

## 5. 关键源码/文档索引

### DSH 文档
- `D:\ai\de\docs\architecture.md` —— 插件树架构、turn flow、扩展点表（"Where new behavior goes"）
- `D:\ai\de\docs\agent-lifecycle.md` —— step/turn 时序图（含 inbox claim、pre-step、request-error 自愈）
- `D:\ai\de\docs\subsystems\goal.md` —— goal 域类型与 `ctx.goals` API（GoalRef/GoalPhase/GoalView/rounds）
- `D:\ai\de\docs\subsystems\subagent.md` —— 子代理缝全部契约（start/startContinuable/followup/interrupt/reportFrom/listChildren）
- `D:\ai\de\docs\subsystems\workflow.md` —— workflow 引擎契约（meta/result/事件/失败纪律）
- `D:\ai\de\docs\subsystems\skills.md` —— 技能注册表/目录/加载契约
- `D:\ai\de\docs\subsystems\session.md` —— SessionEvent 词汇表、deriveMessages、fork、TodoItem
- `D:\ai\de\docs\subsystems\plan.md` —— plan mode（软引导 + exit_plan_mode 工具）
- `D:\ai\de\docs\subsystems\core.md` —— Agent 句柄、inbox、agent/* 事件、agent-presets
- `D:\ai\de\docs\capability-seams.md` —— 服务缝全景图（`ctx.goals/subagents/workflowEngine/skills` 位置）

### DSH 源码（关键文件）
- `packages\goal\goal\src\index.ts` —— GoalService：create/edit/pause/resume/complete/block/clear、CAS、激活管理
- `packages\goal\goal\src\fold.ts` —— 严格回放折叠 + 回合记账校验（`applyGoalEvent` 的 round 检查）
- `packages\goal\goal\src\types.ts` —— GoalRef/GoalPhase/GoalSnapshot/GoalView 类型
- `packages\goal\goal-round-driver\src\index.ts` —— **自动续作驱动器**（readyToDrive/validReservation/竞态围栏/round-limit 阻塞）
- `packages\goal\goal-round-driver\src\prompt.ts` —— `<goal_round>` 回合提示模板
- `packages\goal\tool-goal\src\index.ts` —— get_goal/create_goal/update_goal 工具 + 模型策略 guidance
- `packages\todo\tool-todo\src\index.ts` —— todo_write 工具（整表替换、allowParallelInProgress）
- `packages\subagent\subagent\src\continuation.ts` —— Activation 驻留/冷恢复/所有权图
- `packages\workflow\workflow-worker-thread\src\runtime.ts` —— 脚本钩子实现（agent/parallel/pipeline/phase/log + 上限）
- `packages\skill\tool-skill\src\index.ts` —— 技能目录注入（pre-step digest）+ skill 工具

### Godot MCP 现状（本仓库）
- `addons\godot_mcp\tools\task_plan_store.gd` —— 任务图 + DoD/gate 纯逻辑层（**可直接复用**）
- `addons\godot_mcp\tools\project_tools_native.gd`（`_register_manage_task_plan`）—— manage_task_plan 工具
- `addons\godot_mcp\native_mcp\prompt_workflows.gd` —— 7 个一次性工作流模板（升级对象）
- `addons\godot_mcp\native_mcp\mcp_server_native.gd` —— 服务器入口（回合驱动器的挂载点）

---

*本报告由 AI 研究生成，基于 DSH 仓库 `docs/subsystems/*`、`docs/architecture.md`、`docs/agent-lifecycle.md` 与 `packages/{goal,subagent,workflow,skill,todo}/` 源码，以及本仓库 `task_plan_store.gd` / `prompt_workflows.gd` 现状。*
