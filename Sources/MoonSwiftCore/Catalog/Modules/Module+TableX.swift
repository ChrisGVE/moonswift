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
//       Signatures sourced from TableXModule.swift Lua block function definitions
//       and the module-level Lua API doc comment.
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
            // Source: TableXModule.swift deepcopyCallback — type-aware, handles LuaSwift typed objects
            CatalogFunction(
                name: "deepcopy",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "seen", type: "table", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Return a deep copy of table t with cycle detection. LuaSwift typed objects are cloned via types.clone; plain tables are recursively copied including metatables."
            ),
            // Source: TableXModule.swift deepmergeCallback — type-aware recursive merge
            CatalogFunction(
                name: "deepmerge",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "table",
                doc:
                    "Return a new table that is the recursive merge of t1 and t2. Keys in t2 override t1; nested plain tables are merged recursively. LuaSwift typed objects are replaced, not merged."
            ),
            // Source: TableXModule.swift flattenCallback — args[0]=t, args[1]=depth?
            CatalogFunction(
                name: "flatten",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "depth", type: "number", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Flatten nested arrays in t into a single array. Optional depth limits how many levels are flattened (default: all levels)."
            ),
            // Source: TableXModule.swift keysCallback — args[0]=t
            CatalogFunction(
                name: "keys",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return an array of all keys in t (order is unspecified for non-array tables)."
            ),
            // Source: TableXModule.swift valuesCallback — args[0]=t
            CatalogFunction(
                name: "values",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return an array of all values in t (order is unspecified for non-array tables)."
            ),
            // Source: TableXModule.swift invertCallback — args[0]=t
            CatalogFunction(
                name: "invert",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc:
                    "Return a new table with keys and values swapped. Values must be unique strings or numbers to use as keys."
            ),
            // Lua-defined (injected by the Lua run block)
            // Source: TableXModule.swift Lua — function luaswift.tablex.copy(t)
            CatalogFunction(
                name: "copy",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return a shallow copy of table t (one level only; nested tables share references)."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.map(t, f)
            CatalogFunction(
                name: "map",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "f", type: "function"),
                ],
                returns: "table",
                doc: "Apply f(value, key) to every entry in t and return a new table with the results at the same keys."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.filter(t, f)
            CatalogFunction(
                name: "filter",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "f", type: "function"),
                ],
                returns: "table",
                doc:
                    "Return a new table containing only entries for which f(value, key) returns truthy. Array keys are renumbered sequentially."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.reduce(t, f, init)
            CatalogFunction(
                name: "reduce",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "f", type: "function"),
                    CatalogParam(name: "init", type: "any", isOptional: true),
                ],
                returns: "any",
                doc:
                    "Left-fold t with accumulator function f(acc, value, key). init is the initial accumulator value; defaults to nil."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.foreach(t, f)
            CatalogFunction(
                name: "foreach",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "f", type: "function"),
                ],
                returns: nil,
                doc: "Call f(value, key) for every entry in t for side effects. Returns nil."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.find(t, value)
            CatalogFunction(
                name: "find",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "value", type: "any"),
                ],
                returns: "any",
                doc: "Return the first key whose value equals value, or nil if not found."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.contains(t, value)
            CatalogFunction(
                name: "contains",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "value", type: "any"),
                ],
                returns: "boolean",
                doc: "Return true if any value in t equals value."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.size(t)
            CatalogFunction(
                name: "size",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc:
                    "Return the total number of entries in t, including non-integer keys (unlike #t which only counts the array part)."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.isempty(t)
            CatalogFunction(
                name: "isempty",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "boolean",
                doc: "Return true if t has no entries at all (next(t) == nil)."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.isarray(t)
            CatalogFunction(
                name: "isarray",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "boolean",
                doc: "Return true if t is array-like: all keys are sequential integers starting at 1."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.slice(t, i, j, step)
            CatalogFunction(
                name: "slice",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "i", type: "number", isOptional: true),
                    CatalogParam(name: "j", type: "number", isOptional: true),
                    CatalogParam(name: "step", type: "number", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Return a sub-array of t from index i to j with optional step. Python-style: 1-based, negative indices count from end, step defaults to 1."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.reverse(t)
            CatalogFunction(
                name: "reverse",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return a new array with the elements of t in reverse order."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.unique(t)
            CatalogFunction(
                name: "unique",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return a new array with duplicate values removed, preserving first-occurrence order."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.sort(t, comp)
            CatalogFunction(
                name: "sort",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "comp", type: "function", isOptional: true),
                ],
                returns: "table",
                doc: "Return a new sorted array. Optional comparator comp(a, b) returns true if a should come before b."
            ),
            // Source: TableXModule.swift Lua — set operations
            CatalogFunction(
                name: "union",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "table",
                doc: "Return an array containing all unique values from both t1 and t2 (set union)."
            ),
            CatalogFunction(
                name: "intersection",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "table",
                doc: "Return an array containing values present in both t1 and t2 (set intersection)."
            ),
            CatalogFunction(
                name: "difference",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "table",
                doc: "Return an array of values in t1 that are not in t2 (set difference t1 \\ t2)."
            ),
            // Source: TableXModule.swift Lua — equality
            CatalogFunction(
                name: "equals",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "boolean",
                doc: "Return true if t1 and t2 have the same keys and values (shallow comparison using ==)."
            ),
            CatalogFunction(
                name: "deepequals",
                params: [
                    CatalogParam(name: "t1", type: "table"),
                    CatalogParam(name: "t2", type: "table"),
                ],
                returns: "boolean",
                doc: "Return true if t1 and t2 are structurally identical, comparing nested tables recursively."
            ),
            // Source: TableXModule.swift Lua — collect/dict_from/set_from
            CatalogFunction(
                name: "collect",
                params: [
                    CatalogParam(name: "iter", type: "function")
                ],
                returns: "table",
                doc: "Consume an iterator function and collect all yielded values into an array."
            ),
            CatalogFunction(
                name: "dict_from",
                params: [
                    CatalogParam(name: "keys", type: "table"),
                    CatalogParam(name: "values", type: "table"),
                ],
                returns: "table",
                doc: "Build a dictionary table from parallel arrays of keys and values."
            ),
            CatalogFunction(
                name: "set_from",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "table",
                doc: "Return a set-like table where each unique value from array t becomes a key mapped to true."
            ),
            // Source: TableXModule.swift Lua — function luaswift.tablex.chain(...)
            CatalogFunction(
                name: "chain",
                params: [CatalogParam(name: "...", type: "table")],
                returns: "table",
                doc: "Concatenate multiple arrays into a single new array, in order."
            ),
            // Stdlib injection helper
            // Source: TableXModule.swift Lua — import() extends table library
            CatalogFunction(
                name: "import",
                params: [],
                returns: nil,
                doc:
                    "Inject all tablex functions into the standard table library, enabling table.map, table.filter, table.deepcopy, etc."
            ),
        ],
        availability: .base
    )
}
