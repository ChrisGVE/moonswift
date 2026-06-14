// File: Tests/MoonSwiftCoreTests/Mock/InvocationIntegrationTests.swift
// Location: MoonSwiftCoreTests/Mock/
// Role: P2 F5.3 (task #29) — the invocation CONTROL-LAYER composition: the two
//       pure/side-effectful pre-evaluate gates the AppDriver runs in order on a
//       typed call expression (ARCH-R7-01) — (1) the syntax lint gate on the
//       wrapped `return <expr>` string, and (2) the call-target no-dots check —
//       exercised together on representative invoke expressions, proving a
//       malformed expression is caught by the lint gate and a dotted/indexed/
//       method target by the target check BEFORE any evaluate would run.
//
//       The rest of the F5.3 acceptance is covered elsewhere and not duplicated:
//       engine-side evaluate (first return / rich args / not-a-function / multi-
//       return) → SessionEngineIntegrationTests.swift; the exhaustive no-dots
//       grammar → CallTargetExtractorTests.swift; the string lint overload →
//       SyntaxPrePassStringTests.swift; the form lifecycle → InvokeFormTests.swift.
//
// Upstream: LintService (syntaxPrePass string overload), extractCallTarget,
//           CallTargetResult
// Downstream: (test target)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Control-layer composition (lint gate → target check)

@Suite("F5.3 — invocation control-layer composition (task #29)")
struct InvocationControlLayerTests {

    private let lint = LintService()

    /// Reproduces the AppDriver's pre-evaluate gate order (ARCH-R7-01): lint the
    /// wrapped `return <expr>`, then the target no-dots check. Returns which gate
    /// (if any) would stop the invocation before evaluate.
    private enum GateOutcome: Equatable {
        case lintRejected
        case targetRejected
        case wouldEvaluate(target: String)
    }

    private func runGates(_ expr: String) -> GateOutcome {
        if lint.syntaxPrePass("return \(expr)") != nil { return .lintRejected }
        guard case .valid(let target) = extractCallTarget(expr) else { return .targetRejected }
        return .wouldEvaluate(target: target)
    }

    @Test("a well-formed bare-target call passes both gates and would evaluate")
    func validCallPassesBothGates() {
        #expect(runGates("on_event(\"tick\", 42)") == .wouldEvaluate(target: "on_event"))
    }

    @Test("a rich-argument call (nested table + inline closure) passes both gates")
    func richArgumentCallPasses() {
        #expect(
            runGates("cb({a = 2, nested = {3, 4}}, function() return 5 end)")
                == .wouldEvaluate(target: "cb"))
    }

    @Test("a malformed expression is stopped by the lint gate before the target check")
    func malformedStoppedByLint() {
        // Each is syntactically invalid → caught by the `return <expr>` lint gate.
        for expr in ["myfn(1,", "myfn(", "myfn))"] {
            #expect(runGates(expr) == .lintRejected, "expected lint rejection for \(expr)")
        }
    }

    @Test("a dotted/indexed/method target passes lint but is stopped by the target check")
    func dottedTargetStoppedByTargetCheck() {
        // These are syntactically valid (lint passes) but the call HEAD is not a
        // bare identifier, so the no-dots check rejects them before evaluate —
        // closing the os.execute field-access vector (SEC-09/SEC-10).
        for expr in ["os.execute(\"rm\")", "a.b()", "a[c]()", "obj:method()"] {
            #expect(runGates(expr) == .targetRejected, "expected target rejection for \(expr)")
        }
    }

    @Test("a bare target with a dotted-access ARGUMENT passes both gates (arg ≠ target)")
    func dottedArgumentIsAllowed() {
        // Only the call TARGET is restricted; arguments may use dotted access.
        #expect(runGates("myfunc(os.time())") == .wouldEvaluate(target: "myfunc"))
    }
}
