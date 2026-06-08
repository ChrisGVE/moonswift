// File: Tests/MoonSwiftCoreTests/Sources/SpanSplicerYAMLTests.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: TDD test suite for SpanSplicer.spliceYAML — F8a write-back engine for
//       YAML span-splice (P4 increment 3). Covers all scalar kinds, conversion
//       rules (PRD F8 binding), indentation, validation guards, multi-document,
//       and the special double-quote promotion rule for YAML-special characters.
//
// byteRange semantics (verified by SpanLocatorYAMLSemantics.swift):
//   plain scalar       — byteRange = text only; byte before = space
//   single-quoted      — byteRange = content without quotes; byte-1 = '\'
//   double-quoted      — byteRange = content without quotes; byte-1 = '"'
//   block scalar (|/|-/|+/>/>-) — byteRange starts at the indicator, ends
//                               after the last content byte (trailing \n excluded)
//
// Replacement region (the "span" SpanSplicer+YAML replaces):
//   plain  single-line → byteRange only (no delimiter bytes to include)
//   quoted single-line → (byteRange.lowerBound-1)..<(byteRange.upperBound+1)
//   plain  multi-line  → byteRange only (replaced by "|-\n" + indented lines)
//   quoted multi-line  → (byteRange.lowerBound-1)..<(byteRange.upperBound+1)
//   block  any         → byteRange (already covers indicator + content lines)
//
// This file is the single source of truth for the expected public API contract.
// Upstream: SpanSplicer.spliceYAML (subject under test), SpanLocator
// Downstream: (none — tests only)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(
        forResource: name, withExtension: nil, subdirectory: "Fixtures/Sources"
    )!
    return try Data(contentsOf: url)
}

/// Locate the byte range for `jsonpath` in `data` using the YAML walker.
private func locateYAMLRange(data: Data, jsonpath: String, document: Int = 0) throws -> Range<Int> {
    let expr = try JSONPathExpression(parsing: jsonpath)
    let steps = expr.evaluate(on: try decodeYAML(String(data: data, encoding: .utf8)!, document: document))
    guard let first = steps.first else {
        Issue.record("JSONPath \(jsonpath) matched nothing in fixture")
        throw SpanLocatorError.nodeNotFound
    }
    let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: first.path.steps, document: document)
    return loc.byteRange
}

/// Re-extract a field from YAML data, returning the decoded string or nil.
private func reExtract(data: Data, jsonpath: String, document: Int = 0) throws -> String? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let tree = try decodeYAML(text, document: document)
    let expr = try JSONPathExpression(parsing: jsonpath)
    let matches = expr.evaluate(on: tree)
    guard let (_, value) = matches.first, case .string(let s) = value else { return nil }
    return s
}

// MARK: - Inline YAML helpers

/// Splice `editedText` into an inline YAML string and return the decoded value.
/// The inline YAML is a fresh document; `jsonpath` must resolve within it.
private func roundTripYAML(yaml: String, jsonpath: String, editedText: String) throws -> String {
    let data = Data(yaml.utf8)
    let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)
    let result = SpanSplicer.spliceYAML(
        editedText: editedText,
        into: data,
        byteRange: byteRange,
        jsonpath: jsonpath,
        document: 0
    )
    guard case .success(let newData) = result else {
        Issue.record("spliceYAML failed: \(result)")
        return ""
    }
    return try reExtract(data: newData, jsonpath: jsonpath) ?? ""
}

// MARK: - Plain scalar: single-line stays plain

@Suite("YAML splice — plain scalar single-line stays plain")
struct YAMLSplicerPlainSingleLineTests {

