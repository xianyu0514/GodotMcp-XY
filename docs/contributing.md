# Contributing

Contributions are welcome. Keep changes focused and update code, tests, translations and documentation together.

## Coding conventions

### Language policy

- Comments and user-facing text may be Chinese or English; choose the language that is clearest for users and maintainers.
- Identifiers, file names, function names and class names should remain ASCII/English for GDScript tooling and cross-platform compatibility.

### GDScript style

- Use `snake_case` for variables, functions and methods.
- Use `PascalCase` for `class_name` types.
- Add type hints: `var player: Player`, `func get_name() -> String:`.
- Prefer signals for decoupled node-to-node communication.
- Editor plugin scripts use `@tool`.
- Non-node helpers usually extend `RefCounted`; the plugin entry point extends `EditorPlugin`.
- GUT test files extend `res://addons/gut/test.gd` and should not declare `class_name`.

### Error handling

- Validate tool arguments before making changes.
- Return a structured error dictionary on tool failure: `{"error": "message"}`.
- Avoid `assert()` in production tool paths.
- Include enough context in error messages for users to fix the call.

## Adding a new MCP tool

Complete every step in one PR:

1. **Implement the tool** in the matching `addons/godot_mcp/tools/*_tools_native.gd` file.
2. **Register the tool** with `server_core.register_tool(name, description, input_schema, callable, output_schema, annotations, category, group)`.
3. **Classify the tool** in `native_mcp/mcp_tool_classifier.gd` as `core`, `supplementary` or `meta` and assign a group.
4. **Update tests** under `test/unit/` or `test/unit/tools/`, plus integration tests when the tool crosses editor/runtime/transport boundaries.
5. **Update translations** in `addons/godot_mcp/translations/tool_descriptions.json` and `.csv`.
6. **Update docs** under `docs/tools/` and any workflow pages affected by the new behavior.
7. **Verify** with the relevant unit/integration commands from [Testing](testing.md).

Advanced tools should normally be `supplementary` so they are registered but disabled until explicitly enabled. Keep the core surface capped at 30 unless maintainers intentionally rebalance the default tool set.

## Modifying existing tools

When changing an existing tool, check:

- Input schema and output schema compatibility.
- Tool classification and group membership.
- UI/tool-manager labels and translations.
- Tests for invalid arguments, edge cases and regression coverage.
- Documentation examples and category tables.

If the change affects project files, resources, editor state or runtime behavior, add a direct validation path in tests or in the PR notes.

## Documentation checklist

| Change | Docs to update |
| --- | --- |
| New/renamed tool | `docs/tools/<category>-tools.md`, `docs/tools/README.md`, translations. |
| New setting | `docs/configuration.md`, root README table if user-facing. |
| New CLI flag | `docs/configuration.md`, `docs/getting-started.md` if needed. |
| Runtime probe capability | `docs/architecture.md`, `docs/tools/debug-tools.md`, `docs/testing.md`. |
| Complete-game profile/state/evidence | `docs/game-workflows.md`, Chinese counterpart, architecture, changelog and all workflow gates. |
| Remote/tunnel behavior | `docs/remote-access.md`, config examples. |
| Test workflow | `docs/testing.md`, relevant agent/skill docs. |

## Pull request workflow

1. Create a feature branch.
2. Keep edits scoped to the requested behavior.
3. Run the relevant checks from [Testing](testing.md).
4. Confirm `git status` only contains intentional files.
5. Open a PR with a concise summary, testing evidence and any known limitations.

## Godot 4.7 notes

- Use the GL Compatibility renderer for this project.
- Prefer editor APIs over direct file mutation when editor state must stay synchronized.
- Resource import and FileSystem dock updates may be asynchronous; integration tests should wait for observable state rather than fixed sleeps.
- Keep generated import/cache files out of commits unless they are part of the addon distribution.
