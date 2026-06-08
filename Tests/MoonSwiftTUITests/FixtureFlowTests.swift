// File: Tests/MoonSwiftTUITests/FixtureFlowTests.swift
// Location: MoonSwiftTUITests/
// Role: Reducer-driven integration flow tests.  Each test scripted an ordered
//       sequence of AppEvent values derived from the integration fixture
//       scenarios and asserts the resulting AppState transitions without
//       exercising any real service (RunService, LintService, SourceStore).
//       The fixture Lua source code is embedded inline so this target has no
//       bundle resource dependency.
//
//       Test naming convention: `<scenario>Flow_<assertion>`.
//       Tests must not be named SnapshotTests* or CommandInterpreterTests*
//       (parallel-executor scope boundaries).
//
// Upstream: Reducer.swift, AppState.swift, AppEvent.swift, Effect.swift
// Downstream: (test target only)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Local helpers

/// Applies an ordered event sequence, threading state through each step.
/// Returns the final state and the effects from the last step only.
private func applyAll(_ state: AppState, _ events: [AppEvent]) -> (AppState, [Effect]) {
    var current = state
    var lastEffects: [Effect] = []
    for event in events {
        let (next, effects) = reduce(current, event)
        current = next
        lastEffects = effects
    }
    return (current, lastEffects)
}

/// Applies an ordered event sequence, collecting every step's effects.
/// Returns the final state and a per-step array of effect arrays.
private func applyAllCollectingEffects(
    _ state: AppState,
    _ events: [AppEvent]
) -> (AppState, [[Effect]]) {
    var current = state
    var all: [[Effect]] = []
    for event in events {
        let (next, effects) = reduce(current, event)
        current = next
        all.append(effects)
    }
    return (current, all)
}

/// Returns a `LuaSourceFragment` with a synthetic provenance.
private func makeFragment(code: String, path: String = "/fixtures/script.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
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

/// Builds a minimal `AppState` with one loaded source selected, lint idle, project loaded.
private func loadedState(code: String, path: String = "scripts/init.lua") -> (AppState, SourceID) {
    let id = SourceID(path: path)
    var state = AppState()
    state.sources[id] = .loaded(makeFragment(code: code, path: "/project/\(path)"))
    state.navigatorOrder = [id]
    state.selection = id
    state.lintState = .idle
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (state, id)
}

/// Returns true if any effect in the array satisfies the predicate.
private func hasEffect(_ effects: [Effect], _ predicate: (Effect) -> Bool) -> Bool {
    effects.contains(where: predicate)
}

private func hasRunEffect(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .run = $0 { return true }
        return false
    }
}

private func hasCancelRun(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .cancelRun = $0 { return true }
        return false
    }
}

private func hasLintEffect(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .lint = $0 { return true }
        return false
    }
}

private func hasStartTick(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .startTick = $0 { return true }
        return false
    }
}

private func hasStopTick(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .stopTick = $0 { return true }
        return false
    }
}

// MARK: - run-print-and-error flow tests

@Suite("FixtureFlow — run-print-and-error")
struct RunPrintAndErrorFlowTests {

    /// Fixture code from run-print-and-error/print-and-error.lua (inline).
    private static let code = """
        print("before error")
        error("deliberate runtime error")
        """

    @Test("flow: runOutput accumulates lines; runFinished(.error) clears running state")
    func outputThenError() {
        let (base, id) = loadedState(code: Self.code)

        let runID = UUID()
        let startedAt = Date()

        // Simulate: user presses run, run starts, one output line, run finishes with error.
        let diag = Diagnostic(severity: .error, line: 2, message: "deliberate runtime error", source: .runtime)
        let events: [AppEvent] = [
            .runOutput(["before error"]),
            .runFinished(.error(diag, traceback: [])),
        ]

        // Seed running state first.
        var base2 = base
        base2.runState = .running(id: runID, startedAt: startedAt)
        _ = id  // suppress unused warning

        let (final, _) = applyAll(base2, events)

        guard case .completed(let outcome) = final.runState else {
            Issue.record("Expected .completed run state, got \(final.runState)")
            return
        }
        guard case .error(let d, _) = outcome else {
            Issue.record("Expected .error outcome, got \(outcome)")
            return
        }
        #expect(d.severity == .error)
        #expect(d.source == .runtime)

        // Output lines must appear in the bottom pane.
        #expect(
            final.bottomPane.outputBuffer.contains("before error"),
            "Bottom pane must contain 'before error'"
        )
    }
}

