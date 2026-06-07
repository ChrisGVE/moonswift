// File: Sources/MoonSwiftTUI/App/EventPump.swift
// Location: MoonSwiftTUI/App/
// Role: Dedicated thread that polls the terminal event source with a 50 ms
//       timeout and posts decoded AppEvents to the EventChannel. Supports
//       park/unpark handshake for $EDITOR suspension. Implements EventSource
//       protocol so tests inject scripted events without the FFI shim.
// Upstream: EventSource (production: RatatuiKit.pollEvent; tests: scripted),
//           EventChannel (posts decoded AppEvents)
// Downstream: AppDriver (starts the pump; calls parkAndWait / unparkAfterResume
//             during $EDITOR handoff)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - EventPump

/// Polls a terminal event source on a dedicated thread and forwards decoded
/// `AppEvent` values to the `EventChannel`.
///
/// The pump runs a tight loop of: poll(50 ms timeout) → translate → post.
/// On `EINTR` the shim retries internally; the pump never observes it.
///
/// ### Park / Unpark handshake ($EDITOR suspension)
///
/// Before handing the terminal to `$EDITOR`, the AppDriver must guarantee
/// that no input-class shim call is in flight. The handshake:
///
/// 1. AppDriver calls `parkAndWait()`. This sets the park flag and blocks
///    until the pump acknowledges it has parked (≤ 50 ms poll boundary).
/// 2. AppDriver performs terminal teardown + spawns the editor + waits.
/// 3. AppDriver calls `unparkAfterResume()`. The pump resumes polling.
///
/// The two-condition-variable design guarantees — not merely makes likely —
/// that no input-class call is in flight when teardown begins.
/// (ARCHITECTURE.md §5.2 pump-park handshake)
///
/// `@unchecked Sendable` because all mutable state is guarded by
/// `NSCondition`; the Swift compiler cannot verify this automatically.
public final class EventPump: @unchecked Sendable {

    // MARK: State

    /// Guards all mutable fields: `parkRequested`, `parked`, `stopped`.
    private let condition = NSCondition()
    private var parkRequested: Bool = false
    private var parked: Bool = false
    private var stopped: Bool = false

    // MARK: Dependencies

    private let source: any EventSource
    private let channel: EventChannel

    /// The `Thread` object for this pump; set once the thread starts.
    /// Used by `RatatuiKit.pollEvent` to assert the input-class calling thread.
    private var thread: Thread?

    // MARK: Poll timeout

    /// Timeout passed to the event source on each poll iteration.
    /// 50 ms gives a responsive park boundary while keeping CPU use low.
    private static let pollTimeout: Duration = .milliseconds(50)

    // MARK: Init

    /// Creates and immediately starts the pump thread.
    ///
    /// - Parameters:
    ///   - source: The `EventSource` to poll (RatatuiKit in production; scripted in tests).
    ///   - channel: The `EventChannel` that decoded events are posted into.
    public init(source: any EventSource, channel: EventChannel) {
        self.source = source
        self.channel = channel

        let t = Thread(target: self, selector: #selector(runLoop), object: nil)
        t.name = "moonswift.event-pump"
        t.qualityOfService = .userInteractive
        t.start()

        condition.lock()
        thread = t
        condition.unlock()
    }

    // MARK: Park / Unpark API (UI thread)

    /// Ask the pump to park, then block until it acknowledges.
    ///
    /// Returns only after the pump has observed the flag and parked itself on
    /// its condition variable. The pump will park at its next poll boundary
    /// (≤ 50 ms). Once this returns, no input-class shim call is in flight.
    ///
    /// Must be called from the UI thread only.
    public func parkAndWait() {
        condition.lock()
        defer { condition.unlock() }

        parkRequested = true
        condition.signal()

        // Block until the pump confirms it is parked.
        while !parked {
            condition.wait()
        }
    }

    /// Unpark the pump after terminal resume completes.
    ///
    /// The pump resumes polling from its next loop iteration.
    /// Must be called from the UI thread only.
    public func unparkAfterResume() {
        condition.lock()
        parkRequested = false
        parked = false
        condition.signal()
        condition.unlock()
    }

    /// Request permanent termination of the pump thread.
    ///
    /// Called by the AppDriver during teardown. The pump exits at the next
    /// poll boundary (≤ 50 ms) and the thread terminates cleanly.
    public func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    // MARK: Background poll loop

    @objc private func runLoop() {
        // Thread.current is available here for future input-class assertions
        // (e.g. passing to RatatuiKit.pollEvent when the real EventSource
        //  implementation forwards to the shim). Not used by ScriptedEventSource.

        while true {
            // Check for park / stop requests at the top of every iteration.
            condition.lock()
            if stopped {
                condition.unlock()
                return
            }
            if parkRequested {
                // Signal the UI thread that we have parked.
                parked = true
                condition.signal()
                // Wait until the UI thread unparks us.
                while parkRequested && !stopped {
                    condition.wait()
                }
                if stopped {
                    condition.unlock()
                    return
                }
            }
            condition.unlock()

            // Poll the event source for up to 50 ms.
            let event: Event?
            do {
                event = try source.next(timeout: EventPump.pollTimeout)
            } catch {
                // I/O errors are rare (terminal closed, SIGHUP received).
                // Post a resize event with zero dimensions as a sentinel that
                // the AppDriver interprets as a fatal terminal error, then stop.
                channel.post(.resize(TerminalSize(cols: 0, rows: 0)))
                return
            }

            guard let event else {
                // Timeout — loop back to check park/stop flags.
                continue
            }

            // Translate the RatatuiKit Event into an AppEvent and post it.
            if let appEvent = AppEvent(from: event) {
                channel.post(appEvent)
            }
            // Unknown event kinds are silently dropped (forward compatibility).
        }
    }
}

// MARK: - AppEvent translation

extension AppEvent {

    /// Translates a decoded `RatatuiKit.Event` into an `AppEvent`.
    ///
    /// Returns `nil` for event kinds with no AppEvent counterpart (reserved for
    /// forward compatibility with new shim event kinds).
    fileprivate init?(from event: Event) {
        switch event {
        case .key(let code, let modifiers):
            self = .key(code, modifiers: modifiers)

        case .resize(let cols, let rows):
            self = .resize(TerminalSize(cols: cols, rows: rows))

        case .mouse(let kind, let button, let col, let row, let modifiers):
            self = .mouse(kind: kind, button: button, col: col, row: row, modifiers: modifiers)

        case .paste(let text):
            self = .paste(text)
        }
    }
}
