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
/// ### Thread safety
///
/// `onOutput` is called from RunService's background executor; `onTick` and
/// `finish` are called from the UI thread (AppDriver's event loop). All three
/// mutate `pending` and `lastFlush`, so every entry point is guarded by a
/// private `NSLock`. The lock is uncontended in the common case (only one path
/// is active at any moment) and is a plain spin+yield lock — not a condition
/// variable — so the hold time is always sub-microsecond.
final class Coalescer: @unchecked Sendable {

    // MARK: State

    private var pending: [String] = []
    private var lastFlush: Date = .distantPast

    // MARK: Synchronisation

    /// Guards `pending` and `lastFlush` against concurrent access between the
    /// UI thread (onTick / finish) and RunService's background executor (onOutput).
    private let lock = NSLock()

    // MARK: Dependencies

    private let channel: EventChannel

    // MARK: Constants

    /// Minimum gap between consecutive flushes driven by line arrival.
    private static let flushGate: TimeInterval = 0.016  // 16 ms

    // MARK: Init

    init(channel: EventChannel) {
        self.channel = channel
    }

    // MARK: API

    /// Receive a new output line; flush if the inter-flush gap has elapsed.
    ///
    /// May be called from any thread (RunService's background executor in
    /// production). The lock ensures no race with `onTick` / `finish`.
    func onOutput(_ line: String) {
        lock.lock()
        pending.append(line)
        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastFlush) >= Coalescer.flushGate
        if shouldFlush {
            flushLocked(now: now)
        }
        lock.unlock()
    }

    /// Called on each `.tick` while `runState == .running`; flushes pending lines.
    ///
    /// Called from the UI thread; the lock ensures no race with `onOutput`.
    func onTick() {
        lock.lock()
        if !pending.isEmpty {
            flushLocked(now: Date())
        }
        lock.unlock()
    }

    /// Called when the run ends; flushes any remaining lines before .runFinished.
    ///
    /// The caller must post `.runFinished` only after this call returns, to
    /// guarantee the last-line ordering on the same producer's FIFO channel.
    /// Called from the background Task in AppDriver after `runService.run` returns;
    /// the lock ensures no race with a concurrent `onTick`.
    func finish() {
        lock.lock()
        if !pending.isEmpty {
            flushLocked(now: Date())
        }
        lock.unlock()
    }

    // MARK: Private (must be called under lock)

    /// Flush `pending` to the channel and reset bookkeeping.
    ///
    /// Precondition: `lock` is held by the caller. `pending` is non-empty
    /// (callers are responsible for the empty check outside the lock).
    private func flushLocked(now: Date) {
        guard !pending.isEmpty else { return }
        channel.post(.runOutput(pending))
        pending.removeAll(keepingCapacity: true)
        lastFlush = now
    }
}
