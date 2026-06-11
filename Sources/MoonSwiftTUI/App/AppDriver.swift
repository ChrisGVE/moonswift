// File: Sources/MoonSwiftTUI/App/AppDriver.swift
// Location: MoonSwiftTUI/App/
// Role: The single impure component that owns the Elm-style loop. Drains the
//       EventChannel, calls reduce for each event, executes the returned
//       Effects, and triggers renders. Constructs all service callbacks so
//       that MoonSwiftCore services never see TUI types. Owns the TickSource
//       and coordinates with the EventPump for $EDITOR suspension.
//       (ARCHITECTURE.md §5.1, §3b, §5.2)
// Upstream: EventChannel, TickSource, EventPump, Reducer, Renderer,
//           CommandInterpreter, RenderBackend, TerminalSuspender,
//           MoonSwiftCore service protocols
// Downstream: Services (via callbacks), CommandInterpreter (render), process exit

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - AppDriver

/// Owns and runs the Elm-style event loop on the UI thread.
///
/// The loop shape (ARCHITECTURE.md §5.1):
/// ```
/// while quitCode == nil:
///     events = channel.waitAndDrainAll()
///     for event in events:
///         (state, effects) = reduce(state, event)
///         execute(effects)
///         if quitCode != nil: break
///         if sinceLastRender > 32 ms: renderNow()  // flood guard
///     if quitCode != nil: break
///     renderNow()
/// teardown()
/// exit(quitCode)
/// ```
///
/// `@unchecked Sendable` because all mutable state is owned exclusively by
/// the UI thread — the driver never shares mutable state across threads.
public final class AppDriver: @unchecked Sendable {

    // MARK: Dependencies

    private let channel: EventChannel
    private let pump: EventPump
    private let tickSource: TickSource
    private let highlighter: Highlighter
    private let suspender: (any TerminalSuspender)?

    /// The render pipeline: interprets [RenderCommand] against a RenderBackend.
    /// `nil` in skeleton/test mode when no backend is injected.
    private let interpreter: CommandInterpreter?

    // MARK: Optional engine services
    //
    // All three services default to nil so that existing test call sites (which
    // do not pass services) continue to compile and exercise the skeleton paths.
    // Production code (Main.swift) injects live instances for real execution.

    /// Executes Lua scripts. When non-nil, Effect.run / .cancelRun are dispatched
    /// to this service; when nil the skeleton posts a synthetic .runFinished immediately.
    private let runService: (any RunServiceProtocol)?

    /// Runs syntax pre-pass and full luacheck passes. When non-nil, Effect.lint /
    /// .syntaxPrePass / .prewarmLint are dispatched to this service; when nil the
    /// skeleton posts synthetic results immediately.
    private let lintService: (any LintServiceProtocol)?

    /// Loads source files and dispatches results via its injected callback. When
    /// non-nil, Effect.loadSources / .loadSource are dispatched to this store;
    /// when nil the skeleton no-ops.
    private let sourceStore: SourceStore?

    // MARK: Output coalescer (run-scoped)

    /// The active Coalescer for the current run, or nil when no run is in progress.
    ///
    /// Set when Effect.run dispatches to RunService; cleared in the event loop
    /// when .runFinished is processed (UI thread). `onTick` is called on .tick
    /// events while non-nil to flush any buffered output lines.
    private var activeCoalescer: Coalescer?

    // MARK: Nvim session (P4 F8b, ARCHITECTURE.md §10.6)

    /// The live nvim session, set on `.nvimReady` and cleared at the start of
    /// `Effect.nvimCleanup` execution (before any async teardown). Clearing it
    /// first prevents in-flight `Effect.nvimInput` tasks from writing to a
    /// closing FileHandle (`NSFileHandleOperationException` is uncatchable).
    var nvimSession: NvimSession?

    // MARK: State

    private var state: AppState

    /// Last known terminal size, updated from `.resize` events.
    ///
    /// Seeded to the minimum supported size (80×24) at construction so the
    /// renderer always has a valid size even before the first resize event.
    /// In production the EventPump posts a `.resize` as soon as the pump starts,
    /// so this default is quickly replaced with the real terminal dimensions.
    private var currentSize: TerminalSize = TerminalSize(cols: 80, rows: 24)

    // MARK: Loop control

    /// Non-nil once a `Effect.quit(exitCode:)` has been executed.
    private var quitCode: Int32? = nil

    /// Timestamp of the last call to `renderNow()`, for the flood guard.
    private var lastRenderTime: Date = .distantPast

    /// Flood-guard threshold: render at most once per 32 ms during long batches.
    private static let floodGuardInterval: TimeInterval = 0.032

    // MARK: Init

