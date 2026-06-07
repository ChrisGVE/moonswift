// File: Sources/MoonSwiftCore/Diagnostics/LuaErrorDiagnostics.swift
// Location: MoonSwiftCore/Diagnostics/
// Role: The `Diagnostic.from(luaError:provenance:)` helper seam that maps a
//       raw LuaSwift error into a fragment-relative `Diagnostic`. All RunService
//       and LintService callers go through this single point; P2 replaces this
//       body with LuaSwift#19 structured errors without touching any caller.
// Upstream: LuaSwift (LuaError cases), LuaErrorLineParser (line extraction),
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
    /// - The raw error string encodes a *fragment-relative* line number (1-based)
    ///   in its `]:N:` suffix (or `bytecode:N:` for the pre-pass path).
    /// - `LuaErrorLineParser` extracts that number from within the first ~70 bytes
    ///   of the error string (bounded-anchor rule; see parser comments).
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
            let line = LuaErrorLineParser.lineNumber(from: msg) ?? 0
            return Diagnostic(
                severity: .error,
                line: line,
                message: strippingChunkPrefix(from: msg),
                source: .runtime
            )

        case .runtimeError(let msg):
            let line = LuaErrorLineParser.lineNumber(from: msg) ?? 0
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
}
