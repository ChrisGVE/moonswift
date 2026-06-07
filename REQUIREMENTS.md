# MoonSwift — Requirements

Status: draft for audit (req-collection, 2026-06-07)

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
in their own right. MoonSwift pins a minimum LuaSwift version.

## MVP(+) Scope

Delivery is phased. P1 is the MVP; each phase is independently shippable.

| Phase | Contents |
| ----- | -------- |
| P1 | TUI shell (3 panes), load `.lua` + structured-file fields, one-shot run, lint, project file |
| P2 | Sharing-area mocking (runtime), full debugger (breakpoints/step/inspect) — requires LuaSwift API additions |
| P3 | Completions: native catalog first, optional lua-language-server integration |
| P4 | Editing: suspend+`$EDITOR` with write-back, then embedded Neovim (ext_linegrid) |

### Core Features

#### F1. Source loading (P1)

- Load Lua code from `.lua` files.
- Load Lua code from designated string fields inside JSON, YAML, and TOML
  files. Designation mechanism: the **MoonSwift project file** lists source
  files and path expressions to Lua-bearing fields; additionally an
  **interactive picker** in the TUI browses a structured file's tree and lets
  the user mark fields, persisting the selection to the project file.
- A loaded fragment retains provenance (file, path expression, byte span) —
  required later for write-back (F8) and for correct lint/error line mapping
  (fragment line 1 ≠ file line 1).
- Acceptance: open a project containing a `.lua` file and a YAML file with a
  marked field; both appear as loadable sources; switching sources updates the
  main pane.

#### F2. Project file (P1)

- TOML file (working name `moonswift.toml`) at project root holding: source
  file list, field designations (path expressions per structured file),
  selected Lua version, sharing-area mock definitions (P2), and tool settings.
- Human-editable, diff-friendly, committed to the user's repo.
- `moonswift` launched without a project file offers to create one;
  `moonswift <file.lua>` works without a project for quick one-offs.
- Acceptance: round-trip — picker-made designations persist and reload.

#### F3. One-shot run (P1)

- Execute the selected source in a fresh LuaSwift engine
  (`LuaEngineConfiguration` selectable: sandboxed/unrestricted, the tool
  defaults to sandboxed to mirror host-app reality).
- Output (print/return value) and errors appear in the bottom pane. Errors map
  to source lines (fragment offset applied for structured-file fields).
- Run is non-blocking for the UI (engine runs off the main thread or the UI
  remains responsive); a running script can be cancelled
  (instruction-limit hook as backstop).
- Acceptance: a script printing and erroring shows output then the error with
  the correct line number; runaway loop is cancellable.

#### F4. Linting (P1)

- Two layers:
  1. **Syntax pre-pass** via the host engine's load (always correct for the
     active Lua version) — instant, on every source change.
  2. **luacheck embedded**: vendor luacheck (pure Lua) and run it *inside* a
     dedicated LuaSwift engine; pass options programmatically with the
     LuaSwift module catalog (and, once P2 exists, the project's mocked
     functions/namespaces) injected as known globals — eliminating
     false "undefined global" warnings that generic Lua tooling produces.
- Diagnostics render in the bottom pane and as gutter/inline marks in the main
  pane, with line/column from luacheck's structured report.
- Acceptance: a script using `luaswift.json.encode` and a mocked function
  lints clean; an actually-undefined global is reported.

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
  values, functions) and live state after runs.
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
- **Dependency: new public LuaSwift debug/introspection API** (tracked
  upstream, shipped via LuaSwift's release flow; `@_spi(Tooling)` is the
  fallback if public API is rejected):
  - `lua_sethook`-based line/call/return event hooks with safe Swift
    callbacks;
  - structured errors (line, column where available, traceback) instead of
    plain strings;
  - local/upvalue enumeration at a paused frame (`lua_getlocal` etc.);
  - enumeration of registered servers and functions (today private) — also
    needed by F5's navigator and F4/F7's catalogs.
- Acceptance: set breakpoint, run, hit it, step, inspect a local, continue to
  completion; error in a nested call shows a traceback with correct lines.

#### F7. Completions & hover (P3)

