// File: Sources/MoonSwiftCore/Diagnostics/LuaErrorDiagnostics.swift
// Location: MoonSwiftCore/Diagnostics/
// Role: The `Diagnostic.from(luaError:provenance:)` helper seam that maps a
//       raw LuaSwift error into a fragment-relative `Diagnostic`. All RunService
//       and LintService callers go through this single point.
//
//       Runtime errors use the LuaSwift #19 STRUCTURED surface (`.runtimeFailure`
//       carries `line`/`message`/`traceback` captured while the stack was intact),
//       so no string parsing is needed there (F6.4 — the standalone
//       `LuaErrorLineParser` seam was DELETED). Only COMPILE errors
//       (`.syntaxError`, raw `[string "…"]:N:` / `bytecode:N:` strings, which
//       have no structured location) and the rare legacy `.runtimeError` string
//       path still need a line number; a compact bounded-anchor extractor below
//       handles those two cases (the residual ~30 lines that replace the old
//       124-line parser file).
// Upstream: LuaSwift (LuaError cases, LuaRuntimeFailure),
//           FragmentProvenance (lineOffset for file-relative mapping)
// Downstream: RunService, LintService

import LuaSwift

// MARK: - Diagnostic + LuaError factory

extension Diagnostic {

    /// Builds a fragment-relative `Diagnostic` from a raw LuaSwift error.
    ///
    /// This is the **single entry point** for turning a LuaSwift error into a
    /// diagnostic. No other code in MoonSwiftCore should pattern-match on
    /// `LuaError` for display purposes.
    ///
    /// Line mapping (ARCHITECTURE §6, §3c):
    /// - Runtime errors (`.runtimeFailure`, #19) carry the 1-based line directly.
    /// - Compile errors (`.syntaxError`) and legacy `.runtimeError` strings encode
    ///   the *fragment-relative* line in their `]:N:` suffix (or `bytecode:N:`);
    ///   `compileErrorLineNumber(from:)` extracts it from within the first ~70
    ///   bytes (bounded-anchor rule; see that helper).
    /// - `provenance.lineOffset` is **not** applied here — it is the renderer's
    ///   job to convert from fragment-relative to file-relative for display.
    ///   (Applying it here would break fragment-relative gutter marks.)
    ///
    /// When no line number can be parsed, `line` is 0 (diagnostic without location).
    ///
    /// - Parameters:
    ///   - luaError: The error thrown by `LuaEngine.run` or `LuaEngine.evaluate`.
    ///   - provenance: The fragment that was executing (used for source attribution).
    /// - Returns: A `.runtime`-sourced `Diagnostic` ready for the output tab.
    public static func from(luaError: LuaError, provenance: FragmentProvenance) -> Diagnostic {
        switch luaError {
        case .syntaxError(let msg):
            let line = compileErrorLineNumber(from: msg) ?? 0
            return Diagnostic(
                severity: .error,
                line: line,
                message: strippingChunkPrefix(from: msg),
                source: .runtime
            )

        case .runtimeFailure(let failure):
            // Structured runtime error (LuaSwift #19, v1.11+): the engine's
            // errfunc message handler already captured the 1-based source line
            // and stripped the `chunkname:line:` prefix from the message while
            // the failing stack was intact. Consume those fields directly — string
            // line extraction is neither needed nor as reliable here (no stack to
            // walk by the time `lua_pcall` returns).
            return Diagnostic(
                severity: .error,
                line: failure.line ?? 0,
                message: failure.message,
                source: .runtime
            )

        case .runtimeError(let msg):
            // Legacy/unstructured runtime error path: coroutine runtime errors
            // (v1.11 notes) and any case where the structured handler did not
            // install still arrive as a raw string. Fall back to the same compile-
            // string line extraction + prefix stripping (the structured
            // `.runtimeFailure` case above is the primary runtime path now).
            let line = compileErrorLineNumber(from: msg) ?? 0
            return Diagnostic(
                severity: .error,
                line: line,
                message: strippingChunkPrefix(from: msg),
                source: .runtime
            )

        case .instructionLimitExceeded:
            return Diagnostic(
                severity: .error,
                line: 0,
                message: "Instruction limit exceeded (possible infinite loop)",
                source: .runtime
            )

        case .memoryError(let msg):
            return Diagnostic(
                severity: .error,
                line: 0,
                message: "Memory error: \(msg)",
                source: .runtime
            )

        default:
            return Diagnostic(
                severity: .error,
                line: 0,
                message: luaError.localizedDescription,
                source: .runtime
            )
        }
    }

