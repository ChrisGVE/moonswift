// File: Sources/MoonSwiftCore/Sources/SourceStore.swift
// Location: MoonSwiftCore/Sources/
// Role: Loads Lua source files from disk and assembles LuaSourceFragment values
//       with full FragmentProvenance. Communicates results back to the AppDriver
//       exclusively through an injected @Sendable callback — it never touches
//       the EventChannel, AppState, or any MoonSwiftTUI type (ARCHITECTURE.md
//       §5.1). All loads are asynchronous; both `.lua` files and structured files
//       (JSON/YAML/TOML) funnel through the same callback shape.
// Upstream: ProjectFile (SourceEntry), CryptoKit (SHA-256), SpanLocator (task 16)
// Downstream: AppDriver (consumes the callback), RunService, LintService
//             (receive LuaSourceFragment from AppState after it is loaded)

import CryptoKit
import Foundation
import Yams

// MARK: - File size limits (CR-028)

/// Maximum byte size for a whole `.lua` source file.
///
/// 10 MiB. Files larger than this are rejected with a `.failed` diagnostic
/// rather than read into memory. This prevents OOM conditions from
/// `/dev/zero`, oversized blobs, or pipes with no natural EOF.
/// Adjust here (and update docs) if legitimate large Lua sources are needed.
let sourceFileSizeLimit: Int = 10 * 1_024 * 1_024  // 10 MiB

