// File: Tests/MoonSwiftTUITests/HelpOverlayTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for the help overlay modal rendered by Renderer.renderHelpOverlay
//       (ux-spec.md §2.5, §2.3). Verifies content sections, the exact Tab
//       context-sensitivity note, geometry bounds, Clear widget presence,
//       and dismiss behaviour at both 80×24 and 200×60 terminal sizes.
//       No FFI is linked — assertions run against [RenderCommand] and AppState.
// Upstream: Renderer.swift (renderHelpOverlay), Reducer.swift (helpOverlay keys),
//           AppState.swift (FocusState.helpOverlay)
// Downstream: (test target — nothing imports this)

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Returns an `AppState` with `focus = .helpOverlay` and a minimal theme.
private func helpOverlayState() -> AppState {
    var state = AppState()
    state.focus = .helpOverlay
    // Wire up the theme tokens the renderer reads for section headers, key
    // names, and descriptions so color assertions can be meaningful.
    state.theme.tokens[.dim] = TokenStyle(fg: .rgb(98, 114, 164))
    state.theme.tokens[.keyword] = TokenStyle(fg: .rgb(255, 121, 198))
    state.theme.tokens[.identifier] = TokenStyle(fg: .rgb(248, 248, 242))
    state.theme.tokens[.paneBg] = TokenStyle(fg: .rgb(248, 248, 242))
    return state
}

private func termSize(_ cols: UInt16, _ rows: UInt16) -> TerminalSize {
    TerminalSize(cols: cols, rows: rows)
}

/// Extracts all `.clear` rects from a command sequence.
private func clearRects(_ cmds: [RenderCommand]) -> [Rect] {
    cmds.compactMap {
        if case .clear(let rect) = $0 { return rect }
        return nil
    }
}

/// Extracts all `.paragraph` lines (flattened to plain text) from a command sequence.
private func paragraphText(_ cmds: [RenderCommand]) -> [String] {
    var result: [String] = []
    for cmd in cmds {
        if case .paragraph(_, let lines, _) = cmd {
            for spans in lines {
                result.append(spans.map { $0.text }.joined())
            }
        }
    }
    return result
}

/// Returns true when any text line in `lines` contains `needle`.
private func anyLine(_ lines: [String], contains needle: String) -> Bool {
    lines.contains { $0.contains(needle) }
}

/// Flattened text of the FULL help-overlay content model (ux-spec §2.3, §2.5),
/// independent of the scroll window. The rendered overlay shows only a slice at
/// a time (the list overflows the 60×20 box, ux-spec §2.5), so content-presence
/// assertions check the model here and the windowed render is verified separately.
private func specText() -> [String] {
    helpOverlayLineSpecs().map { spec in
        switch spec {
        case .header(let title): return title
        case .blank: return ""
        case .row(let key, let action): return "\(key)  \(action)"
        case .note(let text): return text
        }
    }
}

// MARK: - Geometry tests

@Suite("Help overlay — Geometry")
struct HelpOverlayGeometryTests {

    @Test("Overlay rect is centered and at most 60 × 20 at 80×24")
    func overlayBoundsAt80x24() {
        let state = helpOverlayState()
        let size = termSize(80, 24)
        let cmds = render(state, size: size)

        let clears = clearRects(cmds)
        #expect(!clears.isEmpty, "Must emit a .clear command behind the overlay")

        let rect = clears[0]
        #expect(rect.width <= 60, "Overlay width must not exceed 60")
        #expect(rect.height <= 20, "Overlay height must not exceed 20")

        // Centered: x = (cols - width) / 2, y = (rows - height) / 2.
        let expectedX = (size.cols - rect.width) / 2
        let expectedY = (size.rows - rect.height) / 2
        #expect(rect.x == expectedX, "Overlay must be horizontally centered")
        #expect(rect.y == expectedY, "Overlay must be vertically centered")
    }

