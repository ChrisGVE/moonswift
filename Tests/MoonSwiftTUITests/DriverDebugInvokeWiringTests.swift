// File: Tests/MoonSwiftTUITests/DriverDebugInvokeWiringTests.swift
// Location: MoonSwiftTUITests/
// Role: Driver-level wiring tests for the P2 debug-run pipeline (CR-013) and the
//       three-control invoke pipeline (CR-014). A spy `SessionEngineProtocol`
//       records every call the AppDriver effect handlers make and drives the
//       `onPause`/`onResumed` callbacks, so we can assert that
//       `executeDebugRun` / `executeStopDebug` / `executeSendDebugCommand` /
//       `executeRequestGlobals` reach the engine and post the right events, and
//       that `executeInvokeLuaCall` maps each outcome (success, target-invalid,
//       not-callable, enginePaused, not-started) to the correct event/transient.
//
//       The effect handlers spawn detached Tasks and post results to the
//       EventChannel; the driver's run loop is NOT started here, so the posted
//       events accumulate and are collected via `drainAll()` under a polling
//       deadline (same CI-thread-starvation tolerance as DriverIntegrationTests).
//
// Upstream: AppDriver (executeDebugRun/…/executeInvokeLuaCall), SessionEngineProtocol
// Downstream: (test target only)

import CryptoKit
import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit
import Testing
import os

@testable import MoonSwiftTUI

// MARK: - Spy session engine

/// Records the AppDriver's engine calls and drives the debug callbacks.
private final class SpySessionEngine: SessionEngineProtocol, @unchecked Sendable {
    struct Recorded {
        var runForDebugCode: String?
        var runForDebugBreakpoints: Set<Int>?
        var sentCommands: [(DebugSessionID, LuaDebugCommand)] = []
        var requestedGlobals: [DebugSessionID] = []
        var invokeExpression: String?
    }

    let state = OSAllocatedUnfairLock<Recorded>(initialState: Recorded())
    let fixedSessionID = DebugSessionID()

    /// When true, `runForDebug` delivers one pause snapshot (carrying this
    /// engine's `fixedSessionID`) via `onPause` before the run "finishes".
    private let deliverPause: Bool
    private let debugOutcome: CoreRunOutcome
    private let invokeResult: Result<LuaValue, Error>

    init(
        deliverPause: Bool = false,
        debugOutcome: CoreRunOutcome = .done(value: nil, duration: .zero),
        invokeResult: Result<LuaValue, Error> = .success(.number(1))
    ) {
        self.deliverPause = deliverPause
        self.debugOutcome = debugOutcome
        self.invokeResult = invokeResult
    }

    func startSession(config: RunConfig, mocks: MockStore) async throws {}
    func sessionRun(_ fragment: LuaSourceFragment) async -> CoreRunOutcome { .cancelled }

    func runForDebug(
        _ fragment: LuaSourceFragment,
        breakpoints: Set<Int>,
        onPause: @escaping @Sendable (DebugSnapshot) -> Void,
        onResumed: @escaping @Sendable (DebugSessionID) -> Void
    ) async -> (DebugSessionID, CoreRunOutcome) {
        state.withLock {
            $0.runForDebugCode = fragment.code
            $0.runForDebugBreakpoints = breakpoints
        }
        if deliverPause {
            onPause(
                DebugSnapshot(
                    sessionID: fixedSessionID, event: .breakpoint, fragmentLine: 1,
                    callStack: [], frameVars: [:], globals: nil, pauseSequence: 1))
        }
        onResumed(fixedSessionID)
        return (fixedSessionID, debugOutcome)
    }

    nonisolated func sendDebugCommand(_ id: DebugSessionID, _ command: LuaDebugCommand) {
        state.withLock { $0.sentCommands.append((id, command)) }
    }
    nonisolated func requestPause(_ id: DebugSessionID) {}
    nonisolated func requestGlobals(_ id: DebugSessionID) {
        state.withLock { $0.requestedGlobals.append(id) }
    }
    nonisolated func cancelRun() {}

    func invokeLuaCall(_ callExpression: String) async throws -> LuaValue {
        state.withLock { $0.invokeExpression = callExpression }
        return try invokeResult.get()
    }

    func liveState() async -> MockLiveState { .empty }
    func endSession() async {}
}

// MARK: - Helpers

private func wiringFragment(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/tests/wiring.lua")
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: url, jsonpath: nil, document: 0,
        byteRange: 0..<data.count, lineOffset: 0, contentHash: SHA256.hash(data: data))
    return LuaSourceFragment(code: code, provenance: provenance)
}

private func makeDriver(engine: SpySessionEngine, channel: EventChannel) -> AppDriver {
    let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
    let tick = TickSource(channel: channel)
    return AppDriver(
        channel: channel, pump: pump, tickSource: tick, seed: AppState(),
        sessionEngine: engine)
}

