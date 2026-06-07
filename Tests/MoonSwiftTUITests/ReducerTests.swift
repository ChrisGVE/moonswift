// File: Tests/MoonSwiftTUITests/ReducerTests.swift
// Location: MoonSwiftTUITests/
// Role: Reducer-sequence tests for key P1 flows. Each test drives a sequence of
//       (state, event) → (state, effects) steps and asserts the resulting state.
//       No FFI is linked in this target (EventSource protocol seam — ARCH §5.1).
// Upstream: Reducer.swift, AppState.swift, AppEvent.swift, Effect.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Returns a minimal `AppState` with a loaded source, useful for run/lint tests.
private func stateWithLoadedSource() -> (AppState, SourceID) {
    let id = SourceID(path: "scripts/init.lua")
    var state = AppState()

    let url = URL(fileURLWithPath: "/project/scripts/init.lua")
    let code = "print('hello')"
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: hash
    )
    let fragment = LuaSourceFragment(code: code, provenance: provenance)

    state.sources[id] = .loaded(fragment)
    state.navigatorOrder = [id]
    state.selection = id
    state.lintState = .idle
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (state, id)
}

/// Extracts a non-nil quit effect from an effect array.
private func extractQuit(_ effects: [Effect]) -> Int32? {
    for e in effects {
        if case .quit(let code) = e { return code }
    }
    return nil
}

// MARK: - Lifecycle tests

@Suite("Reducer — Lifecycle")
struct ReducerLifecycleTests {

    @Test("appStarted returns loadSources and prewarmLint effects")
    func appStartedEffects() {
        let state = AppState()
        let (_, effects) = reduce(state, .appStarted)

        let hasLoadSources = effects.contains {
            if case .loadSources = $0 { return true }
            return false
        }
        let hasPrewarm = effects.contains {
            if case .prewarmLint = $0 { return true }
            return false
        }

        #expect(hasLoadSources, "appStarted must return .loadSources")
        #expect(hasPrewarm, "appStarted must return .prewarmLint")
    }

    @Test("quit key produces quit effect with code 0")
    func quitKeyProducesQuitEffect() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let (_, effects) = reduce(state, .key(.char("q"), modifiers: []))
        #expect(extractQuit(effects) == 0)
    }

    @Test("lintEngineReady transitions lintState to idle")
    func lintEngineReadyTransition() {
        var state = AppState()
        state.lintState = .initializing
        let (next, _) = reduce(state, .lintEngineReady)
        #expect(next.lintState == .idle)
    }

    @Test("lintEngineFailed records failure message")
    func lintEngineFailedMessage() {
        var state = AppState()
        state.lintState = .initializing
        let (next, _) = reduce(state, .lintEngineFailed("out of memory"))
        if case .failed(let msg) = next.lintState {
            #expect(msg == "out of memory")
        } else {
            Issue.record("Expected .failed lintState")
        }
    }

    @Test("catalogProbed stores toml availability")
    func catalogProbedStored() {
        let state = AppState()
        let (next, _) = reduce(state, .catalogProbed(tomlAvailable: true))
        #expect(next.tomlModuleAvailable == true)
    }
}

// MARK: - Source loading tests

@Suite("Reducer — Source loading")
struct ReducerSourceLoadingTests {

    @Test("sourceLoaded adds source to state and navigator order")
    func sourceLoadedAddsToState() {
        let state = AppState()
        let id = SourceID(path: "init.lua")
        let url = URL(fileURLWithPath: "/project/init.lua")
        let code = "return 1"
        let data = Data(code.utf8)
        let hash = SHA256.hash(data: data)
        let provenance = FragmentProvenance(
            file: url,
            jsonpath: nil,
            document: 0,
            byteRange: 0..<data.count,
            lineOffset: 0,
            contentHash: hash
        )
        let fragment = LuaSourceFragment(code: code, provenance: provenance)

        let (next, effects) = reduce(state, .sourceLoaded(id: id, fragment: fragment))

        #expect(next.sources[id] != nil)
        #expect(next.navigatorOrder.contains(id))

        let hasHighlight = effects.contains {
            if case .highlight(let eid) = $0 { return eid == id }
            return false
        }
        #expect(hasHighlight, "sourceLoaded must request a highlight effect")
    }

    @Test("sourceFailed adds failed state to navigator")
    func sourceFailedAddsNavigatorEntry() {
        let state = AppState()
        let id = SourceID(path: "missing.lua")
        let diag = Diagnostic(severity: .error, message: "File not found", source: .sourceLoad)

        let (next, _) = reduce(state, .sourceFailed(id: id, state: .failed(diag)))
        #expect(next.navigatorOrder.contains(id))
        if case .failed(let d) = next.sources[id] {
            #expect(d.message == "File not found")
        } else {
            Issue.record("Expected .failed source state")
        }
    }

