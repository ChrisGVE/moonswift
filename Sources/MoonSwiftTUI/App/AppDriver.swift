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
    public init(
        channel: EventChannel,
        pump: EventPump,
        tickSource: TickSource,
        highlighter: Highlighter = Highlighter(),
        suspender: (any TerminalSuspender)? = nil,
        backend: (any RenderBackend)? = nil,
        seed: AppState
    ) {
        self.channel = channel
        self.pump = pump
        self.tickSource = tickSource
        self.highlighter = highlighter
        self.suspender = suspender
        self.interpreter = backend.map { CommandInterpreter(backend: $0) }
        self.state = seed
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
                if case .resize(let size) = event {
                    currentSize = size
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

        case .run:
            // Service call — dispatched to RunService when implemented (task 23).
            // In the skeleton, post a synthetic runFinished immediately.
            let finishedOutcome = RunOutcome.done(value: nil, duration: .zero)
            channel.post(.runFinished(finishedOutcome))

        case .cancelRun:
            // RunService.cancel() — no-op in skeleton.
            break

        case .syntaxPrePass:
            // LintService.syntaxPrePass() — no-op in skeleton; clean result.
            channel.post(.prePassResult(nil))

        case .lint:
            // LintService.lint() — no-op in skeleton; empty diagnostics.
            channel.post(.lintFinished([]))

        case .prewarmLint:
            // LintService.prewarm() — no-op in skeleton; post ready.
            channel.post(.lintEngineReady)
            channel.post(.catalogProbed(tomlAvailable: false))

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
            // SourceStore.loadSources() — no-op in skeleton.
            break

        case .loadSource:
            // SourceStore.loadSource() — no-op in skeleton.
            break

        case .loadProject:
            // ProjectStore.load() — no-op in skeleton.
            break

        case .reloadProject:
            // ProjectStore.reload() — no-op in skeleton.
            break

        case .saveDesignations:
            // ProjectStore.saveDesignations() — no-op in skeleton.
            channel.post(.designationsSaved)

        case .loadPickerTree(let id, let projectRoot):
            // Parse the structured file for the picker modal (ux-spec §3.6).
            // Dispatched to a background Task; result posted as .pickerTreeReady.
            Task {
                let tree = await Self.loadPickerTreeValue(id: id, projectRoot: projectRoot)
                self.channel.post(tree)
            }

        case .scanProjectDirectory(let dir):
            // Scan the directory for candidate source files (.lua/.json/.yaml/.toml)
            // on a background Task. Posts .projectDirectoryScanned when complete.
            Task {
                let files = await Self.scanForSourceFiles(in: dir)
                self.channel.post(.projectDirectoryScanned(files))
            }

        case .writeProjectFile(let dir, let luaVersion, let sources):
            // Write moonswift.toml on a background Task, then post .projectFileWritten.
            Task {
                let result = await Self.writeProjectFile(
                    directory: dir, luaVersion: luaVersion, sources: sources)
                self.channel.post(result)
                // After a successful write, trigger a project load so the navigator
                // populates (handled via the .loadProject effect which the reducer
                // emits from reduceProjectFileWritten).
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: editor)
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
            }
            return .pickerTreeReady(id, tree: nil, errorMessage: msg)
        } catch {
            return .pickerTreeReady(id, tree: nil, errorMessage: error.localizedDescription)
        }
    }
}
