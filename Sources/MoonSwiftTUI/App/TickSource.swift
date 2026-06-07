// File: Sources/MoonSwiftTUI/App/TickSource.swift
// Location: MoonSwiftTUI/App/
// Role: AppDriver-owned thread that posts .tick events at the armed interval.
//       Armed and disarmed by the AppDriver when it executes Effect.startTick
//       and Effect.stopTick returned by the reducer. startTick ALWAYS replaces
//       the current interval (ARCHITECTURE.md §3b, §5.1).
// Upstream: EventChannel (posts .tick into it)
// Downstream: AppDriver (arms/disarms via arm(interval:) / disarm())

import Foundation

// MARK: - TickSource

/// Delivers `.tick` events to the `EventChannel` at the armed interval.
///
/// Lifecycle:
/// - Created by the `AppDriver`; runs its own `Thread` immediately.
/// - Initially disarmed — no ticks are posted until `arm(interval:)`.
/// - `arm(interval:)` always replaces the current interval; calling it while
///   already armed is safe and changes the rate immediately.
/// - `disarm()` stops ticking until the next `arm(interval:)` call.
/// - `stop()` terminates the background thread permanently (called on quit).
///
/// Thread safety: all mutable state is guarded by an `NSCondition`. The
/// background thread sleeps on the condition and wakes on arm/disarm/stop
/// signals or at the interval boundary, whichever comes first.
///
/// `@unchecked Sendable` because the internal state is protected by an
/// `NSCondition`; the Swift compiler cannot verify this automatically.
public final class TickSource: @unchecked Sendable {

    // MARK: Internal state

    private enum State {
        case disarmed
        case armed(interval: Duration)
        case stopped
    }

    private var state: State = .disarmed
    private let condition = NSCondition()
    private let channel: EventChannel

    // MARK: Init

    /// Creates and starts the TickSource background thread.
    ///
    /// - Parameter channel: The `EventChannel` that `.tick` events are posted into.
    public init(channel: EventChannel) {
        self.channel = channel
        let thread = Thread(target: self, selector: #selector(runLoop), object: nil)
        thread.name = "moonswift.tick-source"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: AppDriver API (UI thread)

    /// Arm the tick source at the given interval, replacing any existing interval.
    ///
    /// - Parameter interval: The tick period. Must be positive.
    public func arm(interval: Duration) {
        condition.lock()
        state = .armed(interval: interval)
        condition.signal()
        condition.unlock()
    }

    /// Stop ticking. The background thread sleeps until the next `arm(interval:)`.
    public func disarm() {
        condition.lock()
        state = .disarmed
        condition.signal()
        condition.unlock()
    }

    /// Permanently terminate the background thread. Called by the AppDriver
    /// before `exit()` to avoid a dangling thread after the process tears down.
    public func stop() {
        condition.lock()
        state = .stopped
        condition.signal()
        condition.unlock()
    }

    // MARK: Background thread loop

    @objc private func runLoop() {
        condition.lock()
        defer { condition.unlock() }

        while true {
            switch state {
            case .stopped:
                return

            case .disarmed:
                // No interval active — wait indefinitely for a state change.
                condition.wait()

            case .armed(let interval):
                // Convert Duration to a TimeInterval (seconds as Double).
                let seconds =
                    Double(interval.components.seconds)
                    + Double(interval.components.attoseconds) / 1e18

                // Wait for the interval or until a state-change signal wakes us.
                let didTimeout = !condition.wait(until: Date(timeIntervalSinceNow: seconds))

                // Re-read state after waking — it may have changed while we slept.
                if case .armed = state, didTimeout {
                    // The interval elapsed and we are still armed — post the tick.
                    // Unlock briefly around the post to avoid holding the lock
                    // while EventChannel takes its own lock.
                    condition.unlock()
                    channel.post(.tick)
                    condition.lock()
                }
            // If we woke due to a signal (arm/disarm/stop), loop and recheck.
            }
        }
    }
}
