// File: Tests/MoonSwiftCoreTests/IntegrationTests.swift
// Location: MoonSwiftCoreTests/
// Role: Integration tests that drive the scenario fixtures in
//       Tests/MoonSwiftCoreTests/Fixtures/IntegrationFixtures/ through the
//       real production stack — RunService, LintService, and SourceStore —
//       without mocks.  Each test loads a fixture source file from the test
//       bundle, constructs a real LuaSourceFragment, and asserts the expected
//       outcome.
//
//       Fixture directories are bundled into MoonSwiftCoreTests via the
//       Package.swift `.copy("Fixtures")` resource rule (which bundles the
//       entire `Tests/MoonSwiftCoreTests/Fixtures/` tree, including the
//       `IntegrationFixtures/` subdirectory).  Tests locate scenarios with
//       Bundle.module.url(forResource:).
//
//       See Tests/MoonSwiftCoreTests/Fixtures/IntegrationFixtures/README.md
//       for the full scenario catalogue.
//
// Upstream: RunService, LintService, SourceStore, LuaModuleCatalog,
//           LuaSourceFragment, FragmentProvenance, RunConfig, Diagnostic
// Downstream: (test target only)

import Collections
import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Test helpers

/// Builds a `LuaSourceFragment` from a Lua source string with a synthetic provenance.
///
/// Used when a test constructs the fragment in Swift rather than loading it from disk.
private func makeFragment(code: String, path: String = "/test/script.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// Resolves an integration fixture directory URL inside the test bundle.
///
/// Scenario directories live in `Tests/MoonSwiftCoreTests/Fixtures/IntegrationFixtures/<scenario>/`
/// and are bundled by the `.copy("Fixtures")` resource rule in Package.swift.
/// The bundle resource path is `Fixtures/IntegrationFixtures/<scenario>`.
private func fixtureDir(_ scenario: String) -> URL {
    guard
        let url = Bundle.module.url(
            forResource: "Fixtures/IntegrationFixtures/\(scenario)",
            withExtension: nil
        )
    else {
        // Missing resource = the scenario directory was not bundled.
        preconditionFailure(
            "Fixture directory 'Fixtures/IntegrationFixtures/\(scenario)' not found in test "
                + "bundle. Ensure Tests/MoonSwiftCoreTests/Fixtures/IntegrationFixtures/\(scenario)"
                + "/ exists and Package.swift copies Tests/MoonSwiftCoreTests/Fixtures/."
        )
    }
    return url
}

/// Loads the text content of a file inside a fixture directory.
private func fixtureSource(scenario: String, filename: String) throws -> String {
    let url = fixtureDir(scenario).appendingPathComponent(filename)
    return try String(contentsOf: url, encoding: .utf8)
}

/// Thread-safe output line collector for RunService tests.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _transients: [String] = []

    func appendLine(_ s: String) {
        lock.withLock { _lines.append(s) }
    }

    func appendTransient(_ s: String) {
        lock.withLock { _transients.append(s) }
    }

    var lines: [String] { lock.withLock { _lines } }
    var transients: [String] { lock.withLock { _transients } }
}

/// Thread-safe callback capture for prewarm results.
private final class PrewarmCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _tomlAvailable: Bool?

    func markReady() { lock.withLock { _ready = true } }
    func markToml(_ v: Bool) { lock.withLock { _tomlAvailable = v } }
    var ready: Bool { lock.withLock { _ready } }
    var tomlAvailable: Bool? { lock.withLock { _tomlAvailable } }
}

/// Pre-warms a `LintService` and returns it ready for `lint(_:knownGlobals:)`.
private func prewarmedLintService() async throws -> LintService {
    let service = LintService()
    let capture = PrewarmCapture()
    await service.prewarm(
        onReady: { capture.markReady() },
        onCatalogProbed: { avail in capture.markToml(avail) }
    )
    guard capture.ready else {
        struct PrewarmFailed: Error, CustomStringConvertible {
            var description: String { "LintService prewarm failed — engine did not become ready" }
        }
        throw PrewarmFailed()
    }
    return service
}

