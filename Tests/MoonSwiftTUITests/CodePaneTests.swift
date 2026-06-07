// File: Tests/MoonSwiftTUITests/CodePaneTests.swift
// Location: MoonSwiftTUITests/
// Role: Snapshot and reducer-sequence tests for the code pane rendering and
//       scrolling logic introduced in task 19. Covers: gutter cell drawing,
//       syntax-highlight batching, scrolling boundary enforcement, cursor-line
//       highlight, gutter marks (E/W), inline diagnostic hover row, colon-jump
//       command (:N<Enter> and :q), and diagnostic navigation (n/N/[d/]d).
//       No FFI is linked in this target (EventSource protocol seam — ARCH §5.1).
// Upstream: Renderer.swift, Reducer.swift, AppState.swift, AppEvent.swift
// Downstream: (test target — nothing imports this)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Shared helpers

/// Builds a `LuaSourceFragment` from arbitrary source text.
private func makeFragment(code: String, path: String = "test.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/project/\(path)")
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let prov = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: hash
    )
    return LuaSourceFragment(code: code, provenance: prov)
}

/// Returns an `AppState` with a loaded source in focus at the code pane.
private func codePaneState(code: String) -> (AppState, SourceID) {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    state.sources[id] = .loaded(makeFragment(code: code))
    state.navigatorOrder = [id]
    state.selection = id
    state.focus = .pane(.codePane)
    state.lintState = .idle
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (state, id)
}

/// Extracts all `.cellRun` commands from a render pass.
private func cellRuns(_ cmds: [RenderCommand]) -> [(col: UInt16, row: UInt16, text: String)] {
    cmds.compactMap {
        if case .cellRun(let c, let r, let t, _) = $0 { return (c, r, t) }
        return nil
    }
}

/// Standard 80×24 terminal size used in most code-pane tests.
private let stdSize = TerminalSize(cols: 80, rows: 24)

// MARK: - Gutter geometry tests

@Suite("Code pane — Gutter geometry")
struct CodePaneGutterTests {

    @Test("Gutter cell appears at col 1 (inside 1-cell border) on every visible row")
    func gutterAtLeftEdge() {
        // At 80×24: upper zone = 14 rows, inner = 12 rows (minus border).
        // Navigator = 18 cols; code pane starts at col 18.
        // Inner code pane x = 19 (18 + 1 border), gutter at col 19.
        let code = (1...12).map { "line\($0)" }.joined(separator: "\n")
        let (state, _) = codePaneState(code: code)
        let layout = computeLayout(size: stdSize, paneLayout: state.paneLayout)
        let innerX = layout.codePane.x + 1  // skip 1-cell border
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)

        // Every gutter cell run must start at innerX.
        let gutterRuns = runs.filter { $0.text.count == 4 }  // gutter is 4 chars
        #expect(!gutterRuns.isEmpty, "At least one 4-char gutter run must exist")
        for g in gutterRuns {
            #expect(g.col == innerX, "Gutter must start at col \(innerX) (inner left edge)")
        }
    }

    @Test("Gutter text for line 1 (non-cursor): ' ' mark + '  1' (right-justified, 3 digits)")
    func gutterLineOneFormat() {
        // Put cursor on line 1 (0-based index 1) so line 0 (1-based line 1) has
        // a blank mark and renders as '   1'.
        var (state, _) = codePaneState(code: "hello\nworld")
        state.codePane.cursorLine = 1  // cursor on second line; line 1 (1-based) is non-cursor
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // First gutter cell: blank mark + "  1" = "   1".
        let gutter = runs.first { $0.text == "   1" }
        #expect(gutter != nil, "Non-cursor line 1 gutter must be '   1' (blank mark, right-aligned number)")
    }

    @Test("Line 10: right-justified as ' 10'")
    func gutterLineTenFormat() {
        let code = (1...10).map { _ in "x" }.joined(separator: "\n")
        let (state, _) = codePaneState(code: code)
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        let gutter = runs.first { $0.text == "  10" }
        #expect(gutter != nil, "Line 10 gutter must be '  10'")
    }

    @Test("Line 100+: line number not truncated (3 chars minimum)")
    func gutterLine100Format() {
        let code = (1...100).map { _ in "x" }.joined(separator: "\n")
        var (state, _) = codePaneState(code: code)
        state.codePane.scrollOffset = 99  // jump to line 100
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // Line 100 gutter: " 100" (blank mark + "100") — still only 4 chars total
        let gutter = runs.first { $0.text == " 100" }
        #expect(gutter != nil, "Line 100 gutter must be ' 100' (mark + 3-digit number)")
    }
}

