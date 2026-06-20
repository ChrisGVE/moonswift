// File: Sources/MoonSwiftCore/Mock/CallTargetExtractor.swift
// Location: MoonSwiftCore/Mock/
// Role: The PURE call-target extractor (IMPL-N01) for F5.3 Lua invocation. Given
//       a full Lua call expression as typed, it extracts the leading call TARGET
//       and accepts it only when the target is a bare identifier immediately
//       applied as a call (the "no-dots" rule — D-1 ruling, SEC-09/SEC-10/DOM-07).
//       Dotted (`a.b`), indexed (`a[b]`), and method (`a:m`) targets are
//       rejected, so the invoke path cannot reach arbitrary host tables.
//
//       No engine, no side effects: the AppDriver runs this AFTER the syntax
//       pre-pass and BEFORE `SessionEngine.invokeLuaCall` (§F5.3, ARCH-R7-01).
//
// ## Grammar (§F5.3 step 2, DOM-R7-01)
//
//   (a) skip leading whitespace;
//   (b) take the maximal identifier run, which must match
//       `^[A-Za-z_][A-Za-z0-9_]*$`;
//   (c) skip trailing whitespace;
//   (d) accept iff the next non-whitespace character starts a recognized call
//       form: `(` (parenthesized), a string literal (`"`, `'`, or a long-string
//       open `[`=*`[`), or `{` (table constructor).
//
// Accepts: `f(...)`, `f'...'`, `f"..."`, `f[[...]]`, `f{...}`, and the
// whitespace-separated forms `f (...)`, `f "x"`, `f {...}`. Rejects everything
// else, including dotted / indexed / method targets and bare names with no call.
//
// Upstream: (none — pure string algorithm)
// Downstream: AppDriver+InvokeEffects (F5.3 invoke pipeline)

import Foundation

/// The result of extracting an invocation target.
public enum CallTargetResult: Sendable, Equatable {
    /// A valid bare-identifier call target (the identifier text).
    case valid(String)
    /// The expression is not a bare-identifier call (dotted, indexed, method,
    /// non-call, or malformed).
    case invalid
}

/// Extracts and validates the call target of a Lua call expression.
///
/// - Parameter expression: The full Lua call expression as typed.
/// - Returns: `.valid(identifier)` when the expression is a bare identifier
///   immediately applied as a call; `.invalid` otherwise.
public func extractCallTarget(_ expression: String) -> CallTargetResult {
    let chars = Array(expression)
    let n = chars.count
    var i = 0

    // (a) skip leading whitespace.
    while i < n, chars[i].isWhitespace { i += 1 }

    // (b) maximal identifier run, first char [A-Za-z_].
    let identStart = i
    guard i < n, isIdentifierStart(chars[i]) else { return .invalid }
    i += 1
    while i < n, isIdentifierContinuation(chars[i]) { i += 1 }
    let identifier = String(chars[identStart..<i])

    // (c) skip trailing whitespace.
    while i < n, chars[i].isWhitespace { i += 1 }

    // (d) the next non-whitespace char must start a recognized call form.
    guard i < n else { return .invalid }
    switch chars[i] {
    case "(", "{", "\"", "'":
        return .valid(identifier)
    case "[":
        // A long-string open is `[` followed by zero or more `=` then `[`.
        // Anything else after `[` is indexing (a[b]) — rejected.
        var j = i + 1
        while j < n, chars[j] == "=" { j += 1 }
        return (j < n && chars[j] == "[") ? .valid(identifier) : .invalid
    default:
        return .invalid
    }
}

/// ASCII letter or underscore (Lua identifiers are ASCII).
private func isIdentifierStart(_ c: Character) -> Bool {
    c == "_" || (c.isASCII && c.isLetter)
}

/// ASCII letter, digit, or underscore.
private func isIdentifierContinuation(_ c: Character) -> Bool {
    c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
}
