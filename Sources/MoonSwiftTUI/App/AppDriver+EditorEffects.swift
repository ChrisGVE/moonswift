// File: Sources/MoonSwiftTUI/App/AppDriver+EditorEffects.swift
// Location: MoonSwiftTUI/App/
// Role: AppDriver extension that implements the $EDITOR / clipboard effect
//       helpers called from executeSingle and from AppDriver+NvimEffects.swift.
//       Extracted from AppDriver+NvimEffects.swift to stay within the 400-line
//       per-file budget (codesize plan, §9 risk tracking). All methods are
//       UI-thread-only (render/terminal-class).
//
// Methods:
//   spawnEditorFallbackAndWait(_:) — $EDITOR fallback loop (ARCHITECTURE §10.8)
//   syntaxErrorCommentBlock(_:)    — normative comment format (ux-spec §7.3)
//   spawnEditorAndWait(url:)       — pump-park / suspend / spawn / resume
//   yankToPasteboard(_:)           — pbcopy clipboard write
//
// Upstream: AppDriver.executeSingle (Effect arms .spawnEditor, .yank,
//           .spawnEditorFallback), AppDriver+NvimEffects.swift
// Downstream: EventChannel (posts AppEvent results)

import Darwin
import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - AppDriver: $EDITOR / clipboard effect helpers

extension AppDriver {

    // MARK: Editor fallback spawn (Inc-10)

