// File: Tests/MoonSwiftTUITests/DebugReducerTests.swift
// Location: MoonSwiftTUITests/
// Role: TDD tests for P2 F6.1 — breakpoint toggle, debug-run preconditions,
//       debug event handling, gutter mark merging, key remapping (b / <C-b>).
//       All tests drive reduce() or the pure helpers directly; no FFI required.
// Upstream: DebugReducer.swift, Reducer.swift, AppState.swift, Effect.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build a minimal loaded source state focused on the code pane.
private func stateWithCode(_ code: String = "line1\nline2\nline3") -> (AppState, SourceID) {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    let url = URL(fileURLWithPath: "/project/test.lua")
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
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.focus = .pane(.codePane)
    state.codePane.cursorLine = 0
    return (state, id)
}

/// Build a minimal DebugSnapshot for test use.
private func makeSnapshot(
    sessionID: DebugSessionID = DebugSessionID(),
    fragmentLine: Int = 2
) -> DebugSnapshot {
    DebugSnapshot(
        sessionID: sessionID,
        event: .breakpoint,
        fragmentLine: fragmentLine,
        callStack: [DebugFrame(level: 0, name: "main", source: "test.lua", line: fragmentLine)],
        frameVars: [:],
        globals: nil
    )
}

// MARK: - Breakpoint toggle

@Suite("DebugReducer — Breakpoint toggle")
struct BreakpointToggleTests {

    @Test("b key sets breakpoint on cursor line (1-based) when code pane focused")
    func bKeySetsBP() {
        var (state, id) = stateWithCode()
        state.codePane.cursorLine = 1  // 0-based = line 2 in 1-based
        let (next, effects) = reduce(state, .key(.char("b"), modifiers: []))
        #expect(next.breakpoints[id] == [2], "breakpoint should be stored 1-based")
        #expect(effects.isEmpty, "toggle has no side effects")
    }

    @Test("b key removes an existing breakpoint (toggle off)")
    func bKeyRemovesBP() {
        var (state, id) = stateWithCode()
        state.codePane.cursorLine = 0
        state.breakpoints[id] = [1]
        let (next, _) = reduce(state, .key(.char("b"), modifiers: []))
        #expect(next.breakpoints[id] == nil, "cleared breakpoint should remove key")
    }

    @Test("b key in navigator pane does not set a breakpoint (pane-scoped)")
    func bKeyNoOpNavigator() {
        var (state, _) = stateWithCode()
        state.focus = .pane(.navigator)
        let (next, _) = reduce(state, .key(.char("b"), modifiers: []))
        // b is pane-scoped: only wired in the code pane. In navigator it is a
        // silent no-op (navigator has no b binding). No breakpoint, no transient.
        #expect(next.breakpoints.isEmpty)
        #expect(next.transient == nil, "no disabled-action transient from navigator")
    }

    @Test("b key is no-op when no source loaded")
    func bKeyNoOpNoSource() {
        var state = AppState()
        state.focus = .pane(.codePane)
        let (next, _) = reduce(state, .key(.char("b"), modifiers: []))
        #expect(next.breakpoints.isEmpty)
        #expect(next.transient != nil)
    }

    @Test("gutter marks rebuilt immediately after toggle")
    func gutterMarksRebuilt() {
        var (state, id) = stateWithCode()
        state.codePane.cursorLine = 0
        let (next, _) = reduce(state, .key(.char("b"), modifiers: []))
        // Line 1 (0-based key 0) should now carry .breakpoint.
        #expect(next.codePane.gutterMarks[0] == .breakpoint)
        _ = id  // used in breakpoints check above
    }

    @Test("C-b performs scroll-up-full-page (UX-01 migration)")
    func ctrlBScrollsUp() {
        var (state, _) = stateWithCode(
            "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nl16\nl17\nl18\nl19\nl20\nl21\nl22\nl23\nl24"
        )
        state.codePane.scrollOffset = 20
        state.codePane.cursorLine = 20
        let (next, _) = reduce(state, .key(.char("b"), modifiers: .ctrl))
        #expect(next.codePane.scrollOffset < 20, "C-b should scroll up")
    }
}

// MARK: - Debug run preconditions

@Suite("DebugReducer — Debug run preconditions")
struct DebugRunPreconditionTests {

