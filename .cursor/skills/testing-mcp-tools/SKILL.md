---
name: testing-mcp-tools
description: "在 Godot 编辑器中通过 HTTP 端到端实测 MCP 工具（尤其是补充类工具）。使用场景：验证新增/修改的 MCP 工具在真实运行的编辑器里能被启用并正确执行，核对生成的资源文件。"
---

# End-to-End Testing of Godot MCP Tools (HTTP)

验证 MCP 工具在真实运行的 Godot 编辑器里端到端可用：注册 → 启用 → HTTP 调用 → 核对副作用（生成/修改的资源文件）。GUT 单测覆盖参数校验/错误分支；本流程覆盖运行时集成。

## 环境

- Godot 二进制：`/home/ubuntu/godot-bin/godot`（4.7-stable）。仓库标称 4.6 但 4.7 也能跑，注意 4.7 会在编辑器导入时改写 `project.godot`（测试用不必还原；提交代码时才需还原）。
- 启动编辑器（GUI，需 DISPLAY=:0）：
  ```
  DISPLAY=:0 nohup /home/ubuntu/godot-bin/godot --editor --path /home/ubuntu/repos/GodotMcp-XY > /tmp/godot_editor.log 2>&1 &
  ```
  首次启动会导入资源，约 1–3 分钟。Vulkan 报错（`rendering_context_driver_vulkan`）可忽略，会回退。

## 关键事实（已验证）

- **MCP 服务不会自动启动**：`Auto Start` 默认未勾。需在 MCP 主屏面板（顶部中间 `MCP` 按钮）→ Settings 标签 → 点 **Start Server**。绑定 `http://localhost:9080/mcp`。默认无鉴权（`Enable Auth` 未勾），curl 无需 token。
- **补充工具默认禁用**：`tools/list` 只返回已启用工具（核心 30 个）。补充工具要在面板 **Tool Manager** 标签里勾选启用。计数显示在表头：`Core: 30/30 | Supp: N/166 | Total: M/196`。
- **工具按组排列**：核心组在前，之后是 `*-Advanced` 组。动画/主题/项目配置工具在 **Project-Advanced** 组（很靠下，需大量向下滚动）。
- **JSON-RPC 参数键是 `arguments`，不是 `params`**：`mcp_server_core.gd:_handle_tool_call` 读 `params.arguments`。这是最容易踩的坑——用错键不会报错，工具会按缺省参数跑或报缺参。
- **禁用态调用**返回 `{"isError":true,"content":[{"text":"Tool is disabled: <name>"}]}`；未注册返回 `Tool not found`。用这两者区分"注册了但禁用" vs "根本没注册"。
- **FileSystem 不会自动发现新文件**：MCP 工具在编辑器进程内写文件后，FileSystem dock 不立即刷新。**切换窗口焦点离开再回到 Godot** 会触发重扫描（点任务栏其它窗口→点回 Godot 标题栏），新文件夹就出现了。
- `res://` = 项目根 = `/home/ubuntu/repos/GodotMcp-XY`。

## 调用模板

```bash
H=(-s -H "Content-Type: application/json" -X POST http://127.0.0.1:9080/mcp)
# 列举已启用工具
curl "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
# 调用工具（注意 params.arguments）
curl "${H[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}'
```
返回里 `result.structuredContent` 是结构化结果，`result.content[0].text` 是 JSON 字符串副本。

## 标准测试流程

1. 启动编辑器，Start Server，`curl GET /mcp` 确认端点活着。
2. **前置态证据**：`tools/list`（补充工具不在列）+ 禁用态 `tools/call`（返回 `Tool is disabled`）。截 Tool Manager 表头（`Total: x/196`）。
3. 在 Tool Manager 勾选目标工具；确认表头 `Supp` 计数 +N，`tools/list` 现在含这些工具。
4. HTTP 调用工具的黄金路径（带具体参数与期望值）。
5. **核对副作用**：直接 `cat` 生成的 `.tres`（文本资源），逐字段比对（如 `length`、`loop_mode = 2` 即 PINGPONG、`tracks/*/path`、keys 数组）。在编辑器里打开该资源，Inspector 应显示正确元数据，且无导入错误。

## 证据要点（adversarial）

- 工具数必须恰好是 `Total: x/196`——少一个说明分类器/注册漏了。
- `loop_mode` 等枚举要核对落盘的整数值（`.tres` 存 `loop_mode = 2`），不只是返回字符串。
- `insert_animation_keys` 插入超过当前 `length` 的关键帧时，`length` 应自动增长（如 1.0→1.5）。
- 颜色用十六进制字符串（`"#ff0000"`，经 `Color.from_string` 解析）；Vector3 用 `[x,y,z]` 或 `{x,y,z}`；四元数轨用 `[x,y,z,w]` 或欧拉 `[x,y,z]`。

## Devin Secrets Needed

无。MCP HTTP 服务默认无鉴权，仅本地回环访问。
