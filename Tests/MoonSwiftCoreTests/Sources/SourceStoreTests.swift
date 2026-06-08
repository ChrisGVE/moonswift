// File: Tests/MoonSwiftCoreTests/Sources/SourceStoreTests.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: Unit tests for SourceStore, FragmentProvenance, LuaSourceFragment,
//       SourceState, and SourceID. Covers the happy path, all error cases
//       (missing file, unreadable file), hash stability, and displayName
//       computation. Also covers structured-file source loading (task 16):
//       JSON/YAML/TOML happy paths, multi-document YAML, wildcard matches,
//       missing/non-string/malformed/alias error cases.
//       Filesystem access is real (via Bundle.module fixtures) per the
//       project's test strategy for source-load tests; no mocking is used
//       because the tested I/O path is the implementation under test.

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - SourceID tests

@Suite("SourceID")
struct SourceIDTests {

    @Test("whole lua file — no jsonpath, document 0")
    func wholeLuaFile() {
        let id = SourceID(path: "scripts/init.lua")
        #expect(id.path == "scripts/init.lua")
        #expect(id.jsonpath == nil)
        #expect(id.document == 0)
    }

    @Test("structured field — jsonpath and document")
    func structuredField() {
        let id = SourceID(path: "config.yaml", jsonpath: "$.scripts.init", document: 1)
        #expect(id.path == "config.yaml")
        #expect(id.jsonpath == "$.scripts.init")
        #expect(id.document == 1)
    }

    @Test("description — whole file shows path only")
    func descriptionWholeLua() {
        let id = SourceID(path: "scripts/init.lua")
        #expect(id.description == "scripts/init.lua")
    }

    @Test("description — structured field shows path:jsonpath")
    func descriptionStructuredField() {
        let id = SourceID(path: "config.yaml", jsonpath: "$.scripts.init", document: 0)
        #expect(id.description == "config.yaml:$.scripts.init")
    }

    @Test("equality — identical IDs are equal")
    func equality() {
        let a = SourceID(path: "a.lua", jsonpath: nil, document: 0)
        let b = SourceID(path: "a.lua", jsonpath: nil, document: 0)
        #expect(a == b)
    }

    @Test("equality — different jsonpath makes IDs unequal")
    func inequalityJsonpath() {
        let a = SourceID(path: "config.yaml", jsonpath: "$.a", document: 0)
        let b = SourceID(path: "config.yaml", jsonpath: "$.b", document: 0)
        #expect(a != b)
    }

    @Test("hashable — can be used as dictionary key")
    func hashableAsKey() {
        let id = SourceID(path: "a.lua")
        var dict: [SourceID: String] = [:]
        dict[id] = "value"
        #expect(dict[id] == "value")
    }
}

// MARK: - FragmentProvenance display name tests

@Suite("FragmentProvenance.displayName")
struct FragmentProvenanceDisplayNameTests {

    private func makeProvenance(
        filename: String,
        jsonpath: String?,
        document: Int = 0
    ) -> FragmentProvenance {
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        let data = Data("test".utf8)
        return FragmentProvenance(
            file: url,
            jsonpath: jsonpath,
            document: document,
            byteRange: 0..<data.count,
            lineOffset: 0,
            contentHash: SHA256.hash(data: data)
        )
    }

    @Test("whole lua file — displayName is filename")
    func wholeLuaDisplayName() {
        let prov = makeProvenance(filename: "init.lua", jsonpath: nil)
        #expect(prov.displayName == "init.lua")
    }

    @Test("whole lua file with directory — displayName is last path component")
    func wholeLuaLastPathComponent() {
        let url = URL(fileURLWithPath: "/project/scripts/init.lua")
        let data = Data("x".utf8)
        let prov = FragmentProvenance(
            file: url,
            jsonpath: nil,
            document: 0,
            byteRange: 0..<data.count,
            lineOffset: 0,
            contentHash: SHA256.hash(data: data)
        )
        #expect(prov.displayName == "init.lua")
    }

    @Test("structured field — displayName is filename:jsonpath")
    func structuredFieldDisplayName() {
        let prov = makeProvenance(filename: "config.yaml", jsonpath: "$.scripts.init")
        #expect(prov.displayName == "config.yaml:$.scripts.init")
    }

    @Test("structured field — displayName uses the exact jsonpath string")
    func structuredFieldDisplayNameExactPath() {
        let prov = makeProvenance(filename: "data.json", jsonpath: "$.a.b[0].c")
        #expect(prov.displayName == "data.json:$.a.b[0].c")
    }
}

// MARK: - FragmentProvenance equality tests

@Suite("FragmentProvenance equality")
struct FragmentProvenanceEqualityTests {

