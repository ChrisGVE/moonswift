// File: Tests/MoonSwiftPerfTests/DebugGlobalsPerfTests.swift
// Location: Tests/MoonSwiftPerfTests/
// Role: Performance benchmarks for the debugger globals/snapshot/validation paths
//       (split from DebugPerfTests.swift to keep each file ≤ 400 lines). Shared
//       helpers (perfFrag, perfEngine, dbgMeasureSync/Async, PerfSnapshotStream)
//       and the threshold constants live in DebugPerfTests.swift as `internal`.
//       Four measurement groups:
//
//         4. g-globals latency — `requestGlobals` → re-published snapshot with
//            globals populated, ≥500 `_G` entries total (PERF-09/12):
//            PRD target < 120 ms → CI threshold 240 ms.
//         6. Snapshot build cost — `DebugSnapshot` init for ≤16 frames, ≤200
//            inspected values, globals EXCLUDED (PERF-01): < 30 ms → 60 ms.
//         7. Explicit-g globals slice — full `_G` walk before baseline
//            subtraction + truncation (PERF-12): < 30 ms → 60 ms.
//         8. Mock-literal load-time validation (PERF-14): 64-literal aggregate
//            < 320 ms PRD → 640 ms CI; a 100-literal store validates 64 + warns.
//
//       All CI thresholds are 2× the PRD target, matching PerfTests.swift.
//
// Upstream: MoonSwiftCore (SessionEngine, DebugSnapshot, DebugVariable,
//           DebugFrame, ProjectValidation, MockStore, LintService),
//           DebugPerfTests.swift (shared helpers + thresholds)
// Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - 4. g-globals latency ≥500 _G entries (PERF-09/12)

/// Measures `requestGlobals` → re-published snapshot with globals populated,
/// with a TOTAL `_G` of ≥500 entries (PERF-09/12, PRD target: < 120 ms,
/// CI threshold: 240 ms). The full walk + baseline-subtraction + truncation
/// path is exercised; 300 user globals plus the ~200-name stdlib clear 500.
@Suite("Perf — g-globals latency ≥500 _G entries (PERF-09/12)")
struct GGlobalsPerfTests {

    @Test("requestGlobals → snapshot with globals < 240 ms for ≥500-entry _G (2× PRD 120 ms target)")
    func gGlobalsLatency() async throws {
        let engine = try await perfEngine()
        defer { Task { await engine.endSession() } }

        let stream = PerfSnapshotStream()

        // 300 user globals via a Lua for-loop, plus stdlib (~200 built-ins):
        // total _G ≥ 500. Breakpoint on line 4 so globals are all installed.
        let script = """
            for i = 1, 300 do
              _G["g" .. i] = i
            end
            local _ = 0
            return "done"
            """
        let runTask = Task.detached {
            await engine.runForDebug(perfFrag(script), breakpoints: [4]) { snap in
                stream.record(snap)
            }
        }

        let pauseSnap = try #require(
            await stream.next(),
            "timed out at breakpoint — g-globals bench cannot proceed"
        )
        #expect(pauseSnap.fragmentLine == 4)

        let elapsed = await dbgMeasureAsync {
            engine.requestGlobals(pauseSnap.sessionID)
            _ = await stream.next()
        }

        print("[perf] requestGlobals → snapshot (≥500 _G entries): \(elapsed)")
        #expect(
            elapsed < gGlobalsThreshold,
            "g-globals latency took \(elapsed) — over 2× PRD target of 120 ms (CI threshold: 240 ms)"
        )

        // Resume so the run finishes and the deferred endSession does not race.
        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - 6. Snapshot build cost ≤16 frames, ≤200 values (PERF-01)

/// Measures the cost of building a `DebugSnapshot` with 16 call-stack frames
/// and 200 inspected locals (globals EXCLUDED), matching PERF-01:
/// PRD target < 30 ms, CI threshold 60 ms. `DebugSnapshot.init` is a pure
/// value-type initialiser — this bench verifies the copy is cheap.
@Suite("Perf — Snapshot build cost ≤16 frames ≤200 values (PERF-01)")
struct SnapshotBuildCostPerfTests {

    /// 200 DebugVariable values in a two-level nested shape (10 parents × 19
    /// children) — exercises the child-array path within the depth cap.
    private static func makeVariables() -> [DebugVariable] {
        (0..<10).map { parent in
            let children: [DebugVariable] = (0..<19).map { child in
                DebugVariable(
                    name: "child\(parent)_\(child)",
                    displayValue: "\(parent * 19 + child)",
                    children: nil
                )
            }
            return DebugVariable(
                name: "parent\(parent)",
                displayValue: "{…}",
                children: children
            )
        }
    }

    /// 16 DebugFrame values, simulating a deep call stack.
    private static func makeFrames() -> [DebugFrame] {
        (0..<16).map { i in
            DebugFrame(
                level: i, name: i == 0 ? "current" : "caller\(i)",
                source: "script.lua", line: 100 - i * 5)
        }
    }

    @Test("DebugSnapshot init with 16 frames, 200 locals, no globals < 60 ms (2× PRD 30 ms target)")
    func snapshotBuildCost() {
        let frames = Self.makeFrames()
        let variables = Self.makeVariables()
        let sessionID = DebugSessionID()

        // All 16 frames carry the same 200 vars for a worst-case memory copy.
        let frameVars: [Int: ([DebugVariable], [DebugVariable])] = Dictionary(
            uniqueKeysWithValues: (0..<16).map { i in (i, (variables, [])) }
        )

        // Warm-up.
        _ = DebugSnapshot(
            sessionID: sessionID, event: .line, fragmentLine: 10,
            callStack: frames, frameVars: frameVars, globals: nil
        )

        let elapsed = dbgMeasureSync {
            _ = DebugSnapshot(
                sessionID: sessionID, event: .line, fragmentLine: 10,
                callStack: frames, frameVars: frameVars, globals: nil
            )
        }

        print("[perf] DebugSnapshot init (16 frames, 200 locals, no globals): \(elapsed)")
        #expect(
            elapsed < snapshotBuildThreshold,
            "DebugSnapshot init took \(elapsed) — over 2× PRD target of 30 ms (CI threshold: 60 ms)"
        )
    }
}