/// Base globals table (catalog without toml, no opt-in modules).
private func baseGlobals() -> [String: Any] {
    LuaModuleCatalog.v0.luacheckGlobals(extraModules: [], tomlProbed: false)
}

// MARK: - Run integration tests

@Suite("Integration — RunService fixtures")
struct RunServiceIntegrationTests {

    // MARK: run-print-and-error

    @Test("print-and-error: output line arrives before .error outcome")
    func printAndError() async throws {
        let code = try fixtureSource(scenario: "run-print-and-error", filename: "print-and-error.lua")
        let fragment = makeFragment(code: code, path: "/fixtures/run-print-and-error/print-and-error.lua")
        let collector = LineCollector()
        let service = RunService { msg in collector.appendTransient(msg) }

        let outcome = await service.run(fragment, config: RunConfig()) { line in
            collector.appendLine(line)
        }

        // The print line must arrive before the error outcome.
        #expect(collector.lines == ["before error"], "Expected one output line 'before error'")

        guard case .error(let diag, _) = outcome else {
            Issue.record("Expected .error outcome, got \(outcome)")
            return
        }
        #expect(diag.severity == .error)
        #expect(diag.source == .runtime)
    }

    // MARK: run-return-value

    @Test("return-value: string return yields .done(value: 'hello')")
    func returnString() async throws {
        let code = try fixtureSource(scenario: "run-return-value", filename: "return-string.lua")
        let fragment = makeFragment(code: code)
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: RunConfig()) { _ in }

        guard case .done(let value, _) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(value == "hello")
    }

    @Test("return-value: integer return yields .done(value: '42')")
    func returnNumber() async throws {
        let code = try fixtureSource(scenario: "run-return-value", filename: "return-number.lua")
        let fragment = makeFragment(code: code)
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: RunConfig()) { _ in }

        guard case .done(let value, _) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(value == "42")
    }

    @Test("return-value: no explicit return yields .done(value: nil)")
    func returnNil() async throws {
        let code = try fixtureSource(scenario: "run-return-value", filename: "return-nil.lua")
        let fragment = makeFragment(code: code)
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: RunConfig()) { _ in }

        guard case .done(let value, _) = outcome else {
            Issue.record("Expected .done, got \(outcome)")
            return
        }
        #expect(value == nil, "No-return script must yield nil return value")
    }

    // MARK: run-runaway-loop

    @Test("runaway-loop: instruction limit terminates the loop as .limitExceeded(.instructions)")
    func runawayLoop() async throws {
        let code = try fixtureSource(scenario: "run-runaway-loop", filename: "runaway-loop.lua")
        let fragment = makeFragment(code: code)
        // Use a small limit so the test completes in < 1 ms wall-clock.
        let config = RunConfig(instructionLimit: 1_000)
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: config) { _ in }

        guard case .limitExceeded(let kind) = outcome else {
            Issue.record("Expected .limitExceeded, got \(outcome)")
            return
        }
        #expect(kind == .instructions)
    }

    // MARK: run-sandbox-test

    @Test("sandbox-test: sandboxed mode reports 'sandboxed' (os.getenv is nil)")
    func sandboxedMode() async throws {
        let code = try fixtureSource(scenario: "run-sandbox-test", filename: "sandbox-test.lua")
        let fragment = makeFragment(code: code)
        let collector = LineCollector()
        let service = RunService { _ in }

        _ = await service.run(fragment, config: RunConfig(config: .sandboxed)) { line in
            collector.appendLine(line)
        }

        #expect(collector.lines == ["sandboxed"], "Sandboxed mode must strip os.getenv")
    }

    @Test("sandbox-test: unrestricted mode reports 'unrestricted' (os.getenv present)")
    func unrestrictedMode() async throws {
        let code = try fixtureSource(scenario: "run-sandbox-test", filename: "sandbox-test.lua")
        let fragment = makeFragment(code: code)
        let collector = LineCollector()
        let service = RunService { _ in }

        _ = await service.run(fragment, config: RunConfig(config: .unrestricted)) { line in
            collector.appendLine(line)
        }

        #expect(collector.lines == ["unrestricted"], "Unrestricted mode must expose os.getenv")
    }

    // MARK: run-instruction-limit

    @Test("instruction-limit: output before limit trip arrives; outcome is .limitExceeded")
    func instructionLimitWithOutput() async throws {
        let code = try fixtureSource(scenario: "run-instruction-limit", filename: "instruction-limit.lua")
        let fragment = makeFragment(code: code)
        let collector = LineCollector()
        let config = RunConfig(instructionLimit: 5_000)
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: config) { line in
            collector.appendLine(line)
        }

        #expect(collector.lines == ["before limit"], "Output before the limit must arrive")

        guard case .limitExceeded(let kind) = outcome else {
            Issue.record("Expected .limitExceeded, got \(outcome)")
            return
        }
        #expect(kind == .instructions)
    }
}

