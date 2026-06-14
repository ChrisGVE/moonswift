// File: Sources/MoonSwiftTUI/Render/DebugTabView.swift
// Location: MoonSwiftTUI/Render/
// Role: The P2 F6.3 Debug-tab view — Locals / Upvalues / Globals / Call-Stack
//       sections, inline table expansion, frame selection, and the §6.9
//       "VM running between pauses" Case-1 / Case-2 states. Lives in its own file
//       (not the 1914-line Renderer.swift) per §4.7 codesize.
//
//       The row MODEL (`DebugRow` + `buildDebugRows`) lives in
//       App/RowModels/DebugRowModel.swift (CR-012) so the reducer depends on a
//       model-layer function, not this view. `buildDebugRows` is the single
//       source of truth for the tab's row layout: both this renderer AND the
//       reducers (frame-select / expand / j-k cursor) call it, so the selectable
//       rows the cursor walks are exactly the rows the user sees — no parallel
//       layout logic that could drift (Elm purity).
//
// Upstream: App/RowModels/DebugRowModel.swift (DebugRow / buildDebugRows),
//           AppState, MoonSwiftCore (DebugSnapshot / DebugVariable / DebugFrame),
//           Renderer.swift style helpers (tokenStyle).
// Downstream: Renderer.swift bottom-pane dispatch (`renderDebugTab`).

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - Renderer

/// Render the Debug tab into `rect` (called from the bottom-pane dispatch).
///
/// Selectable rows are highlighted only in the live paused view; Case-1/Case-2
/// rows are uniformly dimmed. The `j`/`k` cursor lands on the
/// `debugSelectedRow`-th SELECTABLE row, marked with a `❯ ` gutter glyph.
func renderDebugTab(state: AppState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    guard rect.height > 0 else { return [] }

    // No active session at all (defensive — the tab is only shown during one).
    guard state.currentDebugSnapshot != nil || state.activeDebugSessionID != nil else {
        return centeredLine("No debug session.", rect: rect, theme: theme)
    }

    let rows = buildDebugRows(state)
    let paused = state.currentDebugSnapshot != nil

    // Map each row to its selectable ordinal (or nil), so the renderer can mark
    // the cursor row without re-deriving the selectable subsequence.
    var selectableOrdinal = 0
    var ordinalOf: [Int?] = []
    ordinalOf.reserveCapacity(rows.count)
    for row in rows {
        if row.isSelectable {
            ordinalOf.append(selectableOrdinal)
            selectableOrdinal += 1
        } else {
            ordinalOf.append(nil)
        }
    }
    let cursorOrdinal = paused ? state.debugSelectedRow : -1

    // Build the spans for every row, then window to the visible height keeping
    // the cursor row on screen.
    var lines: [[Span]] = []
    var cursorLineIndex = 0
    for (i, row) in rows.enumerated() {
        let isCursor = ordinalOf[i] == cursorOrdinal
        if isCursor { cursorLineIndex = i }
        lines.append(spans(for: row, isCursor: isCursor, dimmed: !paused, theme: theme))
    }

    let height = Int(rect.height)
    let start: Int
    if lines.count <= height {
        start = 0
    } else {
        start = min(max(0, cursorLineIndex - height + 1), lines.count - height)
    }
    let visible = Array(lines[start..<min(lines.count, start + height)])

    return [.paragraph(rect: rect, lines: visible, block: nil)]
}

/// Spans for one row. The cursor row gets a `❯ ` gutter; all others a blank one.
private func spans(for row: DebugRow, isCursor: Bool, dimmed: Bool, theme: ThemeState) -> [Span] {
    let dim = tokenStyle(.dim, theme: theme)
    let normal = dimmed ? dim : tokenStyle(.paneBg, theme: theme)
    let cursorStyle = tokenStyle(.focusBorder, theme: theme)
    let gutter = Span(isCursor ? "❯ " : "  ", style: isCursor ? cursorStyle : normal)

    switch row {
    case .header(let text):
        return [Span("  ", style: dim), Span(text, style: dim)]
    case .info(let text):
        return [Span("  ", style: dim), Span(text, style: dim)]
    case .frame(let f):
        let marker = f.isViewed ? "▸ " : "  "
        return [gutter, Span(marker + f.text, style: normal)]
    case .variable(let v):
        let indent = String(repeating: "  ", count: v.depth)
        let caret = v.expandable ? (v.expanded ? "▾ " : "▸ ") : "  "
        let label: String
        if let keyword = v.keyword {
            label = "\(keyword) \(v.name) = "
        } else {
            label = "\(v.name) = "
        }
        // The value is dim when it is a depth/cycle marker (ux-spec §6.5), else
        // it shares the row style.
        let valueIsMarker = v.displayValue == "(…)" || v.displayValue == "(cycle)"
        let valueStyle = valueIsMarker ? dim : normal
        return [
            gutter,
            Span(indent + caret + label, style: normal),
            Span(v.displayValue, style: valueStyle),
        ]
    }
}

/// A single centered dim line (idle fallback).
private func centeredLine(_ text: String, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    let width = Int(rect.width)
    let padLeft = max(0, (width - text.count) / 2)
    let padded = String(repeating: " ", count: padLeft) + text
    return [.paragraph(rect: rect, lines: [[Span(padded, style: tokenStyle(.dim, theme: theme))]], block: nil)]
}
