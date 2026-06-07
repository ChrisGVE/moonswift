// File: Sources/MoonSwiftCore/Sources/SourceStore.swift
// Location: MoonSwiftCore/Sources/
// Role: Loads Lua source files from disk and assembles LuaSourceFragment values
//       with full FragmentProvenance. Communicates results back to the AppDriver
//       exclusively through an injected @Sendable callback — it never touches
//       the EventChannel, AppState, or any MoonSwiftTUI type (ARCHITECTURE.md
//       §5.1). All loads are asynchronous; structured-file loading (task 16)
//       plugs in via the same callback shape.
// Upstream: ProjectFile (SourceEntry), CryptoKit (SHA-256)
// Downstream: AppDriver (consumes the callback), RunService, LintService
//             (receive LuaSourceFragment from AppState after it is loaded)

import CryptoKit
import Foundation

// MARK: - SourceStore

/// Loads `.lua` source files from disk, computes provenance, and posts results
/// via an injected `@Sendable` callback.
///
/// **Design constraints (ARCHITECTURE.md §3a, §5.1):**
/// - `SourceStore` never imports `MoonSwiftTUI` or calls `EventChannel`.
/// - The AppDriver constructs the callback; its body wraps the `SourceLoadEvent`
///   into an `AppEvent` and posts it.
/// - Every load is performed on a background `Task`; the callback is the only
///   cross-thread interface.
/// - `MoonSwiftCore` has zero terminal I/O; no print, no stderr, no exit calls.
///
/// **Extensibility for task 16:**
/// `loadLuaFile(at:projectRoot:id:)` handles whole `.lua` files. Task 16 adds
/// a counterpart (`loadStructuredFile(…)`) that uses tree-sitter span location
/// to populate `byteRange` and `lineOffset` for field fragments. Both funnel
/// through the same `callback` type so the AppDriver needs no changes.
public final class SourceStore: Sendable {

    // MARK: Types

    /// Callback type that the AppDriver injects. Receives one `SourceLoadEvent`
    /// per source entry (or per field match for structured files in task 16).
    public typealias LoadCallback = @Sendable (SourceLoadEvent) -> Void

    // MARK: Properties

    private let callback: LoadCallback

    // MARK: Initialiser

    /// Creates a `SourceStore` with the given result callback.
    ///
    /// - Parameter callback: Called once per load outcome on a background
    ///   `Task`. The AppDriver is expected to wrap each `SourceLoadEvent` into
    ///   an `AppEvent` and post it to `EventChannel`.
    public init(callback: @escaping LoadCallback) {
        self.callback = callback
    }

    // MARK: Load all sources

    /// Dispatches a background load task for every `.lua` entry in `entries`.
    ///
    /// Non-`.lua` entries are silently skipped here; task 16 handles structured
    /// files. Each entry produces exactly one `callback` invocation on a
    /// background `Task` (loads are independent and run concurrently).
    ///
    /// - Parameters:
    ///   - entries: The `[[source]]` entries from the decoded `ProjectFile`.
    ///   - projectRoot: Absolute URL of the project root directory. Used to
    ///     resolve project-relative source paths.
    public func loadAll(entries: [SourceEntry], projectRoot: URL) {
        for entry in entries {
            guard entry.fields.isEmpty else {
                // Structured-file entries are handled by task 16; skip here.
                continue
            }
            let path = entry.path
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            Task {
                let event = await Self.loadLuaFile(
                    at: path,
                    projectRoot: projectRoot,
                    id: id
                )
                self.callback(event)
            }
        }
    }

    // MARK: Single file load (internal + testable)

    /// Loads one `.lua` file and returns its `SourceLoadEvent`.
    ///
    /// This is `static` and `async` so tests can call it directly without
    /// constructing a `SourceStore` or wiring a callback.
    ///
    /// **Encoding strategy (PRD F1 error cases):**
    /// 1. Strict UTF-8 decode via `String(bytes:encoding:.utf8)`.
    /// 2. If that fails: permissive lossy decode via `String(decoding:as:)`,
    ///    which replaces invalid byte sequences with `\u{FFFD}`. This preserves
    ///    the file as displayable text when it is "mostly UTF-8" (a common case
    ///    for Lua files authored on different platforms).
    /// 3. If the file cannot be read at all: `.failed(.missing)` or
    ///    `.failed(.failed(diagnostic))` depending on whether `fileExists`.
    ///
    /// **Hash:** SHA-256 is computed over the raw `Data` bytes before decoding,
    /// matching the bytes that F8 write-back will re-hash for the conflict guard.
    ///
    /// - Parameters:
    ///   - path: Project-relative path to the `.lua` file.
    ///   - projectRoot: Absolute URL of the project root.
    ///   - id: `SourceID` to use in the returned event.
    /// - Returns: A `SourceLoadEvent` describing the outcome.
    static func loadLuaFile(
        at path: String,
        projectRoot: URL,
        id: SourceID
    ) async -> SourceLoadEvent {
        let fileURL = projectRoot.appendingPathComponent(path)

        // --- Existence check (produces .missing, not .failed) ---
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failed(id: id, state: .missing)
        }

        // --- Read raw bytes ---
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let diagnostic = Diagnostic(
                severity: .error,
                line: 0,
                column: nil,
                code: nil,
                message: "Cannot read \(path): \(error.localizedDescription)",
                source: .sourceLoad
            )
            return .failed(id: id, state: .failed(diagnostic))
        }

        // --- SHA-256 hash (over raw bytes, before decode) ---
        let contentHash = SHA256.hash(data: data)

        // --- UTF-8 decode: strict first, permissive fallback ---
        let code: String
        if let strict = String(bytes: data, encoding: .utf8) {
            code = strict
        } else {
            // Permissive: replaces invalid sequences with U+FFFD. This keeps
            // the file viewable in the code pane while the user corrects the
            // encoding; a warning diagnostic is not emitted here because the
            // UX spec does not define one for non-UTF-8 .lua files — the
            // fragment is loaded and usable (lint/run may produce their own
            // errors). If future UX work adds a warning, add it here.
            code = String(decoding: data, as: UTF8.self)
        }

        // --- Build provenance ---
        let provenance = FragmentProvenance(
            file: fileURL,
            jsonpath: nil,             // whole .lua file — no JSONPath
            document: 0,               // not a multi-document format
            byteRange: 0..<data.count, // span = entire file
            lineOffset: 0,             // fragment line 1 = file line 1
            contentHash: contentHash
        )

        let fragment = LuaSourceFragment(code: code, provenance: provenance)
        return .loaded(id: id, fragment: fragment)
    }
}

