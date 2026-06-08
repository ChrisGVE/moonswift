// File: Tests/MoonSwiftTUITests/NavigatorTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for the navigator pane — keyboard navigation, filter search,
//       error-state rendering (exact ux-spec prefixes/colors), spinner state,
//       selection persistence, and filter narrowing + Esc cancel.
//       Covers Reducer.swift (navigator key handlers, filter handler) and
//       Renderer.swift (navigatorEntry, filteredNavigatorIDs, renderNavigator).
// Upstream: Reducer.swift, Renderer.swift, AppState.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Test helpers

/// Builds a minimal `LuaSourceFragment` for the given code string.
private func makeFragment(code: String = "print('hello')", path: String = "test.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/project/\(path)")
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
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// Builds a minimal `AppState` with a navigator populated from `ids` and
/// `sources`. Focus defaults to `.pane(.navigator)`.
private func stateWithNavigator(
    ids: [SourceID],
    sources: [SourceID: SourceState] = [:],
    selectedIndex: Int = 0,
    filterText: String? = nil,
    spinnerPhase: Int = 0
) -> AppState {
    var state = AppState()
    state.navigatorOrder = ids
    state.sources = sources
    state.navigator = NavigatorState(
        selectedIndex: selectedIndex,
        filterText: filterText,
        spinnerPhase: spinnerPhase
    )
    state.focus = .pane(.navigator)
    return state
}

/// Minimal terminal size for layout tests.
private let size80x24 = TerminalSize(cols: 80, rows: 24)

/// Extracts all `.navigatorList` commands from a render output.
private func extractNavigatorLists(_ cmds: [RenderCommand]) -> [(items: [Span], selectedIndex: Int?)] {
    cmds.compactMap {
        if case .navigatorList(_, let items, let sel, _) = $0 {
            return (items, sel)
        }
        return nil
    }
}

/// Extracts all `.cellRun` commands from a render output.
private func extractCellRuns(_ cmds: [RenderCommand]) -> [(col: UInt16, row: UInt16, text: String)] {
    cmds.compactMap {
        if case .cellRun(let col, let row, let text, _) = $0 { return (col, row, text) }
        return nil
    }
}

// MARK: - Navigator keyboard navigation

@Suite("Navigator — Keyboard navigation")
struct NavigatorKeyboardTests {

