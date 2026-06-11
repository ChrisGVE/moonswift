// File: Sources/MoonSwiftTUI/Nvim/WriteBackCoordinator.swift
// Location: MoonSwiftTUI/Nvim/
// Role: Async write-back pipeline shared by the nvim-embed path (F8b) and the
//       $EDITOR fallback path. Reads the current file from disk, checks for
//       external conflicts, re-locates the byte span (structured files), splices
//       the edited text into the host format via SpanSplicer, and atomically
//       writes the result. A second validateReadable call immediately before
//       the write closes the TOCTOU symlink-swap window.
// Upstream: EditorBridge (nvim path), AppDriver.$EDITOR fallback,
//           LintServiceProtocol (syntaxPrePass injection),
//           SourceStore (validateReadable, structuredFileSizeLimit),
//           SpanSplicer (splice methods), SpanLocator (re-location)
// Downstream: Caller posts AppEvent.writeBackSucceeded / writeBackFailed
//             with the returned WriteBackResult.

import Foundation
import MoonSwiftCore

// MARK: - WriteBackCoordinator

/// Stateless async namespace for the F8 write-back shared contract.
///
/// `write` runs the full dispatch pipeline:
/// 1. Size cap on `editedText`.
/// 2. Syntax pre-pass via the injected `lintService`.
/// 3. First `validateReadable` guard.
/// 4. Blocking read of current file bytes (background `DispatchQueue`).
/// 5. Optional conflict check (`SpanSplicer.hasConflict`).
/// 6. Format dispatch: `.lua` overwrite, or structured re-locate + splice.
/// 7. Second `validateReadable` TOCTOU guard.
/// 8. Atomic write (background `DispatchQueue`).
///
/// All blocking I/O is dispatched onto a dedicated serial `DispatchQueue`
/// wrapped in `withCheckedThrowingContinuation`, keeping cooperative-pool
/// threads free.
public enum WriteBackCoordinator {

    // MARK: - Types

    /// Result outcome for a single write-back attempt.
    public enum Outcome: Sendable, Equatable {
        /// The write completed successfully; `WriteBackResult.newData` is non-nil.
        case success
        /// `SourceStore.validateReadable` rejected the file before or after the read.
        case validateReadableRejection(SourceStore.FileReadRejection)
        /// `SpanSplicer` returned an error (reparse, span-leak, field-mismatch,
        /// unrepresentable — but NOT a syntax pre-pass failure; see below).
        case spliceError(SpliceError)
        /// A blocking I/O operation failed or the file bytes were not valid UTF-8.
        case ioFailure(String)
        /// The file was modified externally between load and write-back.
        case conflictDetected
        /// The syntax pre-pass (step 2) failed with a lint diagnostic.
        ///
        /// Distinct from `spliceError` so AppDriver can map it directly to
        /// `AppEvent.writeBackBlocked(diagnostic)` without inspecting string
        /// content (CR-006 heuristic elimination).
        case syntaxPrePassBlocked(Diagnostic)
    }

    /// The return value of `write`.
    public struct WriteBackResult: Sendable {
        /// The outcome of the write-back attempt.
        public let outcome: Outcome
        /// The new file bytes — non-nil only when `outcome == .success`.
        public let newData: Data?
    }

    // MARK: - Background I/O queue

    /// Serial queue for blocking `Data(contentsOf:)` and `Data.write` calls,
    /// keeping cooperative-pool threads free per ARCHITECTURE.md §10.4.9.
    private static let ioQueue = DispatchQueue(
        label: "com.moonswift.writeback-io",
        qos: .userInitiated
    )

    // MARK: - Entry point

