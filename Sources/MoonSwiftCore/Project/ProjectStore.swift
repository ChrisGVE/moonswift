// File: Sources/MoonSwiftCore/Project/ProjectStore.swift
// Role: Public entry point for moonswift.toml I/O. Owns all project-file reads
//       and writes. Never touches the terminal. Composes ProjectFileCodec
//       (decode/save) and ProjectValidation (semantic rules) into one cohesive
//       load/save/init API.
//
//       ProjectStore is the single component that reads or writes moonswift.toml
//       (ARCHITECTURE.md §2, ProjectStore row). The reducer sees only the typed
//       model and validation Diagnostics.
//
// Upstream: ProjectFileCodec, ProjectValidation, Foundation (file I/O)
// Downstream: Main/CLI (calls load at startup), AppDriver (via Effect.loadProject
//             / Effect.reloadProject)

import Foundation
import TOMLKit

// MARK: - ProjectStore

/// Loads, validates, and saves `moonswift.toml`. All I/O is synchronous;
/// callers that need off-thread execution wrap in a `Task`.
///
/// The type is a namespace (enum) because all methods are static — there is no
/// per-instance mutable state. File-system access is via `Foundation.FileManager`
/// and `String(contentsOf:encoding:)`.
public enum ProjectStore {

    // MARK: - Load result

    /// The outcome of a `load(at:)` call.
    public enum LoadResult: Sendable {

        /// Successfully decoded and (possibly) validated with diagnostics.
        /// Diagnostics may include warnings; the project is usable.
        case loaded(ProjectFile, [Diagnostic])

        /// The TOML was syntactically invalid (malformed TOML).
        /// The project cannot be used until fixed.
        case malformed(Diagnostic)

        /// The file was decoded but `lua_version` is not "5.4". The project
        /// loads read-only; run and lint are disabled.
        case unsupportedVersion(ProjectFile, [Diagnostic])
    }

    // MARK: - Standard file name

    /// File name for the project configuration file.
    public static let fileName = "moonswift.toml"

    // MARK: - Load

    /// Loads and validates the project file at `projectDirectory/moonswift.toml`.
    ///
    /// - Parameters:
    ///   - projectDirectory: The project root directory URL.
    ///   - extraModulesAllowList: Allow-list for `lint.extra_modules` validation.
    ///     Defaults to `LuaModuleCatalog.v0.optInNames` — the canonical set of
    ///     valid opt-in module names. Pass a custom closure in tests.
    /// - Returns: A `LoadResult` describing the decoded file and any diagnostics.
    public static func load(
        at projectDirectory: URL,
        extraModulesAllowList: () -> Set<String> = { LuaModuleCatalog.v0.optInNames }
    ) -> LoadResult {
        let fileURL = projectDirectory.appendingPathComponent(fileName)
        return load(from: fileURL, projectRoot: projectDirectory, extraModulesAllowList: extraModulesAllowList)
    }

    /// Loads and validates the project file at an explicit `fileURL`.
    ///
    /// - Parameter projectRoot: The project root directory. When non-nil, the
    ///   symlink-escape check in `ProjectValidation` resolves candidate source
    ///   paths against this root (CR-030). Pass `nil` when the project root is
    ///   unknown (e.g. in-memory loads from a raw TOML string).
    public static func load(
        from fileURL: URL,
        projectRoot: URL? = nil,
        extraModulesAllowList: () -> Set<String> = { LuaModuleCatalog.v0.optInNames }
    ) -> LoadResult {

        // 1. Read the file from disk.
        let tomlString: String
        do {
            tomlString = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return .malformed(
                .projectError(
                    "could not read moonswift.toml: \(error.localizedDescription)"
                )
            )
        }

        return loadFromString(
            tomlString,
            projectRoot: projectRoot,
            extraModulesAllowList: extraModulesAllowList
        )
    }

