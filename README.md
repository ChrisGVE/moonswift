# MoonSwift

A terminal (TUI) workbench for testing Lua code written against
[LuaSwift](https://github.com/ChrisGVE/LuaSwift).

> Lua means *moon* in Portuguese — MoonSwift is the literal translation of
> LuaSwift: a tool built for that library, not a general-purpose Lua utility.

## Status

Active development. SPM skeleton builds; executable target exits immediately
(TUI not yet initialised). Subsequent tasks (F1+) add the full TUI loop,
services, and terminal rendering.

## Planned scope

- Load Lua code from `.lua` files or from selected fields inside JSON, YAML,
  and TOML documents
- Wire up the Swift↔Lua sharing area (`LuaValueServer` implementations and
  registered Swift functions) from the workbench
- Lint, LSP support, debugging, and one-shot execution
- In-place editing with write-back to the underlying source

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