// MARK: - Scroll boundary tests

@Suite("Code pane — Scroll boundaries")
struct CodePaneScrollTests {

    @Test("j scrolls offset down by 1 and syncs cursorLine")
    func jScrollsDown() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.scrollOffset = 0
        let (next, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(next.codePane.scrollOffset == 1)
        #expect(next.codePane.cursorLine == 1)
    }

    @Test("k scrolls offset up by 1, clamped to 0")
    func kScrollsUpClamped() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.scrollOffset = 0
        let (next, _) = reduce(state, .key(.char("k"), modifiers: []))
        #expect(next.codePane.scrollOffset == 0, "k at top must not go below 0")
        #expect(next.codePane.cursorLine == 0)
    }

    @Test("g jumps to top (offset 0, cursorLine 0)")
    func gJumpsToTop() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.scrollOffset = 5
        state.codePane.cursorLine = 5
        let (next, _) = reduce(state, .key(.char("g"), modifiers: []))
        #expect(next.codePane.scrollOffset == 0)
        #expect(next.codePane.cursorLine == 0)
    }

    @Test("G jumps to large sentinel value (renderer clamps)")
    func gCapitalJumpsToBottom() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.scrollOffset = 0
        let (next, _) = reduce(state, .key(.char("G"), modifiers: []))
        #expect(next.codePane.scrollOffset > 100, "G must set a large scroll offset")
        #expect(next.codePane.cursorLine > 100)
    }

    @Test("Renderer clamps scroll beyond content length to last line")
    func rendererClampsScrollBeyondContent() {
        // 5-line source; scroll and cursor both set way beyond content.
        let code = "a\nb\nc\nd\ne"
        var (state, _) = codePaneState(code: code)
        state.codePane.scrollOffset = 1000
        // Keep cursor at 0 so it is NOT on the clamped scroll row; then the
        // last-line gutter has a blank mark ("   5") rather than a cursor mark.
        state.codePane.cursorLine = 0

        // Should not crash; render must emit gutter cells for the clamped range.
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // After clamping scrollOffset to 4 (0-based last line), only line 5 is
        // visible. Its gutter text is "   5" (blank mark + right-aligned 5).
        let lastGutter = runs.first { $0.text == "   5" }
        #expect(lastGutter != nil, "Renderer must clamp scroll and show last line gutter '   5'")
    }

    @Test("d scrolls down by halfPageSize")
    func dScrollsHalfPage() {
        var (state, _) = codePaneState(code: (1...50).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.scrollOffset = 0
        let (next, _) = reduce(state, .key(.char("d"), modifiers: []))
        #expect(next.codePane.scrollOffset == 10, "d must scroll down halfPageSize (10)")
    }

    @Test("u scrolls up by halfPageSize, clamped to 0")
    func uScrollsHalfPageUp() {
        var (state, _) = codePaneState(code: (1...50).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.scrollOffset = 5
        let (next, _) = reduce(state, .key(.char("u"), modifiers: []))
        #expect(next.codePane.scrollOffset == 0, "u from offset 5 clamped to 0 (halfPage=10)")
    }

    @Test("f scrolls down by fullPageSize")
    func fScrollsFullPage() {
        var (state, _) = codePaneState(code: (1...50).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.scrollOffset = 0
        let (next, _) = reduce(state, .key(.char("f"), modifiers: []))
        #expect(next.codePane.scrollOffset == 20, "f must scroll down fullPageSize (20)")
    }

    @Test("b scrolls up by fullPageSize, clamped to 0")
    func bScrollsFullPageUp() {
        var (state, _) = codePaneState(code: (1...50).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.scrollOffset = 10
        let (next, _) = reduce(state, .key(.char("b"), modifiers: []))
        #expect(next.codePane.scrollOffset == 0, "b from offset 10 clamped to 0 (fullPage=20)")
    }
}

// MARK: - Cursor line rendering tests

@Suite("Code pane — Cursor line rendering")
struct CodePaneCursorTests {

    @Test("Cursor line gutter contains ▶ mark in truecolor/256-color mode")
    func cursorGutterMarkTruecolor() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.cursorLine = 0
        state.theme.capability = .truecolor
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        let cursorGutter = runs.first { $0.text.hasPrefix("▶") }
        #expect(cursorGutter != nil, "Cursor line must show ▶ gutter mark in truecolor mode")
    }

    @Test("Cursor line gutter contains > mark in NO_COLOR mode")
    func cursorGutterMarkNoColor() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.cursorLine = 0
        state.theme.capability = .noColor
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // The first gutter should start with ">" in NO_COLOR mode.
        let cursorGutter = runs.first { $0.text.hasPrefix(">") }
        #expect(cursorGutter != nil, "Cursor line must show > gutter mark in NO_COLOR mode")
    }

    @Test("Non-cursor blank-mark lines use space in gutter")
    func nonCursorGutterBlank() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.cursorLine = 0  // only line 0 is cursor
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // Lines 1 and 2 (1-based 2 and 3) should have blank mark.
        let line2Gutter = runs.first { $0.text == "   2" }
        #expect(line2Gutter != nil, "Line 2 gutter must have blank mark '   2'")
    }
}

