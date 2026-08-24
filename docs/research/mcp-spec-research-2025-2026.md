# MCP 规范最新进展研究报告（2025-11 → 2026）

> 用途：指导 Godot-MCP 插件（纯 GDScript、215 工具）的协议合规与工具组织优化。
> 资料收集时间：2026 年；主要依据 modelcontextprotocol.io 官方文档与 specification GitHub 仓库。

---

## 0. 执行摘要（TL;DR）

1. **规范已迭代到 `2026-07-28`（draft）**，比广泛使用的 `2025-11-25` 更新一代。核心变化是 **stateless MCP**（去掉 session、去掉 `initialize` 握手）、**`server/discover`**、**MRTR 多轮请求模式**、**Tasks 扩展**、**Roots/Sampling/Logging 三功能正式进入 Deprecated**、**HTTP+SSE 传输正式废弃**、**列表结果要求 `ttlMs`/`cacheScope` 缓存提示**。
2. **2025-11-25 版的增量**：elicitation 增加 URL mode、任务（tasks）实验性引入、工具命名规范（SEP-986）、JSON Schema 2020-12 定为默认方言、输入校验错误应作为 Tool Execution Error 返回（让模型自纠）、OIDC Discovery、图标元数据、增量 scope consent 等。
3. **对 215 个工具规模，官方给出的答案**：客户端侧 "progressive discovery"（渐进发现：`search_tools` 元工具 → `get_tool_details` → 执行，三层模式），服务端侧配套的**目录（catalog）元工具**。Godot 插件已有的 `list_tool_catalog` + `enable_tools` 与官方模式高度吻合，可据此强化。
4. **工具 schema 是 LLM 上下文的大头**：官方建议工具定义合计超过上下文窗口 1%–5% 时就必须做渐进发现；`tools/list` 要**确定性排序**（利于 prompt cache 命中）；结果提供 `outputSchema` + `structuredContent` 以支持客户端代码模式（programmatic tool calling）。
5. **客户端生态分化明显**：VS Code/Copilot、Cursor、Claude Code 对 elicitation/资源/prompts 支持较全；Sampling 支持面窄且已官方弃用；OAuth 是远程服务器的事，本地 stdio/Bearer token 场景无需。

---

## 1. 规范版本时间线与关键变化

| 版本 | 日期 | 定位 | 关键内容 |
|---|---|---|---|
| `2024-11-25` | 2024-11-25 | 1.0 首发 | tools / resources / prompts / roots / sampling / logging / completion / pagination / stdio + HTTP+SSE |
| `2025-03-26` | 2025-03-26 | 修订 | tool annotations、elicitation（form 模式）、progress、cancellation、HTTP+SSE 首次标记软弃用 |
| `2025-06-18` | 2025-06-18 | 修订 | **Streamable HTTP 取代 HTTP+SSE**、**OAuth 2.0（DCR）**、roots URI templates、content 类型细化（audio/embedded resource 等） |
| `2025-11-25` | 2025-11-25 | 修订 | **elicitation URL mode、experimental tasks、OIDC Discovery、incremental scope consent（`WWW-Authenticate`）、OAuth Client ID Metadata Documents（CIMD）、工具命名规范、JSON Schema 2020-12 默认、icons/title 元数据、输入校验错误改为 Tool Execution Error、`includeContext` 软弃用** |
| `2026-07-28` | 2026-07-28（draft） | 大改 | **stateless（无 session/握手）、`server/discover`、`subscriptions/listen`、MRTR、Tasks 移入官方扩展、Roots/Sampling/Logging 正式 Deprecated、`ttlMs`/`cacheScope`、错误码分区、`x-mcp-header`、工具列表确定性排序** |

### 1.1 2025-06-18 → 2025-11-25 重点（官方 changelog）

- 授权服务器发现支持 **OpenID Connect Discovery 1.0**（PR #797）。
- 工具/资源/资源模板/prompts 可携带 **icons** 元数据（SEP-973）。
- 授权支持 **增量 scope 同意**：`WWW-Authenticate` 携带 `scope` 挑战（SEP-835）。
- **工具命名规范**（SEP-986）：1–128 字符、大小写字母/数字/下划线/连字符/点，禁空格与特殊字符。
- Elicitation 的 `ElicitResult`/`EnumSchema` 标准化，支持带/不带 title 的单选与多选枚举（SEP-1330）。
- Elicitation 新增 **URL mode**（SEP-1036）：敏感信息（密码、API key、token）必须走 URL mode，**禁止**用 form mode 收集。
- Sampling 支持 `tools`/`toolChoice` 参数（SEP-1577）。
- 新增 **experimental tasks**：durable 请求、轮询、延迟取结果（SEP-1686）。
- **输入校验错误应返回为 Tool Execution Error 而非 Protocol Error**，让模型能自纠（SEP-1303）。
- **JSON Schema 2020-12** 确立为 MCP 默认方言（SEP-1613）。
- 错误码 `-32002`（resource not found）改由 `-32602`（Invalid Params）承担（SEP-2164，于 2026-07-28 完成）。
- 请求 payload 与 RPC 方法定义解耦为独立参数 schema（SEP-1319）。

### 1.2 2025-11-25 → 2026-07-28（当前 draft）重点（官方 changelog）

