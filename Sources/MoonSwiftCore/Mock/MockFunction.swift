// File: Sources/MoonSwiftCore/Mock/MockFunction.swift
// Location: MoonSwiftCore/Mock/
// Role: The mock-FUNCTION definition model (PRD §4.2 `[[mock.function]]`)
//       and F5.2 callback synthesis.
//
//       F5.0 defines the DTO. F5.2 (#6) adds `makeMaterializedCallback(engine:)`
//       on `MockFunctionDef`, which returns the `([LuaValue]) throws -> LuaValue`
//       closure that `SessionEngine.startSession` passes to
//       `engine.registerFunction(name:callback:)` at the F5.2 seam.
//
//       Callback shapes:
//       - echo-args:    Returns args as ONE `LuaValue.array` (DOM-04).
//       - fixed-return: Materializes `returnValue` EAGERLY via evaluate at
//                       session start; the closure returns the captured
//                       `LuaValue` on every call (DOM-R7-N01).
//       - raise-error:  Throws `LuaError.callbackError(errorMessage)`, which
//                       the trampoline propagates to Lua as `error(message)`.
//
//       The codec/validation that PRODUCES these from TOML is F5.5 (#2).
//
// Upstream: LuaSwift (LuaEngine, LuaValue, LuaError)
// Downstream: MockStore (collection), SessionEngine.startSession (F5.2 seam),
//             F5.5 codec/validation

import Foundation
import LuaSwift

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

// MARK: - F5.2 Callback synthesis

extension MockFunctionDef {

    /// Synthesizes the `([LuaValue]) throws -> LuaValue` callback for this
    /// definition, suitable for passing to `engine.registerFunction(name:callback:)`.
    ///
    /// **Must be called on the serial executor** (inside `startSession`'s
    /// `queue.async` block), because `engine.evaluate` is not thread-safe.
    ///
    /// For `fixedReturn`, the `returnValue` expression is **materialized eagerly**
    /// here via `engine.evaluate("return \(returnValue)")` — before the host
    /// `run()` begins. The resulting `LuaValue` is captured by the closure and
    /// returned unchanged on every call (DOM-R7-N01). This avoids re-entering
    /// `evaluate` from inside a running script, which would corrupt the engine's
    /// instruction budget and error state.
    ///
    /// For `echoArgs`, the closure wraps `args` in a single `LuaValue.array`
    /// and returns it, giving Lua one table value (DOM-04). Multiple Lua returns
    /// are not expressible through the `registerFunction` callback surface.
    ///
    /// For `raiseError`, the closure throws `LuaError.callbackError(errorMessage)`,
    /// which the trampoline (`callbackTrampoline` in `LuaEngine+Callbacks.swift`)
    /// converts to a Lua `error(message)` call — surfacing as a runtime error
    /// whose traceback shows the call site line in the fragment.
    ///
    /// - Parameter engine: The just-created `LuaEngine` for the session.
    /// - Returns: The synthesized callback closure.
    public func makeMaterializedCallback(
        engine: LuaEngine,
        onError: (String) -> Void = { _ in }
    ) -> ([LuaValue]) throws -> LuaValue {
        switch behavior {

        case .echoArgs:
            // DOM-04 binding: one table return regardless of argument count.
            // `local t = mocked(1, 2)` → t == {1, 2}; `local a, b = mocked(1, 2)`
            // → a == {1, 2}, b == nil (exactly one return value).
            return { args in .array(args) }

        case .fixedReturn:
            // Materialize the return_value expression once, at session start,
            // before any host Lua runs. The value has already been
            // syntax-validated by F5.5 syntaxPrePass, so a runtime failure here
            // is almost always a sandbox restriction (e.g. os.execute under
            // sandboxed mode) rather than a syntax error. We still fall back to
            // .nil so a single bad mock cannot abort session setup — but the
            // error is reported through `onError` (CR-033) so an unexpected,
            // non-sandbox failure is never swallowed silently.
            let expression = returnValue ?? "nil"
            let materialized: LuaValue
            do {
                materialized = try engine.evaluate("return \(expression)")
            } catch {
                onError(
                    "mock function \"\(name)\" return value failed to materialize: "
                        + "\(error.localizedDescription); using nil")
                materialized = .nil
            }
            return { _ in materialized }

        case .raiseError:
            // Throw a callback error; the trampoline converts it to a Lua
            // error() call, producing a structured runtime diagnostic whose
            // traceback identifies the call site in the fragment.
            let message = errorMessage ?? ""
            return { _ in throw LuaError.callbackError(message) }
        }
    }
}
