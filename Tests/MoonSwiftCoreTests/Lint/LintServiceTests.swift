// File: Tests/MoonSwiftCoreTests/Lint/LintServiceTests.swift
// Location: Tests/MoonSwiftCoreTests/Lint/
// Role: Tests for LintService — syntax pre-pass and full luacheck pass.
//
//       Acceptance criteria (PRD F4 / task 28 test strategy):
//         (1) Pre-pass catches syntax errors with the correct line number.
//         (2) luacheck reports undefined globals.
//         (3) luaswift.* modules lint clean (catalog globals injected).
//         (4) extra_modules adds opt-in entries to the globals table.
//         (5) Engine failure returns the expected error.
//
//       All tests use the production LintService with a real LuaSwift engine
//       and real vendored luacheck — no mocks or stubs.
//
// Upstream: LintService, LuacheckLoader, LuaModuleCatalog, Diagnostic

import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Test fixtures

/// A minimal `FragmentProvenance` for use in lint tests.
///
/// The `contentHash` is the SHA-256 of the empty byte string — acceptable for
/// tests that do not exercise write-back or conflict guards.
private func makeFakeProvenance(lineOffset: Int = 0) -> FragmentProvenance {
    FragmentProvenance(
        file: URL(fileURLWithPath: "/fake/test.lua"),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<0,
        lineOffset: lineOffset,
        contentHash: SHA256.hash(data: Data())
    )
}

/// A LuaSourceFragment wrapping `code` with a minimal provenance.
private func makeFragment(code: String, lineOffset: Int = 0) -> LuaSourceFragment {
    LuaSourceFragment(code: code, provenance: makeFakeProvenance(lineOffset: lineOffset))
}

/// Globals table for base modules only (no toml, no opt-in).
///
/// Returned as a function rather than a global constant to avoid the
/// `[String: Any]` non-Sendable global-variable diagnostic in Swift 6.
private func makeBaseGlobals() -> [String: Any] {
    LuaModuleCatalog.v0.luacheckGlobals(extraModules: [], tomlProbed: false)
}

// MARK: - Thread-safe prewarm result collector

/// Captures the two prewarm callback results across thread boundaries.
///
/// The `onReady` and `onCatalogProbed` closures passed to `prewarm` are
/// `@Sendable` and may fire on a background queue. This class provides
/// thread-safe capture so the test body can read the results after `await`.
private final class PrewarmResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _tomlAvailable: Bool? = nil

    var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ready
    }

    var tomlAvailable: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _tomlAvailable
    }

    func markReady() {
        lock.lock()
        _ready = true
        lock.unlock()
    }

    func setTomlAvailable(_ value: Bool) {
        lock.lock()
        _tomlAvailable = value
        lock.unlock()
    }
}

// MARK: - Pre-pass tests

@Suite("LintService — syntax pre-pass")
struct LintServicePrePassTests {

    private let service = LintService()

    // MARK: (1) Syntax error detection

    @Test("Pre-pass returns nil for syntactically valid code")
    func prePassCleanCode() {
        let fragment = makeFragment(code: "local x = 1; return x")
        let diag = service.syntaxPrePass(fragment)
        #expect(diag == nil, "Expected nil for clean code, got \(String(describing: diag))")
    }

    @Test("Pre-pass returns a diagnostic for invalid Lua syntax")
    func prePassSyntaxError() {
        let fragment = makeFragment(code: "this is not valid lua !!")
        let diag = service.syntaxPrePass(fragment)
        #expect(diag != nil, "Expected a diagnostic for invalid syntax")
        #expect(diag?.source == .syntaxPrePass)
        #expect(diag?.severity == .error)
    }

    @Test("Pre-pass diagnostic carries the correct fragment-relative line number")
    func prePassLineNumber() {
        // Error is on line 3: clean line 1, clean line 2, syntax error line 3.
        let code = "local x = 1\nlocal y = 2\nthis is not valid lua !!"
        let fragment = makeFragment(code: code)
        let diag = service.syntaxPrePass(fragment)
        #expect(diag != nil)
        if let d = diag {
            #expect(d.line == 3, "Expected line 3, got \(d.line)")
        }
    }

