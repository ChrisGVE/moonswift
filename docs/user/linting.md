# MoonSwift — linting

## Overview

MoonSwift applies a two-layer lint pass to each source fragment:

1. **Syntax pre-pass** — fast, runs on every source load and edit.
2. **Full luacheck pass** — async, runs when you press `l`.

Results are shown in the Diagnostics tab of the bottom pane. The code pane
gutter shows `E` (error) and `W` (warning) marks on affected lines.

## Running lint

Press `l` from any pane to lint the currently selected source. Preconditions:

- A source must be selected and in the loaded state.
- The project's `lua_version` must be `"5.4"`.
- The lint engine must be ready.

The lint engine is pre-warmed in the background after the first frame. If
you press `l` before it is ready, a transient message appears:
`lint engine starting…`. Try again when the transient clears.

When a precondition is not met, `l` produces a 1.5-second transient message
and no lint pass starts.

## Layer 1: syntax pre-pass

The syntax pre-pass runs immediately on every source load (and will run on
edits in a future version). It compiles the fragment in a throw-away engine
and discards the bytecode — the compilation result is used only to detect
syntax errors. No output is captured.

Results appear in the Diagnostics tab under the `── Syntax ──` section. A
clean result shows `✔ No syntax errors.`

The pre-pass result persists until the next load or lint run. When the full
luacheck pass is not yet available (engine initializing), the pre-pass result
is the best available answer.

## Layer 2: embedded luacheck

The full luacheck pass runs the vendored luacheck library inside a long-lived
unrestricted Lua engine. This is safe because user code never executes in the
lint engine — scripts enter only as string arguments to
`luacheck.check_strings`. The engine runs unrestricted because luacheck
itself needs `load()` to compile its own modules.

Results appear in the Diagnostics tab under the `── Lint ──` section, sorted
by line number. A clean result shows `✔ No issues found.`

Each diagnostic line format:

```
E line:col message [code]
W line:col message [code]
```

Line numbers are fragment-relative (counted from line 1 of the Lua text,
regardless of where it sits in a structured file).

## Catalog: known globals

MoonSwift configures luacheck with the full set of `luaswift.*` globals so
that legitimate API calls are not flagged as undefined globals.

### Base modules (always known)

These modules are always present and always recognized by luacheck:

| Module | Contents |
|--------|----------|
| `luaswift` | root table (`extend_stdlib`) |
| `luaswift.json` | JSON encode/decode |
| `luaswift.yaml` | YAML encode/decode |
| `luaswift.regex` | regex compile/match |
| `luaswift.mathx` | extended math (38 functions) |
| `luaswift.stringx` | string utilities (30 functions) |
| `luaswift.tablex` | table utilities (31 functions) |
| `luaswift.types` | type introspection (17 functions) |
| `luaswift.utf8x` | UTF-8 utilities (9 functions) |
| `luaswift.svg` | SVG generation (4 functions) |

### Conditional module

`luaswift.toml` (encode/decode) is included in lint globals when a startup
probe confirms it is available in the running binary.

### Opt-in modules

The following modules are **not** included by default. Scripts that use them
will receive "undefined global" warnings unless the project explicitly
declares them in `moonswift.toml`:

| Module | Contents | `extra_modules` value |
|--------|----------|----------------------|
| `luaswift.iox` | file I/O, `path.*` sub-table (17 functions) | `"iox"` |
| `luaswift.http` | HTTP client (8 functions) | `"http"` |
| `luaswift.ui` | UI dialogs: `alert`, `confirm` | `"ui"` |

To enable opt-in modules for a project:

```toml
[lint]
extra_modules = ["iox", "http"]
```

Unknown names in `extra_modules` are rejected at load time with an error
diagnostic.

## Lua 5.5 grammar gap

The vendored luacheck was written to the Lua 5.4 grammar. Lua 5.5 syntax
additions (if any are present in your code) may not parse correctly. Since
MoonSwift P1 targets Lua 5.4 (`lua_version = "5.4"`) this is not expected
to be a practical issue; scripts targeting 5.4 parse correctly.

## Diagnostic tab layout

```
── Syntax ──
✔ No syntax errors.

── Lint ──
W 12:5  unused variable 'result' [W211]
E 17:1  accessing undefined variable 'luaswift.iox.read_file' [W113]
```

Press `<Enter>` on a diagnostic line in the Diagnostics tab to scroll the
code pane to that line with a 500 ms highlight pulse.

## Jump shortcuts

| Key | Action |
|-----|--------|
| `n` | Jump to next diagnostic (code pane focused) |
| `N` | Jump to previous diagnostic |
| `[d` | Jump to first diagnostic |
| `]d` | Jump to last diagnostic |
| `<Enter>` | Jump from diagnostics tab to error line |