// MARK: - Lint integration tests

@Suite("Integration — LintService fixtures")
struct LintServiceIntegrationTests {

    // MARK: lint-clean

    @Test("lint-clean: zero diagnostics for a style-clean script")
    func lintClean() async throws {
        let svc = try await prewarmedLintService()
        let code = try fixtureSource(scenario: "lint-clean", filename: "clean.lua")
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: baseGlobals())
        #expect(diagnostics.isEmpty, "Clean script must produce zero diagnostics, got \(diagnostics)")
    }

    // MARK: lint-undefined-global

    @Test("lint-undefined-global: W1xx warning for undefined global")
    func lintUndefinedGlobal() async throws {
        let svc = try await prewarmedLintService()
        let code = try fixtureSource(scenario: "lint-undefined-global", filename: "undefined-global.lua")
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: baseGlobals())

        let w1xx = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(!w1xx.isEmpty, "Expected at least one W1xx warning for undefined global")
    }

    // MARK: lint-syntax-error

    @Test("lint-syntax-error: syntaxPrePass catches error on line >= 3")
    func lintSyntaxError() throws {
        let service = LintService()
        // The fixture file is valid Lua; we append an invalid statement to create
        // the syntax error at runtime (see syntax-error.lua header comment).
        let validCode = try fixtureSource(scenario: "lint-syntax-error", filename: "syntax-error.lua")
        let invalidCode = validCode + "\nthis is not valid Lua ==="
        let fragment = makeFragment(code: invalidCode)

        let diag = service.syntaxPrePass(fragment)

        guard let d = diag else {
            Issue.record("Expected a syntax diagnostic, got nil")
            return
        }
        #expect(d.severity == .error)
        #expect(d.source == .syntaxPrePass)
        // The error is appended after the valid lines, so line number > 3.
        #expect(d.line > 3, "Expected error on a line after the valid code, got line \(d.line)")
    }

    // MARK: lint-luaswift-modules

    @Test("lint-luaswift-modules: luaswift.* references are clean with catalog globals")
    func lintLuaswiftModules() async throws {
        let svc = try await prewarmedLintService()
        let code = try fixtureSource(scenario: "lint-luaswift-modules", filename: "luaswift-modules.lua")
        let fragment = makeFragment(code: code)
        let diagnostics = try await svc.lint(fragment, knownGlobals: baseGlobals())

        let w1xx = diagnostics.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }
        #expect(w1xx.isEmpty, "luaswift.* must not produce W1xx warnings with catalog globals, got \(w1xx)")
    }

    // MARK: lint-opt-in-modules

    @Test("lint-opt-in-modules: iox in extra_modules reduces W1xx warnings")
    func lintOptInModules() async throws {
        let svc = try await prewarmedLintService()
        let code = try fixtureSource(scenario: "lint-opt-in-modules", filename: "opt-in-modules.lua")
        let fragment = makeFragment(code: code)

        let globalsWithout = LuaModuleCatalog.v0.luacheckGlobals(extraModules: [], tomlProbed: false)
        let globalsWithIox = LuaModuleCatalog.v0.luacheckGlobals(extraModules: ["iox"], tomlProbed: false)

        let diagsWithout = try await svc.lint(fragment, knownGlobals: globalsWithout)
        let diagsWith = try await svc.lint(fragment, knownGlobals: globalsWithIox)

        let w1xx: ([Diagnostic]) -> Int = { diags in
            diags.filter { $0.source == .luacheck && ($0.code?.hasPrefix("1") ?? false) }.count
        }

        #expect(
            w1xx(diagsWith) <= w1xx(diagsWithout),
            "iox in extra_modules must not increase W1xx count: without=\(w1xx(diagsWithout)), with=\(w1xx(diagsWith))"
        )
    }
}

