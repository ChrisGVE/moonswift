// File: Sources/MoonSwiftTUI/App/Reducers/InvokeFormReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: P2 F5.3 — the Lua-invocation form reducer (ux-spec §7.5, PRD §6.6), kept
//       out of the 2300-line Reducer.swift (§4.7). Opens the form from a live
//       function row, handles its single-line text editing, emits
//       `Effect.invokeLuaCall` on `<Enter>`, and applies the four invocation
//       outcome events. Pure: the three F5.3 controls (lint / target / evaluate)
//       are side-effectful and live in the AppDriver (ARCH-R7-01); this file only
//       transitions AppState.
//
//       Form lifecycle (§6.6): `<Esc>` cancels (focus → navigator); a SUCCESS
//       (`luaInvocationResult`) closes the form and writes `→ <display>` to the
//       Output tab; a control FAILURE (lint / target / runtime) keeps the form
//       open with the inline `error` set and the typed `expression` preserved.
//
// Upstream: AppState, InvokeFormState, selectedLiveFunctionName
//           (MockNavigatorView.swift), Effect.invokeLuaCall
// Downstream: Reducer.swift (.invokeForm focus dispatch; invocation events;
//             selectNavigatorEntry open path)

import Foundation
import RatatuiKit

// MARK: - Open

/// Open the invoke form for the live function under the mock-section cursor,
/// pre-filled with `<name>(` (ux-spec §7.5 step 2). No-op when the cursor is not
/// on a `.liveFunction` row.
func reduceOpenInvokeForm(_ s: AppState) -> (AppState, [Effect]) {
    guard let name = selectedLiveFunctionName(s) else { return (s, []) }
    var s = s
    s.invokeFormState = .opening(name)
    s.focus = .invokeForm
    return (s, [])
}

/// Close the form and return focus to the navigator (cancel or post-success).
private func closeInvokeForm(_ s: AppState) -> AppState {
    var s = s
    s.invokeFormState = nil
    s.focus = .pane(.navigator)
    return s
}

// MARK: - Form keys

/// Dispatch a key while the Lua-invocation form is open.
func reduceInvokeFormKey(_ s: AppState, code: KeyCode, modifiers: KeyModifiers) -> (AppState, [Effect]) {
    guard var form = s.invokeFormState else { return (s, []) }

    switch code {
    case .escape:
        // Cancel without evaluating (§6.6).
        return (closeInvokeForm(s), [])

    case .enter:
        // Emit the RAW typed expression; the three controls run in the AppDriver
        // (ARCH-R7-01). The form stays open until an outcome event arrives.
        form.error = nil
        var s = s
        s.invokeFormState = form
        return (s, [.invokeLuaCall(form.expression)])

    case .backspace:
        if !form.expression.isEmpty { form.expression.removeLast() }
        form.error = nil
        var s = s
        s.invokeFormState = form
        return (s, [])

    case .char(let scalar) where !CharacterSet.controlCharacters.contains(scalar):
        form.expression += String(scalar)
        form.error = nil
        var s = s
        s.invokeFormState = form
        return (s, [])

    default:
        return (s, [])
    }
}

// MARK: - Outcome events

/// `luaInvocationResult` — success: write `→ <display>` to the Output tab, close
/// the form, return focus to the navigator (§6.6 one-shot lifecycle).
func reduceLuaInvocationResult(_ s: AppState, display: String) -> (AppState, [Effect]) {
    var s = closeInvokeForm(s)
    s.bottomPane.appendOutputLines(["→ \(display)"])
    return (s, [])
}

/// `luaInvocationLintFailed` — control 1 failure: inline `Invalid call
/// expression: <detail>`, form stays open with text preserved (§6.5/§6.6).
func reduceLuaInvocationLintFailed(_ s: AppState, detail: String) -> (AppState, [Effect]) {
    invokeFormError(s, "Invalid call expression: \(detail)")
}

/// `luaInvocationTargetInvalid` — control 2 failure: inline `Invalid function
/// name.`, form stays open (§6.5/§6.6).
func reduceLuaInvocationTargetInvalid(_ s: AppState) -> (AppState, [Effect]) {
    invokeFormError(s, "Invalid function name.")
}

/// `luaInvocationFailed` — control 3 runtime failure (not the not-a-function
/// case): inline `<message>`, form stays open (§6.6).
func reduceLuaInvocationFailed(_ s: AppState, message: String) -> (AppState, [Effect]) {
    invokeFormError(s, message)
}

/// Set the inline form error, keeping the form open. No-op when the form is
/// already closed (a late event after `<Esc>`).
private func invokeFormError(_ s: AppState, _ message: String) -> (AppState, [Effect]) {
    guard var form = s.invokeFormState else { return (s, []) }
    form.error = message
    var s = s
    s.invokeFormState = form
    return (s, [])
}