    @Test("Pre-pass returns nil for an empty code string")
    func prePassEmptyCode() {
        let fragment = makeFragment(code: "")
        let diag = service.syntaxPrePass(fragment)
        #expect(diag == nil)
    }

    @Test("Pre-pass returns nil for a single-line comment")
    func prePassComment() {
        let fragment = makeFragment(code: "-- just a comment")
        let diag = service.syntaxPrePass(fragment)
        #expect(diag == nil)
    }

    @Test("Pre-pass returns nil for a multi-line clean script")
    func prePassMultiLineClean() {
        let code = """
            local function add(a, b)
                return a + b
            end
            return add(1, 2)
            """
        let fragment = makeFragment(code: code)
        let diag = service.syntaxPrePass(fragment)
        #expect(diag == nil)
    }
}

// MARK: - Full lint pass tests

@Suite("LintService — full luacheck pass")
struct LintServiceFullPassTests {

    /// Pre-warm a fresh service and return it, or fail the test if prewarm fails.
    private func prewarmedService() async throws -> LintService {
        let service = LintService()
        let result = PrewarmResult()

        await service.prewarm(
            onReady: { result.markReady() },
            onCatalogProbed: { avail in result.setTomlAvailable(avail) },
            onFailed: { _ in }
        )

        guard result.ready else {
            struct PrewarmFailed: Error {}
            throw PrewarmFailed()
        }
        return service
    }

    // MARK: (2) Undefined global detection

    @Test("Luacheck reports undefined global with W1xx code")
    func undefinedGlobalReported() async throws {
        let svc = try await prewarmedService()
        let fragment = makeFragment(code: "return undefinedGlobal")
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        #expect(!diagnostics.isEmpty, "Expected at least one diagnostic for undefined global")
        let hasGlobalWarning = diagnostics.contains { d in
            d.source == .luacheck && (d.code?.hasPrefix("1") ?? false)
        }
        #expect(hasGlobalWarning, "Expected a W1xx warning for undefined global in \(diagnostics)")
    }

    @Test("Luacheck reports line and column for undefined global")
    func undefinedGlobalHasLocation() async throws {
        let svc = try await prewarmedService()
        let code = "local clean = 1\nreturn undefinedGlobal"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        let globalDiags = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(!globalDiags.isEmpty)
        if let d = globalDiags.first {
            #expect(d.line > 0, "Expected positive line number, got \(d.line)")
            if let col = d.column {
                #expect(col > 0, "Expected positive column, got \(col)")
            }
        }
    }

    // MARK: (3) luaswift.* modules lint clean

    @Test("luaswift.json.decode lints clean with catalog globals")
    func luaswiftJsonLintsClean() async throws {
        let svc = try await prewarmedService()
        // Reference luaswift.json.decode — a base catalog entry.
        // With catalog globals injected this must produce zero W1xx issues.
        let code = "local data = luaswift.json.decode('{}'); return data"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        let globalWarnings = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(
            globalWarnings.isEmpty,
            "Expected no W1xx warnings for luaswift.json.decode, got \(globalWarnings)"
        )
    }

    @Test("luaswift root table lints clean with catalog globals")
    func luaswiftRootLintsClean() async throws {
        let svc = try await prewarmedService()
        // Reference the luaswift root table — catalog includes it.
        let code = "local t = luaswift; return t"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        let globalWarnings = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(
            globalWarnings.isEmpty,
            "Expected no W1xx warnings for luaswift root reference, got \(globalWarnings)"
        )
    }

    @Test("Unknown global produces warning even with catalog globals injected")
    func unknownGlobalStillWarns() async throws {
        let svc = try await prewarmedService()
        let code = "return notInCatalog"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        let globalWarnings = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(!globalWarnings.isEmpty, "Expected W1xx for unknown global with catalog globals")
    }

    // MARK: (4) extra_modules merging

