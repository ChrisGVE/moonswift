// File: Sources/MoonSwiftTUI/App/Reducers/MockFormReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: P2 F5.4 — the Mock Environment add/edit/delete reducer logic, kept out
//       of the 2300-line Reducer.swift (§4.7). Opens the form (`a` add / `e`
//       edit), handles its type-popup + field-editing keys, validates and commits
//       on `<Enter>` (mutating MockStore + emitting Effect.saveMockStore), and
//       runs the `d` → `Delete this mock? [y/N]` confirm. Pure: all persistence
//       is an Effect; the reducer only transitions AppState.
//
// Upstream: AppState, MockFormState, MockStore, MockValueDef, MockFunctionDef,
//           mockSelectableRows (MockNavigatorView.swift), Effect.saveMockStore
// Downstream: Reducer.swift (a/e/d dispatch in reduceNavigatorKey; .mockForm
//             focus dispatch in reduceKey)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - Selected-mock target

/// Map the mock-section cursor (`navigator.mockSelectedIndex`) to a concrete
/// store target. The selectable order is values then functions (matching
/// `buildMockNavRows`), so an index below `values.count` is a value, else a
/// function. `nil` when the cursor is out of range (no declared mocks).
func selectedMockTarget(_ s: AppState) -> (isValue: Bool, index: Int)? {
    let valuesCount = s.mockStore.values.count
    let total = valuesCount + s.mockStore.functions.count
    let i = s.navigator.mockSelectedIndex
    guard i >= 0, i < total else { return nil }
    return i < valuesCount ? (true, i) : (false, i - valuesCount)
}

// MARK: - Open / close

/// `a` — open the add-mock form at the type-selection popup (F5.4).
func reduceMockAddForm(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    s.mockFormState = MockFormState()  // .typePopup, .value defaults
    s.focus = .mockForm
    return (s, [])
}

/// `e` — open the edit form pre-filled from the selected mock (F5.4). No-op when
/// the cursor is not on a declared mock.
func reduceMockEditForm(_ s: AppState) -> (AppState, [Effect]) {
    guard let target = selectedMockTarget(s) else { return (s, []) }
    var s = s
    if target.isValue {
        s.mockFormState = .editing(value: s.mockStore.values[target.index], index: target.index)
    } else {
        s.mockFormState = .editing(function: s.mockStore.functions[target.index], index: target.index)
    }
    s.focus = .mockForm
    return (s, [])
}

/// Close the form and return focus to the navigator (cancel or post-commit).
private func closeMockForm(_ s: AppState) -> AppState {
    var s = s
    s.mockFormState = nil
    s.focus = .pane(.navigator)
    return s
}

// MARK: - Delete (d → [y/N])

/// `d` — request delete confirmation for the selected mock (F5.4). No-op when
/// the cursor is not on a declared mock.
func reduceMockDeleteRequest(_ s: AppState) -> (AppState, [Effect]) {
    guard selectedMockTarget(s) != nil else { return (s, []) }
    var s = s
    s.mockDeletePending = true
    s.transient = TransientMessage(text: "Delete this mock? [y/N]")
    return (s, [.startTick(interval: TickInterval.transientExpiry)])
}

/// Handle the `Delete this mock? [y/N]` response — `y` deletes + auto-saves.
func reduceMockDeleteConfirm(_ s: AppState, code: KeyCode) -> (AppState, [Effect]) {
    var s = s
    s.mockDeletePending = false
    s.transient = nil
    guard case .char("y") = code, let target = selectedMockTarget(s) else {
        return (s, [])  // any non-`y` cancels
    }
    var values = s.mockStore.values
    var functions = s.mockStore.functions
    if target.isValue {
        values.remove(at: target.index)
    } else {
        functions.remove(at: target.index)
    }
    s.mockStore = MockStore(values: values, functions: functions)
    // Clamp the cursor to the new selectable count.
    let newCount = values.count + functions.count
    s.navigator.mockSelectedIndex = max(0, min(s.navigator.mockSelectedIndex, newCount - 1))
    if newCount == 0 { s.navigator.inMockSection = false }
    return (s, [.saveMockStore(s.mockStore)])
}

// MARK: - Form keys

/// Dispatch a key while the Mock Environment form is open.
func reduceMockFormKey(_ s: AppState, code: KeyCode, modifiers: KeyModifiers) -> (AppState, [Effect]) {
    guard var form = s.mockFormState else { return (s, []) }

    if case .escape = code { return (closeMockForm(s), []) }

    switch form.stage {
    case .typePopup:
        switch code {
        case .char("v"):
            form.kind = .value
            form.stage = .fields
            form.focusedField = 0
        case .char("f"):
            form.kind = .function
            form.stage = .fields
            form.focusedField = 0
        case .char("n"):
            // "Namespace" — a namespace exists only via its values, so open the
            // Value form focused on the Namespace field.
            form.kind = .value
            form.stage = .fields
            form.focusedField = 0
        default:
            return (s, [])
        }
        var s = s
        s.mockFormState = form
        return (s, [])

    case .fields:
        if case .enter = code {
            return confirmMockForm(s, form: form)
        }
        if case .tab = code {
            form.focusedField = (form.focusedField + 1) % max(form.fieldCount, 1)
            form.error = nil
            return applyForm(s, form)
        }
        form = editFocusedField(form, code: code)
        return applyForm(s, form)
    }
}

