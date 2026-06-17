// File: Sources/MoonSwiftTUI/App/Reducer.swift
// Location: MoonSwiftTUI/App/
// Role: Pure (AppState, AppEvent) → (AppState, [Effect]) function. All state
//       transitions live here. The reducer dispatches to focused sub-reducers
//       for key events and handles service events centrally. No I/O, no side
//       effects — effects are *requested*, not executed (ARCHITECTURE.md §5.1).
// Upstream: AppState, AppEvent, Effect
// Downstream: AppDriver (calls reduce(_:_:) on the UI thread)
//
// Inc-8 additions (ARCHITECTURE.md §10.8):
//   - Four FocusState cases added: nvimPane/nvimSpawning/conflictModal/diffView.
//   - reduceKey modal switch is now exhaustive (no default:) — every new case
//     must be handled here at compile time.
//   - nvim event arms: nvimReady, nvimProcessExited, nvimDetached, nvimUnavailable.
//   - resize → nvimResize debounce (~50 ms) while nvim pane active.
//   - <C-e> in code pane: spawnNvim; <C-e> in nvim pane: nvimDetach.

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - reduce

/// Applies `event` to `state` and returns the next state with any requested effects.
///
/// This is the heart of the Elm-style loop. The function is pure: given the
/// same inputs it always returns the same outputs. The AppDriver executes the
/// returned effects; the reducer never does.
///
/// Key dispatch: global keys are checked first (they work in every pane);
/// pane-specific keys are dispatched based on `state.focus`. Modal states
/// capture all keys before the per-pane dispatch.
public func reduce(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    var s = state

    switch event {

    // MARK: Lifecycle

    case .appStarted:
        return reduceAppStarted(s)

    // MARK: Terminal input

    case .key(let code, let modifiers):
        return reduceKey(s, code: code, modifiers: modifiers)

    case .resize(let size):
        // Terminal resize: no broad state change needed — the renderer derives
        // layout from AppState + the size parameter. We do need to notify nvim
        // when its pane is active, but rapid resize bursts must be debounced to
        // avoid flooding the RPC channel (~50 ms window, ARCHITECTURE.md §10.8).
        return reduceResize(s, size: size)

    case .mouse:
        // Mouse events are no-op in P1 (vim-flavored keyboard-only navigation).
        return (s, [])

    case .paste(let text):
        // Forward pasted text to nvim while its pane is focused (via nvim_paste,
        // not nvim_input, so the payload is inserted verbatim). Elsewhere paste
        // is a no-op: the code pane is read-only and the picker uses key events.
        if case .nvimPane = s.focus {
            return (s, [.nvimPaste(text)])
        }
        return (s, [])

    // MARK: Tick

    case .tick:
        return reduceTick(s)

    // MARK: Source loading

    case .sourceLoaded(let id, let fragment):
        s.sources[id] = .loaded(fragment)
        // Ensure the source is in navigator order.
        if !s.navigatorOrder.contains(id) {
            s.navigatorOrder.append(id)
        }
        // Schedule syntax highlight for the newly loaded source.
        var effects: [Effect] = [.highlight(id)]
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
        return (s, effects)

    case .sourceFailed(let id, let state):
        s.sources[id] = state
        if !s.navigatorOrder.contains(id) {
            s.navigatorOrder.append(id)
        }
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    case .projectLoaded(let file, let diagnostics):
        s.project = .loaded(file, diagnostics: diagnostics)
        // Clear stale sources and navigator order so entries from the previous
        // project file do not persist after a C-r reload.
        s.sources = [:]
        s.navigatorOrder = []
        s.selection = nil
        // F5.4: load declared mocks; reset the mock-section cursor + live cache
        // (stale on reload — repopulated on the next run).
        s.mockStore = file.mocks
        s.mockLiveState = nil
        s.navigator.inMockSection = false
        s.navigator.mockSelectedIndex = 0
        // F5.6: restore the saved navigator/bottom split ratios into the layout.
        applySplitRatios(&s, settings: file.settings)
        // F7b: every diagnostic source belongs to the previous project file —
        // clear all three and re-merge so the tab/gutter reflect the new project.
        s.bottomPane.luacheckDiagnostics = []
        s.bottomPane.lualsDiagnostics = []
        s.bottomPane.prePassDiagnostic = nil
        remergeDiagnostics(&s)
        // Re-load sources and (re)start the optional lua-language-server.
        return (s, [.loadSources, .spawnLuaLS])

    case .projectMalformed(let diag):
        s.project = .malformed(diag)
        return (s, [])

    case .projectUnsupportedVersion(let file, _):
        // Degrade to the unsupported-version state (ux-spec §3.7): `r` and `l`
        // are blocked, the bottom pane shows a persistent error header, and the
        // title bar shows `[Lua X.X: unsupported]`. The diagnostics are
        // discarded here because they are already surfaced by the ProjectStore
        // (they contain the "unsupported version" warning); the ProjectState
        // enum carries only the version string the renderer needs.
        s.project = .unsupportedVersion(file.luaVersion)
        return (s, [])

    case .designationsSaved:
        // Close the picker (if open) and reload sources so the navigator
        // reflects the newly saved designations.
        s.pickerState = nil
        s.focus = .pane(.navigator)
        return (s, [.loadSources])

    case .pickerTreeReady(let id, let tree, let errorMessage):
        return reducePickerTreeReady(s, id: id, tree: tree, errorMessage: errorMessage)

    // MARK: Run

    case .runOutput(let lines):
        // Append unconditionally — defense-in-depth (ARCHITECTURE.md §3c).
        s.bottomPane.appendOutputLines(lines)
        return (s, [])

    case .runFinished(let outcome):
        s.runState = .completed(outcome)
        // Log engine-level failures (not script errors) for post-mortem diagnosis.
        if case .engineError(let message) = outcome {
            Logger.shared.error("Lua engine error during run: \(message)")
        }
        // Append the return-value line and run footer to the output buffer so
        // the Output tab always shows the run result (ux-spec §6.3). The renderer
        // reads outputBuffer as-is and expects these lines to already be present.
        if case .done(let value, _) = outcome, let v = value {
            s.bottomPane.appendOutputLines(["→ \(v)"])
        }
        s.bottomPane.appendOutputLines([buildRunFooter(outcome: outcome)])
        // F6.4: append the structured traceback frames (newest first) below the
        // error footer so the Output tab shows where the error occurred.
        if case .error(_, let traceback) = outcome, !traceback.isEmpty {
            s.bottomPane.appendOutputLines(traceback)
        }
        return (s, tickEffectsAfterRunEnds(s))

    case .transient(let message):
        // A service requested a transient status-bar message (e.g. RunService's
        // cancel-degradation notice). Set it and arm the tick for expiry.
        s.transient = TransientMessage(text: message)
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    // MARK: Lint

    case .lintEngineReady:
        s.lintState = .idle
        return (s, [])

    case .lintEngineFailed(let message):
        s.lintState = .failed(message)
        Logger.shared.error("Lint engine failed: \(message)")
        return (s, [])

    case .catalogProbed(let available):
        s.tomlModuleAvailable = available
        return (s, [])

    case .prePassResult(let diag):
        // Record the new syntax-pre-pass state (nil = clean) and re-merge. A
        // clean pass now correctly drops the stale syntax-error gutter mark; an
        // error pass keeps luacheck and LuaLS findings alongside it (F7b).
        s.bottomPane.prePassDiagnostic = diag
        remergeDiagnostics(&s)
        return (s, [])

    case .lintFinished(let diagnostics):
        s.lintState = .idle
        // Replace the luacheck batch and re-merge; the pre-pass and LuaLS
        // findings are preserved by the uniform merge (F7b).
        s.bottomPane.luacheckDiagnostics = diagnostics
        remergeDiagnostics(&s)
        return (s, [])

    // MARK: LuaLS (F7b)

    case .lualsDiagnostics(let lualsDiags):
        // Replace the LuaLS batch and re-merge; the pre-pass and luacheck
        // findings are preserved by the uniform merge (F7b). No per-push filter.
        s.bottomPane.lualsDiagnostics = lualsDiags
        remergeDiagnostics(&s)
        return (s, [])

    case .lualsUnavailable:
        // One-time status-bar note; latch so a reload does not re-nag (F7b).
        if !s.lualsUnavailableNoticeShown {
            s.lualsUnavailableNoticeShown = true
            s.transient = TransientMessage(
                text: "lua-language-server not found — using native catalog.")
            return (s, [armTickIfNeeded(s)].compactMap { $0 })
        }
        return (s, [])

    // MARK: Highlight

    case .highlightReady(let id, let spans):
        s.highlight[id] = spans
        return (s, [])

    // MARK: Init form events (task 24)

    case .projectDirectoryScanned(let files):
        // Populate the init form's candidate file list on scan completion.
        if var form = s.initFormState {
            form.candidateFiles = files
            form.isScanning = false
            s.initFormState = form
        }
        return (s, [])

    case .projectFileWritten(let projectURL, let error):
        return reduceProjectFileWritten(s, projectURL: projectURL, error: error)

    // MARK: Nvim editing (P4 F8b, ARCHITECTURE.md §10.4.2, §10.4.8, §10.8)

    case .nvimRedrawBatch(let events):
        return reduceNvimRedrawBatch(s, events: events)

    case .nvimWriteRequested:
        // BufWriteCmd fired. Fetch the current buffer text via Effect.writeBack
        // (empty editedText = sentinel: AppDriver calls nvim_buf_get_lines before
        // invoking WriteBackCoordinator). ARCHITECTURE.md §10.3c, §10.8 Inc-9.
        return reduceNvimWriteRequested(s)

    case .nvimUnavailable(let reason):
        // nvim is absent or too old. Post the one-time status-bar note
        // (ux-spec §7.4 step 6, exact string) and fall back to $EDITOR
        // (Inc-10 wires Effect.spawnEditorFallback; Inc-8 posts the note).
        return reduceNvimUnavailable(s, reason: reason)

    case .nvimProcessExited(let exitCode):
        // nvim exited — clean or crash. Always emit nvimCleanup; post a transient
        // on unexpected (non-zero) exit (ARCHITECTURE.md §10.8, §10.6 error taxonomy).
        return reduceNvimExited(s, exitCode: exitCode)

    case .nvimReady:
        // Spawn + handshake succeeded. Transition to .nvimPane so the grid is shown.
        // AppDriver already stored the session before calling reduce (see AppDriver
        // drain loop); the reducer only changes focus and state.
        return reduceNvimReady(s)

    case .nvimDetached:
        // nvim acknowledged `qa!`. Tear down the session and return to the code pane.
        // Pass .nvimCleanup explicitly so both cleanup paths are uniform (CR-024).
        return reduceNvimCleanupFocus(s, transientText: nil, extraEffects: [.nvimCleanup])

    // MARK: Write-back outcomes (Inc-9, ARCHITECTURE.md §10.4.2, §10.3c)

    case .writeBackSucceeded(let id):
        // File updated on disk — reload the source so the navigator reflects
        // the new content (same pattern as .designationsSaved → .loadSources).
        return (s, [.loadSource(id)])

    case .writeBackFailed(let outcome):
        // Non-conflict error: surface a status-bar diagnostic per the error
        // taxonomy in ARCHITECTURE.md §10.6.
        return reduceWriteBackFailed(s, outcome: outcome)

    case .writeBackBlocked(let diagnostic):
        // A syntax pre-pass blocked the write. The nvim buffer stays open with
        // the user's edits intact; surface the diagnostic as a *persistent*
        // status-bar message (no 1.5 s expiry) so the reason stays visible until
        // the next `:w` or edit clears it. (Decision: no buffer comment-injection
        // on the nvim path — the buffer is still open, unlike the $EDITOR
        // fallback. ux-spec §7.3, P4 audit gap #5.)
        s.transient = TransientMessage(
            persistentText: "Syntax error: \(diagnostic.message) (line \(diagnostic.line))"
        )
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    case .conflictDetected(let fileURL, let expectedHash, let editedText):
        // External conflict: open the conflict modal (ARCHITECTURE.md §10.3d).
        return reduceConflictDetected(s, fileURL: fileURL, expectedHash: expectedHash, editedText: editedText)

    case .diffViewReady(let diffState):
        // Off-thread build complete: transition to .diffView(.ready).
        s.focus = .diffView(.ready(diffState))
        return (s, [])

    // MARK: Debug (P2 F6.1, ARCHITECTURE.md §10.9)

    case .debugPaused(let snapshot):
        return reduceDebugPaused(s, snapshot: snapshot)

    case .debugFinished(let sessionID, let outcome):
        return reduceDebugFinished(s, sessionID: sessionID, outcome: outcome)

    case .debugResumed(let sessionID):
        // VM resumed after a step/continue command — §6.9 Case-2 transition.
        // Clears the paused snapshot so the Debug tab enters "VM running between
        // pauses" state. Stale session ID is a silent no-op (ARCH-06).
        return reduceDebugResumed(s, sessionID: sessionID)

    case .mockLiveStateReady(let liveState):
        // F5.4: store the introspection snapshot so the Mock Environment section
        // shows live values. `isEmpty` snapshots keep the
        // `(run to populate live state)` hint (DATA-09, handled by buildMockNavRows).
        s.mockLiveState = liveState
        return (s, [])

    // MARK: Lua invocation (F5.3 — handlers in InvokeFormReducer.swift)

    case .luaInvocationResult(let display):
        return reduceLuaInvocationResult(s, display: display)

    case .luaInvocationLintFailed(let detail):
        return reduceLuaInvocationLintFailed(s, detail: detail)

    case .luaInvocationTargetInvalid:
        return reduceLuaInvocationTargetInvalid(s)

    case .luaInvocationFailed(let message):
        return reduceLuaInvocationFailed(s, message: message)

    // MARK: Completions & hover (F7a.2 — handlers in CompletionReducer.swift)

    case .completionsReady(let items):
        return reduceCompletionsReady(s, items: items)

    case .hoverReady(let item):
        return reduceHoverReady(s, item: item)
    }
}