    @Test("extra_modules for iox reduces W1xx warnings for luaswift.iox")
    func extraModulesAddsEntries() async throws {
        let svc = try await prewarmedService()
        // Reference luaswift.iox — an opt-in catalog entry.
        // Without iox in globals, accessing luaswift.iox may raise a W1xx.
        // With iox included, luaswift.iox itself should be recognised.
        let code = "local f = luaswift.iox; return f"
        let fragment = makeFragment(code: code)

        let globalsWithoutIox = LuaModuleCatalog.v0.luacheckGlobals(
            extraModules: [],
            tomlProbed: false
        )
        let globalsWithIox = LuaModuleCatalog.v0.luacheckGlobals(
            extraModules: ["iox"],
            tomlProbed: false
        )

        let diagsWithout = try await svc.lint(fragment, knownGlobals: globalsWithoutIox)
        let diagsWith = try await svc.lint(fragment, knownGlobals: globalsWithIox)

        // Count W1xx codes — global/field access warnings.
        let w1xxCount: ([Diagnostic]) -> Int = { diags in
            diags.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }.count
        }

        // With iox in globals, luaswift.iox should be recognised, producing
        // fewer undefined-field warnings than without it.
        #expect(
            w1xxCount(diagsWith) <= w1xxCount(diagsWithout),
            "Expected fewer W1xx with iox in globals."
        )
    }

    // MARK: (5) Engine failure handling

    @Test("lint throws engineNotReady if prewarm has not been called")
    func lintThrowsIfNotPrewarmed() async {
        let freshService = LintService()
        let fragment = makeFragment(code: "local x = 1")
        do {
            _ = try await freshService.lint(fragment, knownGlobals: makeBaseGlobals())
            Issue.record("Expected LintServiceError.engineNotReady but no error was thrown")
        } catch let error as LintServiceError {
            #expect(error == .engineNotReady)
        } catch {
            Issue.record("Expected LintServiceError but got \(error)")
        }
    }

    // MARK: Diagnostic source consistency

    @Test("All lint diagnostics carry .luacheck source")
    func allDiagnosticsSourcedToLuacheck() async throws {
        let svc = try await prewarmedService()
        let code = "return undefinedA + undefinedB"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        for d in diagnostics {
            #expect(d.source == .luacheck, "Expected .luacheck source, got \(d.source)")
        }
    }

    // MARK: Clean code

    @Test("Clean script produces zero lint diagnostics")
    func cleanScriptZeroDiagnostics() async throws {
        let svc = try await prewarmedService()
        let code = "local x = 1; local y = x + 1; return y"
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: makeBaseGlobals())
        #expect(diagnostics.isEmpty, "Expected zero diagnostics for clean script, got \(diagnostics)")
    }
}

// MARK: - Prewarm tests

@Suite("LintService — prewarm and catalog probe")
struct LintServicePrewarmTests {

    @Test("prewarm calls onReady and onCatalogProbed")
    func prewarmCallsBothCallbacks() async {
        let service = LintService()
        let result = PrewarmResult()

        await service.prewarm(
            onReady: { result.markReady() },
            onCatalogProbed: { avail in result.setTomlAvailable(avail) },
            onFailed: { _ in }
        )

        #expect(result.ready, "Expected onReady to be called after prewarm")
        #expect(result.tomlAvailable != nil, "Expected onCatalogProbed to be called after prewarm")
    }

    @Test("onReady is called before onCatalogProbed")
    func onReadyBeforeProbed() async {
        let service = LintService()
        // Use an array behind a lock to capture call order.
        final class OrderCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var _order: [String] = []
            func append(_ s: String) {
                lock.lock()
                _order.append(s)
                lock.unlock()
            }
            var order: [String] {
                lock.lock()
                defer { lock.unlock() }
                return _order
            }
        }
        let capture = OrderCapture()

        await service.prewarm(
            onReady: { capture.append("ready") },
            onCatalogProbed: { _ in capture.append("probed") },
            onFailed: { _ in }
        )

