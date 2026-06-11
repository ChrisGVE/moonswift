// File: Sources/MoonSwiftTUI/Nvim/NvimProcessSupervisor.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Owns the nvim child process — probe discovery, spawn with XDG isolation,
//       stdin/stdout/stderr pipe management, and the 9-step teardown sequence.
//
// Architecture context (ARCHITECTURE.md §10.4.5, §10.6):
//   NvimProcessSupervisor is created by EditorBridge (Inc-6) immediately before
//   spawn. After spawn, NvimRPCClient (Inc-3) calls attachPipes(stdin:stdout:)
//   to take ownership of the stdin write handle and start the reader thread.
//   NvimProcessSupervisor retains the stdout Pipe so teardown can close it after
//   joining both the reader and stderr-drain threads.
//
//   Thread-safety model (@unchecked Sendable justification):
//     All mutable state (process handle, stdout/stderr pipe handles, exit-handler
//     closure, reader-thread stop flag) is set exactly once during spawn() and
//     thereafter accessed from well-defined single contexts:
//       • stdinPipe / stdoutPipe: set in spawn(); stdoutPipe read handle consumed
//         by NvimRPCClient's nvim-rpc-reader thread; stdinPipe transferred to the
//         NvimRPCClient actor at attachPipes time.
//       • stderrPipe: set in spawn(); drained exclusively by the stderr-drain Thread.
//       • process / exitHandler: set once; terminationHandler dispatched by
//         Foundation's private queue.
//       • stopStderrFlag: written once in teardown(), read repeatedly on the
//         stderr-drain thread — serialised by a dedicated DispatchQueue.
//     No lock is needed beyond that serialised flag (the reader-thread stop flag
//     lives in NvimRPCClient, Inc-3).
//
// Relationships:
//   → NvimProcessSupervisor+Probe.swift: probe logic (NvimProbeResult, probe(),
//       runVersionProbe, parseVersion, meetsMinimumVersion)
//   → NvimRPCClient.swift  (Inc-3): calls attachPipes(stdin:stdout:) after spawn
//   → EditorBridge.swift   (Inc-6): constructs supervisor, calls spawn + onExit
//   ← AppDriver            (Inc-6): calls teardown() on quit / nvimCleanup effect

import Darwin
import Foundation
import MoonSwiftCore

// NvimProbeResult struct and probe() methods live in
// NvimProcessSupervisor+Probe.swift.

// MARK: - NvimProcessSupervisor

