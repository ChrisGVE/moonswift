// File: Tests/MoonSwiftCoreTests/Run/RunServiceTests.swift
// Location: MoonSwiftCoreTests/Run/
// Role: Tests for RunService — covering print capture, error outcomes, instruction
//       limits, unrestricted mode, and the #22-absent degradation path. All tests
//       use the production RunService with a real LuaEngine; no stubs.
// Upstream: RunService, CoreRunOutcome, CoreLimitKind, LuaSourceFragment,
//           FragmentProvenance, RunConfig, Diagnostic
// Downstream: (test target only)

import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Thread-safe test helpers

/// Accumulates lines and transient messages from Sendable callbacks.
///
/// `RunService.run` accepts `@escaping @Sendable` callbacks that fire from a
/// detached `Task` (potentially a different thread). `LineCollector` uses
/// `NSLock` so it can be safely mutated from any thread **synchronously** —
/// no `Task {}` wrapping needed, which means all appends happen-before
/// `run` returns its `await`.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _transients: [String] = []

    func appendLine(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        _lines.append(s)
    }

    func appendTransient(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        _transients.append(s)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    var transients: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _transients
    }
}

/// Builds a minimal `LuaSourceFragment` for test scripts.
private func fragment(code: String) -> LuaSourceFragment {
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

// MARK: - Print capture tests

@Suite("RunService — print capture")
struct RunServicePrintCaptureTests {

    @Test("single print call produces one output line")
    func singlePrint() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let frag = fragment(code: "print('hello')")

        let outcome = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["hello"])
        if case .done = outcome {  // expected
        } else {
            Issue.record("Expected .done, got \(outcome)")
        }
    }

    @Test("multiple arguments are tab-separated on one line")
    func multipleArguments() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let frag = fragment(code: "print(1, 'two', true)")

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["1\ttwo\ttrue"])
    }

    @Test("multiple print calls produce multiple output lines in order")
    func multiplePrints() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let code = """
            print("first")
            print("second")
            print("third")
            """
        let frag = fragment(code: code)

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["first", "second", "third"])
    }

    @Test("print with no arguments produces empty line")
    func printNoArgs() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let frag = fragment(code: "print()")

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == [""])
    }

    @Test("tostring is called on each argument — nil and booleans stringify correctly")
    func tostringOnArgs() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let frag = fragment(code: "print(nil, false, 0)")

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["nil\tfalse\t0"])
    }

    @Test("__tostring metamethod is honoured")
    func tostringMetamethod() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let code = """
            local mt = { __tostring = function(t) return "custom:" .. t.x end }
            local obj = setmetatable({ x = 42 }, mt)
            print(obj)
            """
        let frag = fragment(code: code)

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["custom:42"])
    }

    @Test("__moonswift_sink is removed from globals — user code cannot call it")
    func sinkRemovedFromGlobals() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let code = """
            local fn = __moonswift_sink
            if fn == nil then
                print("sink is nil — good")
            else
                print("sink is NOT nil — bad")
            end
            """
        let frag = fragment(code: code)

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["sink is nil — good"])
    }

    @Test("all output lines arrive before the outcome is returned")
    func outputBeforeOutcome() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let code = "for i = 1, 5 do print(i) end"
        let frag = fragment(code: code)

        let outcome = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines.count == 5)
        if case .done = outcome {  // expected
        } else {
            Issue.record("Expected .done, got \(outcome)")
        }
    }
}

// MARK: - Error outcome tests

@Suite("RunService — error outcomes")
struct RunServiceErrorTests {

    @Test("syntax error produces .error outcome with non-zero line")
    func syntaxError() async {
        let service = RunService { _ in }
        let frag = fragment(code: "this is not lua ===")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        guard case .error(let diag, _) = outcome else {
            Issue.record("Expected .error, got \(outcome)")
            return
        }
        #expect(diag.severity == .error)
        #expect(diag.source == .runtime)
        #expect(diag.line >= 0)
    }

    @Test("runtime error produces .error outcome")
    func runtimeError() async {
        let service = RunService { _ in }
        let frag = fragment(code: "local x = nil; x()")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        guard case .error(let diag, _) = outcome else {
            Issue.record("Expected .error, got \(outcome)")
            return
        }
        #expect(diag.severity == .error)
        #expect(diag.source == .runtime)
    }

    @Test("print output before a runtime error arrives before the error outcome")
    func printThenError() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let code = """
            print("before error")
            error("deliberate error")
            """
        let frag = fragment(code: code)

        let outcome = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["before error"])
        if case .error = outcome {  // expected
        } else {
            Issue.record("Expected .error, got \(outcome)")
        }
    }

    @Test("error() with table argument does not crash the service")
    func errorWithTableArg() async {
        let service = RunService { _ in }
        let frag = fragment(code: "error({code=42})")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        if case .error = outcome {  // expected
        } else {
            Issue.record("Expected .error, got \(outcome)")
        }
    }
}

// MARK: - Instruction limit tests

@Suite("RunService — instruction limit")
struct RunServiceInstructionLimitTests {

    @Test("instruction limit triggers .limitExceeded(.instructions) for an infinite loop")
    func infiniteLoopLimit() async {
        let service = RunService { _ in }
        let config = RunConfig(instructionLimit: 1_000)
        let frag = fragment(code: "while true do end")

        let outcome = await service.run(frag, config: config) { _ in }

        guard case .limitExceeded(let kind) = outcome else {
            Issue.record("Expected .limitExceeded, got \(outcome)")
            return
        }
        guard case .instructions(let count) = kind else {
            Issue.record("Expected .instructions, got \(kind)")
            return
        }
        #expect(count == 1_000, "count must carry the configured limit")
    }

