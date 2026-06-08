// File: Tests/MoonSwiftTUITests/ReducerSequenceTests.swift
// Location: MoonSwiftTUITests/
// Role: Comprehensive table-driven reducer sequence tests. Each test drives a
//       multi-step event sequence and verifies the resulting state and effect
//       list. Covers all seven areas from the task specification: navigation,
//       run flows, lint flows, source loading, cross-producer interleavings,
//       modal flows, and disabled-action transients.
//
//       This file is additive with respect to ReducerTests.swift — it does not
//       replace any existing tests but extends coverage to multi-event sequences
//       and interactions the basic suite does not exercise.
//
// Upstream: Reducer.swift, AppState.swift, AppEvent.swift, Effect.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Shared test helpers

/// Applies an ordered sequence of events to an initial state, threading the
/// returned state through each step. Returns the final state and the effects
/// emitted from the last event only.
///
/// Use `applyAll` when you need to inspect the final state after a sequence.
/// Use `reduce` directly when you need effects from each step.
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

/// Applies an ordered sequence of events, collecting the effects from every
/// step. Returns the final state and a flat list of all effects in emission
/// order.
private func applyAllCollectingEffects(
    _ state: AppState, _ events: [AppEvent]
) -> (AppState, [[Effect]]) {
    var current = state
    var allEffects: [[Effect]] = []
    for event in events {
        let (next, effects) = reduce(current, event)
        current = next
        allEffects.append(effects)
    }
    return (current, allEffects)
}

/// Returns a `LuaSourceFragment` backed by the given source string, with a
/// synthetic file URL and a SHA-256 hash provenance.
private func makeFragment(code: String, path: String) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
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
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// Returns a minimal `AppState` with one loaded source and the lint engine
/// idle, suitable for run/lint sequence tests.
private func loadedSourceState(
    code: String = "print('hello')",
    path: String = "/project/scripts/init.lua"
) -> (AppState, SourceID) {
    let id = SourceID(path: "scripts/init.lua")
    var state = AppState()
    let fragment = makeFragment(code: code, path: path)
    state.sources[id] = .loaded(fragment)
    state.navigatorOrder = [id]
    state.selection = id
    state.lintState = .idle
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (state, id)
}

/// Returns true if any effect in the array matches the given predicate.
private func hasEffect(_ effects: [Effect], matching predicate: (Effect) -> Bool) -> Bool {
    effects.contains(where: predicate)
}