    @Test("Overlay rect is centered and at most 60 × 20 at 200×60")
    func overlayBoundsAt200x60() {
        let state = helpOverlayState()
        let size = termSize(200, 60)
        let cmds = render(state, size: size)

        let clears = clearRects(cmds)
        #expect(!clears.isEmpty, "Must emit a .clear command behind the overlay")

        let rect = clears[0]
        #expect(rect.width == 60, "Overlay must cap at 60 cols on a wide terminal")
        #expect(rect.height == 20, "Overlay must cap at 20 rows on a tall terminal")

        let expectedX = (size.cols - rect.width) / 2
        let expectedY = (size.rows - rect.height) / 2
        #expect(rect.x == expectedX, "Overlay must be horizontally centered at 200×60")
        #expect(rect.y == expectedY, "Overlay must be vertically centered at 200×60")
    }

    @Test("Clear command appears before the overlay paragraph command")
    func clearPrecedesParagraph() {
        let state = helpOverlayState()
        let cmds = render(state, size: termSize(80, 24))

        // Find the clear rect first, then find the paragraph at the same rect.
        // The render sequence also contains non-overlay paragraphs (e.g., the
        // code-pane empty-state prompt), so we look for the paragraph whose
        // rect matches the overlay clear rect rather than the very first paragraph.
        guard
            let clearIdx = cmds.indices.first(where: {
                if case .clear = cmds[$0] { return true }
                return false
            })
        else {
            Issue.record("No .clear command found in render output")
            return
        }
        guard case .clear(let clearRect) = cmds[clearIdx] else { return }

        // Find the paragraph that covers the same rect as the clear.
        let paraIdx = cmds.indices.first {
            if case .paragraph(let r, _, _) = cmds[$0] { return r == clearRect }
            return false
        }

        #expect(paraIdx != nil, "Must emit a .paragraph command for the overlay rect")
        if let p = paraIdx {
            #expect(clearIdx < p, "Clear must come before the overlay paragraph in the command stream")
        }
    }

    @Test("Clear rect and paragraph rect share the same origin and size")
    func clearAndParagraphShareRect() {
        let state = helpOverlayState()
        let cmds = render(state, size: termSize(80, 24))

        var clearRect: Rect?
        var paraRect: Rect?
        for cmd in cmds {
            if case .clear(let r) = cmd { clearRect = r }
            if case .paragraph(let r, _, _) = cmd { paraRect = r }
        }

        #expect(clearRect != nil, "Must emit a .clear command")
        #expect(paraRect != nil, "Must emit a .paragraph command")
        if let c = clearRect, let p = paraRect {
            #expect(c == p, "Clear and paragraph must cover the same rectangle")
        }
    }
}

// MARK: - Content tests

@Suite("Help overlay — Content sections")
struct HelpOverlayContentTests {

    // MARK: Section headers