// MARK: - Gutter mark tests

@Suite("Code pane — Gutter marks (ux-spec §6.6)")
struct CodePaneGutterMarkTests {

    @Test("Error mark shows 'E' in gutter for error-severity diagnostic")
    func errorMarkCharacter() {
        var (state, id) = codePaneState(code: "a\nb\nc")
        _ = id
        // Line 2 (1-based) has an error.
        state.codePane.gutterMarks[1] = .error  // 0-based line 1
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // Gutter for line 2: "E  2" (E mark + right-aligned " 2").
        let errorGutter = runs.first { $0.text == "E  2" }
        #expect(errorGutter != nil, "Error diagnostic at line 2 must show 'E  2' in gutter")
    }

    @Test("Warning mark shows 'W' in gutter for warning-severity diagnostic")
    func warningMarkCharacter() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.gutterMarks[2] = .warning  // 0-based line 2
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        let warnGutter = runs.first { $0.text == "W  3" }
        #expect(warnGutter != nil, "Warning at line 3 must show 'W  3' in gutter")
    }

    @Test("Error takes precedence over warning when both set on same line")
    func errorPrecedenceOverWarning() {
        let (state, _) = codePaneState(code: "a\nb\nc")
        // lintFinished with both an error and warning on line 1.
        let diags = [
            Diagnostic(severity: .error, line: 1, message: "undefined", source: .luacheck),
            Diagnostic(severity: .warning, line: 1, message: "unused", source: .luacheck),
        ]
        let (next, _) = reduce(state, .lintFinished(diags))
        // gutterMarks[0] must be .error (error wins).
        #expect(next.codePane.gutterMarks[0] == .error, "Error must take precedence over warning on same line")
    }

    @Test("lintFinished sets gutter marks from diagnostics (1-based → 0-based)")
    func lintFinishedSetsGutterMarks() {
        let (state, _) = codePaneState(code: "a\nb\nc")
        let diag = Diagnostic(severity: .warning, line: 3, message: "unused var", source: .luacheck)
        let (next, _) = reduce(state, .lintFinished([diag]))
        #expect(next.codePane.gutterMarks[2] == .warning, "lintFinished line 3 → gutter mark at index 2")
    }
}