// MARK: - Nvim redraw handler

/// Apply a complete nvim redraw batch to the grid state.
///
/// The batch is guaranteed to end with `.flush` (flush invariant — only complete
/// batches are posted by `NvimRedrawHandler`). Events are applied in order;
/// `hlAttrDefine` entries populate the hl cache used by subsequent `gridLine`
/// events in the same batch.
private func reduceNvimRedrawBatch(_ state: AppState, events: [NvimRedrawEvent]) -> (AppState, [Effect]) {
    var s = state
    // Local mutable copy of the grid; single write-back at the end of the function.
    // Lazily initialised from the first event in the batch (grid may not yet exist
    // if this is the very first redraw after spawn).
    var grid = s.nvimGrid ?? NvimGridState()

    for event in events {
        switch event {
        case .hlAttrDefine(let id, let rgb):
            grid.hlCache[id] = rgb

        case .defaultColorsSet:
            // Default colour tokens are used by the renderer directly; the
            // grid does not store them (renderer reads AppState.theme instead).
            break

        case .gridResize(_, let width, let height):
            grid.resize(width: width, height: height)

        case .gridLine(_, let row, let colStart, let cells):
            // Pre-size the row to grid width before applying colStart-relative
            // writes (ARCHITECTURE.md §10.4.8 grid_line contract).
            let w = grid.width
            if row < grid.cells.count && grid.cells[row].count < w {
                let blank = NvimCellState()
                grid.cells[row].append(
                    contentsOf: Array(repeating: blank, count: w - grid.cells[row].count)
                )
            }
            grid.applyGridLine(row: row, colStart: colStart, cells: cells)

        case .gridCursorGoto(_, let row, let col):
            grid.cursorRow = row
            grid.cursorCol = col

        case .gridScroll(_, let top, let bot, let left, let right, let rows):
            grid.applyScroll(top: top, bot: bot, left: left, right: right, rows: rows)

        case .gridClear:
            grid.clearAll()

        case .modeChange(let name, _):
            // Mode is stored on NvimPaneState, carried by FocusState.nvimPane.
            // Update it when the nvim pane is active (Inc-8); no-op otherwise.
            if case .nvimPane(var paneState) = s.focus {
                paneState.mode = name
                s.focus = .nvimPane(paneState)
            }

        case .flush:
            // Flush terminates the batch. No state change here — the batch is
            // already complete (NvimRedrawHandler only posts on flush).
            break
        }
    }

    // Write back the mutated grid (single assignment, no force-unwrap needed).
    s.nvimGrid = grid
    return (s, [])
}

// MARK: - Nvim focus + session handlers (Inc-8)

