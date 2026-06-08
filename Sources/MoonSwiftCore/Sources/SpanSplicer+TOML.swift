// File: Sources/MoonSwiftCore/Sources/SpanSplicer+TOML.swift
// Location: MoonSwiftCore/Sources/
// Role: F8a write-back engine — TOML span-splice (P4 increment 2).
//       Extends SpanSplicer with spliceTOML: splices edited text into a TOML
//       value span, selects the correct TOML string kind, and validates the
//       same 3-part write-back contract used by spliceJSON.
// Upstream: EditorBridge (P4, not yet implemented), SpanLocator (byteRange),
//           decodeTOML / JSONPathExpression (validation 3)
// Downstream: (none — pure output: Result<Data, SpliceError>)
//
// Delimiter detection:
//   SpanLocator strips exactly 1 byte from each side.  For `"…"` / `'…'` the
//   byte at byteRange.lowerBound is the first content character.  For `"""…"""`
//   or `'''…'''` the first two bytes inside byteRange are extra delimiter chars.
//   detectDelimiterKind reads bytes around byteRange to classify the original.
//
// String kind for the NEW token (PRD F8, binding):
//   • editedText has a newline, or original was multi-line → """…""" basic.
//   • all other cases → "…" basic with TOML escape rules.
//   Literal style ('…') is never written back; upgrading to basic is always
//   safe and the PRD only mandates it when escapes are needed.
//
// Delimiter-expansion:
//   The splice replaces the WHOLE original token (delimiters + content) so that
//   kind changes (single→multi-line, literal→basic) are self-consistent.
//   expandedRange grows byteRange by 1 on each side (SpanLocator's strip amount).

import Foundation

// MARK: - TOML span-splice

extension SpanSplicer {

    // MARK: - Public entry point

    /// Splice `editedText` into `originalData` at `byteRange`, encoding it as
    /// a TOML string, then validate the 3-part write-back contract.
    ///
    /// The `byteRange` MUST be the range produced by `SpanLocator.locateSpan`
    /// for the same `jsonpath` in `originalData`.  SpanLocator strips the
    /// outermost single delimiter byte from each side, so the byte immediately
    /// before `byteRange.lowerBound` is always `"` or `'`.
    ///
    /// **String kind selection (PRD F8 binding rule):**
    /// - `editedText` contains a newline → `"""…"""` multi-line basic.
    ///   Embedded `"""` sequences are escaped by inserting a `\` before the
    ///   last `"` of any `"""` run.
    /// - `editedText` needs escapes (contains `"`, `\`, or control chars) OR
    ///   the original was a single-line basic string → `"…"` basic string.
    /// - Otherwise (no escapes needed) → `"…"` basic string (simpler and
    ///   unambiguous; literal style is not preserved for edited values).
    ///
    /// **3-part validation contract (all must hold):**
    /// 1. The whole new file re-parses as valid TOML.
    /// 2. Bytes outside the replaced token are byte-identical to `originalData`.
    /// 3. Re-extracting the field at `jsonpath` from the new data yields a
    ///    `.string` value that equals `editedText` exactly.
    ///
    /// - Parameters:
    ///   - editedText: The new string value (raw text, not pre-escaped).
    ///   - originalData: The complete original file bytes (UTF-8 TOML).
    ///   - byteRange: UTF-8 byte range of the current value content (with the
    ///     outermost delimiter byte stripped from each side), as produced by
    ///     `SpanLocator.locateSpan`.
    ///   - jsonpath: RFC 9535 JSONPath expression identifying the field (used
    ///     only for validation part 3).
    ///   - document: TOML is always single-document; reserved for API symmetry
    ///     with the YAML splicer.
    /// - Returns: `.success(newData)` when all three validations pass, or
    ///   `.failure(SpliceError)` with the first failing check.
    public static func spliceTOML(
        editedText: String,
        into originalData: Data,
        byteRange: Range<Int>,
        jsonpath: String,
        document: Int
    ) -> Result<Data, SpliceError> {
        // Detect the original delimiter kind from the bytes surrounding byteRange.
        let kind = detectDelimiterKind(in: originalData, byteRange: byteRange)

        // Compute the full token range (delimiters + content) to replace.
        let tokenRange = expandedRange(byteRange: byteRange, delimiterWidth: kind.width)

        // Encode the edited text as the new TOML string token.
        let newToken = tomlStringToken(for: editedText, originalKind: kind)

        // Build the spliced data by replacing the whole token.
        let newData = buildSplicedData(
            original: originalData,
            byteRange: tokenRange,
            encodedBody: newToken
        )

        // --- Validation (1): the new file re-parses as TOML. ---
        guard let newText = String(data: newData, encoding: .utf8) else {
            return .failure(.reparseFailed("new file bytes are not valid UTF-8"))
        }
        let newTree: TreeValue
        do {
            newTree = try decodeTOML(newText)
        } catch {
            return .failure(.reparseFailed(error.localizedDescription))
        }

        // --- Validation (2): bytes outside the replaced token are unchanged. ---
        let tokenLower = tokenRange.lowerBound
        let tokenUpper = tokenRange.upperBound

        let safeLower = min(tokenLower, originalData.count)
        let safeUpper = min(tokenUpper, originalData.count)

        guard newData.count >= safeLower else {
            return .failure(.spanLeak)
        }

        let originalPrefix = originalData[0..<safeLower]
        let originalSuffix = originalData[safeUpper...]
        let newTokenByteCount = newToken.utf8.count

        guard newData.count >= safeLower + newTokenByteCount else {
            return .failure(.spanLeak)
        }

        let newPrefix = newData[0..<safeLower]
        let newSuffixStart = safeLower + newTokenByteCount
        guard newData.count >= newSuffixStart else {
            return .failure(.spanLeak)
        }
        let newSuffix = newData[newSuffixStart...]

        guard newPrefix == originalPrefix, newSuffix == originalSuffix else {
            return .failure(.spanLeak)
        }

        // --- Validation (3): re-extracting the field equals editedText. ---
        guard let extractedValue = reExtractTOMLField(from: newTree, jsonpath: jsonpath) else {
            return .failure(.fieldMismatch)
        }
        guard extractedValue == editedText else {
            return .failure(.fieldMismatch)
        }

        return .success(newData)
    }

