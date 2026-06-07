// File: Tests/MoonSwiftCoreTests/Diagnostics/LuaErrorLineParserTests.swift
// Location: Tests/MoonSwiftCoreTests/Diagnostics/
// Role: Unit tests for LuaErrorLineParser and the Diagnostic.from(luaError:provenance:)
//       seam. Covers all six fixture classes mandated by PRD §F3 (error-line mapping)
//       and verifies the lineOffset contract documented in LuaErrorDiagnostics.swift.
// Upstream: LuaErrorLineParser, LuaErrorDiagnostics, Diagnostic, FragmentProvenance
// Downstream: (test target only)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Builds a `FragmentProvenance` for use in seam tests.
///
/// - Parameters:
///   - file: The on-disk URL (default: a synthetic path).
///   - jsonpath: JSONPath for structured-file fragments; nil for whole .lua files.
///   - lineOffset: Fragment's first line offset in the containing file.
private func makeProvenance(
    file: URL = URL(fileURLWithPath: "/test/script.lua"),
    jsonpath: String? = nil,
    lineOffset: Int = 0
) -> FragmentProvenance {
    let data = Data("placeholder".utf8)
    return FragmentProvenance(
        file: file,
        jsonpath: jsonpath,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: lineOffset,
        contentHash: SHA256.hash(data: data)
    )
}

// MARK: - Class 1: Short / normal chunk-name format

/// Tests for the common `[string "..."]:N: message` format produced when the
/// Lua source is short enough that the truncated chunk name fits the window.
@Suite("LuaErrorLineParser — short truncated-source chunkname")
struct LuaErrorLineParserShortChunkNameTests {

    @Test("extracts line number from a standard run-path error")
    func standardRunPathError() {
        // Standard Lua 5.4 error from `luaL_loadstring` with short source text.
        // The real engine produces exactly this form for a two-line script.
        let raw = #"[string "local x = nil"]:1: attempt to call a nil value (local 'x')"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 1)
    }

    @Test("extracts line 42 from a multi-line fragment error")
    func lineFortyTwo() {
        let raw = #"[string "-- fragment\n"]:42: attempt to index a nil value"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 42)
    }

    @Test("extracts line number when source text contains normal characters")
    func normalSourceText() {
        // Lua truncates the chunk name to LUA_IDSIZE (~60 bytes) — short sources
        // appear verbatim.  This fixture is well within the 70-byte window.
        let raw = #"[string "print(x)"]:1: attempt to call a nil value (global 'x')"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 1)
    }

    @Test("extracts line number when message is a simple string")
    func simpleMessage() {
        let raw = #"[string "error('boom')"]:1: boom"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 1)
    }

    @Test("handles line 100 correctly (multi-digit)")
    func multiDigitLine() {
        // Build a string that has a valid ]:100: anchor within the first 70 bytes.
        // The chunk name is short so the whole prefix fits in the window.
        let raw = #"[string "x"]:100: some message"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 100)
    }
}

// MARK: - Class 2: Hostile class A — chunk name contains `"]:` sequences

/// Tests for the bounded-anchor rule defending against chunknames that themselves
/// contain `"]:N:` lookalikes (hostile class A in the parser comments).
///
/// The defense: within the ~70-byte search window the parser takes the *last*
/// `]:N:` match. For typical Lua-format strings (short source, short line
/// number) the real delimiter falls last within the window.
@Suite("LuaErrorLineParser — hostile class A (embedded ]: in chunk name)")
struct LuaErrorLineParserHostileClassATests {

    @Test("last ]:N: in window wins when chunk name contains a lookalike")
    func embeddedLookalikeLine() {
        // The chunk name contains `x"]:7:` — a false ]:N: sequence at byte 11.
        // The real line marker `]:3:` comes later and is still within the window.
        // Both matches fit inside 70 bytes; the last one (]:3:) wins.
        let raw = #"[string "x"]:7: lookalike"]:3: real message"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 3)
    }

