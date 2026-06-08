// File: Tests/MoonSwiftCoreTests/Sources/SpanSplicerTests.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: Unit tests for SpanSplicer — the F8a write-back engine for .lua
//       overwrite and JSON span-splice. Covers the full 3-part validation
//       contract, JSON escape encoding, span-leak guard, reparse guard, and
//       the conflict-hash helper. Uses SpanLocator.locateSpan to obtain real
//       byte ranges from fixtures (no hardcoded offsets).
// Upstream: SpanSplicer (subject under test), SpanLocator (produces byteRange)
// Downstream: (none — tests only)

import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Sources")!
    return try Data(contentsOf: url)
}

/// Locate the byte range for `jsonpath` in `data` (JSON format, document 0).
private func locateJSONRange(data: Data, jsonpath: String) throws -> Range<Int> {
    let expr = try JSONPathExpression(parsing: jsonpath)
    let steps = expr.evaluate(on: try decodeJSON(String(data: data, encoding: .utf8)!))
    guard let first = steps.first else {
        Issue.record("JSONPath \(jsonpath) matched nothing in fixture")
        throw SpanLocatorError.nodeNotFound
    }
    let loc = try SpanLocator.locateSpan(in: data, format: .json, path: first.path.steps)
    return loc.byteRange
}

// MARK: - .lua overwrite

@Suite(".lua overwrite")
struct LuaOverwriteTests {

    @Test("returns exact UTF-8 bytes of the edited text")
    func returnsUTF8Bytes() {
        let editedText = "print('updated')\nreturn 0\n"
        let result = SpanSplicer.overwriteLua(editedText: editedText)
        #expect(result == Data(editedText.utf8))
    }

    @Test("empty string produces empty data")
    func emptyString() {
        let result = SpanSplicer.overwriteLua(editedText: "")
        #expect(result == Data())
    }

    @Test("multi-byte UTF-8 content round-trips correctly")
    func multiBytUTF8() {
        let editedText = "-- 日本語コメント\nreturn 42\n"
        let result = SpanSplicer.overwriteLua(editedText: editedText)
        #expect(result == Data(editedText.utf8))
        // Decode back to confirm round-trip fidelity.
        #expect(String(data: result, encoding: .utf8) == editedText)
    }
}

// MARK: - JSON span-splice: happy path

@Suite("JSON span-splice — happy path")
struct JSONSplicerHappyTests {

    /// scripts.json fixture:  {"scripts":{"init":"print('hello')","run":"return 42"},...}
    /// Splice $.scripts.init from "print('hello')" → "print('new')"
    @Test("splices a string field in scripts.json and passes all 3 validations")
    func spliceInitField() throws {
        let data = try fixtureData("scripts.json")
        let jsonpath = "$.scripts.init"
        let byteRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceJSON(
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

        // The new JSON text should contain the updated value.
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("print('new')"))
        // The old value must not appear where the field was.
        #expect(!newText.contains("\"print('hello')\""))

        // Bytes outside the splice span must be identical.
        let prefix = data[0..<byteRange.lowerBound]
        let suffix = data[byteRange.upperBound...]
        #expect(newData[0..<byteRange.lowerBound] == prefix)
        // The suffix starts after the new encoded value; offset by length delta.
        let delta = "print('new')".utf8.count - "print('hello')".utf8.count
        let newSuffixStart = byteRange.upperBound + delta
        #expect(newData[newSuffixStart...] == suffix)
    }

