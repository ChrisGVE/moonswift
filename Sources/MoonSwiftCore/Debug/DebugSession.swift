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
import os

/// A live debug session.
///
/// `@unchecked Sendable`: the mutable `pauseRequested` / `currentSnapshot`
/// fields are guarded by `state` (an `OSAllocatedUnfairLock`), and the mailbox
/// is itself `Sendable` and internally synchronised. Swift 6 strict concurrency
/// cannot see that the lock serialises access; the lock IS the synchronisation
/// mechanism (mirrors the documented lock-guarded patterns in `RunService` /
/// `LintService`).
///
/// CR-025: the latch is read once per `.line` event in breakpoint mode (the
/// VM-hook hot path), so the lighter `os_unfair_lock` is used in place of
/// `NSLock` — uncontended acquisition is a handful of nanoseconds, keeping the
/// per-line mutex cost negligible while preserving cross-thread safety (the
/// pause request is armed on the AppDriver thread, consumed on the VM thread).
public final class DebugSession: @unchecked Sendable {

    /// The lock-guarded mutable state: the pause-request latch and the latest
    /// published snapshot. Bundled under one `os_unfair_lock` so a `.line`-event
    /// latch read is a single cheap acquisition.
    private struct MutableState {
        var pauseRequested = false
        var currentSnapshot: DebugSnapshot?
    }

    /// The opaque handle held by `AppState` and used to address this session.
    public let id: DebugSessionID

    /// The live park/resume mailbox. Owned here; never copied into `AppState`.
    public let mailbox: DebugCommandMailbox

    /// The fragment-relative breakpoint lines, fixed for the session lifetime.
    public let breakpoints: Set<Int>

    /// Guards `pauseRequested` and `currentSnapshot` (see `MutableState`).
    /// `pauseRequested` is set by `requestPause()` (AppDriver thread) and
    /// consumed by the F6.0 hook (VM thread) at its next safe checkpoint
    /// (ARCH-05); `currentSnapshot` is the latest published snapshot, for
    /// re-publication on the globals path and "VM running… (showing last
    /// pause)" rendering.
    private let state = OSAllocatedUnfairLock(initialState: MutableState())

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
        state.withLock { $0.pauseRequested = true }
    }

    /// Arm a globals-capture request and wake the parked VM thread to service it
    /// in place (no VM advance).
    public func requestGlobals() {
        mailbox.signalGlobals()
    }

    // MARK: - VM-side accessors (F6.0 hook)

    /// Read-and-clear the pause-request latch. Returns whether a pause was armed.
    public func consumePauseRequested() -> Bool {
        state.withLock {
            let was = $0.pauseRequested
            $0.pauseRequested = false
            return was
        }
    }

    /// Non-blocking read of the globals latch.
    public var globalsRequested: Bool { mailbox.globalsRequestedSnapshot }

    // MARK: - Snapshot storage

    /// The latest published snapshot, or `nil` before the first pause.
    public var snapshot: DebugSnapshot? {
        state.withLock { $0.currentSnapshot }
    }

    /// Record a newly published snapshot.
    public func setSnapshot(_ snapshot: DebugSnapshot) {
        state.withLock { $0.currentSnapshot = snapshot }
    }
}
