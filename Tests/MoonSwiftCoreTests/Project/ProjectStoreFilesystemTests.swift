// File: Tests/MoonSwiftCoreTests/Project/ProjectStoreFilesystemTests.swift
// Folder: Tests/MoonSwiftCoreTests/Project/
// Role: Tests for ProjectStore's filesystem I/O paths — load(at:), load(from:),
//       save(_:to:), and initialize(at:). Each test creates an isolated temp
//       directory via FileManager and tears it down in a defer block, keeping
//       every test hermetic.
//
//       The loadFromString API (pure, no I/O) is already covered by
//       ProjectStoreTests.swift. These tests target the load/save/init paths
//       that require real file URLs, which were 0% covered.
//
// Upstream: MoonSwiftCore/Project/ProjectStore.swift
// Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Creates a temporary directory under the system temp location.
/// Returns the directory URL; the caller is responsible for removing it.
private func makeTemp() throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - load(at:) — directory-relative load

@Suite("ProjectStore.load(at:)")
struct ProjectStoreLoadAtTests {

    @Test("load(at:) reads moonswift.toml from the directory and returns .loaded")
    func loadsValidFileFromDirectory() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tomlURL = dir.appendingPathComponent("moonswift.toml")
        let content = #"lua_version = "5.4""#
        try content.write(to: tomlURL, atomically: true, encoding: .utf8)

        let result = ProjectStore.load(at: dir)
        if case let .loaded(file, _) = result {
            #expect(file.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded but got \(result)")
        }
    }

    @Test("load(at:) returns .malformed when moonswift.toml does not exist")
    func missingFileReturnsMalformed() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No moonswift.toml written — the file is absent.
        let result = ProjectStore.load(at: dir)
        if case let .malformed(diag) = result {
            #expect(diag.message.contains("moonswift.toml"))
        } else {
            Issue.record("Expected .malformed for missing file but got \(result)")
        }
    }

    @Test("load(at:) returns .malformed when moonswift.toml is syntactically invalid")
    func malformedTomlReturnsMalformed() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tomlURL = dir.appendingPathComponent("moonswift.toml")
        try "lua_version = \"5.4\"\nbad [[[".write(to: tomlURL, atomically: true, encoding: .utf8)

        let result = ProjectStore.load(at: dir)
        if case .malformed = result {
            // correct
        } else {
            Issue.record("Expected .malformed for invalid TOML but got \(result)")
        }
    }

    @Test("load(at:) returns .unsupportedVersion for non-5.4 lua_version")
    func unsupportedVersionFromFile() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tomlURL = dir.appendingPathComponent("moonswift.toml")
        try #"lua_version = "5.3""#.write(to: tomlURL, atomically: true, encoding: .utf8)

        let result = ProjectStore.load(at: dir)
        if case .unsupportedVersion = result {
            // correct
        } else {
            Issue.record("Expected .unsupportedVersion but got \(result)")
        }
    }
}

// MARK: - load(from:) — explicit URL load

@Suite("ProjectStore.load(from:)")
struct ProjectStoreLoadFromTests {

    @Test("load(from:) with explicit URL reads the given file")
    func loadsFromExplicitURL() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("my_project.toml")
        try #"lua_version = "5.4""#.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = ProjectStore.load(from: fileURL)
        if case let .loaded(file, _) = result {
            #expect(file.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded but got \(result)")
        }
    }

    @Test("load(from:) returns .malformed when the file cannot be read")
    func unreadableFileReturnsMalformed() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Point at a URL that does not exist.
        let missingURL = dir.appendingPathComponent("nonexistent.toml")
        let result = ProjectStore.load(from: missingURL)
        if case let .malformed(diag) = result {
            #expect(diag.message.contains("moonswift.toml") || diag.message.contains("could not read"))
        } else {
            Issue.record("Expected .malformed for unreadable file but got \(result)")
        }
    }

    @Test("load(from:) with projectRoot wires symlink-escape validation")
    func loadsWithProjectRoot() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A valid file with no escaping paths — should load cleanly.
        let fileURL = dir.appendingPathComponent("moonswift.toml")
        try #"lua_version = "5.4""#.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = ProjectStore.load(from: fileURL, projectRoot: dir)
        if case let .loaded(file, _) = result {
            #expect(file.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded with projectRoot but got \(result)")
        }
    }

    @Test("fileName constant is 'moonswift.toml'")
    func fileNameConstant() {
        #expect(ProjectStore.fileName == "moonswift.toml")
    }
}