/// Collect posted events across repeated `drainAll()` calls until `count` arrive
/// or the deadline elapses. The driver loop is not running, so nothing else
/// consumes the channel.
private func collectEvents(
    from channel: EventChannel, count: Int, timeout: TimeInterval = 10.0
) -> [AppEvent] {
    var events: [AppEvent] = []
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        events += channel.drainAll()
        if events.count >= count { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return events
}

// MARK: - CR-013: debug-run pipeline wiring

@Suite("Driver debug-run wiring (CR-013)", .serialized)
struct DriverDebugWiringTests {

    @Test("executeDebugRun calls runForDebug and posts paused → resumed → finished")
    func debugRunPipeline() {
        let channel = EventChannel()
        let engine = SpySessionEngine(deliverPause: true)
        let driver = makeDriver(engine: engine, channel: channel)

        driver.executeDebugRun(wiringFragment("return 1"), breakpoints: [2])

        let events = collectEvents(from: channel, count: 3)
        #expect(engine.state.withLock { $0.runForDebugCode } == "return 1")
        #expect(engine.state.withLock { $0.runForDebugBreakpoints } == [2])

        // Order: debugPaused, debugResumed, debugFinished.
        var sawPaused = false
        var sawResumed = false
        var sawFinished = false
        for e in events {
            switch e {
            case .debugPaused: sawPaused = true
            case .debugResumed(let id): sawResumed = (id == engine.fixedSessionID)
            case .debugFinished(let id, _): sawFinished = (id == engine.fixedSessionID)
            default: break
            }
        }
        #expect(sawPaused)
        #expect(sawResumed)
        #expect(sawFinished)
    }

    @Test("executeStopDebug delivers .stop to the engine")
    func stopDebugWiring() {
        let channel = EventChannel()
        let engine = SpySessionEngine()
        let driver = makeDriver(engine: engine, channel: channel)
        let id = engine.fixedSessionID

        driver.executeStopDebug(id)

        let sent = engine.state.withLock { $0.sentCommands }
        #expect(sent.count == 1)
        #expect(sent.first?.1 == .stop)
    }

    @Test("executeSendDebugCommand forwards the command to the engine")
    func sendCommandWiring() {
        let channel = EventChannel()
        let engine = SpySessionEngine()
        let driver = makeDriver(engine: engine, channel: channel)
        let id = engine.fixedSessionID

        driver.executeSendDebugCommand(id, .stepOver)

        let sent = engine.state.withLock { $0.sentCommands }
        #expect(sent.first?.1 == .stepOver)
    }

    @Test("executeRequestGlobals latches a globals request on the engine")
    func requestGlobalsWiring() {
        let channel = EventChannel()
        let engine = SpySessionEngine()
        let driver = makeDriver(engine: engine, channel: channel)
        let id = engine.fixedSessionID

        driver.executeRequestGlobals(id)

        #expect(engine.state.withLock { $0.requestedGlobals } == [id])
    }
}

// MARK: - CR-014: invoke pipeline wiring

@Suite("Driver invoke wiring (CR-014)", .serialized)
struct DriverInvokeWiringTests {

    private func runInvoke(
        _ expression: String, invokeResult: Result<LuaValue, Error>
    ) -> [AppEvent] {
        let channel = EventChannel()
        let engine = SpySessionEngine(invokeResult: invokeResult)
        let driver = makeDriver(engine: engine, channel: channel)
        driver.executeInvokeLuaCall(expression)
        return collectEvents(from: channel, count: 1)
    }

    @Test("a valid call posts the rendered result")
    func invokeSuccess() {
        let events = runInvoke("f()", invokeResult: .success(.number(42)))
        let display = events.compactMap { e -> String? in
            if case .luaInvocationResult(let d) = e { return d } else { return nil }
        }.first
        #expect(display == "42")
    }

    @Test("a dotted target posts targetInvalid before any engine call")
    func invokeTargetInvalid() {
        let events = runInvoke("a.b()", invokeResult: .success(.number(1)))
        let invalid = events.contains { if case .luaInvocationTargetInvalid = $0 { return true } else { return false } }
        #expect(invalid)
    }

    @Test("a not-callable failure maps to the not-a-function transient (CR-022)")
    func invokeNotCallable() {
        let err = LuaError.runtimeError("test.lua:1: attempt to call a nil value (global 'f')")
        let events = runInvoke("f()", invokeResult: .failure(err))
        let transient = events.compactMap { e -> String? in
            if case .transient(let t) = e { return t } else { return nil }
        }.first
        #expect(transient == "f is not a function.")
    }

    @Test("enginePaused maps to a short transient, not the raw description (CR-021)")
    func invokeEnginePaused() {
        let events = runInvoke("f()", invokeResult: .failure(SessionEngineError.enginePaused))
        let transient = events.compactMap { e -> String? in
            if case .transient(let t) = e { return t } else { return nil }
        }.first
        #expect(transient == "Invoke unavailable while a run or debug session is active.")
    }

    @Test("notStarted maps to the no-session transient")
    func invokeNotStarted() {
        let events = runInvoke("f()", invokeResult: .failure(SessionEngineError.notStarted))
        let transient = events.compactMap { e -> String? in
            if case .transient(let t) = e { return t } else { return nil }
        }.first
        #expect(transient == "Invoke a Lua function: run the source first.")
    }
}