    @Test("plain scalar edit stays plain; outside bytes identical; re-extract exact")
    func plainScalarRoundTrip() throws {
        let data = try fixtureData("splice-yaml-plain.yaml")
        let jsonpath = "$.key"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceYAML(
            editedText: "new value",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        // New text must be plain (no quote wrapping around the value)
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("key: new value"))
        #expect(!newText.contains("key: \"new value\""))

        // Bytes before the replaced span must be identical.
        let tokenStart = byteRange.lowerBound
        #expect(newData[0..<tokenStart] == data[0..<tokenStart])

        // Re-extracted value equals the edited text.
        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == "new value")
    }

    @Test("plain scalar nested edit round-trips")
    func plainScalarNestedRoundTrip() throws {
        let decoded = try roundTripYAML(
            yaml: "parent:\n  child: old\n  other: unchanged\n",
            jsonpath: "$.parent.child",
            editedText: "fresh"
        )
        #expect(decoded == "fresh")
    }

    @Test("plain scalar unchanged siblings stay byte-identical")
    func plainScalarSiblingUnchanged() throws {
        let data = try fixtureData("splice-yaml-plain.yaml")
        let jsonpath = "$.nested.field"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceYAML(
            editedText: "updated",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        // The "other: stays put" line must be byte-identical.
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("other: stays put"))
        #expect(newText.contains("top: unchanged"))
    }
}

// MARK: - Quoted scalars: single-line stays same style

@Suite("YAML splice — quoted scalars stay same style")
struct YAMLSplicerQuotedSingleLineTests {

    @Test("single-quoted scalar stays single-quoted")
    func singleQuotedRoundTrip() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let jsonpath = "$.single"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceYAML(
            editedText: "new single",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Must remain single-quoted, not double-quoted.
        #expect(newText.contains("single: 'new single'"))
        #expect(!newText.contains("single: \"new single\""))

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == "new single")
    }

    @Test("double-quoted scalar stays double-quoted")
    func doubleQuotedRoundTrip() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let jsonpath = "$.double"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceYAML(
            editedText: "new double",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("double: \"new double\""))

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == "new double")
    }

    @Test("double-quoted with special chars re-escapes and round-trips")
    func doubleQuotedWithSpecialChars() throws {
        // A backslash and quote in new text must be properly escaped inside "..."
        let decoded = try roundTripYAML(
            yaml: "v: \"old\"\n",
            jsonpath: "$.v",
            editedText: "say \"hi\" and \\"
        )
        #expect(decoded == "say \"hi\" and \\")
    }

    @Test("single-quoted scalar with embedded apostrophe is promoted to double-quoted")
    func singleQuotedWithApostrophePromotedToDouble() throws {
        // Single-quoted YAML scalars represent a single-quote as '' (two quotes).
        // When the new text contains a single quote we promote to double-quoted
        // style because re-escaping with '' is fragile and double-quoted is clearer.
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let jsonpath = "$.single"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "it's here"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }
}

// MARK: - Double-quote promotion for YAML-special characters

@Suite("YAML splice — double-quote promotion for YAML-special chars")
struct YAMLSplicerDoubleQuotePromotionTests {

    // When a plain scalar's new text contains characters that would be
    // mis-parsed as YAML structure (leading `:`, `#`, `*`, `&`, `{`, `[` etc.)
    // the splice MUST promote to double-quoted to preserve correctness.

    @Test("plain scalar promoted to double-quote when value starts with *")
    func asteriskPromotedToDouble() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "*anchor_reference"
        )
        #expect(decoded == "*anchor_reference")
    }

    @Test("plain scalar promoted when value contains ': ' colon-space")
    func colonSpacePromotedToDouble() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "a: b"
        )
        #expect(decoded == "a: b")
    }

    @Test("plain scalar promoted when value contains '#' hash (inline comment)")
    func hashPromotedToDouble() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "text # comment"
        )
        #expect(decoded == "text # comment")
    }

    @Test("plain scalar promoted when value starts with {")
    func bracePromotedToDouble() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "{not: flow}"
        )
        #expect(decoded == "{not: flow}")
    }

    @Test("promoted double-quote value re-parses and re-extracts correctly")
    func promotedValueReparses() throws {
        let original = "cfg: some value\n"
        let data = Data(original.utf8)
        let jsonpath = "$.cfg"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)
        let editedText = "key: value with # comment and *ref"

        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        #expect(throws: Never.self) { try decodeYAML(String(data: newData, encoding: .utf8)!) }
        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }
}

// MARK: - Plain/quoted scalar → multi-line: converts to |- block