// MARK: - Inline diagnostic hover tests

@Suite("Code pane — Inline diagnostic hover (ux-spec §6.7)")
struct CodePaneHoverTests {

    /// Builds an AppState with a diagnostic at 1-based line 1, column 5.
    private func stateWithDiagAtLine1() -> AppState {
        var (state, _) = codePaneState(code: "local x = 1\nreturn x")
        state.bottomPane.diagnostics = [
            Diagnostic(
                severity: .error,
                line: 1,
                column: 5,
                message: "undefined variable 'x'",
                source: .luacheck
            )
        ]
        state.codePane.cursorLine = 0  // cursor on line 0 (1-based: 1)
        state.codePane.scrollOffset = 0
        state.codePane.gutterMarks[0] = .error
        return state
    }

    @Test("Hover row is emitted below cursor when cursor is on diagnostic line")
    func hoverRowEmitted() {
        let state = stateWithDiagAtLine1()
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // The hover row should contain "^ undefined variable 'x'" somewhere.
        let hoverRun = runs.first { $0.text.contains("^ undefined") }
        #expect(hoverRun != nil, "Hover row must appear when cursor is on diagnostic line")
    }

    @Test("Hover row appears on the terminal row immediately below the cursor line")
    func hoverRowPosition() {
        let state = stateWithDiagAtLine1()
        let layout = computeLayout(size: stdSize, paneLayout: state.paneLayout)
        let innerY = layout.codePane.y + 1  // skip top border

        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)

        // The cursor row is innerY + 0 (line 0 at top of visible area).
        // The hover row must be at innerY + 1.
        let hoverRun = runs.first { $0.text.contains("^ undefined") }
        #expect(hoverRun != nil)
        #expect(hoverRun?.row == innerY + 1, "Hover row must be one row below cursor line")
    }

    @Test("Hover text is indented to the diagnostic column (column 5 → 5 spaces)")
    func hoverTextIndentation() {
        let state = stateWithDiagAtLine1()
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // Hover text content: gutter (4 spaces) + 5 spaces indent + "^ " + message.
        // The gutter portion is spaces, not a diagnostic mark char.
        let hoverRun = runs.first { $0.text.contains("^ undefined") }
        #expect(hoverRun != nil)
        // Find the position of "^" within the run: should be at offset 4+5=9 from col.
        if let r = hoverRun {
            if let caretIdx = r.text.firstIndex(of: "^") {
                let offset = r.text.distance(from: r.text.startIndex, to: caretIdx)
                // Gutter=4 + diagnostic.column=5 = 9
                #expect(offset == 9, "Caret must be at offset 9 (gutter 4 + column 5)")
            } else {
                Issue.record("No ^ found in hover text")
            }
        }
    }

    @Test("No hover row when cursor is not on a diagnostic line")
    func noHoverOnNonDiagnosticLine() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        // Diagnostic on line 3, cursor on line 0.
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .error, line: 3, message: "err", source: .luacheck)
        ]
        state.codePane.cursorLine = 0
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        let hoverRun = runs.first { $0.text.contains("^ err") }
        #expect(hoverRun == nil, "No hover when cursor is not on diagnostic line")
    }

    @Test("Hover row is not emitted if there is no room below cursor at pane bottom")
    func noHoverAtPaneBottom() {
        // Fill the code pane with lines so the cursor is at the last visible row.
        // At 80×24: upper=14, inner height = 12.
        let code = (1...12).map { _ in "x" }.joined(separator: "\n")
        var (state, _) = codePaneState(code: code)
        // Cursor at line 11 (0-based), which is the last visible row.
        state.codePane.cursorLine = 11
        state.codePane.scrollOffset = 0
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .error, line: 12, message: "boom", source: .luacheck)
        ]
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        // No room for hover — it must not appear.
        let hoverRun = runs.first { $0.text.contains("^ boom") }
        #expect(hoverRun == nil, "Hover must not overflow pane bottom")
    }
}

