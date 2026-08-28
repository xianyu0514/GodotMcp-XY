# Godot MCP Native — 深度优化计划（借鉴 DeepSeek Harness）

> 目标：优先保持功能正确与完整，再把插件的**缓存命中率、算力（token）消耗、架构精简**优化到参考 DeepSeek Harness（DSH）的最佳实践水平。原蓝图现已用 2 个紧凑元工具实现，而非增加一组常驻 goal 工具。
> 依据：`docs/research/dsh-cache-compute-study.md`（缓存与算力）、`docs/research/dsh-tool-token-economy-study.md`（工具与 token 经济）、`docs/research/dsh-agent-architecture-study.md`（agent 架构）。

---

## 0. DSH 的核心设计原则（TL;DR）

1. **缓存失效由修订驱动，不是 TTL**：DSH 几乎不用 TTL，全部用 seq 水位 / `replace_generation` / epoch / ver 版本号失效——内容变了才作废，缓存命中率最大化。
2. **模型只见最小 schema**：`schemaOf` 白名单只下发 `name/description/parameters`（工具定义层）；output schema、超时、并发标记一律不进上下文。
3. **结果体积三层控制**：工具内建 cap（read 2000 行/glob 100/grep 250）→ 50KB spill 落盘（模型首包见 head/tail 预览 + 标准 `resource_link`，按需通过 `resources/read` 无损取回；落盘失败不转 error）→ 8KB pruner（确定性裁剪可重放）。
4. **token 计费口径**：`JSON.stringify(tools).length / 4` 字符/token 启发式，provider usage 锚定校正。
5. **上下文压缩（compaction）**：contextWindow×0.8 触发、16% 尾部保留、8K 摘要、摘要复用会话前缀保 KV cache。
6. **agent 目标驱动**：goal 持久快照 + CAS revision + 回合驱动器（agent 空闲自动续作下一轮）+ 人类武装授权（armed/disarmed 分离）。

---

## 1. 实施项（按杠杆排序，全部可 GUT 验证）

### M1. tools/list 精简 schema（最高杠杆，先做）
现状：`mcp_types.gd` 的 `MCPTool.to_dict()` 把 `outputSchema` 也下发到 `tools/list`——221 个 output schema 的每轮字节全部浪费（DSH 只发 name/description/parameters）。
- **改动**：`to_dict()` 不再包含 `outputSchema`；完整 schema 改由 `get_tool_details`（已有）按需返回。
- 保留：`annotations`（小）、`x_category`/`x_group`（客户端分组有用）、`inputSchema`（必需）。
- **token 收益**：221 个 output schema（多为 10-30 属性对象）每轮省数千 token；配合 `_meta.ttlMs` 的客户端缓存，重复请求零开销。
- 风险：个别客户端依赖 tools/list 的 outputSchema——DSH 全量客户端（Claude Code/Copilot/Codex）均不依赖，且 `get_tool_details` 兜底。

### M2. token 预算门禁（lint 增强）
- 新建 `utils/token_estimator.gd`：`estimate(text)` = `text.length() / 4`（与 DSH token-meter 口径一致）；`estimate_schema(schema)` = `JSON.stringify(schema).length / 4`。
- `test_tool_schema_lint.gd` 增强：断言 per-tool 定义（name+description+inputSchema）受预算控制、默认启用集（当前 28 core + 6 meta）≤ 15k tokens、全量 223 工具 ≤ 60k tokens。超限即失败，倒逼描述精简。

### M3. 工具结果缓存（确定性 key + 事件失效）
- `mcp_server_core.gd` 现有 scene-structure 缓存（5min TTL）扩展为**通用结果缓存**：
  - key：工具名 + 规范化参数（字典 key 排序后 JSON，确定性）；
  - 容量：LRU 同时受 64 条目与 32 MiB 序列化原始结果预算约束；超预算只是不缓存，本次结果仍完整返回；
  - 失效：写工具（readOnlyHint=false）执行后全失效 + 可选 mtime 指纹 + TTL 兜底（如 60s）；
  - 单飞：同一 key 并发请求合并为一次执行（防重复算力）。
