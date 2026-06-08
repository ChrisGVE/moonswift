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
//   → NvimRPCClient.swift  (Inc-3): calls attachPipes(stdin:stdout:) after spawn
//   → EditorBridge.swift   (Inc-6): constructs supervisor, calls spawn + onExit
//   ← AppDriver            (Inc-6): calls teardown() on quit / nvimCleanup effect

import Darwin
import Foundation
import MoonSwiftCore

// MARK: - Probe result

/// The successful result of a nvim probe: a confirmed executable path and its
/// parsed version tuple.
///
/// The tuple is not `Equatable` by default; tests compare `.0`/`.1` directly.
public struct NvimProbeResult: Sendable {
    /// Absolute path confirmed as executable with version ≥ (0, 9).
    public let path: String
    /// Parsed version `(major, minor)` from the first line of `nvim --version`.
    public let version: (Int, Int)
}

// MARK: - NvimProcessSupervisor

/// Owns the nvim child process and its stdio pipes.
///
/// Lifecycle:
///   1. `probe()` — find a suitable nvim binary (call once before spawn).
///   2. `spawn(path:)` — fork nvim with XDG isolation and start the stderr drain.
///   3. `onExit(_:)` — register the exit callback before spawn or immediately after.
///   4. Hand `stdinPipe`/`stdoutPipe` to `NvimRPCClient.attachPipes`.
///   5. `teardown()` — 9-step clean shutdown (called by the nvimCleanup Effect).
public final class NvimProcessSupervisor: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum stderr bytes captured per session before the drain pipe is closed.
    private static let stderrCapBytes = 1 * 1024 * 1024  // 1 MiB

    /// Chunk size for the stderr drain loop.
    private static let stderrChunkSize = 4 * 1024  // 4 KiB

    /// How long (seconds) to wait for a thread to exit before giving up the join.
    private static let threadJoinTimeoutSeconds = 0.2

    // MARK: - State set during spawn

    // All fields below are set exactly once in spawn() and nil before it.
    // @unchecked Sendable justification is in the file header.

    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var exitHandler: (@Sendable (Int32) -> Void)?

    /// The stdin Pipe. Transferred to NvimRPCClient.attachPipes; supervisor
    /// never writes to stdin itself.
    nonisolated(unsafe) var stdinPipe: Pipe?

    /// The stdout Pipe. NvimRPCClient's reader thread consumes the read end;
    /// supervisor retains the handle so teardown can close it after the join.
    nonisolated(unsafe) var stdoutPipe: Pipe?

    nonisolated(unsafe) private var stderrPipe: Pipe?

    /// The per-session XDG temp directory, removed in teardown step 9.
    nonisolated(unsafe) private var xdgSessionDir: URL?

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

    // MARK: - Probe

    /// Probe for nvim, searching in priority order (ARCHITECTURE.md §10.4.5).
    ///
    /// Public parameterless entry point — delegates to the injectable seam.
    /// Call this before `spawn(path:)`; if it returns nil, fall back to $EDITOR.
    public static func probe() -> NvimProbeResult? {
        probe(
            environment: ProcessInfo.processInfo.environment,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            versionProbe: { runVersionProbe(path: $0) }
        )
    }

    /// Testability seam: injectable probe logic.
    ///
    /// - Parameters:
    ///   - environment: The process environment dict (inject to override NVIM_PATH/PATH).
    ///   - isExecutableFile: Predicate for executable check (inject a fake for tests).
    ///   - fileExists: Predicate for existence check (inject a fake for tests).
    ///   - versionProbe: Runs `<path> --version` and returns the first output line.
    ///                   Return nil to simulate a run failure.
    static func probe(
        environment: [String: String],
        isExecutableFile: (String) -> Bool,
        fileExists: (String) -> Bool,
        versionProbe: (String) -> String?
    ) -> NvimProbeResult? {
        // Build the candidate list in priority order.
        var candidates: [String] = []

        // Step 1: NVIM_PATH override — absolute path + executable guard only.
        // A relative or non-executable value is silently skipped (spec: log debug).
        if let envPath = environment["NVIM_PATH"] {
            if envPath.hasPrefix("/") && fileExists(envPath) && isExecutableFile(envPath) {
                candidates.append(envPath)
            } else {
                Logger.shared.debug(
                    "NvimProcessSupervisor: NVIM_PATH '\(envPath)' rejected "
                        + "(not absolute, not found, or not executable); continuing search"
                )
            }
        }

        // Steps 2–4: Well-known package-manager install locations.
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/nvim",  // Apple Silicon Homebrew
            "/usr/local/bin/nvim",  // Intel Homebrew
            "/opt/local/bin/nvim",  // MacPorts
        ])

        // Step 5: Each absolute component of $PATH.
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":").map(String.init) where dir.hasPrefix("/") {
                candidates.append("\(dir)/nvim")
            }
        }

        // Evaluate candidates in order; return the first that passes all checks.
        for path in candidates {
            guard fileExists(path), isExecutableFile(path) else { continue }
            guard let version = parseVersion(from: versionProbe(path)) else { continue }
            guard meetsMinimumVersion(version) else { continue }
            return NvimProbeResult(path: path, version: version)
        }

        return nil
    }

    // MARK: - Spawn

    /// Spawn `nvim --embed --clean` with per-session XDG isolation.
    ///
    /// Creates a UUID-named subdirectory under the system temp directory with
    /// mode 0700 and sets XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_STATE_HOME to it
    /// before calling `process.run()`.
    ///
    /// - Throws: if `Process.run()` fails (binary missing, permission denied).
    public func spawn(path: String) throws {
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

        // Wire terminationHandler before run() so no exit event is missed.
        proc.terminationHandler = { [weak self] p in
            self?.exitHandler?(p.terminationStatus)
        }

        try proc.run()

        process = proc
        startStderrDrain(pipe: stderr)
    }

    // MARK: - Exit callback

    /// Register the handler called when nvim exits.
    ///
    /// The handler is invoked on Foundation's private terminationHandler queue
    /// (not the nvim-rpc-class thread). It must only post to EventChannel.
    public func onExit(_ handler: @Sendable @escaping (Int32) -> Void) {
        exitHandler = handler
    }

    // MARK: - Teardown (9-step sequence per ARCHITECTURE.md §10.4.5)

    /// Clean shutdown of the nvim process and all associated resources.
    ///
    /// Step 1 (nil AppDriver.nvimSession) happens in AppDriver/Effect.nvimCleanup
    /// before this function is called — it is not repeated here.
    public func teardown() {
        guard let proc = process else { return }

        // Step 2: Signal the stderr-drain thread to stop.
        stopStderrFlag = true
        // (The reader-thread stop flag is owned by NvimRPCClient; it calls its own
        //  join before teardown proceeds past attachPipes, so no action needed here.)

        // Step 3: Wait for the stderr-drain thread (max 200 ms) before closing pipes.
        // This prevents an EBADF / uncatchable NSFileHandleOperationException that
        // would occur if we closed the pipe while the thread is blocked in read(2).
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

        // Step 8: Close stdout and stderr pipes (both drain threads already joined).
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()

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
        let handle = pipe.fileHandleForReading
        let thread = Thread { [weak self] in
            self?.runStderrDrain(handle: handle)
        }
        thread.name = "moonswift.nvim-stderr-drain"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func runStderrDrain(handle: FileHandle) {
        // Fixed-size 4 KiB read(2) loop (ARCHITECTURE.md §10.6 Logging): bounds
        // per-read memory and returns 0 at EOF when nvim closes its stderr.
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: NvimProcessSupervisor.stderrChunkSize)
        var totalBytes = 0

        while !stopStderrFlag {
            let n = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, NvimProcessSupervisor.stderrChunkSize)
            }
            if n <= 0 { break }  // 0 = EOF (nvim closed stderr); <0 = error

            totalBytes += n
            if totalBytes > NvimProcessSupervisor.stderrCapBytes {
                log.debug(
                    "NvimProcessSupervisor: stderr cap (~1 MiB) reached; "
                        + "closing stderr drain to bound memory"
                )
                break
            }
        }

        handle.closeFile()
        stderrExitSemaphore.signal()
    }

    // MARK: - Private: version helpers

    /// Run `<path> --version` and return the first line of stdout.
    ///
    /// Returns nil if the process cannot be launched or produces no output.
    private static func runVersionProbe(path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard stderr during probe

        do {
            try proc.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return output.components(separatedBy: "\n").first
    }

    /// Parse a version tuple from the first line of `nvim --version`.
    ///
    /// Expected format: `NVIM v<major>.<minor>.<patch>` (e.g. `NVIM v0.9.5`).
    /// Returns nil for any format that does not match.
    static func parseVersion(from line: String?) -> (Int, Int)? {
        guard let line else { return nil }

        // The first token of the first line is always "NVIM"; second is "v<x.y.z>".
        let tokens = line.split(separator: " ")
        guard tokens.count >= 2 else { return nil }

        let versionToken = tokens[1]
        guard versionToken.hasPrefix("v") else { return nil }

        let parts = versionToken.dropFirst().split(separator: ".")
        guard parts.count >= 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else { return nil }

        return (major, minor)
    }

    /// Returns true if `version` is at least (0, 9).
    private static func meetsMinimumVersion(_ version: (Int, Int)) -> Bool {
        if version.0 > 0 { return true }
        if version.0 == 0 { return version.1 >= 9 }
        return false
    }
}