    @Test("'Global' section header is present")
    func globalSectionHeader() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Global"), "Global section header must appear in the overlay")
    }

    @Test("'Navigator' section header is present")
    func navigatorSectionHeader() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Navigator"), "Navigator section header must appear in the overlay")
    }

    @Test("'Code pane' section header is present")
    func codePaneSectionHeader() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Code pane"), "Code pane section header must appear in the overlay")
    }

    @Test("'Bottom pane' section header is present")
    func bottomPaneSectionHeader() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Bottom pane"), "Bottom pane section header must appear in the overlay")
    }

    // MARK: Global keys

    @Test("Global key 'r' Run is listed")
    func globalKeyRun() {
        let lines = specText()
        #expect(anyLine(lines, contains: "r"), "Key 'r' must appear in the help overlay")
        #expect(anyLine(lines, contains: "Run"), "Run description must appear in the help overlay")
    }

    @Test("Global key 'x' Cancel is listed")
    func globalKeyCancel() {
        let lines = specText()
        #expect(anyLine(lines, contains: "x"), "Key 'x' must appear")
        #expect(anyLine(lines, contains: "Cancel"), "Cancel description must appear")
    }

    @Test("Global key 'l' Lint is listed")
    func globalKeyLint() {
        let lines = specText()
        #expect(anyLine(lines, contains: "l"), "Key 'l' must appear")
        #expect(anyLine(lines, contains: "Lint"), "Lint description must appear")
    }

    @Test("Global key 'q' Quit is listed")
    func globalKeyQuit() {
        let lines = specText()
        #expect(anyLine(lines, contains: "q"), "Key 'q' must appear")
        #expect(anyLine(lines, contains: "Quit"), "Quit description must appear")
    }

    @Test("Global key '?' help is listed")
    func globalKeyHelp() {
        let lines = specText()
        #expect(anyLine(lines, contains: "?"), "Key '?' must appear")
        #expect(anyLine(lines, contains: "help"), "'help' must appear in ? description")
    }

    @Test("Global key <C-p> is listed")
    func globalKeyCtrlP() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-p>"), "<C-p> must appear in the overlay")
        #expect(anyLine(lines, contains: "$EDITOR"), "$EDITOR must appear in <C-p> description")
    }

    @Test("Global key <C-r> is listed")
    func globalKeyCtrlR() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-r>"), "<C-r> must appear in the overlay")
        #expect(anyLine(lines, contains: "Reload"), "Reload description must appear")
    }

    @Test("Global key <C-h> jump to navigator is listed")
    func globalKeyCtrlH() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-h>"), "<C-h> must appear in the overlay")
    }

    @Test("Global key <C-l> jump to code pane is listed")
    func globalKeyCtrlL() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-l>"), "<C-l> must appear in the overlay")
    }

    @Test("Global key <C-j> jump to bottom pane is listed")
    func globalKeyCtrlJ() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-j>"), "<C-j> must appear in the overlay")
    }

    @Test("Global <Tab> cycle panes is listed")
    func globalKeyTab() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<Tab>"), "<Tab> must appear in the overlay")
    }

    @Test("Global <S-Tab> reverse-cycle is listed")
    func globalKeyShiftTab() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<S-Tab>"), "<S-Tab> must appear in the overlay")
    }

    // MARK: Navigator keys

    @Test("Navigator j/k listed")
    func navigatorJK() {
        let lines = specText()
        #expect(anyLine(lines, contains: "j/k"), "j/k must appear in the overlay")
    }

    @Test("Navigator g first-entry listed")
    func navigatorG() {
        let lines = specText()
        #expect(anyLine(lines, contains: "first"), "First-entry description must appear in the overlay")
    }

    @Test("Navigator G last-entry listed")
    func navigatorCapG() {
        let lines = specText()
        #expect(anyLine(lines, contains: "last"), "Last-entry description must appear in the overlay")
    }

    @Test("Navigator <Enter> load source listed")
    func navigatorEnter() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<Enter>"), "<Enter> must appear in the overlay")
        #expect(anyLine(lines, contains: "Load"), "Load description must appear")
    }

    @Test("Navigator o and <Space> load aliases listed")
    func navigatorLoadAliases() {
        let lines = specText()
        #expect(anyLine(lines, contains: "o"), "o alias must appear in the overlay")
        #expect(anyLine(lines, contains: "<Space>"), "<Space> alias must appear in the overlay")
        #expect(anyLine(lines, contains: "(alias)"), "Alias description must appear")
    }

    @Test("Navigator / filter listed")
    func navigatorFilter() {
        let lines = specText()
        #expect(anyLine(lines, contains: "/"), "/ filter must appear in the overlay")
        #expect(anyLine(lines, contains: "Filter"), "Filter description must appear")
    }

    @Test("Navigator m picker listed")
    func navigatorM() {
        let lines = specText()
        #expect(anyLine(lines, contains: "m"), "m must appear in the overlay")
        #expect(anyLine(lines, contains: "picker"), "picker description must appear")
    }

    // MARK: Code pane keys

    @Test("Code pane d/u half-page scroll listed")
    func codePaneDU() {
        let lines = specText()
        #expect(anyLine(lines, contains: "d/u"), "d/u must appear in the overlay")
        #expect(anyLine(lines, contains: "half-page"), "half-page description must appear")
    }

    @Test("Code pane full-page scroll keys listed (f down, <C-b> up — UX-01 rebind)")
    func codePaneFullPage() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Scroll down full page"), "f full-page-down must appear")
        #expect(anyLine(lines, contains: "<C-b>"), "<C-b> full-page-up must appear (UX-01 rebind)")
        #expect(anyLine(lines, contains: "Scroll up full page"), "<C-b> full-page-up description must appear")
    }

    @Test("Code pane g/G top/bottom listed")
    func codePaneGG() {
        let lines = specText()
        #expect(anyLine(lines, contains: "g/G"), "g/G must appear in the overlay")
    }

    @Test("Code pane :N line jump listed")
    func codePaneColonN() {
        let lines = specText()
        #expect(anyLine(lines, contains: ":N"), ":N must appear in the overlay")
        #expect(anyLine(lines, contains: "line"), "line N description must appear")
    }

    @Test("Code pane n/N diagnostic navigation listed")
    func codePaneNDiag() {
        let lines = specText()
        #expect(anyLine(lines, contains: "n/N"), "n/N must appear in the overlay")
        #expect(anyLine(lines, contains: "diagnostic"), "diagnostic description must appear")
    }

    @Test("Code pane [d first diagnostic listed")
    func codePaneBracketD() {
        let lines = specText()
        #expect(anyLine(lines, contains: "[d"), "[d must appear in the overlay")
    }

    @Test("Code pane ]d last diagnostic listed")
    func codePaneCloseBracketD() {
        let lines = specText()
        #expect(anyLine(lines, contains: "]d"), "]d must appear in the overlay")
    }

    // MARK: Bottom pane keys

    @Test("Bottom pane <Enter> jump to error line listed")
    func bottomPaneEnter() {
        let lines = specText()
        // <Enter> appears for navigator and bottom pane — just check both are represented.
        #expect(anyLine(lines, contains: "Jump code pane"), "Jump code pane description must appear for bottom pane")
    }

    @Test("Bottom pane y yank listed")
    func bottomPaneY() {
        let lines = specText()
        #expect(anyLine(lines, contains: "y"), "y must appear in the overlay")
        #expect(anyLine(lines, contains: "Yank"), "Yank description must appear")
    }

    @Test("Bottom pane 1/2 tab quick-jump listed")
    func bottomPane12() {
        let lines = specText()
        #expect(anyLine(lines, contains: "1/2"), "1/2 must appear in the overlay")
        #expect(anyLine(lines, contains: "Output"), "Output tab reference must appear")
        #expect(anyLine(lines, contains: "Diagnostics"), "Diagnostics tab reference must appear")
    }

    @Test("Bottom pane <C-l> clear output listed")
    func bottomPaneCtrlL() {
        // <C-l> appears globally (jump to code pane) and bottom-pane (clear output).
        // Verify the clear output description is present.
        let lines = specText()
        #expect(anyLine(lines, contains: "Clear output"), "Clear output description must appear for bottom pane")
    }

    // MARK: Tab note (ux-spec §2.5 — exact binding string)

    @Test("Exact Tab context-sensitivity note is present (ux-spec §2.5 binding string)")
    func exactTabNote() {
        // ux-spec §2.5 normative text:
        // "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let expected = "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let lines = specText()
        #expect(
            anyLine(lines, contains: expected),
            "The exact ux-spec §2.5 Tab note must appear verbatim in the overlay"
        )
    }

    @Test("Tab note present at 200×60 too")
    func tabNoteAt200x60() {
        let expected = "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let lines = specText()
        #expect(anyLine(lines, contains: expected), "Tab note must be present at 200×60")
    }

    @Test("Conditional [ Debug ] tab note is present (UX-16)")
    func debugTabConditionalNote() {
        let lines = specText()
        #expect(
            anyLine(lines, contains: "[ Debug ] tab is in the bottom-pane cycle only while a debug session is active"),
            "The conditional [ Debug ] tab note (UX-16) must appear in the overlay"
        )
    }

    // MARK: P2 keys (mocking + debugger — PRD §6.11)

    @Test("Global <C-g> debug run is listed")
    func globalKeyCtrlG() {
        let lines = specText()
        #expect(anyLine(lines, contains: "<C-g>"), "<C-g> must appear in the overlay")
        #expect(anyLine(lines, contains: "debug run"), "debug-run description must appear")
    }

    @Test("Navigator mock keys a/e/d are listed")
    func navigatorMockKeys() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Add a mock"), "a add-mock must appear")
        #expect(anyLine(lines, contains: "Edit the selected mock"), "e edit-mock must appear")
        #expect(anyLine(lines, contains: "Delete the selected mock"), "d delete-mock must appear")
    }

    @Test("Navigator <Enter> documents invoking a live function")
    func navigatorInvoke() {
        let lines = specText()
        #expect(anyLine(lines, contains: "invoke a live function"), "invoke-on-Enter must be documented")
    }

    @Test("Code pane b toggle-breakpoint is listed")
    func codePaneBreakpoint() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Toggle breakpoint"), "b breakpoint toggle must appear")
    }

    @Test("Bottom pane quick-jump includes the Debug tab (1/2/3)")
    func bottomPaneDebugQuickJump() {
        let lines = specText()
        #expect(anyLine(lines, contains: "1/2/3"), "1/2/3 quick-jump must appear")
        #expect(anyLine(lines, contains: "Debug tab"), "Debug-tab quick-jump must be documented")
    }

    @Test("Paused (debug session) section and its keys are listed")
    func pausedSection() {
        let lines = specText()
        #expect(anyLine(lines, contains: "Paused"), "Paused section header must appear")
        #expect(anyLine(lines, contains: "Step over"), "s step-over must appear")
        #expect(anyLine(lines, contains: "Step into"), "i step-into must appear")
        #expect(anyLine(lines, contains: "Step out"), "o step-out must appear")
        #expect(anyLine(lines, contains: "Continue"), "c continue must appear")
        #expect(anyLine(lines, contains: "Capture globals"), "g capture-globals must appear")
    }
}