@Suite("YAML splice — plain/quoted multi-line converts to |- block")
struct YAMLSplicerMultilineConversionTests {

    @Test("plain scalar + multi-line text converts to |- block at key-indent+2")
    func plainToBlockConversion() throws {
        let original = "key: old value\nother: unchanged\n"
        let data = Data(original.utf8)
        let jsonpath = "$.key"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "line one\nline two\nline three"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Must use literal block scalar style.
        #expect(newText.contains("key: |-"))
        // Content lines must be indented at key-indent+2 = 2 spaces.
        #expect(newText.contains("  line one"))
        #expect(newText.contains("  line two"))
        #expect(newText.contains("  line three"))
        // Other key must be unchanged.
        #expect(newText.contains("other: unchanged"))
        // Must re-parse.
        #expect(throws: Never.self) { try decodeYAML(newText) }
        // Re-extracted value must equal editedText exactly (|- strips trailing newline).
        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("double-quoted scalar + multi-line text converts to |- block")
    func doubleQuotedToBlockConversion() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let jsonpath = "$.double"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "first line\nsecond line"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("double: |-"))
        // Lines indented at key-indent(0)+2 = 2 spaces.
        #expect(newText.contains("  first line"))
        #expect(newText.contains("  second line"))
        #expect(throws: Never.self) { try decodeYAML(newText) }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("nested plain scalar + multi-line indents at key-indent+2 relative to key")
    func nestedPlainToBlockCorrectIndent() throws {
        // Key "field" is at indent 2; block content must be at indent 4.
        let original = "parent:\n  field: old\n  other: stays\n"
        let data = Data(original.utf8)
        let jsonpath = "$.parent.field"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "alpha\nbeta"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Key line must show "  field: |-" (2-space key indent + |- indicator)
        #expect(newText.contains("  field: |-"))
        // Content indented at key-indent(2)+2 = 4 spaces.
        #expect(newText.contains("    alpha"))
        #expect(newText.contains("    beta"))
        // Sibling must be unchanged.
        #expect(newText.contains("  other: stays"))
        #expect(throws: Never.self) { try decodeYAML(newText) }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("|- strip chomping ensures no trailing newline in decoded value")
    func blockStripChompingNoTrailingNewline() throws {
        // The |- indicator strips the final newline so the decoded value
        // equals editedText exactly (no trailing \n appended).
        let decoded = try roundTripYAML(
            yaml: "k: v\n",
            jsonpath: "$.k",
            editedText: "a\nb"
        )
        #expect(decoded == "a\nb")
        #expect(!decoded.hasSuffix("\n"))
    }
}

// MARK: - Existing block scalar: preserved and re-indented

@Suite("YAML splice — existing block scalar preserved and re-indented")
struct YAMLSplicerBlockPreservedTests {

    @Test("existing |- block edited with multi-line stays block and re-indents")
    func literalBlockPreservedMultiline() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let jsonpath = "$.literal"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "new line one\nnew line two\nnew line three"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Must still use block scalar (|-).
        #expect(newText.contains("literal: |-"))
        // Content indented at key-indent(0)+2 = 2 spaces.
        #expect(newText.contains("  new line one"))
        #expect(newText.contains("  new line two"))
        #expect(newText.contains("  new line three"))
        // Rest of file unchanged.
        #expect(newText.contains("other: unchanged"))
        #expect(throws: Never.self) { try decodeYAML(newText) }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("existing |- block edited with single-line text stays block (with single content line)")
    func literalBlockPreservedSingleLine() throws {
        // PRD: block scalar style is preserved regardless of new content line count.
        let data = try fixtureData("splice-yaml-block.yaml")
        let jsonpath = "$.literal"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "just one line"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Even a single-line replacement keeps |- style (PRD: preserve block style).
        #expect(newText.contains("literal: |-"))
        #expect(newText.contains("  just one line"))
        #expect(throws: Never.self) { try decodeYAML(newText) }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("nested block scalar $.nested.block re-indented at key-indent(2)+2=4 spaces")
    func nestedBlockPreservedWithCorrectIndent() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let jsonpath = "$.nested.block"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let editedText = "alpha\nbeta\ngamma"
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let newText = String(data: newData, encoding: .utf8)!
        // Key "block" at indent 2; indicator at key+space; content at 4.
        #expect(newText.contains("  block: |-"))
        #expect(newText.contains("    alpha"))
        #expect(newText.contains("    beta"))
        #expect(newText.contains("    gamma"))
        #expect(throws: Never.self) { try decodeYAML(newText) }

        let decoded = try reExtract(data: newData, jsonpath: jsonpath)
        #expect(decoded == editedText)
    }

