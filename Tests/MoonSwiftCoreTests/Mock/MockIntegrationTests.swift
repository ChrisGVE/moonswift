// File: Tests/MoonSwiftCoreTests/Mock/MockIntegrationTests.swift
// Location: MoonSwiftCoreTests/Mock/
// Role: Task #28 — integration tests for F5.1/F5.2 mock materialization using
//       LuaSwift 1.12.4. Only cases not already covered elsewhere are added here;
//       see reconciliation note below.
//
//       ## Coverage reconciliation (task #28 — do not re-test what exists)
//
//       The following 9 of the 10 required cases are already covered:
//
//       Case 1  — script reads mocked boolean → true
//                 MockValueServerBasicTests.readsBooleanTrue
//       Case 2  — script writes writable path → visible via liveState
//                 MockValueServerBasicTests.writablePathVisibleInLiveState
//       Case 3  — non-writable write raises LuaError.readOnlyAccess
//                 MockValueServerBasicTests.nonWritablePathRaisesError
//       Case 4  — number-typed computed expression '1+2*3' → 7
//                 MockValueServerRQ1Tests.computedExpressionMaterializesToSeven
//       Case 5  — expr-typed function literal → callable returning 42
//                 MockValueServerRQ1Tests.functionLiteralMaterializesToCallable
//       Case 7  — sandboxed function literal compiles, fails at runtime
//                 MockValueServerRQ1Tests.sandboxedFunctionLiteralFailsAtRuntime
//       Case 8  — echo-args returns a single table (DOM-04)
//                 MockFunctionEchoArgsTests.echoArgsSingleTable
//       Case 9  — fixed-return with scalar, computed, function-literal (RQ1)
//                 MockFunctionFixedReturnTests.{fixedReturnScalar,
//                   fixedReturnComputedExpression, fixedReturnFunctionLiteral}
//       Case 10 — raise-error produces structured error with message
//                 MockFunctionRaiseErrorTests.raiseErrorOutcome
//
//       ONLY case 6 is missing from the existing suite:
//
//       Case 6  — syntax-invalid literal rejected at definition time with an
//                 'unparseable mock value' diagnostic, BEFORE any session run.
//                 ProjectMockTests.swift deliberately passes `lintService: nil`
//                 for other rules and therefore never exercises the actual
//                 LintService path for this diagnostic.
//
//       This file supplies that single missing case, exercising
//       ProjectValidation.validateMocks with a real LintService instance so
//       the diagnostic is asserted to arise from the validate call itself —
//       never from a SessionEngine.startSession or sessionRun call.
//
// Upstream: ProjectValidation+Mock (validateMocks), MockValueDef, MockStore,
//           LintService (syntaxPrePass string overload)
// Downstream: (test target only)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Case 6: syntax pre-pass gate on mock value literals

/// Validates case 6: a syntactically-invalid value literal in a [[mock.value]]
/// entry is rejected by `validateMocks` with the 'unparseable mock value'
/// diagnostic BEFORE any run or session creation.
@Suite("MockIntegration — case 6: syntax pre-pass gate on invalid mock literals")
struct MockIntegrationSyntaxPrePassTests {

    // MARK: - [[mock.value]] syntax gate

    @Test("syntax-invalid mock value literal produces 'unparseable mock value' diagnostic before any run")
    func invalidValueLiteralRejectedAtValidation() {
        // Arrange: a mock value whose 'value' field is syntactically invalid Lua.
        // The expression "function( end" cannot be parsed by LuaSwift even as a
        // compile-only check.  validateMocks wraps it as "return function( end"
        // and runs syntaxPrePass — no engine session or Lua execution occurs.
        let badDef = MockValueDef(
            namespace: "myapp",
            path: "settings.debug",
            type: .expr,
            value: "function( end",  // deliberately broken Lua
            writable: false
        )
        let store = MockStore(values: [badDef])

        // Act: validate using a real LintService (the only path that exercises
        // the syntaxPrePass gate for mock literals).  Pass nil for catalogSymbols
        // so only the syntax rule fires for this def.
        let lintService = LintService()
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateMocks(
            store,
            lintService: lintService,
            catalogSymbols: { [] },
            into: &diagnostics
        )

        // Assert: at least one diagnostic with the exact prefix dictated by
        // ProjectValidation+Mock.swift line 119: "unparseable mock value: …"
        let syntaxDiag = diagnostics.first {
            $0.message.hasPrefix("unparseable mock value")
        }
        #expect(
            syntaxDiag != nil,
            "validateMocks must produce an 'unparseable mock value' diagnostic for a broken literal"
        )
        // The diagnostic must be an error (not a warning) so it gates session start.
        if let diag = syntaxDiag {
            #expect(
                diag.severity == .error,
                "the 'unparseable mock value' diagnostic must have severity .error"
            )
        }
    }

    @Test("valid mock value literal produces no 'unparseable mock value' diagnostic")
    func validValueLiteralPassesSyntaxGate() {
        // Arrange: a syntactically correct mock value.  This is the negative
        // case — it would be trivially satisfied by an always-true test, but
        // here we confirm the gate is path-selective: valid literals are clean.
        let goodDef = MockValueDef(
            namespace: "myapp",
            path: "timeout",
            type: .number,
            value: "1 + 2 * 3",  // valid Lua expression evaluating to 7
            writable: false
        )
        let store = MockStore(values: [goodDef])

        let lintService = LintService()
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateMocks(
            store,
            lintService: lintService,
            catalogSymbols: { [] },
            into: &diagnostics
        )

        // No 'unparseable mock value' diagnostic must appear for a valid literal.
        let syntaxDiag = diagnostics.first {
            $0.message.hasPrefix("unparseable mock value")
        }
        #expect(
            syntaxDiag == nil,
            "a valid mock value expression must produce no 'unparseable mock value' diagnostic"
        )
    }

    // MARK: - [[mock.function]] fixed-return syntax gate

    @Test("syntax-invalid return_value in fixed-return function produces 'unparseable mock value' before any run")
    func invalidFixedReturnValueRejectedAtValidation() {
        // Arrange: a fixed-return mock function whose return_value is broken Lua.
        // validateMocks wraps it as "return end ===" and runs syntaxPrePass.
        let badFn = MockFunctionDef(
            name: "broken_fn",
            behavior: .fixedReturn,
            returnValue: "end ==="  // syntactically invalid
        )
        let store = MockStore(values: [], functions: [badFn])

        let lintService = LintService()
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateMocks(
            store,
            lintService: lintService,
            catalogSymbols: { [] },
            into: &diagnostics
        )

        let syntaxDiag = diagnostics.first {
            $0.message.hasPrefix("unparseable mock value")
        }
        #expect(
            syntaxDiag != nil,
            "validateMocks must produce 'unparseable mock value' for an invalid return_value expression"
        )
        if let diag = syntaxDiag {
            #expect(diag.severity == .error)
        }
    }
}
