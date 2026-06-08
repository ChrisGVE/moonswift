// File: Sources/MoonSwiftCore/Sources/SpanSplicer+YAML.swift
// Location: MoonSwiftCore/Sources/
// Role: F8a write-back engine — YAML span-splice (P4 increment 3).
//       Extends SpanSplicer with spliceYAML: splices edited text into a YAML
//       value span, selects the correct output style per PRD F8 binding rules,
//       and validates the same 3-part write-back contract used by the JSON and
//       TOML splicers.
// Upstream: EditorBridge (P4, not yet implemented), SpanLocator (byteRange),
//           decodeYAML / JSONPathExpression (validation 3)
// Downstream: (none — pure output: Result<Data, SpliceError>)
//
// byteRange semantics (verified empirically by SpanLocatorYAMLSemantics.swift):
//   plain scalar       — byteRange = text bytes only; byte immediately before
//                        byteRange.lowerBound is a space (after `: `).
//   single-quoted      — byteRange = content without quotes; byte-1 = '\''
//   double-quoted      — byteRange = content without quotes; byte-1 = '"'
//   block scalar (|/-) — byteRange starts at the '|' or '>' indicator character
//                        and ends after the last content byte (trailing newline
//                        of the last content line is NOT included in the range).
//
// PRD F8 YAML style rules (binding):
//   • original was a BLOCK SCALAR (|/|-/|+/>/>-/etc.):
//     → preserve block style (|-), re-indent content to original block indent.
//   • original was flow/plain/quoted AND new text is MULTI-LINE:
//     → convert to literal block scalar (|-) at key's indentation + 2.
//   • SINGLE-LINE replacements keep the original quoting style:
//     - plain stays plain (unless YAML-special chars require promotion)
//     - single-quoted stays single-quoted (unless text has a ' requiring promotion)
//     - double-quoted stays double-quoted (re-escaped as needed)
//     - any plain text with YAML-special leading/embedded chars is promoted to "…"
//
// Replaced region (the slice of originalData that is swapped out):
//   plain  single-line → byteRange only
//   quoted single-line → (byteRange.lowerBound - 1)..<(byteRange.upperBound + 1)
//   plain  multi-line  → byteRange only (indicator replaces the old plain text)
//   quoted multi-line  → (byteRange.lowerBound - 1)..<(byteRange.upperBound + 1)
//   block  any         → byteRange (indicator + content lines are all inside the range)
//
// For multi-line conversion the indicator `|-` is appended to the key line.
// The key line itself is not part of byteRange, but the splicer must replace
// the correct byte region.  For a PLAIN scalar (byte-1 = space, meaning the
// value starts right after `: `) the replacement region starts at byteRange
// and the caller's key line gains `|-\n` plus indented content.  For QUOTED
// the delimiters are included in the replacement region.
//
// Validation contract part 2:
//   "Bytes outside the replaced region are byte-identical to originalData."
//   The replaced region is derived via replacedRegion(…) below; this is what
//   the span-leak check compares.
//
// Key-indent derivation:
//   Scanning backwards from the byte immediately before the replaced region,
//   find the preceding newline (or start of data).  The key-indent is the
//   number of leading spaces on that line.  Block content is written at
//   key-indent + 2.

import Foundation

// MARK: - YAML span-splice

extension SpanSplicer {

    // MARK: - Public entry point