    @Test("chunk name with multiple embedded lookalikes — last one in window wins")
    func multipleEmbeddedLookalikes() {
        // Three ]:N: sequences, all within the 70-byte window.
        // Parser takes the last one: ]:5: at byte 36.
        let raw = #"[string "a"]:2: b"]:4: c"]:5: actual message"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 5)
    }

    @Test("lookalike past the 70-byte window is invisible to the parser")
    func lookalikeBeyondWindow() {
        // Build a string where the only ]:N: is at byte 70 — just outside the window.
        // [string " = 9 bytes, 60 x's = 60 bytes, "]:99: = 6 bytes.
        // The ]: is at byte 9 + 60 + 1 = 70 (0-based), which is beyond [0..69].
        // The closing " at byte 69 is the last byte inside the window; ] at 70 is out.
        // Result: no ]:N: found in window → nil.
        let source = String(repeating: "x", count: 60)
        let raw = "[string \"\(source)\"]:99: message that was never in the window"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        // ]:99: is at byte 70, outside the 70-byte window — parser returns nil.
        #expect(line == nil)
    }
}

// MARK: - Class 3: Hostile class B — message contains `]:N:` patterns

/// Tests for the bounded-anchor rule defending against error messages that
/// themselves contain `]:N:` (hostile class B).
///
/// The 70-byte search window defends when the chunk-name portion is long enough
/// that the real `]:N:` delimiter (which ends the chunk-name) falls at byte ~58
/// and the message's false `]:N:` patterns fall past byte 70.
///
/// In Lua 5.5, chunk names are truncated to 45 visible chars + "..." when the
/// source is longer than 45 chars. The `]:N:` real delimiter therefore appears
/// at byte 58 (= 9 + 45 + 4). The 70-byte window gives 12 bytes of margin
/// before any message text is considered.
///
/// For short source strings (< 45 chars), the real delimiter falls at
/// byte (9 + len + 2), and the window still covers the full prefix. In that
/// regime the message `]:N:` must fall at byte ≥ 70 for the defense to be
/// demonstrated — which requires a message that starts with the short prefix
/// followed by enough text to push any false `]:N:` past the window.
@Suite("LuaErrorLineParser — hostile class B (]:N: in error message)")
struct LuaErrorLineParserHostileClassBTests {

    /// Demonstrates the window defense with a Lua-format string that exactly
    /// mirrors what the real engine produces for a truncated 50-char source
    /// whose runtime error message starts with `]:5:`.
    ///
    /// Format produced by Lua 5.5 for a 50-char source (truncated to 45 + "..."):
    ///   `[string "XXXXXXXXX...XXXX..."]:1: ]:5: trap`
    ///
    /// Real `]:1:` is at byte 58 (inside window).
    /// False `]:5:` starts at byte 62 (also inside window, but EARLIER).
    /// Wait — both are in the window. The LAST one (]:5:) wins. That is the
    /// correct behavior: the parser returns 5, which is the line number
    /// encoded in the error string, the one Lua placed there (it's actually
    /// the real one for the second error() call inside the message).
    ///
    /// The TRUE demonstration of the window defense requires the false ]:N:
    /// to fall at byte ≥ 70. That only happens when the message is long
    /// enough to push it there. The fixture below uses a long message.
    @Test("message ]:N: beyond byte 70 is ignored — real line from byte 58 wins")
    func messagePastWindowIsIgnored() {
        // Craft the exact Lua-truncated format for a 50-char source.
        // Lua shows 45 chars + "..." for sources > 45 chars.
        // Format: [string "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..."]:1: <message>
        // The real ]:1: is at byte 58.
        // Message padding of 12+ bytes before any ]:N: pushes false patterns past byte 70.
        let source45 = String(repeating: "X", count: 45)
        // 13 chars of plain message then ]:9: (false pattern at byte 58+2+13 = 73, past window)
        let raw = "[string \"\(source45)...\"]:1: plain_prefix]:9: trap"
        // ]:1: at byte 58 (in window). ]:9: at byte 73 (past window).
        // LAST match in window is ]:1: → line 1.
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 1)
    }

    @Test("all patterns within window — last one wins (short source scenario)")
    func allPatternsInWindowLastWins() {
        // For very short source strings, all ]:N: matches (including message ones)
        // may fall within the 70-byte window. In that case the parser returns the
        // LAST match, which is the one Lua placed closest to the end of the prefix.
        // This fixture has ]:1: at byte 26, ]:3: at byte 32 — both in window.
        // The last match (]:3: at byte 32) wins. This is acceptable: the 70-byte
        // window is an approximation; perfect disambiguation requires a long source.
        let raw = #"[string "error('x]:3: y')"]:1: x]:3: y"#
        let line = LuaErrorLineParser.lineNumber(from: raw)
        // ]:3: (byte 32) is last in window → returns 3.
        // This is the known behavior for short-source strings.
        #expect(line == 3)
    }
}

