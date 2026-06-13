// File: Sources/MoonSwiftCore/Project/ProjectValidation+Mock.swift
// Location: MoonSwiftCore/Project/
// Role: Mock-environment validation rules for ProjectValidation (F5.5).
//       Each public static function implements ONE distinct rule and appends
//       to a diagnostic collector passed by reference. Rules are collect-all:
//       every rule runs regardless of prior failures so the user sees all
//       problems in one load.
//
//       The exact diagnostic strings in this file are NORMATIVE — they are
//       promoted to ux-spec §6.9 "Mock validation diagnostics" and the F5.5
//       acceptance tests assert them character-for-character.
//
//       Catalog-collision symbol set (conservative choice, documented):
//         A mock function `name` collides if it equals any member of
//         `LuaModuleCatalog.v0.catalogSymbolNames`. That set contains:
//           - `"luaswift"` (the top-level namespace global).
//           - All non-empty module table names ("json", "yaml", "regex", …).
//           - All root-module function names ("extend_stdlib").
//         Only bare top-level identifiers are checked because mock functions
//         register as bare Lua globals; dotted sub-names (e.g. "json.decode")
//         cannot conflict with a single-identifier mock name.
//         This set is injected via the `catalogSymbols` closure parameter so
//         tests can supply a deterministic symbol set without coupling to the
//         catalog at test time.
//
//       Syntax pre-pass (IMPL-01, RQ1):
//         `value` in [[mock.value]] and `return_value` in [[mock.function]]
//         are validated by wrapping as `return <literal>` and calling the
//         string overload `LintServiceProtocol.syntaxPrePass(_ code: String)`.
//         A non-nil returned Diagnostic produces the "unparseable mock value"
//         diagnostic. No Lua execution occurs at validation time.
//
//       PERF-14 soft-cap:
//         When the total number of mock literals (values + fixed-return
//         return_values) exceeds 64, a warning is emitted and only the first
//         64 are syntax-validated. This prevents O(N) compile overhead on
//         large mock sets at load time.
//
// Upstream: MockStore, MockValueDef, MockFunctionDef, LuaModuleCatalog,
//           LintServiceProtocol (syntaxPrePass string overload)
// Downstream: ProjectValidation.validate (calls validateMocks)

import Foundation

// MARK: - Mock validation entry point

extension ProjectValidation {

    /// Validates all mock definitions in `store`, appending diagnostics to `collector`.
    ///
    /// - Parameters:
    ///   - store: The decoded `MockStore` from `ProjectFile.mocks`.
    ///   - lintService: A `LintServiceProtocol` instance used to syntax-check
    ///     value expressions via the `syntaxPrePass(_ code: String)` overload.
    ///     Pass `nil` to skip syntax validation (used in tests that isolate
    ///     other rules).
    ///   - catalogSymbols: Closure returning the set of reserved catalog symbol
    ///     names used for mock function name collision detection. Defaults to
    ///     `LuaModuleCatalog.v0.catalogSymbolNames`.
    ///   - diagnostics: The collector to append findings to.
    static func validateMocks(
        _ store: MockStore,
        lintService: (any LintServiceProtocol)?,
        catalogSymbols: () -> Set<String> = { LuaModuleCatalog.v0.catalogSymbolNames },
        into diagnostics: inout [Diagnostic]
    ) {
        let symbols = catalogSymbols()

        validateMockValues(store.values, lintService: lintService, into: &diagnostics)
        validateMockFunctions(store.functions, symbols: symbols, lintService: lintService, into: &diagnostics)
    }

    // MARK: - [[mock.value]] rules

