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

        Task { [channel] in
            let (sessionID, outcome) = await engine.runForDebug(
                fragment,
                breakpoints: breakpoints,
                onPause: { snapshot in
                    channel.post(.debugPaused(snapshot))
                },
                onResumed: { id in
                    // Posted once per advancing step/continue (ARCH-07). The
                    // session id arrives directly (CR-009) — no shared box bridges
                    // it from `onPause`, so an `onResumed` without a prior
                    // `onPause` can no longer silently drop `.debugResumed`.
                    channel.post(.debugResumed(id))
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

    // MARK: Effect.requestGlobals

    /// Execute `Effect.requestGlobals(sessionID)` — F6.3 `g` globals capture.
    ///
    /// Latches a globals-capture request on the live session via the engine's
    /// nonisolated `requestGlobals` path (PERF-11 — same no-async-hop reasoning
    /// as `sendDebugCommand`: the executor is parked in the paused `runForDebug`
    /// block). The mailbox's two-predicate wake services the latch in-place; the
    /// adapter republishes a snapshot carrying `globals`, which returns as a fresh
    /// `AppEvent.debugPaused`. Stale id → silent no-op (ARCH-06).
    func executeRequestGlobals(_ sessionID: DebugSessionID) {
        sessionEngine?.requestGlobals(sessionID)
    }
}
