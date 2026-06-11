// File: Tests/MoonSwiftTUITests/Nvim/AuditFixWaveDTests_CR038_042.swift
// Location: MoonSwiftTUITests/Nvim/
// Role: Wave-D audit-fix tests for CR-038 through CR-040 — low-priority test
//       improvements identified by qa-expert.  CR-041 and CR-042 live in
//       AuditFixWaveDTests_CR041_042.swift (split for ≤ 400 lines per file).
//
//   CR-038: pollStdinUntil defaults widened from 500 ms to 2 s so the helper
//           does not time out on a loaded CI runner.  The existing helper is in
//           NvimRPCClientTests.swift and is file-private; we duplicate and widen
//           it here for the new tests that need a generous deadline.
//
//   CR-039: spawnThrowsForMissingPath is pinned to the specific error type
//           (CocoaError with .fileNoSuchFile code) rather than `any Error`.
//
//   CR-040: WriteBackCoordinator.performSplice structured-extension + nil
//           jsonpath → full-overwrite fallback; verified via write() call on a
//           .toml extension file with provenance.jsonpath == nil.
//
// Relationships:
//   → NvimRPCClientTests.swift     : pollStdinUntil helper (CR-038)
//   → NvimProcessSupervisorTests.swift : spawnThrowsForMissingPath (CR-039)
//   → WriteBackCoordinator.swift   : performSplice nil-jsonpath path (CR-040)

import CryptoKit
import Darwin
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - CR-038: pollStdinUntil widened helper

