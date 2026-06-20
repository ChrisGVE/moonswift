// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Regex.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.regex — Swift Regex compile/match wrapper.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/RegexModule.swift
//       (Lua run block: luaswift.regex = { compile, match }). The compiled regex
//       object methods (match, find_all, test, replace, replace_all, split) live
//       on the returned object's metatable, not on the module table itself — they
//       are excluded here because luacheck globals describes the module table.
//       Signatures sourced from RegexModule.swift module-level doc comment and
//       callback implementations.
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
            // Source: RegexModule.swift compileCallback — args[0]=pattern, args[1]=flags?
            // Returns a compiled regex object with :match, :find_all, :test,
            // :replace, :replace_all, :split methods on its metatable.
            CatalogFunction(
                name: "compile",
                params: [
                    CatalogParam(name: "pattern", type: "string"),
                    CatalogParam(name: "flags", type: "string", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Compile a regex pattern (ICU syntax) and return a compiled regex object. Optional flags string (e.g. \"i\" for case-insensitive). The returned object has :match, :find_all, :test, :replace, :replace_all, and :split methods."
            ),
            // Source: RegexModule.swift quickMatchCallback — args[0]=text, args[1]=pattern
            // Quick one-shot match without returning a compiled object.
            CatalogFunction(
                name: "match",
                params: [
                    CatalogParam(name: "text", type: "string"),
                    CatalogParam(name: "pattern", type: "string"),
                ],
                returns: "table|nil",
                doc:
                    "One-shot match of pattern against text without compiling. Returns a match table {start, stop, text, groups} or nil if no match."
            ),
        ],
        availability: .base
    )
}
