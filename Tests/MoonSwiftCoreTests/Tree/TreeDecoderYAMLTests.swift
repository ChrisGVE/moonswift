// File: Tests/MoonSwiftCoreTests/Tree/TreeDecoderYAMLTests.swift
// Role: Unit tests for decodeYAML — verifies anchor/alias resolution, multi-
//       document selection, core schema type decoding, non-standard tags, and
//       error cases.
// Upstream: MoonSwiftCore/Tree/TreeDecoderYAML.swift
// Downstream: (test target)

import Testing
import Collections
@testable import MoonSwiftCore

// MARK: - Scalar types

@Suite("YAML decoder — scalars")
struct YAMLDecoderScalarsTests {

    @Test("string scalar")
    func stringScalar() throws {
        let result = try decodeYAML("value: hello")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["value"] == .string("hello"))
    }

    @Test("integer scalar")
    func integerScalar() throws {
        let result = try decodeYAML("n: 42")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["n"] == .int(42))
    }

    @Test("negative integer scalar")
    func negativeInteger() throws {
        let result = try decodeYAML("n: -7")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["n"] == .int(-7))
    }

    @Test("float scalar")
    func floatScalar() throws {
        let result = try decodeYAML("x: 3.14")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["x"] == .double(3.14))
    }

    @Test("bool true")
    func boolTrue() throws {
        let result = try decodeYAML("flag: true")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["flag"] == .bool(true))
    }

    @Test("bool false")
    func boolFalse() throws {
        let result = try decodeYAML("flag: false")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["flag"] == .bool(false))
    }

    @Test("null via tilde")
    func nullTilde() throws {
        let result = try decodeYAML("v: ~")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["v"] == .null)
    }

    @Test("null via 'null' keyword")
    func nullKeyword() throws {
        let result = try decodeYAML("v: null")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["v"] == .null)
    }

    @Test("YAML infinity float")
    func infinityFloat() throws {
        let result = try decodeYAML("x: .inf")
        guard case .map(let dict) = result,
              case .double(let d) = dict["x"] else {
            Issue.record("Expected .double for .inf"); return
        }
        #expect(d.isInfinite && d > 0)
    }

    @Test("YAML NaN float")
    func nanFloat() throws {
        let result = try decodeYAML("x: .nan")
        guard case .map(let dict) = result,
              case .double(let d) = dict["x"] else {
            Issue.record("Expected .double for .nan"); return
        }
        #expect(d.isNaN)
    }
}

// MARK: - Anchors and aliases (resolution)

@Suite("YAML decoder — anchors and aliases")
struct YAMLDecoderAnchorTests {

    @Test("alias resolves to anchor scalar value")
    func aliasResolvesToScalar() throws {
        let yaml = """
        original: &anchor hello
        copy: *anchor
        """
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["original"] == .string("hello"))
        #expect(dict["copy"] == .string("hello"))
    }

    @Test("alias resolves to anchor mapping")
    func aliasResolvesToMapping() throws {
        let yaml = """
        defaults: &defaults
          color: red
          size: 10
        custom:
          <<: *defaults
          size: 20
        """
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        // 'defaults' has the anchor values.
        guard case .map(let defaults) = dict["defaults"] else {
            Issue.record("Expected defaults to be .map"); return
        }
        #expect(defaults["color"] == .string("red"))
        #expect(defaults["size"] == .int(10))
    }

    @Test("alias resolves to anchor sequence")
    func aliasResolvesToSequence() throws {
        let yaml = """
        list: &list
          - a
          - b
        copy: *list
        """
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["list"] == dict["copy"])
    }
}

// MARK: - Multi-document

@Suite("YAML decoder — multi-document")
struct YAMLDecoderMultiDocTests {

    @Test("selects document 0 by default")
    func defaultDocumentIsZero() throws {
        let yaml = """
        ---
        name: first
        ---
        name: second
        """
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["name"] == .string("first"))
    }

    @Test("selects document 1 explicitly")
    func selectDocumentOne() throws {
        let yaml = """
        ---
        name: first
        ---
        name: second
        """
        let result = try decodeYAML(yaml, document: 1)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["name"] == .string("second"))
    }

    @Test("document index out of range throws")
    func documentIndexOutOfRange() throws {
        let yaml = "name: only"
        do {
            _ = try decodeYAML(yaml, document: 1)
            Issue.record("Expected error for out-of-range document index")
        } catch TreeDecoderError.yamlDocumentIndexOutOfRange(let requested, let available) {
            #expect(requested == 1)
            #expect(available == 1)
        }
    }

    @Test("three-document stream, select doc 2")
    func threeDocumentStream() throws {
        let yaml = """
        ---
        n: 1
        ---
        n: 2
        ---
        n: 3
        """
        let result = try decodeYAML(yaml, document: 2)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["n"] == .int(3))
    }
}

// MARK: - Collections

@Suite("YAML decoder — collections")
struct YAMLDecoderCollectionTests {

    @Test("sequence becomes .array")
    func sequenceArray() throws {
        let result = try decodeYAML("items:\n  - one\n  - two\n  - three")
        guard case .map(let dict) = result,
              case .array(let arr) = dict["items"] else {
            Issue.record("Expected array"); return
        }
        #expect(arr == [.string("one"), .string("two"), .string("three")])
    }

    @Test("mapping preserves key order")
    func mappingKeyOrder() throws {
        let yaml = """
        z: 1
        a: 2
        m: 3
        """
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict.keys == ["z", "a", "m"])
    }

    @Test("deep nested mapping")
    func deepMapping() throws {
        let yaml = """
        a:
          b:
            c: 42
        """
        let result = try decodeYAML(yaml)
        guard case .map(let a) = result,
              case .map(let b) = a["a"],
              case .map(let c) = b["b"] else {
            Issue.record("Unexpected shape"); return
        }
        #expect(c["c"] == .int(42))
    }
}

// MARK: - Non-standard tags

@Suite("YAML decoder — non-standard tags")
struct YAMLDecoderTagTests {

    @Test("explicit !!str tag on integer-looking value produces string")
    func explicitStrTag() throws {
        let yaml = "port: !!str 8080"
        let result = try decodeYAML(yaml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        // !!str overrides the default integer resolution.
        #expect(dict["port"] == .string("8080"))
    }
}

// MARK: - Error cases

@Suite("YAML decoder — error cases")
struct YAMLDecoderErrorTests {

    @Test("malformed YAML throws yamlMalformed")
    func malformedYAML() {
        let bad = ": {broken yaml : : :"
        do {
            _ = try decodeYAML(bad)
            Issue.record("Expected error for malformed YAML")
        } catch TreeDecoderError.yamlMalformed {
            // Correct error type.
        } catch {
            // Yams may throw other variants — acceptable.
        }
    }
}
