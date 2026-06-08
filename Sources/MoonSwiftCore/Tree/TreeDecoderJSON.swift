// File: Sources/MoonSwiftCore/Tree/TreeDecoderJSON.swift
// Role: Decodes a UTF-8 JSON string into a TreeValue tree, preserving key
//       insertion order in object nodes.
// Upstream: (input — raw JSON text)
// Downstream: SourceStore (passes the tree to JSONPath evaluator)
//
// Key-order rationale:
//   Foundation's JSONSerialization does NOT preserve key insertion order — it
//   returns an unordered NSDictionary. Because TreeValue.map uses
//   OrderedDictionary to guarantee picker tree-view fidelity (PRD F1.2), a
//   minimal recursive-descent parser is used instead. The parser handles the
//   full JSON RFC 8259 value grammar at the depth needed by P1 (strings,
//   numbers, booleans, null, arrays, objects). It does NOT implement a JSON
//   streaming or partial-document API; the full document must fit in memory
//   (acceptable for config files).
//
// Numeric precision:
//   Integer literals whose value fits in Int64 produce .int(Int64).
//   All other numbers (fractional, out-of-range) produce .double(Double).
//
// Algorithm: single-pass, index-based scan over the UTF-8 scalar view.
// Reference: ECMA-404 (2nd edition, December 2017) §5 JSON text.

import Collections
import Foundation

// MARK: - Public entry point

/// Decodes a UTF-8 JSON document into a `TreeValue` tree.
///
/// Key insertion order is preserved in `.map` nodes — unlike
/// `Foundation.JSONSerialization`, which returns an unordered dictionary.
///
/// - Parameter text: A JSON document as a Swift `String`.
/// - Returns: The root `TreeValue` of the document.
/// - Throws: `TreeDecoderError.jsonMalformed` with a human-readable message
///           describing the first parse error.
public func decodeJSON(_ text: String) throws -> TreeValue {
    var parser = JSONParser(source: text)
    let value = try parser.parseValue()
    parser.skipWhitespace()
    guard parser.isAtEnd else {
        throw TreeDecoderError.jsonMalformed(
            "unexpected trailing content after JSON value at offset \(parser.offset)"
        )
    }
    return value
}

// MARK: - Error type

/// Errors produced by the Tree decoders.
public enum TreeDecoderError: Error, Equatable {
    /// The JSON text is not valid; `reason` describes the first problem found.
    case jsonMalformed(String)
    /// The YAML text is not valid; `reason` is the underlying Yams message.
    case yamlMalformed(String)
    /// The TOML text is not valid; `reason` is the underlying TOMLKit message.
    case tomlMalformed(String)
    /// A valid YAML stream contains fewer documents than requested.
    case yamlDocumentIndexOutOfRange(requested: Int, available: Int)
    /// The document nesting depth exceeds the safe limit (CWE-674).
    ///
    /// The limit is `treeDecoderMaxDepth` (128). Files deeper than this are
    /// rejected with this error rather than overflowing the call stack.
    case nestingTooDeep
    /// The total node count in a decoded document exceeds `treeDecoderMaxNodes`.
    ///
    /// Yams expands YAML anchors/aliases before returning the Node tree, so a
    /// small YAML file with recursive or wide-shallow alias bombs can produce
    /// millions of nodes regardless of nesting depth. This error caps the
    /// total decoded node count to prevent unbounded memory growth.
    case tooManyNodes
}

// MARK: - Nesting depth limit

/// Safe maximum nesting depth for recursive JSON and YAML decoders.
///
/// 128 levels is deep enough for any realistic config or data file; realistic
/// config files rarely exceed 10–20 levels. The Swift default stack size on
/// macOS is ~8 MiB; typical recursive parser frames use several hundred bytes
/// each, so 128 frames sits comfortably within that budget with generous margin.
/// A smaller value also improves test determinism when verifying the guard.
///
/// This constant is `internal` so tests can reference it via `@testable import`.
let treeDecoderMaxDepth = 128

// MARK: - Node-count budget

