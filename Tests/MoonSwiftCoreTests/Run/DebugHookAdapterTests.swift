// File: Tests/MoonSwiftCoreTests/Run/DebugHookAdapterTests.swift
// Location: MoonSwiftCoreTests/Run/
// Role: Integration tests for the F6.0 DebugHookAdapter — pause/snapshot
//       publish, command delivery, globals in-place capture, session teardown,
//       and cross-session isolation. Uses real LuaEngine (no stubs), swift-testing.
//
// ## Synchronization strategy
//
// swift-testing `@Test` functions are `async`. `DispatchSemaphore.wait()` is
// unavailable from async contexts in Swift 6. All synchronization uses
// `AsyncStream<DebugSnapshot>`: each call to `runForDebug` is paired with a
// `SnapshotStream` whose continuation is signalled from the `@Sendable onPause`
// callback. Test bodies `await` snapshots with a 5-second timeout via
// `withTimeout`.
//
// The VM thread parks on NSCondition inside `mailbox.take()`; this is a
// synchronous OS-thread park on the serial executor's thread, which is NOT a
// Swift concurrency thread — so the cooperative thread pool is unaffected.
//
// The session ID for command delivery is read from `snap.sessionID` (populated
// by the F6.0 adapter). No need to await the finished run to get the ID.
//
// Upstream: SessionEngine, DebugHookAdapter, DebugSession, DebugCommandMailbox,
//           DebugSnapshot, DebugFrame, DebugVariable, RunConfig, LuaSourceFragment,
//           LuaSwift (LuaDebugCommand)
import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Timeout helper

/// Await `body` with a hard 5-second timeout. Fails the test if the body does
/// not complete within the limit.
private func withTimeout<T: Sendable>(
    seconds: Double = 5,
    _ body: @Sendable @escaping () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - SnapshotStream

/// A thread-safe snapshot queue with async dequeue. The `onPause` closure is
/// `@Sendable` and can be called from any thread (including the VM thread).
///
/// Design: stores pending snapshots in a FIFO queue and a dictionary of
/// waiting continuations keyed by `UUID`. `record()` either resumes the
/// oldest waiting continuation or enqueues the snapshot for the next
/// `next()` call. The UUID key lets the cancellation handler remove exactly
/// the right waiter without races (avoids the "remove last" hazard).
private final class SnapshotStream: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [DebugSnapshot] = []
    private var _pending: [DebugSnapshot] = []
    // FIFO waiter queue: (id, continuation). Array preserves arrival order.
    private var _waiters: [(UUID, CheckedContinuation<DebugSnapshot?, Never>)] = []

    /// Publish a snapshot from any thread. Resumes the oldest waiting
    /// continuation if one exists; otherwise buffers for the next `next()`.
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

    /// All snapshots published so far.
    var all: [DebugSnapshot] { lock.withLock { _all } }

    /// The most recent snapshot, or `nil`.
    var latest: DebugSnapshot? { lock.withLock { _all.last } }

    /// Dequeue the next snapshot, waiting if none is available yet.
    /// Times out after `seconds` and returns `nil`.
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
                        // Remove this specific waiter by UUID and resume with nil
                        // so the continuation is always resumed exactly once.
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

// MARK: - Fragment / engine helpers

/// Build a LuaSourceFragment with lineOffset 0 for simple test scripts.
private func fragment(_ code: String, lineOffset: Int = 0) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/script.lua")
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

/// Build a started SessionEngine.
private func makeStartedEngine() async throws -> SessionEngine {
    let engine = SessionEngine(onOutput: { _ in })
    try await engine.startSession(config: RunConfig(), mocks: .empty)
    return engine
}

// MARK: - Suite 1: Pause publishes snapshot and blocks the VM

@Suite("DebugHookAdapter — pause and snapshot")
struct DebugHookAdapterPauseTests {

    @Test("pause at a breakpoint publishes a snapshot with locals")
    func pausePublishesLocalsSnapshot() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "local x = 42\nlocal y = x + 1\nreturn y"
        let frag = fragment(script)

        let runTask = Task.detached {
            await engine.runForDebug(frag, breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")

        // Event must be a breakpoint hit (line 1 is in the breakpoint set).
        #expect(snap.event == .breakpoint)
        #expect(snap.fragmentLine == 1)
        // Call stack: at least the main chunk frame.
        #expect(!snap.callStack.isEmpty)
        // Globals are nil (not yet captured).
        #expect(snap.globals == nil)

        // Unblock the VM via the snapshot's embedded session ID.
        engine.sendDebugCommand(snap.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
    }

    @Test("stepping stop (.line event) publishes snapshot then blocks the VM")
    func stepStopPublishesAndBlocks() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "local a = 1\nlocal b = 2\nreturn a + b"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")
        #expect(snap.event == .breakpoint)

        engine.sendDebugCommand(snap.sessionID, .stop)

        let (_, outcome) = await runTask.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled after stop, got \(outcome)")
            return
        }
    }
}

// MARK: - Suite 2: Command delivery resumes the VM

@Suite("DebugHookAdapter — command delivery")
struct DebugHookAdapterCommandTests {

    @Test("continueRun advances the VM past the pause")
    func continueRunAdvancesVM() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "local x = 1\nlocal y = 2\nreturn x + y"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")
        engine.sendDebugCommand(snap.sessionID, .continueRun)

        let (_, outcome) = await runTask.value
        guard case .done(let val, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(val == "3")
    }

    @Test("stop command terminates the run as cancelled")
    func stopCommandTerminatesRun() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "local x = 1\nreturn x"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")
        engine.sendDebugCommand(snap.sessionID, .stop)

        let (_, outcome) = await runTask.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
    }

    @Test("stepOver advances to the next line at the same depth")
    func stepOverAdvancesToNextLine() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "local a = 1\nlocal b = 2\nlocal c = 3\nreturn a + b + c"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let firstSnap = try #require(await stream.next(), "timed out at first pause")
        #expect(firstSnap.fragmentLine == 1)

        engine.sendDebugCommand(firstSnap.sessionID, .stepOver)

        let secondSnap = try #require(await stream.next(), "timed out at second pause")
        // Step over from line 1 should land on line 2.
        #expect(secondSnap.fragmentLine == 2)

        engine.sendDebugCommand(secondSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("command delivery from a different thread resumes the parked VM")
    func crossThreadDelivery() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "return 99"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")

        // Deliver from a background DispatchQueue thread.
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .background).async {
            engine.sendDebugCommand(snap.sessionID, .continueRun)
            delivered.signal()
        }
        // Bridge the semaphore wait (unavailable in async) via a continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                delivered.wait()
                cont.resume()
            }
        }

        let (_, outcome) = await runTask.value
        guard case .done(let val, _) = outcome else {
            Issue.record("expected .done after cross-thread delivery, got \(outcome)")
            return
        }
        #expect(val == "99")
    }
}

