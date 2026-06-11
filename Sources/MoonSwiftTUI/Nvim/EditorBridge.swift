// File: Sources/MoonSwiftTUI/Nvim/EditorBridge.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Static namespace that owns the nvim spawn sequence: probe → fallback
//       decision → process spawn → RPC handshake → buffer seed → autocmd →
//       NvimSession construction → AppEvent.nvimReady(NvimSession) posting.
//
// Architecture context (ARCHITECTURE.md §10.3a, §10.4, §10.8 Inc-7):
//   EditorBridge is a static enum (no instance state). The session lifecycle
//   state lives exclusively in NvimSession, which is owned by AppDriver as
//   `nvimSession?` and delivered to the reducer via AppEvent.nvimReady.
//
//   Spawn ordering (binding — tested by EditorBridgeTests):
//     1. probe()            — locate nvim; post .nvimUnavailable and return on failure
//     2. spawn(path:onExit:) — fork nvim --embed --clean; exit handler wired INSIDE
//                             spawn() before process.run() — no race window
//     3. attachPipes        — hand stdin/stdout to the RPC actor; starts reader thread
//     4. nvim_ui_attach(width, height, {ext_linegrid:true})
//     5. nvim_command("set noswapfile nomodeline shadafile=NONE laststatus=0")
//        hardening BEFORE any buffer ops
//     6. onNotification("moonswift_write", …)
//        BEFORE nvim_create_autocmd (handler registered before the autocmd fires)
//     7. buffer seed:
//        - whole .lua file → nvim_buf_set_name(0, absolutePath)
//        - structured fragment → nvim_buf_set_lines(0, 0, -1, false, lines)
//          then nvim_buf_set_option(0, "filetype", "lua")
//          then nvim_buf_set_option(0, "modified", false)
//     8. nvim_create_autocmd("BufWriteCmd", {pattern="*",
//                            command="call rpcnotify(1,'moonswift_write')"})
//     9. construct NvimSession(supervisor:, rpc:)
//    10. post AppEvent.nvimReady(session) — never a direct write into AppDriver state
//
//   XDG temp dir: created by NvimProcessSupervisor.spawn (mode 0700).
//   Removed by NvimProcessSupervisor.teardown() (called on Effect.nvimCleanup).
//
// Testability seam:
//   `EditorBridge.spawn` accepts a `SessionOverride` that, when non-nil, skips
//   the probe+spawn steps and uses the pre-built supervisor+pipes+rpc directly.
//   Tests inject fake Pipe pairs this way, without forking a real nvim process.
//   Production code always passes `nil` (the default).
//
// Relationships:
//   ← AppDriver.swift (runs spawn in a background Task for Effect.spawnNvim)
//   → NvimProcessSupervisor.swift (probe, spawn, teardown)
//   → NvimRPCClient.swift         (attach, request, notify, onNotification)
//   → EventChannel.swift          (posts AppEvent via the channel)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - EditorBridge

/// Static namespace for the nvim edit-session lifecycle.
///
/// All methods are static; there is no EditorBridge instance. Session state
/// flows out as `AppEvent.nvimReady(NvimSession)` and is owned by AppDriver.
public enum EditorBridge {

    // MARK: - Test seam

    /// Overrides the probe + spawn steps for unit tests.
    ///
    /// When non-nil, `EditorBridge.spawn` skips `NvimProcessSupervisor.probe()`
    /// and `supervisor.spawn(path:)` entirely, and uses the provided supervisor,
    /// pipes, and RPC actor directly. No real nvim process is required.
    ///
    /// Production code always passes `nil` for `sessionOverride`.
    public struct SessionOverride: Sendable {
        /// The pre-built supervisor (won't have `spawn()` called on it).
        public let supervisor: NvimProcessSupervisor
        /// The read end of the fake "stdout" pipe (what the RPC actor reads).
        public let stdoutPipe: Pipe
        /// The write end of the fake "stdin" pipe (what the test server reads).
        public let stdinPipe: Pipe
        /// A pre-built RPC actor (will have `attachPipes` called on it).
        public let rpc: NvimRPCClient

        public init(
            supervisor: NvimProcessSupervisor,
            stdinPipe: Pipe,
            stdoutPipe: Pipe,
            rpc: NvimRPCClient
        ) {
            self.supervisor = supervisor
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.rpc = rpc
        }
    }

    // MARK: - Spawn