// MARK: - save(_:to:)

@Suite("ProjectStore.save(_:to:)")
struct ProjectStoreSaveTests {

    @Test("save writes a valid ProjectFile to disk and load reads it back")
    func roundTrip() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("moonswift.toml")
        let project = ProjectFile(luaVersion: "5.4")
        try ProjectStore.save(project, to: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // Round-trip: load and verify the written file decodes correctly.
        let result = ProjectStore.load(from: fileURL)
        if case let .loaded(loaded, _) = result {
            #expect(loaded.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded after save round-trip but got \(result)")
        }
    }

    @Test("save preserves unknown keys from an existing file")
    func preservesUnknownKeys() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a file with an unknown key first.
        let fileURL = dir.appendingPathComponent("moonswift.toml")
        let original = """
            lua_version = "5.4"

            [future_feature]
            enabled = true
            """
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        // Save an updated model — unknown key should survive.
        let project = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(instructionLimit: 200)
        )
        try ProjectStore.save(project, to: fileURL)

        let written = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(written.contains("future_feature"))
        #expect(written.contains("instruction_limit"))
    }

    @Test("save throws StoreError.saveFailure when the directory does not exist")
    func saveFailureForMissingDirectory() throws {
        // Point save at a path whose parent directory does not exist.
        let nonExistentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = nonExistentDir.appendingPathComponent("moonswift.toml")

        let project = ProjectFile(luaVersion: "5.4")
        do {
            try ProjectStore.save(project, to: fileURL)
            Issue.record("Expected save to throw StoreError.saveFailure")
        } catch let err as StoreError {
            if case .saveFailure = err {
                // correct
            } else {
                Issue.record("Expected .saveFailure but got \(err)")
            }
        }
    }

    @Test("save to an existing file overwrites its content")
    func overwritesExistingFile() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("moonswift.toml")
        try #"lua_version = "5.4""#.write(to: fileURL, atomically: true, encoding: .utf8)

        let updated = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(instructionLimit: 500)
        )
        try ProjectStore.save(updated, to: fileURL)

        let result = ProjectStore.load(from: fileURL)
        if case let .loaded(loaded, _) = result {
            #expect(loaded.run.instructionLimit == 500)
        } else {
            Issue.record("Expected .loaded with updated run config but got \(result)")
        }
    }
}

// MARK: - initialize(at:)

@Suite("ProjectStore.initialize(at:)")
struct ProjectStoreInitializeTests {

    @Test("initialize writes a minimal moonswift.toml that loads as .loaded")
    func writesValidMinimalFile() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writtenURL = try ProjectStore.initialize(at: dir)
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))

        let result = ProjectStore.load(at: dir)
        if case let .loaded(file, _) = result {
            #expect(file.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded for initialized file but got \(result)")
        }
    }

    @Test("initialize returns the URL of the written file")
    func returnsFileURL() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ProjectStore.initialize(at: dir)
        #expect(url.lastPathComponent == "moonswift.toml")
        #expect(url.deletingLastPathComponent().path == dir.path)
    }

    @Test("initialize throws StoreError.fileAlreadyExists when file already present")
    func throwsWhenFileExists() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create the file first.
        _ = try ProjectStore.initialize(at: dir)

        // Second call must throw.
        do {
            _ = try ProjectStore.initialize(at: dir)
            Issue.record("Expected StoreError.fileAlreadyExists but no error was thrown")
        } catch let err as StoreError {
            if case .fileAlreadyExists = err {
                // correct
            } else {
                Issue.record("Expected .fileAlreadyExists but got \(err)")
            }
        }
    }
}
