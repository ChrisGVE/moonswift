// File: Tests/MoonSwiftCoreTests/Run/SessionEngineTests.swift
// Location: MoonSwiftCoreTests/Run/
// Role: Tests for the F5.0 SessionEngine foundation — session survival across a
//       run, RunConfigMode inheritance, the RunState gate (DOM-02), live-state
//       introspection, implicit end-session / engine discard, and the
//       DebugSession mailbox ownership + command routing. All tests use the
//       production SessionEngine with a real LuaEngine (LuaSwift 1.12.4); no
//       stubs. Heavier integration coverage lives in #27/#36.
// Upstream: SessionEngine, SessionEngineProtocol, MockStore, MockLiveState,
//           DebugSession, DebugCommandMailbox, RunConfig, LuaSourceFragment,
//           FragmentProvenance, CoreRunOutcome
import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Thread-safe collector for captured print output. Uses `withLock` (the
/// async-safe scoped form) so `all` can be polled from an async test body.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) {
        lock.withLock { lines.append(s) }
    }
    var all: [String] {
        lock.withLock { lines }
    }
}

/// Builds a `LuaSourceFragment` from raw Lua code with a synthetic provenance.
private func fragment(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/script.lua")
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

private func makeEngine(_ collector: OutputCollector = OutputCollector()) -> SessionEngine {
    SessionEngine(onOutput: { collector.append($0) })
}

// MARK: - Session survival + invocation

@Suite("SessionEngine — session lifecycle")
struct SessionEngineLifecycleTests {

    @Test("engine survives a run; invocation sees post-run state")
    func sessionSurvival() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        let outcome = await engine.sessionRun(fragment("x = 41"))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        // A global set by the run is visible to a later invocation — proving the
        // engine survived (distinct from RunService run-and-discard).
        let value = try await engine.invokeLuaCall("x + 1")
        #expect(value == .number(42))
        await engine.endSession()
    }

    @Test("sessionRun returns the evaluated value and captures print output")
    func sessionRunOutcomeAndOutput() async throws {
        let collector = OutputCollector()
        let engine = makeEngine(collector)
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        let outcome = await engine.sessionRun(fragment("print(\"hi\")\nreturn 1 + 2"))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "3")
        #expect(collector.all == ["hi"])
        await engine.endSession()
    }

    @Test("invokeLuaCall before startSession throws notStarted")
    func invokeBeforeStart() async {
        let engine = makeEngine()
        await #expect(throws: SessionEngineError.notStarted) {
            _ = try await engine.invokeLuaCall("1 + 1")
        }
    }

    @Test("a new session discards the prior engine (no global leak)")
    func newSessionDiscardsPrior() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(fragment("leaked = 99"))
        await engine.endSession()

        // Fresh session: the prior global must be gone.
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(fragment("fresh = 1"))
        let live = await engine.liveState()
        #expect(live.userGlobals.map(\.name).contains("fresh"))
        #expect(!live.userGlobals.map(\.name).contains("leaked"))
        await engine.endSession()
    }
}

// MARK: - RunConfigMode inheritance

@Suite("SessionEngine — RunConfigMode inheritance")
struct SessionEngineModeTests {

    @Test("sandboxed mode strips io and unsafe os fns (never hardcoded)")
    func sandboxedStripsUnsafe() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(config: .sandboxed), mocks: .empty)
        // io / debug are removed wholesale; os keeps only its safe functions.
        #expect(try await engine.invokeLuaCall("type(io)") == .string("nil"))
        #expect(try await engine.invokeLuaCall("type(os.execute)") == .string("nil"))
        await engine.endSession()
    }

    @Test("unrestricted mode exposes io and unsafe os fns")
    func unrestrictedExposesUnsafe() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(config: .unrestricted), mocks: .empty)
        #expect(try await engine.invokeLuaCall("type(io)") == .string("table"))
        #expect(try await engine.invokeLuaCall("type(os.execute)") == .string("function"))
        await engine.endSession()
    }
}

// MARK: - RunState gate (DOM-02)

@Suite("SessionEngine — RunState gate")
struct SessionEngineRunStateTests {

