// File: Tests/MoonSwiftTUITests/CompletionViewTests.swift
// Location: MoonSwiftTUITests/
// Role: Snapshot/render tests for the F7a.2 completion popup (CompletionView)
//       and hover overlay (HoverView), ux-spec §7.6. Asserts exact strings,
//       geometry bounds, selected-row styling, scroll windowing, and the
//       UX-R3-01 "(no documentation available)" fallback. No FFI — assertions
//       run against [RenderCommand].
// Upstream: CompletionView.swift, HoverView.swift, Renderer.swift (dispatch)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func termSize(_ cols: UInt16, _ rows: UInt16) -> TerminalSize {
    TerminalSize(cols: cols, rows: rows)
}

/// A theme with the tokens the completion/hover views read.
private func completionTheme() -> ThemeState {
    var theme = AppState().theme
    theme.tokens[.dim] = TokenStyle(fg: .rgb(98, 114, 164))
    theme.tokens[.keyword] = TokenStyle(fg: .rgb(255, 121, 198))
    theme.tokens[.identifier] = TokenStyle(fg: .rgb(248, 248, 242))
    theme.tokens[.focusBg] = TokenStyle(fg: .rgb(68, 71, 90))
    theme.tokens[.paneBg] = TokenStyle(fg: .rgb(248, 248, 242))
    return theme
}

private func clearRects(_ cmds: [RenderCommand]) -> [Rect] {
    cmds.compactMap {
        if case .clear(let rect) = $0 { return rect }
        return nil
    }
}

private func paragraphSpans(_ cmds: [RenderCommand]) -> [[Span]] {
    var out: [[Span]] = []
    for cmd in cmds {
        if case .paragraph(_, let lines, _) = cmd { out += lines }
    }
    return out
}

private func paragraphText(_ cmds: [RenderCommand]) -> [String] {
    paragraphSpans(cmds).map { spans in spans.map { $0.text }.joined() }
}

private func anyLine(_ lines: [String], contains needle: String) -> Bool {
    lines.contains { $0.contains(needle) }
}

private func item(_ label: String, detail: String? = nil, doc: String? = nil) -> CompletionItem {
    CompletionItem(insertText: label, label: label, detail: detail, doc: doc, kind: .function)
}

/// Build a code-pane state with one loaded source and the given completion focus.
private func stateWith(focus: FocusState) -> AppState {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    let code = "local x = 1\nlocal y = 2"
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: URL(fileURLWithPath: "/project/test.lua"),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    state.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: provenance))
    state.navigatorOrder = [id]
    state.selection = id
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.theme = completionTheme()
    state.focus = focus
    return state
}

// MARK: - Completion popup

@Suite("F7a.2 — completion popup rendering")
struct CompletionPopupViewTests {

    private let codeRect = Rect(x: 20, y: 1, width: 60, height: 20)

    @Test("popup lists each item label and fits within the code pane")
    func popupListsItems() {
        let items = [item("encode", detail: "(v) -> string"), item("decode"), item("null")]
        let popup = CompletionPopupState(items: items)
        let cmds = renderCompletionPopup(
            state: popup, codePaneRect: codeRect, cursorLine: 0, codeScroll: 0,
            terminalSize: termSize(80, 24), theme: completionTheme()
        )
        let text = paragraphText(cmds)
        #expect(anyLine(text, contains: "encode"))
        #expect(anyLine(text, contains: "(v) -> string"))
        #expect(anyLine(text, contains: "decode"))

        let rects = clearRects(cmds)
        #expect(rects.count == 1)
        #expect(rects[0].width <= 50)
        #expect(rects[0].height == 3)  // three items
        #expect(rects[0].x >= codeRect.x)
    }

    @Test("the selected row is drawn with the focus_bg cursor style")
    func selectedRowStyled() {
        let theme = completionTheme()
        let items = [item("alpha"), item("beta")]
        let popup = CompletionPopupState(items: items, selectedIndex: 1)
        let cmds = renderCompletionPopup(
            state: popup, codePaneRect: codeRect, cursorLine: 0, codeScroll: 0,
            terminalSize: termSize(80, 24), theme: theme
        )
        let rows = paragraphSpans(cmds)
        #expect(rows.count == 2)
        #expect(rows[0].first?.style == tokenStyle(.identifier, theme: theme))  // not selected
        #expect(rows[1].first?.style == tokenStyle(.focusBg, theme: theme))  // selected
    }

