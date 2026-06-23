# Godot MCP Native

[![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.7--pre1-orange.svg)](../../docs/changelog.md)

> English: [README.md](README.md)

一个在 **Godot 内部**运行 [Model Context Protocol](https://modelcontextprotocol.io)（MCP）服务器的
编辑器插件，让 Claude、Cursor、Cline、Codex 等 AI 助手通过标准协议读取并修改你的项目——场景、脚本、
节点、资源，乃至运行中的游戏。服务器纯 GDScript 实现：**无需 Node.js、无需 Python、无需外部桥接**。

## 亮点

- **212 个 MCP 工具**，分 6 类（30 个核心默认开启；180 个高级按需启用），外加 2 个用于工具发现的常驻元工具（`list_tool_catalog`、`enable_tools`）。
- **HTTP/SSE**（默认端口 `9080`）与 **stdio** 双传输。
- **运行时探针**：检查并操控*运行中的*游戏，而不止于编辑期状态。
- 可选 **Bearer Token 鉴权**、路径校验，以及可配置的安全级别。

## 快速开始

1. 在 **项目 → 项目设置 → 插件** 中启用插件。
2. 在 **MCP** 停靠面板选择 **HTTP** 并点击 **Start**（默认端口 `9080`）。
3. 将 AI 客户端指向 `http://localhost:9080/mcp`：

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

4. 让 AI「获取 Godot 项目信息」以确认连接成功。

## 工具

| 分类 | 工具数 | 分类 | 工具数 |
| --- | ---: | --- | ---: |
| 节点 | 26 | 编辑器 | 23 |
| 脚本 | 17 | 调试与运行时 | 73 |
| 场景 | 12 | 项目 | 59 |

默认仅开启 30 个核心工具；高级工具可在 MCP 面板中启用。
完整清单见 [工具参考](../../docs/tools/README.md)。

## 配置

所有设置都在 MCP 面板中调整，并持久化到 `user://mcp_settings.cfg`
（`transport_mode`、`http_port`、`auth_enabled`、`auth_token`、`sse_enabled` 等）。
无头启动：`godot --editor --path <project> -- --mcp-server --mcp-port=9080`。

完整说明见 [配置文档](../../docs/configuration.md)。

## 文档

[快速开始](../../docs/getting-started.md) ·
[配置](../../docs/configuration.md) ·
[架构](../../docs/architecture.md) ·
[工具](../../docs/tools/README.md) ·
[测试](../../docs/testing.md) ·
[贡献](../../docs/contributing.md)

## 许可证

[MIT](LICENSE) · **作者：** xianyu0514

*社区插件，与 Godot 引擎及 Anthropic 均无官方隶属关系。*
