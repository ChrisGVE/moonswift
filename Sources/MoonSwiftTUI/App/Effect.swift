// File: Sources/MoonSwiftTUI/App/Effect.swift
// Location: MoonSwiftTUI/App/
// Role: Enumerates every impure action the reducer may request. Effects are
//       the sole exit from purity: the reducer returns them; the AppDriver
//       executes them. Nothing impure happens inside reduce() or render().
//       Signatures match ARCHITECTURE.md §5.1 exactly.
// Upstream: MoonSwiftCore (LuaSourceFragment, SourceID, RunConfig), AppEvent
// Downstream: AppDriver (executes), Reducer (returns), TickSource (driven by
//             startTick/stopTick)

import Foundation
import MoonSwiftCore

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
    case saveDesignations([FieldDesignation])

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
}
