// File: Sources/MoonSwiftTUI/App/RowModels/MockNavRowModel.swift
// Location: MoonSwiftTUI/App/RowModels/
// Role: The Mock-Environment navigator-section row MODEL and its builders —
//       pure `AppState → [MockNavRow]` logic with no rendering. Extracted from
//       Render/MockNavigatorView.swift (CR-012) so the mock reducers depend on a
//       model-layer function, not on a view file. `buildMockNavRows` is the
//       single source of truth for the section's row layout: the renderer (spans
//       + highlight) and the reducer (`j`/`k` cursor, `e`/`d`/`<Enter>` targets)
//       both consume it, so the cursor walks exactly the rows the user sees.
//
//       Live-state rule (DATA-01): the section NEVER mirrors engine value-state.
//       Declared rows come from `MockStore` (definitions); live rows come from a
//       `MockLiveState` introspection snapshot, never from TUI bookkeeping.
//
// Upstream: AppState (mockStore, mockLiveState), MoonSwiftCore
//           (MockValueDef, MockFunctionDef, MockLiveState).
// Downstream: Render/MockNavigatorView.swift (renderNavigator consumes the rows),
//             App/Reducers/MockNavigatorReducer + MockFormReducer + InvokeFormReducer
//             (cursor + `e`/`d`/`<Enter>` targets).

import Foundation
import MoonSwiftCore

// MARK: - Row model

/// One row of the navigator's Mock Environment section.
enum MockNavRow: Equatable {
    /// The `─── Mock Environment ───` section divider (dim, non-selectable).
    case divider
    /// A declared `[[mock.value]]` definition (selectable — `e`/`d` act on it).
    case value(MockValueDef)
    /// A declared `[[mock.function]]` definition (selectable).
    case function(MockFunctionDef)
    /// A post-run live-state entry (introspected; display-only, non-selectable).
    case live(name: String, displayValue: String)
    /// A post-run live-state FUNCTION entry (introspected). Selectable: `<Enter>`
    /// opens the F5.3 invoke form pre-filled with this name (ux-spec §7.5). `e`/`d`
    /// do NOT act on it (those target DECLARED mocks only).
    case liveFunction(name: String)
    /// An informational / empty-state line, e.g. `(run to populate live state)`
    /// (dim, non-selectable).
    case info(String)

    /// Whether the navigator cursor can land here.
    ///
    /// Declared `.value`/`.function` rows are `e`/`d` targets (F5.4); live
    /// `.liveFunction` rows are `<Enter>`-invoke targets (F5.3). Both are
    /// selectable so the `j`/`k` cursor walks them; the reducer routes the action
    /// by row kind (`selectedMockTarget` for `e`/`d`, `selectedLiveFunctionName`
    /// for `<Enter>`).
    var isSelectable: Bool {
        switch self {
        case .value, .function, .liveFunction: return true
        case .divider, .live, .info: return false
        }
    }
}

// MARK: - Row builder

/// Build the Mock Environment section rows: divider, declared values, declared
/// functions, then the live state (or the `(run to populate live state)`
/// empty-state during the no-cache window, DATA-09).
func buildMockNavRows(_ state: AppState) -> [MockNavRow] {
    var rows: [MockNavRow] = [.divider]
    for v in state.mockStore.values { rows.append(.value(v)) }
    for f in state.mockStore.functions { rows.append(.function(f)) }

    if let live = state.mockLiveState, !live.isEmpty {
        for mv in live.mockValues { rows.append(.live(name: mv.name, displayValue: mv.displayValue)) }
        // Registered mock functions and function-typed user globals are the F5.3
        // invoke targets (ux-spec §7.5). A function-typed global renders its value
        // as the `function` sentinel (DATA-N07), which is how we tell it apart from
        // a scalar/table global here.
        for name in live.mockFunctionNames { rows.append(.liveFunction(name: name)) }
        for g in live.userGlobals {
            if g.displayValue == "function" {
                rows.append(.liveFunction(name: g.name))
            } else {
                rows.append(.live(name: g.name, displayValue: g.displayValue))
            }
        }
    } else {
        // No cached snapshot yet (pre-run / mid-run): the bound empty-state.
        rows.append(.info("(run to populate live state)"))
    }
    return rows
}

/// The indices (into `buildMockNavRows`) of the selectable rows, in order — the
/// list the `j`/`k` cursor and `e`/`d` target walk.
func mockSelectableRowIndices(_ rows: [MockNavRow]) -> [Int] {
    rows.indices.filter { rows[$0].isSelectable }
}

/// The selectable rows themselves (declared values/functions, then live
/// functions), in `buildMockNavRows` order.
func mockSelectableRows(_ state: AppState) -> [MockNavRow] {
    buildMockNavRows(state).filter { $0.isSelectable }
}

/// The live function name under the mock-section cursor, or `nil` when the cursor
/// is not on a `.liveFunction` row (it is on a declared mock, or out of range).
///
/// This is the F5.3 `<Enter>`-invoke target lookup, the live-function analogue of
/// `selectedMockTarget` (which serves `e`/`d` on DECLARED mocks only).
func selectedLiveFunctionName(_ state: AppState) -> String? {
    let selectable = mockSelectableRows(state)
    let i = state.navigator.mockSelectedIndex
    guard i >= 0, i < selectable.count else { return nil }
    if case .liveFunction(let name) = selectable[i] { return name }
    return nil
}