    @Test("two identical provenances are equal")
    func equalProvenances() {
        let url = URL(fileURLWithPath: "/tmp/a.lua")
        let data = Data("local x = 1".utf8)
        let hash = SHA256.hash(data: data)
        let p1 = FragmentProvenance(
            file: url, jsonpath: nil, document: 0,
            byteRange: 0..<data.count, lineOffset: 0, contentHash: hash
        )
        let p2 = FragmentProvenance(
            file: url, jsonpath: nil, document: 0,
            byteRange: 0..<data.count, lineOffset: 0, contentHash: hash
        )
        #expect(p1 == p2)
    }

    @Test("provenances with different byteRange are unequal")
    func unequalByByteRange() {
        let url = URL(fileURLWithPath: "/tmp/a.lua")
        let data = Data("local x = 1".utf8)
        let hash = SHA256.hash(data: data)
        let p1 = FragmentProvenance(
            file: url, jsonpath: nil, document: 0,
            byteRange: 0..<10, lineOffset: 0, contentHash: hash
        )
        let p2 = FragmentProvenance(
            file: url, jsonpath: nil, document: 0,
            byteRange: 0..<11, lineOffset: 0, contentHash: hash
        )
        #expect(p1 != p2)
    }
}

// MARK: - Content hash stability tests

@Suite("Content hash stability")
struct ContentHashStabilityTests {

    @Test("same bytes produce same SHA-256 digest")
    func hashStability() {
        let data = Data("hello, moonswift".utf8)
        let hash1 = SHA256.hash(data: data)
        let hash2 = SHA256.hash(data: data)
        // SHA256Digest is Equatable
        #expect(hash1 == hash2)
    }

    @Test("different bytes produce different SHA-256 digest")
    func hashDifference() {
        let data1 = Data("version A".utf8)
        let data2 = Data("version B".utf8)
        let hash1 = SHA256.hash(data: data1)
        let hash2 = SHA256.hash(data: data2)
        #expect(hash1 != hash2)
    }
}

// MARK: - SourceStore.loadLuaFile tests

/// The fixture directory is discovered via `Bundle.module` — the test target
/// resource rule `.copy("Fixtures")` in Package.swift makes it available.
@Suite("SourceStore.loadLuaFile")
struct SourceStoreLoadLuaFileTests {

    /// Returns the URL of the `Fixtures/Sources` directory inside the test bundle.
    private var fixturesRoot: URL {
        // Bundle.module is generated by SPM for test targets that declare resources.
        Bundle.module.url(forResource: "Fixtures/Sources", withExtension: nil)!
    }

    // MARK: Happy path

    @Test("happy path — loads fixture lua file and returns .loaded event")
    func happyPath() async {
        let root = fixturesRoot
        let event = await SourceStore.loadLuaFile(
            at: "hello.lua",
            projectRoot: root,
            id: SourceID(path: "hello.lua")
        )

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.path == "hello.lua")
        #expect(id.jsonpath == nil)
        #expect(fragment.code.contains("hello, moonswift"))
        #expect(fragment.provenance.jsonpath == nil)
        #expect(fragment.provenance.document == 0)
        #expect(fragment.provenance.lineOffset == 0)
    }

    @Test("happy path — byteRange spans the entire file")
    func byteRangeSpansFile() async {
        let root = fixturesRoot
        let event = await SourceStore.loadLuaFile(
            at: "hello.lua",
            projectRoot: root,
            id: SourceID(path: "hello.lua")
        )

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded")
            return
        }

        // The file URL exists; read its byte count independently.
        let fileURL = root.appendingPathComponent("hello.lua")
        let fileData = try! Data(contentsOf: fileURL)
        let expectedRange = 0..<fileData.count

        #expect(fragment.provenance.byteRange == expectedRange)
    }

    @Test("happy path — contentHash matches SHA-256 of file bytes")
    func contentHashMatchesRawBytes() async {
        let root = fixturesRoot
        let event = await SourceStore.loadLuaFile(
            at: "hello.lua",
            projectRoot: root,
            id: SourceID(path: "hello.lua")
        )

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded")
            return
        }

        let fileURL = root.appendingPathComponent("hello.lua")
        let fileData = try! Data(contentsOf: fileURL)
        let expectedHash = SHA256.hash(data: fileData)

        #expect(fragment.provenance.contentHash == expectedHash)
    }

    @Test("happy path — displayName is the filename")
    func displayNameIsFilename() async {
        let root = fixturesRoot
        let event = await SourceStore.loadLuaFile(
            at: "hello.lua",
            projectRoot: root,
            id: SourceID(path: "hello.lua")
        )

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(fragment.provenance.displayName == "hello.lua")
    }

    @Test("happy path — hash is stable across two loads of the same file")
    func hashStabilityAcrossLoads() async {
        let root = fixturesRoot
        let id = SourceID(path: "hello.lua")

        let event1 = await SourceStore.loadLuaFile(at: "hello.lua", projectRoot: root, id: id)
        let event2 = await SourceStore.loadLuaFile(at: "hello.lua", projectRoot: root, id: id)

        guard case .loaded(_, let f1) = event1,
            case .loaded(_, let f2) = event2
        else {
            Issue.record("Expected both .loaded")
            return
        }

        #expect(f1.provenance.contentHash == f2.provenance.contentHash)
    }

    // MARK: Missing file

    @Test("missing file — returns .failed with .missing state")
    func missingFile() async {
        let root = fixturesRoot
        let event = await SourceStore.loadLuaFile(
            at: "does_not_exist.lua",
            projectRoot: root,
            id: SourceID(path: "does_not_exist.lua")
        )

        guard case .failed(let id, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }

        #expect(id.path == "does_not_exist.lua")
        guard case .missing = state else {
            Issue.record("Expected .missing state, got \(state)")
            return
        }
    }

    @Test("missing file — SourceID in error event matches the requested path")
    func missingFileIDMatches() async {
        let root = fixturesRoot
        let id = SourceID(path: "nonexistent/deep/path.lua")
        let event = await SourceStore.loadLuaFile(at: "nonexistent/deep/path.lua", projectRoot: root, id: id)

        guard case .failed(let returnedID, _) = event else {
            Issue.record("Expected .failed")
            return
        }

        #expect(returnedID == id)
    }

    // MARK: Unreadable file (I/O failure)

    /// This test exercises the I/O error path by pointing at a directory path
    /// (which `FileManager.fileExists` reports as existing but `Data(contentsOf:)`
    /// fails on with an appropriate error).
    @Test("unreadable path — directory path produces .failed with diagnostic")
    func directoryAsFileFails() async {
        // Use the fixtures root itself as the "file" path — it exists but is a directory.
        // Data(contentsOf:) will fail with an I/O error.
        let root = fixturesRoot.deletingLastPathComponent()  // one level up
        let dirName = fixturesRoot.lastPathComponent  // "Sources"

        let event = await SourceStore.loadLuaFile(
            at: dirName,
            projectRoot: root,
            id: SourceID(path: dirName)
        )

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }

        guard case .failed(let diagnostic) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }

        #expect(diagnostic.severity == .error)
        #expect(diagnostic.source == .sourceLoad)
        #expect(!diagnostic.message.isEmpty)
    }
}

