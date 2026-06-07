// File: Sources/MoonSwiftTUI/App/EventChannel.swift
// Location: MoonSwiftTUI/App/
// Role: Thread-safe MPSC queue carrying AppEvents from any producer thread
//       (EventPump, TickSource, service callbacks) to the single UI thread.
//       Implements the waitAndDrainAll contract from ARCHITECTURE.md §5.1:
//       blocks until at least one event is queued, then returns all of them.
// Upstream: AppEvent (the queued type)
// Downstream: AppDriver (calls waitAndDrainAll on the UI thread),
//             EventPump / TickSource / service callbacks (call post on any thread)

import Foundation
import MoonSwiftCore

// MARK: - EventChannel

/// The single conduit of `AppEvent` values into the Elm-style loop.
///
/// Any thread may call `post(_:)`. The UI thread calls `waitAndDrainAll()`
/// which blocks until at least one event is available, then returns every
/// queued event in FIFO order per producer (cross-producer ordering is
/// unspecified per the architecture contract).
///
/// Implementation: a mutex-guarded FIFO array and a condition variable.
/// A spurious wake with an empty queue re-blocks — the loop is provably idle
/// between events and never spins (ARCHITECTURE.md §5.1).
///
/// `@unchecked Sendable` because the internal state is protected by an
/// `NSLock`-backed mutex; the Swift compiler cannot verify this automatically.
public final class EventChannel: @unchecked Sendable {

    // MARK: Internal state

    private var queue: [AppEvent] = []
    private let condition = NSCondition()

    // MARK: Init

    public init() {}

    // MARK: Producer API (any thread)

    /// Enqueue an event. Safe to call from any thread or concurrency context.
    ///
    /// The UI thread is woken if it is currently blocking in `waitAndDrainAll`.
    public func post(_ event: AppEvent) {
        condition.lock()
        queue.append(event)
        condition.signal()
        condition.unlock()
    }

    // MARK: Consumer API (UI thread only)

    /// Block until at least one event is queued, then return all queued events.
    ///
    /// Contract (ARCHITECTURE.md §5.1):
    /// - Blocks until ≥ 1 event is available (no busy-wait, no spinning).
    /// - Returns **all** currently queued events in enqueue order.
    /// - A spurious wake with an empty queue re-blocks (the loop calls this
    ///   at the top of every iteration, so a spurious wake is harmless).
    /// - FIFO ordering is guaranteed per producer only; cross-producer ordering
    ///   is unspecified — the reducer must tolerate any interleaving.
    ///
    /// Must be called from the UI thread only. No assertion is made here
    /// because `EventChannel` has no direct reference to the UI thread; the
    /// AppDriver is responsible for calling this exclusively from its own thread.
    public func waitAndDrainAll() -> [AppEvent] {
        condition.lock()
        defer { condition.unlock() }

        // Re-block on spurious wakes with an empty queue.
        while queue.isEmpty {
            condition.wait()
        }

        // Drain the entire queue atomically under the lock.
        let drained = queue
        queue.removeAll(keepingCapacity: true)
        return drained
    }

    /// Return all queued events immediately without blocking.
    ///
    /// Unlike `waitAndDrainAll()`, an empty queue yields an empty array instead
    /// of blocking. Intended for teardown paths and tests that must assert on
    /// the *absence* of events — a blocking drain would deadlock there because
    /// no producer is left to wake the consumer.
    public func drainAll() -> [AppEvent] {
        condition.lock()
        defer { condition.unlock() }
        let drained = queue
        queue.removeAll(keepingCapacity: true)
        return drained
    }
}
