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
- **Completions & hover** — `<C-space>` opens a completion popup for the
  `luaswift.*` namespace plus post-run live-mock names; `K` (or `<Enter>` from
  the popup) shows a hover overlay with the symbol's signature and docs.
  Optionally, when [`lua-language-server`][luals] is on `PATH`, its type-aware
  diagnostics are merged into the Diagnostics tab (silent degrade to the native
  catalog when absent)
- **Mocking** — stub the sharing-area boundary in `moonswift.toml`: serve Swift
  values (`[[mock.value]]`) and Swift-backed functions (`[[mock.function]]`) to
  the script, edit them live in the navigator (`a`/`e`/`d`), and invoke a
  script-defined Lua function from the UI with a full call expression
- **Debugger** — `<C-g>` starts a debug run; toggle line breakpoints with `b`,
  step with `s`/`i`/`o`/`c`, stop with `x`. The `[ Debug ]` tab (`3`) shows
  locals, upvalues, on-demand globals (`g`), and the call stack, with structured
  tracebacks on error
- **LuaSwift globals** — the full `luaswift.*` namespace (json, yaml, regex,
  mathx, stringx, tablex, types, utf8x, svg, and optional iox/http/ui) is
  known to the linter; no spurious undefined-global warnings
- **Sandboxed by default** — safe execution mode removes `io`, `debug`, and
  unsafe OS functions; `unrestricted` mode available when needed
- **Instruction limits** — stop runaway scripts via `run.instruction_limit`
- **NO_COLOR support** — full compliance: character prefixes replace all
  color-only distinctions
- **In-place editing** — press `<C-e>` to open the selected fragment in an
  embedded Neovim session directly inside the code pane; `:w` splices the
  edited text back into the source file with format-preserving write-back and
  conflict detection. When Neovim ≥ 0.9 is not available, `$EDITOR` is used
  instead (one-time notice on first use)

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
   mswift
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

### Mock example

Stub the sharing-area boundary so a fragment can run against controlled inputs:

```toml
lua_version = "5.4"

[[source]]
path = "handler.lua"

[[mock.value]]
namespace = "env"
path = "user.name"
type = "string"
value = '"Ada"'
writable = false

[[mock.function]]
name = "now"
behavior = "fixed-return"
return_value = "1718000000"
```

With `handler.lua`:

```lua
return ("hello " .. env.user.name .. " at " .. now())
```

Run with `r`. After a run, the Mock Environment section of the navigator shows
the live values; press `<Enter>` on a script-defined function to invoke it with
a typed call expression.

## Keybindings

| Key | Action |
|-----|--------|
| `r` | Run selected source |
| `l` | Lint selected source |
| `x` | Cancel run |
| `q` | Quit |
| `?` | Help overlay (full keybinding list) |
| `<C-g>` | Start a debug run (breakpoints, stepping, variable inspection) |
| `<C-e>` | Open selected fragment in embedded Neovim (or `$EDITOR` fallback) |
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
- [Completions](docs/user/completions.md) — completion popup, hover overlay, live-mock items, optional `lua-language-server`
- [Mocking](docs/user/mocking.md) — mock values/functions, the navigator section, Lua invocation, mock sessions
- [Debugging](docs/user/debugging.md) — debug run, breakpoints, stepping, variable inspection, tracebacks
- [Editing and write-back](docs/user/editing-and-write-back.md) — embedded Neovim, `$EDITOR` fallback, write-back contract, conflict handling

[luals]: https://github.com/LuaLS/lua-language-server

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
cd rust/ratatui-ffi && cargo build --release --features swift_ffi
cd ../..
swift package reset
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift build
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift test
```

`--features swift_ffi` is required: it disables `catch_unwind` in
`ffi_guard!` so the Rust unwind TLS (`LOCAL_PANIC_COUNT`) is never
referenced from the compiled objects — eliminating arm64e SIGBUS from
PAC-unsigned `tlv_bootstrap` pointers (ARCHITECTURE.md §5.4 arm64-TLS).

`swift package reset` must run before `swift build` whenever
`MOONSWIFT_SHIM_SOURCE` is toggled; SPM caches manifest evaluation and can
silently reuse a stale shim topology (see ARCHITECTURE.md §5.4).

## License

[Apache 2.0](LICENSE)
