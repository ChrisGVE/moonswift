// File: Sources/MoonSwiftTUI/App/EventSource.swift
// Location: MoonSwiftTUI/App/
// Role: Protocol seam that lets tests inject scripted event sequences into the
//       EventPump without linking the FFI shim. The production EventPump
//       implements this protocol using RatatuiKit.pollEvent; tests inject a
//       ScriptedEventSource with a canned sequence of events.
// Upstream: RatatuiKit (Event — the terminal event type)
// Downstream: EventPump (uses EventSource to decouple itself from FFI calls)

import RatatuiKit

// MARK: - EventSource

/// A source of terminal events for the EventPump.
///
/// The production implementation calls `RatatuiKit.pollEvent(timeout:pumpThread:)`
/// against the real terminal. Test implementations return scripted events so
/// the full EventPump loop (including park/unpark handshake) can be exercised
/// with no FFI link in the test target (ARCHITECTURE.md §5.1).
///
/// The protocol is synchronous and blocking: `next(timeout:)` must block for
/// up to `timeout` then return. A `nil` return means the timeout elapsed;
/// a thrown error means an I/O failure.
public protocol EventSource: Sendable {

    /// Wait for the next event, blocking for at most `timeout`.
    ///
    /// - Returns: A decoded `Event`, or `nil` if the timeout elapsed.
    /// - Throws: Any I/O error that prevents polling (e.g. `FFIError`).
    func next(timeout: Duration) throws -> Event?
}

// MARK: - ScriptedEventSource

/// An `EventSource` backed by a fixed sequence of events, for use in tests.
///
/// Events are returned one-by-one in the order they were supplied. After the
/// sequence is exhausted, `next(timeout:)` returns `nil` (simulating a
/// timeout) on each subsequent call. This lets tests drive the pump for
/// a known number of steps then let it idle.
///
/// Thread safety: `ScriptedEventSource` is `@unchecked Sendable` because its
/// mutable index is accessed only from the single pump thread — the same
/// invariant the real pump upholds for its `EventSource` reference.
public final class ScriptedEventSource: EventSource, @unchecked Sendable {

    private var events: [Event]
    private var index: Int = 0

    /// Creates a scripted source that will emit the given events in order.
    public init(_ events: [Event]) {
        self.events = events
    }

    /// Returns the next scripted event, or `nil` when the sequence is exhausted.
    public func next(timeout: Duration) throws -> Event? {
        guard index < events.count else { return nil }
        let event = events[index]
        index += 1
        return event
    }
}
