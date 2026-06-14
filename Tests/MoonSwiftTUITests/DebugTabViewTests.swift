// File: Tests/MoonSwiftTUITests/DebugTabViewTests.swift
// Location: MoonSwiftTUITests/
// Role: TDD tests for P2 F6.3 — the Debug tab: Locals/Upvalues/Globals/Call-Stack
//       rows, frame selection (no engine re-entry), inline table expansion, the
//       `g` globals request + `(globals pending…)` + `(… N more globals)` elision
//       marker (D2), and the §6.9 VM-running Case-1/Case-2 states.
//
//       Tests drive `reduce()` and the pure `buildDebugRows()` model directly,
//       plus `renderDebugTab()` for marker styling. No FFI, no live engine: the
//       snapshot data is constructed as the value model that the adapter would
//       publish, and behaviour is asserted against the type under test (never
//       constructed-then-read-back).
//
// Upstream: DebugTabView.swift, DebugReducer.swift, Reducer.swift,
//           DebugSnapshot (MoonSwiftCore)
// Downstream: (test target)

import CryptoKit
import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build a loaded state whose debug session is paused at `snapshot`.
private func pausedState(
    snapshot: DebugSnapshot,
    code: String = "l1\nl2\nl3\nl4\nl5"
) -> AppState {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    let url = URL(fileURLWithPath: "/project/test.lua")
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let provenance = FragmentProvenance(
        file: url, jsonpath: nil, document: 0,
        byteRange: 0..<data.count, lineOffset: 0, contentHash: hash
    )
    state.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: provenance))
    state.navigatorOrder = [id]
    state.selection = id
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.focus = .pane(.bottomPane)
    state.activeDebugSessionID = snapshot.sessionID
    state.currentDebugSnapshot = snapshot
    state.lastPauseSnapshot = snapshot
    state.bottomPane.activeTab = .debug
    return state
}

private func snapshot(
    sessionID: DebugSessionID = DebugSessionID(),
    fragmentLine: Int = 2,
    callStack: [DebugFrame] = [DebugFrame(level: 0, name: "main", source: "test.lua", line: 2)],
    frameVars: [Int: ([DebugVariable], [DebugVariable])] = [:],
    globals: [DebugVariable]? = nil,
    globalsElided: Int = 0,
    pauseSequence: Int = 0
) -> DebugSnapshot {
    DebugSnapshot(
        sessionID: sessionID, event: .breakpoint, fragmentLine: fragmentLine,
        callStack: callStack, frameVars: frameVars, globals: globals,
        globalsElided: globalsElided, pauseSequence: pauseSequence
    )
}

/// Collect every `.info` line text in render order.
private func infoTexts(_ rows: [DebugRow]) -> [String] {
    rows.compactMap { if case .info(let t) = $0 { return t } else { return nil } }
}

/// Collect every `.header` text in render order.
private func headerTexts(_ rows: [DebugRow]) -> [String] {
    rows.compactMap { if case .header(let t) = $0 { return t } else { return nil } }
}

/// Collect every variable-row name in render order.
private func variableNames(_ rows: [DebugRow]) -> [String] {
    rows.compactMap { if case .variable(let v) = $0 { return v.name } else { return nil } }
}

// MARK: - Section layout & locals

@Test("Paused Debug tab renders the four section headers in order")
func debugTab_sectionHeaders() {
    let rows = buildDebugRows(pausedState(snapshot: snapshot()))
    #expect(headerTexts(rows) == ["── Locals ──", "── Upvalues ──", "── Globals ──", "── Call Stack ──"])
}

@Test("Locals come from the selected frame's frameVars")
func debugTab_localsFromSelectedFrame() {
    let snap = snapshot(
        callStack: [
            DebugFrame(level: 0, name: "inner", source: "test.lua", line: 3),
            DebugFrame(level: 1, name: "outer", source: "test.lua", line: 1),
        ],
        frameVars: [
            0: ([DebugVariable(name: "x", displayValue: "1")], []),
            1: ([DebugVariable(name: "y", displayValue: "2")], []),
        ]
    )
    let rows = buildDebugRows(pausedState(snapshot: snap))
    #expect(variableNames(rows) == ["x"])
}