/// Handle `<C-e>` from the code pane: spawn nvim, transition to `.nvimSpawning`.
///
/// The code pane rect is derived from the current terminal size and pane layout
/// stored in `AppState.terminalSize` and `AppState.paneLayout` via
/// `computeLayout` (same function the renderer uses — keeps dimensions consistent).
///
/// Returns `(s, [])` without effect if no source is loaded in the code pane.
private func reduceCodePaneSpawnNvim(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    // Require a loaded fragment to edit.
    guard let sid = s.selection,
        case .loaded(let fragment) = s.sources[sid]
    else {
        s.transient = TransientMessage(text: "No source selected to edit")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    let layout = computeLayout(size: s.terminalSize, paneLayout: s.paneLayout)
    s.focus = .nvimSpawning
    return (s, [.spawnNvim(fragment, codePaneRect: layout.codePane)])
}

/// Handle `AppEvent.nvimReady`: transition focus to `.nvimPane`.
///
/// AppDriver already owns the session (stored before the reduce call via the
/// drain loop). The reducer only updates `FocusState`; `NvimPaneState.attachedRect`
/// is recomputed from the current layout so the pane state reflects the live
/// dimensions. The `session` parameter is intentionally omitted: the reducer
/// is pure and the session lives in `AppDriver.nvimSession`.
private func reduceNvimReady(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    let layout = computeLayout(size: s.terminalSize, paneLayout: s.paneLayout)
    let paneState = NvimPaneState(attachedRect: layout.codePane)
    s.focus = .nvimPane(paneState)
    return (s, [])
}

/// Handle `AppEvent.nvimUnavailable`: post the one-time fallback note.
///
/// The exact normative string is from ux-spec §7.4 step 6:
///   "nvim not found. Using $EDITOR for editing."
/// Snapshot tests depend on this exact string — do not alter it.
///
/// `Effect.spawnEditorFallback` is emitted here (Inc-10, ARCHITECTURE.md §10.8
/// Inc-10) on every `nvimUnavailable` event so the user's edit session proceeds
/// via `$EDITOR`. The one-time transient note is gated by
/// `nvimFallbackNotedThisSession`; the fallback effect itself is unconditional.
private func reduceNvimUnavailable(_ s: AppState, reason: String) -> (AppState, [Effect]) {
    var s = s
    _ = reason  // Reason is logged by AppDriver; not surfaced in the transient.

    // Reset focus so the renderer shows the code pane (not a stale .nvimSpawning).
    if case .nvimSpawning = s.focus {
        s.focus = .pane(.codePane)
    }

    // Build the fallback effect when a fragment is available to edit.
    // The fragment is re-derived from the current selection, which is still
    // set (the nvimSpawning → nvimUnavailable path does not clear it).
    var effects: [Effect] = []
    if let sid = s.selection, case .loaded(let fragment) = s.sources[sid] {
        effects.append(.spawnEditorFallback(fragment))
    }

    // One-time fallback note (ux-spec §7.4 step 6, exact string).
    // Subsequent nvimUnavailable events still trigger the fallback effect above
    // but do not re-post the transient (ARCHITECTURE.md §10.6).
    if !s.nvimFallbackNotedThisSession {
        s.nvimFallbackNotedThisSession = true
        // Normative string — ux-spec §7.4 step 6, exact spelling (snapshot-tested).
        s.transient = TransientMessage(text: "nvim not found. Using $EDITOR for editing.")
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
    }

    return (s, effects)
}

/// Handle `AppEvent.nvimProcessExited`: always emit cleanup; post a transient on
/// unexpected (non-zero) exit.
///
/// Normative string (ARCHITECTURE.md §10.6 error taxonomy, §10.8):
///   "nvim exited unexpectedly (code N). Edit lost."
private func reduceNvimExited(_ s: AppState, exitCode: Int32) -> (AppState, [Effect]) {
    var s = s

    // Always clean up and restore focus.
    var effects: [Effect] = [.nvimCleanup]

    let isUnexpected = exitCode != 0
    if isUnexpected {
        s.transient = TransientMessage(
            text: "nvim exited unexpectedly (code \(exitCode)). Edit lost."
        )
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
    }

    // Restore focus and clear the nvim grid regardless.
    return reduceNvimCleanupFocus(s, transientText: nil, extraEffects: effects)
}

/// Restore state to `.pane(.codePane)` and clear nvim-session fields.
///
/// Called by both `.nvimProcessExited` and `.nvimDetached` paths. Both callers
/// pass `extraEffects:[.nvimCleanup, ...]` so the cleanup effect list is uniform
/// and inspectable at the call site — no contains-guard needed here (CR-024).
private func reduceNvimCleanupFocus(
    _ s: AppState,
    transientText: String?,
    extraEffects: [Effect] = []
) -> (AppState, [Effect]) {
    var s = s
    var effects: [Effect] = extraEffects

    s.focus = .pane(.codePane)
    s.nvimGrid = nil
    s.nvimPendingResize = nil
    s.nvimResizeDeadline = nil

    // A persistent (nvim-session-scoped) write-block message has no meaning once
    // the session is gone. Clear it here — it has no expiry, so neither the tick
    // handler nor a code-pane keystroke would ever clear it, and it would freeze
    // in the status bar after an exit that did not pass through the nvim-pane key
    // handler (process crash, `:q` via a mapping). Done before any replacement
    // transient is set below.
    if let t = s.transient, t.expiry == nil {
        s.transient = nil
    }

    if let text = transientText {
        s.transient = TransientMessage(text: text)
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
    }

    return (s, effects)
}

// MARK: - Inc-9 write-back reducers

/// Handle `AppEvent.nvimWriteRequested` — the user pressed `:w` in nvim.
///
/// Emits `Effect.writeBack(fragment, editedText: "", force: false)`. The empty
/// `editedText` is a sentinel: AppDriver calls `nvim_buf_get_lines(0, 0, -1, false)`
/// to populate the actual buffer text before invoking WriteBackCoordinator.
/// Only valid while a fragment is loaded and the nvim pane is active.
private func reduceNvimWriteRequested(_ s: AppState) -> (AppState, [Effect]) {
    guard let sid = s.selection,
        case .loaded(let fragment) = s.sources[sid],
        case .nvimPane = s.focus
    else {
        return (s, [])
    }
    // A fresh `:w` supersedes a persistent write-block message; clear it so a
    // stale error does not linger while the new write runs (gap #5). A
    // re-blocked write re-posts it via `.writeBackBlocked`.
    var s = s
    if let t = s.transient, t.expiry == nil { s.transient = nil }
    return (s, [.writeBack(fragment, editedText: "", force: false)])
}

/// Handle `AppEvent.writeBackFailed` — map the outcome to a status-bar diagnostic.
///
/// Error taxonomy (ARCHITECTURE.md §10.6):
///   - `.validateReadableRejection` → "Cannot read file: <reason>"
///   - `.spliceError`               → format-specific message from `SpliceError`
///   - `.ioFailure`                 → "Write failed: <reason>"
///   - `.conflictDetected`          → should not arrive here; handled separately
///   - `.success`                   → should not arrive here (only on failure path)
private func reduceWriteBackFailed(
    _ s: AppState,
    outcome: WriteBackCoordinator.Outcome
) -> (AppState, [Effect]) {
    var s = s
    let message: String
    switch outcome {
    case .validateReadableRejection(let rejection):
        switch rejection {
        case .notRegularFile:
            message = "Cannot read file: not a regular file"
        case .tooLarge(let limitMiB):
            message = "Cannot read file: exceeds \(limitMiB) MiB limit"
        case .outsideProjectRoot:
            message = "Cannot read file: path is outside project root"
        }
    case .spliceError(let err):
        message = "Write failed: \(err.localizedDescription)"
    case .ioFailure(let reason):
        message = "Write failed: \(reason)"
    case .conflictDetected, .success, .syntaxPrePassBlocked:
        // These outcomes are handled by their own AppEvent cases and should
        // never arrive as writeBackFailed. Log defensively and no-op.
        Logger.shared.debug("writeBackFailed received unexpected outcome: \(outcome)")
        return (s, [])
    }
    s.transient = TransientMessage(text: message)
    return (s, [armTickIfNeeded(s)].compactMap { $0 })
}

/// Handle `AppEvent.conflictDetected` — transition to the conflict modal.
///
/// Requires that the current selection has a loaded fragment (provenance carries
/// the file URL and hash needed by the modal). The modal state stores only the
/// data needed at resolution time, not the full file bytes.
private func reduceConflictDetected(
    _ s: AppState,
    fileURL: URL,
    expectedHash: SHA256Digest,
    editedText: String
) -> (AppState, [Effect]) {
    var s = s
    guard let sid = s.selection,
        case .loaded(let fragment) = s.sources[sid]
    else { return (s, []) }

    // Capture the origin so resolution returns to the right surface. A `:w`
    // conflict arrives while the nvim pane is focused (a live session is
    // attached); the $EDITOR-suspend fallback posts the same event from the
    // code pane (its editor process has already exited — no nvim session). The
    // resolution arms must not send the fallback case back to `.nvimPane`, which
    // has no session behind it (P4 audit gap #1).
    let returnsToNvim: Bool
    if case .nvimPane = s.focus {
        returnsToNvim = true
    } else {
        returnsToNvim = false
    }

    let modalState = ConflictModalState(
        fileURL: fileURL,
        expectedHash: expectedHash,
        editedText: editedText,
        fragment: fragment,
        returnsToNvim: returnsToNvim
    )
    s.focus = .conflictModal(modalState)
    return (s, [])
}

/// The focus to restore when a conflict modal is resolved with `[o]` or `[c]`.
///
/// `returnsToNvim` is `true` only when the conflict was raised from the live
/// embedded-nvim `:w` path; the `$EDITOR`-suspend fallback raises the same
/// conflict with no nvim session, so it must land on the code pane rather than a
/// dead `.nvimPane` placeholder (P4 audit gap #1).
private func conflictReturnFocus(_ s: AppState, returnsToNvim: Bool) -> FocusState {
    guard returnsToNvim else { return .pane(.codePane) }
    let rect = computeLayout(size: s.terminalSize, paneLayout: s.paneLayout).codePane
    return .nvimPane(NvimPaneState(attachedRect: rect))
}

/// Handle key events while `FocusState.conflictModal` is active.
///
/// Key map from ux-spec §7.4 and ARCHITECTURE.md §10.3d:
///   [r] — reload: detach nvim + reload the source from disk (discard edits)
///   [o] — overwrite: force write-back with the user's edited text
///   [d] — diff: build a side-by-side diff view off the UI thread
///   [c] — cancel: return to the nvim buffer unchanged
///
/// Normative modal text (ux-spec §7.3 step 9, §7.4):
///   "File changed externally. [r]eload / [o]verwrite / [d]iff / [c]ancel"
private func reduceConflictModalKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    guard case .conflictModal(let modal) = s.focus else { return (s, []) }

    switch (code, modifiers) {
    case (.char("r"), []):
        // Reload: close nvim and reload the source from disk.
        var s = s
        guard let sid = s.selection else { return (s, []) }
        s.focus = .pane(.codePane)
        s.nvimGrid = nil
        s.nvimPendingResize = nil
        s.nvimResizeDeadline = nil
        return (s, [.nvimDetach, .loadSource(sid)])

    case (.char("o"), []):
        // Overwrite: force write-back with the user's edited text (skip conflict check).
        // Return to the originating surface while the write completes in the
        // background — the nvim pane only when a live session is attached; the
        // $EDITOR fallback returns to the code pane (gap #1).
        var s = s
        s.focus = conflictReturnFocus(s, returnsToNvim: modal.returnsToNvim)
        return (s, [.writeBack(modal.fragment, editedText: modal.editedText, force: true)])

    case (.char("d"), []):
        // Diff: build a side-by-side diff view off the UI thread.
        // Preserve the conflict modal in pendingConflictModal so [c] in the diff
        // view can restore it exactly — spec §10.3d (CR-022).
        var s = s
        s.pendingConflictModal = modal
        s.focus = .diffView(.building)
        return (
            s,
            [
                .buildDiffView(
                    fileURL: modal.fileURL,
                    expectedHash: modal.expectedHash,
                    editedText: modal.editedText,
                    fragment: modal.fragment
                )
            ]
        )

    case (.char("c"), []):
        // Cancel: return to the originating surface without any changes — the
        // nvim buffer when a live session is attached, otherwise the code pane
        // (the $EDITOR fallback has no nvim session to return to — gap #1).
        var s = s
        s.focus = conflictReturnFocus(s, returnsToNvim: modal.returnsToNvim)
        return (s, [])

    default:
        // All other keys are absorbed while the modal is open.
        return (s, [])
    }
}

/// Handle key events while `FocusState.diffView` is active.
///
/// Key map (ARCHITECTURE.md §10.3d, §10.8 Inc-9):
///   [c] — cancel: return to the conflict modal with state preserved (CR-022)
///   j / down — scroll down one line
///   k / up   — scroll up one line
private func reduceDiffViewKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    guard case .diffView(let phase) = s.focus else { return (s, []) }

    // While the diff is still building, absorb all input except cancel.
    if case .building = phase {
        return (s, [])
    }

    guard case .ready(var diffState) = phase else { return (s, []) }

    switch (code, modifiers) {
    case (.char("c"), []):
        // Cancel: restore to the conflict modal with state preserved (§10.3d, CR-022).
        // `pendingConflictModal` was set when [d] transitioned to the diff view; if
        // it is non-nil we can restore .conflictModal exactly. If it is nil (unexpected
        // path) fall back to the always-valid code pane — fabricating an `.nvimPane`
        // would strand a `$EDITOR`-fallback-origin conflict on a dead session, the
        // same hazard the conflict-modal arms guard against (P4 audit gap #1).
        var s = s
        if let pending = s.pendingConflictModal {
            s.pendingConflictModal = nil
            s.focus = .conflictModal(pending)
        } else {
            s.focus = .pane(.codePane)
        }
        return (s, [])

    case (.char("j"), []), (.down, []):
        var s = s
        let maxOffset = max(0, max(diffState.leftLines.count, diffState.rightLines.count) - 1)
        diffState.scrollOffset = min(diffState.scrollOffset + 1, maxOffset)
        s.focus = .diffView(.ready(diffState))
        return (s, [])

    case (.char("k"), []), (.up, []):
        var s = s
        diffState.scrollOffset = max(0, diffState.scrollOffset - 1)
        s.focus = .diffView(.ready(diffState))
        return (s, [])

    default:
        return (s, [])
    }
}

/// Handle key events while `FocusState.nvimPane` is active.
///
/// - `<C-e>` detaches from nvim cleanly (emits `Effect.nvimDetach`).
/// - All other keys are translated via `NvimKeyTranslator`; translatable keys
///   produce `Effect.nvimInput(notation)`; untranslatable keys are dropped silently.
private func reduceNvimPaneKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {

    var s = s
    // Any keystroke in the nvim pane counts as the "next edit" that dismisses a
    // persistent write-block message — this also covers typing `:w` (its keys
    // are forwarded here) and `<C-e>` (gap #5).
    if let t = s.transient, t.expiry == nil { s.transient = nil }

    // <C-e> exits the nvim pane (ux-spec §7.4; symmetric with the enter binding).
    if code == .char("e"), modifiers == .ctrl {
        return (s, [.nvimDetach])
    }

    // Translate the key to nvim notation. Untranslatable keys (nil) are dropped.
    guard let notation = NvimKeyTranslator.translate(code, modifiers: modifiers) else {
        return (s, [])
    }

    return (s, [.nvimInput(notation)])
}

