# MoonSwift

A terminal (TUI) workbench for testing Lua code written against
[LuaSwift](https://github.com/ChrisGVE/LuaSwift).

> Lua means *moon* in Portuguese — MoonSwift is the literal translation of
> LuaSwift: a tool built for that library, not a general-purpose Lua utility.

## Status

Early inception — requirements gathering. Nothing to build or run yet.

## Planned scope

- Load Lua code from `.lua` files or from selected fields inside JSON, YAML,
  and TOML documents
- Wire up the Swift↔Lua sharing area (`LuaValueServer` implementations and
  registered Swift functions) from the workbench
- Lint, LSP support, debugging, and one-shot execution
- In-place editing with write-back to the underlying source

## License

[Apache 2.0](LICENSE)