    private static func validateMockValues(
        _ values: [MockValueDef],
        lintService: (any LintServiceProtocol)?,
        into diagnostics: inout [Diagnostic]
    ) {
        // Duplicate (namespace, path) detection — DATA-03.
        var seenKeys = Set<String>()
        // Syntax pre-pass budget — PERF-14: cap at 64 literals.
        var syntaxBudget = 64
        var budgetExceeded = false

        for def in values {
            // Rule: namespace must not be empty.
            if def.namespace.isEmpty {
                diagnostics.append(.projectError("mock namespace must not be empty"))
            }

            // Rule: path must not be empty (path serves as the key within namespace).
            if def.path.isEmpty {
                diagnostics.append(.projectError("mock name must not be empty"))
            }

            // Duplicate key detection — DATA-03.
            let compositeKey = "\(def.namespace).\(def.path)"
            if seenKeys.contains(compositeKey) {
                diagnostics.append(
                    .projectError("duplicate mock value \"\(compositeKey)\"")
                )
            } else {
                seenKeys.insert(compositeKey)
            }

            // Rule: writable is always decoded as Bool in the codec; the
            // "writable must be a boolean" diagnostic is produced when the
            // codec skips the entry due to wrong TOML type. At this layer
            // the field is already typed — no additional check needed unless
            // a future raw-value path is added.

            // Rule: syntax-check value expression (IMPL-01, RQ1).
            if let service = lintService {
                if syntaxBudget > 0 {
                    syntaxBudget -= 1
                    if let diag = service.syntaxPrePass("return \(def.value)") {
                        diagnostics.append(
                            .projectError("unparseable mock value: \(diag.message)")
                        )
                    }
                } else if !budgetExceeded {
                    budgetExceeded = true
                }
            }
        }

        if budgetExceeded {
            let total = values.count + 64 - syntaxBudget  // approximation for message
            _ = total  // total is implicit from the 64-cap warning
            diagnostics.append(
                .projectWarning(
                    "\(values.count) mock literals exceed the 64-literal validation "
                        + "budget — validating the first 64; re-validate the rest on edit."
                )
            )
        }
    }

    // MARK: - [[mock.function]] rules

    private static func validateMockFunctions(
        _ functions: [MockFunctionDef],
        symbols: Set<String>,
        lintService: (any LintServiceProtocol)?,
        into diagnostics: inout [Diagnostic]
    ) {
        var seenNames = Set<String>()

        for def in functions {
            // Rule: name must not be empty.
            if def.name.isEmpty {
                diagnostics.append(.projectError("mock name must not be empty"))
            }

            // Duplicate name detection — DATA-03.
            if seenNames.contains(def.name) {
                diagnostics.append(
                    .projectError("duplicate mock function \"\(def.name)\"")
                )
            } else {
                seenNames.insert(def.name)
            }

            // Rule: name must not use the __moonswift_ reserved prefix.
            if def.name.hasPrefix("__moonswift_") {
                diagnostics.append(
                    .projectError("mock name \"\(def.name)\" uses reserved prefix __moonswift_")
                )
            }

            // Rule: name must not collide with a catalog symbol.
            if symbols.contains(def.name) {
                diagnostics.append(
                    .projectError("mock name \"\(def.name)\" collides with catalog symbol")
                )
            }

            // Rule: conditional field — return_value required for fixed-return.
            if def.behavior == .fixedReturn && def.returnValue == nil {
                diagnostics.append(
                    .projectError("return_value is required for behavior fixed-return")
                )
            }

            // Rule: conditional field — error_message required for raise-error.
            if def.behavior == .raiseError && def.errorMessage == nil {
                diagnostics.append(
                    .projectError("error_message is required for behavior raise-error")
                )
            }

            // Rule: irrelevant conditional fields for echo-args and cross-behavior.
            validateIrrelevantFields(def, into: &diagnostics)

            // Rule: syntax-check return_value for fixed-return (IMPL-01, RQ1).
            if def.behavior == .fixedReturn, let rv = def.returnValue, let service = lintService {
                if let diag = service.syntaxPrePass("return \(rv)") {
                    diagnostics.append(
                        .projectError("unparseable mock value: \(diag.message)")
                    )
                }
            }
        }
    }

    /// Validates that no conditional field is present for a behavior that does
    /// not use it. Produces `irrelevant field <field> for behavior <behavior>`
    /// diagnostics, using the raw string representations of the TOML keys.
    private static func validateIrrelevantFields(
        _ def: MockFunctionDef,
        into diagnostics: inout [Diagnostic]
    ) {
        switch def.behavior {
        case .echoArgs:
            if def.returnValue != nil {
                diagnostics.append(
                    .projectError(
                        "irrelevant field return_value for behavior echo-args"
                    )
                )
            }
            if def.errorMessage != nil {
                diagnostics.append(
                    .projectError(
                        "irrelevant field error_message for behavior echo-args"
                    )
                )
            }
        case .fixedReturn:
            if def.errorMessage != nil {
                diagnostics.append(
                    .projectError(
                        "irrelevant field error_message for behavior fixed-return"
                    )
                )
            }
        case .raiseError:
            if def.returnValue != nil {
                diagnostics.append(
                    .projectError(
                        "irrelevant field return_value for behavior raise-error"
                    )
                )
            }
        }
    }
}