    @Test("j moves selection down within list")
    func jMovesDown() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 0)

        let (next, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(next.navigator.selectedIndex == 1)

        let (next2, _) = reduce(next, .key(.char("j"), modifiers: []))
        #expect(next2.navigator.selectedIndex == 2)
    }

    @Test("j does not move past last entry")
    func jClampedAtBottom() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 1)
        let (next, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(next.navigator.selectedIndex == 1, "j at last entry must stay at last")
    }

    @Test("k moves selection up within list")
    func kMovesUp() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 2)

        let (next, _) = reduce(state, .key(.char("k"), modifiers: []))
        #expect(next.navigator.selectedIndex == 1)

        let (next2, _) = reduce(next, .key(.char("k"), modifiers: []))
        #expect(next2.navigator.selectedIndex == 0)
    }

    @Test("k does not move past first entry")
    func kClampedAtTop() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 0)
        let (next, _) = reduce(state, .key(.char("k"), modifiers: []))
        #expect(next.navigator.selectedIndex == 0, "k at first entry must stay at 0")
    }

    @Test("g jumps to first entry")
    func gJumpsToFirst() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 2)
        let (next, _) = reduce(state, .key(.char("g"), modifiers: []))
        #expect(next.navigator.selectedIndex == 0)
    }

    @Test("G jumps to last entry")
    func gJumpsToLast() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua"), SourceID(path: "c.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 0)
        let (next, _) = reduce(state, .key(.char("G"), modifiers: []))
        #expect(next.navigator.selectedIndex == 2)
    }

    @Test("j/k/g/G are no-ops on empty list")
    func navigationNoOpOnEmpty() {
        let state = stateWithNavigator(ids: [], selectedIndex: 0)
        for key: KeyCode in [.char("j"), .char("k"), .char("g"), .char("G")] {
            let (next, _) = reduce(state, .key(key, modifiers: []))
            #expect(next.navigator.selectedIndex == 0)
        }
    }

    @Test("Enter loads the selected source into the code pane")
    func enterLoadsSource() {
        let id = SourceID(path: "script.lua")
        let fragment = makeFragment(path: "script.lua")
        let sources: [SourceID: SourceState] = [id: .loaded(fragment)]
        let state = stateWithNavigator(ids: [id], sources: sources, selectedIndex: 0)

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.selection == id, "Enter must select the highlighted source")
    }

    @Test("o loads same as Enter")
    func oActsLikeEnter() {
        let id = SourceID(path: "script.lua")
        let fragment = makeFragment(path: "script.lua")
        let sources: [SourceID: SourceState] = [id: .loaded(fragment)]
        let state = stateWithNavigator(ids: [id], sources: sources, selectedIndex: 0)

        let (next, _) = reduce(state, .key(.char("o"), modifiers: []))
        #expect(next.selection == id)
    }

    @Test("Space loads same as Enter")
    func spaceActsLikeEnter() {
        let id = SourceID(path: "script.lua")
        let fragment = makeFragment(path: "script.lua")
        let sources: [SourceID: SourceState] = [id: .loaded(fragment)]
        let state = stateWithNavigator(ids: [id], sources: sources, selectedIndex: 0)

        let (next, _) = reduce(state, .key(.char(" "), modifiers: []))
        #expect(next.selection == id)
    }

    @Test("m on whole-lua file shows transient instead of opening picker")
    func mOnLuaFileShowsTransient() {
        let id = SourceID(path: "init.lua")  // no jsonpath → whole file
        let state = stateWithNavigator(ids: [id], selectedIndex: 0)

        let (next, _) = reduce(state, .key(.char("m"), modifiers: []))
        #expect(next.focus == .pane(.navigator), "picker must not open for a whole-lua file")
        #expect(next.transient != nil, "a transient must be shown when m is not applicable")
    }

    @Test("m on structured-file entry opens picker modal")
    func mOnStructuredFileOpensPicker() {
        let id = SourceID(path: "data.json", jsonpath: "$.scripts[0]")
        let state = stateWithNavigator(ids: [id], selectedIndex: 0)

        let (next, _) = reduce(state, .key(.char("m"), modifiers: []))
        #expect(next.focus == .pickerModal, "m on structured-file entry must open picker modal")
    }
}

// MARK: - Navigator filter

@Suite("Navigator — Filter search")
struct NavigatorFilterTests {

