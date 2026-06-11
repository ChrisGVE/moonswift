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
//   → NvimRPCClient+Reader.swift  (this file's extension): reader-thread methods
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
    // internal (not private): accessed from NvimRPCClient+Reader.swift extension.
    nonisolated let readerFlagQueue = DispatchQueue(
        label: "moonswift.nvim-rpc-reader-flag",
        qos: .utility
    )
    /// Backing storage for the stop flag; access only via readerFlagQueue.
    // internal: accessed from NvimRPCClient+Reader.swift extension.
    nonisolated(unsafe) var _stopReader: Bool = false

    // internal: accessed from NvimRPCClient+Reader.swift extension.
    nonisolated var stopReaderFlag: Bool {
        get { readerFlagQueue.sync { _stopReader } }
        set { readerFlagQueue.sync { _stopReader = newValue } }
    }

    /// Signalled by the reader thread when it has fully exited its loop.
    // internal: accessed from NvimRPCClient+Reader.swift extension.
    nonisolated let readerExitSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Logger

    // nonisolated so the reader thread (nvim-rpc-class) can log without
    // hopping to the actor executor. Logger.shared is thread-safe (os_log).
    // internal: accessed from NvimRPCClient+Reader.swift extension.
    nonisolated let log = Logger.shared

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
        // Set once here rather than per write: SIGPIPE becomes a returnable
        // EPIPE for every subsequent write(2) on this fd.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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

        // Fail immediately if the write fails rather than registering a
        // continuation that would strand until the reader observes EOF.
        guard writeToStdin(frame) else { throw NvimRPCError.connectionClosed }

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
            //
            // Strong self capture is safe here: the actor's lifetime is bounded
            // by the session that owns it; the Task hop completes promptly
            // (one actor dispatch) and holds no other resources, so there is
            // no retain cycle — the Task itself is not retained by self.
            Task { [self] in
                await cancelPendingRequest(msgid: msgid)
            }
        }

        return try responseDecoder(rawResult)
    }

    // MARK: - notify

    /// Send a one-way msgpack-RPC notification (no response expected).
    ///
    /// Declared `async` per the §10.4.6 interface specification. The body is
    /// synchronous on the actor's executor; callers `await` for the actor-isolation
    /// hop, not for I/O suspension. Silently drops the write if stdin is already
    /// closed (closed-stdin contract, ARCHITECTURE.md §10.4.6).
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: Notification parameters.
    public func notify(method: String, params: [MessagePackValue]) async {
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
    ///
    /// Any request that was in-flight (continuation registered, waiting for a
    /// response) at the time of EOF is resolved here with `connectionClosed`.
    /// This means a write-back buffer fetch requested just before clean shutdown
    /// surfaces as `NvimRPCError.connectionClosed` at the call site rather than
    /// silently hanging. AppDriver maps that to `.writeBackFailed(.ioFailure)`.
    func readerDidObserveEOF() {
        guard stdinOpen else { return }
        stdinOpen = false
        log.debug("NvimRPCClient: reader observed EOF — stdin marked closed")

        // Fail all pending continuations so callers don't hang indefinitely.
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

    /// Write `data` to stdin via POSIX `write(2)` with an EINTR retry loop.
    ///
    /// Returns `true` on full success, `false` on any error (EPIPE, EBADF,
    /// short write). On failure also sets `stdinOpen = false`.
    ///
    /// `FileHandle.write(_:)` raises an uncatchable ObjC exception on a closed
    /// fd; POSIX `write(2)` returns -1/EPIPE instead. F_SETNOSIGPIPE is set
    /// once in `attachPipes` so SIGPIPE arrives as a returnable EPIPE here
    /// (same pattern as FakeNvimServer in tests).
    ///
    /// All callers must check `stdinOpen` before calling this.
    @discardableResult
    private func writeToStdin(_ data: Data) -> Bool {
        guard let handle = stdinWriteHandle else {
            stdinOpen = false
            return false
        }
        let fd = handle.fileDescriptor
        let ok: Bool = data.withUnsafeBytes { ptr -> Bool in
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
        if !ok {
            stdinOpen = false
            log.debug("NvimRPCClient: stdin write failed (errno \(errno)) — marking closed")
        }
        return ok
    }

}
// Reader-thread methods (startReaderThread, runReaderLoop, postEOFToActor) live
// in NvimRPCClient+Reader.swift to keep both files within the 400-line budget.
