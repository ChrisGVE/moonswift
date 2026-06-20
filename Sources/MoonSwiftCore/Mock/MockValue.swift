// File: Sources/MoonSwiftCore/Mock/MockValue.swift
// Location: MoonSwiftCore/Mock/
// Role: The typed mock-VALUE definition model (PRD §4.2 `[[mock.value]]`).
//
//       F5.0 defines the definition DTO because `SessionEngine.startSession`
//       takes a `MockStore` of these. The DTO is the parsed, validated shape of
//       one `[[mock.value]]` table entry. The value-expression syntax gate
//       (syntaxPrePass) and engine materialization (evaluate under
//       RunConfigMode, RQ1) — plus the `MockValueServer` that serves the
//       materialized value — are added by F5.1 (#5) in the same file family;
//       the codec/validation that PRODUCES these from TOML is F5.5 (#2).
//
//       (Ownership note: the F5.5 task originally listed "define MockValueDef";
//       that DTO migrates here because F5.0 depends on it. #2 retains the codec
//       + validation rules.)
//
// Upstream: (none — pure data model)
// Downstream: MockStore (collection), F5.1 MockValueServer, F5.5 codec/validation

import Foundation

// MARK: - MockValueType

/// The declared `type` of a `[[mock.value]]` entry.
///
/// The type is INFORMATIONAL (it labels the navigator display and documents
/// intent), NOT a restriction on the stored expression: every `value` is
/// materialized uniformly via `evaluate("return <value>")` regardless of `type`
/// (RQ1, §F5.1). `expr` is the explicit label for a deliberately non-literal
/// value (a function literal or computed expression).
public enum MockValueType: String, Sendable, Equatable, CaseIterable {
    case string
    case number
    case boolean
    case table
    /// An arbitrary Lua VALUE expression — scalar, table constructor, function
    /// literal, or any computed value (RQ1).
    case expr
}

// MARK: - MockValueDef

/// One parsed `[[mock.value]]` definition.
///
/// `value` is stored verbatim as a Lua VALUE EXPRESSION (RQ1) and is
/// syntax-validated by wrapping it as `return <value>` through the syntax
/// pre-pass; it is materialized by the session engine at run/session start.
/// MoonSwift no longer hand-parses table constructors ahead of time.
public struct MockValueDef: Sendable, Equatable {
    /// The mock namespace (e.g. `"myapp"`); non-empty, no catalog collision.
    public let namespace: String
    /// The key path within the namespace (e.g. `"settings.debug"`).
    public let path: String
    /// The declared (informational) value type.
    public let type: MockValueType
    /// The stored Lua value expression, verbatim.
    public let value: String
    /// Whether Lua code may write this path (`canWrite`).
    public let writable: Bool

    public init(
        namespace: String,
        path: String,
        type: MockValueType,
        value: String,
        writable: Bool
    ) {
        self.namespace = namespace
        self.path = path
        self.type = type
        self.value = value
        self.writable = writable
    }
}