    // MARK: - Delimiter detection

    /// Describes the delimiter kind of the original TOML string token.
    enum TOMLDelimiterKind {
        /// Single-line basic string: `"…"`.
        case basic
        /// Single-line literal string: `'…'`.
        case literal
        /// Multi-line basic string: `"""…"""`.
        case multilineBasic
        /// Multi-line literal string: `'''…'''`.
        case multilineLiteral

        /// The number of delimiter bytes on each side of the content.
        var width: Int {
            switch self {
            case .basic, .literal: return 1
            case .multilineBasic, .multilineLiteral: return 3
            }
        }

        /// Whether this is a basic (double-quoted) style.
        var isBasic: Bool {
            switch self {
            case .basic, .multilineBasic: return true
            case .literal, .multilineLiteral: return false
            }
        }
    }

    /// Determine the delimiter kind of the TOML string at `byteRange` in `data`.
    ///
    /// SpanLocator strips exactly 1 delimiter byte from each side.  Therefore:
    /// - The byte at `byteRange.lowerBound - 1` is the outermost stripped delimiter
    ///   character (`"` or `'`).
    /// - If `byteRange` is non-empty and `data[byteRange.lowerBound]` equals that
    ///   same delimiter character (and so does `data[byteRange.lowerBound + 1]`),
    ///   the original used triple-quote delimiters.
    ///
    /// The multi-line detection reads at most `byteRange.lowerBound` and
    /// `byteRange.lowerBound + 1`; both reads are bounds-checked.
    static func detectDelimiterKind(
        in data: Data,
        byteRange: Range<Int>
    ) -> TOMLDelimiterKind {
        let outerByte: UInt8
        let outerIdx = byteRange.lowerBound - 1
        // If there is no byte before the range (defensive), default to basic.
        guard outerIdx >= 0, outerIdx < data.count else { return .basic }
        outerByte = data[outerIdx]

        let delimChar: UInt8
        let isBasicOuter: Bool
        switch outerByte {
        case UInt8(ascii: "\""):
            delimChar = UInt8(ascii: "\"")
            isBasicOuter = true
        case UInt8(ascii: "'"):
            delimChar = UInt8(ascii: "'")
            isBasicOuter = false
        default:
            // Unknown delimiter byte — default to basic.
            return .basic
        }

        // Check whether the first two bytes of the stripped content also carry
        // the delimiter character (indicating a triple-quote original).
        let inner0 = byteRange.lowerBound
        let inner1 = byteRange.lowerBound + 1
        let isMultiline =
            inner0 < data.count && data[inner0] == delimChar
            && inner1 < data.count && data[inner1] == delimChar

        if isMultiline {
            return isBasicOuter ? .multilineBasic : .multilineLiteral
        }
        return isBasicOuter ? .basic : .literal
    }

    /// Return `(byteRange.lowerBound - 1)..<(byteRange.upperBound + 1)` —
    /// the full TOML string token including its outermost delimiter bytes.
    ///
    /// SpanLocator always strips exactly 1 byte (the outermost delimiter) from
    /// each side, so the token extends 1 byte beyond `byteRange` on each end.
    /// For multi-line strings (`"""`), the two inner delimiter bytes are
    /// already inside `byteRange` and are overwritten as part of the content.
    private static func expandedRange(
        byteRange: Range<Int>,
        delimiterWidth: Int
    ) -> Range<Int> {
        return max(0, byteRange.lowerBound - 1)..<(byteRange.upperBound + 1)
    }

    // MARK: - String token encoding

