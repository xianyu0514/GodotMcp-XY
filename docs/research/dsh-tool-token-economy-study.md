# DSH 工具系统与 Token 经济研究 —— 对 Godot MCP（221 工具）的优化指南

> 研究目标：DeepSeek Harness（`D:\ai\de\`，多包 TypeScript 项目）如何注册/发现/执行工具、如何控制上下文中的工具定义与结果体积；产出可直接指导纯 GDScript 实现的建议。
> 研究对象：Godot MCP `addons/godot_mcp/`（221 工具 = 28 核心 + 189 补充 + 4 元工具，6 大类 + Meta）。
> 版本基线：DSH 仓库当前 HEAD；Godot MCP v1.0.7-pre1。

---

## 0. TL;DR（一页结论）

DSH 的 token 经济不是"单一机制"，而是**注册层（面）→ 定义层（schema）→ 执行层（结果）→ 会话层（计量/压缩）**四层协同：

| 层 | DSH 机制 | 一句话原理 | Godot MCP 对应/差距 |
|---|---|---|---|
| 注册层（工具面） | `tools.restrict(allow/deny)`、agent preset、`presentAs('code')` 折叠 | 让模型**看不到**不需要的工具 | 已有：默认仅 core+meta、`enable_tools`、预设。差距：`tools/list` 仍把 `outputSchema` 发出去（DSH 只发 name/description/parameters） |
| 定义层（schema 体积） | `schemaOf` 白名单、每工具 100-199 号 guidance 段落、工具描述≈1-2 句 | 定义越短，每次请求省得越多（**工具 schema 每轮都全额计费**） | 已有 lint 门禁（白名单/风险关键字/description 覆盖率），缺 **token 预算断言** |
| 执行层（结果体积） | 工具内建 cap（read 2000 行、glob 100、grep 250）+ `spill-policy`（50KB 内联上限，头尾预览+落盘定位符）+ pruner（8KB 裁剪） | 结果只在**超限**时降级，且降级必须自报家门（`truncated`、总数、恢复路径） | 缺：统一 limit/offset/summary 参数规范、大结果落盘+引用约定 |
| 会话层（预算/压缩） | token-meter（4 字符/token 启发式）→ compaction-basic（80% 阈值触发，16% 尾部保留，8K 摘要）→ pruner 先行 | 会话膨胀时**可重放**地缩面，不丢可恢复性 | 缺：会话 token 预算可见性、工具面 token 计量 |

**三条最高杠杆建议**（详见 §3）：
1. `tools/list` 不再下发 `outputSchema`（改由 `get_tool_details` 按需给）——直接砍掉 221 个 output schema 的每轮线缆字节；
2. 把 lint 门禁升级为 **token 预算门禁**：`estimate_tokens = JSON.stringify(schema).length / 4`（DSH 的计费口径），对每个工具的 description/参数 description/默认启用集总量设上限；
3. 为读工具建立**统一分页/汇总/落盘约定** + 会话级 TTL 结果缓存（DSH 不做通用结果缓存，但对 Godot MCP 这类"读代价高、写频率低"的场景值得做，见 §3.3）。

---

## 1. DSH 工具系统设计（全链路）

### 1.1 注册与模型可见面：`schemaOf` 白名单

工具注册入口是 `ToolRuntime.register()`（`packages/core/tools/src/index.ts`）。每个 `ToolDefinition` 携带：

- 模型可见（**只有这三个**，`schemaOf()`，`index.ts:1256-1267`）：`name`、`description`、`parameters`；
- 模型不可见（执行/展示元数据）：`output.schema + output.render`（输出声明与渲染）、`execute()`、`timeoutMs`（超时预算，`index.ts:249-255` 明确"NEVER sent to the model"）、`isConcurrencySafe()`（并行调度分类器，同样不可见）、`presentCall/presentResult`（UI 卡片投影）。

```ts
// packages/core/tools/src/index.ts:1256
private schemaOf(definition: ToolDefinition, detachParameters: boolean): ToolSchema {
  const { name, description, parameters } = definition   // ← 只这三个
  ...
}
```

关键推论：**DSH 自己的任何工具都不会把 output schema 发给模型**。MCP 桥（§1.5）也只在工具内部保留 `structuredContent` 声明，模型侧只见 name/description/parameters。

### 1.2 工具发现（模型视角）：DSH 没有内建渐进披露

DSH 的 system-prompt 组装（`packages/core/system-prompt/src/index.ts` 的 `assemble()`）把**全部可见工具**的 schema 收集进 `PromptAssembly.tools`，经 `toolOrder`（默认字典序）排序后整包发给模型。**没有按 token 预算裁剪工具数的逻辑**——"给模型看多少工具"由组合层决定：

1. **注册层**：`tools.register()` 全局注册；`tools.restrict({allow, deny})` 按 agent scope 过滤（`index.ts:1071`）；
2. **展示层**：`presentAs('native' | 'code' | 'both')`（`index.ts:946`）——`code` 模式下模型只见 `run_code` 一个工具 + 生成的 SDK 签名段（`ts-types.ts`/`py-types.ts`），所有原生工具只能从程序内调用。这是 DSH 对"工具面膨胀"的终极解法（Claude Code 的"工具都进上下文"与"只给一个入口"的中间态）；
3. **预设层**：`agent-presets`（`packages/preset/agent-presets`）以 `agent.cordis.yml` 组合声明（含 `tool-presentation` 行选展示模式、`toolOrder`、persona），按目录发现（`discovery.ts`：`COMPOSITION_FILE='agent.cordis.yml'`，system/user 两级信任）。

> 对比：Godot MCP 的 `list_tool_catalog / search_tools / get_tool_details / enable_tools` 四件套 + `mcp_tool_preset_manager` 正是 DSH 缺失的那一层"工具集自带的渐进披露"——**DSH 若接 Godot MCP，模型侧的发现路径完全依赖这 4 个 meta 工具**。所以 meta 工具的质量（描述、输出体积、可发现性）就是 Godot MCP 的 token 经济命脉。

### 1.3 执行管线：pre → guard → around → body → post → finalize → result

见 `docs/tool-execution-pipeline.md`（Mermaid 图）与 `index.ts` 的调度器。要点：

```
model tool-call
  → tools/pre-execute  瀑布（钩子/权限/approval ask；可 allow/deny/ask）
  → 单调 guard（返回 reason 即拒绝，且不能被后注册 listener 翻转）
  → tools/execute      瀑布（around 包装：超时、重试、度量；只可换 signal）
  → 工具 body          execute(args, exec) 返回 canonical JSON value
  → fs/write-intent 门  （tool-fs 写前读回执，事件门，不改 schema）
  → tools/post-execute 瀑布（accept / 替换 content / 替换 value / block+feedback；可挂 additionalContexts）
  → finalizeContent    定义拥有的最后一次 content 变换（快照于调用开始时）
  → tools/result       同步通知，冻结的权威结果
