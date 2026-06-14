// File: Tests/MoonSwiftCoreTests/Debug/DebuggerIntegrationTests.swift
// Location: MoonSwiftCoreTests/Debug/
// Role: End-to-end integration tests for the debugger path (task #30, p2-p3).
//       Drives the REAL SessionEngine + LuaSwift 1.12.4 pipeline via runForDebug,
//       scripting the DebugCommandMailbox with stepping/globals commands and
//       asserting the observable DebugSnapshot stream.
//
//       ## Coverage scope
//
//       This suite covers cases NOT already exercised in DebugHookAdapterTests:
//
//       (A) Stepping sequence (over/into/out/continue): snapshots advance with
//           correct fragmentLine values across a multi-step sequence.
//
//       (B) Stepping-mode .line event: after a step command the next snapshot
//           carries event == .line (not .breakpoint).
//
//       (C) Structured error/traceback via LuaSwift #19 runtimeFailure: a Lua
//           runtime error during a debug run produces CoreRunOutcome.error with a
//           populated Diagnostic.  ChunkName plumbing (#23) maps frame source
//           names — that is F6.4 work tracked in issue #13; tested via the error
//           message path that IS available in 1.12.4.
//
//       (D) UI non-blocking during pause: while the VM is parked at a pause, a
//           concurrent async task (simulating the UI thread) completes free work,
//           proving the serial executor does not block the Swift concurrency pool.
//
//       (E) Globals two-predicate wake contract (DOM-09): requestGlobals sets the
//           latch; mailbox.take() returns .serviceGlobals. Proved at the engine
//           level by the observable snapshot republish (already covered by adapter
//           tests). Here we add the raw mailbox predicate check: latch is set
//           before servicing and cleared after.
//           → COVERED by DebugCommandMailboxTests in SessionEngineTests. Documented.
//
//       (F) Eager in-place capture (DOM-08): fragmentLine == original pause line
//           after requestGlobals. COVERED by DebugHookAdapterTests
//           (`globalsFragmentLineUnchanged`). Documented here.
//
//       (G) Empty globals → [] non-nil at early pause and at last line (DOM-10):
//           COVERED by DebugHookAdapterTests (`emptyGlobalsIsNonNilEmptySlice`).
//           Documented here.
//
//       (H) globalsRequested lifecycle (set → consumed → cleared):
//           COVERED by DebugCommandMailboxTests (`signalGlobals`). Documented.
//
//       (I) Coroutine frame snapshotted: COVERED by
//           DebugHookAdapterCoroutineTests. Documented here.
//
//       (D1) Cyclic table → `(cycle)` marker in DebugVariable.displayValue.
//            New. Drives a live run to assert the adapter maps cycles correctly.
//
//       (D2) globalsElided > 0 when >256 user globals are defined. New.
//
// ## Synchronization strategy (mirrors DebugHookAdapterTests)
//
// All helpers are private and prefixed `dbgInt` to avoid name collisions with
// the identically-shaped helpers in DebugHookAdapterTests (which is file-private
// there). The snapshot queue type is `DbgIntSnapshotStream`; the engine factory
// is `dbgIntEngine`; the fragment builder is `dbgIntFrag`.
//
// Upstream: SessionEngine, DebugHookAdapter, DebugSession, DebugCommandMailbox,
//           DebugSnapshot, DebugFrame, DebugVariable, RunConfig, LuaSourceFragment,
//           FragmentProvenance, CoreRunOutcome, LuaSwift (LuaDebugCommand)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Private helpers (dbgInt-prefixed to avoid collision)

/// Thread-safe snapshot queue, equivalent to `SnapshotStream` in
/// DebugHookAdapterTests but named distinctly so both files can coexist under
/// the same test module compilation unit without a duplicate-symbol error.
private final class DbgIntSnapshotStream: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [DebugSnapshot] = []
    private var _pending: [DebugSnapshot] = []
    private var _waiters: [(UUID, CheckedContinuation<DebugSnapshot?, Never>)] = []

    func record(_ snapshot: DebugSnapshot) {
        var waiter: CheckedContinuation<DebugSnapshot?, Never>?
        lock.withLock {
            _all.append(snapshot)
            if _waiters.isEmpty {
                _pending.append(snapshot)
            } else {
                waiter = _waiters.removeFirst().1
            }
        }
        waiter?.resume(returning: snapshot)
    }

    var all: [DebugSnapshot] { lock.withLock { _all } }
    var latest: DebugSnapshot? { lock.withLock { _all.last } }

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
                            if let snap = buffered {
                                cont.resume(returning: snap)
                            }
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