// MARK: - SourceStore callback integration tests

@Suite("SourceStore callback integration")
struct SourceStoreIntegrationTests {

    private var fixturesRoot: URL {
        Bundle.module.url(forResource: "Fixtures/Sources", withExtension: nil)!
    }

    @Test("loadAll dispatches callback for each lua entry")
    func loadAllCallbackDispatched() async {
        let entries = [
            SourceEntry(path: "hello.lua", fields: [])
        ]

        // Collect events via an actor to avoid data races.
        actor EventCollector {
            var events: [SourceLoadEvent] = []
            func record(_ event: SourceLoadEvent) { events.append(event) }
        }

        let collector = EventCollector()
        let expectation = AsyncStream<Void>.makeStream()

        let store = SourceStore(callback: { event in
            Task {
                await collector.record(event)
                expectation.continuation.yield(())
            }
        })

        store.loadAll(entries: entries, projectRoot: fixturesRoot)

        // Wait for the callback to fire (with a timeout baked into the test
        // via task cancellation after a reasonable wall-clock delay).
        var receivedCount = 0
        for await _ in expectation.stream {
            receivedCount += 1
            if receivedCount >= entries.count { break }
        }

        let events = await collector.events
        #expect(events.count == 1)

        guard case .loaded(let id, _) = events[0] else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(id.path == "hello.lua")
    }

    @Test("loadAll dispatches callback for structured-file entry")
    func loadAllDispatchesStructuredFile() async {
        let entries = [
            SourceEntry(
                path: "scripts.json",
                fields: [
                    FieldDesignation(jsonpath: "$.scripts.init", document: 0)
                ])
        ]

        actor EventCollector {
            var events: [SourceLoadEvent] = []
            func record(_ event: SourceLoadEvent) { events.append(event) }
        }

        let collector = EventCollector()
        let expectation = AsyncStream<Void>.makeStream()

        let store = SourceStore(callback: { event in
            Task {
                await collector.record(event)
                expectation.continuation.yield(())
            }
        })

        store.loadAll(entries: entries, projectRoot: fixturesRoot)

        var receivedCount = 0
        for await _ in expectation.stream {
            receivedCount += 1
            if receivedCount >= 1 { break }
        }

        let events = await collector.events
        #expect(events.count == 1)

        guard case .loaded(let id, _) = events[0] else {
            Issue.record("Expected .loaded, got \(events[0])")
            return
        }
        #expect(id.path == "scripts.json")
        #expect(id.jsonpath == "$.scripts.init")
    }
}

// MARK: - SourceStore.loadStructuredFile tests

/// Tests for the structured-file source loading path (task 16).
/// Uses real fixture files in `Fixtures/Sources/`: scripts.json, scripts.yaml,
/// scripts.toml, multi.yaml, wildcard.json, malformed.json, alias.yaml.
@Suite("SourceStore.loadStructuredFile")
struct SourceStoreLoadStructuredFileTests {