    /// Splice `editedText` into `originalData` at `byteRange`, encoding it as
    /// a YAML scalar, then validate the 3-part write-back contract.
    ///
    /// The `byteRange` MUST be the range produced by `SpanLocator.locateSpan`
    /// for the same `jsonpath` in `originalData`. The semantics differ by scalar
    /// kind — see file header for the full contract.
    ///
    /// **Style selection (PRD F8 YAML rules, binding):**
    /// - Original block scalar (`|`/`|-`/etc.) → preserved as `|-` block,
    ///   content re-indented at key-indent + 2.
    /// - Flow/plain/quoted + multi-line new text → converted to `|-` block at
    ///   key-indent + 2.
    /// - Single-line new text keeps the original style with re-escaping:
    ///   plain stays plain (with YAML-special-char promotion to `"…"`),
    ///   `'…'` stays single-quoted (promoted to `"…"` if text contains `'`),
    ///   `"…"` stays double-quoted.
    ///
    /// **3-part validation contract (all must hold):**
    /// 1. The whole new file re-parses as valid YAML.
    /// 2. Bytes outside the replaced region are byte-identical to `originalData`.
    /// 3. Re-extracting the field at `jsonpath` (document `document`) from the
    ///    new data yields a `.string` value that equals `editedText` exactly.
    ///
    /// - Parameters:
    ///   - editedText: The new string value (raw text, not pre-escaped).
    ///   - originalData: The complete original file bytes (UTF-8 YAML).
    ///   - byteRange: UTF-8 byte range of the current value (as produced by
    ///     `SpanLocator.locateSpan`).
    ///   - jsonpath: RFC 9535 JSONPath expression identifying the field (used
    ///     only for validation part 3).
    ///   - document: Zero-based document index for multi-document YAML streams.
    /// - Returns: `.success(newData)` when all three validations pass, or
    ///   `.failure(SpliceError)` with the first failing check.
    public static func spliceYAML(
        editedText: String,
        into originalData: Data,
        byteRange: Range<Int>,
        jsonpath: String,
        document: Int
    ) -> Result<Data, SpliceError> {
        // Classify the original scalar kind from bytes surrounding byteRange.
        let kind = yamlScalarKind(in: originalData, byteRange: byteRange)

        // Derive the key's indentation level from the line that holds the key.
        let keyIndent = yamlKeyIndent(in: originalData, byteRange: byteRange, kind: kind)

        // Compute the full replaced region (may differ from byteRange for quoted kinds).
        let region = yamlReplacedRegion(byteRange: byteRange, kind: kind)

        // Encode the new YAML token (may be a plain/quoted scalar or a block scalar).
        let newToken = yamlNewToken(
            editedText: editedText,
            kind: kind,
            keyIndent: keyIndent
        )

        // Build the spliced data by replacing the region with the new token.
        let newData = buildSplicedData(
            original: originalData,
            byteRange: region,
            encodedBody: newToken
        )

        // --- Validation (1): the new file re-parses as YAML. ---
        guard let newText = String(data: newData, encoding: .utf8) else {
            return .failure(.reparseFailed("new file bytes are not valid UTF-8"))
        }
        let newTree: TreeValue
        do {
            newTree = try decodeYAML(newText, document: document)
        } catch {
            return .failure(.reparseFailed(error.localizedDescription))
        }

        // --- Validation (2): bytes outside the replaced region are unchanged. ---
        let regionLower = region.lowerBound
        let regionUpper = region.upperBound

        let safeLower = min(regionLower, originalData.count)
        let safeUpper = min(regionUpper, originalData.count)

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
        guard
            let extractedValue = reExtractYAMLField(
                from: newTree, jsonpath: jsonpath
            )
        else {
            return .failure(.fieldMismatch)
        }
        guard extractedValue == editedText else {
            return .failure(.fieldMismatch)
        }

        return .success(newData)
    }

    // MARK: - YAML scalar kind

    /// Classifies the original scalar at `byteRange` in `data`.
    enum YAMLScalarKind {
        /// Plain (unquoted) scalar: byte before value = space.
        case plain
        /// Single-quoted scalar (`'…'`): byte before = `'`.
        case singleQuoted
        /// Double-quoted scalar (`"…"`): byte before = `"`.
        case doubleQuoted
        /// Block scalar (`|`/`|-`/`|+`/`>`/`>-`/etc.): first byte of range = `|` or `>`.
        case block
    }

    /// Determine the YAML scalar kind from the bytes surrounding `byteRange`.
    ///
    /// Classification rules (matching SpanLocator behaviour):
    /// - If the first byte of `byteRange` is `|` or `>`, it is a block scalar.
    /// - Else if the byte immediately before `byteRange` is `'`, it is single-quoted.
    /// - Else if the byte immediately before `byteRange` is `"`, it is double-quoted.
    /// - Otherwise it is a plain scalar (byte before = space or start-of-data).
    static func yamlScalarKind(in data: Data, byteRange: Range<Int>) -> YAMLScalarKind {
        // Block scalars: first byte of range is the indicator character.
        if byteRange.lowerBound < data.count {
            let first = data[byteRange.lowerBound]
            if first == UInt8(ascii: "|") || first == UInt8(ascii: ">") {
                return .block
            }
        }

        // Quoted scalars: delimiter byte is immediately before the range.
        let prevIdx = byteRange.lowerBound - 1
        if prevIdx >= 0, prevIdx < data.count {
            let prev = data[prevIdx]
            if prev == UInt8(ascii: "'") { return .singleQuoted }
            if prev == UInt8(ascii: "\"") { return .doubleQuoted }
        }

        return .plain
    }

