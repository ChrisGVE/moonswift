// File: Tests/MoonSwiftTUITests/EventChannelTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for EventChannel — FIFO ordering, blocking drain, multi-producer
//       safety, and spurious-wake tolerance. No FFI is linked in this target.
// Upstream: EventChannel.swift
// Downstream: (test target)

import Dispatch
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Returns true if `event` matches the given simple (no-payload) case label.
private func isTick(_ e: AppEvent) -> Bool {
    if case .tick = e { return true }
    return false
}

private func isAppStarted(_ e: AppEvent) -> Bool {
    if case .appStarted = e { return true }
    return false
}

private func isLintEngineReady(_ e: AppEvent) -> Bool {
    if case .lintEngineReady = e { return true }
    return false
}

// MARK: - EventChannel tests

@Suite("EventChannel")
struct EventChannelTests {

    // MARK: Basic single-producer FIFO

    @Test("waitAndDrainAll returns posted events in FIFO order")
    func singleProducerFIFO() {
        let channel = EventChannel()
        channel.post(.tick)
        channel.post(.appStarted)
        channel.post(.lintEngineReady)

        let events = channel.waitAndDrainAll()
        #expect(events.count == 3)
        #expect(isTick(events[0]))
        #expect(isAppStarted(events[1]))
        #expect(isLintEngineReady(events[2]))
    }

    @Test("waitAndDrainAll drains the queue — second call blocks")
    func drainLeavesQueueEmpty() {
        let channel = EventChannel()
        channel.post(.tick)
        let first = channel.waitAndDrainAll()
        #expect(first.count == 1)

        // Post another event and drain again — verifies the queue was truly empty.
        channel.post(.lintEngineReady)
        let second = channel.waitAndDrainAll()
        #expect(second.count == 1)
        #expect(isLintEngineReady(second[0]))
    }

    @Test("post from a background thread is received by the UI thread")
    func multipleProducersReachChannel() {
        let channel = EventChannel()
        let group = DispatchGroup()

        // Two producers post events concurrently.
        let producerCount = 4
        for _ in 0..<producerCount {
            group.enter()
            DispatchQueue.global().async {
                channel.post(.tick)
                group.leave()
            }
        }
        group.wait()

        // Drain — must return exactly producerCount events (all are .tick here).
        let events = channel.waitAndDrainAll()
        #expect(events.count == producerCount)
        #expect(events.allSatisfy { isTick($0) })
    }

    @Test("FIFO per producer: sequential posts from one thread arrive in order")
    func fifoPerSingleProducer() {
        let channel = EventChannel()

        // Post a recognizable sequence from a single thread.
        channel.post(.appStarted)
        channel.post(.tick)
        channel.post(.lintEngineReady)
        channel.post(.catalogProbed(tomlAvailable: true))

        let events = channel.waitAndDrainAll()
        #expect(events.count == 4)
        guard events.count == 4 else { return }
        #expect(isAppStarted(events[0]))
        #expect(isTick(events[1]))
        #expect(isLintEngineReady(events[2]))
        // The last event carries an associated value.
        if case .catalogProbed(let avail) = events[3] {
            #expect(avail == true)
        } else {
            Issue.record("Expected .catalogProbed but got \(events[3])")
        }
    }

    @Test("waitAndDrainAll unblocks when a background thread posts")
    func wakesOnBackgroundPost() async {
        let channel = EventChannel()

        // Schedule a post after a short delay.
        let task = Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            channel.post(.tick)
        }

        // This blocks until the background post arrives.
        let events = channel.waitAndDrainAll()
        #expect(events.count == 1)
        #expect(isTick(events[0]))

        // Clean up the task.
        await task.value
    }

    @Test("multi-producer FIFO: each producer's events arrive in their own order")
    func multiProducerFIFOPerProducer() {
        let channel = EventChannel()
        let dispatchGroup = DispatchGroup()

        // Producer A posts a recognizable pair.
        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            channel.post(.lintEngineReady)
            channel.post(.catalogProbed(tomlAvailable: false))
            dispatchGroup.leave()
        }

        // Producer B posts another pair.
        dispatchGroup.enter()
        DispatchQueue.global(qos: .default).async {
            channel.post(.appStarted)
            channel.post(.tick)
            dispatchGroup.leave()
        }

        dispatchGroup.wait()

        let events = channel.waitAndDrainAll()
        #expect(events.count == 4)

        // Verify intra-producer ordering is preserved, regardless of interleaving.
        let aIndices = events.indices.filter {
            switch events[$0] {
            case .lintEngineReady, .catalogProbed: return true
            default: return false
            }
        }
        let bIndices = events.indices.filter {
            switch events[$0] {
            case .appStarted, .tick: return true
            default: return false
            }
        }
        #expect(aIndices.count == 2)
        #expect(bIndices.count == 2)

        // Within A: .lintEngineReady must precede .catalogProbed.
        if aIndices.count == 2 {
            #expect(aIndices[0] < aIndices[1])
            if case .lintEngineReady = events[aIndices[0]] {
            } else {
                Issue.record("Expected .lintEngineReady first in producer A's sequence")
            }
        }
        // Within B: .appStarted must precede .tick.
        if bIndices.count == 2 {
            #expect(bIndices[0] < bIndices[1])
            if case .appStarted = events[bIndices[0]] {
            } else {
                Issue.record("Expected .appStarted first in producer B's sequence")
            }
        }
    }
}
