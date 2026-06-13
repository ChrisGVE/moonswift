// File: Sources/MoonSwiftCore/Catalog/Modules/Module+YAML.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.yaml — YAML encode/decode including
//       multi-document streams.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/YAMLModule.swift
//       (Lua run block: luaswift.yaml = { encode, decode, encode_all, decode_all }).
//       Signatures sourced from YAMLModule.swift callback implementations and
//       module-level doc comment.
//       The YAML module is gated on LUASWIFT_YAMS in ModuleRegistry but is
//       unconditionally bundled in MoonSwift's LuaSwift dependency (Yams is a
//       direct MoonSwift dependency). Classified .base for the MoonSwift runtime.
//
//       Availability: .base — Yams is always present in MoonSwift builds.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.yaml` — YAML encode, decode, multi-document streams.
    static let yaml = CatalogModule(
        tableName: "yaml",
        functions: [
            // Source: YAMLModule.swift encodeCallback — args[0]=value
            CatalogFunction(
                name: "encode",
                params: [
                    CatalogParam(name: "value", type: "any")
                ],
                returns: "string",
                doc: "Encode a Lua value to a YAML string using the Yams library."
            ),
            // Source: YAMLModule.swift decodeCallback — args[0]=string
            CatalogFunction(
                name: "decode",
                params: [
                    CatalogParam(name: "str", type: "string")
                ],
                returns: "any",
                doc: "Decode a YAML string to a Lua value. Parses the first document in a multi-document stream."
            ),
            // Source: YAMLModule.swift encodeAllCallback — args[0]=array of values
            CatalogFunction(
                name: "encode_all",
                params: [
                    CatalogParam(name: "docs", type: "table")
                ],
                returns: "string",
                doc: "Encode an array of Lua values to a multi-document YAML string. Each document is separated by ---."
            ),
            // Source: YAMLModule.swift decodeAllCallback — args[0]=string
            CatalogFunction(
                name: "decode_all",
                params: [
                    CatalogParam(name: "str", type: "string")
                ],
                returns: "table",
                doc:
                    "Decode a multi-document YAML string to an array of Lua values. Returns an array with one entry per document."
            ),
        ],
        availability: .base
    )
}
