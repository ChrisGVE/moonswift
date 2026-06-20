// File: Sources/MoonSwiftTUI/LuaLS/LuaLSCache.swift
// Folder: Sources/MoonSwiftTUI/LuaLS/
// Role: Own the on-disk per-project cache that backs lua-language-server (F7b).
//       Each project gets its own `~/Library/Caches/moonswift/luals/<hash>/`
//       directory (mode 0700) holding the generated `---@meta` files, the
//       `.luarc.json`, a `meta-version` sentinel (the catalog signature, so the
//       files are rewritten only when the catalog changes), and a `source-path`
//       record (the project's `moonswift.toml` path, consulted by eviction).
//       Pure filesystem mechanics — no process, no actor — so it is unit-tested
//       against temp directories.
//
// Upstream: MetaFileGenerator output ([GeneratedFile]), the project toml path
// Downstream: LuaLSClient (writes the dir before spawn, then points LuaLS at it)

import CryptoKit
import Foundation
import MoonSwiftCore

/// Manages the per-project LuaLS cache directory and its lifecycle.
enum LuaLSCache {

    /// Filenames of the bookkeeping records inside a project cache directory.
    static let sentinelName = "meta-version"
    static let sourcePathRecordName = "source-path"

    /// Grace period before an orphaned cache directory becomes eligible for
    /// eviction (DATA-N02): a directory is removed only when its source path no
    /// longer resolves AND its record is older than this.
    static let evictionGracePeriod: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    // MARK: - Paths

    /// The shared root holding every project's cache subdirectory.
    static func cacheRoot(fileManager: FileManager = .default) -> URL {
        let caches =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("moonswift/luals", isDirectory: true)
    }

    /// The cache subdirectory name for the project whose config is `tomlPath`:
    /// the lowercase hex SHA-256 of the ABSOLUTE, symlink-resolved path (SEC-06).
    /// Resolving symlinks first means two paths to the same file share one cache.
    static func projectHash(forToml tomlPath: URL) -> String {
        let resolved = tomlPath.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(resolved.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The deterministic signature of the generated file set, used as the
    /// `meta-version` sentinel so regeneration happens exactly when the catalog
    /// (and therefore the meta content) changes.
    static func signature(of files: [GeneratedFile]) -> String {
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: [0])  // separator: keep path/content boundaries unambiguous
            hasher.update(data: Data(file.content.utf8))
            hasher.update(data: [0])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Prepare

    /// Ensure the project cache directory exists (mode 0700) and holds the current
    /// generated files, rewriting them only when the catalog signature changed.
    ///
    /// Returns the cache directory URL — the LuaLS workspace root, where the
    /// `.luarc.json` lives so `runtime.version` and `workspace.library` apply.
    ///
    /// - Throws: any filesystem error from directory creation or file writes.
    @discardableResult
    static func prepare(
        metaFiles files: [GeneratedFile],
        tomlPath: URL,
        root: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = root ?? cacheRoot(fileManager: fileManager)
        // 0700 on the root too, not just the per-project dir: a world-listable
        // root leaks app presence + the set of project-hash names to other local
        // users on a shared machine (CR-008).
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let dir = root.appendingPathComponent(projectHash(forToml: tomlPath), isDirectory: true)
        try fileManager.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Re-assert 0700 in case the directory pre-existed with looser bits.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let sig = signature(of: files)
        let sentinel = dir.appendingPathComponent(sentinelName)
        let existing = try? String(contentsOf: sentinel, encoding: .utf8)
        if existing != sig {
            try rewrite(files: files, into: dir, signature: sig, fileManager: fileManager)
        }

        // Always refresh the source-path record's timestamp so an actively-used
        // project never drifts into the eviction grace window.
        let record = dir.appendingPathComponent(sourcePathRecordName)
        let resolved = tomlPath.resolvingSymlinksInPath().standardizedFileURL.path
        try resolved.write(to: record, atomically: true, encoding: .utf8)
        return dir
    }

    /// Wipe and rewrite every generated file plus the sentinel.
    private static func rewrite(
        files: [GeneratedFile],
        into dir: URL,
        signature sig: String,
        fileManager: FileManager
    ) throws {
        // Drop the stale meta directory wholesale so removed modules don't linger.
        let metaDir = dir.appendingPathComponent(MetaFileGenerator.metaDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: metaDir.path) {
            do {
                try fileManager.removeItem(at: metaDir)
            } catch {
                // A removal failure (locked/permission) leaves stale module files
                // that LuaLS would still load; surface it rather than swallow
                // (CR-020).
                Logger.shared.info("LuaLS stale meta-dir removal failed: \(error)")
            }
        }

        let dirPath = dir.standardizedFileURL.path
        for file in files {
            let dest = dir.appendingPathComponent(file.relativePath).standardizedFileURL
            // Reject any relativePath that escapes the cache dir (`..` / absolute).
            // All current paths are compile-time constants, but the public
            // GeneratedFile type offers no guard, so confine writes here (CR-009).
            guard dest.path.hasPrefix(dirPath + "/") else {
                throw LuaLSCacheError.pathEscapesCache(file.relativePath)
            }
            try fileManager.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: dest, atomically: true, encoding: .utf8)
        }
        try sig.write(
            to: dir.appendingPathComponent(sentinelName), atomically: true, encoding: .utf8)
    }

    // MARK: - Eviction

    /// Remove orphaned project cache directories (DATA-N02 AND-predicate): a
    /// directory is deleted only when BOTH its recorded source path no longer
    /// resolves AND its `source-path` record is older than the grace period.
    /// Either condition alone leaves the directory untouched.
    ///
    /// Never throws — eviction is best-effort housekeeping; an unreadable entry
    /// is skipped, not fatal.
    static func evictStale(now: Date, root: URL? = nil, fileManager: FileManager = .default) {
        let root = root ?? cacheRoot(fileManager: fileManager)
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }

        for entry in entries {
            let record = entry.appendingPathComponent(sourcePathRecordName)
            guard let sourcePath = try? String(contentsOf: record, encoding: .utf8) else {
                continue  // no record → not ours / mid-write; leave it alone
            }
            let sourceExists = fileManager.fileExists(atPath: sourcePath)
            let attrs = try? fileManager.attributesOfItem(atPath: record.path)
            let modified = (attrs?[.modificationDate] as? Date) ?? now
            let isOld = now.timeIntervalSince(modified) > evictionGracePeriod
            if !sourceExists && isOld {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

/// Errors raised while preparing the LuaLS cache.
enum LuaLSCacheError: Error, Equatable {
    /// A generated file's `relativePath` resolved outside the cache directory
    /// (absolute path or `..` traversal) — refused rather than written (CR-009).
    case pathEscapesCache(String)
}