    /// Execute the full write-back pipeline for `fragment`.
    ///
    /// - Parameters:
    ///   - fragment:    The loaded source fragment whose provenance points to the
    ///                  on-disk file that will be updated.
    ///   - editedText:  The new Lua source text produced by the editor.
    ///   - projectRoot: The project root URL used by `validateReadable` for the
    ///                  escape guard.
    ///   - lintService: Injected lint service; only `syntaxPrePass` is called.
    ///   - force:       When `true`, the conflict check (step 5) is skipped.
    /// - Returns: A `WriteBackResult` describing the outcome and the new bytes.
    public static func write(
        fragment: LuaSourceFragment,
        editedText: String,
        projectRoot: URL,
        lintService: any LintServiceProtocol,
        force: Bool
    ) async -> WriteBackResult {

        // Step 1: Cap editedText at structuredFileSizeLimit (50 MiB).
        if editedText.utf8.count > structuredFileSizeLimit {
            return WriteBackResult(outcome: .ioFailure("Edited text exceeds size limit"), newData: nil)
        }

        // Step 2: Syntax pre-pass.
        // On failure return `.syntaxPrePassBlocked(diagnostic)` so the caller can
        // map it directly to `AppEvent.writeBackBlocked` without any string heuristic
        // (CR-006: eliminates the `reason.contains("line")` pattern in AppDriver).
        let prePassFragment = LuaSourceFragment(
            code: editedText,
            provenance: fragment.provenance
        )
        if let diagnostic = lintService.syntaxPrePass(prePassFragment) {
            return WriteBackResult(outcome: .syntaxPrePassBlocked(diagnostic), newData: nil)
        }

        // Step 3: First validateReadable — CR-028/CR-030 guard.
        if let rejection = SourceStore.validateReadable(
            at: fragment.provenance.file,
            projectRoot: projectRoot,
            sizeLimit: structuredFileSizeLimit
        ) {
            return WriteBackResult(outcome: .validateReadableRejection(rejection), newData: nil)
        }

        // Step 4: Blocking read on background queue.
        let currentData: Data
        do {
            currentData = try await readFile(at: fragment.provenance.file)
        } catch {
            return WriteBackResult(
                outcome: .ioFailure("Read failed: \(error.localizedDescription)"),
                newData: nil
            )
        }

        // Step 5: Conflict check (unless force).
        if !force {
            if SpanSplicer.hasConflict(
                currentData: currentData,
                expected: fragment.provenance.contentHash
            ) {
                return WriteBackResult(outcome: .conflictDetected, newData: nil)
            }
        }

        // Step 6: Format dispatch.
        let spliceResult = performSplice(
            fragment: fragment,
            editedText: editedText,
            currentData: currentData
        )
        let newData: Data
        switch spliceResult {
        case .success(let data):
            newData = data
        case .failure(let spliceError):
            return WriteBackResult(outcome: .spliceError(spliceError), newData: nil)
        }

        // Step 7: Second validateReadable — TOCTOU guard before write.
        if let rejection = SourceStore.validateReadable(
            at: fragment.provenance.file,
            projectRoot: projectRoot,
            sizeLimit: structuredFileSizeLimit
        ) {
            return WriteBackResult(outcome: .validateReadableRejection(rejection), newData: nil)
        }

        // Step 8: Atomic write on background queue.
        do {
            try await writeFile(data: newData, to: fragment.provenance.file)
        } catch {
            return WriteBackResult(
                outcome: .ioFailure("Write failed: \(error.localizedDescription)"),
                newData: nil
            )
        }

        return WriteBackResult(outcome: .success, newData: newData)
    }

    // MARK: - Format dispatch (step 6)

    /// Splice `editedText` into `currentData` according to the format derived
    /// from the fragment's file extension.
    ///
    /// For `.lua` (nil jsonpath): full overwrite via `SpanSplicer.overwriteLua`.
    /// For JSON/YAML/TOML: re-locate the span on `currentData` (the stale
    /// `provenance.byteRange` is never reused) then delegate to the appropriate
    /// `SpanSplicer` method.
    ///
    /// YAML receives `editedText` with ONE trailing `\n` stripped to satisfy the
    /// `|-` chomping invariant (without the strip, validation-3 returns
    /// `.fieldMismatch`).
    private static func performSplice(
        fragment: LuaSourceFragment,
        editedText: String,
        currentData: Data
    ) -> Result<Data, SpliceError> {

        let ext = fragment.provenance.file.pathExtension

        // Whole .lua file — full overwrite, no re-location needed.
        guard let format = StructuredFileFormat.from(extension: ext) else {
            return .success(SpanSplicer.overwriteLua(editedText: editedText))
        }

        // Structured format — re-locate span on currentData.
        guard let jsonpath = fragment.provenance.jsonpath else {
            // A structured extension with no jsonpath is treated as full overwrite.
            return .success(SpanSplicer.overwriteLua(editedText: editedText))
        }

        let spanResult = relocateSpan(
            currentData: currentData,
            jsonpath: jsonpath,
            format: format,
            document: fragment.provenance.document
        )
        let byteRange: Range<Int>
        switch spanResult {
        case .success(let range):
            byteRange = range
        case .failure(let spliceError):
            return .failure(spliceError)
        }

        switch format {
        case .json:
            return SpanSplicer.spliceJSON(
                editedText: editedText,
                into: currentData,
                byteRange: byteRange,
                jsonpath: jsonpath,
                document: fragment.provenance.document
            )
        case .yaml:
            let strippedText = stripOneTrailingNewline(editedText)
            return SpanSplicer.spliceYAML(
                editedText: strippedText,
                into: currentData,
                byteRange: byteRange,
                jsonpath: jsonpath,
                document: fragment.provenance.document
            )
        case .toml:
            return SpanSplicer.spliceTOML(
                editedText: editedText,
                into: currentData,
                byteRange: byteRange,
                jsonpath: jsonpath,
                document: fragment.provenance.document
            )
        }
    }

