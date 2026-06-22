# Getting Started

This guide takes you from an empty editor to an AI client calling a tool against your
project — usually in under ten minutes.

## 1. Requirements

| Requirement | Notes |
| --- | --- |
| Godot Engine 4.7 | GL Compatibility renderer; 4.7+ recommended. |
| An MCP-capable AI client | Claude Desktop, Cursor, Trae, Cline, OpenCode, Codex, … |
| `npx` / Node (optional) | Only needed for clients that connect through `mcp-remote`. |
| Python 3.8+ (optional) | Only for running the integration test suite. |

No runtime dependencies are required to *use* the plugin — the server is pure GDScript.

## 2. Install the plugin

### Option A — Asset Library (recommended)

1. Open your project in Godot.
2. Go to the **AssetLib** tab.
3. Search for **"Godot MCP Native"**, then **Download** and **Install**.

### Option B — Manual

1. Clone or download this repository.
2. Copy the `addons/godot_mcp` folder into your project's `addons/` directory.
3. Reopen the project in Godot.

## 3. Enable the plugin

1. Open **Project → Project Settings → Plugins**.
2. Find **Godot MCP Native** and set its status to **Enable**.

A new **MCP** dock panel appears. From it you can start/stop the server, switch transport
mode, manage authentication, browse logs, and enable individual tools.

## 4. Start the server

In the **MCP** panel:

1. Choose a transport mode (**HTTP** is the default and works with every client below).
2. Confirm the port (default **`9080`**).
3. Click **Start**.

The server now listens on `http://localhost:9080/mcp`. See [Configuration](configuration.md)
for authentication, SSE, the stdio transport, headless launch, and CLI flags.

## 5. Connect an AI client

All snippets assume HTTP mode on the default port. For authentication and other transports,
see [Configuration → Client configuration](configuration.md#client-configuration).

> Tip: instead of copying the snippets below by hand, use the **Copy Config** menu in the
> panel's status bar — it builds the HTTP or stdio configuration for you with the current
> port and auth token filled in. See
> [Configuration → Generate snippets from the panel](configuration.md#generate-snippets-from-the-panel).

### Claude Desktop

Claude Desktop connects through the `mcp-remote` bridge:

```bash
npm install mcp-remote
```

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9080/mcp"]
    }
  }
}
```

### Cursor / Trae

```json
{
  "mcpServers": {
    "godot-mcp": { "url": "http://localhost:9080/mcp" }
  }
}
```

### Cline

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

### OpenCode

```json
{
  "mcp": {
    "godot-mcp": { "type": "remote", "url": "http://localhost:9080/mcp" }
  }
}
```

### Codex

```toml
[mcp_servers.godot-mcp]
type = "streamableHttp"
url = "http://localhost:9080/mcp"
```

## 6. Make your first call

Ask your AI client something that maps to a core tool, for example:

> "Get the Godot project info."

The client should call `get_project_info` and return the project name, version and
description. From there you can drive the editor in natural language:

> "Add a `Camera2D` to the current scene and centre it on the player."
>
> "Read my player movement script and suggest improvements."
>
> "Create a main menu scene with Play, Options and Quit buttons."

Only the 30 **core** tools (plus 2 always-on **meta** tools) are available immediately. To
unlock the other 172, enable them in the MCP panel — or let the AI do it on demand via the
`list_tool_catalog` / `enable_tools` meta tools. See the
[Tools Reference](tools/README.md#enabling-advanced-tools) and
[Meta tools](tools/README.md#meta-tools-tool-discovery).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Plugin missing from the editor | Re-check **Project Settings → Plugins**; confirm `addons/godot_mcp` exists; restart Godot. |
| Server won't start — port in use | Change the port in the MCP panel, or free `9080` (`netstat -ano \| findstr :9080` on Windows, `lsof -i :9080` on macOS/Linux). |
| `401 Unauthorized` | Auth is enabled — send `Authorization: Bearer <token>` and make sure the token matches the panel. |
| Client sees no tools | The tool may be **advanced** and disabled by default — enable it in the MCP panel. |

## Next steps

- [Configuration](configuration.md) — transports, auth, persistence, CLI flags.
- [Tools Reference](tools/README.md) — every tool, by category.
- [Architecture](architecture.md) — how it all fits together.