    /// Loads and validates from a TOML string (useful for tests and in-memory
    /// operations where no file URL is needed).
    ///
    /// - Parameters:
    ///   - tomlString: The raw TOML content.
    ///   - projectRoot: Optional project root URL for symlink-escape validation
    ///     (CR-030). Pass `nil` when no filesystem context is available.
    ///   - extraModulesAllowList: Allow-list for `lint.extra_modules` validation.
    ///     Defaults to `LuaModuleCatalog.v0.optInNames`.
    public static func loadFromString(
        _ tomlString: String,
        projectRoot: URL? = nil,
        extraModulesAllowList: () -> Set<String> = { LuaModuleCatalog.v0.optInNames }
    ) -> LoadResult {

        // 2. Decode via codec.
        // ProjectFileCodec.decode uses typed throws (CodecError), so we catch
        // that exact type. Swift 6 typed throws means the catch is exhaustive.
        let decoded: (projectFile: ProjectFile, unknownKeyDiagnostics: [Diagnostic])
        let rawRunConfig: String?
        do {
            decoded = try ProjectFileCodec.decode(tomlString)
            // Extract the raw run.config string for explicit validation.
            rawRunConfig = extractRawRunConfig(from: tomlString)
        } catch {
            // `error` is `CodecError` (typed throws from ProjectFileCodec.decode).
            switch error {
            case .parseFailure(let underlying):
                return .malformed(
                    .projectError(
                        "moonswift.toml is not valid TOML: \(underlying.localizedDescription)"
                    )
                )
            case .missingRequiredKey(let key):
                return .malformed(
                    .projectError(
                        "moonswift.toml is missing required key \"\(key)\""
                    )
                )
            }
        }

        let projectFile = decoded.projectFile

        // 3. Run full validation.
        let diagnostics = ProjectValidation.validate(
            projectFile,
            projectRoot: projectRoot,
            rawRunConfig: rawRunConfig,
            unknownKeyDiagnostics: decoded.unknownKeyDiagnostics,
            extraModulesAllowList: extraModulesAllowList
        )

        // 4. Check for unsupported version (read-only load).
        if projectFile.luaVersion != "5.4" {
            return .unsupportedVersion(projectFile, diagnostics)
        }

        return .loaded(projectFile, diagnostics)
    }

    // MARK: - Save

    /// Writes `projectFile` to disk, preserving unknown keys from the existing
    /// file.
    ///
    /// - Parameters:
    ///   - projectFile: The updated project file to serialise.
    ///   - fileURL: Destination file URL (typically `projectRoot/moonswift.toml`).
    /// - Throws: `StoreError.saveFailure` when the file cannot be written, or
    ///   `CodecError` when the existing file fails to parse (re-thrown).
    public static func save(_ projectFile: ProjectFile, to fileURL: URL) throws {

        // Read existing content (for unknown-key preservation).
        let existingContent: String? = try? String(contentsOf: fileURL, encoding: .utf8)

        // Encode via codec (typed throws CodecError).
        let newContent: String
        do {
            newContent = try ProjectFileCodec.save(projectFile, into: existingContent)
        } catch {
            // `error` is `CodecError` (typed throws from ProjectFileCodec.save).
            throw StoreError.codecFailure(error)
        }

        // Write atomically.
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.saveFailure(url: fileURL, underlying: error)
        }
    }

    // MARK: - Init (write minimal project file)

    /// Writes a minimal valid `moonswift.toml` to `projectDirectory`.
    ///
    /// Fails if the file already exists (does not overwrite).
    ///
    /// - Parameters:
    ///   - projectDirectory: The project root directory.
    /// - Returns: The URL of the written file.
    /// - Throws: `StoreError.fileAlreadyExists` if the file exists;
    ///   `StoreError.saveFailure` on write error.
    @discardableResult
    public static func initialize(at projectDirectory: URL) throws -> URL {
        let fileURL = projectDirectory.appendingPathComponent(fileName)

        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StoreError.fileAlreadyExists(url: fileURL)
        }

        let minimal = ProjectFile(luaVersion: "5.4")
        let content: String
        do {
            content = try ProjectFileCodec.save(minimal, into: nil)
        } catch {
            // `error` is `CodecError` (typed throws from ProjectFileCodec.save).
            throw StoreError.codecFailure(error)
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw StoreError.saveFailure(url: fileURL, underlying: error)
        }

        return fileURL
    }

    // MARK: - Private helpers

    /// Extracts the raw `run.config` string from TOML without full decode,
    /// so `ProjectValidation` can check for unrecognised values.
    private static func extractRawRunConfig(from tomlString: String) -> String? {
        // Parse minimally to extract just the run table's config key.
        // We accept parse failure silently here — the main decode will have
        // already caught it before this is called.
        guard let table = try? TOMLKit.TOMLTable(string: tomlString) else { return nil }
        return table["run"]?.table?["config"]?.string
    }
}

// MARK: - StoreError

/// Errors emitted by `ProjectStore`.
public enum StoreError: Error, Sendable {

    /// The file already exists; `initialize` will not overwrite.
    case fileAlreadyExists(url: URL)

    /// A codec error during save.
    case codecFailure(CodecError)

    /// The file could not be written to disk.
    case saveFailure(url: URL, underlying: Error)
}