    // MARK: - Private helpers

    /// Strips the `[string "…"]:N: ` or `bytecode:N: ` prefix from a Lua error
    /// message so that the displayed text is the human-readable part only.
    ///
    /// If no recognisable prefix is found, the string is returned unchanged.
    private static func strippingChunkPrefix(from errorString: String) -> String {
        // Match `]:N: ` (the close of the chunk-name wrapper + line + separator).
        // Walk the string and find the first `:` after a closing `]:digit+`
        // pattern (not necessarily starting from the front — the chunk name may
        // contain colons itself, so we look for the first `]:N: ` where N > 0).
        if let range = errorString.range(of: #"\]:\d+: "#, options: .regularExpression) {
            return String(errorString[range.upperBound...])
        }
        // Bytecode format: "bytecode:N: message"
        if let range = errorString.range(of: #"^bytecode:\d+: "#, options: .regularExpression) {
            return String(errorString[range.upperBound...])
        }
        return errorString
    }

    /// The character budget for the chunk-name search window: LUA_IDSIZE (60 in
    /// the Lua 5.x C header) plus ~10 bytes of margin for the `[string "…"]:`
    /// wrapper. The line marker `]:N:` always falls inside this window.
    private static let chunkSearchWindow = 70

    /// Extract a fragment-relative line number from a COMPILE-error string
    /// (`.syntaxError`) or a legacy `.runtimeError` string. Returns `nil` when no
    /// number can be parsed (line-0 diagnostic).
    ///
    /// Two formats (ARCHITECTURE §6):
    ///   - `bytecode:N: message`            — anchored at position 0.
    ///   - `[string "<src>"]:N: message`    — bounded-anchor rule: search only the
    ///     first `chunkSearchWindow` bytes and take the LAST `]:N:` match, which
    ///     defeats both a chunk name that itself contains `]:` and a message that
    ///     contains a `]:N:` lookalike past the window.
    ///
    /// This replaces the deleted `LuaErrorLineParser` (F6.4); only compile errors
    /// reach it now, so it is narrower than the old runtime-error parser.
    private static func compileErrorLineNumber(from errorString: String) -> Int? {
        // Bytecode: "bytecode:N: ..." — number between the first two colons.
        let bytecodePrefix = "bytecode:"
        if errorString.hasPrefix(bytecodePrefix) {
            let after = errorString.dropFirst(bytecodePrefix.count)
            guard let colon = after.firstIndex(of: ":") else { return nil }
            return Int(after[after.startIndex..<colon])
        }

        // Chunk-name window: the last `]:N:` within the first `chunkSearchWindow` bytes.
        let window: Substring
        if errorString.utf8.count > chunkSearchWindow {
            let utf8 = errorString.utf8
            let end = utf8.index(utf8.startIndex, offsetBy: chunkSearchWindow)
            window = errorString[..<(end.samePosition(in: errorString) ?? errorString.endIndex)]
        } else {
            window = errorString[...]
        }

        var lastLine: Int? = nil
        var from = window.startIndex
        while from < window.endIndex,
            let mark = window.range(of: "]:", range: from..<window.endIndex)
        {
            var digitEnd = mark.upperBound
            while digitEnd < window.endIndex, window[digitEnd].isNumber {
                digitEnd = window.index(after: digitEnd)
            }
            if digitEnd > mark.upperBound, digitEnd < window.endIndex, window[digitEnd] == ":",
                let n = Int(window[mark.upperBound..<digitEnd])
            {
                lastLine = n
            }
            from = mark.upperBound
        }
        return lastLine
    }
}
