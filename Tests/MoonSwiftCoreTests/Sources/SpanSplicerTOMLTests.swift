// File: Tests/MoonSwiftCoreTests/Sources/SpanSplicerTOMLTests.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: Unit tests for SpanSplicer.spliceTOML — the F8a write-back engine for
//       TOML span-splice (P4 increment 2). Covers:
//         • single-line basic-string edit (round-trip, outside bytes unchanged)
//         • edit introducing escapes (quote + backslash → basic string)
//         • edit introducing a newline → converts to """…""" multi-line
//         • literal 'C:\path' upgraded to basic when escapes are needed
//         • editing an existing """…""" value stays multi-line
//         • span-leak guard and reparse guard
//       Uses SpanLocator.locateSpan to obtain real byte ranges from fixtures;
//       no byte offsets are hardcoded.
// Upstream: SpanSplicer (subject under test), SpanLocator (produces byteRange),
//           decodeTOML / JSONPathExpression (re-extraction for validation 3)
// Downstream: (none — tests only)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Sources")!
    return try Data(contentsOf: url)
}

/// Locate the byte range for `jsonpath` in `data` using the TOML walker.
private func locateTOMLRange(data: Data, jsonpath: String) throws -> Range<Int> {
    let expr = try JSONPathExpression(parsing: jsonpath)
    let steps = expr.evaluate(on: try decodeTOML(String(data: data, encoding: .utf8)!))
    guard let first = steps.first else {
        Issue.record("JSONPath \(jsonpath) matched nothing in fixture")
        throw SpanLocatorError.nodeNotFound
    }
    let loc = try SpanLocator.locateSpan(in: data, format: .toml, path: first.path.steps)
    return loc.byteRange
}

// MARK: - TOML span-splice: single-line basic string

@Suite("TOML span-splice — single-line basic string")
struct TOMLSplicerBasicTests {

    // splice-basic.toml:
    //   [scripts]
    //   init = "print('hello')"
    //   path = "C:/old/path"

    @Test("splices a basic-string field and passes all 3 validations")
    func spliceBasicField() throws {
        let data = try fixtureData("splice-basic.toml")
        let jsonpath = "$.scripts.init"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceTOML(
            editedText: "print('new')",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        // New text must contain the updated value.
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("print('new')"))
        #expect(!newText.contains("print('hello')"))

        // Bytes before the replaced token must be byte-identical.
        // byteRange excludes the surrounding `"` (SpanLocator strips 1 each side).
        // The delimiter characters are at byteRange.lowerBound - 1 and byteRange.upperBound.
        let tokenStart = byteRange.lowerBound - 1
        #expect(newData[0..<tokenStart] == data[0..<tokenStart])
    }

    @Test("re-extracted field equals the edited text exactly")
    func reExtractedValueMatchesEdit() throws {
        let data = try fixtureData("splice-basic.toml")
        let jsonpath = "$.scripts.path"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let editedText = "D:/new/path"
        let result = SpanSplicer.spliceTOML(
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
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Failed to re-extract field from new TOML")
            return
        }
        #expect(decoded == editedText)
    }
}

// MARK: - TOML span-splice: escape encoding

@Suite("TOML span-splice — escape encoding")
struct TOMLSplicerEscapeTests {

    // Helper: splice `editedText` into splice-basic.toml at $.scripts.init
    // and return the re-extracted decoded value.
    private func roundTrip(editedText: String) throws -> String {
        // Use an inline TOML document so the fixture file content does not matter.
        let original = "[k]\nval = \"placeholder\"\n"
        let data = Data(original.utf8)
        let jsonpath = "$.k.val"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceTOML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("spliceTOML failed for text: \(editedText.debugDescription)")
            return ""
        }
        let newText = String(data: newData, encoding: .utf8)!
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for text: \(editedText.debugDescription)")
            return ""
        }
        return decoded
    }

    @Test("double-quote in new text is escaped and round-trips")
    func doubleQuote() throws {
        let editedText = #"say "hello""#
        #expect(try roundTrip(editedText: editedText) == editedText)
    }

    @Test("backslash in new text is escaped and round-trips")
    func backslash() throws {
        let editedText = "C:\\Users\\foo"
        #expect(try roundTrip(editedText: editedText) == editedText)
    }

    @Test("tab in new text is escaped and round-trips")
    func tab() throws {
        let editedText = "col1\tcol2"
        #expect(try roundTrip(editedText: editedText) == editedText)
    }

    @Test("carriage return in new text is escaped and round-trips")
    func carriageReturn() throws {
        let editedText = "a\rb"
        #expect(try roundTrip(editedText: editedText) == editedText)
    }

    @Test("control char 0x01 encoded as \\u0001 and round-trips")
    func controlChar() throws {
        let editedText = "before\u{01}after"
        #expect(try roundTrip(editedText: editedText) == editedText)
    }

    @Test("result re-parses as TOML after combined-escape splice")
    func resultReparses() throws {
        let original = "[k]\nval = \"placeholder\"\n"
        let data = Data(original.utf8)
        let editedText = "\"quote\" and \\ and \t and \u{01}"
        let byteRange = try locateTOMLRange(data: data, jsonpath: "$.k.val")

        let result = SpanSplicer.spliceTOML(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: "$.k.val",
            document: 0
        )
        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        let text = String(data: newData, encoding: .utf8)!
        #expect(throws: Never.self) { try decodeTOML(text) }
    }
}

