// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Root.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for the root `luaswift` table. The root table is always
//       present; it acts as the namespace container and exposes the single
//       top-level helper `extend_stdlib`.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/ModuleRegistry.swift
//       (installExtendStdlib — defines luaswift.extend_stdlib).
//       Signatures sourced from ModuleRegistry.swift inline Lua code block and
//       the Swift doc comment on extend_stdlib.
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
            // Source: ModuleRegistry.swift — `luaswift.extend_stdlib = function() … end`
            CatalogFunction(
                name: "extend_stdlib",
                params: [],
                returns: nil,
                doc:
                    "Inject all luaswift extensions into the standard Lua libraries (string, math, table, utf8). Call once at startup to enable convenient shorthand access."
            )
        ],
        availability: .base
    )
}
