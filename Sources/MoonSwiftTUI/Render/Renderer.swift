// File: Sources/MoonSwiftTUI/Render/Renderer.swift
// Location: MoonSwiftTUI/Render/
// Role: Pure (AppState, TerminalSize) → [RenderCommand] function. Computes the
//       three-pane layout geometry, emits chrome commands (title bar, borders,
//       status bar), and dispatches to per-pane helpers for content.
//       Never mutates state, never calls the FFI directly.
//       (ARCHITECTURE.md §2 Renderer row, §3b, ux-spec.md §1–§5)
// Upstream: AppState.swift, RenderCommand.swift, ux-spec.md (binding layout math
//           and literal UI strings — snapshot tests depend on exact strings)
// Downstream: AppDriver.swift (interprets [RenderCommand] → RatatuiKit calls),
//             MoonSwiftTUITests/RendererTests.swift (snapshot assertions)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - Minimum terminal constants (ux-spec.md §1.4)

/// Minimum supported terminal width in columns.
public let minimumTerminalCols: UInt16 = 80
/// Minimum supported terminal rows.
public let minimumTerminalRows: UInt16 = 24

// MARK: - render

/// Converts `state` into a flat sequence of rendering commands for `size`.
///
/// This is a pure function: given the same inputs it always produces the same
/// output. The AppDriver calls it after every drain batch and interprets the
/// returned commands against RatatuiKit (production) or a CellGrid (tests).
///
/// - Parameters:
///   - state: The current application state (read-only).
///   - size: The current terminal dimensions from the last resize event.
/// - Returns: An ordered sequence of `RenderCommand` values covering the
///   full frame, or a single `.belowMinimumSize` command when the terminal
///   is too small to render the normal layout.
public func render(_ state: AppState, size: TerminalSize) -> [RenderCommand] {
    // Guard: below minimum size → special prompt, no layout (ux-spec §1.4).
    guard size.cols >= minimumTerminalCols, size.rows >= minimumTerminalRows else {
        return [.belowMinimumSize(cols: size.cols, rows: size.rows)]
    }

    let layout = computeLayout(size: size, paneLayout: state.paneLayout)
    let theme = state.theme
    let defaultStyle = normalStyle(theme)

    var commands: [RenderCommand] = []
    commands.append(.beginFrame(size: size, defaultStyle: defaultStyle))

    // Chrome: title bar + status bar
    commands += renderTitleBar(state: state, rect: layout.titleBar, theme: theme)
    commands += renderStatusBar(state: state, rect: layout.statusBar, theme: theme)

    // Pane borders
    commands += renderPaneBorders(state: state, layout: layout, theme: theme)

    // Pane content
    commands += renderNavigator(state: state, rect: layout.navigator, theme: theme)
    commands += renderCodePane(state: state, rect: layout.codePane, theme: theme)
    commands += renderBottomPane(state: state, layout: layout, theme: theme)

    // Modal overlays (rendered on top of everything else)
    if state.focus == .helpOverlay {
        commands += renderHelpOverlay(size: size, theme: theme)
    }

    return commands
}

// MARK: - Layout computation (ux-spec.md §1.1 – §1.4)

/// Computes absolute terminal rectangles for every UI region.
///
/// Layout math (ux-spec §1.1–§1.3, all binding):
/// - Title bar: 1 row at the top.
/// - Status bar: 1 row at the bottom.
/// - Usable rows = terminal rows − 2 (chrome rows).
/// - Upper zone: round(usable × 65%) rows (ux-spec §1.4 formula).
/// - Bottom pane: usable − upper, minimum 5 rows; user-adjustable via {/}.
/// - Navigator: [18, 30] columns; user-adjustable via </>.
func computeLayout(size: TerminalSize, paneLayout: PaneLayout) -> LayoutRegion {
    let totalCols = size.cols
    let totalRows = size.rows

    // Chrome: 1 row title + 1 row status bar.
    let usableRows = Int(totalRows) - 2

    // Bottom pane height: user override or ux-spec §1.4 formula.
    // Spec: upper = round(usable × 65%), bottom = usable − upper (minimum 5).
    // round() matches all ux-spec examples: 80×24→upper 14, bottom 8;
    // 200×60→upper 38, bottom 20.
    let rawBottomRows: Int
    if let override = paneLayout.bottomPaneHeight {
        rawBottomRows = override
    } else {
        let upperFromSpec = Int((Double(usableRows) * 0.65).rounded())
        rawBottomRows = max(5, usableRows - upperFromSpec)
    }
    // Clamp: [5, usable − 3] so upper zone always has at least 3 rows.
    let bottomRows = max(5, min(rawBottomRows, usableRows - 3))
    let upperRows = usableRows - bottomRows

    // Navigator width: user-adjustable, clamped to [18, 30].
    let navWidth = UInt16(
        max(PaneLayout.navigatorMin, min(paneLayout.navigatorWidth, PaneLayout.navigatorMax))
    )
    let codePaneWidth = totalCols - navWidth

    // Title bar: row 0.
    let titleBar = Rect(x: 0, y: 0, width: totalCols, height: 1)

    // Upper zone: row 1, full width.
    let upperZone = Rect(x: 0, y: 1, width: totalCols, height: UInt16(upperRows))

    // Navigator: left portion of upper zone.
    let navigator = Rect(x: 0, y: 1, width: navWidth, height: UInt16(upperRows))

    // Code pane: right portion of upper zone.
    let codePane = Rect(x: navWidth, y: 1, width: codePaneWidth, height: UInt16(upperRows))

    // Bottom pane: immediately below upper zone.
    let bottomPaneY = UInt16(1 + upperRows)
    let bottomPane = Rect(x: 0, y: bottomPaneY, width: totalCols, height: UInt16(bottomRows))

    // Status bar: last row.
    let statusBar = Rect(x: 0, y: totalRows - 1, width: totalCols, height: 1)

    let screen = Rect(x: 0, y: 0, width: totalCols, height: totalRows)

    return LayoutRegion(
        screen: screen,
        titleBar: titleBar,
        upperZone: upperZone,
        navigator: navigator,
        codePane: codePane,
        bottomPane: bottomPane,
        statusBar: statusBar
    )
}

// MARK: - Title bar (ux-spec.md §1.6)

private func renderTitleBar(state: AppState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    // Left label: "moonswift" in P1 (project display name reserved for later).
    let leftLabel = "moonswift"

    // Right badges (shown only when relevant, ux-spec §1.6).
    var badges: [String] = []
    if case .loaded(let file, _) = state.project, file.run.config == .unrestricted {
        badges.append("[unrestricted]")
    }
    if case .unsupportedVersion(let v) = state.project {
        badges.append("[Lua \(v): unsupported]")
    }
    if case .quickFile = state.launch {
        badges.append("[no project]")
    }

    return [
        .titleBar(
            rect: rect,
            left: leftLabel,
            badges: badges,
            style: normalStyle(theme)
        )
    ]
}

// MARK: - Pane borders (ux-spec.md §1.5)

private func renderPaneBorders(
    state: AppState,
    layout: LayoutRegion,
    theme: ThemeState
) -> [RenderCommand] {
    var commands: [RenderCommand] = []

    let unfocusedStyle = paneBorderStyle(theme, focused: false)
    let focusedStyle = paneBorderStyle(theme, focused: true)

    let navFocused = state.focus == .pane(.navigator)
    let codeFocused = state.focus == .pane(.codePane)
    let bottomFocused = state.focus == .pane(.bottomPane)

    // Navigator border (rounded, ux-spec §1.5).
    commands.append(
        .block(
            rect: layout.navigator,
            config: BlockConfig(borders: .all, borderType: .rounded),
            borderStyle: navFocused ? focusedStyle : unfocusedStyle
        )
    )

    // Code pane border.
    commands.append(
        .block(
            rect: layout.codePane,
            config: BlockConfig(borders: .all, borderType: .rounded),
            borderStyle: codeFocused ? focusedStyle : unfocusedStyle
        )
    )

    // Bottom pane border.
    commands.append(
        .block(
            rect: layout.bottomPane,
            config: BlockConfig(borders: .all, borderType: .rounded),
            borderStyle: bottomFocused ? focusedStyle : unfocusedStyle
        )
    )

    return commands
}

// MARK: - Navigator content (ux-spec.md §4)

/// Spinner character sets (ux-spec §4.1): braille for truecolor, ASCII for 256/NO_COLOR.
private let spinnerBraille: [Character] = ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
private let spinnerAscii: [Character] = ["|", "/", "-", "\\"]