**Major（破坏性，需版本协商）：**

1. **协议级 session 移除**：Streamable HTTP 不再有 `Mcp-Session-Id`；`tools/list` 等列表不再随连接变化。需要跨调用状态的服务端用"显式 handle"（服务器铸造的不透明 ID 作为普通工具参数传递）。
2. **stateless MCP**：移除 `initialize`/`notifications/initialized` 握手。每个请求在 `_meta` 携带 `io.modelcontextprotocol/protocolVersion`、`io.modelcontextprotocol/clientCapabilities`；客户端在 `_meta` 里自报 `clientInfo`，服务端在结果 `_meta` 里回 `serverInfo`。版本不匹配返回 `UnsupportedProtocolVersionError`。
3. **`server/discover`**：服务端 MUST 实现，广播协议版本、capabilities 与身份；客户端可先调用以做版本选择/向后兼容探测。
4. **`subscriptions/listen`** 取代 GET 流 + `resources/subscribe`：单一长连接 POST 响应流，按类型（`toolsListChanged`、`promptsListChanged`、`resourcesListChanged`、`resourceSubscriptions`）opt-in；`notifications/progress`、`notifications/message` 仍跟随其所属请求的响应流。
5. 移除 `ping`、`logging/setLevel`、`notifications/roots/list_changed`；日志级别改由每请求 `_meta` 的 `io.modelcontextprotocol/logLevel` 控制。
6. **Tasks 移出核心协议、成为官方扩展** `io.modelcontextprotocol/tasks`：`tasks/get` 轮询 + `tasks/update` 交互 + `tasks/cancel`，服务端可主动返回任务句柄。
7. **MRTR（Multi Round-Trip Requests）**：服务端不再主动发 `roots/list`、`sampling/createMessage`、`elicitation/create`；而是返回 `InputRequiredResult`（`resultType: "input_required"` + `inputRequests`），客户端重试原请求并附 `inputResponses`。
8. 所有结果带必填 `resultType`：`"complete"` / `"input_required"`；旧版服务端缺失时按 `"complete"` 处理。
9. 移除 SSE 流恢复（`Last-Event-ID`）；断流后客户端必须用新 request ID 重新发起。

**Minor / 其他：**

- `ClientCapabilities`/`ServerCapabilities` 增加 `extensions` 字段支持官方扩展协商（SEP-2133）。
- `_meta` 中定义 OpenTelemetry 传播键（`traceparent`、`tracestate`、`baggage`）（SEP-414）。
- `tools/list` **应按确定性顺序返回**，利于客户端缓存与 LLM prompt cache 命中。
- Streamable HTTP POST 必须带标准头（`Mcp-Method`、`Mcp-Name`），支持 `x-mcp-header` 把工具参数镜像为 HTTP 头（SEP-2243）。
- 列表/资源读取结果要求 `ttlMs` + `cacheScope`（`"public"`/`"private"`）（SEP-2549）。
- 错误码分区：`-32000`~`-32019` 遗留实现自定义；`-32020`~`-32099` 保留给 MCP 规范（`-32020` HeaderMismatch、`-32021` MissingRequiredClientCapability、`-32022` UnsupportedProtocolVersion）；应用自定义错误应在 `-32000` 之外分配。
- `iss` 参数（RFC 9207）校验、`application_type`（DCR）、客户端凭据按 issuer 绑定（SEP-2468 / SEP-837 / SEP-2352）。
- `inputSchema`/`outputSchema` 放开为任意 JSON Schema 2020-12 关键字，含 `$ref` 解析要求（SEP-2106）。
- `notifications/elicitation/complete` 与 URL mode 的 `elicitationId` 移除（被 MRTR 取代）。
- **Deprecated**：Roots、Sampling、Logging（SEP-2577，至少 12 个月宽限期）；HTTP+SSE 传输（SEP-2596）；`includeContext: "thisServer"/"allServers"`；RFC 7591 DCR 让位于 **CIMD（Client ID Metadata Documents）**。

> ⚠️ **给 Godot-MCP 的即时提醒**：Claude Code 已在按 2026-07-28 校验列表响应（有 issue 报告缺 `ttlMs`/`cacheScope` 会被拒），说明**新版客户端已经开始要求新字段**。插件应尽快在 `tools/list`、`resources/list` 等结果中补 `ttlMs`/`cacheScope`，并对 `resultType` 字段做兼容输出。

---

## 2. MCP 规范功能清单表

> 状态：`Active` = 现行规范要求；`Deprecated` = 官方弃用（宽限期内仍可用）；`Extension` = 官方扩展（需双方 capabilities 声明）。
> 客户端支持度为定性评估（基于官方 client matrix、各客户端文档与社区资料，2026 年状态）。