    @Test("sourceLoaded does not duplicate navigator entry")
    func noNavigatorDuplication() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        state.navigatorOrder = [id]

        let url = URL(fileURLWithPath: "/init.lua")
        let data = Data("print()".utf8)
        let hash = SHA256.hash(data: data)
        let prov = FragmentProvenance(
            file: url, jsonpath: nil, document: 0,
            byteRange: 0..<data.count, lineOffset: 0,
            contentHash: hash)
        let fragment = LuaSourceFragment(code: "print()", provenance: prov)

        let (next, _) = reduce(state, .sourceLoaded(id: id, fragment: fragment))
        let count = next.navigatorOrder.filter { $0 == id }.count
        #expect(count == 1, "Navigator must not duplicate entries")
    }
}

// MARK: - Run flow tests

@Suite("Reducer — Run flow")
struct ReducerRunFlowTests {

    @Test("r key starts a run when source is loaded and version supported")
    func rKeyStartsRun() {
        let (state, _) = stateWithLoadedSource()
        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        if case .running = next.runState {
        } else {
            Issue.record("Expected runState .running after r key")
        }
        let hasRun = effects.contains {
            if case .run = $0 { return true }
            return false
        }
        #expect(hasRun, "r key must produce .run effect")
        let hasStartTick = effects.contains {
            if case .startTick(let i) = $0 { return i == TickInterval.run }
            return false
        }
        #expect(hasStartTick, "r key must arm the tick source at run interval")
    }

    @Test("r key while running shows transient and drops new run")
    func rKeyDropsWhenRunning() {
        var (state, _) = stateWithLoadedSource()
        state.runState = .running(id: UUID(), startedAt: Date())

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        // runState unchanged; a transient is set; no .run effect.
        if case .running = next.runState {
        } else {
            Issue.record("Expected runState to remain .running")
        }
        #expect(next.transient != nil, "Should set a transient when run is blocked")
        let hasRun = effects.contains {
            if case .run = $0 { return true }
            return false
        }
        #expect(!hasRun, "r key during active run must not produce .run effect")
    }

    @Test("runOutput appends lines to outputBuffer unconditionally")
    func runOutputAppends() {
        var state = AppState()
        state.bottomPane.outputBuffer = ["line1"]

        let (next, _) = reduce(state, .runOutput(["line2", "line3"]))
        #expect(next.bottomPane.outputBuffer == ["line1", "line2", "line3"])
    }

    @Test("runOutput appends even after runFinished (late-output defense-in-depth)")
    func runOutputAppendsAfterFinished() {
        var state = AppState()
        state.runState = .completed(.cancelled)

        let (next, _) = reduce(state, .runOutput(["late line"]))
        #expect(next.bottomPane.outputBuffer == ["late line"])
    }

    @Test("runOutput enforces 1000-line FIFO cap")
    func runOutputEnforces1000LineCap() {
        var state = AppState()
        state.bottomPane.outputBuffer = Array(repeating: "x", count: 999)
        // Appending 5 lines exceeds the cap; oldest 4 lines should be evicted.
        let (next, _) = reduce(state, .runOutput(["a", "b", "c", "d", "e"]))
        #expect(next.bottomPane.outputBuffer.count == 1000)
        // The last line must be "e".
        #expect(next.bottomPane.outputBuffer.last == "e")
    }

    @Test("runFinished transitions to completed state")
    func runFinishedCompletesRun() {
        var state = AppState()
        state.runState = .running(id: UUID(), startedAt: Date())

        let (next, effects) = reduce(state, .runFinished(.cancelled))

        if case .completed(.cancelled) = next.runState {
        } else {
            Issue.record("Expected .completed(.cancelled) state")
        }
        // No tick needed after run ends with no transient.
        let hasStopTick = effects.contains {
            if case .stopTick = $0 { return true }
            return false
        }
        #expect(hasStopTick, "runFinished with no active transient must stop the tick")
    }
}

// MARK: - Lint flow tests

@Suite("Reducer — Lint flow")
struct ReducerLintFlowTests {