/// Handle terminal resize events.
///
/// - Always updates `AppState.terminalSize`.
/// - When the nvim pane is active, starts the ~50 ms debounce window:
///   stores the pending size, sets the deadline, and arms the tick.
private func reduceResize(_ s: AppState, size: TerminalSize) -> (AppState, [Effect]) {
    var s = s
    s.terminalSize = size

    // Only debounce for nvim pane; ignore 0×0 sentinel (AppDriver CR-019).
    guard size.cols > 0 && size.rows > 0 else { return (s, []) }

    switch s.focus {
    case .nvimPane, .nvimSpawning:
        // Store the latest size; the existing deadline extends automatically
        // because each resize resets the deadline to "now + 50 ms".
        s.nvimPendingResize = size
        s.nvimResizeDeadline = Date(timeIntervalSinceNow: 0.050)
        var effects: [Effect] = []
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
        return (s, effects)
    default:
        return (s, [])
    }
}

// MARK: - Lifecycle handler

private func reduceAppStarted(_ s: AppState) -> (AppState, [Effect]) {
    var effects: [Effect] = [.loadSources, .prewarmLint]

    // If a project is loaded, start the tick for any active transient.
    if let tick = armTickIfNeeded(s) {
        effects.append(tick)
    }
    return (s, effects)
}

// MARK: - Tick handler

private func reduceTick(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    var effects: [Effect] = []

    // Expire the transient message if it has a deadline and the deadline has
    // passed. A persistent message (expiry == nil) is left for a reducer to
    // clear explicitly.
    if let t = s.transient, let expiry = t.expiry, Date() >= expiry {
        s.transient = nil
    }

    // Expire the 500 ms highlight pulse only once its deadline has passed
    // (ux-spec §3.5). Ticks can arrive much earlier than 500 ms when a faster
    // consumer (the 100 ms run tick) is also armed — those early ticks must
    // not end the animation, so this mirrors the transient-expiry pattern.
    if let expiry = s.codePane.jumpPulseExpiry, Date() >= expiry {
        s.codePane.jumpPulseLine = nil
        s.codePane.jumpPulseExpiry = nil
    }

    // Advance spinner phase (wraps at 8 — braille set has 8 frames).
    s.navigator.spinnerPhase = (s.navigator.spinnerPhase + 1) % 8

    // Fire the nvim-resize debounce once the ~50 ms window has passed.
    // The deadline is set (or refreshed) by each .resize event while the nvim
    // pane is active; we emit Effect.nvimResize exactly once per debounce window
    // (ARCHITECTURE.md §10.8 Inc-8 "nvimResize debounce").
    if let size = s.nvimPendingResize,
        let deadline = s.nvimResizeDeadline,
        Date() >= deadline
    {
        s.nvimPendingResize = nil
        s.nvimResizeDeadline = nil
        effects.append(.nvimResize(size))
    }

    // Recompute whether the tick is still needed.
    if let tick = armTickIfNeeded(s) {
        effects.append(tick)
    } else {
        effects.append(.stopTick)
    }
    return (s, effects)
}

// MARK: - Key dispatch

private func reduceKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {

    // Modal states capture all keys before global/pane dispatch.
    // No `default:` arm — every FocusState case must be handled here.
    // Adding a new FocusState case is a compile error until wired below.
    switch s.focus {
    case .helpOverlay:
        return reduceHelpOverlayKey(s, code: code, modifiers: modifiers)
    case .pickerModal:
        return reducePickerKey(s, code: code, modifiers: modifiers)
    case .initForm:
        return reduceInitFormKey(s, code: code, modifiers: modifiers)
    case .mockForm:
        return reduceMockFormKey(s, code: code, modifiers: modifiers)
    case .invokeForm:
        return reduceInvokeFormKey(s, code: code, modifiers: modifiers)
    case .nvimPane:
        return reduceNvimPaneKey(s, code: code, modifiers: modifiers)
    case .nvimSpawning:
        // Eat all input while the spawn handshake is in flight.
        return (s, [])
    case .conflictModal:
        return reduceConflictModalKey(s, code: code, modifiers: modifiers)
    case .diffView:
        return reduceDiffViewKey(s, code: code, modifiers: modifiers)
    case .completionPopup:
        return reduceCompletionPopupKey(s, code: code, modifiers: modifiers)
    case .hoverOverlay:
        return reduceHoverOverlayKey(s, code: code, modifiers: modifiers)
    case .pane:
        break
    }

    // Debug restart confirmation gate: when `debugRestartPending` is true, the
    // very next key (y or anything else) resolves the `[y/N]` prompt regardless
    // of pane focus (ARCH §F6.1). Runs before all other dispatch.
    if s.debugRestartPending {
        return reduceDebugRestartKey(s, code: code, modifiers: modifiers)
    }

    // F5.4 mock delete confirmation gate: `Delete this mock? [y/N]` — the next
    // key resolves it (navigator focus, form closed). Runs before pane dispatch.
    if s.mockDeletePending {
        return reduceMockDeleteConfirm(s, code: code)
    }

    // Colon command interception: when the code pane is actively collecting a
    // `:N<Enter>` sequence, ALL keys go to the colon handler — including ones
    // that would normally be global (e.g. `q`, which would otherwise quit).
    // This mirrors how Vim intercepts command-line input before normal bindings.
    if case .pane(.codePane) = s.focus, s.codePane.colonCommand != nil {
        return reduceColonCommand(s, code: code, modifiers: modifiers)
    }

    // Filter interception: when the navigator is focused and a filter is active,
    // character keys and backspace feed the filter query before global dispatch.
    // Esc and Enter are also intercepted here to clear / commit the filter.
    if case .pane(.navigator) = s.focus, s.navigator.filterText != nil {
        return reduceNavigatorFilter(s, code: code, modifiers: modifiers)
    }

    // Global keys — active in all panes when no modal is open.
    if let result = reduceGlobalKey(s, code: code, modifiers: modifiers) {
        return result
    }

    // Per-pane dispatch.
    switch s.focus {
    case .pane(.navigator):
        return reduceNavigatorKey(s, code: code, modifiers: modifiers)
    case .pane(.codePane):
        return reduceCodePaneKey(s, code: code, modifiers: modifiers)
    case .pane(.bottomPane):
        return reduceBottomPaneKey(s, code: code, modifiers: modifiers)
    default:
        return (s, [])
    }
}

// MARK: - Global key dispatch table

/// Keys that work in every pane (except when a modal is open).
///
/// Returns `nil` if the key is not a global key, so callers can fall through
/// to per-pane dispatch.
private func reduceGlobalKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect])? {
    var s = s

    // ux-spec §4.2: when project is malformed, only C-p / C-r / q / ? are active.
    // All other global keys are blocked with a transient message.
    if case .malformed = s.project {
        let allowed: [(KeyCode, KeyModifiers)] = [
            (.char("q"), []),
            (.char("?"), []),
            (.char("p"), .ctrl),
            (.char("r"), .ctrl),
        ]
        let isAllowed = allowed.contains { $0.0 == code && $0.1 == modifiers }
        if !isAllowed {
            // Return nil for unrecognised keys so they don't produce noise;
            // only produce a transient when the key would normally do something.
            let actionable: [(KeyCode, KeyModifiers)] = [
                (.char("r"), []), (.char("x"), []), (.char("l"), []),
                (.char("i"), []),
                (.tab, []), (.backTab, []),
                (.char("h"), .ctrl), (.char("l"), .ctrl), (.char("j"), .ctrl),
                (.char("<"), []), (.char(">"), []),
                (.char("{"), []), (.char("}"), []),
            ]
            if actionable.contains(where: { $0.0 == code && $0.1 == modifiers }) {
                s.transient = TransientMessage(text: "Project file error — fix the file first (C-p)")
                return (s, [armTickIfNeeded(s)].compactMap { $0 })
            }
            return nil
        }
    }

    switch (code, modifiers) {

    // r — run selected source
    case (.char("r"), []):
        return tryRun(s)

    // <C-g> — start (or restart-confirm) a debug run (ux-spec §7.2)
    case (.char("g"), .ctrl):
        return tryDebugRun(s)

    // x — stop debug session when one is active (F6.2 override); else cancel run.
    //
    // When a debug session is active `x` delivers `.stop` to the session (the
    // user ends debugging intentionally). This overrides the global cancel-run
    // binding so the same key works consistently in both debug and run contexts
    // (ux-spec §7.2, PRD F6.2). When no debug session is active `x` falls
    // through to the normal `.cancelRun` path.
    case (.char("x"), []):
        if let activeID = s.activeDebugSessionID {
            return reduceDebugStop(s, sessionID: activeID)
        }
        return (s, [.cancelRun])

    // l — lint selected source
    case (.char("l"), []):
        return tryLint(s)

    // q — quit
    case (.char("q"), []):
        return (s, [.cancelRun, .quit(exitCode: 0)])

    // ? — open help overlay (always from the top — ux-spec §2.5)
    case (.char("?"), []):
        s.focus = .helpOverlay
        s.helpScrollOffset = 0
        return (s, [])

    // <C-p> — open project file in $EDITOR
    case (.char("p"), .ctrl):
        if case .loaded(_, _) = s.project,
            case .project(let root) = s.launch
        {
            let url = root.appendingPathComponent("moonswift.toml")
            return (s, [.spawnEditor(url)])
        }
        s.transient = TransientMessage(text: "No project file to open")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    // <C-r> — reload project file
    case (.char("r"), .ctrl):
        return (s, [.reloadProject])

    // <Tab> — cycle focus (context-sensitive: bottom pane cycles its tabs)
    case (.tab, []):
        return reduceCycleFocus(s, forward: true)

    // <S-Tab> — reverse-cycle panes (always panes, not tabs)
    case (.backTab, []):
        return reduceCycleFocus(s, forward: false)

    // <C-h> — jump to navigator
    case (.char("h"), .ctrl):
        s.focus = .pane(.navigator)
        return (s, [])

    // <C-l> — jump to code pane; EXCEPT when the bottom pane is focused,
    // where <C-l> means "clear output buffer" (ux-spec §2.3 bottom-pane
    // table, §6.4). The pane table takes precedence there, so decline the
    // key and let per-pane dispatch handle it (Fixes #1).
    case (.char("l"), .ctrl):
        if case .pane(.bottomPane) = s.focus { return nil }
        s.focus = .pane(.codePane)
        return (s, [])

    // <C-j> — jump to bottom pane
    case (.char("j"), .ctrl):
        s.focus = .pane(.bottomPane)
        return (s, [])

    // < / > — narrow / widen navigator (ux-spec.md §1.3)
    // F5.6: each resize auto-saves the new ratio to [settings] (splitPersistEffects).
    case (.char("<"), []):
        s.paneLayout.navigatorWidth = max(
            PaneLayout.navigatorMin,
            s.paneLayout.navigatorWidth - 2
        )
        return (s, splitPersistEffects(s))

    case (.char(">"), []):
        s.paneLayout.navigatorWidth = min(
            PaneLayout.navigatorMax,
            s.paneLayout.navigatorWidth + 2
        )
        return (s, splitPersistEffects(s))

    // { / } — shrink / grow bottom pane (ux-spec.md §1.3)
    case (.char("{"), []):
        let current = s.paneLayout.bottomPaneHeight ?? PaneLayout.defaultBottomRows
        s.paneLayout.bottomPaneHeight = max(PaneLayout.bottomPaneMin, current - 1)
        return (s, splitPersistEffects(s))

    case (.char("}"), []):
        let current = s.paneLayout.bottomPaneHeight ?? PaneLayout.defaultBottomRows
        s.paneLayout.bottomPaneHeight = min(PaneLayout.bottomPaneMaxRatio, current + 1)
        return (s, splitPersistEffects(s))

    // i — open init form in empty state; transient no-op in quick-file mode.
    //
    // While a debug session is active, `i` is step-into (F6.2) and is routed
    // per focus by the pane handlers (code pane / Debug tab → stepInto;
    // navigator → "press 3" transient; VM running → "VM running…"). Defer to
    // pane routing in that case so the global init-form binding does not shadow
    // it — the same precedence the `x` stop override uses above.
    case (.char("i"), []):
        if s.activeDebugSessionID != nil {
            return nil
        }
        return reduceInitFormOpen(s)

    default:
        return nil
    }
}

