// File: Sources/moonswift/Main.swift
// Location: Sources/moonswift/
// Role: Process entry point. Parses CLI arguments, installs signal handlers
//       (guarded no-ops until terminal init, ARCHITECTURE.md §3a/§3f), loads
//       the project file, initialises the terminal, constructs and starts the
//       AppDriver, maps termination to sysexits codes (PRD §4.7).
//       Contains no domain logic and no UI rendering.
// Upstream: CLIArguments.swift (parsed args), CrashHandlers.swift (handlers),
//           MoonSwiftCore/ProjectStore (project load),
//           MoonSwiftTUI (AppDriver, EventChannel, EventPump, TickSource,
//                         AppState, LaunchMode)
// Downstream: (process entry — nothing imports this target)
//
// Startup sequence (ARCHITECTURE.md §3a):
//   1. Parse CLI arguments → LaunchMode or print-and-exit.
//   2. Install crash handlers (guarded no-ops until shim INITIALIZED is set).
//   3. Load the project file via ProjectStore, or set empty / quick-file mode.
//   4. Initialise the terminal (raw mode, alt screen — sets shim INITIALIZED).
//   5. Construct AppDriver with seed AppState; start EventPump and TickSource.
//   6. Hand off to AppDriver.run() — main thread never returns from here until
//      the user quits. Exit code comes back through run()'s return value.
//
// What this file MUST NOT do (ARCHITECTURE.md §2 Main/CLI row):
//   - Contain domain or UI logic.
//   - Render anything itself.
//   - Call SourceStore (source loading is Effect.loadSources, dispatched by the
//     AppDriver after the first reduce of .appStarted).
//   - Touch the AppDriver loop after handoff.

import Darwin
import Foundation
import MoonSwiftCore
import MoonSwiftTUI
import RatatuiKit

// MARK: - Entry point

@main
struct MoonSwift {
    static func main() {
        // ── 1. Parse arguments ────────────────────────────────────────────────
        let result = CLIParser.parse(CommandLine.arguments)

        switch result {
        case .printVersion(let text):
            print(text)
            exit(ExitCode.success)

        case .printHelp(let text):
            print(text)
            exit(ExitCode.success)

        case .usageError(let message):
            fputs("moonswift: \(message)\n", stderr)
            exit(ExitCode.usage)

        case .projectCwd(let url):
            run(launchMode: resolveProjectMode(at: url))

        case .projectDirectory(let url):
            run(launchMode: resolveProjectMode(at: url))

        case .quickFile(let url):
            run(launchMode: .quickFile(url))
        }
    }
}

// MARK: - Main run path

/// Executes the full TUI startup sequence and enters the AppDriver loop.
///
/// This function does not return — it exits the process after teardown.
/// The exit code is determined by `AppDriver.run()` (Effect.quit carries it).
///
/// - Parameter launchMode: How the binary was invoked; forwarded to the seed
///   `AppState` so the reducer and renderer know the context from frame one.
private func run(launchMode: LaunchMode) {
    // ── 2. Install crash handlers ─────────────────────────────────────────────
    // Guarded no-ops until rffi_terminal_init sets the INITIALIZED atomic.
    // Installed first so no window exists between startup and terminal init
    // where a crash would corrupt the terminal without being caught.
    installCrashHandlers()

    // ── 3. Load project file ──────────────────────────────────────────────────
    // ProjectStore.load is synchronous; source loading is always asynchronous
    // (Effect.loadSources, dispatched after .appStarted by the AppDriver).
    // Main never calls SourceStore.
    let projectState = loadProject(for: launchMode)

    // ── 4. Initialise the terminal ────────────────────────────────────────────
    // Sets raw mode, switches to the alternate screen, hides the cursor.
    // After this call rffi_terminal_init has set the INITIALIZED atomic, so
    // the crash handlers installed above will actually restore the terminal.
    let terminal: Terminal
    do {
        terminal = try Terminal()
    } catch {
        fputs("moonswift: terminal init failed — \(error)\n", stderr)
        exit(ExitCode.software)
    }

    // ── 5. Build seed state and start the AppDriver ───────────────────────────
    let channel = EventChannel()
    let source = ShimEventSource()
    let pump = EventPump(source: source, channel: channel)
    let tickSource = TickSource(channel: channel)

    // The backend wraps the live Terminal. It owns Terminal.teardown() from
    // this point forward — Main.swift must not call teardown independently.
    let backend = RatatuiKitBackend(terminal: terminal)

    // The suspender also wraps the terminal for $EDITOR suspend/resume.
    let suspender = LiveTerminalSuspender(terminal: terminal)

    let seed = AppState(
        launch: launchMode,
        project: projectState,
        lintState: .initializing
    )

    let driver = AppDriver(
        channel: channel,
        pump: pump,
        tickSource: tickSource,
        suspender: suspender,
        backend: backend,
        seed: seed
    )

    // ── 6. Enter the loop ─────────────────────────────────────────────────────
    // AppDriver.run() blocks until Effect.quit is processed. The returned code
    // comes from the quit effect's exitCode payload (0 = normal quit, 70 =
    // internal error). Teardown (terminal restore) runs inside AppDriver.teardown()
    // via the RatatuiKitBackend — Main.swift does not call terminal.teardown().
    let code = driver.run()

    exit(code)
}

// MARK: - Launch mode resolution

/// Returns `.empty` when `directory` contains no `moonswift.toml`; otherwise `.project`.
///
/// This is the single decision point for empty-state detection (ux-spec §3.1, task 24).
/// When no project file is present the TUI opens in empty state offering the init form.
private func resolveProjectMode(at directory: URL) -> LaunchMode {
    let projectFile = directory.appendingPathComponent(ProjectStore.fileName)
    if FileManager.default.fileExists(atPath: projectFile.path) {
        return .project(directory)
    }
    return .empty
}

// MARK: - Project loading

/// Loads the project file for the given launch mode.
///
/// Returns a `ProjectState` ready to seed `AppState`. Source loading is
/// always deferred to the AppDriver loop via `Effect.loadSources`; this
/// function only reads the project file itself.
private func loadProject(for mode: LaunchMode) -> ProjectState {
    switch mode {
    case .quickFile:
        // Quick one-off: no project file. The seed state starts with no project;
        // the reducer's .appStarted handler creates a synthetic source entry.
        return .none

    case .empty:
        // Empty state: no project file yet (offered via the init form).
        return .none

    case .project(let directoryURL):
        // Project directory: load moonswift.toml.
        return projectState(from: ProjectStore.load(at: directoryURL))
    }
}

/// Maps a `ProjectStore.LoadResult` to the `ProjectState` enum used by the
/// seed `AppState`. The mapping is one-to-one; no logic beyond translation.
private func projectState(from result: ProjectStore.LoadResult) -> ProjectState {
    switch result {
    case .loaded(let file, let diagnostics):
        return .loaded(file, diagnostics: diagnostics)

    case .malformed(let diagnostic):
        return .malformed(diagnostic)

    case .unsupportedVersion(let file, let diagnostics):
        // Unsupported Lua version degrades to read-only; the reducer treats this
        // as a loaded-but-limited state (run/lint disabled, UX §3.7).
        return .loaded(file, diagnostics: diagnostics)
    }
}