```

- **并行调度**：`executeToolCalls()`（`packages/core/agent-loop/src/tool-calls.ts`）按 `executionMode` 分 parallel/exclusive 组，`maxParallelToolCalls` 控制池大小；结果按**模型顺序**提交，`additionalContexts` 进入下一步的 FIFO。
- **错误映射**：工具 throw / policy 拒绝 → `ToolFailure {message, info{name,code}}` → 模型收到 `isError` result（`TOOL_ABORTED`/`UNKNOWN_TOOL`/`INVALID_TOOL_OUTPUT` 等稳定 code）。MCP 桥把服务器的 `isError:true` 转 throw（`mcp-client/src/tools.ts:344-346`）。
- **损失无失真**：args 与 value 都过 `snapshotJsonValue` + `deepFreeze`；output.render 失败 → `INVALID_TOOL_OUTPUT`。

### 1.4 结果处理：canonical value → content blocks → 可替换

`createSuccessResult()`（`index.ts:1793`）：value 过 `output.schema` 校验 → `output.render()` 投影为模型可见 content → `finalizeContent` 兜底 → `tools/result`。`post-execute` 是**结果后处理的统一挂点**：spill-policy、repeat-tool-reminder、fs-observation 都挂在这里，不改工具本体——"工具家族解耦策略服务"。

### 1.5 DSH 自己怎么接 MCP（`packages/mcp/mcp-client`）

对 Godot MCP 最相关的一段：

- **命名**：`mcp__<serverName>__<rawName>`，64 字符/`[A-Za-z0-9_-]` 约束，冲突追加 12 位 SHA-256（`tools.ts:111-117`）；
- **同步**：`syncTools()` 拉满 `tools/list` 分页，**全量注册，无过滤**（`tools.ts:143-193`）——DSH 信任服务端自己的工具面控制（即 Godot MCP 的 enabled 开关 + 预设）；
- **调用**：透传 rawName + args，`toolCallTimeoutMs`（默认 60s）兜底超时；`isError` → throw；图片块 → durable attachment（模型无图能力时降级为文本占位）；
- **结果体积**：桥本身**不截断**——大结果由全局 `spill-policy`（§2.4）统一处理。

---

## 2. Token 经济机制清单（目的 × 实现 × 配置值）

以下配置值均来自 DSH 官方 bundle：`packages/bundle/base/cordis.patch.yml`。

### 2.1 工具面控制（注册层）

- **目的**：减少每轮进入上下文的 schema 数量（schema 是"每轮全额计费"的）。
- **实现**：`tools.restrict()`（per-agent allow/deny 掩码，`core/tools/src/index.ts:1071`）+ 预设（`agent-presets`）+ `presentAs('code')` 折叠。
- **DSH 取舍**：默认 `native` 模式（全量 schema）；preset 是"换一套组合"，不是运行时裁剪。

### 2.2 工具定义体积（定义层）

- **目的**：schema 本身越短，每轮越省。
- **实现**：
  - `schemaOf` 白名单（§1.1）——`timeoutMs`、`isConcurrencySafe`、output schema 一律不进上下文；
  - 每工具一条 100-199 号 **guidance 段落**（`system-prompt`，如 `tool:glob` order 103），把"什么时候用、怎么用"从描述里挪到段落，schema 保持精炼；
  - 描述风格：**1-2 句话，第一句=做什么+何时用**（对照 `docs/tool-catalog.md` 里所有工具描述）。
- **计费口径**（token-meter，`packages/llm/token-meter/src/estimate.ts`）：`tokens ≈ 文本字符数 / 4`，每条 content block +4 结构开销，每条消息 +4 role 开销；工具 schema 按 `JSON.stringify(tools).length / 4` 计（`estimateToolsTokens`）。

### 2.3 工具内建结果 cap（执行层，工具自己声明）

| 工具 | cap | 位置 |
|---|---|---|
| `read` | `limit` 默认 2000 行，`offset` 1 起 | `packages/fs/tool-fs/src/index.ts` |
| `glob` | 100 路径（`GLOB_MAX_RESULTS`）；超限取 mtime head 或按顶层目录 round-robin 采样；完整结果落盘 | `packages/fs/tool-fs-search/src/glob.ts` |
| `grep` | 250 匹配（`GREP_MAX_MATCHES`），单行预览 2000 字节（`GREP_MAX_LINE_BYTES`）；完整结果落盘 | `packages/fs/tool-fs-search/src/grep.ts` |
| `str_replace_editor` | `view_range` 行区间；长输出标记 `<response clipped>` | `tool-str-replace-editor` |
| `terminal_read` | `count` 默认 500 行（后端 cap） | `tool-terminal` |
| bash/pwsh | 长输出截尾，完整输出落盘并报告路径 | `tool-bash`/`tool-pwsh` |

共性模式：**cap 是参数化的、可被模型感知的**（描述里写明 cap 与恢复路径）；`rawOutputMaxBytes`/`stderrMaxBytes`/`maxMetaBytes` 等资源上限防止一次调用把内存/上下文打爆。

### 2.4 大结果落盘 + 引用（spill，跨工具策略）

`packages/spill/spill-policy/src/index.ts`：

- 配置：`maxInlineBytes: 50000`（50KB 内联上限，`bundle/base/cordis.patch.yml:352`）；
- 触发：post-execute 里对**纯文本结果**量 UTF-8 字节，超限 → 全文写入 session 级 spill store（`spill-local`，私有临时目录，session 哈希目录 + 随机文件名，`store.ts`），模型只见 **head/tail 预览（各一半预算）+ 定位符 + 恢复指引**：
  ```
  (Omitted 123456 bytes. Full formatted result stored at: <locator>. <retrieval_hint>)
  ```
- 预算自洽：预留通知行的字节数在 cap 内（`reserve`），保证替换结果永不超 cap（`index.ts:171-187`）；
- 边界：`read` 跳过（防 read→spill→read 死循环）；无 session/无 backend/存储失败 → 保留原文（**绝不让 spill 失败把成功调用变成 isError**）；
- 第二臂：`tools/code-dispatch-log` 对 `run_code` 子调用的大结果同样落盘（日志副本瘦身，程序收到的完整值不受影响）。

### 2.5 会话上下文预算与压缩（会话层）

- **计量**：`ctx.tokenMeter`（启发式，§2.2 口径），对所有历史消息可重放地估价（`measure(session)`）。
- **触发**：`compaction-basic`（`packages/compaction/compaction-basic/src/index.ts`）：
  - 每步 `agent/pre-step` 前量压力：`totalTokens ≥ contextWindow × thresholdRatio(0.8)` 才动（`config.ts:20`）；
  - 保留尾部 verbatim：`retainRatio 0.16`（或绝对 `retainTokens`）；摘要目标 `maxTokens: 8192`；
  - **溢出恢复**：收到 provider 的 context-window-exceeded 错误 → 强制压缩 → `retry`（`maxOverflowRetries`）；
  - 每模型可覆盖（`modelPolicies`）；摘要请求复用会话自己的 system/tools/messages 前缀 → **不打断 provider 的 KV cache**（`summarizer.ts`）。
- **工具结果裁剪先行**：`compaction-tool-result-pruner`（§2.6）在摘要前先做模型无关裁剪，把结果面压下去再决定要不要摘要。
- 手工 `/compact`：`command-compact`。

### 2.6 工具结果裁剪（pruner，模型无关、可重放）

`packages/compaction/compaction-tool-result-pruner/src/index.ts`：

- 配置：`thresholdChars: 8192, headChars: 4096, tailChars: 1024`（bundle）；
- 只对**当前 surface 上超预算的 tool/result** 做确定性 head/中/尾裁剪（按 Unicode code point，不劈代理对；保留非文本 block 顺序），替换事件前追加 `compaction/prune` shadow-price 事件（记录被裁节点的启发式 token 价），replay 可精确恢复；
- 是"压缩之前的第一道削减"，保证即使摘要不做，结果面也有硬上限。

### 2.7 渐进披露（DSH 侧缺省，靠工具集自带）

DSH 原生没有"按需加载 schema"的机制（native 模式 = 全量）；它的渐进披露是**预设 + code 折叠**。Godot MCP 的 4 个 meta 工具补上了 DSH 生态里"运行时发现"的位置（§1.2 对比）。

### 2.8 请求级缓存 / KV 对齐（省的是"重复计费"，不是重算）

- `plan-mode` 的 system prompt 明言："The tool catalog stays the same across modes for request-cache stability"（`cordis.patch.yml:273`）——**工具列表跨模式保持稳定，让 provider KV cache 不失效**；
- compaction 摘要复用前缀（§2.5）；`llm-pi-ai` 对 Anthropic 支持 `cache_control` on tool definitions（`packages/llm/llm-pi-ai/src/catalog.ts:381-382`）。

### 2.9 结果缓存（DSH 几乎不做；重复调用防护代替）

- **没有通用工具结果缓存**。唯一类似物：`file-reference-local` 的 workspace 搜索缓存，且在任何 `tool/result` 事件时整体失效（`packages/context/file-reference-local/src/index.ts:97-101`）——**写后全失效**的极端但正确的做法；
- 替代品：`repeat-tool-reminder`（`packages/guard/repeat-tool-reminder/src/index.ts`）对**连续相同调用**（参数深度 key 排序后比较）在第 3/5/8 次向模型注入提醒（`argumentsPreviewChars: 500` 截断），**不否决不重写**，只附加上下文。

### 2.10 超时与资源上限

`tool-call-timeout-policy`（`tools/execute` around 包装）执行 `ToolDefinition.timeoutMs`；bash/pwsh 的 `timeoutMs`、glob/grep 的 `timeoutMs/graceMs/rawOutputMaxBytes` 等是工具自报的资源契约。

---

## 3. 对 Godot MCP 的可操作建议（221 工具现状）

### 3.1 工具 schema 体积优化（与现有 lint 门禁结合）

现状（`test/unit/test_tool_schema_lint.gd`）：白名单关键字（实际只用 7 个）、Copilot 风险关键字豁免（`default` 250+ 处）、description 覆盖率软阈值 70%（734 个顶层属性，191 个无 description）。缺的是**体积/预算维度**。

**建议 A（最高杠杆）：`tools/list` 不再下发 `outputSchema`。**
`mcp_types.gd` 的 `to_dict()`（`mcp_types.gd:78-92`）在 `output_schema` 非空时把整个输出 schema 放进每个工具的 `tools/list` 条目。DSH 的口径是模型只见 name/description/parameters（§1.1），且主流 MCP 客户端不消费 outputSchema（lint 测试注释里也点名 Copilot 对额外关键字敏感）。改动：`to_dict()` 默认省略 `outputSchema`（或加 `include_output_schema` 开关），完整 schema 保留在 `get_tool_details` 按需返回。**221 个 output schema 的每轮字节立即归零**。

**建议 B：在 lint 测试里加 token 预算断言（把 DSH 的计费口径变成门禁）。**
在 `test_tool_schema_lint.gd` 增加：
- 每个工具：`estimate = (len(description) + Σlen(param description) + schema 骨架) / 4`，断言 `estimate ≤ TOOL_TOKEN_BUDGET`（建议 400，即 ~1600 字符，覆盖核心工具的富参数）；
- 默认启用集（28 核心 + 4 meta）：`Σ estimate ≤ DEFAULT_SET_TOKEN_BUDGET`（建议 15k，~60KB，对齐 DSH spill 的 50KB 直觉）；
- 输出报告每个工具/参数的 token 估算，做回归对照表；
- 描述首句规则：description ≤ 220 字符且第一句是"做什么+何时用"（对照 DSH 1-2 句风格）；多句引导挪进参数 description 或统一惯例说明。

**建议 C：参数级瘦身。**
- 自明参数（`session_id`/`timeout_ms`/`node_path` 等 191 个无 description 的）保持无描述即可（lint 已容忍），**但**把"所有路径必须 `res://`"这类跨工具重复约束从每个参数 description 里抽出来，放进 `SERVER_INSTRUCTIONS` 或工具 guidance（DSH 的段落模式）；
- `enum` 化：凡取值集合 ≤ 8 个的字符串参数改用 `enum`（lint 白名单已含 `enum`，`default` 是唯一豁免风险关键字——能用 enum 的地方别再写 `default`+长描述）；
- 默认值尽量用 `default` 参数化而不是在 description 里写"默认 X"（description 每轮计费，default 关键字的线缆成本已被 lint 豁免评估）。

