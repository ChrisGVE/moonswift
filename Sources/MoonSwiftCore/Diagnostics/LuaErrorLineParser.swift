// File: Sources/MoonSwiftCore/Diagnostics/LuaErrorLineParser.swift
// Location: MoonSwiftCore/Diagnostics/
// Role: Extracts a fragment-relative line number from a raw LuaSwift error
//       string. This file is a DESIGNED-TO-DELETE seam: it is removed in P2
//       when LuaSwift#19 ships structured errors. All callers go through the
//       `Diagnostic.from(luaError:provenance:)` helper in
//       LuaErrorDiagnostics.swift; they never call this parser directly.
// Upstream: LuaSwift (error strings from luaL_loadstring / lua_pcall)
// Downstream: LuaErrorDiagnostics (the only caller)
//
// ## Format
//
// Two formats are handled (from ARCHITECTURE §6 — error-line-mapping decision):
//
// 1. Run / lint pre-pass path (luaL_loadstring chunk name = source text,
//    truncated to LUA_IDSIZE ≈ 60 bytes):
//
//       [string "<up-to-60-bytes-of-source>"]:LINE: message
//
//    The chunk name itself may contain the substring `]:` (hostile class A),
//    and the message may contain `]:N:` patterns (hostile class B). The
//    bounded-anchor rule resolves both: search only within the first ~70 bytes
//    (past the chunk name; `]:` can appear no earlier than position ~3, and
//    the chunk name truncates before 70 bytes in all cases). The *last* `]:N:`
//    match within that window is the authoritative one.
//
// 2. Bytecode path (luaL_loadbuffer with source `=bytecode`):
//
//       bytecode:LINE: message
//
//    No surrounding quotes; anchored at the start of the string.

// MARK: - LuaErrorLineParser

/// Extracts the fragment-relative line number from a raw Lua error string.
///
/// Returns `nil` when no line number can be parsed (e.g. engine initialisation
/// errors or fully unrecognised formats). Callers display a line-0 diagnostic in
/// that case.
///
/// This parser is designed to be deleted in P2 when LuaSwift#19 ships
/// structured errors. It is intentionally narrow: it extracts **only the line
/// number**, never the display name (which comes from `FragmentProvenance`).
enum LuaErrorLineParser {

    /// The character budget for the chunk-name search window.
    ///
    /// LUA_IDSIZE is 60 bytes in the Lua 5.x C header; we add 10 bytes of
    /// margin to accommodate the surrounding `[string "…"]:` wrapper.
    private static let searchWindowSize = 70

    /// Parses a fragment-relative line number from a raw Lua error string.
    ///
    /// - Parameter errorString: The raw error string from a `LuaError.syntaxError`
    ///   or `LuaError.runtimeError` payload.
    /// - Returns: The 1-based fragment-relative line number, or `nil` if not found.
    static func lineNumber(from errorString: String) -> Int? {
        // Fast path: bytecode format starts with "bytecode:N:" at position 0.
        if errorString.hasPrefix("bytecode:") {
            return bytecodeLineNumber(from: errorString)
        }
        // General path: search within the first ~70 bytes for the last `]:N:`.
        return chunkNameLineNumber(from: errorString)
    }

    // MARK: - Private helpers

    /// Handles `bytecode:LINE: message`.
    private static func bytecodeLineNumber(from errorString: String) -> Int? {
        // Expected: "bytecode:N: ..."
        // Split on the first ":" after "bytecode" to get the number part.
        let prefix = "bytecode:"
        guard errorString.hasPrefix(prefix) else { return nil }
        let afterPrefix = errorString.dropFirst(prefix.count)
        guard let colonIndex = afterPrefix.firstIndex(of: ":") else { return nil }
        let lineStr = String(afterPrefix[afterPrefix.startIndex..<colonIndex])
        return Int(lineStr)
    }

    /// Handles `[string "..."]:LINE: message`.
    ///
    /// Applies the bounded-anchor rule: search only within the first
    /// `searchWindowSize` bytes, then take the *last* `]:N:` match in that
    /// window. This defeats both hostile class A (chunk name contains `]:`)
    /// and class B (message contains `]:N:`).
    private static func chunkNameLineNumber(from errorString: String) -> Int? {
        // Restrict to the first searchWindowSize bytes (UTF-8 safe: work in String.Index).
        let window: Substring
        if errorString.utf8.count > searchWindowSize {
            let utf8 = errorString.utf8
            let endOffset = utf8.index(utf8.startIndex, offsetBy: searchWindowSize)
            let endIndex = endOffset.samePosition(in: errorString) ?? errorString.endIndex
            window = errorString[..<endIndex]
        } else {
            window = errorString[...]
        }

        // Find all `]:N:` matches in the window and return the line number from
        // the *last* one (bounded-anchor rule — handles both hostile classes).
        var lastLine: Int? = nil
        var searchFrom = window.startIndex
        let target = "]:"
        while searchFrom < window.endIndex {
            guard let bracketColon = window.range(of: target, range: searchFrom..<window.endIndex)
            else { break }

            // After `]:`, scan for digits then `:`.
            let afterBracketColon = bracketColon.upperBound
            var digitEnd = afterBracketColon
            while digitEnd < window.endIndex && window[digitEnd].isNumber {
                digitEnd = window.index(after: digitEnd)
            }
            if digitEnd > afterBracketColon,
                digitEnd < window.endIndex,
                window[digitEnd] == ":",
                let n = Int(window[afterBracketColon..<digitEnd])
            {
                lastLine = n
            }
            searchFrom = bracketColon.upperBound
        }
        return lastLine
    }
}