// MARK: - SourceStore structured-file integration tests

/// Drives `SourceStore.loadStructuredFile` with the scenario fixtures in
/// `Tests/Fixtures/structured-*/` and `Tests/Fixtures/error-*/`.
@Suite("Integration — SourceStore structured-file fixtures")
struct SourceStoreFixtureIntegrationTests {

    // MARK: structured-yaml

    @Test("structured-yaml: loads $.scripts.init and $.scripts.run as two .loaded events")
    func structuredYaml() async {
        let dir = fixtureDir("structured-yaml")
        let fields = [
            FieldDesignation(jsonpath: "$.scripts.init"),
            FieldDesignation(jsonpath: "$.scripts.run"),
        ]
        let events = await SourceStore.loadStructuredFile(at: "config.yaml", projectRoot: dir, fields: fields)

        #expect(events.count == 2, "Expected 2 events, got \(events.count)")
        let loaded = events.compactMap { event -> String? in
            guard case .loaded(_, let frag) = event else { return nil }
            return frag.code
        }
        #expect(loaded.contains("print('yaml init')"))
        #expect(loaded.contains("return 99"))
    }

    // MARK: structured-json

    @Test("structured-json: loads $.handlers.onCreate as a single .loaded event")
    func structuredJson() async {
        let dir = fixtureDir("structured-json")
        let fields = [FieldDesignation(jsonpath: "$.handlers.onCreate")]
        let events = await SourceStore.loadStructuredFile(at: "config.json", projectRoot: dir, fields: fields)

        #expect(events.count == 1)
        guard case .loaded(let id, let fragment) = events[0] else {
            Issue.record("Expected .loaded, got \(events[0])")
            return
        }
        #expect(id.path == "config.json")
        #expect(id.jsonpath == "$.handlers.onCreate")
        #expect(fragment.code == "print('json create')")
    }

    // MARK: structured-toml