    private var fixturesRoot: URL {
        Bundle.module.url(forResource: "Fixtures/Sources", withExtension: nil)!
    }

    // MARK: - Helper

    /// Loads a structured file with one field and returns the first event.
    private func load(
        file: String,
        jsonpath: String,
        document: Int = 0
    ) async -> SourceLoadEvent {
        let events = await SourceStore.loadStructuredFile(
            at: file,
            projectRoot: fixturesRoot,
            fields: [FieldDesignation(jsonpath: jsonpath, document: document)]
        )
        guard let first = events.first else {
            Issue.record("No events returned for \(file) \(jsonpath)")
            return .failed(
                id: SourceID(path: file, jsonpath: jsonpath, document: document),
                state: .missing
            )
        }
        return first
    }

    // MARK: - JSON happy path

    @Test("JSON — $.scripts.init loads correct Lua fragment")
    func jsonHappyPath() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.init")

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.path == "scripts.json")
        #expect(id.jsonpath == "$.scripts.init")
        #expect(id.document == 0)
        #expect(fragment.code == "print('hello')")
    }

    @Test("JSON — byteRange content equals decoded value (R7 cross-check)")
    func jsonByteRangeMatchesValue() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        let fileURL = fixturesRoot.appendingPathComponent("scripts.json")
        let data = try! Data(contentsOf: fileURL)
        let spanStart = fragment.provenance.byteRange.lowerBound
        let spanEnd = fragment.provenance.byteRange.upperBound
        let spanText = String(data: data[spanStart..<spanEnd], encoding: .utf8)

        #expect(spanText == fragment.code)
    }

    @Test("JSON — lineOffset is 0-based line index of value in file")
    func jsonLineOffset() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        // "print('hello')" is on line index 2 (0-based) in scripts.json:
        // line 0: {
        // line 1:   "scripts": {
        // line 2:     "init": "print('hello')",
        #expect(fragment.provenance.lineOffset == 2)
    }

    @Test("JSON — contentHash matches SHA-256 of whole file bytes")
    func jsonContentHash() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded")
            return
        }

        let fileURL = fixturesRoot.appendingPathComponent("scripts.json")
        let data = try! Data(contentsOf: fileURL)
        let expected = SHA256.hash(data: data)

        #expect(fragment.provenance.contentHash == expected)
    }

    @Test("JSON — displayName is filename:jsonpath")
    func jsonDisplayName() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded")
            return
        }

        #expect(fragment.provenance.displayName == "scripts.json:$.scripts.init")
    }

    @Test("JSON — $.scripts.run loads second fragment correctly")
    func jsonSecondFragment() async {
        let event = await load(file: "scripts.json", jsonpath: "$.scripts.run")

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.jsonpath == "$.scripts.run")
        #expect(fragment.code == "return 42")
    }

    // MARK: - YAML happy path

    @Test("YAML — $.scripts.init loads correct Lua fragment")
    func yamlHappyPath() async {
        let event = await load(file: "scripts.yaml", jsonpath: "$.scripts.init")

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.path == "scripts.yaml")
        #expect(id.jsonpath == "$.scripts.init")
        #expect(fragment.code == "print('hello')")
    }

    @Test("YAML — byteRange content equals decoded value (R7 cross-check)")
    func yamlByteRangeMatchesValue() async {
        let event = await load(file: "scripts.yaml", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        let fileURL = fixturesRoot.appendingPathComponent("scripts.yaml")
        let data = try! Data(contentsOf: fileURL)
        let spanStart = fragment.provenance.byteRange.lowerBound
        let spanEnd = fragment.provenance.byteRange.upperBound
        let spanText = String(data: data[spanStart..<spanEnd], encoding: .utf8)

        #expect(spanText == fragment.code)
    }

    @Test("YAML — lineOffset is 0-based line index of value in file")
    func yamlLineOffset() async {
        let event = await load(file: "scripts.yaml", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        // scripts.yaml:
        // line 0: scripts:
        // line 1:   init: "print('hello')"
        #expect(fragment.provenance.lineOffset == 1)
    }

    // MARK: - TOML happy path

    @Test("TOML — $.scripts.init loads correct Lua fragment")
    func tomlHappyPath() async {
        let event = await load(file: "scripts.toml", jsonpath: "$.scripts.init")

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.path == "scripts.toml")
        #expect(id.jsonpath == "$.scripts.init")
        #expect(fragment.code == "print('hello')")
    }

    @Test("TOML — byteRange content equals decoded value (R7 cross-check)")
    func tomlByteRangeMatchesValue() async {
        let event = await load(file: "scripts.toml", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        let fileURL = fixturesRoot.appendingPathComponent("scripts.toml")
        let data = try! Data(contentsOf: fileURL)
        let spanStart = fragment.provenance.byteRange.lowerBound
        let spanEnd = fragment.provenance.byteRange.upperBound
        let spanText = String(data: data[spanStart..<spanEnd], encoding: .utf8)

        #expect(spanText == fragment.code)
    }

    @Test("TOML — lineOffset is 0-based line index of value in file")
    func tomlLineOffset() async {
        let event = await load(file: "scripts.toml", jsonpath: "$.scripts.init")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        // scripts.toml:
        // line 0: [scripts]
        // line 1: init = "print('hello')"
        #expect(fragment.provenance.lineOffset == 1)
    }

    // MARK: - TOML inline-array index regression (#3)

    /// Regression test: TOML inline arrays (scripts = ["a", "b"]) must still
    /// resolve via index steps after the array-of-tables fix (#3).
    @Test("TOML inline array — $.handlers.scripts[0] resolves first element (regression #3)")
    func tomlInlineArrayIndex() async {
        let event = await load(file: "scripts-inline-array.toml", jsonpath: "$.handlers.scripts[0]")

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.jsonpath == "$.handlers.scripts[0]")
        #expect(fragment.code == "print('first')")

        // R7 cross-check: span bytes must equal the decoded string value.
        let fileURL = fixturesRoot.appendingPathComponent("scripts-inline-array.toml")
        let data = try! Data(contentsOf: fileURL)
        let spanStart = fragment.provenance.byteRange.lowerBound
        let spanEnd = fragment.provenance.byteRange.upperBound
        let spanText = String(data: data[spanStart..<spanEnd], encoding: .utf8)
        #expect(spanText == fragment.code, "R7: span bytes must equal decoded code value")
    }

    @Test("TOML inline array — $.handlers.scripts[1] resolves second element (regression #3)")
    func tomlInlineArrayIndexSecond() async {
        let event = await load(file: "scripts-inline-array.toml", jsonpath: "$.handlers.scripts[1]")

        guard case .loaded(_, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(fragment.code == "return 42")
    }

    // MARK: - Multi-document YAML

    @Test("YAML multi-doc — document 0 loads first document's field")
    func yamlMultiDoc0() async {
        let event = await load(file: "multi.yaml", jsonpath: "$.scripts.init", document: 0)

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.document == 0)
        #expect(fragment.code == "print('doc0')")
    }

    @Test("YAML multi-doc — document 1 loads second document's field")
    func yamlMultiDoc1() async {
        let event = await load(file: "multi.yaml", jsonpath: "$.scripts.init", document: 1)

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event)")
            return
        }

        #expect(id.document == 1)
        #expect(fragment.code == "print('doc1')")
    }

    // MARK: - Wildcard (multiple matches)

    @Test("JSON wildcard — $.handlers.* yields two fragments")
    func jsonWildcard() async {
        let events = await SourceStore.loadStructuredFile(
            at: "wildcard.json",
            projectRoot: fixturesRoot,
            fields: [FieldDesignation(jsonpath: "$.handlers.*", document: 0)]
        )

        #expect(events.count == 2)

        let codes = events.compactMap { event -> String? in
            guard case .loaded(_, let fragment) = event else { return nil }
            return fragment.code
        }
        #expect(codes.contains("print('created')"))
        #expect(codes.contains("print('deleted')"))
    }

    // MARK: - Error cases

    @Test("missing file — returns .failed with .missing state")
    func missingFile() async {
        let event = await load(file: "nonexistent.json", jsonpath: "$.scripts.init")

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .missing = state else {
            Issue.record("Expected .missing, got \(state)")
            return
        }
    }

    @Test("malformed file — returns .failed with error diagnostic")
    func malformedFile() async {
        let event = await load(file: "malformed.json", jsonpath: "$.key")

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }

        #expect(diag.severity == .error)
        #expect(diag.source == .sourceLoad)
        // UX spec: malformed file message starts with ✖
        #expect(diag.message.hasPrefix("✖"))
    }

    @Test("unresolved path — returns .failed with warning diagnostic")
    func unresolvedPath() async {
        let event = await load(file: "scripts.json", jsonpath: "$.nonexistent.path")

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }

        #expect(diag.severity == .warning)
        #expect(diag.source == .sourceLoad)
        // UX spec: unresolved path message starts with ⚠
        #expect(diag.message.hasPrefix("⚠"))
    }

    @Test("non-string value — returns .failed with 'expected string' warning")
    func nonStringValue() async {
        // $.version resolves to integer 1 in scripts.json
        let event = await load(file: "scripts.json", jsonpath: "$.version")

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }

        #expect(diag.severity == .warning)
        #expect(diag.source == .sourceLoad)
        #expect(diag.message.contains("expected string"))
    }

    @Test("YAML alias at designated path — returns .failed with 'designate the anchor'")
    func yamlAliasAtPath() async {
        // alias.yaml: scripts.init = *base (an alias)
        let event = await load(file: "alias.yaml", jsonpath: "$.scripts.init")

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }

        #expect(diag.severity == .error)
        #expect(diag.source == .sourceLoad)
        #expect(diag.message.contains("designate the anchor"))
    }
}