private func renderNavigator(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    // Inner rect (inside the 1-cell border).
    guard let inner = insetRect(rect) else { return [] }

    let navFocused = state.focus == .pane(.navigator)

    // Determine the filter-active rect (inner minus 1 row for the filter bar)
    // and the content rect available for the list entries.
    let filterActive = state.navigator.filterText != nil
    let listRect: Rect
    let filterBarRow: UInt16?
    if filterActive, inner.height >= 2 {
        // Reserve the last row of the inner rect for the filter bar.
        listRect = Rect(x: inner.x, y: inner.y, width: inner.width, height: inner.height - 1)
        filterBarRow = inner.y + inner.height - 1
    } else {
        listRect = inner
        filterBarRow = nil
    }

    // Build the filtered entry list.
    let filteredIDs = filteredNavigatorIDs(order: state.navigatorOrder, filterText: state.navigator.filterText)

    // Build display items, applying the spinner for loading entries.
    var items: [Span] = []

    // ux-spec §4.2: malformed project overrides the normal list with a single
    // error entry regardless of navigatorOrder / filterText.
    if case .malformed = state.project {
        items.append(Span("Project file error", style: tokenStyle(.error, theme: theme)))
    } else if filteredIDs.isEmpty {
        let msg = state.navigatorOrder.isEmpty ? "(empty)" : "(no match)"
        items.append(Span(msg, style: dimStyle(theme)))
    } else {
        for id in filteredIDs {
            let (label, style) = navigatorEntry(
                id: id,
                sources: state.sources,
                spinnerPhase: state.navigator.spinnerPhase,
                theme: theme
            )
            items.append(Span(label, style: style))
        }
    }

    // Map the logical selectedIndex (over the full order) to a position in the
    // filtered list so the highlight follows the selection correctly.
    let selectedInFiltered: Int?
    if filteredIDs.isEmpty {
        selectedInFiltered = nil
    } else {
        let selectedID =
            state.navigatorOrder.indices.contains(state.navigator.selectedIndex)
            ? state.navigatorOrder[state.navigator.selectedIndex]
            : nil
        if let sid = selectedID, let pos = filteredIDs.firstIndex(of: sid) {
            selectedInFiltered = pos
        } else {
            // Selected entry is filtered out — no highlight.
            selectedInFiltered = nil
        }
    }

    // Highlight style for the selected row depends on navigator focus.
    let highlightStyle = navFocused ? tokenStyle(.focusBg, theme: theme) : dimStyle(theme)

    var commands: [RenderCommand] = [
        .navigatorList(
            rect: listRect,
            items: items,
            selectedIndex: selectedInFiltered,
            title: []
        )
    ]

    // Filter bar: shown at the bottom of the navigator when filter is active.
    if let row = filterBarRow {
        let query = state.navigator.filterText ?? ""
        let prefix = "/"
        let barText = prefix + query
        // Pad or truncate to fit the inner width.
        let width = Int(inner.width)
        let padded: String
        if barText.count < width {
            padded = barText + String(repeating: " ", count: width - barText.count)
        } else {
            padded = String(barText.prefix(width))
        }
        commands.append(.cellRun(col: inner.x, row: row, text: padded, style: highlightStyle))
    }

    return commands
}

/// Returns the source IDs in `order` that match the current `filterText`.
///
/// When `filterText` is nil or empty the full order is returned unchanged.
/// Matching is case-insensitive substring on the entry's display label
/// (filename for whole-lua files; `filename:jsonpath` for structured fields).
func filteredNavigatorIDs(order: [SourceID], filterText: String?) -> [SourceID] {
    guard let query = filterText, !query.isEmpty else { return order }
    let lower = query.lowercased()
    return order.filter { id in
        id.description.lowercased().contains(lower)
    }
}

/// Returns the display label and style for one navigator entry.
///
/// Error state prefixes follow ux-spec §4.2:
/// - `.missing`             → `✖ <filename>`         in error color
/// - `.failed(.error)`      → `✖ <filename>`         in error color (malformed file)
/// - `.failed(.warning)`    → `⚠ <filename>:<path>` in warning color (unresolved/non-string)
/// - `.loading`             → spinner + `<filename>` in dim color
/// - `.loaded`              → `<displayName>`        in normal color
private func navigatorEntry(
    id: SourceID,
    sources: [SourceID: SourceState],
    spinnerPhase: Int,
    theme: ThemeState
) -> (String, CellStyle) {
    switch sources[id] {
    case .loaded(let fragment):
        return (fragment.provenance.displayName, normalStyle(theme))
    case .loading:
        // Show spinner character next to path; spinner phase drives the frame.
        let spinChar = spinnerCharacter(phase: spinnerPhase, capability: theme.capability)
        return ("\(spinChar) \(id.path)", dimStyle(theme))
    case .missing:
        return ("✖ \(id.path)", tokenStyle(.error, theme: theme))
    case .failed(let diagnostic):
        // Severity determines prefix and color (ux-spec §4.2, §8.5).
        if diagnostic.severity == .warning {
            // Unresolved path or non-string field: ⚠ in warning color.
            return ("⚠ \(id.description)", tokenStyle(.warning, theme: theme))
        } else {
            // Malformed structured file: ✖ in error color.
            return ("✖ \(id.path)", tokenStyle(.error, theme: theme))
        }
    case nil:
        return (id.path, normalStyle(theme))
    }
}

/// Returns the appropriate spinner character for the current phase and terminal capability.
///
/// Braille set (`⠁⠂⠄⡀⢀⠠⠐⠈`) for truecolor; ASCII `|/-\` for 256-color and NO_COLOR.
/// Phase wraps at the set length via modulo (ux-spec §4.1).
private func spinnerCharacter(phase: Int, capability: ColorCapability) -> Character {
    if capability == .truecolor {
        let idx = phase % spinnerBraille.count
        return spinnerBraille[idx]
    } else {
        let idx = phase % spinnerAscii.count
        return spinnerAscii[idx]
    }
}

// MARK: - Code pane content (ux-spec.md §3.3, §4.2, §6.6)

private func renderCodePane(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    guard let inner = insetRect(rect) else { return [] }

    // Picker modal: replace code pane with the tree browser (ux-spec §3.6).
    if state.focus == .pickerModal, let picker = state.pickerState {
        return renderPickerPane(picker: picker, rect: inner, theme: theme)
    }

    // Init form modal: replace code pane with the init form (ux-spec §3.1, task 24).
    if state.focus == .initForm, let form = state.initFormState {
        return renderInitForm(form: form, rect: inner, theme: theme)
    }

    // ux-spec §4.2: malformed project file overrides the code pane with a fixed
    // 4-line error block regardless of any current selection.
    if case .malformed(let diag) = state.project {
        let errorStyle = tokenStyle(.error, theme: theme)
        let dimmed = dimStyle(theme)
        let lines: [[Span]] = [
            [Span("✖ Project file error", style: errorStyle)],
            [],
            [Span("moonswift.toml: \(diag.message)", style: errorStyle)],
            [],
            [Span("Edit the file to correct the error, then press <C-r> to reload.", style: dimmed)],
        ]
        return [.paragraph(rect: inner, lines: lines, block: nil)]
    }

    // No selection: show state-appropriate placeholder.
    guard let selectionID = state.selection else {
        // Empty launch mode → empty-state prompt with the init-form hint (ux-spec §3.1).
        if case .empty = state.launch {
            return renderEmptyStatePrompt(rect: inner, theme: theme)
        }
        // Any other launch with no selection yet → neutral placeholder.
        return [.paragraph(rect: inner, lines: [[Span("Loading…", style: dimStyle(theme))]], block: nil)]
    }

    switch state.sources[selectionID] {
    case .loaded(let fragment):
        let spans = state.highlight[selectionID] ?? []
        let allDiags = state.bottomPane.diagnostics
        return renderCodePaneWithSource(
            fragment: fragment,
            codePane: state.codePane,
            highlights: spans,
            diagnostics: allDiags,
            rect: inner,
            theme: theme
        )
    case .missing:
        let msg = "✖ File not found: \(selectionID.path)"
        return [.paragraph(rect: inner, lines: [[Span(msg, style: tokenStyle(.error, theme: theme))]], block: nil)]
    case .failed(let diagnostic):
        let msg = "✖ Cannot parse \(selectionID.path)\n\n\(diagnostic.message)"
        return paragraphLines(msg, rect: inner, style: tokenStyle(.error, theme: theme))
    case .loading, nil:
        return [.paragraph(rect: inner, lines: [[Span("Loading…", style: dimStyle(theme))]], block: nil)]
    }
}