### 3.2 返回体积控制（limit/offset、summary 模式、大结果落盘+引用）

**建议 D：统一分页/汇总参数规范（读工具）。**
给下列"可能返回大列表/大文档"的读工具补齐 `limit`/`offset`/`summary`（name-only）/`include_total`，并保持返回里带 `truncated`/`total`（对照 DSH glob/grep 的自报家门模式）：
- `list_nodes`、`get_scene_tree`、`get_scene_structure`、`list_project_scenes`、`list_project_resources`、`list_project_scripts`、`batch_get_node_properties`、`get_editor_logs`、`get_debugger_messages`、`get_performance_metrics`、`search_in_files`（对照 grep 的 250 上限）；
- `read_script`/`batch_read_scripts`：补 `offset`/`limit`（行），默认 2000（对齐 DSH `read`）；
- summary 模式默认开（`summary: true` 时只回 `name/type/…` 最小字段），完整字段用 `get_*_details` 类工具或带 `include_full` 再取。

**建议 E：大结果落盘 + 引用约定（Godot 版 spill）。**
- 新增约定（不必做成独立工具，先做规范 + 统一助手）：任何返回 > ~8KB 的读工具（`get_editor_logs`、`get_debugger_messages`、`get_scene_structure` 大场景、`search_in_files` 大命中集）把完整结果写入 `res://.mcp/out/<tool>_<timestamp>.txt`（复用 `task_plan_store.gd` 已建立的 `res://.mcp/` 落盘模式），模型可见部分返回：
  ```
  { "summary": "…前 200 字符…", "truncated": true, "total": 12345,
    "file_path": "res://.mcp/out/get_editor_logs_<ts>.txt",
    "retrieval_hint": "调用 read_script 读取该文件获取完整输出" }
  ```
