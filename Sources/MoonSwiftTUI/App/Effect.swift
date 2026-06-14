// File: Sources/MoonSwiftTUI/App/Effect.swift
// Location: MoonSwiftTUI/App/
// Role: Enumerates every impure action the reducer may request. Effects are
//       the sole exit from purity: the reducer returns them; the AppDriver
//       executes them. Nothing impure happens inside reduce() or render().
//       Signatures match ARCHITECTURE.md §5.1 exactly.
// Upstream: MoonSwiftCore (LuaSourceFragment, SourceID, RunConfig), AppEvent,
//           RatatuiKit (Rect, TerminalSize — nvim effects)
// Downstream: AppDriver (executes), Reducer (returns), TickSource (driven by
//             startTick/stopTick)

import CryptoKit
import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit

// MARK: - Effect

/// An impure action the reducer requests — executed by the AppDriver, never
/// by the reducer or renderer themselves (ARCHITECTURE.md §5.1).
///
/// Effects model the boundary between the pure Elm core and the outside world.
/// Every service call, tick arm/disarm, and the quit signal is an `Effect`.
/// The AppDriver reads the `[Effect]` array returned by `reduce(_:_:)` and
/// dispatches each entry to the appropriate service or built-in handler.
public enum Effect: Sendable {

    // MARK: Run

    /// Start a script run. The AppDriver dispatches to RunService with the
    /// AppDriver-constructed output and finish callbacks (ARCH §5.1 §3c).
    case run(LuaSourceFragment, RunConfig)

    /// Cancel the in-progress run. No-op if no run is active.
    case cancelRun

    // MARK: Lint

    /// Run the syntax pre-pass (`precompile`, result discarded).
    case syntaxPrePass(LuaSourceFragment)

    /// Run the full luacheck pass. `extraModules` are pre-validated names
    /// from the catalog's `.optIn` allow-list (ARCHITECTURE.md §7.3).
    case lint(LuaSourceFragment, extraModules: [String])

    /// Initialise the lint engine off the main thread right after the first
    /// frame. Also carries the one-shot luaswift.toml catalog probe, which
    /// posts `.catalogProbed(tomlAvailable:)` (ARCH §3d, §5.4).
    case prewarmLint

    // MARK: Highlighting

    /// Schedule a tree-sitter parse for the given source off the UI thread.
    /// The result posts `.highlightReady(SourceID, spans:)` via the channel.
    case highlight(SourceID)

    // MARK: Project and sources

    /// Load (or reload from scratch) the project file at the given URL.
    case loadProject(URL)

    /// Reload the current project file from disk (e.g. after `<C-r>`).
    case reloadProject

    /// Load all sources declared in the current project file. This effect is
    /// returned by the `.appStarted` handler; sources load asynchronously
    /// and each posts `.sourceLoaded` or `.sourceFailed` (ARCH §3a).
    case loadSources

    /// Load or reload a single source identified by its `SourceID`.
    case loadSource(SourceID)

    /// Persist updated field designations to `moonswift.toml` and post
    /// `.designationsSaved` when complete.
    ///
    /// `sourcePath` identifies which `SourceEntry` in the project file should
    /// receive the designations — it is the project-relative path of the file
    /// the picker was browsing. Passing the path here avoids relying on field
    /// overlap matching (which silently no-ops when the entry has no prior
    /// fields — the common first-use case).
    case saveDesignations([FieldDesignation], sourcePath: String)

    /// Parse the structured file for the given `SourceID` into a `TreeValue`
    /// tree and post `.pickerTreeReady` when complete. Used by the picker modal
    /// to load the tree the user wants to browse (ux-spec §3.6).
    ///
    /// The file path is derived from `SourceID.path` (project-relative). The
    /// project root URL is passed along so the AppDriver can resolve it.
    case loadPickerTree(SourceID, projectRoot: URL)

    // MARK: Editor

    /// Suspend the pump, leave the alternate screen, spawn `$EDITOR` on the
    /// given file, wait for the editor to exit, then resume (ARCH §5.2 pump-
    /// park handshake). Posts `.sourceLoaded` / `.sourceFailed` after return
    /// if the edited file changed.
    case spawnEditor(URL)