/// Renders the empty-state prompt in the code pane (ux-spec §3.1, §4.1).
///
/// Exact binding text from ux-spec §3.1:
/// ```
/// No project file found.
/// Press <i> to create moonswift.toml, or open a .lua file directly.
/// ```
/// Centered vertically in the available rect (ux-spec §4.1 — "Centered prompt").
private func renderEmptyStatePrompt(rect: Rect, theme: ThemeState) -> [RenderCommand] {
    let line1 = "No project file found."
    let line2 = "Press <i> to create moonswift.toml, or open a .lua file directly."
    let lines: [[Span]] = [
        [Span(line1, style: normalStyle(theme))],
        [Span(line2, style: dimStyle(theme))],
    ]
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

/// Builds a paragraph command from a newline-separated string.
private func paragraphLines(_ text: String, rect: Rect, style: CellStyle) -> [RenderCommand] {
    let lines = text.components(separatedBy: "\n")
        .map { [Span($0, style: style)] }
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

// MARK: - Picker pane renderer (ux-spec §3.6)

/// Renders the structured-file picker in the code-pane area.
///
/// Layout (ux-spec §3.6, binding):
///   Row 0       — title: "  Pick fields: <filename>"
///   Rows 1…n-2  — tree rows with indentation, kind annotation, mark indicator
///   Row n-1     — status line: cursor's normalized JSONPath, or discard prompt
///
/// Row format per tree entry:
///   <indent> <▶/▽> <label>  <annotation>  [●]
/// where:
///   - indent    = 2 spaces per depth level
///   - ▶/▽       = for obj/arr nodes (collapsed/expanded indicator)
///   - annotation= str / int / bool / arr / obj in appropriate style
///   - ●         = mark indicator in added color (only for marked str fields)
///
/// Non-markable rows (non-str) render their annotation in dim style.
/// Pre-existing marks show ● in keyword color; newly added in added color.
/// String rows show the value truncated to fit the line width.
///
/// When the tree is nil (loading): shows "Loading…".
/// When parseError is set: shows "Cannot parse file: <error>" in error color.
/// When awaitingDiscardConfirmation: status row shows the discard prompt.
private func renderPickerPane(picker: PickerState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    // Need at least 3 rows: title + 1 content row + status.
    guard rect.height >= 3 else { return [] }

    var commands: [RenderCommand] = []
    let totalRows = Int(rect.height)

    // Title row.
    let titleText = "  Pick fields: \(picker.filePath)"
    let titleStyle = tokenStyle(.keyword, theme: theme)
    commands.append(
        .cellRun(col: rect.x, row: rect.y, text: pickerPadded(titleText, width: Int(rect.width)), style: titleStyle))

    // Status row (last row of the rect).
    let statusRow = UInt16(Int(rect.y) + totalRows - 1)
    let contentRows = totalRows - 2  // rows between title and status

    // Content area rect (rows 1 … totalRows-2).
    let contentY = Int(rect.y) + 1

    // Parse error: show error message in the content area.
    if let err = picker.parseError {
        let errMsg = "Cannot parse file: \(err)"
        let errStyle = tokenStyle(.error, theme: theme)
        commands.append(
            .cellRun(
                col: rect.x,
                row: UInt16(contentY),
                text: pickerPadded(errMsg, width: Int(rect.width)),
                style: errStyle
            )
        )
        // Status row: Esc hint.
        let statusText = "  <Esc> close"
        commands.append(
            .cellRun(
                col: rect.x,
                row: statusRow,
                text: pickerPadded(statusText, width: Int(rect.width)),
                style: dimStyle(theme)
            )
        )
        return commands
    }

    // Loading state: tree not yet ready.
    guard let tree = picker.tree else {
        commands.append(
            .cellRun(
                col: rect.x,
                row: UInt16(contentY),
                text: pickerPadded("  Loading…", width: Int(rect.width)),
                style: dimStyle(theme)
            )
        )
        commands.append(
            .cellRun(
                col: rect.x,
                row: statusRow,
                text: pickerPadded("", width: Int(rect.width)),
                style: dimStyle(theme)
            )
        )
        return commands
    }

    let rows = tree.visibleRows()

    // Compute the scroll window so the cursor is always visible.
    let scrollStart = pickerScrollStart(cursor: picker.cursorRow, visible: contentRows, total: rows.count)
    let width = Int(rect.width)

    // Build the paragraph lines for the content area. Paragraph renders all
    // lines within the rect, one line per entry, trimming at the rect boundary.
    var contentLines: [[Span]] = []
    for rowOffset in 0..<contentRows {
        let rowIdx = scrollStart + rowOffset

        guard rows.indices.contains(rowIdx) else {
            // Blank row below the tree.
            contentLines.append([Span(String(repeating: " ", count: width), style: normalStyle(theme))])
            continue
        }

        let row = rows[rowIdx]
        let isCursor = rowIdx == picker.cursorRow
        let isMarked = picker.marks.contains(row.normalized)
        let isPreExisting = picker.preExistingMarks.contains(row.normalized)

        let spans = pickerRowSpans(
            row: row,
            isCursor: isCursor,
            isMarked: isMarked,
            isPreExisting: isPreExisting,
            width: width,
            theme: theme
        )
        contentLines.append(spans)
    }

    // Emit tree rows as a paragraph in the content rect.
    let contentRect = Rect(
        x: rect.x,
        y: UInt16(contentY),
        width: rect.width,
        height: UInt16(max(0, contentRows))
    )
    commands.append(.paragraph(rect: contentRect, lines: contentLines, block: nil))

    // Status row: discard confirmation prompt, or current cursor's JSONPath.
    let statusText: String
    if picker.awaitingDiscardConfirmation {
        statusText = "  Discard unsaved field marks? [y/N]"
    } else if rows.indices.contains(picker.cursorRow), rows[picker.cursorRow].kind.isMarkable {
        statusText = "  \(rows[picker.cursorRow].normalized)"
    } else if rows.indices.contains(picker.cursorRow) {
        statusText = "  \(rows[picker.cursorRow].normalized)  (not markable)"
    } else {
        statusText = "  s save  Esc cancel"
    }
    let statusStyle = picker.awaitingDiscardConfirmation ? tokenStyle(.warning, theme: theme) : dimStyle(theme)
    commands.append(
        .cellRun(
            col: rect.x,
            row: statusRow,
            text: pickerPadded(statusText, width: Int(rect.width)),
            style: statusStyle
        )
    )

    return commands
}

/// Computes the scroll-start index so the cursor row is always visible within
/// the `visible`-row content window.
///
/// Simple cursor-follow: the window starts at max(0, cursor - visible + 1) when
/// the cursor is below the window, or stays at min(scrollStart, cursor) when
/// the cursor is above. For the first render, scrollStart starts at 0.
private func pickerScrollStart(cursor: Int, visible: Int, total: Int) -> Int {
    guard visible > 0, total > 0 else { return 0 }
    // Clamp cursor to valid range.
    let c = max(0, min(cursor, total - 1))
    // Keep window: scroll forward when cursor is below bottom, scroll back when above.
    // The simplest correct formula: centre the window around the cursor, biased to start.
    let start = max(0, c - visible + 1)
    return min(start, max(0, total - visible))
}

/// Builds the multi-span row for one picker tree entry.
///
/// Line layout: `<indent><node-prefix><label>  <annotation>  [●]  [value…]`
///   indent       — 2 spaces per depth
///   node-prefix  — "▶ " (collapsed obj/arr), "▽ " (expanded), "  " (scalar)
///   label        — key name or index string
///   annotation   — type tag in dim / normal style
///   mark (●)     — in added or keyword color when marked
///   value        — truncated string value for str rows (dim)
///
/// The cursor row uses the focus_bg background style.
private func pickerRowSpans(
    row: PickerRow,
    isCursor: Bool,
    isMarked: Bool,
    isPreExisting: Bool,
    width: Int,
    theme: ThemeState
) -> [Span] {
    let baseStyle = isCursor ? cursorLineStyle(theme) : normalStyle(theme)
    let dimmed = isCursor ? cursorLineStyle(theme) : dimStyle(theme)
    let annotStyle = row.kind.isMarkable ? baseStyle : dimmed

    // Indentation: 2 spaces per depth.
    let indent = String(repeating: "  ", count: max(0, row.depth))

    // Node prefix: ▶ collapsed, ▽ expanded, empty for scalars.
    let prefix: String
    switch row.kind {
    case .obj, .arr:
        prefix = row.isExpanded ? "▽ " : "▶ "
    default:
        prefix = "  "
    }

    // Mark indicator.
    let markStr: String
    let markStyle: CellStyle
    if isMarked {
        markStr = " ●"
        markStyle = isPreExisting ? tokenStyle(.keyword, theme: theme) : tokenStyle(.added, theme: theme)
    } else {
        markStr = ""
        markStyle = baseStyle
    }

    // Annotation tag.
    let annotStr = "  \(row.kind.annotation)"

    // Value snippet (str rows only, truncated to leave room for other parts).
    let labelPart = indent + prefix + row.label
    let fixedWidth = labelPart.count + annotStr.count + markStr.count
    var valueSnippet = ""
    if let sv = row.stringValue {
        let remaining = width - fixedWidth - 2  // 2 for "  " separator
        if remaining > 3 {
            let truncated = sv.prefix(remaining - 1)
            valueSnippet = "  \(truncated)"
        }
    }

    // Pad to fill the full width so cursor-line background covers the row.
    let totalContent = labelPart.count + annotStr.count + markStr.count + valueSnippet.count
    let padding = String(repeating: " ", count: max(0, width - totalContent))

    var spans: [Span] = [
        Span(labelPart, style: baseStyle),
        Span(annotStr, style: annotStyle),
    ]
    if !markStr.isEmpty {
        spans.append(Span(markStr, style: markStyle))
    }
    if !valueSnippet.isEmpty {
        spans.append(Span(valueSnippet, style: dimmed))
    }
    if !padding.isEmpty {
        spans.append(Span(padding, style: baseStyle))
    }
    return spans
}

/// Pads or truncates `text` to exactly `width` characters for a single cell-run.
private func pickerPadded(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    if text.count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - text.count)
}

// MARK: - Init form renderer (ux-spec §3.1, task 24)

/// Renders the project-init form inline modal in the code-pane area (ux-spec §3.1).
///
/// Layout (binding):
///   Row 0       — title: "  Create moonswift.toml"
///   Row 1       — blank separator
///   Row 2       — "  Lua version:  5.4" (read-only pre-filled, focus_bg when focused)
///   Row 3       — blank separator
///   Row 4       — "  Source files:" header (focus_border color when focused)
///   Rows 5…n-2  — file list entries; `[x]`/`[ ]` prefix; cursor row in focus_bg
///   Row n-1     — contextual hint line (dim)
///
/// When `isScanning` is true, the file list area shows "  Scanning…" (dim).
/// When the candidate list is empty after a scan, shows "  (no files found)".
private func renderInitForm(form: InitFormState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    // Need at least 5 rows: title + sep + luaVersion + sep + hint.
    guard rect.height >= 5 else { return [] }

    let width = Int(rect.width)
    var commands: [RenderCommand] = []
    let titleStyle = tokenStyle(.keyword, theme: theme)
    let normalSt = normalStyle(theme)
    let dimSt = dimStyle(theme)
    let focusSt = cursorLineStyle(theme)

    var termRow = Int(rect.y)
    let maxRow = Int(rect.y) + Int(rect.height) - 1  // last row reserved for hint

    // Row 0: title
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(termRow),
            text: initFormPadded("  Create moonswift.toml", width: width),
            style: titleStyle))
    termRow += 1
    guard termRow <= maxRow else { return commands }

    // Row 1: blank separator
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(termRow),
            text: initFormPadded("", width: width),
            style: normalSt))
    termRow += 1
    guard termRow <= maxRow else { return commands }

    // Row 2: Lua version field
    let luaFocused = form.focusedField == .luaVersion
    let luaRowStyle = luaFocused ? focusSt : normalSt
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(termRow),
            text: initFormPadded("  Lua version:  \(form.luaVersion)", width: width),
            style: luaRowStyle))
    termRow += 1
    guard termRow <= maxRow else { return commands }

    // Row 3: blank separator
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(termRow),
            text: initFormPadded("", width: width),
            style: normalSt))
    termRow += 1
    guard termRow <= maxRow else { return commands }

    // Row 4: Source files header
    let sourcesFocused = form.focusedField == .sourceFiles
    let headerStyle = sourcesFocused ? tokenStyle(.focusBorder, theme: theme) : normalSt
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(termRow),
            text: initFormPadded("  Source files:", width: width),
            style: headerStyle))
    termRow += 1

    // File list area: from termRow to maxRow - 1 (last row reserved for hint).
    let listAreaRows = maxRow - termRow
    if listAreaRows > 0 {
        if form.isScanning {
            commands.append(
                .cellRun(
                    col: rect.x, row: UInt16(termRow),
                    text: initFormPadded("  Scanning…", width: width),
                    style: dimSt))
            termRow += 1
        } else if form.candidateFiles.isEmpty {
            commands.append(
                .cellRun(
                    col: rect.x, row: UInt16(termRow),
                    text: initFormPadded("  (no files found)", width: width),
                    style: dimSt))
            termRow += 1
        } else {
            // Scroll window: ensure the cursor is always visible.
            let visibleStart = max(
                0,
                min(
                    form.fileListCursor - listAreaRows + 1,
                    form.candidateFiles.count - listAreaRows))
            for rowOffset in 0..<listAreaRows {
                let fileIdx = visibleStart + rowOffset
                guard form.candidateFiles.indices.contains(fileIdx) else {
                    commands.append(
                        .cellRun(
                            col: rect.x, row: UInt16(termRow),
                            text: initFormPadded("", width: width),
                            style: normalSt))
                    termRow += 1
                    continue
                }
                let file = form.candidateFiles[fileIdx]
                let isSelected = form.selectedFiles.contains(file)
                let isCursor = sourcesFocused && fileIdx == form.fileListCursor
                let checkMark = isSelected ? "[x]" : "[ ]"
                let rowStyle = isCursor ? focusSt : normalSt
                commands.append(
                    .cellRun(
                        col: rect.x, row: UInt16(termRow),
                        text: initFormPadded("  \(checkMark) \(file)", width: width),
                        style: rowStyle))
                termRow += 1
            }
        }
    }

    // Last row: contextual hint
    let hintText: String
    switch form.focusedField {
    case .luaVersion:
        hintText = "  Enter/Tab next field  Esc cancel"
    case .sourceFiles:
        hintText =
            form.isScanning
            ? "  Esc cancel"
            : "  Space toggle  Enter confirm  Tab prev  Esc cancel"
    }
    commands.append(
        .cellRun(
            col: rect.x, row: UInt16(maxRow),
            text: initFormPadded(hintText, width: width),
            style: dimSt))

    return commands
}