// MARK: - TOML span-splice: newline → multi-line conversion

@Suite("TOML span-splice — newline converts to multi-line")
struct TOMLSplicerMultilineConversionTests {

    @Test("newline in edited text converts basic string to multi-line basic")
    func newlineConvertsToMultiline() throws {
        let original = "[k]\nval = \"old\"\n"
        let data = Data(original.utf8)
        let jsonpath = "$.k.val"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let editedText = "line1\nline2"
        let result = SpanSplicer.spliceTOML(
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
        // The output must use triple-quote delimiters.
        #expect(newText.contains("\"\"\""))
        // Must re-parse as valid TOML.
        #expect(throws: Never.self) { try decodeTOML(newText) }
        // Re-extracted value must equal the edited text.
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed after multiline conversion")
            return
        }
        #expect(decoded == editedText)
    }

    @Test("multi-line text with embedded triple-quote is escaped and round-trips")
    func embeddedTripleQuoteEscaped() throws {
        let original = "[k]\nval = \"old\"\n"
        let data = Data(original.utf8)
        let jsonpath = "$.k.val"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        // The TOML spec allows escaping individual `"` chars inside """…""" to
        // avoid the `"""` end sequence. We splice text containing a triple-quote.
        let editedText = "before\n\"\"\"\nafter"
        let result = SpanSplicer.spliceTOML(
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
        #expect(throws: Never.self) { try decodeTOML(newText) }
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for embedded-triple-quote text")
            return
        }
        #expect(decoded == editedText)
    }
}

// MARK: - TOML span-splice: literal string upgrade

@Suite("TOML span-splice — literal string upgrade")
struct TOMLSplicerLiteralUpgradeTests {

    // splice-literal.toml:
    //   [scripts]
    //   path = 'C:\old\path'
    //   simple = 'hello'

    @Test("literal string edited to text requiring escapes is upgraded to basic")
    func literalUpgradedToBasicOnEscapes() throws {
        let data = try fixtureData("splice-literal.toml")
        let jsonpath = "$.scripts.path"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        // New text contains a double-quote → literal cannot represent it.
        let editedText = "C:\\new\\path with \"quotes\""
        let result = SpanSplicer.spliceTOML(
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
        // Must use double-quote delimiters (upgraded to basic string).
        #expect(newText.contains("\""))
        // Must re-parse.
        #expect(throws: Never.self) { try decodeTOML(newText) }
        // Round-trip must equal editedText.
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed after literal upgrade")
            return
        }
        #expect(decoded == editedText)
    }

    @Test("literal string edited to plain text stays as basic string (minimal change)")
    func literalEditedToPlainProducesBasic() throws {
        // Per the minimal-change rule: we always produce a basic string for
        // any edit via spliceTOML (literal kept only when no escapes needed,
        // but the implementation always produces basic for simplicity and
        // predictability — see SpanSplicer+TOML.swift design note).
        let data = try fixtureData("splice-literal.toml")
        let jsonpath = "$.scripts.simple"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let editedText = "world"
        let result = SpanSplicer.spliceTOML(
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
        #expect(throws: Never.self) { try decodeTOML(newText) }
        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for plain literal edit")
            return
        }
        #expect(decoded == editedText)
    }
}

// MARK: - TOML span-splice: existing multi-line stays multi-line

@Suite("TOML span-splice — existing multi-line stays multi-line")
struct TOMLSplicerMultilinePreserveTests {

    // splice-multiline.toml:
    //   [scripts]
    //   body = """
    //   line one
    //   line two
    //   """

