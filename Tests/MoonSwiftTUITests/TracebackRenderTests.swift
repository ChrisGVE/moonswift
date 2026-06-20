// File: Tests/MoonSwiftTUITests/TracebackRenderTests.swift
// Location: MoonSwiftTUITests/
// Role: P2 F6.4 — the Output-tab traceback rendering: the `tracebackLines`
//       splitter, the `.runFinished(.error)` path (footer + traceback frames),
//       and the `debugFinished(.error)` path (the Debug tab clears on finish, so
//       a debug-run error also surfaces its footer + traceback in the Output
//       tab). Drives reduce() / the helper directly.
//
// Upstream: Renderer.tracebackLines / buildRunFooter, Reducer (.runFinished),
//           DebugReducer (reduceDebugFinished)
// Downstream: (test target)

import Foundation
import MoonSwiftCore
import Testing

@testable import MoonSwiftTUI

// MARK: - tracebackLines splitter

@Suite("F6.4 — tracebackLines splitter")
struct TracebackLinesTests {

    @Test("nil and empty produce no lines")
    func emptyCases() {
        #expect(tracebackLines(nil).isEmpty)
        #expect(tracebackLines("").isEmpty)
    }

    @Test("a multi-line traceback splits into one line per frame, trailing blanks dropped")
    func multiline() {
        let tb = "stack traceback:\n\tinner: in function 'inner'\n\tmain chunk\n"
        #expect(
            tracebackLines(tb) == [
                "stack traceback:", "\tinner: in function 'inner'", "\tmain chunk",
            ])
    }
}

// MARK: - Output-tab rendering

@Suite("F6.4 — error traceback in the Output tab")
struct ErrorTracebackOutputTests {

    private func diag(_ message: String, line: Int = 2) -> Diagnostic {
        Diagnostic(severity: .error, line: line, message: message, source: .runtime)
    }

    @Test(".runFinished error appends the footer then the traceback frames")
    func runFinishedAppendsTraceback() {
        var s = AppState()
        let frames = ["stack traceback:", "\tconfig.lua:2: in main chunk"]
        s = reduce(s, .runFinished(.error(diag("boom"), traceback: frames))).0
        let out = s.bottomPane.outputBuffer
        #expect(out.contains("error — boom → jump to line 2"))
        #expect(out.contains("stack traceback:"))
        #expect(out.contains("\tconfig.lua:2: in main chunk"))
        // Footer comes before the frames.
        let footerIdx = out.firstIndex(of: "error — boom → jump to line 2")
        let frameIdx = out.firstIndex(of: "stack traceback:")
        #expect(footerIdx != nil && frameIdx != nil && footerIdx! < frameIdx!)
    }

    @Test(".runFinished error with no traceback appends only the footer")
    func runFinishedNoTraceback() {
        var s = AppState()
        s = reduce(s, .runFinished(.error(diag("nope", line: 0), traceback: []))).0
        #expect(s.bottomPane.outputBuffer.contains("error — nope"))
        #expect(!s.bottomPane.outputBuffer.contains("stack traceback:"))
    }

    @Test("debugFinished error surfaces the footer + traceback in the Output tab")
    func debugFinishedAppendsTraceback() {
        var s = AppState()
        let id = DebugSessionID()
        s.activeDebugSessionID = id
        let outcome: CoreRunOutcome = .error(
            diag("kaboom", line: 5),
            traceback: "stack traceback:\n\tconfig.lua:5: in function 'inner'")
        s = reduce(s, .debugFinished(id, outcome)).0
        let out = s.bottomPane.outputBuffer
        #expect(out.contains("error — kaboom → jump to line 5"))
        #expect(out.contains("\tconfig.lua:5: in function 'inner'"))
        // The session is cleared on finish.
        #expect(s.activeDebugSessionID == nil)
    }

    @Test("debugFinished for a stale session id is a no-op (no Output change)")
    func debugFinishedStaleIsNoop() {
        var s = AppState()
        s.activeDebugSessionID = DebugSessionID()
        let stale = DebugSessionID()
        s = reduce(s, .debugFinished(stale, .error(diag("x"), traceback: "t"))).0
        #expect(s.bottomPane.outputBuffer.isEmpty)
    }
}
