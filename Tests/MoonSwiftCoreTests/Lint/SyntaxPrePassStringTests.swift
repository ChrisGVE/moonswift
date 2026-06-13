// File: Tests/MoonSwiftCoreTests/Lint/SyntaxPrePassStringTests.swift
// Location: MoonSwiftCoreTests/Lint/
// Role: Tests for the IMPL-01 String overload of syntaxPrePass — valid strings
//       return nil, invalid strings return a .syntaxPrePass Diagnostic, and the
//       dummy provenance is observably harmless (the overload's result equals the
//       fragment method's result for the same code under a real provenance).
// Upstream: LintService, LintServiceProtocol, LuaSourceFragment, FragmentProvenance
import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore

@Suite("LintService — syntaxPrePass(String) overload")
struct SyntaxPrePassStringTests {

    @Test("valid expression returns nil")
    func validReturnsNil() {
        let service = LintService()
        #expect(service.syntaxPrePass("return 1 + 2") == nil)
    }

    @Test("invalid expression returns a .syntaxPrePass error Diagnostic")
    func invalidReturnsDiagnostic() {
        let service = LintService()
        let diagnostic = service.syntaxPrePass("return function( end")
        #expect(diagnostic != nil)
        #expect(diagnostic?.severity == .error)
        #expect(diagnostic?.source == .syntaxPrePass)
    }

    @Test("dummy provenance is harmless: overload result matches fragment method")
    func dummyProvenanceHarmless() {
        let service = LintService()
        let code = "return function( end"

        // Same code under a real, distinct provenance.
        let realData = Data(code.utf8)
        let realFragment = LuaSourceFragment(
            code: code,
            provenance: FragmentProvenance(
                file: URL(fileURLWithPath: "/real/path/script.lua"),
                jsonpath: "$.field",
                document: 0,
                byteRange: 0..<realData.count,
                lineOffset: 5,
                contentHash: SHA256.hash(data: realData)
            )
        )

        let viaString = service.syntaxPrePass(code)
        let viaFragment = service.syntaxPrePass(realFragment)

        // The error's line and message derive solely from the LuaError, so the
        // two diagnostics agree despite the different provenances.
        #expect(viaString?.line == viaFragment?.line)
        #expect(viaString?.message == viaFragment?.message)
        #expect(viaString?.source == viaFragment?.source)
        #expect(viaString?.severity == viaFragment?.severity)
    }
}