/// Owns the nvim child process and its stdio pipes.
///
/// Lifecycle:
///   1. `probe()` — find a suitable nvim binary (call once before spawn).
///   2. `spawn(path:onExit:)` — fork nvim with XDG isolation, wire the exit handler
///      before `Process.run()`, and start the stderr drain.
///   3. Hand `stdinPipe`/`stdoutPipe` to `NvimRPCClient.attachPipes`.
///   4. `teardown()` — 9-step clean shutdown (called by the nvimCleanup Effect).
///
/// Note: `onExit` is passed directly to `spawn(path:onExit:)` so it is installed
/// on `Process.terminationHandler` **before** `process.run()` is called.
/// This closes the race where a fast-exiting child fires its termination handler
/// before the caller can set the exit handler post-spawn.
public final class NvimProcessSupervisor: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum stderr bytes captured per session before the drain pipe is closed.
    private static let stderrCapBytes = 1024 * 1024  // 1 MiB

    /// Chunk size for the stderr drain loop.
    private static let stderrChunkSize = 4 * 1024  // 4 KiB

    /// How long (seconds) to wait for a thread to exit before giving up the join.
    private static let threadJoinTimeoutSeconds = 0.2

    // MARK: - State set during spawn

    // All fields below are set exactly once in spawn() and nil before it.
    // @unchecked Sendable justification is in the file header.

    nonisolated(unsafe) private var process: Process?

    /// The stdin Pipe. Transferred to NvimRPCClient.attachPipes; supervisor
    /// never writes to stdin itself.
    ///
    /// `private(set)`: set once in `spawn(path:onExit:)`; the module can read
    /// it (EditorBridge, tests) but external code cannot accidentally overwrite
    /// it and break the set-once invariant that justifies `@unchecked Sendable`.
    nonisolated(unsafe) private(set) var stdinPipe: Pipe?

    /// The stdout Pipe. NvimRPCClient's reader thread consumes the read end;
    /// supervisor retains the handle so teardown can close it after the join.
    ///
    /// Same `private(set)` rationale as `stdinPipe`.
    nonisolated(unsafe) private(set) var stdoutPipe: Pipe?

    nonisolated(unsafe) private var stderrPipe: Pipe?

    /// The per-session XDG temp directory, removed in teardown step 9.
    ///
    /// `private(set)`: set once in spawn; readable by `@testable` tests to
    /// verify the directory lifecycle without requiring a real nvim binary
    /// (ARCHITECTURE.md §10.8 Inc-7 tests).
    nonisolated(unsafe) private(set) var xdgSessionDir: URL?

    // MARK: - Stop flags (written once in teardown; read on drain/reader threads)

    // We use a simple class-boxed Bool guarded by an NSLock rather than
    // OSAllocatedUnfairLock to stay compatible with macOS 13 (OSAllocatedUnfairLock
    // requires macOS 13.0 but is unavailable as a stored property in Sendable
    // contexts without @unchecked). A simple atomic pattern via a dedicated queue
    // gives clearer intent here.

    private let stderrFlagQueue = DispatchQueue(label: "moonswift.nvim-stderr-flag")
    nonisolated(unsafe) private var _stopStderr = false
    private var stopStderrFlag: Bool {
        get { stderrFlagQueue.sync { _stopStderr } }
        set { stderrFlagQueue.sync { _stopStderr = newValue } }
    }

    /// Semaphore posted by the stderr-drain thread when it has fully exited.
    private let stderrExitSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Shared logger

    private let log = Logger.shared

    // MARK: - Init

    public init() {}

    // MARK: - Spawn

    /// Spawn `nvim --embed --clean` with per-session XDG isolation.
    ///
    /// Creates a UUID-named subdirectory under the system temp directory with
    /// mode 0700 and sets XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_STATE_HOME to it
    /// before calling `process.run()`.
    ///
    /// The `onExit` handler is wired to `Process.terminationHandler` **before**
    /// `process.run()` is called so a fast-exiting child cannot fire the handler
    /// while `onExit` is still nil. The handler is invoked on Foundation's private
    /// terminationHandler queue and must only post to EventChannel.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the nvim executable.
    ///   - onExit: Called with the process exit code when nvim terminates.
    /// - Throws: if `Process.run()` fails (binary missing, permission denied).
    public func spawn(path: String, onExit: @Sendable @escaping (Int32) -> Void) throws {
        let sessionDir = try createXDGSessionDir()
        xdgSessionDir = sessionDir

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--embed", "--clean"]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Point all XDG dirs at the session-isolated temp subdir.
        var env = ProcessInfo.processInfo.environment
        let xdgPath = sessionDir.path
        env["XDG_CONFIG_HOME"] = xdgPath
        env["XDG_DATA_HOME"] = xdgPath
        env["XDG_STATE_HOME"] = xdgPath
        proc.environment = env

        // Wire terminationHandler BEFORE run() — the handler captures `onExit`
        // by value (not by reference to self), so no synchronization is needed
        // and there is no window between run() and handler assignment.
        proc.terminationHandler = { p in
            onExit(p.terminationStatus)
        }

        try proc.run()

        process = proc
        startStderrDrain(pipe: stderr)
    }

    // MARK: - Teardown (9-step sequence per ARCHITECTURE.md §10.4.5)

    /// Clean shutdown of the nvim process and all associated resources.
    ///
    /// **Precondition:** the caller must call `NvimRPCClient.shutdownReader()` first
    /// (which requires the stdout write-end to already be closed so the reader's
    /// blocking `read(2)` returns EOF). Violating this ordering means the reader
    /// thread is still live when step 8 closes the stdout read-end, causing EBADF.
    ///
    /// Step 1 (nil AppDriver.nvimSession) happens in AppDriver/Effect.nvimCleanup
    /// before this function is called — it is not repeated here.
    ///
    /// This method is idempotent: a second call after the first completes is a
    /// safe no-op (the `process` field is cleared to nil under `stderrFlagQueue`
    /// at the start of the first call).
    public func teardown() {
        // Double-teardown guard: atomically take ownership of `process`. A second
        // concurrent or sequential call sees nil and returns immediately, preventing
        // double-SIGTERM, double-close, and double-directory removal.
        let procOrNil: Process? = stderrFlagQueue.sync {
            guard let p = process else { return nil }
            process = nil  // clear under the queue so a racing teardown call returns nil
            return p
        }
        guard let proc = procOrNil else { return }

        // Step 2: Signal the stderr-drain thread to stop AND close the read-end
        // so that the drain thread's blocking read(2) returns immediately (EOF)
        // rather than waiting for nvim to close stderr. Without this, the drain
        // thread can block past the 200 ms join deadline and the subsequent fd
        // close (step 8) races the still-live drain thread on the same fd.
        stopStderrFlag = true
        stderrPipe?.fileHandleForReading.closeFile()

        // Step 3: Wait for the stderr-drain thread (max 200 ms).
        let deadline = DispatchTime.now() + NvimProcessSupervisor.threadJoinTimeoutSeconds
        _ = stderrExitSemaphore.wait(timeout: deadline)

        // Step 4: Send SIGTERM — ask nvim to shut down gracefully.
        proc.terminate()

        // Step 5: Schedule SIGKILL after 2 s in case nvim ignores SIGTERM.
        let killItem = DispatchWorkItem {
            kill(proc.processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: killItem)

        // Step 6: Wait for the process to exit on a background queue (blocking).
        proc.waitUntilExit()

        // Step 7: Cancel the SIGKILL workitem — process already exited.
        killItem.cancel()

        // Step 8: Close stdout pipe read-end (stderr read-end closed in step 2).
        // The reader thread has already been joined by the caller's shutdownReader()
        // call before teardown() — see API precondition above.
        stdoutPipe?.fileHandleForReading.closeFile()

        // Step 9: Remove the per-session XDG temp directory.
        if let dir = xdgSessionDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Private: XDG session directory

    private func createXDGSessionDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let sessionDir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return sessionDir
    }

    // MARK: - Private: stderr drain thread

    private func startStderrDrain(pipe: Pipe) {
        // Capture the fd *before* starting the thread so the drain thread never
        // calls handle.fileDescriptor on a potentially-already-closed handle.
        // teardown() owns the closeFile() call; the thread only uses the raw fd.
        let fd = pipe.fileHandleForReading.fileDescriptor
        // Strong capture on purpose: a weak capture lets the supervisor
        // deallocate before the thread body runs, in which case the drain
        // never starts and stderrExitSemaphore is never signalled — teardown
        // would then always burn its full join timeout (same pattern as the
        // RPC reader thread, CR-035/CR-043). The thread's lifetime is bounded
        // by teardown(), so no retain cycle.
        let thread = Thread { [self] in
            runStderrDrain(fd: fd)
        }
        thread.name = "moonswift.nvim-stderr-drain"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func runStderrDrain(fd: Int32) {
        // Fixed-size 4 KiB read(2) loop (ARCHITECTURE.md §10.6 Logging): bounds
        // per-read memory and returns 0 at EOF when nvim closes its stderr.
        //
        // The stderr read-end is owned by teardown() (step 2), which closes it
        // to produce EOF and unblock read(2). The drain thread must NOT close it
        // — teardown already did, and a second close raises an uncatchable ObjC
        // exception. We work with the raw fd (captured before thread start) to
        // avoid calling handle.fileDescriptor on an already-closed FileHandle.
        var buffer = [UInt8](repeating: 0, count: NvimProcessSupervisor.stderrChunkSize)
        var totalBytes = 0

        while !stopStderrFlag {
            let n = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, NvimProcessSupervisor.stderrChunkSize)
            }
            if n <= 0 { break }  // 0 = EOF (read-end closed by teardown); <0 = error

            totalBytes += n
            if totalBytes > NvimProcessSupervisor.stderrCapBytes {
                log.debug(
                    "NvimProcessSupervisor: stderr cap (~1 MiB) reached; "
                        + "stopping stderr drain to bound memory"
                )
                break
            }
        }

        // teardown() owns closeFile(); do not close the fd here.
        stderrExitSemaphore.signal()
    }

}
// Probe logic (NvimProbeResult, probe(), runVersionProbe, parseVersion,
// meetsMinimumVersion) lives in NvimProcessSupervisor+Probe.swift.