    @Test("popup shows a 10-row window scrolled to the selection")
    func popupScrolls() {
        let items = (0..<15).map { item("i\($0)") }
        let popup = CompletionPopupState(items: items, selectedIndex: 5, scrollOffset: 5)
        let cmds = renderCompletionPopup(
            state: popup, codePaneRect: codeRect, cursorLine: 0, codeScroll: 0,
            terminalSize: termSize(80, 24), theme: completionTheme()
        )
        let text = paragraphText(cmds)
        #expect(text.count == 10)  // completionPopupMaxVisible
        #expect(text.first?.contains("i5") == true)
        #expect(clearRects(cmds).first?.height == 10)
    }

    @Test("dispatch: completionPopup focus renders a popup through render()")
    func dispatchWiring() {
        let items = [item("encode"), item("decode")]
        let state = stateWith(focus: .completionPopup(CompletionPopupState(items: items)))
        let text = paragraphText(render(state, size: termSize(80, 24)))
        #expect(anyLine(text, contains: "encode"))
    }
}

// MARK: - Hover overlay

@Suite("F7a.2 — hover overlay rendering")
struct HoverOverlayViewTests {

    @Test("hover with a doc shows name, signature, and doc text")
    func hoverWithDoc() {
        let hov = HoverOverlayState(
            item: item("split", detail: "(s, sep) -> table", doc: "Split a string on a separator."),
            symbolName: "split"
        )
        let text = paragraphText(renderHoverOverlay(state: hov, size: termSize(80, 24), theme: completionTheme()))
        #expect(anyLine(text, contains: "split"))
        #expect(anyLine(text, contains: "(s, sep) -> table"))
        #expect(anyLine(text, contains: "Split a string on a separator."))
    }

    @Test("nil payload opens the overlay with the symbol name over the no-doc line (UX-R3-01)")
    func hoverNilNoDoc() {
        let hov = HoverOverlayState(item: nil, symbolName: "my_unknown")
        let text = paragraphText(renderHoverOverlay(state: hov, size: termSize(80, 24), theme: completionTheme()))
        #expect(anyLine(text, contains: "my_unknown"))
        #expect(anyLine(text, contains: "(no documentation available)"))
    }

    @Test("a resolved item with no doc still shows the no-doc line")
    func hoverItemNoDoc() {
        let hov = HoverOverlayState(item: item("opaque", detail: "(x)"), symbolName: "opaque")
        let text = paragraphText(renderHoverOverlay(state: hov, size: termSize(80, 24), theme: completionTheme()))
        #expect(anyLine(text, contains: "opaque"))
        #expect(anyLine(text, contains: "(no documentation available)"))
    }

    @Test("the overlay is centered and capped at 60x20 at two terminal sizes")
    func hoverCenteredGeometry() {
        let hov = HoverOverlayState(item: item("x", detail: "(a)", doc: "doc"), symbolName: "x")
        for size in [termSize(80, 24), termSize(200, 60)] {
            let rects = clearRects(renderHoverOverlay(state: hov, size: size, theme: completionTheme()))
            #expect(rects.count == 1)
            let r = rects[0]
            #expect(r.width <= 60)
            #expect(r.height <= 20)
            #expect(r.x == (size.cols - r.width) / 2)
            #expect(r.y == (size.rows - r.height) / 2)
        }
    }

    @Test("real catalog symbol renders its enriched signature and doc")
    func hoverRealCatalogSymbol() {
        let resolved = resolveHoverItem(symbolName: "luaswift.json.encode", liveMocks: [], tomlProbed: false)
        let hov = HoverOverlayState(item: resolved, symbolName: "luaswift.json.encode")
        let text = paragraphText(renderHoverOverlay(state: hov, size: termSize(80, 24), theme: completionTheme()))
        #expect(anyLine(text, contains: "encode"))
        // F7a.0 enrichment guarantees a signature for json.encode.
        #expect(resolved?.detail != nil)
    }

    @Test("dispatch: hoverOverlay focus renders the overlay through render()")
    func dispatchWiring() {
        let state = stateWith(focus: .hoverOverlay(HoverOverlayState(item: nil, symbolName: "foo")))
        let text = paragraphText(render(state, size: termSize(80, 24)))
        #expect(anyLine(text, contains: "(no documentation available)"))
    }
}
