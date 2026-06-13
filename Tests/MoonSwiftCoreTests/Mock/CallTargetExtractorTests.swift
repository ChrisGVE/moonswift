// File: Tests/MoonSwiftCoreTests/Mock/CallTargetExtractorTests.swift
// Location: MoonSwiftCoreTests/Mock/
// Role: Tests for the IMPL-N01 pure call-target extractor — the F5.3 no-dots
//       grammar (DOM-R7-01). Accepts bare-identifier calls in all three call
//       syntaxes (and whitespace-separated forms); rejects dotted / indexed /
//       method targets and non-call expressions.
// Upstream: CallTargetExtractor
import Testing

@testable import MoonSwiftCore

@Suite("CallTargetExtractor")
struct CallTargetExtractorTests {

    @Test(
        "parenthesized call accepts the bare identifier",
        arguments: [
            ("f()", "f"),
            ("f(1, 2)", "f"),
            ("compute(x + y)", "compute"),
            ("_private()", "_private"),
            ("fetch2()", "fetch2"),
        ])
    func parenthesized(expr: String, target: String) {
        #expect(extractCallTarget(expr) == .valid(target))
    }

    @Test(
        "string-literal call forms accept",
        arguments: [
            "require\"mod\"",
            "require'mod'",
            "render[[long]]",
            "render[==[long]==]",
        ])
    func stringLiteralForms(expr: String) {
        guard case .valid = extractCallTarget(expr) else {
            Issue.record("expected .valid for \(expr)")
            return
        }
    }

    @Test("table-constructor call form accepts")
    func tableConstructor() {
        #expect(extractCallTarget("build{ a = 1 }") == .valid("build"))
    }

    @Test(
        "whitespace between identifier and call form is accepted",
        arguments: [
            "f ()",
            "f  \"x\"",
            "f\t{tbl}",
            "  spaced (1)",
        ])
    func whitespaceSeparated(expr: String) {
        guard case .valid = extractCallTarget(expr) else {
            Issue.record("expected .valid for \(expr)")
            return
        }
    }

    @Test(
        "dotted / indexed / method targets are rejected",
        arguments: [
            "os.execute(\"rm\")",
            "a.b()",
            "a[c]()",
            "obj:method()",
            "t[1]()",
        ])
    func qualifiedTargetsRejected(expr: String) {
        #expect(extractCallTarget(expr) == .invalid)
    }

    @Test(
        "non-call and malformed expressions are rejected",
        arguments: [
            "",
            "   ",
            "f",  // bare name, no call
            "f + 1",  // arithmetic, not a call
            "123()",  // not an identifier
            "(f)()",  // leading paren is not an identifier
            "a[b]",  // indexing, no call
        ])
    func nonCallRejected(expr: String) {
        #expect(extractCallTarget(expr) == .invalid)
    }
}