- 恢复路径必须是**模型已经拥有的工具**（Godot MCP 有 `read_script`，天然闭环）；`retrieval_hint` 明确写出恢复工具名；
- 落盘失败/无权限 → 返回原文（严格 best-effort，绝不把成功调用变 error——抄 DSH spill-policy 的边界）；
- 新增一个轻量 meta 工具 `list_output_files`（或并入 `list_tool_catalog` 的位置）列出 `.mcp/out/` 且按会话过期清理（启动/每次 list 时清 >24h 文件）。

**建议 F：错误结果瘦身。**
错误返回统一 `{"error": "一句话", "hint": "恢复动作"}`，不要 dump 整个栈/整个编辑器输出；对照 DSH 的 `ToolFailure{message, info}` 结构与 `UNKNOWN_TOOL` 的"带可达路径"提示（`core/tools/src/index.ts:494-510`：`unknown tool "x": only run_code is callable…`——Godot MCP 的 unknown tool 错误也可以附 `hint: 用 list_tool_catalog 查可用工具`）。

### 3.3 工具结果缓存（哪些读工具值得、key 设计、失效）

DSH 不缓存工具结果（模型需要时自己再读）；但 Godot MCP 场景不同：**读工具有编辑器 IO 代价（扫描目录、解析场景），而同一会话内模型常常反复问同一事实**。做**会话级、按工具显式 opt-in** 的缓存，不自动缓存一切：

