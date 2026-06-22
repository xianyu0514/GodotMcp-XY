# Contributing

Contributions are welcome. This page covers the conventions, the workflow for adding a tool,
and what to update so the docs stay in sync with the code.

## Coding conventions

### Language policy

- Comments and user-facing strings **may be written in Chinese or English** — choose
  whatever is clearest for the teams and customers using the plugin. Localized text is
  encouraged.
- Keep identifiers (variables, functions, class names) ASCII/English for GDScript tooling
  and cross-platform compatibility.

### GDScript style

- `snake_case` for variables, functions and methods; `PascalCase` for `class_name` types.
- Always use type hints: `var player: Player`, `func greet() -> String:`.
- Prefer signals for decoupled node-to-node communication.
- Editor plugin scripts are `@tool`. Non-node helpers extend `RefCounted`; the plugin entry
  point extends `EditorPlugin`.
- GUT test files use `extends "res://addons/gut/test.gd"` (no `class_name`).

### Error handling

- Tool handlers return an error dictionary on failure: `{"error": "message"}`.
- Validate arguments at the top of each handler.
- Avoid `assert()` in production code paths.

### Tests are mandatory

Every code change must come with test updates in `test/`:

- **Direct tests** for the changed logic (happy path + edge cases + errors).
- **Impact tests** for modules affected by signature, export-variable or signal changes.

Run the full [test suites](testing.md) and require zero failures.

## Adding a new tool

Complete every step, in order:

1. **Implement the handler.** In the matching `addons/godot_mcp/tools/*_tools_native.gd`,
   add `_register_<name>()` and `_tool_<name>()`. Register with the 8-argument
   `server_core.register_tool(name, description, input_schema, Callable, output_schema,
   annotations, category, group)`.
2. **Classify it.** Add an entry to `_build_classifications()` in
   `native_mcp/mcp_tool_classifier.gd`, then update the tool counts in
   `test/unit/.../test_mcp_tool_classifier.gd`.
3. **Add unit tests** under `test/unit/tools/` (missing/invalid args, edge cases).
4. **Add descriptions** to `translations/tool_descriptions.json` and
   `translations/tool_descriptions.csv`.
5. **Update the docs** (see below).
6. **Verify.** Run the full GUT suite with zero failures.

> New **advanced** tools are disabled by default (`enabled = (category == "core" or category
> == "meta")`) and won't appear in `tools/list` until enabled in the MCP panel — or, in tests,
> via `core.set_tool_enabled("<tool>", true)`. The `meta` category
> (`list_tool_catalog`, `enable_tools` in `meta_tools_native.gd`) is always enabled, is excluded
> from the 30-core cap, and is preserved by every preset so the model can discover and enable
> other tools on demand.

## Documentation update checklist

When you add or change a tool, keep these in sync:

- `docs/tools/<category>-tools.md` — add/adjust the tool row and the group count in its heading.
- `docs/tools/README.md` — update the category totals table.
- `README.md` and `README.zh.md` (root **and** `addons/godot_mcp/`) — update the tool counts.
- `addons/godot_mcp/translations/tool_descriptions.{json,csv}` — the new/changed description.
- `docs/architecture.md` — only if per-category counts change materially.

Verification:

- [ ] Repo-wide search confirms old counts are fully replaced.
- [ ] The new tool name appears in the relevant category page and translations.

## Pull request workflow

1. Branch from the integration branch and keep changes focused.
2. Implement with tests; run the full GUT suite (0 failures) and any relevant integration
   flow.
3. Self-review for code quality, conventions, and the documentation checklist above.
4. Open the PR with a clear summary of *what* changed and *why*.
5. Address review feedback, then merge (squash) once approved and green.

## Godot 4.7 gotchas

- The `float()` constructor is unavailable — use `as float`.
- `AnimationNodeStateMachine.set_start_node()` does not exist — use `add_node()`.
- Runtime TileMap tools target the legacy `TileMap`; edit-time
  `set_tilemap_layer_cells` / `get_tilemap_layer_cells` use the 4.x single-layer
  `TileMapLayer` API.
- In `execute_editor_script`, use `edited_scene` and `_custom_print()` — not `get_tree()`.
