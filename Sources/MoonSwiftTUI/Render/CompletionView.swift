// File: Sources/MoonSwiftTUI/Render/CompletionView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the F7a.2 completion popup (ux-spec §7.6) — a small floating
//       list anchored below the code-pane cursor, showing at most
//       `completionPopupMaxVisible` items with a scrolling window around the
//       selection. Extracted from Renderer.swift per ARCHITECTURE §4.7. Uses
//       the Renderer.swift style helper `tokenStyle`.
// Upstream: Renderer.render (dispatch), Reducer.reduceCompletionPopupKey
//           (selection/scroll), AppState.CompletionPopupState
// Downstream: CommandInterpreter (applies the emitted .clear/.paragraph)

import RatatuiKit

/// Maximum number of completion rows visible at once (ux-spec §7.6 "max 10
/// items visible"). The reducer's scroll-window maths references this so the
/// view and reducer never disagree on how far the popup scrolls.
let completionPopupMaxVisible = 10

/// Renders the completion popup below the code-pane cursor (ux-spec §7.6).
///
/// Geometry: the popup is anchored one row below the cursor's screen position,
/// left-aligned a couple of columns into the code pane, capped at 50 columns and
/// `completionPopupMaxVisible` rows. When it would overflow the status bar it
/// flips above the cursor instead. The selected row is drawn with the cursor-row
/// background token (`focus_bg`), matching the navigator selection convention.
func renderCompletionPopup(
    state: CompletionPopupState,
    codePaneRect: Rect,
    cursorLine: Int,
    codeScroll: Int,
    terminalSize: TerminalSize,
    theme: ThemeState
) -> [RenderCommand] {
    let visibleCount = min(state.items.count, completionPopupMaxVisible)
    guard visibleCount > 0 else { return [] }

    // Popup width: capped at 50, kept inside the code pane.
    let popupW = max(10, min(50, Int(codePaneRect.width) - 4))

    // Cursor screen row = code-pane content top (+1 for the border) plus the
    // cursor's distance below the first visible line.
    let cursorScreenRow = Int(codePaneRect.y) + 1 + max(0, cursorLine - codeScroll)
    let belowY = cursorScreenRow + 1
    let maxY = Int(terminalSize.rows) - 1 - visibleCount  // keep above the status bar
    let popupY: Int
    if belowY <= maxY {
        popupY = belowY
    } else {
        // Flip above the cursor when there is no room below.
        popupY = max(Int(codePaneRect.y) + 1, cursorScreenRow - visibleCount)
    }
    let popupX = Int(codePaneRect.x) + 2
    let rect = Rect(
        x: UInt16(max(0, popupX)),
        y: UInt16(max(0, popupY)),
        width: UInt16(popupW),
        height: UInt16(visibleCount)
    )

    let selectedStyle = tokenStyle(.focusBg, theme: theme)
    let labelStyle = tokenStyle(.identifier, theme: theme)
    let detailStyle = tokenStyle(.dim, theme: theme)

    // Clamp the scroll window defensively (the reducer keeps it valid, but
    // render is pure over arbitrary state).
    let start = min(max(0, state.scrollOffset), max(0, state.items.count - visibleCount))
    let end = min(start + visibleCount, state.items.count)

    var lines: [[Span]] = []
    for absIndex in start..<end {
        let item = state.items[absIndex]
        let selected = absIndex == state.selectedIndex
        let nameStyle = selected ? selectedStyle : labelStyle
        let valueStyle = selected ? selectedStyle : detailStyle
        var spans: [Span] = [Span(item.label, style: nameStyle)]
        if let detail = item.detail, !detail.isEmpty {
            spans.append(Span("  " + detail, style: valueStyle))
        }
        lines.append(spans)
    }

    return [
        .clear(rect: rect),
        .paragraph(rect: rect, lines: lines, block: nil),
    ]
}
