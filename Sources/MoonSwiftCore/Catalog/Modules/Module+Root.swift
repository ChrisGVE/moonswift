// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Root.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for the root `luaswift` table. The root table is always
//       present; it acts as the namespace container and exposes the single
//       top-level helper `extend_stdlib`.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/ModuleRegistry.swift
//       (installExtendStdlib — defines luaswift.extend_stdlib).
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// The root `luaswift` table, always present.
    ///
    /// The empty `tableName` sentinel distinguishes this entry from named
    /// sub-modules. `luacheckGlobals` emits it as the `luaswift` key in the
    /// globals table.
    static let root = CatalogModule(
        tableName: "",
        functions: [
            // Imports all module extensions into the standard library tables
            // (string, math, table, utf8). Defined by ModuleRegistry.installExtendStdlib.
            CatalogFunction(name: "extend_stdlib"),
        ],
        availability: .base
    )
}
