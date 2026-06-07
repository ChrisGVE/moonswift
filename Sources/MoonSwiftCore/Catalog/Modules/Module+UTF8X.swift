// File: Sources/MoonSwiftCore/Catalog/Modules/Module+UTF8X.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.utf8x — Unicode-aware string operations
//       that correctly handle multi-byte codepoints.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/UTF8XModule.swift
//       (Lua run block: luaswift.utf8x = { width, sub, reverse, upper, lower,
//        len, chars, slice, import }).
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.utf8x` — Unicode-aware string utilities (also aliased as `utf8x` global).
    static let utf8x = CatalogModule(
        tableName: "utf8x",
        functions: [
            // Display width (accounts for wide CJK characters)
            CatalogFunction(name: "width"),
            // Substring by codepoint index
            CatalogFunction(name: "sub"),
            // Reverse codepoint sequence
            CatalogFunction(name: "reverse"),
            // Case transforms
            CatalogFunction(name: "upper"),
            CatalogFunction(name: "lower"),
            // Length in codepoints
            CatalogFunction(name: "len"),
            // Iterate codepoints
            CatalogFunction(name: "chars"),
            // Slice by codepoint range
            CatalogFunction(name: "slice"),
            // Injects functions into the standard utf8 library
            CatalogFunction(name: "import"),
        ],
        availability: .base
    )
}
