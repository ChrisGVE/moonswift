// File: Sources/MoonSwiftCore/Catalog/Modules/Module+JSON.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.json — JSON encode/decode with JSONC and
//       JSON5 variants, plus the null-sentinel helpers.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/JSONModule.swift
//       (install method, Lua run block: luaswift.json = { encode, decode,
//        decode_jsonc, decode_json5, null } + function luaswift.json.is_null).
//
//       Availability: .base — always installed (unconditional in ModuleRegistry).
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.json` — JSON encode, decode, JSONC, JSON5, null sentinel.
    static let json = CatalogModule(
        tableName: "json",
        functions: [
            CatalogFunction(name: "encode"),
            CatalogFunction(name: "decode"),
            CatalogFunction(name: "decode_jsonc"),
            CatalogFunction(name: "decode_json5"),
            // is_null is a function; null is a sentinel value (table), not a function.
            // For luacheck globals we list it as a field so it is known to the linter.
            CatalogFunction(name: "is_null"),
        ],
        availability: .base
    )
}
