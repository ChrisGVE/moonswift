// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Regex.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.regex — Swift Regex compile/match wrapper.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/RegexModule.swift
//       (Lua run block: luaswift.regex = { compile, match }). The compiled regex
//       object methods (match, find_all, test, replace, replace_all, split) live
//       on the returned object's metatable, not on the module table itself — they
//       are excluded here because luacheck globals describes the module table.
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.regex` — compile a pattern, or quick-match without compiling.
    static let regex = CatalogModule(
        tableName: "regex",
        functions: [
            // Returns a compiled regex object with :match, :find_all, :test,
            // :replace, :replace_all, :split methods on its metatable.
            CatalogFunction(name: "compile"),
            // Quick one-shot match without returning a compiled object.
            CatalogFunction(name: "match"),
        ],
        availability: .base
    )
}
