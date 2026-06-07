# Changelog

All notable changes to MoonSwift are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- `.swift-format` config at repo root: 4-space indent, 120-column line
  length, `UseLetInEveryBoundCaseVariable` disabled. Applies consistently
  across all Swift sources and tests.
- CI lint gate in the Swift job (`swift-format lint --strict --recursive
  Sources/ Tests/`) runs before the build step on both matrix legs
  (x86_64 blocking, arm64 advisory). Any unformatted commit fails CI.
- `// swift-format-ignore` annotations on deliberately column-aligned
  blocks (`RffiKeyCode` enum, `KeyCode.init(rawKeyCode:charScalar:)` switch
  table, `MouseKind` enum, `FFICellWriter.writeCells` bitfield extractions)
  to preserve readability alignment while allowing mechanical formatting
  everywhere else.
- SPM package skeleton: targets `moonswift`, `MoonSwiftCore`, `MoonSwiftTUI`,
  `RatatuiKit`, `CRatatuiFFI`, `CTreeSitterTOML`; Swift 6 language mode;
  macOS 13 minimum.
- Vendored ratatui-ffi Rust shim (fork of holo-q/ratatui-ffi) in
  `rust/ratatui-ffi/` with C ABI for terminal rendering.
- Vendored tree-sitter-toml grammar in `Sources/CTreeSitterTOML/` (upstream
  SPM branch omits `scanner.c`; local copy includes it).
- Vendored luacheck pure-Lua subset in `Sources/MoonSwiftCore/Vendor/luacheck/`
  for embedded lint support.
- `Makefile` with `build`, `test`, `clean`, `reset`, and `shim` targets;
  exports `MOONSWIFT_SHIM_SOURCE=1` and `LUASWIFT_INCLUDE_TOMLKIT=1`.
- `ARCHITECTURE.md` — component architecture, threading model, FFI contracts,
  dependency map, release pipeline.
- `docs/internals/ux-spec.md` — binding P1 UX specification: keybindings,
  error text literals, theme token table.
- Repository hygiene: `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/`
  (bug report and feature request templates), `.gitignore` extended for
  Rust `target/` and build artifacts.

### Changed

- Reformatted all Swift sources and tests (`Sources/`, `Tests/`) with
  `swift-format --in-place --recursive` under the new config. Changes are
  purely whitespace and indentation — no semantic modifications.
- Renamed `ThemeToken.operator_` to `ThemeToken.operatorToken` to satisfy
  the `AlwaysUseLowerCamelCase` lint rule (trailing underscore was a
  keyword-escape convention; the new name is more descriptive and
  consistent with the other token cases).

[Unreleased]: https://github.com/ChrisGVE/MoonSwift/compare/HEAD...HEAD
