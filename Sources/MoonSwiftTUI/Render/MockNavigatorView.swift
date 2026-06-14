// File: Sources/MoonSwiftTUI/Render/MockNavigatorView.swift
// Location: MoonSwiftTUI/Render/
// Role: P2 F5.4 — the navigator's "Mock Environment" section: the
//       `─── Mock Environment ───` divider, the declared `[[mock.value]]` /
//       `[[mock.function]]` rows, and the post-run live state (introspection-
//       backed). Lives in its own file (not the 1914-line Renderer.swift) per
//       §4.7; `renderNavigator` appends this section's spans below the source
//       list and the reducer drives `j`/`k`/`e`/`d` over its selectable rows.
//
//       `buildMockNavRows` is the single source of truth for the section's row
//       layout — both the renderer (spans + which row is highlighted) and the
//       reducer (the `j`/`k` cursor and the `e`/`d` target) consume it, so the
//       cursor walks exactly the rows the user sees (the same Elm-purity pattern
//       as DebugTabView).
//
//       Live-state rule (DATA-01): the section NEVER mirrors engine value-state.
//       Declared rows come from `MockStore` (definitions); live rows come from a
//       `MockLiveState` introspection snapshot (`registeredValueServerNames` /
//       `globalValue` etc.), never from TUI bookkeeping.
//
// Upstream: AppState (mockStore, mockLiveState), MockValueDef, MockFunctionDef,
//           MockLiveState, Renderer style helpers (tokenStyle)
// Downstream: Renderer.swift (renderNavigator), Reducer.swift (navigator keys)

import Foundation
import MoonSwiftCore
import RatatuiKit

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

// MARK: - Rendering

/// Render the Mock Environment section to `[Span]` (one span per row), in the
/// same order `buildMockNavRows` produces. The renderer appends these below the
/// source list; the combined `selectedIndex` highlights the active row.
func mockNavRowSpans(_ rows: [MockNavRow], theme: ThemeState) -> [Span] {
    rows.map { row in
        switch row {
        case .divider:
            return Span("─── Mock Environment ───", style: tokenStyle(.dim, theme: theme))
        case .value(let def):
            return Span("\(def.namespace).\(def.path) = \(def.value)", style: tokenStyle(.paneBg, theme: theme))
        case .function(let def):
            return Span("\(def.name) (\(def.behavior.rawValue))", style: tokenStyle(.paneBg, theme: theme))
        case .live(let name, let displayValue):
            return Span("\(name) = \(displayValue)", style: tokenStyle(.dim, theme: theme))
        case .liveFunction(let name):
            // Same text + dim style as a `.live(name, "function")` row so the
            // section's appearance is unchanged; selectability is the only
            // difference (the cursor can now land here for `<Enter>`-invoke).
            return Span("\(name) = function", style: tokenStyle(.dim, theme: theme))
        case .info(let text):
            return Span(text, style: tokenStyle(.dim, theme: theme))
        }
    }
}