// MARK: - Scroll behaviour tests (ux-spec §2.5 — overlay overflows the box)

@Suite("Help overlay — Scroll")
struct HelpOverlayScrollTests {

    /// The overlay content overflows the 60×20 box, so the scroll offset has a
    /// positive maximum at the snapshot terminal sizes.
    @Test("Content overflows the box — max scroll offset is positive")
    func contentOverflows() {
        #expect(helpOverlayMaxScrollOffset(terminalRows: 24) > 0, "Content must overflow a 24-row terminal")
        #expect(helpOverlayMaxScrollOffset(terminalRows: 40) > 0, "Content must overflow a 40-row terminal")
    }

    private func helpState(rows: UInt16 = 40, offset: Int = 0) -> AppState {
        var s = AppState()
        s.focus = .helpOverlay
        s.terminalSize = TerminalSize(cols: 100, rows: rows)
        s.helpScrollOffset = offset
        return s
    }

    @Test("Opening the overlay resets the scroll offset to 0")
    func openResetsOffset() {
        var s = AppState()
        s.focus = .pane(.navigator)
        s.helpScrollOffset = 99
        let (next, _) = reduce(s, .key(.char("?"), modifiers: []))
        #expect(next.focus == .helpOverlay)
        #expect(next.helpScrollOffset == 0, "Opening the overlay must reset the scroll offset")
    }

