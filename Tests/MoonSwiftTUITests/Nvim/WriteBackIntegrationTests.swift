// File: Tests/MoonSwiftTUITests/Nvim/WriteBackIntegrationTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: PRD §F8 acceptance e2e tests and per-format property tests for the
//       write-back pipeline. No real nvim binary is required — all tests drive
//       the WriteBackCoordinator directly with on-disk fixture files, a
//       MockLintService, and the WriteBackFixtures helpers already established
//       by WriteBackCoordinatorTests.
//
//       Acceptance criteria (PRD §F8, ARCHITECTURE.md §10.8 Inc-12):
//         (1) YAML fragment with a syntax error: pre-pass blocks the write.
//         (2) Fix the error: file updated; bytes outside the spliced span are
//             byte-identical to the original file.
//         (3) External change between load and :w: conflict is detected.
//         (4) :w triggers write-back end-to-end (event → coordinator → file).
//
//       Per-format property tests: parameterised over JSON, YAML, TOML, .lua.
//       Each test verifies that after a successful write-back the bytes that
//       lie outside the edited span are bit-for-bit identical to the bytes in
//       the original file (the §F8 "bytes outside the spliced span are
//       byte-identical" contract).
//
// Upstream: WriteBackCoordinator, SpanSplicer, SpanLocator, SourceStore,
//           WriteBackTestSupport (MockLintService, WriteBackFixtures)
// Downstream: (none — tests only)

import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Helpers

/// Returns the byte indices that lie OUTSIDE [spanStart, spanEnd) in `data`.
///
/// Used by the "outside-span bytes are identical" assertion.
private func outsideSpanIndices(
    of data: Data,
    spanStart: Int,
    spanEnd: Int
) -> [Int] {
    let range = 0..<data.count
    return range.filter { $0 < spanStart || $0 >= spanEnd }
}

// MARK: - Acceptance: YAML syntax error blocks write, then fix succeeds

/// PRD §F8 acceptance (1 & 2):
///   YAML fragment with a syntax error → pre-pass blocks the write.
///   Fix the error → file updated; outside-span bytes byte-identical.
@Suite("WriteBackIntegration — YAML syntax error then fix")
struct YAMLSyntaxErrorAcceptanceTests {

