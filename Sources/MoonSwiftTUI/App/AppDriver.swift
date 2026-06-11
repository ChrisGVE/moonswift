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
    //
    // Access level note: properties used by AppDriver+NvimEffects.swift (a same-
    // module extension in a separate file) require at least `internal` visibility.
    // `private` restricts to the declaring file; `fileprivate` to the declaring
    // file; only `internal` (the default) crosses file boundaries within a module.
    // All UI-thread-only mutation invariants are upheld by the driver's single-
    // threaded execution model, not by the access modifier.

    let channel: EventChannel
    let pump: EventPump
    let tickSource: TickSource
    private let highlighter: Highlighter
    let suspender: (any TerminalSuspender)?

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
    let lintService: (any LintServiceProtocol)?

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

    /// The live nvim session.
    ///
    /// **Permitted writers (CR-025 / §10.6 invariant):**
    /// 1. The event drain loop in `run()` — assigns when `.nvimReady` arrives,
    ///    *before* `reduce`, so effects produced in the same drain batch can
    ///    reference the session immediately (§10.4.6 pre-reduce capture).
    /// 2. `executeNvimCleanup()` in `AppDriver+NvimEffects.swift` — sets to `nil`
    ///    synchronously at the start of cleanup, before any async teardown work,
    ///    so in-flight `.nvimInput` Tasks see nil and skip the write — the
    ///    §10.6 nil-before-teardown invariant.
    ///
    /// No other site may write this property. `internal` (not `private`) because
    /// `AppDriver+NvimEffects.swift` reads it from its extension methods; `private`
    /// is not possible across file boundaries within a module. All mutation is
    /// UI-thread-only — the access modifier does not enforce this, the driver's
    /// single-threaded execution model does.
    var nvimSession: NvimSession?

    // MARK: Nvim cleanup Task handle (CR-003)

    /// Handle for the in-flight nvim cleanup Task.
    ///
    /// Stored when `Effect.nvimCleanup` is processed so `teardown()` can await
    /// completion before restoring the terminal. This ensures pipe writes, SIGTERM,
    /// and `waitUntilExit` are fully settled before the render backend tears down.
    var nvimCleanupTask: Task<Void, Never>?

    // MARK: State

    var state: AppState

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

                // Pre-reduce session capture: store the NvimSession before calling
                // reduce so that effects produced in the same drain batch (e.g.
                // a queued nvimInput) can reference it immediately. This is the
                // designated assignment site for nvimSession (CR-025 / §10.4.6).
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
            quitCode = code

        case .startTick(let interval):
            tickSource.arm(interval: interval)

        case .stopTick:
            tickSource.disarm()

        case .run(let fragment, let config):
            executeRun(fragment, config: config)

        case .cancelRun:
            runService?.cancel()
        // Skeleton: no-op.

        case .syntaxPrePass(let fragment):
            executeSyntaxPrePass(fragment)

        case .lint(let fragment, let extraModules):
            executeLint(fragment, extraModules: extraModules)

        case .prewarmLint:
            executePrewarmLint()

        case .highlight(let id):
            executeHighlight(id: id)

        case .loadSources:
            executeLoadSources()

        case .loadSource(let id):
            executeLoadSource(id: id)

        case .loadProject(let url):
            executeLoadProject(url: url)

        case .reloadProject:
            executeReloadProject()

        case .saveDesignations(let designations, let sourcePath):
            executeSaveDesignations(designations, sourcePath: sourcePath)

        case .loadPickerTree(let id, let projectRoot):
            // Short: one-liner Task dispatch (CR-013 [channel] capture).
            Task { [channel] in
                let tree = await Self.loadPickerTreeValue(id: id, projectRoot: projectRoot)
                channel.post(tree)
            }

        case .scanProjectDirectory(let dir):
            // Short: one-liner Task dispatch (CR-013 [channel] capture).
            Task { [channel] in
                let files = await Self.scanForSourceFiles(in: dir)
                channel.post(.projectDirectoryScanned(files))
            }

        case .writeProjectFile(let dir, let luaVersion, let sources):
            // Short: one-liner Task dispatch (CR-013 [channel] capture).
            Task { [channel] in
                let result = await Self.writeProjectFile(
                    directory: dir, luaVersion: luaVersion, sources: sources)
                channel.post(result)
            }

        case .spawnEditor(let url):
            // Full pump-park + terminal suspend + editor spawn + resume.
            // ARCHITECTURE.md §5.2, ffi-boundary.md §EDITOR suspend/resume.
            spawnEditorAndWait(url: url)

        case .yank(let text):
            // Clipboard write via pbcopy (ux-spec §2.3 bottom-pane `y`).
            yankToPasteboard(text)

        // MARK: Nvim effects (P4 F8b, ARCHITECTURE.md §10.4.1, §10.6)
        // Bodies extracted to AppDriver+NvimEffects.swift.

        case .spawnNvim(let fragment, let rect):
            executeSpawnNvim(fragment: fragment, rect: rect)

        case .nvimInput(let keyNotation):
            executeNvimInput(keyNotation)

        case .nvimDetach:
            executeNvimDetach()

        case .nvimResize(let size):
            executeNvimResize(size)

        case .nvimCleanup:
            executeNvimCleanup()

        // MARK: Write-back effects (Inc-9, ARCHITECTURE.md §10.4.1, §10.3c)
        // Bodies extracted to AppDriver+NvimEffects.swift.

        case .writeBack(let fragment, let editedText, let force):
            executeWriteBack(fragment: fragment, editedText: editedText, force: force)

        case .spawnEditorFallback(let fragment):
            // $EDITOR fallback path for nvim-absent/too-old (ARCHITECTURE.md §10.8
            // Inc-10, ux-spec §7.3). Body in AppDriver+NvimEffects.swift.
            spawnEditorFallbackAndWait(fragment: fragment)

        case .buildDiffView(let fileURL, let expectedHash, let editedText, let fragment):
            executeBuildDiffView(
                fileURL: fileURL,
                expectedHash: expectedHash,
                editedText: editedText,
                fragment: fragment
            )
        }
    }

    // MARK: Effect helpers — core services

    /// Dispatch a run to the live `RunService`, or post a synthetic result in skeleton mode.
    private func executeRun(_ fragment: LuaSourceFragment, config: RunConfig) {
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
    }

    /// Run the syntax pre-pass off the UI thread; post `.prePassResult` on completion.
    ///
    /// `syntaxPrePass` is synchronous but creates a fresh engine; running off the
    /// UI thread avoids a momentary freeze on large files.
    private func executeSyntaxPrePass(_ fragment: LuaSourceFragment) {
        if let svc = lintService {
            Task { [channel] in
                let diag = svc.syntaxPrePass(fragment)
                channel.post(.prePassResult(diag))
            }
        } else {
            channel.post(.prePassResult(nil))
        }
    }

    /// Run the full luacheck lint pass on a background Task; post `.lintFinished`.
    ///
    /// Builds the luacheck globals from the catalog using the current
    /// `tomlModuleAvailable` probe result from state before dispatching.
    private func executeLint(_ fragment: LuaSourceFragment, extraModules: [String]) {
        if let svc = lintService {
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
            channel.post(.lintFinished([]))
        }
    }

    /// Prewarm the lint engine in the background; posts `.lintEngineReady`,
    /// `.catalogProbed`, or `.lintEngineFailed` via the supplied callbacks.
    private func executePrewarmLint() {
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
    }

    /// Dispatch a highlight request to the `Highlighter`'s serial parse executor.
    ///
    /// The source text is extracted from state on the UI thread before the async
    /// dispatch — no data race because `AppState` is a value type.
    private func executeHighlight(id: SourceID) {
        if case .loaded(let fragment) = state.sources[id] {
            let text = fragment.code
            highlighter.highlight(id, text: text, via: channel)
        } else {
            // Source not loaded yet — post empty spans so the reducer's
            // first-access-unhighlighted contract is satisfied.
            channel.post(.highlightReady(id, spans: []))
        }
    }

    /// Trigger a full project source-file load via the `SourceStore`.
    ///
    /// Derives the project root and entry list from the current state. If the
    /// project is not yet loaded (e.g. quickFile mode) the reducer will not emit
    /// this effect, so no guard is needed here beyond the store availability check.
    private func executeLoadSources() {
        guard let store = sourceStore,
            let projectDir = projectDirectoryURL(),
            case .loaded(let projectFile, _) = state.project
        else { return }
        store.loadAll(entries: projectFile.sources, projectRoot: projectDir)
    }

    /// Reload a single source entry identified by `id` via the `SourceStore`.
    private func executeLoadSource(id: SourceID) {
        guard let store = sourceStore,
            let projectDir = projectDirectoryURL(),
            case .loaded(let projectFile, _) = state.project
        else { return }
        // Find the matching entry and load it as a one-element batch.
        if let entry = projectFile.sources.first(where: { $0.path == id.path }) {
            store.loadAll(entries: [entry], projectRoot: projectDir)
        }
    }

    /// Cancel in-flight source loads and start a fresh project load from `url`.
    ///
    /// Cancelling stale source loads before the new project load prevents ghost
    /// navigator entries from old results (SourceStore contract, SourceStore.swift §doc).
    private func executeLoadProject(url: URL) {
        guard let store = sourceStore else { return }
        store.cancelAll()
        Task { [channel] in
            let result = ProjectStore.load(at: url)
            channel.post(Self.projectEvent(from: result))
        }
    }

    /// Cancel in-flight source loads and reload the project file from the current directory.
    private func executeReloadProject() {
        guard let store = sourceStore, let projectDir = projectDirectoryURL() else { return }
        store.cancelAll()
        Task { [channel] in
            let result = ProjectStore.load(at: projectDir)
            channel.post(Self.projectEvent(from: result))
        }
    }

    /// Persist updated field designations and post `.designationsSaved` (or `.projectMalformed`).
    ///
    /// Applies `designations` to the source entry identified by `sourcePath`
    /// in the current project file, then writes the updated file via `ProjectStore.save`.
    private func executeSaveDesignations(
        _ designations: [FieldDesignation],
        sourcePath: String
    ) {
        guard sourceStore != nil,
            let projectDir = projectDirectoryURL(),
            case .loaded(let projectFile, _) = state.project
        else {
            // Skeleton: acknowledge immediately.
            channel.post(.designationsSaved)
            return
        }
        let updatedFile = Self.applyDesignations(
            designations, sourcePath: sourcePath, to: projectFile)
        let fileURL = projectDir.appendingPathComponent(ProjectStore.fileName)
        Task { [channel] in
            do {
                try ProjectStore.save(updatedFile, to: fileURL)
                channel.post(.designationsSaved)
            } catch {
                let diag = Diagnostic(
                    severity: .error,
                    message: "Could not save designations: \(error.localizedDescription)",
                    source: .projectConfig
                )
                channel.post(.projectMalformed(diag))
            }
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
    ///
    /// CR-003: awaits `nvimCleanupTask` first so that any in-flight pipe writes,
    /// SIGTERM, and `waitUntilExit` are fully settled before the terminal backend
    /// tears down. The blocking wait runs here on the UI thread (which is quitting
    /// anyway) so it does not starve the cooperative pool.
    private func teardown() {
        // Await the nvim cleanup Task if one is in flight (CR-003). This blocks
        // the UI thread, but teardown is the last thing the UI thread does before
        // the process exits, so blocking here is the correct pattern.
        if let cleanupTask = nvimCleanupTask {
            let sema = DispatchSemaphore(value: 0)
            Task {
                await cleanupTask.value
                sema.signal()
            }
            sema.wait()
            nvimCleanupTask = nil
        }
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
    /// CR-031: delegates to `WriteBackCoordinator.decodeTree` (the single
    /// authoritative decode switch) rather than duplicating the format dispatch.
    /// Used exclusively by the `buildDiffView` effect arm to re-locate the
    /// on-disk span for the left column of the diff view.
    /// `internal` (not `private`) — called from `AppDriver+NvimEffects.swift`
    /// inside `executeBuildDiffView`; `private` would restrict to this file only.
    static func decodeTreeForDiff(
        _ text: String,
        format: StructuredFileFormat,
        document: Int
    ) throws -> TreeValue {
        try WriteBackCoordinator.decodeTree(text, format: format, document: document)
    }

    // MARK: Service helpers

    /// Derive the `SourceID` for a `LuaSourceFragment` relative to `projectRoot`.
    ///
    /// The `path` component is the fragment's file URL made relative to the project
    /// root. If the file is not under the root (unusual — would have been rejected
    /// by validateReadable), the absolute path is used as a fallback. The
    /// `jsonpath` and `document` fields are taken directly from the provenance
    /// so the ID matches the key already present in `AppState.sources`.
    ///
    /// Called on the UI thread before dispatching write-back Tasks so that
    /// navigator-cursor moves during the async edit do not retarget the post-write
    /// reload (CR-023).
    static func sourceID(for fragment: LuaSourceFragment, projectRoot: URL) -> SourceID {
        let filePath = fragment.provenance.file.path
        let rootPath = projectRoot.path
        let relPath: String
        if filePath.hasPrefix(rootPath + "/") {
            relPath = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            relPath = filePath
        }
        return SourceID(
            path: relPath,
            jsonpath: fragment.provenance.jsonpath,
            document: fragment.provenance.document
        )
    }

    /// Returns the project root directory URL derived from the current launch mode.
    ///
    /// - `.project(url)` → `url` (the directory itself).
    /// - `.quickFile(url)` → the file's containing directory.
    /// - `.empty` → nil (no project context).
    ///
    /// Called on the UI thread when dispatching source / project effects.
    func projectDirectoryURL() -> URL? {
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
