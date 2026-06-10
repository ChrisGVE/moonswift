// File: Tests/MoonSwiftTUITests/Nvim/NvimRPCClientTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Unit tests for NvimRPCClient — the actor that owns stdin writes and
//       deserialises nvim's msgpack-RPC responses. All tests use fake Pipe pairs;
//       no real nvim process is required.
//
// Architecture context (ARCHITECTURE.md §10.4.6, §10.6):
//   The actor serialises all state (msgid counter, pending continuations, handler
//   registry, stdinOpen flag). Tests exercise the wire protocol over real OS pipes
//   to verify framing, ordering, handler dispatch, and teardown robustness.
//
// Test teardown convention:
//   Every test closes the stdoutPipe write end before calling shutdownReader().
//   This produces EOF on the reader's blocking read(2), causing the reader thread
//   to exit and the DispatchSemaphore in shutdownReader() to be signalled promptly.
//   Without this, the reader would block indefinitely and shutdownReader() would
//   wait the full 2 s timeout before returning.
//
// Relationships:
//   → NvimRPCClient.swift: the unit under test
//   → MsgpackRPCFramer.swift: framing used internally by the reader thread
//   → MessagePackValue: pack/unpack used to craft test frames

import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Test helpers

/// Encode a 4-element msgpack-RPC response `[1, msgid, error, result]`.
private func responseBytes(msgid: Int, error: MessagePackValue, result: MessagePackValue) -> Data {
    pack(.array([.uint(1), .int(Int64(msgid)), error, result]))
}

/// Encode a 3-element msgpack-RPC notification `[2, method, params]`.
private func notificationBytes(method: String, params: [MessagePackValue]) -> Data {
    pack(.array([.uint(2), .string(method), .array(params)]))
}

/// Decode a single msgpack value from `data`. Crashes on test misconfiguration.
private func decodeSingle(_ data: Data) -> MessagePackValue {
    guard let v = try? unpackFirst(data) else {
        fatalError("Test helper: failed to decode msgpack from \(data.count) bytes")
    }
    return v
}

/// Extract an `Int` msgid from either a `.int` or `.uint` MessagePackValue.
/// The msgpack-RPC protocol allows the msgid to be encoded as either type
/// (pack(.int(0)) produces fixint 0x00, which decodes as .uint(0)).
private func extractMsgid(_ v: MessagePackValue) -> Int? {
    switch v {
    case .int(let i): return Int(i)
    case .uint(let u): return Int(exactly: u)
    default: return nil
    }
}

/// Run `operation` with a hard deadline. On timeout the operation's Task is
/// cancelled and its (cancellation-induced) error propagates to the caller.
///
/// Deadlock-proofing note: an earlier version raced the operation against a
/// timeout child inside a `withThrowingTaskGroup`. That shape deadlocks on
/// timeout — the group's scope-exit await waits for the operation child, and
/// a child suspended on a non-cancellable await (e.g. `Task.value`) never
/// finishes. Cancelling an unstructured Task that the operation itself owns
/// (this version) is the only shape that cannot hang: `operation` must be
/// cancellation-responsive, which `NvimRPCClient.request` and `Task.sleep`
/// both are.
private func withTimeout<T: Sendable>(
    nanoseconds: UInt64 = 3_000_000_000,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let opTask = Task { try await operation() }
    return try await awaitWithTimeout(opTask, nanoseconds: nanoseconds)
}

/// Await `task.value` with a watchdog that cancels `task` on timeout.
///
/// `Task.value` itself is NOT cancellation-responsive (it waits for the task
/// to finish no matter what), so the watchdog cancels the awaited task — the
/// task's own cancellation handling (e.g. `request`'s
/// `withTaskCancellationHandler`) then completes it with `CancellationError`,
/// which surfaces here as the thrown error. A test regression therefore fails
/// within the deadline instead of hanging CI.
private func awaitWithTimeout<T: Sendable>(
    _ task: Task<T, Error>,
    nanoseconds: UInt64 = 3_000_000_000
) async throws -> T {
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: nanoseconds)
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try await task.value
}

/// Poll `stdinPipe.fileHandleForReading` for stdin bytes using a background
/// DispatchSemaphore-based reader that does NOT block the cooperative thread pool.
/// Accumulates bytes across calls; returns all bytes seen so far.
///
/// Uses a background DispatchQueue to read, posting bytes back via a channel
/// implemented with a checked continuation. Times out after `timeoutNs`.
private func pollStdinUntil(
    count minFrames: Int,
    stdinPipe: Pipe,
    timeoutNs: UInt64 = 500_000_000
) async -> (data: Data, frames: [MessagePackValue]) {
    let fd = stdinPipe.fileHandleForReading.fileDescriptor
    var accumulated = Data()
    let deadline = Date(timeIntervalSinceNow: Double(timeoutNs) / 1e9)

    while Date() < deadline {
        // Non-blocking read attempt using O_NONBLOCK on the fd temporarily.
        // We set the fd to non-blocking, read what's there, then restore.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { ptr in read(fd, ptr.baseAddress, 4096) }
        _ = fcntl(fd, F_SETFL, flags)  // restore blocking mode

        if n > 0 {
            accumulated.append(contentsOf: buf[0..<n])
            // Feed all accumulated bytes to a fresh framer each time we add new data.
            // (The framer is stateful but we re-create it to decode from the
            //  full accumulated buffer rather than try to maintain framer state.)
            var freshFramer = MsgpackRPCFramer()
            if let frames = try? freshFramer.pushChecked(accumulated),
                frames.count >= minFrames
            {
                return (accumulated, frames)
            }
        }

        // Yield the cooperative thread to let other tasks (including the actor's
        // writes) make progress, then retry.
        try? await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
    }

    // Return whatever we have after timeout.
    var freshFramer = MsgpackRPCFramer()
    let frames = (try? freshFramer.pushChecked(accumulated)) ?? []
    return (accumulated, frames)
}