**建议 G：值得缓存的读工具与 key。**
| 工具 | key（canonical 参数） | 依赖指纹（失效依据） |
|---|---|---|
| `get_project_info` | 固定 | 项目级版本号（`project.godot` mtime） |
| `get_project_settings` | 属性名 | 该属性 mtime/值 |
| `list_project_resources` / `list_project_scenes` / `list_project_scripts` | 目录 + 过滤参数 | 目录树的 max(mtime)（扫描时顺带收集） |
| `get_scene_tree` / `get_scene_structure` | 场景路径 | 场景文件 mtime + 编辑器版本计数 |
| `get_node_properties` | 节点路径 + 属性列表 | 场景 mtime + 写工具调用计数 |
| `read_script` | 文件路径 + offset/limit | 文件 mtime |
| `search_in_files` | query + 目录 + include | 命中目录树的 max(mtime) |

- **key 必须规范化**：参数深度 key 排序后 `JSON.stringify`（直接移植 DSH `repeat-tool-reminder` 的 `sortJsonValue`，`guard/repeat-tool-reminder/src/index.ts:89-105`），否则 `{"a":1,"b":2}` 与 `{"b":2,"a":1}` 是两个 cache miss；
- **失效三原则**：
  1. 写工具（`create_node`/`update_node_property`/`modify_script`/`create_resource`/`run_project`/`stop_project`/`set_project_settings` 等）命中时**全量失效**（最保守，抄 `file-reference-local` 的"任何 tool/result 全失效"，`context/file-reference-local/src/index.ts:97-101`）；
  2. 文件/场景类读工具用 **mtime 指纹**：返回前重 stat，mtime 变了就重算；
  3. **TTL 兜底**（建议 5-30s），防"改了编辑器外文件"这类指纹捕捉不到的变化。