    // MARK: - Key indent derivation

    /// Return the number of leading spaces on the line that contains the key
    /// associated with `byteRange`.
    ///
    /// For all scalar kinds the key line is the line immediately preceding the
    /// value (or the same line for flow scalars). We locate the key line by
    /// scanning backwards from the start of the replaced region to find the
    /// preceding newline, then count leading spaces.
    ///
    /// For block scalars the value starts at the `|` indicator, which is on
    /// the same line as the key (e.g. `key: |-`). We scan backwards from the
    /// `|` to find the start of that line.
    static func yamlKeyIndent(
        in data: Data,
        byteRange: Range<Int>,
        kind: YAMLScalarKind
    ) -> Int {
        // Find the start of the line containing the key (or the indicator for blocks).
        // Start scanning backwards from byteRange.lowerBound.
        let searchFrom: Int
        switch kind {
        case .block:
            // The indicator is on the key line; search backward from it.
            searchFrom = byteRange.lowerBound
        case .plain:
            searchFrom = byteRange.lowerBound
        case .singleQuoted, .doubleQuoted:
            // Delimiter byte is at byteRange.lowerBound - 1; key line starts further back.
            searchFrom = max(0, byteRange.lowerBound - 1)
        }

        // Scan backwards to find the preceding newline (or start of data).
        var lineStart = 0
        for i in stride(from: searchFrom - 1, through: 0, by: -1) {
            if i < data.count, data[i] == UInt8(ascii: "\n") {
                lineStart = i + 1
                break
            }
        }

        // Count leading spaces on this line.
        var indent = 0
        var pos = lineStart
        while pos < data.count, data[pos] == UInt8(ascii: " ") {
            indent += 1
            pos += 1
        }
        return indent
    }

    // MARK: - Replaced region computation

    /// Return the byte region of `originalData` that the splice will overwrite.
    ///
    /// - For **plain** scalars: the region is `byteRange` itself (no delimiter bytes).
    /// - For **quoted** scalars: the region extends 1 byte on each side to include
    ///   the opening and closing delimiter characters.
    /// - For **block** scalars: the region is `byteRange` itself (the full block
    ///   node including indicator and content lines is already inside the range).
    static func yamlReplacedRegion(
        byteRange: Range<Int>,
        kind: YAMLScalarKind
    ) -> Range<Int> {
        switch kind {
        case .plain, .block:
            return byteRange
        case .singleQuoted, .doubleQuoted:
            let lower = max(0, byteRange.lowerBound - 1)
            let upper = byteRange.upperBound + 1
            return lower..<upper
        }
    }

    // MARK: - New token encoding

    /// Produce the complete new YAML token (inline or block) to splice in.
    ///
    /// Decision tree (PRD F8 binding):
    /// 1. Original was a block scalar → always produce `|-` block.
    /// 2. New text is multi-line → produce `|-` block regardless of original style.
    /// 3. Single-line: keep original style with re-escaping and possible promotion.
    static func yamlNewToken(
        editedText: String,
        kind: YAMLScalarKind,
        keyIndent: Int
    ) -> String {
        let contentIndent = keyIndent + 2
        let isMultiLine = editedText.contains("\n")

        // Block scalars always stay block (PRD: preserve block style).
        if kind == .block {
            return yamlBlockToken(text: editedText, contentIndent: contentIndent)
        }

        // Flow/plain/quoted + multi-line → convert to |- block.
        if isMultiLine {
            return yamlBlockToken(text: editedText, contentIndent: contentIndent)
        }

        // Single-line: apply per-style rules.
        switch kind {
        case .plain:
            return yamlPlainOrPromoted(editedText)
        case .singleQuoted:
            return yamlSingleQuotedOrPromoted(editedText)
        case .doubleQuoted:
            return "\"\(yamlDoubleQuoteBody(editedText))\""
        case .block:
            // Unreachable: handled above.
            return yamlBlockToken(text: editedText, contentIndent: contentIndent)
        }
    }

    // MARK: - Block scalar encoding

