// File: Tests/MoonSwiftTUITests/CommandInterpreterTests.swift
// Location: MoonSwiftTUITests/
// Role: Unit tests for CommandInterpreter against RecordingRenderBackend.
//       Verifies command ordering, every RenderCommand case is dispatched,
//       the batching contract (N cellRun commands → N backend cellRun calls),
//       below-minimum-size behavior (leaveAltScreen + no widget calls, then
//       resumeAltScreen on regrow + full redraw), and first-error accumulation.
//       No FFI is linked in this target — all assertions run against the
//       recording fake (ARCHITECTURE.md §5.1; ux-spec.md §1.4).
// Upstream: CommandInterpreter.swift, RecordingRenderBackend.swift,
//           RenderCommand.swift
// Downstream: (test target)

import Foundation
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func makeRect(_ x: UInt16 = 0, _ y: UInt16 = 0, _ w: UInt16 = 80, _ h: UInt16 = 24)
    -> Rect
{
    Rect(x: x, y: y, width: w, height: h)
}

private func makeSize(_ cols: UInt16 = 80, _ rows: UInt16 = 24) -> TerminalSize {
    TerminalSize(cols: cols, rows: rows)
}

private func defaultStyle() -> CellStyle { .default }

private func makeInterpreter() -> (CommandInterpreter, RecordingRenderBackend) {
    let backend = RecordingRenderBackend()
    let interpreter = CommandInterpreter(backend: backend)
    return (interpreter, backend)
}

// MARK: - Suite

@Suite("CommandInterpreter")
struct CommandInterpreterTests {

    // MARK: beginFrame

    @Test("beginFrame command is dispatched first in a normal frame")
    func beginFrameDispatchedFirst() throws {
        let (interp, backend) = makeInterpreter()
        let size = makeSize()
        let style = defaultStyle()

        try interp.apply([
            .beginFrame(size: size, defaultStyle: style),
            .clear(rect: makeRect()),
        ])

        guard case .beginFrame(let s, let ds) = backend.calls.first else {
            Issue.record("Expected first call to be beginFrame")
            return
        }
        #expect(s == size)
        #expect(ds == style)
    }

    // MARK: flush called at end of normal frame