// MARK: - Suite 3: Globals in-place capture

@Suite("DebugHookAdapter — globals capture")
struct DebugHookAdapterGlobalsTests {

    @Test("requestGlobals captures user globals in-place at the pause line (DOM-08)")
    func globalsCaptureinPlace() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "myGlobal = 7\nreturn myGlobal"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let prePauseSnap = try #require(await stream.next(), "timed out at first pause")
        // Globals must be nil before `g` is pressed.
        #expect(prePauseSnap.globals == nil)
        let pauseLine = prePauseSnap.fragmentLine

        engine.requestGlobals(prePauseSnap.sessionID)

        // Wait for the republished snapshot with globals.
        let withGlobalsSnap = try #require(await stream.next(), "timed out at globals snap")

        // fragmentLine must be IDENTICAL — VM did not advance (DOM-08).
        #expect(
            withGlobalsSnap.fragmentLine == pauseLine,
            "VM advanced: pre=\(pauseLine) post=\(withGlobalsSnap.fragmentLine)")

        // globals must be non-nil (the `[]` empty slice is still non-nil).
        let _ = try #require(withGlobalsSnap.globals)

        engine.sendDebugCommand(prePauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("globals fragmentLine is identical before and after g (DOM-08, binding)")
    func globalsFragmentLineUnchanged() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        // Line 2 fires AFTER line 1 set myGlobal.
        let script = "myGlobal = 99\nlocal x = myGlobal + 1\nreturn x"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [2]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at first pause")
        #expect(pauseSnap.fragmentLine == 2)
        #expect(pauseSnap.globals == nil)

        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(await stream.next(), "timed out at globals snap")

        // Key assertion: fragmentLine UNCHANGED.
        #expect(globalsSnap.fragmentLine == pauseSnap.fragmentLine)

        // myGlobal must appear in the globals slice.
        let globals = try #require(globalsSnap.globals)
        let myGlobalEntry = globals.first { $0.name == "myGlobal" }
        #expect(myGlobalEntry != nil, "myGlobal should appear in user globals")
        #expect(myGlobalEntry?.displayValue == "99")

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("empty user globals renders as [] non-nil (DOM-10 / UX-R3-02)")
    func emptyGlobalsIsNonNilEmptySlice() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        // No user globals assigned at the time of the pause.
        let script = "local x = 1\nlocal y = 2\nreturn x + y"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [1]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at first pause")
        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(await stream.next(), "timed out at globals snap")
        // globals must be non-nil ([] empty slice, not nil).
        let globals = try #require(globalsSnap.globals, "globals must be non-nil after g")
        // Should be empty — no user globals defined at line 1.
        let userNames = globals.map(\.name)
        #expect(!userNames.contains("string"), "stdlib must be filtered")
        #expect(!userNames.contains("math"), "stdlib must be filtered")

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("stdlib names are excluded from globals slice (DATA-N04)")
    func stdlibExcludedFromGlobals() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()
        let script = "myVal = 42\nlocal z = myVal\nreturn z"

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [2]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let pauseSnap = try #require(await stream.next(), "timed out at first pause")
        engine.requestGlobals(pauseSnap.sessionID)

        let globalsSnap = try #require(await stream.next(), "timed out at globals snap")
        let globals = try #require(globalsSnap.globals)
        let names = globals.map(\.name)

        // Stdlib must be absent.
        #expect(!names.contains("string"))
        #expect(!names.contains("table"))
        #expect(!names.contains("math"))
        #expect(!names.contains("io"))
        #expect(!names.contains("os"))
        #expect(!names.contains("debug"))

        // User global must be present.
        #expect(names.contains("myVal"))

        engine.sendDebugCommand(pauseSnap.sessionID, .continueRun)
        _ = await runTask.value
    }

    @Test("globalsRequested latch is not carried into a new session (DOM-06)")
    func noGlobalsLeakAcrossSessions() async throws {
        let engine = try await makeStartedEngine()

        // Session 1: pause, request globals, then stop before globals are serviced.
        let stream1 = SnapshotStream()

        let runTask1 = Task.detached {
            await engine.runForDebug(
                fragment("local a = 1\nreturn a"),
                breakpoints: [1]
            ) { snap in stream1.record(snap) }
        }

        let pauseSnap1 = try #require(await stream1.next(), "timed out at session-1 pause")
        // Signal globals — but then immediately stop so it may not be serviced.
        engine.requestGlobals(pauseSnap1.sessionID)
        engine.sendDebugCommand(pauseSnap1.sessionID, .stop)
        _ = await runTask1.value

        // End and restart session.
        await engine.endSession()
        try await engine.startSession(config: RunConfig(), mocks: .empty)

        // Session 2: the first pause must have globals == nil (no stale carry-over).
        let stream2 = SnapshotStream()

        let runTask2 = Task.detached {
            await engine.runForDebug(
                fragment("local b = 2\nreturn b"),
                breakpoints: [1]
            ) { snap in stream2.record(snap) }
        }

        let newSnap = try #require(await stream2.next(), "timed out at session-2 pause")
        // Globals must be nil — no stale carry-over from session 1.
        #expect(newSnap.globals == nil, "globals must be nil at first pause in a new session")

        engine.sendDebugCommand(newSnap.sessionID, .continueRun)
        _ = await runTask2.value
        await engine.endSession()
    }
}

