// File: Sources/MoonSwiftTUI/LuaLS/LuaLSClient.swift
// Folder: Sources/MoonSwiftTUI/LuaLS/
// Role: The optional lua-language-server integration (F7b). An actor that, when
//       the binary is on PATH, generates the catalog meta files into a per-project
//       cache, spawns lua-language-server as a stdio LSP child pointed at that
//       cache, opens the active fragment as an in-memory document, and forwards
//       the server's published diagnostics (mapped to MoonSwift `Diagnostic`s)
//       back to the caller. When the binary is absent — or the child dies
//       mid-session — it degrades silently to the native F7a catalog: the caller
//       is told once via `onUnavailable`, and every later call is a safe no-op.
//
//   Concurrency: actor isolation serialises spawn / sync / teardown, so the
//   long-lived child and its document-version table never race. The diagnostics
//   callback is `@Sendable` and is invoked from the listen task.
//
// Upstream: LuaLSCache (meta files), LuaLSProcess (transport), ChimeHQ
//           LanguageClient (InitializingServer), LuaLSDiagnosticMapper
// Downstream: AppDriver spawn/sync/teardown effects → AppEvent.lualsDiagnostics
//             / .lualsUnavailable

import CryptoKit
import Foundation
import LanguageClient
import LanguageServerProtocol
import MoonSwiftCore

// `Diagnostic` is declared in both MoonSwiftCore and LanguageServerProtocol; the
// client deals in MoonSwift's, so its uses below are module-qualified.

