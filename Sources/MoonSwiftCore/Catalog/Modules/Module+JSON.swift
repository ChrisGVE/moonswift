// File: Sources/MoonSwiftCore/Catalog/Modules/Module+JSON.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.json — JSON encode/decode with JSONC and
//       JSON5 variants, plus the null-sentinel helpers.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/JSONModule.swift
//       (install method, Lua run block: luaswift.json = { encode, decode,
//        decode_jsonc, decode_json5, null } + function luaswift.json.is_null).
//       Signatures sourced from JSONModule.swift callback implementations and
//       module-level doc comment.
//
//       Availability: .base — always installed (unconditional in ModuleRegistry).
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.json` — JSON encode, decode, JSONC, JSON5, null sentinel.
    static let json = CatalogModule(
        tableName: "json",
        functions: [
            // Source: JSONModule.swift encodeCallback — args[0]=value, args[1]=options?
            // options table: {pretty: boolean, indent: number}
            CatalogFunction(
                name: "encode",
                params: [
                    CatalogParam(name: "value", type: "any"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Encode a Lua value to a JSON string. The optional options table accepts {pretty=true, indent=2} for formatted output."
            ),
            // Source: JSONModule.swift decodeCallback — args[0]=string, args[1]=options?
            // options table: {format: string, comments: boolean}
            CatalogFunction(
                name: "decode",
                params: [
                    CatalogParam(name: "str", type: "string"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "any",
                doc:
                    "Decode a JSON string to a Lua value. Optional options table: {format='jsonc'|'json5'} or {comments=true} for JSONC."
            ),
            // Source: JSONModule.swift decodeJSONCCallback — args[0]=string
            CatalogFunction(
                name: "decode_jsonc",
                params: [
                    CatalogParam(name: "str", type: "string")
                ],
                returns: "any",
                doc:
                    "Decode a JSONC (JSON with Comments) string to a Lua value. Strips // and /* */ comments before parsing."
            ),
            // Source: JSONModule.swift decodeJSON5Callback — args[0]=string
            CatalogFunction(
                name: "decode_json5",
                params: [
                    CatalogParam(name: "str", type: "string")
                ],
                returns: "any",
                doc:
                    "Decode a JSON5 (relaxed JSON) string to a Lua value. Allows trailing commas, unquoted keys, and single-quoted strings."
            ),
            // is_null is a function; null is a sentinel value (table), not a function.
            // For luacheck globals we list it as a field so it is known to the linter.
            // Source: JSONModule.swift Lua run block — function luaswift.json.is_null(v)
            CatalogFunction(
                name: "is_null",
                params: [
                    CatalogParam(name: "v", type: "any")
                ],
                returns: "boolean",
                doc:
                    "Return true if v is the json.null sentinel or a decoded JSON null. Use instead of == json.null because decoded nulls are distinct table instances."
            ),
        ],
        availability: .base
    )
}
