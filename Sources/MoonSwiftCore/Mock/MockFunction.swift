// File: Sources/MoonSwiftCore/Mock/MockFunction.swift
// Location: MoonSwiftCore/Mock/
// Role: The mock-FUNCTION definition model (PRD §4.2 `[[mock.function]]`).
//
//       F5.0 defines the definition DTO because `SessionEngine.startSession`
//       takes a `MockStore` of these. Callback synthesis (the Swift function
//       registered into the engine) and `fixed-return` value materialization
//       are added by F5.2 (#6); the codec/validation that PRODUCES these from
//       TOML is F5.5 (#2). (DTO migrated here from #2 because F5.0 depends on it.)
//
// Upstream: (none — pure data model)
// Downstream: MockStore (collection), F5.2 callback synthesis, F5.5 codec/validation

import Foundation

// MARK: - MockBehavior

/// The behavior of a `[[mock.function]]` entry.
public enum MockBehavior: String, Sendable, Equatable, CaseIterable {
    /// Returns its arguments as ONE Lua table (DOM-04; no conditional field).
    case echoArgs = "echo-args"
    /// Returns a fixed value materialized from `returnValue`.
    case fixedReturn = "fixed-return"
    /// Raises an error with `errorMessage`.
    case raiseError = "raise-error"
}

// MARK: - MockFunctionDef

/// One parsed `[[mock.function]]` definition.
///
/// `returnValue` is present ONLY when `behavior == .fixedReturn` (a Lua value
/// expression, RQ1, materialized via evaluate); `errorMessage` is present ONLY
/// when `behavior == .raiseError`. Both are `nil` (key omitted) otherwise — the
/// conditional-field representation (DATA-06).
public struct MockFunctionDef: Sendable, Equatable {
    /// The function name exposed to Lua (e.g. `"host_log"`); no catalog or
    /// reserved (`__moonswift_`) collision.
    public let name: String
    /// The behavior selector.
    public let behavior: MockBehavior
    /// The fixed-return value expression, present only for `.fixedReturn`.
    public let returnValue: String?
    /// The error message, present only for `.raiseError`.
    public let errorMessage: String?

    public init(
        name: String,
        behavior: MockBehavior,
        returnValue: String? = nil,
        errorMessage: String? = nil
    ) {
        self.name = name
        self.behavior = behavior
        self.returnValue = returnValue
        self.errorMessage = errorMessage
    }
}
