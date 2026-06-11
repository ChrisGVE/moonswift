// File: Sources/MoonSwiftTUI/Render/NvimConflictView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the conflict-resolution modal (P4 F8b, ux-spec §7.4) shown when
//       the on-disk file has changed since the fragment was loaded for editing.
//       Delegated from Renderer.swift when FocusState is .conflictModal.
//
// Architecture context (ARCHITECTURE.md §10.8 Inc-11):
//   The conflict modal overlays the code-pane area (same as helpOverlay / picker).
//   It shows a centred two-line prompt using the EXACT ux-spec §7.4 string —
//   snapshot tests pin this string; any deviation is a test failure.
//
//   Normative string (ux-spec §7.4):
//     "File changed externally. [r]eload / [o]verwrite / [d]iff / [c]ancel"
//
// Relationships:
//   ← Renderer.swift   (Inc-11 delegation): called for .conflictModal focus
//   → ConflictModalState (NvimGridState.swift Inc-4): carries modal context
//   → RatatuiKit/CellStyle: target type for styling

import MoonSwiftCore
import RatatuiKit

// MARK: - Public entry point

/// Renders the conflict-resolution modal centred in `rect`.
///
/// The modal is a two-line block:
///   Line 1: "File changed externally."        (dim style)
///   Line 2: "[r]eload / [o]verwrite / [d]iff / [c]ancel"  (keyword style for keys)
///
/// The exact line-2 string is normative per ux-spec §7.4 and snapshot-tested.
/// The two lines are centred vertically in `rect`; each line is centred horizontally.
///
/// - Parameters:
///   - rect: The code-pane rect where the modal is drawn (borders already inset).
///   - theme: Active theme state for styling.
/// - Returns: An ordered sequence of `.cellRun` commands.
func renderConflictModal(rect: Rect, theme: ThemeState) -> [RenderCommand] {
    guard rect.height >= 2, rect.width > 0 else { return [] }

    let width = Int(rect.width)

    // Normative strings — ux-spec §7.4 (NEVER change without updating snapshots).
    let line1 = "File changed externally."
    let line2 = "[r]eload / [o]verwrite / [d]iff / [c]ancel"

    // Centre the two-line block vertically: start at the row that places them
    // in the middle of the rect. When rect.height is even, bias one row above centre.
    let blockStartRow = Int(rect.y) + max(0, (Int(rect.height) - 2) / 2)

    let dimSt = tokenStyle(.dim, theme: theme)
    let normalSt = tokenStyle(.paneBg, theme: theme)

    return [
        .cellRun(
            col: rect.x,
            row: UInt16(blockStartRow),
            text: centred(line1, width: width),
            style: dimSt
        ),
        .cellRun(
            col: rect.x,
            row: UInt16(blockStartRow + 1),
            text: centred(line2, width: width),
            style: normalSt
        ),
    ]
}

// MARK: - Layout helper

/// Returns `text` horizontally centred in a field of `width` characters.
///
/// If `text` is wider than `width` it is truncated (left-biased). The result
/// is always exactly `width` characters so the cell run covers the full rect row.
private func centred(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    guard text.count < width else { return String(text.prefix(width)) }
    let padLeft = (width - text.count) / 2
    let padRight = width - text.count - padLeft
    return String(repeating: " ", count: padLeft) + text + String(repeating: " ", count: padRight)
}
