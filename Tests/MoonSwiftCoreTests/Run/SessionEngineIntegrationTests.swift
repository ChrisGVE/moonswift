// File: Tests/MoonSwiftCoreTests/Run/SessionEngineIntegrationTests.swift
// Location: MoonSwiftCoreTests/Run/
// Role: Integration tests for the F5.0 SessionEngine lifecycle and RunState gate
//       using the real LuaSwift 1.12.4 pipeline. Task #27 in p2-p3 tag.
//
//       Coverage map (task #27 requirements vs SessionEngineTests.swift):
//
//       Case 1 — engine survives a run: COVERED in SessionEngineTests.swift
//         (`sessionSurvival`). NOT re-tested here.
//
//       Case 2 — mock-aware sessionRun keeps engine alive (persona A7):
//         PARTIALLY covered (survival aspect) in SessionEngineTests.swift but
//         NOT with a non-empty MockStore. Added here: `sessionRunWithMocks` —
//         verifies that liveState() after sessionRun returns mock values and
//         function names sourced via registeredValueServerNames /
//         registeredFunctionNames introspection, never parallel bookkeeping.
//
//       Case 3 — sessionRunFinished → liveState trigger (CONS-R4-01):
//         The trigger mechanism is reducer-side (AppDriver posts sessionRunFinished;
//         reducer emits Effect.queryLiveState). Engine-side contract: liveState()
//         after sessionRun returns a state with isEmpty == false (so the reducer
//         knows a real snapshot is available). Added here: `liveStateNotEmptyAfterRun`.
//
//       Case 4 — RunConfigMode inheritance: COVERED in SessionEngineTests.swift
//         (`sandboxedStripsUnsafe`, `unrestrictedExposesUnsafe`). NOT re-tested here.
//
//       Case 5 — RunState gate: liveState while .running returns empty, after .idle
//         returns real globals: COVERED in SessionEngineTests.swift
//         (`liveStateEmptyMidRun`, `liveStateIdleUserGlobals`). invokeLuaCall while
//         .running throws NOT yet covered. Added here: `invokeLuaCallThrowsWhileRunning`.
//
//       Case 6 — liveState cache (called at most once per run): Cache is reducer/
//         AppState policy, not engine policy. Engine contract: consecutive liveState()
//         calls between runs return structurally equal snapshots (deterministic).
//         Added here: `liveStateConsistentAcrossConsecutiveCalls`.
//
// Upstream: SessionEngine, SessionEngineProtocol, MockStore, MockValueDef,
//           MockFunctionDef, MockLiveState, MockBehavior, RunConfig,
//           LuaSourceFragment, FragmentProvenance
import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Private helpers (integration-local; avoid colliding with SessionEngineTests helpers)

/// Builds a `LuaSourceFragment` for use in integration test cases.
/// Named distinctly from `fragment(_:)` in SessionEngineTests to prevent collision.
private func intFrag(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/integration.lua")
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

/// Creates a `SessionEngine` with a no-op output sink (integration tests do not
/// need to capture print output unless the test explicitly requires it).
private func intEngine() -> SessionEngine {
    SessionEngine(onOutput: { _ in })
}

// MARK: - Persona A7: mock-aware sessionRun + liveState

@Suite("SessionEngineIntegration — mock-aware session (persona A7)")
struct SessionEngineIntegrationMockAwareTests {

    /// After a `sessionRun` on a session started with a non-empty `MockStore`,
    /// `liveState()` must surface both the registered mock value namespace
    /// (via `registeredValueServerNames` introspection) and the mock function
    /// name (via `registeredFunctionNames` introspection) — sourced entirely
    /// from the engine, never from parallel bookkeeping.
    @Test("sessionRun with mocks — liveState reports mock values and functions via introspection")
    func sessionRunWithMocks() async throws {
        let engine = intEngine()

        // Build a MockStore with one value namespace ("config") and one
        // fixed-return function ("fetch"). These are the simplest shapes that
        // force a MockValueServer and a callback registration.
        let valueDef = MockValueDef(
            namespace: "config",
            path: "timeout",
            type: .number,
            value: "30",
            writable: false
        )
        let funcDef = MockFunctionDef(
            name: "fetch",
            behavior: .fixedReturn,
            returnValue: "\"ok\"",
            errorMessage: nil
        )
        let store = MockStore(values: [valueDef], functions: [funcDef])

        try await engine.startSession(config: RunConfig(), mocks: store)

        // Run a fragment that exercises both the mock value and the function.
        let outcome = await engine.sessionRun(intFrag("local t = config.timeout; local r = fetch()"))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            await engine.endSession()
            return
        }

        // After the run, liveState() must reflect the installed mocks — the
        // entire snapshot is built from LuaSwift #21 introspection
        // (registeredValueServerNames / registeredFunctionNames / globalNames).
        let state = await engine.liveState()

        // Mock value server namespace must be visible.
        #expect(
            state.mockValues.map(\.name).contains("config"),
            "registered MockValueServer namespace 'config' must appear in mockValues"
        )
        // Mock function name must be visible.
        #expect(
            state.mockFunctionNames.contains("fetch"),
            "registered callback 'fetch' must appear in mockFunctionNames"
        )
        // The snapshot is real, not the empty gate sentinel.
        #expect(!state.isEmpty, "liveState must not be the empty sentinel after a completed run")

        await engine.endSession()
    }
}

