// File: Tests/MoonSwiftCoreTests/F6DebugTapeTests.swift
// Location: MoonSwiftCoreTests/
// Role: F6 acceptance tape — end-to-end debugger flow: breakpoint → pause →
//       step → inspect globals (requestGlobals) → continue. Drives the REAL
//       SessionEngine via runForDebug, asserts the pause snapshot, verifies a
//       stepOver advances the line, confirms requestGlobals produces a non-nil
//       globals slice in the republished snapshot, and confirms continueRun
//       finishes the run cleanly.
//
//       ANTI-HANG contract (see task #34 brief):
//         - Every `await stream.next()` is bounded by the 5-second default
//           timeout in F6TapeSnapshotStream.next().
//         - The VM is ALWAYS unparked (via .continueRun or .stop) before
//           awaiting runTask.value. A parked VM emits no further snapshots
//           and hangs forever if awaited directly.
//         - The `defer` block delivers .stop to the session ID captured from
//           the first pause, so if a test body fails early the VM is still
//           released.
//
//       Helper names are prefixed `f6Tape` to avoid collisions.
//
// Upstream: SessionEngine, DebugSnapshot, DebugSessionID, LuaSourceFragment,
//           FragmentProvenance, CoreRunOutcome, RunConfig
// Downstream: (test target only)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Snapshot stream (f6Tape-prefixed)

/// Thread-safe snapshot sink + bounded-wait getter.
/// Named `F6TapeSnapshotStream` to avoid collision with `DbgIntSnapshotStream`
/// in DebuggerIntegrationTests.swift.
private final class F6TapeSnapshotStream: @unchecked Sendable {
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

    /// Returns the next snapshot or `nil` on timeout (default 5 s).
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
                        var w: CheckedContinuation<DebugSnapshot?, Never>?
                        self.lock.withLock {
                            if let idx = self._waiters.firstIndex(where: { $0.0 == id }) {
                                w = self._waiters.remove(at: idx).1
                            }
                        }
                        w?.resume(returning: nil)
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

// MARK: - Helpers

private func f6TapeEngine() async throws -> SessionEngine {
    let engine = SessionEngine(onOutput: { _ in })
    try await engine.startSession(config: RunConfig(), mocks: .empty)
    return engine
}

private func f6TapeFrag(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/f6-tape.lua")
    let data = Data(code.utf8)
    let prov = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: prov)
}

// MARK: - Suite: F6 debug acceptance tape

@Suite("F6 acceptance — debugger tape (breakpoint → step → globals → continue)")
struct F6DebugTapeTests {

    /// Tape 1: breakpoint pause, stepOver advances line, continueRun finishes run.
    ///
    /// Asserts:
    ///   - First pause snapshot has `.event == .breakpoint` and `fragmentLine == 2`.
    ///   - After stepOver the second snapshot has `.event == .line` and a later line.
    ///   - After continueRun the run outcome is `.done`.
    @Test("breakpoint pauses; stepOver advances line; continueRun finishes")
    func breakpointStepContinue() async throws {
        let engine = try await f6TapeEngine()
        defer { Task { await engine.endSession() } }

        let stream = F6TapeSnapshotStream()

        let script = """
            local a = 1
            local b = 2
            local c = a + b
            return c
            """
        // Breakpoint on line 2.
        let runTask = Task.detached {
            await engine.runForDebug(f6TapeFrag(script), breakpoints: [2]) { snap in
                stream.record(snap)
            }
        }

        // First pause at the breakpoint.
        let snap1 = try #require(
            await stream.next(),
            "timed out waiting for breakpoint pause"
        )
        #expect(snap1.event == .breakpoint, "first pause must be .breakpoint")
        #expect(snap1.fragmentLine == 2, "first pause must be at line 2")

        // stepOver from line 2 → should land on line 3.
        engine.sendDebugCommand(snap1.sessionID, .stepOver)

