# Changelog

All notable changes to MoonSwift are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

#### Editing subsystem (embedded Neovim + `$EDITOR` fallback)

- In-place editing via embedded Neovim (`<C-e>`): spawns `nvim --embed --clean`
  sized to the code pane, renders the ext_linegrid output cell-by-cell using
  the existing RatatuiKit cell API. All standard Neovim commands work inside the
  pane; `:w` triggers write-back.
- Write-back pipeline: `:w` inside the nvim pane splices the edited text
  precisely into the source file without re-encoding anything outside the edited
  span. JSON, YAML, TOML, and whole `.lua` files are each handled by the
  existing `SpanSplicer` format dispatch.
- Conflict detection: if the source file was modified on disk between load and
  `:w`, a prompt offers `[r]eload / [o]verwrite / [d]iff / [c]ancel`. The diff
  path opens a side-by-side view of the on-disk fragment vs. the edited buffer.
- `$EDITOR` fallback: when Neovim ≥ 0.9 is not available, a one-time
  status-bar note appears and the existing `$EDITOR` mechanism is used instead.
  A syntax-error loop re-opens the editor with an injected comment block until
  the edit is clean or the block is deleted.
- Neovim minimum version: 0.9.0 (required for `ext_linegrid` and
  `nvim_create_autocmd`).

#### New components (`Sources/MoonSwiftTUI/Nvim/`)

- `EditorBridge` — static namespace implementing the 11-step nvim spawn
  sequence: probe → fallback decision → `NvimProcessSupervisor.spawn` → RPC
  handshake → buffer seed → autocmd → `NvimSession` construction →
  `AppEvent.nvimReady` posting.
- `NvimProcessSupervisor` + `NvimProcessSupervisor+Probe` — nvim binary
  discovery (NVIM_PATH override + Homebrew/MacPorts/PATH search, version ≥ 0.9
  check), XDG-isolated spawn (0700 temp dir), stderr drain with 1 MiB cap, and
  a 9-step teardown (SIGTERM → 2 s deadline → SIGKILL).
- `NvimRPCClient` (actor) + `NvimRPCClient+Reader` — actor owns the stdin
  `FileHandle`; `request`/`notify`/`onNotification` run on the actor executor;
  blocking `read(2)` reader loop on a dedicated `moonswift.nvim-rpc-reader`
  thread delivers to the actor via `Task { await client.deliver(msg) }`.
- `NvimRedrawHandler` — decodes nvim `redraw` notification batches
  (`ext_linegrid` protocol) into `NvimGridState`; posts
  `AppEvent.nvimRedrawBatch` only on the terminating `flush` sub-event.
- `NvimKeyTranslator` — translates `KeyCode`/`Modifiers` to nvim key notation
  (printable, `<CR>`/`<Esc>`/`<BS>`/`<Tab>`, F-keys, `<C-x>`/`<S-x>`/`<M-x>`,
  `<lt>` for literal `<`).
- `WriteBackCoordinator` — static async 8-step write-back pipeline: size cap →
  syntax pre-pass → double `validateReadable` (TOCTOU guard) → background read
  → conflict check → format dispatch → atomic write.
- `MsgpackRPCFramer` — length-prefixed msgpack-RPC framing with 16 MiB frame
  cap, 64-level depth cap, and 1 M element cap.
- `NvimRPCTypes` — `RawRPCMessage` parse, `WriteBackResult`/`Outcome` types.
- `NvimGridState` — `NvimGridState`/`NvimCellState`/`NvimPaneState`/
  `NvimSession`/`ConflictModalState`/`DiffViewState`/`DiffViewPhase` value types.
- `NvimRedrawEvent` — `NvimRedrawEvent` enum, `NvimCell`, `HLAttrs`.

#### New render views (`Sources/MoonSwiftTUI/Render/`)

- `NvimGridView` — renders `NvimGridState` into `[RenderCommand]` with
  coalesced attribute runs.
- `NvimConflictView` — renders the conflict-resolution prompt
  (`[r]eload / [o]verwrite / [d]iff / [c]ancel`).
- `NvimDiffView` — side-by-side diff view with changed/added/removed line
  colouring.

#### Vendored codec

