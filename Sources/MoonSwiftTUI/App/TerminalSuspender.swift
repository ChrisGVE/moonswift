// File: Sources/MoonSwiftTUI/App/TerminalSuspender.swift
// Location: MoonSwiftTUI/App/
// Role: Protocol seam that decouples AppDriver from the real Terminal FFI calls
//       during $EDITOR suspend/resume. Production code passes a live Terminal
//       wrapped in LiveTerminalSuspender; tests inject a RecordingTerminalSuspender
//       that captures calls without touching the FFI shim.
//       Follows the EventSource-protocol precedent (EventSource.swift).
// Upstream: RatatuiKit.Terminal (production conformance)
// Downstream: AppDriver (consumes during spawnEditor effect)

import RatatuiKit

// MARK: - TerminalSuspender

/// Abstracts the render/terminal-class suspend and resume operations so that
/// the AppDriver's $EDITOR handshake can be tested without a real TTY or the
/// FFI shim.
///
/// The production conformance (`LiveTerminalSuspender`) delegates directly to
/// `RatatuiKit.Terminal.suspend()` and `Terminal.resume()`. Tests inject a
/// `RecordingTerminalSuspender` that records the call sequence without issuing
/// any FFI calls.
///
/// Thread class: render/terminal-class — both methods must be called from the
/// UI thread (the same constraint as the underlying `Terminal` methods).
public protocol TerminalSuspender: AnyObject {
    /// Leave the alternate screen and restore termios.
    ///
    /// Must be called with the EventPump already parked (ARCHITECTURE.md §5.2).
    /// - Throws: Any error from the underlying terminal operation.
    func suspend() throws

    /// Re-enter raw mode and the alternate screen.
    ///
    /// The caller unparks the EventPump after this returns.
    /// - Throws: Any error from the underlying terminal operation.
    func resume() throws
}

// MARK: - LiveTerminalSuspender

/// Production `TerminalSuspender` that delegates to a live `RatatuiKit.Terminal`.
///
/// Constructed by `AppDriver` in the real application. Holds a strong reference
/// to the `Terminal` instance to guarantee the handle stays valid across the
/// suspend/resume cycle.
public final class LiveTerminalSuspender: TerminalSuspender {

    private let terminal: Terminal

    /// Wraps the given terminal. The terminal must have been successfully
    /// initialized before this object is used.
    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    public func suspend() throws {
        try terminal.suspend()
    }

    public func resume() throws {
        try terminal.resume()
    }
}

// MARK: - RecordingTerminalSuspender

/// Test double that records suspend/resume calls without touching the FFI shim.
///
/// Inject this into `AppDriver` to verify the exact call sequence during
/// $EDITOR handshake tests. `throws` is supported: set `suspendError` or
/// `resumeError` to simulate FFI failures.
public final class RecordingTerminalSuspender: TerminalSuspender {

    // MARK: Recorded calls

    /// Append-only log of the operations that were called, in order.
    public private(set) var calls: [Operation] = []

    /// The operations the suspender can perform.
    public enum Operation: Equatable {
        case suspend
        case resume
    }

    // MARK: Configurable failures

    /// When non-nil, `suspend()` throws this error instead of recording the call.
    public var suspendError: Error?

    /// When non-nil, `resume()` throws this error instead of recording the call.
    public var resumeError: Error?

    public init() {}

    // MARK: TerminalSuspender

    public func suspend() throws {
        if let err = suspendError { throw err }
        calls.append(.suspend)
    }

    public func resume() throws {
        if let err = resumeError { throw err }
        calls.append(.resume)
    }
}
