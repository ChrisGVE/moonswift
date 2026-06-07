# Changelog

All notable changes to MoonSwift are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/ChrisGVE/MoonSwift/compare/HEAD...HEAD
