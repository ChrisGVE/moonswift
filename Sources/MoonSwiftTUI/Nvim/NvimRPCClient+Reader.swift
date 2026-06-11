// File: Sources/MoonSwiftTUI/Nvim/NvimRPCClient+Reader.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Reader-thread machinery for NvimRPCClient. Extracted from
//       NvimRPCClient.swift to stay within the 400-line file budget.
//       Contains the three nonisolated methods that run on (or start)
//       the nvim-rpc-class background Thread.
//
// Architecture context (ARCHITECTURE.md §10.4.6):
//   The reader thread (nvim-rpc-class) is the sole non-actor context that
//   produces messages for NvimRPCClient. It accesses only nonisolated state
//   (stopReaderFlag, readerExitSemaphore, log) and delivers messages to
//   actor-isolated state exclusively via Task { await self.deliver(...) }.
//
// Relationships:
//   ↔ NvimRPCClient.swift: main actor declaration — stored props, init,
//     public API (attachPipes, request, notify, onNotification, deliver,
//     shutdownReader, writeToStdin). Extension methods here are private /
//     nonisolated; they call back into actor-isolated methods only via Task.

import Darwin
import Foundation
import MoonSwiftCore

// MARK: - NvimRPCClient: reader-thread extension

extension NvimRPCClient {

    /// Start the background reader thread that drains nvim's stdout pipe.
    ///
    /// Called from `attachPipes` on the actor's executor.  The Thread body
    /// captures `self` strongly: the actor outlives the thread (the thread is
    /// stopped before the actor can be deallocated), so there is no cycle.
    func startReaderThread(stdoutPipe: Pipe) {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        // Strong self capture is required here: if `self` were captured weakly
        // and the actor were deallocated before the thread's first iteration,
        // `runReaderLoop` would never be called, `readerExitSemaphore` would
        // never be signalled, and `shutdownReader()` would block for the full
        // 2 s timeout. The thread lifetime is bounded — it exits when it sees
        // the stop flag or EOF, whichever comes first — so there is no cycle.
        let thread = Thread { [self] in
            runReaderLoop(fd: fd)
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
    /// On ANY loop exit — EOF (read returns 0), read error, `FramerError`, or
    /// the stop flag — the `defer` block first posts a Task hop that sets
    /// `stdinOpen = false` and fails pending continuations
    /// (`readerDidObserveEOF`, idempotent), then signals the semaphore so
    /// `shutdownReader()` can return. The EOF notification MUST be
    /// unconditional: if the stop flag is set before this thread first checks
    /// it (a thread that starts late), the loop exits without ever reading —
    /// skipping the notification would leave `stdinOpen == true` forever and
    /// any later `request()` would suspend with no one to resume it.
    ///
    /// `nonisolated` because it runs on the nvim-rpc-class Thread, not on the
    /// actor's executor. It accesses only `nonisolated` state (`stopReaderFlag`,
    /// `readerExitSemaphore`, `log`) and communicates with actor-isolated state
    /// exclusively through `Task { await self.deliver/readerDidObserveEOF }`.
    nonisolated func runReaderLoop(fd: Int32) {
        let bufferSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var framer = MsgpackRPCFramer()

        defer {
            postEOFToActor()
            readerExitSemaphore.signal()
        }

        while !stopReaderFlag {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, bufferSize)
            }

            if n == 0 {
                // EOF: nvim closed its stdout (clean exit or teardown).
                log.debug("NvimRPCClient reader: EOF on nvim stdout")
                return
            }

            if n < 0 {
                // Error (EINTR is handled by retrying; other errors are fatal).
                if errno == EINTR { continue }
                log.debug("NvimRPCClient reader: read(2) error \(errno) — exiting loop")
                return
            }

            let chunk = Data(buf[0..<n])
            let decoded: [MessagePackValue]

            do {
                decoded = try framer.pushChecked(chunk)
            } catch let e as FramerError {
                log.debug("NvimRPCClient reader: framer cap violation \(e) — closing")
                return
            } catch {
                log.debug("NvimRPCClient reader: unexpected framer error \(error) — closing")
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
                // Strong self: actor lifetime exceeds the reader thread (the
                // thread is stopped before the actor can be deallocated).
                Task { [self] in
                    await deliver(msg)
                }
            }
        }
    }

    /// Post an EOF notification to the actor from the reader thread.
    ///
    /// `nonisolated` because it is called from `runReaderLoop` (nvim-rpc-class
    /// thread). The actual state mutation happens inside `readerDidObserveEOF`
    /// on the actor's executor via the Task hop. Strong self: same bounded-
    /// lifetime rationale as `startReaderThread` — the actor outlives the thread.
    nonisolated func postEOFToActor() {
        Task { [self] in
            await readerDidObserveEOF()
        }
    }
}
