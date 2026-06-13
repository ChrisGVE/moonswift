// File: Tests/MoonSwiftCoreTests/Mock/MockFunctionTests.swift
// Location: MoonSwiftCoreTests/Mock/
// Role: Integration tests for F5.2 — MockFunctionDef callback synthesis and
//       engine registration. All three behaviors are exercised against a real
//       LuaEngine via SessionEngine (no stubs).
//
//       ## Design notes
//
//       Tests exercise the full stack: MockFunctionDef → MockStore →
//       SessionEngine.startSession (registers callback via F5.2 seam) →
//       sessionRun. This is the only trustworthy proof that a synthesized
//       callback is visible to Lua.
//
//       Suites run in parallel (swift-testing default). No busy-loops or
//       sleep calls — async/await throughout.
//
//       DOM-04 (echo-args single-table binding) and RQ1 (fixed-return with
//       scalar, computed expression, function literal) are each verified with
//       a dedicated test. raise-error verifies that the outcome is `.error`
//       with a diagnostic whose message contains the configured string.
//
// Upstream: MockFunctionDef, MockBehavior, MockStore, SessionEngine,
//           RunConfig, LuaSourceFragment, FragmentProvenance, CoreRunOutcome

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Thread-safe collector for captured print output.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

/// Builds a `LuaSourceFragment` from raw Lua with a synthetic provenance.
private func fragment(_ code: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/test/mock_fn_test.lua")
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

/// Creates a `SessionEngine` backed by a private output collector.
private func makeEngine(_ collector: OutputCollector = OutputCollector()) -> SessionEngine {
    SessionEngine(onOutput: { collector.append($0) })
}

/// Starts a session with a single `[[mock.function]]` definition.
private func startSession(
    engine: SessionEngine,
    function def: MockFunctionDef
) async throws {
    let store = MockStore(values: [], functions: [def])
    try await engine.startSession(config: RunConfig(), mocks: store)
}

// MARK: - echo-args behavior (DOM-04)

@Suite("MockFunction — echo-args (DOM-04)")
struct MockFunctionEchoArgsTests {

    @Test("echo-args returns a single table containing all arguments")
    func echoArgsSingleTable() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(name: "mocked", behavior: .echoArgs)
        try await startSession(engine: engine, function: def)

        // DOM-04 binding: `local t = mocked(1, 2)` → t[1]==1, t[2]==2.
        let outcome = await engine.sessionRun(
            fragment(
                """
                local t = mocked(1, 2)
                return t[1] == 1 and t[2] == 2
                """))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }

    @Test("echo-args: second variable in multi-assignment is nil (DOM-04)")
    func echoArgsSecondVariableIsNil() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(name: "mocked", behavior: .echoArgs)
        try await startSession(engine: engine, function: def)

        // `local a, b = mocked(1, 2)` → a == {1,2}, b == nil.
        // The callback returns exactly ONE value; Lua assigns nil to b.
        let outcome = await engine.sessionRun(
            fragment(
                """
                local a, b = mocked(1, 2)
                return b == nil
                """))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }

    @Test("echo-args with zero arguments returns an empty table")
    func echoArgsNoArguments() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(name: "mocked", behavior: .echoArgs)
        try await startSession(engine: engine, function: def)

        let outcome = await engine.sessionRun(
            fragment(
                """
                local t = mocked()
                local count = 0
                for _ in pairs(t) do count = count + 1 end
                return count == 0
                """))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }
}

// MARK: - fixed-return behavior (RQ1)

@Suite("MockFunction — fixed-return (RQ1)")
struct MockFunctionFixedReturnTests {

    @Test("fixed-return with scalar literal returns the scalar")
    func fixedReturnScalar() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(
            name: "get_value",
            behavior: .fixedReturn,
            returnValue: "42"
        )
        try await startSession(engine: engine, function: def)

