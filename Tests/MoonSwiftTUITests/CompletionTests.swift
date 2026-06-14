// File: Tests/MoonSwiftTUITests/CompletionTests.swift
// Location: MoonSwiftTUITests/
// Role: Reducer-sequence + resolver tests for the F7a.2 completion popup and
//       hover overlay (ux-spec §7.6). Drives reduce() directly — no FFI, no
//       async, no live engine. Rendering/snapshot assertions live in
//       CompletionViewTests.swift.
// Upstream: Reducer.swift (completion dispatch), CompletionReducer.swift
//           (gestures + extraction), AppDriver+CompletionEffects.swift
//           (resolveHoverItem), AppState (CompletionPopupState/HoverOverlayState)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build a code-pane-focused state with one loaded source.
private func codePaneState(
    code: String,
    cursorLine: Int = 0,
    focus: FocusState = .pane(.codePane)
) -> AppState {
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
    state.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: provenance))
    state.navigatorOrder = [id]
    state.selection = id
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.codePane.cursorLine = cursorLine
    state.codePane.scrollOffset = cursorLine
    state.focus = focus
    return state
}

private func mockItem(_ name: String) -> CompletionItem {
    CompletionItem(insertText: name, label: name, detail: nil, doc: nil, kind: .mock)
}

// MARK: - Text extraction

@Suite("F7a.2 — completion/hover text extraction")
struct CompletionExtractionTests {

    @Test("completionPrefix takes the trailing identifier/dot run")
    func prefixExtraction() {
        #expect(completionPrefix(forLine: "x = luaswift.json.") == "luaswift.json.")
        #expect(completionPrefix(forLine: "luaswift.") == "luaswift.")
        #expect(completionPrefix(forLine: "foo.bar") == "foo.bar")
    }

    @Test("completionPrefix is empty when the line ends in a non-token char")
    func prefixEmptyOnTrailingSpace() {
        #expect(completionPrefix(forLine: "no token here ") == "")
        #expect(completionPrefix(forLine: "") == "")
    }

    @Test("symbolUnderCursor prefers the dotted qualified token")
    func symbolDotted() {
        #expect(symbolUnderCursor(line: "local s = luaswift.stringx.split(x)") == "luaswift.stringx.split")
    }

    @Test("symbolUnderCursor falls back to the longest bare identifier")
    func symbolBare() {
        #expect(symbolUnderCursor(line: "  helper(value)  ") == "helper")
        #expect(symbolUnderCursor(line: "   ") == "")
    }
}

// MARK: - Code-pane gestures

@Suite("F7a.2 — code-pane completion/hover gestures")
struct CompletionGestureTests {

    @Test("<C-space> emits queryCompletions with the extracted prefix")
    func ctrlSpaceEmitsQuery() {
        let state = codePaneState(code: "x = luaswift.json.")
        let (_, effects) = reduce(state, .key(.char(" "), modifiers: .ctrl))
        #expect(effects.count == 1)
        guard case .queryCompletions(let prefix, let liveMocks, let tomlProbed) = effects.first else {
            Issue.record("expected queryCompletions, got \(String(describing: effects.first))")
            return
        }
        #expect(prefix == "luaswift.json.")
        #expect(liveMocks.isEmpty)  // no mockLiveState cached
        #expect(tomlProbed == false)
    }

    @Test("<C-space> passes the tomlProbed flag through from state")
    func ctrlSpaceTomlFlag() {
        var state = codePaneState(code: "luaswift.")
        state.tomlModuleAvailable = true
        let (_, effects) = reduce(state, .key(.char(" "), modifiers: .ctrl))
        guard case .queryCompletions(_, _, let tomlProbed) = effects.first else {
            Issue.record("expected queryCompletions")
            return
        }
        #expect(tomlProbed == true)
    }

    @Test("K emits queryHover with the symbol under the cursor and stashes it")
    func kEmitsHover() {
        let state = codePaneState(code: "local s = luaswift.stringx.split(x)")
        let (next, effects) = reduce(state, .key(.char("K"), modifiers: []))
        #expect(effects.count == 1)
        guard case .queryHover(let symbol, _, _) = effects.first else {
            Issue.record("expected queryHover, got \(String(describing: effects.first))")
            return
        }
        #expect(symbol == "luaswift.stringx.split")
        #expect(next.hoverPendingSymbol == "luaswift.stringx.split")
    }
}

// MARK: - Event transitions

@Suite("F7a.2 — completionsReady / hoverReady transitions")
struct CompletionEventTests {

    @Test("completionsReady opens the popup when items are non-empty")
    func readyOpensPopup() {
        let state = codePaneState(code: "luaswift.")
        let items = [mockItem("encode"), mockItem("decode")]
        let (next, effects) = reduce(state, .completionsReady(items))
        #expect(effects.isEmpty)
        guard case .completionPopup(let popup) = next.focus else {
            Issue.record("expected completionPopup focus")
            return
        }
        #expect(popup.items.count == 2)
        #expect(popup.selectedIndex == 0)
    }

    @Test("completionsReady with no items is a no-op (nothing to complete)")
    func readyEmptyNoPopup() {
        let state = codePaneState(code: "luaswift.")
        let (next, _) = reduce(state, .completionsReady([]))
        #expect(next.focus == .pane(.codePane))
    }