    // MARK: - Re-location pipeline

    /// Re-locate the byte span for `jsonpath` in `currentData`.
    ///
    /// Always re-locates from the live `currentData` — never trusts the stale
    /// `provenance.byteRange` (an external edit may have shifted bytes since load
    /// time). This is the binding contract from ARCHITECTURE.md §10.4.9.
    private static func relocateSpan(
        currentData: Data,
        jsonpath: String,
        format: StructuredFileFormat,
        document: Int
    ) -> Result<Range<Int>, SpliceError> {
        // 1. Parse the JSONPath expression.
        let expression: JSONPathExpression
        do {
            expression = try JSONPathExpression(parsing: jsonpath)
        } catch {
            return .failure(.reparseFailed("Invalid JSONPath: \(error.localizedDescription)"))
        }

        // 2. Decode current bytes to a String, then to TreeValue.
        guard let text = String(data: currentData, encoding: .utf8) else {
            return .failure(.reparseFailed("File bytes are not valid UTF-8"))
        }
        let tree: TreeValue
        do {
            tree = try decodeTree(text, format: format, document: document)
        } catch {
            return .failure(.reparseFailed("Decode failed: \(error.localizedDescription)"))
        }

        // 3. Evaluate to get concrete resolved-step paths.
        let matches = expression.evaluate(on: tree)
        guard let firstMatch = matches.first else {
            return .failure(.reparseFailed("JSONPath matched no node in current data"))
        }

        // 4. Extract [ResolvedStep] from the NormalizedPath.
        let resolvedPath: [ResolvedStep] = firstMatch.path.steps

        // 5. Locate the byte span via tree-sitter.
        let spanLocation: SpanLocation
        do {
            spanLocation = try SpanLocator.locateSpan(
                in: currentData,
                format: format,
                path: resolvedPath,
                document: document
            )
        } catch {
            return .failure(.reparseFailed("Span location failed: \(error.localizedDescription)"))
        }

        return .success(spanLocation.byteRange)
    }

    // MARK: - YAML trailing-newline strip

    /// Strip exactly one trailing `\n` from `text` if present.
    ///
    /// The YAML `|-` chomping indicator drops a trailing newline from the stored
    /// scalar value. Without this strip, `spliceYAML` validation-3 would return
    /// `.fieldMismatch` because the re-extracted value would not equal `editedText`.
    private static func stripOneTrailingNewline(_ text: String) -> String {
        if text.hasSuffix("\n") {
            return String(text.dropLast())
        }
        return text
    }

    // MARK: - Decode helpers

    /// Decode `text` in the given `format`, selecting the correct decoder.
    ///
    /// `internal` visibility allows `AppDriver.buildDiffView` to call this
    /// instead of duplicating the switch (CR-031 readability fix).
    static func decodeTree(
        _ text: String,
        format: StructuredFileFormat,
        document: Int
    ) throws -> TreeValue {
        switch format {
        case .json: return try decodeJSON(text)
        case .yaml: return try decodeYAML(text, document: document)
        case .toml: return try decodeTOML(text)
        }
    }

    // MARK: - Blocking I/O helpers

    /// Read the file at `url` on the background I/O queue.
    ///
    /// Re-checks the file size immediately before reading to guard against a file
    /// growing past `structuredFileSizeLimit` between the step-3 `validateReadable`
    /// call and the actual read (CR-029). Throws an `IOSizeError` on oversize.
    private static func readFile(at url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    // Re-check size to close the gap between validateReadable (step 3)
                    // and the actual read (step 4). `.mappedIfSafe` is intentionally
                    // avoided here: we need the byte count before mapping and the
                    // file attr call is cheap compared to a multi-MiB read.
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let fileSize = (attrs[.size] as? Int) ?? 0
                    if fileSize > structuredFileSizeLimit {
                        continuation.resume(
                            throwing: ReadFileSizeError(
                                message:
                                    "File size \(fileSize) exceeds the \(structuredFileSizeLimit / (1024 * 1024)) MiB limit"
                            )
                        )
                        return
                    }
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Thrown by `readFile` when the file has grown past `structuredFileSizeLimit`.
    private struct ReadFileSizeError: Error {
        let message: String
        var localizedDescription: String { message }
    }

    /// Write `data` atomically to `url` on the background I/O queue.
    private static func writeFile(data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try data.write(to: url, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
