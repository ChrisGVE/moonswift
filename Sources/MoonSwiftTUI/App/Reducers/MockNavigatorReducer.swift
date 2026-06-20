// File: Sources/MoonSwiftTUI/App/Reducers/MockNavigatorReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: P2 F5.4 — navigator cursor movement across the two sections (source list
//       + Mock Environment), kept out of the 2300-line Reducer.swift (§4.7).
//       The source-list movement reuses the existing filtered-index helpers
//       (filteredIDs / filteredPosition / fullOrderIndex); this file adds the
//       divider crossing and the mock-section cursor (NavigatorState.inMockSection
//       / mockSelectedIndex). `j` at the last source steps INTO the mock section
//       (if it has selectable rows); `k` at the first mock row steps back OUT —
//       so `j`/`k` "traverse both sections skipping the divider" (PRD F5.4).
//
// Upstream: AppState, NavigatorState, filteredIDs/filteredPosition/fullOrderIndex
//           (Reducer.swift), mockSelectableRows (App/RowModels/MockNavRowModel.swift)
// Downstream: Reducer.swift reduceNavigatorKey (j / k dispatch)

import Foundation

/// True when the Mock Environment section is shown (only for a loaded project).
private func mockSectionAvailable(_ s: AppState) -> Bool {
    if case .loaded = s.project { return true }
    return false
}

/// Number of SELECTABLE rows in the mock section (declared values + functions).
private func mockSelectableCount(_ s: AppState) -> Int {
    mockSectionAvailable(s) ? mockSelectableRows(s).count : 0
}

/// `j` — move the navigator cursor down, crossing into the mock section at the
/// bottom of the source list.
func reduceNavigatorMoveDown(_ s: AppState) -> AppState {
    var s = s
    let mockCount = mockSelectableCount(s)

    if s.navigator.inMockSection {
        if mockCount > 0 {
            s.navigator.mockSelectedIndex = min(s.navigator.mockSelectedIndex + 1, mockCount - 1)
        }
        return s
    }

    let filtered = filteredIDs(from: s)
    guard !filtered.isEmpty else { return s }
    let currentPos =
        filteredPosition(
            selectedIndex: s.navigator.selectedIndex, filtered: filtered, order: s.navigatorOrder) ?? 0

    if currentPos >= filtered.count - 1 {
        // At the last source: step into the mock section if it has a target.
        if mockCount > 0 {
            s.navigator.inMockSection = true
            s.navigator.mockSelectedIndex = 0
        }
        return s
    }

    s.navigator.selectedIndex = fullOrderIndex(
        filteredPos: currentPos + 1, filtered: filtered, order: s.navigatorOrder)
    return s
}

/// `k` — move the navigator cursor up, crossing back out of the mock section at
/// its first row.
func reduceNavigatorMoveUp(_ s: AppState) -> AppState {
    var s = s

    if s.navigator.inMockSection {
        if s.navigator.mockSelectedIndex <= 0 {
            // At the first mock row: step back out to the (preserved) source row.
            s.navigator.inMockSection = false
        } else {
            s.navigator.mockSelectedIndex -= 1
        }
        return s
    }

    let filtered = filteredIDs(from: s)
    guard !filtered.isEmpty else { return s }
    let currentPos =
        filteredPosition(
            selectedIndex: s.navigator.selectedIndex, filtered: filtered, order: s.navigatorOrder) ?? 0
    s.navigator.selectedIndex = fullOrderIndex(
        filteredPos: max(currentPos - 1, 0), filtered: filtered, order: s.navigatorOrder)
    return s
}
