// File: Sources/MoonSwiftCore/Catalog/Modules/Module+IOx.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.iox — file system and path utilities,
//       opt-in because sandboxed projects should not have file access by default.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/IOModule.swift
//       (Lua run block: luaswift.iox = { read_file, write_file, append_file,
//        exists, is_file, is_dir, list_dir, mkdir, remove, rename, stat,
//        path = { join, basename, dirname, extension, absolute, normalize } }).
//
//       The `path` sub-table functions are catalogued with the `path.` prefix
//       so consumers know they live inside the nested table.
//
//       Availability: .optIn — the user must declare `iox` in
//       `lint.extra_modules` in moonswift.toml.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.iox` — file system access and path utilities.
    static let iox = CatalogModule(
        tableName: "iox",
        functions: [
            // File operations
            CatalogFunction(name: "read_file"),
            CatalogFunction(name: "write_file"),
            CatalogFunction(name: "append_file"),
            CatalogFunction(name: "exists"),
            CatalogFunction(name: "is_file"),
            CatalogFunction(name: "is_dir"),
            CatalogFunction(name: "list_dir"),
            CatalogFunction(name: "mkdir"),
            CatalogFunction(name: "remove"),
            CatalogFunction(name: "rename"),
            CatalogFunction(name: "stat"),
            // Path sub-table entries (iox.path.<name>)
            CatalogFunction(name: "path.join"),
            CatalogFunction(name: "path.basename"),
            CatalogFunction(name: "path.dirname"),
            CatalogFunction(name: "path.extension"),
            CatalogFunction(name: "path.absolute"),
            CatalogFunction(name: "path.normalize"),
        ],
        availability: .optIn
    )
}
