// File: Sources/moonswift/ShimEventSource.swift
// Location: Sources/moonswift/
// Role: Production conformance of `EventSource` that delegates to the
//       RatatuiKit `pollEvent(timeout:pumpThread:)` free function. Lives in
//       the executable target so the test targets (which link no FFI shim)
//       can use the `ScriptedEventSource` stub instead without breaking builds.
// Upstream: RatatuiKit (pollEvent, Event, Thread)
// Downstream: EventPump (receives this as its `EventSource` dependency)
//
// Architecture note: the protocol seam lives in `MoonSwiftTUI` so that
// `MoonSwiftTUITests` can inject `ScriptedEventSource` without linking the
// shim. The production implementation belongs here because only the
// executable target is allowed to link both `MoonSwiftTUI` and `RatatuiKit`.
// (ARCHITECTURE.md §5.1, §5.2; dependency rule: moonswift → MoonSwiftTUI
// → MoonSwiftCore; moonswift also imports RatatuiKit for the shim wiring.)

import Foundation
import MoonSwiftTUI
import RatatuiKit

// MARK: - ShimEventSource

/// An `EventSource` that polls the CRatatuiFFI shim for terminal events.
///
/// Each call to `next(timeout:)` delegates to `pollEvent(timeout:pumpThread:)`
/// from `RatatuiKit`. The function is input-class (EventPump thread only); the
/// shim asserts this in debug builds.
///
/// This type is `@unchecked Sendable` because it carries no mutable state —
/// every call is stateless, forwarding directly to the C shim. The Sendable
/// conformance is needed because `EventPump` stores its source as
/// `any EventSource` which is `Sendable`.
final class ShimEventSource: EventSource, @unchecked Sendable {

    /// Creates a `ShimEventSource`. No state to initialise.
    init() {}

    /// Poll the terminal shim for the next event.
    ///
    /// Blocks for at most `timeout`, then returns `nil` on elapsed time or
    /// the decoded `Event` on success. Throws `FFIError` on an I/O error.
    ///
    /// Thread class: input-class — must be called from the EventPump thread.
    func next(timeout: Duration) throws -> Event? {
        // Pass the current thread as the pump thread for the debug assertion.
        // This is always called from the pump thread; the assertion in
        // assertInputClass verifies it in debug builds (ARCHITECTURE.md §5.2).
        return try pollEvent(timeout: timeout, pumpThread: Thread.current)
    }
}