    /// Creates the AppDriver with all its dependencies.
    ///
    /// The three service parameters (`runService`, `lintService`, `sourceStore`)
    /// all default to `nil`. When nil, the corresponding effects fall back to the
    /// original skeleton behaviour (synthetic empty results posted immediately).
    /// This preserves backward compatibility for test call sites that do not
    /// inject services. Production code (Main.swift) passes live instances.
    ///
    /// - Parameters:
    ///   - channel: The MPSC queue bridging all event producers to the loop.
    ///   - pump: The terminal event pump (already running on its thread).
    ///   - tickSource: The armed/disarmed tick poster (already running).
    ///   - highlighter: The tree-sitter highlighter (serial parse executor).
    ///   - suspender: The terminal suspend/resume adapter for $EDITOR handoff.
    ///     `nil` in skeleton mode (no terminal); inject `LiveTerminalSuspender`
    ///     in production and `RecordingTerminalSuspender` in tests.
    ///   - backend: The rendering surface to drive. `nil` in skeleton/test mode.
    ///     Inject `RatatuiKitBackend` in production. When non-nil, the backend
    ///     owns `Terminal.teardown()` — callers must not call it independently.
    ///   - seed: The initial `AppState` built from the decoded project file.
    ///   - runService: Optional `RunService` for real Lua execution. Nil = skeleton.
    ///   - lintService: Optional `LintService` for real linting. Nil = skeleton.
    ///   - sourceStore: Optional `SourceStore` for real file loading. Nil = skeleton.
    public init(
        channel: EventChannel,
        pump: EventPump,
        tickSource: TickSource,
        highlighter: Highlighter = Highlighter(),
        suspender: (any TerminalSuspender)? = nil,
        backend: (any RenderBackend)? = nil,
        seed: AppState,
        runService: (any RunServiceProtocol)? = nil,
        lintService: (any LintServiceProtocol)? = nil,
        sourceStore: SourceStore? = nil
    ) {
        self.channel = channel
        self.pump = pump
        self.tickSource = tickSource
        self.highlighter = highlighter
        self.suspender = suspender
        self.interpreter = backend.map { CommandInterpreter(backend: $0) }
        self.state = seed
        self.runService = runService
        self.lintService = lintService
        self.sourceStore = sourceStore
    }

    // MARK: Run

    /// Start the event loop. Blocks until the process is ready to exit, then
    /// returns the exit code. The caller (Main.swift) calls `Foundation.exit`.
    ///
    /// Must be called from the UI thread only; it never returns until
    /// `Effect.quit` is processed.
    @discardableResult
    public func run() -> Int32 {
        // Fire the .appStarted event to kick off source loading and pre-warm.
        channel.post(.appStarted)

        while quitCode == nil {
            let events = channel.waitAndDrainAll()
            for event in events {
                // Track terminal size from resize events so renderNow() always
                // has the current dimensions. Updated before the reduce call so
                // the renderer sees the new size immediately on the same frame.
                //
                // CR-019: EventPump posts resize(0,0) as a sentinel when the
                // terminal source throws (closed TTY / SIGHUP). Treat it as a
                // clean EOF quit so the loop exits gracefully instead of
                // looping forever on an unresponsive channel.
                if case .resize(let size) = event {
                    if size.cols == 0 && size.rows == 0 {
                        quitCode = 0
                        break
                    }
                    currentSize = size
                }

                // On tick, flush any pending coalescer output before reducing.
                // This bounds sparse-output latency to ≤ ~116 ms (100 ms tick +
                // 16 ms gate) as documented in ARCHITECTURE.md §3c.
                if case .tick = event {
                    activeCoalescer?.onTick()
                }

                // When a run finishes, clear the coalescer reference so onTick
                // no longer fires for the completed run. The coalescer has already
                // flushed all pending lines via finish() inside the run Task before
                // .runFinished was posted, so no output is lost here.
                if case .runFinished = event {
                    activeCoalescer = nil
                }

                // Capture the nvim session from nvimReady before the reduce call
                // so it is available immediately for subsequent effects in the same
                // drain batch. AppDriver is the authoritative owner of nvimSession
                // (ARCHITECTURE.md §10.4.6 NvimSession ownership note).
                if case .nvimReady(let session) = event {
                    nvimSession = session
                }

                let (newState, effects) = reduce(state, event)
                state = newState
                execute(effects)

                if quitCode != nil { break }

                // Flood guard: don't render more often than every 32 ms during a
                // long drain batch (ARCHITECTURE.md §3b).
                let now = Date()
                if now.timeIntervalSince(lastRenderTime) > AppDriver.floodGuardInterval {
                    renderNow()
                }
            }
            if quitCode == nil {
                renderNow()
            }
        }

        teardown()
        return quitCode ?? 0
    }

    // MARK: Effect execution

    /// Execute a single effect. Side effects are performed here; the reducer
    /// never executes anything impure.
    private func execute(_ effects: [Effect]) {
        for effect in effects {
            executeSingle(effect)
            if quitCode != nil { return }
        }
    }