    /// Suspend the pump, leave the alternate screen, spawn `$EDITOR` on a temp
    /// file containing the fragment text (structured files) or on the file
    /// directly (whole `.lua` files), then run the syntax loop and write-back.
    ///
    /// This is the `$EDITOR` fallback path for the nvim-embed feature (F8b):
    /// emitted by the reducer on `AppEvent.nvimUnavailable` when nvim is absent
    /// or too old (ARCHITECTURE.md §10.8 Inc-10, ux-spec §7.3).
    ///
    /// AppDriver executes the full sequence synchronously on the UI thread:
    ///   1. Write temp file (structured) or use existing file URL (whole `.lua`).
    ///   2. Pump-park + terminal suspend + `$EDITOR` spawn + resume.
    ///   3. Read edited bytes.
    ///   4. Syntax pre-pass; if error inject comment block and repeat from 2.
    ///   5. On clean: `await WriteBackCoordinator.write(…lintService:…)`.
    ///   6. Post `.writeBackSucceeded` / `.writeBackFailed` / `.conflictDetected`.
    ///
    /// The existing `case spawnEditor(URL)` is retained unchanged for the
    /// `<C-p>` project-file path. This case is the nvim-fallback edit path.
    case spawnEditorFallback(LuaSourceFragment)

    // MARK: Nvim editing (P4 F8b, ARCHITECTURE.md §10.4.1)

    /// Spawn `nvim --embed --clean` for the given fragment, sized to codePaneRect.
    ///
    /// AppDriver executes this by launching EditorBridge.spawn in a background Task.
    /// The Task posts either `.nvimUnavailable` (probe failure) or `.nvimReady`
    /// (successful handshake) via the EventChannel.
    case spawnNvim(LuaSourceFragment, codePaneRect: Rect)

    /// Forward a key-notation string to the running nvim instance via
    /// `nvim_input`. No-op if no session is active (session already nil-guarded
    /// by AppDriver before the Task fires).
    case nvimInput(String)

    /// Detach from the running nvim instance cleanly via `nvim_command "qa!"`.
    ///
    /// AppDriver posts `.nvimDetached` after the notify completes. The reducer
    /// emits `.nvimCleanup` on `.nvimDetached` (Inc-8).
    case nvimDetach

    /// Resize the running nvim UI (fire-and-forget `nvim_ui_try_resize`).
    ///
    /// Debouncing (~50 ms) is applied by AppDriver to avoid flooding nvim during
    /// rapid terminal-resize events. Wired in Inc-8.
    case nvimResize(TerminalSize)

    /// Tear down the active nvim session: stop the reader thread, wait for nvim
    /// to exit, close the pipes, and nil `AppDriver.nvimSession`.
    ///
    /// Emitted by the reducer on both `.nvimProcessExited` AND `.nvimDetached`
    /// (Inc-8 wiring). AppDriver executes it synchronously at the start of the
    /// effect (nil session before async teardown) to prevent in-flight nvimInput
    /// tasks from writing to a closing FileHandle.
    case nvimCleanup

    // MARK: Write-back (Inc-9, ARCHITECTURE.md §10.4.1, §10.3c)

    /// Execute the full write-back pipeline for `fragment`.
    ///
    /// When `editedText` is empty and a live nvim session exists, AppDriver
    /// fetches the buffer content via `nvim_buf_get_lines(0, 0, -1, false)`
    /// before calling `WriteBackCoordinator.write`. When `editedText` is
    /// non-empty (conflict-overwrite path from `ConflictModalState`), it is
    /// passed directly. `force: true` skips the conflict check.
    ///
    /// On completion AppDriver posts one of:
    ///   `.writeBackSucceeded`, `.writeBackFailed`, `.writeBackBlocked`,
    ///   or `.conflictDetected` (ARCHITECTURE.md §10.3c).
    case writeBack(LuaSourceFragment, editedText: String, force: Bool)

    /// Build a `DiffViewState` off the UI thread and post `.diffViewReady`.
    ///
    /// AppDriver launches a background Task that re-reads `fileURL`, re-locates
    /// the span via `SpanLocator`, constructs `DiffViewState`, and posts
    /// `AppEvent.diffViewReady(state)` on completion. The reducer transitions
    /// focus to `.diffView(.building)` before emitting this effect so the renderer
    /// can show a spinner during the build (ARCHITECTURE.md §10.4.10, §10.3d).
    case buildDiffView(
        fileURL: URL,
        expectedHash: SHA256Digest,
        editedText: String,
        fragment: LuaSourceFragment
    )

    // MARK: Tick source

    /// Arm (or replace) the tick source with the given interval.
    ///
    /// The reducer computes **one** interval — the minimum across all currently
    /// active consumers: run-coalescer tick (100 ms), highlight pulse (500 ms),
    /// transient expiry (1.5 s). `.startTick` **always replaces** the previous
    /// interval; the AppDriver disarms the old timer and arms a new one at the
    /// requested interval (ARCHITECTURE.md §3b, §5.1).
    case startTick(interval: Duration)