// MARK: - Navigator key dispatch table

private func reduceNavigatorKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    // F6.2 navigator interception: while a debug session is paused, s/i/o/c
    // show a transient directing the user to the Debug tab (PRD §2566).
    // These keys have no navigator meaning, so interception does not shadow any
    // existing binding. The check is pre-switch so it takes priority.
    if s.activeDebugSessionID != nil, s.currentDebugSnapshot != nil {
        switch (code, modifiers) {
        case (.char("s"), []), (.char("i"), []), (.char("o"), []), (.char("c"), []):
            return reduceNavigatorDebugKeyTransient(s)
        default:
            break
        }
    }

    switch (code, modifiers) {

    case (.char("j"), []):
        return (reduceNavigatorMoveDown(s), [])

    case (.char("k"), []):
        return (reduceNavigatorMoveUp(s), [])

    case (.char("g"), []):
        // Jump to the first entry in the filtered list (returns to the source section).
        s.navigator.inMockSection = false
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: 0, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    case (.char("G"), []):
        // Jump to the last entry in the filtered list (returns to the source section).
        s.navigator.inMockSection = false
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: filtered.count - 1,
                filtered: filtered,
                order: s.navigatorOrder
            )
        }
        return (s, [])

    case (.enter, []), (.char("o"), []), (.char(" "), []):
        return selectNavigatorEntry(s)

    // F5.4 Mock Environment: `a` add (always, so the first mock can be created),
    // `e` edit / `d` delete (only on a selected mock in the section).
    case (.char("a"), []):
        guard case .loaded = s.project else { return (s, []) }
        return reduceMockAddForm(s)

    case (.char("e"), []):
        guard s.navigator.inMockSection else { return (s, []) }
        return reduceMockEditForm(s)

    case (.char("d"), []):
        guard s.navigator.inMockSection else { return (s, []) }
        return reduceMockDeleteRequest(s)

    case (.char("/"), []):
        // Activate inline filter mode with an empty query. Pressing / again
        // when filter is already active closes it (toggle, ux-spec §2.2).
        s.navigator.filterText = s.navigator.filterText == nil ? "" : nil
        return (s, [])

    case (.escape, []):
        // Esc clears the filter when active; otherwise it is a no-op.
        if s.navigator.filterText != nil {
            s.navigator.filterText = nil
        }
        return (s, [])

    case (.char("m"), []):
        // Open the structured-file picker for the selected entry.
        // Only meaningful for structured-file sources (SourceID has a jsonpath).
        return openPickerOrTransient(s)

    default:
        return (s, [])
    }
}

// MARK: - Navigator filter input handler

/// Handles keyboard input while the navigator inline filter is active.
///
/// All printable characters are appended to the filter query; `<Backspace>`
/// deletes the last character; `<Esc>` cancels and clears the filter; `<Enter>`
/// commits the filter (loads the current selection). Navigation keys (`j`/`k`/
/// `g`/`G`) are NOT intercepted here — typing any letter including 'j' and 'k'
/// appends to the query (ux-spec §2.2: typing chars feeds the query).
private func reduceNavigatorFilter(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.escape, []):
        // Clear the filter and return to normal navigator mode.
        s.navigator.filterText = nil
        return (s, [])

    case (.enter, []):
        // Commit: load the currently highlighted filtered entry.
        return selectNavigatorEntry(s)

    case (.backspace, []):
        // Delete the last character from the query.
        if var query = s.navigator.filterText, !query.isEmpty {
            query.removeLast()
            s.navigator.filterText = query
        }
        return (s, [])

    case (.char(let scalar), []) where !CharacterSet.controlCharacters.contains(scalar):
        // Append a printable character to the filter query (ux-spec §2.2: typing feeds
        // the query; navigation is via arrow keys or after Enter commit). This catch-all
        // intentionally matches every printable character including 'j', 'k', 'g', 'G'
        // so the user can search for entries whose names contain those letters.
        let ch = String(scalar)
        s.navigator.filterText = (s.navigator.filterText ?? "") + ch
        // Re-anchor selection to the first matching entry when the query grows.
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex =
                fullOrderIndex(filteredPos: 0, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    default:
        // All other keys (modifiers, function keys, etc.) are ignored in filter mode.
        return (s, [])
    }
}

// MARK: - Code pane key dispatch table

private func reduceCodePaneKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("j"), []):
        s.codePane.scrollOffset += 1
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("k"), []):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - 1)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("d"), []):
        s.codePane.scrollOffset += halfPageSize
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("u"), []):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - halfPageSize)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("f"), []):
        s.codePane.scrollOffset += fullPageSize
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    // b — toggle breakpoint on cursor line (UX-01 collision resolution: formerly
    // scroll-up-full-page; that binding moves to <C-b> per ux-spec §2.3 amendment).
    case (.char("b"), []):
        return reduceBreakpointToggle(s)

    // <C-b> — scroll up full page (replaces the retired plain `b` binding).
    case (.char("b"), .ctrl):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - fullPageSize)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("g"), []):
        s.codePane.scrollOffset = 0
        s.codePane.cursorLine = 0
        return (s, [])

    case (.char("G"), []):
        // Jump to bottom — renderer clamps; use a large sentinel value.
        s.codePane.scrollOffset = Int.max / 2
        s.codePane.cursorLine = Int.max / 2
        return (s, [])

    // : — begin colon command entry (ux-spec §2.3 ":N<Enter>" and ":q").
    case (.char(":"), []):
        s.codePane.colonCommand = ""
        return (s, [])

    case (.char("n"), []):
        return jumpToDiagnostic(s, direction: .next)

    case (.char("N"), []):
        return jumpToDiagnostic(s, direction: .previous)

    // [d — jump to first diagnostic
    case (.char("["), []):
        return jumpToDiagnostic(s, direction: .first)

    // ]d — jump to last diagnostic (mapped as ] because [ and ] are separate keys)
    case (.char("]"), []):
        return jumpToDiagnostic(s, direction: .last)

    // <C-e> — open current source in nvim (P4b, ux-spec §7.4).
    case (.char("e"), .ctrl):
        return reduceCodePaneSpawnNvim(s)

    // s/i/o/c — step over / into / out / continue (F6.2 paused-mode keys).
    // Active only while a debug session is paused (snapshot present); otherwise
    // a disabled transient (ux-spec §7.2, §6.9). The `x` stop key is handled
    // globally (see reduceGlobalKey) so it does not appear here.
    case (.char("s"), []):
        return reduceDebugStepKey(s, command: .stepOver)
    case (.char("i"), []):
        return reduceDebugStepKey(s, command: .stepInto)
    case (.char("o"), []):
        return reduceDebugStepKey(s, command: .stepOut)
    case (.char("c"), []):
        return reduceDebugStepKey(s, command: .continueRun)

    // <C-space> — open the completion popup (F7a.2, ux-spec §7.6).
    case (.char(" "), .ctrl):
        return reduceCodePaneOpenCompletion(s)

    // K — open the hover overlay for the symbol under the cursor (F7a.2).
    case (.char("K"), []):
        return reduceCodePaneOpenHover(s)

    default:
        return (s, [])
    }
}

// MARK: - Colon command handler (ux-spec §2.3 ":N<Enter>" jump)

/// Handles key input while the code pane `:` command is being entered.
///
/// Accepts digits (accumulated in `colonCommand`), `Enter` to execute the jump,
/// and `Esc` to cancel. The special sequence `:q` shows the "use q to quit"
/// transient per ux-spec §2.3 — it is the only recognised non-digit input.
/// Any other non-digit character cancels the command silently.
private func reduceColonCommand(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.escape, []):
        // Cancel without executing.
        s.codePane.colonCommand = nil
        return (s, [])

    case (.enter, []):
        // Execute: parse digits and jump, then clear the command buffer.
        let digits = s.codePane.colonCommand ?? ""
        s.codePane.colonCommand = nil
        if let lineNum = Int(digits), lineNum > 0 {
            // Jump to line lineNum (1-based → 0-based).
            let target = lineNum - 1
            s.codePane.cursorLine = target
            s.codePane.scrollOffset = target
        }
        return (s, [])

    case (.char(let scalar), []) where Character(scalar).isNumber:
        // Append a digit to the command buffer.
        s.codePane.colonCommand = (s.codePane.colonCommand ?? "") + String(scalar)
        return (s, [])

    case (.char("q"), []):
        // ":q" — show the "use q to quit" transient (ux-spec §2.3 exact string).
        s.codePane.colonCommand = nil
        s.transient = TransientMessage(text: "use q to quit")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    default:
        // Any other character cancels the command silently.
        s.codePane.colonCommand = nil
        return (s, [])
    }
}

// MARK: - Bottom pane key dispatch table

