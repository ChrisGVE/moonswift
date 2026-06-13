// File: Tests/MoonSwiftTUITests/DebugSteppingTests.swift
// Location: MoonSwiftTUITests/
// Role: TDD tests for P2 F6.2 — stepping/continue/pause/stop reducer logic.
//       Covers: paused-mode key dispatch (s/i/o/c/x), VM-running disabled
//       transients, navigator step-key transient, x-stop neutral message
//       mapping (DOM-N01), focus-move-to-debug-tab on breakpoint hit, and
//       the debugResumed event clearing the debug-running flag.
//
//       All tests drive reduce() directly; no FFI, no async, no live engine.
//       The sendDebugCommand effect is tested by asserting the Effect case;
//       the actual delivery to the engine is tested in AppDriver tests.
//
// Upstream: DebugReducer.swift, Reducer.swift, AppEvent.swift, Effect.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Shared helpers (F6.2-scoped)

/// Build a minimal loaded state with an active, paused debug session.
///
/// `fragmentLine` is 1-based (matching `DebugSnapshot.fragmentLine`).
private func pausedDebugState(
    code: String = "line1\nline2\nline3",
    fragmentLine: Int = 2,
    focusedPane: PaneID = .codePane
) -> (AppState, SourceID, DebugSessionID) {
    let id = SourceID(path: "test.lua")
    let sid = DebugSessionID()
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
    state.focus = .pane(focusedPane)

    // Set up an active paused debug session with a snapshot.
    state.activeDebugSessionID = sid
    state.currentDebugSnapshot = DebugSnapshot(
        sessionID: sid,
        event: .breakpoint,
        fragmentLine: fragmentLine,
        callStack: [DebugFrame(level: 0, name: "main", source: "test.lua", line: fragmentLine)],
        frameVars: [:],
        globals: nil
    )
    state.bottomPane.activeTab = .debug
    return (state, id, sid)
}

/// Build a state with an active debug session that is NOT paused (VM running).
/// `currentDebugSnapshot` is nil — session started but not yet paused.
private func vmRunningDebugState(
    focusedPane: PaneID = .codePane
) -> (AppState, SourceID, DebugSessionID) {
    let id = SourceID(path: "test.lua")
    let sid = DebugSessionID()
    var state = AppState()
    let url = URL(fileURLWithPath: "/project/test.lua")
    let code = "line1\nline2\nline3"
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
    state.focus = .pane(focusedPane)

    // Session active but no snapshot → VM running, not paused.
    state.activeDebugSessionID = sid
    state.currentDebugSnapshot = nil
    state.bottomPane.activeTab = .debug
    return (state, id, sid)
}

/// Extract the `sendDebugCommand` effect from a list, if present.
private func findSendCommand(_ effects: [Effect]) -> (DebugSessionID, LuaDebugCommand)? {
    for e in effects {
        if case .sendDebugCommand(let sid, let cmd) = e { return (sid, cmd) }
    }
    return nil
}

// MARK: - Paused-mode key dispatch (code pane or Debug tab focused)

@Suite("F6.2 — Paused-mode key dispatch")
struct PausedModeKeyTests {

    // MARK: Step over