    @Test("hoverReady opens the overlay with the resolved item")
    func hoverReadyOpensOverlay() {
        let state = codePaneState(code: "luaswift.json.encode")
        let item = CompletionItem(
            insertText: "encode", label: "encode",
            detail: "(value) -> string", doc: "Encode a Lua value.", kind: .function
        )
        let (next, _) = reduce(state, .hoverReady(item))
        guard case .hoverOverlay(let hov) = next.focus else {
            Issue.record("expected hoverOverlay focus")
            return
        }
        #expect(hov.item == item)
        #expect(hov.symbolName == "encode")
    }

    @Test("hoverReady(nil) still opens the overlay titled by the pending symbol (UX-R3-01)")
    func hoverReadyNilOpensOverlay() {
        var state = codePaneState(code: "my_unknown_symbol")
        state.hoverPendingSymbol = "my_unknown_symbol"
        let (next, _) = reduce(state, .hoverReady(nil))
        guard case .hoverOverlay(let hov) = next.focus else {
            Issue.record("expected hoverOverlay focus even for nil payload")
            return
        }
        #expect(hov.item == nil)
        #expect(hov.symbolName == "my_unknown_symbol")
        #expect(next.hoverPendingSymbol == "")  // cleared after consumption
    }
}

// MARK: - Popup + overlay key handling

@Suite("F7a.2 — popup and overlay key handling")
struct CompletionModalKeyTests {

    private func popupState(_ items: [CompletionItem], selected: Int = 0) -> AppState {
        var state = codePaneState(code: "luaswift.")
        state.focus = .completionPopup(CompletionPopupState(items: items, selectedIndex: selected))
        return state
    }

    @Test("j/k move the popup selection within bounds")
    func popupNavigation() {
        let items = [mockItem("a"), mockItem("b"), mockItem("c")]
        let (afterJ, _) = reduce(popupState(items), .key(.char("j"), modifiers: []))
        guard case .completionPopup(let p1) = afterJ.focus else {
            Issue.record("expected popup")
            return
        }
        #expect(p1.selectedIndex == 1)

        let (afterK, _) = reduce(afterJ, .key(.char("k"), modifiers: []))
        guard case .completionPopup(let p2) = afterK.focus else {
            Issue.record("expected popup")
            return
        }
        #expect(p2.selectedIndex == 0)

        // k at the top clamps.
        let (atTop, _) = reduce(afterK, .key(.char("k"), modifiers: []))
        guard case .completionPopup(let p3) = atTop.focus else {
            Issue.record("expected popup")
            return
        }
        #expect(p3.selectedIndex == 0)
    }

    @Test("<Enter> on a popup item opens the hover overlay for it (no insertion)")
    func popupEnterOpensHover() {
        let items = [mockItem("alpha"), mockItem("beta")]
        let (next, _) = reduce(popupState(items, selected: 1), .key(.enter, modifiers: []))
        guard case .hoverOverlay(let hov) = next.focus else {
            Issue.record("expected hoverOverlay focus")
            return
        }
        #expect(hov.item?.label == "beta")
        #expect(hov.symbolName == "beta")
    }

    @Test("<Esc> dismisses the popup back to the code pane")
    func popupEscDismiss() {
        let (next, _) = reduce(popupState([mockItem("a")]), .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.codePane))
    }

    @Test("<Esc> and K both dismiss the hover overlay")
    func hoverDismiss() {
        var state = codePaneState(code: "x")
        state.focus = .hoverOverlay(HoverOverlayState(item: nil, symbolName: "x"))
        let (afterEsc, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(afterEsc.focus == .pane(.codePane))

        let (afterK, _) = reduce(state, .key(.char("K"), modifiers: []))
        #expect(afterK.focus == .pane(.codePane))
    }
}

// MARK: - Hover symbol resolution

@Suite("F7a.2 — resolveHoverItem")
struct ResolveHoverItemTests {

    @Test("resolves a dotted catalog function to its enriched item")
    func resolvesCatalogFunction() {
        let item = resolveHoverItem(symbolName: "luaswift.json.encode", liveMocks: [], tomlProbed: false)
        #expect(item != nil)
        #expect(item?.label == "encode")
        #expect(item?.detail != nil)  // F7a.0 signature enrichment
    }

    @Test("returns nil for an unknown symbol")
    func unknownReturnsNil() {
        #expect(resolveHoverItem(symbolName: "luaswift.nope.zzz", liveMocks: [], tomlProbed: false) == nil)
        #expect(resolveHoverItem(symbolName: "totally_unknown", liveMocks: [], tomlProbed: false) == nil)
        #expect(resolveHoverItem(symbolName: "", liveMocks: [], tomlProbed: false) == nil)
    }

    @Test("falls back to the live-mock slice for a bare name")
    func resolvesLiveMock() {
        let mocks = [mockItem("host_log")]
        let item = resolveHoverItem(symbolName: "host_log", liveMocks: mocks, tomlProbed: false)
        #expect(item?.label == "host_log")
        #expect(item?.kind == .mock)
    }
}