    @Test("/ activates filter with empty query")
    func slashActivatesFilter() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids)
        #expect(state.navigator.filterText == nil)

        let (next, _) = reduce(state, .key(.char("/"), modifiers: []))
        #expect(next.navigator.filterText == "", "/ must set filterText to empty string")
    }

    @Test("/ inside filter mode appends to the query (paths contain slashes)")
    func slashInFilterModeAppends() {
        // Regression (#QA-20): a /-as-toggle case made path queries like
        // "src/foo" impossible. ux-spec §2.2 names only <Esc> as the close key.
        let ids = [SourceID(path: "src/a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "src")

        let (next, _) = reduce(state, .key(.char("/"), modifiers: []))
        #expect(next.navigator.filterText == "src/", "/ must append to the query, not close the filter")
    }

    @Test("Typing characters in filter mode appends to query")
    func typingAppendsToQuery() {
        let ids = [SourceID(path: "alpha.lua"), SourceID(path: "beta.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "")

        let (s1, _) = reduce(state, .key(.char("a"), modifiers: []))
        #expect(s1.navigator.filterText == "a")

        let (s2, _) = reduce(s1, .key(.char("l"), modifiers: []))
        #expect(s2.navigator.filterText == "al")

        let (s3, _) = reduce(s2, .key(.char("p"), modifiers: []))
        #expect(s3.navigator.filterText == "alp")
    }

    @Test("Typing j and k in filter mode appends to query (not navigation)")
    func jkInFilterModeAppendsToQuery() {
        let ids = [SourceID(path: "foo.lua"), SourceID(path: "bar.lua")]
        let state = stateWithNavigator(ids: ids, selectedIndex: 0, filterText: "")

        let (sj, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(sj.navigator.filterText == "j", "j in filter mode must append to query, not navigate")

        let (sk, _) = reduce(state, .key(.char("k"), modifiers: []))
        #expect(sk.navigator.filterText == "k", "k in filter mode must append to query, not navigate")
    }

    @Test("Backspace removes the last character from the filter query")
    func backspaceRemovesLastChar() {
        let ids = [SourceID(path: "alpha.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "alp")

        let (next, _) = reduce(state, .key(.backspace, modifiers: []))
        #expect(next.navigator.filterText == "al")
    }

    @Test("Backspace on empty query leaves it empty")
    func backspaceOnEmptyQuery() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "")

        let (next, _) = reduce(state, .key(.backspace, modifiers: []))
        #expect(next.navigator.filterText == "", "backspace on empty query must leave it empty, not nil")
    }

    @Test("Esc clears the filter and returns to normal mode")
    func escClearsFilter() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "abc")

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.navigator.filterText == nil, "Esc must clear filterText to nil")
    }

    @Test("Esc with no filter active is a no-op")
    func escWithNoFilterIsNoOp() {
        let ids = [SourceID(path: "a.lua")]
        // filterText is nil by default in stateWithNavigator.
        let state = stateWithNavigator(ids: ids)

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.navigator.filterText == nil, "Esc with nil filter must leave it nil")
    }

    @Test("Typing narrows selection to first matching entry")
    func typingNarrowsSelection() {
        // IDs in order: alpha.lua, beta.lua, another.lua
        let ids = [
            SourceID(path: "alpha.lua"),
            SourceID(path: "beta.lua"),
            SourceID(path: "another.lua"),
        ]
        // Start with selection on beta.lua (index 1), activate filter.
        let state = stateWithNavigator(ids: ids, selectedIndex: 1, filterText: "")

        // Type "al" — only "alpha.lua" and "another.lua" remain visible
        // but "al" matches "alpha.lua" earlier in the list.
        let (s1, _) = reduce(state, .key(.char("a"), modifiers: []))
        let (s2, _) = reduce(s1, .key(.char("l"), modifiers: []))

        // Selected entry should now be the first match (alpha.lua, index 0 in full order).
        let selectedID = ids[s2.navigator.selectedIndex]
        #expect(selectedID == SourceID(path: "alpha.lua"), "selection must re-anchor to first match")
    }

    @Test("filteredNavigatorIDs returns all IDs when filter is nil")
    func filterNilReturnsAll() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        let result = filteredNavigatorIDs(order: ids, filterText: nil)
        #expect(result == ids)
    }

    @Test("filteredNavigatorIDs returns all IDs when filter is empty string")
    func filterEmptyReturnsAll() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        let result = filteredNavigatorIDs(order: ids, filterText: "")
        #expect(result == ids)
    }

    @Test("filteredNavigatorIDs is case-insensitive substring match")
    func filterCaseInsensitive() {
        let ids = [
            SourceID(path: "Alpha.lua"),
            SourceID(path: "beta.lua"),
            SourceID(path: "GAMMA.lua"),
        ]
        let result = filteredNavigatorIDs(order: ids, filterText: "alpha")
        #expect(result == [SourceID(path: "Alpha.lua")])
    }

    @Test("filteredNavigatorIDs matches on path:jsonpath for structured entries")
    func filterMatchesJsonpath() {
        let lua = SourceID(path: "scripts.lua")
        let structured = SourceID(path: "data.json", jsonpath: "$.scripts[0]")
        let ids = [lua, structured]

        let result = filteredNavigatorIDs(order: ids, filterText: "scripts")
        // Both contain "scripts" (the lua file has "scripts" in its path; the
        // structured entry has it in its jsonpath description).
        #expect(result.count == 2)
    }

    @Test("filteredNavigatorIDs returns empty array when nothing matches")
    func filterNoMatch() {
        let ids = [SourceID(path: "alpha.lua"), SourceID(path: "beta.lua")]
        let result = filteredNavigatorIDs(order: ids, filterText: "zzz")
        #expect(result.isEmpty)
    }

    @Test("Enter in filter mode loads the highlighted entry")
    func enterInFilterModeLoads() {
        let idA = SourceID(path: "alpha.lua")
        let idB = SourceID(path: "beta.lua")
        let fragment = makeFragment(path: "alpha.lua")
        let sources: [SourceID: SourceState] = [idA: .loaded(fragment)]
        let state = stateWithNavigator(
            ids: [idA, idB],
            sources: sources,
            selectedIndex: 0,
            filterText: "alp"
        )

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.selection == idA, "Enter in filter mode must load the selected entry")
    }
}

