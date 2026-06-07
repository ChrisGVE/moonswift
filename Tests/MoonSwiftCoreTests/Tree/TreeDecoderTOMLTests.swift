// File: Tests/MoonSwiftCoreTests/Tree/TreeDecoderTOMLTests.swift
// Role: Unit tests for decodeTOML — verifies scalar types, dotted key nesting,
//       arrays-of-tables, datetime handling, key order, and error cases.
// Upstream: MoonSwiftCore/Tree/TreeDecoderTOML.swift
// Downstream: (test target)

import Testing
import Collections
@testable import MoonSwiftCore

// MARK: - Scalar types

@Suite("TOML decoder — scalars")
struct TOMLDecoderScalarsTests {

    @Test("string value")
    func stringValue() throws {
        let toml = #"name = "Alice""#
        let result = try decodeTOML(toml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["name"] == .string("Alice"))
    }

    @Test("integer value")
    func integerValue() throws {
        let result = try decodeTOML("count = 42")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["count"] == .int(42))
    }

    @Test("negative integer")
    func negativeInteger() throws {
        let result = try decodeTOML("x = -7")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["x"] == .int(-7))
    }

    @Test("float value")
    func floatValue() throws {
        let result = try decodeTOML("ratio = 3.14")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["ratio"] == .double(3.14))
    }

    @Test("bool true")
    func boolTrue() throws {
        let result = try decodeTOML("enabled = true")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["enabled"] == .bool(true))
    }

    @Test("bool false")
    func boolFalse() throws {
        let result = try decodeTOML("enabled = false")
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["enabled"] == .bool(false))
    }
}

// MARK: - Dotted keys

@Suite("TOML decoder — dotted keys")
struct TOMLDecoderDottedKeyTests {

    @Test("dotted key creates nested map")
    func dottedKeyNesting() throws {
        let toml = "server.host = \"localhost\""
        let result = try decodeTOML(toml)
        guard case .map(let root) = result,
              case .map(let server) = root["server"] else {
            Issue.record("Expected nested .map for server"); return
        }
        #expect(server["host"] == .string("localhost"))
    }

    @Test("three-level dotted key")
    func threeLevelDottedKey() throws {
        let toml = "a.b.c = 99"
        let result = try decodeTOML(toml)
        guard case .map(let a) = result,
              case .map(let b) = a["a"],
              case .map(let c) = b["b"] else {
            Issue.record("Unexpected shape"); return
        }
        #expect(c["c"] == .int(99))
    }

    @Test("multiple dotted keys under same prefix")
    func multipleDottedKeys() throws {
        let toml = """
        server.host = "localhost"
        server.port = 8080
        """
        let result = try decodeTOML(toml)
        guard case .map(let root) = result,
              case .map(let server) = root["server"] else {
            Issue.record("Expected nested .map"); return
        }
        #expect(server["host"] == .string("localhost"))
        #expect(server["port"] == .int(8080))
    }
}

// MARK: - Tables

@Suite("TOML decoder — tables")
struct TOMLDecoderTableTests {

    @Test("standard [table] header")
    func tableHeader() throws {
        let toml = """
        [database]
        host = "db.local"
        port = 5432
        """
        let result = try decodeTOML(toml)
        guard case .map(let root) = result,
              case .map(let db) = root["database"] else {
            Issue.record("Expected nested .map"); return
        }
        #expect(db["host"] == .string("db.local"))
        #expect(db["port"] == .int(5432))
    }

    @Test("TOML key order is alphabetical (toml++ limitation)")
    func tableKeyOrderAlphabetical() throws {
        // toml++ (the underlying C++ library used by TOMLKit) iterates table
        // keys in alphabetical order, not insertion order. This is a known
        // limitation of the TOML decoder: unlike the JSON and YAML decoders,
        // TOML does NOT preserve the authored key insertion order.
        // The resulting OrderedDictionary reflects alphabetical iteration, so
        // the picker tree view for TOML files shows keys sorted alphabetically.
        let toml = """
        z = 1
        a = 2
        m = 3
        """
        let result = try decodeTOML(toml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        // All three keys are present.
        #expect(dict["z"] == .int(1))
        #expect(dict["a"] == .int(2))
        #expect(dict["m"] == .int(3))
        // Key iteration order is alphabetical due to toml++ internals.
        #expect(dict.keys.first == "a")
    }
}

// MARK: - Arrays of tables ([[array]])

@Suite("TOML decoder — arrays of tables")
struct TOMLDecoderArrayOfTablesTests {

