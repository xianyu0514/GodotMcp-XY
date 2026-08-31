# Godot MCP Native — Documentation

This folder is the documentation hub for Godot MCP Native, a Godot 4.7 editor plugin that runs an MCP server inside the editor and exposes project/editor/runtime operations to AI assistants.

## Choose your path

| Goal | Read |
| --- | --- |
| Install the plugin and connect an AI client | [Getting Started](getting-started.md) |
| Complete a multi-phase game goal with objective evidence | [Complete Game Workflows](game-workflows.md) |
| [Goal Playbook](goal-playbook.md) | Phrase goals, pick a path, know what counts as done, debug stalls |
| Tune ports, transports, auth, CLI flags and tool presets | [Configuration](configuration.md) |
| Expose the local MCP server to remote/cloud clients | [Remote & Cloud Access](remote-access.md) |
| Understand internals before changing code | [Architecture](architecture.md) |
| Read the full design: modules, data flow, trade-offs | [System Design](system-design.md) · [Architecture Diagrams](architecture-diagrams.html) |
| Browse every MCP tool | [Tools Reference](tools/README.md) |
| Build a production-style AI game loop | [Industrialization Guide](industrialization/README.md) |
| Run unit/integration tests | [Testing](testing.md) |
| Add a tool or contribute a PR | [Contributing](contributing.md) |
| Check release history | [Changelog](changelog.md) |

## Key facts

- **Engine:** Godot 4.7, GL Compatibility renderer.
- **Entry point:** `addons/godot_mcp/mcp_server_native.gd`.
- **Default endpoint:** `http://localhost:9080/mcp`.
- **Tool count:** 232 total = 28 core + 198 advanced + 6 always-on meta tools.
- **Runtime dependency:** none for the plugin itself; testing may require Godot/GUT and Python.
- **Primary config file:** `user://mcp_settings.cfg`.

## Documentation maintenance rules

When code behavior changes, update the matching page in the same PR:

- New/changed tool → category page under `docs/tools/`, [Tools Reference](tools/README.md), translations and tests.
- Caching, revision tags, transport or queueing changes → [System Design](system-design.md) and matching unit tests.
- Tool count / category / group changes → `tools_manifest.gd`, [System Design](system-design.md) and the classifier consistency tests. Verify the inline counts in `tools_manifest.gd` header comments and `SERVER_INSTRUCTIONS` in `mcp_server_core.gd` still match the manifest.
- Workflow compiler, runner or evidence behavior → [Complete Game Workflows](game-workflows.md), [Architecture](architecture.md) and workflow quality tests.
- New setting or CLI flag → [Configuration](configuration.md) and any client snippets.
- Runtime probe behavior → [Architecture](architecture.md), [Debug & Runtime Tools](tools/debug-tools.md) and [Testing](testing.md).
- Remote/tunnel behavior → [Remote & Cloud Access](remote-access.md) and configuration examples.