// MARK: - Navigator rendering — error state prefixes

@Suite("Navigator — Error state rendering")
struct NavigatorRenderingTests {

    /// Builds a theme state with the named token set to a sentinel style so tests
    /// can distinguish which token drove the style of a navigator entry.
    private func themeWithTokens() -> ThemeState {
        // Use a blank theme — tokenStyle returns .default for unknown tokens.
        // The tests here check the *text prefix*, not the color style.
        ThemeState(name: "test", capability: .truecolor, tokens: [:])
    }

    @Test("Loaded entry shows provenance displayName, no prefix")
    func loadedEntryLabel() {
        let id = SourceID(path: "scripts/init.lua")
        let fragment = makeFragment(code: "-- ok", path: "scripts/init.lua")
        let sources: [SourceID: SourceState] = [id: .loaded(fragment)]
        let state = stateWithNavigator(ids: [id], sources: sources)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        #expect(!lists.isEmpty, "render must produce a navigatorList command")
        let text = lists[0].items.first?.text ?? ""
        #expect(!text.hasPrefix("✖"), "loaded entry must not have error prefix")
        #expect(!text.hasPrefix("⚠"), "loaded entry must not have warning prefix")
        // The display name for a whole-lua file is its path basename via provenance.
        #expect(!text.isEmpty, "loaded entry must have a non-empty label")
    }

    @Test("Missing file entry shows ✖ prefix")
    func missingFilePrefix() {
        let id = SourceID(path: "gone.lua")
        let sources: [SourceID: SourceState] = [id: .missing]
        let state = stateWithNavigator(ids: [id], sources: sources)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        #expect(text.hasPrefix("✖"), "missing file must show ✖ prefix (ux-spec §4.2)")
        #expect(text.contains("gone.lua"), "missing file label must contain the path")
    }

    @Test("Malformed structured file shows ✖ prefix (error severity)")
    func malformedStructuredFilePrefix() {
        let id = SourceID(path: "data.json", jsonpath: "$.foo")
        let diag = Diagnostic(severity: .error, message: "parse error", source: .sourceLoad)
        let sources: [SourceID: SourceState] = [id: .failed(diag)]
        let state = stateWithNavigator(ids: [id], sources: sources)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        #expect(text.hasPrefix("✖"), "malformed file must show ✖ prefix (ux-spec §4.2)")
    }

    @Test("Unresolved JSONPath shows ⚠ prefix (warning severity)")
    func unresolvedJsonpathPrefix() {
        let id = SourceID(path: "data.json", jsonpath: "$.missing")
        let diag = Diagnostic(severity: .warning, message: "path matched nothing", source: .sourceLoad)
        let sources: [SourceID: SourceState] = [id: .failed(diag)]
        let state = stateWithNavigator(ids: [id], sources: sources)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        #expect(text.hasPrefix("⚠"), "unresolved path must show ⚠ prefix (ux-spec §4.2)")
        // The description for a structured entry is "<path>:<jsonpath>".
        #expect(text.contains("data.json"), "unresolved path label must contain filename")
        #expect(text.contains("$.missing"), "unresolved path label must contain the jsonpath")
    }

