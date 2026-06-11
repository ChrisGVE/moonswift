// File: Sources/MoonSwiftTUI/Render/NvimDiffView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the side-by-side diff view (P4 F8b) for the .diffView FocusState.
//       Delegated from Renderer.swift when FocusState is .diffView(.building) or
//       .diffView(.ready(DiffViewState)).
//
// Architecture context (ARCHITECTURE.md §10.4.10, §10.8 Inc-11):
//   The diff view occupies the code-pane area (rect passed from Renderer.swift).
//   Two phases:
//     .building — off-thread Task is constructing the DiffViewState; spinner shown.
//     .ready(state) — side-by-side line-level view of left (on-disk) vs right (edited).
//
//   Layout (.ready phase):
//     Row 0: column headers — leftTitle | rightTitle
//     Rows 1…: left and right lines in two equal half-width columns, scrollable.
//     The two halves are separated by a single '│' divider column.
//
//   The diff view uses keyword style for changed lines (those where left ≠ right)
//   and normal style for unchanged lines. Lines present only on one side are
//   shown as empty on the other side with dim style.
//
// Relationships:
//   ← Renderer.swift       (Inc-11 delegation): called for .diffView focus
//   → NvimGridState.swift  (Inc-4): DiffViewState, DiffViewPhase

import MoonSwiftCore
import RatatuiKit

// MARK: - Public entry point

/// Renders the diff view for the given phase into `rect`.
///
/// - `.building`: shows a spinner/loading placeholder in the centre of `rect`.
/// - `.ready(state)`: renders the two-column side-by-side diff.
///
/// - Parameters:
///   - phase: Current diff view phase.
///   - rect: The code-pane inner rect (border already removed by Renderer).
///   - theme: Active theme state.
/// - Returns: Ordered `.cellRun` commands covering `rect`.
func renderDiffView(phase: DiffViewPhase, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    switch phase {
    case .building:
        return renderDiffBuilding(rect: rect, theme: theme)
    case .ready(let state):
        return renderDiffReady(state: state, rect: rect, theme: theme)
    }
}

// MARK: - Building phase

/// Renders a centred spinner placeholder while the diff is being constructed.
private func renderDiffBuilding(rect: Rect, theme: ThemeState) -> [RenderCommand] {
    guard rect.height > 0, rect.width > 0 else { return [] }
    let message = "Building diff…"
    let width = Int(rect.width)
    let text = diffCentred(message, width: width)
    let midRow = UInt16(Int(rect.y) + Int(rect.height) / 2)
    return [.cellRun(col: rect.x, row: midRow, text: text, style: tokenStyle(.dim, theme: theme))]
}

// MARK: - Ready phase

/// Renders the two-column side-by-side diff (header row + content rows).
///
/// Layout:
///   - `halfWidth` = (rect.width - 1) / 2  (−1 for the '│' divider column)
///   - Left column:  cols [rect.x … rect.x + halfWidth − 1]
///   - Divider:      col  [rect.x + halfWidth]          (dim '│')
///   - Right column: cols [rect.x + halfWidth + 1 … rect.x + rect.width − 1]
///
/// Row 0: title headers (keyword style).
/// Rows 1…: content lines scrolled by state.scrollOffset.
private func renderDiffReady(
    state: DiffViewState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    guard rect.height >= 2, rect.width >= 3 else { return [] }

    let totalWidth = Int(rect.width)
    let halfWidth = (totalWidth - 1) / 2
    let rightColX = Int(rect.x) + halfWidth + 1
    let dividerX = Int(rect.x) + halfWidth

    let normalSt = tokenStyle(.paneBg, theme: theme)
    let dimSt = tokenStyle(.dim, theme: theme)
    let changedSt = tokenStyle(.keyword, theme: theme)
    let headerSt = tokenStyle(.focusBorder, theme: theme)

    var commands: [RenderCommand] = []

    // Row 0: column headers.
    let headerRow = rect.y
    commands.append(
        .cellRun(
            col: rect.x,
            row: headerRow,
            text: diffPadded(state.leftTitle, width: halfWidth),
            style: headerSt
        )
    )
    commands.append(
        .cellRun(col: UInt16(dividerX), row: headerRow, text: "│", style: dimSt)
    )
    commands.append(
        .cellRun(
            col: UInt16(rightColX),
            row: headerRow,
            text: diffPadded(state.rightTitle, width: totalWidth - halfWidth - 1),
            style: headerSt
        )
    )

    // Content rows: rows 1 … (rect.height - 1).
    let contentRows = Int(rect.height) - 1
    guard contentRows > 0 else { return commands }

    let maxLines = max(state.leftLines.count, state.rightLines.count)
    let scrollOffset = max(0, min(state.scrollOffset, max(0, maxLines - 1)))
    let rightWidth = totalWidth - halfWidth - 1

    for rowOffset in 0..<contentRows {
        let lineIdx = scrollOffset + rowOffset
        let termRow = UInt16(Int(rect.y) + 1 + rowOffset)

        let leftText = lineIdx < state.leftLines.count ? state.leftLines[lineIdx] : ""
        let rightText = lineIdx < state.rightLines.count ? state.rightLines[lineIdx] : ""

        // Changed lines (where left ≠ right) use changedSt; identical lines use normalSt.
        let isChanged = leftText != rightText
        let contentStyle = isChanged ? changedSt : normalSt
        let absentStyle = dimSt

        // Left column.
        let leftStyle = lineIdx < state.leftLines.count ? contentStyle : absentStyle
        commands.append(
            .cellRun(
                col: rect.x,
                row: termRow,
                text: diffPadded(leftText, width: halfWidth),
                style: leftStyle
            )
        )

        // Divider.
        commands.append(
            .cellRun(col: UInt16(dividerX), row: termRow, text: "│", style: dimSt)
        )

        // Right column.
        let rightStyle = lineIdx < state.rightLines.count ? contentStyle : absentStyle
        commands.append(
            .cellRun(
                col: UInt16(rightColX),
                row: termRow,
                text: diffPadded(rightText, width: rightWidth),
                style: rightStyle
            )
        )
    }

    return commands
}

// MARK: - Layout helpers

/// Pads or truncates `text` to exactly `width` characters.
private func diffPadded(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    if text.count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - text.count)
}

/// Returns `text` horizontally centred in a field of `width` characters.
private func diffCentred(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    guard text.count < width else { return String(text.prefix(width)) }
    let padLeft = (width - text.count) / 2
    let padRight = width - text.count - padLeft
    return String(repeating: " ", count: padLeft) + text + String(repeating: " ", count: padRight)
}
