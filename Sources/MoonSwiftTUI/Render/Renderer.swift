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

private func renderNavigator(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    // Inner rect (inside the 1-cell border).
    guard let inner = insetRect(rect) else { return [] }

    var items: [Span] = []

    if state.navigatorOrder.isEmpty {
        items.append(Span("(empty)", style: dimStyle(theme)))
    } else {
        for id in state.navigatorOrder {
            let (label, style) = navigatorEntry(id: id, sources: state.sources, theme: theme)
            items.append(Span(label, style: style))
        }
    }

    let selectedIdx = state.navigatorOrder.isEmpty ? nil : state.navigator.selectedIndex
    return [.navigatorList(rect: inner, items: items, selectedIndex: selectedIdx, title: [])]
}

/// Returns the display label and style for one navigator entry.
private func navigatorEntry(
    id: SourceID,
    sources: [SourceID: SourceState],
    theme: ThemeState
) -> (String, CellStyle) {
    switch sources[id] {
    case .loaded(let fragment):
        return (fragment.provenance.displayName, normalStyle(theme))
    case .loading:
        return (id.path, dimStyle(theme))
    case .missing:
        return ("✖ \(id.path)", tokenStyle(.error, theme: theme))
    case .failed(let diagnostic):
        return ("✖ \(id.path): \(diagnostic.message)", tokenStyle(.error, theme: theme))
    case nil:
        return (id.path, normalStyle(theme))
    }
}

// MARK: - Code pane content (ux-spec.md §3.3, §4.2, §6.6)

