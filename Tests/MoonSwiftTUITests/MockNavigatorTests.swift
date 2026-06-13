// File: Tests/MoonSwiftTUITests/MockNavigatorTests.swift
// Location: MoonSwiftTUITests/
// Role: P2 F5.4 — the navigator's Mock Environment section: the row model
//       (divider + declared values/functions + live-state empty hint), the exact
//       divider string, and the `j`/`k` cursor crossing the divider between the
//       source list and the mock section (PRD F5.4 acceptance: two sections,
//       divider, j/k traverses both skipping the divider). Live-state population
//       (from a run) and the a/e/d forms are covered separately.
//
// Upstream: MockNavigatorView.swift, MockNavigatorReducer.swift, Reducer.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func loadedStateWithMocks(
    sourceCount: Int = 2,
    values: [MockValueDef] = [
        MockValueDef(namespace: "myapp", path: "settings.debug", type: .boolean, value: "true", writable: false)
    ],
    functions: [MockFunctionDef] = [
        MockFunctionDef(name: "on_event", behavior: .echoArgs, returnValue: nil, errorMessage: nil)
    ]
) -> AppState {
    var s = AppState()
    var order: [SourceID] = []
    for i in 0..<sourceCount {
        let id = SourceID(path: "src\(i).lua")
        let code = "x = \(i)"
        let data = Data(code.utf8)
        let prov = FragmentProvenance(
            file: URL(fileURLWithPath: "/p/src\(i).lua"), jsonpath: nil, document: 0,
            byteRange: 0..<data.count, lineOffset: 0, contentHash: SHA256.hash(data: data))
        s.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: prov))
        order.append(id)
    }
    s.navigatorOrder = order
    s.selection = order.first
    let file = ProjectFile(luaVersion: "5.4", mocks: MockStore(values: values, functions: functions))
    s.project = .loaded(file, diagnostics: [])
    s.mockStore = file.mocks
    s.focus = .pane(.navigator)
    s.terminalSize = TerminalSize(cols: 120, rows: 40)
    return s
}

// MARK: - Row model

@Suite("F5.4 — Mock Environment row model")
struct MockNavRowModelTests {

    @Test("rows are divider, declared values, declared functions, then the live hint")
    func rowLayout() {
        let s = loadedStateWithMocks()
        let rows = buildMockNavRows(s)
        #expect(rows.first == .divider)
        #expect(rows.contains { if case .value = $0 { return true } else { return false } })
        #expect(rows.contains { if case .function = $0 { return true } else { return false } })
        // No run yet → the live-state empty hint is present.
        #expect(rows.contains(.info("(run to populate live state)")))
    }

    @Test("the divider renders the exact bound string in dim")
    func dividerString() {
        let theme = ThemeState()
        let spans = mockNavRowSpans([.divider], theme: theme)
        #expect(spans.first?.text == "─── Mock Environment ───")
        #expect(spans.first?.style.fg == tokenStyle(.dim, theme: theme).fg)
    }

    @Test("only value and function rows are selectable")
    func selectableRows() {
        let s = loadedStateWithMocks()
        let selectable = mockSelectableRows(s)
        #expect(selectable.count == 2)  // 1 value + 1 function
        #expect(selectable.allSatisfy { $0.isSelectable })
    }

    @Test("no mocks declared → divider + only the live hint, nothing selectable")
    func emptyMockStore() {
        let s = loadedStateWithMocks(values: [], functions: [])
        let rows = buildMockNavRows(s)
        #expect(rows == [.divider, .info("(run to populate live state)")])
        #expect(mockSelectableRows(s).isEmpty)
    }

    @Test("a mockLiveStateReady snapshot replaces the hint with live rows (F5.4)")
    func liveStateReplacesHint() {
        var s = loadedStateWithMocks(values: [], functions: [])
        let live = MockLiveState(
            mockValues: [],
            mockFunctionNames: [],
            userGlobals: [MockLiveValue(name: "result", displayValue: "42")],
            isEmpty: false)
        s = reduce(s, .mockLiveStateReady(live)).0
        let rows = buildMockNavRows(s)
        #expect(rows.contains(.live(name: "result", displayValue: "42")))
        #expect(!rows.contains(.info("(run to populate live state)")))
    }

    @Test("an isEmpty live snapshot keeps the (run to populate live state) hint (DATA-09)")
    func emptyLiveKeepsHint() {
        var s = loadedStateWithMocks(values: [], functions: [])
        s = reduce(s, .mockLiveStateReady(.empty)).0
        #expect(buildMockNavRows(s).contains(.info("(run to populate live state)")))
    }
}

// MARK: - j/k cursor crossing the divider

@Suite("F5.4 — navigator j/k crosses the divider")
struct MockNavCrossingTests {

    @Test("j at the last source steps into the mock section")
    func enterMockSection() {
        var s = loadedStateWithMocks(sourceCount: 2)
        // selectedIndex 0 → j → 1 (last source), still source section.
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.selectedIndex == 1)
        #expect(!s.navigator.inMockSection)
        // j again → cross into the mock section at its first selectable row.
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.inMockSection)
        #expect(s.navigator.mockSelectedIndex == 0)
    }

    @Test("j moves down the mock section and clamps at the last selectable row")
    func moveWithinMockSection() {
        var s = loadedStateWithMocks(sourceCount: 1)
        // 1 source: j → cross into mock (idx 0). 2 selectable mock rows.
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.inMockSection)
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.mockSelectedIndex == 1)
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.mockSelectedIndex == 1)  // clamped (2 rows)
    }

    @Test("k at the first mock row steps back out to the source list")
    func leaveMockSection() {
        var s = loadedStateWithMocks(sourceCount: 1)
        s.navigator.inMockSection = true
        s.navigator.mockSelectedIndex = 1
        s = reduce(s, .key(.char("k"), modifiers: [])).0
        #expect(s.navigator.inMockSection)
        #expect(s.navigator.mockSelectedIndex == 0)
        s = reduce(s, .key(.char("k"), modifiers: [])).0
        #expect(!s.navigator.inMockSection)  // stepped back out
    }

    @Test("j does not enter the mock section when no mocks are declared")
    func noEntryWhenEmpty() {
        var s = loadedStateWithMocks(sourceCount: 1, values: [], functions: [])
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(!s.navigator.inMockSection)  // nothing selectable to land on
    }

    @Test("g returns the cursor to the source section")
    func gReturnsToSources() {
        var s = loadedStateWithMocks(sourceCount: 1)
        s.navigator.inMockSection = true
        s = reduce(s, .key(.char("g"), modifiers: [])).0
        #expect(!s.navigator.inMockSection)
    }

    @Test("Enter in the mock section does not load a source")
    func enterInMockIsNoop() {
        var s = loadedStateWithMocks(sourceCount: 2)
        let originalSelection = s.selection
        s.navigator.inMockSection = true
        s.selection = nil  // prove Enter doesn't set it
        let (next, effects) = reduce(s, .key(.enter, modifiers: []))
        #expect(next.selection == nil)
        #expect(effects.isEmpty)
        _ = originalSelection
    }
}