@Test("Empty locals/upvalues render their bound empty-state lines")
func debugTab_emptyLocalsUpvalues() {
    let snap = snapshot(frameVars: [0: ([], [])])
    let rows = buildDebugRows(pausedState(snapshot: snap))
    #expect(infoTexts(rows).contains("(no locals)"))
    #expect(infoTexts(rows).contains("(no upvalues)"))
}

// MARK: - Frame selection (no engine re-entry)

@Test("Enter on a parent frame shows that frame's locals from the cached frameVars")
func debugTab_selectParentFrame() {
    let snap = snapshot(
        callStack: [
            DebugFrame(level: 0, name: "inner", source: "test.lua", line: 3),
            DebugFrame(level: 1, name: "outer", source: "test.lua", line: 1),
        ],
        frameVars: [
            0: ([DebugVariable(name: "x", displayValue: "1")], []),
            1: ([DebugVariable(name: "y", displayValue: "2")], []),
        ]
    )
    var state = pausedState(snapshot: snap)
    // Selectable rows are the two frames; cursor on the second (level 1).
    state.debugSelectedRow = 1
    let (next, effects) = reduce(state, .key(.enter, modifiers: []))
    #expect(effects.isEmpty)  // pure UI nav, no engine effect
    #expect(next.debugSelectedFrame == 1)
    #expect(variableNames(buildDebugRows(next)) == ["y"])
    // Code pane retargeted to the frame's line (1-based → 0-based offset).
    #expect(next.codePane.cursorLine == 0)
}

// MARK: - Globals (g) request + pending + empty + elision

@Test("g while paused emits requestGlobals and sets the pending latch")
func debugTab_globalsRequest() {
    let snap = snapshot()
    let state = pausedState(snapshot: snap)
    let (next, effects) = reduce(state, .key(.char("g"), modifiers: []))
    #expect(next.debugGlobalsRequested)
    #expect(
        effects.contains { if case .requestGlobals(let id) = $0 { return id == snap.sessionID } else { return false } })
    // The Globals section shows the in-flight placeholder.
    #expect(infoTexts(buildDebugRows(next)).contains("(globals pending…)"))
}

@Test("Not-yet-fetched globals render header only (no line)")
func debugTab_globalsNotFetched() {
    let rows = buildDebugRows(pausedState(snapshot: snapshot()))
    #expect(!infoTexts(rows).contains("(globals pending…)"))
    #expect(!infoTexts(rows).contains("(no globals defined)"))
}

@Test("Empty fetched globals render the single (no globals defined) line")
func debugTab_globalsEmpty() {
    let rows = buildDebugRows(pausedState(snapshot: snapshot(globals: [])))
    #expect(infoTexts(rows).contains("(no globals defined)"))
}

@Test("Breadth-capped globals render the (… N more globals) elision marker (D2)")
func debugTab_globalsElisionMarker() {
    let snap = snapshot(globals: [DebugVariable(name: "g1", displayValue: "1")], globalsElided: 3)
    let rows = buildDebugRows(pausedState(snapshot: snap))
    #expect(infoTexts(rows).contains("(… 3 more globals)"))
}