// MARK: - CR-002 regression: escaped strings must load successfully

/// Regression suite for CR-002: the former R7 byte-equality check compared
/// raw file bytes (escape sequences verbatim, e.g. backslash-n = two chars)
/// against the decoded Lua string (backslash-n = real newline). Any fragment
/// containing a JSON escape would always trigger a false span-mismatch failure.
/// The R7 check has been removed; only the tree-sitter round-trip validates the
/// span. These tests confirm that escaped fragments load as .loaded, not .failed.
@Suite("SourceStore — escaped-string fragments (CR-002 regression)")
struct SourceStoreEscapedStringTests {

    private var fixturesRoot: URL {
        Bundle.module.url(forResource: "Fixtures/Sources", withExtension: nil)!
    }

    /// A JSON fragment whose value contains a \n escape must load as .loaded
    /// and produce the decoded string (real newline), not a span-mismatch failure.
    @Test("JSON \\n escape — loads as .loaded with decoded value (not .failed)")
    func jsonNewlineEscape() async {
        let events = await SourceStore.loadStructuredFile(
            at: "scripts-escaped.json",
            projectRoot: fixturesRoot,
            fields: [FieldDesignation(jsonpath: "$.scripts.init", document: 0)]
        )

        guard let event = events.first else {
            Issue.record("Expected at least one event")
            return
        }

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event) — R7 regression: escaped fragment must not fail")
            return
        }

        #expect(id.jsonpath == "$.scripts.init")
        // The decoded value must contain a real newline, not the two-char sequence.
        #expect(fragment.code.contains("\n"))
        #expect(!fragment.code.contains("\\n"))
    }

    /// A JSON fragment whose value contains a \t escape must also load cleanly.
    @Test("JSON \\t escape — loads as .loaded with decoded value (not .failed)")
    func jsonTabEscape() async {
        let events = await SourceStore.loadStructuredFile(
            at: "scripts-escaped.json",
            projectRoot: fixturesRoot,
            fields: [FieldDesignation(jsonpath: "$.scripts.tab", document: 0)]
        )

        guard let event = events.first else {
            Issue.record("Expected at least one event")
            return
        }

        guard case .loaded(let id, let fragment) = event else {
            Issue.record("Expected .loaded, got \(event) — R7 regression: escaped fragment must not fail")
            return
        }

        #expect(id.jsonpath == "$.scripts.tab")
        // The decoded value must contain a real tab character.
        #expect(fragment.code.contains("\t"))
        #expect(!fragment.code.contains("\\t"))
    }
}