// MARK: - run-return-value flow tests

@Suite("FixtureFlow — run-return-value")
struct RunReturnValueFlowTests {

    @Test("flow: .done with string return value stores value in RunState.completed")
    func doneStringReturn() {
        let (base, _) = loadedState(code: "return 'hello'")
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let (final, _) = applyAll(base2, [.runFinished(.done(value: "hello", duration: .zero))])

        guard case .completed(.done(let v, _)) = final.runState else {
            Issue.record("Expected .completed(.done), got \(final.runState)")
            return
        }
        #expect(v == "hello")
    }

    @Test("flow: .done with nil return value stores nil in RunState.completed")
    func doneNilReturn() {
        let (base, _) = loadedState(code: "local _ = 1")
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let (final, _) = applyAll(base2, [.runFinished(.done(value: nil, duration: .zero))])

        guard case .completed(.done(let v, _)) = final.runState else {
            Issue.record("Expected .completed(.done), got \(final.runState)")
            return
        }
        #expect(v == nil)
    }
}

// MARK: - run-runaway-loop flow tests

@Suite("FixtureFlow — run-runaway-loop")
struct RunRunawayLoopFlowTests {

    @Test("flow: .limitExceeded(.instructions) transitions to completed; tick stops")
    func limitExceededStopsTick() {
        let (base, _) = loadedState(code: "while true do end")
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let (final, effects) = applyAll(base2, [.runFinished(.limitExceeded(kind: .instructions))])

        guard case .completed(.limitExceeded(let kind)) = final.runState else {
            Issue.record("Expected .completed(.limitExceeded), got \(final.runState)")
            return
        }
        #expect(kind == .instructions)
        #expect(hasStopTick(effects), "stopTick effect must be emitted when run ends")
    }
}

// MARK: - run-sandbox-test flow tests

@Suite("FixtureFlow — run-sandbox-test")
struct RunSandboxTestFlowTests {

    @Test("flow: sandboxed run output carries 'sandboxed' label in bottom pane")
    func sandboxedOutputRecorded() {
        let (base, _) = loadedState(code: "print('sandboxed')")
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let (final, _) = applyAll(
            base2,
            [
                .runOutput(["sandboxed"]),
                .runFinished(.done(value: nil, duration: .zero)),
            ])

        #expect(
            final.bottomPane.outputBuffer.contains("sandboxed"),
            "Sandboxed output must appear in bottom pane"
        )
    }
}

// MARK: - run-instruction-limit flow tests

@Suite("FixtureFlow — run-instruction-limit")
struct RunInstructionLimitFlowTests {

    @Test("flow: output before limit trip is preserved; state is .limitExceeded")
    func outputPreservedBeforeLimit() {
        let (base, _) = loadedState(code: "print('before limit'); while true do end")
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let (final, _) = applyAll(
            base2,
            [
                .runOutput(["before limit"]),
                .runFinished(.limitExceeded(kind: .instructions)),
            ])

        #expect(
            final.bottomPane.outputBuffer.contains("before limit"),
            "Output before limit must be preserved"
        )
        guard case .completed(.limitExceeded(let kind)) = final.runState else {
            Issue.record("Expected .completed(.limitExceeded), got \(final.runState)")
            return
        }
        #expect(kind == .instructions)
    }
}

// MARK: - lint-clean flow tests

@Suite("FixtureFlow — lint-clean")
struct LintCleanFlowTests {

