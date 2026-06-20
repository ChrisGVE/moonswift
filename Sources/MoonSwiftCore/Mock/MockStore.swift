// File: Sources/MoonSwiftCore/Mock/MockStore.swift
// Location: MoonSwiftCore/Mock/
// Role: The in-memory store of mock definitions handed to a session
//       (PRD §4.1). F5.0 defines it as the value-typed collection of parsed
//       `[[mock.value]]` / `[[mock.function]]` definitions that
//       `SessionEngine.startSession(config:mocks:)` installs.
//
//       F5.0 scope: the definition container + lookups. Server synthesis +
//       engine installation (register a `MockValueServer` per namespace,
//       register a synthesized callback per function) is added by F5.1 (#5) /
//       F5.2 (#6) as a `MockStore` install seam; introspection reconciliation
//       for the navigator live-state view is read directly off the engine by
//       `SessionEngine.liveState()` (#1) and refined by F5.4 (#7). No engine
//       dependency lives here yet — the store is a pure `Sendable` value.
//
// Upstream: MockValueDef, MockFunctionDef
// Downstream: SessionEngine.startSession (consumes), F5.1/F5.2 install seam,
//             F5.5 codec (produces)

import Foundation

/// An immutable, value-typed collection of mock definitions for one session.
public struct MockStore: Sendable, Equatable {
    /// All `[[mock.value]]` definitions.
    public let values: [MockValueDef]
    /// All `[[mock.function]]` definitions.
    public let functions: [MockFunctionDef]

    public init(values: [MockValueDef] = [], functions: [MockFunctionDef] = []) {
        self.values = values
        self.functions = functions
    }

    /// An empty store — the session has no mocks (a plain mock-aware session can
    /// still be used for post-run invocation / live state).
    public static let empty = MockStore()

    /// Whether the store declares no mocks at all.
    public var isEmpty: Bool { values.isEmpty && functions.isEmpty }

    /// The distinct namespaces declared across all mock values, in first-seen
    /// order. Each becomes one `MockValueServer` namespace at install time.
    public var namespaces: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for def in values where !seen.contains(def.namespace) {
            seen.insert(def.namespace)
            ordered.append(def.namespace)
        }
        return ordered
    }

    /// The mock-value definitions belonging to `namespace`.
    public func values(in namespace: String) -> [MockValueDef] {
        values.filter { $0.namespace == namespace }
    }
}