    /// Disarm the tick source. Posted when no consumer needs timer-driven
    /// updates (ARCHITECTURE.md §3b): no active run, no active transient,
    /// no pending highlight pulse.
    case stopTick

    // MARK: Clipboard

    /// Copy `text` to the system clipboard via pbcopy (ux-spec §2.3 bottom-pane `y`).
    ///
    /// The AppDriver executes this by spawning `pbcopy` and writing `text` to its
    /// stdin. The reducer requests the effect; the driver executes it. This is a
    /// purely additive case: no other driver logic is modified.
    ///
    /// **Scope note (task 21):** The driver execution arm (`case .yank`) is wired
    /// in AppDriver.executeSingle because it is a trivial additive single case with
    /// no conflict risk. If AppDriver is out-of-scope for a future task, add the arm
    /// at the call site in that task's pass.
    case yank(String)

    // MARK: Init form

    /// Scan `directory` for candidate source files (.lua/.json/.yaml/.toml) and
    /// post `.projectDirectoryScanned` with the resulting paths when complete.
    ///
    /// Used by the init form to populate the source-file multi-select list.
    /// The scan runs on a background Task to avoid blocking the UI thread.
    case scanProjectDirectory(URL)

    /// Write a minimal `moonswift.toml` containing `luaVersion` and `sources`
    /// to `directory`, then post `.projectFileWritten` (success or failure).
    ///
    /// Transitions the app from empty state to the loaded project state.
    case writeProjectFile(directory: URL, luaVersion: String, sources: [String])

    // MARK: Debug (P2 F6.1, ARCHITECTURE.md §10.9)

    /// Start a debug run for `fragment` with the given breakpoint lines.
    ///
    /// `breakpoints` are fragment-relative 1-based line numbers (already
    /// translated from the fragment-relative cursor line held in `AppState`).
    /// AppDriver launches `SessionEngineProtocol.runForDebug` inside a background
    /// Task; the `onPause` callback posts `AppEvent.debugPaused`; after the run
    /// completes AppDriver posts `AppEvent.debugFinished`.
    case debugRun(LuaSourceFragment, breakpoints: Set<Int>)

    /// Tear down any active debug session and stop the debug run.
    ///
    /// AppDriver calls `SessionEngineProtocol.sendDebugCommand(.stop)` on the
    /// session addressed by `id`. A stale id is a silent no-op (ARCH-06).
    case stopDebug(DebugSessionID)

    /// Deliver a stepping or continue command to a live debug session.
    ///
    /// AppDriver calls `SessionEngineProtocol.sendDebugCommand(id, command)`
    /// nonisolated (PERF-11 — the serial executor is occupied by the parked
    /// `runForDebug` block during a pause, so async dispatch would deadlock).
    /// Stale id → silent no-op (ARCH-06). Used by F6.2 for `.stepOver`,
    /// `.stepInto`, `.stepOut`, `.continueRun`, and `.stop` from the paused
    /// stepping UI (distinct from `.stopDebug` which was F6.1's teardown-only path).
    case sendDebugCommand(DebugSessionID, LuaDebugCommand)

    /// Invoke a Lua function via a FULL call expression (F5.3, RQ2).
    ///
    /// Carries the RAW typed call expression (e.g. `on_event("tick", 42)`); the
    /// reducer NEVER runs the controls (ARCH-R7-01 — they are side-effectful). The
    /// AppDriver runs the three ordered controls (`AppDriver+InvokeEffects`):
    ///   1. lint gate — `LintServiceProtocol.syntaxPrePass("return <expr>")`; a
    ///      syntax error posts `.luaInvocationLintFailed(detail)`, stops.
    ///   2. target no-dots check — `extractCallTarget(expr)`; a dotted/indexed/
    ///      method target posts `.luaInvocationTargetInvalid`, stops.
    ///   3. evaluate — `SessionEngineProtocol.invokeLuaCall(expr)`; success posts
    ///      `.luaInvocationResult(display)`, a not-a-function / no-session failure
    ///      posts a `.transient`, any other runtime error posts
    ///      `.luaInvocationFailed(message)`.
    case invokeLuaCall(String)

    /// Persist the mock definitions to `[[mock.*]]` in moonswift.toml after an
    /// add/edit/delete (F5.4). AppDriver decode-modifies-encodes the project file
    /// (preserving all other keys) with the new `MockStore` and writes it back;
    /// fire-and-forget on success, logged on failure. No-op without a loaded project.
    case saveMockStore(MockStore)

