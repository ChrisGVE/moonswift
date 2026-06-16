// File: Tests/MoonSwiftCoreTests/F5SessionTapeTests.swift
// Location: MoonSwiftCoreTests/
// Role: F5 acceptance tape — end-to-end scripted session flow: open project →
//       define mocks (MockStore) → sessionRun → invokeLuaCall. Drives the REAL
//       SessionEngine with a populated MockStore and asserts that (a) the session
//       run sees mock-installed values via namespace lookup, (b) a post-run
//       invokeLuaCall sees the post-run state, and (c) liveState reflects the
//       user globals written by the fragment.
//
//       All tests use the production SessionEngine + LuaSwift; no stubs.
//       Helper names are prefixed `f5Tape` to avoid collisions with sibling files.
//
// Upstream: SessionEngine, MockStore, MockValueDef, MockFunctionDef,
//           LuaSourceFragment, FragmentProvenance, CoreRunOutcome, MockLiveState
// Downstream: (test target only)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers (f5Tape-prefixed)

private func f5TapeEngine() -> SessionEngine {
    SessionEngine(onOutput: { _ in })
}

private func f5TapeFrag(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/f5-tape.lua")
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

// MARK: - Suite: F5 mock-aware session run

/// F5 acceptance tape: drives `startSession(config:mocks:)` with a real
/// `MockStore`, runs a fragment that reads the installed mock values, then invokes
/// a Lua function defined by the script to confirm the post-run engine state is
/// intact.
@Suite("F5 acceptance — mock-aware session run tape")
struct F5SessionRunTapeTests {

    /// Tape 1: mock value is visible to the script and post-run invocation.
    ///
    /// Scenario:
    ///   - Define a mock value `app.version = "1.0"` in the MockStore.
    ///   - Run a script that reads it via `app.version` and stores the result.
    ///   - After the run, invoke a global helper to confirm post-run engine
    ///     state is live (the session survived the run).
    @Test("mock value is readable by the script; post-run invocation sees session state")
    func mockValueReadableAndPostRunInvoke() async throws {
        let engine = f5TapeEngine()
        let mocks = MockStore(
            values: [
                MockValueDef(
                    namespace: "app",
                    path: "version",
                    type: .string,
                    value: "\"1.0\"",
                    writable: false
                )
            ],
            functions: []
        )
        try await engine.startSession(config: RunConfig(), mocks: mocks)
        defer { Task { await engine.endSession() } }

        // Script reads the mock namespace value and stores it in a user global.
        let script = """
            local v = app.version
            session_saw_version = (v == "1.0")
            function check() return session_saw_version end
            """
        let outcome = await engine.sessionRun(f5TapeFrag(script))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }

        // The script defined `check()` — invokeLuaCall proves engine survived.
        let result = try await engine.invokeLuaCall("check()")
        // check() returns true (boolean) because app.version == "1.0".
        #expect(result == .bool(true), "check() must return true; got \(result)")
    }

    /// Tape 2: mock function (echo-args) is callable from the script.
    ///
    /// Scenario:
    ///   - Define a mock function `host_log` with behavior `.echoArgs`.
    ///   - Run a script that calls `host_log("ping")` and asserts the return.
    ///   - Confirm liveState after the run reflects the user global written by
    ///     the script.
    @Test("mock function (echo-args) is callable; liveState reflects post-run globals")
    func mockFunctionEchoArgsCallable() async throws {
        let engine = f5TapeEngine()
        let mocks = MockStore(
            values: [],
            functions: [
                MockFunctionDef(name: "host_log", behavior: .echoArgs)
            ]
        )
        try await engine.startSession(config: RunConfig(), mocks: mocks)
        defer { Task { await engine.endSession() } }

        // Script calls the mock function and stores a sentinel.
        let script = """
            local result = host_log("ping")
            call_succeeded = (type(result) == "table")
            """
        let outcome = await engine.sessionRun(f5TapeFrag(script))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }

        // liveState must be non-empty and contain the user global.
        let live = await engine.liveState()
        #expect(!live.isEmpty, "liveState must be non-empty after run")
        let globalNames = live.userGlobals.map(\.name)
        #expect(
            globalNames.contains("call_succeeded"),
            "user global 'call_succeeded' must be in liveState; got \(globalNames)")

        // Invoke to confirm the Lua-side truth value.
        let val = try await engine.invokeLuaCall("call_succeeded")
        #expect(val == .bool(true), "call_succeeded must be true; got \(val)")
    }

    /// Tape 3: invocation result reflects post-run state (session survival).
    ///
    /// A fresh session runs a script that defines a counter function, then
    /// invokeLuaCall is used to call it — proving the engine has not been
    /// discarded after `sessionRun` (unlike RunService's run-and-discard pattern).
    @Test("invokeLuaCall after sessionRun sees the post-run engine (session survival)")
    func sessionSurvivesRun() async throws {
        let engine = f5TapeEngine()
        try await engine.startSession(config: RunConfig(), mocks: .empty)
        defer { Task { await engine.endSession() } }

        let script = """
            count = 0
            function inc() count = count + 1; return count end
            """
        let outcome = await engine.sessionRun(f5TapeFrag(script))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }

        // First invocation returns 1, second returns 2 — session state persists.
        let first = try await engine.invokeLuaCall("inc()")
        #expect(first == .number(1), "first inc() call must return 1; got \(first)")

        let second = try await engine.invokeLuaCall("inc()")
        #expect(second == .number(2), "second inc() call must return 2; got \(second)")
    }

    /// Tape 4: mock function with fixed-return value is callable and returns
    /// the materialized constant.
    @Test("mock function (fixed-return) materializes the constant at session start")
    func mockFunctionFixedReturn() async throws {
        let engine = f5TapeEngine()
        let mocks = MockStore(
            values: [],
            functions: [
                MockFunctionDef(
                    name: "get_token",
                    behavior: .fixedReturn,
                    returnValue: "\"secret-abc\""
                )
            ]
        )
        try await engine.startSession(config: RunConfig(), mocks: mocks)
        defer { Task { await engine.endSession() } }

        let script = """
            tok = get_token()
            got_token = (tok == "secret-abc")
            """
        let outcome = await engine.sessionRun(f5TapeFrag(script))
        guard case .done = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }

        let val = try await engine.invokeLuaCall("got_token")
        #expect(val == .bool(true), "got_token must be true; got \(val)")
    }
}