    @Test("liveState returns empty while a run is executing")
    func liveStateEmptyMidRun() async throws {
        // Park the run mid-flight inside the print sink (deterministic, zero
        // CPU burn — avoids starving timing-sensitive parallel suites). When the
        // sink sees "started" the run is in-flight (RunState == .running) on the
        // serial executor; the gate's fast path must return empty WITHOUT
        // dispatching onto the (blocked) executor.
        let collector = OutputCollector()
        let proceed = DispatchSemaphore(value: 0)
        let engine = SessionEngine(onOutput: { line in
            collector.append(line)
            // Park the serial executor here while still RunState == .running.
            // `wait` from this synchronous closure is allowed (the test body's
            // async context is not).
            if line == "started" {
                _ = proceed.wait(timeout: .now() + 5)
            }
        })
        try await engine.startSession(config: RunConfig(), mocks: .empty)

        async let running = engine.sessionRun(
            fragment("print(\"started\")\nbusy = 1\nreturn 1")
        )
        // Poll (async-safe) until the sink has recorded "started": at that point
        // the run is parked in the sink with RunState == .running.
        var waited = 0
        while !collector.all.contains("started") && waited < 1000 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(collector.all.contains("started"))

        let midRun = await engine.liveState()
        #expect(midRun.isEmpty)
        #expect(midRun.userGlobals.isEmpty)

        proceed.signal()
        _ = await running
        // After completion (RunState -> .idle) the real globals are visible.
        let afterRun = await engine.liveState()
        #expect(!afterRun.isEmpty)
        #expect(afterRun.userGlobals.map(\.name).contains("busy"))
        await engine.endSession()
    }

    @Test("liveState after a run returns user globals, not stdlib")
    func liveStateIdleUserGlobals() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(fragment("myGlobal = 7"))
        let live = await engine.liveState()
        #expect(!live.isEmpty)
        let names = live.userGlobals.map(\.name)
        #expect(names.contains("myGlobal"))
        // stdlib names captured in the baseline must not leak into user globals.
        #expect(!names.contains("string"))
        #expect(!names.contains("math"))
        let myGlobal = live.userGlobals.first { $0.name == "myGlobal" }
        #expect(myGlobal?.displayValue == "7")
        await engine.endSession()
    }

    @Test("liveState returns empty after endSession")
    func liveStateEmptyAfterEnd() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(fragment("g = 1"))
        await engine.endSession()
        let live = await engine.liveState()
        #expect(live.isEmpty)
    }
}

// MARK: - Error outcomes

@Suite("SessionEngine — outcomes")
struct SessionEngineOutcomeTests {

    @Test("syntax error in a run surfaces an error outcome")
    func syntaxError() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        let outcome = await engine.sessionRun(fragment("return ==="))
        guard case .error = outcome else {
            Issue.record("expected .error, got \(outcome)")
            return
        }
        await engine.endSession()
    }

    @Test("instruction limit fires as limitExceeded")
    func instructionLimit() async throws {
        let engine = makeEngine()
        try await engine.startSession(
            config: RunConfig(instructionLimit: 10_000),
            mocks: .empty
        )
        let outcome = await engine.sessionRun(
            fragment("local s = 0\nwhile true do s = s + 1 end")
        )
        guard case .limitExceeded(let kind) = outcome else {
            Issue.record("expected .limitExceeded, got \(outcome)")
            return
        }
        #expect(kind == .instructions(count: 10_000))
        await engine.endSession()
    }
}

// MARK: - runForDebug + mailbox ownership

@Suite("SessionEngine — debug session ownership")
struct SessionEngineDebugOwnershipTests {

    @Test("runForDebug runs the fragment and returns id + outcome")
    func runForDebugRuns() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        let (_, outcome) = await engine.runForDebug(
            fragment("return 5"),
            breakpoints: [],
            onPause: { _ in }
        )
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "5")
        await engine.endSession()
    }

    @Test("command delivery to a stale / unknown id is a silent no-op")
    func staleCommandNoOp() async throws {
        let engine = makeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        let (id, _) = await engine.runForDebug(
            fragment("return 1"),
            breakpoints: [],
            onPause: { _ in }
        )
        // The session ended at completion; these must not crash.
        engine.sendDebugCommand(id, .stop)
        engine.requestPause(id)
        engine.requestGlobals(id)
        // A never-registered id likewise.
        engine.sendDebugCommand(DebugSessionID(), .continueRun)
        await engine.endSession()
    }
}

// MARK: - DebugCommandMailbox

@Suite("DebugCommandMailbox")
struct DebugCommandMailboxTests {