private func renderCodePane(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    guard let inner = insetRect(rect) else { return [] }

    // No selection: empty-state prompt (ux-spec §3.1).
    guard let selectionID = state.selection else {
        return renderCodePanePrompt(rect: inner, theme: theme)
    }

    switch state.sources[selectionID] {
    case .loaded(let fragment):
        let spans = state.highlight[selectionID] ?? []
        return renderCodePaneSource(
            fragment: fragment,
            codePane: state.codePane,
            highlights: spans,
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

private func renderCodePanePrompt(rect: Rect, theme: ThemeState) -> [RenderCommand] {
    let lines: [[Span]] = [
        [Span("No project file found.", style: normalStyle(theme))],
        [Span("Press <i> to create moonswift.toml, or open a .lua file directly.", style: dimStyle(theme))],
    ]
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

/// Builds a paragraph command from a newline-separated string.
private func paragraphLines(_ text: String, rect: Rect, style: CellStyle) -> [RenderCommand] {
    let lines = text.components(separatedBy: "\n")
        .map { [Span($0, style: style)] }
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

private func renderCodePaneSource(
    fragment: LuaSourceFragment,
    codePane: CodePaneState,
    highlights: [HighlightSpan],
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let lines = fragment.code.components(separatedBy: "\n")
    let visibleRows = Int(rect.height)
    let startLine = min(codePane.scrollOffset, max(0, lines.count - 1))
    let endLine = min(startLine + visibleRows, lines.count)

    // Build a per-line span lookup for the visible range.
    var spansByLine: [Int: [HighlightSpan]] = [:]
    for span in highlights where span.line >= startLine && span.line < endLine {
        spansByLine[span.line, default: []].append(span)
    }

    var commands: [RenderCommand] = []

    for (rowOffset, lineIdx) in (startLine..<endLine).enumerated() {
        let row = rect.y + UInt16(rowOffset)
        let lineText = lineIdx < lines.count ? lines[lineIdx] : ""
        let lineNumber = lineIdx + 1
        let mark = codePane.gutterMarks[lineIdx]
        let isCursor = lineIdx == codePane.cursorLine

        // Gutter column (4 cells wide: 1 mark + 3 line-number digits).
        let gutterWidth: UInt16 = 4
        let gutterText = formatGutterCell(
            lineNumber: lineNumber,
            mark: mark,
            isCursor: isCursor,
            noColor: theme.capability == .noColor
        )
        let gStyle = gutterCellStyle(mark: mark, isCursor: isCursor, theme: theme)
        commands.append(.cellRun(col: rect.x, row: row, text: gutterText, style: gStyle))

        // Code content to the right of the gutter.
        let contentCol = rect.x + gutterWidth
        let contentWidth = Int(rect.width) - Int(gutterWidth)
        guard contentWidth > 0 else { continue }

        let baseStyle = isCursor ? cursorLineStyle(theme) : normalStyle(theme)
        let lineSpans = spansByLine[lineIdx] ?? []
        let lineCommands = renderCodeLine(
            text: lineText,
            spans: lineSpans,
            col: contentCol,
            row: row,
            maxWidth: contentWidth,
            baseStyle: baseStyle,
            theme: theme
        )
        commands += lineCommands
    }

    return commands
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
private func gutterCellStyle(mark: GutterMark?, isCursor: Bool, theme: ThemeState) -> CellStyle {
    if let mark {
        switch mark {
        case .error: return tokenStyle(.error, theme: theme)
        case .warning: return tokenStyle(.warning, theme: theme)
        }
    }
    if isCursor { return cursorLineStyle(theme) }
    return dimStyle(theme)
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
    let contentRect = Rect(x: inner.x, y: inner.y + 1, width: inner.width, height: inner.height - 1)

    let selectedTabIdx = state.bottomPane.activeTab == .output ? 0 : 1
    var commands: [RenderCommand] = [
        .tabBar(rect: tabRow, tabs: ["Output", "Diagnostics"], selectedIndex: selectedTabIdx)
    ]

    switch state.bottomPane.activeTab {
    case .output:
        commands += renderOutputTab(state: state, rect: contentRect, theme: theme)
    case .diagnostics:
        commands += renderDiagnosticsTab(state: state, rect: contentRect, theme: theme)
    }

    return commands
}

private func renderOutputTab(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    let lines = state.bottomPane.outputBuffer.map { [Span($0, style: normalStyle(theme))] }
    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

private func renderDiagnosticsTab(
    state: AppState,
    rect: Rect,
    theme: ThemeState
) -> [RenderCommand] {
    var lines: [[Span]] = []

    // Syntax section (ux-spec §6.5).
    lines.append([Span("── Syntax ──", style: dimStyle(theme))])
    if let diag = state.bottomPane.prePassDiagnostic {
        let prefix = diag.severity == .error ? "E" : "W"
        let colStr = diag.column.map { ":\($0)" } ?? ""
        let text = "\(prefix) \(diag.line)\(colStr) \(diag.message)"
        let style = tokenStyle(diag.severity == .error ? .error : .warning, theme: theme)
        lines.append([Span(text, style: style)])
    } else {
        lines.append([Span("✔ No syntax errors.", style: normalStyle(theme))])
    }

    // Lint section (ux-spec §6.5).
    lines.append([Span("── Lint ──", style: dimStyle(theme))])
    let lintDiags = state.bottomPane.diagnostics
    if lintDiags.isEmpty {
        lines.append([Span("✔ No issues found.", style: normalStyle(theme))])
    } else {
        for d in lintDiags.sorted(by: { $0.line < $1.line }) {
            let prefix = d.severity == .error ? "E" : "W"
            let colStr = d.column.map { ":\($0)" } ?? ""
            let text = "\(prefix) \(d.line)\(colStr) \(d.message)"
            let style = tokenStyle(d.severity == .error ? .error : .warning, theme: theme)
            lines.append([Span(text, style: style)])
        }
    }

    return [.paragraph(rect: rect, lines: lines, block: nil)]
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

private func renderHelpOverlay(size: TerminalSize, theme: ThemeState) -> [RenderCommand] {
    // Centered modal, max 60 × 20 (ux-spec §2.5).
    let overlayW: UInt16 = min(60, size.cols)
    let overlayH: UInt16 = min(20, size.rows)
    let overlayX = (size.cols - overlayW) / 2
    let overlayY = (size.rows - overlayH) / 2
    let overlayRect = Rect(x: overlayX, y: overlayY, width: overlayW, height: overlayH)

    var lines: [[Span]] = []
    let n = normalStyle(theme)
    let d = dimStyle(theme)

    lines.append([Span("Global keys", style: n)])
    // swift-format-ignore
    for (key, action) in helpGlobalKeys {
        lines.append([Span("  \(key.padding(toLength: 10, withPad: " ", startingAt: 0))  \(action)", style: n)])
    }
    lines.append([Span("", style: n)])

    // Explicit note required by ux-spec §2.5.
    lines.append(
        [Span("<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused.", style: d)]
    )

    return [
        .clear(rect: overlayRect),
        .paragraph(rect: overlayRect, lines: lines, block: nil),
    ]
}

// swift-format-ignore
/// Global keybinding rows displayed in the help overlay (ux-spec §2.3).
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

// MARK: - Style helpers

/// Returns the style for the `normal` (identifier) token.
private func normalStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.normal, theme: theme)
}

/// Returns the style for the `dim` token (secondary / inactive content).
private func dimStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.dim, theme: theme)
}

/// Returns the pane border style for focused or unfocused state (ux-spec §1.5).
private func paneBorderStyle(_ theme: ThemeState, focused: Bool) -> CellStyle {
    return focused ? tokenStyle(.focusBorder, theme: theme) : tokenStyle(.border, theme: theme)
}

/// Returns the cursor-line background style (`focus_bg` token, ux-spec §6.6).
private func cursorLineStyle(_ theme: ThemeState) -> CellStyle {
    return tokenStyle(.focusBorder, theme: theme)
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
