---
name: godot-mcp-game-development
description: Develop, debug, verify, and ship Godot games through the Godot MCP Native server. Use when a task targets a Godot project connected to this MCP; do not use for editing the MCP server implementation itself.
---

# Godot MCP Game Development

Drive work as a durable evidence-backed loop while keeping the active tool surface small.

## Orient and resume

1. Call `get_project_context` first. Retain its `revision` and `section_revisions`; later pass `known_revision` or `known_section_revisions` to avoid repeating unchanged context.
2. Resume an existing task plan. For multi-step work without one, enable `Project-Advanced` and initialize `manage_task_plan`.
3. Use `search_tools` and `get_tool_details` before enabling supplementary groups. Enable only the groups needed for the current phase.
4. Read focused scenes, nodes, scripts, resources, or engine class metadata only after orientation identifies them.

## Execute recoverably

- Claim ready work with `manage_task_plan(action="claim")`. Save a `checkpoint` after each coherent mutation or verification result.
- Prefer one previewed, revision-guarded `apply_project_change_set` when changes cross files, project settings, node properties, or scene structure.
- Use focused tools for edits outside the transaction schema. Preserve existing style, APIs, paths, and input actions.
- On recoverable failure, call `manage_task_plan(action="fail", error_message="...", data={...})` with concise evidence and a retry point. Do not repeat an external or destructive operation without new evidence.

## Verify observable behavior

- Use the cheapest relevant gate first: script/import checks, focused tests, runtime checks, then export.
- For gameplay or UI work, enable `Debug-Advanced`, install the runtime probe when needed, and use UI semantics plus `visual_playtest`. Prefer semantic paths and rectangles over guessed coordinates.
- Feed measurements into DoD gates with `set_dod observed=...`; mark done only after all criteria pass.
- On failure, inspect the smallest relevant context, fix the cause, and rerun the affected gate before broader validation.

## Finish

Checkpoint final evidence, mark the task done, request the next ready task, and continue until no ready or in-progress work remains. Report a blocker only when persisted evidence shows that new authority, credentials, or external state is required.