/// Pads or truncates `text` to exactly `width` characters for a single init-form cell-run.
private func initFormPadded(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    if text.count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - text.count)
}

/// Entry point that resolves the hover diagnostic and delegates to the core renderer.
///
/// Called from `renderCodePane` with the full diagnostic list so the hover row
/// can be shown when the cursor is on a diagnostic line (ux-spec §6.7).
private func renderCodePaneWithSource(
    fragment: LuaSourceFragment,
    codePane: CodePaneState,
    highlights: [HighlightSpan],
    diagnostics: [Diagnostic],
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let lines = fragment.code.components(separatedBy: "\n")
    // Clamp scroll and cursor offsets so they never exceed the last valid line.
    let maxOffset = max(0, lines.count - 1)
    let startLine = min(codePane.scrollOffset, maxOffset)
    let cursorLineIdx = min(codePane.cursorLine, maxOffset)

    // Resolve hover: show one diagnostic hover row when the cursor sits on a
    // diagnostic line (ux-spec §6.7).
    let hover = hoverDiagnosticForLine(lineIdx: cursorLineIdx, diagnostics: diagnostics)

    return renderCodePaneSourceWithHover(
        lines: lines,
        startLine: startLine,
        cursorLineIdx: cursorLineIdx,
        codePane: codePane,
        highlights: highlights,
        hoverDiagnostic: hover,
        rect: rect,
        theme: theme
    )
}

