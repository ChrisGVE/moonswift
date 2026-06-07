// File: Sources/MoonSwiftCore/JSONPath/JSONPathError.swift
// Role: Parse-time errors for the RFC 9535 subset parser. Every error carries
//       an offset into the input string so callers can produce byte-precise
//       diagnostics. Distinct cases cover unsupported selectors (with guidance),
//       malformed syntax, and document-level constraints.
// Upstream: (none — leaf error type)
// Downstream: JSONPathParser, JSONPathExpression

// MARK: - JSONPathError

/// A parse-time error thrown by `JSONPathExpression.init(parsing:)`.
///
/// Each case is distinct so tests can assert the exact failure mode, and so
/// the diagnostic rendered to the user names the unsupported construct and
/// lists the supported subset.
///
/// The associated `offset` is the byte offset (UTF-8 code unit index) inside
/// the expression string where the error was detected. Use it to anchor a
/// caret in a diagnostic.
public enum JSONPathError: Error, Sendable, Equatable {

    // MARK: Unsupported selectors (parse-time error with guidance)

    /// A filter selector `?()` was encountered, which is outside the P1 subset.
    ///
    /// Supported selectors: child name, quoted name, non-negative array index,
    /// wildcard (`*`), descendant segment (`..`).
    case unsupportedFilterSelector(offset: Int)

    /// A slice selector `[start:end:step]` was encountered, which is outside
    /// the P1 subset.
    case unsupportedSliceSelector(offset: Int)

    /// A negative array index was used. Only non-negative indices are supported.
    case unsupportedNegativeIndex(offset: Int)

    /// A function extension `name()` was encountered, which is outside the
    /// P1 subset.
    case unsupportedFunctionExtension(name: String, offset: Int)

    // MARK: Malformed syntax

    /// The expression does not start with `$` (the root identifier).
    case missingRoot(offset: Int)

    /// A quoted key was opened but the closing quote was never found before
    /// the end of input.
    case unterminatedQuote(offset: Int)

    /// A bracket segment `[…]` was opened but the closing `]` was never found.
    case unterminatedBracket(offset: Int)

    /// An escape sequence inside a quoted string is not valid per RFC 9535.
    case invalidEscapeSequence(offset: Int)

    /// An array index contained characters that are not decimal digits after
    /// optional leading sign.
    case invalidIndex(offset: Int)

    /// An unexpected character was encountered at the given offset.
    case unexpectedCharacter(Character, offset: Int)

    /// The expression ended prematurely (e.g. a trailing `.` or `..`).
    case unexpectedEnd(offset: Int)
}

// MARK: - Guidance text

extension JSONPathError {

    /// A human-readable description suitable for displaying in the diagnostics
    /// pane. Each unsupported-selector case names the construct and lists the
    /// supported subset; malformed cases describe what was wrong.
    public var diagnosticMessage: String {
        switch self {
        case .unsupportedFilterSelector:
            return """
                Filter selectors ?() are not supported in MoonSwift's JSONPath subset. \
                Supported: child name selectors ($.a.b), quoted names ($['a b']), \
                non-negative array indices ($.a[0]), wildcard ($.a.*, $[*]), \
                descendant segment ($..name).
                """
        case .unsupportedSliceSelector:
            return """
                Slice selectors [start:end] are not supported in MoonSwift's JSONPath \
                subset. Supported: child name selectors ($.a.b), quoted names ($['a b']), \
                non-negative array indices ($.a[0]), wildcard ($.a.*, $[*]), \
                descendant segment ($..name).
                """
        case let .unsupportedNegativeIndex(offset: _):
            return """
                Negative array indices are not supported in MoonSwift's JSONPath subset. \
                Use non-negative indices ($.a[0], $.a[1], …). Supported: child name \
                selectors, quoted names, non-negative array indices, wildcard, \
                descendant segment.
                """
        case let .unsupportedFunctionExtension(name: name, offset: _):
            return """
                Function extensions (\(name)()) are not supported in MoonSwift's JSONPath \
                subset. Supported: child name selectors ($.a.b), quoted names ($['a b']), \
                non-negative array indices ($.a[0]), wildcard ($.a.*, $[*]), \
                descendant segment ($..name).
                """
        case .missingRoot:
            return "JSONPath expression must start with $ (the root identifier)."
        case let .unterminatedQuote(offset: offset):
            return "Unterminated quoted string in JSONPath expression at offset \(offset). Add a closing quote."
        case let .unterminatedBracket(offset: offset):
            return "Unterminated bracket segment in JSONPath expression at offset \(offset). Add a closing ]."
        case let .invalidEscapeSequence(offset: offset):
            return
                "Invalid escape sequence in JSONPath quoted string at offset \(offset). Valid escapes: \\', \\\", \\\\, \\/, \\b, \\f, \\n, \\r, \\t, \\uXXXX."
        case .invalidIndex:
            return "Array index in JSONPath expression must be a non-negative integer."
        case let .unexpectedCharacter(ch, offset: offset):
            return "Unexpected character '\(ch)' in JSONPath expression at offset \(offset)."
        case .unexpectedEnd:
            return "JSONPath expression ended unexpectedly. A segment is incomplete."
        }
    }
}