- `MessagePackValue` — vendored MIT-licensed msgpack value codec
  (`a2/MessagePack.swift`, 7 files) at
  `Sources/MoonSwiftCore/Vendor/MessagePackValue/`. Used by `NvimRPCClient`
  and `MsgpackRPCFramer` for wire-protocol encode/decode. No imports beyond
  Foundation.

### Changed

- `AppState` gains four nvim-related `FocusState` cases (`nvimPane`,
  `nvimSpawning`, `conflictModal`, `diffView`) and several new top-level fields
  (`nvimGrid`, `conflictModal`, `diffView`, `pendingConflictModal`,
  `nvimFallbackNotedThisSession`, `nvimPendingResize`, `nvimResizeDeadline`,
  `terminalSize`).
- `AppDriver` split: nvim effect arms extracted into
  `AppDriver+NvimEffects.swift`; `$EDITOR` / clipboard helpers into
  `AppDriver+EditorEffects.swift`.
- LuaSwift bumped to 1.12.4; `cooperativeCancellation` performance fix
  included in that release resolves a long-tail latency regression in the
  instruction-limit hook path.

### Fixed

- `NvimRPCClient` EOF guard: `stdinOpen` flag prevents writes to a closed
  `FileHandle` after teardown (`NSFileHandleOperationException` is uncatchable
  in Swift).

## [0.1.0] - 2026-06-08

First public preview (P1 feature set). MoonSwift is a terminal UI editor and
runner for Lua fragments embedded in structured files (JSON/YAML/TOML) and
standalone `.lua` files.

### Added

#### Application (TUI)

- Elm-style application core: immutable `AppState`, pure `Reducer` with
  per-focus key dispatch tables, and an `AppDriver` event loop with flood
  guard that translates state effects into core-service calls.
- Three-pane layout (navigator, code pane, bottom pane) with a pure layout
  `Renderer` implementing the binding UX spec, plus `</>`/`{/}` pane-resize
  keybindings.
- Navigator pane: source list with live filter, loading spinner, and error
  states.
- Code pane: syntax highlighting (tree-sitter query engine with an LRU cache),
  colon-jump to line, hover, diagnostic gutter, and a deadline-guarded
  highlight-pulse animation on diagnostic jump.
- Bottom pane: run output, diagnostics tab, run bookkeeping (FIFO notices,
  yank), and `C-l` clear.
- Help overlay covering every pane section with per-token keybinding listings.
- Init-form modal: detects an empty project (no `moonswift.toml`), scans the
  directory, and writes a new project file.
- Source picker modal (`PickerState`/`PickerTree`) for selecting fields within
  structured files.
- Theme engine: Dracula-derived 18-token color tables, terminal-capability
  detection, and an environment-seam override mechanism.
- External-editor handoff: `spawnEditor` effect with a pump-park/unpark
  handshake and a `TerminalSuspender` protocol seam for clean suspend/resume.
- Degraded-state rendering per spec for unsupported Lua versions and malformed
  projects (engine/lint errors logged, keys blocked on malformed project).

#### Engine (MoonSwiftCore)

- Project codec and validation for `moonswift.toml`
  (`lua_version`, `[[source]]`/`[[source.field]]`, `[run]`, `[lint]`,
  `[settings]`) with comment preservation and forward-compatibility.
- Source loading with provenance for standalone `.lua` files and field
  designation within JSON/YAML/TOML structured files.
- `TreeValue` decoded tree with a `SpanLocator` mapping decoded values back to
  byte ranges (incl. TOML array-of-tables index steps).
- JSONPath subset evaluator with syntax validation at project-load time.
- `RunService`: one-shot Lua engine lifecycle with instruction and wall-clock
  limits, output coalescing (`Coalescer`), and sandbox vs. unrestricted modes.
- `LintService`: two-layer lint (syntax pre-pass + embedded luacheck) backed by
  a `LuaModuleCatalog` (base / conditional / opt-in / compile-flag-gated module
  availability).
- Diagnostics: `LuaError`→`Diagnostic` mapping with a line parser.
- Background timing primitives: `TickSource` (arm/disarm timer) and `EventPump`
  with a park/unpark handshake for editor suspension.

#### Rendering (RatatuiKit)

