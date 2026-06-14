// File: Sources/MoonSwiftTUI/App/InvokeFormState.swift
// Location: MoonSwiftTUI/App/
// Role: P2 F5.3 — state for the Lua-invocation form (ux-spec §7.5, PRD §6.6).
//       Held as an Optional on AppState (non-nil only while the form is open,
//       mirroring MockFormState). `<Enter>` on a live function row in the Mock
//       Environment opens it pre-filled with the function name and an opening
//       `(`; the user types a FULL Lua call expression. `<Enter>` emits
//       `Effect.invokeLuaCall(expression)` (RAW string — the three F5.3 controls
//       run in the AppDriver, never the pure reducer, ARCH-R7-01). `<Esc>`
//       cancels. Field editing is a pure reducer transition (InvokeFormReducer);
//       rendering is InvokeFormView.
//
//       Form lifecycle (§6.6): success closes the form (focus → navigator); a
//       control failure (lint / target / runtime) keeps it open with `error` set
//       and `expression` preserved so the user corrects in place.
//
// Upstream: (none — pure value type)
// Downstream: InvokeFormReducer.swift, InvokeFormView.swift, Reducer.swift dispatch

import Foundation

/// The Lua-invocation form: a single call-expression input line.
public struct InvokeFormState: Sendable, Equatable {

    /// The function name the form was opened for. Used for the not-a-function
    /// transient (`<name> is not a function.`) and as the pre-fill head.
    public var functionName: String

    /// The full Lua call expression being typed. Pre-filled as `"<name>("`; the
    /// user completes the arguments and closing paren.
    public var expression: String

    /// Inline error shown under the input (lint / target / runtime failure),
    /// cleared on the next edit. `nil` while the input is clean.
    public var error: String?

    public init(functionName: String, expression: String, error: String? = nil) {
        self.functionName = functionName
        self.expression = expression
        self.error = error
    }

    /// Open the form for `name`, pre-filling the call head and opening paren
    /// (ux-spec §7.5 step 2).
    public static func opening(_ name: String) -> InvokeFormState {
        InvokeFormState(functionName: name, expression: "\(name)(")
    }
}