    @Test("C-g with no source emits 'No source to debug.' transient")
    func noSourceTransient() {
        var state = AppState()
        state.focus = .pane(.codePane)
        let (next, _) = reduce(state, .key(.char("g"), modifiers: .ctrl))
        #expect(next.transient?.text == "No source to debug.")
    }

    @Test("C-g with run in progress emits 'A run is already in progress.' transient")
    func runInProgressTransient() {
        var (state, _) = stateWithCode()
        state.runState = .running(id: UUID(), startedAt: Date())
        let (next, _) = reduce(state, .key(.char("g"), modifiers: .ctrl))
        #expect(next.transient?.text == "A run is already in progress.")
    }

    @Test("C-g with active debug session sets restart confirmation transient")
    func restartConfirmationTransient() {
        var (state, _) = stateWithCode()
        state.activeDebugSessionID = DebugSessionID()
        let (next, _) = reduce(state, .key(.char("g"), modifiers: .ctrl))
        #expect(next.transient?.text == "Restart debug session? [y/N]")
        #expect(next.debugRestartPending == true)
    }

    @Test("C-g with unsupported Lua version emits unavailable transient")
    func unsupportedVersionTransient() {
        var (state, _) = stateWithCode()
        state.project = .unsupportedVersion("5.1")
        let (next, _) = reduce(state, .key(.char("g"), modifiers: .ctrl))
        #expect(next.transient?.text == "Debugging unavailable for this Lua version.")
    }

    @Test("C-g with ready state emits debugRun effect")
    func readyStateEmitsDebugRun() {
        let (state, _) = stateWithCode()
        let (next, effects) = reduce(state, .key(.char("g"), modifiers: .ctrl))
        let hasDebugRun = effects.contains {
            if case .debugRun = $0 { return true }
            return false
        }
        #expect(hasDebugRun, "C-g in ready state must emit .debugRun")
        #expect(next.bottomPane.activeTab == .debug, "debug tab shown on launch")
    }
}

// MARK: - Restart confirmation

@Suite("DebugReducer — Restart confirmation")
struct DebugRestartConfirmTests {

    @Test("y key during restart-pending tears down old session and relaunches")
    func yKeyRestartsSession() {
        var (state, _) = stateWithCode()
        let oldID = DebugSessionID()
        state.activeDebugSessionID = oldID
        state.debugRestartPending = true

        let (next, effects) = reduce(state, .key(.char("y"), modifiers: []))
        let hasStop = effects.contains {
            if case .stopDebug(let id) = $0 { return id == oldID }
            return false
        }
        let hasDebugRun = effects.contains {
            if case .debugRun = $0 { return true }
            return false
        }
        #expect(hasStop, "y should emit .stopDebug for old session")
        #expect(hasDebugRun, "y should emit .debugRun for new session")
        #expect(next.debugRestartPending == false)
    }

    @Test("n key during restart-pending cancels without relaunching")
    func nKeyCancels() {
        var (state, _) = stateWithCode()
        state.activeDebugSessionID = DebugSessionID()
        state.debugRestartPending = true

        let (next, effects) = reduce(state, .key(.char("n"), modifiers: []))
        let hasDebugRun = effects.contains {
            if case .debugRun = $0 { return true }
            return false
        }
        #expect(!hasDebugRun, "n should not launch a new debug run")
        #expect(next.debugRestartPending == false)
        #expect(next.transient == nil)
    }

    @Test("any non-y key during restart-pending cancels")
    func escapeKeyCancels() {
        var (state, _) = stateWithCode()
        state.activeDebugSessionID = DebugSessionID()
        state.debugRestartPending = true

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.debugRestartPending == false)
    }
}

// MARK: - Debug event handlers

@Suite("DebugReducer — Debug events")
struct DebugEventTests {

    @Test("debugPaused stores snapshot, switches to debug tab, rebuilds gutter marks")
    func debugPausedStoresSnapshot() {
        var (state, id) = stateWithCode()
        state.activeDebugSessionID = DebugSessionID()
        state.breakpoints[id] = [2]  // breakpoint at line 2 (1-based)
        let snapshot = makeSnapshot(fragmentLine: 2)
        let (next, _) = reduce(state, .debugPaused(snapshot))

        #expect(next.currentDebugSnapshot?.fragmentLine == 2)
        #expect(next.bottomPane.activeTab == .debug)
        // Line 2 (0-based key 1) has a breakpoint and is paused → .pausedBreakpoint.
        #expect(next.codePane.gutterMarks[1] == .pausedBreakpoint)
    }