/// Build a `LuaSourceFragment` with lineOffset 0 for integration tests.
/// Named `dbgIntFrag` to avoid collision with `fragment(_:)` in
/// DebugHookAdapterTests and `intFrag(_:)` in SessionEngineIntegrationTests.
private func dbgIntFrag(_ code: String, lineOffset: Int = 0) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/dbg-integration.lua")
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: lineOffset,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// Create and start a `SessionEngine` for one test.
/// Named `dbgIntEngine` to avoid collision with `makeStartedEngine()` /
/// `intEngine()` in the sibling test files.
private func dbgIntEngine() async throws -> SessionEngine {
    let engine = SessionEngine(onOutput: { _ in })
    try await engine.startSession(config: RunConfig(), mocks: .empty)
    return engine
}

// MARK: - Suite A: Stepping sequence (over / into / out / continue)

/// Case 1 from task #30: set a breakpoint, drive the mailbox with scripted
/// commands, assert paused snapshots advance correctly for over/into/out/continue.
///
/// Uses `runForDebug` with the `onResumed` seam to confirm the engine posts
/// the resumed signal for each advancing command (ARCH-07).
@Suite("DebuggerIntegration — stepping sequence")
struct DbgIntSteppingSequenceTests {

    // A 4-line script with a nested function call so we can test into/out:
    //   line 1: define helper (no pause — not an executable statement on its own)
    //   line 2: call helper (stepping into produces line 3 pause)
    //   line 3: body of helper
    //   line 4: return from main
    //
    // We set a breakpoint on line 2 to get the first pause, then drive:
    //   pause on line 2 → stepOver → pause on line 4 → continueRun → done
    @Test("stepOver from a breakpoint advances to the next source line")
    func steppingSequenceStepOver() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()
        let resumedCount = LockCounter()

        let script = """
            local function add(a, b)
              return a + b
            end
            local result = add(10, 20)
            return result
            """
        // Breakpoint on line 4 (local result = add(10, 20))
        let runTask = Task.detached {
            await engine.runForDebug(
                dbgIntFrag(script), breakpoints: [4],
                onPause: { snap in
                    stream.record(snap)
                },
                onResumed: { _ in
                    resumedCount.increment()
                })
        }
        defer { Task { await runTask.value } }

        // First pause at line 4 (breakpoint).
        let snap1 = try #require(await stream.next(), "timed out at first pause")
        #expect(snap1.event == .breakpoint)
        #expect(snap1.fragmentLine == 4)

        // Step over — should land on line 5 (return result) as a .line event.
        engine.sendDebugCommand(snap1.sessionID, .stepOver)

        let snap2 = try #require(await stream.next(), "timed out at second pause")
        #expect(snap2.event == .line, "stepping stop must be .line, not .breakpoint")
        #expect(snap2.fragmentLine == 5, "stepOver from line 4 should reach line 5")

