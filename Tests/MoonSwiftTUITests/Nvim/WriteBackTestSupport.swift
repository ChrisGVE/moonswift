// File: Tests/MoonSwiftTUITests/Nvim/WriteBackTestSupport.swift
// Location: MoonSwiftTUITests/Nvim/
// Role: Shared test support for WriteBackCoordinatorTests — the MockLintService
//       used to control syntaxPrePass outcomes without a real LuaEngine, and the
//       WriteBackFixtures namespace with temp-dir, fixture-copy, and provenance
//       builders shared by all write-back suites.
// Upstream: LintServiceProtocol, SpanLocator, TreeDecoder*, FragmentProvenance
// Downstream: WriteBackCoordinatorTests.swift (sole consumer)

import CryptoKit
import Foundation

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - MockLintService

/// Minimal mock that lets tests control whether syntaxPrePass returns a
/// Diagnostic or nil without spinning up a real LuaEngine.
struct MockLintService: LintServiceProtocol {

    /// When non-nil, syntaxPrePass returns this diagnostic for every call.
    let stubbedDiagnostic: Diagnostic?

    init(stubbedDiagnostic: Diagnostic? = nil) {
        self.stubbedDiagnostic = stubbedDiagnostic
    }

    func syntaxPrePass(_ fragment: LuaSourceFragment) -> Diagnostic? {
        return stubbedDiagnostic
    }

    func lint(
        _ fragment: LuaSourceFragment,
        knownGlobals: [String: Any]
    ) async throws -> [Diagnostic] {
        return []
    }

    func prewarm(
        onReady: @escaping @Sendable () -> Void,
        onCatalogProbed: @escaping @Sendable (_ tomlAvailable: Bool) -> Void,
        onFailed: @escaping @Sendable (_ message: String) -> Void
    ) async {
        onReady()
    }
}

// MARK: - WriteBackFixtures

/// Namespace for fixture and provenance helpers shared by the write-back suites.
enum WriteBackFixtures {

    /// Returns a `URL` inside a fresh temporary directory (unique per test call).
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteBackCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies the fixture file named `name` from MoonSwiftCoreTests/Fixtures/Sources
    /// into `destinationDir` and returns the URL of the copy.
    ///
    /// Uses `#filePath` navigation: Tests/MoonSwiftTUITests/Nvim/ → up 3 dirs →
    /// Tests/ → MoonSwiftCoreTests/Fixtures/Sources/<name>.
    static func copyFixture(
        _ name: String,
        into destinationDir: URL,
        file: StaticString = #filePath
    ) throws -> URL {
        let testRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // Nvim/
            .deletingLastPathComponent()  // MoonSwiftTUITests/
            .deletingLastPathComponent()  // Tests/

        let fixtureURL =
            testRoot
            .appendingPathComponent("MoonSwiftCoreTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Sources")
            .appendingPathComponent(name)

        let destURL = destinationDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL, to: destURL)
        return destURL
    }

    /// Build a `FragmentProvenance` for a **whole Lua file** at `fileURL`.
    static func luaProvenance(fileURL: URL) throws -> FragmentProvenance {
        let data = try Data(contentsOf: fileURL)
        return FragmentProvenance(
            file: fileURL,
            jsonpath: nil,
            document: 0,
            byteRange: 0..<data.count,
            lineOffset: 0,
            contentHash: SHA256.hash(data: data)
        )
    }

    /// Build a `FragmentProvenance` for a structured-file field, locating the span
    /// from the current bytes on disk (for test setup only — real code re-locates).
    static func structuredProvenance(
        fileURL: URL,
        jsonpath: String,
        format: StructuredFileFormat,
        document: Int = 0
    ) throws -> FragmentProvenance {
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8)!
        let expr = try JSONPathExpression(parsing: jsonpath)
        let tree: TreeValue
        switch format {
        case .json: tree = try decodeJSON(text)
        case .yaml: tree = try decodeYAML(text, document: document)
        case .toml: tree = try decodeTOML(text)
        }
        let matches = expr.evaluate(on: tree)
        guard matches.first != nil else {
            struct NoMatch: Error {}
            throw NoMatch()
        }
        let loc = try SpanLocator.locateSpan(
            in: data,
            format: format,
            path: matches[0].path.steps,
            document: document
        )
        return FragmentProvenance(
            file: fileURL,
            jsonpath: jsonpath,
            document: document,
            byteRange: loc.byteRange,
            lineOffset: loc.lineOffset,
            contentHash: SHA256.hash(data: data)
        )
    }
}
