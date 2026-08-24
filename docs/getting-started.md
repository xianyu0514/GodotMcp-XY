# Getting Started

This guide takes a fresh Godot project from install to a working MCP connection.

## 1. Requirements

- Godot Engine 4.7 with the GL Compatibility renderer.
- A project where editor plugins can be enabled.
- An MCP client such as Claude Desktop, Cursor, Trae, Cline, OpenCode, Codex or any generic MCP client.
- Optional: `npx` if your client is stdio-only and must bridge to HTTP with `mcp-remote`.

## 2. Install the plugin

### Option A — Asset Library

1. Open **AssetLib** in Godot.
2. Search for **Godot MCP Native**.
3. Click **Download → Install**.
4. Leave `addons/godot_mcp` selected when Godot asks which files to install.

### Option B — Manual copy

Copy this repository's `addons/godot_mcp` folder into your project's `addons/` directory:

```text
your-project/
└── addons/
    └── godot_mcp/
        ├── plugin.cfg
        ├── mcp_server_native.gd
        └── ...
```

## 3. Enable the plugin

1. Open **Project → Project Settings → Plugins**.
2. Enable **Godot MCP Native**.
3. Confirm that an **MCP** dock appears in the editor.

If the panel does not appear, close and reopen the project, then check the Output panel for plugin load errors.

## 4. Start the server

1. Open the **MCP** dock.
2. Use the default transport, **HTTP**.
3. Keep the default port, `9080`, unless another process already uses it.
4. Click **Start Server**.

The local endpoint is:

```text
http://localhost:9080/mcp
```

To start automatically from a script or headless editor session:

```bash
godot --editor --path /absolute/path/to/project -- --mcp-server --mcp-port=9080
```

## 5. Connect an AI client

### Direct HTTP clients: Cursor, Trae, Cline, OpenCode, Codex and generic MCP clients

Use the URL form when the client supports HTTP MCP servers:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp"
    }
  }
}
```

If auth is enabled in the MCP panel, include the Bearer token:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "url": "http://localhost:9080/mcp",
      "headers": {
        "Authorization": "Bearer your-secret-token-here"
      }
    }
  }
}
```

### Claude Desktop and other stdio-only clients

Use `mcp-remote` to bridge stdio to the HTTP endpoint:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "http://localhost:9080/mcp"
      ]
    }
  }
}
```

For a pure stdio Godot process, launch Godot as the MCP server process:

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "path/to/godot",
      "args": [
        "--editor",
        "--headless",
        "--path",
        "/absolute/path/to/your/godot/project",
        "--",
        "--mcp-server",
        "--mcp-transport=stdio"
      ]
    }
  }
}
```

## 6. Verify the connection

Ask your assistant:

```text
Get the Godot project info.
```

A healthy connection returns a result from `get_project_info` containing the project name and metadata.

Then try a read-only prompt:

```text
List the current scene tree and summarize the top-level nodes.
```

## 7. Enable advanced tools only when needed

At startup, the client sees the 28 core tools plus 4 meta tools. For specialized workflows:

- In the editor, open the tool manager in the MCP panel and toggle a group.
- From the client, call `list_tool_catalog` to discover tools and `enable_tools` to enable names, groups or presets.

Example workflow:

```text
Use list_tool_catalog to show Debug-Advanced tools, then enable the debugging preset.
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Client cannot connect | Confirm the MCP panel says the server is running and that the client URL ends with `/mcp`. |
| Port is busy | Change `http_port` in the panel or launch with `--mcp-port=<port>`. |
| Auth errors | Disable auth temporarily or ensure the client sends `Authorization: Bearer <token>`. |
| Advanced tool missing | Enable its group from the MCP panel or with `enable_tools`. |
| stdio client cannot use HTTP URL | Use `mcp-remote` or launch Godot with `--mcp-transport=stdio`. |
| Remote/cloud client cannot reach localhost | Use [Remote & Cloud Access](remote-access.md). |

## Next steps

- Review [Configuration](configuration.md) for auth, presets and CLI flags.
- Browse [Tools Reference](tools/README.md) before granting broad advanced tool access.
- Read [Testing](testing.md) if you plan to contribute code or tools.