/// Widened version of the pollStdinUntil helper from NvimRPCClientTests.swift.
/// Default timeout is 2 s (was 500 ms) so CI-loaded machines do not flake.
///
/// Duplicated here (not shared) because the original is file-private in
/// NvimRPCClientTests.swift — cross-file access would require making it
/// internal, which widens visibility beyond what the test needs.
private func pollStdinUntilWide(
    count minFrames: Int,
    stdinPipe: Pipe,
    timeoutNs: UInt64 = 2_000_000_000  // CR-038: widened from 500 ms
) async -> (data: Data, frames: [MessagePackValue]) {
    let fd = stdinPipe.fileHandleForReading.fileDescriptor
    var accumulated = Data()
    let deadline = Date(timeIntervalSinceNow: Double(timeoutNs) / 1e9)

    while Date() < deadline {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { ptr in read(fd, ptr.baseAddress, 4096) }
        _ = fcntl(fd, F_SETFL, flags)

        if n > 0 {
            accumulated.append(contentsOf: buf[0..<n])
            var freshFramer = MsgpackRPCFramer()
            if let frames = try? freshFramer.pushChecked(accumulated),
                frames.count >= minFrames
            {
                return (accumulated, frames)
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    var freshFramer = MsgpackRPCFramer()
    let frames = (try? freshFramer.pushChecked(accumulated)) ?? []
    return (accumulated, frames)
}

/// Watchdog wrapper (mirrors NvimRPCClientTests.awaitWithTimeout).
private func awaitWithTimeout038<T: Sendable>(
    _ task: Task<T, Error>,
    nanoseconds: UInt64 = 5_000_000_000
) async throws -> T {
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: nanoseconds)
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try await task.value
}

// MARK: - CR-038: widened deadline smoke test

/// Confirm that pollStdinUntilWide with the new 2 s deadline successfully reads
/// a request frame from a real NvimRPCClient within the wider window.  This is a
/// regression guard: if the actor ever stalls past 500 ms on a loaded runner,
/// the old 500 ms deadline would flake; 2 s gives a 4× margin.
@Suite("CR-038 — pollStdinUntil widened to 2 s deadline")
struct PollStdinWidenedTests {

    @Test("pollStdinUntilWide reads a request frame within 2 s")
    func pollStdinWidenedReadsFrame() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        let client = NvimRPCClient()
        await client.attachPipes(stdin: stdinPipe, stdout: stdoutPipe)

        let requestTask = Task<MessagePackValue, Error> {
            try await client.request(method: "ping", params: [], responseDecoder: { v in v })
        }

        // Use the 2 s deadline helper.
        let (_, frames) = await pollStdinUntilWide(count: 1, stdinPipe: stdinPipe)

        guard frames.count >= 1,
            case .array(let arr) = frames[0], arr.count == 4
        else {
            requestTask.cancel()
            stdoutPipe.fileHandleForWriting.closeFile()
            client.shutdownReader()
            Issue.record("No request frame seen within 2 s deadline")
            return
        }

        // Extract msgid and respond so the request Task can complete.
        var msgid: Int?
        switch arr[1] {
        case .int(let i): msgid = Int(i)
        case .uint(let u): msgid = Int(exactly: u)
        default: break
        }

        if let mid = msgid {
            let resp = pack(.array([.uint(1), .int(Int64(mid)), .nil, .string("pong")]))
            stdoutPipe.fileHandleForWriting.write(resp)
            _ = try? await awaitWithTimeout038(requestTask)
        } else {
            requestTask.cancel()
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        client.shutdownReader()
        #expect(frames.count >= 1)
    }
}

// MARK: - CR-039: spawnThrowsForMissingPath — pin error type

/// CR-039: pin the specific error type thrown by spawn() when the binary is absent.
/// The existing test asserted `throws: CocoaError.self` which is correct;
/// we add a check that the NSError code is NSFileNoSuchFileError (260)
/// so that a regression that changes the error domain/code is caught.
@Suite("CR-039 — spawnThrowsForMissingPath pins error type")
struct SpawnMissingPathErrorTypeTests {

    @Test("spawn() with missing binary throws CocoaError with .fileNoSuchFile code")
    func spawnThrowsMissingPathCocoaError() {
        let supervisor = NvimProcessSupervisor()
        do {
            try supervisor.spawn(path: "/nonexistent/nvim-missing-12345") { _ in }
            Issue.record("Expected spawn() to throw for missing binary")
        } catch let cocoaError as CocoaError {
            // Pin the specific error code — .fileNoSuchFile is 260.
            #expect(
                cocoaError.code == .fileNoSuchFile,
                "Expected CocoaError.fileNoSuchFile (260); got \(cocoaError.code.rawValue)"
            )
        } catch {
            Issue.record(
                "Expected CocoaError.fileNoSuchFile; got \(type(of: error)): \(error)"
            )
        }
    }
}

// MARK: - CR-040: performSplice nil jsonpath → full overwrite fallback

/// CR-040: a structured file extension (.toml, .json, .yaml) with a nil jsonpath
/// in the fragment provenance must fall through to the full-overwrite path
/// (SpanSplicer.overwriteLua) instead of attempting relocation.
///
/// This verifies the guard clause:
///   guard let jsonpath = fragment.provenance.jsonpath else {
///     return .success(SpanSplicer.overwriteLua(editedText: editedText))
///   }
@Suite("CR-040 — performSplice structured extension + nil jsonpath → full overwrite")
struct PerformSpliceNilJsonpathTests {

    @Test(".toml extension with nil jsonpath produces full-overwrite outcome (.success)")
    func tomlExtensionNilJsonpathFullOverwrite() async throws {
        // Create a temp dir and a .toml file with any content.
        let dir = try WriteBackFixtures.tempDir()
        // Copy a .lua fixture and rename it to .toml so the file format
        // classification sees a structured extension.
        let luaURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let tomlURL = dir.appendingPathComponent("hello.toml")
        try FileManager.default.copyItem(at: luaURL, to: tomlURL)
        try FileManager.default.removeItem(at: luaURL)

        let data = try Data(contentsOf: tomlURL)
        // Build provenance with jsonpath == nil (whole-file, no JSONPath).
        let provenance = FragmentProvenance(
            file: tomlURL,
            jsonpath: nil,  // <-- the path under test
            document: 0,
            byteRange: 0..<data.count,
            lineOffset: 0,
            contentHash: SHA256.hash(data: data)
        )
        let fragment = LuaSourceFragment(code: "", provenance: provenance)
        let editedText = "return 42\n"

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: editedText,
            projectRoot: dir,
            lintService: MockLintService(),
            force: true
        )
        #expect(result.outcome == .success, "nil jsonpath on .toml must use full-overwrite path")
        #expect(result.newData == Data(editedText.utf8), "newData must equal editedText bytes")

        // Verify on-disk content matches.
        let onDisk = try Data(contentsOf: tomlURL)
        #expect(onDisk == Data(editedText.utf8))
    }

    @Test(".json extension with nil jsonpath produces full-overwrite outcome (.success)")
    func jsonExtensionNilJsonpathFullOverwrite() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let luaURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let jsonURL = dir.appendingPathComponent("hello.json")
        try FileManager.default.copyItem(at: luaURL, to: jsonURL)
        try FileManager.default.removeItem(at: luaURL)

        let data = try Data(contentsOf: jsonURL)
        let provenance = FragmentProvenance(
            file: jsonURL, jsonpath: nil, document: 0,
            byteRange: 0..<data.count, lineOffset: 0,
            contentHash: SHA256.hash(data: data)
        )
        let fragment = LuaSourceFragment(code: "", provenance: provenance)
        let editedText = "return 99\n"

        let result = await WriteBackCoordinator.write(
            fragment: fragment, editedText: editedText,
            projectRoot: dir, lintService: MockLintService(), force: true
        )
        #expect(result.outcome == .success)
        #expect(result.newData == Data(editedText.utf8))
    }
}