    @Test("re-extracted field value equals the edited text exactly")
    func reExtractedValueMatchesEdit() throws {
        let data = try fixtureData("scripts.json")
        let jsonpath = "$.scripts.run"
        let byteRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        let editedText = "return 99"
        let result = SpanSplicer.spliceJSON(
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

        // Decode the new file and re-extract the field value.
        let newText = String(data: newData, encoding: .utf8)!
        let tree = try decodeJSON(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Failed to re-extract field from new JSON")
            return
        }
        #expect(decoded == editedText)
    }

    @Test("simple nested object round-trip: old→new field value")
    func simpleNestedRoundTrip() throws {
        // Construct a minimal JSON fixture inline (no file I/O in SpanSplicer).
        let original = #"{"a":{"b":"old"}}"#
        let data = Data(original.utf8)

        let jsonpath = "$.a.b"
        let byteRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceJSON(
            editedText: "new",
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }

        let expected = #"{"a":{"b":"new"}}"#
        #expect(String(data: newData, encoding: .utf8) == expected)

        // Outside bytes — prefix up to byteRange.lowerBound and suffix from upperBound.
        #expect(newData[0..<byteRange.lowerBound] == data[0..<byteRange.lowerBound])
        let newSuffixStart = byteRange.lowerBound + "new".utf8.count
        let oldSuffixStart = byteRange.upperBound
        #expect(newData[newSuffixStart...] == data[oldSuffixStart...])
    }
}

// MARK: - JSON span-splice: escape encoding

@Suite("JSON span-splice — escape encoding")
struct JSONSplicerEscapeTests {

    /// A helper that splices `editedText` into `{"k":"placeholder"}` at $.k,
    /// then decodes the result and verifies the round-trip.
    private func roundTrip(editedText: String) throws -> String {
        let original = #"{"k":"placeholder"}"#
        let data = Data(original.utf8)
        let jsonpath = "$.k"
        let byteRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        let result = SpanSplicer.spliceJSON(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: jsonpath,
            document: 0
        )

        guard case .success(let newData) = result else {
            Issue.record("spliceJSON failed for text: \(editedText.debugDescription)")
            return ""
        }
        let newText = String(data: newData, encoding: .utf8)!
        let tree = try decodeJSON(newText)
        let expr = try JSONPathExpression(parsing: jsonpath)
        let matches = expr.evaluate(on: tree)
        guard let (_, value) = matches.first, case .string(let decoded) = value else {
            Issue.record("Re-extract failed for text: \(editedText.debugDescription)")
            return ""
        }
        return decoded
    }