// MARK: - Colon-jump command tests

@Suite("Code pane — :N<Enter> jump command (ux-spec §2.3)")
struct CodePaneColonJumpTests {

    @Test("Typing : sets colonCommand to empty string")
    func colonStartsCommand() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.focus = .pane(.codePane)
        let (next, _) = reduce(state, .key(.char(":"), modifiers: []))
        #expect(next.codePane.colonCommand == "", "After : colonCommand must be ''")
    }

    @Test("Digits are accumulated in colonCommand")
    func digitsAccumulate() {
        var (state, _) = codePaneState(code: (1...20).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.colonCommand = ""  // command already active

        var s = state
        (s, _) = reduce(s, .key(.char("1"), modifiers: []))
        (s, _) = reduce(s, .key(.char("5"), modifiers: []))
        #expect(s.codePane.colonCommand == "15", "Digits 1 and 5 must accumulate to '15'")
    }

    @Test(":5<Enter> jumps cursor to line 5 (1-based)")
    func colonJumpToLine5() {
        var (state, _) = codePaneState(code: (1...20).map { "\($0)" }.joined(separator: "\n"))
        state.codePane.colonCommand = ""
        state.codePane.cursorLine = 0

        var s = state
        (s, _) = reduce(s, .key(.char("5"), modifiers: []))
        (s, _) = reduce(s, .key(.enter, modifiers: []))

        // Line 5 (1-based) → cursor at index 4 (0-based).
        #expect(s.codePane.cursorLine == 4, ":5<Enter> must jump to cursorLine 4 (0-based)")
        #expect(s.codePane.scrollOffset == 4)
        #expect(s.codePane.colonCommand == nil, "colonCommand must be cleared after jump")
    }

    @Test(":1<Enter> jumps to first line")
    func colonJumpToLine1() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.colonCommand = ""
        state.codePane.scrollOffset = 2

        var s = state
        (s, _) = reduce(s, .key(.char("1"), modifiers: []))
        (s, _) = reduce(s, .key(.enter, modifiers: []))
        #expect(s.codePane.cursorLine == 0)
        #expect(s.codePane.scrollOffset == 0)
    }

    @Test("Empty :Enter does nothing (no crash, command cleared)")
    func colonEmptyEnter() {
        var (state, _) = codePaneState(code: "a\nb")
        state.codePane.colonCommand = ""
        state.codePane.scrollOffset = 1

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.codePane.colonCommand == nil, "Empty :Enter must clear colonCommand")
        #expect(next.codePane.scrollOffset == 1, "Empty :Enter must not change scroll offset")
    }

    @Test(":Esc cancels command without jumping")
    func colonEscCancels() {
        var (state, _) = codePaneState(code: "a\nb\nc")
        state.codePane.colonCommand = "7"
        state.codePane.cursorLine = 0

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.codePane.colonCommand == nil, "Esc must clear colonCommand")
        #expect(next.codePane.cursorLine == 0, "Esc must not move the cursor")
    }

    @Test(":q shows 'use q to quit' transient (ux-spec §2.3 exact string)")
    func colonQShowsTransient() {
        var (state, _) = codePaneState(code: "a")
        state.codePane.colonCommand = ""

        let (next, _) = reduce(state, .key(.char("q"), modifiers: []))
        #expect(next.codePane.colonCommand == nil, ":q must clear the command")
        #expect(next.transient?.text == "use q to quit", ":q transient must match ux-spec exact string")
    }

    @Test("Non-digit character cancels colon command silently")
    func nonDigitCancelsCommand() {
        var (state, _) = codePaneState(code: "a\nb")
        state.codePane.colonCommand = "3"

        let (next, _) = reduce(state, .key(.char("x"), modifiers: []))
        #expect(next.codePane.colonCommand == nil, "Non-digit must cancel colonCommand")
    }
}

// MARK: - Diagnostic navigation tests

@Suite("Code pane — Diagnostic navigation (n/N/[d/]d, ux-spec §2.3)")
struct CodePaneDiagNavTests {

