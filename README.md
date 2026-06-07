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
- Rust toolchain (for building the ratatui-ffi shim; required for the full
  TUI — not yet needed for the skeleton build)

### Quick build (skeleton — no shim required yet)

The default build mode references a prebuilt shim XCFramework. During
bootstrap (before the first shim release), set `MOONSWIFT_SHIM_SOURCE=1`
to use the stub C target instead:

```sh
MOONSWIFT_SHIM_SOURCE=1 swift build
MOONSWIFT_SHIM_SOURCE=1 swift test
```

### Full build (after F0.2 and F0.3 land)

```sh
make build   # builds the Rust shim + swift build
make test    # runs cargo test + swift test
```

The Makefile is added in task F0.3. Until then, use the env-variable form
above. Every `make` invocation also exports `LUASWIFT_INCLUDE_TOMLKIT=1`
so the release binary always includes the `luaswift.toml` module; a plain
`swift build` without the variable still produces a working binary
(see ARCHITECTURE.md §5.4).

## License

[Apache 2.0](LICENSE)
