// File: Tests/MoonSwiftTUITests/Nvim/EditorBridgeTestSupport.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Shared test infrastructure for EditorBridge test suites — fake server,
//       pipe helpers, fragment factories, and event polling utilities.
//
// See EditorBridgeTests.swift and EditorBridgeFallbackTests.swift for the suites
// that consume these types. Pattern mirrors WriteBackTestSupport.swift.

import CryptoKit
import Foundation
import RatatuiKit
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - FakeNvimServer

/// Minimal fake "nvim server" that reads msgpack-RPC request frames from the
/// stdin pipe (written by the NvimRPCClient actor), responds with an OK frame
/// `[1, msgid, nil, nil]`, and records method names in arrival order.
///
/// Runs on a dedicated DispatchQueue. Call `start()` before the EditorBridge
/// spawn task; call `stop()` and close the stdoutPipe write-end when done.
final class FakeNvimServer: @unchecked Sendable {

    /// All request method names seen, in arrival order.
    private(set) var recordedMethods: [String] = []

    private let stdinReadHandle: FileHandle
    private let stdoutWriteHandle: FileHandle
    private let stdoutFD: Int32
    private let queue = DispatchQueue(label: "test.fake-nvim-server", qos: .utility)
    private let lock = NSLock()
    private let countSemaphore = DispatchSemaphore(value: 0)
    private var targetCount: Int = 0
    private var stopped: Bool = false

    /// - Parameters:
    ///   - stdinPipe: The pipe whose **read** end is the server's input
    ///     (the actor writes requests to the **write** end).
    ///   - stdoutPipe: The pipe whose **write** end the server uses to send
    ///     OK responses back to the actor's reader thread.
    init(stdinPipe: Pipe, stdoutPipe: Pipe) {
        self.stdinReadHandle = stdinPipe.fileHandleForReading
        self.stdoutWriteHandle = stdoutPipe.fileHandleForWriting
        self.stdoutFD = stdoutWriteHandle.fileDescriptor
        // The test may close the actor-side read end while a reply is in
        // flight; suppress SIGPIPE so the write just fails with EPIPE.
        _ = fcntl(stdoutFD, F_SETNOSIGPIPE, 1)
    }

    func start() {
        queue.async { [weak self] in self?.runLoop() }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Block until `count` request frames have been recorded, or timeout.
    /// Returns `true` if the goal was reached within the deadline.
    func waitForMethods(count: Int, timeoutSeconds: Double = 3.0) -> Bool {
        lock.lock()
        targetCount = count
        // Signal immediately if we already have enough (race with start()).
        if recordedMethods.count >= count {
            lock.unlock()
            return true
        }
        lock.unlock()
        let deadline = DispatchTime.now() + timeoutSeconds
        return countSemaphore.wait(timeout: deadline) == .success
    }

    /// Thread-safe snapshot of all recorded method names at this instant.
    func snapshotMethods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMethods
    }

    private func runLoop() {
        let fd = stdinReadHandle.fileDescriptor
        var framer = MsgpackRPCFramer()
        var raw = [UInt8](repeating: 0, count: 65536)

        while true {
            lock.lock()
            let halted = stopped
            lock.unlock()
            if halted { break }

            let cap = raw.count
            let n = raw.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, cap)
            }
            if n <= 0 { break }

