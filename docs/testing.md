# Testing

The project ships two complementary test suites:

| Suite | Location | Framework | What it covers |
| --- | --- | --- | --- |
| Unit | `test/unit/` | [GUT](https://github.com/bitwes/Gut) | Tool logic, parsing, parsers, UI helpers — in isolation. |
| Integration | `test/integration/` | Python | End-to-end flows that drive a real editor over HTTP MCP. |

Both suites are expected to pass with **zero failures** before a change is merged.

## Unit tests (GUT)

Unit tests run headlessly through GUT's command-line runner. GUT must be installed in the
project (`addons/gut/`).

```bash
godot --headless --path . \
  -s addons/gut/gut_cmdln.gd \
  -gdir=res://test/unit/ -ginclude_subdirs -gexit
```

Layout under `test/unit/`:

- `tools/` — per-tool tests (with `fixtures/` for sample scenes/scripts).
- `ui/` — dock-panel and tool-item UI behaviour.
- `helpers/` — shared test utilities.

Conventions (see [Contributing](contributing.md)):

- Test files use `extends "res://addons/gut/test.gd"` — **not** `class_name` (a GUT CLI limit).
- Cover the happy path, edge cases, and error handling for every change.

## Integration tests (Python)

Integration tests launch Godot, start the HTTP MCP server (default port `9080`), and call
tools over the wire to verify complete flows (batch edits, debugger control, export tools,
resource dependency scans, runtime-probe interactions, and more).

```bash
cd test/integration
python test_runtime_probe_flow.py
```

Each `test_*_flow.py` script is self-contained and can be run individually. They require a
Godot executable available to launch the editor headlessly and Python 3.8+.

## Tips

- When iterating on a single tool, run just its unit test file with `-gtest=res://test/unit/tools/<file>.gd`.
- Advanced tools are disabled by default; tests enable the tool under test explicitly via
  `core.set_tool_enabled("<tool>", true)`.
- Clean up generated artifacts after integration runs (temporary `.tmp_*` folders) so they
  don't leak into later runs.