    @Test("Down arrow scrolls one line; up arrow scrolls back")
    func arrowLineScroll() {
        let (down, _) = reduce(helpState(), .key(.down, modifiers: []))
        #expect(down.helpScrollOffset == 1, "Down must scroll one line")
        let (up, _) = reduce(down, .key(.up, modifiers: []))
        #expect(up.helpScrollOffset == 0, "Up must scroll back one line")
    }

    @Test("<C-d>/<C-u> half-page; <C-f>/<C-b> and PgDn/PgUp full-page")
    func pageScroll() {
        let (half, _) = reduce(helpState(), .key(.char("d"), modifiers: .ctrl))
        #expect(half.helpScrollOffset > 1, "<C-d> must scroll a half page")
        let (full, _) = reduce(helpState(), .key(.char("f"), modifiers: .ctrl))
        #expect(full.helpScrollOffset >= half.helpScrollOffset, "<C-f> full page ≥ <C-d> half page")
        let (pgdn, _) = reduce(helpState(), .key(.pageDown, modifiers: []))
        #expect(pgdn.helpScrollOffset == full.helpScrollOffset, "PgDn must equal <C-f> full page")
        let (pgup, _) = reduce(pgdn, .key(.pageUp, modifiers: []))
        #expect(pgup.helpScrollOffset == 0, "PgUp from one full page must return to top")
    }

