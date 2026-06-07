// File: Sources/MoonSwiftCore/Catalog/Modules/Module+UI.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.ui — native UI dialogs (alert, confirm).
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/UIModule.swift
//       (Lua run block: luaswift.ui = { alert, confirm }).
//
//       Availability: .optIn — UI dialogs interrupt the script runner and must
//       be explicitly requested via `lint.extra_modules = ["ui"]` in
//       moonswift.toml.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.ui` — native macOS UI dialogs.
    static let ui = CatalogModule(
        tableName: "ui",
        functions: [
            // Shows an alert sheet with optional action buttons; returns the chosen action.
            CatalogFunction(name: "alert"),
            // Shows a boolean confirmation dialog; returns true/false.
            CatalogFunction(name: "confirm"),
        ],
        availability: .optIn
    )
}
