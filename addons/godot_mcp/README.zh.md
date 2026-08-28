# Godot MCP Native 插件目录

此目录是可分发的 Godot 插件。将 `addons/godot_mcp` 复制到任意 Godot 4.7 项目后，即可在编辑器内部运行 MCP 服务器。

## 目录内容

- `plugin.cfg` 与 `mcp_server_native.gd` — 编辑器插件入口。
- `native_mcp/` — JSON-RPC/MCP 核心、HTTP/SSE 与 stdio 传输、鉴权、设置、隧道和工具状态管理。
- `tools/` — 223 个 MCP 工具的实现。
- `runtime/mcp_runtime_probe.gd` — 可选 Autoload，用于检查和驱动运行中的游戏。
- `ui/` — MCP 停靠面板、工具管理器和详情视图。
- `translations/` — 面板文本和工具描述。

工具管理器提供 2D、3D、界面、资源与动画、调试与测试、发布与维护等任务视图，以及 12 个带用途和工具数量预览的实用预设。每个视图只筛选和切换其精选工具，同时保留现有核心/扩展层级与分组兼容性。

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

插件注册 223 个工具：

- 28 个核心工具默认启用。
- 189 个高级工具默认注册但不启用，可在面板或通过 `enable_tools` 开启。
- 6 个常驻元工具：四个发现工具，加上 `plan_game_workflow` 与 `run_game_workflow`。

完整目标由两个工作流工具把 12 类可复用制作能力编译为持久 DAG。DAG 可以超过 10 个原子能力，但每轮执行最多 4 次调用；隐藏工具不会引发显隐切换，只有客观证据齐全才会完成。短任务继续使用 `enable_tools`，其默认 8 个/硬上限 10 个的发现预算保持不变。

工具发现采用渐进且缓存友好的流程：把中英文目标作为 `workflow_query` 交给一次 `enable_tools` 调用，即可在本地完成路由，并原子启用有界的“检查/执行/验证”工具集。自适应路线覆盖全部 217 个非 Meta 原子工具，只返回名称且默认限制为 8 个工具；核心/元工具始终保留，上一任务的高级工具默认被替换，`replace_supplementary=false` 可显式增量装载。目录 revision 与依赖标签结果 revision 不会清空无关的场景、脚本和资源读取；脚本和资源按精确路径懒失效。

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