    /// Execute the full `$EDITOR` fallback sequence for the given source fragment.
    ///
    /// Implements ARCHITECTURE.md §10.8 Inc-10 and ux-spec §7.3:
    ///
    /// 1. For structured-file fragments: create a temp file in
    ///    `FileManager.default.temporaryDirectory` with a UUID name, opened with
    ///    `O_EXCL | O_WRONLY | O_CREAT` and mode 0600. A pre-existing file at
    ///    the path is surfaced as `.writeBackFailed(.ioFailure(…))` and returns.
    ///    For whole `.lua` files: use `fragment.provenance.file` directly.
    /// 2. Cap content at `structuredFileSizeLimit` before the pre-pass.
    /// 3. Syntax loop (ux-spec §7.3 §7):
    ///    a. Spawn `$EDITOR <path>` via `spawnEditorAndWait` mechanics
    ///       (pump-park, terminal suspend/resume). Returns immediately on no `$EDITOR`.
    ///    b. Read the edited bytes from the temp file (or the file directly).
    ///    c. Run `LintService.syntaxPrePass`. On error: inject the normative
    ///       comment block at the top of the file and loop back to (a). On success:
    ///       break.
    /// 4. Dispatch `WriteBackCoordinator.write(…lintService:…)` in a background
    ///    `Task`, posting the appropriate `AppEvent` on completion — same events
    ///    as `Effect.writeBack` (writeBackSucceeded / writeBackFailed /
    ///    conflictDetected).
    ///
    /// Must be called from the UI thread (render/terminal-class, same constraint as
    /// `spawnEditorAndWait`).
    func spawnEditorFallbackAndWait(fragment: LuaSourceFragment) {
        // Resolve the project root early; no-op if unavailable.
        guard let projectRoot = projectDirectoryURL() else {
            channel.post(.writeBackFailed(.ioFailure("Project root unavailable")))
            return
        }

        // Determine whether this is a structured-file fragment or a whole .lua file.
        let isStructured = fragment.provenance.jsonpath != nil

        // For structured fragments, create a temp file. For whole .lua files, edit
        // the source file directly (same behaviour as the existing spawnEditor path).
        let editURL: URL
        if isStructured {
            // Create temp file with a UUID name, O_EXCL, mode 0600.
            // EEXIST on the UUID path is surfaced as an error (no retry loop).
            let tmpDir = FileManager.default.temporaryDirectory
            let name = "moonswift-\(UUID().uuidString).lua"
            let url = tmpDir.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd == -1 {
                let reason =
                    errno == EEXIST
                    ? "Temp file already exists: \(url.lastPathComponent)"
                    : "Cannot create temp file: \(String(cString: strerror(errno)))"
                channel.post(.writeBackFailed(.ioFailure(reason)))
                return
            }
            // CR-014: EINTR-safe full-count write(2) loop. A partial write (e.g.
            // EINTR on a large file) must be retried until all bytes are written
            // or a hard error is returned. `written < 0` alone misses the case
            // where write(2) returns fewer than `count` bytes without error.
            let fragmentData = Data(fragment.code.utf8)
            let writeOK = fragmentData.withUnsafeBytes { ptr -> Bool in
                guard let base = ptr.baseAddress, ptr.count > 0 else { return true }
                var sent = 0
                while sent < ptr.count {
                    let n = write(fd, base.advanced(by: sent), ptr.count - sent)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    sent += n
                }
                return true
            }
            close(fd)
            if !writeOK {
                // CR-017: remove the partially-written temp file before returning.
                try? FileManager.default.removeItem(at: url)
                channel.post(
                    .writeBackFailed(.ioFailure("Cannot write temp file: \(url.lastPathComponent)"))
                )
                return
            }
            editURL = url
        } else {
            editURL = fragment.provenance.file
        }

        // CR-017: defer deletion of the temp file on all structured-fragment exit
        // paths so the plain-text fragment content does not persist in $TMPDIR.
        // For whole .lua files `editURL == fragment.provenance.file`; removing it
        // would delete the source — guard with `isStructured` before removing.
        defer {
            if isStructured {
                try? FileManager.default.removeItem(at: editURL)
            }
        }

        // Skeleton path: if no lint service is injected, skip the pre-pass loop
        // and post synthetic success immediately (same skeleton contract as writeBack).
        guard let lint = lintService else {
            spawnEditorAndWait(url: editURL)
            // CR-023 skeleton path: use fragment-derived SourceID, not state.selection.
            let fragmentID = Self.sourceID(for: fragment, projectRoot: projectRoot)
            Task { [channel] in
                channel.post(.writeBackSucceeded(fragmentID))
            }
            return
        }

        // Syntax loop — ux-spec §7.3 §7:
        // Each iteration: park/suspend/spawn/resume (via spawnEditorAndWait),
        // read file, syntax pre-pass. On error: inject comment block and loop.
        // On success: break and dispatch write-back.
        while true {
            spawnEditorAndWait(url: editURL)

            // Read the edited bytes from the temp file (or the source file).
            let editedText: String
            do {
                let data = try Data(contentsOf: editURL)
                // Cap at structuredFileSizeLimit before the pre-pass.
                if data.count > structuredFileSizeLimit {
                    channel.post(.writeBackFailed(.ioFailure("Edited text exceeds size limit")))
                    return
                }
                // CR-002b: non-UTF-8 bytes must not silently become "" and
                // overwrite the source file with zero content. Surface the
                // encoding failure as .writeBackFailed(.ioFailure) instead.
                guard let text = String(data: data, encoding: .utf8) else {
                    channel.post(.writeBackFailed(.ioFailure("File is not valid UTF-8")))
                    return
                }
                editedText = text
            } catch {
                channel.post(
                    .writeBackFailed(
                        .ioFailure("Cannot read temp file: \(error.localizedDescription)"))
                )
                return
            }

            // Syntax pre-pass.
            let prePassFrag = LuaSourceFragment(code: editedText, provenance: fragment.provenance)
            if let diag = lint.syntaxPrePass(prePassFrag) {
                // Error: inject normative comment block (ux-spec §7.3) at the top
                // of the temp file, then loop back to open the editor again.
                let commentBlock = Self.syntaxErrorCommentBlock(diag)
                let newText = commentBlock + editedText
                do {
                    try Data(newText.utf8).write(to: editURL, options: .atomic)
                } catch {
                    channel.post(
                        .writeBackFailed(
                            .ioFailure("Cannot annotate temp file: \(error.localizedDescription)"))
                    )
                    return
                }
                // Loop: re-open the editor with the annotated file.
                continue
            }

            // Syntax clean — dispatch WriteBackCoordinator.write on a background Task.
            let capturedText = editedText
            let capturedFragment = fragment
            // CR-023: use fragment-derived SourceID, not state.selection.
            let fragmentID = Self.sourceID(for: fragment, projectRoot: projectRoot)
            Task { [channel] in
                let result = await WriteBackCoordinator.write(
                    fragment: capturedFragment,
                    editedText: capturedText,
                    projectRoot: projectRoot,
                    lintService: lint,
                    force: false
                )
                switch result.outcome {
                case .success:
                    channel.post(.writeBackSucceeded(fragmentID))
                case .syntaxPrePassBlocked(let diagnostic):
                    // Should not occur (pre-pass was clean above); surface anyway (CR-006).
                    channel.post(.writeBackBlocked(diagnostic))
                case .conflictDetected:
                    channel.post(
                        .conflictDetected(
                            fileURL: capturedFragment.provenance.file,
                            expectedHash: capturedFragment.provenance.contentHash,
                            editedText: capturedText
                        )
                    )
                case .spliceError(let err):
                    channel.post(.writeBackFailed(.spliceError(err)))
                case .validateReadableRejection(let rejection):
                    channel.post(.writeBackFailed(.validateReadableRejection(rejection)))
                case .ioFailure(let reason):
                    channel.post(.writeBackFailed(.ioFailure(reason)))
                }
            }
            return
        }
    }