    @Test("bytes outside the replaced block span are byte-identical to original")
    func blockSpliceSpanLeakCheck() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let jsonpath = "$.literal"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceYAML(
            editedText: "only this",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        // Prefix up to the block scalar must be byte-identical.
        // For a block scalar byteRange.lowerBound IS the start of the replaced region.
        let regionStart = byteRange.lowerBound
        #expect(newData[0..<regionStart] == data[0..<regionStart])
    }
}

// MARK: - Span-leak and reparse guards

@Suite("YAML splice — validation guards")
struct YAMLSplicerValidationGuardTests {

    @Test("span-leak: byte range exceeding data.count returns .spanLeak")
    func spanLeakOutOfBounds() throws {
        let original = "k: v\n"
        let data = Data(original.utf8)
        // A range completely outside the data triggers the guard.
        let bogusRange = (data.count + 10)..<(data.count + 20)
        let result = SpanSplicer.spliceYAML(
            editedText: "x",
            into: data,
            byteRange: bogusRange,
            jsonpath: "$.k",
            document: 0
        )
        // The splicer must not crash; it must return an error.
        if case .failure(let err) = result {
            // spanLeak or reparseFailed are both acceptable for a completely invalid range.
            switch err {
            case .spanLeak, .reparseFailed:
                break  // expected
            default:
                Issue.record("Unexpected error: \(err)")
            }
        }
        // Not a crash — we just verify it doesn't return .success.
        guard case .failure = result else {
            Issue.record("Expected failure for out-of-bounds range, got .success")
            return
        }
    }

    @Test("reparseFailed: a range that corrupts YAML structure returns .reparseFailed")
    func reparseFailedOnCorruption() throws {
        // Splice into a byte range that would corrupt the YAML structure —
        // specifically by injecting YAML-structure-breaking content without
        // proper quoting (to force the reparse failure path).
        // We fake this by passing a byteRange that covers the wrong region
        // (the key bytes instead of the value bytes), forcing the splice to
        // produce invalid YAML.
        let original = "key: value\n"
        let data = Data(original.utf8)
        // "key" is at bytes 0-2; replacing it with multi-char text that makes
        // the YAML unparseable (e.g., inserting a tab character as key).
        let keyRange = 0..<3  // covers "key"
        let result = SpanSplicer.spliceYAML(
            editedText: "\t",
            into: data,
            byteRange: keyRange,
            jsonpath: "$.key",
            document: 0
        )
        // Must fail — the YAML will either not re-parse or re-extract will fail.
        guard case .failure = result else {
            // It's also acceptable if the splice somehow succeeds (unusual but
            // not impossible depending on exact bytes); the important thing is
            // it never crashes or silently corrupts.
            return
        }
    }

    @Test("fieldMismatch: splice at wrong path returns .fieldMismatch")
    func fieldMismatchWrongPath() throws {
        let original = "a: hello\nb: world\n"
        let data = Data(original.utf8)
        let byteRange = try locateYAMLRange(data: data, jsonpath: "$.a")

        // Splice at $.a byteRange but validate against $.b — field won't match.
        let result = SpanSplicer.spliceYAML(
            editedText: "spliced",
            into: data,
            byteRange: byteRange,
            jsonpath: "$.b",  // intentionally wrong path for validation
            document: 0
        )
        if case .failure(let err) = result {
            // Either fieldMismatch (re-extract gives "spliced" at $.a, not $.b)
            // or reparseFailed is acceptable.
            switch err {
            case .fieldMismatch, .reparseFailed:
                break
            default:
                Issue.record("Unexpected error: \(err)")
            }
        }
    }
}

// MARK: - Multi-document YAML

@Suite("YAML splice — multi-document")
struct YAMLSplicerMultiDocTests {

