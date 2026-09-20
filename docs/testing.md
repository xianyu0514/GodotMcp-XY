# Testing

Use the lightest test that proves the change, then run broader suites before merging code changes.

## Unit tests (GUT)

Unit tests live under `test/unit/`. Tool-specific tests usually live under `test/unit/tools/`.

Typical command shape:

```bash
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/unit/ -ginclude_subdirs -gexit
```

Notes:

- GUT is required for this command.
- Test files should extend `res://addons/gut/test.gd` and should not declare `class_name`.
- Cover happy paths, invalid arguments, edge cases and changed error behavior.

### Complete-game workflow gates

The durable workflow path has three complementary suites:

- `test_game_workflow_engine.gd` checks composition beyond ten steps, distinct same-tool writes, production ordering, blueprint integrity, protected paths, bounded receipts, pending behavior and strict objective evidence.
- `tools/test_game_workflow_tools.gd` checks persistence/CAS, hidden atomic dispatch, on-demand input schemas, async polling, recovery safety and an end-to-end simulated gameplay + UI + QA loop that reaches `completed` across multiple four-call rounds.
- `test_game_workflow_quality_gate.gd` covers 25 English/Chinese goals across all 12 profiles, requires 100% declared profile/capability recall, includes cross-domain negative cases and gates uncached compilation P95 below 5 ms.

When changing a profile, runner state or evidence rule, update the relevant expectation instead of loosening completion. A false `completed` result is a release blocker.

## Integration tests (Python)

Integration tests live under `test/integration/` and exercise the HTTP MCP server against a running/editor Godot instance.

Typical flow:

1. Start Godot with the MCP server enabled.
2. Ensure the server listens on `http://127.0.0.1:9080/mcp`.
3. Run the target Python test:

```bash
python test/integration/test_runtime_probe_flow.py
```

Integration tests are useful for transport behavior, runtime probe workflows, editor automation, imports/exports and project-level side effects.

The first-contact contract — what a fresh AI client experiences on connect (initialize instructions, lazy tools/list surface, project identity probes, self-healing disabled/unknown-tool errors, `workflow_query` routing with `suggested_prompt`, prompt recipes) — is pinned by:

```bash
GODOT_EXE=<editor-console-exe> MCP_PORT=9187 python test/integration/test_first_contact_flow.py
```

The making loop itself — create inputs/scene/script with atomic tools only, run and observe real movement and collision, change a parameter through `apply_change_set` and measure the effect, then restart the editor and confirm persistence — is pinned by:

```bash
GODOT_EXE=<editor-console-exe> MCP_PORT=9188 python test/integration/test_first_playable_flow.py
```

## Static checks

The repository includes focused static checks such as:

```bash
python test/quiet_mode_static_check.py
```

Use them when the touched code path is relevant.

## Manual MCP smoke test

For local diagnosis, call the HTTP endpoint directly:

```bash
curl -s \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:9080/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

Tool call payloads use `params.arguments`:

```bash
curl -s \
  -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:9080/mcp \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_project_info","arguments":{}}}'
```

## What to run by change type

| Change | Minimum validation |
| --- | --- |
| Documentation only | Markdown/link checks and JSON example validation. |
| Tool schema or handler | Targeted unit tests plus tool registration/classification checks. |
| Workflow compiler/runner | All three complete-game workflow suites, Schema/token budget checks and full GUT. |
| Runtime probe | Relevant runtime integration test plus unit tests for payload parsing. |
| UI/panel behavior | Targeted unit tests plus manual editor smoke test. |
| Transport/auth | HTTP/stdio/auth tests and direct curl smoke test. |
| Export/import/project resources | Targeted integration test and filesystem side-effect inspection. |

## Test data hygiene

- Prefer writing temporary resources under test-specific paths.
- Clean up generated files or keep them in ignored test output directories.
- Do not commit local `user://` settings, tokens or editor cache files.
- Avoid modifying generated `.uid` files by hand.

## Script, lifecycle and batch recovery checks

For targeted GUT runs, clear the repository's default directory configuration with `-gconfig=`; otherwise `-gtest` can also run the configured full suite:

```bash
godot --headless --path . -s addons/gut/gut_cmdln.gd -gconfig= -gtest=res://test/unit/tools/test_script_write_diagnostics.gd -gexit
```

The related fixtures are `test_project_lifecycle.gd` and `test_batch_scene_recovery.gd`. Run the tool directory plus manifest/schema/workflow checks when changing their shared contracts.

Set `GODOT_EXE` to a Godot 4.7 executable before running these isolated editor tests:

```bash
python test/integration/test_script_write_diagnostics_flow.py
python test/integration/test_project_lifecycle_flow.py
python test/integration/test_batch_scene_recovery_flow.py
```

The diagnostics fixture checks actual source paths, global classes, autoloads, repairs and unchecked languages/templates. Lifecycle uses HTTP MCP to test run/reuse, pause, stop and probe installation. Batch recovery uses the real EditorUndoRedoManager to verify repeated undo/redo, object identity, ownership, saved scenes and history cleanup. Each test creates its own project and cleans it up; remaining `.tmp_adoption_*` logs are local evidence and must not be committed.