/// Renders the code pane source, optionally including a single-row inline
/// diagnostic hover below the cursor line (ux-spec §6.7).
///
/// - Parameters:
///   - lines: The source split into individual lines.
///   - startLine: The first visible line index (0-based, already clamped).
///   - cursorLineIdx: The 0-based cursor line index (already clamped).
///   - codePane: The current code pane scroll/cursor state.
///   - highlights: Syntax spans for the visible area.
///   - hoverDiagnostic: If non-nil, a hover row is inserted directly below the
///     cursor line. Format: `"  ^ <message>"` indented to the diagnostic column.
///   - rect: The inner rectangle of the code pane (border already excluded).
///   - theme: The active theme state.
private func renderCodePaneSourceWithHover(
    lines: [String],
    startLine: Int,
    cursorLineIdx: Int,
    codePane: CodePaneState,
    highlights: [HighlightSpan],
    hoverDiagnostic: HoverDiagnostic?,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let gutterWidth: UInt16 = 4
    let contentWidth = Int(rect.width) - Int(gutterWidth)
    let contentCol = rect.x + gutterWidth
    let visibleRows = Int(rect.height)

    // Build a per-line span lookup for the visible range.
    // We scan ahead by one extra line beyond visibleRows to accommodate the
    // hover row potentially pushing one source line off the bottom.
    let scanEnd = min(startLine + visibleRows + 1, lines.count)
    var spansByLine: [Int: [HighlightSpan]] = [:]
    for span in highlights where span.line >= startLine && span.line < scanEnd {
        spansByLine[span.line, default: []].append(span)
    }

    var commands: [RenderCommand] = []
    // `termRow` tracks which terminal row we are writing into (starts at rect.y).
    var termRow = Int(rect.y)
    var lineIdx = startLine

    while termRow < Int(rect.y) + visibleRows, lineIdx < lines.count {
        let row = UInt16(termRow)
        let lineText = lines[lineIdx]
        let lineNumber = lineIdx + 1
        let mark = codePane.gutterMarks[lineIdx]
        let isCursor = lineIdx == cursorLineIdx
        // Highlight-pulse line: true while `jumpPulseLine` is set and matches this
        // line index. The cursor line takes priority so ▶ always appears on focus_bg
        // (ux-spec §3.5 — discrete single-tick pulse; see design note below).
        let isPulseLine = !isCursor && (codePane.jumpPulseLine == lineIdx)

        // Gutter cell: 1 mark character + 3 right-aligned line-number digits.
        let gutterText = formatGutterCell(
            lineNumber: lineNumber,
            mark: mark,
            isCursor: isCursor,
            noColor: theme.capability == .noColor
        )
        let gutterStyle = gutterCellStyle(mark: mark, isCursor: isCursor, isPulseLine: isPulseLine, theme: theme)
        commands.append(.cellRun(col: rect.x, row: row, text: gutterText, style: gutterStyle))

        // Source line content (right of gutter).
        // Design note: ux-spec §3.5 describes a "transition" from highlight_pulse
        // to normal over 500 ms. The current TickSource fires one 500 ms tick; on
        // that tick `reduceTick` clears `jumpPulseLine`. This gives a discrete
        // highlight_pulse color for ~500 ms then snaps to normal — one step rather
        // than a gradient. A gradient would require sub-500 ms ticks and color
        // interpolation; the spec's word "transitions" is interpreted as a temporal
        // change (not necessarily a smooth gradient) at this scope level.
        if contentWidth > 0 {
            let baseStyle =
                isCursor
                ? cursorLineStyle(theme)
                : isPulseLine
                    ? pulseLineStyle(theme)
                    : normalStyle(theme)
            let lineSpans = spansByLine[lineIdx] ?? []
            commands += renderCodeLine(
                text: lineText,
                spans: lineSpans,
                col: contentCol,
                row: row,
                maxWidth: contentWidth,
                baseStyle: baseStyle,
                theme: theme
            )
        }

        termRow += 1

        // Inline hover row: inserted immediately below the cursor line when
        // the cursor is on a diagnostic line (ux-spec §6.7). The row is only
        // emitted if there is at least one more terminal row available.
        if isCursor, let hover = hoverDiagnostic, termRow < Int(rect.y) + visibleRows {
            let hRow = UInt16(termRow)
            let hoverText = buildHoverText(hover: hover, contentWidth: Int(rect.width))
            let hoverStyle = tokenStyle(.dim, theme: theme)
            commands.append(
                .cellRun(col: rect.x, row: hRow, text: hoverText, style: hoverStyle)
            )
            termRow += 1
            // The hover row uses one extra terminal row. The source line at
            // `lineIdx + 1` will be skipped if the pane is now full, which is
            // correct — the hover visually replaces the next source line.
        }

        lineIdx += 1
    }

    return commands
}

/// A resolved hover diagnostic ready for rendering (ux-spec §6.7).
struct HoverDiagnostic {
    /// Message text displayed in the hover row.
    let message: String
    /// 0-based column of the diagnostic (determines indentation in hover text).
    let column: Int
}

/// Builds the hover row text for a diagnostic (ux-spec §6.7).
///
/// Format: spaces × column + "^ " + message, truncated to `maxWidth`.
/// The caret `^` is placed at the diagnostic column; 2 leading spaces provide
/// visual separation from the gutter (gutter is 4 wide; caret follows the gap).
private func buildHoverText(hover: HoverDiagnostic, contentWidth: Int) -> String {
    let gutterWidth = 4
    let totalWidth = gutterWidth + contentWidth
    // The gutter area of the hover row is left blank (spaces), matching the
    // gutter width. Within the content area the caret is placed at the
    // diagnostic column position (0-based within the line).
    let gutterSpaces = String(repeating: " ", count: gutterWidth)
    let indent = String(repeating: " ", count: max(0, hover.column))
    let hoverContent = indent + "^ " + hover.message
    let full = gutterSpaces + hoverContent
    // Pad or truncate to totalWidth so the hover fills the pane row exactly.
    if full.count < totalWidth {
        return full + String(repeating: " ", count: totalWidth - full.count)
    }
    return String(full.prefix(totalWidth))
}

/// Returns a `HoverDiagnostic` if any diagnostic falls on `lineIdx` (0-based).
///
/// `Diagnostic.line` is 1-based per the MoonSwiftCore convention; the
/// conversion is applied here so all callers can use the renderer's 0-based
/// line indices directly.
private func hoverDiagnosticForLine(
    lineIdx: Int,
    diagnostics: [Diagnostic]
) -> HoverDiagnostic? {
    let oneBased = lineIdx + 1
    guard let diag = diagnostics.first(where: { $0.line == oneBased }) else { return nil }
    return HoverDiagnostic(message: diag.message, column: diag.column ?? 0)
}

/// Formats the 4-character gutter cell for one code line.
///
/// Layout: `[mark][lineNum padded to 3 chars]`.
/// Mark: `E` (error), `W` (warning), `▶`/`>` (cursor), ` ` (blank).
private func formatGutterCell(
    lineNumber: Int,
    mark: GutterMark?,
    isCursor: Bool,
    noColor: Bool
) -> String {
    let markChar: Character
    if let mark {
        // ux-spec §6.6: character markers always present alongside color.
        switch mark {
        case .error: markChar = "E"
        case .warning: markChar = "W"
        }
    } else if isCursor {
        // ux-spec §6.6: ▶ truecolor/256, > NO_COLOR.
        markChar = noColor ? ">" : "▶"
    } else {
        markChar = " "
    }
    let numStr = String(lineNumber)
    // Right-justify line number in 3 characters.
    let padded = numStr.count < 3 ? String(repeating: " ", count: 3 - numStr.count) + numStr : numStr
    return String(markChar) + padded
}

/// Returns the gutter cell style for a line.
///
/// Priority order (ux-spec §6.6, §3.5):
/// 1. Cursor line: `focus_bg` background — cursor mark (`▶`/`>`) uses this style.
/// 2. Pulse line: `highlight_pulse` background while a 500 ms jump pulse is active.
/// 3. Error mark: `error` color for the `E` character.
/// 4. Warning mark: `warning` color for the `W` character.
/// 5. No mark: `gutter_bg` — the gutter background color (ux-spec §8.1).
private func gutterCellStyle(mark: GutterMark?, isCursor: Bool, isPulseLine: Bool, theme: ThemeState) -> CellStyle {
    // Cursor line takes priority so the ▶ mark appears on focus_bg.
    if isCursor { return cursorLineStyle(theme) }
    // Pulse line: jump-target highlighted with highlight_pulse during animation.
    if isPulseLine { return pulseLineStyle(theme) }
    if let mark {
        switch mark {
        case .error: return tokenStyle(.error, theme: theme)
        case .warning: return tokenStyle(.warning, theme: theme)
        }
    }
    return tokenStyle(.gutterBg, theme: theme)
}

/// Renders one source line as a sequence of cell runs with highlight spans.
///
/// Gaps between spans use `baseStyle`; spans use their mapped token style.
/// Cells are written in row-major order for the CellBuffer batching contract.
private func renderCodeLine(
    text: String,
    spans: [HighlightSpan],
    col: UInt16,
    row: UInt16,
    maxWidth: Int,
    baseStyle: CellStyle,
    theme: ThemeState
) -> [RenderCommand] {
    guard !text.isEmpty else { return [] }
    let visible = String(text.prefix(maxWidth))
    let chars = Array(visible)
    guard !chars.isEmpty else { return [] }

    let sorted = spans.sorted { $0.column < $1.column }
    var commands: [RenderCommand] = []
    var charIdx = 0

    for span in sorted {
        let spanStart = span.column
        let spanEnd = span.column + span.length

        // Gap before span: base style.
        if charIdx < spanStart {
            let gapEnd = min(spanStart, chars.count)
            if charIdx < gapEnd {
                let gapText = String(chars[charIdx..<gapEnd])
                commands.append(.cellRun(col: col + UInt16(charIdx), row: row, text: gapText, style: baseStyle))
                charIdx = gapEnd
            }
        }

        // Span content: token style.
        if charIdx < chars.count && spanStart < chars.count {
            let start = max(charIdx, spanStart)
            let end = min(spanEnd, chars.count)
            if start < end {
                let spanText = String(chars[start..<end])
                commands.append(
                    .cellRun(
                        col: col + UInt16(start), row: row, text: spanText,
                        style: tokenStyle(span.tokenKind, theme: theme))
                )
                charIdx = end
            }
        }
    }

    // Trailing content after last span: base style.
    if charIdx < chars.count {
        let trailText = String(chars[charIdx...])
        commands.append(.cellRun(col: col + UInt16(charIdx), row: row, text: trailText, style: baseStyle))
    }

    return commands
}

// MARK: - Bottom pane content (ux-spec.md §6)

