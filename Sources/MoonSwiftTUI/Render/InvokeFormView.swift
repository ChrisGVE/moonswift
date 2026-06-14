// File: Sources/MoonSwiftTUI/Render/InvokeFormView.swift
// Location: MoonSwiftTUI/Render/
// Role: P2 F5.3 — renders the Lua-invocation form in the code-pane area
//       (ux-spec §7.5). A single call-expression input line, the focused-field
//       `▸` marker matching the mock form, an optional inline error, and the key
//       hint line. State + behaviour live in InvokeFormState / InvokeFormReducer;
//       this file is render-only.
//
// Upstream: InvokeFormState, Renderer style helpers (tokenStyle)
// Downstream: Renderer.renderCodePane (focus == .invokeForm)

import Foundation
import RatatuiKit

/// Render the invoke form into `rect`.
func renderInvokeForm(form: InvokeFormState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    let normal = tokenStyle(.paneBg, theme: theme)
    let dim = tokenStyle(.dim, theme: theme)
    let focus = tokenStyle(.focusBorder, theme: theme)
    let errorStyle = tokenStyle(.error, theme: theme)

    var lines: [[Span]] = []
    lines.append([Span("Invoke \(form.functionName)", style: normal)])
    lines.append([Span("", style: dim)])
    // The single call-expression input line (focused).
    lines.append([Span("▸ Call: \(form.expression)", style: focus)])
    if let error = form.error {
        lines.append([Span("", style: dim)])
        lines.append([Span(error, style: errorStyle)])
    }
    lines.append([Span("", style: dim)])
    lines.append([Span("Enter invoke   Esc cancel", style: dim)])

    return [.paragraph(rect: rect, lines: lines, block: nil)]
}
