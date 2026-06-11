// File: Sources/MoonSwiftTUI/Render/NvimGridView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the nvim embedded-editor cell grid (P4 F8b) into the code-pane
//       area as a flat sequence of RenderCommand.cellRun values. Delegated from
//       Renderer.swift when FocusState is .nvimPane or .nvimSpawning.
//
// Architecture context (ARCHITECTURE.md §10.4.8, §10.8 Inc-11):
//   - Called ONLY on the UI / render thread (§5.2 thread-class rule).
//   - Walks NvimGridState.cells row-by-row, coalescing adjacent cells that share
//     the same hlId into a single .cellRun command. CellBuffer will further batch
//     these; the coalescing here reduces the number of commands emitted.
//   - HLAttrs from NvimGridState.hlCache are mapped to CellStyle by hlAttrsToCellStyle.
//   - A nil nvimGrid (session not yet attached, or grid not yet received) is
//     rendered as a "Connecting…" placeholder in dimStyle.
//   - MoonSwift's own chrome (title bar, status bar, navigator, bottom pane) wraps
//     the nvim area on all sides; nvim runs with laststatus=0 (§7.4 step 5).
//   - When .nvimSpawning the code-pane shows a spinner line instead of a grid.
//
// Relationships:
//   ← Renderer.swift   (Inc-11 delegation): calls renderNvimPane / renderNvimSpawning
//   → NvimGridState.swift (Inc-4):  NvimGridState, NvimCellState, HLAttrs
//   → RatatuiKit/CellStyle:         target type for hlAttrsToCellStyle

import MoonSwiftCore
import RatatuiKit

// MARK: - Public entry points (called by Renderer.swift delegation)

/// Renders the nvim grid into `rect` using cells from `grid`.
///
/// Walks every row/column of the grid and emits one `.cellRun` per contiguous
/// run of cells that share the same hlId. A nil grid (session not yet ready)
/// shows a "Connecting…" placeholder. The function is UI-thread-only per
/// ARCHITECTURE.md §5.2.
///
/// - Parameters:
///   - grid: The current rendered nvim cell state, or nil before first redraw.
///   - rect: The code-pane inner rect (border already removed by Renderer).
///   - theme: Active theme state for placeholder / fallback styling.
/// - Returns: An ordered sequence of `.cellRun` commands covering `rect`.
func renderNvimGrid(
    grid: NvimGridState?,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    guard let grid else {
        return renderNvimPlaceholder("Connecting…", rect: rect, theme: theme)
    }
    guard grid.width > 0, grid.height > 0 else {
        return renderNvimPlaceholder("Connecting…", rect: rect, theme: theme)
    }
    return renderGridCells(grid: grid, rect: rect, theme: theme)
}

/// Renders a spinner placeholder for the .nvimSpawning focus state.
///
/// Shows "nvim starting…" in the center of the code-pane rect (dim style).
func renderNvimSpawning(rect: Rect, theme: ThemeState) -> [RenderCommand] {
    renderNvimPlaceholder("nvim starting…", rect: rect, theme: theme)
}

// MARK: - Grid cell walk

/// Walks `grid.cells` and emits coalesced `.cellRun` commands into `rect`.
///
/// Coalescing rule: adjacent cells in the same row that share the same `hlId`
/// are merged into a single `.cellRun`. This mirrors how the existing
/// `renderCodeLine` helper coalesces highlight spans, and keeps the command
/// count proportional to style changes rather than character count.
///
/// Bounds: the grid may be larger or smaller than `rect`. The walk is clamped
/// to min(grid.height, rect.height) rows and min(grid.width, rect.width) cols.
private func renderGridCells(
    grid: NvimGridState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let visibleRows = min(grid.height, Int(rect.height))
    let visibleCols = min(grid.width, Int(rect.width))
    guard visibleRows > 0, visibleCols > 0 else { return [] }

    let defaultStyle = nvimDefaultStyle(theme: theme)
    var commands: [RenderCommand] = []
    commands.reserveCapacity(visibleRows * 4)  // rough reserve: a few runs per row

    for rowIdx in 0..<visibleRows {
        let termRow = UInt16(Int(rect.y) + rowIdx)
        let rowCells = grid.cells[rowIdx]

        // Coalesce adjacent cells with the same hlId.
        var runStart = 0
        var runHlId = rowCells.isEmpty ? 0 : rowCells[0].hlId
        var runText = ""

        for colIdx in 0..<visibleCols {
            let cell = rowCells[colIdx]
            if cell.hlId == runHlId {
                runText += cell.text.isEmpty ? " " : cell.text
            } else {
                // Flush the current run.
                if !runText.isEmpty {
                    let style = resolveStyle(hlId: runHlId, grid: grid, defaultStyle: defaultStyle)
                    commands.append(
                        .cellRun(
                            col: UInt16(Int(rect.x) + runStart),
                            row: termRow,
                            text: runText,
                            style: style
                        )
                    )
                }
                runStart = colIdx
                runHlId = cell.hlId
                runText = cell.text.isEmpty ? " " : cell.text
            }
        }
        // Flush the trailing run.
        if !runText.isEmpty {
            let style = resolveStyle(hlId: runHlId, grid: grid, defaultStyle: defaultStyle)
            commands.append(
                .cellRun(
                    col: UInt16(Int(rect.x) + runStart),
                    row: termRow,
                    text: runText,
                    style: style
                )
            )
        }
    }

    return commands
}