    private func executeSingle(_ effect: Effect) {
        switch effect {

        case .quit(let code):
            // Only set the flag; the loop breaks, then teardown runs.
            quitCode = code

        case .startTick(let interval):
            tickSource.arm(interval: interval)

        case .stopTick:
            tickSource.disarm()

        case .run(let fragment, let config):
            if let svc = runService {
                // Dispatch to the real RunService on a background Task.
                // Capture coalescer, channel, and svc explicitly — all Sendable.
                let coalescer = Coalescer(channel: channel)
                activeCoalescer = coalescer
                Task { [channel, coalescer, svc] in
                    let outcome = await svc.run(
                        fragment,
                        config: config,
                        output: { line in coalescer.onOutput(line) }
                    )
                    coalescer.finish()
                    channel.post(.runFinished(Self.appOutcome(from: outcome)))
                }
            } else {
                // Skeleton: post a synthetic .done immediately.
                channel.post(.runFinished(.done(value: nil, duration: .zero)))
            }

        case .cancelRun:
            if let svc = runService {
                svc.cancel()
            }
        // Skeleton: no-op (break is implicit via fall-through to next event).

        case .syntaxPrePass(let fragment):
            if let svc = lintService {
                // syntaxPrePass is synchronous but creates a fresh engine; run off
                // the UI thread to avoid a momentary freeze on large files.
                Task { [channel] in
                    let diag = svc.syntaxPrePass(fragment)
                    channel.post(.prePassResult(diag))
                }
            } else {
                // Skeleton: post clean result immediately.
                channel.post(.prePassResult(nil))
            }

        case .lint(let fragment, let extraModules):
            if let svc = lintService {
                // Build the luacheck globals from the catalog using the current
                // tomlModuleAvailable probe result from state.
                let tomlProbed = state.tomlModuleAvailable ?? false
                let globals = LuaModuleCatalog.v0.luacheckGlobals(
                    extraModules: extraModules,
                    tomlProbed: tomlProbed
                )
                Task { [channel] in
                    do {
                        let diags = try await svc.lint(fragment, knownGlobals: globals)
                        channel.post(.lintFinished(diags))
                    } catch {
                        // Engine not ready or internal failure — post empty diagnostics
                        // so the reducer can clear the .running lint state.
                        channel.post(.lintFinished([]))
                    }
                }
            } else {
                // Skeleton: empty diagnostics.
                channel.post(.lintFinished([]))
            }

        case .prewarmLint:
            if let svc = lintService {
                Task { [channel] in
                    await svc.prewarm(
                        onReady: { channel.post(.lintEngineReady) },
                        onCatalogProbed: { avail in channel.post(.catalogProbed(tomlAvailable: avail)) },
                        onFailed: { msg in channel.post(.lintEngineFailed(msg)) }
                    )
                }
            } else {
                // Skeleton: post ready + no-toml immediately.
                channel.post(.lintEngineReady)
                channel.post(.catalogProbed(tomlAvailable: false))
            }

        case .highlight(let id):
            // Dispatch to the Highlighter's serial parse executor.
            // The source text is extracted from the current state here, on the
            // UI thread, before the async dispatch — so there is no data race:
            // AppState is a value type and we copy the text string into the
            // closure (Sendable capture).
            if case .loaded(let fragment) = state.sources[id] {
                let text = fragment.code
                highlighter.highlight(id, text: text, via: channel)
            } else {
                // Source not loaded yet — post empty spans so the reducer's
                // first-access-unhighlighted contract is satisfied.
                channel.post(.highlightReady(id, spans: []))
            }

        case .loadSources:
            if let store = sourceStore {
                // Derive project root and entry list from current state.
                if let projectDir = projectDirectoryURL(),
                    case .loaded(let projectFile, _) = state.project
                {
                    store.loadAll(entries: projectFile.sources, projectRoot: projectDir)
                }
                // If the project isn't loaded yet (e.g. quickFile mode), the
                // reducer won't emit this effect, so no load is needed.
            }
        // Skeleton: no-op.

        case .loadSource(let id):
            if let store = sourceStore,
                let projectDir = projectDirectoryURL(),
                case .loaded(let projectFile, _) = state.project
            {
                // Find the matching entry and load it as a one-element batch.
                let entry = projectFile.sources.first { entry in
                    // Match by path; for structured files match by id.path too.
                    entry.path == id.path
                }
                if let entry {
                    store.loadAll(entries: [entry], projectRoot: projectDir)
                }
            }
        // Skeleton: no-op.

        case .loadProject(let url):
            if let store = sourceStore {
                // Cancel any in-flight source loads from the previous project
                // before starting a fresh ProjectStore.load (SourceStore contract,
                // SourceStore.swift §doc). Stale loads posting events for the old
                // project would create ghost navigator entries.
                store.cancelAll()
                Task { [channel] in
                    let result = ProjectStore.load(at: url)
                    channel.post(Self.projectEvent(from: result))
                }
            }
        // Skeleton: no-op.

        case .reloadProject:
            if let store = sourceStore, let projectDir = projectDirectoryURL() {
                // Cancel stale source loads before reloading the project file
                // (SourceStore contract, SourceStore.swift §doc).
                store.cancelAll()
                Task { [channel] in
                    let result = ProjectStore.load(at: projectDir)
                    channel.post(Self.projectEvent(from: result))
                }
            }
        // Skeleton: no-op.

        case .saveDesignations(let designations, let sourcePath):
            if sourceStore != nil,
                let projectDir = projectDirectoryURL(),
                case .loaded(let projectFile, _) = state.project
            {
                // Build an updated ProjectFile with the new designations merged
                // into the entry identified by sourcePath. ProjectStore.save is
                // a static method; no store instance capture is required.
                let updatedFile = Self.applyDesignations(
                    designations,
                    sourcePath: sourcePath,
                    to: projectFile
                )
                let fileURL = projectDir.appendingPathComponent(ProjectStore.fileName)
                Task { [channel] in
                    do {
                        try ProjectStore.save(updatedFile, to: fileURL)
                        channel.post(.designationsSaved)
                    } catch {
                        // Save failure: post a projectMalformed diagnostic so the
                        // reducer surfaces the error rather than silently swallowing it.
                        let diag = Diagnostic(
                            severity: .error,
                            message: "Could not save designations: \(error.localizedDescription)",
                            source: .projectConfig
                        )
                        channel.post(.projectMalformed(diag))
                    }
                }
            } else {
                // Skeleton: acknowledge immediately.
                channel.post(.designationsSaved)
            }

        case .loadPickerTree(let id, let projectRoot):
            // Parse the structured file for the picker modal (ux-spec §3.6).
            // Explicit [channel] capture avoids capturing self (CR-013).
            Task { [channel] in
                let tree = await Self.loadPickerTreeValue(id: id, projectRoot: projectRoot)
                channel.post(tree)
            }

        case .scanProjectDirectory(let dir):
            // Scan the directory for candidate source files (.lua/.json/.yaml/.toml)
            // on a background Task. Explicit [channel] capture avoids self capture (CR-013).
            Task { [channel] in
                let files = await Self.scanForSourceFiles(in: dir)
                channel.post(.projectDirectoryScanned(files))
            }

        case .writeProjectFile(let dir, let luaVersion, let sources):
            // Write moonswift.toml on a background Task. Explicit [channel] avoids
            // capturing self (CR-013). After a successful write the reducer emits
            // .loadProject from reduceProjectFileWritten.
            Task { [channel] in
                let result = await Self.writeProjectFile(
                    directory: dir, luaVersion: luaVersion, sources: sources)
                channel.post(result)
            }

        case .spawnEditor(let url):
            // Full pump-park + terminal suspend + editor spawn + resume sequence.
            // See ARCHITECTURE.md §5.2 and docs/internals/ffi-boundary.md for the
            // handshake diagram and thread-class invariants.
            spawnEditorAndWait(url: url)

        case .yank(let text):
            // Copy text to the system clipboard via pbcopy (ux-spec §2.3 bottom-pane `y`).
            // Purely additive: spawn pbcopy, write text to stdin, let it exit.
            yankToPasteboard(text)

        // MARK: Nvim effects (P4 F8b, ARCHITECTURE.md §10.4.1, §10.6)

        case .spawnNvim(let fragment, let rect):
            // Launch the EditorBridge spawn sequence on a background Task.
            // Explicit [channel] capture — never capture self (CR-013).
            Task { [channel] in
                await EditorBridge.spawn(fragment: fragment, rect: rect, channel: channel)
            }

        case .nvimInput(let keyNotation):
            // Forward a key-notation string to the running nvim instance.
            // Guard with the session reference captured synchronously on the UI
            // thread; if teardown already nil-ed the session this is a no-op.
            guard let session = nvimSession else { return }
            Task { [channel] in
                await session.rpc.notify(
                    method: "nvim_input",
                    params: [.string(keyNotation)]
                )
                // nvim_input is fire-and-forget; no response expected.
                _ = channel  // Satisfy capture for potential future use.
            }

        case .nvimDetach:
            // Send `:qa!` to detach; post .nvimDetached after the notify returns.
            guard let session = nvimSession else { return }
            Task { [channel] in
                await session.rpc.notify(
                    method: "nvim_command",
                    params: [.string(":qa!")]
                )
                channel.post(.nvimDetached)
            }

        case .nvimResize(let size):
            // Fire-and-forget resize notification. Debouncing is applied by Inc-8's
            // reducer dispatch; at this layer we just forward the call.
            guard let session = nvimSession else { return }
            Task {
                await session.rpc.notify(
                    method: "nvim_ui_try_resize",
                    params: [
                        .int(Int64(size.cols)),
                        .int(Int64(size.rows)),
                    ]
                )
            }

        case .nvimCleanup:
            // Step 1 (ARCHITECTURE.md §10.4.5): nil the session reference
            // synchronously before any async work to prevent in-flight nvimInput
            // tasks from writing to closing pipes.
            guard let session = nvimSession else { return }
            nvimSession = nil
            // Shut down the RPC reader thread, then tear down the process.
            Task {
                session.rpc.shutdownReader()
                session.supervisor.teardown()
            }

        // MARK: Write-back effects (Inc-9, ARCHITECTURE.md §10.4.1, §10.3c)

        case .writeBack(let fragment, let editedText, let force):
            // Resolve the project root and lint service before dispatching to
            // the background Task. Both are value captures — no self retained.
            guard let projectRoot = projectDirectoryURL() else { return }
            let lint: any LintServiceProtocol
            if let svc = lintService {
                lint = svc
            } else {
                // Skeleton: no lint service — post success immediately.
                let sid = state.selection
                Task { [channel] in
                    if let sid {
                        channel.post(.writeBackSucceeded(sid))
                    }
                }
                return
            }
            // Fetch the buffer text from nvim when editedText is empty.
            // The empty-string sentinel is the nvimWriteRequested path
            // (ARCHITECTURE.md §10.3c): AppDriver calls nvim_buf_get_lines
            // before invoking WriteBackCoordinator.write.
            let session = nvimSession
            let sid = state.selection
            Task { [channel] in
                let resolvedText: String
                if editedText.isEmpty, let session {
                    do {
                        let lines = try await session.rpc.request(
                            method: "nvim_buf_get_lines",
                            params: [
                                .int(0),  // buffer 0 = current
                                .int(0),  // start line
                                .int(-1),  // end = all
                                .bool(false),
                            ]
                        ) { value -> [String] in
                            guard case .array(let arr) = value else { return [] }
                            return arr.compactMap {
                                if case .string(let s) = $0 { return s }
                                return nil
                            }
                        }
                        resolvedText = lines.joined(separator: "\n") + "\n"
                    } catch {
                        channel.post(
                            .writeBackFailed(.ioFailure("Buffer read failed: \(error.localizedDescription)"))
                        )
                        return
                    }
                } else {
                    resolvedText = editedText
                }

                let result = await WriteBackCoordinator.write(
                    fragment: fragment,
                    editedText: resolvedText,
                    projectRoot: projectRoot,
                    lintService: lint,
                    force: force
                )

                switch result.outcome {
                case .success:
                    if let sid {
                        channel.post(.writeBackSucceeded(sid))
                    }
                case .conflictDetected:
                    // Surface the conflict modal (ARCHITECTURE.md §10.3d).
                    channel.post(
                        .conflictDetected(
                            fileURL: fragment.provenance.file,
                            expectedHash: fragment.provenance.contentHash,
                            editedText: resolvedText
                        )
                    )
                case .spliceError(let err):
                    if case .reparseFailed(let reason) = err,
                        reason.contains("line")
                    {
                        // Syntax pre-pass failure: surface as writeBackBlocked.
                        let diag = Diagnostic(
                            severity: .error,
                            line: 1,
                            message: reason,
                            source: .syntaxPrePass
                        )
                        channel.post(.writeBackBlocked(diag))
                    } else {
                        channel.post(.writeBackFailed(.spliceError(err)))
                    }
                case .validateReadableRejection(let rejection):
                    channel.post(.writeBackFailed(.validateReadableRejection(rejection)))
                case .ioFailure(let reason):
                    channel.post(.writeBackFailed(.ioFailure(reason)))
                }
            }

        case .buildDiffView(let fileURL, let expectedHash, let editedText, let fragment):
            // Build the DiffViewState off the UI thread (ARCHITECTURE.md §10.4.10).
            // Re-reads the on-disk file, re-locates the span via SpanLocator,
            // and constructs left/right line arrays.
            Task { [channel] in
                do {
                    let currentData = try Data(contentsOf: fileURL)
                    // Left side: on-disk span text.
                    let leftText: String
                    if let jsonpath = fragment.provenance.jsonpath,
                        let fmt = StructuredFileFormat.from(
                            extension: fileURL.pathExtension)
                    {
                        let expr = try JSONPathExpression(parsing: jsonpath)
                        guard let text = String(data: currentData, encoding: .utf8)
                        else {
                            channel.post(
                                .writeBackFailed(
                                    .ioFailure("File is not valid UTF-8")))
                            return
                        }
                        let tree = try Self.decodeTreeForDiff(text, format: fmt, document: fragment.provenance.document)
                        let matches = expr.evaluate(on: tree)
                        guard let first = matches.first else {
                            channel.post(
                                .writeBackFailed(
                                    .ioFailure("JSONPath matched nothing in current file")))
                            return
                        }
                        let loc = try SpanLocator.locateSpan(
                            in: currentData,
                            format: fmt,
                            path: first.path.steps,
                            document: fragment.provenance.document
                        )
                        let spanData = currentData[loc.byteRange]
                        leftText = String(data: spanData, encoding: .utf8) ?? ""
                    } else {
                        leftText = String(data: currentData, encoding: .utf8) ?? ""
                    }

                    let isConflict = SpanSplicer.hasConflict(
                        currentData: currentData, expected: expectedHash)
                    let leftTitle =
                        isConflict
                        ? "On disk (changed) — \(fileURL.lastPathComponent)"
                        : "On disk — \(fileURL.lastPathComponent)"
                    let rightTitle = "Edited"

                    let diffState = DiffViewState(
                        leftTitle: leftTitle,
                        rightTitle: rightTitle,
                        leftLines: leftText.components(separatedBy: "\n"),
                        rightLines: editedText.components(separatedBy: "\n")
                    )
                    channel.post(.diffViewReady(diffState))
                } catch {
                    channel.post(
                        .writeBackFailed(
                            .ioFailure("Diff build failed: \(error.localizedDescription)")))
                }
            }
        }
    }

