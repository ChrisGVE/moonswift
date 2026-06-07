// File: Sources/MoonSwiftCore/Catalog/Modules/Module+YAML.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.yaml — YAML encode/decode including
//       multi-document streams.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/YAMLModule.swift
//       (Lua run block: luaswift.yaml = { encode, decode, encode_all, decode_all }).
//       The YAML module is gated on LUASWIFT_YAMS in ModuleRegistry but is
//       unconditionally bundled in MoonSwift's LuaSwift dependency (Yams is a
//       direct MoonSwift dependency). Classified .base for the MoonSwift runtime.
//
//       Availability: .base — Yams is always present in MoonSwift builds.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.yaml` — YAML encode, decode, multi-document streams.
    static let yaml = CatalogModule(
        tableName: "yaml",
        functions: [
            CatalogFunction(name: "encode"),
            CatalogFunction(name: "decode"),
            CatalogFunction(name: "encode_all"),
            CatalogFunction(name: "decode_all"),
        ],
        availability: .base
    )
}