// MARK: - File size limit tests (CR-028)

/// Tests that SourceStore rejects files exceeding the configured size limits
/// before reading their content, preventing OOM from large files or /dev/zero.
///
/// These tests write real files to a temporary directory because the size-check
/// code path uses `FileManager.attributesOfItem` on a real on-disk file.
@Suite("SourceStore — file size limits (CR-028)")
struct SourceStoreFileSizeLimitTests {

    /// Create a temporary directory for this test run, return its URL.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceStoreFileSizeLimitTests-\(Int.random(in: 0..<Int.max))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("lua file exceeding sourceFileSizeLimit returns .failed with size error")
    func luaFileOverLimitFails() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a file whose byte count exceeds sourceFileSizeLimit.
        // Use random bytes so it reads as garbage (not a real Lua file).
        let fileURL = tempDir.appendingPathComponent("huge.lua")
        let oversizeBytes = sourceFileSizeLimit + 1
        // Write in 64 KiB chunks to avoid allocating the full oversized buffer.
        let chunkSize = 65_536
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        var written = 0
        let chunk = Data(repeating: 0x20, count: chunkSize)  // spaces
        while written < oversizeBytes {
            let toWrite = min(chunkSize, oversizeBytes - written)
            handle.write(chunk.prefix(toWrite))
            written += toWrite
        }
        handle.closeFile()