private func renderBottomPane(
    state: AppState,
    layout: LayoutRegion,
    theme: ThemeState
) -> [RenderCommand] {
    guard let inner = insetRect(layout.bottomPane), inner.height >= 2 else { return [] }

    let tabRow = Rect(x: inner.x, y: inner.y, width: inner.width, height: 1)
    var commands: [RenderCommand] = []
    commands += renderBottomPaneTabBar(
        state: state, rect: tabRow, width: Int(inner.width), theme: theme)

    // ux-spec §3.7: unsupported Lua version shows a persistent error header
    // pinned between the tab bar and the tab content area.
    var contentStartY = inner.y + 1
    var contentHeight = inner.height - 1

    if case .unsupportedVersion(let v) = state.project, contentHeight >= 1 {
        let headerRect = Rect(x: inner.x, y: contentStartY, width: inner.width, height: 1)
        let headerText = "✖ Lua version \"\(v)\" is not supported. MoonSwift P1 supports Lua 5.4 only."
        let truncated =
            headerText.count > Int(inner.width)
            ? String(headerText.prefix(Int(inner.width)))
            : headerText
        commands.append(
            .cellRun(
                col: headerRect.x, row: headerRect.y, text: truncated,
                style: tokenStyle(.error, theme: theme)
            ))
        contentStartY += 1
        contentHeight -= 1
    }

    guard contentHeight > 0 else { return commands }
    let contentRect = Rect(x: inner.x, y: contentStartY, width: inner.width, height: contentHeight)

    switch state.bottomPane.activeTab {
    case .output:
        commands += renderOutputTab(state: state, rect: contentRect, theme: theme)
    case .diagnostics:
        commands += renderDiagnosticsTab(state: state, rect: contentRect, theme: theme)
    }

    return commands
}

// MARK: Tab bar (ux-spec §6.1)

/// Renders the tab bar row for the bottom pane.
///
/// Tab layout (ux-spec §6.1, §8.5 accessibility):
/// - Active tab: text underlined in `focus_border` color.
/// - Inactive tab: normal style.
/// - Exact tab labels: `[ Output ]` and `[ Diagnostics ]` (ux-spec §6.1).
/// - Source provenance (display name) is right-justified in the same row when
///   a source is loaded (ux-spec §6.1).
private func renderBottomPaneTabBar(
    state: AppState,
    rect: Rect,
    width: Int,
    theme: ThemeState
) -> [RenderCommand] {
    let outputLabel = "[ Output ]"
    let diagLabel = "[ Diagnostics ]"

    // Build the tab line left-to-right with exact labels.
    let activeIsOutput = state.bottomPane.activeTab == .output
    // Two spans: active tab underlined, inactive normal.
    let outputStyle: CellStyle
    let diagStyle: CellStyle
    if activeIsOutput {
        outputStyle = tabActiveStyle(theme)
        diagStyle = normalStyle(theme)
    } else {
        outputStyle = normalStyle(theme)
        diagStyle = tabActiveStyle(theme)
    }

    // Separator between the two tab labels.
    let separator = " "
    let tabsText = outputLabel + separator + diagLabel

    // Right-justified source provenance (ux-spec §6.1).
    let provenance: String?
    if let id = state.selection, case .loaded(let fragment) = state.sources[id] {
        provenance = fragment.provenance.displayName
    } else {
        provenance = nil
    }

    // Total tab row as cell runs: output tab | sep | diagnostics tab | padding | provenance.
    var commands: [RenderCommand] = []
    let row = rect.y
    let startCol = rect.x

    // Output tab span.
    commands.append(
        .cellRun(col: startCol, row: row, text: outputLabel, style: outputStyle)
    )
    // Separator.
    let sepCol = startCol + UInt16(outputLabel.count)
    commands.append(
        .cellRun(col: sepCol, row: row, text: separator, style: normalStyle(theme))
    )
    // Diagnostics tab span.
    let diagCol = sepCol + UInt16(separator.count)
    commands.append(
        .cellRun(col: diagCol, row: row, text: diagLabel, style: diagStyle)
    )

    // Provenance and padding fill the rest of the row.
    let usedCols = tabsText.count
    let remainingCols = max(0, width - usedCols)
    if let prov = provenance, !prov.isEmpty, remainingCols > 0 {
        // Right-justify: pad left so the provenance sits flush at the right edge.
        let truncated = String(prov.suffix(remainingCols))
        let padCount = remainingCols - truncated.count
        let padCol = startCol + UInt16(usedCols)
        if padCount > 0 {
            commands.append(
                .cellRun(
                    col: padCol, row: row,
                    text: String(repeating: " ", count: padCount),
                    style: normalStyle(theme))
            )
        }
        let provCol = padCol + UInt16(padCount)
        commands.append(
            .cellRun(col: provCol, row: row, text: truncated, style: dimStyle(theme))
        )
    } else if remainingCols > 0 {
        // Fill remaining space with spaces.
        let padCol = startCol + UInt16(usedCols)
        commands.append(
            .cellRun(
                col: padCol, row: row,
                text: String(repeating: " ", count: remainingCols),
                style: normalStyle(theme))
        )
    }

    return commands
}

/// Style for the active bottom-pane tab (underlined, `focus_border` color).
///
/// ux-spec §6.1: "Active tab: underlined text in `focus_border` color."
/// §8.5 accessibility: underline is the non-color indicator alongside color.
private func tabActiveStyle(_ theme: ThemeState) -> CellStyle {
    guard let ts = theme.tokens[.focusBorder] else { return CellStyle.default }
    let fg: UInt32 = ts.fg.map { terminalColorToUInt32($0) } ?? 0xFFFF_FFFF
    let bg: UInt32 = ts.bg.map { terminalColorToUInt32($0) } ?? 0xFFFF_FFFF
    // UNDERLINE bit = 0x0004 (matches shim macro encoding in tokenStyle).
    return CellStyle(fg: fg, bg: bg, mods: 0x0004)
}

// MARK: Output tab (ux-spec §6.3, §6.4)