    // BUG REPORT — SpanLocator: TOML array-of-tables index step fails
    //
    // Expected: $.hooks[0].script resolves to a .loaded event with
    //           fragment.code == "print('toml hook')" for [[hooks]] TOML tables.
    //
    // Actual: SpanLocator.walkTOML hits the .index(0) step expecting
    //         node.nodeType == "array", but TOML array-of-tables produces
    //         sibling `table_array_element` nodes at the document level,
    //         NOT a single `array` node containing element children. The guard
    //         `guard node.nodeType == "array"` (SpanLocator.swift walkTOML,
    //         case .index) throws `.nodeNotFound`, causing SourceStore to emit
    //         .failed with "span location failed … nodeNotFound".
    //
    // Root cause: walkTOML handles [table].key steps via `tomlFindTable`, which
    //   correctly matches the first `table_array_element` named "hooks" and
    //   returns that node. The subsequent .index(0) step then receives the
    //   matched `table_array_element` and expects it to be an "array" node —
    //   but TOML's grammar does not wrap [[arr]] elements in an enclosing array
    //   node; all `table_array_element` siblings with the same key form the
    //   logical array at the document level.
    //
    // Fix (not done here — task spec: do not touch Sources/): SpanLocator
    //   walkTOML case .index(n) must detect that the current node is a
    //   `table_array_element` (meaning the path traversal already resolved the
    //   key and arrived at a single element). Instead of indexing an array node,
    //   it should walk the document-level children to find the Nth
    //   `table_array_element` with the same header key, then descend into that
    //   element for the remaining path steps.
    //
    // Test below documents the current (broken) behaviour so CI catches any
    // regression and serves as a specification for the fix.
    @Test("structured-toml: $.hooks[0].script from array-of-tables (BUG: span location fails)")
    func structuredToml() async {
        let dir = fixtureDir("structured-toml")
        let fields = [FieldDesignation(jsonpath: "$.hooks[0].script")]
        let events = await SourceStore.loadStructuredFile(at: "config.toml", projectRoot: dir, fields: fields)

        #expect(events.count == 1, "Expected exactly one event")
        guard let first = events.first else { return }

        // BUG: currently produces .failed due to SpanLocator nodeNotFound on
        //      TOML array-of-tables index step. Document the actual broken state.
        switch first {
        case .loaded(_, let fragment):
            // If this branch is reached the bug is fixed — assert correct value.
            #expect(
                fragment.code == "print('toml hook')",
                "Fixed SpanLocator must return the first hooks entry"
            )
        case .failed(_, let state):
            // Bug is still present: verify it is a span-location failure, not
            // a parse or path-resolution failure (which would indicate a different problem).
            guard case .failed(let diag) = state else {
                Issue.record(
                    "Expected .failed(Diagnostic) for span-location bug, got .missing: \(state)"
                )
                return
            }
            #expect(
                diag.message.contains("span location failed") && diag.message.contains("nodeNotFound"),
                "BUG: must be a span-location nodeNotFound failure, got: \(diag.message)"
            )
        }
    }

    // MARK: structured-multi-doc

    @Test("structured-multi-doc: document 0 and 1 each yield one .loaded event")
    func structuredMultiDoc() async {
        let dir = fixtureDir("structured-multi-doc")
        let fields = [
            FieldDesignation(jsonpath: "$.script", document: 0),
            FieldDesignation(jsonpath: "$.script", document: 1),
        ]
        let events = await SourceStore.loadStructuredFile(at: "multi-doc.yaml", projectRoot: dir, fields: fields)

        #expect(events.count == 2, "Expected 2 events for 2 document designations, got \(events.count)")

        let codes = events.compactMap { event -> String? in
            guard case .loaded(_, let frag) = event else { return nil }
            return frag.code
        }
        #expect(codes.contains("print('doc0')"), "Document 0 code missing from events")
        #expect(codes.contains("print('doc1')"), "Document 1 code missing from events")
    }

    // MARK: structured-wildcard

    @Test("structured-wildcard: $.handlers.* yields two .loaded events for each handler")
    func structuredWildcard() async {
        let dir = fixtureDir("structured-wildcard")
        let fields = [FieldDesignation(jsonpath: "$.handlers.*")]
        let events = await SourceStore.loadStructuredFile(at: "wildcard.yaml", projectRoot: dir, fields: fields)

        #expect(events.count == 2, "Wildcard must yield one event per matched handler, got \(events.count)")
        let codes = events.compactMap { event -> String? in
            guard case .loaded(_, let frag) = event else { return nil }
            return frag.code
        }
        #expect(codes.contains("print('wildcard created')"))
        #expect(codes.contains("print('wildcard deleted')"))
    }

    // MARK: error-missing-source

    @Test("error-missing-source: .failed with .missing state for absent file")
    func errorMissingSource() async {
        let dir = fixtureDir("error-missing-source")
        let id = SourceID(path: "does-not-exist.lua")
        let event = await SourceStore.loadLuaFile(at: "does-not-exist.lua", projectRoot: dir, id: id)

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed event, got \(event)")
            return
        }
        guard case .missing = state else {
            Issue.record("Expected .missing state, got \(state)")
            return
        }
    }

    // MARK: error-malformed-yaml

    @Test("error-malformed-yaml: .failed with '✖' diagnostic for malformed YAML")
    func errorMalformedYaml() async {
        let dir = fixtureDir("error-malformed-yaml")
        let fields = [FieldDesignation(jsonpath: "$.scripts.init")]
        let events = await SourceStore.loadStructuredFile(at: "malformed.yaml", projectRoot: dir, fields: fields)

        guard let first = events.first else {
            Issue.record("No events returned for malformed YAML")
            return
        }
        guard case .failed(_, let state) = first else {
            Issue.record("Expected .failed, got \(first)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }
        #expect(diag.severity == .error)
        #expect(diag.message.hasPrefix("✖"), "Malformed-file error must start with ✖, got: \(diag.message)")
    }

    // MARK: error-non-string-field

    @Test("error-non-string-field: .failed diagnostic contains 'expected string'")
    func errorNonStringField() async {
        let dir = fixtureDir("error-non-string-field")
        let fields = [FieldDesignation(jsonpath: "$.version")]
        let events = await SourceStore.loadStructuredFile(at: "config.json", projectRoot: dir, fields: fields)

        guard let first = events.first else {
            Issue.record("No events returned for non-string field")
            return
        }
        guard case .failed(_, let state) = first else {
            Issue.record("Expected .failed, got \(first)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }
        #expect(diag.severity == .warning)
        #expect(
            diag.message.contains("expected string"),
            "Non-string-field diagnostic must mention 'expected string', got: \(diag.message)"
        )
    }

    // MARK: error-unresolved-path

    @Test("error-unresolved-path: .failed with '⚠' diagnostic for unresolved JSONPath")
    func errorUnresolvedPath() async {
        let dir = fixtureDir("error-unresolved-path")
        let fields = [FieldDesignation(jsonpath: "$.nonexistent.path")]
        let events = await SourceStore.loadStructuredFile(at: "config.yaml", projectRoot: dir, fields: fields)

        guard let first = events.first else {
            Issue.record("No events returned for unresolved path")
            return
        }
        guard case .failed(_, let state) = first else {
            Issue.record("Expected .failed, got \(first)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }
        #expect(diag.severity == .warning)
        #expect(
            diag.message.hasPrefix("⚠"),
            "Unresolved-path warning must start with ⚠, got: \(diag.message)"
        )
    }
}

// MARK: - Parser hostile-input integration tests

@Suite("Integration — parser hostile-input fixtures")
struct ParserHostileInputTests {

    // MARK: parser-hostile-chunkname

    @Test("hostile-chunkname: syntaxPrePass returns nil — code is valid despite hostile chars")
    func hostileChunknameSyntaxClean() throws {
        let service = LintService()
        let code = try fixtureSource(
            scenario: "parser-hostile-chunkname",
            filename: "hostile-chunkname.lua"
        )
        let fragment = makeFragment(code: code)
        let diag = service.syntaxPrePass(fragment)
        #expect(diag == nil, "Hostile-chunkname script is valid Lua; pre-pass must return nil")
    }

    @Test("hostile-chunkname: luacheck long-string encoder round-trips code without corruption")
    func hostileChunknameFullLint() async throws {
        let svc = try await prewarmedLintService()
        let code = try fixtureSource(
            scenario: "parser-hostile-chunkname",
            filename: "hostile-chunkname.lua"
        )
        let fragment = makeFragment(code: code)

        // If the long-string encoder breaks on "]:" the lint engine will crash
        // or produce an error diagnostic with source .luacheck for an engine error.
        // A successful lint call (no throw) means the round-trip was lossless.
        let diagnostics = try await svc.lint(fragment, knownGlobals: baseGlobals())

        // No engine-level failures; only possible warnings for the code itself.
        let engineErrors = diagnostics.filter {
            $0.source == .runtime || $0.source == .syntaxPrePass
        }
        #expect(
            engineErrors.isEmpty,
            "Hostile-chunkname must not produce engine-level errors, got \(engineErrors)"
        )
    }

    // MARK: parser-hostile-message

    @Test("hostile-message: Diagnostic.message preserves the full error string including ']:1:'")
    func hostileMessagePreservesContent() async throws {
        let code = try fixtureSource(
            scenario: "parser-hostile-message",
            filename: "hostile-message.lua"
        )
        let fragment = makeFragment(code: code, path: "/fixtures/hostile-message.lua")
        let service = RunService { _ in }

        let outcome = await service.run(fragment, config: RunConfig()) { _ in }

        guard case .error(let diag, _) = outcome else {
            Issue.record("Expected .error outcome, got \(outcome)")
            return
        }

        // The error message must contain the hostile substring — the parser must
        // not strip "]:1:" thinking it is a location prefix.
        #expect(
            diag.message.contains("]:1:"),
            "Diagnostic message must preserve ']:1:' hostile content, got: \(diag.message)"
        )
    }
}

// MARK: - JSONPath integration tests

/// Exercises the RFC 9535 subset JSONPath implementation against the real
/// structured-file fixtures, verifying both supported constructs and rejection
/// of unsupported ones.
@Suite("Integration — JSONPath RFC 9535 supported/rejected constructs")
struct JSONPathIntegrationTests {

    // MARK: Supported: child name, array index, wildcard, descendant

    @Test("JSONPath: child name selector resolves correctly")
    func childNameSelector() throws {
        let expr = try JSONPathExpression(parsing: "$.scripts.init")
        let tree = TreeValue.map(
            OrderedDictionary(uniqueKeysWithValues: [
                (
                    "scripts",
                    TreeValue.map(
                        OrderedDictionary(uniqueKeysWithValues: [
                            ("init", TreeValue.string("print('hello')")),
                            ("run", TreeValue.string("return 1")),
                        ])
                    )
                )
            ])
        )
        let results = expr.evaluate(on: tree)
        #expect(results.count == 1)
        #expect(results.first?.value == .string("print('hello')"))
    }

    @Test("JSONPath: array index selector resolves first element")
    func arrayIndexSelector() throws {
        let expr = try JSONPathExpression(parsing: "$.hooks[0].script")
        let tree = TreeValue.map(
            OrderedDictionary(uniqueKeysWithValues: [
                (
                    "hooks",
                    TreeValue.array([
                        TreeValue.map(
                            OrderedDictionary(uniqueKeysWithValues: [
                                ("script", TreeValue.string("print('hook0')")),
                                ("name", TreeValue.string("startup")),
                            ])
                        ),
                        TreeValue.map(
                            OrderedDictionary(uniqueKeysWithValues: [
                                ("script", TreeValue.string("return 0")),
                                ("name", TreeValue.string("shutdown")),
                            ])
                        ),
                    ])
                )
            ])
        )
        let results = expr.evaluate(on: tree)
        #expect(results.count == 1)
        #expect(results.first?.value == .string("print('hook0')"))
    }

    @Test("JSONPath: wildcard selector returns all children")
    func wildcardSelector() throws {
        let expr = try JSONPathExpression(parsing: "$.handlers.*")
        let tree = TreeValue.map(
            OrderedDictionary(uniqueKeysWithValues: [
                (
                    "handlers",
                    TreeValue.map(
                        OrderedDictionary(uniqueKeysWithValues: [
                            ("onCreate", TreeValue.string("print('created')")),
                            ("onDelete", TreeValue.string("print('deleted')")),
                        ])
                    )
                )
            ])
        )
        let results = expr.evaluate(on: tree)
        #expect(results.count == 2)
        let values = Set(results.compactMap { if case .string(let s) = $0.value { s } else { nil } })
        #expect(values == ["print('created')", "print('deleted')"])
    }

    @Test("JSONPath: no-match path returns empty array (no crash)")
    func noMatchReturnsEmpty() throws {
        let expr = try JSONPathExpression(parsing: "$.nonexistent.deep.path")
        let tree = TreeValue.map(
            OrderedDictionary(uniqueKeysWithValues: [("key", TreeValue.string("value"))])
        )
        let results = expr.evaluate(on: tree)
        #expect(results.isEmpty)
    }

    // MARK: Rejected unsupported constructs

    @Test("JSONPath: filter expressions are rejected at parse time")
    func filterExpressionRejected() {
        #expect(throws: (any Error).self) {
            _ = try JSONPathExpression(parsing: "$.store.book[?(@.price < 10)]")
        }
    }

    @Test("JSONPath: script expressions are rejected at parse time")
    func scriptExpressionRejected() {
        #expect(throws: (any Error).self) {
            _ = try JSONPathExpression(parsing: "$..book[(@.length-1)]")
        }
    }

    @Test("JSONPath: bare '.' without a name is rejected")
    func bareDotRejected() {
        #expect(throws: (any Error).self) {
            _ = try JSONPathExpression(parsing: "$.")
        }
    }
}

// MARK: - OrderedDictionary convenience (local to this test target)

/// A minimal ordered-key dictionary helper so tests can build `TreeValue.map`
/// values without importing the full `swift-collections` type.
extension OrderedDictionary where Key == String, Value == TreeValue {
    fileprivate init(uniqueKeysWithValues pairs: [(String, TreeValue)]) {
        self.init()
        for (k, v) in pairs { self[k] = v }
    }
}