/// Maximum number of `TreeValue` nodes that the YAML decoder will produce.
///
/// Yams resolves YAML anchors/aliases before this decoder runs, so a small
/// file with many shallow aliases can expand to millions of in-memory nodes
/// even when nesting depth stays within `treeDecoderMaxDepth`. Without a
/// node-count budget the only mitigation would be the 50 MiB file-size limit,
/// which is insufficient — a 1 KiB YAML file can reference a 100-element
/// sequence 500 000 times and expand to 50 million nodes.
///
/// 500 000 nodes is generous for any real config or data file while still
/// bounding peak RSS to a safe level (each `TreeValue` node is a few hundred
/// bytes on the heap; 500 k nodes ≈ ~100 MiB worst-case).
///
/// This constant is `internal` so tests can reference it via `@testable import`.
let treeDecoderMaxNodes = 500_000

// MARK: - JSONParser (internal)

/// Minimal recursive-descent JSON parser.
///
/// Implements ECMA-404 §5 for the value grammar. Single-pass, index-based.
/// State is index into `source.unicodeScalars`.
///
/// Nesting depth is tracked via `depth` and capped at `treeDecoderMaxDepth`
/// (512) to prevent stack overflow on pathologically nested documents (CWE-674).
private struct JSONParser {

    // MARK: State

    private let source: String
    private var index: String.UnicodeScalarView.Index
    /// Current nesting depth. Incremented on entering an array or object,
    /// decremented on exit. Capped at `treeDecoderMaxDepth`.
    private var depth: Int

    // MARK: Init

    init(source: String) {
        self.source = source
        self.index = source.unicodeScalars.startIndex
        self.depth = 0
    }

    // MARK: Helpers

    var isAtEnd: Bool { index == source.unicodeScalars.endIndex }

    var offset: Int { source.unicodeScalars.distance(from: source.unicodeScalars.startIndex, to: index) }

    private var current: Unicode.Scalar? {
        isAtEnd ? nil : source.unicodeScalars[index]
    }

    private mutating func advance() {
        guard !isAtEnd else { return }
        source.unicodeScalars.formIndex(after: &index)
    }

    mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" {
            advance()
        }
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard current == scalar else {
            throw TreeDecoderError.jsonMalformed(
                "expected '\(scalar)' but found '\(current.map(String.init) ?? "end of input")' at offset \(offset)"
            )
        }
        advance()
    }

    // MARK: Value dispatch

    mutating func parseValue() throws -> TreeValue {
        skipWhitespace()
        guard let c = current else {
            throw TreeDecoderError.jsonMalformed("unexpected end of input while expecting a value")
        }
        switch c {
        case "\"": return .string(try parseString())
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "t": return try parseLiteral("true", value: .bool(true))
        case "f": return try parseLiteral("false", value: .bool(false))
        case "n": return try parseLiteral("null", value: .null)
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return try parseNumber()
        default:
            throw TreeDecoderError.jsonMalformed(
                "unexpected character '\(c)' at offset \(offset)"
            )
        }
    }

    // MARK: Literal (true / false / null)

    private mutating func parseLiteral(_ word: String, value: TreeValue) throws -> TreeValue {
        for scalar in word.unicodeScalars {
            guard current == scalar else {
                throw TreeDecoderError.jsonMalformed(
                    "expected '\(word)' at offset \(offset)"
                )
            }
            advance()
        }
        return value
    }

    // MARK: String

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = ""
        while let c = current {
            if c == "\"" {
                advance()
                return result
            }
            if c == "\\" {
                advance()
                result += try parseEscape()
            } else {
                result.unicodeScalars.append(c)
                advance()
            }
        }
        throw TreeDecoderError.jsonMalformed("unterminated string at offset \(offset)")
    }

    private mutating func parseEscape() throws -> String {
        guard let c = current else {
            throw TreeDecoderError.jsonMalformed("unexpected end of input inside string escape")
        }
        advance()
        switch c {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return "\u{0008}"
        case "f": return "\u{000C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u": return try parseUnicodeEscape()
        default:
            throw TreeDecoderError.jsonMalformed(
                "invalid escape character '\\(c)' at offset \(offset)"
            )
        }
    }

    private mutating func parseUnicodeEscape() throws -> String {
        // Consume exactly 4 hex digits.
        var hex = ""
        for _ in 0..<4 {
            guard let c = current, isHexDigit(c) else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid \\uXXXX escape at offset \(offset)"
                )
            }
            hex.unicodeScalars.append(c)
            advance()
        }
        guard let codeUnit = UInt16(hex, radix: 16) else {
            throw TreeDecoderError.jsonMalformed(
                "invalid \\uXXXX escape '\(hex)' at offset \(offset)"
            )
        }
        // Handle surrogate pairs: high surrogate (0xD800–0xDBFF) must be
        // followed by a low surrogate (0xDC00–0xDFFF) encoded as \uXXXX.
        if codeUnit >= 0xD800 && codeUnit <= 0xDBFF {
            guard current == "\\" else {
                throw TreeDecoderError.jsonMalformed(
                    "high surrogate without following \\uXXXX at offset \(offset)"
                )
            }
            advance()
            guard current == "u" else {
                throw TreeDecoderError.jsonMalformed(
                    "high surrogate without following \\uXXXX at offset \(offset)"
                )
            }
            advance()
            var lowHex = ""
            for _ in 0..<4 {
                guard let c = current, isHexDigit(c) else {
                    throw TreeDecoderError.jsonMalformed(
                        "invalid low surrogate \\uXXXX at offset \(offset)"
                    )
                }
                lowHex.unicodeScalars.append(c)
                advance()
            }
            guard let lowUnit = UInt16(lowHex, radix: 16),
                lowUnit >= 0xDC00 && lowUnit <= 0xDFFF
            else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid low surrogate '\\u\(lowHex)' at offset \(offset)"
                )
            }
            let codePoint = 0x10000 + (UInt32(codeUnit - 0xD800) << 10) + UInt32(lowUnit - 0xDC00)
            guard let scalar = Unicode.Scalar(codePoint) else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid surrogate pair code point U+\(String(codePoint, radix: 16, uppercase: true))"
                )
            }
            return String(scalar)
        }
        // Non-surrogate BMP character.
        guard let scalar = Unicode.Scalar(codeUnit) else {
            throw TreeDecoderError.jsonMalformed(
                "invalid Unicode code unit U+\(hex) at offset \(offset)"
            )
        }
        return String(scalar)
    }

    private func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(s) || ("a"..."f").contains(s) || ("A"..."F").contains(s)
    }

    // MARK: Number

    private mutating func parseNumber() throws -> TreeValue {
        let start = index
        // Optional leading minus.
        if current == "-" { advance() }
        // Integer part.
        if current == "0" {
            advance()
        } else {
            guard let c = current, ("1"..."9").contains(c) else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid number at offset \(offset)"
                )
            }
            while let c = current, ("0"..."9").contains(c) { advance() }
        }
        var hasFraction = false
        var hasExponent = false
        // Optional fractional part.
        if current == "." {
            hasFraction = true
            advance()
            guard let c = current, ("0"..."9").contains(c) else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid fractional part at offset \(offset)"
                )
            }
            while let c = current, ("0"..."9").contains(c) { advance() }
        }
        // Optional exponent.
        if current == "e" || current == "E" {
            hasExponent = true
            advance()
            if current == "+" || current == "-" { advance() }
            guard let c = current, ("0"..."9").contains(c) else {
                throw TreeDecoderError.jsonMalformed(
                    "invalid exponent at offset \(offset)"
                )
            }
            while let c = current, ("0"..."9").contains(c) { advance() }
        }
        let raw = String(source.unicodeScalars[start..<index])
        // Produce Int64 when the literal is a pure integer (no "." or "e/E")
        // that fits in range; otherwise Double.
        if !hasFraction && !hasExponent, let intVal = Int64(raw) {
            return .int(intVal)
        }
        guard let dblVal = Double(raw) else {
            throw TreeDecoderError.jsonMalformed(
                "number '\(raw)' overflows Double at offset \(offset)"
            )
        }
        return .double(dblVal)
    }

    // MARK: Array

    private mutating func parseArray() throws -> TreeValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= treeDecoderMaxDepth else {
            throw TreeDecoderError.nestingTooDeep
        }
        try expect("[")
        skipWhitespace()
        var elements: [TreeValue] = []
        if current == "]" {
            advance()
            return .array(elements)
        }
        while true {
            elements.append(try parseValue())
            skipWhitespace()
            if current == "]" {
                advance()
                return .array(elements)
            }
            try expect(",")
        }
    }

    // MARK: Object

    private mutating func parseObject() throws -> TreeValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= treeDecoderMaxDepth else {
            throw TreeDecoderError.nestingTooDeep
        }
        try expect("{")
        skipWhitespace()
        var dict = OrderedDictionary<String, TreeValue>()
        if current == "}" {
            advance()
            return .map(dict)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            dict[key] = value
            skipWhitespace()
            if current == "}" {
                advance()
                return .map(dict)
            }
            try expect(",")
        }
    }
}
