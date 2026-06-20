// File: Sources/MoonSwiftCore/Catalog/CatalogConsumers+Meta.swift
// Folder: Sources/MoonSwiftCore/Catalog/
// Role: The catalog's LuaLS meta-file consumer (F7b) — the third consumer beside
//       luacheckGlobals (F4) and completionItems (F7a). Implements
//       `luaLSMetaFiles()`, replacing the P1 stub, by delegating to the pure
//       MetaFileGenerator. Returns one `---@meta` file per module plus a
//       `.luarc.json`; the TUI LuaLSClient writes them into the per-project
//       cache dir (PRD §F7b).
//
// Upstream: LuaModuleCatalog (modules), MetaFileGenerator (pure builders)
// Downstream: LuaLSClient (TUI — writes the files, spawns LuaLS)

import Foundation

extension LuaModuleCatalog {

    /// Generate the LuaLS project files describing the `luaswift.*` namespace:
    /// one `---@meta` file per catalog module followed by a `.luarc.json` that
    /// lists the meta directory under `workspace.library` and pins
    /// `runtime.version` to the active Lua version.
    ///
    /// All catalog modules are described (the runtime probe gates actual
    /// availability; the meta surface mirrors what completions offer). The result
    /// is deterministic for a given catalog, so a stable hash of it backs the
    /// meta-version sentinel that triggers regeneration on catalog changes.
    public func luaLSMetaFiles() -> [GeneratedFile] {
        var files = modules.map(MetaFileGenerator.metaFile(for:))
        files.append(MetaFileGenerator.luarcJSON())
        return files
    }
}
