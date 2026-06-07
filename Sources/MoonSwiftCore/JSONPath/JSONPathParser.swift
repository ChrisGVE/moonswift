// File: Sources/MoonSwiftCore/JSONPath/JSONPathParser.swift
// Role: Recursive-descent parser that converts a JSONPath expression string
//       into a [PathSegment] AST. Implements the RFC 9535 subset supported in
//       MoonSwift P1: root $, child name (dot + bracket), quoted names (single-
//       and double-quoted with RFC 9535 escapes), non-negative array indices,
//       wildcard, and descendant segments. Unsupported constructs (filter,
//       slice, negative index, function extensions) produce distinct errors with
//       guidance text.
//
// Reference: RFC 9535 §2.1–§2.5 (https://www.rfc-editor.org/rfc/rfc9535)
//            RFC 9535 §2.7 (normalized path form, for guidance in errors)
//
// Upstream: JSONPathExpression (calls parse())
// Downstream: (none — produces [PathSegment])

// MARK: - JSONPathParser

/// A single-pass recursive-descent parser over a JSONPath expression string.
///
/// Create one instance per expression and call `parse()`. The parser works on
/// the UTF-8 scalar view to give byte-precise error offsets, which the caller
/// surfaces in diagnostics as caret positions.
struct JSONPathParser {

    // MARK: State

    private let input: [Unicode.Scalar]  // full scalar sequence for random access
    private var pos: Int                 // current cursor (scalar index)

    // MARK: Init

    /// Create a parser for the given expression string.
    init(_ expression: String) {
        input = Array(expression.unicodeScalars)
        pos = 0
    }

    // MARK: Entry point

    /// Parse the expression and return a segment array, or throw a `JSONPathError`.
    mutating func parse() throws(JSONPathError) -> [PathSegment] {
        // RFC 9535 §2.1: every JSONPath expression starts with $.
        guard consume("$") else {
            throw .missingRoot(offset: pos)
        }

        var segments: [PathSegment] = []

        while pos < input.count {
            let ch = current()

            if ch == "." {
                // Could be a dot-child segment (`.name`, `.*`) or a descendant
                // segment (`..name`, `..*`, `..['name']`, `..[*]`).
                advance()                               // consume first .
                if pos < input.count && current() == "." {
                    advance()                           // consume second .
                    // Descendant: what follows is a selector.
                    let selector = try parseDescendantSelector()
                    segments.append(.descendant(selector))
                } else {
                    // Child segment via dot notation.
                    let selector = try parseDotSelector()
                    segments.append(.child(selector))
                }
            } else if ch == "[" {
                // Bracket segment — child step.
                let selector = try parseBracketSegment()
                segments.append(.child(selector))
            } else {
                throw .unexpectedCharacter(Character(ch), offset: pos)
            }
        }

        return segments
    }

    // MARK: - Dot-notation selector

    /// Parse the selector that follows a single `.` in dot notation.
    ///
    /// Grammar (subset): `.name` | `.*`
    private mutating func parseDotSelector() throws(JSONPathError) -> Selector {
        guard pos < input.count else {
            throw .unexpectedEnd(offset: pos)
        }
        let ch = current()
        if ch == "*" {
            advance()
            return .wildcard
        }
        // Must be an identifier character (first char: letter or _; subsequent:
        // letter, digit, or _). RFC 9535 uses a broader Unicode name grammar,
        // but the subset normalises via dot notation only for ASCII-safe keys;
        // broader keys use bracket notation.
        guard isIdentifierStart(ch) else {
            throw .unexpectedCharacter(Character(ch), offset: pos)
        }
        let name = scanIdentifier()
        return .name(name)
    }

    // MARK: - Descendant selector

    /// Parse the selector that follows `..` in a descendant segment.
    ///
    /// Grammar (subset): `..name` | `..*` | `..['key']` | `..[N]` | `..[*]`
    private mutating func parseDescendantSelector() throws(JSONPathError) -> Selector {
        guard pos < input.count else {
            throw .unexpectedEnd(offset: pos)
        }
        let ch = current()
        if ch == "*" {
            advance()
            return .wildcard
        }
        if ch == "[" {
            // Bracket form inside a descendant segment — reuse bracket parsing.
            return try parseBracketSegment()
        }
        if isIdentifierStart(ch) {
            let name = scanIdentifier()
            return .name(name)
        }
        throw .unexpectedCharacter(Character(ch), offset: pos)
    }

    // MARK: - Bracket segment

