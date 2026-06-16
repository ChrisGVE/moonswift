// File: Sources/MoonSwiftTUI/LuaLS/LuaLSProcess.swift
// Folder: Sources/MoonSwiftTUI/LuaLS/
// Role: Hardened subprocess transport for lua-language-server (F7b). Spawns the
//       child with a direct exec + argument vector + absolute-path/executable
//       checks + curated environment (ARCHITECTURE §7.3, mirroring
//       NvimProcessSupervisor's hardening), and exposes a JSONRPC `DataChannel`
//       bridging the child's stdin/stdout. Teardown is idempotent (a double-call
//       guard prevents double-SIGTERM and double-close), matching
//       NvimProcessSupervisor.teardown's contract.
//
//   Thread-safety model (@unchecked Sendable justification):
//   - `process` and `stdinHandle` are set once at construction and never
//     reassigned; reads after construction are safe.
//   - stdin writes are serialised on a dedicated `writeQueue`.
//   - the teardown flag is a single Bool guarded by `stateQueue` (set-once).
//   - stdout delivery is via an `AsyncStream` continuation (Sendable), fed from
//     the readability handler.
//
// Upstream: LuaLSEnvironment (curated env), the resolved executable path
// Downstream: LuaLSClient (wraps the DataChannel in a JSONRPCServerConnection)

import Foundation
import JSONRPC

/// A spawned lua-language-server process and its JSONRPC data channel.
final class LuaLSProcess: @unchecked Sendable {

    private let process: Process
    private let stdinHandle: FileHandle
    private let continuation: AsyncStream<Data>.Continuation

    private let writeQueue = DispatchQueue(label: "moonswift.luals-stdin")
    private let stateQueue = DispatchQueue(label: "moonswift.luals-state")
    private var torndown = false

    /// The JSONRPC byte channel: writes frame to the child's stdin, reads stream
    /// from its stdout. Message framing is applied by `JSONRPCServerConnection`.
    let dataChannel: DataChannel

    /// Whether the child is still running (used by teardown tests). Reads
    /// `Process.isRunning`, which is internally synchronised by Foundation, so
    /// this getter needs no `stateQueue` hop (CR-013).
    var isRunning: Bool { process.isRunning }

    private init(
        process: Process,
        stdinHandle: FileHandle,
        stream: AsyncStream<Data>,
        continuation: AsyncStream<Data>.Continuation
    ) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.continuation = continuation
        self.dataChannel = DataChannel(
            writeHandler: { [weak stdinHandle, writeQueue] data in
                guard let stdinHandle else { return }
                // Serialise stdin writes on `writeQueue` WITHOUT blocking the
                // cooperative pool: the write handler is `async`, so suspend the
                // task on a continuation the queue resumes, rather than
                // `writeQueue.sync` which would pin a pool thread for the
                // duration of the pipe write (CR-002). Ordering and error
                // propagation are preserved by the serial queue + continuation.
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<Void, Error>) in
                    writeQueue.async {
                        do {
                            try stdinHandle.write(contentsOf: data)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            },
            dataSequence: stream
        )
    }

    /// Spawn `executablePath` in `workspace` with `environment`, returning the
    /// running transport.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the lua-language-server binary.
    ///   - workspace: Current directory for the child — the cache dir holding
    ///     `.luarc.json`, so the server picks up `runtime.version`/library.
    ///   - environment: The curated child environment (see `LuaLSEnvironment`).
    ///   - onExit: Called with the exit status when the child terminates.
    /// - Throws: `LuaLSProcessError.notExecutable` if the path is not an
    ///   executable file, or any `Process.run()` error.
    static func spawn(
        executablePath: String,
        workspace: URL,
        environment: [String: String],
        onExit: @Sendable @escaping (Int32) -> Void
    ) throws -> LuaLSProcess {
        guard executablePath.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw LuaLSProcessError.notExecutable(executablePath)
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = []  // lua-language-server defaults to stdio LSP transport
        proc.environment = environment
        proc.currentDirectoryURL = workspace
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let (stream, continuation) = AsyncStream<Data>.makeStream()

        // Deliver stdout bytes to the data sequence; an empty read is EOF.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        // Drain stderr so the child never blocks on a full stderr pipe (the
        // server logs verbosely). Discarded — diagnostics arrive over stdout.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        proc.terminationHandler = { p in
            continuation.finish()
            onExit(p.terminationStatus)
        }

        // Set F_SETNOSIGPIPE on the PARENT's write end of the stdin pipe (macOS
        // -only fcntl flag; absent on Linux, but MoonSwift is macOS-only). A
        // write after the child has died then surfaces as a thrown EPIPE on the
        // write queue instead of a SIGPIPE killing the host process.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try proc.run()

        return LuaLSProcess(
            process: proc,
            stdinHandle: stdin.fileHandleForWriting,
            stream: stream,
            continuation: continuation
        )
    }

    /// Terminate the child and release its resources. Idempotent: a second call
    /// (or a call racing the termination handler) is a safe no-op.
    func terminate() {
        let firstCall: Bool = stateQueue.sync {
            guard !torndown else { return false }
            torndown = true
            return true
        }
        guard firstCall else { return }

        continuation.finish()
        if process.isRunning {
            process.terminate()  // SIGTERM — the child shuts down its LSP loop
        }
        try? stdinHandle.close()
    }
}

/// Errors raised while spawning lua-language-server.
enum LuaLSProcessError: Error, Equatable {
    /// The resolved path is not an absolute path to an executable file.
    case notExecutable(String)
}
