// File: Tests/MoonSwiftCoreTests/Sources/SpanLocatorTests.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: Direct unit tests for SpanLocator.locateSpan — one walker per format
//       (JSON, YAML, TOML) with known byte-range assertions, plus all three
//       error cases: parseFailed, yamlAliasAtDesignatedPath, nodeNotFound.
//
// Fixture byte offsets (verified by byte-counting fixture files):
//   scripts.json : $.scripts.init → 30..<44  ("print('hello')" without quotes)
//   scripts.yaml : $.scripts.init → 18..<32
//   scripts.toml : $.scripts.init → 18..<32

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Sources")!
    return try Data(contentsOf: url)
}

// MARK: - SpanLocator JSON walker tests

@Suite("SpanLocator — JSON walker")
struct SpanLocatorJSONTests {

    // Path $.scripts.init → [.key("scripts"), .key("init")]
    let path: [ResolvedStep] = [.key("scripts"), .key("init")]

    @Test("locates $.scripts.init value content in scripts.json")
    func locateInitValue() throws {
        let data = try fixtureData("scripts.json")
        let loc = try SpanLocator.locateSpan(in: data, format: .json, path: path)
        // Byte range: content of "print('hello')" without surrounding double-quotes
        #expect(loc.byteRange == 30..<44)
        // Value is on line 2 (0-based) inside the nested object
        #expect(loc.lineOffset == 2)
    }

    @Test("locates $.scripts.run value content in scripts.json")
    func locateRunValue() throws {
        let data = try fixtureData("scripts.json")
        let runPath: [ResolvedStep] = [.key("scripts"), .key("run")]
        let loc = try SpanLocator.locateSpan(in: data, format: .json, path: runPath)
        // "return 42" is 9 bytes; byte range verified: 59..<68
        #expect(loc.byteRange == 59..<68)
        #expect(loc.lineOffset == 3)
    }

    @Test("throws nodeNotFound for missing key in scripts.json")
    func nodeNotFoundKey() throws {
        let data = try fixtureData("scripts.json")
        let missing: [ResolvedStep] = [.key("scripts"), .key("nonexistent")]
        #expect(throws: SpanLocatorError.nodeNotFound) {
            try SpanLocator.locateSpan(in: data, format: .json, path: missing)
        }
    }

    @Test("throws parseFailed for invalid UTF-8 data")
    func parseFailedInvalidUTF8() throws {
        // 0xFF bytes are not valid UTF-8
        let bad = Data([0xFF, 0xFE, 0x00])
        #expect(throws: SpanLocatorError.parseFailed) {
            try SpanLocator.locateSpan(in: bad, format: .json, path: [.key("x")])
        }
    }
}

// MARK: - SpanLocator YAML walker tests

@Suite("SpanLocator — YAML walker")
struct SpanLocatorYAMLTests {

    let path: [ResolvedStep] = [.key("scripts"), .key("init")]

    @Test("locates $.scripts.init value content in scripts.yaml")
    func locateInitValue() throws {
        let data = try fixtureData("scripts.yaml")
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        // Byte range: content of "print('hello')" without surrounding double-quotes
        #expect(loc.byteRange == 18..<32)
        #expect(loc.lineOffset == 1)
    }

    @Test("locates $.scripts.run value content in scripts.yaml")
    func locateRunValue() throws {
        let data = try fixtureData("scripts.yaml")
        let runPath: [ResolvedStep] = [.key("scripts"), .key("run")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: runPath)
        #expect(loc.byteRange.count == 9)  // "return 42" = 9 bytes
    }

    @Test("throws yamlAliasAtDesignatedPath for alias node in alias.yaml")
    func yamlAliasError() throws {
        let data = try fixtureData("alias.yaml")
        // $.scripts.init resolves to *base alias node
        #expect(throws: SpanLocatorError.yamlAliasAtDesignatedPath) {
            try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        }
    }

    @Test("throws nodeNotFound for path not in scripts.yaml")
    func nodeNotFound() throws {
        let data = try fixtureData("scripts.yaml")
        let missing: [ResolvedStep] = [.key("scripts"), .key("missing")]
        #expect(throws: SpanLocatorError.nodeNotFound) {
            try SpanLocator.locateSpan(in: data, format: .yaml, path: missing)
        }
    }
}

// MARK: - SpanLocator TOML walker tests

@Suite("SpanLocator — TOML walker")
struct SpanLocatorTOMLTests {

    // scripts.toml: [scripts] table → init key
    let path: [ResolvedStep] = [.key("scripts"), .key("init")]

    @Test("locates $.scripts.init value content in scripts.toml")
    func locateInitValue() throws {
        let data = try fixtureData("scripts.toml")
        let loc = try SpanLocator.locateSpan(in: data, format: .toml, path: path)
        // Byte range: content of "print('hello')" without surrounding double-quotes
        #expect(loc.byteRange == 18..<32)
        #expect(loc.lineOffset == 1)
    }

    @Test("locates $.scripts.run value content in scripts.toml")
    func locateRunValue() throws {
        let data = try fixtureData("scripts.toml")
        let runPath: [ResolvedStep] = [.key("scripts"), .key("run")]
        let loc = try SpanLocator.locateSpan(in: data, format: .toml, path: runPath)
        #expect(loc.byteRange.count == 9)  // "return 42"
    }

    @Test("throws nodeNotFound for missing key in scripts.toml")
    func nodeNotFound() throws {
        let data = try fixtureData("scripts.toml")
        let missing: [ResolvedStep] = [.key("scripts"), .key("nonexistent")]
        #expect(throws: SpanLocatorError.nodeNotFound) {
            try SpanLocator.locateSpan(in: data, format: .toml, path: missing)
        }
    }
}
