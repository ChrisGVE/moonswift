// File: Tests/MoonSwiftPerfTests/DebugPerfTests.swift
// Location: Tests/MoonSwiftPerfTests/
// Role: Performance benchmarks for the P2 debugger stepping/cancel paths, plus
//       the shared helpers + threshold constants used by both this file and its
//       companion DebugGlobalsPerfTests.swift (the suite set is split across two
//       files to keep each ≤ 400 lines). The groups here:
//
//         3a. Step reducer pass — pure `reduceDebugStepKey` call with a paused
//             AppState: isolates the Swift-side reducer cost with no I/O
//             (PERF-04, in-process reducer only).
//         3b. Mailbox wake round-trip — `sendDebugCommand(.stepOver)` to the
//             next snapshot: cross-thread park/wake across TWO OS scheduler
//             round-trips (PERF-04 sub-target < 16 ms → CI threshold 32 ms).
//         5.  Pause/stop latency — `sendDebugCommand(.stop)` to session end:
//             PRD target < 200 ms → CI threshold 400 ms.
//
//       The globals (4, 7), snapshot-build (6), and mock-validation (8) groups
//       live in DebugGlobalsPerfTests.swift; they reuse the `internal` helpers
//       (perfFrag, perfEngine, dbgMeasureSync/Async, PerfSnapshotStream) and the
//       threshold constants declared below. All CI thresholds are 2× the PRD
//       target, matching PerfTests.swift convention.
//
//       Running locally:
//         MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 \
//           swift test --filter DebugStepReducerPerfTests
//
// Upstream: MoonSwiftCore (SessionEngine, DebugSnapshot),
//           MoonSwiftTUI (reduceDebugStepKey — internal via @testable)
// Downstream: DebugGlobalsPerfTests.swift (shares the helpers/thresholds here)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Thresholds
//
// PRD target → CI threshold (2×):
//   Step reducer pass              <  1 ms  →   2 ms  (PERF-04, pure Swift)
//   Mailbox wake round-trip        < 16 ms  →  32 ms  (PERF-04 sub-target)
//   g-globals latency (500+ _G)   < 120 ms → 240 ms  (PERF-09/12)
//   Pause/stop latency            < 200 ms → 400 ms
//   Snapshot build cost (≤16 fr)  <  30 ms →  60 ms  (PERF-01)
//   Globals slice walk (≥256 uglo) <  30 ms →  60 ms  (PERF-12)
//   Mock-literal 64-agg validation < 320 ms → 640 ms  (PERF-14)

// `internal` (not `private`) so the companion file DebugGlobalsPerfTests.swift
// shares these debug-specific thresholds and helpers (the codesize split keeps
// each file ≤ 400 lines). Names are debug-unique to avoid module collisions.
let stepReducerThreshold: Duration = .milliseconds(2)
let mailboxWakeThreshold: Duration = .milliseconds(32)
let gGlobalsThreshold: Duration = .milliseconds(240)
let pauseStopThreshold: Duration = .milliseconds(400)
let snapshotBuildThreshold: Duration = .milliseconds(60)
let globalsSliceThreshold: Duration = .milliseconds(60)
let mockValidationThreshold: Duration = .milliseconds(640)

// MARK: - Shared fixtures

/// Build a `LuaSourceFragment` with a synthetic provenance.
/// Mirrors the `dbgIntFrag` helper in DebuggerIntegrationTests (file-private
/// there; redeclared here with a `perf` prefix to avoid any future collision).
func perfFrag(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/perf-debug.lua")
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// Start a fresh `SessionEngine` for one perf test.
func perfEngine() async throws -> SessionEngine {
    let engine = SessionEngine(onOutput: { _ in })
    try await engine.startSession(config: RunConfig(), mocks: .empty)
    return engine
}

/// Measures wall-clock elapsed time for `body`. Matches the `measureSync`
/// helper in PerfTests.swift; `dbg`-prefixed + `internal` so the companion
/// DebugGlobalsPerfTests.swift shares it without clashing with the file-private
/// `measureSync` in PerfTests.swift / CompletionPerfTests.swift.
func dbgMeasureSync(_ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    body()
    return clock.now - start
}

/// Async variant for bodies that `await`.
func dbgMeasureAsync(_ body: () async -> Void) async -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    await body()
    return clock.now - start
}

// MARK: - Thread-safe snapshot stream
//
// Mirrors DbgIntSnapshotStream (DebuggerIntegrationTests) with a `perf`-prefix
// so both files can coexist in the same test module compilation unit without a
// duplicate-symbol error.