        let snap2 = try #require(
            await stream.next(),
            "timed out waiting for stepOver pause"
        )
        #expect(snap2.event == .line, "stepOver stop must be .line, not .breakpoint")
        #expect(snap2.fragmentLine > 2, "stepOver must advance past line 2")

        // Continue to completion — unpark before awaiting runTask.
        engine.sendDebugCommand(snap2.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        guard case .done(let val, _) = outcome else {
            Issue.record("expected .done outcome, got \(outcome)")
            return
        }
        #expect(val == "3", "return value must be 3 (1+2); got \(String(describing: val))")
    }

    /// Tape 2: requestGlobals in-place produces a non-nil globals slice without
    /// advancing the VM (DOM-08).
    ///
    /// Asserts:
    ///   - Pause snapshot at breakpoint has `globals == nil` (not yet requested).
    ///   - After requestGlobals, the republished snapshot has non-nil `globals`.
    ///   - `fragmentLine` is unchanged after requestGlobals (VM did not advance).
    @Test("requestGlobals produces non-nil globals; VM does not advance (DOM-08)")
    func requestGlobalsInPlace() async throws {
        let engine = try await f6TapeEngine()
        defer { Task { await engine.endSession() } }

        let stream = F6TapeSnapshotStream()

        // Define some user globals before the pause line.
        let script = """
            alpha = 42
            beta = "hello"
            local _ = 0
            return "done"
            """
        // Breakpoint on line 3 (after globals are set).
        let runTask = Task.detached {
            await engine.runForDebug(f6TapeFrag(script), breakpoints: [3]) { snap in
                stream.record(snap)
            }
        }

        let pauseSnap = try #require(
            await stream.next(),
            "timed out waiting for breakpoint"
        )
        #expect(pauseSnap.fragmentLine == 3)
        #expect(pauseSnap.globals == nil, "globals must be nil before requestGlobals")

        // Request globals in-place — VM stays parked.
        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(
            await stream.next(),
            "timed out waiting for globals snapshot"
        )

        // VM must not have advanced.
        #expect(
            globalsSnap.fragmentLine == pauseSnap.fragmentLine,
            "VM must not advance during requestGlobals (DOM-08)")

        let globals = try #require(globalsSnap.globals, "globals must be non-nil after request")
        let names = globals.map(\.name)
        #expect(names.contains("alpha"), "'alpha' must appear in globals")
        #expect(names.contains("beta"), "'beta' must appear in globals")

        // Unpark before awaiting.
        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    /// Tape 3: stepInto descends into a nested function; stepOut returns to caller.
    ///
    /// Asserts:
    ///   - After stepInto the snapshot is inside the function body (deeper stack).
    ///   - After stepOut the stack is shallower or line is past the call site.
    @Test("stepInto descends into function; stepOut returns to caller")
    func stepIntoAndOut() async throws {
        let engine = try await f6TapeEngine()
        defer { Task { await engine.endSession() } }

        let stream = F6TapeSnapshotStream()

        let script = """
            local function double(n)
              return n * 2
            end
            local x = double(5)
            return x
            """
        // Breakpoint on line 4 (the call site).
        let runTask = Task.detached {
            await engine.runForDebug(f6TapeFrag(script), breakpoints: [4]) { snap in
                stream.record(snap)
            }
        }

        let callSite = try #require(await stream.next(), "timed out at call-site breakpoint")
        #expect(callSite.fragmentLine == 4)
        let callStackDepth = callSite.callStack.count

        // stepInto — descend into double().
        engine.sendDebugCommand(callSite.sessionID, .stepInto)

        let innerSnap = try #require(await stream.next(), "timed out inside double()")
        #expect(innerSnap.event == .line, "stepInto stop must be .line")
        #expect(
            innerSnap.callStack.count > callStackDepth,
            "stepInto must deepen the call stack")

        // stepOut — return to caller.
        engine.sendDebugCommand(innerSnap.sessionID, .stepOut)

        let callerSnap = try #require(await stream.next(), "timed out after stepOut")
        #expect(callerSnap.event == .line, "stepOut stop must be .line")
        #expect(
            callerSnap.callStack.count < innerSnap.callStack.count
                || callerSnap.fragmentLine > 4,
            "stepOut must return to the caller scope")

        // Finish the run.
        engine.sendDebugCommand(callerSnap.sessionID, .continueRun)
        let (_, outcome) = await runTask.value
        guard case .done(let val, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(val == "10", "return value must be 10 (5*2); got \(String(describing: val))")
    }

    /// Tape 4: a runtime error during a debug run surfaces as CoreRunOutcome.error.
    ///
    /// Asserts:
    ///   - Pause snapshot arrives at the breakpoint.
    ///   - After continueRun the outcome is `.error` with a populated Diagnostic.
    @Test("runtime error during debug run surfaces as CoreRunOutcome.error with Diagnostic")
    func runtimeErrorInDebugRun() async throws {
        let engine = try await f6TapeEngine()
        defer { Task { await engine.endSession() } }

        let stream = F6TapeSnapshotStream()

        let script = """
            local x = 1
            error("tape-deliberate-failure")
            """
        // Breakpoint on line 1, then continue into the error.
        let runTask = Task.detached {
            await engine.runForDebug(f6TapeFrag(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }

        let pauseSnap = try #require(await stream.next(), "timed out at breakpoint")
        #expect(pauseSnap.fragmentLine == 1)

        // Continue — hits error() on line 2.
        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        guard case .error(let diag, _) = outcome else {
            Issue.record("expected .error outcome, got \(outcome)")
            return
        }
        #expect(
            diag.message.contains("tape-deliberate-failure"),
            "error message must contain the Lua error text; got: \(diag.message)")
        #expect(diag.severity == .error)
        #expect(diag.line > 0, "error line must be non-zero")
    }
}