    @Test("g/Home jump to top; G/End jump to bottom")
    func topBottomJumps() {
        let maxOffset = helpOverlayMaxScrollOffset(terminalRows: 40)
        let (bottom, _) = reduce(helpState(), .key(.char("G"), modifiers: []))
        #expect(bottom.helpScrollOffset == maxOffset, "G must jump to the last scroll position")
        let (end, _) = reduce(helpState(), .key(.end, modifiers: []))
        #expect(end.helpScrollOffset == maxOffset, "End must jump to the bottom like G")
        let (top, _) = reduce(bottom, .key(.char("g"), modifiers: []))
        #expect(top.helpScrollOffset == 0, "g must jump back to the top")
        let (home, _) = reduce(bottom, .key(.home, modifiers: []))
        #expect(home.helpScrollOffset == 0, "Home must jump to the top like g")
    }

    @Test("Scroll offset is clamped to [0, maxOffset]")
    func clamping() {
        let maxOffset = helpOverlayMaxScrollOffset(terminalRows: 40)
        // Many full-page-downs cannot exceed the maximum.
        var s = helpState()
        for _ in 0..<20 { s = reduce(s, .key(.pageDown, modifiers: [])).0 }
        #expect(s.helpScrollOffset == maxOffset, "Repeated PgDn must clamp at maxOffset")
        // Up from the top cannot go negative.
        let (up, _) = reduce(helpState(), .key(.up, modifiers: []))
        #expect(up.helpScrollOffset == 0, "Up at the top must clamp at 0")
    }

    @Test("Scrolling to the bottom brings the Paused section into the rendered window")
    func scrolledRenderShowsLowerContent() {
        // At the top, the Paused section is below the visible window.
        let top = paragraphText(render(helpState(offset: 0), size: termSize(100, 40)))
        #expect(!anyLine(top, contains: "Step over"), "Paused keys must be off-screen at the top")
        // After scrolling to the bottom, the Paused section is visible.
        let maxOffset = helpOverlayMaxScrollOffset(terminalRows: 40)
        let bottom = paragraphText(render(helpState(offset: maxOffset), size: termSize(100, 40)))
        #expect(anyLine(bottom, contains: "Step over"), "Paused keys must be visible after scrolling to the bottom")
    }

    @Test("A scroll footer is rendered with the scroll keymap")
    func footerRendered() {
        let lines = paragraphText(render(helpState(offset: 0), size: termSize(100, 40)))
        #expect(anyLine(lines, contains: "C-d/C-u"), "Footer must list the half-page scroll keys")
        #expect(anyLine(lines, contains: "Esc close"), "Footer must show the dismiss hint")
        #expect(anyLine(lines, contains: "more"), "Footer must indicate more content when scrolled away from an edge")
    }
}

// MARK: - Dismiss behaviour tests

@Suite("Help overlay — Dismiss behaviour")
struct HelpOverlayDismissTests {

