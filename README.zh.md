# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.1.0-orange.svg)](docs/changelog.md)
[![Tools](https://img.shields.io/badge/MCP%20tools-232-blue.svg)](docs/tools/README.md)

> English documentation: [README.md](README.md)。

**让 AI 直接驱动 Godot。** Godot MCP Native 是一个 Godot 4.7 编辑器插件，会在 Godot 编辑器内部运行 [Model Context Protocol](https://modelcontextprotocol.io)（MCP）服务器。Claude、Cursor、Cline、Trae、OpenCode、Codex 等 MCP 客户端可以通过标准协议读取和修改场景、脚本、节点、资源，甚至检查正在运行的游戏。

插件不需要 Node.js 桥接、不需要 Python 守护进程，也不需要维护外部服务器。协议层由 GDScript 实现，并直接调用 Godot 编辑器和运行时 API。

## 亮点

- **原生服务器：** MCP 服务运行在 Godot 编辑器进程内，随插件一起发布。
- **双传输模式：** 默认 HTTP/SSE（`http://localhost:9080/mcp`），也支持面向本地进程客户端的 stdio。
- **233 个工具且默认面精简：** 28 个核心工具默认启用，199 个高级工具按需启用，另有 6 个常驻元工具负责发现、启用和完整游戏闭环。
- **运行时自动化：** Runtime Probe 可以检查实时场景树、求值表达式、注入输入、控制动画/音频/Shader/TileMap、截图并采集性能指标。
- **安全控制：** 支持 Bearer Token 鉴权、路径校验、限流和严格安全模式，优先使用 Godot API，避免任意系统命令执行。

## 安装

### Asset Library（推荐）

1. 在 Godot 中打开 **AssetLib**。
2. 搜索 **Godot MCP Native**。
3. 点击 **Download → Install**。
4. 在 **Project → Project Settings → Plugins** 中启用插件。

### 手动安装

将 `addons/godot_mcp` 复制到项目的 `addons/` 目录，然后在 **Project Settings → Plugins** 中启用 **Godot MCP Native**。

启用后，编辑器会出现新的 **MCP** 停靠面板。

完整步骤见 [Getting Started](docs/getting-started.md)。

## 30 秒连接

1. 在 **MCP** 面板中选择 **HTTP**，点击 **Start Server**。默认端点是 `http://localhost:9080/mcp`。
2. 在 MCP 客户端中配置：

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

3. 对 AI 助手说：`Get the Godot project info.` 客户端应调用 `get_project_info` 并返回项目元数据。

Claude Desktop、Cursor、Trae、Cline、OpenCode、Codex 的配置示例见 [Getting Started](docs/getting-started.md#5-connect-an-ai-client) 和 [Configuration](docs/configuration.md#client-configuration)。

## 工具范围

| 分类 | 工具数 | 核心 | 高级 | 覆盖内容 |
| --- | ---: | ---: | ---: | --- |
| [Node](docs/tools/node-tools.md) | 26 | 9 | 17 | 节点增删改查、层级编辑、信号、分组、锚点、批量编辑和场景审计 |
| [Script](docs/tools/script-tools.md) | 19 | 6 | 13 | 读取/创建/修改/锚点补丁/校验 GDScript 与 C#，Shader 校验、搜索、符号和引用 |
| [Scene](docs/tools/scene-tools.md) | 12 | 4 | 8 | 创建/打开/保存场景、结构检查、场景实例化和 TileMapLayer 单元格 |
| [Editor](docs/tools/editor-tools.md) | 27 | 3 | 24 | 运行/停止、截图、选择、Inspector、导出模板、脚本缓冲区和撤销/重做 |
| [Debug & Runtime](docs/tools/debug-tools.md) | 73 | 3 | 70 | 日志、调试器、性能分析、运行时探针、确定性游玩验证和回归门禁 |
| [Project](docs/tools/project-tools.md) | 69 | 3 | 66 | 设置、资源、输入映射、测试、迁移扫描、资产、TileSet、精灵表/glTF 和任务计划 |
| [Meta](docs/tools/meta-tools.md) | 6 | — | — | 常驻发现、按需启用和持久化完整游戏编排 |
| **总计** | **233** | **28** | **199** | |

启动时只有核心工具和元工具会出现在 `tools/list` 中。对于完整用户目标，`plan_game_workflow` 会把 12 类制作能力组合成持久目标 DAG，`run_game_workflow` 每轮最多推进 4 个已授权原子调用。完整 DAG 可以超过 10 个工具：既有 8/10 上限只约束单轮发现与上下文，不限制整个游戏能完成的能力。隐藏步骤沿用普通缓存且不切换显隐；异步工作持续轮询、修复次数有界，只有所有目标门禁都取得引擎签发的客观证据才返回 `completed`。未知目标、缺失能力、缺少输入、保护路径和无法验证的结果都会明确停止，不会静默跳过。详见[完整游戏工作流](docs/game-workflows.zh.md)。

对于短小的临时任务，最快路径仍是一次 `enable_tools({"workflow_query": "..."})` 调用：纯本地不可变能力索引把中英文目标路由为“检查 → 执行 → 验证”，并在同一次原子切换中从全部 227 个非 Meta 原子工具里启用最多 8 个，不复制 Schema。每个原子工具都可通过精确名称、官方英文说明或中文说明直接命中。预计算工具名签名与显式动作/对象证据先提高自然任务精度，再进入成本感知回退；均衡的 48 项中英制作任务门禁达到 Recall@8 和完整任务成功率 100%，平均高级工具 Schema 节省 97.34%。每个工具定义只在注册时估算一次 Schema token 成本；新增意图覆盖相同时，路由器优先选择“语义价值/增量 token”最高的候选，而精确原子请求始终拥有最高优先级。归一化任务目标复用最多 64 项的 LRU 路由缓存。工具显隐不会重建索引或清空路线，只有工具定义增删才失效，因此切换任务后仍保持高缓存命中。核心/元工具始终保留，默认替换上一任务的高级工具，使后续提示词更小且更利于缓存命中；仍支持增量装载、手工分组和 12 个预设。`search_tools` 保留用于预览路线和比较候选。目录 revision 保持发现响应精简；依赖标签缓存 revision 则保留无关的场景、脚本和资源读取，并按脚本/资源路径懒失效。详见 [Tools Reference](docs/tools/README.md)。

超大成功结果无需在首包支付全文上下文成本，但仍可无损取回。响应保留兼容的 head/tail 预览，并追加标准 MCP `resource_link`；`resources/read` 按完整内容的 SHA-256 寻址，以 UTF-8 安全的 16 KiB 固定页返回，持续跟随 `_meta.nextUri` 即可精确还原原始 JSON。动态结果链接不会进入 `resources/list`。关键错误以及源码/日志读取始终完整内联，落盘失败也会回退到完整内联结果。204 KiB Unicode 回归样本的首包减少 95.62%，同时校验逐字节完整重建。

高返回量的稳定读工具统一提供无损续页字段：`total_count`、`returned_count`、`has_more`、`next_offset`。项目资源和源码扫描的所有页面复用同一份 revision 安全快照，因此响应变小不会导致重复扫描；快照池最多 8 项、单项 4 MiB。带状态的写操作不会为了分页而重新执行，始终把正确性和功能收益放在 token、延迟优化之前。

缓存效率不再只靠孤立命中断言，而是由“检查 → 编辑 → 运行 → 调试 → 验证”的离线会话回放持续门禁。内部诊断统一统计请求、真实 handler 执行、顺序命中、单飞复用、陈旧淘汰、扫描快照、工具定义、工作流路线和内容寻址 spill 复用，不增加 MCP 工具或 Schema。共享结果 LRU 同时受 64 项和 32 MiB 序列化原始结果预算约束；因内存预算未缓存的值仍会在本次调用中完整返回。

外部编辑器变更现在会立即推进同一套 dependency revision。Godot 4.7 的文件系统 reload/reimport/source/class 信号、资源与场景保存、项目设置变更在每帧合并一次。已知路径只失效对应的精确脚本/资源依赖；路径集合差分识别新增、删除和重命名，再更新相关目录。无法解释的无路径事件会安全退化为所有文件域失效，60 秒 TTL 仍作为最终保险。整个链路不增加 MCP 工具或 Schema。

## 示例提示词

```text
在当前场景添加 Camera2D，并让它跟随玩家。
创建一个包含 Play、Options、Quit 按钮的主菜单场景。
读取我的移动脚本，并重构为状态机。
运行项目，然后报告实时 FPS、节点数量和最近的运行时错误。
启用 debugging 预设，执行一次确定性的跳跃测试并验证土狼时间。
规划并完成一个可玩的 2D 垂直切片，包含暂停菜单、测试和 Linux 导出冒烟验证。
```

## 配置速览

配置通过 MCP 面板管理，并持久化到 `user://mcp_settings.cfg`。

| 配置项 | 默认值 | 用途 |
| --- | --- | --- |
| `transport_mode` | `http` | `http` 表示 HTTP/SSE，`stdio` 表示本地进程传输 |
| `http_port` | `9080` | HTTP 监听端口 |
| `sse_enabled` | `true` | 启用支持 SSE 的 MCP 客户端所需事件流 |
| `auth_enabled` | `false` | 要求 `Authorization: Bearer <token>` 请求头 |
| `auth_token` | `""` | 启用鉴权时使用的 token |
| `auto_start` | `false` | 编辑器/插件加载时自动启动服务器 |
| `security_level` | `1` | `0` 宽松，`1` 严格路径和安全检查 |
| `rate_limit` | `1000` | 限流窗口内允许的请求数 |

无界面启动示例：

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

更多传输、鉴权、命令行覆盖、客户端片段和工具预设见 [Configuration](docs/configuration.md)。

## 环境要求

- Godot Engine 4.7，使用 GL Compatibility 渲染器。
- 插件运行本身不依赖 Node.js 或 Python。
- 只有 stdio-only 客户端通过 `mcp-remote` 桥接 HTTP 时才需要 `npx`。
- 运行集成测试和 GUT 单元测试时才需要 Python 3.8+、Godot/GUT。

## 文档

| 文档 | 用途 |
| --- | --- |
| [Getting Started](docs/getting-started.md) | 安装、启用和连接插件 |
| [完整游戏工作流](docs/game-workflows.zh.md) | 持久化多阶段规划、执行状态、客观证据与边界 |
| [Configuration](docs/configuration.md) | 端口、传输、鉴权、CLI 参数、客户端片段和预设 |
| [Remote & Cloud Access](docs/remote-access.md) | Cloudflare Quick Tunnel、Tailscale Funnel、ngrok 和公网 URL |
| [Architecture](docs/architecture.md) | 插件生命周期、核心服务、传输层、工具、运行时探针和安全模型 |
| [Tools Reference](docs/tools/README.md) | 所有 MCP 工具、层级和分类 |
| [Industrialization Guide](docs/industrialization/README.md) | 规划、资产生成、确定性游玩测试和迭代闭环 |
| [Testing](docs/testing.md) | GUT 单元测试、Python 集成测试和验证建议 |
| [Contributing](docs/contributing.md) | 代码规范、新增工具、文档清单和 PR 流程 |
| [Changelog](docs/changelog.md) | 版本记录 |

## 贡献

欢迎提交 Issue 和 Pull Request。新增工具或修改 MCP 行为前，请先阅读 [Contributing](docs/contributing.md)，确保代码、测试、翻译和文档同步更新。

## 许可证

本项目基于 [MIT License](LICENSE) 发布。

## 作者

**xianyu0514**

## 致谢

- Godot Engine 团队和社区。
- Model Context Protocol 规范与生态。
- Claude 等 MCP 客户端推动的 AI 助手工作流。

---

Godot MCP Native 是社区插件，与 Godot Engine、Anthropic 或任何 MCP 客户端厂商均无官方隶属关系。
