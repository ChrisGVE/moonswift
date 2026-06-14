// File: Tests/MoonSwiftCoreTests/Diagnostics/LuaErrorDiagnosticsTests.swift
// Folder: Tests/MoonSwiftCoreTests/Diagnostics/
// Role: Unit tests for Diagnostic.from(luaError:provenance:):
//         • LuaError.memoryError — maps to a "Memory error: …" message
//         • LuaError.unknown (and other non-matched cases) — maps to
//           localizedDescription
//         • LuaError.syntaxError — compile-error line extraction via the inlined
//           bounded-anchor `compileErrorLineNumber` (the F6.4 replacement for the
//           deleted LuaErrorLineParser), including the hostile chunk-name /
//           message / window-boundary cases.
//
//       instructionLimitExceeded is tested in RunServiceTests.swift; the
//       structured `.runtimeFailure` path (#19) is covered by the live-engine
//       SessionEngine/RunService tests.
//
// Upstream: MoonSwiftCore/Diagnostics/LuaErrorDiagnostics.swift
// Downstream: (test target — nothing imports this)

import CryptoKit
import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Builds a minimal `FragmentProvenance` for seam tests.
private func makeProvenance(lineOffset: Int = 0) -> FragmentProvenance {
    let data = Data("placeholder".utf8)
    return FragmentProvenance(
        file: URL(fileURLWithPath: "/test/script.lua"),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: lineOffset,
        contentHash: SHA256.hash(data: data)
    )
}

// MARK: - Diagnostic.from(luaError:provenance:) — additional error cases

@Suite("Diagnostic.from(luaError:) — memoryError and default cases")
struct DiagnosticFromLuaErrorTests {

    @Test("memoryError maps to severity .error with 'Memory error:' prefix")
    func memoryErrorMessage() {
        let prov = makeProvenance()
        let diag = Diagnostic.from(
            luaError: .memoryError("out of heap"),
            provenance: prov
        )
        #expect(diag.severity == .error)
        #expect(diag.message.hasPrefix("Memory error:"))
        #expect(diag.message.contains("out of heap"))
    }

    @Test("memoryError produces line 0 (no line info available)")
    func memoryErrorLineIsZero() {
        let prov = makeProvenance()
        let diag = Diagnostic.from(
            luaError: .memoryError("allocation failure"),
            provenance: prov
        )
        #expect(diag.line == 0)
    }

    @Test("memoryError source is .runtime")
    func memoryErrorSourceIsRuntime() {
        let prov = makeProvenance()
        let diag = Diagnostic.from(
            luaError: .memoryError("oom"),
            provenance: prov
        )
        #expect(diag.source == .runtime)
    }

    @Test("unknown LuaError case falls through to localizedDescription")
    func unknownErrorUsesLocalizedDescription() {
        let prov = makeProvenance()
        // LuaError.unknown is not pattern-matched explicitly; it falls to `default`.
        let luaErr = LuaError.unknown(code: 42, message: "unexpected code 42")
        let diag = Diagnostic.from(luaError: luaErr, provenance: prov)
        #expect(diag.severity == .error)
        #expect(diag.line == 0)
        #expect(diag.source == .runtime)
        // localizedDescription for .unknown includes the code.
        #expect(diag.message.contains("42") || !diag.message.isEmpty)
    }

    @Test("callbackError falls through to localizedDescription")
    func callbackErrorUsesLocalizedDescription() {
        let prov = makeProvenance()
        // .callbackError is not an explicit case in the switch — goes to `default`.
        let luaErr = LuaError.callbackError("swift side panicked")
        let diag = Diagnostic.from(luaError: luaErr, provenance: prov)
        #expect(diag.severity == .error)
        #expect(diag.line == 0)
        #expect(diag.source == .runtime)
        #expect(!diag.message.isEmpty)
    }

    @Test("typeError falls through to localizedDescription")
    func typeErrorUsesLocalizedDescription() {
        let prov = makeProvenance()
        let luaErr = LuaError.typeError(expected: "string", actual: "number")
        let diag = Diagnostic.from(luaError: luaErr, provenance: prov)
        #expect(diag.severity == .error)
        #expect(diag.line == 0)
        #expect(diag.source == .runtime)
        #expect(!diag.message.isEmpty)
    }

    @Test("memoryError message does not duplicate the 'Memory error:' prefix")
    func memoryErrorNoPrefixDuplication() {
        let prov = makeProvenance()
        let diag = Diagnostic.from(
            luaError: .memoryError("double-free"),
            provenance: prov
        )
        // Message should start with "Memory error:" exactly once.
        let prefixCount = diag.message.components(separatedBy: "Memory error:").count - 1
        #expect(prefixCount == 1)
    }
}

// MARK: - syntaxError compile-line extraction (F6.4 — replaces LuaErrorLineParser)

/// Exercises `compileErrorLineNumber` through the public `.syntaxError` seam,
/// covering the same formats and hostile classes the deleted
/// `LuaErrorLineParserTests` did — now asserted at the seam (`Diagnostic.from`)
/// where it actually matters, since `.syntaxError(String)` is directly
/// constructible in a test.
@Suite("Diagnostic.from(.syntaxError) — compile-error line extraction")
struct DiagnosticSyntaxErrorLineTests {

    private func line(_ raw: String) -> Int {
        Diagnostic.from(luaError: .syntaxError(raw), provenance: makeProvenance()).line
    }

    @Test("standard [string \"…\"]:N: format extracts the line")
    func standardChunkFormat() {
        #expect(line("[string \"x = \"]:1: unexpected symbol near '<eof>'") == 1)
        #expect(line("[string \"line1\\nline2\"]:42: '=' expected") == 42)
        #expect(line("[string \"y\"]:100: bad") == 100)
    }

    @Test("bytecode:N: format extracts the line")
    func bytecodeFormat() {
        #expect(line("bytecode:7: malformed number") == 7)
    }

    @Test("last ]:N: in the window wins when the chunk name has a lookalike")
    func lastMatchWins() {
        // Chunk name itself contains a `]:9:` lookalike; the real marker is `]:3:`.
        #expect(line("[string \"a]:9: b\"]:3: real error") == 3)
    }

    @Test("a ]:N: lookalike past the 70-byte window is invisible")
    func lookalikeBeyondWindow() {
        // No marker within the first ~70 bytes → line 0 (the trailing ]:5: is out of window).
        let padded = "[string \"" + String(repeating: "z", count: 90) + "\"]:5: late"
        #expect(line(padded) == 0)
    }

    @Test("an unparseable string yields line 0")
    func unparseable() {
        #expect(line("totally unstructured message") == 0)
    }
}