    @Test("flush is called once at the end of a normal frame")
    func flushCalledAtEnd() throws {
        let (interp, backend) = makeInterpreter()
        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle())
        ])

        #expect(backend.calls.last == .flush)
    }

    // MARK: titleBar

    @Test("titleBar command dispatches to backend titleBar")
    func titleBarDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(0, 0, 80, 1)
        let style = defaultStyle()

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: style),
            .titleBar(rect: rect, left: "moonswift", badges: ["[running]"], style: style),
        ])

        let titleCall = backend.calls.first {
            if case .titleBar = $0 { return true }
            return false
        }
        guard case .titleBar(let r, let left, let badges, _) = titleCall else {
            Issue.record("No titleBar call recorded")
            return
        }
        #expect(r == rect)
        #expect(left == "moonswift")
        #expect(badges == ["[running]"])
    }

    // MARK: navigatorList

    @Test("navigatorList command dispatches to backend navigatorList")
    func navigatorListDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(0, 1, 18, 14)
        let items: [Span] = [Span("init.lua"), Span("helper.lua")]
        let title: [Span] = [Span("Sources")]

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .navigatorList(rect: rect, items: items, selectedIndex: 0, title: title),
        ])

        let navCall = backend.calls.first {
            if case .navigatorList = $0 { return true }
            return false
        }
        guard case .navigatorList(let r, let its, let sel, let ttl) = navCall else {
            Issue.record("No navigatorList call recorded")
            return
        }
        #expect(r == rect)
        #expect(its == items)
        #expect(sel == 0)
        #expect(ttl == title)
    }

    // MARK: paragraph

    @Test("paragraph command dispatches to backend paragraph")
    func paragraphDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(18, 1, 62, 14)
        let lines: [[Span]] = [[Span("print('hello')")], [Span("return 42")]]

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .paragraph(rect: rect, lines: lines, block: nil),
        ])

        let paraCall = backend.calls.first {
            if case .paragraph = $0 { return true }
            return false
        }
        guard case .paragraph(let r, let ls, let blk) = paraCall else {
            Issue.record("No paragraph call recorded")
            return
        }
        #expect(r == rect)
        #expect(ls == lines)
        #expect(blk == nil)
    }

    // MARK: tabBar

    @Test("tabBar command dispatches to backend tabBar")
    func tabBarDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(0, 15, 80, 1)

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .tabBar(rect: rect, tabs: ["Output", "Errors"], selectedIndex: 1),
        ])

        let tabCall = backend.calls.first {
            if case .tabBar = $0 { return true }
            return false
        }
        guard case .tabBar(let r, let tabs, let sel) = tabCall else {
            Issue.record("No tabBar call recorded")
            return
        }
        #expect(r == rect)
        #expect(tabs == ["Output", "Errors"])
        #expect(sel == 1)
    }

    // MARK: block

    @Test("block command dispatches to backend block")
    func blockDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(0, 1, 18, 14)
        let config = BlockConfig(borders: .all, borderType: .rounded)
        let borderStyle = CellStyle(fg: 0x00_FF_FF_FF, bg: 0xFFFF_FFFF)

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .block(rect: rect, config: config, borderStyle: borderStyle),
        ])

        let blockCall = backend.calls.first {
            if case .block = $0 { return true }
            return false
        }
        guard case .block(let r, let cfg, let bs) = blockCall else {
            Issue.record("No block call recorded")
            return
        }
        #expect(r == rect)
        #expect(cfg == config)
        #expect(bs == borderStyle)
    }

    // MARK: clear

    @Test("clear command dispatches to backend clear")
    func clearDispatched() throws {
        let (interp, backend) = makeInterpreter()
        let rect = makeRect(18, 1, 62, 14)

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .clear(rect: rect),
        ])

        let clearCall = backend.calls.first {
            if case .clear = $0 { return true }
            return false
        }
        guard case .clear(let r) = clearCall else {
            Issue.record("No clear call recorded")
            return
        }
        #expect(r == rect)
    }

    // MARK: cellRun — batching contract

    @Test("N cellRun commands produce N backend cellRun calls (batching contract)")
    func cellRunBatchingContract() throws {
        let (interp, backend) = makeInterpreter()
        let style = defaultStyle()
        let altStyle = CellStyle(fg: 0x00_FF_00_00, bg: 0xFFFF_FFFF)

        // Three cellRun commands with different styles — must not be merged.
        let commands: [RenderCommand] = [
            .beginFrame(size: makeSize(), defaultStyle: style),
            .cellRun(col: 0, row: 5, text: "hello", style: style),
            .cellRun(col: 5, row: 5, text: " ", style: altStyle),
            .cellRun(col: 6, row: 5, text: "world", style: style),
        ]

        try interp.apply(commands)

        let cellCalls = backend.calls.compactMap {
            call -> (col: UInt16, row: UInt16, text: String, style: CellStyle)? in
            if case .cellRun(let c, let r, let t, let s) = call { return (c, r, t, s) }
            return nil
        }
        #expect(cellCalls.count == 3, "Expect 3 backend cellRun calls for 3 input commands")
        #expect(cellCalls[0].text == "hello")
        #expect(cellCalls[1].text == " ")
        #expect(cellCalls[2].text == "world")
    }

    @Test("cellRun with same style at same row preserves individual commands")
    func cellRunSameStylePreservesCommands() throws {
        let (interp, backend) = makeInterpreter()
        let style = defaultStyle()

        // Two separate cellRun commands — the interpreter must NOT merge them.
        // Merging is the CellBuffer's job inside the production backend; the
        // interpreter simply passes each command through as a single call.
        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: style),
            .cellRun(col: 0, row: 0, text: "abc", style: style),
            .cellRun(col: 3, row: 0, text: "def", style: style),
        ])

        let cellCalls = backend.calls.filter {
            if case .cellRun = $0 { return true }
            return false
        }
        #expect(cellCalls.count == 2, "Two cellRun commands → two backend calls, not one merged call")
    }

    // MARK: belowMinimumSize — no widget calls

    @Test("belowMinimumSize frame calls leaveAltScreenWithMessage, no widget calls")
    func belowMinimumSizeNoWidgetCalls() throws {
        let (interp, backend) = makeInterpreter()

        try interp.apply([.belowMinimumSize(cols: 60, rows: 20)])

        // Must call leaveAltScreenWithMessage with the exact dimensions.
        guard case .leaveAltScreenWithMessage(let cols, let rows) = backend.calls.first else {
            Issue.record("Expected leaveAltScreenWithMessage as first call")
            return
        }
        #expect(cols == 60)
        #expect(rows == 20)

        // Must not call any widget or cell methods.
        let hasWidgets = backend.calls.contains {
            switch $0 {
            case .beginFrame, .flush, .titleBar, .navigatorList, .paragraph,
                .tabBar, .block, .clear, .cellRun, .resumeAltScreen:
                return true
            case .leaveAltScreenWithMessage:
                return false
            }
        }
        #expect(!hasWidgets, "belowMinimumSize frame must not produce widget or flush calls")
    }

    @Test("repeated belowMinimumSize does not call leaveAltScreenWithMessage again")
    func repeatedBelowMinimumNoDuplicate() throws {
        let (interp, backend) = makeInterpreter()

        // First below-minimum frame: should call leave.
        try interp.apply([.belowMinimumSize(cols: 60, rows: 20)])
        let firstCount = backend.calls.filter {
            if case .leaveAltScreenWithMessage = $0 { return true }
            return false
        }.count
        #expect(firstCount == 1)

        // Second below-minimum frame: already below, must not call leave again.
        try interp.apply([.belowMinimumSize(cols: 60, rows: 20)])
        let secondCount = backend.calls.filter {
            if case .leaveAltScreenWithMessage = $0 { return true }
            return false
        }.count
        #expect(secondCount == 1, "Second below-minimum frame must not call leaveAltScreenWithMessage again")
    }

    // MARK: regrow — resumeAltScreen before widget commands

    @Test("normal frame after belowMinimumSize calls resumeAltScreen before widgets")
    func regrowCallsResumeBeforeWidgets() throws {
        let (interp, backend) = makeInterpreter()

        // Trigger below-minimum.
        try interp.apply([.belowMinimumSize(cols: 60, rows: 20)])
        let leaveIdx = backend.calls.firstIndex {
            if case .leaveAltScreenWithMessage = $0 { return true }
            return false
        }
        #expect(leaveIdx != nil, "Must leave alt screen on below-minimum frame")

        // Now send a normal frame — the interpreter must call resumeAltScreen first.
        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
            .clear(rect: makeRect()),
        ])

        let resumeIdx = backend.calls.firstIndex {
            if case .resumeAltScreen = $0 { return true }
            return false
        }
        let beginIdx = backend.calls.firstIndex {
            if case .beginFrame = $0 { return true }
            return false
        }

        #expect(resumeIdx != nil, "Must call resumeAltScreen when terminal regrows")
        #expect(beginIdx != nil, "Must call beginFrame in the regrow frame")
        if let ri = resumeIdx, let bi = beginIdx {
            #expect(ri < bi, "resumeAltScreen must precede beginFrame in the regrow frame")
        }
    }

    @Test("normal frame after regrow does not call resumeAltScreen again")
    func secondNormalFrameNoResumeAgain() throws {
        let (interp, backend) = makeInterpreter()

        try interp.apply([.belowMinimumSize(cols: 60, rows: 20)])
        try interp.apply([.beginFrame(size: makeSize(), defaultStyle: defaultStyle())])
        // Second normal frame — isBelowMinimum flag is cleared; no extra resume.
        try interp.apply([.beginFrame(size: makeSize(), defaultStyle: defaultStyle())])

        let resumeCount = backend.calls.filter {
            if case .resumeAltScreen = $0 { return true }
            return false
        }.count
        #expect(
            resumeCount == 1, "resumeAltScreen must be called exactly once per regrow, not on subsequent normal frames")
    }

    // MARK: command ordering

    @Test("commands are dispatched in the order they appear in the sequence")
    func commandOrderingPreserved() throws {
        let (interp, backend) = makeInterpreter()
        let style = defaultStyle()
        let rect = makeRect()

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: style),
            .clear(rect: rect),
            .cellRun(col: 0, row: 0, text: "A", style: style),
            .cellRun(col: 1, row: 0, text: "B", style: style),
            // flush is implicit at the end
        ])

        // Filter out the trailing .flush and check the dispatch order.
        let relevantCalls = backend.calls.filter { call in
            switch call {
            case .flush: return false
            default: return true
            }
        }
        #expect(relevantCalls.count == 4)
        if case .beginFrame = relevantCalls[0] {
        } else {
            Issue.record("Expected beginFrame at index 0, got \(relevantCalls[0])")
        }
        if case .clear = relevantCalls[1] {
        } else {
            Issue.record("Expected clear at index 1, got \(relevantCalls[1])")
        }
        if case .cellRun(_, _, let t, _) = relevantCalls[2] {
            #expect(t == "A")
        } else {
            Issue.record("Expected cellRun 'A' at index 2, got \(relevantCalls[2])")
        }
        if case .cellRun(_, _, let t, _) = relevantCalls[3] {
            #expect(t == "B")
        } else {
            Issue.record("Expected cellRun 'B' at index 3, got \(relevantCalls[3])")
        }
    }

    // MARK: all cases covered

    @Test("every RenderCommand case is dispatched (no case silently dropped)")
    func allCasesCovered() throws {
        let (interp, backend) = makeInterpreter()
        let style = defaultStyle()
        let rect = makeRect()
        let config = BlockConfig()

        try interp.apply([
            .beginFrame(size: makeSize(), defaultStyle: style),
            .titleBar(rect: rect, left: "app", badges: [], style: style),
            .navigatorList(rect: rect, items: [], selectedIndex: nil, title: []),
            .paragraph(rect: rect, lines: [], block: nil),
            .tabBar(rect: rect, tabs: ["T"], selectedIndex: 0),
            .block(rect: rect, config: config, borderStyle: style),
            .clear(rect: rect),
            .cellRun(col: 0, row: 0, text: "x", style: style),
        ])

        let kinds: [(CallKind, String)] = [
            (.beginFrame, "beginFrame"),
            (.titleBar, "titleBar"),
            (.navigatorList, "navigatorList"),
            (.paragraph, "paragraph"),
            (.tabBar, "tabBar"),
            (.block, "block"),
            (.clear, "clear"),
            (.cellRun, "cellRun"),
            (.flush, "flush"),
        ]

        for (kind, name) in kinds {
            let found = backend.calls.contains { matchesKind($0, kind) }
            #expect(found, "Expected backend call '\(name)' was not recorded")
        }
    }

    // MARK: error accumulation

    @Test("first error in a frame is re-thrown after all commands are attempted")
    func firstErrorRethrownAfterAllCommands() throws {
        let (interp, backend) = makeInterpreter()
        backend.errorOnCall = .clear

        // The interpreter must attempt all commands even after clear throws.
        // The cellRun that follows must still be recorded.
        do {
            try interp.apply([
                .beginFrame(size: makeSize(), defaultStyle: defaultStyle()),
                .clear(rect: makeRect()),
                .cellRun(col: 0, row: 0, text: "z", style: defaultStyle()),
            ])
            Issue.record("Expected an error to be thrown")
        } catch {
            #expect(error is RecordingError)
        }

        // cellRun must have been recorded despite the earlier clear error.
        let hasCellRun = backend.calls.contains {
            if case .cellRun = $0 { return true }
            return false
        }
        #expect(hasCellRun, "cellRun after a failing clear must still be dispatched")
    }
}

// MARK: - Kind-match helper

/// Discriminant for backend call matching in tests (no associated values).
private enum CallKind {
    case beginFrame
    case flush
    case titleBar
    case navigatorList
    case paragraph
    case tabBar
    case block
    case clear
    case cellRun
    case leaveAltScreenWithMessage
    case resumeAltScreen
}

private func matchesKind(_ call: RecordingRenderBackend.BackendCall, _ kind: CallKind) -> Bool {
    switch (call, kind) {
    case (.beginFrame, .beginFrame): return true
    case (.flush, .flush): return true
    case (.titleBar, .titleBar): return true
    case (.navigatorList, .navigatorList): return true
    case (.paragraph, .paragraph): return true
    case (.tabBar, .tabBar): return true
    case (.block, .block): return true
    case (.clear, .clear): return true
    case (.cellRun, .cellRun): return true
    case (.leaveAltScreenWithMessage, .leaveAltScreenWithMessage): return true
    case (.resumeAltScreen, .resumeAltScreen): return true
    default: return false
    }
}
