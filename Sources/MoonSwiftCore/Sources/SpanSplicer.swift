// File: Sources/MoonSwiftCore/Sources/SpanSplicer.swift
// Location: MoonSwiftCore/Sources/
// Role: F8a write-back engine — pure byte-level splice of edited Lua text into
//       its host file.  Covers two formats for P4 increment 1:
//         • .lua files: full overwrite (UTF-8 passthrough).
//         • JSON structured files: byte-range splice with JSON string encoding,
//           validated against a 3-part contract (reparse, span-leak, field match).
//       Does NOT perform any disk I/O; all operations accept/return Data so the
//       caller owns reading and writing (EditorBridge, P4 task 23).
// Upstream: EditorBridge (P4 — not yet implemented), SpanLocator (produces
//           byteRange), JSONPathExpression (re-resolves path for validation 3)
// Downstream: (none — pure output: Result<Data, SpliceError>)
//
// Scope: .lua + JSON only. YAML and TOML splicing are separate P4 increments.

import CryptoKit
import Foundation

// MARK: - SpliceError

/// Errors returned by `SpanSplicer` when a splice fails validation.
///
/// All three validation predicates (reparse, span-leak, field-match) must hold
/// for a splice to be accepted.  The first failing check short-circuits and
/// returns the matching case.
public enum SpliceError: Error, Equatable, Sendable {

    /// Validation (1) failed: the whole new file no longer parses in its format.
    ///
    /// `reason` is a human-readable explanation of the parse failure, suitable
    /// for a status-bar diagnostic message.
    case reparseFailed(String)

    /// Validation (2) failed: bytes outside the value span changed.
    ///
    /// This indicates a logic error in the caller — the byte range supplied to
    /// `spliceJSON` does not match what was produced by `SpanLocator`.
    case spanLeak

    /// Validation (3) failed: re-extracting the field from the new file does not
    /// equal the edited text.
    ///
    /// This catches a structural corruption where the splice was byte-legal but
    /// produced a syntactically different value than intended.
    case fieldMismatch

    /// The edited value cannot be represented in the host syntax.
    ///
    /// Theoretically unreachable for JSON (given the full escape rules), but
    /// reserved so callers can handle it without a force-cast.
    case unrepresentable(String)
}

// MARK: - SpanSplicer

/// Stateless write-back engine for F8a (P4 — increment 1).
///
/// All methods are `static` and produce no shared mutable state.
/// Disk I/O is the caller's responsibility.
public enum SpanSplicer {

    // MARK: - .lua overwrite

    /// Return the UTF-8 representation of `editedText` as the new file data.
    ///
    /// For whole `.lua` files the write-back is a complete file replacement:
    /// the caller replaces the file on disk with the bytes returned here.
    /// No validation contract is applied — the editor is responsible for
    /// syntactic correctness before calling write-back.
    ///
    /// - Parameter editedText: The new Lua source text.
    /// - Returns: `Data` containing the UTF-8 encoding of `editedText`.
    public static func overwriteLua(editedText: String) -> Data {
        return Data(editedText.utf8)
    }

    // MARK: - JSON span-splice

    /// Splice `editedText` into `originalData` at `byteRange`, re-encoding it
    /// as a JSON string body, then validate the 3-part write-back contract.
    ///
    /// The `byteRange` MUST be the range produced by `SpanLocator.locateSpan`
    /// for the same `jsonpath` in `originalData` — i.e. the UTF-8 bytes of the
    /// string value content, with surrounding double-quote bytes excluded.
    ///
    /// **3-part validation contract (all must hold):**
    /// 1. The whole new file re-parses as valid JSON.
    /// 2. Bytes outside `[0..<byteRange.lowerBound]` and
    ///    `[byteRange.upperBound...]` are byte-identical to `originalData`.
    /// 3. Re-extracting the field at `jsonpath` from the new data yields
    ///    a `.string` value that equals `editedText` exactly.
    ///
    /// - Parameters:
    ///   - editedText: The new string value (raw text, not pre-escaped).
    ///   - originalData: The complete original file bytes (UTF-8 JSON).
    ///   - byteRange: UTF-8 byte range of the current value content (quotes
    ///     excluded), as produced by `SpanLocator.locateSpan`.
    ///   - jsonpath: RFC 9535 JSONPath expression identifying the field (used
    ///     only for validation part 3; ignored in the splice itself).
    ///   - document: YAML multi-document index — always 0 for JSON (reserved
    ///     for API symmetry with future YAML support).
    /// - Returns: `.success(newData)` when all three validations pass, or
    ///   `.failure(SpliceError)` with the first failing check.
    public static func spliceJSON(
        editedText: String,
        into originalData: Data,
        byteRange: Range<Int>,
        jsonpath: String,
        document: Int
    ) -> Result<Data, SpliceError> {
        // Build the new Data by splicing the JSON-encoded body into the range.
        let encodedBody = jsonStringBody(for: editedText)
        let newData = buildSplicedData(
            original: originalData,
            byteRange: byteRange,
            encodedBody: encodedBody
        )

        // --- Validation (1): the new file re-parses as JSON. ---
        guard let newText = String(data: newData, encoding: .utf8) else {
            return .failure(.reparseFailed("new file bytes are not valid UTF-8"))
        }
        let newTree: TreeValue
        do {
            newTree = try decodeJSON(newText)
        } catch {
            return .failure(.reparseFailed(error.localizedDescription))
        }

        // --- Validation (2): bytes outside the splice span are unchanged. ---
        // The prefix [0..<byteRange.lowerBound] must be byte-identical.
        // The suffix [byteRange.upperBound...] must be byte-identical, shifted
        // by the length delta introduced by the new encoded body.
        let lowerBound = byteRange.lowerBound
        let upperBound = byteRange.upperBound

        let safeUpper = min(upperBound, originalData.count)
        let safeLower = min(lowerBound, originalData.count)

        let originalPrefix = originalData[0..<safeLower]
        let originalSuffix = originalData[safeUpper...]
        let encodedBodyCount = encodedBody.utf8.count

        guard newData.count >= safeLower + encodedBodyCount else {
            return .failure(.spanLeak)
        }

        let newPrefix = newData[0..<safeLower]
        let newSuffixStart = safeLower + encodedBodyCount
        guard newData.count >= newSuffixStart else {
            return .failure(.spanLeak)
        }
        let newSuffix = newData[newSuffixStart...]

        guard newPrefix == originalPrefix, newSuffix == originalSuffix else {
            return .failure(.spanLeak)
        }

        // --- Validation (3): re-extracting the field equals editedText. ---
        guard let extractedValue = reExtractJSONField(from: newTree, jsonpath: jsonpath) else {
            return .failure(.fieldMismatch)
        }
        guard extractedValue == editedText else {
            return .failure(.fieldMismatch)
        }

        return .success(newData)
    }

