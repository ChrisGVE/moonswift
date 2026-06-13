// File: Sources/MoonSwiftTUI/App/AppDriver+DebugEffects.swift
// Location: MoonSwiftTUI/App/
// Role: AppDriver extension that executes P2 F6.1/F6.2 debug effects:
//       `Effect.debugRun`, `Effect.stopDebug`, `Effect.sendDebugCommand`.
//       All impure debug I/O lives here; the reducer (DebugReducer.swift) stays
//       pure. AppDriver is the sole layer that calls
//       `SessionEngineProtocol.runForDebug` and posts `AppEvent.debug*`
//       (ARCHITECTURE.md §5.1).
//
//       Threading note: `runForDebug` blocks the session engine's serial queue
//       until the run finishes (the VM thread parks at each pause). AppDriver
//       wraps it in a background `Task` — the same pattern as `executeRun` — so
//       the UI thread is never blocked. The `onPause` and `onResumed` callbacks
//       post to the EventChannel from whatever thread the VM parks on;
//       `EventChannel.post` is thread-safe by design.
//
//       Session engine ownership: the session engine (`SessionEngineProtocol`) is
//       the same engine used by `sessionRun` (F5.0). It is accessed here as a
//       stored property on `AppDriver`; see `AppDriver.swift` for the ownership
//       comment (the driver never holds the debug session object itself — IMPL-02).
//
// Upstream: AppDriver.swift (calls `executeDebugRun`, `executeStopDebug`,
//           `executeSendDebugCommand`),
//           SessionEngineProtocol (runForDebug, sendDebugCommand),
//           EventChannel (posts AppEvent.debugPaused / debugResumed / debugFinished)
// Downstream: Reducer.swift / DebugReducer.swift (consumes the posted events)

import Foundation
import LuaSwift
import MoonSwiftCore

// MARK: - AppDriver + Debug Effects

extension AppDriver {

    // MARK: Effect.debugRun

    /// Execute `Effect.debugRun(fragment, breakpoints:)`.
    ///
    /// Launches `runForDebug` on a background Task. The `onPause` closure is
    /// called on the VM thread (or whichever thread `DebugHookAdapter` parks on);
    /// it posts `AppEvent.debugPaused` via the `EventChannel`. After `runForDebug`
    /// returns, the Task posts `AppEvent.debugFinished`.
    ///
    /// The session engine is captured as `sessionEngine` (a stored property on
    /// `AppDriver`). If no session engine is injected (skeleton/test mode) this
    /// method posts a synthetic `debugFinished(.cancelled)` immediately.
    func executeDebugRun(_ fragment: LuaSourceFragment, breakpoints: Set<Int>) {
        guard let engine = sessionEngine else {
            // Skeleton: post a synthetic finish immediately so the reducer can
            // clear any pending state without hanging.
            let placeholderID = DebugSessionID()
            channel.post(.debugFinished(placeholderID, .cancelled))
            return
        }

        // A SessionIDBox lets the `onResumed` closure capture the session ID
        // before `runForDebug` returns it. The box is written once (from the
        // engine's queue, before any resume fires) and read many times (each
        // .stepOver/.continueRun). Class semantics make the capture safe across
        // the async boundary; the write happens-before the first read because the
        // DebugSession is registered before the VM thread starts.
        let sessionIDBox = SessionIDBox()

        Task { [channel] in
            let (sessionID, outcome) = await engine.runForDebug(
                fragment,
                breakpoints: breakpoints,
                onPause: { snapshot in
                    // First-pause: seed the box so onResumed can post correctly.
                    sessionIDBox.id = snapshot.sessionID
                    channel.post(.debugPaused(snapshot))
                },
                onResumed: {
                    // Posted once per advancing step/continue (ARCH-07).
                    // `onPause` is always called before `onResumed` for a given
                    // pause cycle, so `sessionIDBox.id` is always set here.
                    if let id = sessionIDBox.id {
                        channel.post(.debugResumed(id))
                    }
                }
            )
            channel.post(.debugFinished(sessionID, outcome))
        }
    }

    // MARK: Effect.stopDebug

    /// Execute `Effect.stopDebug(sessionID)`.
    ///
    /// Delivers a `.stop` command to the live session via `sendDebugCommand`.
    /// This is a nonisolated call — `sendDebugCommand` runs on the caller's
    /// thread and resolves the session ID under the engine's NSLock-guarded
    /// registry. A stale `id` (session already torn down) is a silent no-op
    /// (ARCH-06), so no guard is needed here.
    func executeStopDebug(_ sessionID: DebugSessionID) {
        sessionEngine?.sendDebugCommand(sessionID, .stop)
    }

    // MARK: Effect.sendDebugCommand

    /// Execute `Effect.sendDebugCommand(sessionID, command)` — F6.2 stepping.
    ///
    /// Delivers a `.stepOver`, `.stepInto`, `.stepOut`, `.continueRun`, or
    /// `.stop` command to the parked VM thread via the engine's nonisolated
    /// `sendDebugCommand` path (PERF-11 — no async hop, no executor contention).
    /// Stale id → silent no-op (ARCH-06).
    func executeSendDebugCommand(_ sessionID: DebugSessionID, _ command: LuaDebugCommand) {
        sessionEngine?.sendDebugCommand(sessionID, command)
    }
}

// MARK: - SessionIDBox (internal to this file)

/// A reference-typed wrapper for a `DebugSessionID` that is populated before
/// the first resume fires and remains stable for the run's lifetime.
///
/// Used by `executeDebugRun` to bridge the session ID from the `onPause`
/// callback (which has it first, from the snapshot) into the `onResumed`
/// callback (which needs it to post `AppEvent.debugResumed`). The class wrapper
/// is necessary because both closures are `@Sendable` — a shared reference is
/// the only way to write once and read from another `@Sendable` closure.
///
/// Thread safety: `id` is written from the VM thread inside `onPause`, and
/// read from the VM thread inside `onResumed`. Both callbacks fire on the same
/// VM thread (the serial queue that runs `runForDebug`), so no lock is needed.
final class SessionIDBox: @unchecked Sendable {
    var id: DebugSessionID?
}