// MARK: - 7. Explicit-g globals slice (PERF-12)

/// Measures the full `_G` walk before baseline subtraction + truncation by
/// timing the globals round-trip with 270 user globals — enough to exercise the
/// walk without heavy truncation (PERF-12, PRD target < 30 ms, CI threshold
/// 60 ms). The breadth cap (256) elides 14 entries, so the measured cost is the
/// walk, not the truncation bookkeeping.
@Suite("Perf — Explicit-g globals slice before truncation (PERF-12)")
struct GlobalsSlicePerfTests {

    @Test("_G walk (270 user globals) → snapshot < 60 ms (2× PRD 30 ms target, PERF-12)")
    func globalsSliceWalkLatency() async throws {
        let engine = try await perfEngine()
        defer { Task { await engine.endSession() } }

        let stream = PerfSnapshotStream()
        let script = """
            for i = 1, 270 do
              _G["h" .. i] = i
            end
            local _ = 0
            return "done"
            """
        let runTask = Task.detached {
            await engine.runForDebug(perfFrag(script), breakpoints: [4]) { snap in
                stream.record(snap)
            }
        }

        let pauseSnap = try #require(
            await stream.next(),
            "timed out at breakpoint — globals-slice bench cannot proceed"
        )

        let elapsed = await dbgMeasureAsync {
            engine.requestGlobals(pauseSnap.sessionID)
            _ = await stream.next()
        }

        print("[perf] globals slice walk (270 user globals): \(elapsed)")
        #expect(
            elapsed < globalsSliceThreshold,
            "Globals slice walk took \(elapsed) — over 2× PRD target of 30 ms (CI threshold: 60 ms, PERF-12)"
        )

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - 8. Mock-literal load-time validation (PERF-14)

/// Measures `ProjectValidation.validateMocks` for a 100-literal store: the
/// first 64 literals are syntax-validated; the remaining 36 are skipped and a
/// soft-cap warning is emitted (PERF-14). 64-literal aggregate < 320 ms PRD →
/// CI threshold 640 ms.
@Suite("Perf — Mock-literal load-time validation (PERF-14)")
struct MockLiteralValidationPerfTests {

    /// Build a `MockStore` with `valueCount` value defs + `functionCount`
    /// fixed-return function defs (all valid Lua number literals).
    private static func makeStore(values valueCount: Int, functions functionCount: Int) -> MockStore {
        let values = (1...valueCount).map { i in
            MockValueDef(namespace: "perf", path: "v\(i)", type: .number, value: "\(i)", writable: false)
        }
        let functions = (1...functionCount).map { i in
            MockFunctionDef(name: "fn\(i)", behavior: .fixedReturn, returnValue: "\(i)", errorMessage: nil)
        }
        return MockStore(values: values, functions: functions)
    }

    @Test("validateMocks 100 literals (64 validated, 36 skipped) < 640 ms (2× PRD 320 ms target)")
    func mockLiteralValidationAggregate() {
        // 60 value literals + 40 fixed-return function literals = 100 total;
        // only the first 64 are validated, 36 skipped.
        let store = Self.makeStore(values: 60, functions: 40)
        let lintService = LintService()
        var diagnostics: [Diagnostic] = []

        let elapsed = dbgMeasureSync {
            ProjectValidation.validateMocks(store, lintService: lintService, into: &diagnostics)
        }

        print("[perf] validateMocks (100 literals, 64 validated): \(elapsed)")

        // PERF-14: the over-budget warning must fire, confirming the 64-cap hit.
        let hasOverBudgetWarning = diagnostics.contains {
            $0.message.contains("exceed the 64-literal validation budget")
        }
        #expect(
            hasOverBudgetWarning,
            "PERF-14 over-budget warning must be emitted for 100 literals; diagnostics: \(diagnostics.map(\.message))"
        )
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "Expected no validation errors for valid literals; got: \(errors.map(\.message))")
        #expect(
            elapsed < mockValidationThreshold,
            "validateMocks (100 literals) took \(elapsed) — over 2× PRD target of 320 ms (CI threshold: 640 ms)"
        )
    }

    @Test("validateMocks 64 literals validates all — no PERF-14 warning (baseline)")
    func mockLiteralValidationAtCap() {
        let store = Self.makeStore(values: 40, functions: 24)  // 40 + 24 = 64 total.
        let lintService = LintService()
        var diagnostics: [Diagnostic] = []

        let elapsed = dbgMeasureSync {
            ProjectValidation.validateMocks(store, lintService: lintService, into: &diagnostics)
        }

        print("[perf] validateMocks (64 literals, all validated): \(elapsed)")

        let hasOverBudgetWarning = diagnostics.contains {
            $0.message.contains("exceed the 64-literal validation budget")
        }
        #expect(
            !hasOverBudgetWarning,
            "PERF-14 warning must NOT fire at exactly 64 literals; diagnostics: \(diagnostics.map(\.message))"
        )
        let errors = diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "Expected no validation errors; got: \(errors.map(\.message))")
        #expect(
            elapsed < mockValidationThreshold,
            "validateMocks (64 literals) took \(elapsed) — over CI threshold 640 ms"
        )
    }
}