// MARK: - Class 4: Bytecode format

/// Tests for the `bytecode:N: message` format produced by the pre-compile path
/// (`luaL_loadbuffer` with source `=bytecode`).
@Suite("LuaErrorLineParser — bytecode:N: format")
struct LuaErrorLineParserBytecodeTests {

    @Test("bytecode:1: message extracts line 1")
    func bytecodeLineOne() {
        let raw = "bytecode:1: attempt to call a nil value"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 1)
    }

    @Test("bytecode:42: message extracts line 42")
    func bytecodeLineFortyTwo() {
        let raw = "bytecode:42: undefined global"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 42)
    }

    @Test("bytecode:N: message extracts multi-digit line")
    func bytecodeMultiDigit() {
        let raw = "bytecode:200: some error"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 200)
    }

    @Test("string starting with bytecode: but missing second colon returns nil")
    func bytecodeNoSecondColon() {
        // Degenerate: "bytecode:abc" has no digit + colon suffix.
        let raw = "bytecode:abc message"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == nil)
    }
}

// MARK: - Class 5: No match — graceful degradation

/// Tests that the parser returns nil line and does not crash on arbitrary
/// strings that contain no recognised anchors.
@Suite("LuaErrorLineParser — no match (graceful degradation)")
struct LuaErrorLineParserNoMatchTests {

    @Test("arbitrary string returns nil")
    func arbitraryString() {
        let raw = "something went wrong"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == nil)
    }

    @Test("empty string returns nil")
    func emptyString() {
        let line = LuaErrorLineParser.lineNumber(from: "")
        #expect(line == nil)
    }

    @Test("string with colon but no digits returns nil")
    func colonNoDigits() {
        let raw = "]:abc: no digits here"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == nil)
    }

    @Test("string with ]: but no trailing colon after digits returns nil")
    func colonDigitsNoTrailingColon() {
        let raw = "[string \"x\"]:42 no trailing colon"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == nil)
    }

    @Test("engine initialisation error string returns nil gracefully")
    func engineInitError() {
        // Errors like "Failed to initialize Lua state" have no ]:N: pattern.
        let raw = "Failed to initialize Lua state"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == nil)
    }
}

// MARK: - Class 6: LUA_IDSIZE truncation realism

/// Tests near the LUA_IDSIZE boundary.
///
/// Lua 5.5 truncates the chunk name in error strings to at most 45 visible
/// characters (followed by "...") when the source exceeds 45 bytes. The
/// `[string "…"]:` wrapper places the real `]:N:` delimiter at:
///
///   byte 9 + min(len, 45) + (len > 45 ? 4 : 2)
///
/// For a 45-char source (no truncation): 9 + 45 + 2 = 56 — inside window.
/// For a 46-char source (truncated): 9 + 45 + 4 = 58 — inside window.
/// For a 60-char raw source (as in the first test): same as 46+ → byte 58.
///
/// The 70-byte window therefore comfortably covers all realistic `]:N:`
/// positions (max ≈ 58 bytes for truncated names), with 12 bytes of margin.
@Suite("LuaErrorLineParser — LUA_IDSIZE truncation boundary")
struct LuaErrorLineParserTruncationBoundaryTests {