    // MARK: Editor spawn

    /// Execute the full $EDITOR handshake for the given file URL.
    ///
    /// Sequence (ARCHITECTURE.md §5.2, ffi-boundary.md §EDITOR suspend/resume):
    /// 1. Park the pump — blocks until the pump acknowledges (≤ 50 ms).
    ///    No input-class shim call is in flight after this returns.
    /// 2. Suspend the terminal (leave alt screen, restore termios).
    /// 3. Spawn `$EDITOR <path>` — direct exec, no shell interpretation.
    /// 4. Wait for the editor process to exit (any exit code is accepted).
    /// 5. Resume the terminal (raw mode, alt screen).
    /// 6. Unpark the pump.
    ///
    /// If `$EDITOR` is not set: posts a transient and returns immediately
    /// without touching the pump or the terminal.
    ///
    /// If terminal suspend/resume is unavailable (no `suspender` injected):
    /// the pump is still parked/unparked around the spawn so the handshake
    /// contract is upheld even in skeleton/test mode.
    ///
    /// Must be called from the UI thread (render/terminal-class).
    private func spawnEditorAndWait(url: URL) {
        // Guard: $EDITOR must be set. The exact transient string is normative
        // (ux-spec.md §6.4 — "No $EDITOR" entry).
        guard let editor = ProcessInfo.processInfo.environment["EDITOR"],
            !editor.isEmpty
        else {
            let msg = "$EDITOR is not set. Set it to open the project file."
            // Set the transient directly on state (AppDriver owns state mutation)
            // and arm the tick source so the transient expiry is processed.
            state.transient = TransientMessage(text: msg)
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }

        // CR-011: validate that $EDITOR names an absolute, existing, executable
        // file before passing it to Process.executableURL. A relative, non-existent,
        // or non-executable value would otherwise allow arbitrary code execution
        // with the permissions of the moonswift process.
        //
        // IMPORTANT: check the raw `editor` string — not `URL(fileURLWithPath:).path`
        // — because URL(fileURLWithPath:) resolves relative paths against the
        // process working directory, producing an absolute path even for a bare
        // name like "vim". The guard must reject anything that is not already
        // written as an absolute path by the user.
        guard editor.hasPrefix("/") else {
            state.transient = TransientMessage(text: "$EDITOR must be an absolute path.")
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }
        let editorURL = URL(fileURLWithPath: editor)
        guard FileManager.default.fileExists(atPath: editorURL.path),
            FileManager.default.isExecutableFile(atPath: editorURL.path)
        else {
            state.transient = TransientMessage(
                text: "$EDITOR '\(editorURL.lastPathComponent)' is not executable.")
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }

        // 1. Park the pump — guaranteed no input-class call in flight after this.
        pump.parkAndWait()

        // 2. Suspend the terminal (TTY-gated: only when a suspender is injected).
        if let suspender {
            do {
                try suspender.suspend()
            } catch {
                // Terminal suspend failed — unpark and continue; the UI loop is
                // still healthy. A render after unpark will restore the view.
                pump.unparkAfterResume()
                return
            }
        }

        // 3 + 4. Spawn the editor with the file path as a direct argument vector
        //         (no shell — no word splitting, no glob expansion, no injection).
        //         editorURL was validated above (absolute + executable).
        let process = Process()
        process.executableURL = editorURL
        process.arguments = [url.path]
        do {
            try process.run()
            process.waitUntilExit()
            // Non-zero exit is accepted: the editor may exit with an error code
            // (e.g. nvim exits 1 on :cquit) but we continue regardless
            // (ARCHITECTURE.md §5.2 "non-zero editor exit → continue anyway").
        } catch {
            // Editor could not be launched (executable not found, permission
            // denied, etc.). Fall through to resume — the terminal must always
            // be restored.
        }

        // 5. Resume the terminal (TTY-gated).
        if let suspender {
            do {
                try suspender.resume()
            } catch {
                // Resume failure is serious but unrecoverable without crashing;
                // log and continue — the loop will render over whatever state
                // the terminal is in. Emergency restore is the crash-handler
                // path (ARCHITECTURE.md §3f); this is not a crash path.
            }
        }

        // 6. Unpark the pump — resumes normal input polling.
        pump.unparkAfterResume()
    }