    /// Encode `editedText` as a complete TOML string TOKEN (delimiters included).
    ///
    /// Produces `"""…"""` (multi-line basic) when `editedText` has a newline or
    /// the original was multi-line; otherwise `"…"` (single-line basic).
    /// The leading `\n` after `"""` is trimmed by TOML parsers, so the content
    /// starts at the first non-newline character.
    static func tomlStringToken(for editedText: String, originalKind: TOMLDelimiterKind) -> String {
        let isMultiline =
            editedText.contains("\n")
            || originalKind == .multilineBasic
            || originalKind == .multilineLiteral
        if isMultiline {
            return "\"\"\"\n\(multilineBasicBody(for: editedText))\"\"\""
        }
        return "\"\(tomlBasicStringBody(for: editedText))\""
    }

    // MARK: - TOML basic string body encoding

    /// Encode `text` as the body of a TOML basic string — bytes between `"…"`.
    ///
    /// TOML basic string escape rules (TOML v1.0 §2.1 "Basic strings"):
    /// - `"` → `\"`
    /// - `\` → `\\`
    /// - `\b` (0x08) → `\b`
    /// - `\t` (0x09) → `\t`
    /// - `\n` (0x0A) → `\n`
    /// - `\f` (0x0C) → `\f`
    /// - `\r` (0x0D) → `\r`
    /// - Other control chars (U+0000–U+0008, U+000A–U+001F, U+007F) → `\uXXXX`
    ///
    /// Reference: TOML v1.0 specification §2.1
    /// https://toml.io/en/v1.0.0#string
    static func tomlBasicStringBody(for text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08:
                result += "\\b"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x22:  // "
                result += "\\\""
            case 0x5C:  // \
                result += "\\\\"
            case 0x00..<0x08, 0x0B, 0x0E..<0x20, 0x7F:
                // Other control characters: encode as \uXXXX.
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - TOML multi-line basic string body encoding

    /// Encode `text` as the body of a TOML multi-line basic string — bytes
    /// between the opening `"""\n` and the closing `"""`.
    ///
    /// Inside `"""…"""` the characters `"` and `\` still need escaping when
    /// they would otherwise form the `"""` end sequence.  The TOML spec
    /// (v1.0 §2.1.5 "Multi-line basic strings") allows one or two unescaped
    /// `"` characters adjacent to the closing `"""` but NOT three in a row.
    ///
    /// Strategy: scan `text` for runs of consecutive `"` characters.  Whenever
    /// a run of 3 or more would appear, escape every third `"` as `\"` to
    /// break the run.  Control characters (except `\n`, `\r`, `\t`) are
    /// encoded as `\uXXXX` per the same rules as basic strings.
    /// Backslash is also escaped as `\\`.
    ///
    /// The result does NOT include surrounding `"""` or the leading `\n`;
    /// callers add those (see `tomlStringToken`).
    ///
    /// Reference: TOML v1.0 specification §2.1.5
    /// https://toml.io/en/v1.0.0#string
    static func multilineBasicBody(for text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)

        // We need to track consecutive `"` runs to detect potential `"""` endings.
        // We accumulate each scalar and post-process runs of `"` to escape as needed.
        var quoteRun = 0

        func flushQuoteRun() {
            // Emit `quoteRun` quote chars, escaping every 3rd to break `"""` sequences.
            var remaining = quoteRun
            while remaining > 0 {
                if remaining >= 3 {
                    // Emit two unescaped quotes then one escaped to break the run.
                    result += "\"\""
                    result += "\\\""
                    remaining -= 3
                } else {
                    result += "\""
                    remaining -= 1
                }
            }
            quoteRun = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.value == 0x22 {  // "
                quoteRun += 1
                continue
            }
            // Non-quote: flush any accumulated quote run first.
            if quoteRun > 0 { flushQuoteRun() }

            switch scalar.value {
            case 0x5C:  // \
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x00..<0x08, 0x0B, 0x0E..<0x20, 0x7F:
                // Control chars (except LF, TAB, CR which are allowed raw in multiline).
                result += String(format: "\\u%04X", scalar.value)
            default:
                // \n (0x0A) and \t (0x09) are allowed unescaped inside """.
                result.unicodeScalars.append(scalar)
            }
        }

        // Flush any trailing quote run.
        if quoteRun > 0 { flushQuoteRun() }

        return result
    }

    // MARK: - Validation (3): field re-extraction

    /// Parse `jsonpath` and evaluate it against `tree`, returning the decoded
    /// string value of the first match, or `nil` if the path resolves to a
    /// non-string or matches nothing.
    ///
    /// Mirrors `reExtractJSONField` in SpanSplicer.swift for TOML.
    private static func reExtractTOMLField(from tree: TreeValue, jsonpath: String) -> String? {
        guard let expr = try? JSONPathExpression(parsing: jsonpath) else { return nil }
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first else { return nil }
        if case .string(let decoded) = value { return decoded }
        return nil
    }
}