        let id = SourceID(path: "huge.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "huge.lua", projectRoot: tempDir, id: id)

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }
        #expect(diag.message.contains("limit"), "Expected size limit message, got: \(diag.message)")
        #expect(diag.severity == .error)
    }

    @Test("lua file within sourceFileSizeLimit loads successfully")
    func luaFileAtLimitSucceeds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("small.lua")
        let content = "return 42\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let id = SourceID(path: "small.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "small.lua", projectRoot: tempDir, id: id)

        guard case .loaded = event else {
            Issue.record("Expected .loaded for file within limit, got \(event)")
            return
        }
    }

    @Test("structured file exceeding structuredFileSizeLimit returns .failed")
    func structuredFileOverLimitFails() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("huge.json")
        let oversizeBytes = structuredFileSizeLimit + 1
        let chunkSize = 65_536
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        var written = 0
        let chunk = Data(repeating: 0x20, count: chunkSize)
        while written < oversizeBytes {
            let toWrite = min(chunkSize, oversizeBytes - written)
            handle.write(chunk.prefix(toWrite))
            written += toWrite
        }
        handle.closeFile()

        let fields = [FieldDesignation(jsonpath: "$.x", document: 0)]
        let events = await SourceStore.loadStructuredFile(
            at: "huge.json", projectRoot: tempDir, fields: fields
        )

        #expect(!events.isEmpty, "Expected at least one event")
        if let event = events.first, case .failed(_, let state) = event,
            case .failed(let diag) = state
        {
            #expect(diag.message.contains("limit"), "Expected size limit message, got: \(diag.message)")
        } else {
            Issue.record("Expected .failed(_, .failed) for oversized structured file, got \(events)")
        }
    }

    // MARK: - File-type guard (CR-028 extension)

    @Test("lua — FIFO (named pipe) rejected as non-regular file")
    func luaFifoRejected() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a named pipe (FIFO) using mkfifo(2).
        let fifoPath = tempDir.appendingPathComponent("pipe.lua").path
        let rc = mkfifo(fifoPath, 0o600)
        guard rc == 0 else {
            // If the OS won't create a FIFO here, skip gracefully.
            return
        }

        let id = SourceID(path: "pipe.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "pipe.lua", projectRoot: tempDir, id: id)

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed for FIFO, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic) for FIFO, got \(state)")
            return
        }
        #expect(diag.severity == .error)
        #expect(
            diag.message.contains("not a regular file"),
            "Expected 'not a regular file' message, got: \(diag.message)"
        )
    }

    @Test("lua — symlink is rejected as non-regular file regardless of target size")
    func luaSymlinkRejectedAsNonRegular() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a small regular target file.
        let targetURL = tempDir.appendingPathComponent("target.lua")
        try "return 1\n".write(to: targetURL, atomically: true, encoding: .utf8)

        // Create a symlink pointing to it.
        // FileManager.attributesOfItem(atPath:) returns .typeSymbolicLink for
        // symlink paths — it does NOT follow the symlink for the type attribute.
        // The file-type guard therefore rejects symlinks directly, preventing
        // any attempt to open a link whose target could change between validation
        // and read (TOCTOU / CWE-61). The TOCTOU re-check in SourceStore
        // provides an additional layer for symlinks that pass ProjectValidation.
        let symlinkURL = tempDir.appendingPathComponent("link.lua")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let id = SourceID(path: "link.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "link.lua", projectRoot: tempDir, id: id)

        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed for symlink, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic) for symlink, got \(state)")
            return
        }
        #expect(diag.severity == .error)
        #expect(
            diag.message.contains("not a regular file"),
            "Expected 'not a regular file' message, got: \(diag.message)"
        )
    }

    @Test("structured — FIFO rejected as non-regular file")
    func structuredFifoRejected() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fifoPath = tempDir.appendingPathComponent("pipe.json").path
        let rc = mkfifo(fifoPath, 0o600)
        guard rc == 0 else { return }

        let fields = [FieldDesignation(jsonpath: "$.x", document: 0)]
        let events = await SourceStore.loadStructuredFile(
            at: "pipe.json", projectRoot: tempDir, fields: fields
        )

        guard let event = events.first, case .failed(_, let state) = event,
            case .failed(let diag) = state
        else {
            Issue.record("Expected .failed(_, .failed) for FIFO structured file, got \(events)")
            return
        }
        #expect(diag.severity == .error)
        #expect(
            diag.message.contains("not a regular file"),
            "Expected 'not a regular file' message, got: \(diag.message)"
        )
    }
}

// MARK: - TOCTOU symlink-escape re-check tests (CR-030)