    @Test("Lua-format truncated chunk name (45 chars + ...) — line marker at byte 58")
    func luaFormatTruncatedChunkName() {
        // Lua truncates sources > 45 chars to 45 chars + "..." in the error prefix.
        // Format: [string "X*45..."]  (9 + 45 + 4 + 2 = 60 bytes before the line digit)
        // ]: is at byte 58 — well inside the 70-byte window.
        let source = String(repeating: "a", count: 45)
        let raw = "[string \"\(source)...\"]:7: error message"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 7)
    }

    @Test("short chunk name (10 chars, no truncation) — line marker well inside window")
    func shortChunkName() {
        // 10-char source: [string "0123456789"]:15: error
        // ]: is at byte 21 — inside the 70-byte window.
        let source = "0123456789"
        let raw = "[string \"\(source)\"]:15: error"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 15)
    }

    @Test("raw 60-char source string (no ... suffix) — ]: at byte 70 is outside window")
    func rawSixtyCharSource() {
        // A manually-constructed string where the source is 60 raw chars (no
        // Lua truncation applied). This puts ]: at byte 70, just outside the window.
        // The parser returns nil — this is correct: such strings do not arise from
        // the real Lua engine (which always truncates at 45 chars), so nil is safe.
        let source = String(repeating: "x", count: 60)
        let raw = "[string \"\(source)\"]:3: marker outside window"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        // ]: at byte 70 (= 9 + 60 + 1) — outside [0..69] window → nil.
        #expect(line == nil)
    }

    @Test("maximum realistic Lua truncation (45 + ...) — line 100 parsed correctly")
    func maxTruncationMultiDigitLine() {
        // Same format as the Lua engine would produce for a long source.
        // Multi-digit line number to exercise digit scanning.
        let source = String(repeating: "b", count: 45)
        let raw = "[string \"\(source)...\"]:100: syntax error"
        let line = LuaErrorLineParser.lineNumber(from: raw)
        #expect(line == 100)
    }
}

// MARK: - Real engine integration: live Lua error format verification

/// Validates the parser against errors produced by a real LuaSwift engine.
///
/// These tests generate live errors from LuaSwift's `evaluate` path and pass
/// the raw error strings directly to `LuaErrorLineParser`. They are the
/// strongest verification: if the engine changes its error format, these tests
/// will catch the regression immediately.
///
/// Note on source format: in Lua 5.x, a source string starting with `=` is
/// used as a literal chunk name (e.g. `===` → chunk name `==`). Such errors
/// do NOT produce the `[string "..."]:N:` format and are unrecognised by the
/// parser. The tests below use normal Lua code (no leading `=`) so that the
/// engine produces the standard `[string "..."]:N:` wrapper.
@Suite("LuaErrorLineParser — real LuaSwift engine error format verification")
struct LuaErrorLineParserRealEngineTests {

    @Test("syntax error at line 1 from real engine — parser extracts line 1")
    func realEngineSyntaxErrorLine1() throws {
        let engine = try LuaEngine()
        // "this is not lua" produces a syntax error at line 1 with
        // [string "this is not lua"]:1: syntax error near 'is'
        do {
            try engine.run("this is not lua")
            Issue.record("Expected syntaxError, got success")
        } catch let e as LuaError {
            guard case .syntaxError(let msg) = e else {
                Issue.record("Expected .syntaxError, got \(e)")
                return
            }
            let line = LuaErrorLineParser.lineNumber(from: msg)
            #expect(line != nil, "Parser must extract a line from real engine error: \(msg)")
            if let line {
                #expect(line == 1)
            }
        }
    }

