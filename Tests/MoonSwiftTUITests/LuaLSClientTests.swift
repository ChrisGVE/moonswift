// File: Tests/MoonSwiftTUITests/LuaLSClientTests.swift
// Role: Lifecycle tests for the optional lua-language-server client (F7b):
//       silent degradation when the binary is absent, and — gated on a real
//       lua-language-server being installed — end-to-end diagnostics flow,
//       meta-file generation, idempotent teardown, and cancelproof process
//       termination.
// Upstream: MoonSwiftTUI/LuaLS/{LuaLSClient,LuaLSProcess,LuaLSCache}.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import Testing

@testable import MoonSwiftTUI

// MARK: - Installed-binary detection

/// The lua-language-server executable on PATH, or `nil` when not installed.
private func installedLuaLSPath() -> String? {
    let fm = FileManager.default
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/lua-language-server"
        if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    // Common Homebrew location even when PATH is trimmed in the test runner.
    let brew = "/usr/local/bin/lua-language-server"
    return fm.isExecutableFile(atPath: brew) ? brew : nil
}

private var luaLSInstalled: Bool { installedLuaLSPath() != nil }

// MARK: - Diagnostics collector

/// Thread-safe sink for the client's `@Sendable` callbacks.
private actor Collector {
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var unavailable = false
    func add(_ d: [Diagnostic]) { diagnostics.append(contentsOf: d) }
    func markUnavailable() { unavailable = true }
}

// MARK: - Fixtures

/// A `LuaSourceFragment` carrying `code`, with provenance rooted at a temp file.
private func makeFragment(code: String) -> LuaSourceFragment {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("luals-frag-\(UUID().uuidString).lua")
    let data = Data(code.utf8)
    let prov = FragmentProvenance(
        file: file,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: prov)
}

/// A temp `moonswift.toml` path (content irrelevant — only the path is hashed).
private func makeTempToml() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("luals-proj-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let toml = dir.appendingPathComponent("moonswift.toml")
    try "lua_version = \"5.4\"\n".write(to: toml, atomically: true, encoding: .utf8)
    return toml
}

@Suite("LuaLSClient")
struct LuaLSClientTests {

    // MARK: Absent (no `.enabled(if:)` — must run everywhere)

    @Test("Absent binary degrades silently to F7a")
    func absentBinaryDegrades() async throws {
        let toml = try makeTempToml()
        defer { try? FileManager.default.removeItem(at: toml.deletingLastPathComponent()) }

        let collector = Collector()
        let client = LuaLSClient(executablePath: "/nonexistent/lua-language-server")
        await client.start(
            tomlPath: toml,
            metaFiles: LuaModuleCatalog.v0.luaLSMetaFiles(),
            onDiagnostics: { d in Task { await collector.add(d) } },
            onUnavailable: { Task { await collector.markUnavailable() } }
        )
        // Allow the onUnavailable Task to settle.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await collector.unavailable)
        #expect(await collector.diagnostics.isEmpty)
        await client.teardown()  // teardown on an inert client is a safe no-op
    }

    // MARK: Present (gated on a real install)

    @Test("Present binary produces .luals diagnostics + meta files", .enabled(if: luaLSInstalled))
    func presentBinaryDiagnostics() async throws {
        let toml = try makeTempToml()
        defer { try? FileManager.default.removeItem(at: toml.deletingLastPathComponent()) }
        let cacheDir = LuaLSCache.cacheRoot()
            .appendingPathComponent(LuaLSCache.projectHash(forToml: toml))
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let collector = Collector()
        let client = LuaLSClient(executablePath: installedLuaLSPath())
        await client.start(
            tomlPath: toml,
            metaFiles: LuaModuleCatalog.v0.luaLSMetaFiles(),
            onDiagnostics: { d in Task { await collector.add(d) } },
            onUnavailable: { Task { await collector.markUnavailable() } }
        )

        // Meta files were generated into the cache dir.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: cacheDir.appendingPathComponent(".luarc.json").path))
        let metaContents = try fm.contentsOfDirectory(
            atPath: cacheDir.appendingPathComponent("meta").path)
        #expect(!metaContents.isEmpty)

        // An undefined global must surface as a .luals diagnostic.
        await client.sync(fragment: makeFragment(code: "print(undefinedGlobalXyz)\n"))

        var found: [Diagnostic] = []
        for _ in 0..<200 {  // up to ~20s for cold start + analysis
            found = await collector.diagnostics.filter { $0.source == .luals }
            if !found.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!found.isEmpty)
        // Position mapping: LSP 0-based line 0 → MoonSwift 1-based line 1.
        if let first = found.first {
            #expect(first.line == 1)
            #expect(first.source == .luals)
        }

        await client.teardown()
        await client.teardown()  // idempotent — second call is a no-op
        #expect(await collector.unavailable == false)
    }

    // MARK: Cancelproof transport (gated on a real install)

    @Test("Transport teardown signals the child and is idempotent", .enabled(if: luaLSInstalled))
    func transportTeardownSignalsChild() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("luals-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let proc = try LuaLSProcess.spawn(
            executablePath: installedLuaLSPath()!,
            workspace: workspace,
            environment: LuaLSEnvironment.childEnvironment(),
            onExit: { _ in }
        )
        #expect(proc.isRunning)

        proc.terminate()
        proc.terminate()  // idempotent — no double-SIGTERM crash

        // The child must stop running shortly after SIGTERM.
        var stopped = false
        for _ in 0..<50 {
            if !proc.isRunning {
                stopped = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(stopped)
    }

    @Test("Non-executable path is rejected by the transport")
    func transportRejectsNonExecutable() {
        #expect(throws: LuaLSProcessError.self) {
            _ = try LuaLSProcess.spawn(
                executablePath: "/nonexistent/lua-language-server",
                workspace: FileManager.default.temporaryDirectory,
                environment: [:],
                onExit: { _ in }
            )
        }
    }
}