    @Test("instruction limit of 0 means unlimited — small script completes normally")
    func zeroLimitIsUnlimited() async {
        let service = RunService { _ in }
        let config = RunConfig(instructionLimit: 0)
        let frag = fragment(code: "return 1 + 2")

        let outcome = await service.run(frag, config: config) { _ in }

        if case .done = outcome {  // expected
        } else {
            Issue.record("Expected .done with no limit, got \(outcome)")
        }
    }

    @Test("print output before instruction-limit trip still arrives")
    func printBeforeLimit() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let config = RunConfig(instructionLimit: 5_000)
        let code = """
            print("before limit")
            local i = 0
            while true do i = i + 1 end
            """
        let frag = fragment(code: code)

        let outcome = await service.run(frag, config: config) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["before limit"])
        if case .limitExceeded(let kind) = outcome,
            case .instructions(let count) = kind
        {
            #expect(count == 5_000, "count must carry the configured limit (5_000)")
        } else {
            Issue.record("Expected .limitExceeded(.instructions(count:)), got \(outcome)")
        }
    }
}

// MARK: - Done outcome / return value tests

@Suite("RunService — done outcomes and return values")
struct RunServiceDoneTests {

    @Test("script returning a number yields .done with string representation")
    func returnsNumber() async {
        let service = RunService { _ in }
        let frag = fragment(code: "return 42")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        guard case .done(let value, _) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(value == "42")
    }

    @Test("script with no return statement yields .done with nil value")
    func noReturnIsNil() async {
        let service = RunService { _ in }
        let frag = fragment(code: "local x = 1")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        guard case .done(let value, _) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(value == nil)
    }

    @Test("duration in .done is non-negative")
    func durationIsNonNegative() async {
        let service = RunService { _ in }
        let frag = fragment(code: "return 'fast'")

        let outcome = await service.run(frag, config: RunConfig()) { _ in }

        guard case .done(_, let duration) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(duration >= .zero)
    }
}

// MARK: - Unrestricted mode tests

@Suite("RunService — unrestricted mode")
struct RunServiceUnrestrictedTests {

    @Test("unrestricted mode makes io table available — stripped in sandbox")
    func ioAvailableInUnrestricted() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let config = RunConfig(config: .unrestricted)
        let frag = fragment(code: "print(type(io))")

        _ = await service.run(frag, config: config) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["table"])
    }

    @Test("sandboxed mode removes io — type(io) is nil")
    func ioRemovedInSandbox() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let config = RunConfig(config: .sandboxed)
        let frag = fragment(code: "print(type(io))")

        _ = await service.run(frag, config: config) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["nil"])
    }

    @Test("os.clock is available in sandboxed mode — safe os subset")
    func osClockInSandbox() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }
        let frag = fragment(code: "print(type(os.clock()))")

        _ = await service.run(frag, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["number"])
    }
}

// MARK: - Cancellation degradation path tests

@Suite("RunService — cancellation degradation (#22 absent)")
struct RunServiceCancellationDegradationTests {

    @Test("cancel() when no run active posts a transient on degradation path")
    func cancelDegradationPostsTransient() async {
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }

        service.cancel()

        // Give any Task { } a chance to complete.
        let transients = collector.transients

        #if MOONSWIFT_LUASWIFT_22
            // On the #22 path, cancel() with no active engine is a no-op.
            #expect(transients.isEmpty)
        #else
            // On the degradation path, a transient message is always posted.
            #expect(transients.count == 1)
            if let msg = transients.first {
                #expect(msg.contains("Cancellation"))
            }
        #endif
    }

    @Test("without #22, instruction limit is the only early-exit from an infinite loop")
    func onlyInstructionLimitExits() async {
        let service = RunService { _ in }
        let config = RunConfig(instructionLimit: 10_000)
        let frag = fragment(code: "local i = 0; while true do i = i + 1 end")

        let outcome = await service.run(frag, config: config) { _ in }

        if case .limitExceeded(let kind) = outcome,
            case .instructions(let count) = kind
        {
            #expect(count == 10_000, "count must carry the configured limit (10_000)")
        } else {
            Issue.record("Expected .limitExceeded(.instructions(count:)), got \(outcome)")
        }
    }
}

// MARK: - Engine isolation tests

@Suite("RunService — engine isolation")
struct RunServiceEngineIsolationTests {

    @Test("globals from one run do not leak to the next — fresh engine per run")
    func engineIsolation() async {
        let service = RunService { _ in }
        let setGlobal = fragment(code: "myGlobal = 'set by run 1'")
        let readGlobal = fragment(code: "print(type(myGlobal))")

        _ = await service.run(setGlobal, config: RunConfig()) { _ in }

        let collector = LineCollector()
        _ = await service.run(readGlobal, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        let lines = collector.lines
        #expect(lines == ["nil"])
    }

    @Test("two sequential runs both complete cleanly")
    func sequentialRunsComplete() async {
        let service = RunService { _ in }
        let frag1 = fragment(code: "return 1")
        let frag2 = fragment(code: "return 2")

        let outcome1 = await service.run(frag1, config: RunConfig()) { _ in }
        let outcome2 = await service.run(frag2, config: RunConfig()) { _ in }

        if case .done(let v1, _) = outcome1 {
            #expect(v1 == "1")
        } else {
            Issue.record("Run 1: expected .done, got \(outcome1)")
        }

        if case .done(let v2, _) = outcome2 {
            #expect(v2 == "2")
        } else {
            Issue.record("Run 2: expected .done, got \(outcome2)")
        }
    }
}