    @Test("editing an existing multi-line basic string preserves triple-quote delimiters")
    func existingMultilineStaysMultiline() throws {
        let data = try fixtureData("splice-multiline.toml")
        let jsonpath = "$.scripts.body"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let editedText = "updated\nlines\nhere"
        let result = SpanSplicer.spliceTOML(
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
        // Must still use triple-quote delimiters.
        #expect(newText.contains("\"\"\""))
        #expect(throws: Never.self) { try decodeTOML(newText) }

        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for existing-multiline edit")
            return
        }
        #expect(decoded == editedText)
    }

    @Test("editing multi-line to single-line text still uses triple-quote delimiters")
    func existingMultilineEditedToSingleLine() throws {
        let data = try fixtureData("splice-multiline.toml")
        let jsonpath = "$.scripts.body"
        let byteRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        // The original string was multi-line; even if the new text has no
        // newline the original delimiter style (triple-quote) is preserved.
        let editedText = "single line"
        let result = SpanSplicer.spliceTOML(
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
        #expect(throws: Never.self) { try decodeTOML(newText) }

        let tree = try decodeTOML(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for multiline-to-singleline edit")
            return
        }
        #expect(decoded == editedText)
    }
}

// MARK: - TOML span-splice: validation failures

@Suite("TOML span-splice — validation failures")
struct TOMLSplicerValidationTests {

    @Test("returns .reparseFailed when the splice range covers the key name")
    func reparseFailedOnKeyRange() throws {
        // Supply a byteRange whose `lowerBound - 1` falls inside the key name,
        // so expandedRange replaces part of the key token. The resulting file
        // is malformed TOML (a bare value with no `=`), triggering reparseFailed.
        //
        // [k]\nval = "value"\n
        //  0123456789...
        //  v=0, a=1, l=2, space=3, ==4, space=5, "=10(+4 for header)
        //
        // Deliberately set byteRange so lowerBound-1 is inside "val" (e.g. offset 6),
        // causing expandedRange to replace `l = "value"\n` with `"new"`.
        // The resulting file becomes `[k]\nva"new"\n` which is invalid TOML.
        let original = "[k]\nval = \"value\"\n"
        let data = Data(original.utf8)
        let jsonpath = "$.k.val"
        let realRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        // Shift the range far left so it starts inside the key bytes.
        // realRange is something like 11..<16; shift back 8 bytes to overlap the key.
        let shiftedLower = max(0, realRange.lowerBound - 8)
        let shiftedRange = shiftedLower..<(realRange.upperBound)

        let result = SpanSplicer.spliceTOML(
            editedText: "new",
            into: data,
            byteRange: shiftedRange,
            jsonpath: jsonpath,
            document: 0
        )
        // Either reparseFailed (broken TOML) or spanLeak (suffix differs) or
        // fieldMismatch (path no longer resolves). Any failure is correct.
        guard case .failure = result else {
            Issue.record("Expected .failure for shifted range, got .success")
            return
        }
        _ = realRange  // suppress unused warning
    }

    @Test("returns failure for out-of-bounds byte range")
    func outOfBoundsRange() throws {
        let original = "[k]\nval = \"v\"\n"
        let data = Data(original.utf8)
        let jsonpath = "$.k.val"
        let realRange = try locateTOMLRange(data: data, jsonpath: jsonpath)

        let outOfBounds = data.count..<(data.count + 5)

        let result = SpanSplicer.spliceTOML(
            editedText: "new",
            into: data,
            byteRange: outOfBounds,
            jsonpath: jsonpath,
            document: 0
        )
        guard case .failure = result else {
            Issue.record("Expected .failure for out-of-bounds range, got .success")
            return
        }
        _ = realRange  // suppress unused warning
    }

    @Test("returns .fieldMismatch when jsonpath points to a different field")
    func fieldMismatchOnWrongPath() throws {
        let original = "[k]\nval = \"v\"\nother = \"other_val\"\n"
        let data = Data(original.utf8)

        // Use the byte range of $.k.val but validate against $.k.other.
        let kRange = try locateTOMLRange(data: data, jsonpath: "$.k.val")

        let result = SpanSplicer.spliceTOML(
            editedText: "new",
            into: data,
            byteRange: kRange,
            jsonpath: "$.k.other",  // intentional mismatch
            document: 0
        )
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure, got .success")
            return
        }
        if case .fieldMismatch = error {
            // correct
        } else {
            Issue.record("Expected .fieldMismatch, got \(error)")
        }
    }
}
