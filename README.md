# MoonSwift

[![CI](https://github.com/ChrisGVE/moonswift/actions/workflows/ci.yml/badge.svg)](https://github.com/ChrisGVE/moonswift/actions/workflows/ci.yml)

A terminal (TUI) workbench for testing Lua code written against
[LuaSwift](https://github.com/ChrisGVE/LuaSwift).

> Lua means *moon* in Portuguese — MoonSwift is the literal translation of
> LuaSwift: a tool built for that library, not a general-purpose Lua utility.

## Features

- **Source browser** — load `.lua` files or string fields from JSON, YAML, and
  TOML documents; navigate sources in a panel with `j`/`k`
- **Run** — execute the selected fragment with `r`; output streams into the
  Output tab with return-value display and wall-clock timing
- **Lint** — two-layer analysis with `l`: a fast syntax pre-pass on every load
  plus a full embedded luacheck pass on demand
- **LuaSwift globals** — the full `luaswift.*` namespace (json, yaml, regex,
  mathx, stringx, tablex, types, utf8x, svg, and optional iox/http/ui) is
  known to the linter; no spurious undefined-global warnings
- **Sandboxed by default** — safe execution mode removes `io`, `debug`, and
  unsafe OS functions; `unrestricted` mode available when needed
- **Instruction limits** — stop runaway scripts via `run.instruction_limit`
- **NO_COLOR support** — full compliance: character prefixes replace all
  color-only distinctions

## Quick start

1. Create a project directory and add a `moonswift.toml`:

   ```toml
   lua_version = "5.4"

   [[source]]
   path = "hello.lua"
   ```

2. Add `hello.lua` next to the project file:

   ```lua
   print("hello from MoonSwift")
   return 42
   ```

3. Launch MoonSwift in the project directory:

   ```sh
   moonswift
   ```

4. Press `r` to run, `l` to lint. Press `?` for the full keybinding reference.

### Structured file example

```toml
lua_version = "5.4"

[[source]]
path = "config.json"

  [[source.field]]
  jsonpath = "$.scripts.init"
```

With a `config.json` containing:

```json
{
  "scripts": {
    "init": "return luaswift.mathx.clamp(0, 100, 42)"
  }
}
```

MoonSwift loads the string value at `$.scripts.init` as a Lua fragment.

## Keybindings

| Key | Action |
|-----|--------|
| `r` | Run selected source |
| `l` | Lint selected source |
| `x` | Cancel run |
| `q` | Quit |
| `?` | Help overlay (full keybinding list) |
| `<C-p>` | Open project file in `$EDITOR` |
| `<C-r>` | Reload project file |
| `<Tab>` | Cycle panes; cycle tabs when bottom pane is focused |
| `<S-Tab>` | Reverse-cycle panes |
| `<C-h>` | Jump to navigator |
| `<C-l>` | Jump to code pane |
| `<C-j>` | Jump to bottom pane |

Press `?` inside MoonSwift for the complete per-pane reference.

## User documentation

- [CLI reference](docs/user/cli.md) — flags, exit codes, environment variables
- [Project file](docs/user/project-file.md) — full `moonswift.toml` schema
- [Sources](docs/user/sources.md) — loading .lua files, field designations, JSONPath subset
- [Running](docs/user/running.md) — execution, output capture, limits, sandbox
- [Linting](docs/user/linting.md) — two-layer lint, catalog modules, extra_modules

## Building from source

### Requirements

- macOS 13 or later
- Xcode 16 or later (provides the Swift 6 toolchain)
- Rust toolchain (`rustup`; required for the Rust shim build)
- `cbindgen` for header regeneration: `cargo install cbindgen` (optional —
  only needed when the Rust ABI changes; the committed header works otherwise)

### Standard build

```sh
make build   # cargo build --release in rust/ratatui-ffi, then swift build
make test    # cargo test + swift test
make clean   # remove Rust and Swift build artifacts
make reset   # swift package reset (use after toggling MOONSWIFT_SHIM_SOURCE)
```

`make build` and `make test` both export `MOONSWIFT_SHIM_SOURCE=1` (source
mode, the contributor default during bootstrap) and `LUASWIFT_INCLUDE_TOMLKIT=1`
(so the binary always includes the `luaswift.toml` module). A plain
`swift build` without these variables still produces a working binary — see
ARCHITECTURE.md §5.4.

### Manual build (without Make)

```sh
cd rust/ratatui-ffi && cargo build --release
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift build
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift test
```

Run `swift package reset` first if you previously built without
`MOONSWIFT_SHIM_SOURCE=1` — SPM caches manifest evaluation and can silently
reuse a stale shim topology (see ARCHITECTURE.md §5.4).

## License

[Apache 2.0](LICENSE)
