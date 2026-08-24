# DSH 缓存与算力优化机制研究 — 面向 Godot MCP（GDScript）的可移植设计报告

> 研究目标：DeepSeek Harness（DSH，`D:\ai\de\`，多包 TypeScript 项目）如何在上下文管理、压缩（compaction）、溢出落盘（spill）、持久化（storage/persistence）中省 token 与算力；并把这些机制中**可移植**的部分，转化为 Godot 4.x 编辑器内 MCP 服务器（GDScript）的**可操作设计建议**。
>
> 说明：DSH 是 TS 项目，本报告只解读设计意图并给出模式，不移植实现。DSH 的文档位于 `docs/subsystems/*.md`（而非任务描述中猜测的 `docs/context.md` 等——仓库实际布局以 `docs/subsystems/` 为准）。
>
> 面向读者：Godot-MCP-Native（`addons/godot_mcp/`）的维护者。所有建议都以"编辑器内 MCP 服务器 + GDScript"为约束（无 Node.js、单进程、`res://`/`user://` 文件系统、`Resource`/`Signal` 生态）。

---

## 0. 结论速览（先看这个）

| DSH 机制 | 省什么 | GDScript 移植难度 | 移植价值 | 对应章节 |
|---|---|---|---|---|
| 会话日志 = append-only 事件源 + 派生消息缓存 | 重复投影算力 | ★☆☆ | ★★★ 立即做 | §3.1 / §4.1 |
| Token 估算（chars/4）+ 用量锚定 | 估不准导致的盲目压缩 | ★☆☆ | ★★★ 立即做 | §2.4 / §4.2 |
| 工具结果剪枝（head/middle/tail） | 上下文 token | ★☆☆ | ★★★ 立即做 | §2.2 / §4.4 |
| 工具结果溢出落盘（spill） | 上下文 token | ★★☆ | ★★★ 立即做 | §2.3 / §4.5 |
| 单飞（single-flight）+ LRU 就绪池 | 重复计算/重复读盘 | ★★☆ | ★★★ 立即做 | §2.6 / §4.6 |
| 增量投影 + 持久化水位（ver/seq） | 重算/重读 | ★★☆ | ★★★ 立即做 | §2.5 / §4.7 |
| 会话压缩（compaction + 摘要） | 超窗 token（大头） | ★★★ | ★★★ 长期做 | §2.1 / §4.3 |
| 前缀缓存对齐（KV cache 复用） | 计费 token（大头） | ★★★ | ★★☆ 长期做 | §2.7 / §4.8 |
| 写批量（200ms 窗口） | 磁盘 IO | ★☆☆ | ★★☆ 可选 | §2.8 |
| 软失效 / epoch 守卫缓存 | 失效风暴 | ★★☆ | ★★☆ 可选 | §2.6 / §4.6 |

优先级建议（对 Godot MCP）：**先做 §4.1–§4.7（L0 单测可验证、无外部依赖）**，§4.8 的 KV 前缀对齐需要模型侧配合（`system` 提示词稳定 + DeepSeek 的 `prompt_cache_hit_tokens` 反馈），可作为二期。

---

## 1. DSH 缓存设计全景

DSH 的缓存**不是一个组件，而是一组分层机制**。按"数据从哪来、失效由谁驱动"划分成五类：

### 1.1 LLM 提示词缓存（provider KV cache）—— 省计费 token

这是 DSH 最大头的省钱点：**让每次请求的 prompt 前缀尽量与上一次完全一致**，命中提供商的 KV cache（DeepSeek 报告 `prompt_cache_hit_tokens`）。

- **用量回读**：`packages/llm/llm-deepseek/src/translate.ts` 的 `mapUsage()` 把 DeepSeek 的 `prompt_cache_hit_tokens`（注意：DeepSeek 的 `prompt_tokens` 已包含命中数）转换成互斥桶 `cacheReadTokens`，供 UI 与策略观察真实命中率：
  ```ts
  const cacheRead = usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens
  inputTokens: usage.prompt_tokens - (cacheRead ?? 0),
  ...cacheRead !== undefined ? { cacheReadTokens: cacheRead } : {},
  ```
  实测门禁：`packages/core/agent-loop/tests/request-cache.e2e.ts`（真 API 测试"从第二个请求起每个请求都命中前缀缓存"）。
- **请求可重建（reconstructability）**：会话把 `request/header`（call config + system prompt + tools schema）作为**日志事件**落盘（`docs/subsystems/session.md` §request/header）。每次请求的 envelope 是日志的纯函数 → 恢复/续跑时重放出**逐字节相同的** system + tools + 历史消息前缀，天然命中缓存。`request-reconstruction.spec.ts` 专门断言"resume snapshot 后保持 cache-aligned"。
- **系统提示词有序装配**：`packages/core/system-prompt` 把 system prompt 拆成**按 `order` 排序的 section**，动态值（策略、sandbox 模式、当前状态）通过 `systemPrompt.context()` 挂载，且**只追加到保留历史之后**，避免重写稳定前缀（`packages/interaction/user-approval/src/index.ts:203`："switching policy does not rewrite the stable system-prompt cache prefix"）。
- **提供商适配**：`packages/llm/llm-pi-ai/src/catalog.ts` 声明 `cacheControlFormat`、`supportsCacheControlOnTools`、`supportsLongCacheRetention`——对 Anthropic 系协议在工具定义/消息上加 `cache_control` 标记。
- **摘要请求也复用前缀**：见 §2.1 的 KV-preserving summarization。

### 1.2 会话上下文缓存（内存）—— 省重复投影算力

- **派生消息缓存**：`Session.deriveMessages()` 把"日志 → LLM 消息数组"的结果缓存（`packages/core/session/src/index.ts:701-745`）。每个 surface 节点**只投影一次**，新节点增量追加；当发生 `surfaceOp: replace`（压缩）时 `replaceGeneration` 递增，缓存整组重建：
  ```ts
  private derived: Message[] = []
  private derivedNodes = 0
  private derivedGeneration = 0
  deriveMessages(): Message[] {
    const generation = surface.replaceGeneration
    if (generation !== this.derivedGeneration) { this.derived = []; this.derivedNodes = 0; ... }
    for (const seq of nodes.slice(this.derivedNodes)) { ... append projection ... }
  }
  ```
  关键细节：投影结果**复用日志里已 deep-freeze 的事件数据**（零拷贝、无二次克隆），返回新数组但共享消息对象。
- **增量折叠**：`requestHeader()` / `requestContext()` 各维护一个 `*FoldSeq` 游标，"只折叠新事件"（`index.ts:657-699`）。
- **Token 计量器增量重放**：见 §2.4。
- **events 快照**：`events` getter 缓存不可变数组，append 时才置空（`index.ts:550-562`）。

### 1.3 磁盘/持久化缓存（跨进程、跨重启）

- **准备会话 LRU 池**：`packages/session/session-persistence/src/preparations.ts` 的 `SessionPreparations`：
  - **单飞冷读**：同一 session id 的并发 `inspect()` 共享一个 in-flight `Promise`（`entryFor` 只启动一次 load）；
  - **就绪条目 LRU**：`capacity`（默认 5，`coordinator.ts:27`）上限，`touch()` 在 Map 里 erase+set 实现 MRU 序，超容时逐出最旧的 ready 条目；
  - **显式失效**：`invalidate(id)` 在持久化日志变更后丢弃条目——**缓存永远从属于日志修订**。
- **投影检查点持久化**：`packages/session/session-projection-cache/src/spec.ts`——按 session 存 `{key → {ver, seq, val}}`，`seq` 是日志水位、"一行记录永远不会错，只是可能过期"，`ver` 不匹配直接丢弃。**这是"增量投影 + 持久化水位"的教科书实现**。
- **派生只读模型**：`packages/session-query/session-query-sqlite` 把会话日志投影成 SQLite FTS 全文索引（`schema.ts`，版本不匹配就地 reset），日志变更时增量喂入。
- **溢出文件**：spill（§2.3）与附件图片变体缓存（§1.5）。

### 1.4 工具结果缓存（短期、进程内）

- **Web fetch 渲染备忘录**：`packages/web/tool-web/src/fetch.ts:284-300`，`WeakMap<result, Map<maxOutputChars, RenderedFetch>>`——同一个冻结结果的 HTML→markdown 转换只跑一次（工具注册表会调两次：`render` + `presentationMeta`）。GC 自动回收。
- **命令目录缓存**：`packages/client/ui-commands/src/client/directory.ts`（§2.6 详述）。
- **图片变体确定性缓存**：`packages/attachment/attachment-local/src/request-image.ts` 的 `requestImageVariantId()` = `sha256(transformVersion + attachmentId + 路由像素预算 + 字节预算 + 编码参数)`——**key 由全部变换输入确定性导出**，同一张图同策略只转码一次，落盘复用。`DEFAULT_IMAGE_COMPRESSION_CONCURRENCY = 2` 限制并发转码。

### 1.5 配置/解析缓存（一次性、进程级）

- `packages/settings/settings/src/index.ts:839`（attach/detach/commit 后作废的 memoized resolutions）；
- `packages/typert/generator/src/analyzer.ts:196`（memoized parse result）；
- `packages/identity/anonymous-user-id`（按文件路径 memoize，进程生命周期）；
- `packages/client/modules` 的 `loadCache`（模块只物化一次）；
- `packages/llm/llm-pi-ai/src/index.ts:144`（按原始配置 memoize 的 profile 解析）。

**小结**：DSH 的缓存铁律是 —— *缓存 key 必须能穷举所有影响输出的输入，失效必须由"底层修订"驱动而非 TTL 猜测*。TTL 在 DSH 里几乎不出现（搜索 `ttl` 基本无命中），取而代之的是 **revision / generation / seq 水位 / epoch**。这是本报告移植时的第一设计原则。

---

## 2. 算力 / token 优化清单（机制 → 目的 → 实现要点）

### 2.1 Compaction（会话压缩）—— 超窗时把旧历史压成摘要

**目的**：会话逼近模型 context window 时，把一段旧 surface 压缩成一个 checkpoint 摘要节点，释放上下文。

**策略参数**（`packages/compaction/compaction-basic/src/config.ts` + `types.ts`）：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `thresholdRatio` | `0.8` | 请求+响应压力 ≥ 窗口 80% 才触发 |
| `retainRatio` | `0.16` | 压缩后保留窗口 16% 的"原样尾部" |
| `maxTokens` | `8192` | 摘要生成上限 |
| `compactionRetries` | `1` | 压力仍超阈值时的额外尝试次数 |
| `maxOverflowRetries` | `1` | provider 确认 context-overflow 后的恢复重试上限 |
| `auto` | `true` | 自动挂 `agent/pre-step`（压力触发）与 `agent/request-error`（溢出恢复） |

**触发流**（`index.ts:258-332` `compactIfNeeded`）：
1. 用 token-meter 测当前压力；
2. `context-overflow` 直接强制压；`pressure` 需 `totalTokens ≥ thresholdTokens`；
3. 若装了剪枝器，先跑**模型无关剪枝**（§2.2）再复测——剪枝可能已把压力压回阈值下，省掉一次 LLM 摘要调用；
4. 选段（§2.1.1）→ 调 LLM 摘要 → 把摘要作为 `user/message` 用 `surfaceOp: {op:'replace', start, end}` 换掉旧段（`region.ts:462-465`，`commitCompactionBody`）；
5. 摘要必须**更小**才算成功：`framedSummaryTokenCount < shadowedTokenCount`（`region.ts:374`），否则整体失败。

**2.1.1 选段规则**（`region.ts:98-134` `selectCompactableRange`）——这是可移植性最高的部分：
```ts
// 1) 从尾部向前累加 token，直到 >= retainTokens，记 keepFromIdx
// 2) 若 keepFromIdx 处的边界会"劈开"一个 assistant 工具调用/结果对，就继续前移
// 3) 压缩 [surface[0], surface[keepFromIdx-1]]
```
即：**头锚定、保留 priced 尾部、绝不断开 tool-call/tool-result 配对**。

**2.1.2 KV-preserving 摘要**（`summarizer.ts:31-66, 121-182`）：
- 摘要请求的 body = **会话自己的 system prompt + tools + 被压缩段的消息**（`buildSummarizationInput`，`region.ts:498-514`），**再加一条最终 user 指令**（`COMPACTION_INSTRUCTION`，一个固定 Markdown 骨架：Primary Request / Files and Code / Errors and Fixes / Pending Jobs / Current Work / Next Step / Critical Context...）；
- 这样摘要调用是"上次请求的真前缀"，**复用 provider 的 KV cache**，而不是另起炉灶废掉缓存；
- 落地的 checkpoint 用 `compactCheckpointSource(compactionId)` 标记来源，`<compacted-summary>` 标签包裹，并附 preamble 告诉模型"这是既有背景，直接继续"（`frameSummary`，`summarizer.ts:189-195`）。

**2.1.3 事务与崩溃安全**（`region.ts:152-254`）：
- `compaction/start` → 摘要 → `compaction/summary`（含 shadowedSeqs/TokenCount）→ 替换节点 → `compaction/end`，**锁在 start 时持久化**；崩溃留下未闭合的 start 可被检测（孤儿锁），而不是假成功；
- 摘要期间 surface 被改动 → `SurfaceChangedError`（whole-surface 或 selected-span 两种稳定性检查）。

### 2.2 工具结果剪枝（model-free pruning）—— 确定性删中段

**目的**：不改语义也要先砍掉超长工具结果的"中段"，把压力压回阈值下，避免立刻触发 LLM 摘要。

**默认预算**（`packages/compaction/compaction-tool-result-pruner/src/config.ts`）：
```ts
thresholdChars: 8192,   // 超过 8192 个 Unicode 码点才剪
headChars:     4096,    // 保留前 4096
tailChars:     1024,    // 保留后 1024
PRUNE_MARKER = '\n\n[... tool result middle pruned ...]\n\n'
```
- **按 Unicode 码点切片**（`codePointLength = Array.from(text).length`），不劈断 surrogate pair；
- 保留非 text 块（如图片）的顺序，只剪 text 中段；
- 替换也走 surface `replace`，且**紧邻之前追加一个 `compaction/prune` 影子价事件**（记录 `shadowedTokenCount`），让纯消费者无需逐节点状态即可做减法（`index.ts:159-173`）；
- 断言 `charsAfter < charsBefore` 且 `charsAfter ≤ thresholdChars`（`index.ts:118`），**替换必须更小**。

### 2.3 溢出落盘（Spill）—— 超预算结果移到文件里，上下文只留预览 + 定位

**目的**：一个工具结果大到不适合放回上下文时，把全文写进 session 私有文件，模型端只见**有界预览 + 文件路径 + 取回指引**。

- **触发**：`tools/post-execute` 结果（纯文本、UTF-8 字节数）> `maxInlineBytes`（`packages/spill/spill-policy/src/index.ts`）。
- **替换文本** = `head 预算/2 + tail 预算/2` 的 headTail 预览 + 空行 + notice：`(Omitted N bytes. Full formatted result stored at: <locator>. <retrievalHint>)`。
  - 关键细节：**notice 的字节数先从预算里预留**（`index.ts:171-172`），保证替换后总字节 ≤ cap；
  - `TextRetainer`（`packages/util/output-retention/src/index.ts`）负责 head/tail 截断，**切在 UTF-8 边界上**（`trimTrailingPartialUtf8`/`trimLeadingContinuationUtf8`），内存有界（最多 `prefixCap + suffixCap + 一块`）。
- **Best-effort 原则**：没有 session、没有 spill 后端、或写盘失败 → **保持原文**，绝不把成功调用变成 `isError`（`index.ts:33-35, 154-161`）。
- **防读循环**：模型端 `read` 工具的调用跳过 spill（避免 `read → spill → read 再读` 死循环）；但日志副本仍被 bound（UI/重放从 spill 文件取全文）。
- **存储**（`packages/spill/spill-local/src/store.ts`）：`<root>/session-<sha256(sessionId)[0:12]>/<6字节随机hex>-<sanitizedName>`，`open('wx', 0o600)` 独占防 symlink 劫持；root 是 0700 的 lazily-created 临时目录。
- **可观测性**：spill 请求记录 `source.toolName/callId`（仅描述，不做访问控制）。

### 2.4 Token 计量（token-meter）—— 便宜且够准的估算 + 用量锚定

**目的**：给"该不该压缩"一个**不用真 tokenizer** 的压力读数，并尽量用 provider 的真实 usage 校准。

**固定启发式**（`packages/llm/token-meter/src/estimate.ts`）：
```ts
CHARS_PER_TOKEN = 4      // 每 4 字符 ≈ 1 token
BLOCK_OVERHEAD  = 4      // 每块的 JSON 框架开销
ROLE_OVERHEAD   = 4      // 每条消息的 role 框架开销
```
逐块递归计价：text/reasoning = `ceil(len/4)+4`；tool-call = name+arguments 分别计价 +4；tool-result 递归 +4；未知块保守地按 `JSON.stringify` 计价。

**增量重放**（`packages/llm/token-meter/src/index.ts:159-181`）：每个 session 一个 `ReplayState`（WeakMap），持 `consumedEvents` 游标，`measure()` 只折叠新事件；surface 增删通过 `foldSurfaceTokens` 增量维护。

**用量锚定**（`index.ts:221-261`）：`assistant/message` 携带 provider usage 时，若该次请求的 canonical envelope 与当前 header 相同且 provider 总数 ≥ 启发式锚，则 `baseline = usage`，之后只按**增量**估算：`totalTokens = baseline.tokens + surfaceDeltaTokens`（`surfaceDeltaTokens = 当前surface启发式 - 锚定时刻surface启发式`）。即 **"provider 报多少就用多少，增量才用启发式"**——压缩一发生（无自身 usage），投影立刻反映收缩。

**输出**（`projection.ts`）：互斥桶 `uncachedInputTokens / cacheReadTokens / cacheWriteTokens / outputTokens` + `ContextPressureProjection{pressureTokens, projectedTokens, contextWindow}`。

### 2.5 增量投影与持久化水位

**目的**：任何"从日志派生"的模型（UI 投影、全文索引、token 计数）都只消费新事件。

- 内存版：`*FoldSeq` 游标（§1.2）；
- 持久化版：`session-projection-cache` 的 `{ver, seq, val}` 行（§1.3）——`seq` 即日志水位，读取时 `seq` 落后就只补折尾部；`ver` 不匹配整行丢弃（缓存语义：stale 缓存只带来更长的尾部重放，**绝不带来错误值**）；
- 配套原语：`SessionPersistence.readFrom(id, fromSeq)`——SQLite 后端按 seq 只读后缀（`docs/subsystems/persistence.md` §readFrom）。

### 2.6 单飞 + LRU 就绪池 + 软失效（命令目录缓存）

**目的**：一个"远端/昂贵快照"（命令目录、会话历史）被多处同时需要时：
- **单飞**：并发请求共享同一个 in-flight 拉取；
- **软失效**：失效通知只触发后台重拉，旧快照继续服务（stale-while-revalidate）；
- **epoch 守卫**：只有最新一轮拉取可以发布结果（旧拉取晚到直接丢弃）；
- **强等待**：需要"必须就绪"的调用方 join 在飞请求上；
- **预取**：作用域诞生时 `warm()`。

`packages/client/ui-commands/src/client/directory.ts` 状态机：`cold / pending / ready / failed`，`Entry.epoch` 每次拉取自增，发布前比对。DSH 的 session-persistence 冷读（§1.3）同属此模式（single-flight + LRU + invalidate）。

### 2.7 前缀缓存对齐（贯穿性设计约束）

不是单独组件，而是**贯穿 system prompt 装配、请求重建、摘要调用、恢复续跑**的约束：任何"会进入 prompt 的内容"都尽量只增不改、保持顺序稳定；动态值放尾部或走运行时快照。这样：
- 普通多轮请求命中前缀缓存（大头省钱）；
- 压缩摘要调用也命中（`summarizer.ts` 注释明说"reuses the provider's warm prefix cache"）；
- 崩溃恢复/续跑重放出相同前缀。

### 2.8 写批量（持久化 IO 优化）

`packages/session/session-persistence/src/coordinator.ts`：`DEFAULT_WRITE_BATCH_MAX_DELAY_MS = 200` —— 首个待写事件启动 200ms 固定窗口，窗口内事件合并成一个 batch，`session/flush` 可立即排空。事件进日志（内存）**不阻塞**，持久化异步批量落盘。

### 2.9 其他

- **惰性物化**：`create()` 只登记元数据，首个 append 才写盘（`persistence.md`），废弃会话零残留；
- **压缩后保留"未发布就绪条目"复用**：同一 Session 的 inspect/prepare 共享一次读盘+解压+校验+冻结（`persistence.md` §inspect，LRU 容量 5）；
- **`ignorable` 未知事件跳过标记**：未知但纯信息的事件可以安全跳过（`persistence-catalog.md` §envelope），防止旧版本读取新日志时整体拒绝。

---

## 3. DSH 关键文件索引（引用速查）

| 主题 | 文件 |
|---|---|
| 会话事件模型 / 派生缓存 / surface replace | `packages/core/session/src/index.ts`（701-745 deriveMessages 缓存；657-699 fold 游标） |
| Token 估算启发式 | `packages/llm/token-meter/src/estimate.ts` |
| Token 计量增量重放 + 用量锚 | `packages/llm/token-meter/src/index.ts` |
| 压缩策略配置 | `packages/compaction/compaction-basic/src/config.ts` |
| 压缩触发流 | `packages/compaction/compaction-basic/src/index.ts` |
| 压缩选段 / 事务 / KV 前缀重建 | `packages/compaction/compaction-basic/src/region.ts` |
| 压缩摘要指令 / 前缀复用 | `packages/compaction/compaction-basic/src/summarizer.ts` |
| 工具结果剪枝 | `packages/compaction/compaction-tool-result-pruner/src/{config,index}.ts` |
| 溢出落盘策略 | `packages/spill/spill-policy/src/index.ts` |
| 溢出存储（私有文件） | `packages/spill/spill-local/src/store.ts` |
| head/tail 保留器（UTF-8 安全） | `packages/util/output-retention/src/index.ts` |
| 持久化 LRU + 单飞 + 失效 | `packages/session/session-persistence/src/preparations.ts`（容量默认在 `coordinator.ts:27`） |
| 投影检查点持久化水位 | `packages/session/session-projection-cache/src/spec.ts` |
| 命令目录缓存状态机 | `packages/client/ui-commands/src/client/directory.ts` |
| 图片变体确定性缓存 key | `packages/attachment/attachment-local/src/request-image.ts`（`requestImageVariantId`） |
| DeepSeek prompt-cache 用量映射 | `packages/llm/llm-deepseek/src/translate.ts`（`mapUsage`） |
| 提供商 cache_control 能力 | `packages/llm/llm-pi-ai/src/catalog.ts` |
| 系统提示词有序装配 | `packages/core/system-prompt/src/index.ts` |
| 真 API 缓存命中门禁 | `packages/core/agent-loop/tests/request-cache.e2e.ts` |
| 文档：各子系统 | `docs/subsystems/{session,compaction,spill,storage,persistence,token-meter,session-query,system-prompt}.md` |
| 文档：持久化事件目录 | `docs/persistence-catalog.md` |

---

## 4. 可移植设计模式（Godot MCP / GDScript 落地）

以下每条都给出：**做什么 → key/容量/TTL/失效怎么定 → GDScript 注意点 → 与 Godot-MCP 现有模块的接缝**。

### 4.1 会话日志 = append-only 事件源 + 派生消息增量缓存

**做什么**：把"模型可见历史"与"原始事件"分开。MCP 会话中每次工具调用的结果、每次 assistant 消息都作为**不可变事件**追加到会话日志；"发给模型的 messages 数组"从日志派生并缓存。

**GDScript 设计**：
```gdscript
# session_log.gd —— 事件源（append-only）
const SurfaceOp := {"APPEND": 0, "REPLACE": 1}
var _events: Array[Dictionary] = []        # {type, seq, time, data, surface_op?, source_seqs?}
var _events_snapshot: Array = []           # 缓存不可变快照，append 时置空
var _surface: Array[int] = []              # 模型可见节点 seq 列表
var _replace_generation := 0               # 每次 REPLACE 递增

# 派生消息缓存（同 DSH deriveMessages）
var _derived: Array[Dictionary] = []
var _derived_nodes := 0
var _derived_generation := 0

func derive_messages() -> Array[Dictionary]:
    if _replace_generation != _derived_generation:
        _derived.clear()
        _derived_nodes = 0
        _derived_generation = _replace_generation
    for i in range(_derived_nodes, _surface.size()):
        var seq: int = _surface[i]
        var msg: Dictionary = _project_event(_events[seq])   # 纯函数：事件 → 消息
        _derived.append(msg)
        _derived_nodes = i + 1
    return _derived.duplicate()            # 返回新数组（浅拷贝即可，消息对象只读）
```

**要点**：
- 投影是**纯函数**：`event → message | null`（非 surface 事件返回 null 跳过），与 DSH 的 `deriveEventMessage` 对应。
- 事件数据在 append 时做一次**深拷贝 + 只读化**（GDScript 无 freeze，用"约定只读 + 内部拷贝"即可），避免调用方改坏日志。
- **失效由日志修订驱动，不用 TTL**：`_replace_generation`（压缩）或日志长度变化即重建对应缓存。
- 对 Godot MCP 的接缝：`mcp_server_core.gd` 目前直接转发工具结果；改为"工具结果 → `tool/result` 事件 → `mcp_server_core` 维护 surface → 请求模型时 `derive_messages()`"。`mcp_tool_classifier.gd`/`enable_tools` 的懒加载目录可继续独立。

### 4.2 Token 估算器 + 用量锚定（压力门禁）

**做什么**：在**不做真实 tokenize** 的前提下，估算"当前会话发给模型要花多少 token"，并优先采用 provider 返回的真实 usage。

**GDScript 设计**：
```gdscript
const CHARS_PER_TOKEN := 4
const BLOCK_OVERHEAD := 4
const ROLE_OVERHEAD := 4

func estimate_message(msg: Dictionary) -> int:   # 递归计价 content blocks
    return _estimate_blocks(msg.get("content", [])) + ROLE_OVERHEAD

func _estimate_blocks(blocks: Array) -> int:
    var t := 0
    for b in blocks:
        match b.get("type"):
            "text", "reasoning":
                t += ceili(str(b.get("text", "")).length() / float(CHARS_PER_TOKEN)) + BLOCK_OVERHEAD
            "tool-call":
                t += ceili(str(b.get("name", "")).length() / float(CHARS_PER_TOKEN)) \
                   + ceili(str(b.get("arguments", "")).length() / float(CHARS_PER_TOKEN)) + BLOCK_OVERHEAD
            "tool-result":
                t += _estimate_blocks(b.get("content", [])) + BLOCK_OVERHEAD
            _:
                t += BLOCK_OVERHEAD + ceili(JSON.stringify(b).length() / float(CHARS_PER_TOKEN))
    return t
```

**用量锚定**（关键设计）：保存"上一次 provider 报的 usage"与"当时 surface 的启发式总数"。下一次估测：
```
若 最新请求 envelope 与当前相同 且 provider_total >= 当时启发式锚:
    total = provider_total + (当前 surface 启发式 - 锚定 surface 启发式)
否则:
    total = 完整启发式重估
```
- 注：`str.length()` 在 Godot 4 返回 Unicode 码点个数，天然满足"不劈 surrogate"要求；GDScript `String` 内部是 UTF-32。
- 对 Godot MCP 的接缝：新增 `utils/token_estimator.gd`；`debug_tools` 的 `assert_performance_budget` 可扩展一个 `assert_context_budget`；压力读数用于 §4.3 的门禁。

### 4.3 会话压缩（compaction）—— 超窗时压缩旧段

**做什么**：当 §4.2 的压力 ≥ 0.8 × 模型窗口时，把一段旧 surface 换成一段"摘要 checkpoint"（由 LLM 生成，或**先剪后压**），保留尾部 0.16 × 窗口的原样内容。

**GDScript 设计**：
```gdscript
const THRESHOLD_RATIO := 0.8
const RETAIN_RATIO := 0.16
const SUMMARY_MAX_TOKENS := 8192

# 选段：尾向前累加 token 到 >= retain_tokens；边界不得劈开 tool-call/tool-result 对
func select_compactable_range(surface: Array[int], priced: Dictionary, retain_tokens: int) -> Dictionary:
    var acc := 0
    var keep_from := priced.size()
    for i in range(priced.size() - 1, -1, -1):
        acc += priced[surface[i]].tokens
        keep_from = i
        if acc >= retain_tokens: break
    if keep_from == 0: return {}
    while keep_from > 0 and not _tool_pairing_balanced_before(surface[keep_from]):
        keep_from -= 1
    if keep_from == 0: return {}
    return {"start": surface[0], "end": surface[keep_from - 1]}
```

**执行事务**（仿 DSH 的 start→summary→replace→end）：
1. 写入 `compaction/start` 事件（即"压缩锁"）；
2. 先跑 §4.4 剪枝，重测压力，可能已达标则放弃 LLM 摘要；
3. 仍超标 → 组摘要请求：`[被压缩段消息...] + 固定压缩指令`（复用会话的 system prompt/tools 前缀，见 §4.8）；
4. 校验 `摘要启发式 < 被压段启发式`，否则失败；
5. 用 `surfaceOp REPLACE` 落地摘要节点 + `compaction/summary`（记录 shadowedSeqs/TokenCount）+ `compaction/end`；失败也写 `compaction/end(error)`，未闭合的 start 视为孤儿锁。
6. **摘要必须更小**（`if framed >= shadowed: fail`）——这条能防止压缩反而膨胀。

**对 Godot MCP 的接缝**：Godot 无 provider context window 的通用注册表；建议做成可配置 `mcp_context_budget`（默认 128k/256k），在 `mcp_server_core.gd` 的请求前钩子触发。摘要指令可直接复用 DSH 的 Markdown 骨架（Primary Request / Files and Code / Errors and Fixes / Pending Jobs / Current Work / Next Step / Critical Context），翻译成中英双语模板放入 `translations/`。

### 4.4 工具结果剪枝（head/middle/tail）—— 零模型成本降压力

**做什么**：对超过阈值的纯文本工具结果，确定性替换为 `head + marker + tail`。

**GDScript 设计**（默认预算抄 DSH：`threshold=8192` 字符，`head=4096`，`tail=1024`）：
```gdscript
const PRUNE_MARKER := "\n\n[... tool result middle pruned ...]\n\n"
const PRUNE_THRESHOLD_CHARS := 8192
const PRUNE_HEAD_CHARS := 4096
const PRUNE_TAIL_CHARS := 1024

func prune_text(text: String) -> String:          # 返回剪后文本；未超阈值返回原样
    var n := text.length()                        # Godot 4: Unicode 码点数
    if n <= PRUNE_THRESHOLD_CHARS: return text
    var head: String = text.substr(0, PRUNE_HEAD_CHARS)
    var tail: String = text.substr(n - PRUNE_TAIL_CHARS, PRUNE_TAIL_CHARS)
    var out := head + PRUNE_MARKER + tail
    return out if out.length() < n else text      # 必须更小，否则保留原文
```

**要点**：
- 剪枝是对**每个超限工具结果**就地执行（结果仍保留在原消息位置，配对其 tool-call 不受影响）；
- 在 GDScript 里 `String.substr()` 按码点切分，天然安全；
- 可把 `PRUNE_*` 做成 `ProjectSettings` 配置（`mcp_server_native.gd` 读取）；
- 建议同 DSH：剪枝替换紧邻追加一个 `compaction/prune` 日志事件记录"影子价"，便于 UI 累计节省。

### 4.5 溢出落盘（spill）—— 超大结果出上下文

**做什么**：结果超过内联预算（如 `max_inline_bytes = 16_384` 字节）时，全文写 `user://mcp/spill/session-<hash>/`，模型端只看到 `headTail 预览 + (Omitted N bytes. Full result at: <path>. 用 read_file 读取)`。

**GDScript 设计要点**：
```gdscript
const SPILL_ROOT := "user://mcp/spill"
const MAX_INLINE_BYTES := 16384

func maybe_spill(session_id: String, tool_name: String, text: String) -> String:
    var bytes := text.to_utf8_buffer().size()
    if bytes <= MAX_INLINE_BYTES: return text
    var dir := SPILL_ROOT.path_join("session-" + session_id.sha256_text().substr(0, 12))
    DirAccess.make_dir_recursive_absolute(dir)
    var path := dir.path_join("%s-%s.txt" % [randi(), tool_name.get_file().to_snake_case()])
    FileAccess.open(path, FileAccess.WRITE).store_string(text)   # 写失败 → 返回原文
    var notice := "(Omitted %d bytes. Full result stored at: %s. 用 read_file 工具读取。)" % [bytes, path]
    var half := maxi(0, (MAX_INLINE_BYTES - notice.to_utf8_buffer().size() - 2) / 2)
    return text.substr(0, half) + "\n\n" + notice + (text.substr(-half) if half > 0 else "")
```
- **best-effort 铁律**：写盘失败/无会话归属 → 保留原文，**绝不把成功调用变 error**（DSH `spill-policy` 明确如此）；
- **notice 字节先预留**，替换总长 ≤ cap；
- **防读循环**：对 `read_file`（或等价"读文件"工具）的输出跳过 spill；
- 清理策略：按 session 目录整体回收（DSH 的 spill seam 本身不定义清理策略，由宿主做 retention）。

### 4.6 工具结果缓存：确定性 key + 单飞 + 事件驱动失效（不用 TTL）

**做什么**：对**计算昂贵且可复现**的工具结果做进程内缓存：符号索引、场景审计、批量脚本编译校验、依赖扫描、`list_tool_catalog` 等。

**key 设计（抄 DSH 图片变体 key 的确定性原则）**：
```
cache_key = sha256( JSON( [
    tool_name,
    规范化后的参数（键排序、去空格、浮点归一化）,   # canonical args
    transform_version,      # 工具/算法版本，改算法必升
    project_state_fingerprint,   # 依赖的项目状态（见失效联动）
] ) )
```

**容量与失效（抄 CommandDirectory / SessionPreparations）**：
- `Dictionary` 即 LRU 容器：命中时 `erase(key); set(key, val)` 挪到尾部（MRU），超 `capacity`（如 64 条）时逐出首个条目；
- **失效联动（关键，替代 TTL）**：
  - 文件/资源类结果：监听 `ResourceLoader` 的 `resource_changed`、`EditorFileSystem.filesystem_changed`，对**涉及路径前缀**的 key 作废；
  - 场景/节点类结果：监听 `EditorNode.get_singleton().get_undo_redo().version_changed` 与 `SceneTree` 变更；
  - 项目设置类：`ProjectSettings.settings_changed`；
  - 无可靠事件时，用**软失效**：命中后标记"stale pending"，后台重算，旧值继续服务（GDScript 里可简单实现为 `await` 重算后替换）；
  - **epoch 守卫**：重算请求自增 epoch，只有最新一轮能发布结果，晚到的丢弃；
- **单飞**：同 key 的并发请求共享同一个进行中的计算（`Dictionary[key]` 存 `{done, value}` 或直接存进行中的协程信号）；
- **体积控制**：缓存条目按"产出字节"计费，超预算的条目不入缓存（或只缓存摘要级结果）。

### 4.7 增量投影 + 持久化水位（ver/seq checkpoint）

**做什么**：任何"从项目状态/日志派生的重模型"（符号索引、场景结构缓存、工具目录投影）都存 `{ver, seq/watermark, value}`，重建时只重放水位之后的部分。

**GDScript 设计**：
```gdscript
# 落盘到 user://mcp/projcache/<domain>.json
func load_checkpoint(domain: String, ver: int) -> Dictionary:
    var f := FileAccess.open(CP_ROOT.path_join(domain + ".json"), FileAccess.READ)
    if f == null: return {}
    var rec: Dictionary = JSON.parse_string(f.get_as_text())
    if rec.get("ver") != ver: return {}          # 版本不匹配 → 整组丢弃（绝不迁移）
    return rec                                    # {ver, seq, rows: {key: {seq, val}}}

func save_checkpoint(domain: String, rec: Dictionary) -> void:   # 原子替换
    var tmp := CP_ROOT.path_join(domain + ".tmp")
    FileAccess.open(tmp, FileAccess.WRITE).store_string(JSON.stringify(rec))
    DirAccess.rename_absolute(tmp, CP_ROOT.path_join(domain + ".json"))
```
- **语义**：stale 缓存只带来更长的尾部重放，**绝不带来错误值**；
- 事件源（§4.1）的每个 append 递增 `seq`，投影模型记录自己消费到的 `seq`；
- Godot 侧天然对应：`EditorFileSystem.get_filesystem()` 的扫描结果、`manage_task_plan` 的任务图（可加 `rev` 字段做乐观并发）。

### 4.8 前缀缓存对齐（KV cache 复用）—— 结构性省钱

**做什么**：让"发给模型的消息数组"在**多轮之间只增不改、前缀字节相同**，从而命中 DeepSeek 等提供商的 prefix cache（`prompt_cache_hit_tokens > 0`）。

**GDScript 落地清单**：
1. **system prompt 有序装配**：把 system prompt 拆成按 `order` 排序的 section（`tools:xxx`、`policy:xxx`、`context:xxx`），动态值只通过"运行时快照/追加到尾部"呈现，**不要重写已发送过的前缀**（抄 `user-approval` 的注释原则）；
2. **请求可重建**：把"本次请求的 system + tools schema + 消息列表"作为可重建状态保存；恢复/续跑时重放出相同前缀；
3. **摘要调用复用前缀**：§4.3 的摘要请求 = 会话自己的 system/tools + 被压段消息 + 固定指令（唯一新增部分），保证压缩这一"额外调用"也命中缓存；
4. **反馈回路**：解析 DeepSeek 响应的 `prompt_cache_hit_tokens`（`mapUsage` 语义：`prompt_tokens` 已含命中，需减去），记录到会话日志事件，面板显示"本次命中 X token / 缓存率"，驱动持续优化。

**注意**：此项收益取决于 provider（DeepSeek 按 64 token 块粒度缓存、约 5 分钟 TTL 的自动前缀缓存），且要求消息序列稳定；若模型客户端（如 Claude Desktop 经 stdio）会篡改/重排消息，则收益打折——所以列为二期。

### 4.9 写批量 + 单飞（IO/算力卫生）

- **写批量**：多个工具结果/日志事件在 200ms 窗口内合并写盘（`mcp_server_core` 维护一个 flush 定时器 + `flush()` 屏障）；MCP 的 `resources/list_changed` 等通知可批量发送；
- **惰性物化**：会话元数据先登记，首个事件才建文件；
- **GC 友好的缓存**：GDScript 无 WeakRef 自动回收容器，但 `WeakRef` 可手动清理；大对象缓存（如截图）显式设容量上限。

---

## 5. 建议的落地顺序（针对 Godot-MCP-Native 现状）

> 参考 AGENTS.md：221 个工具、`mcp_server_core.gd` 中枢、`tool_state_manager.gd` 已管状态。以下顺序以"每步可独立验证（L0 导入门禁 + GUT 单测）"为准。

1. **M1（立即）**：`utils/token_estimator.gd`（§4.2）+ `utils/result_cache.gd`（§4.6：确定性 key、LRU、单飞、事件失效、体积上限）。单测覆盖 key 规范化（参数顺序/浮点/空值）、LRU 逐出、软失效。
2. **M2（立即）**：`utils/result_trimmer.gd`（§4.4 剪枝）+ `utils/spill_store.gd`（§4.5 溢出落盘），挂到 `mcp_server_core` 的 `tools/post-execute` 等价钩子上；`max_inline_bytes`/`prune_*` 进 `ProjectSettings`。
3. **M3（一周内）**：会话日志化改造（§4.1）：`session_log.gd` + `derive_messages()` 缓存 + `surface replace`；`tool_state_manager.gd` 保留现有职责，日志只做派生源。回归门禁：全量 GUT。
4. **M4（两周内）**：压力门禁 + 剪枝先行压缩（§4.3 的无摘要半程）：`select_compactable_range` + 事务事件 + 孤儿锁检测；摘要 LLM 调用接到 `mcp_http_server` 的 provider 通道（或现有外部 API 适配）。
5. **M5（二期）**：前缀缓存对齐（§4.8）：system prompt section 化、请求可重建、`prompt_cache_hit_tokens` 反馈面板。
6. **M6（可选）**：增量投影 checkpoint（§4.7）用于符号索引/场景审计类工具；写批量（§4.9）。

---

## 6. 关键设计原则总结（给 GDScript 实现者的 TL;DR）

1. **缓存 key 必须确定性覆盖全部输入**，含一个 `transform_version`（算法升级即失效）；sha256(规范化输入) 是最便宜的防错手段。
2. **失效用修订/水位驱动，不用 TTL**：日志 seq、`replace_generation`、文件系统变更信号、undo/redo 版本。缓存语义永远是"stale 只能慢，不能错"。
3. **任何"替换/压缩"都必须更小才落地**：`新启发式 ≥ 旧启发式 → 拒绝`（防膨胀）。
4. **剪枝/溢出是压缩的免费前置**：先模型无关地砍体积，能省掉一次 LLM 调用就别调。
5. **best-effort 铁律**：缓存/落盘失败 → 走原始路径，绝不把成功变失败。
6. **前缀稳定 = 结构性省钱**：凡进入 prompt 的内容只增不改、顺序稳定；动态值放尾部。
7. **单飞 + epoch 守卫**：昂贵结果并发请求共享一次计算，晚到的旧结果丢弃。
8. **估算优先、锚定校准**：`chars/4` 启发式决定"要不要压缩"，provider 真实 usage 决定"到底多少"。

---

*本报告基于 DSH 仓库（D:\ai\de\）源码与 `docs/subsystems/*.md` 文档研究而成；所有引用的文件路径/默认值均可在对应文件中复核。*