/// Renders the Output tab content.
///
/// Structure:
///   - Run header: `── Run N · HH:MM:SS ──` (ux-spec §6.3, §6.8 narrow elision).
///   - Streamed output lines from `outputBuffer` (after the header).
///   - Run footer appended after the last output line (ux-spec §6.3).
///   - Return value line `→ <display>` before the footer when present.
///
/// The buffer stores output as plain strings including the header and footer
/// lines already appended by the reducer. The renderer displays the buffer
/// contents as-is, scrolled by `scrollOffset`.
private func renderOutputTab(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let bp = state.bottomPane

    // Assemble full view: run header (if a run has started), then buffer lines.
    // The buffer itself already contains footer/notice lines appended by the reducer.
    var allLines: [String] = []

    // Run header (ux-spec §6.3) — present when at least one run has been made.
    if bp.runNumber > 0, let startTime = bp.runStartTime {
        let header = buildRunHeader(runNumber: bp.runNumber, startTime: startTime, width: Int(rect.width))
        allLines.append(header)
    }

    // Buffer lines (output, footer, notices).
    allLines.append(contentsOf: bp.outputBuffer)

    // Scroll window.
    let scrollOffset = min(bp.scrollOffset, max(0, allLines.count - 1))
    let visibleLines = allLines.dropFirst(scrollOffset)

    let lines = visibleLines.map { [Span($0, style: normalStyle(theme))] }
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

/// Builds the run header string for the given run number and start time,
/// applying the narrow-width elision ladder (ux-spec §6.8).
///
/// Elision steps (ux-spec §6.8, all binding):
///
/// | Width | Format                   |
/// |-------|--------------------------|
/// | ≥ 80  | `── Run N · HH:MM:SS ──` |
/// | ≥ 60  | `── Run N · HH:MM ──`    |
/// | ≥ 40  | `── Run N ──`            |
/// | < 40  | `──N──`                  |
func buildRunHeader(runNumber: Int, startTime: Date, width: Int) -> String {
    let calendar = Calendar.current
    let h = calendar.component(.hour, from: startTime)
    let m = calendar.component(.minute, from: startTime)
    let s = calendar.component(.second, from: startTime)
    let hms = String(format: "%02d:%02d:%02d", h, m, s)
    let hm = String(format: "%02d:%02d", h, m)

    if width >= 80 {
        return "── Run \(runNumber) · \(hms) ──"
    } else if width >= 60 {
        return "── Run \(runNumber) · \(hm) ──"
    } else if width >= 40 {
        return "── Run \(runNumber) ──"
    } else {
        return "──\(runNumber)──"
    }
}

// MARK: Run footer helpers (ux-spec §6.3)

/// Builds the run footer string from a `RunOutcome` (ux-spec §6.3 exact format).
///
/// | Outcome              | Footer text                                      |
/// |----------------------|--------------------------------------------------|
/// | `.done`              | `done — Xms`                                     |
/// | `.error`             | `error — <message> → jump to line N`             |
/// | `.cancelled`         | `cancelled`                                      |
/// | `.limitExceeded`     | `instruction limit exceeded (N instructions)` /  |
/// |                      | `wall-clock limit exceeded (Xms)`                |
///
/// The `→ jump to line N` affordance is interactive in the rendered pane:
/// pressing Enter on that line triggers the jump (handled by the reducer's
/// `jumpCodePaneFromBottomPane` function). Exact string per ux-spec §6.3.
func buildRunFooter(outcome: RunOutcome) -> String {
    switch outcome {
    case .done(_, let duration):
        let ms =
            duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return "done — \(ms)ms"
    case .error(let diag, _):
        let lineRef = diag.line > 0 ? " → jump to line \(diag.line)" : ""
        return "error — \(diag.message)\(lineRef)"
    case .cancelled:
        return "cancelled"
    case .limitExceeded(let kind):
        switch kind {
        case .instructions:
            return "instruction limit exceeded"
        case .wallClock:
            return "wall-clock limit exceeded"
        }
    case .engineError(let message):
        // ux-spec §6.3 exact format: "✖ Engine error: <message>"
        return "✖ Engine error: \(message)"
    }
}

// MARK: Diagnostics tab (ux-spec §6.5)

/// Renders the Diagnostics tab content.
///
/// Structure (ux-spec §6.5, all binding exact strings):
///   - Overall empty state (no pre-pass result yet, no lint run): `No diagnostics.` centered.
///   - Syntax pre-pass section: header `── Syntax ──`, then either the
///     pre-pass diagnostic or `✔ No syntax errors.`.
///   - Lint section: header `── Lint ──`, then diagnostics sorted by line or
///     `✔ No issues found.`.
///
/// Each diagnostic line format: `<E|W> <line>:<col> <message> [<code>]`
/// (ux-spec §6.5 — `[<code>]` present only when `code` is non-nil).
private func renderDiagnosticsTab(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let bp = state.bottomPane
    let hasPrePassResult = bp.prePassDiagnostic != nil
    let hasLintResult = !bp.diagnostics.isEmpty

    // Overall empty state (ux-spec §6.5: "No diagnostics." centered).
    if !hasPrePassResult && !hasLintResult {
        let msg = "No diagnostics."
        let lineW = msg.count
        // Center horizontally within the rect.
        let padLeft = max(0, (Int(rect.width) - lineW) / 2)
        let padRight = max(0, Int(rect.width) - padLeft - lineW)
        let centeredText = String(repeating: " ", count: padLeft) + msg + String(repeating: " ", count: padRight)
        return [
            .paragraph(
                rect: rect,
                lines: [[Span(centeredText, style: dimStyle(theme))]],
                block: nil)
        ]
    }

    var lines: [[Span]] = []

    // Syntax section (ux-spec §6.5 — exact header string).
    lines.append([Span("── Syntax ──", style: dimStyle(theme))])
    if let diag = bp.prePassDiagnostic {
        lines.append([Span(formatDiagnosticLine(diag), style: diagStyle(diag, theme: theme))])
    } else {
        lines.append([Span("✔ No syntax errors.", style: normalStyle(theme))])
    }

    // Lint section (ux-spec §6.5 — exact header string).
    lines.append([Span("── Lint ──", style: dimStyle(theme))])
    // ux-spec §4.2: lint engine error takes precedence over normal lint results.
    if case .failed(let msg) = state.lintState {
        lines.append([Span("✖ Lint engine error: \(msg)", style: tokenStyle(.error, theme: theme))])
    } else {
        let lintDiags = bp.diagnostics.sorted { $0.line < $1.line }
        if lintDiags.isEmpty {
            lines.append([Span("✔ No issues found.", style: normalStyle(theme))])
        } else {
            for d in lintDiags {
                lines.append([Span(formatDiagnosticLine(d), style: diagStyle(d, theme: theme))])
            }
        }
    }

    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

/// Formats one diagnostic as the ux-spec §6.5 canonical string.
///
/// Format: `<E|W> <line>:<col> <message> [<code>]`
/// - Column omitted when `nil` (no colon separator).
/// - Code suffix `[<code>]` omitted when `code` is `nil`.
/// - `E` for error severity, `W` for warning (ux-spec §8.5 accessibility rule:
///   character prefix required alongside color).
func formatDiagnosticLine(_ diag: Diagnostic) -> String {
    let prefix = diag.severity == .error ? "E" : "W"
    let colStr = diag.column.map { ":\($0)" } ?? ""
    let codeStr = diag.code.map { " [\($0)]" } ?? ""
    return "\(prefix) \(diag.line)\(colStr) \(diag.message)\(codeStr)"
}

/// Returns the cell style for a diagnostic line (error or warning color).
private func diagStyle(_ diag: Diagnostic, theme: ThemeState) -> CellStyle {
    return tokenStyle(diag.severity == .error ? .error : .warning, theme: theme)
}

// MARK: - Status bar (ux-spec.md §5)

private func renderStatusBar(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let cols = Int(rect.width)

    // Left zone: transient overrides persistent indicators (ux-spec §5.3).
    let leftText: String
    if let transient = state.transient {
        leftText = transient.text
    } else {
        leftText = buildLeftIndicators(state: state, cols: cols)
    }

    // Right zone: contextual hints (ux-spec §5.4), subject to elision ladder.
    let rightText = buildRightHints(state: state, cols: cols)

    let line = buildStatusBarLine(left: leftText, right: rightText, width: cols)
    return [.cellRun(col: rect.x, row: rect.y, text: line, style: normalStyle(theme))]
}

/// Builds the left-zone persistent indicator string (ux-spec §5.2, §5.5).
private func buildLeftIndicators(state: AppState, cols: Int) -> String {
    // Full indicator strings (ux-spec §5.2 — exact literals).
    var full: [String] = []
    // Abbreviated versions for the elision ladder (ux-spec §5.5 step 3).
    var short: [String] = []

    if case .running = state.runState {
        full.append("[running…]")
        short.append("[run]")
    }
    if state.lintState == .running {
        full.append("[linting…]")
        short.append("[lint]")
    }
    if case .unsupportedVersion(let v) = state.project {
        full.append("[Lua \(v): unsupported]")
        short.append("[unsup]")
    }
    if case .quickFile = state.launch {
        full.append("[no project]")
        short.append("[noprj]")
    }
    if case .malformed = state.project {
        full.append("[project error]")
        short.append("[err]")
    }

    if full.isEmpty { return "" }

    // Elision ladder (ux-spec §5.5).
    if cols < 40 {
        // Step 4: single most-critical indicator only.
        return short.first ?? ""
    }
    if cols < 60 {
        // Step 3: abbreviated indicators.
        return short.joined(separator: " ")
    }
    // Steps 1+2: full indicators (right hints handle further elision).
    return full.joined(separator: " ")
}

/// Builds the right-zone contextual hints string (ux-spec §5.4, §5.5).
private func buildRightHints(state: AppState, cols: Int) -> String {
    // Step 2 (ux-spec §5.5): drop all hints when < 80 cols.
    guard cols >= 80 else { return "" }

    let fullHints: String
    let shortHints: String

    switch state.focus {
    case .pane(.navigator):
        fullHints = "j/k navigate  Enter load  m picker  / filter"
        shortHints = "j/k  Enter  m  /"
    case .pane(.codePane):
        fullHints = "j/k scroll  :N jump  n/N diag  r run  l lint"
        shortHints = "j/k  :N  n/N  r  l"
    case .pane(.bottomPane):
        switch state.bottomPane.activeTab {
        case .output:
            fullHints = "j/k scroll  Enter jump  y yank  1/2 tabs  C-l clear"
            shortHints = "j/k  Enter  1/2"
        case .diagnostics:
            fullHints = "j/k scroll  Enter jump  n/N diag  1/2 tabs"
            shortHints = "j/k  Enter  n/N  1/2"
        }
    default:
        return ""
    }

    // Step 1 (ux-spec §5.5): drop long hints, keep short key-only hints at < 100 cols.
    return cols >= 100 ? fullHints : shortHints
}

/// Combines left and right strings into a padded status bar line of exactly `width` chars.
private func buildStatusBarLine(left: String, right: String, width: Int) -> String {
    guard width > 0 else { return "" }

    if right.isEmpty {
        let padded = left + String(repeating: " ", count: max(0, width - left.count))
        return String(padded.prefix(width))
    }

    let totalContent = left.count + right.count
    if totalContent < width {
        // Both fit: pad the gap between them.
        let gap = width - totalContent
        return left + String(repeating: " ", count: gap) + right
    }
    // Right doesn't fit: show only left, padded to width.
    let padded = left + String(repeating: " ", count: max(0, width - left.count))
    return String(padded.prefix(width))
}

// MARK: - Help overlay (ux-spec.md §2.5)

/// Renders the centered help overlay modal (ux-spec §2.5).
///
/// Layout: `Clear` widget behind a bordered content box, centered, max 60 × 20.
/// Sections: global keys, navigator keys, code pane keys, bottom pane keys, then
/// the explicit Tab context-sensitivity note (ux-spec §2.5, §2.2 — binding exact string).
///
/// Styling (ux-spec §8.1 token assignments):
///   - Section headers: `dim` color (secondary labels).
///   - Key names: `keyword` color (matches Lua keyword pink — reused for UI keys).
///   - Descriptions: `identifier` color (Dracula foreground — readable body text).
private func renderHelpOverlay(size: TerminalSize, theme: ThemeState) -> [RenderCommand] {
    // Centered modal, max 60 × 20 (ux-spec §2.5).
    let overlayW: UInt16 = min(60, size.cols)
    let overlayH: UInt16 = min(20, size.rows)
    let overlayX = (size.cols - overlayW) / 2
    let overlayY = (size.rows - overlayH) / 2
    let overlayRect = Rect(x: overlayX, y: overlayY, width: overlayW, height: overlayH)

    let headerStyle = dimStyle(theme)
    let keyStyle = tokenStyle(.keyword, theme: theme)
    let descStyle = tokenStyle(.identifier, theme: theme)
    let noteStyle = dimStyle(theme)

    var lines: [[Span]] = []

    // Each keybinding section: header, then one line per binding.
    // A binding row is two spans: key name (keyword color) + description (identifier color).
    lines.append([Span("Global", style: headerStyle)])
    for (key, action) in helpGlobalKeys {
        lines.append(helpRow(key: key, action: action, keyStyle: keyStyle, descStyle: descStyle))
    }

    lines.append([Span("", style: headerStyle)])
    lines.append([Span("Navigator", style: headerStyle)])
    for (key, action) in helpNavigatorKeys {
        lines.append(helpRow(key: key, action: action, keyStyle: keyStyle, descStyle: descStyle))
    }

    lines.append([Span("", style: headerStyle)])
    lines.append([Span("Code pane", style: headerStyle)])
    for (key, action) in helpCodePaneKeys {
        lines.append(helpRow(key: key, action: action, keyStyle: keyStyle, descStyle: descStyle))
    }

    lines.append([Span("", style: headerStyle)])
    lines.append([Span("Bottom pane", style: headerStyle)])
    for (key, action) in helpBottomPaneKeys {
        lines.append(helpRow(key: key, action: action, keyStyle: keyStyle, descStyle: descStyle))
    }

    // Explicit Tab note — exact string required by ux-spec §2.5, §2.2.
    lines.append([Span("", style: noteStyle)])
    lines.append(
        [Span("<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused.", style: noteStyle)]
    )

    return [
        .clear(rect: overlayRect),
        .paragraph(rect: overlayRect, lines: lines, block: nil),
    ]
}

/// Builds one two-span help row: key name left-padded to 10 chars, then description.
///
/// The split into two `Span`s lets the production renderer apply distinct colors
/// without any post-processing: key names use `keyword`, descriptions `identifier`.
private func helpRow(key: String, action: String, keyStyle: CellStyle, descStyle: CellStyle) -> [Span] {
    // Pad key name to 10 characters for column-aligned display.
    let paddedKey = "  " + key.padding(toLength: 10, withPad: " ", startingAt: 0)
    let description = "  " + action
    return [Span(paddedKey, style: keyStyle), Span(description, style: descStyle)]
}

// swift-format-ignore
/// Global keybinding rows for the help overlay (ux-spec §2.3 global table).
private let helpGlobalKeys: [(String, String)] = [
    ("r",       "Run selected source"),
    ("x",       "Cancel run"),
    ("l",       "Lint selected source"),
    ("q",       "Quit"),
    ("?",       "Open/close this help"),
    ("<C-p>",   "Open project file in $EDITOR"),
    ("<C-r>",   "Reload project file"),
    ("<Tab>",   "Cycle panes / cycle bottom-pane tabs"),
    ("<S-Tab>", "Reverse-cycle panes"),
    ("<C-h>",   "Jump focus to navigator"),
    ("<C-l>",   "Jump focus to code pane"),
    ("<C-j>",   "Jump focus to bottom pane"),
]

// swift-format-ignore
/// Navigator keybinding rows for the help overlay (ux-spec §2.3 navigator table).
private let helpNavigatorKeys: [(String, String)] = [
    ("j/k",     "Move selection down/up"),
    ("g",       "Jump to first entry"),
    ("G",       "Jump to last entry"),
    ("<Enter>", "Load selected source"),
    ("o",       "Load selected source (alias)"),
    ("<Space>", "Load selected source (alias)"),
    ("/",       "Filter entries"),
    ("m",       "Open structured-file picker"),
]

// swift-format-ignore
/// Code pane keybinding rows for the help overlay (ux-spec §2.3 code pane table).
private let helpCodePaneKeys: [(String, String)] = [
    ("j/k",     "Scroll down/up one line"),
    ("d/u",     "Scroll down/up half-page"),
    ("f/b",     "Scroll down/up full page"),
    ("g/G",     "Jump to top/bottom"),
    (":N",      "Jump to line N"),
    ("n/N",     "Jump to next/previous diagnostic"),
    ("[d",      "Jump to first diagnostic"),
    ("]d",      "Jump to last diagnostic"),
]

// swift-format-ignore
/// Bottom pane keybinding rows for the help overlay (ux-spec §2.3 bottom pane table).
private let helpBottomPaneKeys: [(String, String)] = [
    ("j/k",     "Scroll down/up"),
    ("<Enter>", "Jump code pane to error line"),
    ("y",       "Yank focused line to clipboard"),
    ("1/2",     "Quick-jump to Output/Diagnostics tab"),
    ("<C-l>",   "Clear output buffer"),
]

// MARK: - Style helpers

/// Returns the style for the `pane_bg` token (default pane background + text).
private func normalStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.paneBg, theme: theme)
}

