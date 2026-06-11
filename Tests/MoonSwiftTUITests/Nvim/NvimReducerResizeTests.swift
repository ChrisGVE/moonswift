// File: Tests/MoonSwiftTUITests/Nvim/NvimReducerResizeTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer tests for Inc-8 — terminal resize debounce and modeChange
//       handling for the nvim editing subsystem (ARCHITECTURE.md §10.8 Inc-8).
//
//       Covers:
//         • resize while .nvimPane → stores pending size, arms tick
//         • resize while .pane(.codePane) → no debounce state set
//         • resize always updates AppState.terminalSize
//         • tick after debounce deadline → emits Effect.nvimResize, clears state
//         • tick before deadline → no nvimResize emitted
//         • modeChange in .nvimPane → updates NvimPaneState.mode
//         • modeChange outside .nvimPane → no state change
//
// Relationships:
//   → Reducer.swift  (Inc-8): reduceResize, reduceTick, reduceNvimRedrawBatch
//   → AppState.swift (Inc-8): nvimPendingResize, nvimResizeDeadline, terminalSize
//   → Effect.swift   (Inc-8): nvimResize, startTick

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers (file-private; duplicated from NvimReducerFocusTests to keep
//         each file self-contained and ≤400 lines)

private func makeResizeTestFragment() -> LuaSourceFragment {
    let provenance = FragmentProvenance(
        file: URL(fileURLWithPath: "/tmp/test.lua"),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<9,
        lineOffset: 0,
        contentHash: SHA256.hash(data: Data())
    )
    return LuaSourceFragment(code: "return 1\n", provenance: provenance)
}

private func makeResizeCodePaneState() -> AppState {
    let sid = SourceID(path: "test.lua")
    return AppState(
        sources: [sid: .loaded(makeResizeTestFragment())],
        navigatorOrder: [sid],
        selection: sid,
        focus: .pane(.codePane),
        terminalSize: TerminalSize(cols: 120, rows: 40)
    )
}

private func makeResizeNvimPaneState() -> AppState {
    var s = makeResizeCodePaneState()
    s.focus = .nvimPane(NvimPaneState(attachedRect: Rect(x: 18, y: 1, width: 102, height: 22)))
    return s
}

private func applyResize(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

// MARK: - Suite

@Suite("NvimReducerResizeTests")
struct NvimReducerResizeTests {

    // MARK: Resize debounce

    @Test("resize while .nvimPane stores pending size and arms tick")
    func resizeWhileNvimPaneDebounces() {
        let s = makeResizeNvimPaneState()
        let size = TerminalSize(cols: 100, rows: 30)
        let (next, effects) = applyResize(s, .resize(size))
        #expect(next.nvimPendingResize == size)
        #expect(next.nvimResizeDeadline != nil)
        // A tick must be armed so the debounce window fires.
        let hasTick = effects.contains {
            if case .startTick = $0 { return true }
            return false
        }
        #expect(hasTick, "startTick expected when debounce is queued")
    }

    @Test("resize while .pane(.codePane) does not set pending resize")
    func resizeOutsideNvimPaneNoDebounce() {
        let s = makeResizeCodePaneState()
        let (next, _) = applyResize(s, .resize(TerminalSize(cols: 100, rows: 30)))
        #expect(next.nvimPendingResize == nil)
    }

    @Test("resize always updates AppState.terminalSize regardless of focus")
    func resizeUpdatesTerminalSize() {
        let s = makeResizeCodePaneState()
        let size = TerminalSize(cols: 100, rows: 30)
        let (next, _) = applyResize(s, .resize(size))
        #expect(next.terminalSize == size)
    }

    @Test("resize while .nvimSpawning queues debounce (nvim not yet active)")
    func resizeWhileSpawningDebounces() {
        var s = makeResizeCodePaneState()
        s.focus = .nvimSpawning
        let size = TerminalSize(cols: 100, rows: 30)
        let (next, _) = applyResize(s, .resize(size))
        #expect(next.nvimPendingResize == size)
    }

    @Test("rapid resize events: latest size wins when debounce fires")
    func rapidResizeLatestSizeWins() {
        var s = makeResizeNvimPaneState()
        // First resize.
        let (s1, _) = applyResize(s, .resize(TerminalSize(cols: 90, rows: 25)))
        // Second resize overrides the first.
        let (s2, _) = applyResize(s1, .resize(TerminalSize(cols: 100, rows: 30)))
        // The pending resize must be the last one.
        #expect(s2.nvimPendingResize == TerminalSize(cols: 100, rows: 30))
    }

    @Test("0×0 sentinel resize does not set debounce state")
    func sentinelResizeIgnored() {
        var s = makeResizeNvimPaneState()
        let (next, _) = applyResize(s, .resize(TerminalSize(cols: 0, rows: 0)))
        #expect(next.nvimPendingResize == nil)
    }

    // MARK: Debounce tick firing

    @Test("tick after deadline emits nvimResize(size) and clears pending state")
    func tickAfterDeadlineFiresResize() {
        var s = makeResizeNvimPaneState()
        let size = TerminalSize(cols: 100, rows: 30)
        s.nvimPendingResize = size
        s.nvimResizeDeadline = Date(timeIntervalSinceNow: -1.0)  // already expired

        let (next, effects) = applyResize(s, .tick)
        #expect(next.nvimPendingResize == nil, "Pending resize cleared after fire")
        #expect(next.nvimResizeDeadline == nil, "Deadline cleared after fire")
        let hasNvimResize = effects.contains {
            if case .nvimResize(let sz) = $0 { return sz == size }
            return false
        }
        #expect(hasNvimResize, "nvimResize effect expected after debounce expires")
    }

    @Test("tick before deadline does NOT emit nvimResize")
    func tickBeforeDeadlineNoResize() {
        var s = makeResizeNvimPaneState()
        let size = TerminalSize(cols: 100, rows: 30)
        s.nvimPendingResize = size
        s.nvimResizeDeadline = Date(timeIntervalSinceNow: 60.0)  // far future

        let (next, effects) = applyResize(s, .tick)
        #expect(next.nvimPendingResize == size, "Pending resize preserved before deadline")
        let hasNvimResize = effects.contains {
            if case .nvimResize = $0 { return true }
            return false
        }
        #expect(!hasNvimResize, "nvimResize must not fire before deadline")
    }

    @Test("tick with no pending resize emits no nvimResize")
    func tickNoPendingResizeNoEffect() {
        let s = makeResizeNvimPaneState()  // no pending resize seeded
        let (_, effects) = applyResize(s, .tick)
        let hasNvimResize = effects.contains {
            if case .nvimResize = $0 { return true }
            return false
        }
        #expect(!hasNvimResize)
    }

    // MARK: modeChange updates NvimPaneState.mode

    @Test("modeChange batch in .nvimPane updates NvimPaneState.mode")
    func modeChangeUpdatesMode() {
        let s = makeResizeNvimPaneState()
        guard case .nvimPane(let ps0) = s.focus else {
            Issue.record("Expected .nvimPane")
            return
        }
        #expect(ps0.mode == "normal")

        let (next, _) = applyResize(
            s,
            .nvimRedrawBatch([.modeChange(name: "insert", modeIdx: 1), .flush])
        )
        guard case .nvimPane(let ps1) = next.focus else {
            Issue.record("Expected .nvimPane after modeChange")
            return
        }
        #expect(ps1.mode == "insert")
    }

    @Test("modeChange batch outside .nvimPane is consumed without changing focus")
    func modeChangeOutsideNvimPaneIsNoop() {
        let s = makeResizeCodePaneState()  // focus is .pane(.codePane)
        let (next, _) = applyResize(
            s,
            .nvimRedrawBatch([.modeChange(name: "insert", modeIdx: 1), .flush])
        )
        #expect(next.focus == .pane(.codePane))
    }

    @Test("modeChange updates mode field without touching other NvimPaneState fields")
    func modeChangeOnlyUpdatesMode() {
        let rect = Rect(x: 18, y: 1, width: 80, height: 20)
        var s = makeResizeCodePaneState()
        s.focus = .nvimPane(NvimPaneState(attachedRect: rect, mode: "normal", modified: true))

        let (next, _) = applyResize(
            s,
            .nvimRedrawBatch([.modeChange(name: "visual", modeIdx: 3), .flush])
        )
        guard case .nvimPane(let ps) = next.focus else {
            Issue.record("Expected .nvimPane")
            return
        }
        #expect(ps.mode == "visual")
        #expect(ps.attachedRect == rect, "attachedRect must be unchanged")
        #expect(ps.modified == true, "modified flag must be unchanged")
    }
}