    @Test("put then take returns the command")
    func putTake() {
        let mailbox = DebugCommandMailbox()
        mailbox.put(.continueRun)
        guard case .command(let cmd) = mailbox.take() else {
            Issue.record("expected .command")
            return
        }
        #expect(cmd == .continueRun)
    }

    @Test("signalGlobals then take returns serviceGlobals and clears the latch")
    func signalGlobals() {
        let mailbox = DebugCommandMailbox()
        mailbox.signalGlobals()
        #expect(mailbox.globalsRequestedSnapshot)
        guard case .serviceGlobals = mailbox.take() else {
            Issue.record("expected .serviceGlobals")
            return
        }
        #expect(!mailbox.globalsRequestedSnapshot)
    }

    @Test("command slot takes priority over a pending globals latch")
    func commandBeforeGlobals() {
        let mailbox = DebugCommandMailbox()
        mailbox.signalGlobals()
        mailbox.put(.stop)
        // First take services the command...
        guard case .command(let cmd) = mailbox.take(), cmd == .stop else {
            Issue.record("expected .command(.stop) first")
            return
        }
        // ...then the still-pending globals latch.
        guard case .serviceGlobals = mailbox.take() else {
            Issue.record("expected .serviceGlobals second")
            return
        }
    }

    @Test("DebugSession routes a delivered command to its mailbox")
    func sessionRoutesCommand() {
        let session = DebugSession(breakpoints: [3, 7])
        session.deliver(.stepOver)
        guard case .command(let cmd) = session.mailbox.take(), cmd == .stepOver else {
            Issue.record("expected .stepOver routed to the mailbox")
            return
        }
        #expect(session.breakpoints == [3, 7])
    }

    @Test("DebugSession pause latch is read-and-cleared")
    func pauseLatch() {
        let session = DebugSession()
        #expect(!session.consumePauseRequested())
        session.requestPause()
        #expect(session.consumePauseRequested())
        #expect(!session.consumePauseRequested())
    }

    // #24: concurrency stress. The mailbox is single-slot OVERWRITE-LAST
    // (PERF-10): concurrent producers may legitimately drop intermediate
    // commands — "exactly-once delivery" is NOT an invariant of this design.
    // The binding requirement (risk R1) is that contention never deadlocks the
    // parked consumer, never loses a wakeup, and never yields a malformed Wake.
    // We hammer N producers against one consumer, then deliver a terminal
    // `.stop` once every producer has returned; the consumer MUST observe it
    // and terminate well inside the watchdog ceiling.
    @Test("concurrent producers never deadlock or lose a wakeup (overwrite-last, R1)")
    func concurrentProducersNoDeadlockNoLostWakeup() {
        let mailbox = DebugCommandMailbox()
        let producerCount = 64

        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var commandsSeen = 0
            var sawStop = false
            var sawServiceGlobals = false
        }
        let outcome = Outcome()

        // Consumer parks in take() and drains until it observes the terminal stop.
        let consumer = Thread {
            while true {
                switch mailbox.take() {
                case .command(let cmd):
                    outcome.lock.withLock { outcome.commandsSeen += 1 }
                    if cmd == .stop {
                        outcome.lock.withLock { outcome.sawStop = true }
                        return
                    }
                case .serviceGlobals:
                    // No signalGlobals is issued here, so this must never occur.
                    outcome.lock.withLock { outcome.sawServiceGlobals = true }
                    return
                }
            }
        }
        consumer.start()

        // N producers hammer the single slot concurrently.
        DispatchQueue.concurrentPerform(iterations: producerCount) { _ in
            mailbox.put(.stepOver)
        }
        // Every producer has returned; deliver the terminal command.
        mailbox.put(.stop)

        // Bounded join: terminate the test far before the 300 s watchdog.
        let deadline = Date(timeIntervalSinceNow: 10)
        while !consumer.isFinished {
            if Date() > deadline {
                Issue.record("consumer did not terminate — deadlock or lost wakeup")
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        outcome.lock.withLock {
            #expect(outcome.sawStop, "terminal .stop must be observed (no lost wakeup)")
            #expect(!outcome.sawServiceGlobals, "no .serviceGlobals without signalGlobals")
            #expect(outcome.commandsSeen >= 1, "at least the terminal command is delivered")
            #expect(
                outcome.commandsSeen <= producerCount + 1,
                "overwrite-last bounds total deliveries")
        }
    }
}