    /// Returns a state with diagnostics at lines 3, 7, and 12.
    private func stateWithThreeDiags() -> AppState {
        var (state, _) = codePaneState(code: (1...20).map { "\($0)" }.joined(separator: "\n"))
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .error, line: 3, message: "e1", source: .luacheck),
            Diagnostic(severity: .warning, line: 7, message: "w1", source: .luacheck),
            Diagnostic(severity: .error, line: 12, message: "e2", source: .luacheck),
        ]
        return state
    }

    @Test("[d jumps to first diagnostic (line 3)")
    func firstDiagnosticJump() {
        let state = stateWithThreeDiags()
        let (next, _) = reduce(state, .key(.char("["), modifiers: []))
        #expect(next.codePane.cursorLine == 2, "[d must jump to line 3 (0-based index 2)")
        #expect(next.codePane.diagnosticIndex == 0)
    }

    @Test("]d jumps to last diagnostic (line 12)")
    func lastDiagnosticJump() {
        let state = stateWithThreeDiags()
        let (next, _) = reduce(state, .key(.char("]"), modifiers: []))
        #expect(next.codePane.cursorLine == 11, "]d must jump to line 12 (0-based index 11)")
        #expect(next.codePane.diagnosticIndex == 2)
    }

    @Test("n advances to next diagnostic with wrap-around")
    func nextDiagnosticWraps() {
        var state = stateWithThreeDiags()
        state.codePane.diagnosticIndex = 2  // currently at last (line 12)

        let (next, _) = reduce(state, .key(.char("n"), modifiers: []))
        // Wrap around to first (line 3, index 0).
        #expect(next.codePane.diagnosticIndex == 0, "n must wrap from last to first diagnostic")
        #expect(next.codePane.cursorLine == 2)
    }

    @Test("N goes to previous diagnostic with wrap-around")
    func prevDiagnosticWraps() {
        var state = stateWithThreeDiags()
        state.codePane.diagnosticIndex = 0  // currently at first (line 3)

        let (next, _) = reduce(state, .key(.char("N"), modifiers: []))
        // Wrap around to last (line 12, index 2).
        #expect(next.codePane.diagnosticIndex == 2, "N must wrap from first to last diagnostic")
        #expect(next.codePane.cursorLine == 11)
    }

    @Test("n on first call (diagnosticIndex nil) starts at index 0")
    func nFirstCallStartsAtZero() {
        var state = stateWithThreeDiags()
        state.codePane.diagnosticIndex = nil  // unset

        let (next, _) = reduce(state, .key(.char("n"), modifiers: []))
        #expect(next.codePane.diagnosticIndex == 0, "First n must go to index 0")
        #expect(next.codePane.cursorLine == 2)
    }

    @Test("N on first call (diagnosticIndex nil) wraps to last")
    func nCapitalFirstCallWrapsToLast() {
        var state = stateWithThreeDiags()
        state.codePane.diagnosticIndex = nil

        let (next, _) = reduce(state, .key(.char("N"), modifiers: []))
        // For N with nil, the formula is (0 - 1 + 3) % 3 = 2.
        #expect(next.codePane.diagnosticIndex == 2)
        #expect(next.codePane.cursorLine == 11)
    }

    @Test("n/N are no-ops when no diagnostics are present")
    func nNoOpWithNoDiags() {
        var (state, _) = codePaneState(code: "a")
        state.bottomPane.diagnostics = []
        state.codePane.scrollOffset = 0

        let (next, _) = reduce(state, .key(.char("n"), modifiers: []))
        #expect(next.codePane.scrollOffset == 0, "n with no diagnostics must not move the cursor")
    }

    @Test("diagnosticIndex is reset when a new source is selected")
    func diagnosticIndexResetOnSourceChange() {
        var state = stateWithThreeDiags()
        state.codePane.diagnosticIndex = 2

        // Add a second source and select it via navigator.
        let id2 = SourceID(path: "other.lua")
        state.sources[id2] = .loaded(makeFragment(code: "x", path: "other.lua"))
        state.navigatorOrder.append(id2)
        state.navigator.selectedIndex = 1  // select the second source
        state.focus = .pane(.navigator)

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.codePane.diagnosticIndex == nil, "diagnosticIndex must reset on source change")
    }
}