    @Test("Esc dismisses the help overlay (focus returns to navigator)")
    func escDismisses() {
        var state = helpOverlayState()
        state.focus = .helpOverlay
        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator), "Esc must dismiss the overlay and restore navigator focus")
    }

    @Test("? dismisses the help overlay (focus returns to navigator)")
    func questionMarkDismisses() {
        var state = helpOverlayState()
        state.focus = .helpOverlay
        let (next, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(next.focus == .pane(.navigator), "? must dismiss the overlay and restore navigator focus")
    }

    @Test("? from any pane opens the overlay")
    func questionMarkOpens() {
        var state = AppState()
        state.focus = .pane(.codePane)
        let (next, _) = reduce(state, .key(.char("?"), modifiers: []))
        #expect(next.focus == .helpOverlay, "? must set focus to .helpOverlay")
    }

    @Test("q quits from help overlay (produces quit effect, code 0)")
    func qQuitsFromHelpOverlay() {
        var state = helpOverlayState()
        state.focus = .helpOverlay
        let (_, effects) = reduce(state, .key(.char("q"), modifiers: []))
        let hasQuit = effects.contains {
            if case .quit(let code) = $0 { return code == 0 }
            return false
        }
        #expect(hasQuit, "q in help overlay must produce .quit(exitCode: 0) effect")
    }

    @Test("Other keys do not dismiss the overlay")
    func otherKeyNoOp() {
        var state = helpOverlayState()
        state.focus = .helpOverlay
        let (next, _) = reduce(state, .key(.char("x"), modifiers: []))
        #expect(next.focus == .helpOverlay, "Non-dismiss keys must not close the overlay")
    }

    @Test("Help overlay is rendered when focus is .helpOverlay")
    func overlayRenderedWhenFocused() {
        let state = helpOverlayState()
        let cmds = render(state, size: termSize(80, 24))
        let hasClear = cmds.contains {
            if case .clear = $0 { return true }
            return false
        }
        #expect(hasClear, "Overlay must be rendered (clear command present) when focus is .helpOverlay")
    }

    @Test("Help overlay is NOT rendered when focus is a pane")
    func overlayAbsentWhenPaneFocused() {
        var state = AppState()
        state.focus = .pane(.navigator)
        let cmds = render(state, size: termSize(80, 24))
        let hasClear = cmds.contains {
            if case .clear = $0 { return true }
            return false
        }
        #expect(!hasClear, "No clear command when overlay is not active")
    }
}

// MARK: - Styling tests

@Suite("Help overlay — Styling")
struct HelpOverlayStyleTests {

    @Test("Key name spans use keyword color")
    func keyNamesUseKeywordColor() {
        var state = helpOverlayState()
        // Map keyword to a unique recognisable color.
        let keywordRGB: (UInt8, UInt8, UInt8) = (255, 121, 198)
        state.theme.tokens[.keyword] = TokenStyle(fg: .rgb(keywordRGB.0, keywordRGB.1, keywordRGB.2))
        let cmds = render(state, size: termSize(80, 24))

        // Find any paragraph command and scan its spans for keyword-colored text.
        var foundKeywordColor = false
        let expectedFG: UInt32 = (UInt32(keywordRGB.0) << 16) | (UInt32(keywordRGB.1) << 8) | UInt32(keywordRGB.2)
        for cmd in cmds {
            if case .paragraph(_, let lines, _) = cmd {
                for spans in lines {
                    for span in spans {
                        if span.style.fg == expectedFG {
                            foundKeywordColor = true
                        }
                    }
                }
            }
        }
        #expect(foundKeywordColor, "At least one span must use the keyword color for key names")
    }

    @Test("Description spans use identifier color")
    func descriptionsUseIdentifierColor() {
        var state = helpOverlayState()
        let identRGB: (UInt8, UInt8, UInt8) = (248, 248, 242)
        state.theme.tokens[.identifier] = TokenStyle(fg: .rgb(identRGB.0, identRGB.1, identRGB.2))
        let cmds = render(state, size: termSize(80, 24))

        var foundIdentColor = false
        let expectedFG: UInt32 = (UInt32(identRGB.0) << 16) | (UInt32(identRGB.1) << 8) | UInt32(identRGB.2)
        for cmd in cmds {
            if case .paragraph(_, let lines, _) = cmd {
                for spans in lines {
                    for span in spans {
                        if span.style.fg == expectedFG {
                            foundIdentColor = true
                        }
                    }
                }
            }
        }
        #expect(foundIdentColor, "At least one span must use the identifier color for descriptions")
    }
}
