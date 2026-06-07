// File: Tests/MoonSwiftCoreTests/Tree/TreeDecoderJSONTests.swift
// Role: Unit tests for decodeJSON — verifies key-order preservation, numeric
//       precision, all scalar types, deep nesting, and error cases.
// Upstream: MoonSwiftCore/Tree/TreeDecoderJSON.swift
// Downstream: (test target)

import Testing
import Collections
@testable import MoonSwiftCore

// MARK: - Scalar types

@Suite("JSON decoder — scalars")
struct JSONDecoderScalarsTests {

    @Test("string value")
    func stringValue() throws {
        let result = try decodeJSON(#""hello""#)
        #expect(result == .string("hello"))
    }

    @Test("string with escape sequences")
    func stringEscapes() throws {
        let result = try decodeJSON(#""a\tb\nc\r""#)
        #expect(result == .string("a\tb\nc\r"))
    }

    @Test("string with Unicode escape")
    func stringUnicodeEscape() throws {
        let result = try decodeJSON(#""A""#)  // U+0041 = 'A'
        #expect(result == .string("A"))
    }

    @Test("string with surrogate pair (emoji)")
    func stringSurrogatePair() throws {
        // U+1F600 = 😀, encoded as 😀
        let result = try decodeJSON(#""😀""#)
        #expect(result == .string("😀"))
    }

    @Test("integer value fits Int64")
    func integerValue() throws {
        let result = try decodeJSON("42")
        #expect(result == .int(42))
    }

    @Test("negative integer")
    func negativeInteger() throws {
        let result = try decodeJSON("-7")
        #expect(result == .int(-7))
    }

    @Test("integer at Int64 max boundary")
    func integerMaxBoundary() throws {
        let result = try decodeJSON("9223372036854775807")  // Int64.max
        #expect(result == .int(Int64.max))
    }

    @Test("integer overflow becomes double")
    func integerOverflow() throws {
        // One above Int64.max — cannot fit in Int64.
        let result = try decodeJSON("9223372036854775808")
        guard case .double = result else {
            Issue.record("Expected .double for overflow integer, got \(result)")
            return
        }
    }

    @Test("fractional number produces double")
    func fractionalDouble() throws {
        let result = try decodeJSON("3.14")
        #expect(result == .double(3.14))
    }

    @Test("scientific notation produces double")
    func scientificDouble() throws {
        let result = try decodeJSON("1e3")
        #expect(result == .double(1000.0))
    }

    @Test("negative fractional double")
    func negativeFractional() throws {
        let result = try decodeJSON("-2.5")
        #expect(result == .double(-2.5))
    }

    @Test("bool true")
    func boolTrue() throws {
        let result = try decodeJSON("true")
        #expect(result == .bool(true))
    }

    @Test("bool false")
    func boolFalse() throws {
        let result = try decodeJSON("false")
        #expect(result == .bool(false))
    }

    @Test("null")
    func nullValue() throws {
        let result = try decodeJSON("null")
        #expect(result == .null)
    }
}

// MARK: - Arrays

@Suite("JSON decoder — arrays")
struct JSONDecoderArrayTests {

    @Test("empty array")
    func emptyArray() throws {
        let result = try decodeJSON("[]")
        #expect(result == .array([]))
    }

    @Test("array of mixed types")
    func mixedArray() throws {
        let result = try decodeJSON(#"[1, "two", true, null]"#)
        #expect(result == .array([.int(1), .string("two"), .bool(true), .null]))
    }

    @Test("nested array")
    func nestedArray() throws {
        let result = try decodeJSON("[[1, 2], [3, 4]]")
        #expect(result == .array([.array([.int(1), .int(2)]), .array([.int(3), .int(4)])]))
    }
}

// MARK: - Objects and key order

@Suite("JSON decoder — objects and key order")
struct JSONDecoderObjectTests {

    @Test("empty object")
    func emptyObject() throws {
        let result = try decodeJSON("{}")
        #expect(result == .map([:]))
    }

    @Test("single-key object")
    func singleKey() throws {
        let result = try decodeJSON(#"{"a": 1}"#)
        var expected = OrderedDictionary<String, TreeValue>()
        expected["a"] = .int(1)
        #expect(result == .map(expected))
    }

    @Test("key insertion order is preserved (z before a)")
    func keyOrderPreserved() throws {
        // JSONSerialization would sort or randomise; our parser must keep z first.
        let result = try decodeJSON(#"{"z": 1, "a": 2, "m": 3}"#)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map, got \(result)")
            return
        }
        #expect(dict.keys == ["z", "a", "m"])
    }

    @Test("key insertion order preserved across more keys")
    func keyOrderLarger() throws {
        let json = #"{"beta": 2, "alpha": 1, "gamma": 3, "delta": 4}"#
        let result = try decodeJSON(json)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict.keys == ["beta", "alpha", "gamma", "delta"])
    }

    @Test("nested object preserves key order at each level")
    func nestedObjectKeyOrder() throws {
        let json = #"{"outer": {"z": 1, "a": 2}}"#
        let result = try decodeJSON(json)
        guard case .map(let outer) = result,
              case .map(let inner) = outer["outer"] else {
            Issue.record("Unexpected shape"); return
        }
        #expect(inner.keys == ["z", "a"])
    }

    @Test("object in array")
    func objectInArray() throws {
        let result = try decodeJSON(#"[{"x": 1}, {"y": 2}]"#)
        guard case .array(let arr) = result,
              case .map(let first) = arr[0],
              case .map(let second) = arr[1] else {
            Issue.record("Unexpected shape"); return
        }
        #expect(first["x"] == .int(1))
        #expect(second["y"] == .int(2))
    }

    @Test("deep nesting (5 levels)")
    func deepNesting() throws {
        let json = #"{"a": {"b": {"c": {"d": {"e": 42}}}}}"#
        let result = try decodeJSON(json)
        guard case .map(let a) = result,
              case .map(let b) = a["a"],
              case .map(let c) = b["b"],
              case .map(let d) = c["c"],
              case .map(let e) = d["d"] else {
            Issue.record("Unexpected shape"); return
        }
        #expect(e["e"] == .int(42))
    }
}

// MARK: - Whitespace handling

@Suite("JSON decoder — whitespace")
struct JSONDecoderWhitespaceTests {

    @Test("leading and trailing whitespace ignored")
    func leadingTrailingWhitespace() throws {
        let result = try decodeJSON("   42   ")
        #expect(result == .int(42))
    }

    @Test("object with internal whitespace")
    func objectWithWhitespace() throws {
        let result = try decodeJSON(#"  {  "k"  :  "v"  }  "#)
        var expected = OrderedDictionary<String, TreeValue>()
        expected["k"] = .string("v")
        #expect(result == .map(expected))
    }
}

// MARK: - Error cases

@Suite("JSON decoder — error cases")
struct JSONDecoderErrorTests {

    @Test("empty input throws")
    func emptyInput() {
        #expect(throws: (any Error).self) {
            try decodeJSON("")
        }
    }

    @Test("trailing garbage throws")
    func trailingGarbage() {
        #expect(throws: (any Error).self) {
            try decodeJSON("42 garbage")
        }
    }

    @Test("unterminated string throws")
    func unterminatedString() {
        #expect(throws: (any Error).self) {
            try decodeJSON(#""unterminated"#)
        }
    }

    @Test("invalid escape throws")
    func invalidEscape() {
        #expect(throws: (any Error).self) {
            try decodeJSON(#""\q""#)
        }
    }

    @Test("incomplete array throws")
    func incompleteArray() {
        #expect(throws: (any Error).self) {
            try decodeJSON("[1, 2,")
        }
    }

    @Test("incomplete object throws")
    func incompleteObject() {
        #expect(throws: (any Error).self) {
            try decodeJSON(#"{"key":"#)
        }
    }

    @Test("bare word throws")
    func bareWord() {
        #expect(throws: (any Error).self) {
            try decodeJSON("truee")
        }
    }
}