- **实现落点**：新 `result_cache_manager.gd`（或扩展 `tool_state_manager.gd`），在 `mcp_server_core` 的 dispatch 层做：命中 → 直接回缓存值（**并在结果里带 `"cached": true`**，让模型知道这不是新读数）；未命中 → 执行后按规则入缓存。**只对 `annotations.readOnlyHint == true` 且显式声明 `cacheable: true` 的工具生效**。
- **不要**缓存 `enable_tools`/`set_tool_enabled` 之外的写工具、不要跨会话持久化缓存（编辑器状态会变）。

### 3.4 上下文预算机制（会话级）

**建议 H：工具面 token 计量暴露给模型。**
- 新增 meta 工具 `get_context_budget`（或并入 `list_tool_catalog` 输出）：返回 `enabled_count`、`estimated_tool_list_bytes`、`estimated_tool_list_tokens`（按 DSH 口径 `JSON.stringify(tools)/4`）、`budget_warning`（超过阈值时提示先 `enable_tools` 关闭不需要的分组）；
- `enable_tools` 返回里加 `estimated_tool_list_tokens`（启用前后对比），让模型对"开一组 73 个 Debug 工具"的代价有数——**让模型自己为 token 做决策**，而不是靠服务端硬限。

**建议 I：工具描述分级（可选、低优先）。**
DSH 不按 tier 裁剪 schema（要么全量要么 code 折叠）。对 Godot MCP，若要"分级"，现实的做法不是改 tools/list（MCP 协议一次给全 schema），而是：
- **保持默认集小**（现状 28+4 就很好；考虑把 `debug_tools` 里 73 个中启用默认的分组进一步收紧）；
- **预设导向**：`enable_tools` 的 preset 名称与描述在 `SERVER_INSTRUCTIONS`/`list_tool_catalog` 里写清楚每套预设覆盖的分组与工具数（模型按任务挑预设，一次切换省 100+ 工具的每轮计费）。

