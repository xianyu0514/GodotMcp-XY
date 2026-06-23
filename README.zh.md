# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.7--pre1-orange.svg)](docs/changelog.md)
[![Tools](https://img.shields.io/badge/MCP%20tools-211-blue.svg)](docs/tools/README.md)

> English documentation: [README.md](README.md)

**让 AI 助手直接操控 Godot。** Godot MCP Native 是一个编辑器插件，它在 Godot **内部**运行一个
[Model Context Protocol](https://modelcontextprotocol.io)（MCP）服务器，使 Claude、Cursor、
Cline、Codex 等 AI 客户端能够通过自然语言读取并修改你的项目——场景、脚本、节点、资源，乃至**正在
运行的游戏**。

无需 Node.js，无需 Python 桥接，也没有额外进程需要维护。协议完全用 GDScript 实现，直接与引擎对话。

---

## 为什么选择它

- **原生、零依赖** —— MCP 服务器是编辑器进程的一部分，不必另外安装或常驻任何程序。
- **双传输** —— 默认 HTTP/SSE（端口 `9080`），适合编辑器与远程客户端；同时支持本地进程使用的 stdio。
- **211 个工具，分级合理** —— 30 个高价值「核心」工具默认开启；另有 179 个「高级」工具按需一键启用，外加 2 个常驻「元」工具用于工具发现。
- **感知运行时** —— 探针让 AI 不仅能编辑，还能检查与操控**运行中的游戏**：实时场景树、表达式求值、
  输入注入，以及动画 / 音频 / 着色器 / 瓦片地图控制。
- **天生安全** —— 可选 Bearer Token 鉴权、路径校验，并以引擎 API 取代调用系统命令。

## 安装

**资源库（推荐）：** 在 Godot 中打开 **AssetLib**，搜索 **“Godot MCP Native”**，依次 **下载 → 安装**。

**手动安装：** 将 `addons/godot_mcp` 复制到你项目的 `addons/` 目录。

随后在 **项目 → 项目设置 → 插件** 中启用它，编辑器会出现一个 **MCP** 停靠面板。

➡️ 完整步骤见 [docs/getting-started.md](docs/getting-started.md)

## 30 秒接入

1. 在 **MCP** 面板选择 **HTTP** 并点击 **Start**（默认端口 `9080`）。
2. 将客户端指向 `http://localhost:9080/mcp`：

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

3. 对 AI 说：「获取 Godot 项目信息」——它会调用 `get_project_info`，连接即告成功。

Claude Desktop、Cursor、Trae、Cline、OpenCode、Codex 的配置片段见
[快速开始](docs/getting-started.md#5-connect-an-ai-client) 与
[配置](docs/configuration.md#client-configuration)。

## AI 能做什么

插件提供 **211 个工具**，分为六大类（外加 2 个用于工具发现的常驻「元」工具），每一类都有完整的逐工具参考。

| 分类 | 工具数 | 涵盖内容 |
| --- | ---: | --- |
| [节点 Node](docs/tools/node-tools.md) | 26 | 创建/编辑节点、信号、分组、锚点、批量编辑、审计 |
| [脚本 Script](docs/tools/script-tools.md) | 17 | 读写/校验 GDScript 与 C#、搜索、符号索引 |
| [场景 Scene](docs/tools/scene-tools.md) | 12 | 创建/打开/保存场景、结构查看、预制体实例化、瓦片地图 |
| [编辑器 Editor](docs/tools/editor-tools.md) | 23 | 运行/停止、截图、选择、检查器、导出、缓冲区同步 |
| [调试与运行时 Debug](docs/tools/debug-tools.md) | 73 | 日志、调试器、断点、性能分析、实时运行时控制 |
| [项目 Project](docs/tools/project-tools.md) | 58 | 设置、资源、输入映射、审计、4.7 迁移、资产生成、精灵图/glTF 资产闭环、任务计划 |
| [元 Meta](docs/tools/README.md#meta-tools-tool-discovery) | 2 | 常驻的工具发现与按需启用（`list_tool_catalog`、`enable_tools`） |

默认仅启用 30 个**核心**工具（外加 2 个常驻**元**工具）；其余 179 个**高级**工具可在 MCP 面板中按需启用。详见
[工具参考](docs/tools/README.md)。

### 示例提示词

```
在当前场景中添加一个 Camera2D，并让它跟随玩家。
创建一个包含 Play、Options、Quit 按钮的主菜单场景。
读取我的移动脚本，并重构为状态机实现。
运行项目，然后告诉我实时 FPS 和节点数量。
```

## 配置

所有配置都可在 MCP 面板中完成，并持久化到 `user://mcp_settings.cfg`。

| 设置项 | 默认值 | 设置项 | 默认值 |
| --- | --- | --- | --- |
| `transport_mode` | `http` | `sse_enabled` | `true` |
| `http_port` | `9080` | `auto_start` | `false` |
| `auth_enabled` | `false` | `security_level` | `1` |
| `auth_token` | `""` | `rate_limit` | `1000` |

无头启动与命令行覆盖：

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

➡️ 详情见 [docs/configuration.md](docs/configuration.md)

## 环境要求

- Godot 引擎 4.7（GL Compatibility 渲染器）。
- 无运行时依赖。仅当客户端通过 `mcp-remote` 连接时才需要 `npx`；仅运行集成测试时才需要 Python 3.8+。

## 文档

- [快速开始](docs/getting-started.md)
- [配置](docs/configuration.md)
- [架构](docs/architecture.md)
- [工具参考](docs/tools/README.md)
- [测试](docs/testing.md)
- [贡献指南](docs/contributing.md)
- [更新日志](docs/changelog.md)

## 贡献

欢迎提交 Issue 与 Pull Request。请先阅读 [docs/contributing.md](docs/contributing.md)，了解编码规范、
新增工具流程以及文档更新清单。

## 许可证

基于 [MIT 许可证](LICENSE) 发布。

## 作者

**xianyu0514**

## 致谢

- Godot 引擎团队。
- Model Context Protocol 规范及其社区。
- 启发本集成的 Anthropic Claude。

---

*社区插件，与 Godot 引擎及 Anthropic 均无官方隶属关系。*