// MARK: - Highlight batching contract tests

@Suite("Code pane — Syntax highlight batching (no per-cell runs)")
struct CodePaneHighlightBatchingTests {

    @Test("Each cellRun covers a contiguous same-style run (no single-char runs for a plain line)")
    func plainLineNotPerCell() {
        // A plain 10-char line with no highlight spans must produce one content
        // cellRun (the whole line as one run) — not 10 per-character runs.
        let code = "helloworld"  // single line, 10 chars
        let (state, _) = codePaneState(code: code)
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)

        // Filter to runs in the code content area (not gutter).
        let layout = computeLayout(size: stdSize, paneLayout: state.paneLayout)
        let innerX = layout.codePane.x + 1  // border
        let gutterWidth: UInt16 = 4
        let contentX = innerX + gutterWidth

        let contentRuns = runs.filter { $0.col == contentX }
        // Plain line should produce exactly 1 content run.
        #expect(contentRuns.count == 1, "Plain line must produce exactly 1 content cellRun (batching contract)")
        #expect(contentRuns.first?.text == "helloworld")
    }

    @Test("Highlight spans produce at most ceil(lineLen/spanLen) runs")
    func highlightSpansAreBatched() {
        // A 10-char line with one highlight span covering chars 0–4.
        // Expected: 2 runs (span + tail), not 10.
        let code = "helloworld"
        var (state, id) = codePaneState(code: code)
        state.highlight[id] = [
            HighlightSpan(line: 0, column: 0, length: 5, tokenKind: .keyword)
        ]

        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)
        let layout = computeLayout(size: stdSize, paneLayout: state.paneLayout)
        let innerX = layout.codePane.x + 1
        let gutterWidth: UInt16 = 4
        let contentX = innerX + gutterWidth

        let contentRuns = runs.filter { $0.col >= contentX }
        // 2 runs expected: "hello" (keyword) + "world" (normal).
        #expect(contentRuns.count == 2, "One highlight span on 10-char line must produce exactly 2 content runs")
        #expect(contentRuns[0].text == "hello")
        #expect(contentRuns[1].text == "world")
    }
}

// MARK: - Snapshot geometry test

@Suite("Code pane — Snapshot geometry")
struct CodePaneSnapshotTests {

    @Test("Short source (3 lines) at 80x24: exactly 3 gutter cells emitted")
    func threeLineGutterCount() {
        let code = "a\nb\nc"
        let (state, _) = codePaneState(code: code)
        let cmds = render(state, size: stdSize)
        let runs = cellRuns(cmds)

        // Gutter cells are 4 chars wide; count those whose text length is 4.
        let gutterCells = runs.filter { $0.text.count == 4 }
        // Lines "   1", "   2", "   3" — plus cursor "▶  1" at row 0.
        // Actually line 1 is cursor, so "▶  1" (4 chars), "   2", "   3".
        #expect(
            gutterCells.count == 3,
            "3-line source must produce exactly 3 gutter cell runs (one per visible line)"
        )
    }

    @Test("Render at 100x40: more visible lines")
    func renderAt100x40() {
        // Upper zone at 100×40: usable=38, upper=round(38×0.65)=25, inner=23 rows.
        let code = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let (state, _) = codePaneState(code: code)
        let size = TerminalSize(cols: 100, rows: 40)
        let cmds = render(state, size: size)
        let runs = cellRuns(cmds)

        // Every visible row should have a gutter. inner height = 25 - 2 = 23.
        let gutterCells = runs.filter { $0.text.count == 4 }
        // Plus the cursor row which may be "▶  1" (also 4 chars).
        #expect(gutterCells.count >= 23, "At 100×40, at least 23 visible rows must each emit a gutter cell")
    }
}