    // MARK: Clipboard

    /// Write `text` to the system clipboard by piping it through `pbcopy`.
    ///
    /// macOS-only (`pbcopy` is a standard utility). Failure (pbcopy not on PATH,
    /// or stdin write fails) is silently swallowed — clipboard is a best-effort
    /// feature; the UI does not change either way. Must be called from the UI
    /// thread (all effects are executed on the UI thread by `executeSingle`).
    private func yankToPasteboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            // pbcopy unavailable or failed — silent no-op (see doc comment).
        }
    }

    // MARK: Render

    /// Render the current state to the terminal.
    ///
    /// Calls `render(_:size:)` to produce a [RenderCommand] sequence, then
    /// hands it to the `CommandInterpreter` to drive the RenderBackend. When
    /// no backend is injected (skeleton/test mode) this is a timed no-op so
    /// the flood-guard timestamp advances correctly.
    ///
    /// Must be called from the UI thread (render/terminal-class).
    private func renderNow() {
        lastRenderTime = Date()
        guard let interp = interpreter else { return }
        let commands = render(state, size: currentSize)
        do {
            try interp.apply(commands)
        } catch {
            // Render errors are non-fatal: the loop continues and the next frame
            // will attempt a full redraw. Log to stderr; the UI remains intact.
            fputs("moonswift: render error — \(error)\n", stderr)
        }
    }

    // MARK: Teardown

    /// Restore the terminal and shut down background threads.
    ///
    /// Called after the loop exits (after `quitCode` is set). The backend owns
    /// `Terminal.teardown()`; callers (Main.swift) must not call it separately
    /// when a backend is active. Background threads are stopped before teardown
    /// so no render/input calls are in flight during terminal restore.
    private func teardown() {
        pump.stop()
        tickSource.stop()
        if let interp = interpreter {
            do {
                try interp.backend.teardown()
            } catch {
                fputs("moonswift: terminal teardown warning — \(error)\n", stderr)
            }
        }
    }

    // MARK: Init form helpers (task 24)

    /// Scans `directory` for candidate source files (.lua/.json/.yaml/.toml).
    ///
    /// Returns a sorted list of paths relative to `directory`. Files in
    /// subdirectories are included. Hidden files and directories are skipped.
    /// Never throws — errors return an empty array.
    private static func scanForSourceFiles(in directory: URL) async -> [String] {
        // Enumerate on a nonisolated closure to avoid the Sendable constraint
        // on FileManager.DirectoryEnumerator.makeIterator (unavailable from async).
        return await Task.detached(priority: .utility) {
            scanSourceFilesSync(in: directory)
        }.value
    }

    /// Synchronous helper called from the detached task above.
    ///
    /// Walks `directory` for .lua/.json/.yaml/.yml/.toml files, skipping
    /// hidden files. Returns paths relative to `directory`, sorted.
    private static func scanSourceFilesSync(in directory: URL) -> [String] {
        let extensions = Set(["lua", "json", "yaml", "yml", "toml"])
        var results: [String] = []
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            let rel =
                fileURL.path.hasPrefix(directory.path)
                ? String(fileURL.path.dropFirst(directory.path.count + 1))
                : fileURL.path
            guard rel != "moonswift.toml" else { continue }
            results.append(rel)
        }
        return results.sorted()
    }

    /// Writes `moonswift.toml` to `directory` and returns the AppEvent to post.
    ///
    /// Uses `ProjectStore.save` to serialise a `ProjectFile` built from the
    /// chosen `luaVersion` and `sources`. Atomic write via Foundation.
    private static func writeProjectFile(
        directory: URL,
        luaVersion: String,
        sources: [String]
    ) async -> AppEvent {
        let sourceEntries = sources.map { SourceEntry(path: $0) }
        let projectFile = ProjectFile(luaVersion: luaVersion, sources: sourceEntries)
        let fileURL = directory.appendingPathComponent(ProjectStore.fileName)
        do {
            // Use save (not initialize) to allow overwrite if the form is somehow
            // re-submitted — initialize would throw fileAlreadyExists.
            try ProjectStore.save(projectFile, to: fileURL)
            return .projectFileWritten(projectURL: fileURL, error: nil)
        } catch {
            return .projectFileWritten(projectURL: nil, error: error.localizedDescription)
        }
    }

    // MARK: Picker tree loader

    /// Parses a structured file on a background Task and returns the picker-ready
    /// AppEvent to post. Resolves the file format from the `SourceID.path` extension.
    ///
    /// Called from `executeSingle(.loadPickerTree)` inside a `Task {}` block so
    /// the parse never blocks the UI thread. Dispatched as static so it does not
    /// capture `self` and can run concurrently without data-race risk.
    ///
    /// Supported formats: `.json` → `decodeJSON`, `.yaml` / `.yml` → `decodeYAML`,
    /// `.toml` → `decodeTOML`. Unknown extension → parse error event.
    private static func loadPickerTreeValue(id: SourceID, projectRoot: URL) async -> AppEvent {
        let fileURL = projectRoot.appendingPathComponent(id.path)
        let ext = (id.path as NSString).pathExtension.lowercased()

        // --- File-type + size + TOCTOU guard (CR-028 / CR-030) ---
        // The picker reads the whole structured file into memory to build its
        // tree, so it needs the same OOM / hang / symlink-escape protections as
        // the source loaders. Without this, a project file naming a FIFO or a
        // symlink to /dev/zero as a source would hang or exhaust memory here.
        if let rejection = SourceStore.validateReadable(
            at: fileURL,
            projectRoot: projectRoot,
            sizeLimit: structuredFileSizeLimit
        ) {
            let message: String
            switch rejection {
            case .notRegularFile:
                message = "Cannot open \(id.path): not a regular file"
            case .tooLarge(let limitMiB):
                message = "Cannot open \(id.path): file size exceeds the \(limitMiB) MiB limit"
            case .outsideProjectRoot:
                message = "Cannot open \(id.path): path resolves outside the project root"
            }
            return .pickerTreeReady(id, tree: nil, errorMessage: message)
        }

        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return .pickerTreeReady(id, tree: nil, errorMessage: error.localizedDescription)
        }

        do {
            let tree: TreeValue
            switch ext {
            case "json":
                tree = try decodeJSON(raw)
            case "yaml", "yml":
                // For YAML, use the document index from the SourceID (multi-doc support).
                tree = try decodeYAML(raw, document: id.document)
            case "toml":
                tree = try decodeTOML(raw)
            default:
                return .pickerTreeReady(
                    id,
                    tree: nil,
                    errorMessage: "Unsupported file format: .\(ext)"
                )
            }
            return .pickerTreeReady(id, tree: tree, errorMessage: nil)
        } catch let e as TreeDecoderError {
            let msg: String
            switch e {
            case .jsonMalformed(let r): msg = r
            case .yamlMalformed(let r): msg = r
            case .tomlMalformed(let r): msg = r
            case .yamlDocumentIndexOutOfRange(let req, let avail):
                msg = "document \(req) requested but only \(avail) available"
            case .nestingTooDeep:
                msg = "File nesting too deep (exceeds safe recursion limit)"
            case .tooManyNodes:
                msg = "File too large to browse (node count exceeds safe limit)"
            }
            return .pickerTreeReady(id, tree: nil, errorMessage: msg)
        } catch {
            return .pickerTreeReady(id, tree: nil, errorMessage: error.localizedDescription)
        }
    }

    /// Decode `text` in the given `format` to a `TreeValue` for diff construction.
    ///
    /// Mirrors `WriteBackCoordinator.decodeTree` — kept separate to avoid
    /// coupling AppDriver to WriteBackCoordinator internals. Used exclusively
    /// by the `buildDiffView` effect arm to re-locate the on-disk span for the
    /// left column of the diff view.
    private static func decodeTreeForDiff(
        _ text: String,
        format: StructuredFileFormat,
        document: Int
    ) throws -> TreeValue {
        switch format {
        case .json: return try decodeJSON(text)
        case .yaml: return try decodeYAML(text, document: document)
        case .toml: return try decodeTOML(text)
        }
    }

    // MARK: Service helpers

    /// Returns the project root directory URL derived from the current launch mode.
    ///
    /// - `.project(url)` → `url` (the directory itself).
    /// - `.quickFile(url)` → the file's containing directory.
    /// - `.empty` → nil (no project context).
    ///
    /// Called on the UI thread when dispatching source / project effects.
    private func projectDirectoryURL() -> URL? {
        switch state.launch {
        case .project(let dir):
            return dir
        case .quickFile(let fileURL):
            return fileURL.deletingLastPathComponent()
        case .empty:
            return nil
        }
    }

    /// Maps a `CoreRunOutcome` to the TUI-layer `RunOutcome`.
    ///
    /// The two enums are structurally identical but live in different layers
    /// (MoonSwiftCore vs. MoonSwiftTUI) to avoid the core importing TUI types.
    /// This mapper is the single cross-layer translation point. Associated
    /// values on `CoreLimitKind` (the configured limit thresholds) are forwarded
    /// directly to `LimitKind` so `buildRunFooter` can format the ux-spec §6.3
    /// strings: `instruction limit exceeded (N instructions)` / `wall-clock
    /// limit exceeded (Xms)`.
    private static func appOutcome(from core: CoreRunOutcome) -> RunOutcome {
        switch core {
        case .done(let value, let duration):
            return .done(value: value, duration: duration)
        case .error(let diag, let traceback):
            // CoreRunOutcome.error carries traceback as String?; RunOutcome expects [String].
            return .error(diag, traceback: traceback.map { [$0] } ?? [])
        case .cancelled:
            return .cancelled
        case .limitExceeded(let kind):
            switch kind {
            case .instructions(let count):
                return .limitExceeded(kind: .instructions(count: count))
            case .wallClock(let durationMs):
                return .limitExceeded(kind: .wallClock(durationMs: durationMs))
            }
        }
    }

    /// Maps a `ProjectStore.LoadResult` to the `AppEvent` the reducer expects.
    ///
    /// `.unsupportedVersion` maps to `.projectUnsupportedVersion` so the reducer
    /// sets `ProjectState.unsupportedVersion` and the renderer surfaces the
    /// degraded state (ux-spec §3.7): persistent bottom-pane header, disabled
    /// `r`/`l`, and `[Lua X.X: unsupported]` title badge.
    private static func projectEvent(from result: ProjectStore.LoadResult) -> AppEvent {
        switch result {
        case .loaded(let file, let diags):
            return .projectLoaded(file, diagnostics: diags)
        case .malformed(let diag):
            return .projectMalformed(diag)
        case .unsupportedVersion(let file, let diags):
            return .projectUnsupportedVersion(file, diagnostics: diags)
        }
    }

    /// Applies updated `[FieldDesignation]` to the matching source entry in
    /// `projectFile`, returning a new `ProjectFile` with the designations merged.
    ///
    /// The target entry is identified by `sourcePath` — the project-relative
    /// file path that the picker was browsing. Matching by path is correct for
    /// both the common first-use case (entry has zero prior fields) and the
    /// subsequent edit case (entry already has fields). The previous field-overlap
    /// strategy silently no-oped when the entry had no prior designations.
    ///
    /// This is the write-back path for the picker modal save (ux-spec §3.6): when
    /// the user confirms marks, the reducer emits `Effect.saveDesignations` and the
    /// AppDriver calls this helper to build the updated file before persisting it.
    private static func applyDesignations(
        _ designations: [FieldDesignation],
        sourcePath: String,
        to projectFile: ProjectFile
    ) -> ProjectFile {
        // Replace fields only on the entry whose path matches the picker's source.
        // All other entries are left exactly as-is.
        let updatedSources = projectFile.sources.map { entry -> SourceEntry in
            guard entry.path == sourcePath else { return entry }
            return SourceEntry(path: entry.path, fields: designations)
        }

        return ProjectFile(
            luaVersion: projectFile.luaVersion,
            sources: updatedSources,
            run: projectFile.run,
            lint: projectFile.lint,
            settings: projectFile.settings
        )
    }
}