    /// Persist the navigator/bottom split ratios to `[settings]` in moonswift.toml
    /// after a TUI resize (F5.6). AppDriver decode-modifies-encodes the project
    /// file (preserving all other keys) and writes it back; fire-and-forget on
    /// success, logged on failure. No-op when no project file is loaded.
    case persistSplitRatios(navigatorSplit: Double, bottomSplit: Double)

    /// Request the bounded/filtered user-globals slice for a paused session (F6.3 `g`).
    ///
    /// AppDriver calls `SessionEngineProtocol.requestGlobals(id)` nonisolated
    /// (PERF-11 — the serial executor is parked in `runForDebug` during a pause,
    /// so an async hop would deadlock). The session's mailbox latches the request
    /// and the two-predicate wake services it IN-PLACE at the current pause line
    /// (no VM advance, DOM-08); the adapter republishes a snapshot with `globals`
    /// populated, arriving back as a fresh `AppEvent.debugPaused`. A stale id is a
    /// silent no-op (ARCH-06).
    case requestGlobals(DebugSessionID)

    // MARK: Completions & hover (P3 F7a.2, ARCHITECTURE.md §4.7)

    /// Query completion items for `prefix` and post `.completionsReady`.
    ///
    /// AppDriver calls `LuaModuleCatalog.v0.completionItems(prefix:liveMocks:
    /// tomlProbed:)` on a background Task and posts the result. `liveMocks` is
    /// snapshotted from the cached `AppState.mockLiveState` at reducer time
    /// (PERF-03 — never a fresh per-keystroke introspection); `tomlProbed` is
    /// the `AppState.tomlModuleAvailable` probe result. The catalog returns `[]`
    /// for any prefix other than `luaswift.` / `luaswift.X.`, so an off-prefix
    /// `<C-space>` is a harmless empty query.
    case queryCompletions(prefix: String, liveMocks: [CompletionItem], tomlProbed: Bool)

    /// Resolve the catalog/live-mock entry for `symbolName` and post
    /// `.hoverReady(CompletionItem?)` (F7a.2).
    ///
    /// AppDriver resolves a dotted symbol (`luaswift.stringx.split`) to its
    /// module-level item, or a bare name to a live-mock item, on a background
    /// Task. Posts `.hoverReady(nil)` when nothing matches — the reducer opens
    /// the overlay regardless (UX-R3-01). `liveMocks`/`tomlProbed` are
    /// snapshotted at reducer time, as for `.queryCompletions`.
    case queryHover(symbolName: String, liveMocks: [CompletionItem], tomlProbed: Bool)

    // MARK: Process lifecycle

    /// Break the AppDriver loop, run teardown, and `exit(exitCode)`.
    /// The exit code is passed through to `Foundation.exit(_:)` after the
    /// terminal is restored (ARCHITECTURE.md §3f, §5.1). Common values:
    ///   0 — normal quit (q)
    ///  70 — internal error (EX_SOFTWARE)
    case quit(exitCode: Int32)
}

// MARK: - Tick interval constants

/// Canonical tick intervals used by the reducer when computing the minimum
/// interval across active consumers (ARCHITECTURE.md §3b).
public enum TickInterval {
    /// Fastest interval: armed while `runState == .running` to bound
    /// coalescer flush latency to ≤ ~116 ms (100 ms tick + 16 ms gate).
    public static let run: Duration = .milliseconds(100)

    /// Medium interval: armed while a highlight pulse is animating (500 ms).
    public static let highlightPulse: Duration = .milliseconds(500)

    /// Slowest interval: armed while a transient status-bar message is visible;
    /// the reducer cancels the transient after 1.5 s (ARCHITECTURE.md §3b).
    public static let transientExpiry: Duration = .milliseconds(1_500)

    /// Debug-session UI poll interval — armed while a debug session is active (or
    /// launching) to keep the loop ticking for elapsed-time / state updates
    /// between pauses (CR-041). A dedicated constant rather than reusing
    /// `transientExpiry`: the two are semantically unrelated (one bounds a
    /// status-message lifetime, this paces debug-UI refresh), so retuning one must
    /// not silently move the other. They currently share the 1.5 s value.
    public static let debugPoll: Duration = .milliseconds(1_500)

    /// Debounce window for nvim resize events (Inc-8, ARCHITECTURE.md §10.8).
    ///
    /// When a terminal resize arrives while the nvim pane is active the reducer
    /// stores the pending size and arms the tick at this interval; on the next
    /// tick it emits `Effect.nvimResize` and clears the pending state.
    public static let nvimResize: Duration = .milliseconds(50)
}