private func reduceBottomPaneKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("j"), []):
        // In the Debug tab while paused, j/k drive the row-selection cursor
        // (frames + expandable values, F6.3); elsewhere they scroll.
        if s.bottomPane.activeTab == .debug, s.currentDebugSnapshot != nil {
            return reduceDebugRowMove(s, delta: 1)
        }
        s.bottomPane.scrollOffset += 1
        return (s, [])

    case (.char("k"), []):
        if s.bottomPane.activeTab == .debug, s.currentDebugSnapshot != nil {
            return reduceDebugRowMove(s, delta: -1)
        }
        s.bottomPane.scrollOffset = max(0, s.bottomPane.scrollOffset - 1)
        return (s, [])

    case (.enter, []):
        // Debug tab while paused: select a frame / toggle inline expansion (F6.3).
        if s.bottomPane.activeTab == .debug, s.currentDebugSnapshot != nil {
            return reduceDebugTabEnter(s)
        }
        // Jump code pane to the error line of the focused diagnostic.
        return jumpCodePaneFromBottomPane(s)

    case (.char("y"), []):
        // Yank: copy the focused output/diagnostic line to the clipboard via pbcopy
        // (ux-spec §2.3 bottom-pane table). The Effect.yank request is executed by
        // the AppDriver, which is the only component that performs impure I/O.
        let text = yankFocusedLine(from: s)
        return (s, text.map { [.yank($0)] } ?? [])

    case (.char("1"), []):
        s.bottomPane.activeTab = .output
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.char("2"), []):
        s.bottomPane.activeTab = .diagnostics
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.char("3"), []):
        // Quick-jump to the Debug tab — but it exists only during a debug session
        // (UX-R2-N03). With no session, decline with the bound transient.
        guard s.activeDebugSessionID != nil else {
            s.transient = TransientMessage(text: "Debug tab not active.")
            return (s, [.startTick(interval: TickInterval.transientExpiry)])
        }
        s.bottomPane.activeTab = .debug
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.tab, []):
        // Cycle tabs within the bottom pane (context-sensitive Tab).
        // Debug tab is included when a debug session is active (ux-spec §6.2).
        switch s.bottomPane.activeTab {
        case .output:
            s.bottomPane.activeTab = .diagnostics
        case .diagnostics:
            if s.activeDebugSessionID != nil {
                s.bottomPane.activeTab = .debug
            } else {
                s.bottomPane.activeTab = .output
            }
        case .debug:
            s.bottomPane.activeTab = .output
        }
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.char("l"), .ctrl):
        // C-l clears the output buffer and inserts a [cleared] notice
        // at the top (ux-spec §6.4). Pane precedence rule #1: this case
        // is only reached when bottomPane is focused (the global C-l handler
        // declines the key when bottomPane is focused, per ux-spec §2.2).
        s.bottomPane.clearOutputWithNotice()
        return (s, [])

    // s/i/o/c — step over / into / out / continue while Debug tab active (F6.2).
    // Active only while the Debug tab is shown AND the session is paused. When the
    // VM is running (snapshot nil, session active) they produce a "VM running…"
    // disabled transient. Routing matches the code-pane paused-mode keys so the
    // user can step from either focused pane (ux-spec §7.2).
    case (.char("s"), []):
        guard s.bottomPane.activeTab == .debug else { return (s, []) }
        return reduceDebugStepKey(s, command: .stepOver)
    case (.char("i"), []):
        guard s.bottomPane.activeTab == .debug else { return (s, []) }
        return reduceDebugStepKey(s, command: .stepInto)
    case (.char("o"), []):
        guard s.bottomPane.activeTab == .debug else { return (s, []) }
        return reduceDebugStepKey(s, command: .stepOut)
    case (.char("c"), []):
        guard s.bottomPane.activeTab == .debug else { return (s, []) }
        return reduceDebugStepKey(s, command: .continueRun)

    // g — request the bounded/filtered globals slice while paused in the Debug
    // tab (F6.3). Scoped to the Debug tab; a no-op outside a paused session.
    case (.char("g"), []):
        guard s.bottomPane.activeTab == .debug else { return (s, []) }
        return reduceDebugGlobalsRequest(s)

    default:
        return (s, [])
    }
}

// MARK: - Picker key dispatch (ux-spec §3.6, §2.3 picker table)

/// Handles all keyboard input while the structured-file picker modal is open.
///
/// Key routing (ux-spec §2.3 picker table):
///   j / k          — move tree cursor down / up
///   Space/Right/l  — expand node
///   Left/h         — collapse node
///   Enter / m      — mark/unmark string field
///   s              — save all marks and close picker
///   Esc            — cancel with optional dirty confirmation
///   y              — confirm discard (when awaitingDiscardConfirmation)
///
/// When the picker has no tree yet (loading), only Esc is active. When a parse
/// error occurred, only Esc exits (ux-spec §3.6 error case).
private func reducePickerKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    // If picker state is nil (e.g. race between event delivery and state teardown),
    // absorb non-Esc keys so focus stays in pickerModal; Esc always exits.
    guard var picker = s.pickerState else {
        if case (.escape, []) = (code, modifiers) {
            s.focus = .pane(.navigator)
        }
        return (s, [])
    }

    // When awaiting discard confirmation, only y and any other key (→ N) matter.
    if picker.awaitingDiscardConfirmation {
        switch (code, modifiers) {
        case (.char("y"), []):
            // Discard confirmed — close without saving.
            s.pickerState = nil
            s.focus = .pane(.navigator)
            return (s, [])
        default:
            // Any other key returns to the picker (N or anything else).
            picker.awaitingDiscardConfirmation = false
            s.pickerState = picker
            return (s, [])
        }
    }

    // Parse error state: only Esc exits (ux-spec §3.6).
    if picker.parseError != nil {
        if case (.escape, []) = (code, modifiers) {
            s.pickerState = nil
            s.focus = .pane(.navigator)
        }
        return (s, [])
    }

    // Tree still loading: only Esc is active.
    guard var tree = picker.tree else {
        if case (.escape, []) = (code, modifiers) {
            s.pickerState = nil
            s.focus = .pane(.navigator)
        }
        return (s, [])
    }

    let rows = tree.visibleRows()

    switch (code, modifiers) {

    // j — cursor down
    case (.char("j"), []):
        if !rows.isEmpty {
            picker.cursorRow = min(picker.cursorRow + 1, rows.count - 1)
        }

    // k — cursor up
    case (.char("k"), []):
        picker.cursorRow = max(picker.cursorRow - 1, 0)

    // Space / Right / l — expand node
    case (.char(" "), []), (.right, []), (.char("l"), []):
        if rows.indices.contains(picker.cursorRow) {
            let row = rows[picker.cursorRow]
            if row.kind == .obj || row.kind == .arr {
                tree.expanded.insert(row.nodeID)
                picker.tree = tree
            }
        }

    // Left / h — collapse node
    case (.left, []), (.char("h"), []):
        if rows.indices.contains(picker.cursorRow) {
            let row = rows[picker.cursorRow]
            if row.kind == .obj || row.kind == .arr {
                tree.expanded.remove(row.nodeID)
                picker.tree = tree
                // Clamp cursor after collapse shrinks the visible list.
                let newRows = tree.visibleRows()
                picker.cursorRow = min(picker.cursorRow, max(0, newRows.count - 1))
            }
        }

    // Enter / m — mark or unmark a string field
    case (.enter, []), (.char("m"), []):
        if rows.indices.contains(picker.cursorRow) {
            let row = rows[picker.cursorRow]
            if row.kind == .str {
                if picker.marks.contains(row.normalized) {
                    picker.marks.remove(row.normalized)
                } else {
                    picker.marks.insert(row.normalized)
                }
            }
        }

    // s — save all marks to project file and close picker
    case (.char("s"), []):
        let designations = picker.marks.sorted().map { FieldDesignation(jsonpath: $0) }
        s.pickerState = picker
        // .designationsSaved handler closes picker and reloads sources.
        // Pass picker.filePath so applyDesignations can match the entry by path
        // (not by field overlap), which correctly handles the first-use case
        // where the entry has zero prior fields.
        return (s, [.saveDesignations(designations, sourcePath: picker.filePath)])

    // Esc — cancel with dirty-state confirmation prompt
    case (.escape, []):
        if picker.isDirty {
            picker.awaitingDiscardConfirmation = true
            s.pickerState = picker
        } else {
            s.pickerState = nil
            s.focus = .pane(.navigator)
        }
        return (s, [])

    default:
        break
    }

    s.pickerState = picker
    return (s, [])
}

/// Handles the .pickerTreeReady event: populates the PickerState tree on
/// success or records the parse error for the renderer to display.
private func reducePickerTreeReady(
    _ s: AppState,
    id: SourceID,
    tree: TreeValue?,
    errorMessage: String?
) -> (AppState, [Effect]) {
    var s = s
    // Only apply if the picker is still open for this SourceID.
    guard var picker = s.pickerState, picker.sourceID == id else {
        return (s, [])
    }

    if let error = errorMessage {
        picker.parseError = error
        picker.tree = nil
    } else if let treeValue = tree {
        picker.tree = PickerTree(root: treeValue)
        // Clamp cursor to the first visible row (safe: cursor starts at 0).
        let rowCount = picker.tree?.visibleRows().count ?? 0
        picker.cursorRow = min(picker.cursorRow, max(0, rowCount - 1))
    }

    s.pickerState = picker
    return (s, [])
}

// MARK: - Init form open handler (task 24)

/// Opens the project-initialisation form or shows a transient for quick-file mode.
///
/// - Empty state (`LaunchMode.empty`): open the form, fire a directory scan.
/// - Quick-file mode (`LaunchMode.quickFile`): show a transient; init form
///   is not available in quick-file mode (ux-spec §3.1 note).
/// - Project mode: no-op (project already exists).
private func reduceInitFormOpen(_ s: AppState) -> (AppState, [Effect])? {
    var s = s

    switch s.launch {
    case .empty:
        guard s.initFormState == nil else {
            // Already open — absorb key.
            return (s, [])
        }
        s.initFormState = InitFormState()
        s.focus = .initForm
        return (s, [.scanProjectDirectory(emptyCWD(for: s))])

    case .quickFile:
        // Quick-file mode: i is a no-op with a transient (task 24 scope note).
        s.transient = TransientMessage(text: "No project: i unavailable in quick-file mode")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    case .project:
        // Project already loaded — i has no meaning.
        return nil
    }
}

/// Returns the working-directory URL for the empty-state scan.
///
/// In empty state `s.launch == .empty` and we have no project root URL, so we
/// fall back to the process current directory (same as what Main resolved when
/// deciding the launch mode was empty).
private func emptyCWD(for s: AppState) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

// MARK: - Init form key handler (task 24, replaces stub)