@Test("A globals-republish clears the pending latch and preserves frame/expansion")
func debugTab_globalsRepublishPreservesNav() {
    let sid = DebugSessionID()
    let fresh = snapshot(
        sessionID: sid, fragmentLine: 2,
        frameVars: [
            0: (
                [
                    DebugVariable(
                        name: "t", displayValue: "{table}",
                        children: [DebugVariable(name: "a", displayValue: "1")])
                ], []
            )
        ],
        pauseSequence: 1
    )
    var state = pausedState(snapshot: fresh)
    // User expands `t`, then presses g.
    state.debugExpandedPaths = ["local:t"]
    state = reduce(state, .key(.char("g"), modifiers: [])).0
    #expect(state.debugGlobalsRequested)
    // Adapter republishes the SAME pause (same sequence) with globals populated.
    let republished = snapshot(
        sessionID: sid, fragmentLine: 2,
        frameVars: fresh.frameVars,
        globals: [DebugVariable(name: "G", displayValue: "9")],
        pauseSequence: 1
    )
    let after = reduce(state, .debugPaused(republished)).0
    #expect(!after.debugGlobalsRequested)  // resolved
    #expect(after.debugExpandedPaths == ["local:t"])  // expansion preserved
    #expect(variableNames(buildDebugRows(after)).contains("G"))  // globals now shown
}

@Test("A new pause re-hitting the same line resets the cursor (CR-023)")
func debugTab_loopRehitResetsNav() {
    // Two consecutive NEW pauses on the SAME fragment line (a breakpoint inside
    // a loop body). They differ only by pauseSequence — keying on
    // (sessionID, fragmentLine) alone would misclassify the second as an
    // in-place globals republish and leave a stale expansion/cursor.
    let sid = DebugSessionID()
    let frameVars: [Int: ([DebugVariable], [DebugVariable])] = [
        0: (
            [
                DebugVariable(
                    name: "t", displayValue: "{table}",
                    children: [DebugVariable(name: "a", displayValue: "1")])
            ], []
        )
    ]
    let first = snapshot(
        sessionID: sid, fragmentLine: 2, frameVars: frameVars, pauseSequence: 1)
    var state = pausedState(snapshot: first)  // currentDebugSnapshot is non-nil
    state.debugExpandedPaths = ["local:t"]
    state.debugSelectedRow = 1
    // A NEW pause on the SAME line while the prior snapshot is still live (no
    // intervening resume nilled it). Old (sessionID, fragmentLine) keying would
    // misclassify this as a globals republish and keep the stale cursor; the
    // differing pauseSequence makes it correctly a fresh pause that resets.
    let second = snapshot(
        sessionID: sid, fragmentLine: 2, frameVars: frameVars, pauseSequence: 2)
    let after = reduce(state, .debugPaused(second)).0
    #expect(after.debugExpandedPaths.isEmpty)  // expansion reset for the new pause
    #expect(after.debugSelectedRow == 0)  // cursor reset
}

// MARK: - Inline table expansion

@Test("Enter on an expandable value toggles its children inline")
func debugTab_inlineExpansion() {
    let snap = snapshot(frameVars: [
        0: (
            [
                DebugVariable(
                    name: "t", displayValue: "{table}",
                    children: [DebugVariable(name: "a", displayValue: "1")])
            ],
            []
        )
    ])
    var state = pausedState(snapshot: snap)
    // The only selectable rows are: the expandable `t` and the single frame.
    // Cursor defaults to row 0 → `t`.
    #expect(!variableNames(buildDebugRows(state)).contains("a"))  // collapsed
    state = reduce(state, .key(.enter, modifiers: [])).0
    #expect(state.debugExpandedPaths.contains("local:t"))
    #expect(variableNames(buildDebugRows(state)).contains("a"))  // expanded
    // Collapse again.
    state = reduce(state, .key(.enter, modifiers: [])).0
    #expect(!state.debugExpandedPaths.contains("local:t"))
}