// MARK: - Suite

@Suite("NvimRPCClient")
struct NvimRPCClientTests {

    // MARK: request / response round-trip

    /// Spawning the actor with fake pipes, sending a request, feeding a crafted
    /// response back through the stdout pipe, and asserting the decoded result.
    @Test("request returns decoded result from a crafted response frame")
    func requestResponseRoundTrip() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // Kick off the request in a child Task (async let can't be captured by
        // closures, so we use an explicit Task handle instead).
        let requestHandle = Task<MessagePackValue, Error> {
            try await client.request(
                method: "nvim_get_api_info",
                params: [],
                responseDecoder: { v in v }
            )
        }

        // Poll stdin until the request frame arrives.
        let (_, frames) = await pollStdinUntil(count: 1, stdinPipe: stdinPipe)

        guard frames.count >= 1 else {
            requestHandle.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("No request frame written to stdin within timeout")
            return
        }

        // Decode the msgid from the request frame [0, msgid, method, params].
        let requestFrame = frames[0]
        guard case .array(let arr) = requestFrame, arr.count == 4,
            let msgid = extractMsgid(arr[1])
        else {
            requestHandle.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("Request frame shape mismatch: \(requestFrame)")
            return
        }

        // Write the matching response into the stdout pipe.
        let responseData = responseBytes(msgid: msgid, error: .nil, result: .string("hello"))
        stdoutPipe.fileHandleForWriting.write(responseData)