    /// Step 1: A write with syntactically invalid Lua is blocked by the pre-pass.
    @Test("syntax error in edited text blocks write-back via spliceError")
    func yamlSyntaxErrorBlocksWrite() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Inject a diagnostic so the mock pre-pass reports a syntax error.
        let syntaxDiag = Diagnostic(
            severity: .error,
            line: 1,
            message: "unexpected symbol near 'end'",
            source: .syntaxPrePass
        )
        let lint = MockLintService(stubbedDiagnostic: syntaxDiag)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "end -- invalid Lua",
            projectRoot: dir,
            lintService: lint,
            force: false
        )

        // Must be blocked by the pre-pass (reported as .spliceError).
        if case .spliceError = result.outcome {
            // Correct: write was blocked by the syntax pre-pass.
        } else {
            Issue.record(
                "Expected .spliceError from syntax pre-pass, got \(result.outcome)")
        }
        #expect(result.newData == nil)

        // The original file must be untouched.
        let originalData = try Data(contentsOf: fileURL)
        let originalText = String(data: originalData, encoding: .utf8)!
        #expect(originalText.contains("print('hello')"))
    }

    /// Step 2: After fixing the error the write succeeds and the bytes OUTSIDE
    /// the spliced span are byte-identical to the original file.
    @Test("valid edit succeeds and outside-span bytes are bit-for-bit identical")
    func yamlFixedEditPreservesOutsideSpanBytes() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let originalData = try Data(contentsOf: fileURL)
        let jsonpath = "$.scripts.init"

        // Re-locate the span so we know its exact byte extent before write-back.
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let originalSpanStart = provenance.byteRange.lowerBound
        let originalSpanEnd = provenance.byteRange.upperBound

        let fragment = LuaSourceFragment(code: "", provenance: provenance)
        let editedText = "return 99\n"

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )

        #expect(result.outcome == .success)
        guard let newData = result.newData else {
            Issue.record("newData must be non-nil on success")
            return
        }

        // The new file must contain the edited text.
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("return 99"))

        // Bytes OUTSIDE the original span in the new file must be bit-for-bit
        // identical to those same positions in the original file.
        //
        // Re-locate the span in the NEW data so we know where the edited region
        // ended up (its position may shift if the replacement is a different
        // size). Instead, we compare the prefix (before old span start) and the
        // suffix (after old span end) against the original file's corresponding
        // regions.
        let originalPrefix = originalData[0..<originalSpanStart]
        let originalSuffix = originalData[originalSpanEnd...]

        // The new data's prefix length must equal the original prefix length
        // (nothing before the span changes).
        #expect(newData.count >= originalPrefix.count)
        let newPrefix = newData[0..<originalSpanStart]
        #expect(newPrefix == originalPrefix, "bytes before the span changed")

        // Suffix: find where it starts in the new file.
        // The suffix starts right after the new value's end. Because the span
        // may now have a different length, compute the new span length by
        // re-locating in newData.
        guard let newText2 = String(data: newData, encoding: .utf8) else {
            Issue.record("newData not valid UTF-8")
            return
        }
        let expr = try JSONPathExpression(parsing: jsonpath)
        let newTree = try decodeYAML(newText2, document: 0)
        let newMatches = expr.evaluate(on: newTree)
        guard let firstMatch = newMatches.first else {
            Issue.record("JSONPath matched nothing in new data")
            return
        }
        let newLoc = try SpanLocator.locateSpan(
            in: newData,
            format: .yaml,
            path: firstMatch.path.steps,
            document: 0
        )
        let newSpanEnd = newLoc.byteRange.upperBound
        let newSuffix = newData[newSpanEnd...]
        #expect(newSuffix == originalSuffix, "bytes after the span changed")
    }
}

// MARK: - Acceptance: external conflict is detected

/// PRD §F8 acceptance (3): file externally modified between load and :w.
@Suite("WriteBackIntegration — external conflict detected")
struct ExternalConflictAcceptanceTests {

    @Test("external modification after load triggers .conflictDetected")
    func externalModificationTriggersConflict() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Simulate external change after the fragment was loaded.
        let original = try Data(contentsOf: fileURL)
        var mutated = original
        mutated.append(Data("  # external comment\n".utf8))
        try mutated.write(to: fileURL, options: .atomic)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 1",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )

        #expect(result.outcome == .conflictDetected)
        #expect(result.newData == nil)
    }

    @Test("force:true overrides conflict and succeeds")
    func forceOverridesConflict() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Mutate file — would normally trigger conflict.
        let original = try Data(contentsOf: fileURL)
        var mutated = original
        mutated.append(Data("  # external comment\n".utf8))
        try mutated.write(to: fileURL, options: .atomic)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 1",
            projectRoot: dir,
            lintService: MockLintService(),
            force: true
        )

        #expect(result.outcome == .success)
        #expect(result.newData != nil)
    }
}

// MARK: - Acceptance: :w triggers write-back end-to-end

/// PRD §F8 acceptance (4): :w triggers write-back end-to-end (event → coordinator → file).
///
/// This test drives the WriteBackCoordinator directly — the "event → coordinator"
/// part of the pipeline — and verifies that the output file is updated on disk
/// (the "coordinator → file" part). The nvim RPC notification layer is tested in
/// EditorBridgeTests; here we verify the coordinator's atomic write contract.
@Suite("WriteBackIntegration — write-back end-to-end")
struct WriteBackEndToEndTests {

    @Test(":w scenario — JSON field updated on disk after write-back")
    func jsonWriteBackUpdatesFile() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let editedText = "return 'from nvim'"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )

        #expect(result.outcome == .success)

        // Verify the on-disk file was updated.
        let onDisk = try Data(contentsOf: fileURL)
        let onDiskText = String(data: onDisk, encoding: .utf8)!
        #expect(onDiskText.contains("from nvim"))
    }

    @Test(":w scenario — Lua file overwritten atomically on disk")
    func luaWriteBackUpdatesFile() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let editedText = "-- edited by nvim\nreturn 'nvim'\n"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )

        #expect(result.outcome == .success)
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == Data(editedText.utf8))
    }
}

