// File: Sources/MoonSwiftCore/Catalog/Modules/Module+UI.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.ui — native UI dialogs (alert, confirm).
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/UIModule.swift
//       (Lua run block: luaswift.ui = { alert, confirm }).
//       Signatures sourced from UIModule.swift alertCallback/confirmCallback and
//       the module-level doc comment describing button roles and return value.
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
            // Source: UIModule.swift alertCallback — parseDialogArgs(args, funcName: "ui.alert")
            // args: title (string), message (string), buttons? (table of string|{text,role})
            // Returns 1-indexed button position pressed.
            CatalogFunction(
                name: "alert",
                params: [
                    CatalogParam(name: "title", type: "string"),
                    CatalogParam(name: "message", type: "string"),
                    CatalogParam(name: "buttons", type: "table", isOptional: true),
                ],
                returns: "number",
                doc:
                    "Show a native alert dialog with title and message. Optional buttons is an array of strings or {text, role} tables (role: \"destructive\"|\"cancel\"). Returns the 1-indexed position of the button pressed. Blocks until the user responds."
            ),
            // Source: UIModule.swift confirmCallback — same signature as alert
            // Displayed as action sheet style on iOS, same as alert on macOS.
            CatalogFunction(
                name: "confirm",
                params: [
                    CatalogParam(name: "title", type: "string"),
                    CatalogParam(name: "message", type: "string"),
                    CatalogParam(name: "buttons", type: "table", isOptional: true),
                ],
                returns: "number",
                doc:
                    "Show a native confirmation dialog (action-sheet style on iOS, same as alert on macOS). Returns the 1-indexed position of the button pressed. Blocks until the user responds."
            ),
        ],
        availability: .optIn
    )
}