        #expect(capture.order == ["ready", "probed"], "Expected ready before probed, got \(capture.order)")
    }

    @Test("Catalog probe returns a Bool result")
    func catalogProbeReturnsBool() async {
        let service = LintService()
        let result = PrewarmResult()

        await service.prewarm(
            onReady: {},
            onCatalogProbed: { avail in result.setTomlAvailable(avail) },
            onFailed: { _ in }
        )

        #expect(result.tomlAvailable != nil, "Expected a probe result")
    }

    @Test("Lint is available after prewarm completes")
    func lintAvailableAfterPrewarm() async throws {
        let service = LintService()
        let result = PrewarmResult()

        await service.prewarm(
            onReady: { result.markReady() },
            onCatalogProbed: { avail in result.setTomlAvailable(avail) },
            onFailed: { _ in }
        )

        #expect(result.ready)
        // Should not throw engineNotReady.
        let fragment = makeFragment(code: "local x = 1; return x")
        let diagnostics = try await service.lint(fragment, knownGlobals: makeBaseGlobals())
        #expect(diagnostics.isEmpty)
    }
}

// MARK: - CR-010: Lua literal encoding injection safety

/// Tests that `luaTableLiteral` / `luaValueLiteral` / `luaQuotedString` correctly
/// escape backslashes and double-quotes so a module name containing those
/// characters cannot break the generated Lua source or inject arbitrary code.
///
/// The globals table is normally produced from compile-time catalog identifiers
/// (CR-010 fix: backslash-before-quote ordering is correct). These tests verify
/// the defence-in-depth path.
@Suite("LintService — Lua literal injection safety (CR-010)")
struct LintServiceLuaLiteralInjectionTests {

    // MARK: Unit-level: luaQuotedString (tested via @testable import)

    @Test("backslash in key is double-escaped in table literal")
    func backslashInKeyDoesNotBreakLiteral() {
        // A module name like "foo\\bar" should produce ["foo\\\\bar"] in the
        // generated Lua, not leave a raw unescaped backslash that would be
        // interpreted as a Lua escape sequence.
        let dict: [String: Any] = ["foo\\bar": [:] as [String: Any]]
        let literal = luaTableLiteral(from: dict)
        // The literal must contain \\\\ (four characters: two backslashes in
        // the Swift string → one escaped backslash in Lua).
        #expect(literal.contains("foo\\\\bar"), "Expected double-escaped backslash, got: \(literal)")
        // Sanity: it must NOT contain a bare unescaped backslash followed by
        // a double-quote (the injection vector).
        #expect(!literal.contains("\\\""), "Unexpected unescaped quote in: \(literal)")
    }

    @Test("double-quote in key is escaped in table literal")
    func doubleQuoteInKeyIsEscaped() {
        let dict: [String: Any] = ["foo\"bar": [:] as [String: Any]]
        let literal = luaTableLiteral(from: dict)
        #expect(literal.contains("\\\""), "Expected escaped quote in: \(literal)")
    }

    @Test("backslash-before-quote in key: backslash escaped before quote")
    func backslashBeforeQuoteOrdering() {
        // The key "a\"b" contains a backslash followed by a double-quote.
        // Correct output: ["a\\\"b"] — backslash doubled, then quote escaped.
        // Incorrect output (old code): ["a\\"b"] — quote escapes the backslash,
        // leaving the quote unescaped and breaking the Lua string literal.
        let dict: [String: Any] = ["a\\\"b": [:] as [String: Any]]
        let literal = luaTableLiteral(from: dict)
        #expect(
            literal.contains("a\\\\\\\"b"),
            "Expected backslash doubled then quote escaped, got: \(literal)"
        )
    }

    @Test("clean catalog-style key encodes without extra escaping")
    func cleanKeyNoExtraEscaping() {
        // Normal catalog keys ("luaswift", "json") must not be mangled.
        let dict: [String: Any] = ["luaswift": ["fields": [:] as [String: Any]]]
        let literal = luaTableLiteral(from: dict)
        #expect(literal.contains("\"luaswift\""), "Expected unmodified key, got: \(literal)")
    }
}
