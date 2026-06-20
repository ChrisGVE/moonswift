// File: Sources/MoonSwiftCore/Catalog/Modules/Module+Types.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.types — runtime type detection and
//       conversion helpers for LuaSwift's extended type system.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/TypesModule.swift
//       (typesLuaCode constant: function types.typeof, is, is_luaswift, is_callable,
//        is_iterable, is_numeric, is_vector, is_matrix, is_geometry, to_array,
//        to_vec2, to_vec3, to_complex, to_vector, to_matrix, clone, all_types).
//       Signatures sourced from TypesModule.swift typesLuaCode Lua block.
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
            // Source: TypesModule.swift typesLuaCode — function types.typeof(value)
            // Returns __luaswift_type for typed tables, or Lua's type() for primitives.
            CatalogFunction(
                name: "typeof",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "string",
                doc:
                    "Return the type name of value as a string. For LuaSwift typed objects returns their __luaswift_type (e.g. \"complex\", \"vec2\"); for Lua primitives returns Lua's type() result."
            ),
            // Source: TypesModule.swift — function types.is(value, typename)
            CatalogFunction(
                name: "is",
                params: [
                    CatalogParam(name: "value", type: "any"),
                    CatalogParam(name: "typename", type: "string"),
                ],
                returns: "boolean",
                doc: "Return true if types.typeof(value) == typename."
            ),
            // Source: TypesModule.swift — function types.is_luaswift(value)
            CatalogFunction(
                name: "is_luaswift",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc:
                    "Return true if value is any LuaSwift extended type (has a __luaswift_type field). LuaSwift types behave like native Lua values via metatables."
            ),
            // Source: TypesModule.swift — function types.is_callable(value)
            CatalogFunction(
                name: "is_callable",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value is a function or a table with a __call metamethod."
            ),
            // Source: TypesModule.swift — function types.is_iterable(value)
            CatalogFunction(
                name: "is_iterable",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value can be iterated with pairs/ipairs (i.e. is a table)."
            ),
            // Source: TypesModule.swift — function types.is_numeric(value)
            CatalogFunction(
                name: "is_numeric",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value is a number or a complex table."
            ),
            // Source: TypesModule.swift — function types.is_vector(value)
            CatalogFunction(
                name: "is_vector",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value is a vec2, vec3, or linalg.vector."
            ),
            // Source: TypesModule.swift — function types.is_matrix(value)
            CatalogFunction(
                name: "is_matrix",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value is a linalg.matrix or array."
            ),
            // Source: TypesModule.swift — function types.is_geometry(value)
            CatalogFunction(
                name: "is_geometry",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "boolean",
                doc: "Return true if value is a vec2, vec3, quaternion, or transform3d."
            ),
            // Type conversion
            // Source: TypesModule.swift — function types.to_array(value)
            CatalogFunction(
                name: "to_array",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a luaswift.array. Accepts arrays, linalg.vector, linalg.matrix, vec2, vec3, or plain tables. Throws if conversion is not defined for the source type."
            ),
            // Source: TypesModule.swift — function types.to_vec2(value)
            CatalogFunction(
                name: "to_vec2",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a vec2. Accepts vec2, array, linalg.vector, or a table with [1]/[2] numeric fields. Throws if conversion is not defined."
            ),
            // Source: TypesModule.swift — function types.to_vec3(value)
            CatalogFunction(
                name: "to_vec3",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a vec3. Accepts vec3, vec2 (z=0), array, linalg.vector, or a table with numeric fields. Throws if conversion is not defined."
            ),
            // Source: TypesModule.swift — function types.to_complex(value)
            CatalogFunction(
                name: "to_complex",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a complex number. Accepts complex, number (imaginary part = 0), or vec2 (x=re, y=im). Throws if conversion is not defined."
            ),
            // Source: TypesModule.swift — function types.to_vector(value)
            CatalogFunction(
                name: "to_vector",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a linalg.vector. Accepts linalg.vector, array, vec2, vec3, or plain table. Throws if conversion is not defined."
            ),
            // Source: TypesModule.swift — function types.to_matrix(value)
            CatalogFunction(
                name: "to_matrix",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "table",
                doc:
                    "Convert value to a linalg.matrix. Accepts linalg.matrix, array, or nested table. Throws if conversion is not defined."
            ),
            // Utilities
            // Source: TypesModule.swift — function types.clone(value)
            CatalogFunction(
                name: "clone",
                params: [CatalogParam(name: "value", type: "any")],
                returns: "any",
                doc:
                    "Return a deep clone of value. For LuaSwift typed objects delegates to their internal clone logic; for plain tables performs a deep copy."
            ),
            // Source: TypesModule.swift — function types.all_types()
            CatalogFunction(
                name: "all_types",
                params: [],
                returns: "table",
                doc:
                    "Return an array of all registered LuaSwift type name strings (e.g. {\"complex\", \"vec2\", \"vec3\", \"array\", …})."
            ),
        ],
        availability: .base
    )
}
