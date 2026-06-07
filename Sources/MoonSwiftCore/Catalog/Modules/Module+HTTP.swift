// File: Sources/MoonSwiftCore/Catalog/Modules/Module+HTTP.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.http — HTTP client (GET, POST, PUT, PATCH,
//       DELETE, HEAD, OPTIONS, and the generic request function).
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/HTTPModule.swift
//       (Lua run block: luaswift.http = { get, post, put, patch, delete, head,
//        options, request }).
//
//       Availability: .optIn — network access must be explicitly requested by the
//       user via `lint.extra_modules = ["http"]` in moonswift.toml.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.http` — HTTP client methods.
    static let http = CatalogModule(
        tableName: "http",
        functions: [
            CatalogFunction(name: "get"),
            CatalogFunction(name: "post"),
            CatalogFunction(name: "put"),
            CatalogFunction(name: "patch"),
            CatalogFunction(name: "delete"),
            CatalogFunction(name: "head"),
            CatalogFunction(name: "options"),
            // Generic request; all method functions are thin wrappers around this.
            CatalogFunction(name: "request"),
        ],
        availability: .optIn
    )
}
