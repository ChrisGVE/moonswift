# MoonSwift — Requirements

Status: post-audit round 1 (req-collection, 2026-06-07)

## Overview

**MoonSwift** is a macOS terminal (TUI) workbench for developing and testing Lua
code written against the **LuaSwift** library
([`ChrisGVE/LuaSwift`](https://github.com/ChrisGVE/LuaSwift)). The name is the
literal translation of LuaSwift (*lua* = "moon" in Portuguese); it is a
LuaSwift-specific tool, not a general Lua utility. Binary: `moonswift`;
Swift package: `MoonSwift`; repo: `ChrisGVE/moonswift`.

**Problem.** Applications embedding LuaSwift host Lua scripts in `.lua` files
or inside fields of JSON/YAML/TOML configuration files. Those scripts call
Swift-provided functions and read/write Swift-served values (the "sharing
area": `LuaValueServer` namespaces and `registerFunction` callbacks). Today the
only way to exercise such a script is to run the full host application. There
is no way to run, lint, debug, or get completions for a script against a
simulated host environment — and generic Lua tooling knows nothing about
LuaSwift's ~31 Swift-backed modules or the app's registered functions.

**Solution.** A keyboard-driven TUI that loads Lua sources (whole files or
designated fields inside structured files), lets the user mock the sharing
area at runtime, and provides one-shot run, linting, debugging, completions,
and eventually in-place editing with write-back — all aware of the LuaSwift
module catalog and the mocked host environment.

**Target users.** Public tool for any developer embedding LuaSwift in an app
(Chris is user zero). Published on GitHub; distribution polish (brew, etc.)
follows once useful.

**Relationship to LuaSwift.** Adjacent project, separate repo (decision at
inception): SPM has no dev-dependency separation, so tool dependencies must
not pollute the zero-mandatory-deps library; release cadences and platform
targets differ (library: iOS+macOS sandbox-friendly; tool: macOS-only,
process-spawning). Where MoonSwift needs library internals (debug hooks,
introspection, structured errors), the approach is **adding public API to
LuaSwift** via its normal release flow — these are valuable library features
in their own right. The three required API surfaces are filed upstream:
[LuaSwift#19](https://github.com/ChrisGVE/LuaSwift/issues/19) (structured
errors), [LuaSwift#20](https://github.com/ChrisGVE/LuaSwift/issues/20)
(debug hooks), [LuaSwift#21](https://github.com/ChrisGVE/LuaSwift/issues/21)
(introspection). MoonSwift pins a minimum LuaSwift version per phase
(P1: ≥ 1.9.1; P2: the release shipping #19–#21).

## MVP(+) Scope

Delivery is phased. P1 is the MVP; each phase is independently shippable.

| Phase | Contents |
| ----- | -------- |
| P1 | TUI shell (3 panes), load `.lua` + structured-file fields, syntax highlighting, one-shot run, lint, project file |
| P2 | Sharing-area mocking (runtime), full debugger — **gated on the LuaSwift release shipping #19/#20/#21** |
| P3 | Completions: native catalog first, optional lua-language-server integration |
| P4 | Editing: suspend+`$EDITOR` with write-back, then embedded Neovim (ext_linegrid) |

### Core Features

#### F1. Source loading (P1)

- Load Lua code from `.lua` files.
- Load Lua code from designated string fields inside JSON, YAML, and TOML
  files. Designation mechanism: the **MoonSwift project file** lists source
  files and **JSONPath (RFC 9535) expressions** to Lua-bearing fields
  (applied analogously to YAML/TOML trees); additionally an **interactive
  picker** in the TUI browses a structured file's tree and lets the user mark
  fields, persisting the generated JSONPath to the project file. Expressions
  matching multiple nodes designate multiple fragments.
- A loaded fragment retains provenance (file, path expression, byte span) —
  required later for write-back (F8) and for correct lint/error line mapping
  (fragment line 1 ≠ file line 1).
- Error cases are first-class: a malformed structured file, a path expression
  that resolves to nothing, and a path resolving to a non-string value each
  produce a clear diagnostic in the messages pane (naming file, path, and
  cause) and leave the rest of the project usable.
- Acceptance: open a project containing a `.lua` file and a YAML file with a
  marked field; both appear as loadable sources; switching sources updates the
  main pane. Breaking the YAML file yields the documented diagnostic, not a
  crash; the `.lua` source remains loadable.

#### F2. Project file (P1)

- TOML file (working name `moonswift.toml`) at project root holding: source
  file list, field designations (JSONPath expressions per structured file),
  **selected Lua version** (present from day one; P1 accepts only `5.4` and
  errors with guidance for other values — see Lua versions under Technical
  Architecture), sharing-area mock definitions (P2), and tool settings
  (optional run limits, theme).
- Human-editable, diff-friendly, committed to the user's repo.
- `moonswift` launched without a project file offers to create one;
  `moonswift <file.lua>` works without a project for quick one-offs.
- Acceptance: round-trip — picker-made designations persist and reload;
  a project file selecting an unsupported Lua version produces the guidance
  error.

#### F3. One-shot run (P1)

- Execute the selected source in a fresh LuaSwift engine
  (`LuaEngineConfiguration` selectable: sandboxed/unrestricted, the tool
  defaults to sandboxed to mirror host-app reality).
- Output (print/return value) and errors appear in the bottom pane. Errors map
  to source lines (fragment offset applied for structured-file fields).
  - P1 line extraction: parse Lua's stable error-string format
    (`[string "chunkname"]:LINE: message`) — the documented fallback contract
    until LuaSwift#19 ships structured errors; the parser is isolated so #19
    replaces it without touching consumers.
- Run is non-blocking for the UI: the engine runs off the main thread; a
  count-mask hook polls a cancellation flag so a running script is always
  cancellable from the UI. Optional instruction-count and wall-clock limits
  are configurable in the project file (no limit by default).
- Acceptance: a script printing and erroring shows output then the error with
  the correct line number; a runaway loop is cancelled from the keyboard
  within a human-perceptible delay.

#### F4. Linting (P1)

- Two layers:
  1. **Syntax pre-pass** via the host engine's load (always correct for the
     active Lua version) — instant, on every source change.
  2. **luacheck embedded**: vendor luacheck **pinned to an exact upstream
     commit** (master line, for Lua 5.5 syntax support), **pure-Lua subset
     only** (`check_strings`/`get_report` path; no `luafilesystem`, no CLI),
     run *inside* a dedicated LuaSwift engine; options passed programmatically
     with the LuaSwift module catalog (and, once P2 exists, the project's
     mocked functions/namespaces) injected as known globals — eliminating
     false "undefined global" warnings that generic Lua tooling produces.
  - Known gap, accepted: luacheck's Lua 5.5 grammar is still maturing
    upstream (e.g. the 5.5 `global` declaration, lunarmodules/luacheck#134);
    affected constructs may mis-lint until upstream lands them. The syntax
    pre-pass remains authoritative for validity.
  - P1 includes a **spike acceptance**: the vendored luacheck demonstrably
    runs inside a LuaSwift engine and produces a structured report, before
    the rest of F4 is built on it.
- Diagnostics render in the bottom pane and as gutter/inline marks in the main
  pane, with line/column from luacheck's structured report.
- Acceptance: a script using `luaswift.json.encode` lints clean; an
  actually-undefined global is reported; the spike test passes in CI.

#### F5. Sharing-area mocking (P2)

The shared environment is a dictionary-like surface populated at runtime plus
callback functions wired in both directions. MoonSwift mocks all three,
defined interactively in the TUI and persisted to the project file (no Swift
codegen in scope — see Deferred):

- **Mock values**: user defines namespaces and key paths with values
  (scalars, tables); MoonSwift synthesizes `LuaValueServer` instances serving
  them, including writability per path (`canWrite`/`write`), with writes
  visible in the navigator.
- **Mock Swift functions** (Lua → Swift): user declares function names with
  canned return values or simple scripted behaviors (e.g. echo args, return
  fixture, raise error); registered via `registerFunction` before each run.
- **Lua invocation** (Swift → Lua): the user can invoke a global Lua function
  from the TUI with constructed `LuaValue` arguments (via
  `callLuaFunction`/`callAndReleaseLuaFunction`), simulating the host app
  triggering script callbacks; result shows in the output pane.
- The left navigator pane displays the mock environment tree (namespaces,
  values, functions) and live state after runs — backed by LuaSwift#21
  introspection so the display reflects the engine's actual state, not
  parallel bookkeeping.
- Acceptance: script reads a mocked value, calls a mocked function, defines a
  callback; user invokes the callback from the TUI and sees its result;
  mock definitions survive restart via the project file.

#### F6. Debugger (P2)

Full interactive debugging in the TUI:

- Line breakpoints (set/clear in the main pane), step over / into / out,
  continue, pause.
- At a pause: variable inspection (locals, upvalues, globals on demand), call
  stack display with frame selection.
- Runtime errors carry structured info: message, source line, full traceback.
- **Dependency: LuaSwift#19 (structured errors) and #20 (debug hook API:
  line/call/return events, pause/resume, frame inspection), plus #21
  (introspection) for the navigator.** P2 starts when the LuaSwift release
  shipping these is available; `@_spi(Tooling)` is the documented fallback if
  public API is rejected upstream. The API design happens in those issues
  (including the pause concurrency model — see Open Questions).
- Acceptance: set breakpoint, run, hit it, step, inspect a local, continue to
  completion; error in a nested call shows a traceback with correct lines.

#### F7. Completions & hover (P3)

- **Phase 3a — native catalog**: in-process completions and hover docs for the
  LuaSwift module catalog (the ~31 `luaswift.*` modules) plus the project's
  mocked functions/namespaces — derived live from the engine/module registry
  (#21), so user-registered mocks complete instantly. Keyboard-triggered in
  the main pane (read-only context: signature/hover lookup; full completion
  matters most once editing exists).
- **Phase 3b — optional LuaLS**: if `lua-language-server` is installed
  (brew), MoonSwift can spawn it (stdio LSP client) and feed generated
  `---@meta` definition files describing the module catalog + project mocks,
  with `runtime.version` matched to the active engine. Adds type-aware
  diagnostics and richer hover. Strictly optional — absence degrades to 3a.
- One **source-of-truth catalog generator** feeds three consumers: luacheck
  globals table (F4), LuaLS meta files (F7b), native completion data (F7a).
- Acceptance (3a): hover on `luaswift.stringx.split` shows its signature;
  a mocked function appears in completion results.

#### F8. Editing & write-back (P4)

- **Phase 4a — suspend & hand over**: from the TUI, open the current source in
  `$EDITOR` (the git-commit pattern: leave alternate screen, spawn editor on
  an extracted temp buffer, resume on exit). On save: validate (syntax
  pre-pass); on failure re-open with the error injected as comments (kubectl
  pattern).
- **Write-back contract** (both 4a and 4b):
  - `.lua` files: overwrite file.
  - Structured-file fields: **span-splice** — locate the value's exact byte
    range in the original file, splice the edited text with correct
    escaping/indentation for the format (JSON string escaping, YAML block
    scalar indentation, TOML strings), preserving everything outside the span
    by construction (Swift YAML/TOML libraries do not round-trip faithfully;
    span-splice sidesteps that).
  - **Conflict guard**: the file's content hash is captured at load; a
    mismatch at write-back time (external modification) prompts the user
    (reload / overwrite / show diff) — silent clobbering is out.
  - **Validation contract**: after splicing, (1) the whole file re-parses in
    its format, (2) bytes outside the spliced span are byte-identical to the
    original, (3) re-extracting the designated field yields exactly the
    edited text. Any failure aborts the write and surfaces the cause.
  - Per-format edge-case rules (YAML flow vs. block style, block-scalar
    indentation, TOML multiline strings, JSON escaping) are enumerated
    explicitly at PRD time — they are correctness requirements, not
    implementation details.
- **Phase 4b — embedded Neovim**: `nvim --embed` child process, msgpack-RPC,
  `nvim_ui_attach` with `ext_linegrid` (single grid); MoonSwift renders the
  grid into the main pane (cell-level drawing — see Technical Architecture)
  and translates input to nvim key notation. VimR's MIT `NvimApi` Swift
  package is the donor/reference implementation for the RPC layer. Graceful
  absence: no `nvim` on PATH → 4a behavior.
- Acceptance (4a): edit a YAML-hosted fragment introducing a syntax error →
  reopened with error comment; fix → file updated, all comments/format
  preserved per the validation contract; externally-touched file triggers the
  conflict prompt; (4b): nvim renders in-pane, `:w` triggers the same
  write-back.

### User Experience

Single-window TUI, keyboard-driven, three regions:

- **Left column — navigator**: in P1, lists all project sources (`.lua` files
  and designated structured-file fields); selecting an entry loads it in the
  main pane. From P2, additionally shows the sharing-area mock environment
  (namespaces → values, functions) and live state.
- **Main area — code**: read-only (until P4) display of the selected source
  with tree-sitter syntax highlighting (P1), line numbers, lint gutter marks,
  breakpoint marks (P2), current-line indicator while debugging.
- **Bottom pane — output & messages**: run output, structured errors with
  tracebacks, lint diagnostics, debugger status. Tabbed or merged stream
  (PRD decides).

Conventions: vim-flavored navigation where it doesn't conflict
(`hjkl`-friendly, `:`-style command line acceptable but not required for v1),
visible key hints (status bar), every action reachable by keyboard, mouse
support where crossterm provides it for free. Resize-safe. Works in 80×24
minimum; designed for larger.

Color: truecolor themes with capability detection and 256-color degradation.
Screen-reader/accessibility support is explicitly deferred (TUI; revisit
post-P2).

"Magic moment": point MoonSwift at a config file with an embedded script,
mock the two functions the app provides, hit run, see it work — without
launching the host app.

### Technical Architecture

- **Language/runtime**: Swift (Swift 6 mode), macOS only. SPM executable
  package; binary `moonswift`.
- **TUI stack**: **ratatui via an own Rust cdylib shim**. A Rust crate in the
  MoonSwift repo wraps ratatui + crossterm behind a C ABI (cbindgen), consumed
  by a Swift overlay target — the same Rust→C-ABI→Swift pattern as the mmdr
  fork (MarkdownExtendedView precedent). Requirements on the shim:
  - expose the stock widgets/layout actually used (split layout, list/tree,
    paragraph/scroll, status bar) with C-friendly setter APIs;
  - expose **cell-level buffer access for a region** (write cells with rune +
    RGB attrs into a rect) — first-class, because the code pane (highlight
    spans, gutter marks) and the P4b nvim grid blit are custom-drawn;
  - own the terminal session: raw mode, alternate screen, resize events, and
    crossterm's input decoding surfaced as a C event stream (keys with
    modifiers, mouse, paste).
  - Build integration: cargo invoked from the build (plugin/Makefile) for
    dev; prebuilt artifacts (xcframework or static lib) attached to releases
    so end users and plain `swift build` consumers don't need a Rust
    toolchain — exact mechanism decided at PRD/architecture time.
  - The shim starts as an internal component; extraction as a standalone
    open-source package is a deferred idea.
- **Syntax highlighting** (P1): SwiftTreeSitter + tree-sitter-lua (both
  active, SPM-ready); capture names map to theme attributes rendered through
  the shim's cell-level API. Tree-sitter grammars for JSON/YAML/TOML serve
  the picker (F1) and span location (F8) later.
- **Engine**: LuaSwift via SPM. P1 minimum ≥ 1.9.1; P2 minimum = the release
  shipping #19/#20/#21. One engine instance per run (fresh state); a separate
  long-lived engine hosts embedded luacheck.
- **Lint**: vendored luacheck (exact pinned commit; pure-Lua subset, no lfs)
  executed in-process; options injected programmatically from the catalog
  generator.
- **LSP client** (P3b): ChimeHQ `LanguageServerProtocol` + `LanguageClient`
  (BSD-3, active). Never sourcekit-lsp's underscored module.
- **Neovim RPC** (P4b): msgpack via maintained library or vendored
  `MessagePack.swift`; RPC framing hand-rolled (small); VimR `NvimApi` as
  reference.
- **Lua versions**: LuaSwift selects the Lua version at compile time
  (`LUASWIFT_LUA_VERSION`), so one build = one version. **P1 ships a single
  binary built against 5.4** (LuaSwift's default). The project file carries a
  version field from day one (validated; non-5.4 values error with guidance).
  Shipping all five versions (5.1–5.5) is a distribution-phase deliverable;
  the mechanism (five binaries + selector shim vs. fat binary) is an open
  question resolved then — it no longer blocks P1.
- **Testing**: **Swift Testing** (`@Test`/`#expect`); Rust shim tested with
  cargo test. UI logic separated from terminal I/O for unit testability;
  snapshot-style tests of rendered cell buffers where practical; fixture
  projects for integration tests (run/lint/debug flows). Specific coverage
  scope set at PRD time.
- **CI**: GitHub Actions, macOS runner with Rust toolchain; **builds AND runs
  the full test suite** (Swift + cargo) on every push/PR; the luacheck spike
  test is a required check. Lua-version build matrix joins at the
  distribution phase. Formatter/linter gates (swift-format etc.) decided at
  PRD time.

### Constraints

- **macOS-only** dev tool (no Linux/Windows in scope; terminal + process
  spawning + LuaSwift's Apple-platform focus). **Minimum macOS 13** (modern
  Swift 6 toolchain floor; LuaSwift itself supports 12+, so the binding is
  our choice, revisitable).
- License: Apache 2.0 (already committed). Vendored/depended components must
  be compatible (luacheck MIT, ratatui MIT, crossterm MIT, SwiftTreeSitter
  MIT, tree-sitter-lua MIT, ChimeHQ BSD-3, VimR-derived code MIT — all
  compatible; attribution preserved).
- **Build-time Rust toolchain** is acceptable for contributors and CI; it
  must NOT be required by end users (prebuilt shim artifacts in releases).
- Zero mandatory external **runtime** dependencies for P1/P2: lint embedded,
  no LuaLS, no nvim required. Optional integrations degrade gracefully.
- LuaSwift coupling: only public API (preferred) or `@_spi(Tooling)`
  (fallback); never forking or reaching into internals.
- `Package.resolved` is committed and tracked (executable tool — reproducible
  builds); the Rust shim's `Cargo.lock` likewise.
- Performance: TUI must stay responsive during runs (async execution);
  lint pre-pass fast enough to run on change. No further quantified targets
  at requirements stage (PRD sets any needed).
- The tool itself runs scripts **unsandboxed-capable**: it is a dev tool, the
  user may enable `unrestricted` config to test io/os-touching code — but the
  default mirrors the library default (sandboxed).

## Open Questions

1. **Five-version delivery mechanism** (distribution phase, post-P1) — five
   binaries + selector shim vs. fat binary with five embedded engines.
   Context: LuaSwift's version selection is compile-time per build of the C
   target; a fat binary means five `CLua` builds linked under distinct module
   names (feasibility unverified — symbol-collision risk in one process).
   Current thinking: five binaries + `moonswift` shim reading the project
   file's version. Impact: packaging, CI matrix. Decide when distribution
   phase is planned; P1 unaffected (single 5.4 binary).
2. **Debugger pause concurrency model** — hook blocks engine thread awaiting
   debugger commands (channel/semaphore) vs. coroutine-based. Belongs to the
   LuaSwift#20 API design; not blocking P1. Impact: shape of the upstream
   API.
3. **Shim API granularity** — how much of ratatui's widget set the C ABI
   exposes in v1 vs. driving more through the cell-level API. Current
   thinking: minimal widget surface (layout splits, list, paragraph, status
   bar) + cells for everything custom; grow on demand. Impact: shim scope,
   PRD task sizing. Decide in PRD/architecture.
4. **Bottom pane structure** — tabs (Output | Diagnostics | Debug) vs. merged
   annotated stream. Current thinking: tabs. Decide in PRD (UX detail).
5. **Module catalog source format** — hand-maintained Swift description of the
   31 modules' signatures vs. generated from LuaSwift source/doc comments.
   Hand-maintained drifts; generation needs LuaSwift-side annotations.
   Current thinking: start hand-maintained in MoonSwift, propose a
   machine-readable catalog upstream later (#21 covers names, not
   signatures). Impact: F4/F7 fidelity, upstream scope. Decide in PRD.
6. **JSONPath implementation** — RFC 9535 conformance level and library
   (existing Swift implementation vs. own parser for the subset YAML/TOML
   trees need). Impact: F1/F2 effort. Decide in PRD.

## Deferred Ideas

- **Standalone ratatui-shim package** (e.g. "SwiftRatatui") — extract the
  Rust shim + Swift overlay into its own repo/release cycle once proven in
  MoonSwift, per the satellite-library strategy. Complexity M (packaging,
  docs, semver discipline). Depends on the shim stabilizing through P1–P2.
  Promote when a second consumer or external interest appears.
- **Swift codegen export** (from mock definitions to `LuaValueServer`
  conformance source for the host app) — rationale: mocking serves the
  testing goal without codegen; codegen is a distinct "scaffolding" feature.
  Complexity M. Depends on F5. Promote when users ask for it.
- **Embedded nvim ext_multigrid / externalized UI** (cmdline, popupmenu drawn
  by MoonSwift) — single-grid is sufficient; externalization is polish.
  Complexity M. Depends on F8b.
- **PTY-hosted editor pane** (SwiftTerm headless + pty running stock nvim or
  any `$EDITOR` inside the main pane) — alternative/complement to ext_linegrid
  embedding; lower integration ceiling but editor-agnostic. Complexity M.
  Revisit at P4 planning if ext_linegrid proves heavy.
- **Watch mode / auto-rerun on file change** — natural once F3 exists;
  deferred to keep P1 minimal. Complexity S. Promote in any post-P1 phase.
- **Multiple simultaneous engines** (compare a script across Lua versions
  side-by-side) — depends on Open Question 1 resolving toward fat binary;
  niche. Complexity L.
- **Other-library awareness** (NumericSwift etc. module catalogs when
  LuaSwift is built with those flags) — requirement (a) limits v1 to plain
  LuaSwift; catalog generator should be designed not to preclude it.
  Complexity S–M. Promote post-P3.
- **Distribution polish** — Homebrew formula, notarized release binaries,
  five-Lua-version delivery (Open Question 1), `moonswift init` scaffolding.
  Promote when the tool is publicly useful (post-P2 realistically).
- **REPL pane** (interactive Lua prompt against the mocked environment) —
  high value but new UI surface; revisit at P2 review. Complexity M.
- **Accessibility** (screen-reader-friendly output mode, high-contrast/
  color-blind-safe themes) — revisit post-P2.