- 只缓存**幂等读工具**（readOnlyHint=true 且显式 opt-in 清单，如 get_scene_structure/list_nodes/list_project_scenes/list_project_scripts）。

### M4. 结果体积控制（spill 落盘）
- core 层新增结果上限：`MAX_INLINE_RESULT_BYTES = 50000`（DSH 默认）。
- 超限结果：写盘到 `res://.mcp/out/<sha256>.json`，返回兼容的 `{truncated, total_bytes, path, head, tail, resume_hint}` 预览，同时追加标准 MCP `resource_link`。相同内容验证 SHA-256 后直接复用，不重复写盘。
- `resources/read` 通过 `godot-mcp://result/<sha256>` 返回 UTF-8 安全的 16 KiB 固定页；跟随 `_meta.nextUri` 并顺序拼接可逐字节还原原 JSON。动态结果不加入 `resources/list`，也不新增工具/Schema。
- **功能收益优先**：错误结果与源码/日志读取完整内联；hash/写盘失败时回退完整内联，不转 error、不丢字段。204,211-byte Unicode 门禁首包节省 95.62%，13 页 SHA-256 完整重建。

### M5. 读工具无损分页与扫描复用
- 高返回稳定读工具统一 `limit`/`offset` 与 `returned_count`/`total_count`/`has_more`/`next_offset` 语义。
- `list_project_resources`、两个 debugger stack 读工具和四个项目扫描工具已补齐；项目扫描把与视图无关的完整结果按查询参数与依赖 revision 缓存，跨页只扫描一次。
- 快照独立限制为最多 8 项、单项 4 MiB；超限时只是不缓存，本次结果仍完整可用。现有领域计数已经承担 summary 职责，不为所有工具强加新的模式参数。
- `apply_migration_fixes` 等带状态写工具不按重复执行方式分页，避免后续页基于已修改项目而产生不一致；大结果继续走 M4 无损资源读取。
- 与合入基线 `3421e6b` 的同一 token 门禁对比，全量 221 工具定义仅增加 266 估算 token（30,626 → 30,892，+0.87%），默认 32 工具增加 79（3,855 → 3,934）；代表性工作流的 Schema 节省率保持 98.12%（基线 98.11%）。

### M6. 精简（非破坏性）
- 巨型文件拆分（project_tools_native.gd 364KB→按域 4-6 文件）——架构精简，纯机械。
- 死代码清理（audit 已列的 `is_path_safe` 等）。
- 单一数据表驱动注册（消除 classifier/docs/翻译/测试 5 处重复）。

---

## 2. 持久目标闭环（已实现）

DSH 的"强 agent"= 六层正交机制。映射到 Godot MCP：

| DSH 机制 | Godot MCP 对应 | 落地形态 |
| --- | --- | --- |
| 事件溯源会话日志（唯一事实源） | `TaskPlanStore`（默认 `res://.mcp/task_plan.json`） | 目标合同、蓝图、状态和证据收据存一处 |
| goal 域（持久快照 + CAS revision） | `plan_game_workflow` | plan/status/replan/cancel，共用 `expected_workflow_id` CAS |
| 回合驱动器（agent 空闲自动续作） | `run_game_workflow` | 默认 4/8/16/32 自适应检查点切片；pending/暂时失败可续作，重复失败转重规划 |
| subagent 缝（独立上下文委派） | 不适用（MCP 服务器不做委派） | 文档说明：由客户端 agent 承担 |
| skill/todo/plan 消费端 | 12 个可组合制作 profile | 目标编译为确定性 DAG，不依赖额外模型/网络路由 |
| 会话续作（session 持久化） | 状态动作 + 持久任务文件 | 重连后通过 `plan_game_workflow(action="status")` 恢复 |