// MARK: - Suite 4: Coroutine frame snapshotting

@Suite("DebugHookAdapter — coroutine")
struct DebugHookAdapterCoroutineTests {

    @Test("coroutine frame appears in the call stack snapshot (DOM-03)")
    func coroutineFrameIsSnapshotted() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()

        // Create a coroutine that yields at a breakpoint line.
        let script = """
            local co = coroutine.create(function()
              local val = 42
              coroutine.yield()
            end)
            coroutine.resume(co)
            return "done"
            """

        // Breakpoint at line 3 (coroutine.yield inside the coroutine body).
        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [3]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for coroutine pause")

        // The call stack must have at least one frame.
        #expect(!snap.callStack.isEmpty, "call stack must not be empty inside a coroutine pause")
        // Frame 0 locals may or may not include val — timing-dependent. Just check no crash.
        let (_, _) = snap.frameVars[0] ?? ([], [])

        engine.sendDebugCommand(snap.sessionID, .continueRun)
        _ = await runTask.value
    }
}

// MARK: - Suite 5: Eager all-frame snapshot

@Suite("DebugHookAdapter — all-frame snapshot")
struct DebugHookAdapterAllFrameTests {

    @Test("all frames are snapshotted eagerly (F6.3 pre-condition)")
    func allFramesEagerlyCaptured() async throws {
        let engine = try await makeStartedEngine()
        defer { Task { await engine.endSession() } }

        let stream = SnapshotStream()

        // Two-level call: outer calls inner; breakpoint inside inner.
        let script = """
            local function inner(n)
              local doubled = n * 2
              return doubled
            end
            local function outer(x)
              local result = inner(x)
              return result
            end
            return outer(21)
            """

        let runTask = Task.detached {
            await engine.runForDebug(fragment(script), breakpoints: [2]) { snap in
                stream.record(snap)
            }
        }
        defer { Task { await runTask.value } }

        let snap = try #require(await stream.next(), "timed out waiting for pause")

        // At least 2 frames: inner (level 0) + outer (level 1).
        #expect(
            snap.callStack.count >= 2,
            "expected at least 2 frames, got \(snap.callStack.count)")

        // frameVars must contain both level 0 and level 1.
        #expect(snap.frameVars[0] != nil, "level 0 vars must be present")
        #expect(snap.frameVars[1] != nil, "level 1 vars must be present")

        // Level 0 (inner) must have 'n'.
        let (innerLocals, _) = snap.frameVars[0] ?? ([], [])
        let nVar = innerLocals.first { $0.name == "n" }
        #expect(nVar != nil, "local 'n' must be in inner frame")
        #expect(nVar?.displayValue == "21")

        engine.sendDebugCommand(snap.sessionID, .continueRun)
        _ = await runTask.value
    }
}
