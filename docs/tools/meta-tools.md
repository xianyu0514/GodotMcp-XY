# Meta Tools

[← Tools reference](README.md)

**2 tools** — always on (a dedicated `meta` category, separate from the 30 core / 174 advanced split).

These tools power **lazy tool loading**: the server exposes only a small default set (~30 core tools plus these 2 meta tools) so `tools/list` stays small and token-cheap, while the full toolset remains reachable on demand. The model discovers what it needs with `list_tool_catalog`, then switches it on with `enable_tools`.

> Meta tools are **never disabled** — not by the `minimal_core` preset, not via the MCP panel, and not by restored persisted state (the invariant is enforced in `set_tool_enabled` / `set_group_enabled`). This guarantees the model can always re-discover and re-enable other tools even from the smallest profile.
>
> The discover-then-enable workflow is also returned in the MCP `initialize` response's `instructions` field, so compatible clients inject it into the model's context automatically — no manual prompt setup required.

### Meta (2)

| Tool | Tier | Description |
| --- | --- | --- |
| `list_tool_catalog` | Always-on | List the registered MCP tools grouped by category, with a one-line description and each tool's enabled state — **without** loading every full tool schema. Filter by `group` or `query`, or pass `enabled_only` / `include_descriptions` to shrink the response. |
| `enable_tools` | Always-on | Enable or disable MCP tools on demand. Pass `tools` and/or `groups` (with `enabled`, and optional `exclusive` to reset to a core-only baseline first), or `preset` to apply a curated profile wholesale (`minimal_core`, `level_design`, `debugging`, `automation_qa`, `art_resources`, `all`). Emits `notifications/tools/list_changed` so the client refreshes its tool list. Core and meta tools always stay enabled. |

### Lazy-loading workflow

```
minimal_core (~32 visible tools)
  -> list_tool_catalog({group: "Debug-Advanced"})   # discover, cheap (no schemas)
  -> enable_tools({preset: "debugging"})            # or {groups: [...]} / {tools: [...]}
  -> the enabled tools now appear in tools/list and can be called directly
```

See the [task → preset guide](../configuration.md#tool-presets) for choosing the smallest preset per task.