        let outcome = await engine.sessionRun(fragment("return get_value() == 42"))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }

    @Test("fixed-return with computed expression (RQ1) evaluates at session start")
    func fixedReturnComputedExpression() async throws {
        let engine = makeEngine()
        // The expression "10 * 2" is evaluated once at startSession, not per call.
        let def = MockFunctionDef(
            name: "computed",
            behavior: .fixedReturn,
            returnValue: "10 * 2"
        )
        try await startSession(engine: engine, function: def)

        let outcome = await engine.sessionRun(fragment("return computed() == 20"))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }

    @Test("fixed-return with function literal returns a callable (RQ1)")
    func fixedReturnFunctionLiteral() async throws {
        let engine = makeEngine()
        // The return_value is a function literal — materialized as .luaFunction.
        // The script must be able to call the returned value.
        let def = MockFunctionDef(
            name: "get_fn",
            behavior: .fixedReturn,
            returnValue: "function(x) return x + 1 end"
        )
        try await startSession(engine: engine, function: def)

        let outcome = await engine.sessionRun(
            fragment(
                """
                local fn = get_fn()
                return fn(5) == 6
                """))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }

    @Test("fixed-return value is stable across multiple calls (materialized once)")
    func fixedReturnStableAcrossCalls() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(
            name: "stable",
            behavior: .fixedReturn,
            returnValue: "99"
        )
        try await startSession(engine: engine, function: def)

        // Both calls must return 99, proving the materialized value is reused.
        let outcome = await engine.sessionRun(
            fragment(
                """
                return stable() == 99 and stable() == 99
                """))
        guard case .done(let value, _) = outcome else {
            Issue.record("expected .done, got \(outcome)")
            return
        }
        #expect(value == "true")
        await engine.endSession()
    }
}

// MARK: - raise-error behavior

@Suite("MockFunction — raise-error")
struct MockFunctionRaiseErrorTests {

    @Test("raise-error produces a .error outcome with the configured message")
    func raiseErrorOutcome() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(
            name: "fail",
            behavior: .raiseError,
            errorMessage: "simulated failure"
        )
        try await startSession(engine: engine, function: def)

        // The Lua call site is line 1.
        let outcome = await engine.sessionRun(fragment("fail()"))
        guard case .error(let diagnostic, _) = outcome else {
            Issue.record("expected .error, got \(outcome)")
            return
        }
        // The error message must contain the configured string.
        #expect(diagnostic.message.contains("simulated failure"))
        await engine.endSession()
    }

    @Test("raise-error surfaces a structured .error outcome (line attribution pending LuaSwift #19)")
    func raiseErrorIsStructuredError() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(
            name: "kaboom",
            behavior: .raiseError,
            errorMessage: "boom"
        )
        try await startSession(engine: engine, function: def)

        // At LuaSwift 1.12.4 (the pinned revision), LuaError.callbackError is
        // routed through the default branch of Diagnostic.from(luaError:), which
        // sets line: 0 and traceback: nil. Full call-site line attribution will be
        // available once LuaSwift #19 structured errors land (a future PRD task).
        //
        // What IS guaranteed now: the outcome is .error (not .done), and the
        // diagnostic message carries the configured error_message string wrapped
        // in "Swift callback error: <message>".
        let outcome = await engine.sessionRun(fragment("local x = 1\nkaboom()"))
        guard case .error(let diagnostic, _) = outcome else {
            Issue.record("expected .error, got \(outcome)")
            return
        }
        #expect(diagnostic.message.contains("boom"))
        await engine.endSession()
    }

    @Test("raise-error does not affect subsequent sessionRun calls")
    func raiseErrorDoesNotCorruptSession() async throws {
        let engine = makeEngine()
        let def = MockFunctionDef(
            name: "boom",
            behavior: .raiseError,
            errorMessage: "oops"
        )
        try await startSession(engine: engine, function: def)

        // First run: error expected.
        let first = await engine.sessionRun(fragment("boom()"))
        guard case .error = first else {
            Issue.record("expected .error on first run, got \(first)")
            return
        }

        // Second run: a plain script should still succeed.
        let second = await engine.sessionRun(fragment("return 1 + 1"))
        guard case .done(let value, _) = second else {
            Issue.record("expected .done on second run, got \(second)")
            return
        }
        #expect(value == "2")
        await engine.endSession()
    }
}
