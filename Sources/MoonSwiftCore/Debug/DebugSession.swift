// File: Sources/MoonSwiftCore/Debug/DebugSession.swift
// Location: MoonSwiftCore/Debug/
// Role: One live debug session, owned by the `SessionEngine` (PRD §F5.0
//       "Mailbox + session ownership", IMPL-02 / ARCH-04). A reference type so
//       its live `DebugCommandMailbox` and atomics can be reached from the VM
//       thread (the parked `runForDebug` body) AND the AppDriver thread (command
//       delivery) without ever being copied into the `Sendable` value-type
//       `AppState` — which holds only an opaque `DebugSessionID`.
//
//       F5.0 scope: lifecycle + ownership + command routing. The VM-side
//       producer/consumer of the snapshot and globals (the debug hook adapter)
//       is F6.0 (#9); this type provides the storage and the routing seams it
//       drives. Breakpoints are fixed for the session lifetime (captured at
//       `runForDebug` start).
//
// Upstream: DebugCommandMailbox, DebugSnapshot, LuaSwift (LuaDebugCommand)
// Downstream: SessionEngine (owns the registry of these), F6.0 DebugHookAdapter

import Foundation
import LuaSwift

/// A live debug session.
///
/// `@unchecked Sendable`: the mutable `pauseRequested` / `currentSnapshot`
/// fields are guarded by `lock`, and the mailbox is itself `Sendable` and
/// internally synchronised. Swift 6 strict concurrency cannot see that `lock`
/// serialises access; the `NSLock` IS the synchronisation mechanism (mirrors
/// the documented lock-guarded patterns in `RunService` / `LintService`).
public final class DebugSession: @unchecked Sendable {

    /// The opaque handle held by `AppState` and used to address this session.
    public let id: DebugSessionID

    /// The live park/resume mailbox. Owned here; never copied into `AppState`.
    public let mailbox: DebugCommandMailbox

    /// The fragment-relative breakpoint lines, fixed for the session lifetime.
    public let breakpoints: Set<Int>

    /// Guards `pauseRequested` and `currentSnapshot`.
    private let lock = NSLock()
    /// Set by `requestPause()` (AppDriver thread), consumed by the F6.0 hook
    /// (VM thread) at its next safe checkpoint (ARCH-05).
    private var pauseRequested = false
    /// The latest published snapshot, for re-publication on the globals path
    /// and for "VM running… (showing last pause)" rendering.
    private var currentSnapshot: DebugSnapshot?

    public init(id: DebugSessionID = DebugSessionID(), breakpoints: Set<Int> = []) {
        self.id = id
        self.mailbox = DebugCommandMailbox()
        self.breakpoints = breakpoints
    }

    // MARK: - Command routing (called from the nonisolated command-delivery path)

    /// Deliver a user command to the parked VM thread.
    public func deliver(_ command: LuaDebugCommand) {
        mailbox.put(command)
    }

    /// Arm a pause request, to be honored at the VM's next safe checkpoint.
    public func requestPause() {
        lock.lock()
        pauseRequested = true
        lock.unlock()
    }

    /// Arm a globals-capture request and wake the parked VM thread to service it
    /// in place (no VM advance).
    public func requestGlobals() {
        mailbox.signalGlobals()
    }

    // MARK: - VM-side accessors (F6.0 hook)

    /// Read-and-clear the pause-request latch. Returns whether a pause was armed.
    public func consumePauseRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = pauseRequested
        pauseRequested = false
        return was
    }

    /// Non-blocking read of the globals latch.
    public var globalsRequested: Bool { mailbox.globalsRequestedSnapshot }

    // MARK: - Snapshot storage

    /// The latest published snapshot, or `nil` before the first pause.
    public var snapshot: DebugSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    /// Record a newly published snapshot.
    public func setSnapshot(_ snapshot: DebugSnapshot) {
        lock.lock()
        currentSnapshot = snapshot
        lock.unlock()
    }
}
