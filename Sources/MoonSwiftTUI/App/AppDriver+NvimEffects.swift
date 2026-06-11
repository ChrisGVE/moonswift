// File: Sources/MoonSwiftTUI/App/AppDriver+NvimEffects.swift
// Location: MoonSwiftTUI/App/
// Role: AppDriver extension that implements the nvim-specific effect execution
//       methods called from executeSingle. Extracted from AppDriver.swift to
//       stay within the 400-line per-file budget (codesize plan, §9 risk
//       tracking). All methods are UI-thread-only (render/terminal-class).
//       $EDITOR / clipboard helpers live in AppDriver+EditorEffects.swift.
//
// Methods (effect bodies):
//   executeSpawnNvim(_:rect:)                    — launch EditorBridge.spawn
//   executeNvimInput(_:)                         — forward key-notation to nvim RPC
//   executeNvimDetach()                          — send qa! + post .nvimDetached
//   executeNvimResize(_:)                        — fire-and-forget nvim_ui_try_resize
//   executeNvimCleanup()                         — nil session + pipe teardown (§10.6)
//   executeWriteBack(_:editedText:force:)        — full write-back pipeline
//   executeBuildDiffView(_:expectedHash:…)       — diff state builder
//
// Upstream: AppDriver.executeSingle (Effect arms .spawnNvim, .nvimInput,
//           .nvimDetach, .nvimResize, .nvimCleanup, .writeBack, .buildDiffView),
//           NvimProcessSupervisor, WriteBackCoordinator
// Downstream: EventChannel (posts AppEvent results)

import CryptoKit
import Darwin
import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - AppDriver: nvim effect bodies

extension AppDriver {

    // MARK: Nvim effects (P4 F8b, ARCHITECTURE.md §10.4.1, §10.6)

    /// Launch the EditorBridge spawn sequence on a background Task.
    ///
    /// Explicit `[channel]` capture — never capture `self` (CR-013).
    func executeSpawnNvim(fragment: LuaSourceFragment, rect: Rect) {
        Task { [channel] in
            await EditorBridge.spawn(fragment: fragment, rect: rect, channel: channel)
        }
    }

    /// Forward a key-notation string to the running nvim instance.
    ///
    /// Guards with the session reference captured synchronously on the UI thread;
    /// if teardown already nil-ed the session this is a no-op.
    func executeNvimInput(_ keyNotation: String) {
        guard let session = nvimSession else { return }
        Task {
            await session.rpc.notify(
                method: "nvim_input",
                params: [.string(keyNotation)]
            )
            // nvim_input is fire-and-forget; no response expected.
        }
    }

    /// Send `qa!` to detach; post `.nvimDetached` after the notify returns.
    ///
    /// Note: no leading colon — `nvim_command` takes an Ex command, not a
    /// command-line string; leading colons are harmless but noise-free without.
    func executeNvimDetach() {
        guard let session = nvimSession else { return }
        Task { [channel] in
            await session.rpc.notify(
                method: "nvim_command",
                params: [.string("qa!")]
            )
            channel.post(.nvimDetached)
        }
    }

    /// Fire-and-forget resize notification.
    ///
    /// Debouncing is applied by the reducer dispatch in Inc-8; at this layer we
    /// just forward the call.
    func executeNvimResize(_ size: TerminalSize) {
        guard let session = nvimSession else { return }
        Task {
            await session.rpc.notify(
                method: "nvim_ui_try_resize",
                params: [
                    .int(Int64(size.cols)),
                    .int(Int64(size.rows)),
                ]
            )
        }
    }

    /// Nil the session reference synchronously then tear down the process.
    ///
    /// Step 1 (ARCHITECTURE.md §10.4.5 / §10.6 nil-before-teardown invariant):
    /// nil `nvimSession` before any async work so in-flight `nvimInput` tasks see
    /// nil and skip the write. CR-003: close the stdout write-end before
    /// `shutdownReader` so the reader's blocking `read(2)` immediately returns
    /// 0 (EOF) instead of waiting for the 2 s semaphore timeout. The `Task`
    /// handle is stored in `nvimCleanupTask` so `teardown()` can await it.
    func executeNvimCleanup() {
        guard let session = nvimSession else { return }
        nvimSession = nil
        nvimCleanupTask = Task {
            session.supervisor.stdoutPipe?.fileHandleForWriting.closeFile()
            session.rpc.shutdownReader()
            session.supervisor.teardown()
        }
    }

