// File: Sources/MoonSwiftTUI/App/AppDriver.swift
// Location: MoonSwiftTUI/App/
// Role: The single impure component that owns the Elm-style loop. Drains the
//       EventChannel, calls reduce for each event, executes the returned
//       Effects, and triggers renders. Constructs all service callbacks so
//       that MoonSwiftCore services never see TUI types. Owns the TickSource
//       and coordinates with the EventPump for $EDITOR suspension.
//       (ARCHITECTURE.md §5.1, §3b)
// Upstream: EventChannel, TickSource, EventPump, Reducer, Renderer (stub),
//           MoonSwiftCore service protocols
// Downstream: Services (via callbacks), Terminal (render), process exit

import Foundation
import MoonSwiftCore

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

    // MARK: State

    private var state: AppState

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
    ///   - seed: The initial `AppState` built from the decoded project file.
    public init(
        channel: EventChannel,
        pump: EventPump,
        tickSource: TickSource,
        seed: AppState
    ) {
        self.channel = channel
        self.pump = pump
        self.tickSource = tickSource
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
            // Highlighter.highlight() — no-op in skeleton; empty spans.
            channel.post(.highlightReady(id, spans: []))

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

        case .spawnEditor:
            // Pump-park + terminal suspend + editor spawn + resume (ARCH §5.2).
            // Skeleton: no-op in this task (implemented in task F8a).
            break
        }
    }

    // MARK: Render

    /// Call the renderer with the current state. In the skeleton this is a
    /// no-op; the real renderer (task 14) issues RenderCommands to RatatuiKit.
    private func renderNow() {
        lastRenderTime = Date()
        // Renderer stub — implemented in task 14.
    }

    // MARK: Teardown

    /// Restore the terminal and shut down background threads.
    ///
    /// Called after the loop exits (after `quitCode` is set). The real
    /// terminal teardown (task 13 / RatatuiKit) is invoked here.
    private func teardown() {
        pump.stop()
        tickSource.stop()
        // Terminal.teardown() called here in the full implementation (task 13).
    }
}
