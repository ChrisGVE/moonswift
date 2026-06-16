// File: Tests/MoonSwiftTUITests/LuaLSCacheTests.swift
// Role: Verify the per-project LuaLS cache mechanics (F7b): project-hash
//       determinism + symlink resolution (SEC-06), directory layout + 0700
//       permissions, signature-driven regeneration, and the AND-predicate
//       eviction grace rule (DATA-N02).
// Upstream: MoonSwiftTUI/LuaLS/LuaLSCache.swift, MoonSwiftCore.GeneratedFile
// Downstream: (test target)

import Foundation
import MoonSwiftCore
import Testing

@testable import MoonSwiftTUI

@Suite("LuaLSCache")
struct LuaLSCacheTests {

    // MARK: Helpers

    /// A unique empty temp directory; the caller removes it.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("luals-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let sampleFiles = [
        GeneratedFile(relativePath: ".luarc.json", content: "{ \"runtime.version\": \"Lua 5.4\" }\n"),
        GeneratedFile(relativePath: "meta/luaswift.lua", content: "---@meta\n"),
    ]

    // MARK: project-hash

    @Test("project-hash is deterministic and symlink-resolved (SEC-06)")
    func projectHashResolvesSymlinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let real = dir.appendingPathComponent("moonswift.toml")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let h1 = LuaLSCache.projectHash(forToml: real)
        let h2 = LuaLSCache.projectHash(forToml: link)
        #expect(h1 == h2)  // symlink resolves to the same real path
        #expect(h1.count == 64)  // SHA-256 hex
        #expect(h1 == h1.lowercased())

        let other = dir.appendingPathComponent("other.toml")
        try "y".write(to: other, atomically: true, encoding: .utf8)
        #expect(LuaLSCache.projectHash(forToml: other) != h1)
    }

    // MARK: prepare

    @Test("prepare writes meta + .luarc.json + sentinel in a 0700 dir")
    func prepareWritesFiles() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let toml = root.appendingPathComponent("moonswift.toml")
        try "p".write(to: toml, atomically: true, encoding: .utf8)

        let cacheDir = try LuaLSCache.prepare(metaFiles: sampleFiles, tomlPath: toml, root: root)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent(".luarc.json").path))
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent("meta/luaswift.lua").path))
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent("meta-version").path))
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent("source-path").path))

        let perms = try fm.attributesOfItem(atPath: cacheDir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)

        let recorded = try String(
            contentsOf: cacheDir.appendingPathComponent("source-path"), encoding: .utf8)
        #expect(recorded == toml.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test("prepare rewrites only when the catalog signature changes")
    func prepareRegeneratesOnSignatureChange() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let toml = root.appendingPathComponent("moonswift.toml")
        try "p".write(to: toml, atomically: true, encoding: .utf8)
        let fm = FileManager.default

        let cacheDir = try LuaLSCache.prepare(metaFiles: sampleFiles, tomlPath: toml, root: root)

        // Drop a marker inside the meta dir; a rewrite wipes the meta dir.
        let marker = cacheDir.appendingPathComponent("meta/__marker")
        try "m".write(to: marker, atomically: true, encoding: .utf8)

        // Same files → no rewrite → marker survives.
        _ = try LuaLSCache.prepare(metaFiles: sampleFiles, tomlPath: toml, root: root)
        #expect(fm.fileExists(atPath: marker.path))

        // Changed files → rewrite → marker gone.
        let changed = sampleFiles + [GeneratedFile(relativePath: "meta/extra.lua", content: "---@meta\n")]
        _ = try LuaLSCache.prepare(metaFiles: changed, tomlPath: toml, root: root)
        #expect(!fm.fileExists(atPath: marker.path))
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent("meta/extra.lua").path))
    }

    // MARK: eviction (AND predicate, DATA-N02)

    @Test("eviction removes only orphaned AND aged caches")
    func evictionAndPredicate() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60)

        // Build a cache subdir whose source-path record points at `sourcePath`,
        // with the record back-dated to `recordDate`.
        func makeEntry(name: String, sourcePath: String, recordDate: Date) throws -> URL {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let record = dir.appendingPathComponent("source-path")
            try sourcePath.write(to: record, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: recordDate], ofItemAtPath: record.path)
            return dir
        }

        let missingPath = root.appendingPathComponent("gone.toml").path
        let presentPath = root.appendingPathComponent("here.toml")
        try "x".write(to: presentPath, atomically: true, encoding: .utf8)

        let orphanedAndOld = try makeEntry(name: "a", sourcePath: missingPath, recordDate: old)
        let orphanedButFresh = try makeEntry(name: "b", sourcePath: missingPath, recordDate: now)
        let presentButOld = try makeEntry(name: "c", sourcePath: presentPath.path, recordDate: old)

        LuaLSCache.evictStale(now: now, root: root)

        #expect(!fm.fileExists(atPath: orphanedAndOld.path))  // both conditions → removed
        #expect(fm.fileExists(atPath: orphanedButFresh.path))  // within grace → kept
        #expect(fm.fileExists(atPath: presentButOld.path))  // source resolves → kept
    }
}