// MARK: - CONS-R4-01: sessionRunFinished → liveState trigger (engine-side contract)

@Suite("SessionEngineIntegration — CONS-R4-01 engine contract")
struct SessionEngineIntegrationConsR401Tests {

    /// CONS-R4-01 (session-engine side): after `sessionRun` completes — the
    /// event that triggers `AppEvent.sessionRunFinished` in the AppDriver — the
    /// engine's `liveState()` must return a snapshot with `isEmpty == false`.
    ///
    /// The TUI reducer reads `!isEmpty` to distinguish a real post-run snapshot
    /// from the mid-run empty sentinel. This test pins the engine-side half of
    /// the contract.
    @Test("liveState isEmpty == false immediately after sessionRun completes")
    func liveStateNotEmptyAfterRun() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)

        // Run a fragment that sets at least one user global so the snapshot
        // is definitely non-trivial (liveState returns real globals).
        _ = await engine.sessionRun(intFrag("result = 42"))

        let state = await engine.liveState()

        // Primary CONS-R4-01 contract: the snapshot is not the empty sentinel.
        #expect(!state.isEmpty, "liveState must not be empty after sessionRun completes")

        // Secondary check: the user global written by the fragment is visible
        // via globalNames introspection (confirms the engine survived the run).
        #expect(
            state.userGlobals.map(\.name).contains("result"),
            "user global 'result' written by sessionRun must be visible via introspection"
        )

        await engine.endSession()
    }
}

// MARK: - RunState gate: invokeLuaCall throws while .running

@Suite("SessionEngineIntegration — RunState gate (invokeLuaCall)")
struct SessionEngineIntegrationRunStateGateTests {

    /// DOM-02: `invokeLuaCall` must throw `SessionEngineError.enginePaused` when
    /// the engine is in RunState `.running`. This is the symmetric companion to the
    /// `liveState()` gate (covered in SessionEngineTests.liveStateEmptyMidRun).
    ///
    /// Technique: the print sink parks the serial executor in a semaphore wait
    /// while the run is in flight (RunState == .running). During that window,
    /// a concurrent `invokeLuaCall` must observe `.running` on the fast-path
    /// atomic and throw `.enginePaused` WITHOUT entering the executor.
    @Test("invokeLuaCall while .running throws enginePaused")
    func invokeLuaCallThrowsWhileRunning() async throws {
        // Thread-safe container for the thrown error (written from async, read afterward).
        final class CapturedError: @unchecked Sendable {
            private let lock = NSLock()
            private var _error: Error?
            func set(_ e: Error) { lock.withLock { _error = e } }
            var value: Error? { lock.withLock { _error } }
        }
        let captured = CapturedError()

        // Thread-safe flag to know when the run is in-flight in the sink.
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            func set() { lock.withLock { _value = true } }
            var isSet: Bool { lock.withLock { _value } }
        }
        let inFlight = Flag()
        let proceed = DispatchSemaphore(value: 0)

        let engine = SessionEngine(onOutput: { line in
            if line == "started" {
                inFlight.set()
                // Park the serial executor here — engine is RunState .running.
                _ = proceed.wait(timeout: .now() + 5)
            }
        })

        try await engine.startSession(config: RunConfig(), mocks: .empty)

        // Start a run that parks itself after the first print.
        async let running = engine.sessionRun(
            intFrag("print(\"started\")\nbusy = 1\nreturn 1")
        )

        // Async-safe poll: wait until the sink has parked (RunState == .running).
        var waited = 0
        while !inFlight.isSet && waited < 1000 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(inFlight.isSet, "timed out waiting for the run to park in the sink")

        // With the executor parked and RunState == .running, invokeLuaCall must
        // throw on the fast-path atomic WITHOUT queuing onto the blocked executor.
        do {
            _ = try await engine.invokeLuaCall("1 + 1")
            Issue.record("expected enginePaused throw, but invokeLuaCall returned")
        } catch let error as SessionEngineError {
            #expect(error == .enginePaused, "expected .enginePaused, got \(error)")
        } catch {
            captured.set(error)
            Issue.record("unexpected error type: \(error)")
        }