    @Test("l key starts lint when engine is idle and source is loaded")
    func lKeyStartsLint() {
        let (state, _) = stateWithLoadedSource()
        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.lintState == .running)
        let hasLint = effects.contains {
            if case .lint = $0 { return true }
            return false
        }
        #expect(hasLint, "l key must produce .lint effect")
    }

    @Test("l key while engine is initialising shows transient")
    func lKeyWhileInitialisingShowsTransient() {
        var (state, _) = stateWithLoadedSource()
        state.lintState = .initializing

        let (next, _) = reduce(state, .key(.char("l"), modifiers: []))
        #expect(next.transient?.text.contains("starting") == true)
    }

    @Test("lintFinished updates diagnostics and gutter marks")
    func lintFinishedUpdatesDiagnostics() {
        var state = AppState()
        state.lintState = .running
        let diag = Diagnostic(severity: .error, line: 3, message: "undefined global", source: .luacheck)

        let (next, _) = reduce(state, .lintFinished([diag]))

        #expect(next.lintState == .idle)
        #expect(next.bottomPane.diagnostics.count == 1)
        // Gutter mark at line 2 (0-based from 1-based line 3).
        #expect(next.codePane.gutterMarks[2] == .error)
    }

    @Test("prePassResult clears previous pre-pass diagnostic on success")
    func prePassResultClears() {
        var state = AppState()
        state.bottomPane.prePassDiagnostic = Diagnostic(
            severity: .error, line: 1, message: "syntax error", source: .syntaxPrePass)

        let (next, _) = reduce(state, .prePassResult(nil))
        #expect(next.bottomPane.prePassDiagnostic == nil)
    }

    @Test("prePassResult sets diagnostic on syntax error")
    func prePassResultSetsError() {
        let state = AppState()
        let diag = Diagnostic(severity: .error, line: 5, message: "'end' expected", source: .syntaxPrePass)

        let (next, _) = reduce(state, .prePassResult(diag))
        #expect(next.bottomPane.prePassDiagnostic == diag)
    }
}

// MARK: - Focus and navigation tests

@Suite("Reducer — Focus and navigation")
struct ReducerFocusTests {

    @Test("Tab cycles focus: navigator → codePane → bottomPane → navigator")
    func tabCyclesFocus() {
        var state = AppState()
        state.focus = .pane(.navigator)

        let (s1, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(s1.focus == .pane(.codePane))

        let (s2, _) = reduce(s1, .key(.tab, modifiers: []))
        #expect(s2.focus == .pane(.bottomPane))

        // Tab in bottom pane cycles its tabs first, then back to navigator.
        let (s3, _) = reduce(s2, .key(.tab, modifiers: []))
        #expect(s3.bottomPane.activeTab == .diagnostics)

        let (s4, _) = reduce(s3, .key(.tab, modifiers: []))
        #expect(s4.focus == .pane(.navigator))
    }

    @Test("S-Tab reverse-cycles panes unconditionally")
    func shiftTabReversesCycles() {
        var state = AppState()
        state.focus = .pane(.navigator)

        let (next, _) = reduce(state, .key(.backTab, modifiers: []))
        #expect(next.focus == .pane(.bottomPane))
    }

    @Test("Ctrl-h jumps focus to navigator")
    func ctrlHJumpsToNavigator() {
        var state = AppState()
        state.focus = .pane(.codePane)

        let (next, _) = reduce(state, .key(.char("h"), modifiers: .ctrl))
        #expect(next.focus == .pane(.navigator))
    }

    @Test("Ctrl-l jumps focus to codePane")
    func ctrlLJumpsToCodePane() {
        var state = AppState()
        state.focus = .pane(.bottomPane)

        let (next, _) = reduce(state, .key(.char("l"), modifiers: .ctrl))
        #expect(next.focus == .pane(.codePane))
    }

    @Test("Ctrl-j jumps focus to bottomPane")
    func ctrlJJumpsToBottomPane() {
        var state = AppState()
        state.focus = .pane(.navigator)

        let (next, _) = reduce(state, .key(.char("j"), modifiers: .ctrl))
        #expect(next.focus == .pane(.bottomPane))
    }

    @Test("? opens help overlay")
    func questionMarkOpensHelp() {
        var state = AppState()
        state.focus = .pane(.navigator)

        let (next, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(next.focus == .helpOverlay)
    }

    @Test("Esc in help overlay returns to navigator pane focus")
    func escClosesHelpOverlay() {
        var state = AppState()
        state.focus = .helpOverlay

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator))
    }

