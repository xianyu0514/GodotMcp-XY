# Godot MCP Native — Documentation

Godot MCP Native is a Godot 4.7 `EditorPlugin` that runs a **Model Context Protocol
(MCP) server inside the editor**. It exposes the project — scenes, scripts, nodes,
resources and the running game — to AI assistants over a standard protocol, with **no
Node.js, Python, or external bridge process** required.

This folder is the documentation root. Pick a path below based on what you want to do.

## Start here

| If you want to… | Read |
| --- | --- |
| Install the plugin and connect an AI client | [Getting Started](getting-started.md) |
| Tune ports, transports, authentication and CLI flags | [Configuration](configuration.md) |
| Reach the server from a remote client / the cloud | [Remote & Cloud Access](remote-access.md) |
| Understand how the server is built | [Architecture](architecture.md) |
| Browse every tool the AI can call | [Tools Reference](tools/README.md) |
| Have the AI build a whole game (asset + planning + iteration loops) | [Industrialization Guide](industrialization/README.md) |
| Run the unit and integration test suites | [Testing](testing.md) |
| Add a tool or send a pull request | [Contributing](contributing.md) |
| See what changed between versions | [Changelog](changelog.md) |

## At a glance

- **Native** — the MCP server is implemented in GDScript and runs in the editor process.
- **Two transports** — HTTP/SSE (default, port `9080`) and stdio.
- **205 tools** in 6 categories — 30 enabled by default ("core"), 173 opt-in ("advanced"), plus 2 always-on "meta" tools for tool discovery.
- **Runtime-aware** — a probe autoload lets the AI inspect and drive a *running* game,
  not just edit-time state.
- **Secure by design** — optional Bearer-token auth, path validation, and a configurable
  security level instead of shelling out to the OS.

## Configuration examples

Ready-to-copy MCP client snippets live in [`configuration/`](configuration/):

- [`mcp-http-config-example.json`](configuration/mcp-http-config-example.json)
- [`mcp-stdio-config-example.json`](configuration/mcp-stdio-config-example.json)

## Project facts

- **Author:** xianyu0514
- **License:** [MIT](../LICENSE)
- **Engine:** Godot 4.7 (GL Compatibility renderer)
- **Plugin entry point:** `addons/godot_mcp/mcp_server_native.gd`
