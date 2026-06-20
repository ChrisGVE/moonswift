# MoonSwift — end-to-end test fixtures

Hand-authored projects for exercising the real `mswift` binary against every
embedding format. One self-contained project per subfolder; each is opened with:

```sh
mswift e2e/json      # or yaml / toml / lua
```

## Layout

| Folder | Embedding | What it carries |
| ------ | --------- | --------------- |
| `json/` | Lua fragments as JSON string fields (`\n`-escaped) | `config.json` + `moonswift.toml` |
| `yaml/` | Lua fragments as YAML block scalars (`\|`) | `config.yaml` + `moonswift.toml` |
| `toml/` | Lua fragments as TOML multi-line strings (`"""`) | `config.toml` + `moonswift.toml` |
| `lua/`  | Standalone `.lua` source files | `main.lua`, `helper.lua` + `moonswift.toml` |

## Designed coverage (all four flows in every project)

Every project's `moonswift.toml` defines the same mock surface and every
fragment is written to touch all four subsystems:

- **Mock (P2)** — `app.settings.verbose` (boolean) and `app.limits.max`
  (number) mock *values*; `host_log` (echo-args) and `fetch_count`
  (fixed-return `42`) mock *functions*. Exercise the Mock navigator/form and
  the Invoke form.
- **Debugger (P2)** — each fragment has a `for` loop and a branch
  (`classify`), giving line targets for breakpoints, stepping, and snapshot
  inspection.
- **Completions (P3)** — fragments declare locals (`total`, `classify`) and
  reference the `app.*` mock namespace and stdlib (`string`, `tostring`), so
  LuaLS has locals, namespaces, and library symbols to complete. `[lint]
  extra_modules` opts in `iox`/`http` as known globals.
- **nvim editing (P4)** — every fragment is editable; structured-file
  fragments exercise the splice/write-back round-trip, `lua/` exercises whole
  -file editing.

All fragments run cleanly under the default sandbox (`print`, mock symbols,
and safe stdlib only) so a plain run succeeds before any debug/edit action.