/// Long-lived owner of the lua-language-server child for one project.
public actor LuaLSClient {

    /// The binary name searched for on `PATH` when no explicit path is given.
    public static let executableName = "lua-language-server"

    /// An explicit executable path, or `nil` to resolve `executableName` on PATH.
    /// Tests inject a path (real binary) or a bogus one (absent-path coverage).
    private let executableOverride: String?

    private var process: LuaLSProcess?
    private var server: InitializingServer?
    private var listenTask: Task<Void, Never>?
    private var workspaceDir: URL?

    /// Open document URIs mapped to their last LSP version (didOpen → 1, then
    /// monotonically increasing didChange versions).
    private var documentVersions: [String: Int] = [:]

    public init(executablePath: String? = nil) {
        self.executableOverride = executablePath
    }

    // MARK: - Lifecycle

    /// Resolve, prepare, and spawn the server for the project whose config is
    /// `tomlPath`, generating `metaFiles` into the cache first.
    ///
    /// Degrades silently when the binary is absent or the spawn fails: calls
    /// `onUnavailable` (once, by the caller's contract) and leaves the client
    /// inert. On success, published diagnostics flow to `onDiagnostics`.
    public func start(
        tomlPath: URL,
        metaFiles: [GeneratedFile],
        onDiagnostics: @Sendable @escaping ([MoonSwiftCore.Diagnostic]) -> Void,
        onUnavailable: @Sendable @escaping () -> Void
    ) async {
        guard let executablePath = resolveExecutable() else {
            onUnavailable()
            return
        }

        // Best-effort housekeeping: drop long-orphaned caches before adding ours.
        // Done only when LuaLS is actually present, so an absent binary touches
        // no filesystem state.
        LuaLSCache.evictStale(now: Date())

        let dir: URL
        do {
            dir = try LuaLSCache.prepare(metaFiles: metaFiles, tomlPath: tomlPath)
        } catch {
            // A cache-write failure is not a "not found" condition — log and
            // degrade silently without the misleading status note.
            Logger.shared.error("LuaLS cache preparation failed: \(error)")
            return
        }

        let proc: LuaLSProcess
        do {
            proc = try LuaLSProcess.spawn(
                executablePath: executablePath,
                workspace: dir,
                environment: LuaLSEnvironment.childEnvironment(),
                onExit: { status in
                    Logger.shared.info("lua-language-server exited with status \(status)")
                }
            )
        } catch {
            Logger.shared.info("lua-language-server spawn failed: \(error) — using native catalog")
            onUnavailable()
            return
        }

        let connection = JSONRPCServerConnection(dataChannel: proc.dataChannel)
        let initializing = InitializingServer(
            server: connection,
            initializeParamsProvider: { Self.initializeParams(rootUri: dir) }
        )

        self.process = proc
        self.server = initializing
        self.workspaceDir = dir
        self.documentVersions = [:]
        startListening(initializing, onDiagnostics: onDiagnostics)

        // Kick the initialize handshake so diagnostics flow without waiting for
        // the first document notification.
        _ = try? await initializing.initializeIfNeeded()
    }

    /// Push the current text of `fragment` to the server as a full-document
    /// sync (didOpen the first time, didChange thereafter). No-op when inert.
    public func sync(fragment: LuaSourceFragment) async {
        guard let server, let workspaceDir else { return }
        let uri = Self.documentURI(for: fragment, in: workspaceDir)
        let text = fragment.code

        do {
            if let previous = documentVersions[uri] {
                let version = previous + 1
                try await server.sendNotification(
                    .textDocumentDidChange(
                        DidChangeTextDocumentParams(
                            uri: uri,
                            version: version,
                            contentChange: TextDocumentContentChangeEvent(
                                range: nil, rangeLength: nil, text: text))))
                documentVersions[uri] = version
            } else {
                try await server.sendNotification(
                    .textDocumentDidOpen(
                        DidOpenTextDocumentParams(
                            textDocument: TextDocumentItem(
                                uri: uri, languageId: .lua, version: 1, text: text))))
                documentVersions[uri] = 1
            }
        } catch {
            // A write failure means the child has gone — degrade to F7a quietly.
            Logger.shared.info("LuaLS document sync failed: \(error)")
        }
    }

    /// Terminate the server and release all resources. Idempotent.
    public func teardown() async {
        listenTask?.cancel()
        listenTask = nil
        if let server {
            try? await server.shutdownAndExit()
        }
        process?.terminate()
        process = nil
        server = nil
        workspaceDir = nil
        documentVersions = [:]
    }

    // MARK: - Listening

    /// Spawn the task that forwards published diagnostics to `onDiagnostics`.
    private func startListening(
        _ server: InitializingServer,
        onDiagnostics: @Sendable @escaping ([MoonSwiftCore.Diagnostic]) -> Void
    ) {
        listenTask = Task {
            for await event in server.eventSequence {
                guard case .notification(let notification) = event,
                    case .textDocumentPublishDiagnostics(let params) = notification
                else { continue }
                onDiagnostics(LuaLSDiagnosticMapper.map(params))
            }
        }
    }

    // MARK: - Helpers

    /// The executable path: the injected override, else the first `PATH` entry
    /// that holds an executable `lua-language-server`, else `nil` (absent).
    private func resolveExecutable() -> String? {
        if let executableOverride {
            return FileManager.default.isExecutableFile(atPath: executableOverride)
                ? executableOverride : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(Self.executableName)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Minimal LSP `InitializeParams` with the cache dir as the workspace root,
    /// so the server reads its `.luarc.json` (runtime.version, library, globals).
    private static func initializeParams(rootUri dir: URL) -> InitializeParams {
        InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: .init(name: "MoonSwift"),
            locale: nil,
            rootPath: dir.path,
            rootUri: dir.absoluteString,
            initializationOptions: nil,
            capabilities: ClientCapabilities(
                workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil),
            trace: nil,
            workspaceFolders: nil
        )
    }

    /// A stable `file://` URI inside the workspace for `fragment`, keyed by its
    /// provenance so didOpen/didChange versions line up across edits. The `.lua`
    /// extension makes the server treat the in-memory text as Lua.
    static func documentURI(for fragment: LuaSourceFragment, in workspace: URL) -> String {
        let prov = fragment.provenance
        let key = "\(prov.file.path)#\(prov.document)#\(prov.jsonpath ?? "")"
        let hash = SHA256.hash(data: Data(key.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return workspace.appendingPathComponent("doc-\(hash).lua").absoluteString
    }
}
