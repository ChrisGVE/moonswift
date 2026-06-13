// File: Sources/MoonSwiftTUI/App/MockFormState.swift
// Location: MoonSwiftTUI/App/
// Role: P2 F5.4 — state for the Mock Environment add/edit form. Held as an
//       Optional on AppState (non-nil only while the form is open, mirroring
//       InitFormState / PickerState). The `a` key opens it at the type-popup
//       stage; `e` opens it pre-filled at the fields stage. `<Enter>` validates
//       and commits (mutating MockStore + auto-saving moonswift.toml); `<Esc>`
//       cancels. Field navigation and text entry are pure reducer transitions
//       (MockFormReducer.swift); rendering is MockFormView.swift.
//
// Upstream: MockValueDef / MockFunctionDef / MockValueType / MockBehavior
// Downstream: MockFormReducer.swift, MockFormView.swift, Reducer.swift dispatch

import Foundation
import MoonSwiftCore

/// The Mock Environment add/edit form.
public struct MockFormState: Sendable, Equatable {

    /// Which kind of mock the form edits. (The popup's "Namespace" choice opens
    /// a Value form focused on the Namespace field — a namespace exists in
    /// `MockStore` only via its values, so there is no standalone namespace kind.)
    public enum Kind: Sendable, Equatable, CaseIterable {
        case value
        case function
    }

    /// The form's two stages: the type-selection popup, then field editing.
    public enum Stage: Sendable, Equatable {
        /// `Add mock — Value / Function / Namespace` popup (add flow only).
        case typePopup
        /// The inline field editor for the chosen kind.
        case fields
    }

    public var kind: Kind
    public var stage: Stage

    /// The index into `mockStore.values` / `.functions` being edited, or `nil`
    /// for an add. On confirm, a non-nil index replaces; `nil` appends.
    public var editingIndex: Int?

    // MARK: Value fields
    public var namespace: String
    public var keyPath: String
    public var valueType: MockValueType
    public var valueExpr: String
    public var writable: Bool

    // MARK: Function fields
    public var functionName: String
    public var behavior: MockBehavior
    public var returnValue: String
    public var errorMessage: String

    /// The 0-based index of the focused field within the current kind's field
    /// list (see `fieldCount`). Text entry edits the focused field.
    public var focusedField: Int

    /// Inline validation error shown under the form, cleared on the next edit.
    public var error: String?

    public init(
        kind: Kind = .value,
        stage: Stage = .typePopup,
        editingIndex: Int? = nil,
        namespace: String = "",
        keyPath: String = "",
        valueType: MockValueType = .string,
        valueExpr: String = "",
        writable: Bool = false,
        functionName: String = "",
        behavior: MockBehavior = .echoArgs,
        returnValue: String = "",
        errorMessage: String = "",
        focusedField: Int = 0,
        error: String? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.editingIndex = editingIndex
        self.namespace = namespace
        self.keyPath = keyPath
        self.valueType = valueType
        self.valueExpr = valueExpr
        self.writable = writable
        self.functionName = functionName
        self.behavior = behavior
        self.returnValue = returnValue
        self.errorMessage = errorMessage
        self.focusedField = focusedField
        self.error = error
    }

    /// The number of focusable fields for the current kind (ux-spec §7.1).
    /// Value: Namespace, Key path, Type, Value, Writable (5).
    /// Function: Function name, Behavior, then a conditional Return value
    ///   (fixed-return) or Error message (raise-error) → 2 or 3.
    /// Namespace: Namespace name (1).
    public var fieldCount: Int {
        switch kind {
        case .value: return 5
        case .function:
            switch behavior {
            case .fixedReturn, .raiseError: return 3
            case .echoArgs: return 2
            }
        }
    }

    /// Pre-fill the form from an existing value definition (edit flow).
    public static func editing(value def: MockValueDef, index: Int) -> MockFormState {
        MockFormState(
            kind: .value, stage: .fields, editingIndex: index,
            namespace: def.namespace, keyPath: def.path, valueType: def.type,
            valueExpr: def.value, writable: def.writable)
    }

    /// Pre-fill the form from an existing function definition (edit flow).
    public static func editing(function def: MockFunctionDef, index: Int) -> MockFormState {
        MockFormState(
            kind: .function, stage: .fields, editingIndex: index,
            functionName: def.name, behavior: def.behavior,
            returnValue: def.returnValue ?? "", errorMessage: def.errorMessage ?? "")
    }
}
