// File: Tests/MoonSwiftTUITests/Nvim/EditorFallbackRoundTripTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: End-to-end test of the $EDITOR fallback reopen loop
//       (spawnEditorFallbackAndWait) — the 4a acceptance round-trip: a syntax
//       error triggers a reopen with the normative comment block injected, and
//       the user's edits are preserved across the reopen (block prepended, not
//       substituted). Drives the real production loop through the injectable
//       editor-runner seam, so no $EDITOR binary or TTY is required.
//       (REQUIREMENTS §F8 acceptance 4a, ARCHITECTURE §10.3e; P4 audit gap #5.)
//       The write-back outcome itself is covered by WriteBackIntegrationTests.

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// A stand-in for the editor step: at each "open" it records the file content it
/// is handed (what the loop wrote/injected), then writes the next scripted
/// payload to simulate the user editing the buffer.
private final class FakeEditorRunner: @unchecked Sendable {
    private(set) var observedContents: [String] = []
    private var writes: [String]
    init(writes: [String]) { self.writes = writes }

    func run(_ url: URL) {
        observedContents.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        if !writes.isEmpty {
            let next = writes.removeFirst()
            try? next.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private func projectState(root: URL) -> AppState {
    var s = AppState()
    s.launch = .project(root)
    s.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return s
}

private func makeDriver(seed: AppState, lint: MockLintService) -> AppDriver {
    let channel = EventChannel()
    let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
    let tick = TickSource(channel: channel)
    return AppDriver(
        channel: channel,
        pump: pump,
        tickSource: tick,
        suspender: RecordingTerminalSuspender(),
        seed: seed,
        lintService: lint
    )
}

// MARK: - Suite

@Suite("EditorFallback — 4a reopen round-trip")
struct EditorFallbackRoundTripTests {

    @Test("a syntax error reopens the editor with the comment block prepended to the preserved edit")
    func reopenInjectsCommentAndPreservesEdit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("script.lua")
        try "return 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        // Whole-.lua fragment: the loop edits the source file directly.
        let provenance = FragmentProvenance(
            file: fileURL, jsonpath: nil, document: 0,
            byteRange: 0..<8, lineOffset: 0,
            contentHash: SHA256.hash(data: Data("return 1\n".utf8)))
        let fragment = LuaSourceFragment(code: "return 1\n", provenance: provenance)

        // The user introduces a broken edit, then fixes it on the reopen.
        let broken = "this is BROKEN lua (((\n"
        let fixed = "return 42\n"
        let fake = FakeEditorRunner(writes: [broken, fixed])

        // Content-aware pre-pass: broken code → diagnostic, fixed code → clean.
        let lint = MockLintService(prePass: { frag in
            frag.code.contains("BROKEN")
                ? Diagnostic(severity: .error, line: 1, message: "syntax error", source: .syntaxPrePass)
                : nil
        })

        let driver = makeDriver(seed: projectState(root: root), lint: lint)
        driver.spawnEditorFallbackAndWait(fragment: fragment, runEditor: { fake.run($0) })

        // The loop reopened exactly once after the error (open #1 = broken edit,
        // open #2 = after comment injection; the fixed edit ends the loop).
        #expect(fake.observedContents.count == 2)

        // On the reopen, the file the user saw carried the normative comment block
        // prepended to their broken edit — the edit is preserved, not replaced.
        let reopened = try #require(fake.observedContents.last)
        #expect(reopened.hasPrefix("-- SYNTAX ERROR: syntax error (line 1)"))
        #expect(reopened.contains("Delete this block to force-accept."))
        #expect(reopened.contains("this is BROKEN lua ((("))

        _ = fixed  // the fixed payload ends the loop; write-back covered elsewhere
    }

    @Test("a clean first edit ends the loop with no reopen")
    func cleanEditNoReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("script.lua")
        try "return 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let provenance = FragmentProvenance(
            file: fileURL, jsonpath: nil, document: 0,
            byteRange: 0..<8, lineOffset: 0,
            contentHash: SHA256.hash(data: Data("return 1\n".utf8)))
        let fragment = LuaSourceFragment(code: "return 1\n", provenance: provenance)

        let fake = FakeEditorRunner(writes: ["return 7\n"])
        let lint = MockLintService(prePass: { _ in nil })  // always clean

        let driver = makeDriver(seed: projectState(root: root), lint: lint)
        driver.spawnEditorFallbackAndWait(fragment: fragment, runEditor: { fake.run($0) })

        // No syntax error → the editor opened once and the loop exited.
        #expect(fake.observedContents.count == 1)
    }
}