/// Handles all keyboard input while the project-init form modal is open.
///
/// Key routing (ux-spec §3.1):
///   Tab / Enter (on luaVersion)  — advance to sourceFiles field
///   Tab (on sourceFiles)         — wrap back to luaVersion
///   j / k                        — move cursor in file list
///   Space / Enter (sourceFiles)  — toggle selection of current file
///   Enter (on sourceFiles, last) — confirm and write project file
///   Esc                          — cancel without writing
///
/// Fields (ux-spec §3.1):
///   Field 1 — Lua version: pre-filled "5.4", read-only in P1, Enter/Tab advances.
///   Field 2 — Source files: multi-select, Space/Enter to toggle, Enter confirms.
private func reduceInitFormKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    // If the form was closed (e.g. by a race), return focus to navigator.
    guard var form = s.initFormState else {
        s.focus = .pane(.navigator)
        return (s, [])
    }

    switch (code, modifiers) {

    // Esc — cancel without writing (ux-spec §3.1)
    case (.escape, []):
        s.initFormState = nil
        s.focus = .pane(.navigator)
        return (s, [])

    // Tab — cycle between fields
    case (.tab, []):
        switch form.focusedField {
        case .luaVersion:
            form.focusedField = .sourceFiles
        case .sourceFiles:
            form.focusedField = .luaVersion
        }
        s.initFormState = form
        return (s, [])

    // Enter — confirm current field or submit form
    case (.enter, []):
        switch form.focusedField {
        case .luaVersion:
            // Advance to the source files field.
            form.focusedField = .sourceFiles
            s.initFormState = form
            return (s, [])

        case .sourceFiles:
            // Confirm: write the project file with the current selections.
            return confirmInitForm(s, form: form)
        }

    // j — move cursor down in the file list (only on sourceFiles field)
    case (.char("j"), []):
        if form.focusedField == .sourceFiles, !form.candidateFiles.isEmpty {
            form.fileListCursor = min(form.fileListCursor + 1, form.candidateFiles.count - 1)
            s.initFormState = form
        }
        return (s, [])

    // k — move cursor up in the file list (only on sourceFiles field)
    case (.char("k"), []):
        if form.focusedField == .sourceFiles {
            form.fileListCursor = max(form.fileListCursor - 1, 0)
            s.initFormState = form
        }
        return (s, [])

    // Space — toggle selection of current file in the list
    case (.char(" "), []):
        if form.focusedField == .sourceFiles, form.candidateFiles.indices.contains(form.fileListCursor) {
            let file = form.candidateFiles[form.fileListCursor]
            if form.selectedFiles.contains(file) {
                form.selectedFiles.remove(file)
            } else {
                form.selectedFiles.insert(file)
            }
            s.initFormState = form
        }
        return (s, [])

    default:
        return (s, [])
    }
}

/// Confirm the init form: write moonswift.toml with chosen selections.
private func confirmInitForm(_ s: AppState, form: InitFormState) -> (AppState, [Effect]) {
    let sources = form.selectedFiles.sorted()
    let dir = emptyCWD(for: s)
    let effect = Effect.writeProjectFile(
        directory: dir,
        luaVersion: form.luaVersion,
        sources: sources
    )
    return (s, [effect])
}

