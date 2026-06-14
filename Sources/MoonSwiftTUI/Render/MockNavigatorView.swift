// File: Sources/MoonSwiftTUI/Render/MockNavigatorView.swift
// Location: MoonSwiftTUI/Render/
// Role: P2 F5.4 — the navigator's "Mock Environment" section: the
//       `─── Mock Environment ───` divider, the declared `[[mock.value]]` /
//       `[[mock.function]]` rows, and the post-run live state (introspection-
//       backed). Lives in its own file (not the 1914-line Renderer.swift) per
//       §4.7; `renderNavigator` appends this section's spans below the source
//       list and the reducer drives `j`/`k`/`e`/`d` over its selectable rows.
//
//       The row MODEL (`MockNavRow` + `buildMockNavRows` + the selectable-row
//       helpers) lives in App/RowModels/MockNavRowModel.swift (CR-012) so the
//       mock reducers depend on a model-layer function, not this view.
//       `buildMockNavRows` is the single source of truth for the section's row
//       layout — both the renderer (spans + which row is highlighted) and the
//       reducer (the `j`/`k` cursor and the `e`/`d` target) consume it, so the
//       cursor walks exactly the rows the user sees (the same Elm-purity pattern
//       as DebugTabView).
//
//       Live-state rule (DATA-01): the section NEVER mirrors engine value-state.
//       Declared rows come from `MockStore` (definitions); live rows come from a
//       `MockLiveState` introspection snapshot, never from TUI bookkeeping.
//
// Upstream: App/RowModels/MockNavRowModel.swift (MockNavRow / buildMockNavRows),
//           AppState (mockStore, mockLiveState), Renderer style helpers (tokenStyle)
// Downstream: Renderer.swift (renderNavigator)

import Foundation
import MoonSwiftCore
import RatatuiKit

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
