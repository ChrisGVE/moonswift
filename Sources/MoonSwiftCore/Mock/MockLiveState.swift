// File: Sources/MoonSwiftCore/Mock/MockLiveState.swift
// Location: MoonSwiftCore/Mock/
// Role: The post-run introspection snapshot of the live session engine
//       (PRD §4.3, resolves DATA-10). Produced by `SessionEngine.liveState()`
//       ONLY when RunState == .idle; an empty value is returned mid-run (the
//       F5.0 RunState gate, DOM-02). Sourced ENTIRELY via LuaSwift #21
//       introspection (registeredValueServerNames, registeredFunctionNames,
//       globalNames, globalValue), NEVER parallel bookkeeping (REQUIREMENTS F5).
//
//       Consumed identically by the F5.4 navigator live-state renderer and the
//       F7a.1 live-mock completion layer (both read these exact fields). All
//       stored fields are value types, so `Sendable` is synthesised — no
//       `@unchecked` needed.
//
// Upstream: (none — pure data model)
// Downstream: SessionEngine.liveState (produces), MockNavigatorView (F5.4),
//             completion layer (F7a.1)

import Foundation

// MARK: - MockLiveValue

/// One live name→value pair in a `MockLiveState`.
///
/// `displayValue` is the already-rendered display string of the introspected
/// Lua value (depth-capped like `DebugVariable`), so neither consumer holds a
/// LuaSwift inspector type. Depth-cap fallback (DATA-N06): a value past the
/// depth cap renders as the literal sentinel `(…)`. A function-typed value
/// (possible with RQ1 function-literal mocks) renders as `function` (DATA-N07).
public struct MockLiveValue: Sendable, Equatable {
    /// Namespace path (e.g. `"config.timeout"`) or bare global name.
    public let name: String
    /// Rendered current value; `(…)` when depth-capped.
    public let displayValue: String

    public init(name: String, displayValue: String) {
        self.name = name
        self.displayValue = displayValue
    }
}

// MARK: - MockLiveState

/// Post-run introspection snapshot of the live session engine.
public struct MockLiveState: Sendable, Equatable {
    /// Registered mock VALUES currently installed, keyed by namespace path.
    public let mockValues: [MockLiveValue]
    /// Registered mock FUNCTION names currently installed (e.g. `"fetch"`).
    public let mockFunctionNames: [String]
    /// User-defined globals written by the fragment (stdlib baseline already
    /// subtracted — same filter as the debugger `g` slice), name → value.
    public let userGlobals: [MockLiveValue]
    /// True when the snapshot was assembled from an EMPTY (mid-run / no-cache)
    /// engine state, so the navigator shows `(run to populate live state)`
    /// (DATA-09) rather than treating it as a valid empty post-run result.
    public let isEmpty: Bool

    public init(
        mockValues: [MockLiveValue],
        mockFunctionNames: [String],
        userGlobals: [MockLiveValue],
        isEmpty: Bool
    ) {
        self.mockValues = mockValues
        self.mockFunctionNames = mockFunctionNames
        self.userGlobals = userGlobals
        self.isEmpty = isEmpty
    }

    /// The empty value returned mid-run (RunState gate) and during the no-cache
    /// window. `isEmpty == true`, no entries — the navigator renders
    /// `(run to populate live state)`.
    public static let empty = MockLiveState(
        mockValues: [],
        mockFunctionNames: [],
        userGlobals: [],
        isEmpty: true
    )
}