final class PerfSnapshotStream: @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [DebugSnapshot] = []
    private var _waiters: [(UUID, CheckedContinuation<DebugSnapshot?, Never>)] = []

    func record(_ snapshot: DebugSnapshot) {
        var waiter: CheckedContinuation<DebugSnapshot?, Never>?
        lock.withLock {
            if _waiters.isEmpty {
                _pending.append(snapshot)
            } else {
                waiter = _waiters.removeFirst().1
            }
        }
        waiter?.resume(returning: snapshot)
    }

    func next(timeout seconds: Double = 5) async -> DebugSnapshot? {
        let id = UUID()
        return await withTaskGroup(of: DebugSnapshot?.self) { group in
            group.addTask { [self, id] in
                await withTaskCancellationHandler(
                    operation: {
                        await withCheckedContinuation {
                            (cont: CheckedContinuation<DebugSnapshot?, Never>) in
                            var buffered: DebugSnapshot?
                            self.lock.withLock {
                                if self._pending.isEmpty {
                                    self._waiters.append((id, cont))
                                } else {
                                    buffered = self._pending.removeFirst()
                                }
                            }
                            if let snap = buffered { cont.resume(returning: snap) }
                        }
                    },
                    onCancel: { [self, id] in
                        var waiter: CheckedContinuation<DebugSnapshot?, Never>?
                        self.lock.withLock {
                            if let idx = self._waiters.firstIndex(where: { $0.0 == id }) {
                                waiter = self._waiters.remove(at: idx).1
                            }
                        }
                        waiter?.resume(returning: nil)
                    }
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - 3a. Step reducer pass (PERF-04, in-process only)

/// Measures the pure Swift reducer cost of a `s` (stepOver) gesture while
/// the VM is paused (PRD PERF-04 target: < 1 ms, CI threshold: 2 ms).
///
/// This bench isolates the STATE MACHINE only — no engine call, no mailbox I/O.
/// `reduceDebugStepKey` reads the active session ID, clears `currentDebugSnapshot`,
/// rebuilds gutter marks, and emits `Effect.sendDebugCommand`. All of that is
/// pure Swift; the effect is discarded here, measuring only the state-transition
/// cost the main thread pays on every step keypress.
///
/// CI threshold: 2 ms (2× the 1 ms PRD target). Under heavy load, a pure
/// in-memory reducer call should never exceed 1 ms on any modern hardware, so
/// the 2 ms ceiling is conservative and stable.
@Suite("Perf — Step reducer pass (PERF-04 in-process)")
struct DebugStepReducerPerfTests {

    @Test("reduceDebugStepKey (.stepOver) < 2 ms while paused (2× PRD 1 ms target)")
    func stepReducerPass() {
        // Build a minimal AppState that looks "paused": an active session ID
        // and a non-nil currentDebugSnapshot.
        let sessionID = DebugSessionID()
        let snapshot = DebugSnapshot(
            sessionID: sessionID,
            event: .breakpoint,
            fragmentLine: 3,
            callStack: [DebugFrame(level: 0, name: "main", source: "script", line: 3)],
            frameVars: [0: ([], [])],
            globals: nil
        )
        let state = AppState(
            activeDebugSessionID: sessionID,
            currentDebugSnapshot: snapshot
        )

        // Warm-up: one call to prime branch predictors and any lazy init.
        _ = reduceDebugStepKey(state, command: .stepOver)

        let elapsed = dbgMeasureSync {
            _ = reduceDebugStepKey(state, command: .stepOver)
        }

        print("[perf] reduceDebugStepKey(.stepOver): \(elapsed)")
        #expect(
            elapsed < stepReducerThreshold,
            "reduceDebugStepKey took \(elapsed) — over 2× PRD target of 1 ms (CI threshold: 2 ms)"
        )
    }
}

// MARK: - 3b. Mailbox wake round-trip (PERF-04 cross-thread)

/// Measures `sendDebugCommand(.stepOver)` to the NEXT snapshot arriving on the
/// stream — the cross-thread mailbox wake overhead (PERF-04 sub-target: < 16 ms,
/// CI threshold: 32 ms).
///
/// What is measured: the two OS scheduler round-trips that the NSCondition wake
/// cycle requires — (1) `put(_:)` signals the condition, (2) the VM-thread wakes
/// and services the command, (3) the hook fires the onPause callback, (4) the
/// Task await resumes on the cooperative pool. This is end-to-end mailbox
/// overhead with no meaningful Lua computation (a 1-line script, stepping to
/// line 2 via stepOver).
///
/// Noted caveat: the NSCondition-based park/wake path has inherently variable
/// latency when the OS scheduler is under load (shared CI runners can
/// context-switch away for 5–15 ms). The 2× multiplier (32 ms) covers realistic
/// variance; very-heavy-load spikes beyond 32 ms are expected and do NOT indicate
/// a real regression — widen the threshold and re-run to confirm.
@Suite("Perf — Mailbox wake round-trip (PERF-04 cross-thread)")
struct DebugMailboxWakePerfTests {

    @Test("sendDebugCommand(.stepOver) → next snapshot < 32 ms mailbox overhead (2× PRD 16 ms target)")
    func mailboxWakeRoundTrip() async throws {
        let engine = try await perfEngine()
        defer { Task { await engine.endSession() } }

        let stream = PerfSnapshotStream()

        // A 2-line script: pause on line 1, stepOver reaches line 2, then
        // continueRun to finish. Minimal Lua work so the measurement reflects
        // mailbox/scheduling overhead rather than VM execution time.
        let script = "local x = 1\nreturn x"
        let runTask = Task.detached {
            await engine.runForDebug(perfFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        // Wait for the first pause (breakpoint on line 1).
        let pauseSnap = try #require(
            await stream.next(),
            "timed out waiting for first pause — mailbox round-trip bench cannot proceed"
        )
        #expect(pauseSnap.fragmentLine == 1)

        // Measure: time from sendDebugCommand(.stepOver) to the next snapshot.
        let elapsed = await dbgMeasureAsync {
            engine.sendDebugCommand(pauseSnap.sessionID, .stepOver)
            _ = await stream.next()
        }

        print("[perf] mailbox wake round-trip (stepOver → next snapshot): \(elapsed)")
        // NSCondition latency is OS-scheduler dependent; verify on a quiet
        // machine before treating an overrun as a real regression.
        #expect(
            elapsed < mailboxWakeThreshold,
            "Mailbox wake round-trip took \(elapsed) — over 2× PRD sub-target of 16 ms (CI threshold: 32 ms)"
        )

        // Clean up: the VM is parked after the measured step. `.stop`
        // unconditionally unparks it so `runForDebug` returns — never rely on a
        // further snapshot arriving (the VM emits none while parked, which would
        // hang the await below).
        engine.sendDebugCommand(pauseSnap.sessionID, .stop)
        _ = await runTask.value
    }
}

// MARK: - 5. Pause/stop latency (PRD target: < 200 ms, CI threshold: 400 ms)

/// Measures `sendDebugCommand(.stop)` → session end while the VM is parked at
/// a breakpoint (PRD target: < 200 ms, CI threshold: 400 ms).
///
/// What this bench measures: the `.stop` command travels through the
/// NSCondition mailbox, the hook adapter returns `LuaDebugCommand.stop`, the
/// VM raises `LuaError.cancelled` (or equivalent), and `runForDebug` returns.
/// The bench measures the wall-clock elapsed from `sendDebugCommand(.stop)` to
/// the `runTask` completing — the full cancel + teardown path.
@Suite("Perf — Pause/stop latency")
struct DebugStopPerfTests {

    @Test("sendDebugCommand(.stop) → runForDebug returns < 400 ms (2× PRD 200 ms target)")
    func pauseStopLatency() async throws {
        let engine = try await perfEngine()
        defer { Task { await engine.endSession() } }

        let stream = PerfSnapshotStream()
        let script = "local x = 1\nreturn x"

        let runTask = Task.detached {
            await engine.runForDebug(perfFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }

        let pauseSnap = try #require(
            await stream.next(),
            "timed out waiting for pause — stop-latency bench cannot proceed"
        )
        #expect(pauseSnap.fragmentLine == 1)

        // Measure: time from .stop delivery to the run task completing.
        let elapsed = await dbgMeasureAsync {
            engine.sendDebugCommand(pauseSnap.sessionID, .stop)
            _ = await runTask.value
        }

        print("[perf] pause/stop latency (.stop → runForDebug return): \(elapsed)")
        #expect(
            elapsed < pauseStopThreshold,
            "Pause/stop latency took \(elapsed) — over 2× PRD target of 200 ms (CI threshold: 400 ms)"
        )
    }
}