        // Resume to finish.
        engine.sendDebugCommand(snap2.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        guard case .done(let val, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(val == "30")
        // Both stepOver and continueRun must have triggered onResumed (ARCH-07).
        #expect(resumedCount.value == 2, "expected 2 onResumed signals, got \(resumedCount.value)")
    }

    @Test("stepInto descends into the called function")
    func steppingSequenceStepInto() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        let script = """
            local function inner(n)
              return n * 2
            end
            local x = inner(7)
            return x
            """
        // Breakpoint on line 4 (local x = inner(7))
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [4]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at breakpoint")
        #expect(pauseSnap.fragmentLine == 4)

        // stepInto — should descend into `inner` and stop on line 2 (return n * 2).
        engine.sendDebugCommand(pauseSnap.sessionID, .stepInto)

        let innerSnap = try #require(await stream.next(), "timed out inside inner")
        // Must have entered the function body. LuaSwift fires the handler at the
        // first executable line of `inner` (line 2).
        #expect(innerSnap.event == .line)
        #expect(innerSnap.fragmentLine == 2, "stepInto should land inside inner at line 2")

        // At least two frames on the call stack: inner (0) + main chunk (1).
        #expect(innerSnap.callStack.count >= 2, "call stack must have inner + caller frames")

        engine.sendDebugCommand(innerSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("stepOut exits the current function and resumes the caller")
    func steppingSequenceStepOut() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        let script = """
            local function inner(n)
              local doubled = n * 2
              return doubled
            end
            local x = inner(5)
            return x
            """
        // Breakpoint on line 2 (local doubled = n * 2) — inside inner.
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [2]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let innerSnap = try #require(await stream.next(), "timed out inside inner")
        #expect(innerSnap.fragmentLine == 2)

        // stepOut — should return to the caller (line 5 or beyond, back in main).
        engine.sendDebugCommand(innerSnap.sessionID, .stepOut)

        let callerSnap = try #require(await stream.next(), "timed out after stepOut")
        #expect(callerSnap.event == .line)
        // After stepping out of `inner`, execution resumes at the call site (line 5)
        // or the next line. The call stack must be shallower than inside `inner`.
        #expect(
            callerSnap.callStack.count < innerSnap.callStack.count
                || callerSnap.fragmentLine > 2,
            "stepOut must return to the caller scope")

        engine.sendDebugCommand(callerSnap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Suite B: Stepping-mode .line-only contract

/// Case 2 from task #30: in stepping mode, the adapter classifies every delivered
/// event as .line (not .breakpoint) because LuaSwift fires the handler only at
/// the step-fire point, and those lines are not in the breakpoint set.
///
/// The adapter comment (CONS-07) documents the distinction:
/// "In STEPPING mode, LuaSwift only calls the handler at the step-fire point."
/// We verify the contract by asserting .line on all non-breakpoint stepping stops.
@Suite("DebuggerIntegration — stepping mode .line contract")
struct DbgIntSteppingModeLineTests {

    @Test("stepping stops after the initial breakpoint carry .line event (CONS-07)")
    func steppingStopsAreLineEvents() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        let script = """
            local a = 1
            local b = 2
            local c = 3
            return a + b + c
            """
        // Single breakpoint on line 1 to enter stepping mode.
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        // First pause is a breakpoint.
        let bp = try #require(await stream.next(), "timed out at breakpoint")
        #expect(bp.event == .breakpoint)

        // Step over twice — both stops must be .line (lines 2 and 3 are not
        // in the breakpoint set, so they can only arrive as stepping stops).
        engine.sendDebugCommand(bp.sessionID, .stepOver)

        let step1 = try #require(await stream.next(), "timed out at step 1")
        #expect(step1.event == .line, "first stepping stop must be .line")

        engine.sendDebugCommand(step1.sessionID, .stepOver)

        let step2 = try #require(await stream.next(), "timed out at step 2")
        #expect(step2.event == .line, "second stepping stop must be .line")

        engine.sendDebugCommand(step2.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Suite C: Structured error / traceback

/// Case 3 from task #30: a Lua runtime error during a debug run is surfaced as
/// `CoreRunOutcome.error` with a populated `Diagnostic`. LuaSwift #19 structures
/// the runtime failure; #23 (chunkName plumbing) is F6.4 / issue #13 — deferred.
/// Here we verify the error outcome shape that IS available in 1.12.4.
@Suite("DebuggerIntegration — structured error during debug run")
struct DbgIntStructuredErrorTests {

    @Test("a Lua runtime error in a debug run surfaces as CoreRunOutcome.error with a Diagnostic")
    func runtimeErrorProducesErrorOutcome() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        // Script: pause on line 1, then advance into line 2 which raises an error.
        let script = """
            local x = 1
            error("deliberate failure")
            """
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at pause")
        #expect(pauseSnap.fragmentLine == 1)

        // Step past the pause — next execution hits error("deliberate failure").
        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        // The run must end as .error (not .done or .cancelled).
        guard case .error(let diag, _) = outcome else {
            Issue.record("expected .error outcome, got \(outcome)")
            return
        }
        // Diagnostic must carry the user-facing error text.
        #expect(
            diag.message.contains("deliberate failure"),
            "diagnostic message must contain the Lua error string; got: \(diag.message)")
        // Line must be non-zero — either the raw line or the structured line
        // from LuaSwift #19. Line 2 is where error() was called.
        #expect(diag.line > 0, "diagnostic line must be non-zero for a line-level error")
        #expect(diag.severity == .error)

        // NOTE: chunkName plumbing (LuaSwift #23) which would set frame .source
        // to a human-readable name is F6.4 work tracked in issue #13 and is NOT
        // yet wired through runForDebug. If/when implemented, add an assertion
        // here that the Diagnostic's source or traceback reflects the chunk name.
    }
}

// MARK: - Suite D: UI thread non-blocking during pause

/// Case 4 from task #30: while the VM is parked at a debug pause, the Swift
/// concurrency pool is not blocked. We prove this by running concurrent async
/// work (simulating the UI thread) during a pause and verifying it completes
/// before the VM is unparked.
///
/// The VM parks via `NSCondition.wait()` on the serial executor's OS thread —
/// that is a synchronous park on the DispatchQueue thread, NOT on a Swift
/// concurrency thread. The cooperative thread pool therefore remains available
/// for other Tasks.
@Suite("DebuggerIntegration — UI non-blocking during pause")
struct DbgIntUINotBlockedTests {

    @Test("async Tasks can complete while the VM is parked at a pause (ARCH-07)")
    func asyncTasksRunDuringVMPause() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()
        let uiWorkCompleted = LockFlag()

        let script = "local x = 1\nreturn x"

        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        // Wait until the VM is parked at the breakpoint.
        let pauseSnap = try #require(await stream.next(), "timed out at pause")

        // Launch a concurrent Task (simulating the UI thread doing work) while
        // the VM is parked. This must complete even though runForDebug has not
        // resumed yet — the serial executor's thread is busy with NSCondition.wait,
        // but the Swift cooperative pool is unaffected.
        let uiTask = Task {
            // A brief sleep then mark completion.  If the pool were blocked this
            // would time out and the assertion below would fail.
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            uiWorkCompleted.set()
        }

        // Await the UI task — it should complete well before the watchdog.
        let uiDone = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await uiTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 s watchdog
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        #expect(uiDone, "UI task must complete while VM is parked (cooperative pool not blocked)")
        #expect(uiWorkCompleted.isSet, "uiWorkCompleted flag must be set before unparking the VM")

        // Unpark the VM.
        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Suite D1: Cyclic table → `(cycle)` marker

/// Handover-directed: a cyclic table local renders as `(cycle)` (parens, not
/// angle brackets) in `DebugVariable.displayValue`. This asserts that
/// `inspectedValueToDebugVariable` maps the cycle sentinel correctly.
@Suite("DebuggerIntegration — cycle marker (D1)")
struct DbgIntCycleMarkerTests {

    @Test("a cyclic table local renders as \"(cycle)\" in the pause snapshot (D1)")
    func cyclicTableRendersCycleMarker() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        // Create a self-referential table and pause on the next line.
        let script = """
            local t = {}
            t.self = t
            local _ = 0
            return "done"
            """
        // Breakpoint on line 3 — after the self-reference is installed.
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [3]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause at line 3")
        #expect(snap.fragmentLine == 3)

        // Frame 0 locals should contain `t` (the cyclic table).
        let (locals, _) = snap.frameVars[0] ?? ([], [])
        let tVar = locals.first { $0.name == "t" }
        let tEntry = try #require(tVar, "local 't' must appear in frame 0 vars")

        // The table `t` has a child `self` that points back to `t` itself — a cycle.
        // LuaSwift emits isCycle == true for the child. The adapter maps that to
        // displayValue "(cycle)" (parens, not "<cycle>") per PRD §6.5 / ux-spec.
        let children = tEntry.children ?? []
        let selfChild = children.first { $0.name == "self" }
        let selfEntry = try #require(selfChild, "child 'self' must appear in children of 't'")
        #expect(
            selfEntry.displayValue == "(cycle)",
            "cycle sentinel must be \"(cycle)\" (parens), got: \"\(selfEntry.displayValue)\"")

        engine.sendDebugCommand(snap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Suite D2: globalsElided cap enforcement

/// Handover-directed: when the user-globals slice exceeds
/// `DebugSnapshot.globalsBreadthCap` (256), the re-published snapshot has
/// `globalsElided > 0` and `globals.count == 256`; when it fits,
/// `globalsElided == 0`.
@Suite("DebuggerIntegration — globalsElided breadth cap (D2)")
struct DbgIntGlobalsElidedTests {

    @Test("globals.count == 256 and globalsElided > 0 when >256 user globals are defined (D2)")
    func globalsElisionCapExceeded() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        // Define 300 user globals via a Lua for-loop, then pause on the next line.
        // This is the recommended technique from the task spec when inline definition
        // of 256+ variables in a fragment is impractical.
        let script = """
            for i = 1, 300 do
              _G["g" .. i] = i
            end
            local _ = 0
            return "done"
            """
        // Breakpoint on line 4 — after all 300 globals are installed.
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [4]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at breakpoint")
        #expect(pauseSnap.fragmentLine == 4)
        #expect(pauseSnap.globalsElided == 0, "globals not yet fetched — elided must be 0")

        // Request globals in-place.
        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(await stream.next(), "timed out at globals snapshot")

        // fragmentLine must be IDENTICAL — VM did not advance (DOM-08).
        #expect(
            globalsSnap.fragmentLine == pauseSnap.fragmentLine,
            "VM must not advance during globals capture")

        let globals = try #require(globalsSnap.globals, "globals must be non-nil after requestGlobals")

        // The breadth cap must have been applied.
        #expect(
            globals.count == DebugSnapshot.globalsBreadthCap,
            "globals slice must be capped at \(DebugSnapshot.globalsBreadthCap), got \(globals.count)")

        // At least some of the 300 user globals exceed the cap.
        #expect(
            globalsSnap.globalsElided > 0,
            "globalsElided must be > 0 when >256 user globals are defined; got \(globalsSnap.globalsElided)")

        // The sum of kept + elided must equal the total user globals that passed the
        // filter (300 g1…g300 — all pass because they are not stdlib / blocklist).
        // Other globals that were defined in the engine (e.g. `print`) are excluded
        // by the baseline filter, so the user count is exactly 300.
        let totalFiltered = globals.count + globalsSnap.globalsElided
        #expect(
            totalFiltered == 300,
            "kept (\(globals.count)) + elided (\(globalsSnap.globalsElided)) should equal 300 user globals")

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("globalsElided == 0 when fewer than 256 user globals are defined (D2, baseline)")
    func globalsElisionCapNotExceeded() async throws {
        let engine = try await dbgIntEngine()
        defer { Task { await engine.endSession() } }

        let stream = DbgIntSnapshotStream()

        // Only 5 user globals — well under the cap.
        let script = """
            a1 = 1
            a2 = 2
            a3 = 3
            a4 = 4
            a5 = 5
            local _ = 0
            return "done"
            """
        // Breakpoint on line 6.
        let runTask = Task.detached {
            await engine.runForDebug(dbgIntFrag(script), breakpoints: [6]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at breakpoint")
        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(await stream.next(), "timed out at globals snapshot")
        let globals = try #require(globalsSnap.globals, "globals must be non-nil")

        // Under-cap: elided must be 0.
        #expect(
            globalsSnap.globalsElided == 0,
            "globalsElided must be 0 when fewer than 256 user globals; got \(globalsSnap.globalsElided)")

        // The 5 user globals must be present.
        let names = globals.map(\.name)
        for n in ["a1", "a2", "a3", "a4", "a5"] {
            #expect(names.contains(n), "user global '\(n)' must appear in the globals slice")
        }

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Coverage notes for already-covered cases

// Case 5 (globals two-predicate wake):
//   COVERED by DebugCommandMailboxTests.signalGlobals (SessionEngineTests.swift)
//   and DebugHookAdapterGlobalsTests.globalsCaptureinPlace (DebugHookAdapterTests.swift).
//
// Case 6 (eager in-place capture — fragmentLine unchanged after requestGlobals, DOM-08):
//   COVERED by DebugHookAdapterGlobalsTests.globalsFragmentLineUnchanged.
//
// Case 7 (empty user globals → [] non-nil at early pause and at the last line, DOM-10):
//   COVERED by DebugHookAdapterGlobalsTests.emptyGlobalsIsNonNilEmptySlice.
//
// Case 8 (globalsRequested lifecycle — set → consumed → cleared, PERF-10):
//   COVERED by DebugCommandMailboxTests.signalGlobals (set+consumed) and
//   DebugHookAdapterGlobalsTests.noGlobalsLeakAcrossSessions (cross-session clean).
//
// Case 9 (coroutine frame snapshotted):
//   COVERED by DebugHookAdapterCoroutineTests.coroutineFrameIsSnapshotted.

// MARK: - Private concurrency utilities

/// Thread-safe increment counter for counting onResumed signals.
private final class LockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

/// Thread-safe boolean flag.
private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false
    func set() { lock.withLock { _set = true } }
    var isSet: Bool { lock.withLock { _set } }
}