/// Returns the style for the `dim` token (secondary / inactive content).
private func dimStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.dim, theme: theme)
}

/// Returns the pane border style for focused or unfocused state (ux-spec §1.5).
///
/// Focused pane border uses `focus_border` (ux-spec §1.5).
/// Unfocused pane border: ux-spec §1.5 mentions a "border" token, but the
/// canonical 18-token table (ux-spec §8.1) contains no `border` entry. The
/// closest semantic match for secondary chrome is `dim` — non-emphasized UI
/// elements per §8.1. Using `dim` keeps unfocused borders visually recessed
/// without importing a color that belongs to the `running` indicator.
private func paneBorderStyle(_ theme: ThemeState, focused: Bool) -> CellStyle {
    return focused ? tokenStyle(.focusBorder, theme: theme) : tokenStyle(.dim, theme: theme)
}

/// Returns the cursor-line background style (`focus_bg` token, ux-spec §6.6).
///
/// ux-spec §6.6 table: "Cursor line ▶ gutter mark: `focus_bg` token".
/// ux-spec §8.1: `focus_bg` = `#44475A` (Dracula selection) background.
private func cursorLineStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.focusBg, theme: theme)
}

/// Returns the 500 ms highlight-pulse line style (`highlight_pulse` token, ux-spec §3.5, §8.1).
///
/// Applied to the jump-target line while `codePane.jumpPulseLine` is set. The reducer
/// clears `jumpPulseLine` on the first 500 ms tick, reverting the line to `normalStyle`.
/// ux-spec §8.1: `highlight_pulse` = `#6272A4` (Dracula comment blue) background.
private func pulseLineStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.highlightPulse, theme: theme)
}

/// Resolves a `ThemeToken` to a `CellStyle` from the active theme table.
///
/// Falls back to the terminal-default style (no color, no modifiers) when
/// the token is not registered in the theme. Style modifier encoding
/// matches the shim's `BOLD`/`ITALIC`/`UNDERLINE` macro values (bits 0–2).
func tokenStyle(_ token: ThemeToken, theme: ThemeState) -> CellStyle {
    guard let ts = theme.tokens[token] else { return CellStyle.default }
    let fg: UInt32 = ts.fg.map { terminalColorToUInt32($0) } ?? 0xFFFF_FFFF
    let bg: UInt32 = ts.bg.map { terminalColorToUInt32($0) } ?? 0xFFFF_FFFF
    // Modifier bit encoding: BOLD=0x0001, ITALIC=0x0002, UNDERLINE=0x0004.
    var mods: UInt16 = 0
    if ts.bold { mods |= 0x0001 }
    if ts.italic { mods |= 0x0002 }
    if ts.underline { mods |= 0x0004 }
    return CellStyle(fg: fg, bg: bg, mods: mods)
}

/// Converts a `TerminalColor` to the `CellStyle`-internal UInt32 encoding.
///
/// Encoding: `0x00RRGGBB` for RGB; `0x0100_00NN` for a 256-color index (top
/// byte = `0x01` marks indexed color, bottom byte = palette index). Both
/// conventions are defined by the shim's `RffiStyle.fg/bg` field contract.
private func terminalColorToUInt32(_ color: TerminalColor) -> UInt32 {
    switch color {
    case .rgb(let r, let g, let b):
        return (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    case .index(let i):
        return 0x0100_0000 | UInt32(i)
    }
}

// MARK: - Rect helpers

/// Returns the inner rectangle after removing a 1-cell border on all sides.
///
/// Returns `nil` when the rectangle is too small to have a visible inner area
/// (width or height < 2).
private func insetRect(_ rect: Rect) -> Rect? {
    guard rect.width >= 2, rect.height >= 2 else { return nil }
    return Rect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: rect.height - 2)
}
