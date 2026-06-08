# Changelog

All notable changes to MoonSwift are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- `docs/user/` — user documentation for P1 features:
  - `docs/user/cli.md` — CLI flags, exit codes (0/64/65/70), environment
    variables (`NO_COLOR`, `MOONSWIFT_LOG`, contributor build variables)
  - `docs/user/project-file.md` — full `moonswift.toml` schema reference:
    `lua_version`, `[[source]]` / `[[source.field]]`, `[run]` (config,
    instruction_limit, wall_clock_limit_ms), `[lint]` (extra_modules),
    `[settings]` (theme), forward-compatibility and comment-preservation notes
  - `docs/user/sources.md` — loading `.lua` files, field designation, JSONPath
    subset table (supported and unsupported constructs), YAML multi-document
    `document` key, YAML alias restriction, TOML mapping contract, error states
  - `docs/user/running.md` — one-shot execution, output capture, return value
    display, cancellation (honest degradation note: LuaSwift#22 not at current
    pin), instruction and wall-clock limits (wall-clock inert until #22),
    sandbox vs unrestricted, `io.write` limitation
  - `docs/user/linting.md` — two-layer approach (syntax pre-pass + luacheck),
    catalog v0 base modules, conditional `luaswift.toml`, opt-in modules
    (iox/http/ui) with `extra_modules` configuration, Lua 5.5 grammar gap note
- `README.md` — updated with P1 feature list, quick-start examples (minimal
  `moonswift.toml` with `.lua` source and structured-file field designation),
  keybinding summary, links to user documentation

- `.github/workflows/release.yml` — `workflow_dispatch` release workflow
  implementing the two-phase release ordering protocol (ARCHITECTURE.md §5.4):
  cross-compile Rust shim (arm64 + x86_64) → lipo universal static lib →
  XCFramework → sha256 → bot commit updating `Package.swift` binaryTarget →
  tag → GitHub release with artifact upload → build-provenance attestation
  (`actions/attest-build-provenance`) → clean x86_64 verify job (`swift build`
  in binaryTarget mode, no Rust toolchain).  Also builds and attaches a
  notarization-ready universal `moonswift` binary.
- `RELEASING.md` — documents the release pipeline, the branch-protection bypass
  allowance setup for `github-actions[bot]`, recovery procedures, and
  notarization instructions.

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
- `docs/internals/ffi-boundary.md` — threading contract (render/terminal-class
  vs input-class), error protocol (i32 + last-error), process-global last-error
  slot (arm64e TLS/PAC rationale), `ffi_guard!` variants, cell batching
  contract, and emergency restore design.
- `docs/internals/lint.md` — vendored luacheck subset manifest, `package.preload`
  loader mechanism, spike test verdict, upgrade path.
- `docs/internals/catalog.md` — `LuaModuleCatalog` schema, availability
  categories (`.base`/`.conditional`/`.optIn`/`.compileFlagGated`), three
  consumers (`luacheckGlobals`, `optInNames`, completion/meta stubs), and
  the maintenance rule for LuaSwift version bumps.
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