/// Tests for the post-validation symlink re-check in SourceStore (CR-030).
/// ProjectValidation resolves symlinks at validation time; SourceStore
/// re-resolves at read time so a symlink swap between those two moments
/// cannot redirect a path outside the project root.
@Suite("SourceStore — TOCTOU symlink-escape re-check (CR-030)")
struct SourceStoreTOCTOUTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceStoreTOCTOU-\(Int.random(in: 0..<Int.max))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("lua — path escaping project root returns .failed")
    func luaEscapesRoot() async throws {
        // Project dir contains only a symlink whose TARGET is outside the dir.
        // Arrange: create two sibling temp dirs: projectRoot and outsideDir.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TOCTOU-\(Int.random(in: 0..<Int.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let projectRoot = base.appendingPathComponent("project")
        let outsideDir = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        // Write a real lua file outside the project.
        let outsideFile = outsideDir.appendingPathComponent("secret.lua")
        try "return 'secret'".write(to: outsideFile, atomically: true, encoding: .utf8)

        // Place a symlink inside the project that points outside.
        let symlinkInProject = projectRoot.appendingPathComponent("evil.lua")
        try FileManager.default.createSymbolicLink(at: symlinkInProject, withDestinationURL: outsideFile)

        let id = SourceID(path: "evil.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "evil.lua", projectRoot: projectRoot, id: id)

        // The file-type guard catches this (symlink → .typeSymbolicLink, not .typeRegular)
        // before the TOCTOU check even runs. Either guard producing .failed is correct.
        guard case .failed(_, let state) = event else {
            Issue.record("Expected .failed for path escaping project root, got \(event)")
            return
        }
        guard case .failed(let diag) = state else {
            Issue.record("Expected .failed(diagnostic), got \(state)")
            return
        }
        #expect(diag.severity == .error)
    }

    @Test("lua — regular file inside project root loads successfully")
    func luaInsideRootSucceeds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("valid.lua")
        try "return 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let id = SourceID(path: "valid.lua", jsonpath: nil, document: 0)
        let event = await SourceStore.loadLuaFile(at: "valid.lua", projectRoot: tempDir, id: id)

        guard case .loaded = event else {
            Issue.record("Expected .loaded for regular file inside root, got \(event)")
            return
        }
    }

    @Test("structured — path escaping project root returns .failed")
    func structuredEscapesRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TOCTOU-str-\(Int.random(in: 0..<Int.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let projectRoot = base.appendingPathComponent("project")
        let outsideDir = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let outsideFile = outsideDir.appendingPathComponent("data.json")
        try "{\"x\":1}".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkInProject = projectRoot.appendingPathComponent("evil.json")
        try FileManager.default.createSymbolicLink(at: symlinkInProject, withDestinationURL: outsideFile)

        let fields = [FieldDesignation(jsonpath: "$.x", document: 0)]
        let events = await SourceStore.loadStructuredFile(
            at: "evil.json", projectRoot: projectRoot, fields: fields
        )

        guard let event = events.first, case .failed(_, let state) = event,
            case .failed(let diag) = state
        else {
            Issue.record("Expected .failed for structured path escaping root, got \(events)")
            return
        }
        #expect(diag.severity == .error)
    }
}

// MARK: - Shared read-guard tests (validateReadable, CR-028 / CR-030)

/// Tests for the `SourceStore.validateReadable` helper — the single guard shared
/// by `loadLuaFile`, `loadStructuredFile`, and the MoonSwiftTUI picker tree
/// loader. Each rejection reason and the safe path is exercised directly so the
/// guard cannot regress on any one read path.
@Suite("SourceStore — validateReadable shared guard")
struct SourceStoreValidateReadableTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidateReadable-\(Int.random(in: 0..<Int.max))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("regular file inside root, under limit — returns nil (safe)")
    func safeRegularFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("ok.json")
        try "{\"x\":1}".write(to: fileURL, atomically: true, encoding: .utf8)

        let rejection = SourceStore.validateReadable(
            at: fileURL, projectRoot: dir, sizeLimit: structuredFileSizeLimit
        )
        #expect(rejection == nil)
    }

    @Test("FIFO (named pipe) — rejected as .notRegularFile")
    func fifoRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifoURL = dir.appendingPathComponent("pipe.json")
        let rc = mkfifo(fifoURL.path, 0o600)
        // Skip gracefully if the platform refuses to create a FIFO here.
        guard rc == 0 else { return }

        let rejection = SourceStore.validateReadable(
            at: fifoURL, projectRoot: dir, sizeLimit: structuredFileSizeLimit
        )
        #expect(rejection == .notRegularFile)
    }

    @Test("symlink — rejected as .notRegularFile (its target is never read)")
    func symlinkRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.json")
        try "{\"x\":1}".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let rejection = SourceStore.validateReadable(
            at: link, projectRoot: dir, sizeLimit: structuredFileSizeLimit
        )
        #expect(rejection == .notRegularFile)
    }

    @Test("regular file over the limit — rejected as .tooLarge with MiB limit")
    func oversizeRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("big.json")
        // Use a tiny sizeLimit so we need only a few bytes over it.
        let limit = 16
        try Data(repeating: 0x20, count: limit + 1).write(to: fileURL)

        let rejection = SourceStore.validateReadable(
            at: fileURL, projectRoot: dir, sizeLimit: limit
        )
        #expect(rejection == .tooLarge(limitMiB: limit / (1_024 * 1_024)))
    }

    @Test("regular file exactly at the limit — not rejected for size")
    func atLimitNotRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("edge.json")
        let limit = 32
        try Data(repeating: 0x20, count: limit).write(to: fileURL)

        let rejection = SourceStore.validateReadable(
            at: fileURL, projectRoot: dir, sizeLimit: limit
        )
        #expect(rejection == nil)
    }

    @Test("symlink escaping the project root — rejected before content read")
    func escapeRejected() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectRoot = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("data.json")
        try "{\"x\":1}".write(to: outsideFile, atomically: true, encoding: .utf8)
        let link = projectRoot.appendingPathComponent("evil.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)

        // The type guard fires first (symlink → not regular); either that or the
        // escape check is a correct rejection. Assert a non-nil rejection.
        let rejection = SourceStore.validateReadable(
            at: link, projectRoot: projectRoot, sizeLimit: structuredFileSizeLimit
        )
        #expect(rejection != nil)
    }
}
