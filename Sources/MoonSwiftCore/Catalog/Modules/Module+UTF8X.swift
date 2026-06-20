// File: Sources/MoonSwiftCore/Catalog/Modules/Module+UTF8X.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.utf8x — Unicode-aware string operations
//       that correctly handle multi-byte codepoints.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/UTF8XModule.swift
//       (Lua run block: luaswift.utf8x = { width, sub, reverse, upper, lower,
//        len, chars, slice, import }).
//       Signatures sourced from UTF8XModule.swift callback implementations and
//       the module-level Lua API doc comment.
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.utf8x` — Unicode-aware string utilities (also aliased as `utf8x` global).
    static let utf8x = CatalogModule(
        tableName: "utf8x",
        functions: [
            // Source: UTF8XModule.swift widthCallback — args[0]=string
            // Returns total display-column width, counting CJK/wide chars as 2.
            CatalogFunction(
                name: "width",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "number",
                doc:
                    "Return the display-column width of a UTF-8 string. Wide characters (CJK ideographs, full-width, emoji) count as 2 columns; all others count as 1."
            ),
            // Source: UTF8XModule.swift subCallback — args[0]=string, args[1]=i, args[2]=j?
            // Codepoint-based; negative indices count from end.
            CatalogFunction(
                name: "sub",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "i", type: "number"),
                    CatalogParam(name: "j", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Return the substring of s from codepoint index i to j (inclusive, 1-based). Negative indices count from the end. j defaults to -1 (last codepoint)."
            ),
            // Source: UTF8XModule.swift reverseCallback — args[0]=string
            CatalogFunction(
                name: "reverse",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "string",
                doc: "Reverse the codepoint sequence of a UTF-8 string, preserving multi-byte characters."
            ),
            // Source: UTF8XModule.swift upperCallback — args[0]=string
            CatalogFunction(
                name: "upper",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "string",
                doc:
                    "Convert a UTF-8 string to uppercase using Swift's full Unicode case mapping (handles accented characters, etc.)."
            ),
            // Source: UTF8XModule.swift lowerCallback — args[0]=string
            CatalogFunction(
                name: "lower",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "string",
                doc: "Convert a UTF-8 string to lowercase using Swift's full Unicode case mapping."
            ),
            // Source: UTF8XModule.swift lenCallback — args[0]=string
            CatalogFunction(
                name: "len",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "number",
                doc:
                    "Return the number of Unicode codepoints in s (not bytes). Equivalent to utf8.len but works without pcall on arbitrary strings."
            ),
            // Source: UTF8XModule.swift charsCallback — args[0]=string
            // Returns an iterator function suitable for use in a generic for loop.
            CatalogFunction(
                name: "chars",
                params: [
                    CatalogParam(name: "s", type: "string")
                ],
                returns: "function",
                doc:
                    "Return an iterator over the Unicode codepoints of s. Each iteration yields one codepoint as a single-character string. Use in a generic for loop: for ch in utf8x.chars(s) do ... end"
            ),
            // Source: UTF8XModule.swift sliceCallback — args[0]=string, args[1]=i, args[2]=j?
            CatalogFunction(
                name: "slice",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "i", type: "number"),
                    CatalogParam(name: "j", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Return the codepoint slice of s from index i to j. Identical to utf8x.sub but named for consistency with tablex.slice semantics."
            ),
            // Source: UTF8XModule.swift Lua run block — import() extends utf8 library
            CatalogFunction(
                name: "import",
                params: [],
                returns: nil,
                doc:
                    "Inject utf8x functions (width, sub, reverse, upper, lower, chars, slice) into the standard utf8 library table. No-op when the utf8 library is absent (Lua < 5.3)."
            ),
        ],
        availability: .base
    )
}