    @Test("s key while paused in code pane emits sendDebugCommand(.stepOver)")
    func sKeyStepOverCodePane() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (_, effects) = reduce(state, .key(.char("s"), modifiers: []))
        let cmd = findSendCommand(effects)
        #expect(cmd != nil, "s must emit sendDebugCommand")
        #expect(cmd?.0 == sid, "command must target the active session")
        #expect(cmd?.1 == .stepOver, "s = step over")
    }

    @Test("s key while paused in bottom pane (Debug tab) emits sendDebugCommand(.stepOver)")
    func sKeyStepOverDebugTab() {
        var (state, _, sid) = pausedDebugState(focusedPane: .bottomPane)
        state.bottomPane.activeTab = .debug
        let (_, effects) = reduce(state, .key(.char("s"), modifiers: []))
        let cmd = findSendCommand(effects)
        #expect(cmd != nil, "s in Debug tab must emit sendDebugCommand")
        #expect(cmd?.0 == sid)
        #expect(cmd?.1 == .stepOver)
    }

    // MARK: Step into

    @Test("i key while paused emits sendDebugCommand(.stepInto)")
    func iKeyStepInto() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (_, effects) = reduce(state, .key(.char("i"), modifiers: []))
        let cmd = findSendCommand(effects)
        #expect(cmd?.1 == .stepInto, "i = step into")
        #expect(cmd?.0 == sid)
    }

    // MARK: Step out

    @Test("o key while paused emits sendDebugCommand(.stepOut)")
    func oKeyStepOut() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (_, effects) = reduce(state, .key(.char("o"), modifiers: []))
        let cmd = findSendCommand(effects)
        #expect(cmd?.1 == .stepOut, "o = step out")
        #expect(cmd?.0 == sid)
    }

    // MARK: Continue

    @Test("c key while paused emits sendDebugCommand(.continueRun)")
    func cKeyContinue() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (_, effects) = reduce(state, .key(.char("c"), modifiers: []))
        let cmd = findSendCommand(effects)
        #expect(cmd?.1 == .continueRun, "c = continue")
        #expect(cmd?.0 == sid)
    }

    // MARK: Stop

    @Test("x key while paused emits sendDebugCommand(.stop) and NEUTRAL 'Session stopped.' message")
    func xKeyStopNeutralMessage() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (next, effects) = reduce(state, .key(.char("x"), modifiers: []))

        // Must emit the stop command.
        let cmd = findSendCommand(effects)
        #expect(cmd?.1 == .stop, "x = stop")
        #expect(cmd?.0 == sid)

        // DOM-N01: the stop message must be NEUTRAL, not a cancelled-error diagnostic.
        #expect(next.transient?.text == "Session stopped.", "x stop must show neutral message")
    }

    @Test("x key while paused does NOT add a .cancelled diagnostic to the bottom pane")
    func xKeyNoCancelledDiagnostic() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("x"), modifiers: []))
        // Bottom pane diagnostics must not contain an error for cancellation.
        let hasCancelDiag = next.bottomPane.diagnostics.contains {
            $0.message.lowercased().contains("cancel")
        }
        #expect(!hasCancelDiag, "x stop must not inject a cancelled diagnostic")
    }

    @Test("step keys clear the current paused snapshot (VM is resuming)")
    func stepKeyClearsSnapshot() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("s"), modifiers: []))
        // After a step command the snapshot should be cleared (VM running between
        // pauses — Case 2 / §6.9). The next debugPaused will set a new snapshot.
        #expect(next.currentDebugSnapshot == nil, "snapshot cleared on step/continue/stop")
    }

    @Test("continue key clears the current paused snapshot")
    func continueKeyClearsSnapshot() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("c"), modifiers: []))
        #expect(next.currentDebugSnapshot == nil)
    }

    @Test("x stop key clears the active session ID")
    func xKeyStopClearsSession() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("x"), modifiers: []))
        // x stop: session is torn down, ID is cleared from state.
        #expect(next.activeDebugSessionID == nil, "session cleared on stop")
    }
}

// MARK: - VM-running disabled transients

@Suite("F6.2 — VM-running disabled transients")
struct VMRunningDisabledTransientTests {

    @Test("s key when VM running (not paused) shows 'VM running…' transient")
    func sKeyVMRunning() {
        let (state, _, _) = vmRunningDebugState(focusedPane: .codePane)
        let (next, effects) = reduce(state, .key(.char("s"), modifiers: []))
        #expect(next.transient?.text == "VM running…", "VM running transient exact string")
        let hasSend = findSendCommand(effects) != nil
        #expect(!hasSend, "no command delivered when VM running")
    }

