// File: Sources/MoonSwiftCore/Run/SessionEngineProtocol.swift
// Location: MoonSwiftCore/Run/
// Role: The protocol seam for the long-lived session engine (PRD §4.3 / §F5.0).
//       A test double conforms to this so the reducer/AppDriver wiring and the
//       stale-id silent-no-op path can be exercised without a real LuaEngine.
//
// ## Data-flow contract (ARCH-03)
//
// The protocol deliberately mixes two flow shapes:
//   - `runForDebug` takes a `@Sendable (DebugSnapshot) -> Void` handler because
//     debug pauses are a STREAM published over the run's lifetime (matching the
//     RunService/LintService callback-injection style; the AppDriver is the sole
//     AppEvent-posting layer for all services).
//   - `startSession` / `invokeLuaCall` / `liveState` / `endSession` return async
//     because each is a SINGLE request/response the AppDriver wraps into one
//     AppEvent.
//
// ## Threading (PERF-11)
//
// The three command-delivery methods (`sendDebugCommand` / `requestPause` /
// `requestGlobals`) are `nonisolated` (NOT `async`): the serial executor is
// occupied by the parked `runForDebug` block during a pause, so an
// executor-hopping `async` call would queue behind it and deadlock. They run on
// the caller's thread, resolve `id` under the engine's NSLock-guarded session
// registry, and call the live mailbox / atomics DIRECTLY. A stale `id` (session
// already torn down — an architecturally-guaranteed race, ARCH-06) is a SILENT
// no-op: never a trap, throw, or diagnostic.
//
// Upstream: RunConfig, MockStore, LuaSourceFragment, CoreRunOutcome,
//           DebugSnapshot, DebugSessionID, MockLiveState, LuaSwift (LuaValue,
//           LuaDebugCommand)
// Downstream: AppDriver effect handlers; SessionEngine (production impl); test
//             doubles.

import Foundation
import LuaSwift

// MARK: - SessionEngineError

/// Errors thrown by the session engine.
public enum SessionEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// An introspection / invocation call was made while the VM was executing
    /// (RunState != .idle). The LuaSwift-equivalent of `LuaError.enginePaused`
    /// for the MoonSwift service boundary (DOM-02).
    case enginePaused
    /// `startSession` could not create the underlying engine.
    case engineCreationFailed(String)
    /// A run/introspection method was called before `startSession`.
    case notStarted

    public var description: String {
        switch self {
        case .enginePaused:
            return "Session engine busy — the VM is executing; introspection and invocation are between-runs only"
        case .engineCreationFailed(let message):
            return "Failed to create session engine: \(message)"
        case .notStarted:
            return "Session engine not started — startSession has not been called"
        }
    }
}

// MARK: - SessionEngineProtocol

/// The long-lived session engine seam.
///
/// Conforming types are `Sendable` and confined to a serial executor; the UI
/// thread never touches `LuaEngine`. Results flow back to the loop only via
/// AppDriver-built `@Sendable` callbacks (ARCHITECTURE §5.1).
public protocol SessionEngineProtocol: Sendable {

    /// Create the session engine for `config` and install `mocks`.
    ///
    /// Establishes a long-lived engine (sandbox mode inherited from `config`,
    /// never hardcoded), captures the stdlib baseline for later user-global
    /// filtering, and prepares the mock store for the session. Must be called
    /// before any run/introspection method.
    func startSession(config: RunConfig, mocks: MockStore) async throws

    /// Run `fragment` in the long-lived engine and KEEP the engine alive
    /// afterward (CONS-R2-02). Distinct from `RunService`'s run-and-discard:
    /// `invokeLuaCall` / `liveState` see the post-run engine state. RunState is
    /// `.running` for the body, `.idle` after.
    func sessionRun(_ fragment: LuaSourceFragment) async -> CoreRunOutcome

    /// Run `fragment` for debugging, publishing each pause via `onPause`.
    ///
    /// Establishes a `DebugSession` (owning the live `DebugCommandMailbox`),
    /// returns its opaque `DebugSessionID` and the final outcome. The actual
    /// pause hook is installed by F6.0; in F5.0 this establishes the session
    /// lifecycle and runs the fragment.
    ///
    /// `onResumed` is called once per advancing command (`.stepOver`, `.stepInto`,
    /// `.stepOut`, `.continueRun`) — never for `.stop` or globals-only wakes
    /// (ARCH-07 / F6.2). It receives the resuming session's `DebugSessionID`
    /// directly (CR-009) so the AppDriver can post `AppEvent.debugResumed(id)`
    /// without bridging the id through a shared mutable box from `onPause`.
    func runForDebug(
        _ fragment: LuaSourceFragment,
        breakpoints: Set<Int>,
        onPause: @escaping @Sendable (DebugSnapshot) -> Void,
        onResumed: @escaping @Sendable (DebugSessionID) -> Void
    ) async -> (DebugSessionID, CoreRunOutcome)

    /// Deliver a debug command to the live session addressed by `id`. Stale id
    /// → silent no-op (ARCH-06).
    nonisolated func sendDebugCommand(_ id: DebugSessionID, _ command: LuaDebugCommand)

    /// Arm a pause request on the live session addressed by `id` (ARCH-05).
    /// Stale id → silent no-op.
    nonisolated func requestPause(_ id: DebugSessionID)

    /// Arm a globals-capture request on the live session addressed by `id`
    /// (ARCH-05). Stale id → silent no-op.
    nonisolated func requestGlobals(_ id: DebugSessionID)

    /// Cooperatively cancel the in-flight `sessionRun` (user `x` / cancel-run).
    /// Calls `requestCancellation()` on the running engine off the serial queue;
    /// a no-op when no run is in flight (ARCH-06-style silent no-op). #44.
    nonisolated func cancelRun()

    /// Evaluate a full Lua call expression against the surviving engine
    /// (RQ2: `evaluate("return \(callExpression)")`). The lint + target checks
    /// run in the AppDriver BEFORE this call (§F5.3); by here the expression is
    /// already syntax-valid and target-checked. Asserts RunState == .idle;
    /// throws `SessionEngineError.enginePaused` if called mid-run.
    func invokeLuaCall(_ callExpression: String) async throws -> LuaValue

    /// Snapshot the live engine's mock + user-global state (#21 introspection).
    /// Returns `MockLiveState.empty` mid-run (RunState gate, DOM-02); the real
    /// sweep runs only when RunState == .idle.
    func liveState() async -> MockLiveState

    /// Tear down the session engine and discard any live `DebugSession`.
    func endSession() async
}