@Test("Cycle / depth markers render dim")
func debugTab_markersDim() {
    let snap = snapshot(frameVars: [
        0: (
            [
                DebugVariable(name: "c", displayValue: "(cycle)"),
                DebugVariable(name: "d", displayValue: "(…)"),
            ],
            []
        )
    ])
    let theme = ThemeState()
    let cmds = renderDebugTab(
        state: pausedState(snapshot: snap),
        rect: Rect(x: 0, y: 0, width: 60, height: 20), theme: theme)
    // Pull every span and confirm the marker strings are present with the dim fg.
    let dimFg = tokenStyle(.dim, theme: theme).fg
    var markerSpans: [Span] = []
    for cmd in cmds {
        if case .paragraph(_, let lines, _) = cmd {
            for line in lines {
                for span in line where span.text == "(cycle)" || span.text == "(…)" { markerSpans.append(span) }
            }
        }
    }
    #expect(markerSpans.count == 2)
    #expect(markerSpans.allSatisfy { $0.style.fg == dimFg })
}

// MARK: - VM-running Case 1 / Case 2 (§6.9)

@Test("Case 1 — fresh open, never paused — shows VM-running placeholders")
func debugTab_vmRunningCase1() {
    var state = pausedState(snapshot: snapshot())
    state.currentDebugSnapshot = nil
    state.lastPauseSnapshot = nil  // never paused
    let rows = buildDebugRows(state)
    #expect(infoTexts(rows).first == "VM running…")
    #expect(infoTexts(rows).filter { $0 == "(VM running — no snapshot yet)" }.count == 4)
}

@Test("Case 2 — running after a pause — retains last-pause data under the showing-last-pause header")
func debugTab_vmRunningCase2() {
    let snap = snapshot(frameVars: [0: ([DebugVariable(name: "x", displayValue: "1")], [])])
    var state = pausedState(snapshot: snap)
    state.currentDebugSnapshot = nil  // resumed, but lastPauseSnapshot retained
    let rows = buildDebugRows(state)
    #expect(infoTexts(rows).first == "VM running… (showing last pause)")
    #expect(variableNames(rows) == ["x"])  // retained
}

@Test("debugResumed discards a pending globals latch (no stale pending in Case 2)")
func debugTab_resumeDiscardsPending() {
    let sid = DebugSessionID()
    var state = pausedState(snapshot: snapshot(sessionID: sid))
    state = reduce(state, .key(.char("g"), modifiers: [])).0
    #expect(state.debugGlobalsRequested)
    let after = reduce(state, .debugResumed(sid)).0
    #expect(!after.debugGlobalsRequested)
    #expect(after.currentDebugSnapshot == nil)
}

// MARK: - Cursor navigation & 3 quick-jump guard

@Test("j/k move the cursor over selectable rows and clamp")
func debugTab_cursorClamp() {
    let snap = snapshot(callStack: [
        DebugFrame(level: 0, name: "a", source: "test.lua", line: 1),
        DebugFrame(level: 1, name: "b", source: "test.lua", line: 2),
    ])
    var state = pausedState(snapshot: snap)
    // Two selectable rows (the frames). k at top stays 0; j moves to 1; j clamps.
    state = reduce(state, .key(.char("k"), modifiers: [])).0
    #expect(state.debugSelectedRow == 0)
    state = reduce(state, .key(.char("j"), modifiers: [])).0
    #expect(state.debugSelectedRow == 1)
    state = reduce(state, .key(.char("j"), modifiers: [])).0
    #expect(state.debugSelectedRow == 1)  // clamped
}

@Test("3 with no debug session shows the bound transient and does not switch tabs")
func debugTab_quickJumpNoSession() {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    state.sources[id] = .loaded(
        LuaSourceFragment(
            code: "x=1",
            provenance: FragmentProvenance(
                file: URL(fileURLWithPath: "/p/test.lua"), jsonpath: nil, document: 0,
                byteRange: 0..<3, lineOffset: 0, contentHash: SHA256.hash(data: Data("x=1".utf8)))
        ))
    state.selection = id
    state.focus = .pane(.bottomPane)
    state.bottomPane.activeTab = .output
    let (next, _) = reduce(state, .key(.char("3"), modifiers: []))
    #expect(next.transient?.text == "Debug tab not active.")
    #expect(next.bottomPane.activeTab == .output)
}