- **Phase 3a — native catalog**: in-process completions and hover docs for the
  LuaSwift module catalog (the ~31 `luaswift.*` modules) plus the project's
  mocked functions/namespaces — derived live from the engine/module registry,
  so user-registered mocks complete instantly. Keyboard-triggered in the main
  pane (read-only context: signature/hover lookup; full completion matters
  most once editing exists).
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
  pattern). Write-back:
  - `.lua` files: overwrite file;
  - structured-file fields: **span-splice** — locate the value's exact byte
    range in the original file, splice the edited text with correct
    escaping/indentation for the format (JSON string escaping, YAML block
    scalar indentation, TOML), re-parse the whole file as a validation step.
    Comments, key order, and formatting outside the span are preserved by
    construction (Swift YAML/TOML libraries do not round-trip faithfully;
    span-splice sidesteps that).
- **Phase 4b — embedded Neovim**: `nvim --embed` child process, msgpack-RPC,
  `nvim_ui_attach` with `ext_linegrid` (single grid); MoonSwift renders the
  grid into the main pane and translates input to nvim key notation. VimR's
  MIT `NvimApi` Swift package is the donor/reference implementation for the
  RPC layer. Graceful absence: no `nvim` on PATH → 4a behavior.
- Acceptance (4a): edit a YAML-hosted fragment introducing a syntax error →
  reopened with error comment; fix → file updated, all comments/format
  preserved; (4b): nvim renders in-pane, `:w` triggers the same write-back.

### User Experience

Single-window TUI, keyboard-driven, three regions:

- **Left column — navigator**: tree of project sources (.lua files,
  designated fields) and, from P2, the sharing-area mock environment
  (namespaces → values, functions). Selecting a source loads it in the main
  pane.
- **Main area — code**: read-only (until P4) display of the selected source
  with tree-sitter syntax highlighting, line numbers, lint gutter marks,
  breakpoint marks (P2), current-line indicator while debugging.
- **Bottom pane — output & messages**: run output, structured errors with
  tracebacks, lint diagnostics, debugger status. Tabbed or merged stream
  (PRD decides).

Conventions: vim-flavored navigation where it doesn't conflict
(`hjkl`-friendly, `:`-style command line acceptable but not required for v1),
visible key hints (status bar), every action reachable by keyboard, mouse
support where TermKit gives it for free. Resize-safe. Works in 80×24 minimum;
designed for larger.

"Magic moment": point MoonSwift at a config file with an embedded script,
mock the two functions the app provides, hit run, see it work — without
launching the host app.

### Technical Architecture

- **Language/runtime**: Swift (5.9+, Swift 6 mode preferred), macOS only
  (minimum macOS 13, per TermKit). SPM executable package; binary `moonswift`.
- **TUI framework**: **TermKit** (migueldeicaza) — SplitView/ListView/
  StatusBar map directly to the three regions; public `Painter` API allows
  the custom cell-grid view the nvim phase needs; bundled SwiftTerm-backed
  `Terminal` view as fallback embedding path. Alpha quality: pin a commit,
  expect to upstream fixes. **SwiftTerm** (headless engine) for PTY needs.
- **Syntax highlighting**: SwiftTreeSitter + tree-sitter-lua (both active,
  SPM-ready); capture names map to terminal color attributes. Same machinery
  later locates spans for write-back in JSON/YAML/TOML (tree-sitter grammars
  exist for all three).
- **Engine**: LuaSwift via SPM, pinned minimum version. One engine instance
  per run (fresh state); a separate long-lived engine hosts embedded luacheck.
- **Lint**: vendored luacheck (master, for Lua 5.5 syntax) executed in-process;
  options injected programmatically from the catalog generator.
- **LSP client** (P3b): ChimeHQ `LanguageServerProtocol` + `LanguageClient`
  (BSD-3, active). Never sourcekit-lsp's underscored module.
- **Neovim RPC** (P4b): msgpack via maintained library or vendored
  `MessagePack.swift`; RPC framing hand-rolled (small); VimR `NvimApi` as
  reference.
- **Lua versions**: LuaSwift selects the Lua version at compile time
  (`LUASWIFT_LUA_VERSION`), so one build = one version. Decision: **ship all
  five** (5.1–5.5). Mechanism (five binaries `moonswift-5x` + selector shim
  vs. one fat binary linking five engine builds) is a PRD/architecture
  decision — see Open Questions.