    @Test("i key when VM running shows 'VM running…' transient")
    func iKeyVMRunning() {
        let (state, _, _) = vmRunningDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("i"), modifiers: []))
        #expect(next.transient?.text == "VM running…")
    }

    @Test("o key when VM running shows 'VM running…' transient")
    func oKeyVMRunning() {
        let (state, _, _) = vmRunningDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("o"), modifiers: []))
        #expect(next.transient?.text == "VM running…")
    }

    @Test("c key when VM running shows 'VM running…' transient")
    func cKeyVMRunning() {
        let (state, _, _) = vmRunningDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .key(.char("c"), modifiers: []))
        #expect(next.transient?.text == "VM running…")
    }

    @Test("x key when VM running (not paused) still stops the session")
    func xKeyVMRunningStopsSession() {
        let (state, _, sid) = vmRunningDebugState(focusedPane: .codePane)
        let (next, effects) = reduce(state, .key(.char("x"), modifiers: []))
        // x stop is ALWAYS live — even when VM is running (PRD F6.2: x overrides global cancel).
        let cmd = findSendCommand(effects)
        #expect(cmd?.0 == sid, "x stop always targets the live session")
        #expect(cmd?.1 == .stop, "x always issues .stop")
        #expect(next.transient?.text == "Session stopped.")
    }
}

// MARK: - x overrides global cancel while debug session active

@Suite("F6.2 — x key global cancel override")
struct XKeyGlobalCancelOverrideTests {

    @Test("x key with no debug session is the global cancel-run (no sendDebugCommand)")
    func xKeyNoSessionIsCancelRun() {
        var state = AppState()
        state.focus = .pane(.codePane)
        state.runState = .running(id: UUID(), startedAt: Date())
        let (_, effects) = reduce(state, .key(.char("x"), modifiers: []))
        let hasSend = findSendCommand(effects) != nil
        let hasCancelRun = effects.contains {
            if case .cancelRun = $0 { return true }
            return false
        }
        #expect(!hasSend, "no session → sendDebugCommand must not appear")
        #expect(hasCancelRun, "no session → must emit .cancelRun (global cancel)")
    }

    @Test("x key with active debug session sends .stop, NOT .cancelRun (override confirmed)")
    func xKeyWithSessionOverridesGlobalCancel() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let (_, effects) = reduce(state, .key(.char("x"), modifiers: []))
        let hasSend = findSendCommand(effects) != nil
        let hasCancelRun = effects.contains {
            if case .cancelRun = $0 { return true }
            return false
        }
        #expect(hasSend, "active session → sendDebugCommand(.stop) must appear")
        #expect(!hasCancelRun, "active session → .cancelRun must NOT appear (override)")
    }
}

// MARK: - Focus: breakpoint hit moves to Debug tab

@Suite("F6.2 — Breakpoint hit moves focus to Debug tab")
struct BreakpointFocusTests {

    @Test("debugPaused moves bottom pane to debug tab (auto-focus per §6.1)")
    func debugPausedMovesDebugTab() {
        let id = SourceID(path: "test.lua")
        let sid = DebugSessionID()
        var state = AppState()
        let url = URL(fileURLWithPath: "/project/test.lua")
        let code = "line1\nline2"
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
        state.selection = id
        state.activeDebugSessionID = sid
        state.bottomPane.activeTab = .output  // was on output tab

        let snapshot = DebugSnapshot(
            sessionID: sid, event: .breakpoint, fragmentLine: 1,
            callStack: [], frameVars: [:], globals: nil
        )
        let (next, _) = reduce(state, .debugPaused(snapshot))
        #expect(next.bottomPane.activeTab == .debug, "breakpoint hit auto-switches to Debug tab")
    }
}

// MARK: - Navigator transient for step keys while paused

@Suite("F6.2 — Navigator transient for step keys while paused")
struct NavigatorStepKeyTransientTests {