| 功能 | 引入版本 | 状态 | 用途 | 客户端支持度 |
|---|---|---|---|---|
| **Tools** | 2024-11-25 | Active（2026-07-28 增加 title/icons/outputSchema/x-mcp-header） | 模型调用的可执行能力，核心原语 | 全部客户端 |
| **Resources** | 2024-11-25 | Active（2026-07-28 订阅机制改为 subscriptions/listen） | 只读数据/上下文注入（文件、快照、诊断） | 主流均支持（Claude Desktop/Code/Cursor/Cline/VS Code） |
| **Prompts** | 2024-11-25 | Active | 可复用模板化工作流，用户显式触发 | Claude Desktop、VS Code、Cursor、Cline；Codex 较弱 |
| **Completion**（参数补全） | 2025-03-26 | Active | 工具/资源/prompt 参数值的自动补全建议 | 支持面窄（Claude Desktop 部分、Inspector） |
| **Sampling** | 2025-03-26 | **Deprecated**（SEP-2577） | 服务端反向请求 LLM 生成（"反向工具调用"） | 极少（VS Code 实验性）；新实现不应再依赖 |
| **Roots** | 2024-11-25 | **Deprecated**（SEP-2577） | 客户端告知服务端允许访问的目录/文件 | 有限；官方建议改用工具参数/资源 URI/服务端配置 |
| **Logging** | 2024-11-25 | **Deprecated**（SEP-2577） | 结构化日志通知 | 有限；建议 stdio 用 stderr，HTTP 用 OTel |
| **Elicitation**（form） | 2025-03-26 | Active | 服务端向用户收集结构化输入（嵌套在工具调用中） | VS Code、Cursor、Claude Code 等逐步支持；Claude Desktop 较弱（跟踪 issue #41110） |
| **Elicitation**（URL mode） | 2025-11-25 | Active（2026-07-28 并入 MRTR） | 敏感交互跳转到服务端自有 URL，不经客户端 | 随客户端 MRTR/elicitation 支持推进 |
| **Tasks**（异步任务） | 2025-11-25 实验 → 2026-07-28 | **Extension** `io.modelcontextprotocol/tasks` | 长任务：轮询进度、中途要输入、崩溃恢复 | 支持面在扩展，需双方 opt-in；见官方扩展矩阵 |
| **Agent-to-Agent** | 2025-11-25 起 | 无独立协议，靠 elicitation + tasks + MRTR 组合 | 服务端请求客户端/用户参与的多轮交互 | 客户端能力驱动，非独立开关 |
| **OAuth 2.0 授权** | 2025-06-18 | Active（DCR 弃用 → CIMD 推荐；OIDC Discovery；增量 scope） | 远程服务器的鉴权（PKCE、DCR/CIMD、step-up scope） | Claude/VS Code/Cursor/Goose 等远程连接支持；本地服务器非必需 |
| **Streamable HTTP** | 2025-06-18 | Active（2026-07-28 stateless 化 + 头标准化） | 远程/本地 HTTP 传输，POST 单端点 + 可流式响应 | 主流客户端均支持；HTTP+SSE 已弃用 |
| **HTTP+SSE 传输** | 2024-11-25 | **Deprecated**（2026-07-28 正式） | 旧式双端点传输 | 客户端仍兼容，但新实现应迁移 |
| **Batch 请求** | — | **不支持** | JSON-RPC 2.0 的 batch 被 MCP 排除；官方以并发请求、MRTR、Tasks 覆盖该需求 | 无 |
| **Progress notifications** | 2025-03-26 | Active | 长操作进度上报（`_meta.progressToken`） | 主流支持 |
| **Cancellation** | 2025-03-26 | Active | 客户端取消进行中的请求/任务 | 主流支持 |
| **Pagination** | 2024-11-25 | Active（2026-07-28 加 ttlMs/cacheScope） | 大列表分页（cursor 游标） | 主流支持 |
| **Subscriptions** | 2024-11-25（resources/subscribe） | Active（2026-07-28 改为 subscriptions/listen） | 服务端→客户端变更通知 | 新版客户端支持 listen 模式 |
| **Tool annotations** | 2025-03-26 | Active | readOnly/destructive/idempotent/openWorld 提示，指导权限与缓存 | 主流认可（客户端应视为不可信） |
| **structuredContent + outputSchema** | 2025-06-18 起强化 | Active（2026-07-28 任意 JSON Schema） | 结构化结果 + 输出 schema，支撑客户端代码模式/强类型 | VS Code/Claude Code 等已用；建议服务端普遍提供 |
| **MCP Apps**（扩展） | 2026（SEP-1865） | **Extension** `io.modelcontextprotocol/ui` | 客户端内嵌交互式 UI（HTML） | Claude web/Desktop、VS Code、Cursor、ChatGPT、Goose 等（见扩展矩阵） |
| **server/discover** | 2026-07-28 | Active（draft） | 版本/capabilities/身份探测，替代 initialize | 随 2026-07-28 客户端推进 |
| **MRTR** | 2026-07-28 | Active（draft） | 服务端请求追加输入（elicitation/sampling/roots 统一为 input_required 结果） | 随 2026-07-28 客户端推进 |

---

## 3. 客户端生态现状（capabilities 支持差异）