    @Test("Non-string field shows ⚠ prefix (warning severity)")
    func nonStringFieldPrefix() {
        let id = SourceID(path: "config.json", jsonpath: "$.count")
        let diag = Diagnostic(severity: .warning, message: "not a string", source: .sourceLoad)
        let sources: [SourceID: SourceState] = [id: .failed(diag)]
        let state = stateWithNavigator(ids: [id], sources: sources)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        #expect(text.hasPrefix("⚠"), "non-string field must show ⚠ prefix (ux-spec §4.2)")
    }

    @Test("Loading entry shows spinner character")
    func loadingEntryShowsSpinner() {
        let id = SourceID(path: "loading.lua")
        let sources: [SourceID: SourceState] = [id: .loading]
        // Use spinnerPhase = 0 → braille '⠁' for truecolor.
        let state = stateWithNavigator(ids: [id], sources: sources, spinnerPhase: 0)
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        // Phase 0 of the braille set is '⠁' (ux-spec §4.1).
        #expect(
            text.contains("⠁") || text.contains("|"),
            "loading entry must show a spinner character")
        #expect(text.contains("loading.lua"), "loading entry must show the filename")
    }

    @Test("Empty navigator shows (empty) label")
    func emptyNavigatorLabel() {
        let state = stateWithNavigator(ids: [])
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        #expect(lists[0].items.first?.text == "(empty)", "(empty) label required by ux-spec §4.1")
    }

    @Test("Filter with no match shows (no match) label")
    func noMatchLabel() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "zzz")
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        #expect(
            lists[0].items.first?.text == "(no match)",
            "(no match) label required when filter yields no results")
    }

    @Test("Filter active renders filter bar with / prefix")
    func filterBarRendered() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: "lua")
        let cmds = render(state, size: size80x24)

        let cellRuns = extractCellRuns(cmds)
        let filterBars = cellRuns.filter { $0.text.hasPrefix("/") }
        #expect(!filterBars.isEmpty, "filter bar must be rendered as a cellRun starting with /")
        let barText = filterBars[0].text
        #expect(barText.contains("lua"), "filter bar must show the current query")
    }

    @Test("Filter bar not rendered when filter is nil")
    func noFilterBarWhenFilterNil() {
        let ids = [SourceID(path: "a.lua")]
        let state = stateWithNavigator(ids: ids, filterText: nil)
        let cmds = render(state, size: size80x24)

        let cellRuns = extractCellRuns(cmds)
        let filterBars = cellRuns.filter { $0.text.hasPrefix("/") }
        #expect(filterBars.isEmpty, "filter bar must not appear when filter is inactive")
    }

    @Test("Selection highlight targets correct filtered list position")
    func selectionMapsToFilteredPosition() {
        // Three entries; filter "lua" matches all three (they all end in .lua).
        // Use a filter that excludes the first entry to force an interesting mapping.
        let ids = [
            SourceID(path: "config.json", jsonpath: "$.scripts"),  // no "lua"
            SourceID(path: "init.lua"),  // matches "lua"
            SourceID(path: "main.lua"),  // matches "lua"
        ]
        // Select "main.lua" (full-order index 2); filter "lua" leaves
        // init.lua at filtered position 0 and main.lua at filtered position 1.
        let state = stateWithNavigator(ids: ids, selectedIndex: 2, filterText: "lua")
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        #expect(
            lists[0].selectedIndex == 1,
            "selectedIndex in filtered list must be 1 for main.lua with filter 'lua'")
    }

    @Test("Selection shows nil highlighted index when filtered out")
    func selectionNilWhenFilteredOut() {
        let ids = [
            SourceID(path: "alpha.lua"),
            SourceID(path: "beta.lua"),
        ]
        // Selected is "alpha.lua" (index 0); filter "beta" matches only beta.lua.
        let state = stateWithNavigator(ids: ids, selectedIndex: 0, filterText: "beta")
        let cmds = render(state, size: size80x24)

        let lists = extractNavigatorLists(cmds)
        #expect(
            lists[0].selectedIndex == nil,
            "selectedIndex must be nil when the selected entry is filtered out")
    }
}

