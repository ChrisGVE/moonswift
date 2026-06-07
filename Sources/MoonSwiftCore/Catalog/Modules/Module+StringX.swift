// File: Sources/MoonSwiftCore/Catalog/Modules/Module+StringX.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.stringx — Swift-backed string utilities:
//       strip/split/join, padding, character classification, and import().
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/StringXModule.swift
//       (Lua run block: luaswift.stringx = { ... }). Backward-compat aliases
//       (isalpha, isdigit, …) are included because luacheck must accept them
//       as valid accesses on the module table even though the is_<name> forms
//       are preferred.
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.stringx` — extended string functions (also aliased as `stringx`
    /// via `luaswift.extend_stdlib`).
    static let stringx = CatalogModule(
        tableName: "stringx",
        functions: [
            // Whitespace stripping
            CatalogFunction(name: "strip"),
            CatalogFunction(name: "lstrip"),
            CatalogFunction(name: "rstrip"),
            // Splitting and joining
            CatalogFunction(name: "split"),
            CatalogFunction(name: "replace"),
            CatalogFunction(name: "join"),
            // Predicates
            CatalogFunction(name: "startswith"),
            CatalogFunction(name: "endswith"),
            CatalogFunction(name: "contains"),
            CatalogFunction(name: "count"),
            // Case transforms
            CatalogFunction(name: "capitalize"),
            CatalogFunction(name: "title"),
            // Padding and centering
            CatalogFunction(name: "lpad"),
            CatalogFunction(name: "rpad"),
            CatalogFunction(name: "center"),
            // Character-class predicates (canonical is_<name> convention)
            CatalogFunction(name: "is_alpha"),
            CatalogFunction(name: "is_digit"),
            CatalogFunction(name: "is_alnum"),
            CatalogFunction(name: "is_space"),
            CatalogFunction(name: "is_upper"),
            CatalogFunction(name: "is_lower"),
            CatalogFunction(name: "is_empty"),
            CatalogFunction(name: "is_blank"),
            // Backward-compatibility aliases (deprecated; prefer is_<name> forms)
            CatalogFunction(name: "isalpha"),
            CatalogFunction(name: "isdigit"),
            CatalogFunction(name: "isalnum"),
            CatalogFunction(name: "isspace"),
            CatalogFunction(name: "isupper"),
            CatalogFunction(name: "islower"),
            CatalogFunction(name: "isempty"),
            CatalogFunction(name: "isblank"),
            // Multi-line and wrapping
            CatalogFunction(name: "splitlines"),
            CatalogFunction(name: "wrap"),
            CatalogFunction(name: "truncate"),
            CatalogFunction(name: "slice"),
            // Stdlib injection helper
            CatalogFunction(name: "import"),
        ],
        availability: .base
    )
}