// MARK: - HL attribute → CellStyle mapping

/// Resolves an hlId to a CellStyle by looking up the grid's hlCache.
///
/// hlId 0 means "default highlight" (from defaultColorsSet), represented by
/// the theme's normal background style. For non-zero IDs we look up HLAttrs
/// in the cache; a missing entry falls back to `defaultStyle`.
private func resolveStyle(hlId: Int, grid: NvimGridState, defaultStyle: CellStyle) -> CellStyle {
    if hlId == 0 { return defaultStyle }
    guard let attrs = grid.hlCache[hlId] else { return defaultStyle }
    return hlAttrsToCellStyle(attrs, defaultStyle: defaultStyle)
}

/// Maps `HLAttrs` (from nvim's hl_attr_define) to a `CellStyle`.
///
/// Colour encoding follows the shim's contract:
///   - 24-bit RGB: packed as `0x00RRGGBB` (bits 0–23).
///   - `nil` fg/bg: use the `CellStyle` sentinel `0xFFFF_FFFF` (terminal default).
/// The `reverse` attribute swaps fg and bg after mapping.
///
/// Modifier bit encoding matches the shim macro values (Renderer.swift §Style helpers):
///   BOLD = 0x0001, ITALIC = 0x0002, UNDERLINE = 0x0004.
func hlAttrsToCellStyle(_ attrs: HLAttrs, defaultStyle: CellStyle) -> CellStyle {
    var fg: UInt32 = attrs.fg ?? 0xFFFF_FFFF
    var bg: UInt32 = attrs.bg ?? 0xFFFF_FFFF

    if attrs.reverse {
        // Swap fg ↔ bg, treating 0xFFFF_FFFF (default) as transparent.
        let tmpFg = fg
        fg = bg
        bg = tmpFg
    }

    var mods: UInt16 = 0
    if attrs.bold { mods |= 0x0001 }
    if attrs.italic { mods |= 0x0002 }
    if attrs.underline { mods |= 0x0004 }

    return CellStyle(fg: fg, bg: bg, mods: mods)
}

// MARK: - Placeholder helper

/// Renders a single centred text line as a placeholder when the grid is absent.
private func renderNvimPlaceholder(
    _ message: String,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    guard rect.height > 0, rect.width > 0 else { return [] }
    let style = nvimDimStyle(theme: theme)
    let width = Int(rect.width)
    let text: String
    if message.count >= width {
        text = String(message.prefix(width))
    } else {
        let padLeft = (width - message.count) / 2
        let padRight = width - message.count - padLeft
        text =
            String(repeating: " ", count: padLeft)
            + message
            + String(repeating: " ", count: padRight)
    }
    let midRow = UInt16(Int(rect.y) + Int(rect.height) / 2)
    return [.cellRun(col: rect.x, row: midRow, text: text, style: style)]
}

// MARK: - Style shortcuts

/// Default nvim cell style: uses the theme's pane_bg token.
private func nvimDefaultStyle(theme: ThemeState) -> CellStyle {
    tokenStyle(.paneBg, theme: theme)
}

/// Dim style for placeholder text.
private func nvimDimStyle(theme: ThemeState) -> CellStyle {
    tokenStyle(.dim, theme: theme)
}