// MARK: - Navigator spinner state

@Suite("Navigator — Spinner")
struct NavigatorSpinnerTests {

    @Test("Tick advances spinnerPhase by 1 and wraps at 8")
    func spinnerPhaseAdvancesOnTick() {
        var state = AppState()
        state.navigator.spinnerPhase = 0
        // Add a loading source so the tick arms the spinner timer.
        let id = SourceID(path: "loading.lua")
        state.sources[id] = .loading
        state.navigatorOrder = [id]

        let (next, _) = reduce(state, .tick)
        #expect(next.navigator.spinnerPhase == 1)

        var s7 = next
        s7.navigator.spinnerPhase = 7
        let (wrapped, _) = reduce(s7, .tick)
        #expect(wrapped.navigator.spinnerPhase == 0, "spinnerPhase must wrap from 7 back to 0")
    }

    @Test("Braille spinner characters match ux-spec §4.1 set")
    func brailleSpinnerChars() {
        let expected: [Character] = ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
        let id = SourceID(path: "loading.lua")
        let sources: [SourceID: SourceState] = [id: .loading]
        var state = stateWithNavigator(ids: [id], sources: sources)
        state.theme = ThemeState(name: "test", capability: .truecolor, tokens: [:])

        for (phase, char) in expected.enumerated() {
            state.navigator.spinnerPhase = phase
            let cmds = render(state, size: size80x24)
            let lists = extractNavigatorLists(cmds)
            let text = lists[0].items.first?.text ?? ""
            #expect(
                text.contains(String(char)),
                "phase \(phase) must show braille character '\(char)' (ux-spec §4.1)")
        }
    }

    @Test("ASCII spinner characters for 256-color capability")
    func asciiSpinnerChars() {
        let expected: [Character] = ["|", "/", "-", "\\"]
        let id = SourceID(path: "loading.lua")
        let sources: [SourceID: SourceState] = [id: .loading]
        var state = stateWithNavigator(ids: [id], sources: sources)
        state.theme = ThemeState(name: "test", capability: .color256, tokens: [:])

        for (phase, char) in expected.enumerated() {
            state.navigator.spinnerPhase = phase
            let cmds = render(state, size: size80x24)
            let lists = extractNavigatorLists(cmds)
            let text = lists[0].items.first?.text ?? ""
            #expect(
                text.contains(String(char)),
                "phase \(phase) must show ASCII spinner '\(char)' in 256-color mode")
        }
    }

    @Test("ASCII spinner for NO_COLOR capability")
    func asciiSpinnerInNoColor() {
        let id = SourceID(path: "loading.lua")
        let sources: [SourceID: SourceState] = [id: .loading]
        var state = stateWithNavigator(ids: [id], sources: sources)
        state.theme = ThemeState(name: "test", capability: .noColor, tokens: [:])
        state.navigator.spinnerPhase = 1  // '/' in ASCII set

        let cmds = render(state, size: size80x24)
        let lists = extractNavigatorLists(cmds)
        let text = lists[0].items.first?.text ?? ""
        #expect(
            text.contains("/") || text.contains("|") || text.contains("-") || text.contains("\\"),
            "NO_COLOR mode must use ASCII spinner")
    }
}

// MARK: - Navigator selection persistence

@Suite("Navigator — Selection persistence")
struct NavigatorSelectionPersistenceTests {