- Safe Swift overlay over the C FFI shim: `Terminal` lifecycle, event decoding,
  widget wrappers, and cell-level batched drawing (`CellBuffer`, `CellGrid`
  snapshot backend).
- `RenderBackend` protocol with a production `RatatuiKitBackend`, a
  `CommandInterpreter`, and an FFI-free `RecordingRenderBackend` test double.

#### CLI (moonswift)

- Typed argument parser with `sysexits`-style exit codes (0 success, 64 usage,
  65 data error, 70 internal error).
- `@convention(c)` crash handlers that restore the terminal on abnormal exit.
- Startup sequence with empty-project detection.

#### Tooling, packaging & documentation

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
  allowance setup for `github-actions[bot]`, the `TAP_DISPATCH_TOKEN` Homebrew
  secret, recovery procedures, and notarization instructions.
- Homebrew distribution: the release pipeline dispatches a
  `moonswift-release-published` event to `ChrisGVE/homebrew-tap`, which bumps
  `Formula/moonswift.rb` and opens a PR (`brew install ChrisGVE/tap/moonswift`).

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

### Security

- Unified disk-read guard `SourceStore.validateReadable` routes every file read
  (`loadLuaFile`, `loadStructuredFile`, and the picker tree loader) through one
  check: regular-file type only (rejects symlinks, devices, FIFOs) and a size
  ceiling (10 MiB for `.lua`, 50 MiB for structured files) before the file is
  read into memory.
- Path-traversal hardening: `escapesProjectRoot` resolves symlinks before the
  containment check (CWE-61 prevention).
- Denial-of-service limits on structured-tree decoding: a nesting-depth cap
  (128) on the JSON/YAML decoders to prevent stack exhaustion, and a YAML
  alias-bomb node-count budget (`treeDecoderMaxNodes`) to bound alias expansion.
- External-editor command validation: the `EDITOR` value is validated as a raw
  executable path (rejecting relative or malformed paths) before
  `Process.executableURL` is set.
- FFI safety: `Terminal` is guarded against use-after-free; the Rust shim guards
  the `tcgetattr` return, defers `Box` free during teardown, and recovers from a
  poisoned mutex in the process-global last-error slot. Widget/layout FFI calls
  are render-class thread-asserted.
- Release builds of the shim require `--features swift_ffi`, which drops
  `catch_unwind` and sets `panic = abort` (arm64e PAC/TLS safety).
- CI enforces an 85% line-coverage gate on `MoonSwiftCore`.

### Fixed

- `SpanLocator` no longer false-flags escaped fields (removed the R7
  byte-equality check) and resolves TOML array-of-tables index steps correctly.
- JSONPath expressions are validated against the real parser at project load
  rather than failing later at evaluation.
- Diagnostics-tab jump/yank index offset corrected.
- FIFO notice ordering fixed and the dead `clearedNoticeInserted` flag removed.
- `resize(0,0)` sentinel treated as a clean quit.
- `q` quits from the help overlay; misleading `n`/`N` hints dropped.
- `Coalescer` made thread-safe for cross-thread output coalescing.
- Backslash escaped before quote in generated Lua table literals.
- Snapshot backend renders a distinct tab style; a missing golden now fails the
  test instead of silently passing.
- Lint prewarm engine-init failure is reported via `onFailed` rather than
  swallowed.
- Release pipeline: the distributable universal `moonswift` binary is now
  force-statically linked against the Rust shim (the source-mode build
  otherwise links the dylib, whose `install_name` is an absolute build-tree
  path — producing a `dyld: Library not loaded` failure on any other machine).
  An `otool -L` gate fails the release if a `libratatui_ffi` load command
  survives.

### Changed

- Reformatted all Swift sources and tests (`Sources/`, `Tests/`) with
  `swift-format --in-place --recursive` under the new config. Changes are
  purely whitespace and indentation — no semantic modifications.
- Renamed `ThemeToken.operator_` to `ThemeToken.operatorToken` to satisfy
  the `AlwaysUseLowerCamelCase` lint rule (trailing underscore was a
  keyword-escape convention; the new name is more descriptive and
  consistent with the other token cases).

[Unreleased]: https://github.com/ChrisGVE/moonswift/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ChrisGVE/moonswift/releases/tag/v0.1.0