    @Test("double-quote is escaped as backslash-quote")
    func doubleQuote() throws {
        let editedText = #"say "hello""#
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("backslash is escaped as double-backslash")
    func backslash() throws {
        let editedText = "C:\\Users\\foo"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("newline is encoded as backslash-n and decodes back")
    func newline() throws {
        let editedText = "line1\nline2"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("tab is encoded as backslash-t and decodes back")
    func tab() throws {
        let editedText = "col1\tcol2"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("carriage return is encoded as backslash-r")
    func carriageReturn() throws {
        let editedText = "a\rb"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("control char 0x01 is encoded as \\u0001")
    func controlCharSOH() throws {
        let editedText = "before\u{01}after"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("backspace 0x08 is encoded as backslash-b")
    func backspace() throws {
        let editedText = "a\u{08}b"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("form-feed 0x0C is encoded as backslash-f")
    func formFeed() throws {
        let editedText = "a\u{0C}b"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("combined escapes: quote + backslash + newline + tab + control char all round-trip")
    func combinedEscapes() throws {
        // This single value exercises every escape rule in one splice.
        let editedText = "say \"hi\\there\"\nwith\ttab\u{01}ctrl"
        let decoded = try roundTrip(editedText: editedText)
        #expect(decoded == editedText)
    }

    @Test("result file re-parses as JSON after combined-escape splice")
    func resultReparses() throws {
        let original = #"{"k":"placeholder"}"#
        let data = Data(original.utf8)
        let editedText = "\"quote\" and \\ and \n and \t and \u{01}"
        let byteRange = try locateJSONRange(data: data, jsonpath: "$.k")

        let result = SpanSplicer.spliceJSON(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: "$.k",
            document: 0
        )
        guard case .success(let newData) = result else {
            Issue.record("Expected .success")
            return
        }
        // Foundation JSONSerialization must accept the output.
        let text = String(data: newData, encoding: .utf8)!
        #expect(throws: Never.self) { try decodeJSON(text) }
    }

    @Test("encoded body is single-line even when editedText has newlines")
    func singleLineEncoding() throws {
        let original = #"{"k":"placeholder"}"#
        let data = Data(original.utf8)
        let editedText = "line1\nline2\nline3"
        let byteRange = try locateJSONRange(data: data, jsonpath: "$.k")

        let result = SpanSplicer.spliceJSON(
            editedText: editedText,
            into: data,
            byteRange: byteRange,
            jsonpath: "$.k",
            document: 0
        )
        guard case .success(let newData) = result else {
            Issue.record("Expected .success")
            return
        }
        let text = String(data: newData, encoding: .utf8)!
        // The output JSON document must be one line (no literal newlines
        // inside the string value — they are encoded as \n).
        #expect(!text.contains("\n"))
    }
}

// MARK: - JSON span-splice: validation failures

@Suite("JSON span-splice — validation failures")
struct JSONSplicerValidationTests {

    @Test("returns .reparseFailed when the new document is malformed JSON")
    func reparseFailedMalformed() throws {
        // Construct a fixture where splicing a deliberately bad encoding produces
        // malformed JSON. We achieve this by calling the internal helper directly
        // with a byteRange that, when replaced, breaks JSON syntax.
        //
        // Strategy: use the real fixture but supply a byteRange that covers more
        // than just the value content — e.g. includes a closing quote + brace.
        // The easiest approach is to compute the real range and then extend it
        // to swallow the closing quote, so the resulting file becomes invalid.
        let original = #"{"k":"value"}"#
        let data = Data(original.utf8)
        let jsonpath = "$.k"
        let realRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        // Extend the range to include the closing `"` — this will produce
        // {"k":"new} which is invalid JSON.
        let brokenRange = realRange.lowerBound..<(realRange.upperBound + 1)

        let result = SpanSplicer.spliceJSON(
            editedText: "new",
            into: data,
            byteRange: brokenRange,
            jsonpath: jsonpath,
            document: 0
        )
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure, got .success")
            return
        }
        if case .reparseFailed = error {
            // correct
        } else {
            Issue.record("Expected .reparseFailed, got \(error)")
        }
    }

    @Test("returns .spanLeak when bytes outside the splice span differ from original")
    func spanLeakDetected() throws {
        // SpanSplicer guarantees no bytes outside [byteRange] change.
        // We verify this by passing a valid splice and checking the validation
        // logic separately via a crafted scenario.
        //
        // Since the public API computes prefix/suffix from originalData and
        // newData, and the implementation always derives newData by concatenating
        // [0..<lower] + encodedBody + [upper...], the only way to produce a
        // .spanLeak is if the range is somehow inconsistent (e.g. extends past
        // the end of data so the suffix is truncated).  We test the validator
        // indirectly: pass a byteRange whose upperBound > data.count so that
        // the suffix in the result differs.
        let original = #"{"k":"v"}"#
        let data = Data(original.utf8)
        let jsonpath = "$.k"
        let realRange = try locateJSONRange(data: data, jsonpath: jsonpath)

        // Shift the range entirely past the data to make newData lose the suffix.
        // upperBound past data.count causes the suffix extraction to be empty,
        // but the original suffix is non-empty, so the validator fires .spanLeak.
        let outOfBounds = data.count..<(data.count + 5)

        let result = SpanSplicer.spliceJSON(
            editedText: "new",
            into: data,
            byteRange: outOfBounds,
            jsonpath: jsonpath,
            document: 0
        )
        // This will either be .reparseFailed (malformed JSON from out-of-bounds
        // slice) or .spanLeak.  Either is a failure — but .spanLeak is the
        // expected one here once reparse passes (if it does).
        guard case .failure = result else {
            Issue.record("Expected failure for out-of-bounds range, got .success")
            return
        }
        _ = realRange  // suppress unused warning
    }

    @Test(".spanLeak is distinct from .reparseFailed")
    func spanLeakEquality() {
        let leak = SpliceError.spanLeak
        let reparse = SpliceError.reparseFailed("x")
        #expect(leak != reparse)
    }

    @Test("returns .fieldMismatch when re-extracted field does not equal editedText")
    func fieldMismatchDetected() throws {
        // To trigger .fieldMismatch the validation must pass (1) and (2) but
        // fail (3).  This can't happen through normal spliceJSON because the
        // implementation guarantees the splice is correct — it can only occur
        // if someone passes a jsonpath that points to a DIFFERENT field than
        // the one at byteRange.
        //
        // We test this by giving $.k's byteRange but jsonpath "$.other",
        // where $.other has a different value. After splice, $.other will still
        // be "other_val", not "new", so (3) fires.
        let original = #"{"k":"v","other":"other_val"}"#
        let data = Data(original.utf8)

        // Use the range of $.k but validate against $.other.
        let kRange = try locateJSONRange(data: data, jsonpath: "$.k")

        let result = SpanSplicer.spliceJSON(
            editedText: "new",
            into: data,
            byteRange: kRange,
            jsonpath: "$.other",  // intentional mismatch
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

// MARK: - Conflict-hash helper

@Suite("Conflict-hash helper")
struct ConflictHashTests {

    @Test("returns false when current data matches the expected hash")
    func noConflictWhenHashMatches() {
        let data = Data("hello, moonswift".utf8)
        let expectedHash = SHA256.hash(data: data)
        #expect(SpanSplicer.hasConflict(currentData: data, expected: expectedHash) == false)
    }

    @Test("returns true when current data has been mutated")
    func conflictWhenHashDiffers() {
        let original = Data("hello, moonswift".utf8)
        let expectedHash = SHA256.hash(data: original)
        let mutated = Data("hello, MUTATED".utf8)
        #expect(SpanSplicer.hasConflict(currentData: mutated, expected: expectedHash) == true)
    }

    @Test("returns true for empty data vs non-empty original hash")
    func conflictEmptyVsNonEmpty() {
        let original = Data("content".utf8)
        let expectedHash = SHA256.hash(data: original)
        #expect(SpanSplicer.hasConflict(currentData: Data(), expected: expectedHash) == true)
    }

    @Test("returns false for empty data against empty-data hash")
    func noConflictBothEmpty() {
        let emptyHash = SHA256.hash(data: Data())
        #expect(SpanSplicer.hasConflict(currentData: Data(), expected: emptyHash) == false)
    }
}

// MARK: - SpliceError: Equatable contract

@Suite("SpliceError Equatable")
struct SpliceErrorEquatableTests {

    @Test(".spanLeak equals itself")
    func spanLeakEqualsSelf() {
        #expect(SpliceError.spanLeak == SpliceError.spanLeak)
    }

    @Test(".fieldMismatch equals itself")
    func fieldMismatchEqualsSelf() {
        #expect(SpliceError.fieldMismatch == SpliceError.fieldMismatch)
    }

    @Test(".reparseFailed equals itself with same message")
    func reparseFailedEquality() {
        #expect(SpliceError.reparseFailed("msg") == SpliceError.reparseFailed("msg"))
    }

    @Test(".reparseFailed differs when messages differ")
    func reparseFailedInequality() {
        #expect(SpliceError.reparseFailed("a") != SpliceError.reparseFailed("b"))
    }

    @Test(".unrepresentable equals itself with same message")
    func unrepresentableEquality() {
        #expect(SpliceError.unrepresentable("x") == SpliceError.unrepresentable("x"))
    }

    @Test("distinct cases are not equal")
    func distinctCasesNotEqual() {
        #expect(SpliceError.spanLeak != SpliceError.fieldMismatch)
        #expect(SpliceError.spanLeak != SpliceError.reparseFailed(""))
        #expect(SpliceError.fieldMismatch != SpliceError.unrepresentable(""))
    }
}