    /// Execute the full write-back pipeline.
    ///
    /// Resolves the project root and lint service synchronously on the UI thread,
    /// then dispatches `WriteBackCoordinator.write` on a background `Task`.
    /// When `editedText` is the empty sentinel the buffer is fetched from nvim
    /// via `nvim_buf_get_lines` before invoking the coordinator (§10.3c).
    ///
    /// CR-002: if `editedText` is empty but `nvimSession` is already nil, posts
    /// `.writeBackFailed` immediately — overwriting with zero bytes is the worst
    /// silent data-loss failure class.
    func executeWriteBack(
        fragment: LuaSourceFragment,
        editedText: String,
        force: Bool
    ) {
        guard let projectRoot = projectDirectoryURL() else { return }
        let lint: any LintServiceProtocol
        if let svc = lintService {
            lint = svc
        } else {
            // Skeleton: no lint service — post success immediately.
            let fragmentID = Self.sourceID(for: fragment, projectRoot: projectRoot)
            Task { [channel] in
                channel.post(.writeBackSucceeded(fragmentID))
            }
            return
        }
        // Capture session reference synchronously on UI thread before the Task.
        // If editedText is the empty sentinel (nvimWriteRequested path) and the
        // session was already nil-ed by cleanup, surface the failure immediately.
        let session = nvimSession
        let fragmentID = Self.sourceID(for: fragment, projectRoot: projectRoot)
        Task { [channel] in
            let resolvedText: String
            if editedText.isEmpty {
                guard let session else {
                    channel.post(
                        .writeBackFailed(
                            .ioFailure("session closed before buffer could be read"))
                    )
                    return
                }
                do {
                    let lines = try await session.rpc.request(
                        method: "nvim_buf_get_lines",
                        params: [
                            .int(0),  // buffer 0 = current
                            .int(0),  // start line
                            .int(-1),  // end = all
                            .bool(false),
                        ]
                    ) { value -> [String] in
                        guard case .array(let arr) = value else { return [] }
                        return arr.compactMap {
                            if case .string(let s) = $0 { return s }
                            return nil
                        }
                    }
                    resolvedText = lines.joined(separator: "\n") + "\n"
                } catch {
                    channel.post(
                        .writeBackFailed(
                            .ioFailure("Buffer read failed: \(error.localizedDescription)"))
                    )
                    return
                }
            } else {
                resolvedText = editedText
            }

            let result = await WriteBackCoordinator.write(
                fragment: fragment,
                editedText: resolvedText,
                projectRoot: projectRoot,
                lintService: lint,
                force: force
            )

            switch result.outcome {
            case .success:
                channel.post(.writeBackSucceeded(fragmentID))
            case .conflictDetected:
                channel.post(
                    .conflictDetected(
                        fileURL: fragment.provenance.file,
                        expectedHash: fragment.provenance.contentHash,
                        editedText: resolvedText
                    )
                )
            case .syntaxPrePassBlocked(let diagnostic):
                channel.post(.writeBackBlocked(diagnostic))
            case .spliceError(let err):
                channel.post(.writeBackFailed(.spliceError(err)))
            case .validateReadableRejection(let rejection):
                channel.post(.writeBackFailed(.validateReadableRejection(rejection)))
            case .ioFailure(let reason):
                channel.post(.writeBackFailed(.ioFailure(reason)))
            }
        }
    }

    /// Build the `DiffViewState` off the UI thread (ARCHITECTURE.md §10.4.10).
    ///
    /// Re-reads the on-disk file, re-locates the span via `SpanLocator`, and
    /// constructs left/right line arrays. Posts `.diffViewReady` on success or
    /// `.writeBackFailed(.ioFailure)` on any error.
    func executeBuildDiffView(
        fileURL: URL,
        expectedHash: SHA256Digest,
        editedText: String,
        fragment: LuaSourceFragment
    ) {
        Task { [channel] in
            do {
                let currentData = try Data(contentsOf: fileURL)
                let leftText: String
                if let jsonpath = fragment.provenance.jsonpath,
                    let fmt = StructuredFileFormat.from(
                        extension: fileURL.pathExtension)
                {
                    let expr = try JSONPathExpression(parsing: jsonpath)
                    guard let text = String(data: currentData, encoding: .utf8)
                    else {
                        channel.post(
                            .writeBackFailed(
                                .ioFailure("File is not valid UTF-8")))
                        return
                    }
                    let tree = try Self.decodeTreeForDiff(
                        text, format: fmt, document: fragment.provenance.document)
                    let matches = expr.evaluate(on: tree)
                    guard let first = matches.first else {
                        channel.post(
                            .writeBackFailed(
                                .ioFailure("JSONPath matched nothing in current file")))
                        return
                    }
                    let loc = try SpanLocator.locateSpan(
                        in: currentData,
                        format: fmt,
                        path: first.path.steps,
                        document: fragment.provenance.document
                    )
                    let spanData = currentData[loc.byteRange]
                    leftText = String(data: spanData, encoding: .utf8) ?? ""
                } else {
                    leftText = String(data: currentData, encoding: .utf8) ?? ""
                }

                let isConflict = SpanSplicer.hasConflict(
                    currentData: currentData, expected: expectedHash)
                let leftTitle =
                    isConflict
                    ? "On disk (changed) — \(fileURL.lastPathComponent)"
                    : "On disk — \(fileURL.lastPathComponent)"

                let diffState = DiffViewState(
                    leftTitle: leftTitle,
                    rightTitle: "Edited",
                    leftLines: leftText.components(separatedBy: "\n"),
                    rightLines: editedText.components(separatedBy: "\n")
                )
                channel.post(.diffViewReady(diffState))
            } catch {
                channel.post(
                    .writeBackFailed(
                        .ioFailure("Diff build failed: \(error.localizedDescription)")))
            }
        }
    }

}
