// File: Sources/MoonSwiftTUI/App/Coalescer.swift
// Location: MoonSwiftTUI/App/
// Role: Batches print-output lines from RunService before posting them to
//       the EventChannel. Three flush triggers prevent either a flood of
//       single-line events or stranded lines at run end (ARCH §3c).
//       Constructed by the AppDriver and embedded in the run callbacks;
//       RunService is completely unaware of its existence.
// Upstream: EventChannel (destination for .runOutput events)
// Downstream: AppDriver (constructs Coalescer and passes it into run callbacks)

import Foundation

// MARK: - Coalescer

/// Accumulates script output lines and flushes them in batches to `EventChannel`.
///
/// ### Three flush triggers (ARCHITECTURE.md §3c)
///
/// 1. **Line arrival gate:** when a new line arrives, flush immediately if
///    ≥ 16 ms have elapsed since the last flush; otherwise buffer the line.
/// 2. **Tick:** called by the AppDriver on each `.tick` while a run is active;
///    flushes any pending lines (bounds sparse-output latency to ≤ 116 ms).
/// 3. **Run end:** `finish()` flushes any remaining lines *before* the caller
///    posts `.runFinished` — the last-line guarantee (same producer, FIFO).
///
/// ### Not thread-safe by design
///
/// `Coalescer` is owned exclusively by the closures the AppDriver constructs
/// for one run (onOutput and onFinish). Both closures are invoked on RunService's
/// serial executor — a single background thread — so no synchronisation is
/// needed inside `Coalescer`.
final class Coalescer {

    // MARK: State

    private var pending: [String] = []
    private var lastFlush: Date = .distantPast

    // MARK: Dependencies

    private let channel: EventChannel

    // MARK: Constants

    /// Minimum gap between consecutive flushes driven by line arrival.
    private static let flushGate: TimeInterval = 0.016   // 16 ms

    // MARK: Init

    init(channel: EventChannel) {
        self.channel = channel
    }

    // MARK: API

    /// Receive a new output line; flush if the inter-flush gap has elapsed.
    func onOutput(_ line: String) {
        pending.append(line)
        let now = Date()
        if now.timeIntervalSince(lastFlush) >= Coalescer.flushGate {
            flush(now: now)
        }
    }

    /// Called on each `.tick` while `runState == .running`; flushes pending lines.
    func onTick() {
        if !pending.isEmpty {
            flush(now: Date())
        }
    }

    /// Called when the run ends; flushes any remaining lines before .runFinished.
    ///
    /// The caller must post `.runFinished` only after this call returns, to
    /// guarantee the last-line ordering on the same producer's FIFO channel.
    func finish() {
        if !pending.isEmpty {
            flush(now: Date())
        }
    }

    // MARK: Private

    private func flush(now: Date) {
        guard !pending.isEmpty else { return }
        channel.post(.runOutput(pending))
        pending.removeAll(keepingCapacity: true)
        lastFlush = now
    }
}