            guard let frames = try? framer.pushChecked(Data(raw[0..<n])) else { continue }
            for frame in frames { handleFrame(frame) }
        }
    }

    private func handleFrame(_ frame: MessagePackValue) {
        // Request shape: [0, msgid, method, params]
        guard case .array(let arr) = frame, arr.count == 4 else { return }

        let typeTag: UInt64
        switch arr[0] {
        case .uint(let u): typeTag = u
        default: return
        }
        guard typeTag == 0 else { return }  // must be a request (type 0)

        let msgid: Int64
        switch arr[1] {
        case .int(let i): msgid = i
        case .uint(let u): msgid = Int64(u)
        default: return
        }

        guard case .string(let method) = arr[2] else { return }

        lock.lock()
        recordedMethods.append(method)
        let reached = recordedMethods.count >= targetCount && targetCount > 0
        lock.unlock()

        if reached { countSemaphore.signal() }

        // Respond with OK: [1, msgid, nil, nil].
        //
        // POSIX write(2), NOT FileHandle.write: teardown can close this pipe
        // end while a frame is still being handled, and NSFileHandle raises an
        // uncatchable ObjC exception on a closed fd — it took the whole test
        // process down with SIGSEGV (sequence-dependent suite crash). write(2)
        // returns -1 (EBADF/EPIPE) instead; the server is best-effort.
        lock.lock()
        let halted = stopped
        lock.unlock()
        guard !halted else { return }

        let response = pack(.array([.uint(1), .int(msgid), .nil, .nil]))
        _ = response.withUnsafeBytes { ptr in
            write(stdoutFD, ptr.baseAddress, ptr.count)
        }
    }
}

// MARK: - FakePipePair

/// A fake Pipe pair and server ready for use in EditorBridge tests.
/// `stdinPipe`  — actor writes requests here; server reads from the read-end.
/// `stdoutPipe` — server writes responses here; actor reads from the read-end.
struct FakePipePair {
    let stdinPipe: Pipe
    let stdoutPipe: Pipe
    let server: FakeNvimServer

    init() {
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        server = FakeNvimServer(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
    }

    /// Tear down after a test: stop the server loop FIRST (so a frame still in
    /// flight does not write into a closing pipe), then close the stdout
    /// write-end (causes EOF on the actor reader), then join the reader thread.
    func teardown(rpc: NvimRPCClient) {
        server.stop()
        stdoutPipe.fileHandleForWriting.closeFile()
        rpc.shutdownReader()
    }
}

// MARK: - Shared helpers

/// A 80×24 Rect for use as the codePaneRect in tests.
let testRect = Rect(x: 0, y: 0, width: 80, height: 24)

/// A 3-element msgpack-RPC notification frame `[2, method, params]`.
/// Named with the `editorBridge` prefix to avoid collision with the same
/// helper defined privately in NvimRPCClientTests.swift.
func editorBridgeNotificationBytes(method: String, params: [MessagePackValue] = []) -> Data {
    pack(.array([.uint(2), .string(method), .array(params)]))
}

/// Resolve the `NvimRPCClient` actor identity from a `.nvimReady` event.
func sessionFromReady(_ event: AppEvent) -> NvimSession? {
    if case .nvimReady(let s) = event { return s }
    return nil
}

/// Poll `channel` with short sleeps until `predicate` matches an event, or timeout.
func waitForEvent(
    in channel: EventChannel,
    timeoutSeconds: Double = 3.0,
    predicate: (AppEvent) -> Bool
) async -> AppEvent? {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    while Date() < deadline {
        let events = channel.drainAll()
        if let match = events.first(where: predicate) { return match }
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
    }
    return nil
}

/// Minimal LuaSourceFragment with a whole-file .lua provenance (`jsonpath == nil`).
func makeLuaFragment(at path: String = "/tmp/test.lua") -> LuaSourceFragment {
    let provenance = FragmentProvenance(
        file: URL(fileURLWithPath: path),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<9,
        lineOffset: 0,
        contentHash: SHA256.hash(data: Data())
    )
    return LuaSourceFragment(code: "return 1\n", provenance: provenance)
}

/// Minimal LuaSourceFragment with a structured-file provenance (`jsonpath != nil`).
func makeStructuredFragment(code: String = "return 42\n") -> LuaSourceFragment {
    let provenance = FragmentProvenance(
        file: URL(fileURLWithPath: "/tmp/config.json"),
        jsonpath: "$.scripts.init",
        document: 0,
        byteRange: 0..<10,
        lineOffset: 0,
        contentHash: SHA256.hash(data: Data())
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}