        // Await the result with a watchdog so a regression can't hang CI.
        let result = try await awaitWithTimeout(requestHandle)
        #expect(result == .string("hello"))

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
    }

    // MARK: notify encodes and writes

    /// `notify` must write a 3-element `[2, method, params]` frame to stdin.
    @Test("notify writes a well-formed [2,method,params] frame to stdin")
    func notifyWritesFrame() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        await client.notify(method: "ping", params: [.string("payload")])

        // Poll stdin until the notification frame arrives.
        let (_, frames) = await pollStdinUntil(count: 1, stdinPipe: stdinPipe)
        #expect(frames.count >= 1, "Expected at least 1 notification frame")

        guard let frame = frames.first, case .array(let arr) = frame else {
            Issue.record("Notification frame is not an array or missing")
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            return
        }
        #expect(arr.count == 3)
        #expect(arr[0] == .uint(2))
        #expect(arr[1] == .string("ping"))
        #expect(arr[2] == .array([.string("payload")]))

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
    }

    // MARK: onNotification handler dispatch

    /// A handler registered with `onNotification` must be invoked when a
    /// matching notification frame arrives on the stdout pipe.
    @Test("onNotification handler fires when matching notification arrives")
    func onNotificationHandlerFires() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // Bridge the handler callback through an AsyncStream rather than a bare
        // checked continuation: `for await` is cancellation-responsive, so the
        // withTimeout watchdog can fail this test instead of hanging it if the
        // handler never fires.
        let stream = AsyncStream<MessagePackValue> { continuation in
            Task {
                await client.onNotification("redraw") { params in
                    continuation.yield(.array(params))
                    continuation.finish()
                }

                // Write the notification after handler registration.
                let frameData = notificationBytes(
                    method: "redraw",
                    params: [.string("grid_line"), .int(42)]
                )
                stdoutPipe.fileHandleForWriting.write(frameData)
            }
        }

        let received: MessagePackValue = try await withTimeout {
            for await value in stream { return value }
            throw CancellationError()
        }

        guard case .array(let arr) = received else {
            Issue.record("Handler did not receive an array")
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            return
        }
        #expect(arr.count == 2)
        #expect(arr[0] == .string("grid_line"))
        #expect(arr[1] == .int(42))

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
    }

    // MARK: Response ordering

    /// Two concurrent requests must each receive their correct response even when
    /// responses arrive in reverse order.
    @Test("two concurrent requests each receive their correct response")
    func twoRequestsReturnInOrder() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // Launch both requests concurrently before feeding any response.
        let task1 = Task<MessagePackValue, Error> {
            try await client.request(
                method: "method_a", params: [], responseDecoder: { v in v }
            )
        }
        let task2 = Task<MessagePackValue, Error> {
            try await client.request(
                method: "method_b", params: [], responseDecoder: { v in v }
            )
        }

        // Poll stdin accumulating bytes until we have 2 frames from both tasks.
        let (_, frames) = await pollStdinUntil(
            count: 2,
            stdinPipe: stdinPipe,
            timeoutNs: 2_000_000_000
        )

        guard frames.count == 2 else {
            task1.cancel()
            task2.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("Expected 2 request frames; got \(frames.count)")
            return
        }

        // Extract msgids from the two request frames.
        var msgidFor: [String: Int] = [:]
        for frame in frames {
            guard case .array(let arr) = frame, arr.count == 4,
                let mid = extractMsgid(arr[1]),
                case .string(let method) = arr[2]
            else { continue }
            msgidFor[method] = mid
        }

        guard let mid1 = msgidFor["method_a"], let mid2 = msgidFor["method_b"] else {
            task1.cancel()
            task2.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("Could not extract msgids; map: \(msgidFor)")
            return
        }

        // Deliver responses in reverse order (r2 before r1) — tests correlation.
        stdoutPipe.fileHandleForWriting.write(
            responseBytes(msgid: mid2, error: .nil, result: .string("result_b"))
        )
        stdoutPipe.fileHandleForWriting.write(
            responseBytes(msgid: mid1, error: .nil, result: .string("result_a"))
        )

        let v1 = try await awaitWithTimeout(task1)
        let v2 = try await awaitWithTimeout(task2)

        #expect(v1 == .string("result_a"))
        #expect(v2 == .string("result_b"))

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
    }

    // MARK: Reader stop and join (EOF)

    /// Closing the stdout write end produces EOF on the reader; `shutdownReader()`
    /// must return without hanging.
    @Test("shutdownReader returns after stdout pipe is closed (EOF)")
    func shutdownReaderOnEOF() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // Close the write end — reader sees EOF.
        stdoutPipe.fileHandleForWriting.closeFile()

        // shutdownReader() is nonisolated/synchronous. Wrap in Task + timeout to
        // ensure a deadlock surfaces as a test failure rather than a CI hang.
        let completed = try await withTimeout(nanoseconds: 5_000_000_000) {
            client.shutdownReader()
            return true
        }
        #expect(completed == true, "shutdownReader should return once reader exits")
    }

    // MARK: Closed-stdin contract — notify

    /// After the stdout pipe is closed (causing stdinOpen=false), `notify` must
    /// silently drop the write rather than crashing or throwing.
    @Test("notify is silent after reader detects EOF and stdinOpen is false")
    func notifyDropsAfterClose() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        // EOF → reader exits → readerDidObserveEOF marks stdinOpen=false.
        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()

        // Wait for the actor to process the readerDidObserveEOF Task hop.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Calling notify after shutdown must not crash or throw.
        await client.notify(method: "after_close", params: [])
        // Reaching here without crashing is the success condition.
    }

    // MARK: Closed-stdin contract — request throws

    /// After stdinOpen becomes false, `request` must throw `NvimRPCError.connectionClosed`
    /// rather than writing to a closed FileHandle.
    @Test("request throws connectionClosed after stdin is closed")
    func requestThrowsAfterClose() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()

        // Wait for the actor to process the EOF hop and set stdinOpen=false.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Timing note: even if the reader's EOF hop has not landed yet (stdinOpen
        // still true), the request registers a continuation that the hop then
        // fails with connectionClosed — both orders converge on the same error.
        // The withTimeout watchdog turns any regression into a fast failure.
        do {
            _ = try await withTimeout {
                try await client.request(
                    method: "should_fail",
                    params: [],
                    responseDecoder: { v in v }
                )
            }
            Issue.record("Expected NvimRPCError.connectionClosed to be thrown")
        } catch NvimRPCError.connectionClosed {
            // Expected path.
        } catch is CancellationError {
            Issue.record("request hung past deadline instead of throwing connectionClosed")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Response error field propagation

    /// When the response carries a non-nil error field, `request` must throw
    /// `NvimRPCError.remoteError` carrying that value.
    @Test("request throws remoteError when response error field is non-nil")
    func requestThrowsOnRemoteError() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        let requestHandle = Task<MessagePackValue, Error> {
            try await client.request(
                method: "bad_method",
                params: [],
                responseDecoder: { v in v }
            )
        }

        // Poll stdin until the request frame appears.
        let (_, frames) = await pollStdinUntil(count: 1, stdinPipe: stdinPipe)

        guard frames.count >= 1,
            case .array(let arr) = frames[0],
            let mid = extractMsgid(arr[1])
        else {
            requestHandle.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("Could not extract msgid from request frame")
            return
        }

        // Respond with a non-nil error field.
        let errData = responseBytes(
            msgid: mid,
            error: .array([.int(0), .string("E492: Not an editor command")]),
            result: .nil
        )
        stdoutPipe.fileHandleForWriting.write(errData)

        do {
            _ = try await awaitWithTimeout(requestHandle)
            Issue.record("Expected NvimRPCError.remoteError to be thrown")
        } catch NvimRPCError.remoteError {
            // Expected path.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
    }
}