// MARK: - Per-format property tests (outside-span bytes preserved)

/// Property tests: for each format, after a successful write-back the bytes
/// outside the edited span are byte-identical to the original file.
///
/// The table below drives a parameterised approach: three structured formats
/// plus the whole-.lua overwrite case (which has no "outside span" to check
/// but verifies full-overwrite correctness).
///
/// For structured formats the test:
///   1. Reads the original file bytes.
///   2. Locates the span for the target JSONPath.
///   3. Performs a write-back with new text.
///   4. Re-locates the span in the new data.
///   5. Compares prefix (before old span) and suffix (after old span) between
///      original and new data — they must be bit-for-bit identical.
@Suite("WriteBackIntegration — per-format outside-span bytes preserved")
struct PerFormatPropertyTests {

    // MARK: JSON

    @Test("JSON: bytes outside spliced span are byte-identical to original")
    func jsonOutsideSpanPreserved() async throws {
        try await assertOutsideSpanPreserved(
            fixtureName: "scripts.json",
            jsonpath: "$.scripts.init",
            format: .json,
            editedText: "return 'json-property-test'"
        )
    }

    @Test("JSON: multiple keys in same object — only target field changes")
    func jsonOtherFieldsUnchanged() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let originalData = try Data(contentsOf: fileURL)
        let originalText = String(data: originalData, encoding: .utf8)!

        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 'changed'",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        let newText = String(data: result.newData!, encoding: .utf8)!

        // The sibling "run" field must be unchanged.
        let siblingOriginal = originalText.contains("\"run\": \"return 42\"")
        let siblingNew = newText.contains("\"run\": \"return 42\"")
        // Both or neither should contain the sibling — and the original does.
        #expect(siblingOriginal)
        #expect(siblingNew, "sibling field 'run' was modified by write-back")
    }

    // MARK: YAML

    @Test("YAML: bytes outside spliced span are byte-identical to original")
    func yamlOutsideSpanPreserved() async throws {
        try await assertOutsideSpanPreserved(
            fixtureName: "scripts.yaml",
            jsonpath: "$.scripts.init",
            format: .yaml,
            editedText: "return 'yaml-property-test'\n"
        )
    }

    @Test("YAML: sibling key unchanged after splice")
    func yamlSiblingUnchanged() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let originalData = try Data(contentsOf: fileURL)
        let originalText = String(data: originalData, encoding: .utf8)!

        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 'changed'\n",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        let newText = String(data: result.newData!, encoding: .utf8)!

        // The "version: 1" and "enabled: true" lines outside the scripts block
        // must be unchanged.
        #expect(originalText.contains("version: 1"))
        #expect(newText.contains("version: 1"), "'version' field was modified")
        #expect(originalText.contains("enabled: true"))
        #expect(newText.contains("enabled: true"), "'enabled' field was modified")
    }

    @Test("YAML block scalar: bytes outside spliced span are byte-identical to original")
    func yamlBlockScalarOutsideSpanPreserved() async throws {
        try await assertOutsideSpanPreserved(
            fixtureName: "splice-yaml-block.yaml",
            jsonpath: "$.literal",
            format: .yaml,
            editedText: "new line one\nnew line two\n"
        )
    }

    // MARK: TOML

    @Test("TOML: bytes outside spliced span are byte-identical to original")
    func tomlOutsideSpanPreserved() async throws {
        try await assertOutsideSpanPreserved(
            fixtureName: "scripts.toml",
            jsonpath: "$.scripts.init",
            format: .toml,
            editedText: "return 'toml-property-test'"
        )
    }

    @Test("TOML: sibling field unchanged after splice")
    func tomlSiblingUnchanged() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.toml", into: dir)
        let jsondata = try Data(contentsOf: fileURL)
        let originalText = String(data: jsondata, encoding: .utf8)!

        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .toml)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 'changed'",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        let newText = String(data: result.newData!, encoding: .utf8)!

        #expect(originalText.contains("version = 1"))
        #expect(newText.contains("version = 1"), "'version' field was modified")
        #expect(originalText.contains("enabled = true"))
        #expect(newText.contains("enabled = true"), "'enabled' field was modified")
    }

    // MARK: Lua (full-overwrite path)

    @Test("Lua: full overwrite produces exact editedText bytes on disk")
    func luaFullOverwriteExact() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let editedText = "-- property test\nreturn 'property'\n"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        guard let newData = result.newData else {
            Issue.record("newData must be non-nil on success")
            return
        }
        // Full overwrite: entire file must equal editedText bytes.
        #expect(newData == Data(editedText.utf8))
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == Data(editedText.utf8))
    }

    // MARK: Repeated round-trip (idempotence)

    @Test("JSON: repeated write-back is idempotent (two successive writes)")
    func jsonRepeatedWriteIsIdempotent() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let jsonpath = "$.scripts.init"

        // First write.
        var provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        var fragment = LuaSourceFragment(code: "", provenance: provenance)
        let firstText = "return 'first'"
        let r1 = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: firstText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(r1.outcome == .success)

        // Second write using the freshly updated file.
        provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        fragment = LuaSourceFragment(code: "", provenance: provenance)
        let secondText = "return 'second'"
        let r2 = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: secondText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(r2.outcome == .success)
        guard let finalData = r2.newData else {
            Issue.record("Second write produced nil newData")
            return
        }
        let finalText = String(data: finalData, encoding: .utf8)!
        #expect(finalText.contains("second"))
        // First write's value must be gone.
        #expect(!finalText.contains("return 'first'"))
    }
}

