// File: Sources/MoonSwiftTUI/Render/HelpOverlayView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the `?` help overlay (ux-spec §2.5, §2.3) — the centered 60×20
//       modal listing every keybinding grouped by context. The list overflows
//       the box, so it scrolls (offset clamped by `helpOverlayMaxScrollOffset`,
//       which the reducer also calls). Extracted from Renderer.swift per
//       ARCHITECTURE §4.7 (feature logic stays out of Renderer.swift).
// Upstream: Renderer.render (dispatch), Reducer.reduceHelpOverlayKey (scroll +
//           offset clamp), AppState.helpScrollOffset. Uses the Renderer.swift
//           style helper `tokenStyle`.
// Downstream: CommandInterpreter (applies the emitted .clear/.paragraph).

import RatatuiKit

/// Renders the help overlay at the current scroll offset (ux-spec §2.5).
///
/// The content (`helpOverlayLineSpecs()`) overflows the 60×20 box, so the last
/// overlay row is reserved for a static scroll footer and the content scrolls in
/// the rows above it. The offset is clamped here to mirror the reducer's clamp.
func renderHelpOverlay(
    size: TerminalSize,
    theme: ThemeState,
    scrollOffset: Int
) -> [RenderCommand] {
    // Centered modal, max 60 × 20 (ux-spec §2.5).
    let overlayW: UInt16 = min(60, size.cols)
    let overlayH: UInt16 = min(20, size.rows)
    let overlayX = (size.cols - overlayW) / 2
    let overlayY = (size.rows - overlayH) / 2
    let overlayRect = Rect(x: overlayX, y: overlayY, width: overlayW, height: overlayH)

    let headerStyle = tokenStyle(.dim, theme: theme)
    let keyStyle = tokenStyle(.keyword, theme: theme)
    let descStyle = tokenStyle(.identifier, theme: theme)
    let noteStyle = tokenStyle(.dim, theme: theme)

    // The full content (single source of truth, shared with the reducer's scroll
    // clamp via helpOverlayLineSpecs().count). It overflows the box, so the last
    // overlay row is reserved for a static scroll footer and the content scrolls
    // in the rows above it (ux-spec §2.5).
    let specs = helpOverlayLineSpecs()
    let contentViewport = max(1, Int(overlayH) - 1)  // -1 reserves the footer row
    let maxOffset = max(0, specs.count - contentViewport)
    let offset = min(max(0, scrollOffset), maxOffset)
    let endIdx = min(offset + contentViewport, specs.count)

    func styled(_ spec: HelpLine) -> [Span] {
        switch spec {
        case .header(let title): return [Span(title, style: headerStyle)]
        case .blank: return [Span("", style: headerStyle)]
        case .row(let key, let action):
            return helpRow(key: key, action: action, keyStyle: keyStyle, descStyle: descStyle)
        case .note(let text): return [Span(text, style: noteStyle)]
        }
    }

    var lines: [[Span]] = specs[offset..<endIdx].map(styled)
    // Pad so the footer always lands on the last overlay row.
    while lines.count < contentViewport { lines.append([Span("", style: noteStyle)]) }
    lines.append(
        [Span(helpOverlayFooter(canScrollUp: offset > 0, canScrollDown: offset < maxOffset), style: noteStyle)]
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
    ("x",       "Cancel run / stop debug session"),
    ("l",       "Lint selected source"),
    ("q",       "Quit"),
    ("?",       "Open/close this help"),
    ("<C-g>",   "Start / restart a debug run"),
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
    ("<Enter>", "Load source / invoke a live function"),
    ("o",       "Load selected source (alias)"),
    ("<Space>", "Load selected source (alias)"),
    ("/",       "Filter entries"),
    ("m",       "Open structured-file picker"),
    ("a",       "Add a mock (Value / Function / Namespace)"),
    ("e",       "Edit the selected mock"),
    ("d",       "Delete the selected mock"),
]

// swift-format-ignore
/// Code pane keybinding rows for the help overlay (ux-spec §2.3 code pane table).
private let helpCodePaneKeys: [(String, String)] = [
    ("j/k",     "Scroll down/up one line"),
    ("d/u",     "Scroll down/up half-page"),
    ("f",       "Scroll down full page"),
    ("<C-b>",   "Scroll up full page"),
    ("b",       "Toggle breakpoint on cursor line"),
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
    ("1/2/3",   "Quick-jump to Output/Diagnostics/Debug tab"),
    ("<C-l>",   "Clear output buffer"),
]

// swift-format-ignore
/// Paused-debug keybinding rows for the help overlay (ux-spec §2.3 paused table).
/// Active only while a debug session is paused; the Debug tab is then in the cycle.
private let helpPausedKeys: [(String, String)] = [
    ("s",       "Step over"),
    ("i",       "Step into"),
    ("o",       "Step out"),
    ("c",       "Continue"),
    ("x",       "Stop the debug session"),
    ("g",       "Capture globals (Debug tab)"),
]

/// One ordered line of the help overlay. The spec list returned by
/// `helpOverlayLineSpecs()` is the single source of truth for the overlay's
/// content AND its length: the renderer maps each spec to styled spans, and the
/// reducer reads `.count` (via `helpOverlayMaxScrollOffset`) to clamp the scroll
/// offset — so the two can never disagree on how far the overlay scrolls.
enum HelpLine {
    case header(String)
    case blank
    case row(key: String, action: String)
    case note(String)
}

/// The full ordered content of the help overlay (ux-spec §2.3, §2.5), grouped by
/// context. The `<Tab>` note flags the conditional `[ Debug ]` tab (UX-16).
func helpOverlayLineSpecs() -> [HelpLine] {
    var lines: [HelpLine] = []
    func section(_ title: String, _ keys: [(String, String)]) {
        if !lines.isEmpty { lines.append(.blank) }
        lines.append(.header(title))
        for (key, action) in keys { lines.append(.row(key: key, action: action)) }
    }
    section("Global", helpGlobalKeys)
    section("Navigator", helpNavigatorKeys)
    section("Code pane", helpCodePaneKeys)
    section("Bottom pane", helpBottomPaneKeys)
    section("Paused (debug session)", helpPausedKeys)
    lines.append(.blank)
    lines.append(.note("<Tab>: cycles panes globally; cycles tabs when the bottom pane is focused."))
    lines.append(.note("The [ Debug ] tab is in the bottom-pane cycle only while a debug session is active."))
    return lines
}

/// The largest valid `helpScrollOffset` for a terminal of `terminalRows` rows.
/// Mirrors `renderHelpOverlay`'s window maths (overlay height capped at 20, last
/// row reserved for the scroll footer) so the reducer's clamp is exact.
func helpOverlayMaxScrollOffset(terminalRows: UInt16) -> Int {
    let overlayH = Int(min(20, terminalRows))
    let contentViewport = max(1, overlayH - 1)  // -1 reserves the footer row
    return max(0, helpOverlayLineSpecs().count - contentViewport)
}

/// The static footer row: the scroll keymap plus a more-content indicator.
private func helpOverlayFooter(canScrollUp: Bool, canScrollDown: Bool) -> String {
    let more: String
    switch (canScrollUp, canScrollDown) {
    case (true, true): more = "↑↓ more"
    case (false, true): more = "↓ more"
    case (true, false): more = "↑ more"
    case (false, false): more = ""
    }
    let keys = "↑/↓  C-d/C-u  C-f/C-b  g/G  ·  Esc close"
    return more.isEmpty ? keys : "\(more)  ·  \(keys)"
}