- **Upstream LuaSwift work** (tracked as LuaSwift issues, releases precede the
  MoonSwift phases needing them):
  1. structured errors (line/traceback) — needed by P1 (error line mapping
     benefits) but P1 can fall back to parsing Lua's error-string format;
     required by P2;
  2. debug hook API (line/call/return events, pause/resume, locals/upvalues) —
     P2;
  3. introspection: enumerate registered servers/functions — P2 (navigator),
     P3 (catalog).
- **Testing**: XCTest; UI logic separated from terminal I/O for unit
  testability; snapshot-style tests of rendered cell buffers where practical;
  fixture projects for integration tests (run/lint/debug flows). Specific
  coverage scope set at PRD time.
- **CI**: GitHub Actions, macOS runner; build matrix across the five Lua
  versions mirrors LuaSwift's own CI approach.

### Constraints

- macOS-only dev tool (no Linux/Windows in scope; terminal + process spawning
  + LuaSwift's Apple-platform focus).
- License: Apache 2.0 (already committed). Vendored/depended components must
  be compatible (luacheck MIT, TermKit MIT, SwiftTerm MIT, ChimeHQ BSD-3,
  VimR-derived code MIT — all compatible; attribution preserved).
- Zero mandatory external runtime dependencies for P1/P2: lint embedded,
  no LuaLS, no nvim required. Optional integrations degrade gracefully.
- LuaSwift coupling: only public API (preferred) or `@_spi(Tooling)`
  (fallback); never forking or reaching into internals.
- Performance: TUI must stay responsive during runs (async execution);
  lint pre-pass fast enough to run on change. No further quantified targets
  at requirements stage (PRD sets any needed).
- The tool itself runs scripts **unsandboxed-capable**: it is a dev tool, the
  user may enable `unrestricted` config to test io/os-touching code — but the
  default mirrors the library default (sandboxed).

## Open Questions

1. **Five-version delivery mechanism** — five binaries + selector vs. fat
   binary with five embedded engines. Context: LuaSwift's version selection is
   compile-time per build of the C target; a fat binary means five `CLua`
   builds linked under distinct module names (feasibility unverified —
   symbol-collision risk in one process). Current thinking: five binaries +
   `moonswift` shim reading the project file's version is simpler and
   CI-cheap. Impact: packaging, project-file semantics, CI matrix. Decide in
   PRD/architecture.
2. **Debugger concurrency model** — pausing Lua at a hook while the TUI stays
   interactive: hook blocks engine thread awaiting debugger commands
   (channel/semaphore), or coroutine-based? Depends on the upstream API design.
   Impact: shape of the LuaSwift debug API proposal. Decide during the
   LuaSwift API design (P2 prep), not blocking P1.
3. **Path-expression syntax for field designation** — minimal dotted/bracket
   notation (`scripts.on_load`, `jobs[2].hook`) vs. adopting full JSONPath.
   Current thinking: minimal grammar covering keys, array indices, and a
   wildcard (`tests[*].body`); extend if real use demands. Impact: F1/F2
   parsing scope. Decide in PRD.
4. **Bottom pane structure** — tabs (Output | Diagnostics | Debug) vs. merged
   annotated stream. Current thinking: tabs. Decide in PRD (UX detail).
5. **Module catalog source format** — hand-maintained Swift description of the
   31 modules' signatures vs. generated from LuaSwift source/doc comments.
   Hand-maintained drifts; generation needs LuaSwift-side annotations.
   Current thinking: start hand-maintained in MoonSwift, propose a
   machine-readable catalog upstream later. Impact: F4/F7 fidelity, upstream
   scope. Decide in PRD.

## Deferred Ideas

- **Swift codegen export** (from mock definitions to `LuaValueServer`
  conformance source for the host app) — rationale: mocking serves the
  testing goal without codegen; codegen is a distinct "scaffolding" feature.
  Complexity M. Depends on F5. Promote when users ask for it.
- **Embedded nvim ext_multigrid / externalized UI** (cmdline, popupmenu drawn
  by MoonSwift) — single-grid is sufficient; externalization is polish.
  Complexity M. Depends on F8b.
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
  `moonswift init` scaffolding. Promote when the tool is publicly useful
  (post-P2 realistically).
- **REPL pane** (interactive Lua prompt against the mocked environment) —
  high value but new UI surface; revisit at P2 review. Complexity M.
