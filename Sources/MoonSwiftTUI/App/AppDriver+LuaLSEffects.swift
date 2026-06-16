// File: Sources/MoonSwiftTUI/App/AppDriver+LuaLSEffects.swift
// Location: MoonSwiftTUI/App/
// Role: P3 F7b — the AppDriver's side-effectful lua-language-server handlers. The
//       reducer emits `Effect.spawnLuaLS` (on project load) and `Effect.lualsSync`
//       (alongside each `.lint`) and never touches the client directly. This
//       extension owns the long-lived `LuaLSClient`: it (re)spawns one per project
//       load and forwards document text to it, posting results back as
//       `AppEvent.lualsDiagnostics` / `.lualsUnavailable`. No-op in skeleton/test
//       mode (no client factory injected), matching the other optional services.
//
// Upstream: AppDriver (channel, lualsClient, makeLuaLSClient), MoonSwiftCore
//           (LuaModuleCatalog, ProjectStore)
// Downstream: Reducer (lualsDiagnostics / lualsUnavailable transitions)

import Foundation
import MoonSwiftCore

extension AppDriver {

    /// (Re)spawn lua-language-server for the loaded project (F7b).
    ///
    /// Skeleton/test mode (no `makeLuaLSClient`) is a no-op. Only `.project`
    /// launches spawn a server — `.quickFile`/`.empty` have no `moonswift.toml`
    /// to hash for the cache, so they fall back to the native F7a catalog.
    /// Any prior client is torn down before the new one starts.
    func executeSpawnLuaLS() {
        guard let makeLuaLSClient else { return }
        guard case .project(let dir) = state.launch else { return }

        let tomlPath = dir.appendingPathComponent(ProjectStore.fileName)
        let metaFiles = LuaModuleCatalog.v0.luaLSMetaFiles()
        let previous = lualsClient
        let client = makeLuaLSClient()
        lualsClient = client

        Task { [channel] in
            if let previous { await previous.teardown() }
            await client.start(
                tomlPath: tomlPath,
                metaFiles: metaFiles,
                onDiagnostics: { channel.post(.lualsDiagnostics($0)) },
                onUnavailable: { channel.post(.lualsUnavailable) }
            )
        }
    }

    /// Forward `fragment`'s current text to the running server (F7b). No-op when
    /// no client is live (binary absent, or spawn still in flight).
    func executeLualsSync(_ fragment: LuaSourceFragment) {
        guard let client = lualsClient else { return }
        Task { await client.sync(fragment: fragment) }
    }
}
