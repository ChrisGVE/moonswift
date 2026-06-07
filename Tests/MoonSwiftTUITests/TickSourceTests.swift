// File: Tests/MoonSwiftTUITests/TickSourceTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for TickSource — arm/disarm lifecycle, interval replacement, and
//       flood guard via the AppDriver. No FFI linked.
// Upstream: TickSource.swift, EventChannel.swift
// Downstream: (test target)

import Foundation
import Testing

@testable import MoonSwiftTUI

// MARK: - TickSource tests

@Suite("TickSource")
struct TickSourceTests {

    @Test("armed TickSource posts tick events at the given interval")
    func armedTickPosts() {
        let channel = EventChannel()
        let tick = TickSource(channel: channel)

        // Arm at a short interval for testing.
        tick.arm(interval: .milliseconds(50))

        // Wait long enough for at least two ticks.
        Thread.sleep(forTimeInterval: 0.15)

        tick.stop()

        // Drain non-blockingly: if the TickSource posted nothing, a blocking
        // drain would deadlock instead of failing the assertion below.
        let events = channel.drainAll()
        let tickCount = events.filter {
            if case .tick = $0 { return true }
            return false
        }.count
        #expect(tickCount >= 2, "Armed TickSource must post ≥ 2 ticks in 150ms at 50ms interval")
    }

    @Test("disarmed TickSource stops posting ticks")
    func disarmedTickStops() {
        let channel = EventChannel()
        let tick = TickSource(channel: channel)

        // Arm briefly, then disarm.
        tick.arm(interval: .milliseconds(40))
        Thread.sleep(forTimeInterval: 0.05)
        tick.disarm()

        // Drain any events accumulated before disarm (non-blocking — there may
        // be none if no tick fired in the brief armed window).
        _ = channel.drainAll()

        // Wait another window — no new ticks should arrive.
        Thread.sleep(forTimeInterval: 0.1)
        tick.stop()

        // The channel should be empty (or have only ticks from the very brief
        // race window around disarm — we accept up to 1).
        // We post a sentinel then drain: if only the sentinel appears, the tick
        // was cleanly stopped.
        channel.post(.appStarted)
        let events = channel.waitAndDrainAll()
        let ticksAfterDisarm = events.filter {
            if case .tick = $0 { return true }
            return false
        }.count
        #expect(ticksAfterDisarm <= 1, "Disarmed TickSource must not post ticks (at most 1 race tick accepted)")
    }

    @Test("startTick always replaces the current interval")
    func startTickReplacesInterval() {
        let channel = EventChannel()
        let tick = TickSource(channel: channel)

        // Arm at 200ms, then immediately replace with 50ms.
        tick.arm(interval: .milliseconds(200))
        Thread.sleep(forTimeInterval: 0.01)
        tick.arm(interval: .milliseconds(50))

        // Wait 130ms — at 50ms we expect ≥ 2 ticks; at 200ms we'd expect 0.
        Thread.sleep(forTimeInterval: 0.13)
        tick.stop()

        channel.post(.appStarted)  // sentinel
        let events = channel.waitAndDrainAll()
        let tickCount = events.filter {
            if case .tick = $0 { return true }
            return false
        }.count
        #expect(tickCount >= 2, "After interval replacement to 50ms, must see ≥ 2 ticks in 130ms")
    }

    @Test("stop terminates the background thread cleanly")
    func stopTerminatesCleanly() {
        let channel = EventChannel()
        let tick = TickSource(channel: channel)
        tick.arm(interval: .milliseconds(50))
        Thread.sleep(forTimeInterval: 0.06)

        // stop() should return promptly — it signals the condition variable.
        let before = Date()
        tick.stop()
        let elapsed = Date().timeIntervalSince(before)
        #expect(elapsed < 0.2, "stop() must signal the background thread within 200ms")
    }
}