/// Handles the `.projectFileWritten` event — transitions from empty to loaded state.
///
/// CR-020 guard: if `initFormState` is nil when this event arrives the form was
/// cancelled (Esc pressed) before the background write Task completed. Discard
/// the event silently — the written file on disk is harmless, but the app state
/// must not transition into project mode after a cancel.
private func reduceProjectFileWritten(
    _ s: AppState,
    projectURL: URL?,
    error: String?
) -> (AppState, [Effect]) {
    var s = s

    // Guard: if the init form was cancelled while the Task was in flight,
    // initFormState is nil. Discard the late event unconditionally.
    guard s.initFormState != nil else { return (s, []) }

    if let err = error {
        // Write failed: show transient, leave form open.
        s.transient = TransientMessage(text: "Error writing project file: \(err)")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    guard let url = projectURL else { return (s, []) }

    // Close the form.
    s.initFormState = nil
    s.focus = .pane(.navigator)

    // Transition launch mode to project with the directory.
    let dir = url.deletingLastPathComponent()
    s.launch = .project(dir)

    // Trigger a project reload to populate the navigator.
    return (s, [.loadProject(url.deletingLastPathComponent())])
}

// MARK: - Focus cycling

private func reduceCycleFocus(
    _ s: AppState,
    forward: Bool
) -> (AppState, [Effect]) {
    var s = s

    guard case .pane(let current) = s.focus else {
        // In a modal state, Tab has no focus-cycle effect.
        return (s, [])
    }

    // Context-sensitive Tab: when the bottom pane is focused, cycle its tabs.
    // Includes the Debug tab when a debug session is active (ux-spec §6.1, §6.2).
    if forward && current == .bottomPane {
        switch s.bottomPane.activeTab {
        case .output:
            s.bottomPane.activeTab = .diagnostics
        case .diagnostics:
            if s.activeDebugSessionID != nil {
                // Debug tab is present — cycle into it.
                s.bottomPane.activeTab = .debug
            } else {
                // No debug session: last tab, wrap back to navigator.
                s.focus = .pane(.navigator)
            }
        case .debug:
            // Last tab in debug mode — wrap back to navigator.
            s.focus = .pane(.navigator)
        }
        s.bottomPane.scrollOffset = 0
        return (s, [])
    }

    let order: [PaneID] = [.navigator, .codePane, .bottomPane]
    if let idx = order.firstIndex(of: current) {
        let next: Int
        if forward {
            next = (idx + 1) % order.count
        } else {
            next = (idx + order.count - 1) % order.count
        }
        s.focus = .pane(order[next])
    }
    return (s, [])
}

// MARK: - Run / Lint preconditions

private func tryRun(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    // Guard: a run must not be already in progress.
    if case .running = s.runState {
        s.transient = TransientMessage(text: "Run in progress")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Guard: a debug session must not be live (CR-001). Debug runs do NOT set
    // `runState`, so without this guard a plain `r` during a paused (or
    // launching) debug session starts a normal run whose `endSession` deadlocks
    // behind the VM thread parked in the mailbox. Stop the debugger first.
    if s.activeDebugSessionID != nil || s.debugLaunchPending {
        s.transient = TransientMessage(text: "Debug session active — press x to stop first.")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Guard: a source must be selected and loaded.
    guard let id = s.selection,
        case .loaded(let fragment) = s.sources[id]
    else {
        s.transient = TransientMessage(text: "No source loaded")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Guard: Lua version must be supported.
    if case .unsupportedVersion = s.project {
        s.transient = TransientMessage(
            text: "Run disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        )
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Start the run: record the start time and increment the run counter.
    let startTime = Date()
    s.runState = .running(id: UUID(), startedAt: startTime)
    s.bottomPane.activeTab = .output
    s.bottomPane.outputBuffer.removeAll()
    s.bottomPane.startRun(at: startTime)

    let runConfig: RunConfig
    if case .loaded(let file, _) = s.project {
        runConfig = file.run
    } else {
        runConfig = RunConfig()
    }

    let effects: [Effect] = [
        .run(fragment, runConfig),
        .startTick(interval: TickInterval.run),
    ]
    return (s, effects)
}

private func tryLint(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    guard case .idle = s.lintState else {
        let msg =
            s.lintState == .initializing
            ? "lint engine starting…"
            : "Lint engine not ready"
        s.transient = TransientMessage(text: msg)
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    guard let id = s.selection,
        case .loaded(let fragment) = s.sources[id]
    else {
        s.transient = TransientMessage(text: "No source loaded")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    if case .unsupportedVersion = s.project {
        s.transient = TransientMessage(
            text: "Lint disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        )
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    s.lintState = .running
    s.bottomPane.activeTab = .diagnostics
    let extraModules = extractExtraModules(from: s.project)
    // F7b: feed the same fragment to lua-language-server (no-op when absent), so
    // a LuaLS pass accompanies each luacheck pass.
    return (s, [.lint(fragment, extraModules: extraModules), .lualsSync(fragment)])
}

// MARK: - Helpers

/// Compute the minimal tick interval across all currently active consumers.
/// Returns nil if no consumer needs ticks.
private func armTickIfNeeded(_ s: AppState) -> Effect? {
    var minimum: Duration? = nil

    // Run-coalescer tick (100 ms) while a run is active.
    if case .running = s.runState {
        minimum = TickInterval.run
    }

    // Spinner tick (100 ms) while any source is loading (ux-spec §4.1).
    // The same interval as the run tick so there is no extra overhead when both
    // are active simultaneously — `startTick` always replaces the previous timer.
    let anyLoading = s.sources.values.contains {
        if case .loading = $0 { return true }
        return false
    }
    if anyLoading {
        let candidate = TickInterval.run
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    // Transient expiry (1.5 s) while an *expiring* transient message is showing.
    // A persistent message (expiry == nil) needs no tick — it is cleared by a
    // reducer, not by deadline — so it must not spin the timer forever.
    if let t = s.transient, t.expiry != nil {
        let candidate = TickInterval.transientExpiry
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    // Highlight pulse (500 ms) while a jump-target pulse is animating (ux-spec §3.5).
    // One tick fires after 500 ms; the tick handler clears `jumpPulseLine`.
    if s.codePane.jumpPulseLine != nil {
        let candidate = TickInterval.highlightPulse
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    // Nvim resize debounce (50 ms) while a pending resize is queued (Inc-8).
    if s.nvimPendingResize != nil {
        let candidate = TickInterval.nvimResize
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    guard let interval = minimum else { return nil }
    return .startTick(interval: interval)
}

/// Compute tick effects to emit after a run finishes.
private func tickEffectsAfterRunEnds(_ s: AppState) -> [Effect] {
    if let tick = armTickIfNeeded(s) {
        return [tick]
    }
    return [.stopTick]
}

/// Recompute the merged diagnostics display list and gutter marks from the three
/// independent sources MoonSwift maintains: the syntax pre-pass (0 or 1), the
/// luacheck batch, and the LuaLS batch (F7b). Every reducer arm that mutates one
/// source calls this so the merge stays uniform — no arm reconstructs the list
/// from a partial set, which previously dropped luacheck on a syntax error and
/// dropped the pre-pass on a lint pass. Order (pre-pass → luacheck → LuaLS)
/// matches the Diagnostics-tab reading order.
func remergeDiagnostics(_ s: inout AppState) {
    var merged: [Diagnostic] = []
    if let pre = s.bottomPane.prePassDiagnostic { merged.append(pre) }
    merged.append(contentsOf: s.bottomPane.luacheckDiagnostics)
    merged.append(contentsOf: s.bottomPane.lualsDiagnostics)
    s.bottomPane.diagnostics = merged
    s.codePane.gutterMarks = gutterMarks(from: merged)
}

/// Build gutter marks from a diagnostic array.
///
/// Module-internal (CR-042) so `DebugReducer` recomputes the merged mark set
/// through this one definition rather than a duplicate.
func gutterMarks(from diagnostics: [Diagnostic]) -> [Int: GutterMark] {
    var marks: [Int: GutterMark] = [:]
    for d in diagnostics {
        let line = max(0, d.line - 1)  // convert 1-based to 0-based
        switch d.severity {
        case .error:
            marks[line] = .error
        case .warning:
            if marks[line] == nil {
                marks[line] = .warning
            }
        }
    }
    return marks
}

/// Extract the extraModules list from the current project state.
private func extractExtraModules(from project: ProjectState) -> [String] {
    if case .loaded(let file, _) = project {
        return file.lint.extraModules
    }
    return []
}

/// Select the currently highlighted navigator entry and load it into the code pane.
///
/// Resets the full `CodePaneState` so scroll, cursor, colon command, and
/// diagnostic index all start fresh for the newly selected source.
private func selectNavigatorEntry(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    // F5.4/F5.3: in the Mock Environment section, Enter does not load a source.
    // On a live function row it opens the F5.3 invoke form (ux-spec §7.5); on a
    // declared mock row it is a no-op (add/edit/delete are the `a`/`e`/`d` keys).
    if s.navigator.inMockSection {
        return reduceOpenInvokeForm(s)
    }
    guard s.navigator.selectedIndex < s.navigatorOrder.count else {
        return (s, [])
    }
    let id = s.navigatorOrder[s.navigator.selectedIndex]
    s.selection = id
    // Full reset: scroll offset, cursor line, colonCommand, diagnosticIndex.
    s.codePane = CodePaneState()

    var effects: [Effect] = []
    // Schedule highlight if the source is loaded and has no spans yet.
    if case .loaded = s.sources[id], s.highlight[id] == nil {
        effects.append(.highlight(id))
    }
    // Run syntax pre-pass on selection.
    if case .loaded(let fragment) = s.sources[id] {
        effects.append(.syntaxPrePass(fragment))
    }
    return (s, effects)
}

// MARK: - Navigator filter helpers

/// Returns the filtered source IDs using the navigator's current filter text.
///
/// Delegates to `filteredNavigatorIDs` in Renderer.swift (the same logic drives
/// both the display list and navigation so the two stay in sync).
func filteredIDs(from s: AppState) -> [SourceID] {
    filteredNavigatorIDs(order: s.navigatorOrder, filterText: s.navigator.filterText)
}

/// Returns the position of the selected entry within the filtered list, or nil
/// if the currently selected source ID is not present in `filtered`.
func filteredPosition(
    selectedIndex: Int,
    filtered: [SourceID],
    order: [SourceID]
) -> Int? {
    guard order.indices.contains(selectedIndex) else { return nil }
    let id = order[selectedIndex]
    return filtered.firstIndex(of: id)
}

/// Maps a position in the filtered list back to an index in the full `order` array.
///
/// Returns the last valid index as a fallback so `selectedIndex` never goes out of range.
func fullOrderIndex(filteredPos: Int, filtered: [SourceID], order: [SourceID]) -> Int {
    guard filtered.indices.contains(filteredPos) else { return max(0, order.count - 1) }
    let id = filtered[filteredPos]
    return order.firstIndex(of: id) ?? max(0, order.count - 1)
}

/// Opens the structured-file picker for the selected navigator entry, or shows
/// a 1.5 s transient when the entry is not a structured file (ux-spec §3.6).
///
/// Structured files are `.json`, `.yaml`, `.yml`, and `.toml` entries — either
/// whole-file entries (jsonpath == nil) or individual field entries (jsonpath
/// != nil). In both cases the picker browses the entire file; pre-existing
/// designations are pre-filled from the project state.
///
/// The picker requires the project root URL to load the file; if the app is
/// not in project mode (LaunchMode.project), the picker is unavailable.
private func openPickerOrTransient(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    guard s.navigator.selectedIndex < s.navigatorOrder.count else {
        return (s, [])
    }
    let id = s.navigatorOrder[s.navigator.selectedIndex]
    let ext = (id.path as NSString).pathExtension.lowercased()
    let isStructured = ext == "json" || ext == "yaml" || ext == "yml" || ext == "toml"

    guard isStructured else {
        // Whole .lua file or unknown extension — picker is not applicable.
        s.transient = TransientMessage(text: "Picker available for structured files only")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    guard case .project(let root) = s.launch else {
        s.transient = TransientMessage(text: "Picker requires a project")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Collect pre-existing designations for this file so the picker can
    // pre-fill marks and detect dirtiness on close.
    let preExisting = existingDesignations(for: id.path, project: s.project)

    // Seed picker state — tree is nil until .pickerTreeReady arrives.
    s.pickerState = PickerState(
        sourceID: id,
        filePath: id.path,
        tree: nil,
        parseError: nil,
        cursorRow: 0,
        marks: preExisting,
        preExistingMarks: preExisting,
        awaitingDiscardConfirmation: false
    )
    s.focus = .pickerModal

    return (s, [.loadPickerTree(id, projectRoot: root)])
}

/// Returns the set of normalized JSONPath strings already designated for `filePath`
/// in the current project state.
private func existingDesignations(for filePath: String, project: ProjectState) -> Set<String> {
    guard case .loaded(let file, _) = project else { return [] }
    var paths: Set<String> = []
    for entry in file.sources where entry.path == filePath {
        for field in entry.fields {
            paths.insert(field.jsonpath)
        }
    }
    return paths
}

// MARK: - Diagnostic navigation

private enum DiagnosticDirection { case next, previous, first, last }

/// Jumps the code pane cursor to a diagnostic using the `diagnosticIndex` counter.
///
/// Navigation is wrap-around: `n` past the last diagnostic wraps to the first;
/// `N` before the first wraps to the last (ux-spec §2.3). `diagnosticIndex` is
/// maintained across `n`/`N` calls and reset whenever the active source changes.
private func jumpToDiagnostic(
    _ s: AppState,
    direction: DiagnosticDirection
) -> (AppState, [Effect]) {
    var s = s
    let diags = s.bottomPane.diagnostics
    guard !diags.isEmpty else { return (s, []) }

    let count = diags.count
    let newIndex: Int
    switch direction {
    case .first:
        newIndex = 0
    case .last:
        newIndex = count - 1
    case .next:
        // Wrap-around: advance from current index or start from 0 on first call.
        let current = s.codePane.diagnosticIndex ?? -1
        newIndex = (current + 1) % count
    case .previous:
        // Wrap-around: step back, wrapping to last when at index 0 or unset.
        let current = s.codePane.diagnosticIndex ?? 0
        newIndex = (current - 1 + count) % count
    }

    s.codePane.diagnosticIndex = newIndex
    let targetLine = diags[newIndex].line
    let targetIdx = max(0, targetLine - 1)
    s.codePane.cursorLine = targetIdx
    // Center the target line in the visible area when possible (ux-spec §3.5,
    // task 31). `halfPageSize` approximates half the code-pane height; the
    // renderer clips any over-scroll to the last line automatically.
    s.codePane.scrollOffset = max(0, targetIdx - halfPageSize)
    return (s, [])
}

/// Number of synthetic header rows prepended before lint diagnostics in the
/// diagnostics tab (ux-spec §6.5): "── Syntax ──", prepass result, "── Lint ──".
/// scrollOffset must be adjusted by this amount to obtain a `diagnostics[]` index.
private let diagTabHeaderRows = 3

private func jumpCodePaneFromBottomPane(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    let diags = s.bottomPane.diagnostics
    guard !diags.isEmpty else { return (s, []) }

    // CR-017: diagnostics tab renders 3 synthetic header rows before the first
    // lint diagnostic (── Syntax ──, prepass result, ── Lint ──). Subtract them
    // so scrollOffset maps to the correct diagnostics[] index.
    let rawOffset = s.bottomPane.scrollOffset
    let diagIdx: Int
    switch s.bottomPane.activeTab {
    case .diagnostics:
        let adjusted = rawOffset - diagTabHeaderRows
        guard adjusted >= 0 else { return (s, []) }
        diagIdx = min(adjusted, diags.count - 1)
    case .output:
        diagIdx = min(rawOffset, diags.count - 1)
    case .debug:
        // Debug tab Enter: jump code pane to the paused debug line if available.
        guard let snapshot = s.currentDebugSnapshot else { return (s, []) }
        let targetLine = max(0, snapshot.fragmentLine - 1)
        s.codePane.cursorLine = targetLine
        s.codePane.scrollOffset = max(0, targetLine - halfPageSize)
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    let line = diags[diagIdx].line
    let targetLine = max(0, line - 1)
    s.codePane.cursorLine = targetLine
    // Center the target in view where possible (task 31 jump behavior;
    // half-page matches the d/u scroll step).
    s.codePane.scrollOffset = max(0, targetLine - 10)
    // Start the 500 ms highlight pulse (ux-spec §3.5). The expiry deadline —
    // not the next tick — ends the animation, because a faster tick consumer
    // (100 ms run tick) may fire well before 500 ms.
    s.codePane.jumpPulseLine = targetLine
    s.codePane.jumpPulseExpiry = Date().addingTimeInterval(0.5)
    return (s, [armTickIfNeeded(s)].compactMap { $0 })
}

/// Returns the text of the line currently focused in the bottom pane, if any.
///
/// The scroll offset is a visual row index. For the output tab a synthetic run
/// header row (when `runNumber > 0`) is prepended at row 0, so the buffer index
/// is `offset - 1` when a header is shown. For the diagnostics tab the three
/// synthetic header rows (── Syntax ──, prepass result, ── Lint ──) precede the
/// lint diagnostics, so the buffer index is `offset - diagTabHeaderRows`.
///
/// Returns `nil` when the offset falls on a synthetic row or out of range.
private func yankFocusedLine(from s: AppState) -> String? {
    let offset = s.bottomPane.scrollOffset
    switch s.bottomPane.activeTab {
    case .output:
        // CR-017: when a run has been started the renderer prepends a phantom
        // run-header row at visual row 0. Adjust the buffer index accordingly.
        let hasHeader = s.bottomPane.runNumber > 0
        let bufferIdx = hasHeader ? offset - 1 : offset
        guard bufferIdx >= 0, s.bottomPane.outputBuffer.indices.contains(bufferIdx) else {
            return nil
        }
        return s.bottomPane.outputBuffer[bufferIdx]
    case .diagnostics:
        // Adjust for the 3 synthetic header rows in the diagnostics tab.
        let diagIdx = offset - diagTabHeaderRows
        guard diagIdx >= 0, s.bottomPane.diagnostics.indices.contains(diagIdx) else {
            return nil
        }
        let d = s.bottomPane.diagnostics[diagIdx]
        let prefix = d.severity == .error ? "E" : "W"
        let colStr = d.column.map { ":\($0)" } ?? ""
        let codeStr = d.code.map { " [\($0)]" } ?? ""
        return "\(prefix) \(d.line)\(colStr) \(d.message)\(codeStr)"
    case .debug:
        // Debug tab yank: no structured data to copy in F6.1; no-op.
        return nil
    }
}

// MARK: - Scroll constants

/// Half-page scroll size (approximate; renderer clips to content bounds).
private let halfPageSize = 10

/// Full-page scroll size (approximate; renderer clips to content bounds).
private let fullPageSize = 20
