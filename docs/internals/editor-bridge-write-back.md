# Internals — EditorBridge / WriteBackCoordinator seam

This document covers the internal design of the editing subsystem (P4 F8b)
introduced in ARCHITECTURE.md §10. It is intended for contributors navigating
the nvim-embed and write-back code paths.

---

## Overview

The editing subsystem has two phases:

1. **Session establishment** — `EditorBridge.spawn` forks `nvim --embed --clean`,
   wires the RPC actor, and hands a live `NvimSession` to the AppDriver via
   `AppEvent.nvimReady(NvimSession)`.

2. **Write-back** — when the user presses `:w` inside the nvim pane,
   `WriteBackCoordinator.write` splices the edited text into the source file using
   the same `SpanSplicer` / `SpanLocator` machinery used by `SourceStore`.

The two components are statically namespaced enums. There is no `EditorBridge`
instance and no `WriteBackCoordinator` instance — all state flows through
`AppState` and `EventChannel`.

---

## EditorBridge

File: `Sources/MoonSwiftTUI/Nvim/EditorBridge.swift`

`EditorBridge.spawn` executes a strict 11-step ordering (ARCHITECTURE.md §10.4,
§10.8 Inc-7). The ordering matters because nvim begins sending `redraw`
notifications as soon as `nvim_ui_attach` returns; any handler registered after
that point may miss the first batch.

```
Step  What happens
────  ──────────────────────────────────────────────────────────────────
 1    NvimProcessSupervisor.probe() — locate nvim binary; check version ≥ 0.9.
      On failure: post AppEvent.nvimUnavailable and return.

 2    NvimProcessSupervisor.spawn(path:) — fork nvim --embed --clean with
      XDG isolation (0700 temp dir). Open stdin/stdout/stderr pipes.

 3    supervisor.onExit { } — register exit handler BEFORE attachPipes so
      no exit event is missed between process start and pipe attachment.

 4    rpc.attachPipes — hand stdin/stdout to the actor; starts the
      nvim-rpc-reader Thread (moonswift.nvim-rpc-reader).

 5    rpc.request nvim_ui_attach(width, height, {ext_linegrid:true}).
      Declares the grid dimensions; nvim begins sending redraw batches.

 6    rpc.notify nvim_command("set noswapfile nomodeline shadafile=NONE laststatus=0")
      — hardening BEFORE any buffer operations. Prevents swapfile resolution
      from racing with buffer name assignment.

 7    rpc.onNotification("moonswift_write", handler)
      — MUST be registered BEFORE step 9 so no `:w` notification is missed.

 8    Buffer seed:
        .lua file   → nvim_buf_set_name(0, absolutePath)
        structured  → nvim_buf_set_lines, nvim_buf_set_option(filetype=lua),
                       nvim_buf_set_option(modified=false)

 9    rpc.request nvim_create_autocmd("BufWriteCmd", {pattern:"*",
      command:"call rpcnotify(1, 'moonswift_write')"})
      — intercepts `:w` and fires the write-back notification.

10    Construct NvimSession(supervisor:, rpc:).

11    Post AppEvent.nvimReady(session) via EventChannel.
```

### Test seam

`EditorBridge.spawn` accepts a `SessionOverride?` parameter. When non-nil it
skips steps 1–2 entirely and uses the pre-built supervisor and RPC actor
directly. Tests inject fake `Pipe` pairs this way; no real nvim process is
needed.

---

## WriteBackCoordinator

File: `Sources/MoonSwiftTUI/Nvim/WriteBackCoordinator.swift`

`WriteBackCoordinator.write` is a static `async` function. It runs an 8-step
pipeline; every step that fails returns immediately without writing the file.

```
Step  What happens
────  ──────────────────────────────────────────────────────────────────
 1    Cap editedText at structuredFileSizeLimit (50 MiB). Returns .ioFailure
      if exceeded.

 2    Syntax pre-pass via the injected LintServiceProtocol. Returns
      .spliceError if a Diagnostic is produced.

 3    First SourceStore.validateReadable guard (CR-028/CR-030: file type,
      size, path-escape). Returns .validateReadableRejection on failure.

 4    Read the current file bytes on the background ioQueue via
      withCheckedThrowingContinuation. Returns .ioFailure on I/O error.

 5    Conflict check: SpanSplicer.hasConflict(currentData:expected:).
      Returns .conflictDetected unless force:true.

 6    Format dispatch (performSplice):
        .lua extension   → SpanSplicer.overwriteLua (full-file overwrite)
        .json extension  → re-locate span → SpanSplicer.spliceJSON
        .yaml extension  → re-locate span → SpanSplicer.spliceYAML
                           (strips one trailing \n before splice)
        .toml extension  → re-locate span → SpanSplicer.spliceTOML
      Re-location always uses the LIVE currentData bytes — the stale
      provenance.byteRange is never reused.

 7    Second SourceStore.validateReadable guard — TOCTOU window between
      the read (step 4) and the write (step 8).

 8    Atomic write via Data.write(to:options:.atomic) on the background
      ioQueue via withCheckedThrowingContinuation.
```

