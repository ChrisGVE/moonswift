// File: Sources/MoonSwiftTUI/Nvim/NvimRPCClient.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: msgpack-RPC client actor for the embedded nvim process. Owns the stdin
//       write FileHandle; manages msgid counter, pending-request continuations,
//       and notification handlers. A background Thread named
//       "moonswift.nvim-rpc-reader" loops on blocking read(2), feeds bytes to
//       MsgpackRPCFramer, and enqueues decoded messages to the actor.
//
// Architecture context (ARCHITECTURE.md §10.4.6, §10.2, §10.6):
//   Three thread classes after P4:
//     1. render/terminal-class (UI thread)  — RatatuiKit FFI calls only
//     2. input-class (pump thread)           — rffi_poll_event only
//     3. nvim-rpc-class (this reader thread) — stdout reads → actor deliver()
//   NvimRPCClient (actor) serialises all stdin writes and all notification
//   dispatch on its actor executor. No NSLock needed for actor-isolated state.
//
// Sendability of the reader Thread body:
//   The Thread closure captures `self` (the actor, which is Sendable by
//   definition), `fd` (Int32, Sendable), and a local `MsgpackRPCFramer` (value
//   type, not shared). Swift 6 strict concurrency accepts this because all
//   captured values satisfy Sendable. The Thread does NOT call any actor method
//   directly — it only enqueues `Task { await self.deliver(msg) }`, which the
//   actor serialises.
//
// Stop / join mechanism:
//   A `DispatchSemaphore` (readerExitSemaphore) is signalled by the reader
//   thread when it exits its loop. `shutdownReader()` closes the stop-flag,
//   then calls `readerExitSemaphore.wait()` — blocking on the actor's executor
//   is fine here because `shutdownReader` is `nonisolated`. The stop flag itself
//   is a simple Bool protected by a dedicated serial DispatchQueue
//   (readerFlagQueue) to avoid data races without needing OSAllocatedUnfairLock
//   (macOS 13 compatibility).
//
// Relationships:
//   ← NvimProcessSupervisor.swift (Inc-2): calls attachPipes(stdin:stdout:)
//   → EditorBridge.swift          (Inc-6): calls request/notify/onNotification
//   → AppDriver.swift             (Inc-6): calls shutdownReader() in teardown

import Darwin
import Foundation
import MoonSwiftCore

// Wire-protocol value types (NvimRPCError, NvimBuffer, NvimWindow,
// RawRPCMessage) live in NvimRPCTypes.swift to keep this file within the
// codesize budget.

// MARK: - NvimRPCClient actor