    /// Parse a `[…]` segment and return the selector it contains.
    ///
    /// On entry `pos` points at `[`; on exit it is past `]`.
    private mutating func parseBracketSegment() throws(JSONPathError) -> Selector {
        let openPos = pos
        guard consume("[") else {
            throw .unexpectedCharacter(Character(current()), offset: pos)
        }
        skipWhitespace()

        guard pos < input.count else {
            throw .unterminatedBracket(offset: openPos)
        }

        let ch = current()

        // Wildcard: [*]
        if ch == "*" {
            advance()
            skipWhitespace()
            guard consume("]") else {
                throw .unterminatedBracket(offset: openPos)
            }
            return .wildcard
        }

        // Filter selector: ?() — unsupported
        if ch == "?" {
            throw .unsupportedFilterSelector(offset: pos)
        }

        // Function call: name(...) — unsupported
        if isIdentifierStart(ch) {
            let startPos = pos
            let name = scanIdentifier()
            skipWhitespace()
            if pos < input.count && current() == "(" {
                throw .unsupportedFunctionExtension(name: name, offset: startPos)
            }
            // Otherwise this is an unquoted name (non-standard) — treat as name
            // selector for robustness, but RFC 9535 requires quotes inside brackets.
            // We allow bare identifiers to be friendly; normalized output uses quotes.
            skipWhitespace()
            guard consume("]") else {
                throw .unterminatedBracket(offset: openPos)
            }
            return .name(name)
        }

        // Quoted name: ['key'] or ["key"]
        if ch == "'" || ch == "\"" {
            let name = try parseQuotedString()
            skipWhitespace()
            guard consume("]") else {
                throw .unterminatedBracket(offset: openPos)
            }
            return .name(name)
        }

        // Slice check: if we see a colon after optional digits, it's a slice.
        // We detect this early to give the right error.
        if ch == ":" {
            throw .unsupportedSliceSelector(offset: pos)
        }

        // Array index (non-negative) or negative index (unsupported).
        if ch == "-" {
            throw .unsupportedNegativeIndex(offset: pos)
        }
        if ch.properties.numericType == .decimal {
            let idx = try parseNonNegativeIndex(openBracketPos: openPos)
            skipWhitespace()
            guard consume("]") else {
                throw .unterminatedBracket(offset: openPos)
            }
            return .index(idx)
        }

        throw .unexpectedCharacter(Character(ch), offset: pos)
    }

    // MARK: - Quoted string

    /// Parse a single- or double-quoted string per RFC 9535 §2.3.5.
    ///
    /// Supported escape sequences: `\b`, `\f`, `\n`, `\r`, `\t`, `\\`, `\/`,
    /// `\'`, `\"`, `\uXXXX`.
    ///
    /// On entry `pos` points at the opening quote; on exit it is past the
    /// closing quote.
    private mutating func parseQuotedString() throws(JSONPathError) -> String {
        let quotePos = pos
        let quote = current()   // ' or "
        advance()               // consume opening quote

        var result = ""
        while pos < input.count {
            let ch = current()
            if ch == quote {
                advance()       // consume closing quote
                return result
            }
            if ch == "\\" {
                let escStart = pos
                advance()       // consume backslash
                guard pos < input.count else {
                    throw .unterminatedQuote(offset: quotePos)
                }
                let esc = current()
                advance()       // consume escape character
                switch esc {
                case "b":  result.append("\u{0008}")
                case "f":  result.append("\u{000C}")
                case "n":  result.append("\n")
                case "r":  result.append("\r")
                case "t":  result.append("\t")
                case "\\": result.append("\\")
                case "/":  result.append("/")
                case "'":  result.append("'")
                case "\"": result.append("\"")
                case "u":
                    // \uXXXX — four hex digits.
                    let scalar = try parseUnicodeEscape(escapedAt: escStart)
                    result.append(Character(scalar))
                default:
                    throw .invalidEscapeSequence(offset: escStart)
                }
            } else {
                result.append(Character(ch))
                advance()
            }
        }
        throw .unterminatedQuote(offset: quotePos)
    }

    /// Parse four hex digits after `\u` and return the corresponding Unicode
    /// scalar. On entry `pos` points at the first digit.
    private mutating func parseUnicodeEscape(escapedAt: Int) throws(JSONPathError) -> Unicode.Scalar {
        var hexString = ""
        for _ in 0..<4 {
            guard pos < input.count else {
                throw .invalidEscapeSequence(offset: escapedAt)
            }
            let ch = current()
            guard isHexDigit(ch) else {
                throw .invalidEscapeSequence(offset: escapedAt)
            }
            hexString.append(Character(ch))
            advance()
        }
        guard let codePoint = UInt32(hexString, radix: 16),
              let scalar = Unicode.Scalar(codePoint) else {
            throw .invalidEscapeSequence(offset: escapedAt)
        }
        return scalar
    }

    // MARK: - Non-negative integer index

    /// Parse decimal digits into an `Int` index. Rejects slices (`:`) and
    /// verifies the result is non-negative.
    private mutating func parseNonNegativeIndex(openBracketPos: Int) throws(JSONPathError) -> Int {
        let start = pos
        while pos < input.count && current().properties.numericType == .decimal {
            advance()
        }
        let digits = String(input[start..<pos].map(Character.init))

        // Slice: digits followed by colon.
        if pos < input.count && current() == ":" {
            throw .unsupportedSliceSelector(offset: start)
        }

        guard let value = Int(digits) else {
            throw .invalidIndex(offset: start)
        }
        return value
    }

    // MARK: - Identifier scanning

    /// Scan a dot-notation identifier (letter or `_` start; letter, digit, or
    /// `_` continuation). RFC 9535 permits a broader Unicode name grammar;
    /// the P1 subset is ASCII-centric for keys that qualify for dot notation.
    private mutating func scanIdentifier() -> String {
        var name = ""
        while pos < input.count {
            let ch = current()
            if isIdentifierStart(ch) || (ch >= "0" && ch <= "9") {
                name.append(Character(ch))
                advance()
            } else {
                break
            }
        }
        return name
    }

    // MARK: - Character predicates

    private func isIdentifierStart(_ ch: Unicode.Scalar) -> Bool {
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == "_"
    }

    private func isHexDigit(_ ch: Unicode.Scalar) -> Bool {
        (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F")
    }

    // MARK: - Cursor helpers

    private func current() -> Unicode.Scalar { input[pos] }

    private mutating func advance() { pos += 1 }

    @discardableResult
    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard pos < input.count, input[pos] == scalar else { return false }
        pos += 1
        return true
    }

    private mutating func skipWhitespace() {
        while pos < input.count {
            let ch = current()
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                advance()
            } else {
                break
            }
        }
    }
}