    @Test("s key from navigator while paused shows 'Stepping is in the Debug tab — press 3.' transient")
    func sKeyNavigatorTransient() {
        let (state, _, _) = pausedDebugState(focusedPane: .navigator)
        let (next, effects) = reduce(state, .key(.char("s"), modifiers: []))
        #expect(
            next.transient?.text == "Stepping is in the Debug tab — press 3.",
            "exact transient string from PRD §2564"
        )
        let hasSend = findSendCommand(effects) != nil
        #expect(!hasSend, "no step command from navigator transient path")
    }

    @Test("i key from navigator while paused shows navigator transient")
    func iKeyNavigatorTransient() {
        let (state, _, _) = pausedDebugState(focusedPane: .navigator)
        let (next, _) = reduce(state, .key(.char("i"), modifiers: []))
        #expect(next.transient?.text == "Stepping is in the Debug tab — press 3.")
    }

    @Test("o key from navigator while paused shows navigator transient")
    func oKeyNavigatorTransient() {
        let (state, _, _) = pausedDebugState(focusedPane: .navigator)
        let (next, _) = reduce(state, .key(.char("o"), modifiers: []))
        #expect(next.transient?.text == "Stepping is in the Debug tab — press 3.")
    }

    @Test("c key from navigator while paused shows navigator transient")
    func cKeyNavigatorTransient() {
        let (state, _, _) = pausedDebugState(focusedPane: .navigator)
        let (next, _) = reduce(state, .key(.char("c"), modifiers: []))
        #expect(next.transient?.text == "Stepping is in the Debug tab — press 3.")
    }

    @Test("s key from navigator with NO debug session is a plain no-op (not a transient)")
    func sKeyNavigatorNoSession() {
        var state = AppState()
        state.focus = .pane(.navigator)
        // No active debug session.
        let (next, _) = reduce(state, .key(.char("s"), modifiers: []))
        // No transient: s is not a recognised navigator key when no debug session is active.
        // (The navigator s was never bound; the step transient only fires when paused.)
        #expect(next.transient == nil)
    }
}

// MARK: - debugResumed event

@Suite("F6.2 — debugResumed event")
struct DebugResumedEventTests {

    @Test("debugResumed clears currentDebugSnapshot (Case 2 — VM running after pause)")
    func debugResumedClearsSnapshot() {
        let (state, _, sid) = pausedDebugState(focusedPane: .codePane)
        let (next, _) = reduce(state, .debugResumed(sid))
        #expect(next.currentDebugSnapshot == nil, "snapshot cleared on debugResumed")
        // Session ID is retained (session is still live — just unpaused).
        #expect(next.activeDebugSessionID == sid, "session ID retained when VM resumes")
    }

    @Test("debugResumed with stale sessionID is a no-op")
    func debugResumedStaleID() {
        let (state, _, _) = pausedDebugState(focusedPane: .codePane)
        let stale = DebugSessionID()  // different from the live session
        let (next, _) = reduce(state, .debugResumed(stale))
        // Live snapshot must be untouched.
        #expect(next.currentDebugSnapshot != nil, "stale debugResumed must not clear live snapshot")
    }
}

// MARK: - Reducer sequence: breakpoint → step over → step into → step out → continue

@Suite("F6.2 — Reducer sequence: full stepping cycle")
struct SteppingSequenceTests {