    @Test("Navigator j/k moves selection")
    func navigatorJKMovesSelection() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        state.navigatorOrder = ids
        state.navigator.selectedIndex = 0

        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.navigator.selectedIndex == 1)

        let (s2, _) = reduce(s1, .key(.char("j"), modifiers: []))
        #expect(s2.navigator.selectedIndex == 2)

        let (s3, _) = reduce(s2, .key(.char("j"), modifiers: []))
        // At last entry — should not exceed bounds.
        #expect(s3.navigator.selectedIndex == 2)

        let (s4, _) = reduce(s3, .key(.char("k"), modifiers: []))
        #expect(s4.navigator.selectedIndex == 1)
    }

    @Test("Navigator g/G jump to first and last entries")
    func navigatorGGJumps() {
        var state = AppState()
        state.focus = .pane(.navigator)
        state.navigatorOrder = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        state.navigator.selectedIndex = 1

        let (s1, _) = reduce(state, .key(.char("g"), modifiers: []))
        #expect(s1.navigator.selectedIndex == 0)

        let (s2, _) = reduce(s1, .key(.char("G"), modifiers: []))
        #expect(s2.navigator.selectedIndex == 1)
    }
}

// MARK: - Tick and transient tests

@Suite("Reducer — Tick and transient")
struct ReducerTickTests {

    @Test("tick expires transient message after its deadline")
    func tickExpiresTransient() {
        var state = AppState()
        // Force expiry to the past by overwriting the expiry field via a fresh struct.
        state.transient = TransientMessage(text: "test")
        // Travel time: wait for the message's real expiry (1.5s) is too slow
        // for a unit test — instead we simulate by checking that a .tick
        // clears it when Date() >= expiry. We can't easily inject time here,
        // so we just verify the tick path clears an already-expired transient.
        // Create a transient that expired 1 second ago.
        state.transient = TransientMessage.makeExpired(text: "stale message")

        let (next, effects) = reduce(state, .tick)
        #expect(next.transient == nil, "Tick must clear an expired transient")
        let hasStopTick = effects.contains {
            if case .stopTick = $0 { return true }
            return false
        }
        #expect(hasStopTick, "After transient cleared with no other consumers, tick must stop")
    }

    @Test("tick preserves active transient before deadline")
    func tickPreservesActiveTransient() {
        var state = AppState()
        // Create a transient that expires far in the future.
        state.transient = TransientMessage.makeFuture(text: "active message", secondsFromNow: 60)

        let (next, _) = reduce(state, .tick)
        #expect(next.transient != nil, "Tick must NOT clear a transient that has not expired")
    }

    @Test("tick advances navigator spinner phase")
    func tickAdvancesSpinner() {
        var state = AppState()
        state.navigator.spinnerPhase = 7  // At wrap boundary.

        let (next, _) = reduce(state, .tick)
        #expect(next.navigator.spinnerPhase == 0, "Spinner must wrap at 8")
    }
}

// MARK: - Highlight tests

@Suite("Reducer — Highlight")
struct ReducerHighlightTests {

    @Test("highlightReady stores spans in AppState.highlight")
    func highlightReadyStoresSpans() {
        let state = AppState()
        let id = SourceID(path: "init.lua")
        let spans = [
            HighlightSpan(line: 0, column: 0, length: 5, tokenKind: .keyword),
            HighlightSpan(line: 1, column: 4, length: 3, tokenKind: .number),
        ]

        let (next, _) = reduce(state, .highlightReady(id, spans: spans))
        #expect(next.highlight[id] == spans)
    }

    @Test("highlightReady replaces previous spans for the same source")
    func highlightReadyReplaces() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        state.highlight[id] = [HighlightSpan(line: 0, column: 0, length: 10, tokenKind: .comment)]

        let newSpans = [HighlightSpan(line: 0, column: 0, length: 5, tokenKind: .string)]
        let (next, _) = reduce(state, .highlightReady(id, spans: newSpans))
        #expect(next.highlight[id]?.count == 1)
        #expect(next.highlight[id]?.first?.tokenKind == .string)
    }
}

// MARK: - TransientMessage helper extension for tests

extension TransientMessage {
    /// Creates a `TransientMessage` with an already-past expiry (for tick tests).
    static func makeExpired(text: String) -> TransientMessage {
        // Create a TransientMessage with a past expiry via a custom initializer.
        return _Expired(text: text)
    }

    /// Creates a `TransientMessage` with an expiry far in the future.
    static func makeFuture(text: String, secondsFromNow: Double) -> TransientMessage {
        return _Future(text: text, seconds: secondsFromNow)
    }

    // Workaround: since TransientMessage.expiry is let, we inject via custom init.
    private static func _Expired(text: String) -> TransientMessage {
        // Abuse the duration parameter to create a very-short expiry, then
        // return the struct. We can't directly set a past date, so we use
        // Duration.zero and let it expire "immediately" in the context of the test.
        // The reducer checks Date() >= expiry; with duration 0 the expiry is
        // in the past by definition as soon as we return from this call.
        return TransientMessage(text: text, duration: .zero)
    }

    private static func _Future(text: String, seconds: Double) -> TransientMessage {
        return TransientMessage(text: text, duration: .seconds(Int(seconds)))
    }
}
