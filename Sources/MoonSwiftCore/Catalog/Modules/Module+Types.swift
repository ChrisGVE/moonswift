// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Types.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.types — runtime type detection and
//       conversion helpers for LuaSwift's extended type system.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/TypesModule.swift
//       (typesLuaCode constant: function types.typeof, is, is_luaswift, is_callable,
//        is_iterable, is_numeric, is_vector, is_matrix, is_geometry, to_array,
//        to_vec2, to_vec3, to_complex, to_vector, to_matrix, clone, all_types).
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.types` — type detection and conversion (also aliased as `types` global).
    static let types = CatalogModule(
        tableName: "types",
        functions: [
            // Type querying
            CatalogFunction(name: "typeof"),
            CatalogFunction(name: "is"),
            CatalogFunction(name: "is_luaswift"),
            CatalogFunction(name: "is_callable"),
            CatalogFunction(name: "is_iterable"),
            CatalogFunction(name: "is_numeric"),
            CatalogFunction(name: "is_vector"),
            CatalogFunction(name: "is_matrix"),
            CatalogFunction(name: "is_geometry"),
            // Type conversion
            CatalogFunction(name: "to_array"),
            CatalogFunction(name: "to_vec2"),
            CatalogFunction(name: "to_vec3"),
            CatalogFunction(name: "to_complex"),
            CatalogFunction(name: "to_vector"),
            CatalogFunction(name: "to_matrix"),
            // Utilities
            CatalogFunction(name: "clone"),
            CatalogFunction(name: "all_types"),
        ],
        availability: .base
    )
}
