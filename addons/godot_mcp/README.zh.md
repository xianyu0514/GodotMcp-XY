# Godot MCP Native 插件目录

此目录是可分发的 Godot 插件。将 `addons/godot_mcp` 复制到任意 Godot 4.7 项目后，即可在编辑器内部运行 MCP 服务器。

## 目录内容

- `plugin.cfg` 与 `mcp_server_native.gd` — 编辑器插件入口。
- `native_mcp/` — JSON-RPC/MCP 核心、HTTP/SSE 与 stdio 传输、鉴权、设置、隧道和工具状态管理。
- `tools/` — 215 个 MCP 工具的实现。
- `runtime/mcp_runtime_probe.gd` — 可选 Autoload，用于检查和驱动运行中的游戏。
- `ui/` — MCP 停靠面板、工具管理器和详情视图。
- `translations/` — 面板文本和工具描述。

## 快速开始

1. 将本目录复制到项目的 `res://addons/godot_mcp`。
2. 在 **Project → Project Settings → Plugins** 中启用 **Godot MCP Native**。
3. 打开 **MCP** 面板并点击 **Start Server**。
4. 将 MCP 客户端连接到 `http://localhost:9080/mcp`。

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

## 工具模型

插件注册 215 个工具：

- 30 个核心工具默认启用。
- 183 个高级工具默认注册但不启用，可在面板或通过 `enable_tools` 开启。
- 2 个常驻元工具：`list_tool_catalog` 与 `enable_tools`。

完整列表见项目级 [Tools Reference](../../docs/tools/README.md)。

## 配置

配置在 MCP 面板中修改，并保存到 `user://mcp_settings.cfg`。常用配置包括 `transport_mode`、`http_port`、`auth_enabled`、`auth_token`、`auto_start`、`security_level`、`rate_limit` 和 `sse_enabled`。

无界面启动：

```bash
godot --editor --path /path/to/project -- --mcp-server --mcp-port=9080
```

## 文档

建议从仓库 [README](../../README.md)、[Getting Started](../../docs/getting-started.md)、[Configuration](../../docs/configuration.md) 和 [Tools Reference](../../docs/tools/README.md) 开始。

## 许可证

MIT。详见 [LICENSE](../../LICENSE)。