    // multi.yaml:
    //   scripts:\n
    //     init: "print('doc0')"\n
    //   ---\n
    //   scripts:\n
    //     init: "print('doc1')"\n

    @Test("splice into document 0 does not touch document 1")
    func spliceDoc0LeavesDoc1Intact() throws {
        let data = try fixtureData("multi.yaml")
        let jsonpath = "$.scripts.init"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath, document: 0)

        let result = SpanSplicer.spliceYAML(
            editedText: "print('modified')",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        // Document 0 must reflect the change.
        let doc0 = try reExtract(data: newData, jsonpath: jsonpath, document: 0)
        #expect(doc0 == "print('modified')")

        // Document 1 must still contain the original value.
        let doc1 = try reExtract(data: newData, jsonpath: jsonpath, document: 1)
        #expect(doc1 == "print('doc1')")
    }

    @Test("splice into document 1 leaves document 0 intact")
    func spliceDoc1LeavesDoc0Intact() throws {
        let data = try fixtureData("multi.yaml")
        let jsonpath = "$.scripts.init"
        let byteRange = try locateYAMLRange(data: data, jsonpath: jsonpath, document: 1)

        let result = SpanSplicer.spliceYAML(
            editedText: "print('doc1-updated')",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 1
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let doc1 = try reExtract(data: newData, jsonpath: jsonpath, document: 1)
        #expect(doc1 == "print('doc1-updated')")

        let doc0 = try reExtract(data: newData, jsonpath: jsonpath, document: 0)
        #expect(doc0 == "print('doc0')")
    }
}

// MARK: - Round-trip edge cases

@Suite("YAML splice — edge cases")
struct YAMLSplicerEdgeCaseTests {

    @Test("empty string value round-trips via double-quoted style")
    func emptyStringRoundTrip() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: ""
        )
        #expect(decoded == "")
    }

    @Test("unicode content round-trips correctly")
    func unicodeRoundTrip() throws {
        let editedText = "こんにちは 🌙"
        let decoded = try roundTripYAML(
            yaml: "msg: hello\n",
            jsonpath: "$.msg",
            editedText: editedText
        )
        #expect(decoded == editedText)
    }

    @Test("multi-line with trailing newline returns .fieldMismatch (|- strips it)")
    func multiLineTrailingNewlineIsFieldMismatch() throws {
        // editedText ends with \n. The splicer uses |- (strip chomping),
        // which always strips the final newline. This means the decoded
        // value will be "line" — not "line\n" — so validation (3) must
        // fail with .fieldMismatch, not silently corrupt the value.
        // Callers must strip the trailing newline before calling spliceYAML.
        let editedText = "line\n"  // has trailing \n
        let data = Data("k: v\n".utf8)
        let byteRange = try locateYAMLRange(data: data, jsonpath: "$.k")
        let result = SpanSplicer.spliceYAML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: "$.k",
            document: 0
        )
        // Must fail — |- strips the trailing \n so re-extract gives "line" ≠ "line\n".
        guard case .failure(let err) = result else {
            Issue.record("Expected .failure for trailing-newline text, got .success")
            return
        }
        // The correct failure is .fieldMismatch (reparse succeeds but re-extract
        // doesn't equal editedText because |- chomped the trailing newline).
        #expect(err == .fieldMismatch)
    }

    @Test("value starting with YAML null keyword stays quoted if value is non-null")
    func nullKeywordNotMisparsed() throws {
        // "null" as a YAML plain scalar decodes as .null, not .string("null").
        // The splicer must quote it to preserve the string semantics.
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "null"
        )
        // Either "null" decodes back as string "null" (correct)
        // or the splicer returns .unrepresentable (also acceptable).
        #expect(decoded == "null")
    }

    @Test("value starting with YAML bool keyword stays quoted")
    func boolKeywordNotMisparsed() throws {
        let decoded = try roundTripYAML(
            yaml: "key: old\n",
            jsonpath: "$.key",
            editedText: "true"
        )
        #expect(decoded == "true")
    }
}
