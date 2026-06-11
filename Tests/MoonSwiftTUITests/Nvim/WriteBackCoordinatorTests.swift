// File: Tests/MoonSwiftTUITests/Nvim/WriteBackCoordinatorTests.swift
// Location: MoonSwiftTUITests/Nvim/
// Role: Unit tests for WriteBackCoordinator — the async write-back pipeline
//       that reads the current file, checks for conflicts, splices the edited
//       text back into the host format, and atomically writes the result.
//       Covers: JSON/TOML/YAML/Lua happy paths, conflict detection, force
//       override, size-cap, syntax pre-pass rejection, validateReadable
//       rejection, and YAML trailing-newline strip.
// Upstream: WriteBackCoordinator (subject under test), SpanSplicer, SpanLocator,
//           SourceStore, WriteBackTestSupport (MockLintService, WriteBackFixtures)
// Downstream: (none — tests only)

import CryptoKit
import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - .lua happy path

@Suite("WriteBackCoordinator — .lua overwrite")
struct LuaWriteBackTests {

    @Test("happy path: overwrites .lua file with edited text")
    func luaHappyPath() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: provenance.file.path, provenance: provenance)
        let editedText = "return 99\n"
        let lint = MockLintService()
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: lint,
            force: false
        )
        #expect(result.outcome == .success)
        #expect(result.newData == Data(editedText.utf8))
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == Data(editedText.utf8))
    }

    @Test("returns .validateReadableRejection when file URL is outside project root")
    func luaFileOutsideRoot() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let outsideDir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: outsideDir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 1\n",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        if case .validateReadableRejection = result.outcome {
            // Expected: file is outside the project root
        } else {
            Issue.record("Expected .validateReadableRejection, got \(result.outcome)")
        }
        #expect(result.newData == nil)
    }
}

// MARK: - JSON happy path

@Suite("WriteBackCoordinator — JSON splice")
struct JSONWriteBackTests {

    @Test("happy path: splices new Lua text into JSON field")
    func jsonHappyPath() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        let fragment = LuaSourceFragment(code: provenance.file.path, provenance: provenance)
        let editedText = "return 42"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        guard let newData = result.newData else {
            Issue.record("newData should be non-nil on .success")
            return
        }
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("return 42"))
    }
}

// MARK: - TOML happy path

@Suite("WriteBackCoordinator — TOML splice")
struct TOMLWriteBackTests {

    @Test("happy path: splices new Lua text into TOML field")
    func tomlHappyPath() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.toml", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .toml)
        let fragment = LuaSourceFragment(code: provenance.file.path, provenance: provenance)
        let editedText = "return 55"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        guard let newData = result.newData else {
            Issue.record("newData should be non-nil on .success")
            return
        }
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("return 55"))
    }
}

// MARK: - YAML happy path

@Suite("WriteBackCoordinator — YAML splice")
struct YAMLWriteBackTests {

    @Test("happy path: splices new Lua text into YAML field (strips trailing newline)")
    func yamlHappyPath() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: provenance.file.path, provenance: provenance)
        // editedText with trailing newline; WBC must strip it for YAML.
        let editedText = "return 77\n"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
        guard let newData = result.newData else {
            Issue.record("newData should be non-nil on .success")
            return
        }
        let newText = String(data: newData, encoding: .utf8)!
        #expect(newText.contains("return 77"))
    }

    @Test("single-line YAML value without trailing newline also succeeds")
    func yamlNoTrailingNewline() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.yaml", into: dir)
        let jsonpath = "$.scripts.run"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .yaml)
        let fragment = LuaSourceFragment(code: provenance.file.path, provenance: provenance)
        let editedText = "return 0"
        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        #expect(result.outcome == .success)
    }
}

// MARK: - Conflict detection

@Suite("WriteBackCoordinator — conflict detection")
struct ConflictTests {