/// Actor that owns all stdin writes to the nvim process and dispatches incoming
/// msgpack-RPC messages from its stdout stream.
///
/// All mutable state — msgid counter, pending continuations, notification
/// handlers, and the `stdinOpen` flag — is actor-isolated; no explicit lock
/// is needed. The reader thread is the only non-actor context and interacts
/// with the actor solely via `Task { await self.deliver(msg) }`.
public actor NvimRPCClient {

    // MARK: - Constants

    /// Maximum milliseconds `shutdownReader()` will wait for the thread to exit.
    private static let threadJoinTimeoutSeconds: Double = 2.0

    // MARK: - Actor-isolated state

    /// Monotonically increasing message-id allocated per request.
    private var nextMsgid: Int = 0

    /// Pending request continuations keyed by msgid.
    private var pending: [Int: CheckedContinuation<MessagePackValue, Error>] = [:]

    /// Per-method notification handlers registered by callers.
    private var notificationHandlers: [String: @Sendable ([MessagePackValue]) -> Void] = [:]

    /// The stdin FileHandle owned by this actor. nil until attachPipes is called.
    private var stdinWriteHandle: FileHandle?

    /// False once a write failure or reader EOF is observed. Checked before every
    /// write to prevent an uncatchable NSFileHandleOperationException.
    private var stdinOpen: Bool = false

    // MARK: - Reader thread coordination (nonisolated, safe by design)
    //
    // These are written exactly once (in attachPipes / the reader loop) and
    // read only from shutdownReader() or the reader thread itself. A dedicated
    // serial queue guards the stop flag; the semaphore is post-once.

    /// Serial queue that protects _stopReader.
    nonisolated private let readerFlagQueue = DispatchQueue(
        label: "moonswift.nvim-rpc-reader-flag",
        qos: .utility
    )
    /// Backing storage for the stop flag; access only via readerFlagQueue.
    nonisolated(unsafe) private var _stopReader: Bool = false

    nonisolated private var stopReaderFlag: Bool {
        get { readerFlagQueue.sync { _stopReader } }
        set { readerFlagQueue.sync { _stopReader = newValue } }
    }

    /// Signalled by the reader thread when it has fully exited its loop.
    nonisolated private let readerExitSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Logger

    // nonisolated so the reader thread (nvim-rpc-class) can log without
    // hopping to the actor executor. Logger.shared is thread-safe (os_log).
    nonisolated private let log = Logger.shared

    // MARK: - Init

    public init() {}

    // MARK: - Pipe attachment

    /// Attach the nvim stdin/stdout pipes and start the reader thread.
    ///
    /// Must be called once, immediately after the nvim process is spawned.
    /// The actor takes ownership of the stdin write handle; the supervisor
    /// must not write to stdin after this call.
    ///
    /// - Parameters:
    ///   - stdin: The Pipe whose write end the actor will use to send RPC frames.
    ///   - stdout: The Pipe whose read end the reader thread will consume.
    public func attachPipes(stdin: Pipe, stdout: Pipe) {
        stdinWriteHandle = stdin.fileHandleForWriting
        stdinOpen = true
        startReaderThread(stdoutPipe: stdout)
    }

    // MARK: - request

    /// Send a msgpack-RPC request and await its response.
    ///
    /// Executes entirely on the actor's executor: allocates a msgid, encodes
    /// `[0, msgid, method, params]`, writes to stdin, registers a continuation,
    /// and suspends. The continuation is resumed by `deliver(_:)` when the
    /// matching response arrives.
    ///
    /// - Parameters:
    ///   - method: The nvim API method name (e.g. `"nvim_command"`).
    ///   - params: Method parameters.
    ///   - responseDecoder: Transforms the response `result` field into `T`.
    ///     Called on the actor's executor. May throw; the error propagates to
    ///     the caller.
    /// - Returns: The decoder's output.
    /// - Throws: `NvimRPCError.connectionClosed` if stdin is already closed.
    ///           `NvimRPCError.remoteError` if the nvim response error field is
    ///           non-nil / non-.nil. Any error thrown by `responseDecoder`.
    public func request<T: Sendable>(
        method: String,
        params: [MessagePackValue],
        responseDecoder: @Sendable (MessagePackValue) throws -> T
    ) async throws -> T {
        guard stdinOpen else { throw NvimRPCError.connectionClosed }

        let msgid = nextMsgid
        nextMsgid += 1

        // Encode [0, msgid, method, params].
        let frame = pack(
            .array([
                .uint(0),
                .int(Int64(msgid)),
                .string(method),
                .array(params),
            ]))

        writeToStdin(frame)

        // Suspend and register the continuation. The continuation is resumed
        // by deliver(_:) on the actor executor — no lock needed.
        //
        // Cancellation safety: if the calling Task is cancelled while suspended
        // here, `withTaskCancellationHandler` removes the continuation from
        // `pending` and resumes it with `CancellationError`. Without this,
        // a cancelled Task would leave a dangling continuation entry in `pending`
        // that can never be resumed — a memory leak and potential deadlock.
        let rawResult: MessagePackValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[msgid] = cont
            }
        } onCancel: {
            // onCancel runs in the cancelling context (arbitrary thread), so we
            // hop to the actor to safely remove and resume the continuation.
            Task { [weak self] in
                await self?.cancelPendingRequest(msgid: msgid)
            }
        }

        return try responseDecoder(rawResult)
    }

    // MARK: - notify

    /// Send a one-way msgpack-RPC notification (no response expected).
    ///
    /// Encodes `[2, method, params]` and writes to stdin on the actor's
    /// executor. Silently drops the write if stdin is already closed
    /// (closed-stdin contract, ARCHITECTURE.md §10.4.6).
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: Notification parameters.
    public func notify(method: String, params: [MessagePackValue]) {
        guard stdinOpen else { return }

        let frame = pack(
            .array([
                .uint(2),
                .string(method),
                .array(params),
            ]))

        writeToStdin(frame)
    }

    // MARK: - onNotification

    /// Register a callback invoked when a notification with `method` arrives.
    ///
    /// The handler is called on the actor's executor. It must only post
    /// `Sendable` values to `EventChannel` — no other side effects.
    /// Registering a second handler for the same method replaces the first.
    ///
    /// - Parameters:
    ///   - method: The notification method to observe (e.g. `"redraw"`).
    ///   - handler: Called with the notification's `params` array.
    public func onNotification(
        _ method: String,
        _ handler: @Sendable @escaping ([MessagePackValue]) -> Void
    ) {
        notificationHandlers[method] = handler
    }

    // MARK: - deliver

    /// Dispatch a decoded `RawRPCMessage` to the appropriate handler.
    ///
    /// Called exclusively from the reader thread via `Task { await deliver }`.
    /// Runs on the actor's executor — all state access is safe.
    ///
    /// - Parameter message: The decoded message to dispatch.
    public func deliver(_ message: RawRPCMessage) {
        switch message {
        case .response(let msgid, let error, let result):
            guard let cont = pending.removeValue(forKey: msgid) else {
                log.debug(
                    "NvimRPCClient: received response for unknown msgid \(msgid) — dropped"
                )
                return
            }
            // Treat any non-nil error field as a remote error.
            if case .nil = error {
                cont.resume(returning: result)
            } else {
                cont.resume(throwing: NvimRPCError.remoteError(error))
            }

        case .notification(let method, let params):
            if let handler = notificationHandlers[method] {
                handler(params)
            } else {
                log.debug(
                    "NvimRPCClient: unhandled notification '\(method)' — no handler registered"
                )
            }

        case .request(let msgid, let method, _):
            // nvim almost never sends requests; log and drop as per spec.
            log.debug(
                "NvimRPCClient: ignoring incoming request msgid=\(msgid) method='\(method)'"
            )
        }
    }

    // MARK: - Cancellation helper

    /// Remove a pending continuation by msgid and resume it with `CancellationError`.
    ///
    /// Called from the `withTaskCancellationHandler` onCancel closure via a Task
    /// hop so execution happens on the actor's executor. Safe to call even if the
    /// continuation was already resumed (the dictionary remove is a no-op).
    func cancelPendingRequest(msgid: Int) {
        guard let cont = pending.removeValue(forKey: msgid) else { return }
        cont.resume(throwing: CancellationError())
    }

    // MARK: - EOF / connection-closed notification from reader

    /// Called by the reader thread (via a Task hop) when it observes EOF or a
    /// framer cap violation. Sets stdinOpen=false so subsequent send attempts
    /// are dropped safely.
    func readerDidObserveEOF() {
        guard stdinOpen else { return }
        stdinOpen = false
        log.debug("NvimRPCClient: reader observed EOF — stdin marked closed")

        // Cancel all pending continuations so callers don't hang.
        let snapshot = pending
        pending.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: NvimRPCError.connectionClosed)
        }
    }

    // MARK: - Shutdown

    /// Signal the reader thread to stop and wait for it to exit.
    ///
    /// Callers must close the stdout write end **before** calling this method
    /// so that the reader's blocking `read(2)` returns 0 (EOF). This is
    /// `nonisolated` so the caller can wait without re-entering the actor
    /// executor (the wait is a blocking semaphore wait, not `await`).
    ///
    /// Typical teardown sequence:
    ///   1. `stdoutPipe.fileHandleForWriting.closeFile()` — produces EOF.
    ///   2. `await client.shutdownReader()` — joins the thread.
    ///   3. Close remaining pipe handles.
    public nonisolated func shutdownReader() {
        stopReaderFlag = true
        let timeout = DispatchTime.now() + NvimRPCClient.threadJoinTimeoutSeconds
        _ = readerExitSemaphore.wait(timeout: timeout)
    }

    // MARK: - Private: stdin write

    /// Write `data` to the stdin FileHandle. On any write failure, marks stdin
    /// as closed. All callers must check `stdinOpen` before calling this.
    private func writeToStdin(_ data: Data) {
        guard let handle = stdinWriteHandle else { return }
        // FileHandle.write(_:) raises NSFileHandleOperationException (uncatchable)
        // on a closed fd. The stdinOpen guard above is the only safe protection.
        // If somehow we reach here on a bad fd (OS race), the process crashes —
        // but that is prevented by the session-nil guard in AppDriver (§10.6).
        handle.write(data)
    }

    // MARK: - Private: reader thread

    /// Start the background reader thread that drains nvim's stdout pipe.
    private func startReaderThread(stdoutPipe: Pipe) {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        // Capture only Sendable values: `self` (actor = Sendable), `fd` (Int32).
        // runReaderLoop is nonisolated so calling it from the Thread body is safe
        // without an async hop — it never touches actor-isolated state directly.
        let thread = Thread { [weak self] in
            self?.runReaderLoop(fd: fd)
        }
        thread.name = "moonswift.nvim-rpc-reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The reader loop. Runs entirely on the nvim-rpc-class thread.
    ///
    /// The loop uses a fixed 64 KiB buffer and blocking `read(2)` (POSIX).
    /// This avoids the drawbacks of `availableData` (busy-polls) and
    /// `readabilityHandler` (fires on an uncontrolled GCD queue).
    ///
    /// On EOF (read returns 0) or after a `FramerError`, the loop exits, the
    /// semaphore is signalled (enabling `shutdownReader()` to return), and a
    /// Task hop notifies the actor to set `stdinOpen = false`.
    ///
    /// `nonisolated` because it runs on the nvim-rpc-class Thread, not on the
    /// actor's executor. It accesses only `nonisolated` state (`stopReaderFlag`,
    /// `readerExitSemaphore`, `log`) and communicates with actor-isolated state
    /// exclusively through `Task { await self.deliver/readerDidObserveEOF }`.
    nonisolated private func runReaderLoop(fd: Int32) {
        let bufferSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var framer = MsgpackRPCFramer()

        defer { readerExitSemaphore.signal() }

        while !stopReaderFlag {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, bufferSize)
            }

            if n == 0 {
                // EOF: nvim closed its stdout (clean exit or teardown).
                log.debug("NvimRPCClient reader: EOF on nvim stdout")
                signalEOF()
                return
            }

            if n < 0 {
                // Error (EINTR is handled by retrying; other errors are fatal).
                if errno == EINTR { continue }
                log.debug("NvimRPCClient reader: read(2) error \(errno) — exiting loop")
                signalEOF()
                return
            }

            let chunk = Data(buf[0..<n])
            let decoded: [MessagePackValue]

            do {
                decoded = try framer.pushChecked(chunk)
            } catch let e as FramerError {
                log.debug("NvimRPCClient reader: framer cap violation \(e) — closing")
                signalEOF()
                return
            } catch {
                log.debug("NvimRPCClient reader: unexpected framer error \(error) — closing")
                signalEOF()
                return
            }

            for value in decoded {
                guard let msg = RawRPCMessage.parse(from: value) else {
                    log.debug(
                        "NvimRPCClient reader: unrecognised msgpack-RPC shape — dropped"
                    )
                    continue
                }
                // Enqueue delivery to the actor; the reader thread does not hold
                // the actor lock — the Task wrapper is the only channel.
                Task { [weak self] in
                    await self?.deliver(msg)
                }
            }
        }
    }

    /// Post an EOF notification to the actor from the reader thread.
    /// `nonisolated` because it is called from `runReaderLoop` (nvim-rpc-class
    /// thread). The actual state mutation happens inside `readerDidObserveEOF`
    /// on the actor's executor via the Task hop.
    nonisolated private func signalEOF() {
        Task { [weak self] in
            await self?.readerDidObserveEOF()
        }
    }
}