// MARK: - Shared assertion helper

/// Assert that after a successful write-back the bytes in the original file
/// that lie OUTSIDE the edited span are bit-for-bit identical in the new file.
///
/// The comparison is done for the prefix (before the old span start) and the
/// suffix (after the old span end). If the replacement text shifts the suffix
/// to a different byte offset that is expected and correct — only the bytes
/// themselves must be equal.
private func assertOutsideSpanPreserved(
    fixtureName: String,
    jsonpath: String,
    format: StructuredFileFormat,
    editedText: String,
    file: StaticString = #filePath,
    line: Int = #line
) async throws {
    let dir = try WriteBackFixtures.tempDir()
    let fileURL = try WriteBackFixtures.copyFixture(fixtureName, into: dir)
    let originalData = try Data(contentsOf: fileURL)

    let provenance = try WriteBackFixtures.structuredProvenance(
        fileURL: fileURL, jsonpath: jsonpath, format: format)
    let spanStart = provenance.byteRange.lowerBound
    let spanEnd = provenance.byteRange.upperBound

    let fragment = LuaSourceFragment(code: "", provenance: provenance)
    let result = await WriteBackCoordinator.write(
        fragment: fragment,
        editedText: editedText,
        projectRoot: dir,
        lintService: MockLintService(),
        force: false
    )
    guard result.outcome == .success else {
        Issue.record("Write-back failed: \(result.outcome)")
        return
    }
    guard let newData = result.newData else {
        Issue.record("newData nil on success")
        return
    }

    // Compare prefix (bytes before the old span start).
    guard originalData.count >= spanStart, newData.count >= spanStart else {
        Issue.record("New data shorter than old span start")
        return
    }
    let originalPrefix = originalData[0..<spanStart]
    let newPrefix = newData[0..<spanStart]
    #expect(
        originalPrefix == newPrefix,
        "Prefix bytes changed for \(fixtureName)"
    )

    // Compare suffix (bytes after the old span end in the original).
    // These same bytes should be at the tail of the new file shifted by the
    // delta (replacement length − original span length). The simplest correct
    // check is: original suffix bytes appear verbatim somewhere at the tail of
    // the new file.
    let originalSuffix = originalData[spanEnd...]
    let newSuffix = newData[(newData.count - originalSuffix.count)...]
    #expect(
        originalSuffix == newSuffix,
        "Suffix bytes changed for \(fixtureName)"
    )
}