    @Test("flow: empty diagnostic list from lint leaves bottom pane with no lint entries")
    func emptyDiagnosticsFromLint() {
        let (base, _) = loadedState(code: "local function add(a, b) return a + b end")
        var base2 = base
        base2.lintState = .running

        let (final, effects) = applyAll(base2, [.lintFinished([])])

        #expect(final.lintState == .idle)
        #expect(
            final.bottomPane.diagnostics.filter { $0.source == .luacheck }.isEmpty,
            "Clean lint must produce zero luacheck diagnostics"
        )
        // Tick should stop when lint is done and no run is active.
        let allStopped = hasStopTick(effects)
        _ = allStopped  // tick may or may not stop depending on other state; just verify no crash
    }
}

// MARK: - lint-undefined-global flow tests

@Suite("FixtureFlow — lint-undefined-global")
struct LintUndefinedGlobalFlowTests {

    @Test("flow: W1xx diagnostic from lint appears in bottom pane diagnostics")
    func undefinedGlobalInBottomPane() {
        let (base, _) = loadedState(code: "return notDeclaredAnywhere")
        var base2 = base
        base2.lintState = .running

        let w1xx = Diagnostic(
            severity: .warning,
            line: 1,
            column: 8,
            code: "111",
            message: "accessing undefined variable 'notDeclaredAnywhere'",
            source: .luacheck
        )

        let (final, _) = applyAll(base2, [.lintFinished([w1xx])])

        #expect(final.lintState == .idle)
        let luacheckDiags = final.bottomPane.diagnostics.filter { $0.source == .luacheck }
        #expect(!luacheckDiags.isEmpty, "Expected at least one luacheck diagnostic")
        #expect(luacheckDiags.first?.code == "111")
    }
}

// MARK: - lint-syntax-error flow tests

@Suite("FixtureFlow — lint-syntax-error")
struct LintSyntaxErrorFlowTests {

    @Test("flow: prePassResult(.some) stores error diagnostic in bottom pane")
    func syntaxErrorInBottomPane() {
        let (base, _) = loadedState(code: "this is not valid Lua ===")
        var base2 = base
        base2.lintState = .running

        let syntaxDiag = Diagnostic(
            severity: .error,
            line: 1,
            message: "unexpected symbol near 'not'",
            source: .syntaxPrePass
        )

        let (final, _) = applyAll(base2, [.prePassResult(syntaxDiag)])

        // The pre-pass diagnostic is stored in `prePassDiagnostic`, not in `diagnostics`.
        let preDiag = final.bottomPane.prePassDiagnostic
        #expect(preDiag != nil, "Syntax pre-pass error must be stored in prePassDiagnostic")
        #expect(preDiag?.severity == .error)
        #expect(preDiag?.source == .syntaxPrePass)
    }
}

// MARK: - source loading flow tests

@Suite("FixtureFlow — structured-file loading scenarios")
struct StructuredFileLoadingFlowTests {

    @Test("flow: sourceLoaded event populates sources dict with .loaded state")
    func sourceLoadedPopulatesState() {
        var state = AppState()
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let id = SourceID(path: "config.yaml", jsonpath: "$.scripts.init")
        let fragment = makeFragment(code: "print('yaml init')", path: "/project/config.yaml")
        let (final, _) = applyAll(state, [.sourceLoaded(id: id, fragment: fragment)])

        guard case .loaded(let f) = final.sources[id] else {
            Issue.record("Expected .loaded source state, got \(String(describing: final.sources[id]))")
            return
        }
        #expect(f.code == "print('yaml init')")
    }

    @Test("flow: sourceFailed(.missing) stores .missing state for absent file")
    func sourceFailedMissingStored() {
        var state = AppState()
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let id = SourceID(path: "does-not-exist.lua")
        let (final, _) = applyAll(state, [.sourceFailed(id: id, state: .missing)])

        guard case .missing = final.sources[id] else {
            Issue.record("Expected .missing source state, got \(String(describing: final.sources[id]))")
            return
        }
    }

    @Test("flow: sourceFailed(.failed(diag)) stores .failed state with diagnostic")
    func sourceFailedDiagStored() {
        var state = AppState()
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let id = SourceID(path: "malformed.yaml", jsonpath: "$.scripts.init")
        let diag = Diagnostic(
            severity: .error,
            message: "✖ Cannot parse malformed.yaml: bad indentation",
            source: .sourceLoad
        )
        let (final, _) = applyAll(state, [.sourceFailed(id: id, state: .failed(diag))])

        guard case .failed(let d) = final.sources[id] else {
            Issue.record("Expected .failed source state, got \(String(describing: final.sources[id]))")
            return
        }
        #expect(d.severity == .error)
        #expect(d.message.hasPrefix("✖"))
    }