    /// Execute the full nvim spawn + handshake sequence in a background Task.
    ///
    /// Called by AppDriver when it executes `Effect.spawnNvim`. The function
    /// runs entirely off the UI thread (the caller wraps it in `Task { }`).
    ///
    /// On success:  posts `AppEvent.nvimReady(NvimSession)`.
    /// On failure:  posts `AppEvent.nvimUnavailable(reason)` and returns.
    ///
    /// - Parameters:
    ///   - fragment: The source fragment to seed into the nvim buffer.
    ///   - rect: The code-pane rectangle used for `nvim_ui_attach` dimensions.
    ///   - channel: The EventChannel to post results to.
    ///   - sessionOverride: When non-nil, skips probe + spawn and uses the
    ///     provided supervisor and RPC actor. For unit tests only; always nil
    ///     in production.
    public static func spawn(
        fragment: LuaSourceFragment,
        rect: Rect,
        channel: EventChannel,
        sessionOverride: SessionOverride? = nil
    ) async {
        let supervisor: NvimProcessSupervisor
        let rpc: NvimRPCClient
        let stdinPipe: Pipe
        let stdoutPipe: Pipe

        if let override = sessionOverride {
            // Test path: bypass probe and spawn entirely.
            supervisor = override.supervisor
            stdinPipe = override.stdinPipe
            stdoutPipe = override.stdoutPipe
            rpc = override.rpc
        } else {
            // Production path: probe, then spawn.

            // Step 1: Probe for a usable nvim binary.
            guard let probeResult = NvimProcessSupervisor.probe() else {
                channel.post(.nvimUnavailable("nvim not found or version < 0.9"))
                return
            }

            let newSupervisor = NvimProcessSupervisor()
            let newRPC = NvimRPCClient()

            // Step 2: Spawn nvim with XDG isolation (creates the 0700 temp dir).
            // The exit handler is passed directly into spawn() so it is installed
            // on Process.terminationHandler before process.run() — no race window.
            do {
                try newSupervisor.spawn(path: probeResult.path) { code in
                    channel.post(.nvimProcessExited(exitCode: code))
                }
            } catch {
                channel.post(.nvimUnavailable("nvim spawn failed: \(error.localizedDescription)"))
                return
            }

            guard let sp = newSupervisor.stdinPipe, let so = newSupervisor.stdoutPipe else {
                channel.post(.nvimUnavailable("nvim pipes unavailable after spawn"))
                newSupervisor.teardown()
                return
            }

            supervisor = newSupervisor
            rpc = newRPC
            stdinPipe = sp
            stdoutPipe = so
        }

        // (Production step 2 already wired the exit handler inside spawn().)
        // For the test/override path the supervisor is a stub with no real process,
        // so no exit handler registration is needed there.

        // Step 3: Hand stdin/stdout to the actor; starts the nvim-rpc-reader thread.
        await rpc.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // Step 4: nvim_ui_attach — declare dimensions and request ext_linegrid.
        let width = Int(rect.width)
        let height = Int(rect.height)
        do {
            try await rpc.request(
                method: "nvim_ui_attach",
                params: [
                    .int(Int64(width)),
                    .int(Int64(height)),
                    .map([.string("ext_linegrid"): .bool(true)]),
                ],
                responseDecoder: { _ in () }
            )
        } catch {
            channel.post(.nvimUnavailable("nvim_ui_attach failed: \(error.localizedDescription)"))
            supervisor.teardown()
            return
        }

        // Step 5: Hardening — must complete BEFORE any buffer operations so nvim
        // resolves the swapfile path before nvim_buf_set_name sets the buffer name.
        await rpc.notify(
            method: "nvim_command",
            params: [.string("set noswapfile nomodeline shadafile=NONE laststatus=0")]
        )

        // Step 6: Register the write-back notification handler BEFORE installing
        // the autocmd that triggers it. This ordering guarantee is tested.
        await rpc.onNotification("moonswift_write") { _ in
            channel.post(.nvimWriteRequested)
        }

        // Step 7: Seed the buffer based on fragment type.
        if fragment.provenance.jsonpath == nil {
            // Whole .lua file: set the buffer name to the absolute path. nvim
            // reads the file itself; no nvim_buf_set_lines call is needed.
            let absolutePath = fragment.provenance.file.path
            do {
                try await rpc.request(
                    method: "nvim_buf_set_name",
                    params: [.int(0), .string(absolutePath)],
                    responseDecoder: { _ in () }
                )
            } catch {
                Logger.shared.debug("nvim_buf_set_name failed: \(error)")
            }
        } else {
            // Structured fragment: inject the Lua text line-by-line.
            let lines = fragment.code
                .components(separatedBy: "\n")
                .map { MessagePackValue.string($0) }
            do {
                try await rpc.request(
                    method: "nvim_buf_set_lines",
                    params: [
                        .int(0), .int(0), .int(-1), .bool(false),
                        .array(lines),
                    ],
                    responseDecoder: { _ in () }
                )
            } catch {
                Logger.shared.debug("nvim_buf_set_lines failed: \(error)")
            }
            // Mark filetype and clear the modified flag (fire-and-forget).
            await rpc.notify(
                method: "nvim_buf_set_option",
                params: [.int(0), .string("filetype"), .string("lua")]
            )
            await rpc.notify(
                method: "nvim_buf_set_option",
                params: [.int(0), .string("modified"), .bool(false)]
            )
        }

        // Step 8: Install the BufWriteCmd autocmd that intercepts `:w` and fires
        // the moonswift_write RPC notification. The body is a literal string with
        // no user input — no injection risk.
        do {
            try await rpc.request(
                method: "nvim_create_autocmd",
                params: [
                    .string("BufWriteCmd"),
                    .map([
                        .string("pattern"): .string("*"),
                        .string("command"): .string("call rpcnotify(1, 'moonswift_write')"),
                    ]),
                ],
                responseDecoder: { _ in () }
            )
        } catch {
            // Autocmd failure means `:w` won't trigger write-back, but the session
            // is still usable. Log and continue.
            Logger.shared.debug("nvim_create_autocmd failed: \(error)")
        }

        // Steps 9–10: Construct NvimSession and post nvimReady.
        let session = NvimSession(supervisor: supervisor, rpc: rpc)
        channel.post(.nvimReady(session))
    }
}