    // MARK: Normative comment block

    /// Build the normative comment block injected at the top of a temp file when
    /// the syntax pre-pass fails (ux-spec §7.3, snapshot-tested exact format).
    ///
    /// Format (two lines, terminated by newline):
    /// ```lua
    /// -- SYNTAX ERROR: <message> (line N)
    /// -- Fix the error above, then save to continue. Delete this block to force-accept.
    /// ```
    static func syntaxErrorCommentBlock(_ diag: Diagnostic) -> String {
        "-- SYNTAX ERROR: \(diag.message) (line \(diag.line))\n"
            + "-- Fix the error above, then save to continue."
            + " Delete this block to force-accept.\n"
    }

    // MARK: Editor spawn

    /// Execute the full $EDITOR handshake for the given file URL.
    ///
    /// Sequence (ARCHITECTURE.md §5.2, ffi-boundary.md §EDITOR suspend/resume):
    /// 1. Park the pump — blocks until the pump acknowledges (≤ 50 ms).
    ///    No input-class shim call is in flight after this returns.
    /// 2. Suspend the terminal (leave alt screen, restore termios).
    /// 3. Spawn `$EDITOR <path>` — direct exec, no shell interpretation.
    /// 4. Wait for the editor process to exit (any exit code is accepted).
    /// 5. Resume the terminal (raw mode, alt screen).
    /// 6. Unpark the pump.
    ///
    /// CR-011 / ARCHITECTURE.md §7.3: `$EDITOR` is split on whitespace so that
    /// `"code -w"` launches `code` with leading arg `-w`. The first component must
    /// be an absolute path — no PATH lookup, no shell, no injection.
    ///
    /// If `$EDITOR` is not set or fails validation: posts a transient and returns
    /// without touching the pump or the terminal.
    ///
    /// Must be called from the UI thread (render/terminal-class).
    func spawnEditorAndWait(url: URL) {
        // Guard: $EDITOR must be set. The exact transient string is normative
        // (ux-spec.md §6.4 — "No $EDITOR" entry).
        guard let editor = ProcessInfo.processInfo.environment["EDITOR"],
            !editor.isEmpty
        else {
            let msg = "$EDITOR is not set. Set it to open the project file."
            state.transient = TransientMessage(text: msg)
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }

        // Split on whitespace; validate the binary component is an absolute path.
        let editorComponents = editor.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard let editorBinary = editorComponents.first else {
            state.transient = TransientMessage(text: "$EDITOR is empty after trimming.")
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }
        guard editorBinary.hasPrefix("/") else {
            state.transient = TransientMessage(text: "$EDITOR must be an absolute path.")
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }
        let editorURL = URL(fileURLWithPath: editorBinary)
        guard FileManager.default.fileExists(atPath: editorURL.path),
            FileManager.default.isExecutableFile(atPath: editorURL.path)
        else {
            state.transient = TransientMessage(
                text: "$EDITOR '\(editorURL.lastPathComponent)' is not executable.")
            tickSource.arm(interval: TickInterval.transientExpiry)
            return
        }
        // Leading args from the EDITOR value (e.g. ["-w"] for "code -w").
        let editorLeadingArgs = Array(editorComponents.dropFirst())

        // 1. Park the pump.
        pump.parkAndWait()

        // 2. Suspend the terminal (TTY-gated).
        if let suspender {
            do {
                try suspender.suspend()
            } catch {
                pump.unparkAfterResume()
                return
            }
        }

        // 3 + 4. Spawn the editor: binary + leading args + file path.
        let process = Process()
        process.executableURL = editorURL
        process.arguments = editorLeadingArgs + [url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Editor could not be launched — fall through to resume.
        }

        // 5. Resume the terminal (TTY-gated).
        if let suspender {
            do { try suspender.resume() } catch {}
        }

        // 6. Unpark the pump.
        pump.unparkAfterResume()
    }

    // MARK: Clipboard

    /// Write `text` to the system clipboard by piping it through `pbcopy`.
    ///
    /// macOS-only (`pbcopy` is a standard utility). Failure is silently swallowed
    /// — clipboard is a best-effort feature. Must be called from the UI thread.
    func yankToPasteboard(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            // pbcopy unavailable or failed — silent no-op.
        }
    }
}