**关键设计原则**（来自 DSH）：
1. 续作自动但武装/解除武装永远是人类决定（armed/disarmed 分离）；
2. 单一事实源，不造第二份状态（goal 状态只存一处，其余投影）；
3. 回合提示强制"重读现场"（inspect instead of assume）；
4. fatal 与可重试失败分开；blocked 需连续 3 轮 + 具体原因；
5. 目标工具变更走 CAS revision 防陈旧覆盖。

实现没有加入三个独立 goal CRUD 工具，也没有把完整计划塞进一次 `tools/list`。仅增加两个紧凑常驻 Schema；全部原子工作仍由现有 217 个工具执行。

---

## 3. 落地顺序

| 阶段 | 内容 | 状态 / 验证 |
| --- | --- | --- |
| 已完成 | M1（tools/list 去 outputSchema）+ M2（token 预算）+ M3（LRU 结果缓存）+ M4（无损、可寻址 spill） | ✅ 全量 GUT 0 失败 + token 预算断言；204,211-byte 结果首包减少 95.62%，逐页 SHA-256 精确重建 |
| 已完成 | M6（巨型文件拆分 / 死代码 / 单一数据表 tools_manifest） | ✅ 导入门禁 + 计数一致（381e472 / dd0ecd5 / f26fdde） |
| 已追加 | tools/list 服务端缓存 + 确定性排序；结果缓存同时保存 formatted payload（命中跳过 JSON.stringify/spill 检查）；meta 发现工具（list_tool_catalog/search_tools/get_tool_details）纳入只读结果缓存；HTTP 轮询去除每轮 `_connections.duplicate()` | ✅ 全量 GUT 0 失败（678006f / f630cc9 / 3530489 / 7c67f8e） |
| 已完成 | M5（无损 list 分页 + revision 安全扫描快照） | ✅ 7 条稳定读路径补齐；跨页单扫描；8 项 / 4 MiB 门禁；写工具不以重执行换分页 |
| 已完成 | P3.3 工作流路由质量门禁 | ✅ 48 个中英真实制作任务 / 12 领域 / 174 个原子期望；Recall@8 与完整任务成功率 100%，验证阶段召回 97.30%，已知跨域误选 0，平均 Schema 节省 97.34%；默认预算仍为 8，未新增工具/Schema/模型调用 |
| 已完成 | P3.4 缓存可观测性与真实命中基线 | 无新增工具/Schema；统一量化 tools/list、结果 LRU、单飞、扫描快照、工作流路线与 spill。确定性“检查→编辑→运行→调试→验证”会话门禁记录结果复用 50%、路线 50%、tools/list 80%、快照 80%、spill 50%，并证明相关脚本精确失效、无关场景/项目信息保持命中；结果缓存新增 32 MiB 总预算 |
| 已完成 | P3.5 外部文件变更的事件驱动精确失效 | 接入 Godot 4.7 `EditorFileSystem` reload/reimport/source/class/filesystem、`EditorPlugin` resource/scene save 和 `ProjectSettings.settings_changed` 信号；同帧事件只合并、扫描一次，已知路径精确失效，新增/删除/重命名由路径集差分更新目录，无路径事件安全退化到文件域；保留 60 秒 TTL，不增加工具/Schema |
| 已完成 | P4 持久完整游戏闭环执行器 | 新增 2 个元工具；12 个可组合 profile；完整 DAG 可超过 10 步；隐藏原子工具不切换显隐；pending、CAS、蓝图完整性、保护路径和客观收据均有回归门禁 |
| 已完成 | P4.1 自适应目标完成与恢复 | 4/8/16/32 检查点只让步不截断；100 个显式原子能力可跨轮完成；陌生复合目标按语义子目标合并且未覆盖要求会明确澄清；安全读取/幂等调用可在重启后重放，未知写入停止；暂时失败退避、相同失败 3 次转重规划；默认响应不重复 DAG/Schema |
| 下轮 | P4.2 真实空项目端到端基准 | 在固定 Godot fixture 中实际完成可运行 2D 切片，记录任务成功率、调用/重试/MCP 往返、Schema/结果 token、重复扫描与自动修复成功率；作为以后所有优化的总门禁 |