    @Test("Selection is preserved on a sourceLoaded event for another source")
    func selectionPersistedOnOtherSourceLoad() {
        let idA = SourceID(path: "a.lua")
        let idB = SourceID(path: "b.lua")
        let fragA = makeFragment(path: "a.lua")
        let fragB = makeFragment(path: "b.lua")

        var state = AppState()
        state.navigatorOrder = [idA, idB]
        state.sources[idA] = .loaded(fragA)
        state.sources[idB] = .loading
        state.selection = idA
        state.navigator.selectedIndex = 0

        // Load B — must not change the selection.
        let (next, _) = reduce(state, .sourceLoaded(id: idB, fragment: fragB))
        #expect(next.selection == idA, "selection must persist across other sources loading")
        #expect(next.navigator.selectedIndex == 0, "selectedIndex must persist across other sources loading")
    }

    @Test("Code pane state resets on new selection")
    func codePaneResetsOnNewSelection() {
        let idA = SourceID(path: "a.lua")
        let fragA = makeFragment(path: "a.lua")

        var state = AppState()
        state.navigatorOrder = [idA]
        state.sources[idA] = .loaded(fragA)
        state.navigator.selectedIndex = 0
        state.focus = .pane(.navigator)
        // Mess up the code pane state.
        state.codePane.scrollOffset = 42
        state.codePane.cursorLine = 42

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.codePane.scrollOffset == 0, "codePane scroll must reset on new selection")
        #expect(next.codePane.cursorLine == 0, "codePane cursor must reset on new selection")
    }

    @Test("Filter text is independent of selection (selection survives filter Esc)")
    func selectionSurvivesFilterCancel() {
        let idA = SourceID(path: "alpha.lua")
        let idB = SourceID(path: "beta.lua")
        let fragA = makeFragment(path: "alpha.lua")

        var state = AppState()
        state.navigatorOrder = [idA, idB]
        state.sources[idA] = .loaded(fragA)
        state.selection = idA
        state.navigator.selectedIndex = 0
        state.navigator.filterText = "alp"
        state.focus = .pane(.navigator)

        // Esc cancels filter — selection must remain on alpha.lua.
        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.selection == idA, "Esc cancel must preserve existing selection")
        #expect(next.navigator.selectedIndex == 0, "Esc cancel must preserve selectedIndex")
    }
}

// MARK: - filteredNavigatorIDs unit tests

@Suite("Navigator — filteredNavigatorIDs")
struct FilteredNavigatorIDsTests {

    @Test("Returns full order when filter is nil")
    func nilFilter() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        #expect(filteredNavigatorIDs(order: ids, filterText: nil) == ids)
    }

    @Test("Returns full order when filter is empty string")
    func emptyFilter() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        #expect(filteredNavigatorIDs(order: ids, filterText: "") == ids)
    }

    @Test("Matches filename substring case-insensitively")
    func caseInsensitiveMatch() {
        let ids = [SourceID(path: "Alpha.lua"), SourceID(path: "beta.lua")]
        #expect(filteredNavigatorIDs(order: ids, filterText: "ALPHA") == [SourceID(path: "Alpha.lua")])
    }

    @Test("Matches jsonpath portion of description for structured entries")
    func matchesJsonpath() {
        let structured = SourceID(path: "data.json", jsonpath: "$.lua_scripts[0]")
        let plain = SourceID(path: "init.lua")
        let ids = [plain, structured]
        let result = filteredNavigatorIDs(order: ids, filterText: "lua_scripts")
        #expect(result == [structured])
    }

    @Test("Empty result when nothing matches")
    func noMatch() {
        let ids = [SourceID(path: "a.lua"), SourceID(path: "b.lua")]
        #expect(filteredNavigatorIDs(order: ids, filterText: "xyz").isEmpty)
    }

    @Test("Preserves original order among matching entries")
    func preservesOrder() {
        let ids = [
            SourceID(path: "b_module.lua"),
            SourceID(path: "a_module.lua"),
            SourceID(path: "c_module.lua"),
        ]
        let result = filteredNavigatorIDs(order: ids, filterText: "module")
        #expect(result == ids, "order of matching entries must be preserved")
    }
}