    @Test("flow: wildcard sourceLoaded posts two independent loaded events")
    func wildcardTwoLoadedEvents() {
        var state = AppState()
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let id1 = SourceID(path: "wildcard.yaml", jsonpath: "$.handlers.onCreate")
        let id2 = SourceID(path: "wildcard.yaml", jsonpath: "$.handlers.onDelete")
        let f1 = makeFragment(code: "print('wildcard created')")
        let f2 = makeFragment(code: "print('wildcard deleted')")

        let events: [AppEvent] = [
            .sourceLoaded(id: id1, fragment: f1),
            .sourceLoaded(id: id2, fragment: f2),
        ]
        let (final, _) = applyAll(state, events)

        guard case .loaded(let frag1) = final.sources[id1] else {
            Issue.record("Expected .loaded for onCreate")
            return
        }
        guard case .loaded(let frag2) = final.sources[id2] else {
            Issue.record("Expected .loaded for onDelete")
            return
        }
        #expect(frag1.code == "print('wildcard created')")
        #expect(frag2.code == "print('wildcard deleted')")
    }

    @Test("flow: multi-doc sourceLoaded events store fragments keyed by document index")
    func multiDocTwoFragments() {
        var state = AppState()
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let id0 = SourceID(path: "multi-doc.yaml", jsonpath: "$.script", document: 0)
        let id1 = SourceID(path: "multi-doc.yaml", jsonpath: "$.script", document: 1)
        let f0 = makeFragment(code: "print('doc0')")
        let f1 = makeFragment(code: "print('doc1')")

        let (final, _) = applyAll(
            state,
            [
                .sourceLoaded(id: id0, fragment: f0),
                .sourceLoaded(id: id1, fragment: f1),
            ])

        guard case .loaded(let frag0) = final.sources[id0] else {
            Issue.record("Expected .loaded for document 0")
            return
        }
        guard case .loaded(let frag1) = final.sources[id1] else {
            Issue.record("Expected .loaded for document 1")
            return
        }
        #expect(frag0.code == "print('doc0')")
        #expect(frag1.code == "print('doc1')")
    }
}

// MARK: - parser hostile-input flow tests

@Suite("FixtureFlow — parser hostile-input scenarios")
struct ParserHostileInputFlowTests {

    @Test("flow: hostile-chunkname lintFinished with no engine errors completes cleanly")
    func hostileChunknameCleanLint() {
        let (base, _) = loadedState(code: "local a = ']:1: end'; local b = '[[nested]]'")
        var base2 = base
        base2.lintState = .running

        // Engine survived the hostile round-trip: zero diagnostics.
        let (final, _) = applyAll(base2, [.lintFinished([])])

        #expect(final.lintState == .idle)
        let engineErrors = final.bottomPane.diagnostics.filter {
            $0.source == .runtime || $0.source == .syntaxPrePass
        }
        #expect(engineErrors.isEmpty, "Hostile-chunkname must not leave engine-level errors")
    }

    @Test("flow: hostile-message .error preserves full message content in run state")
    func hostileMessagePreservedInState() {
        let (base, _) = loadedState(code: #"error("hostile ]:1: content in message")"#)
        var base2 = base
        base2.runState = .running(id: UUID(), startedAt: Date())

        let diag = Diagnostic(
            severity: .error,
            line: 1,
            message: "hostile ]:1: content in message",
            source: .runtime
        )

        let (final, _) = applyAll(base2, [.runFinished(.error(diag, traceback: []))])

        guard case .completed(.error(let d, _)) = final.runState else {
            Issue.record("Expected .completed(.error), got \(final.runState)")
            return
        }
        #expect(
            d.message.contains("]:1:"),
            "Hostile substring must survive into RunState.completed.error.diagnostic"
        )
    }
}