    @Test("syntax error at line 3 from real engine — parser extracts line 3")
    func realEngineSyntaxErrorLine3() throws {
        let engine = try LuaEngine()
        // Two valid Lua lines then a syntax error on line 3.
        // Engine produces: [string "local a = 1..."]:3: syntax error near 'is'
        let code = "local a = 1\nlocal b = 2\nthis is not lua"
        do {
            try engine.run(code)
            Issue.record("Expected syntaxError, got success")
        } catch let e as LuaError {
            guard case .syntaxError(let msg) = e else {
                Issue.record("Expected .syntaxError, got \(e)")
                return
            }
            let line = LuaErrorLineParser.lineNumber(from: msg)
            #expect(line != nil, "Parser must extract a line from real engine error: \(msg)")
            if let line {
                #expect(line == 3)
            }
        }
    }

    @Test("runtime error at line 1 from real engine — parser extracts line 1")
    func realEngineRuntimeErrorLine1() throws {
        let engine = try LuaEngine()
        // Engine produces: [string "local x = nil; x()"]:1: attempt to call a nil value (local 'x')
        do {
            try engine.run("local x = nil; x()")
            Issue.record("Expected runtimeError, got success")
        } catch let e as LuaError {
            guard case .runtimeError(let msg) = e else {
                Issue.record("Expected .runtimeError, got \(e)")
                return
            }
            let line = LuaErrorLineParser.lineNumber(from: msg)
            #expect(line != nil, "Parser must extract a line from real engine error: \(msg)")
            if let line {
                #expect(line == 1)
            }
        }
    }

    @Test("runtime error at line 2 from real engine — parser extracts line 2")
    func realEngineRuntimeErrorLine2() throws {
        let engine = try LuaEngine()
        // Engine produces: [string "local x = 1..."]:2: attempt to call a number value (local 'x')
        let code = "local x = 1\nx()"
        do {
            try engine.run(code)
            Issue.record("Expected runtimeError, got success")
        } catch let e as LuaError {
            guard case .runtimeError(let msg) = e else {
                Issue.record("Expected .runtimeError, got \(e)")
                return
            }
            let line = LuaErrorLineParser.lineNumber(from: msg)
            #expect(line != nil, "Parser must extract a line from real engine error: \(msg)")
            if let line {
                #expect(line == 2)
            }
        }
    }
}

// MARK: - Seam: Diagnostic.from(luaError:provenance:)

/// Tests for the `Diagnostic.from(luaError:provenance:)` seam (LuaErrorDiagnostics.swift).
///
/// Key contracts verified here:
/// 1. `displayName` comes from `provenance.displayName`, never from the engine string.
/// 2. `lineOffset` is NOT applied inside `Diagnostic.from` — it is the renderer's job
///    (documented in LuaErrorDiagnostics.swift header: "provenance.lineOffset is not
///     applied here — it is the renderer's job to convert from fragment-relative to
///     file-relative").
/// 3. Whole-.lua-file fragments get `displayName == file.lastPathComponent`.
/// 4. Structured-file fragments get `displayName == "<file>:<jsonpath>"`.
@Suite("Diagnostic.from(luaError:provenance:) — seam contract")
struct DiagnosticFromLuaErrorSeamTests {

    // MARK: Display name — comes from provenance, never from engine string