**建议 J：会话 token 预算（服务端软上限）。**
给插件加配置 `max_tool_list_tokens`（默认如 12k，按 4 字符/token 折算 ~48KB）：`enable_tools` 启用后若超限，返回 `warning`（不阻止，只提示）——阻止会把模型锁死，提示则保留自主性（对照 DSH spill 的"宁可保留原文也不失败"哲学）。

### 3.5 渐进披露强化（已有 4 层，补细节）

现状已相当好：`list_tool_catalog`（分组+一句话，`_short_description` 140 字符）→ `search_tools`（AND 关键词 + limit 30 + total_matched）→ `get_tool_details`（单工具全量）→ `enable_tools`（按工具/分组/预设，exclusive 重置）。

**建议 K：给目录工具加分页与体积控制。**
- `list_tool_catalog`：加 `offset`/`limit`（默认如 100）+ `total_matched`（search_tools 已有），221 个工具全量列出时模型侧仍是 ~几千 token 的一次性开销，分页可再压；
- `search_tools` 的 `include_descriptions` 默认已 true，建议再加 `include_groups`/`compact`（name+group 单行）选项。

**建议 L：让发现闭环更顺。**
- `get_tool_details` 支持批量（`names: []`）——模型一次想核对 3-5 个工具 schema 时省 3-5 轮 RTT；
- `enable_tools` 支持 `dry_run`（返回将启用的工具清单 + token 估算，不实际切换），模型可以先"预算"再执行；
- 在 `SERVER_INSTRUCTIONS`（`mcp_server_core.gd:43`）里补充**预设速查**：每个 preset 的名字 → 分组 → 工具数 → 典型用途（现在只有名字列表）。

**建议 M：补一个"我缺什么工具"的检索增强。**
`search_tools` 只做 name+description 子串匹配；建议加同义词/别名表（如 `search_tools("physics")` 能命中 `set_collision_one_way`、`update_runtime_node_property` 命中"运行时属性"），因为 221 个工具按英文命名，模型容易猜错词。实现成本低（一个 `aliases` 字典），收益是**少一轮 get_tool_details 探测**。

### 3.6 其他可借鉴（重复调用、超时、KV 稳定、并行）

**建议 N：重复调用防护（轻量版 repeat-tool-reminder）。**
在 dispatch 层检测"同一工具 + 规范化参数"的连续调用：第 3 次起在结果文本头部追加一行 `(note: 这是第 N 次相同调用，上一次结果见上；如无进展请换参数或换工具)`——不拦截不重写，只提醒。缓存命中（§3.3）时天然消解一部分重复。

**建议 O：per-tool 超时契约。**
`ToolDefinition.timeoutMs` 在 DSH 是显式声明、由 `tool-call-timeout-policy` 执行的。Godot MCP 的调试类工具（`await_scene_ready`、`await_runtime_condition`、`play_and_verify`、`smoke_test_export`）天生长耗时——建议在 `MCPTool` 数据类加 `timeout_ms` 字段并在 `mcp_types.gd` 注册时校验，`mcp_http_server`/`mcp_stdio_server` 的调用处理按它设上限，避免"await 条件永不满足"的调用把会话卡死（这比 token 更伤算力）。

**建议 P：KV cache 稳定（tools/list 字节稳定性）。**
DSH 为 KV cache 稳定连 plan mode 都不换工具目录（§2.8）。Godot MCP 侧：
- `tools/list` 的**顺序保持稳定**（`_tools` Dictionary 在 Godot 4 保插入序，已稳定；`_meta.ttlMs/cacheScope` 已设置，`mcp_server_core.gd:603-606`）——**不要**每次 `tools/list` 前重排；
- `notifications/tools/list_changed` 只在真的变了才发（`_tool_list_dirty` 已实现）——保持，别在无变化时误发（会让客户端重拉整个列表、打爆 KV）；
- 启用/禁用尽量用**分组粒度**（`set_group_enabled`），少做逐工具微调，减少 list_changed 次数。

