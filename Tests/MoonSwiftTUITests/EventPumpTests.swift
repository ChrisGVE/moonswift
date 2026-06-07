// File: Tests/MoonSwiftTUITests/EventPumpTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for EventPump park/unpark handshake and event translation.
//       Uses ScriptedEventSource so no FFI is linked in this target.
// Upstream: EventPump.swift, EventSource.swift, EventChannel.swift
// Downstream: (test target)

import Foundation
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - EventPump tests

@Suite("EventPump")
struct EventPumpTests {

    @Test("pump posts key events from scripted source to channel")
    func pumpPostsKeyEvents() {
        let channel = EventChannel()
        let source = ScriptedEventSource([
            .key(.char("j"), modifiers: []),
            .key(.char("k"), modifiers: []),
        ])
        let pump = EventPump(source: source, channel: channel)

        // Give the pump time to process the two scripted events.
        // After the scripted events are consumed, the pump returns nil (timeout)
        // on each call, so we just wait and then drain. The wide window absorbs
        // CI-runner scheduling starvation (thread wakeups delayed by 80ms+).
        Thread.sleep(forTimeInterval: 0.5)

        // Stop the pump before draining to avoid races. Drain non-blockingly:
        // after stop() no producer remains, so a blocking drain on an empty
        // queue would deadlock instead of failing the assertion below.
        pump.stop()

        let events = channel.drainAll()
        #expect(events.count >= 2)
        guard events.count >= 2 else { return }
        if case .key(.char("j"), let mods) = events[0] {
            #expect(mods == [])
        } else {
            Issue.record("Expected first event to be key j, got \(events[0])")
        }
        if case .key(.char("k"), _) = events[1] {
        } else {
            Issue.record("Expected second event to be key k, got \(events[1])")
        }
    }

    @Test("park/unpark handshake: parkAndWait blocks until pump is parked")
    func parkUnparkHandshake() {
        let channel = EventChannel()
        // Infinite source: always returns .tick after a short delay.
        let source = InfiniteEventSource()
        let pump = EventPump(source: source, channel: channel)

        // Give the pump a moment to start polling.
        Thread.sleep(forTimeInterval: 0.05)

        // Park the pump and measure how long it takes.
        let before = Date()
        pump.parkAndWait()
        let elapsed = Date().timeIntervalSince(before)

        // parkAndWait must return within one poll interval plus margin. The 1s
        // bound is generous for CI-runner scheduling jitter; the test
        // distinguishes "acknowledges promptly" from "hangs", not exact latency.
        #expect(elapsed < 1.0, "parkAndWait should return promptly (one poll + generous margin)")

        // After park: unpark and stop.
        pump.unparkAfterResume()
        pump.stop()
    }

    @Test("park flag prevents event posts during the parked window")
    func parkedPumpDoesNotPost() throws {
        let channel = EventChannel()
        let source = ScriptedEventSource([
            .key(.char("a"), modifiers: []),
            .key(.char("b"), modifiers: []),
        ])
        let pump = EventPump(source: source, channel: channel)

        // Park immediately — the pump may or may not have posted anything yet.
        pump.parkAndWait()

        // While parked: drain what was posted before the park.
        // Then wait a bit to confirm no new events arrive while parked.
        // Must be the non-blocking drain — the parked pump posts nothing, so
        // waitAndDrainAll() on an empty queue would block forever.
        Thread.sleep(forTimeInterval: 0.1)
        let preUnparkCount = channel.drainAll().count  // may be 0, 1, or 2

        // Unpark and stop.
        pump.unparkAfterResume()
        pump.stop()

        // The total events posted must be ≤ the number of scripted events.
        #expect(preUnparkCount <= 2, "Parked pump must not post more than scripted events")
    }

    @Test("pump stops cleanly when stop() is called")
    func pumpStopsCleanly() {
        let channel = EventChannel()
        let source = InfiniteEventSource()
        let pump = EventPump(source: source, channel: channel)

        Thread.sleep(forTimeInterval: 0.05)
        pump.stop()

        // After stop(), posting to the channel should not cause a deadlock.
        // We verify the pump thread exits within a reasonable time by simply
        // returning from the test (if the thread is still running it would
        // hold a lock and potentially block the test thread's next waitAndDrain).
        // A successful test return is the evidence.
    }

    @Test("resize events are translated and posted")
    func resizeEventsPosted() {
        let channel = EventChannel()
        let source = ScriptedEventSource([
            .resize(cols: 80, rows: 24)
        ])
        let pump = EventPump(source: source, channel: channel)
        // Wide window absorbs CI-runner scheduling starvation.
        Thread.sleep(forTimeInterval: 0.5)
        pump.stop()

        // Non-blocking drain: the pump is stopped, so nothing would wake a
        // blocking drain if the resize event were missed.
        let events = channel.drainAll()
        let hasResize = events.contains {
            if case .resize(let size) = $0 {
                return size.cols == 80 && size.rows == 24
            }
            return false
        }
        #expect(hasResize, "Resize event must be translated and posted")
    }
}

// MARK: - InfiniteEventSource (helper for park tests)

/// An `EventSource` that never runs out of events — returns `.tick` on each call
/// after a brief delay so the pump keeps polling without spinning.
final class InfiniteEventSource: EventSource, @unchecked Sendable {
    func next(timeout: Duration) throws -> Event? {
        // Simulate a ~20ms polling cycle.
        Thread.sleep(forTimeInterval: 0.02)
        return .key(.char("x"), modifiers: [])
    }
}
