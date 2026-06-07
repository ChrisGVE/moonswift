// File: Sources/MoonSwiftCore/Catalog/Modules/Module+TableX.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.tablex — Swift-backed table utilities
//       (deep copy/merge/flatten, keys/values/invert) plus pure-Lua extensions
//       (map, filter, reduce, set operations, chain, …).
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/TableXModule.swift
//       (Swift-registered: deepcopy, deepmerge, flatten, keys, values, invert;
//        Lua-defined: copy, map, filter, reduce, foreach, find, contains, size,
//        isempty, isarray, slice, reverse, unique, sort, union, intersection,
//        difference, equals, deepequals, collect, dict_from, set_from, chain,
//        import).
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.tablex` — extended table utilities.
    static let tablex = CatalogModule(
        tableName: "tablex",
        functions: [
            // Swift-backed (registered via registerFunction)
            CatalogFunction(name: "deepcopy"),
            CatalogFunction(name: "deepmerge"),
            CatalogFunction(name: "flatten"),
            CatalogFunction(name: "keys"),
            CatalogFunction(name: "values"),
            CatalogFunction(name: "invert"),
            // Lua-defined (injected by the Lua run block)
            CatalogFunction(name: "copy"),
            CatalogFunction(name: "map"),
            CatalogFunction(name: "filter"),
            CatalogFunction(name: "reduce"),
            CatalogFunction(name: "foreach"),
            CatalogFunction(name: "find"),
            CatalogFunction(name: "contains"),
            CatalogFunction(name: "size"),
            CatalogFunction(name: "isempty"),
            CatalogFunction(name: "isarray"),
            CatalogFunction(name: "slice"),
            CatalogFunction(name: "reverse"),
            CatalogFunction(name: "unique"),
            CatalogFunction(name: "sort"),
            CatalogFunction(name: "union"),
            CatalogFunction(name: "intersection"),
            CatalogFunction(name: "difference"),
            CatalogFunction(name: "equals"),
            CatalogFunction(name: "deepequals"),
            CatalogFunction(name: "collect"),
            CatalogFunction(name: "dict_from"),
            CatalogFunction(name: "set_from"),
            CatalogFunction(name: "chain"),
            // Stdlib injection helper
            CatalogFunction(name: "import"),
        ],
        availability: .base
    )
}