    // MARK: - Conflict-hash helper

    /// Returns `true` when `currentData` has been externally modified since the
    /// hash `expected` was captured at load time.
    ///
    /// The driver re-reads the file from disk and calls this before writing back.
    /// A `true` result triggers the conflict prompt:
    /// *"File changed externally. [r]eload / [o]verwrite / [d]iff / [c]ancel"*.
    ///
    /// - Parameters:
    ///   - currentData: The file bytes as they currently exist on disk.
    ///   - expected: The `SHA256Digest` captured by `SourceStore` at load time
    ///     (stored in `FragmentProvenance.contentHash`).
    /// - Returns: `true` if the current SHA-256 digest differs from `expected`.
    public static func hasConflict(currentData: Data, expected: SHA256Digest) -> Bool {
        return SHA256.hash(data: currentData) != expected
    }

    // MARK: - JSON string body encoding

    /// Encode `text` as the body of a JSON string — the bytes that appear between
    /// the surrounding double-quote delimiters.
    ///
    /// Escape rules (RFC 8259 §7):
    /// - `"` → `\"`
    /// - `\` → `\\`
    /// - `\n` (LF, 0x0A) → `\n`
    /// - `\r` (CR, 0x0D) → `\r`
    /// - `\t` (HT, 0x09) → `\t`
    /// - `\b` (BS, 0x08) → `\b`
    /// - `\f` (FF, 0x0C) → `\f`
    /// - Other control characters (U+0000–U+001F) → `\uXXXX`
    ///
    /// The result is always single-line: literal newlines in `text` become `\n`
    /// escape sequences, so the JSON body never introduces a line break in the
    /// output file.
    ///
    /// Reference: RFC 8259 §7 "Strings"
    static func jsonStringBody(for text: String) -> String {
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
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x00..<0x20:
                // Other control characters: encode as \uXXXX (always 4 hex digits).
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Splice assembly

    /// Assemble new `Data` by replacing `originalData[byteRange]` with the
    /// UTF-8 bytes of `encodedBody`.
    ///
    /// Bytes before and after `byteRange` are preserved byte-for-byte.
    /// If `byteRange` extends past `originalData.count`, the out-of-range
    /// portion is treated as an empty suffix (no crash, but validation (2)
    /// will subsequently detect the leak).
    private static func buildSplicedData(
        original: Data,
        byteRange: Range<Int>,
        encodedBody: String
    ) -> Data {
        let lower = min(byteRange.lowerBound, original.count)
        let upper = min(byteRange.upperBound, original.count)

        var newData = Data()
        newData.reserveCapacity(original.count - (upper - lower) + encodedBody.utf8.count)
        newData.append(original[0..<lower])
        newData.append(Data(encodedBody.utf8))
        newData.append(original[upper...])
        return newData
    }

    // MARK: - Validation (3): field re-extraction

    /// Parse `jsonpath` and evaluate it against `tree`, returning the decoded
    /// string value of the first match, or `nil` if the path resolves to a
    /// non-string or matches nothing.
    ///
    /// Used exclusively by validation step (3) in `spliceJSON`.
    private static func reExtractJSONField(from tree: TreeValue, jsonpath: String) -> String? {
        guard let expr = try? JSONPathExpression(parsing: jsonpath) else { return nil }
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first else { return nil }
        if case .string(let decoded) = value { return decoded }
        return nil
    }
}