    @Test("basic array-of-tables")
    func basicArrayOfTables() throws {
        let toml = """
        [[product]]
        name = "Widget"
        price = 9.99

        [[product]]
        name = "Gadget"
        price = 24.99
        """
        let result = try decodeTOML(toml)
        guard case .map(let root) = result,
              case .array(let products) = root["product"] else {
            Issue.record("Expected array of tables"); return
        }
        #expect(products.count == 2)
        guard case .map(let first) = products[0],
              case .map(let second) = products[1] else {
            Issue.record("Array elements should be maps"); return
        }
        #expect(first["name"] == .string("Widget"))
        #expect(second["name"] == .string("Gadget"))
    }

    @Test("array-of-tables with nested table")
    func nestedArrayOfTables() throws {
        let toml = """
        [[fruits]]
        name = "apple"

        [fruits.physical]
        color = "red"
        shape = "round"

        [[fruits]]
        name = "banana"
        """
        let result = try decodeTOML(toml)
        guard case .map(let root) = result,
              case .array(let fruits) = root["fruits"] else {
            Issue.record("Expected array of tables"); return
        }
        #expect(fruits.count == 2)
        guard case .map(let apple) = fruits[0] else {
            Issue.record("Expected first fruit to be map"); return
        }
        #expect(apple["name"] == .string("apple"))
        guard case .map(let physical) = apple["physical"] else {
            Issue.record("Expected nested physical table"); return
        }
        #expect(physical["color"] == .string("red"))
    }
}

// MARK: - Plain arrays

@Suite("TOML decoder — plain arrays")
struct TOMLDecoderArrayTests {

    @Test("integer array")
    func integerArray() throws {
        let result = try decodeTOML("ports = [8080, 8443, 9000]")
        guard case .map(let dict) = result,
              case .array(let arr) = dict["ports"] else {
            Issue.record("Expected array"); return
        }
        #expect(arr == [.int(8080), .int(8443), .int(9000)])
    }

    @Test("string array")
    func stringArray() throws {
        let result = try decodeTOML(#"tags = ["a", "b", "c"]"#)
        guard case .map(let dict) = result,
              case .array(let arr) = dict["tags"] else {
            Issue.record("Expected array"); return
        }
        #expect(arr == [.string("a"), .string("b"), .string("c")])
    }
}

// MARK: - Datetime → null

@Suite("TOML decoder — datetime values become null")
struct TOMLDecoderDatetimeTests {

    @Test("date-time value becomes null")
    func datetimeBecomesNull() throws {
        let toml = "ts = 1979-05-27T07:32:00Z"
        let result = try decodeTOML(toml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        // Datetime is non-designatable; must be .null.
        #expect(dict["ts"] == .null)
    }

    @Test("local date becomes null")
    func localDateBecomesNull() throws {
        let toml = "d = 1979-05-27"
        let result = try decodeTOML(toml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["d"] == .null)
    }

    @Test("local time becomes null")
    func localTimeBecomesNull() throws {
        let toml = "t = 07:32:00"
        let result = try decodeTOML(toml)
        guard case .map(let dict) = result else {
            Issue.record("Expected .map"); return
        }
        #expect(dict["t"] == .null)
    }
}

// MARK: - Error cases

@Suite("TOML decoder — error cases")
struct TOMLDecoderErrorTests {

    @Test("malformed TOML throws tomlMalformed")
    func malformedTOML() {
        #expect(throws: (any Error).self) {
            try decodeTOML("= broken [")
        }
    }

    @Test("invalid key throws")
    func invalidKey() {
        #expect(throws: (any Error).self) {
            // Duplicate key is invalid TOML.
            try decodeTOML("a = 1\na = 2")
        }
    }
}
