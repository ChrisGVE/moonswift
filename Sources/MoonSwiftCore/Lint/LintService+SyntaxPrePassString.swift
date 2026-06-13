// File: Sources/MoonSwiftCore/Lint/LintService+SyntaxPrePassString.swift
// Location: MoonSwiftCore/Lint/
// Role: A String-accepting overload of the syntax pre-pass (IMPL-01 / IMPL-R8-01),
//       added as a default-implemented method in an extension on
//       `LintServiceProtocol`. The existing protocol declares ONLY
//       `syntaxPrePass(_ fragment: LuaSourceFragment)` (LintService.swift:62/182);
//       this file adds `syntaxPrePass(_ code: String)` for validating synthetic
//       in-memory strings with no on-disk origin: the mock `value` literal
//       (F5.1), the mock `return_value` literal (F5.2), and the invoke call
//       expression (F5.3).
//
//       It wraps `code` in a synthetic `LuaSourceFragment` with a dummy
//       `FragmentProvenance` and forwards to the existing fragment method. The
//       dummy is observably harmless: the fragment pre-pass body reads only
//       `fragment.code` (LintService.swift:182-212), and the `.syntaxError`
//       error-mapping branch reads only the LuaError message and never touches
//       provenance (LuaErrorDiagnostics.swift:40-47). Keeping the dummy in one
//       place means no call site reconstructs a provenance.
//
// Upstream: LintServiceProtocol, LuaSourceFragment, FragmentProvenance, Diagnostic
// Downstream: F5.1/F5.2 mock-literal validation, F5.3 invoke-expression validation

import CryptoKit
import Foundation

extension LintServiceProtocol {

    /// Run the syntax pre-pass on a raw Lua source string.
    ///
    /// Wraps `code` in a synthetic fragment with a dummy provenance and forwards
    /// to `syntaxPrePass(_ fragment:)`. Callers pass the already-`return <…>`-
    /// wrapped string (e.g. `syntaxPrePass("return \(value)")`); because
    /// `lineOffset` is 0 and `code` is the wrapped expression, any surfaced
    /// message is accurate for the single-line literal.
    ///
    /// - Parameter code: The Lua source to syntax-check.
    /// - Returns: A `.syntaxPrePass`-sourced `Diagnostic` on error, `nil` when clean.
    public func syntaxPrePass(_ code: String) -> Diagnostic? {
        let fragment = LuaSourceFragment(
            code: code,
            provenance: FragmentProvenance(
                file: URL(fileURLWithPath: "<mock-literal>"),  // sentinel; never opened
                jsonpath: nil,
                document: 0,
                byteRange: 0..<code.utf8.count,
                lineOffset: 0,  // diagnostics are 1:1 on `code`
                contentHash: SHA256.hash(data: Data())  // empty-data digest; not write-back
            )
        )
        return syntaxPrePass(fragment)
    }
}