    /// Produce a `|-` block scalar token for `text` with `contentIndent` spaces
    /// before each content line.
    ///
    /// Uses the strip chomping indicator (`-`) so the decoded value matches
    /// `text` exactly without an appended trailing newline. Each line of `text`
    /// is indented to `contentIndent` spaces. The indicator line is just `|-`
    /// (no newline character is prepended; the caller's key line already ends
    /// with a space before this token).
    ///
    /// Note: for a block scalar replacement the replaced region IS the old block
    /// scalar node (which started with `|`). So this token replaces it in-place.
    /// For a flow/plain→block conversion the replaced region is the old scalar
    /// token; the key line's `: ` remains and the new token `|-\n…` follows it.
    private static func yamlBlockToken(text: String, contentIndent: Int) -> String {
        let indent = String(repeating: " ", count: contentIndent)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result = "|-\n"
        for (i, line) in lines.enumerated() {
            result += indent + line
            if i < lines.count - 1 {
                result += "\n"
            }
        }
        return result
    }

    // MARK: - Plain scalar: keep or promote to double-quoted

    /// Return a plain scalar token for `text`, promoting to `"…"` when `text`
    /// contains characters that YAML would misinterpret in plain context.
    ///
    /// YAML plain scalars cannot safely start with or contain certain sequences
    /// without being reinterpreted as structure:
    ///   • Characters that trigger special parsing when leading: `*`, `&`, `!`,
    ///     `{`, `[`, `|`, `>`, `'`, `"`, `%`, `@`, `` ` ``
    ///   • Inline sequences that break plain parsing: `: ` (mapping), ` #` (comment)
    ///   • Leading/trailing whitespace
    ///   • YAML core-schema keywords decoded as non-string: `null`, `~`,
    ///     `true`, `false`, `yes`, `no`, `on`, `off`
    ///   • Numeric-looking values (would decode as int/float/bool)
    ///
    /// When any condition applies, the text is wrapped in `"…"` with YAML
    /// double-quote escape rules applied.
    static func yamlPlainOrPromoted(_ text: String) -> String {
        if needsDoubleQuoting(text) {
            return "\"\(yamlDoubleQuoteBody(text))\""
        }
        return text
    }

    /// Whether `text` must be double-quoted to round-trip correctly as a YAML
    /// string scalar (i.e. will not be mis-decoded as null/bool/int/float or
    /// cause a parse error in plain context).
    static func needsDoubleQuoting(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        // YAML core-schema keywords that decode to non-string in plain context.
        let reservedKeywords: Set<String> = [
            "null", "~", "true", "false", "yes", "no", "on", "off",
            "True", "False", "Yes", "No", "On", "Off",
            "TRUE", "FALSE", "YES", "NO", "ON", "OFF",
            ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF",
            "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN",
        ]
        if reservedKeywords.contains(text) { return true }

        // Purely numeric values would decode as int or float.
        if isYAMLNumeric(text) { return true }

        let first = text.unicodeScalars.first!.value

        // Characters that are special as the leading byte of a plain scalar.
        let specialLeaders: Set<UInt32> = [
            0x2A,  // *  (alias indicator)
            0x26,  // &  (anchor indicator)
            0x21,  // !  (tag indicator)
            0x7B,  // {  (flow mapping start)
            0x5B,  // [  (flow sequence start)
            0x7C,  // |  (literal block scalar)
            0x3E,  // >  (folded block scalar)
            0x27,  // '  (single-quote — starts a quoted scalar)
            0x22,  // "  (double-quote — starts a quoted scalar)
            0x25,  // %  (directive indicator)
            0x40,  // @  (reserved)
            0x60,  // `  (reserved)
            0x2D,  // -  (only special when "- " or "---")
            0x3F,  // ?  (only special when "? " in a mapping)
            0x3A,  // :  (only special when ": ")
            0x23,  // #  (comment — only special when preceded by space, but
            //     leading is also ambiguous in some parsers)
        ]
        if specialLeaders.contains(first) {
            // For -, ?, : only promote when followed by space; others always.
            switch first {
            case 0x2D:  // - followed by space = block sequence entry
                if text.hasPrefix("- ") || text == "-" { return true }
            case 0x3F:  // ? followed by space = explicit mapping key
                if text.hasPrefix("? ") || text == "?" { return true }
            case 0x3A:  // : followed by space = value indicator
                if text.hasPrefix(": ") || text == ":" { return true }
            default:
                return true
            }
        }

        // Inline sequences that break plain scalars mid-value.
        if text.contains(": ") { return true }  // mapping separator
        if text.contains(" #") { return true }  // inline comment

        // Leading/trailing whitespace is invalid in plain scalars.
        if text.first?.isWhitespace == true || text.last?.isWhitespace == true {
            return true
        }

        return false
    }