> 依据：官方 [Extension Support Matrix](https://modelcontextprotocol.io/extensions/client-matrix.md)、VS Code 官方博客（[full MCP spec support](https://raw.githubusercontent.com/microsoft/vscode-docs/106b2e626f4292378adb35215e96bbf5902a51fd/blogs/2025/06/12/full-mcp-spec-support.md)、[VS Code 博客：Prompts/Resources/Sampling](https://devblogs.microsoft.com/visualstudio/mcp-prompts-resources-sampling/)）、社区矩阵（如 [mcp_client_compatibility](https://github.com/armpro24-blip/cad-cae-copilot/blob/main/aieng-ui/backend/docs/mcp_client_compatibility.md)、[glama Cline 页](https://glama.ai/mcp/clients/cline)）。能力演进快，以各客户端官方文档为准。

| 客户端 | Tools | Resources | Prompts | Elicitation | Sampling | OAuth(远程) | Streamable HTTP | MCP Apps | Tasks(扩展) |
|---|---|---|---|---|---|---|---|---|---|
| **Claude Desktop** | ✅ | ✅ | ✅ | ⚠️ 弱/跟踪中（[issue #41110](https://github.com/anthropics/claude-code/issues/41110)） | ❌ | ✅ | ✅ | ✅ | ⚠️ 视版本 |
| **Claude Code** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ❌（矩阵未列） | ⚠️ 已向 2026-07-28 迁移（[ttlMs 校验 issue #88128](https://github.com/anthropics/claude-code/issues/88128)） |
| **Cursor** | ✅ | ✅ | ✅ | ✅（2025 起） | ❌ | ✅ | ✅ | ✅ | ⚠️ |
| **Cline** | ✅ | ✅ | ✅ | ✅ | ⚠️ 实验性 | ⚠️ 部分 | ✅ | ❌（矩阵未列） | ⚠️ |
| **VS Code / GitHub Copilot** | ✅ | ✅ | ✅ | ✅（[2025-06 全规范支持](https://www.infoworld.com/article/4006321/visual-studio-code-bolsters-mcp-support.html)） | ⚠️ 实验性（opt-in） | ✅ | ✅ | ✅ | ⚠️ |
| **OpenAI Codex** | ✅ | ⚠️ 部分 | ⚠️ 部分 | ❌/有限 | ❌ | ⚠️ 部分 | ✅ | ❌ | ❌ |
| **ChatGPT** | ✅ | ⚠️ 部分 | ❌/有限 | ❌/有限 | ❌ | ✅ | ✅ | ✅ | ❌ |
| **Goose / Postman / MCPJam** | ✅ | ✅ | ✅ | ⚠️ | ❌ | ✅ | ✅ | ✅（矩阵） | ⚠️ |

要点：

- **Elicitation 是 2025-11-25 后最重要的新交互能力**，但支持集中在"编辑器型"客户端（VS Code、Cursor、Claude Code），桌面聊天型（Claude Desktop）偏弱。对编辑器型插件（Godot-MCP）价值高：可在工具执行中途向用户确认（如"确认覆盖场景？"）。
- **Sampling 已官方弃用**：不要围绕它设计能力；需要"AI 参与"时用工具参数回调/外部 LLM API。
- **OAuth 针对远程部署**；本地 stdio / localhost+Bearer Token（插件现状）是合理且官方认可的形态（[Security Best Practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices.md) 明确：本地服务器用 stdio 或受限 HTTP + token）。
- **MCP Apps 是 2026 年新增长点**（客户端内嵌 UI），对编辑器插件可作为后续加分项，但需要客户端支持，优先级低。

---

## 4. "理想的编辑器型 MCP 服务器"能力清单（按优先级）

针对 Godot-MCP（本地编辑器、215 工具、stdio + HTTP 双传输）的落地排序：

### P0 — 协议正确性与"能被高效使用"（必须）
1. **合法且精简的 `tools/list`**：确定性排序；无参数工具用 `{"type":"object","additionalProperties":false}`；默认 JSON Schema 2020-12 方言；工具名遵守 SEP-986（ASCII 字母数字 `_-.`，1–128 字符，无空格）。
2. **工具调用三态错误模型**：
   - *Protocol Error*（JSON-RPC error，如未知工具、畸形请求）→ 少用，模型难以自纠；
   - *Tool Execution Error*（`result.isError: true` + 可行动文本，如"参数 X 非法：应为 1–100"）→ **绝大多数业务/校验错误走这里**，模型能自纠重试（SEP-1303 官方要求）；
   - *Input Required*（`resultType: "input_required"`，2026-07-28）→ 需要用户补充信息时使用。
3. **`structuredContent` + `outputSchema`**：列表/查询类工具返回可解析的结构化 JSON + 输出 schema（支撑客户端代码模式与强类型校验）。
4. **`ttlMs` + `cacheScope` + `resultType`**：列表结果带缓存提示（SEP-2549）；结果带 `resultType: "complete"` 兼容 2026-07-28 客户端。
5. **Progress + Cancellation**：耗时工具（`play_and_verify`、`generate_3d_asset`、`smoke_test_export`、性能门禁）接受 `_meta.progressToken` 发 `notifications/progress`，并响应 `notifications/cancelled`。
6. **Tool annotations**：`readOnlyHint`（查询类）、`destructiveHint`（删除/覆盖）、`idempotentHint`、`openWorldHint`。
7. **`listChanged`**：启用/禁用工具后发变更通知，让客户端刷新目录。
8. **版本协商与双版本兼容**：`server/discover`（2026-07-28）+ 兼容旧握手（2025-11-25 `initialize`）；`_meta` 里正确回填 `protocolVersion`/`serverInfo`。

### P1 — 大规模工具集的组织（强烈建议）
9. **服务端目录（catalog）元工具**：`search_tools(query)`（返回 名称+一行描述）、`get_tool_details(name)`（返回完整 schema）、`list_tool_catalog`、`enable_tools` —— 插件已具备后两者，补齐 `search_tools`/`get_tool_details` 即完整对齐官方 catalog→inspect→execute 三层模式。
10. **按需启用（lazy tools）**：核心 30 + meta 2 常驻，supplementary 默认关闭、由 AI 经 `enable_tools` 启用（现有设计正确），并在描述里写明"启用后需 tools/list 刷新"。
11. **工具名分组前缀 + 稳定顺序**：如 `node_*`、`script_*`、`scene_*`、`debug_*`、`project_*`、`meta_*`（现状已符合）；命名一致、避免同义词（`get`/`list`/`read` 语义统一）。
12. **结果大小控制**：列表类工具支持 `limit`/`offset` 或返回摘要+句柄，避免单次结果撑爆上下文。

### P2 — 面向 2026 规范的增量（建议跟进）
13. **状态句柄模式**：插件 `tool_state_manager` / `manage_task_plan` 的状态改为显式句柄（如 `plan_id`），创建工具返回句柄、后续工具接收句柄参数（对齐 stateless MCP 的官方建议）。
14. **Tasks 扩展（`io.modelcontextprotocol/tasks`）**：对分钟级操作（`generate_3d_asset` 轮询、`play_and_verify`）返回 `CreateTaskResult` + `tasks/get` 轮询；需客户端 opt-in，作为渐进路线。
15. **Elicitation（form/URL）**：对破坏性操作提供"执行前确认"，但先检测客户端 capabilities，不支持则回退为"dry_run + 显式 confirm 参数"（插件已有 dry_run 传统，很好）。
16. **Resources 使用**：把项目诊断/场景快照/导出产物以 resources 暴露（URI 设计见下），并在工具结果里用 `resource_link`/`resource` 内容类型引用。
17. **MCP Apps**（加分项、低优先级）：如需做"节点树可视化/差异对比"内嵌 UI 再评估。

### P3 — 明确不做/谨慎
- **Sampling**（官方弃用）。
- **Roots**（官方弃用；编辑器项目根即天然 scope，用工具参数传路径即可，插件现有 `path_validator` 更安全）。
- **Logging 通知**：stdio 走 stderr，HTTP 走插件面板日志即可。
- **OAuth 全套**：本地部署用 Bearer Token（现有 `mcp_auth_manager`）足够；仅当计划支持远程托管时才引入 OAuth 2.1 + CIMD。

---

## 5. 工具设计最佳实践清单（可操作规则）

来源：官方 [Client Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/develop/clients/client-best-practices)、[Tools 规范](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)、[SEP-1303](https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors.md)、社区 schema 指南（[attio mcp-schema-guidelines](https://github.com/kesslerio/attio-mcp-server/blob/main/docs/mcp-schema-guidelines.md)）。

### 命名与描述
1. 工具名：ASCII 字母数字 `_-.`，1–128 字符；**动词开头、语义唯一**（`create_node`、`list_children`）；分组前缀一致；不要在名字里塞参数。
2. 描述 = **第一句讲清"做什么 + 何时用"**（模型靠它做工具选择）；第二句讲副作用/前置条件；第三句讲返回值要点。避免空泛（"Performs operations"）与营销话术。
3. 描述里写明**状态句柄的生命周期**（如"plan 24 小时后过期"）与**默认值行为**（如 `dry_run=true` 时不落盘）。
4. 每个参数必须有 `description`，含单位、枚举含义、边界（`0–100`）；可选参数明确默认值。
5. 能用 `enum` 就用 `enum`（约束越强，模型选错概率越低）；**避免在 inputSchema 用 `oneOf`/`anyOf`**（多数客户端/模型对条件 schema 支持差），需要多形态时拆成独立工具或用可选字段；`anyOf` 可用于 outputSchema 描述联合返回。

### Schema 与结果
6. `inputSchema` 遵守 JSON Schema 2020-12；必须的才放 `required`；`additionalProperties: false` 防模型发明参数。
7. 输出：查询/结构类工具提供 `outputSchema` + `structuredContent`（JSON 对象/数组），同时给一段人类可读的 `content.text` 摘要（兼容旧客户端，也利于日志）。
8. 结果文本控制在"模型可消化的篇幅"：大结果给摘要 + 指向 `resource` 内容或后续工具。
9. **错误即数据**：业务错误用 `isError: true` 返回，文本要"可行动的修复建议 + 当前值 + 期望值"；不要抛 JSON-RPC error，除非请求本身畸形。
10. 工具执行前 **fail-fast 校验**所有参数（类型、范围、路径存在性、权限），校验失败立即返回 Tool Execution Error（[SEP-1303](https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors.md)），不要执行到一半才失败。
11. **单一职责**：一个工具只做一件事（拆分 `list`/`create`/`update`/`delete`/`get`），避免"万能工具 + 动作枚举参数"（枚举动作让模型更难推理，也难缓存）。

### 行为与安全
12. 破坏性工具（删除/覆盖/导出覆盖/设置写入）在描述与名称中明示，必要时要求显式确认参数（`confirm: true`）或先 `dry_run`。
13. 读操作标注 `readOnlyHint`，写操作标注 `idempotentHint`（可重试）或 `destructiveHint`。
14. 工具实现必须：校验输入、限频、净化输出；对路径类参数做项目根约束（插件 `path_validator` 已做，继续保持）。
15. 长操作：接受 `progressToken`，按阶段发进度；支持取消；不要在工具内部阻塞主线程（GDScript 用 `await`/线程，注意编辑器线程安全）。

---

## 6. "215 个工具"规模的组织策略（LLM 高效使用）

### 6.1 问题本质
- 工具定义是**上下文大头**：官方示例中全量加载约 150K token，渐进发现仅约 2K token（[Client Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/develop/clients/client-best-practices)）。
- 工具过多还会造成**选择困难**（模型在无关工具间游移）与 prompt cache 失效（工具数组变动即缓存 miss）。
- 官方阈值：工具定义合计超过上下文窗口 **1%–5%** 就应切换渐进发现。

### 6.2 服务端能做的（Godot-MCP 落地）
1. **三层目录模式（catalog → inspect → execute）**：
   - `list_tool_catalog`（已有）：返回全量目录 = 名称 + 一行描述（保持轻量）。
   - `search_tools`（建议新增）：关键词/正则匹配名称+描述，返回命中项（名称+一行描述），支持分组过滤。
   - `get_tool_details`（建议新增）：单个工具的完整 schema（desc + input/output schema + 示例）。
   - `enable_tools`（已有）：按需启用分组/工具，配合 `tools/list_changed` 通知。
2. **分层常驻**：28 核心 + 2 meta 常驻（当前设计）；supplementary 185 个默认关闭；meta 工具自身描述里写明"如何发现并启用其他工具"。
3. **分组前缀**：`node_`/`script_`/`scene_`/`editor_`/`debug_`/`project_`/`meta_` 前缀（现状），并在 catalog 描述中按组给出"何时用哪组"的一句话指引（如 `debug_` 组 = 断点/性能/运行时探针）。
4. **schema 精简**：
   - 只暴露必要参数；高频默认值写进描述而非塞参数；
   - 列表类工具统一 `limit`（默认小值）+ `offset`/`cursor`；
   - 共享"目标定位"参数（如 `node_path`）写法全局统一；
   - 避免为每个工具重复长段 boilerplate 描述。
5. **确定性顺序 + 稳定列表**：`tools/list` 固定顺序（分组→工具名），工具集不变时列表不变（利于客户端缓存与 prompt cache）。
6. **描述撰写规范（内部约定）**：每条 ≤ ~200 字符（catalog 一行 ≤ ~80），首句动词开头；全插件统一中英双语模板（现有翻译系统可复用）。

### 6.3 客户端侧的配合（插件文档层面）
- 在 README 中说明"核心组 = 常驻上下文；其余按需启用"，指导用户在 Claude Desktop / VS Code / Cursor 中配置合理默认。
- 依赖客户端渐进发现时，插件无需改动协议：`search_tools` 等 meta 工具天然被客户端当作普通工具。

---

## 7. Agentic 模式：长任务编排与自主开发循环

### 7.1 MCP 侧的长任务原语（2026 现状）
- **Progress**：`_meta.progressToken` + `notifications/progress`（`total`/`progress`/`message`）—— 秒级进度。
- **Cancellation**：`notifications/cancelled`（2025-03-26 起）；2026-07-28 stateless 化后取消与请求 ID 绑定。
- **Tasks 扩展**（[ext-tasks](https://github.com/modelcontextprotocol/ext-tasks)）：分钟/小时级操作 —— `CreateTaskResult`（`taskId` + `pollIntervalMs` + `ttlMs`）→ `tasks/get` 轮询 → `input_required` 时 `tasks/update` 供输入 → `completed/failed/cancelled` 终态；**崩溃后可恢复**（task ID 持久化）。适合 Godot 的 `generate_3d_asset`（异步轮询 Meshy/Tripo）、`play_and_verify`（启动+断言）、导出冒烟等。
- **Subscriptions（2026-07-28）**：`subscriptions/listen` 推送变更（工具/资源列表变化、task 状态推送 `notifications/tasks`）。
- 官方 [Roadmap](https://modelcontextprotocol.io/development/roadmap.md) 正在推进：server-initiated events（webhook 推送）、Tasks 入核心、ETag 缓存、DPoP/agent identity。

### 7.2 自主开发循环（Claude Code 生态的启示）
- **Hooks**（[Claude Code hooks 文档](https://code.claude.com/docs/en/hooks)）：`PreToolUse`/`PostToolUse`/`Stop`/`SessionStart` 等钩子在工具调用前后拦截 —— 可做"写后审"（write-then-review）、禁止名单、自动测试触发。MCP 工具同样被 hooks 拦截，因此**插件无需实现 hooks**，但工具语义（读/写/破坏性注解）要清晰，让客户端 hooks/权限系统能正确分类。
- **Permission 模式**：`default/plan/acceptEdits/auto/dontAsk/bypassPermissions` 分级授权；破坏性工具标注 `destructiveHint` 会直接影响客户端是否弹确认。
- **对 Godot-MCP 的落地建议**：
  - 保证 `manage_task_plan`（plan→execute→run→verify→fix 闭环）的**每一步都有可验证产物**（DoD 落盘、assert 门禁返回结构化结果），让"自主循环"可审计、可回滚；
  - 编辑器侧提供"写后验证"闭环：写脚本/场景后自动触发 `validate_script`/`verify_scene`/`assert_no_runtime_errors`（插件已有），并在结果里给出明确 pass/fail 与修复建议；
  - 耗时步骤全部接 progress/可取消；失败时返回结构化错误让上层循环重试（`isError: true` + 建议动作）。

---

## 8. 对 Godot-MCP 的具体优化清单（映射到现有架构）

| # | 优化项 | 现有锚点 | 动作 |
|---|---|---|---|
| 1 | `tools/list` 返回 `ttlMs`/`cacheScope`/`resultType` | `mcp_server_core.gd` 注册/分发 | 列表响应包装加字段；`resultType: "complete"` 兜底 |
| 2 | 工具执行错误统一走 `isError: true` + 可行动文本 | 各 `_tool_*()` 返回 `{"error": ...}` | 检查是否误用了 JSON-RPC error；错误文本加"建议修复" |
| 3 | 查询类工具补 `outputSchema` + `structuredContent` | `register_tool()` 已有 output_schema 参数 | 优先给 list/query/audit/assert 类工具补齐 |
| 4 | 新增 `search_tools`、`get_tool_details` meta 工具 | `meta_tools_native.gd` | 目录三层模式补全；`list_tool_catalog` 保持轻量 |
| 5 | 耗时工具接 progress + 可取消 | `play_and_verify`、`generate_3d_asset`、`smoke_test_export`、性能门禁 | 读取 `_meta.progressToken`，发 `notifications/progress`；响应取消 |
| 6 | 工具命名/描述审计（SEP-986 + 描述规范） | 215 个注册项 | 扫描非法字符、同义词混乱、无描述参数 |
| 7 | 状态句柄化（stateless 对齐） | `tool_state_manager.gd`、`manage_task_plan` | 创建→返回句柄→后续传句柄；句柄过期报 Tool Execution Error |
| 8 | 破坏性/幂等/只读注解全覆盖 | `annotations` 参数已存在 | 审计补充 `readOnlyHint/destructiveHint/idempotentHint` |
| 9 | `listChanged` 通知 | 启用/禁用工具路径 | 启用/禁用后发 `notifications/tools/list_changed` |
| 10 | 版本协商（`server/discover` + 旧握手兼容） | `mcp_types.gd` 常量 | 支持 2026-07-28 `_meta` 字段；旧客户端仍走 initialize |
| 11 | Tasks 扩展（渐进路线） | `generate_3d_asset` 已异步 | 客户端声明 `io.modelcontextprotocol/tasks` 时返回任务句柄 |
| 12 | 文档同步 | README / docs | 说明"核心常驻 + 按需启用"的上下文策略与客户端配置建议 |

---

## 9. 参考链接

### 官方规范与文档（modelcontextprotocol.io / GitHub）
- [Spec 2025-11-25 官方 changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog.md)
- [Spec 2026-07-28 官方 changelog（当前 draft）](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md)
- [Spec 版本 diff：2025-06-18…2025-11-25（GitHub）](https://github.com/modelcontextprotocol/specification/compare/2025-06-18...2025-11-25)
- [Spec 版本 diff：2025-11-25…2026-07-28（GitHub）](https://github.com/modelcontextprotocol/specification/compare/2025-11-25...2026-07-28)
- [Spec 2025-11-25 changelog（GitHub 源码）](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/02dd8f61/docs/specification/draft/changelog.mdx)
- [Tools 规范（2026-07-28）](https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md) — 错误处理、命名、outputSchema、x-mcp-header、stateful tools 指南
- [基础协议总览（2026-07-28）：resultType/错误码/stateless](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md)
- [Elicitation 规范（2025-11-25）](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation.md)
- [Client Best Practices（渐进发现 + 代码模式）](https://modelcontextprotocol.io/docs/2025-11-25/develop/clients/client-best-practices.md)
- [Security Best Practices（2026-07-28）](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices.md)
- [官方 Roadmap（2026-08-22 更新）](https://modelcontextprotocol.io/development/roadmap.md)
- [Extension Support Matrix（客户端扩展支持矩阵）](https://modelcontextprotocol.io/extensions/client-matrix.md)
- [Tasks 扩展总览（ext-tasks）](https://modelcontextprotocol.io/extensions/tasks/overview.md) / [ext-tasks 仓库](https://github.com/modelcontextprotocol/ext-tasks)
- [文档索引 llms.txt](https://modelcontextprotocol.io/llms.txt)
- [示例服务器列表（官方 examples）](https://modelcontextprotocol.io/examples.md)

### SEP（Specification Enhancement Proposals）
- [SEP-986 工具命名格式](https://modelcontextprotocol.io/seps/986-specify-format-for-tool-names.md)
- [SEP-1303 输入校验错误 → Tool Execution Error](https://modelcontextprotocol.io/seps/1303-input-validation-errors-as-tool-execution-errors.md)
- [SEP-1577 Sampling with tools](https://modelcontextprotocol.io/seps/1577--sampling-with-tools.md)
- [SEP-1613 JSON Schema 2020-12 默认方言](https://modelcontextprotocol.io/seps/1613-establish-json-schema-2020-12-as-default-dialect-f.md)
- [SEP-1686 Tasks](https://modelcontextprotocol.io/seps/1686-tasks.md) / [SEP-2663 Tasks 扩展](https://modelcontextprotocol.io/seps/2663-tasks-extension.md)
- [SEP-2322 Multi Round-Trip Requests (MRTR)](https://modelcontextprotocol.io/seps/2322-MRTR.md)
- [SEP-2549 列表结果 TTL](https://modelcontextprotocol.io/seps/2549-TTL-for-list-results.md)
- [SEP-2567 Sessionless MCP](https://modelcontextprotocol.io/seps/2567-sessionless-mcp.md)
- [SEP-2575 Make MCP Stateless](https://modelcontextprotocol.io/seps/2575-stateless-mcp.md)
- [SEP-2577 Deprecate Roots/Sampling/Logging](https://modelcontextprotocol.io/seps/2577-deprecate-roots-sampling-and-logging.md)
- [SEP-2596 功能生命周期与弃用策略](https://modelcontextprotocol.io/seps/2596-spec-feature-lifecycle-and-deprecation.md)
- [SEP-2106 inputSchema/outputSchema JSON Schema 2020-12](https://modelcontextprotocol.io/seps/2106-json-schema-2020-12.md)
- [SEP-1036 URL mode elicitation](https://modelcontextprotocol.io/seps/1036-url-mode-elicitation-for-secure-out-of-band-intera.md)
- [SEP-1330 Elicitation 枚举 schema](https://modelcontextprotocol.io/seps/1330-elicitation-enum-schema-improvements-and-standards.md)
- [SEP-973 元数据（icons/title）](https://modelcontextprotocol.io/seps/973-expose-additional-metadata-for-implementations-res.md)
- [SEP-2164 资源不存在错误码](https://modelcontextprotocol.io/seps/2164-resource-not-found-error.md)
- [SEP-2243 HTTP 头标准化](https://modelcontextprotocol.io/seps/2243-http-standardization.md)
- [SEP-1865 MCP Apps](https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp.md)
- [SEP-1730 SDK 分层系统](https://modelcontextprotocol.io/seps/1730-sdks-tiering-system.md)

### 客户端生态
- [VS Code 博客：Prompts/Resources/Sampling（2025-09）](https://devblogs.microsoft.com/visualstudio/mcp-prompts-resources-sampling/)
- [VS Code 博客：full MCP spec support（2025-06，GitHub raw）](https://raw.githubusercontent.com/microsoft/vscode-docs/106b2e626f4292378adb35215e96bbf5902a51fd/blogs/2025/06/12/full-mcp-spec-support.md)
- [InfoWorld：VS Code bolsters MCP support](https://www.infoworld.com/article/4006321/visual-studio-code-bolsters-mcp-support.html)
- [Claude Desktop elicitation 支持跟踪 issue（anthropics/claude-code #41110）](https://github.com/anthropics/claude-code/issues/41110)
- [Claude Code 对 2026-07-28 ttlMs/cacheScope 的校验 issue #88128](https://github.com/anthropics/claude-code/issues/88128)
- [Cline 客户端能力页（glama）](https://glama.ai/mcp/clients/cline)
- [社区 MCP 客户端兼容性矩阵](https://github.com/armpro24-blip/cad-cae-copilot/blob/main/aieng-ui/backend/docs/mcp_client_compatibility.md)
- [2026 年 MCP 支持工具列表（contextbolt）](https://contextbolt.com/blog/ai-tools-mcp-support/)
- [Best MCP Clients 2026 对比（nimbalyst）](https://nimbalyst.com/blog/best-mcp-clients-2026/)
- [Claude Code Hooks 文档](https://code.claude.com/docs/en/hooks) / [权限配置](https://code.claude.com/docs/en/agent-sdk/permissions)
- [Claude Code 配置指南（hooks/permissions/MCP）](https://github.com/AlexandrG539/claude-code-setup-guide)

### 生态 / 社区资料
- [MCP Server 上下文成本与 Catalog Mode（strayspark）](https://www.strayspark.studio/blog/mcp-server-context-costs-catalog-mode-progressive-disclosure)
- [MCP Tool Schema 指南（attio-mcp-server）](https://github.com/kesslerio/attio-mcp-server/blob/main/docs/mcp-schema-guidelines.md)
- [MCP Best Practices 架构指南（modelcontextprotocol.info）](https://modelcontextprotocol.info/docs/best-practices/)
- [MCP 参考服务器路线图（chuk-mcp-server-reference）](https://raw.githubusercontent.com/chrishayuk/chuk-mcp-server-reference/refs/heads/main/ROADMAP.md)
- [MCP 安全分析：2025-11-25 Tasks（safeguard.sh）](https://safeguard.sh/resources/blog/mcp-spec-2025-11-25-tasks-abstraction-security)
- [MCP 深入分析（plurigrid/asi skills）](https://github.com/plurigrid/asi/blob/main/skills/agentic-coordination-protocols/01-mcp-deep-dive.md)
- [Microsoft mcp-for-beginners：协议特性进阶](https://github.com/microsoft/mcp-for-beginners/blob/main/05-AdvancedTopics/mcp-protocol-features/README.md)
