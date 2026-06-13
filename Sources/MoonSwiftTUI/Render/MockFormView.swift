// File: Sources/MoonSwiftTUI/Render/MockFormView.swift
// Location: MoonSwiftTUI/Render/
// Role: P2 F5.4 — renders the Mock Environment add/edit form in the code-pane
//       area (ux-spec §7.1). Two stages: the `Add mock — Value / Function /
//       Namespace` type popup, and the inline field editor with the focused
//       field marked. Field labels are the bound ux-spec strings. State +
//       behaviour live in MockFormState / MockFormReducer; this file is render-only.
//
// Upstream: MockFormState, Renderer style helpers (tokenStyle)
// Downstream: Renderer.renderCodePane (focus == .mockForm)

import Foundation
import MoonSwiftCore
import RatatuiKit

/// Render the mock form into `rect`.
func renderMockForm(form: MockFormState, rect: Rect, theme: ThemeState) -> [RenderCommand] {
    let normal = tokenStyle(.paneBg, theme: theme)
    let dim = tokenStyle(.dim, theme: theme)
    let focus = tokenStyle(.focusBorder, theme: theme)
    let errorStyle = tokenStyle(.error, theme: theme)

    var lines: [[Span]] = []

    switch form.stage {
    case .typePopup:
        // Bound popup title (ux-spec §6.5).
        lines.append([Span("Add mock — Value / Function / Namespace", style: normal)])
        lines.append([Span("", style: dim)])
        lines.append([Span("  v  Value", style: normal)])
        lines.append([Span("  f  Function", style: normal)])
        lines.append([Span("  n  Namespace", style: normal)])
        lines.append([Span("", style: dim)])
        lines.append([Span("v/f/n select   Esc cancel", style: dim)])

    case .fields:
        let kindLabel = form.kind == .value ? "value" : "function"
        let verb = form.editingIndex == nil ? "Add" : "Edit"
        lines.append([Span("\(verb) mock \(kindLabel)", style: normal)])
        lines.append([Span("", style: dim)])
        for (i, fl) in formFields(form).enumerated() {
            let marker = i == form.focusedField ? "▸ " : "  "
            let style = i == form.focusedField ? focus : normal
            lines.append([Span("\(marker)\(fl.label): \(fl.value)", style: style)])
        }
        if let error = form.error {
            lines.append([Span("", style: dim)])
            lines.append([Span(error, style: errorStyle)])
        }
        lines.append([Span("", style: dim)])
        lines.append([Span("Tab next   Space/←/→ cycle   Enter confirm   Esc cancel", style: dim)])
    }

    return [.paragraph(rect: rect, lines: lines, block: nil)]
}

/// The (label, value) pairs for the current kind, in focus order. Labels are the
/// bound ux-spec §6.5 form labels.
private func formFields(_ form: MockFormState) -> [(label: String, value: String)] {
    switch form.kind {
    case .value:
        return [
            ("Namespace", form.namespace),
            ("Key path", form.keyPath),
            ("Type", form.valueType.rawValue),
            ("Value", form.valueExpr),
            ("Writable", form.writable ? "true" : "false"),
        ]
    case .function:
        var fields: [(String, String)] = [
            ("Function name", form.functionName),
            ("Behavior", form.behavior.rawValue),
        ]
        switch form.behavior {
        case .fixedReturn: fields.append(("Return value", form.returnValue))
        case .raiseError: fields.append(("Error message", form.errorMessage))
        case .echoArgs: break
        }
        return fields
    }
}