    @Test("Full cycle: set breakpoint → debugPaused → step over → step into → step out → continue")
    func fullSteppingCycle() {
        // 1. Start in a loaded, focused-code-pane state.
        let id = SourceID(path: "test.lua")
        var state = AppState()
        let url = URL(fileURLWithPath: "/project/test.lua")
        let code = "line1\nline2\nline3\nline4"
        let data = Data(code.utf8)
        let hash = SHA256.hash(data: data)
        let prov = FragmentProvenance(
            file: url, jsonpath: nil, document: 0, byteRange: 0..<data.count,
            lineOffset: 0, contentHash: hash
        )
        let fragment = LuaSourceFragment(code: code, provenance: prov)
        state.sources[id] = .loaded(fragment)
        state.navigatorOrder = [id]
        state.selection = id
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        state.focus = .pane(.codePane)
        state.codePane.cursorLine = 0

        // 2. Set a breakpoint at line 1 via b key.
        (state, _) = reduce(state, .key(.char("b"), modifiers: []))
        #expect(state.breakpoints[id] == [1], "breakpoint stored 1-based")

        // 3. Simulate: debug run started, VM hits breakpoint → debugPaused.
        let sid = DebugSessionID()
        state.activeDebugSessionID = sid
        let snap1 = DebugSnapshot(
            sessionID: sid, event: .breakpoint, fragmentLine: 1,
            callStack: [DebugFrame(level: 0, name: "f", source: "test.lua", line: 1)],
            frameVars: [:], globals: nil
        )
        (state, _) = reduce(state, .debugPaused(snap1))
        #expect(state.currentDebugSnapshot?.fragmentLine == 1, "paused at line 1")
        #expect(state.bottomPane.activeTab == .debug, "Debug tab auto-shown")

        // 4. Step over (s key).
        var effects: [Effect]
        (state, effects) = reduce(state, .key(.char("s"), modifiers: []))
        #expect(findSendCommand(effects)?.1 == .stepOver, "s → stepOver")
        #expect(state.currentDebugSnapshot == nil, "snapshot cleared after step")

        // 5. Simulate: VM resumed, then paused again at line 2 → debugPaused.
        let snap2 = DebugSnapshot(
            sessionID: sid, event: .line, fragmentLine: 2,
            callStack: [
                DebugFrame(level: 0, name: "f", source: "test.lua", line: 2),
                DebugFrame(level: 1, name: "g", source: "test.lua", line: 5),
            ],
            frameVars: [:], globals: nil
        )
        (state, _) = reduce(state, .debugPaused(snap2))
        #expect(state.currentDebugSnapshot?.fragmentLine == 2)

        // 6. Step into (i key).
        (state, effects) = reduce(state, .key(.char("i"), modifiers: []))
        #expect(findSendCommand(effects)?.1 == .stepInto, "i → stepInto")
        #expect(state.currentDebugSnapshot == nil)

        // 7. Simulate pause at line 3.
        let snap3 = DebugSnapshot(
            sessionID: sid, event: .line, fragmentLine: 3,
            callStack: [DebugFrame(level: 0, name: "f", source: "test.lua", line: 3)],
            frameVars: [:], globals: nil
        )
        (state, _) = reduce(state, .debugPaused(snap3))

        // 8. Step out (o key).
        (state, effects) = reduce(state, .key(.char("o"), modifiers: []))
        #expect(findSendCommand(effects)?.1 == .stepOut, "o → stepOut")
        #expect(state.currentDebugSnapshot == nil)

        // 9. Simulate pause at line 4.
        let snap4 = DebugSnapshot(
            sessionID: sid, event: .line, fragmentLine: 4,
            callStack: [DebugFrame(level: 0, name: "f", source: "test.lua", line: 4)],
            frameVars: [:], globals: nil
        )
        (state, _) = reduce(state, .debugPaused(snap4))

        // 10. Continue (c key).
        (state, effects) = reduce(state, .key(.char("c"), modifiers: []))
        #expect(findSendCommand(effects)?.1 == .continueRun, "c → continueRun")
        #expect(state.currentDebugSnapshot == nil)

        // 11. Simulate: run finished normally.
        (state, _) = reduce(state, .debugFinished(sid, .done(value: nil, duration: .zero)))
        #expect(state.activeDebugSessionID == nil, "session cleared after finish")
        #expect(state.currentDebugSnapshot == nil)
    }
}

// MARK: - Status bar paused hint

@Suite("F6.2 — Status bar paused hint (renderer binding)")
struct PausedHintStatusBarTests {

    @Test("buildPausedStatusHint produces exact PRD string with display-name and line")
    func pausedStatusHint() {
        // The renderer builds the paused hint from the snapshot; verify the exact format.
        // PRD §1473: "[paused at <display-name>:<line>]  s/i/o step  c continue  x stop"
        let expected = "[paused at test.lua:2]  s/i/o step  c continue  x stop"
        let got = buildPausedStatusHint(displayName: "test.lua", line: 2)
        #expect(got == expected, "exact paused status hint string (PRD §1473–1474)")
    }
}
