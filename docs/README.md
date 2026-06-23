# Godot MCP Native — Documentation

This folder is the documentation hub for Godot MCP Native, a Godot 4.7 editor plugin that runs an MCP server inside the editor and exposes project/editor/runtime operations to AI assistants.

## Choose your path

| Goal | Read |
| --- | --- |
| Install the plugin and connect an AI client | [Getting Started](getting-started.md) |
| Tune ports, transports, auth, CLI flags and tool presets | [Configuration](configuration.md) |
| Expose the local MCP server to remote/cloud clients | [Remote & Cloud Access](remote-access.md) |
| Understand internals before changing code | [Architecture](architecture.md) |
| Browse every MCP tool | [Tools Reference](tools/README.md) |
| Build a production-style AI game loop | [Industrialization Guide](industrialization/README.md) |
| Run unit/integration tests | [Testing](testing.md) |
| Add a tool or contribute a PR | [Contributing](contributing.md) |
| Check release history | [Changelog](changelog.md) |

## Key facts

- **Engine:** Godot 4.7, GL Compatibility renderer.
- **Entry point:** `addons/godot_mcp/mcp_server_native.gd`.
- **Default endpoint:** `http://localhost:9080/mcp`.
- **Tool count:** 214 total = 30 core + 182 advanced + 2 always-on meta tools.
- **Runtime dependency:** none for the plugin itself; testing may require Godot/GUT and Python.
- **Primary config file:** `user://mcp_settings.cfg`.

## Documentation maintenance rules

When code behavior changes, update the matching page in the same PR:

- New/changed tool → category page under `docs/tools/`, [Tools Reference](tools/README.md), translations and tests.
- New setting or CLI flag → [Configuration](configuration.md) and any client snippets.
- Runtime probe behavior → [Architecture](architecture.md), [Debug & Runtime Tools](tools/debug-tools.md) and [Testing](testing.md).
- Remote/tunnel behavior → [Remote & Cloud Access](remote-access.md) and configuration examples.