### Blocking I/O isolation

All `Data(contentsOf:)` and `Data.write(to:options:)` calls happen on a
dedicated serial `DispatchQueue` (`com.moonswift.writeback-io`) wrapped in
`withCheckedThrowingContinuation`. This keeps Swift cooperative-pool threads
free; the AppDriver's UI thread is never blocked by disk I/O.

### Re-location pipeline

For structured formats, step 6 re-locates the Lua value's byte span on the
CURRENT file bytes (not the stale provenance.byteRange). The pipeline:

```
1. JSONPathExpression(parsing: provenance.jsonpath)
2. String(data: currentData, encoding: .utf8)
3. Decode → TreeValue (format-specific decoder)
4. expression.evaluate(on: tree) → [Match]
5. firstMatch.path.steps → [ResolvedStep]
6. SpanLocator.locateSpan(in: currentData, format:, path:, document:)
   → SpanLocation.byteRange
```

This re-location ensures correctness when external edits have shifted byte
offsets since the fragment was loaded.

---

## Thread model

| Thread / executor | Functions called |
|-------------------|-----------------|
| AppDriver (UI thread) | Calls `EditorBridge.spawn` inside a background `Task`; receives `AppEvent.nvimReady` |
| Background `Task` (Swift cooperative pool) | `EditorBridge.spawn` body; `WriteBackCoordinator.write` body |
| `NvimRPCClient` actor executor | `rpc.attachPipes`, `rpc.request`, `rpc.notify`, `rpc.onNotification`; all `await rpc.*` calls hop here |
| `moonswift.nvim-rpc-reader` Thread | Reads nvim stdout via blocking `read(2)`; delivers to the actor via `Task { await client.deliver(msg) }` |
| `com.moonswift.writeback-io` DispatchQueue | `Data(contentsOf:)` and `Data.write` |

The nvim-rpc-reader thread is the **nvim-rpc-class** defined in
ARCHITECTURE.md §5.2. It must not call render/terminal-class or input-class
functions.

---

## Error taxonomy (write-back outcomes)

| Outcome | Cause | User-visible rendering |
|---------|-------|----------------------|
| `.success` | Write completed | Reload source; status-bar "saved" |
| `.validateReadableRejection` | File type, size, or path-escape violation | Status-bar: "Cannot read file: \<reason\>" |
| `.spliceError(.reparseFailed)` | Syntax pre-pass or re-location failed | Status-bar: format-specific diagnostic |
| `.spliceError(other)` | SpanSplicer validation failure | Status-bar: format-specific diagnostic |
| `.ioFailure` | Read or write I/O error | Status-bar: "Write failed: \<reason\>" |
| `.conflictDetected` | Content hash mismatch | Conflict modal: `[r]/[o]/[d]/[c]` |

---

## Key invariants

- **Handler before autocmd** (step 7 before step 9): if the autocmd fired and
  the handler had not yet been registered, the write-back notification would be
  lost. The ordering is tested in `EditorBridgeTests`.
- **Re-locate, never reuse**: `WriteBackCoordinator` never reads
  `fragment.provenance.byteRange` for the actual splice — it always re-locates
  from the live bytes. The stale range is only used to seed the conflict check
  (via the hash, not the range itself).
- **TOCTOU double-check**: `validateReadable` runs twice — once before the read
  and once immediately before the write — to close the symlink-swap window.
- **SIGPIPE ignored at startup**: `signal(SIGPIPE, SIG_IGN)` is installed in
  `Sources/moonswift/main.swift` before any pipe is opened. A write to a
  dead nvim pipe therefore raises `EPIPE` (surfaced as `.ioFailure`) rather
  than killing MoonSwift.

---

## Related files

| File | Role |
|------|------|
| `Sources/MoonSwiftTUI/Nvim/EditorBridge.swift` | Session lifecycle: probe → spawn → RPC handshake |
| `Sources/MoonSwiftTUI/Nvim/WriteBackCoordinator.swift` | Write-back pipeline: 8-step format dispatch |
| `Sources/MoonSwiftTUI/Nvim/NvimProcessSupervisor.swift` | Process fork, pipe management, teardown |
| `Sources/MoonSwiftTUI/Nvim/NvimRPCClient.swift` | Actor: request/notify/onNotification |
| `Sources/MoonSwiftTUI/Nvim/NvimRedrawHandler.swift` | Redraw batch decoder |
| `Sources/MoonSwiftCore/Sources/SpanSplicer.swift` | Format-specific splice operations |
| `Sources/MoonSwiftCore/Sources/SpanLocator.swift` | tree-sitter-based byte-span location |
| `Tests/MoonSwiftTUITests/Nvim/WriteBackCoordinatorTests.swift` | Unit tests: format paths, conflict, errors |
| `Tests/MoonSwiftTUITests/Nvim/WriteBackIntegrationTests.swift` | E2e / acceptance tests (PRD §F8) |
| `Tests/MoonSwiftTUITests/Nvim/WriteBackTestSupport.swift` | MockLintService, WriteBackFixtures |