    @Test("debugPaused without breakpoint marks pause line as .debugPaused")
    func debugPausedNoBP() {
        var (state, _) = stateWithCode()
        state.activeDebugSessionID = DebugSessionID()
        let snapshot = makeSnapshot(fragmentLine: 1)
        let (next, _) = reduce(state, .debugPaused(snapshot))

        // Line 1 (0-based key 0): no breakpoint → .debugPaused.
        #expect(next.codePane.gutterMarks[0] == .debugPaused)
    }

    @Test("debugFinished clears session state and rebuilds gutter without paused mark")
    func debugFinishedClearsState() {
        var (state, id) = stateWithCode()
        let sid = DebugSessionID()
        state.activeDebugSessionID = sid
        state.currentDebugSnapshot = makeSnapshot(sessionID: sid, fragmentLine: 1)
        state.breakpoints[id] = [1]

        let (next, _) = reduce(state, .debugFinished(sid, .done(value: nil, duration: .zero)))
        #expect(next.activeDebugSessionID == nil)
        #expect(next.currentDebugSnapshot == nil)
        // Line 1 (0-based key 0): has breakpoint but not paused → .breakpoint.
        #expect(next.codePane.gutterMarks[0] == .breakpoint)
    }

    @Test("debugFinished with stale sessionID is a no-op")
    func debugFinishedStaleID() {
        var (state, _) = stateWithCode()
        let liveID = DebugSessionID()
        let staleID = DebugSessionID()
        state.activeDebugSessionID = liveID
        state.currentDebugSnapshot = makeSnapshot(sessionID: liveID)

        let (next, _) = reduce(state, .debugFinished(staleID, .done(value: nil, duration: .zero)))
        // Live session untouched.
        #expect(next.activeDebugSessionID == liveID)
        #expect(next.currentDebugSnapshot != nil)
    }
}

// MARK: - Gutter mark merging

@Suite("DebugReducer — Gutter mark priority")
struct GutterMarkPriorityTests {

    @Test("pausedBreakpoint outranks breakpoint on same line")
    func pausedBPOutranksBP() {
        let diag: [Int: GutterMark] = [:]
        let marks = debugGutterMarks(diagnosticMarks: diag, breakpoints: [2], pausedLine: 2)
        #expect(marks[1] == .pausedBreakpoint)
    }

    @Test("debugPaused outranks error on same line")
    func debugPausedOutranksError() {
        let diag: [Int: GutterMark] = [0: .error]
        let marks = debugGutterMarks(diagnosticMarks: diag, breakpoints: [], pausedLine: 1)
        #expect(marks[0] == .debugPaused)
    }

    @Test("breakpoint outranks warning on same line")
    func breakpointOutranksWarning() {
        let diag: [Int: GutterMark] = [0: .warning]
        let marks = debugGutterMarks(diagnosticMarks: diag, breakpoints: [1], pausedLine: nil)
        #expect(marks[0] == .breakpoint)
    }

    @Test("error preserved when no breakpoint or pause on that line")
    func errorPreserved() {
        let diag: [Int: GutterMark] = [0: .error]
        let marks = debugGutterMarks(diagnosticMarks: diag, breakpoints: [], pausedLine: nil)
        #expect(marks[0] == .error)
    }

    @Test("nil pausedLine leaves breakpoint mark intact")
    func nilPausedLine() {
        let diag: [Int: GutterMark] = [:]
        let marks = debugGutterMarks(diagnosticMarks: diag, breakpoints: [3], pausedLine: nil)
        #expect(marks[2] == .breakpoint)
    }
}

// MARK: - Tab 3 key

@Suite("DebugReducer — Tab 3 key")
struct Tab3KeyTests {

    @Test("key 3 in bottom pane switches to debug tab")
    func key3SwitchesDebugTab() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        let (next, _) = reduce(state, .key(.char("3"), modifiers: []))
        #expect(next.bottomPane.activeTab == .debug)
        #expect(next.bottomPane.scrollOffset == 0)
    }
}