/// Returns true if the effect list contains a `.loadSources` effect.
private func hasLoadSources(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .loadSources = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.prewarmLint` effect.
private func hasPrewarmLint(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .prewarmLint = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.run` effect.
private func hasRunEffect(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .run = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.lint` effect.
private func hasLintEffect(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .lint = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.cancelRun` effect.
private func hasCancelRun(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .cancelRun = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.stopTick` effect.
private func hasStopTick(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .stopTick = $0 { return true }
        return false
    }
}

/// Returns true if the effect list contains a `.startTick` effect at any
/// interval.
private func hasStartTick(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .startTick = $0 { return true }
        return false
    }
}

/// Returns true if `runState` is `.running`.
private func isRunning(_ state: AppState) -> Bool {
    if case .running = state.runState { return true }
    return false
}

/// Returns true if `runState` is `.completed` with the given outcome.
private func isCompleted(_ state: AppState, _ outcome: RunOutcome) -> Bool {
    if case .completed(let o) = state.runState { return o == outcome }
    return false
}

// MARK: - 1. Navigation sequence tests

@Suite("ReducerSequence — Navigation")
struct NavigationSequenceTests {

    // MARK: Tab cycling — full pane cycle

    @Test("Tab cycles navigator → codePane → bottomPane → (tabs) → navigator")
    func fullTabCycle() {
        var state = AppState()
        state.focus = .pane(.navigator)

        // Step 1: navigator → codePane
        let (s1, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(s1.focus == .pane(.codePane))

        // Step 2: codePane → bottomPane
        let (s2, _) = reduce(s1, .key(.tab, modifiers: []))
        #expect(s2.focus == .pane(.bottomPane))
        #expect(s2.bottomPane.activeTab == .output, "Initial tab must be output")

        // Step 3: bottomPane with output tab → switch to diagnostics (context-sensitive Tab)
        let (s3, _) = reduce(s2, .key(.tab, modifiers: []))
        #expect(s3.focus == .pane(.bottomPane), "Focus must stay on bottomPane during tab cycle")
        #expect(s3.bottomPane.activeTab == .diagnostics)
        #expect(s3.bottomPane.scrollOffset == 0, "Tab switch must reset scroll")

        // Step 4: bottomPane with diagnostics tab → back to navigator
        let (s4, _) = reduce(s3, .key(.tab, modifiers: []))
        #expect(s4.focus == .pane(.navigator))
    }

    // MARK: S-Tab reverse cycling — no context sensitivity

    @Test("S-Tab cycles bottomPane → codePane → navigator")
    func reverseTabCycles() {
        var state = AppState()
        state.focus = .pane(.navigator)

        // S-Tab from navigator goes to bottomPane (wraps)
        let (s1, _) = reduce(state, .key(.backTab, modifiers: []))
        #expect(s1.focus == .pane(.bottomPane))

        // S-Tab from bottomPane goes to codePane
        let (s2, _) = reduce(s1, .key(.backTab, modifiers: []))
        #expect(s2.focus == .pane(.codePane))

        // S-Tab from codePane goes to navigator
        let (s3, _) = reduce(s2, .key(.backTab, modifiers: []))
        #expect(s3.focus == .pane(.navigator))
    }

    @Test("S-Tab from bottomPane does not cycle inner tabs")
    func shiftTabDoesNotCycleBottomPaneTabs() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .diagnostics

        let (next, _) = reduce(state, .key(.backTab, modifiers: []))
        // S-Tab must change pane focus, not cycle tabs
        #expect(next.focus == .pane(.codePane))
        #expect(next.bottomPane.activeTab == .diagnostics, "S-Tab must not change inner tab")
    }

    // MARK: Tab inside modal — no effect

    @Test("Tab inside helpOverlay does not cycle panes")
    func tabInsideModalNoEffect() {
        var state = AppState()
        state.focus = .helpOverlay

        let (next, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(next.focus == .helpOverlay, "Tab must not change focus while a modal is open")
    }

    // MARK: Direct focus jumps

    @Test("C-h / C-l / C-j jump focus regardless of starting pane")
    func directFocusJumps() {
        // Table: (start focus, key, modifier, expected focus)
        typealias Row = (FocusState, KeyCode, KeyModifiers, FocusState)
        let table: [Row] = [
            (.pane(.codePane), .char("h"), .ctrl, .pane(.navigator)),
            (.pane(.bottomPane), .char("h"), .ctrl, .pane(.navigator)),
            (.pane(.navigator), .char("h"), .ctrl, .pane(.navigator)),
            (.pane(.navigator), .char("l"), .ctrl, .pane(.codePane)),
            (.pane(.codePane), .char("l"), .ctrl, .pane(.codePane)),
            (.pane(.navigator), .char("j"), .ctrl, .pane(.bottomPane)),
            (.pane(.codePane), .char("j"), .ctrl, .pane(.bottomPane)),
        ]

        for (startFocus, code, mod, expectedFocus) in table {
            var state = AppState()
            state.focus = startFocus
            let (next, _) = reduce(state, .key(code, modifiers: mod))
            #expect(
                next.focus == expectedFocus,
                "From \(startFocus): \(code) + \(mod) → expected \(expectedFocus), got \(next.focus)"
            )
        }
    }

    // MARK: Navigator j/k/g/G sequence

    @Test("Navigator j/k navigation clamps at boundaries")
    func navigatorJKClampsBoundaries() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let ids = [
            SourceID(path: "a.lua"),
            SourceID(path: "b.lua"),
            SourceID(path: "c.lua"),
        ]
        state.navigatorOrder = ids
        state.navigator.selectedIndex = 0

        // j from 0 → 1
        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.navigator.selectedIndex == 1)

        // j from 1 → 2
        let (s2, _) = reduce(s1, .key(.char("j"), modifiers: []))
        #expect(s2.navigator.selectedIndex == 2)

        // j from 2 (last) → stays at 2
        let (s3, _) = reduce(s2, .key(.char("j"), modifiers: []))
        #expect(s3.navigator.selectedIndex == 2, "j at last entry must clamp")

        // k from 2 → 1
        let (s4, _) = reduce(s3, .key(.char("k"), modifiers: []))
        #expect(s4.navigator.selectedIndex == 1)

        // k from 1 → 0
        let (s5, _) = reduce(s4, .key(.char("k"), modifiers: []))
        #expect(s5.navigator.selectedIndex == 0)

        // k from 0 (first) → stays at 0
        let (s6, _) = reduce(s5, .key(.char("k"), modifiers: []))
        #expect(s6.navigator.selectedIndex == 0, "k at first entry must clamp")
    }

    @Test("Navigator g/G jump to first and last with more than two entries")
    func navigatorGGJumpMultiEntry() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let ids = (0..<5).map { SourceID(path: "file\($0).lua") }
        state.navigatorOrder = ids
        state.navigator.selectedIndex = 3

        // g jumps to first
        let (s1, _) = reduce(state, .key(.char("g"), modifiers: []))
        #expect(s1.navigator.selectedIndex == 0)

        // G jumps to last
        let (s2, _) = reduce(s1, .key(.char("G"), modifiers: []))
        #expect(s2.navigator.selectedIndex == 4)
    }

    @Test("Navigator g/G on empty list does not crash")
    func navigatorGGEmptyList() {
        var state = AppState()
        state.focus = .pane(.navigator)
        state.navigatorOrder = []
        state.navigator.selectedIndex = 0

        let (s1, _) = reduce(state, .key(.char("g"), modifiers: []))
        #expect(s1.navigator.selectedIndex == 0)

        let (s2, _) = reduce(s1, .key(.char("G"), modifiers: []))
        #expect(s2.navigator.selectedIndex == 0)
    }

    // MARK: Code pane scroll keys

    @Test("Code pane j/k/d/u/f/b/g/G scroll keys sequence")
    func codePaneScrollKeys() {
        var state = AppState()
        state.focus = .pane(.codePane)
        state.codePane.scrollOffset = 0

        // j scrolls down 1
        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.codePane.scrollOffset == 1)

        // d scrolls down half page (10)
        let (s2, _) = reduce(s1, .key(.char("d"), modifiers: []))
        #expect(s2.codePane.scrollOffset == 11)

        // f scrolls down full page (20)
        let (s3, _) = reduce(s2, .key(.char("f"), modifiers: []))
        #expect(s3.codePane.scrollOffset == 31)

        // u scrolls up half page (10)
        let (s4, _) = reduce(s3, .key(.char("u"), modifiers: []))
        #expect(s4.codePane.scrollOffset == 21)

        // b scrolls up full page (20)
        let (s5, _) = reduce(s4, .key(.char("b"), modifiers: []))
        #expect(s5.codePane.scrollOffset == 1)

        // k scrolls up 1
        let (s6, _) = reduce(s5, .key(.char("k"), modifiers: []))
        #expect(s6.codePane.scrollOffset == 0)

        // k at 0 clamps to 0
        let (s7, _) = reduce(s6, .key(.char("k"), modifiers: []))
        #expect(s7.codePane.scrollOffset == 0, "k at 0 must clamp")

        // G jumps to bottom (large sentinel)
        let (s8, _) = reduce(s7, .key(.char("G"), modifiers: []))
        #expect(s8.codePane.scrollOffset > 1000, "G must set a large scroll offset")

        // g jumps to top
        let (s9, _) = reduce(s8, .key(.char("g"), modifiers: []))
        #expect(s9.codePane.scrollOffset == 0)
    }

    @Test("Code pane scroll up clamps at zero, never goes negative")
    func codePaneScrollNeverNegative() {
        var state = AppState()
        state.focus = .pane(.codePane)
        state.codePane.scrollOffset = 2

        // u from 2 → clamped at 0 (10 - 2 = 8 would overshoot; max(0, 2-10) = 0)
        let (s1, _) = reduce(state, .key(.char("u"), modifiers: []))
        #expect(s1.codePane.scrollOffset == 0)

        // b from 0 → clamped at 0
        let (s2, _) = reduce(s1, .key(.char("b"), modifiers: []))
        #expect(s2.codePane.scrollOffset == 0)
    }

    // MARK: Bottom pane tab quick-jump keys

    @Test("Bottom pane 1/2 keys quick-jump tabs and reset scroll")
    func bottomPaneQuickJumpTabs() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        state.bottomPane.scrollOffset = 15

        // 2 jumps to diagnostics tab and resets scroll
        let (s1, _) = reduce(state, .key(.char("2"), modifiers: []))
        #expect(s1.bottomPane.activeTab == .diagnostics)
        #expect(s1.bottomPane.scrollOffset == 0)

        // 1 jumps back to output tab and resets scroll
        var s1Scrolled = s1
        s1Scrolled.bottomPane.scrollOffset = 8
        let (s2, _) = reduce(s1Scrolled, .key(.char("1"), modifiers: []))
        #expect(s2.bottomPane.activeTab == .output)
        #expect(s2.bottomPane.scrollOffset == 0)
    }

    // MARK: Pane-width adjustment keys

    @Test("< / > narrow and widen navigator, clamped to [18, 30]")
    func navigatorWidthAdjustment() {
        var state = AppState()
        // Start at default (18)
        state.paneLayout.navigatorWidth = 18

        // < at minimum clamps
        let (s1, _) = reduce(state, .key(.char("<"), modifiers: []))
        #expect(s1.paneLayout.navigatorWidth == 18, "< at minimum must clamp to 18")

        // > increases by 2
        let (s2, _) = reduce(s1, .key(.char(">"), modifiers: []))
        #expect(s2.paneLayout.navigatorWidth == 20)

        // > at maximum clamps
        var atMax = s2
        atMax.paneLayout.navigatorWidth = 30
        let (s3, _) = reduce(atMax, .key(.char(">"), modifiers: []))
        #expect(s3.paneLayout.navigatorWidth == 30, "> at maximum must clamp to 30")
    }

    @Test("{ / } shrink and grow bottom pane height, clamped to [5, 40]")
    func bottomPaneHeightAdjustment() {
        var state = AppState()
        state.paneLayout.bottomPaneHeight = 8

        // { shrinks by 1
        let (s1, _) = reduce(state, .key(.char("{"), modifiers: []))
        #expect(s1.paneLayout.bottomPaneHeight == 7)

        // } grows by 1
        let (s2, _) = reduce(s1, .key(.char("}"), modifiers: []))
        #expect(s2.paneLayout.bottomPaneHeight == 8)

        // { at minimum clamps
        var atMin = s2
        atMin.paneLayout.bottomPaneHeight = 5
        let (s3, _) = reduce(atMin, .key(.char("{"), modifiers: []))
        #expect(s3.paneLayout.bottomPaneHeight == 5, "{ at minimum must clamp to 5")

        // } at maximum clamps
        var atMax = s3
        atMax.paneLayout.bottomPaneHeight = 40
        let (s4, _) = reduce(atMax, .key(.char("}"), modifiers: []))
        #expect(s4.paneLayout.bottomPaneHeight == 40, "} at maximum must clamp to 40")
    }
}

// MARK: - 2. Run flow sequence tests

@Suite("ReducerSequence — Run flow")
struct RunFlowSequenceTests {

    // MARK: Full r → running → output → runFinished sequence

    @Test("r → runOutput → runFinished: full run lifecycle sequence")
    func fullRunLifecycle() {
        var (state, _) = loadedSourceState()
        state.focus = .pane(.navigator)

        // Step 1: r starts the run
        let (s1, e1) = reduce(state, .key(.char("r"), modifiers: []))
        #expect(isRunning(s1), "After r: runState must be .running")
        #expect(s1.bottomPane.activeTab == .output, "After r: bottom pane must auto-switch to output")
        #expect(s1.bottomPane.outputBuffer.isEmpty, "After r: output buffer must be cleared")
        #expect(hasRunEffect(e1), "After r: must emit .run effect")
        #expect(
            hasEffect(e1) {
                if case .startTick(TickInterval.run) = $0 { return true }
                return false
            },
            "After r: must arm tick at run interval"
        )

        // Step 2: runOutput appends lines
        let (s2, _) = reduce(s1, .runOutput(["line 1", "line 2"]))
        #expect(s2.bottomPane.outputBuffer == ["line 1", "line 2"])
        #expect(isRunning(s2), "runOutput must not change runState")

        // Step 3: more runOutput appends
        let (s3, _) = reduce(s2, .runOutput(["line 3"]))
        #expect(s3.bottomPane.outputBuffer == ["line 1", "line 2", "line 3"])

        // Step 4: runFinished transitions state
        let (s4, e4) = reduce(s3, .runFinished(.done(value: nil, duration: .milliseconds(42))))
        #expect(isCompleted(s4, .done(value: nil, duration: .milliseconds(42))))
        #expect(
            !isRunning(s4),
            "After runFinished: runState must not be .running"
        )
        // No transient is active so tick must stop
        #expect(hasStopTick(e4), "After runFinished with no transient: must stop tick")
    }

    // MARK: Concurrent-run guard

    @Test("r while running: transient shown, runState unchanged, no .run effect")
    func concurrentRunGuard() {
        var (state, _) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())
        let runId = state.runState  // capture original

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        // runState must be unchanged
        #expect(next.runState == runId)
        // Transient must be set
        #expect(next.transient != nil, "Concurrent run must set a transient")
        // No .run effect
        #expect(!hasRunEffect(effects), "Concurrent run must not emit .run effect")
        // Tick must be armed for transient expiry
        #expect(hasStartTick(effects), "Concurrent run must arm tick for transient")
    }

    @Test("r while running: sequence r, r shows transient without losing first run")
    func doubleRSequence() {
        let (state, _) = loadedSourceState()

        // First r starts the run
        let (s1, _) = reduce(state, .key(.char("r"), modifiers: []))
        #expect(isRunning(s1))

        // Second r is a no-op for the run, sets transient
        let (s2, e2) = reduce(s1, .key(.char("r"), modifiers: []))
        #expect(isRunning(s2), "Second r must not start a new run")
        #expect(s2.transient != nil)
        #expect(!hasRunEffect(e2))
    }

    // MARK: Cancellation with x

    @Test("x key emits cancelRun effect regardless of runState")
    func xKeyCancelRun() {
        // Test with .running state
        var (state, _) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())

        let (_, e1) = reduce(state, .key(.char("x"), modifiers: []))
        #expect(hasCancelRun(e1), "x while running must emit .cancelRun")

        // Test with .idle state (no-op for the service but effect is still emitted)
        state.runState = .idle
        let (_, e2) = reduce(state, .key(.char("x"), modifiers: []))
        #expect(hasCancelRun(e2), "x while idle must still emit .cancelRun")
    }

    @Test("x → runFinished(.cancelled): full cancellation sequence")
    func cancellationSequence() {
        let (state, _) = loadedSourceState()

        // r starts run
        let (s1, _) = reduce(state, .key(.char("r"), modifiers: []))
        #expect(isRunning(s1))

        // x requests cancellation (effect dispatched)
        let (s2, e2) = reduce(s1, .key(.char("x"), modifiers: []))
        #expect(hasCancelRun(e2))
        // runState is still running until service posts runFinished
        #expect(isRunning(s2), "runState must remain .running until runFinished arrives")

        // Service posts runFinished(.cancelled)
        let (s3, e3) = reduce(s2, .runFinished(.cancelled))
        #expect(isCompleted(s3, .cancelled))
        #expect(hasStopTick(e3), "After cancelled run: tick must stop")
    }

    // MARK: Error outcome

    @Test("runFinished(.error): state transitions to completed")
    func runFinishedError() {
        var state = AppState()
        state.runState = .running(id: UUID(), startedAt: Date())
        let diag = Diagnostic(severity: .error, line: 5, message: "attempt to index nil", source: .runtime)

        let (next, _) = reduce(state, .runFinished(.error(diag, traceback: ["stack line 1"])))

        if case .completed(.error(let d, let tb)) = next.runState {
            #expect(d.message == "attempt to index nil")
            #expect(tb == ["stack line 1"])
        } else {
            Issue.record("Expected .completed(.error) runState")
        }
    }

    // MARK: Limit exceeded

    @Test("runFinished(.limitExceeded): both limit kinds captured correctly")
    func runFinishedLimitExceeded() {
        var state = AppState()
        state.runState = .running(id: UUID(), startedAt: Date())

        // Instructions limit
        let (s1, _) = reduce(state, .runFinished(.limitExceeded(kind: .instructions)))
        if case .completed(.limitExceeded(let k)) = s1.runState {
            #expect(k == .instructions)
        } else {
            Issue.record("Expected .completed(.limitExceeded(.instructions))")
        }

        // Wall-clock limit
        let (s2, _) = reduce(state, .runFinished(.limitExceeded(kind: .wallClock)))
        if case .completed(.limitExceeded(let k)) = s2.runState {
            #expect(k == .wallClock)
        } else {
            Issue.record("Expected .completed(.limitExceeded(.wallClock))")
        }
    }

    // MARK: Tick during run

    @Test("tick during run: spinner advances, tick re-armed at run interval")
    func tickDuringRun() {
        var (state, _) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())
        state.navigator.spinnerPhase = 3

        let (next, effects) = reduce(state, .tick)

        #expect(next.navigator.spinnerPhase == 4)
        // Tick must re-arm because run is still active
        #expect(
            hasEffect(effects) {
                if case .startTick(TickInterval.run) = $0 { return true }
                return false
            },
            "Tick during run must re-arm at run interval"
        )
        #expect(!hasStopTick(effects), "Tick during run must not stop tick")
    }
}

// MARK: - 3. Lint flow sequence tests

@Suite("ReducerSequence — Lint flow")
struct LintFlowSequenceTests {

    // MARK: Full l → running → lintFinished sequence

    @Test("l → lintFinished: full lint lifecycle sequence")
    func fullLintLifecycle() {
        var (state, _) = loadedSourceState()
        state.focus = .pane(.navigator)

        // Step 1: l starts lint
        let (s1, e1) = reduce(state, .key(.char("l"), modifiers: []))
        #expect(s1.lintState == .running, "After l: lintState must be .running")
        #expect(s1.bottomPane.activeTab == .diagnostics, "After l: bottom pane must switch to diagnostics")
        #expect(hasLintEffect(e1), "After l: must emit .lint effect")

        // Step 2: lintFinished clears diagnostics and gutter
        let diag = Diagnostic(severity: .warning, line: 2, message: "unused var", source: .luacheck)
        let (s2, _) = reduce(s1, .lintFinished([diag]))

        #expect(s2.lintState == .idle, "After lintFinished: lintState must return to idle")
        #expect(s2.bottomPane.diagnostics == [diag])
        #expect(s2.codePane.gutterMarks[1] == .warning, "Gutter mark at line 1 (0-based) for warning at line 2")
    }

    @Test("l → lintFinished with no diagnostics: clears gutter marks")
    func lintFinishedEmpty() {
        var (state, _) = loadedSourceState()
        // Pre-set some gutter marks
        state.codePane.gutterMarks = [0: .error, 2: .warning]
        state.lintState = .running

        let (next, _) = reduce(state, .lintFinished([]))
        #expect(next.lintState == .idle)
        #expect(next.bottomPane.diagnostics.isEmpty)
        #expect(next.codePane.gutterMarks.isEmpty, "lintFinished([]) must clear all gutter marks")
    }

    // MARK: Pre-warm sequence

    @Test("appStarted → prewarmLint → lintEngineReady: pre-warm sequence")
    func prewarmSequence() {
        let state = AppState()

        // Step 1: appStarted returns prewarmLint effect
        let (_, e1) = reduce(state, .appStarted)
        #expect(hasPrewarmLint(e1), "appStarted must emit .prewarmLint")

        // Step 2: lintEngineReady transitions engine from initializing to idle
        var initState = AppState()
        initState.lintState = .initializing
        let (s2, _) = reduce(initState, .lintEngineReady)
        #expect(s2.lintState == .idle, "lintEngineReady must transition .initializing → .idle")
    }

    // MARK: Engine failure

    @Test("lintEngineFailed transitions to .failed and records message")
    func lintEngineFailedSequence() {
        var state = AppState()
        state.lintState = .initializing

        let (next, _) = reduce(state, .lintEngineFailed("Lua 5.4 bridge missing"))

        if case .failed(let msg) = next.lintState {
            #expect(msg == "Lua 5.4 bridge missing")
        } else {
            Issue.record("Expected lintState == .failed after lintEngineFailed")
        }
    }

    @Test("l while engine is failed: transient shown, no .lint effect")
    func lWhileEngineFailed() {
        var (state, _) = loadedSourceState()
        state.lintState = .failed("bridge error")

        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.transient != nil, "l with failed engine must show transient")
        #expect(!hasLintEffect(effects), "l with failed engine must not emit .lint effect")
    }

    // MARK: prePassResult sequence

    @Test("prePassResult(nil) clears pre-pass diagnostic")
    func prePassResultClearsDiagnostic() {
        var state = AppState()
        let priorDiag = Diagnostic(severity: .error, line: 3, message: "expected 'end'", source: .syntaxPrePass)
        state.bottomPane.prePassDiagnostic = priorDiag
        state.bottomPane.diagnostics = [priorDiag]

        let (next, _) = reduce(state, .prePassResult(nil))

        #expect(next.bottomPane.prePassDiagnostic == nil, "prePassResult(nil) must clear pre-pass diagnostic")
    }

    @Test("prePassResult with diagnostic: sets pre-pass and adds to diagnostics")
    func prePassResultSetsDiagnostic() {
        let state = AppState()
        let diag = Diagnostic(severity: .error, line: 1, message: "syntax error near '}'", source: .syntaxPrePass)

        let (next, _) = reduce(state, .prePassResult(diag))

        #expect(next.bottomPane.prePassDiagnostic == diag)
        #expect(next.bottomPane.diagnostics.contains(diag))
        #expect(next.codePane.gutterMarks[0] == .error, "Pre-pass error at line 1 must produce gutter mark at index 0")
    }

    @Test("prePassResult sequence: error then clear then error again")
    func prePassResultMultipleUpdates() {
        let state = AppState()

        // First pass: syntax error
        let err1 = Diagnostic(severity: .error, line: 2, message: "err1", source: .syntaxPrePass)
        let (s1, _) = reduce(state, .prePassResult(err1))
        #expect(s1.bottomPane.prePassDiagnostic == err1)

        // Second pass: clean
        let (s2, _) = reduce(s1, .prePassResult(nil))
        #expect(s2.bottomPane.prePassDiagnostic == nil)

        // Third pass: new error
        let err2 = Diagnostic(severity: .error, line: 5, message: "err2", source: .syntaxPrePass)
        let (s3, _) = reduce(s2, .prePassResult(err2))
        #expect(s3.bottomPane.prePassDiagnostic == err2)
    }

    // MARK: l while lint is already running

    @Test("l while lint is running: transient shown, no second .lint effect")
    func lWhileLintRunning() {
        var (state, _) = loadedSourceState()
        state.lintState = .running

        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.transient != nil, "l while lint running must show transient")
        #expect(!hasLintEffect(effects), "l while lint running must not emit second .lint effect")
    }
}

// MARK: - 4. Source loading sequence tests

@Suite("ReducerSequence — Source loading")
struct SourceLoadingSequenceTests {

    // MARK: appStarted → loadSources

    @Test("appStarted emits .loadSources and .prewarmLint as startup effects")
    func appStartedEmitsStartupEffects() {
        let state = AppState()
        let (_, effects) = reduce(state, .appStarted)
        #expect(hasLoadSources(effects), "appStarted must emit .loadSources")
        #expect(hasPrewarmLint(effects), "appStarted must emit .prewarmLint")
    }

    @Test("appStarted on second call (reload scenario) still emits .loadSources")
    func appStartedIdempotent() {
        var state = AppState()
        // Simulate already-loaded state
        let id = SourceID(path: "init.lua")
        let fragment = makeFragment(code: "print()", path: "/project/init.lua")
        state.sources[id] = .loaded(fragment)
        state.navigatorOrder = [id]

        let (_, effects) = reduce(state, .appStarted)
        #expect(hasLoadSources(effects))
    }

    // MARK: sourceLoaded → navigator update

    @Test("sourceLoaded sequence: multiple sources load in order")
    func multipleSourcesLoad() {
        let state = AppState()
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        let fragments = ids.map { id in makeFragment(code: "-- \(id.path)", path: "/project/\(id.path)") }

        // Load sources one by one
        var current = state
        for (id, fragment) in zip(ids, fragments) {
            let (next, effects) = reduce(current, .sourceLoaded(id: id, fragment: fragment))
            #expect(next.sources[id] != nil)
            #expect(next.navigatorOrder.contains(id))
            #expect(
                hasEffect(effects) {
                    if case .highlight(let eid) = $0 { return eid == id }
                    return false
                },
                "sourceLoaded must emit .highlight for \(id.path)"
            )
            current = next
        }

        // All three sources must be in navigator order
        #expect(current.navigatorOrder == ids)
    }

    @Test("sourceLoaded: loading an already-known ID does not duplicate navigator entry")
    func reloadDoesNotDuplicate() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        state.navigatorOrder = [id]
        let fragment = makeFragment(code: "print(1)", path: "/project/init.lua")

        let (next, _) = reduce(state, .sourceLoaded(id: id, fragment: fragment))
        let count = next.navigatorOrder.filter { $0 == id }.count
        #expect(count == 1, "Reloading a known source must not duplicate it in navigator order")
    }

    @Test("sourceLoaded: newly loaded source gets a .highlight effect")
    func sourceLoadedRequestsHighlight() {
        let state = AppState()
        let id = SourceID(path: "a.lua")
        let fragment = makeFragment(code: "return 42", path: "/project/a.lua")

        let (_, effects) = reduce(state, .sourceLoaded(id: id, fragment: fragment))
        let hasHighlight = effects.contains {
            if case .highlight(let eid) = $0 { return eid == id }
            return false
        }
        #expect(hasHighlight)
    }

    // MARK: sourceFailed

    @Test("sourceFailed: adds failed state and appears in navigator")
    func sourceFailedSequence() {
        let state = AppState()
        let id = SourceID(path: "missing.lua")
        let diag = Diagnostic(severity: .error, message: "File not found", source: .sourceLoad)

        let (next, _) = reduce(state, .sourceFailed(id: id, state: .failed(diag)))

        #expect(next.navigatorOrder.contains(id))
        if case .failed(let d) = next.sources[id] {
            #expect(d.message == "File not found")
        } else {
            Issue.record("Expected .failed(diag) in sources")
        }
    }

    @Test("sourceFailed with .missing state: stored correctly")
    func sourceFailedMissingState() {
        let state = AppState()
        let id = SourceID(path: "ghost.lua")

        let (next, _) = reduce(state, .sourceFailed(id: id, state: .missing))

        #expect(next.navigatorOrder.contains(id))
        if case .missing = next.sources[id] {
            // correct
        } else {
            Issue.record("Expected .missing source state")
        }
    }

    // MARK: designationsSaved

    @Test("designationsSaved emits .loadSources to reload all sources")
    func designationsSavedTriggersReload() {
        let state = AppState()
        let (_, effects) = reduce(state, .designationsSaved)
        #expect(hasLoadSources(effects), "designationsSaved must trigger .loadSources")
    }
}

// MARK: - 5. Cross-producer interleaving tests

@Suite("ReducerSequence — Cross-producer interleavings")
struct CrossProducerInterleavingTests {

    // MARK: lintFinished after runFinished

    @Test("lintFinished arriving after runFinished: both results are applied")
    func lintFinishedAfterRunFinished() {
        var (state, _) = loadedSourceState()
        // Simulate run completed and lint in progress simultaneously
        state.runState = .running(id: UUID(), startedAt: Date())
        state.lintState = .running

        // runFinished arrives first
        let runDiag = Diagnostic(severity: .error, line: 7, message: "runtime err", source: .runtime)
        let (s1, _) = reduce(state, .runFinished(.error(runDiag, traceback: [])))
        #expect(isCompleted(s1, .error(runDiag, traceback: [])))
        #expect(s1.lintState == .running, "lintState must remain .running after runFinished")

        // lintFinished arrives after
        let lintDiag = Diagnostic(severity: .warning, line: 3, message: "lint warn", source: .luacheck)
        let (s2, _) = reduce(s1, .lintFinished([lintDiag]))
        #expect(s2.lintState == .idle)
        #expect(s2.bottomPane.diagnostics == [lintDiag])
        // Run outcome must be preserved
        #expect(isCompleted(s2, .error(runDiag, traceback: [])))
    }

    // MARK: Late runOutput after runFinished (defense-in-depth, ARCH §3c)

    @Test("late runOutput after runFinished is appended without changing runState")
    func lateRunOutputAfterFinished() {
        var state = AppState()
        state.runState = .completed(.done(value: nil, duration: .milliseconds(10)))
        state.bottomPane.outputBuffer = ["line1"]

        let (next, _) = reduce(state, .runOutput(["late line"]))

        #expect(
            isCompleted(next, .done(value: nil, duration: .milliseconds(10))),
            "runState must not change on late runOutput")
        #expect(
            next.bottomPane.outputBuffer == ["line1", "late line"],
            "Late runOutput must still be appended")
    }

    // MARK: Tick interleaved mid-run

    @Test("tick mid-run: spinner advances, runState unchanged")
    func tickInterleavedMidRun() {
        var (state, _) = loadedSourceState()
        let runId = UUID()
        state.runState = .running(id: runId, startedAt: Date())
        state.navigator.spinnerPhase = 0

        // Multiple ticks during run
        var current = state
        for expectedPhase in 1...7 {
            let (next, effects) = reduce(current, .tick)
            #expect(next.navigator.spinnerPhase == expectedPhase)
            #expect(
                hasEffect(effects) {
                    if case .startTick(TickInterval.run) = $0 { return true }
                    return false
                },
                "Tick during run must re-arm at run interval"
            )
            // runState must be preserved
            if case .running(let id, _) = next.runState {
                #expect(id == runId, "runId must be preserved through ticks")
            } else {
                Issue.record("Tick must not change runState")
            }
            current = next
        }
    }

    @Test("tick interleaved with runOutput: both effects applied correctly")
    func tickInterleavedWithRunOutput() {
        var (state, _) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())

        // runOutput arrives
        let (s1, _) = reduce(state, .runOutput(["output1"]))
        #expect(s1.bottomPane.outputBuffer == ["output1"])

        // tick arrives (spinner advance)
        let (s2, _) = reduce(s1, .tick)
        #expect(s2.navigator.spinnerPhase == 1)
        // Output must be preserved after tick
        #expect(s2.bottomPane.outputBuffer == ["output1"])

        // more runOutput
        let (s3, _) = reduce(s2, .runOutput(["output2"]))
        #expect(s3.bottomPane.outputBuffer == ["output1", "output2"])
    }

    // MARK: Highlight arriving while run is in progress

    @Test("highlightReady during run: spans stored, runState unchanged")
    func highlightReadyDuringRun() {
        var (state, id) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())

        let spans = [HighlightSpan(line: 0, column: 0, length: 5, tokenKind: .keyword)]
        let (next, _) = reduce(state, .highlightReady(id, spans: spans))

        #expect(next.highlight[id] == spans, "Highlight spans must be stored during run")
        #expect(isRunning(next), "highlightReady must not change runState")
    }

    // MARK: Source loading while lint is running

    @Test("sourceLoaded arriving while lint is running: both states preserved")
    func sourceLoadedWhileLintRunning() {
        var state = AppState()
        state.lintState = .running

        let id = SourceID(path: "new.lua")
        let fragment = makeFragment(code: "return 1", path: "/project/new.lua")

        let (next, _) = reduce(state, .sourceLoaded(id: id, fragment: fragment))

        #expect(next.lintState == .running, "sourceLoaded must not change lintState")
        #expect(next.sources[id] != nil)
        #expect(next.navigatorOrder.contains(id))
    }

    // MARK: Multiple source failures

    @Test("multiple sourceFailed events: all recorded without cross-contamination")
    func multipleSourceFailures() {
        let state = AppState()
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        let diags = [
            Diagnostic(severity: .error, message: "File not found: a.lua", source: .sourceLoad),
            Diagnostic(severity: .error, message: "File not found: b.lua", source: .sourceLoad),
        ]

        var current = state
        for (id, diag) in zip(ids, diags) {
            let (next, _) = reduce(current, .sourceFailed(id: id, state: .failed(diag)))
            current = next
        }

        // Both entries must be in navigator order
        for id in ids {
            #expect(current.navigatorOrder.contains(id))
        }

        // Messages must not be mixed
        if case .failed(let d) = current.sources[ids[0]] {
            #expect(d.message.contains("a.lua"))
        }
        if case .failed(let d) = current.sources[ids[1]] {
            #expect(d.message.contains("b.lua"))
        }
    }
}

// MARK: - 6. Modal flow tests

@Suite("ReducerSequence — Modal flows")
struct ModalFlowTests {

    // MARK: Help overlay open/close

    @Test("? opens help overlay; Esc closes it")
    func helpOverlayOpenClose() {
        var state = AppState()
        state.focus = .pane(.navigator)

        // ? opens help overlay
        let (s1, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(s1.focus == .helpOverlay, "? must open help overlay")

        // Esc closes it back to navigator
        let (s2, _) = reduce(s1, .key(.escape, modifiers: []))
        #expect(s2.focus == .pane(.navigator), "Esc must close help overlay and return to navigator")
    }

    @Test("? closes help overlay when already open")
    func questionMarkClosesHelpOverlay() {
        var state = AppState()
        state.focus = .helpOverlay

        let (next, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(next.focus == .pane(.navigator), "? inside help overlay must close it")
    }

    @Test("Keys other than Esc/? in help overlay have no focus effect")
    func helpOverlayAbsorbsKeys() {
        var state = AppState()
        state.focus = .helpOverlay

        for code: KeyCode in [.char("r"), .char("l"), .char("j"), .tab] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(next.focus == .helpOverlay, "Key \(code) inside help overlay must not change focus")
        }
    }

    @Test("Help overlay sequence: open → key spam → close")
    func helpOverlayKeySpamSequence() {
        var state = AppState()
        state.focus = .pane(.codePane)

        // Open
        let (s1, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(s1.focus == .helpOverlay)

        // Spam some keys — none should escape
        let (s2, _) = applyAll(
            s1,
            [
                .key(.char("r"), modifiers: []),
                .key(.char("l"), modifiers: []),
                .key(.tab, modifiers: []),
                .key(.char("j"), modifiers: []),
            ])
        #expect(s2.focus == .helpOverlay, "Spammed keys must not change focus inside help overlay")

        // Close with Esc
        let (s3, _) = reduce(s2, .key(.escape, modifiers: []))
        #expect(s3.focus == .pane(.navigator), "Esc must close help overlay")
    }

    // MARK: Picker modal (P1 stub — Esc closes; other keys are absorbed)

    @Test("Picker modal: Esc closes to navigator")
    func pickerModalEscCloses() {
        var state = AppState()
        state.focus = .pickerModal

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator), "Esc must close picker modal")
    }

    @Test("Picker modal: keys other than Esc are absorbed without changing focus")
    func pickerModalAbsorbsKeys() {
        var state = AppState()
        state.focus = .pickerModal

        for code: KeyCode in [.char("j"), .char("k"), .char("s"), .enter, .tab] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(
                next.focus == .pickerModal,
                "Key \(code) in picker modal must not change focus (P1 stub)"
            )
        }
    }

    // MARK: Init form modal (P1 stub — Esc closes; other keys are absorbed)

    // NOTE: initForm is a P1 stub. Only Esc is handled; all other keys are
    // absorbed. Full form behavior (field navigation, confirmation) belongs to
    // a future task (task 24). These tests verify the stub contract.

    @Test("Init form: Esc closes to navigator")
    func initFormEscCloses() {
        var state = AppState()
        state.focus = .initForm

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator), "Esc must close init form")
    }

    @Test("Init form: keys other than Esc are absorbed without changing focus")
    func initFormAbsorbsKeys() {
        var state = AppState()
        state.focus = .initForm

        for code: KeyCode in [.char("j"), .enter, .tab, .char("i")] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(
                next.focus == .initForm,
                "Key \(code) in init form must not change focus (P1 stub)"
            )
        }
    }

    // MARK: Modal state prevents global key dispatch

    @Test("Global keys (r, l, q) are absorbed by modal states, not dispatched")
    func modalAbsorbsGlobalKeys() {
        let modalFocuses: [FocusState] = [.helpOverlay, .pickerModal, .initForm]

        for focus in modalFocuses {
            var state = AppState()
            state.focus = focus
            // Seed a source so r/l would normally fire if not in modal
            let id = SourceID(path: "a.lua")
            let fragment = makeFragment(code: "print()", path: "/project/a.lua")
            state.sources[id] = .loaded(fragment)
            state.selection = id
            state.lintState = .idle

            // r must not start a run
            let (sr, er) = reduce(state, .key(.char("r"), modifiers: []))
            #expect(!isRunning(sr), "r in \(focus) must not start a run")
            #expect(!hasRunEffect(er), "r in \(focus) must not emit .run effect")

            // l must not start lint
            let (sl, el) = reduce(state, .key(.char("l"), modifiers: []))
            #expect(sl.lintState != .running, "l in \(focus) must not start lint")
            #expect(!hasLintEffect(el), "l in \(focus) must not emit .lint effect")
        }
    }
}

// MARK: - 7. Disabled-action transient tests

@Suite("ReducerSequence — Disabled actions produce transients")
struct DisabledActionTests {

    // MARK: r with no source loaded

    @Test("r with no selection: produces transient, no .run effect")
    func rNoSelection() {
        var state = AppState()
        state.selection = nil
        state.lintState = .idle
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        #expect(next.transient != nil, "r with no source must set transient")
        #expect(!hasRunEffect(effects), "r with no source must not emit .run effect")
        #expect(hasStartTick(effects), "Transient must arm tick for expiry")
    }

    @Test("r with source in .loading state: produces transient, no .run effect")
    func rSourceLoading() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        state.sources[id] = .loading
        state.navigatorOrder = [id]
        state.selection = id
        state.lintState = .idle
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        #expect(next.transient != nil, "r with loading source must set transient")
        #expect(!hasRunEffect(effects))
    }

    @Test("r with source in .failed state: produces transient, no .run effect")
    func rSourceFailed() {
        var state = AppState()
        let id = SourceID(path: "missing.lua")
        let diag = Diagnostic(severity: .error, message: "not found", source: .sourceLoad)
        state.sources[id] = .failed(diag)
        state.navigatorOrder = [id]
        state.selection = id
        state.lintState = .idle
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        #expect(next.transient != nil)
        #expect(!hasRunEffect(effects))
    }

    // MARK: r with unsupported Lua version

    @Test("r with unsupported Lua version: shows unsupported-version transient")
    func rUnsupportedVersion() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        let fragment = makeFragment(code: "print()", path: "/project/init.lua")
        state.sources[id] = .loaded(fragment)
        state.navigatorOrder = [id]
        state.selection = id
        state.lintState = .idle
        state.project = .unsupportedVersion("5.1")

        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))

        #expect(next.transient != nil)
        #expect(next.transient?.text.contains("unsupported Lua version") == true)
        #expect(!hasRunEffect(effects))
    }

    // MARK: l with no source loaded

    @Test("l with no selection: produces transient, no .lint effect")
    func lNoSelection() {
        var state = AppState()
        state.selection = nil
        state.lintState = .idle

        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.transient != nil, "l with no source must set transient")
        #expect(!hasLintEffect(effects))
        #expect(hasStartTick(effects))
    }

    // MARK: l while engine is initializing

    @Test("l while engine is .initializing: shows 'engine starting' transient")
    func lWhileInitializing() {
        var (state, _) = loadedSourceState()
        state.lintState = .initializing

        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.transient != nil)
        #expect(
            next.transient?.text.contains("starting") == true,
            "Transient must mention engine is starting")
        #expect(!hasLintEffect(effects))
    }

    @Test("l with unsupported Lua version: shows unsupported-version transient")
    func lUnsupportedVersion() {
        var state = AppState()
        let id = SourceID(path: "init.lua")
        let fragment = makeFragment(code: "print()", path: "/project/init.lua")
        state.sources[id] = .loaded(fragment)
        state.navigatorOrder = [id]
        state.selection = id
        state.lintState = .idle
        state.project = .unsupportedVersion("5.1")

        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))

        #expect(next.transient != nil)
        #expect(next.transient?.text.contains("unsupported Lua version") == true)
        #expect(!hasLintEffect(effects))
    }

    // MARK: Transient replaces prior transient

    @Test("New transient replaces the prior one immediately (never stacked)")
    func newTransientReplacesOld() {
        var state = AppState()
        state.transient = TransientMessage.makeFuture(text: "old message", secondsFromNow: 60)
        state.selection = nil
        state.lintState = .idle

        // r triggers a new transient
        let (next, _) = reduce(state, .key(.char("r"), modifiers: []))

        #expect(next.transient != nil)
        #expect(next.transient?.text != "old message", "New transient must replace prior one")
    }

    // MARK: C-p with no project

    @Test("C-p with no project loaded: produces transient, no .spawnEditor effect")
    func ctrlPNoProject() {
        var state = AppState()
        state.project = .none
        state.focus = .pane(.navigator)

        let (next, effects) = reduce(state, .key(.char("p"), modifiers: .ctrl))

        #expect(next.transient != nil)
        let hasEditor = hasEffect(effects) {
            if case .spawnEditor = $0 { return true }
            return false
        }
        #expect(!hasEditor, "C-p with no project must not spawn editor")
    }

    // MARK: Transient armed with tick — verified via effect list

    @Test("Every disabled-action transient arms the tick source")
    func disabledActionsArmTick() {
        // Table: state setup → event → expect transient + tick
        let nothingLoaded: AppState = {
            var s = AppState()
            s.selection = nil
            s.lintState = .idle
            return s
        }()

        let checks: [(AppState, AppEvent)] = [
            (nothingLoaded, .key(.char("r"), modifiers: [])),
            (nothingLoaded, .key(.char("l"), modifiers: [])),
        ]

        for (state, event) in checks {
            let (next, effects) = reduce(state, event)
            #expect(next.transient != nil, "Event \(event) must set transient")
            #expect(hasStartTick(effects), "Event \(event) must arm tick for transient expiry")
        }
    }
}

// MARK: - Additional cross-cutting sequence tests

@Suite("ReducerSequence — Cross-cutting sequences")
struct CrossCuttingSequenceTests {

    // MARK: projectLoaded and projectMalformed

    @Test("projectLoaded stores project state")
    func projectLoaded() {
        let state = AppState()
        let project = ProjectFile(luaVersion: "5.4")
        let diag = Diagnostic(severity: .warning, message: "unknown key", source: .projectConfig)

        let (next, effects) = reduce(state, .projectLoaded(project, diagnostics: [diag]))

        if case .loaded(let pf, let diags) = next.project {
            #expect(pf.luaVersion == "5.4")
            #expect(diags == [diag])
        } else {
            Issue.record("Expected .loaded project state")
        }
        #expect(effects.isEmpty, "projectLoaded must emit no effects")
    }

    @Test("projectMalformed stores malformed state")
    func projectMalformed() {
        let state = AppState()
        let diag = Diagnostic(severity: .error, message: "TOML parse error", source: .projectConfig)

        let (next, _) = reduce(state, .projectMalformed(diag))

        if case .malformed(let d) = next.project {
            #expect(d.message == "TOML parse error")
        } else {
            Issue.record("Expected .malformed project state")
        }
    }

    // MARK: catalogProbed

    @Test("catalogProbed sequence: false then true updates availability correctly")
    func catalogProbedSequence() {
        let state = AppState()

        let (s1, _) = reduce(state, .catalogProbed(tomlAvailable: false))
        #expect(s1.tomlModuleAvailable == false)

        let (s2, _) = reduce(s1, .catalogProbed(tomlAvailable: true))
        #expect(s2.tomlModuleAvailable == true)
    }

    // MARK: Complete startup sequence

    @Test("Full startup sequence: appStarted → sourceLoaded → lintEngineReady")
    func fullStartupSequence() {
        let state = AppState()

        // appStarted fires effects
        let (s1, e1) = reduce(state, .appStarted)
        #expect(hasLoadSources(e1))
        #expect(hasPrewarmLint(e1))

        // A source arrives
        let id = SourceID(path: "main.lua")
        let fragment = makeFragment(code: "return 1", path: "/project/main.lua")
        let (s2, _) = reduce(s1, .sourceLoaded(id: id, fragment: fragment))
        #expect(s2.navigatorOrder == [id])

        // Lint engine becomes ready
        var s2a = s2
        s2a.lintState = .initializing
        let (s3, _) = reduce(s2a, .lintEngineReady)
        #expect(s3.lintState == .idle)
    }

    // MARK: Navigator filter open/close

    @Test("/ opens navigator filter; Esc closes it")
    func navigatorFilterOpenClose() {
        var state = AppState()
        state.focus = .pane(.navigator)
        #expect(state.navigator.filterText == nil)

        // / opens filter (sets to empty string)
        let (s1, _) = reduce(state, .key(.char("/"), modifiers: []))
        #expect(s1.navigator.filterText == "", "/ must open filter with empty string")

        // / inside filter mode APPENDS (paths contain slashes); only Esc
        // closes the filter (ux-spec §2.2).
        let (s2, _) = reduce(s1, .key(.char("/"), modifiers: []))
        #expect(s2.navigator.filterText == "/", "/ in filter mode must append, not close")

        // Esc closes the filter.
        let (s3, _) = reduce(s2, .key(.escape, modifiers: []))
        #expect(s3.navigator.filterText == nil, "Esc must close navigator filter")
    }

    // MARK: Navigator Enter selects source

    @Test("Navigator Enter selects the highlighted source and resets code pane")
    func navigatorEnterSelectsSource() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let id = SourceID(path: "a.lua")
        let fragment = makeFragment(code: "print()", path: "/project/a.lua")
        state.sources[id] = .loaded(fragment)
        state.navigatorOrder = [id]
        state.navigator.selectedIndex = 0
        // Pre-set some code pane state to verify it resets
        state.codePane.scrollOffset = 42
        state.codePane.cursorLine = 10

        let (next, effects) = reduce(state, .key(.enter, modifiers: []))

        #expect(next.selection == id)
        #expect(next.codePane.scrollOffset == 0, "Selecting a source must reset scroll offset")
        #expect(next.codePane.cursorLine == 0, "Selecting a source must reset cursor line")
        // Must request a syntax pre-pass
        let hasSyntaxPrePass = hasEffect(effects) {
            if case .syntaxPrePass = $0 { return true }
            return false
        }
        #expect(hasSyntaxPrePass, "Navigator Enter must emit .syntaxPrePass for the selected source")
    }

    // MARK: C-r reloads project

    @Test("C-r emits .reloadProject effect")
    func ctrlRReloadsProject() {
        let state = AppState()
        let (_, effects) = reduce(state, .key(.char("r"), modifiers: .ctrl))
        let hasReload = hasEffect(effects) {
            if case .reloadProject = $0 { return true }
            return false
        }
        #expect(hasReload, "C-r must emit .reloadProject effect")
    }

    // MARK: q quit sequence

    @Test("q emits cancelRun and quit(0) effects")
    func qQuit() {
        var state = AppState()
        state.focus = .pane(.navigator)

        let (_, effects) = reduce(state, .key(.char("q"), modifiers: []))

        #expect(hasCancelRun(effects), "q must emit .cancelRun")
        let hasQuit = hasEffect(effects) {
            if case .quit(0) = $0 { return true }
            return false
        }
        #expect(hasQuit, "q must emit .quit(exitCode: 0)")
    }

    // MARK: Bottom pane C-l — clear output buffer (pane table overrides global)

    // History (#1): the global C-l handler used to intercept this key before
    // per-pane dispatch, making the bottom pane's clear handler unreachable.
    // Fixed by having the global case decline the key when the bottom pane is
    // focused (ux-spec §2.3 bottom-pane table, §6.4).

    @Test("C-l while bottomPane focused clears the output buffer, focus stays")
    func ctrlLFromBottomPaneClearsBuffer() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.outputBuffer = Array(repeating: "line", count: 5)
        state.bottomPane.scrollOffset = 3

        let (next, _) = reduce(state, .key(.char("l"), modifiers: .ctrl))

        // C-l inserts the ux-spec §6.4 "[cleared]" notice as the sole buffer line
        // rather than emptying the buffer, so the user sees the clear confirmation.
        #expect(
            next.bottomPane.outputBuffer == ["[cleared]"],
            "C-l in bottom pane must clear to '[cleared]' notice (ux-spec §6.4)")
        #expect(next.bottomPane.scrollOffset == 0, "Clear resets scroll offset")
        #expect(next.focus == .pane(.bottomPane), "Focus stays on the bottom pane")
    }

    @Test("C-l from navigator and codePane still jumps focus to codePane")
    func ctrlLFromOtherPanesJumpsToCodePane() {
        for pane in [PaneID.navigator, PaneID.codePane] {
            var state = AppState()
            state.focus = .pane(pane)

            let (next, _) = reduce(state, .key(.char("l"), modifiers: .ctrl))

            #expect(next.focus == .pane(.codePane), "Global C-l must jump to codePane from \(pane)")
        }
    }

    // MARK: Bottom pane j/k scroll

    @Test("Bottom pane j/k scroll, never negative")
    func bottomPaneScroll() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.scrollOffset = 0

        // j scrolls down
        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.bottomPane.scrollOffset == 1)

        // k at 1 scrolls up
        let (s2, _) = reduce(s1, .key(.char("k"), modifiers: []))
        #expect(s2.bottomPane.scrollOffset == 0)

        // k at 0 clamps
        let (s3, _) = reduce(s2, .key(.char("k"), modifiers: []))
        #expect(s3.bottomPane.scrollOffset == 0)
    }

    // MARK: Transient expiry via tick

    @Test("Tick clears an expired transient and stops tick when no other consumers")
    func tickClearsExpiredTransient() {
        var state = AppState()
        state.transient = TransientMessage.makeExpired(text: "expired msg")

        let (next, effects) = reduce(state, .tick)

        #expect(next.transient == nil, "Tick must clear expired transient")
        #expect(hasStopTick(effects), "After transient clears with no run, tick must stop")
    }

    @Test("Tick clears expired transient but keeps tick armed when run is active")
    func tickClearsTransientKeepsTickForRun() {
        var (state, _) = loadedSourceState()
        state.runState = .running(id: UUID(), startedAt: Date())
        state.transient = TransientMessage.makeExpired(text: "short transient")

        let (next, effects) = reduce(state, .tick)

        #expect(next.transient == nil, "Expired transient must be cleared")
        // Tick must be re-armed for the active run
        #expect(
            hasEffect(effects) {
                if case .startTick(TickInterval.run) = $0 { return true }
                return false
            },
            "Tick must be re-armed at run interval since run is still active"
        )
        #expect(!hasStopTick(effects), "Tick must not stop while run is active")
    }
}