    @Test("detects conflict when file is mutated after fragment load")
    func conflictDetected() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Mutate file after provenance was captured — content hash no longer matches.
        let original = try Data(contentsOf: fileURL)
        var mutated = original
        mutated.append(Data(" ".utf8))
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

    @Test("force:true bypasses conflict check and writes successfully")
    func forceOverridesConflict() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("scripts.json", into: dir)
        let jsonpath = "$.scripts.init"
        let provenance = try WriteBackFixtures.structuredProvenance(
            fileURL: fileURL, jsonpath: jsonpath, format: .json)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Mutate file — would normally trigger conflict.
        let original = try Data(contentsOf: fileURL)
        var mutated = original
        mutated.append(Data(" ".utf8))
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

// MARK: - SpliceError propagation

@Suite("WriteBackCoordinator — SpliceError propagation")
struct SpliceErrorTests {

    /// CR-006: syntax pre-pass failure returns `.syntaxPrePassBlocked(diagnostic)`
    /// so callers can map it to `AppEvent.writeBackBlocked` without string inspection.
    @Test("syntax pre-pass diagnostic returns .syntaxPrePassBlocked")
    func syntaxPrePassDiagnostic() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let diagnostic = Diagnostic(
            severity: .error,
            line: 1,
            message: "unexpected symbol near '<eof>'",
            source: .syntaxPrePass
        )
        let lint = MockLintService(stubbedDiagnostic: diagnostic)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "function(",  // syntactically invalid but mock controls it
            projectRoot: dir,
            lintService: lint,
            force: false
        )
        // CR-006: must be .syntaxPrePassBlocked carrying the exact diagnostic.
        if case .syntaxPrePassBlocked(let diag) = result.outcome {
            #expect(diag.message == diagnostic.message)
            #expect(diag.line == diagnostic.line)
        } else {
            Issue.record("Expected .syntaxPrePassBlocked, got \(result.outcome)")
        }
        #expect(result.newData == nil)
    }
}

// MARK: - Missing file

@Suite("WriteBackCoordinator — missing file")
struct MissingFileTests {

    /// A missing file is NOT a `validateReadable` rejection: the guard checks
    /// file type, size, and root escape on a file's metadata, and a nonexistent
    /// path has none — `SourceStore.FileReadRejection` deliberately has no
    /// `.missing` case. The pipeline therefore reaches the read step (step 4),
    /// whose failure surfaces as `.ioFailure`.
    @Test("returns .ioFailure when file does not exist")
    func fileMissing() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let missingURL = dir.appendingPathComponent("nonexistent.lua")

        // Build a provenance pointing at a file that doesn't exist.
        let provenance = FragmentProvenance(
            file: missingURL,
            jsonpath: nil,
            document: 0,
            byteRange: 0..<0,
            lineOffset: 0,
            contentHash: SHA256.hash(data: Data())
        )
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "return 1\n",
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        if case .ioFailure = result.outcome {
            // Expected: the read step fails on the nonexistent file.
        } else {
            Issue.record("Expected .ioFailure, got \(result.outcome)")
        }
        #expect(result.newData == nil)
    }
}

// MARK: - Size cap

@Suite("WriteBackCoordinator — size cap")
struct SizeCapTests {

    @Test("returns .ioFailure when editedText exceeds structuredFileSizeLimit")
    func editedTextExceedsLimit() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "", provenance: provenance)

        // Build a string larger than 50 MiB. Use a repeated single byte for speed.
        let oversized = String(repeating: "x", count: structuredFileSizeLimit + 1)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: oversized,
            projectRoot: dir,
            lintService: MockLintService(),
            force: false
        )
        if case .ioFailure(let msg) = result.outcome {
            #expect(msg == "Edited text exceeds size limit")
        } else {
            Issue.record("Expected .ioFailure(\"Edited text exceeds size limit\"), got \(result.outcome)")
        }
        #expect(result.newData == nil)
    }
}
