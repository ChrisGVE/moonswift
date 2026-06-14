// File: Sources/MoonSwiftCore/Debug/DebugCommandMailbox.swift
// Location: MoonSwiftCore/Debug/
// Role: The one blocking primitive in the debugger (PRD §4.5). A single-slot
//       mailbox on an NSCondition where the VM thread parks during a pause and
//       the AppDriver thread delivers the user's next command. Owned by the
//       reference-typed `DebugSession` inside the `SessionEngine`; NEVER stored
//       in the `Sendable` value-type `AppState` (IMPL-02 / ARCH-04).
//
//       F5.0 defines the full primitive (it is foundational — `DebugSession`
//       owns one). F6.0's hook adapter is the VM-side consumer that calls
//       `take()` and the AppDriver is the producer that calls `put(_:)` /
//       `signalGlobals()`.
//
// ## Two-predicate wake (ARCH-08 / DOM-09)
//
// On each NSCondition wake `take()` checks, in order: (1) a filled command slot
// → returns `.command`; (2) a pending globals latch → returns `.serviceGlobals`
// (consuming the latch); else it re-waits. The globals path therefore wakes the
// parked VM thread WITHOUT enqueuing a `LuaDebugCommand` — there is no command
// that means "capture globals, do not advance", so the latch is a separate
// predicate. The VM services the globals in place and re-parks without advancing
// (DOM-08).
//
// ## Latch placement (correctness note)
//
// The globals-requested boolean lives INSIDE the mailbox, guarded by the same
// NSCondition that guards the command slot. The PRD describes it as the owning
// `DebugSession`'s "globalsRequested latch"; physically it is co-located with
// the slot so the wait predicate and the wake are serialised by one mutex (a
// latch guarded by a different lock would admit a lost-wakeup). `DebugSession`
// sets it via `signalGlobals()` and observes it via `globalsRequestedSnapshot`.
//
// Upstream: LuaSwift (LuaDebugCommand)
// Downstream: DebugSession (owns one), F6.0 DebugHookAdapter (VM consumer),
//             AppDriver+DebugEffects (producer)

import Foundation
import LuaSwift

/// Single-slot, NSCondition-guarded command mailbox for VM-thread park/resume.
///
/// `@unchecked Sendable`: every field is accessed only under `condition`'s lock,
/// which Swift 6 strict concurrency cannot see; the `NSCondition` IS the
/// synchronisation mechanism (mirrors the documented lock-guarded patterns in
/// `RunService` / `LintService`).
public final class DebugCommandMailbox: @unchecked Sendable {

    /// What a parked `take()` woke up to deliver.
    public enum Wake: Sendable {
        /// A user command is ready; resume the VM accordingly.
        case command(LuaDebugCommand)
        /// The user requested globals; capture them in place and re-park
        /// WITHOUT advancing the VM.
        case serviceGlobals
    }

    /// SEC-01 watchdog ceiling: a pause that is never resumed within this window
    /// auto-resolves to `.command(.stop)` so a wedged session cannot park the VM
    /// thread forever. This is the production default; a session uses its
    /// instance `timeout` (see `init(timeout:)`).
    public static let takeTimeout: Duration = .seconds(300)

    /// Guards `slot` and `globalsRequested`. Also the park/wake primitive.
    private let condition = NSCondition()
    /// The single pending command, or `nil` when empty.
    private var slot: LuaDebugCommand?
    /// The pending globals-capture latch (the DebugSession "globalsRequested").
    private var globalsRequested = false
    /// The SEC-01 ceiling for THIS mailbox. Production uses `takeTimeout`; a
    /// short value is injectable for the watchdog test (CR-015).
    private let timeout: Duration

    public init() { self.timeout = Self.takeTimeout }

    /// Test hook (CR-015): inject a short watchdog ceiling so the SEC-01 timeout
    /// path is reachable without a 300 s wait. NOT for production use.
    init(timeout: Duration) { self.timeout = timeout }

    // MARK: - Producer side (AppDriver thread)

    /// Deliver a command to the parked VM thread.
    ///
    /// Sets the slot and signals the condition. Called directly (cross-thread)
    /// from the `nonisolated` command-delivery path — safe because all access is
    /// under `condition` (PERF-11).
    public func put(_ command: LuaDebugCommand) {
        condition.lock()
        slot = command
        condition.signal()
        condition.unlock()
    }

    /// Set the globals latch and wake the parked VM thread to service it.
    ///
    /// No command is enqueued; the wake returns `.serviceGlobals` and the VM
    /// does not advance.
    public func signalGlobals() {
        condition.lock()
        globalsRequested = true
        condition.signal()
        condition.unlock()
    }

    /// Non-blocking read of the globals latch, for `DebugSession` / tests.
    public var globalsRequestedSnapshot: Bool {
        condition.lock()
        defer { condition.unlock() }
        return globalsRequested
    }

    // MARK: - Consumer side (VM thread)

    /// The absolute SEC-01 deadline for a pause cycle that starts now.
    ///
    /// The VM-side park loop computes this ONCE per pause and passes it to every
    /// `take(until:)`. Computing it per `take()` call instead would reset the
    /// ceiling on each globals-servicing hop, so a flood of `g` requests
    /// (faster than once per `timeout`) could keep a wedged session parked
    /// forever — the bug CR-008 fixes. The deadline must be derived outside the
    /// re-park loop precisely so it bounds the WHOLE pause, not each hop.
    func pauseDeadline() -> Date {
        let seconds =
            Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        return Date(timeIntervalSinceNow: seconds)
    }

    /// Park the VM thread until a command arrives, a globals request arrives, or
    /// the supplied absolute `deadline` elapses.
    ///
    /// Two-predicate wake (command slot first, then globals latch). On timeout
    /// returns `.command(.stop)` so the VM tears the session down rather than
    /// parking indefinitely (SEC-01). The caller supplies one per-pause deadline
    /// so repeated globals-servicing wakes share a single ceiling (CR-008).
    public func take(until deadline: Date) -> Wake {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let command = slot {
                slot = nil
                return .command(command)
            }
            if globalsRequested {
                globalsRequested = false
                return .serviceGlobals
            }
            if !condition.wait(until: deadline) {
                // Watchdog elapsed with neither predicate satisfied.
                return .command(.stop)
            }
        }
    }

    /// Convenience single-park `take` with a fresh SEC-01 deadline. A multi-hop
    /// park loop (the VM-side adapter) MUST instead call `take(until:)` with a
    /// per-pause deadline so globals hops cannot reset the ceiling (CR-008).
    public func take() -> Wake { take(until: pauseDeadline()) }
}
