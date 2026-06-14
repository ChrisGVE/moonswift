// File: Sources/MoonSwiftTUI/Render/HoverView.swift
// Location: MoonSwiftTUI/Render/
// Role: Renders the F7a.2 hover overlay (ux-spec §7.6) — a centered 60×20 modal
//       (the help-overlay geometry, UX-14) showing a symbol's name, signature,
//       and doc string, scrolling when the content overflows. The no-doc case
//       (UX-R3-01) renders the symbol name over the dimmed
//       `(no documentation available)` line. Extracted from Renderer.swift per
//       ARCHITECTURE §4.7. Uses the Renderer.swift style helper `tokenStyle`.
// Upstream: Renderer.render (dispatch), Reducer.reduceHoverOverlayKey (scroll +
//           offset clamp via hoverOverlayMaxScrollOffset), AppState.HoverOverlayState
// Downstream: CommandInterpreter (applies the emitted .clear/.paragraph)

import RatatuiKit

/// The exact string shown when a symbol has no signature/doc (UX-R3-01, NEW
/// ux-spec string §6.5). `K` is never a silent no-op — the overlay still opens
/// and renders this line.
let hoverNoDocumentationLine = "(no documentation available)"

/// One ordered content line of the hover overlay, independent of styling. The
/// spec list is the single source of truth for the overlay's content AND its
/// length: `renderHoverOverlay` styles each spec and `hoverOverlayMaxScrollOffset`
/// reads `.count` to clamp the scroll offset — so the two can never disagree.
enum HoverLine: Equatable {
    case name(String)
    case signature(String)
    case blank
    case doc(String)
    case noDoc
}

/// Builds the ordered hover content for `state`, wrapping the doc string to
/// `width` columns. Used by both the renderer and the scroll-offset clamp.
func hoverContentSpecs(state: HoverOverlayState, width: Int) -> [HoverLine] {
    var specs: [HoverLine] = []
    if let item = state.item {
        specs.append(.name(item.label))
        if let detail = item.detail, !detail.isEmpty {
            specs.append(.signature(detail))
        }
        specs.append(.blank)
        if let doc = item.doc, !doc.isEmpty {
            for wrapped in wrapText(doc, width: width) {
                specs.append(.doc(wrapped))
            }
        } else {
            specs.append(.noDoc)
        }
    } else {
        // No-doc case (UX-R3-01): title with the resolved name when there is one.
        if !state.symbolName.isEmpty {
            specs.append(.name(state.symbolName))
            specs.append(.blank)
        }
        specs.append(.noDoc)
    }
    return specs
}

/// Renders the hover overlay at the current scroll offset (ux-spec §7.6).
///
/// Mirrors `renderHelpOverlay`: centered 60×20 box, the last row reserved for a
/// scroll footer, content scrolling in the rows above. The offset is clamped here
/// to match the reducer's clamp.
func renderHoverOverlay(
    state: HoverOverlayState,
    size: TerminalSize,
    theme: ThemeState
) -> [RenderCommand] {
    let overlayW: UInt16 = min(60, size.cols)
    let overlayH: UInt16 = min(20, size.rows)
    let overlayX = (size.cols - overlayW) / 2
    let overlayY = (size.rows - overlayH) / 2
    let overlayRect = Rect(x: overlayX, y: overlayY, width: overlayW, height: overlayH)

    let nameStyle = tokenStyle(.keyword, theme: theme)
    let signatureStyle = tokenStyle(.dim, theme: theme)
    let docStyle = tokenStyle(.identifier, theme: theme)
    let dimStyle = tokenStyle(.dim, theme: theme)

    let contentWidth = max(1, Int(overlayW) - 2)
    let specs = hoverContentSpecs(state: state, width: contentWidth)
    let contentViewport = max(1, Int(overlayH) - 1)  // -1 reserves the footer row
    let maxOffset = max(0, specs.count - contentViewport)
    let offset = min(max(0, state.scrollOffset), maxOffset)
    let endIdx = min(offset + contentViewport, specs.count)

    func styled(_ spec: HoverLine) -> [Span] {
        switch spec {
        case .name(let text): return [Span(text, style: nameStyle)]
        case .signature(let text): return [Span(text, style: signatureStyle)]
        case .blank: return [Span("", style: docStyle)]
        case .doc(let text): return [Span(text, style: docStyle)]
        case .noDoc: return [Span(hoverNoDocumentationLine, style: dimStyle)]
        }
    }

    var lines: [[Span]] = specs[offset..<endIdx].map(styled)
    while lines.count < contentViewport { lines.append([Span("", style: dimStyle)]) }
    lines.append(
        [Span(hoverFooter(canScrollUp: offset > 0, canScrollDown: offset < maxOffset), style: dimStyle)]
    )

    return [
        .clear(rect: overlayRect),
        .paragraph(rect: overlayRect, lines: lines, block: nil),
    ]
}

/// The largest valid `HoverOverlayState.scrollOffset` for the given terminal.
/// Mirrors `renderHoverOverlay`'s window maths so the reducer's clamp is exact.
func hoverOverlayMaxScrollOffset(state: HoverOverlayState, terminalSize: TerminalSize) -> Int {
    let overlayW = Int(min(60, terminalSize.cols))
    let overlayH = Int(min(20, terminalSize.rows))
    let contentWidth = max(1, overlayW - 2)
    let contentViewport = max(1, overlayH - 1)
    let specs = hoverContentSpecs(state: state, width: contentWidth)
    return max(0, specs.count - contentViewport)
}

/// The static footer row: the scroll keymap plus a more-content indicator.
private func hoverFooter(canScrollUp: Bool, canScrollDown: Bool) -> String {
    let more: String
    switch (canScrollUp, canScrollDown) {
    case (true, true): more = "↑↓ more"
    case (false, true): more = "↓ more"
    case (true, false): more = "↑ more"
    case (false, false): more = ""
    }
    let keys = "↑/↓  ·  Esc close"
    return more.isEmpty ? keys : "\(more)  ·  \(keys)"
}

/// Wraps `text` to `width` columns on whitespace boundaries. A single word longer
/// than `width` is hard-split so no line exceeds the box.
func wrapText(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var current = ""
        for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(word)
            // Hard-split an over-long word.
            while word.count > width {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(String(word.prefix(width)))
                word = String(word.dropFirst(width))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        lines.append(current)
    }
    return lines
}