/// Maximum byte size for a structured data file (JSON / YAML / TOML).
///
/// 50 MiB. Structured files are expected to be config/data files; anything
/// larger is almost certainly not a config file and would cause excessive
/// memory use during tree decode. Adjust here (and update docs) if needed.
let structuredFileSizeLimit: Int = 50 * 1_024 * 1_024  // 50 MiB

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
/// **Cancellation (CR-013):**
/// `loadAll` stores every background task handle in `activeTasks`. Calling
/// `cancelAll()` cancels all in-flight tasks from the previous `loadAll` before
/// the next reload starts, preventing stale callbacks from arriving after a
/// project reload. The AppDriver calls `cancelAll()` in the `reloadProject`
/// effect handler before dispatching a new `loadAll`.
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

    /// Lock protecting `activeTasks`. All mutations happen under this lock.
    private let tasksLock = NSLock()

    /// Background task handles for the current `loadAll` invocation.
    ///
    /// Stored so `cancelAll()` can cancel in-flight loads when the project is
    /// reloaded. Guarded by `tasksLock`.
    ///
    /// `nonisolated(unsafe)` is required because `SourceStore` is `Sendable`
    /// and Swift 6 strict concurrency cannot see that `tasksLock` serialises
    /// all accesses. The lock IS the synchronisation mechanism. (CR-013)
    nonisolated(unsafe) private var activeTasks: [Task<Void, Never>] = []

    // MARK: Initialiser

    /// Creates a `SourceStore` with the given result callback.
    ///
    /// - Parameter callback: Called once per load outcome on a background
    ///   `Task`. The AppDriver is expected to wrap each `SourceLoadEvent` into
    ///   an `AppEvent` and post it to `EventChannel`.
    public init(callback: @escaping LoadCallback) {
        self.callback = callback
    }

    // MARK: Cancellation

    /// Cancels all background load tasks started by the most recent `loadAll`.
    ///
    /// Call this before dispatching a new `loadAll` (e.g., in the
    /// `reloadProject` effect handler in AppDriver) so that callbacks from the
    /// previous load batch do not arrive after the new project is loaded.
    ///
    /// Cancellation is cooperative: tasks check `Task.isCancelled` at `await`
    /// suspension points. A task that is already past its last suspension will
    /// complete and invoke the callback; that is unavoidable but harmless because
    /// the AppDriver ignores stale events for the superseded project.
    public func cancelAll() {
        tasksLock.lock()
        let tasks = activeTasks
        activeTasks = []
        tasksLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    // MARK: Load all sources

    /// Dispatches background load tasks for every entry in `entries`.
    ///
    /// - Whole `.lua` entries (empty `fields`): dispatched to `loadLuaFile`.
    /// - Structured-file entries (non-empty `fields`): dispatched to
    ///   `loadStructuredFile`. Each field designation produces one callback
    ///   invocation per match (wildcards may yield multiple fragments) or one
    ///   failure event.
    ///
    /// All spawned task handles are stored in `activeTasks` so that
    /// `cancelAll()` can cancel the batch on a subsequent reload. Call
    /// `cancelAll()` before `loadAll` to discard any in-flight tasks from
    /// the previous project load. (CR-013)
    ///
    /// - Parameters:
    ///   - entries: The `[[source]]` entries from the decoded `ProjectFile`.
    ///   - projectRoot: Absolute URL of the project root directory.
    public func loadAll(entries: [SourceEntry], projectRoot: URL) {
        var newTasks: [Task<Void, Never>] = []

        for entry in entries {
            if entry.fields.isEmpty {
                // Whole .lua file.
                let path = entry.path
                let id = SourceID(path: path, jsonpath: nil, document: 0)
                let task = Task {
                    guard !Task.isCancelled else { return }
                    let event = await Self.loadLuaFile(
                        at: path,
                        projectRoot: projectRoot,
                        id: id
                    )
                    guard !Task.isCancelled else { return }
                    self.callback(event)
                }
                newTasks.append(task)
            } else {
                // Structured file with field designations.
                let path = entry.path
                let fields = entry.fields
                let task = Task {
                    guard !Task.isCancelled else { return }
                    let events = await Self.loadStructuredFile(
                        at: path,
                        projectRoot: projectRoot,
                        fields: fields
                    )
                    guard !Task.isCancelled else { return }
                    for event in events {
                        self.callback(event)
                    }
                }
                newTasks.append(task)
            }
        }

        tasksLock.lock()
        activeTasks = newTasks
        tasksLock.unlock()
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

        // --- File size guard (CR-028): reject oversized files before reading ---
        // attributesOfItem reads only the file metadata — no I/O on file content.
        // This prevents OOM from /dev/zero, pipes, or accidental huge files.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let fileSize = attrs[.size] as? Int,
            fileSize > sourceFileSizeLimit
        {
            let limitMiB = sourceFileSizeLimit / (1_024 * 1_024)
            let diagnostic = Diagnostic(
                severity: .error,
                line: 0,
                column: nil,
                code: nil,
                message: "Cannot read \(path): file size exceeds the \(limitMiB) MiB limit",
                source: .sourceLoad
            )
            return .failed(id: id, state: .failed(diagnostic))
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
            jsonpath: nil,  // whole .lua file — no JSONPath
            document: 0,  // not a multi-document format
            byteRange: 0..<data.count,  // span = entire file
            lineOffset: 0,  // fragment line 1 = file line 1
            contentHash: contentHash
        )

        let fragment = LuaSourceFragment(code: code, provenance: provenance)
        return .loaded(id: id, fragment: fragment)
    }

    // MARK: - Structured file load (task 16)

    /// Loads one structured file (JSON/YAML/TOML) and returns one `SourceLoadEvent`
    /// per field designation.
    ///
    /// For each `FieldDesignation` in `fields`:
    /// 1. Reads file bytes + SHA-256 hash.
    /// 2. Decodes to `TreeValue` using the format-appropriate decoder.
    /// 3. Evaluates the JSONPath designation.
    /// 4. For each match:
    ///    a. Verifies the value is `.string` (else `⚠ expected string` warning).
    ///    b. Locates the byte span via tree-sitter (`SpanLocator`).
    ///    c. Checks for YAML aliases at the designated path (error).
    ///    d. Cross-checks span text against decoded value (R7).
    ///    e. Posts `.loaded` with a `FragmentProvenance` carrying all location data.
    ///
    /// Error/warning cases (UX spec §4.2, exact message strings):
    /// - Malformed file: `.failed` with `.failed(Diagnostic)` severity `.error`.
    /// - Unresolved path: `.failed` with `.failed(Diagnostic)` severity `.warning`.
    /// - Non-string value: `.failed` with `.failed(Diagnostic)` "expected string".
    /// - YAML alias at path: `.failed` with `.failed(Diagnostic)` "designate the anchor".
    /// - Span mismatch (R7): `.failed` with `.failed(Diagnostic)` span-mismatch message.
    ///
    /// - Parameters:
    ///   - path: Project-relative path to the structured file.
    ///   - projectRoot: Absolute URL of the project root.
    ///   - fields: The field designations from the `SourceEntry`.
    /// - Returns: An array of `SourceLoadEvent` values — one per match or one
    ///   failure per unresolved/error designation.
    static func loadStructuredFile(
        at path: String,
        projectRoot: URL,
        fields: [FieldDesignation]
    ) async -> [SourceLoadEvent] {
        let fileURL = projectRoot.appendingPathComponent(path)
        let filename = fileURL.lastPathComponent

        // --- Existence check ---
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // One .missing event for the whole file (not per field).
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            return [.failed(id: id, state: .missing)]
        }

        // --- File size guard (CR-028): reject oversized files before reading ---
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let fileSize = attrs[.size] as? Int,
            fileSize > structuredFileSizeLimit
        {
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            let limitMiB = structuredFileSizeLimit / (1_024 * 1_024)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): file size exceeds the \(limitMiB) MiB limit",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- Read raw bytes ---
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): \(error.localizedDescription)",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- SHA-256 hash (over raw bytes, whole file) ---
        let contentHash = SHA256.hash(data: data)

        // --- Determine format from extension ---
        let ext = fileURL.pathExtension
        guard let format = StructuredFileFormat.from(extension: ext) else {
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): unsupported format .\(ext)",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- UTF-8 decode ---
        guard let text = String(data: data, encoding: .utf8) else {
            let id = SourceID(path: path, jsonpath: nil, document: 0)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): file is not valid UTF-8",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- Process each field designation ---
        var events: [SourceLoadEvent] = []
        for field in fields {
            let fieldEvents = processField(
                field: field,
                path: path,
                fileURL: fileURL,
                text: text,
                data: data,
                format: format,
                contentHash: contentHash,
                filename: filename
            )
            events.append(contentsOf: fieldEvents)
        }
        return events
    }

    // MARK: - Per-field processing

    /// Process a single `FieldDesignation` and return the resulting events.
    ///
    /// This is broken out of `loadStructuredFile` so each field is self-contained
    /// and the parent function stays readable.
    private static func processField(
        field: FieldDesignation,
        path: String,
        fileURL: URL,
        text: String,
        data: Data,
        format: StructuredFileFormat,
        contentHash: CryptoKit.SHA256Digest,
        filename: String
    ) -> [SourceLoadEvent] {
        let jsonpathStr = field.jsonpath
        let docIndex = field.document

        // --- Parse the JSONPath expression ---
        let expression: JSONPathExpression
        do {
            expression = try JSONPathExpression(parsing: jsonpathStr)
        } catch {
            let id = SourceID(path: path, jsonpath: jsonpathStr, document: docIndex)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): invalid JSONPath \"\(jsonpathStr)\"",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- Decode the file to TreeValue ---
        let tree: TreeValue
        do {
            switch format {
            case .json:
                tree = try decodeJSON(text)
            case .yaml:
                tree = try decodeYAML(text, document: docIndex)
            case .toml:
                tree = try decodeTOML(text)
            }
        } catch {
            let id = SourceID(path: path, jsonpath: jsonpathStr, document: docIndex)
            let diag = Diagnostic(
                severity: .error,
                message: "✖ Cannot parse \(filename): \(error.localizedDescription)",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- Evaluate the JSONPath designation ---
        let matches = expression.evaluate(on: tree)

        if matches.isEmpty {
            let id = SourceID(
                path: path,
                jsonpath: expression.normalized,
                document: docIndex
            )
            let diag = Diagnostic(
                severity: .warning,
                message: "⚠ \(filename): JSONPath \"\(expression.normalized)\" matched no fields",
                source: .sourceLoad
            )
            return [.failed(id: id, state: .failed(diag))]
        }

        // --- Process each match ---
        var events: [SourceLoadEvent] = []
        for (normalizedPath, value) in matches {
            let normalizedJSONPath = normalizedPath.description
            let id = SourceID(
                path: path,
                jsonpath: normalizedJSONPath,
                document: docIndex
            )
            // Verify the value is a string.
            guard case .string(let code) = value else {
                let typeName = treeValueTypeName(value)
                let diag = Diagnostic(
                    severity: .warning,
                    message:
                        "⚠ \(filename): JSONPath \"\(normalizedJSONPath)\" resolves to \(typeName), expected string",
                    source: .sourceLoad
                )
                events.append(.failed(id: id, state: .failed(diag)))
                continue
            }

            // --- Locate byte span via tree-sitter ---
            let spanLocation: SpanLocation
            do {
                spanLocation = try SpanLocator.locateSpan(
                    data: data,
                    text: text,
                    format: format,
                    path: normalizedPath.steps,
                    document: docIndex
                )
            } catch SpanLocatorError.yamlAliasAtDesignatedPath {
                let diag = Diagnostic(
                    severity: .error,
                    message: "✖ \(filename): \"\(normalizedJSONPath)\" is a YAML alias — designate the anchor",
                    source: .sourceLoad
                )
                events.append(.failed(id: id, state: .failed(diag)))
                continue
            } catch {
                // Span location failed; post a degraded loaded event with the
                // whole-file span as a fallback (byteRange = 0..<data.count,
                // lineOffset = 0). This is sub-optimal but keeps the fragment
                // usable. An error diagnostic is posted to signal the problem.
                let diag = Diagnostic(
                    severity: .error,
                    message: "✖ \(filename): span location failed for \"\(normalizedJSONPath)\": \(error)",
                    source: .sourceLoad
                )
                events.append(.failed(id: id, state: .failed(diag)))
                continue
            }

            // --- Build provenance and fragment ---
            let provenance = FragmentProvenance(
                file: fileURL,
                jsonpath: normalizedJSONPath,
                document: docIndex,
                byteRange: spanLocation.byteRange,
                lineOffset: spanLocation.lineOffset,
                contentHash: contentHash
            )
            let fragment = LuaSourceFragment(code: code, provenance: provenance)
            events.append(.loaded(id: id, fragment: fragment))
        }
        return events
    }

    // MARK: - Helpers

    /// Human-readable type name for `TreeValue` cases (used in diagnostics).
    private static func treeValueTypeName(_ value: TreeValue) -> String {
        switch value {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "float"
        case .bool: return "boolean"
        case .array: return "array"
        case .map: return "object"
        case .null: return "null"
        }
    }
}