        // Unblock the run and let it complete cleanly.
        proceed.signal()
        _ = await running

        await engine.endSession()
    }
}

// MARK: - liveState determinism (engine-side cache contract)

@Suite("SessionEngineIntegration — liveState determinism")
struct SessionEngineIntegrationLiveStateDeterminismTests {

    /// The reducer caches the `MockLiveState` from a single `liveState()` call
    /// per run. The engine-side contract that makes this safe: two consecutive
    /// `liveState()` calls between runs (when RunState == .idle and no Lua
    /// runs between them) must return structurally equal snapshots.
    ///
    /// This verifies that `globalNames` / `globalValue` introspection is
    /// deterministic across multiple reads between runs — the engine is NOT
    /// mutating between the two calls.
    @Test("consecutive liveState calls between runs return equal snapshots")
    func liveStateConsistentAcrossConsecutiveCalls() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)

        _ = await engine.sessionRun(intFrag("alpha = 1\nbeta = 2"))

        // Both calls happen at RunState == .idle, with no intervening Lua code.
        let first = await engine.liveState()
        let second = await engine.liveState()

        // The snapshots must be structurally equal (same names, same display values).
        #expect(
            first == second,
            "consecutive liveState calls at RunState .idle must return equal snapshots"
        )
        // Confirm the snapshots are real (the reducer's cache is meaningful).
        #expect(!first.isEmpty, "snapshots must not be the empty sentinel")
        let names = first.userGlobals.map(\.name)
        #expect(
            names.contains("alpha") && names.contains("beta"),
            "both globals written by the run must appear in the snapshot")

        await engine.endSession()
    }
}

// MARK: - F5.3 Lua invocation (Swift → Lua, RQ2)

@Suite("SessionEngineIntegration — F5.3 invokeLuaCall (task #29)")
struct SessionEngineIntegrationInvokeTests {

    /// A script defines a global function; after the run, invoking it via a full
    /// call expression returns its FIRST return value, evaluated natively by Lua.
    @Test("invoke a defined global returns its first return value")
    func invokeReturnsFirstValue() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(intFrag("function on_event(name, payload) return payload end"))

        let value = try await engine.invokeLuaCall("on_event(\"tick\", 42)")
        guard case .number(let n) = value else {
            Issue.record("expected .number(42), got \(value)")
            await engine.endSession()
            return
        }
        #expect(n == 42)
        await engine.endSession()
    }

    /// RQ2: a call with a nested table and an inline function-literal argument is
    /// evaluated natively by Lua (the table is constructed, the closure built and
    /// called) — proving pure-Swift argument parsing is no longer on the path.
    @Test("rich-argument invocation evaluates nested table + inline closure natively")
    func invokeRichArguments() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(
            intFrag("function myCallback(t, f) return t.a + t.nested[1] + f() end"))

        let value = try await engine.invokeLuaCall(
            "myCallback({a = 2, nested = {3, 4}}, function() return 5 end)")
        guard case .number(let n) = value else {
            Issue.record("expected .number(10), got \(value)")
            await engine.endSession()
            return
        }
        #expect(n == 10)  // 2 + 3 + 5
        await engine.endSession()
    }

    /// A target that does not resolve to a callable global raises the Lua
    /// "attempt to call a nil value" runtime error (the AppDriver maps this to the
    /// `<name> is not a function.` transient; here we assert the engine raises it).
    @Test("invoking an undefined target raises attempt-to-call-a-nil-value")
    func invokeNotAFunction() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(intFrag("x = 1"))

        do {
            _ = try await engine.invokeLuaCall("nope(1)")
            Issue.record("expected a runtime error for an undefined call target")
        } catch {
            #expect(
                error.localizedDescription.contains("attempt to call a nil value"),
                "expected attempt-to-call-a-nil-value, got: \(error.localizedDescription)")
        }
        await engine.endSession()
    }

    /// Only the FIRST return value is observed (evaluate uses nresults=1, DOM-N04):
    /// a multi-return function invoked as `f()` yields just its first value.
    @Test("only the first return value is returned (multi-return truncated)")
    func invokeFirstReturnOnly() async throws {
        let engine = intEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        _ = await engine.sessionRun(intFrag("function multi() return 1, 2, 3 end"))

        let value = try await engine.invokeLuaCall("multi()")
        guard case .number(let n) = value else {
            Issue.record("expected .number(1), got \(value)")
            await engine.endSession()
            return
        }
        #expect(n == 1)
        await engine.endSession()
    }
}