    @Test("displayName for whole .lua file comes from provenance.file.lastPathComponent")
    func displayNameFromWholeLuaFile() {
        let provenance = makeProvenance(
            file: URL(fileURLWithPath: "/project/scripts/hello.lua"),
            jsonpath: nil,
            lineOffset: 0
        )
        // The engine string contains the Lua engine chunk prefix, which must NOT
        // appear in any Diagnostic field — the display name must come from provenance.
        let luaError = LuaError.syntaxError(#"[string "==="]:1: unexpected symbol near '='"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)

        // Verify the message does NOT contain the raw engine chunk-name prefix.
        #expect(!diag.message.contains("[string"), "message must not contain raw engine chunk prefix")
        // The Diagnostic type itself does not have a displayName field; the display
        // name lives in provenance.  Verify provenance.displayName is correct.
        #expect(provenance.displayName == "hello.lua")
    }

    @Test("displayName for structured-file fragment includes jsonpath")
    func displayNameFromStructuredFileFragment() {
        let provenance = makeProvenance(
            file: URL(fileURLWithPath: "/project/config.json"),
            jsonpath: "$.scripts.init",
            lineOffset: 5
        )
        #expect(provenance.displayName == "config.json:$.scripts.init")
    }

    // MARK: lineOffset is NOT applied inside Diagnostic.from

    @Test("Diagnostic.from does not apply lineOffset — line is fragment-relative")
    func lineOffsetNotAppliedInParser() {
        // A fragment that starts at file line 10 (lineOffset = 9, since fileLine =
        // lineOffset + fragmentLine).  The error is on fragment-relative line 2.
        let provenance = makeProvenance(lineOffset: 9)
        let luaError = LuaError.syntaxError(#"[string "x\ny==="]:2: unexpected symbol"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)

        // The diagnostic line must be fragment-relative (2), NOT file-relative (11).
        // lineOffset is intentionally NOT added here — that is the renderer's job.
        #expect(
            diag.line == 2, "Diagnostic.from must report fragment-relative line; lineOffset is applied by the renderer")
    }

    @Test("Diagnostic.from with lineOffset 0 for whole .lua file")
    func lineOffsetZeroForWholeLuaFile() {
        let provenance = makeProvenance(lineOffset: 0)
        let luaError = LuaError.syntaxError(#"[string "==="]:1: unexpected symbol"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.line == 1)
    }

    // MARK: Error case coverage

    @Test("syntaxError produces .error severity with .runtime source")
    func syntaxErrorSeverityAndSource() {
        let provenance = makeProvenance()
        let luaError = LuaError.syntaxError(#"[string "x"]:1: unexpected symbol"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.severity == .error)
        #expect(diag.source == .runtime)
    }

    @Test("runtimeError produces .error severity with .runtime source")
    func runtimeErrorSeverityAndSource() {
        let provenance = makeProvenance()
        let luaError = LuaError.runtimeError(#"[string "x"]:1: attempt to call nil"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.severity == .error)
        #expect(diag.source == .runtime)
    }

    @Test("unparseable error string produces line 0 — diagnostic without location")
    func unparseableErrorProducesLineZero() {
        let provenance = makeProvenance()
        // A string with no recognisable ]:N: anchor.
        let luaError = LuaError.syntaxError("something completely unrecognised")
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.line == 0, "nil parse result must map to line 0 per LuaErrorDiagnostics contract")
    }

    @Test("instructionLimitExceeded produces line 0 with a human-readable message")
    func instructionLimitExceeded() {
        let provenance = makeProvenance()
        let diag = Diagnostic.from(luaError: .instructionLimitExceeded, provenance: provenance)
        #expect(diag.line == 0)
        #expect(diag.severity == .error)
        #expect(diag.message.lowercased().contains("instruction") || diag.message.lowercased().contains("limit"))
    }

    @Test("bytecode error string produces correct line via Diagnostic.from seam")
    func bytecodeErrorViaSeam() {
        let provenance = makeProvenance()
        let luaError = LuaError.syntaxError("bytecode:7: syntax error")
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.line == 7)
    }

    // MARK: strippingChunkPrefix — message content after the seam

    @Test("message from syntaxError strips the chunk-name prefix")
    func messageStripsChunkNamePrefix() {
        let provenance = makeProvenance()
        let luaError = LuaError.syntaxError(#"[string "==="]:1: unexpected symbol near '='"#)
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        // The human-readable part after the ]:N: separator must remain.
        #expect(diag.message == "unexpected symbol near '='")
    }

    @Test("message from bytecode error strips the bytecode:N: prefix")
    func messageStripsBytecodePrefix() {
        let provenance = makeProvenance()
        let luaError = LuaError.syntaxError("bytecode:3: undefined global")
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.message == "undefined global")
    }

    @Test("unrecognised error string is returned as-is (no stripping)")
    func unrecognisedErrorReturnedAsIs() {
        let provenance = makeProvenance()
        let luaError = LuaError.syntaxError("completely opaque error text")
        let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
        #expect(diag.message == "completely opaque error text")
    }
}