    /// Heuristic: return true if `text` would be decoded as a YAML numeric.
    ///
    /// Covers: decimal integers, hex (0x…), octal (0o…), floats (…e…, …E…, ….),
    /// and YAML special floats handled separately in `needsDoubleQuoting`.
    private static func isYAMLNumeric(_ text: String) -> Bool {
        // Simple test: try Int64 and Double parsing on the raw text.
        // For hex/octal prefixes tree-sitter-yaml resolves them as integers.
        if Int64(text) != nil { return true }
        if text.hasPrefix("0x") || text.hasPrefix("0X"),
            Int64(text.dropFirst(2), radix: 16) != nil
        {
            return true
        }
        if text.hasPrefix("0o") || text.hasPrefix("0O"),
            Int64(text.dropFirst(2), radix: 8) != nil
        {
            return true
        }
        if Double(text) != nil, text.contains(".") || text.contains("e") || text.contains("E") {
            return true
        }
        return false
    }

    // MARK: - Single-quoted scalar: keep or promote

    /// Return a single-quoted `'…'` token for `text`, promoting to `"…"` when
    /// `text` contains a single-quote character (which cannot safely appear
    /// inside `'…'` even with the `''` escape — the splice may introduce
    /// parsing ambiguity). Promotes also for multi-line text (unreachable here
    /// because multi-line is handled before this call, but defensive).
    static func yamlSingleQuotedOrPromoted(_ text: String) -> String {
        // Single-quoted strings cannot contain a single-quote without special
        // handling (YAML 1.2 §7.3.3 uses '' to represent '). We promote to
        // double-quoted for simplicity and correctness.
        if text.unicodeScalars.contains(where: { $0.value == 0x27 }) {
            return "\"\(yamlDoubleQuoteBody(text))\""
        }
        return "'\(text)'"
    }

    // MARK: - Double-quoted scalar body encoding

    /// Encode `text` as the body of a YAML double-quoted scalar — the bytes
    /// between the surrounding double-quote characters.
    ///
    /// YAML double-quoted escape rules (YAML 1.2 §7.3.1):
    /// - `\` → `\\`
    /// - `"` → `\"`
    /// - `\0` (null)  → `\0`
    /// - `\a` (0x07)  → `\a`
    /// - `\b` (0x08)  → `\b`
    /// - `\t` (0x09)  → `\t`
    /// - `\n` (0x0A)  → `\n`
    /// - `\v` (0x0B)  → `\v`
    /// - `\f` (0x0C)  → `\f`
    /// - `\r` (0x0D)  → `\r`
    /// - `\e` (0x1B)  → `\e`
    /// - Other control characters (U+0000–U+001F, U+007F, U+0085, U+2028,
    ///   U+2029) → `\uXXXX` or `\UXXXXXXXX`
    ///
    /// Reference: YAML 1.2 Specification §7.3.1 "Double Quoted Style"
    /// https://yaml.org/spec/1.2-old/spec.html#id2786942
    static func yamlDoubleQuoteBody(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00: result += "\\0"
            case 0x07: result += "\\a"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0B: result += "\\v"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x1B: result += "\\e"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x85: result += "\\N"  // NEXT LINE
            case 0xA0: result += "\\_"  // NO-BREAK SPACE
            case 0x2028: result += "\\L"  // LINE SEPARATOR
            case 0x2029: result += "\\P"  // PARAGRAPH SEPARATOR
            case 0x01..<0x07, 0x0E..<0x1B, 0x1C..<0x20, 0x7F:
                // Other control characters: encode as \uXXXX (4 hex digits).
                result += String(format: "\\u%04X", scalar.value)
            case 0x80..<0x85, 0x86..<0xA0, 0xD800..<0xE000, 0xFFFE...0xFFFF:
                // BMP non-characters and surrogates: \uXXXX
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Validation (3): YAML field re-extraction

    /// Parse `jsonpath` and evaluate it against `tree`, returning the decoded
    /// string value of the first match, or `nil` if the path resolves to a
    /// non-string or matches nothing.
    ///
    /// Mirrors `reExtractJSONField` in SpanSplicer.swift and
    /// `reExtractTOMLField` in SpanSplicer+TOML.swift, for YAML.
    private static func reExtractYAMLField(from tree: TreeValue, jsonpath: String) -> String? {
        guard let expr = try? JSONPathExpression(parsing: jsonpath) else { return nil }
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first else { return nil }
        if case .string(let decoded) = value { return decoded }
        return nil
    }
}
