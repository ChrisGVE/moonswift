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
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "Global"), "Global section header must appear in the overlay")
    }

    @Test("'Navigator' section header is present")
    func navigatorSectionHeader() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "Navigator"), "Navigator section header must appear in the overlay")
    }

    @Test("'Code pane' section header is present")
    func codePaneSectionHeader() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "Code pane"), "Code pane section header must appear in the overlay")
    }

    @Test("'Bottom pane' section header is present")
    func bottomPaneSectionHeader() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "Bottom pane"), "Bottom pane section header must appear in the overlay")
    }

    // MARK: Global keys

    @Test("Global key 'r' Run is listed")
    func globalKeyRun() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "r"), "Key 'r' must appear in the help overlay")
        #expect(anyLine(lines, contains: "Run"), "Run description must appear in the help overlay")
    }

    @Test("Global key 'x' Cancel is listed")
    func globalKeyCancel() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "x"), "Key 'x' must appear")
        #expect(anyLine(lines, contains: "Cancel"), "Cancel description must appear")
    }

    @Test("Global key 'l' Lint is listed")
    func globalKeyLint() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "l"), "Key 'l' must appear")
        #expect(anyLine(lines, contains: "Lint"), "Lint description must appear")
    }

    @Test("Global key 'q' Quit is listed")
    func globalKeyQuit() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "q"), "Key 'q' must appear")
        #expect(anyLine(lines, contains: "Quit"), "Quit description must appear")
    }

    @Test("Global key '?' help is listed")
    func globalKeyHelp() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "?"), "Key '?' must appear")
        #expect(anyLine(lines, contains: "help"), "'help' must appear in ? description")
    }

    @Test("Global key <C-p> is listed")
    func globalKeyCtrlP() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<C-p>"), "<C-p> must appear in the overlay")
        #expect(anyLine(lines, contains: "$EDITOR"), "$EDITOR must appear in <C-p> description")
    }

    @Test("Global key <C-r> is listed")
    func globalKeyCtrlR() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<C-r>"), "<C-r> must appear in the overlay")
        #expect(anyLine(lines, contains: "Reload"), "Reload description must appear")
    }

    @Test("Global key <C-h> jump to navigator is listed")
    func globalKeyCtrlH() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<C-h>"), "<C-h> must appear in the overlay")
    }

    @Test("Global key <C-l> jump to code pane is listed")
    func globalKeyCtrlL() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<C-l>"), "<C-l> must appear in the overlay")
    }

    @Test("Global key <C-j> jump to bottom pane is listed")
    func globalKeyCtrlJ() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<C-j>"), "<C-j> must appear in the overlay")
    }

    @Test("Global <Tab> cycle panes is listed")
    func globalKeyTab() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<Tab>"), "<Tab> must appear in the overlay")
    }

    @Test("Global <S-Tab> reverse-cycle is listed")
    func globalKeyShiftTab() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<S-Tab>"), "<S-Tab> must appear in the overlay")
    }

    // MARK: Navigator keys

    @Test("Navigator j/k listed")
    func navigatorJK() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "j/k"), "j/k must appear in the overlay")
    }

    @Test("Navigator g first-entry listed")
    func navigatorG() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "first"), "First-entry description must appear in the overlay")
    }

    @Test("Navigator G last-entry listed")
    func navigatorCapG() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "last"), "Last-entry description must appear in the overlay")
    }

    @Test("Navigator <Enter> load source listed")
    func navigatorEnter() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "<Enter>"), "<Enter> must appear in the overlay")
        #expect(anyLine(lines, contains: "Load"), "Load description must appear")
    }

    @Test("Navigator / filter listed")
    func navigatorFilter() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "/"), "/ filter must appear in the overlay")
        #expect(anyLine(lines, contains: "Filter"), "Filter description must appear")
    }

    @Test("Navigator m picker listed")
    func navigatorM() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "m"), "m must appear in the overlay")
        #expect(anyLine(lines, contains: "picker"), "picker description must appear")
    }

    // MARK: Code pane keys

    @Test("Code pane d/u half-page scroll listed")
    func codePaneDU() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "d/u"), "d/u must appear in the overlay")
        #expect(anyLine(lines, contains: "half-page"), "half-page description must appear")
    }

    @Test("Code pane f/b full-page scroll listed")
    func codePaneFB() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "f/b"), "f/b must appear in the overlay")
        #expect(anyLine(lines, contains: "full page"), "full page description must appear")
    }

    @Test("Code pane g/G top/bottom listed")
    func codePaneGG() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "g/G"), "g/G must appear in the overlay")
    }

    @Test("Code pane :N line jump listed")
    func codePaneColonN() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: ":N"), ":N must appear in the overlay")
        #expect(anyLine(lines, contains: "line"), "line N description must appear")
    }

    @Test("Code pane n/N diagnostic navigation listed")
    func codePaneNDiag() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "n/N"), "n/N must appear in the overlay")
        #expect(anyLine(lines, contains: "diagnostic"), "diagnostic description must appear")
    }

    @Test("Code pane [d first diagnostic listed")
    func codePaneBracketD() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "[d"), "[d must appear in the overlay")
    }

    @Test("Code pane ]d last diagnostic listed")
    func codePaneCloseBracketD() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "]d"), "]d must appear in the overlay")
    }

    // MARK: Bottom pane keys

    @Test("Bottom pane <Enter> jump to error line listed")
    func bottomPaneEnter() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        // <Enter> appears for navigator and bottom pane — just check both are represented.
        #expect(anyLine(lines, contains: "Jump code pane"), "Jump code pane description must appear for bottom pane")
    }

    @Test("Bottom pane y yank listed")
    func bottomPaneY() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "y"), "y must appear in the overlay")
        #expect(anyLine(lines, contains: "Yank"), "Yank description must appear")
    }

    @Test("Bottom pane 1/2 tab quick-jump listed")
    func bottomPane12() {
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "1/2"), "1/2 must appear in the overlay")
        #expect(anyLine(lines, contains: "Output"), "Output tab reference must appear")
        #expect(anyLine(lines, contains: "Diagnostics"), "Diagnostics tab reference must appear")
    }

    @Test("Bottom pane <C-l> clear output listed")
    func bottomPaneCtrlL() {
        // <C-l> appears globally (jump to code pane) and bottom-pane (clear output).
        // Verify the clear output description is present.
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(anyLine(lines, contains: "Clear output"), "Clear output description must appear for bottom pane")
    }

    // MARK: Tab note (ux-spec §2.5 — exact binding string)

    @Test("Exact Tab context-sensitivity note is present (ux-spec §2.5 binding string)")
    func exactTabNote() {
        // ux-spec §2.5 normative text:
        // "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let expected = "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let lines = paragraphText(render(helpOverlayState(), size: termSize(80, 24)))
        #expect(
            anyLine(lines, contains: expected),
            "The exact ux-spec §2.5 Tab note must appear verbatim in the overlay"
        )
    }

    @Test("Tab note present at 200×60 too")
    func tabNoteAt200x60() {
        let expected = "<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."
        let lines = paragraphText(render(helpOverlayState(), size: termSize(200, 60)))
        #expect(anyLine(lines, contains: expected), "Tab note must be present at 200×60")
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