**建议 Q：并行提示。**
`annotations.readOnlyHint` 已在下发；客户端（如 DSH 的 agent-loop）会据此并行执行并发安全的读工具。保证所有 `readOnlyHint: true` 的工具**确实无副作用**（当前 `_handle_tools_call` 已有 `readOnlyHint` 检查，`mcp_server_core.gd:719`），读工具并发执行是免费的算力。

---

## 4. 引用文件索引

### DSH 侧（`D:\ai\de\`）
| 主题 | 文件 |
|---|---|
| 工具注册/执行管线/schemaOf 白名单/restrict/presentAs | `packages/core/tools/src/index.ts`（`register` 1037、`restrict` 1071、`schemas/schemaOf` 1234/1256、管线 1342-1818） |
| 执行管线图 | `docs/tool-execution-pipeline.md` |
| 工具目录（生成文档，全量 schema 样本） | `docs/tool-catalog.md` |
| system-prompt 组装/toolOrder/guidance 段落 | `packages/core/system-prompt/src/index.ts`（`assemble` 467、`orderTools` 164） |
| agent-loop 工具调度（并行池、结果顺序） | `packages/core/agent-loop/src/tool-calls.ts` |
| 工具展示模式（native/code/both） | `packages/core/agent-tool-presentation/src/index.ts` |
| MCP 客户端桥（命名、同步、执行、isError 映射、图片） | `packages/mcp/mcp-client/src/tools.ts`、`src/index.ts` |
| token 计量（4 字符/token 口径） | `packages/llm/token-meter/src/estimate.ts` |
| 结果落盘策略（50KB 上限、head/tail 预览+定位符、read 豁免） | `packages/spill/spill-policy/src/index.ts`；存储 `packages/spill/spill-local/src/store.ts` |
| 输出保留库（TextRetainer/ItemRetainer/UTF-8 安全） | `packages/util/output-retention/src/index.ts` |
| 会话压缩（80% 阈值、16% 尾部、8K 摘要、溢出恢复） | `packages/compaction/compaction-basic/src/index.ts`、`src/config.ts` |
| 工具结果裁剪（8K/4K/1K、shadow-price、可重放） | `packages/compaction/compaction-tool-result-pruner/src/index.ts` |
| 预设系统（目录发现、agent.cordis.yml、system/user） | `packages/preset/agent-presets/src/discovery.ts`、`preset.ts`、`mount.ts` |
| glob/grep cap（100/250、采样、落盘、超时） | `packages/fs/tool-fs-search/src/glob.ts`、`grep.ts` |
| 重复调用提醒（canonical 参数、[3,5,8]、500 字符预览） | `packages/guard/repeat-tool-reminder/src/index.ts` |
| 搜索缓存（任何 tool/result 全失效） | `packages/context/file-reference-local/src/index.ts:97-101` |
| 官方 bundle 配置值（spill/pruner/plan-mode/…） | `packages/bundle/base/cordis.patch.yml` |
| KV cache / cache_control | `packages/llm/llm-pi-ai/src/catalog.ts:381-382`、`cordis.patch.yml:273` |

### Godot MCP 侧（`C:\kaifa\xx\Godot-MCP-Native\`）
| 主题 | 文件 |
|---|---|
| 工具注册 API / tools/list / 启用控制 / 通知 | `addons/godot_mcp/native_mcp/mcp_server_core.gd`（`register_tool` 996、`_handle_tools_list` 590、`set_tool_enabled` 1059、`notify_tool_list_changed` 1109） |
| MCPTool.to_dict（outputSchema/annotations 下发点） | `addons/godot_mcp/native_mcp/mcp_types.gd:78-92` |
| 分类/分组/核心上限 | `addons/godot_mcp/native_mcp/mcp_tool_classifier.gd` |
| 预设解析 | `addons/godot_mcp/native_mcp/mcp_tool_preset_manager.gd` |
| 渐进披露 meta 工具（4 层） | `addons/godot_mcp/tools/meta_tools_native.gd`（`list_tool_catalog` 51、`search_tools` 128、`get_tool_details` 211、`enable_tools` 263） |
| schema lint 门禁（白名单/风险关键字/description 覆盖率/734 属性基线） | `test/unit/test_tool_schema_lint.gd` |
| 落盘先例（`res://.mcp/`） | `addons/godot_mcp/tools/task_plan_store.gd` |