private func applyForm(_ s: AppState, _ form: MockFormState) -> (AppState, [Effect]) {
    var s = s
    s.mockFormState = form
    return (s, [])
}

// MARK: - Field editing

/// Apply a key to the focused field: text input for text fields, cycle for enum
/// fields (Type / Behavior), toggle for the Writable bool.
private func editFocusedField(_ form: MockFormState, code: KeyCode) -> MockFormState {
    var form = form
    form.error = nil
    let field = form.focusedField

    // Enum / bool fields react to space / left / right; text fields to char / backspace.
    if form.kind == .value && field == 2 {  // Type
        if isCycleKey(code) { form.valueType = cycle(form.valueType, forward: !isPrev(code)) }
        return form
    }
    if form.kind == .value && field == 4 {  // Writable
        if isCycleKey(code) { form.writable.toggle() }
        return form
    }
    if form.kind == .function && field == 1 {  // Behavior
        if isCycleKey(code) { form.behavior = cycle(form.behavior, forward: !isPrev(code)) }
        return form
    }

    // Text fields.
    switch code {
    case .backspace:
        mutateText(&form) { if !$0.isEmpty { $0.removeLast() } }
    case .char(let scalar) where !CharacterSet.controlCharacters.contains(scalar):
        let ch = String(scalar)
        mutateText(&form) { $0 += ch }
    default:
        break
    }
    return form
}

/// Mutate the text value of the focused text field in place.
private func mutateText(_ form: inout MockFormState, _ edit: (inout String) -> Void) {
    switch (form.kind, form.focusedField) {
    case (.value, 0): edit(&form.namespace)
    case (.value, 1): edit(&form.keyPath)
    case (.value, 3): edit(&form.valueExpr)
    case (.function, 0): edit(&form.functionName)
    case (.function, 2):
        if form.behavior == .raiseError { edit(&form.errorMessage) } else { edit(&form.returnValue) }
    default: break
    }
}

private func isCycleKey(_ code: KeyCode) -> Bool {
    switch code {
    case .char(" "), .left, .right: return true
    default: return false
    }
}

private func isPrev(_ code: KeyCode) -> Bool {
    if case .left = code { return true }
    return false
}

private func cycle<T: CaseIterable & Equatable>(_ value: T, forward: Bool) -> T {
    let all = Array(T.allCases)
    guard let i = all.firstIndex(of: value), !all.isEmpty else { return value }
    let n = all.count
    let next = forward ? (i + 1) % n : (i - 1 + n) % n
    return all[next]
}

// MARK: - Confirm

/// Validate the form and commit to MockStore (append or replace), then auto-save.
func confirmMockForm(_ s: AppState, form: MockFormState) -> (AppState, [Effect]) {
    switch form.kind {
    case .value:
        guard !form.namespace.trimmed.isEmpty else { return (formError(s, form, "Namespace must not be empty."), []) }
        guard !form.keyPath.trimmed.isEmpty else { return (formError(s, form, "Key path must not be empty."), []) }
        let def = MockValueDef(
            namespace: form.namespace.trimmed, path: form.keyPath.trimmed,
            type: form.valueType, value: form.valueExpr, writable: form.writable)
        var values = s.mockStore.values
        if let idx = form.editingIndex, values.indices.contains(idx) {
            values[idx] = def
        } else {
            values.append(def)
        }
        return commit(s, MockStore(values: values, functions: s.mockStore.functions))

    case .function:
        guard !form.functionName.trimmed.isEmpty else {
            return (formError(s, form, "Function name must not be empty."), [])
        }
        if form.behavior == .fixedReturn, form.returnValue.trimmed.isEmpty {
            return (formError(s, form, "Return value is required for fixed-return."), [])
        }
        if form.behavior == .raiseError, form.errorMessage.trimmed.isEmpty {
            return (formError(s, form, "Error message is required for raise-error."), [])
        }
        let def = MockFunctionDef(
            name: form.functionName.trimmed, behavior: form.behavior,
            returnValue: form.behavior == .fixedReturn ? form.returnValue : nil,
            errorMessage: form.behavior == .raiseError ? form.errorMessage : nil)
        var functions = s.mockStore.functions
        if let idx = form.editingIndex, functions.indices.contains(idx) {
            functions[idx] = def
        } else {
            functions.append(def)
        }
        return commit(s, MockStore(values: s.mockStore.values, functions: functions))
    }
}

private func formError(_ s: AppState, _ form: MockFormState, _ message: String) -> AppState {
    var s = s
    var form = form
    form.error = message
    s.mockFormState = form
    return s
}

private func commit(_ s: AppState, _ store: MockStore) -> (AppState, [Effect]) {
    var s = s
    s.mockStore = store
    s.mockFormState = nil
    s.focus = .pane(.navigator)
    return (s, [.saveMockStore(store)])
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
