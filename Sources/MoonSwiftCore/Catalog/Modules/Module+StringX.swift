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
//       Signatures sourced from StringXModule.swift callback implementations and
//       the module-level Lua API doc comment.
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
            // Source: StringXModule.swift stripCallback — args[0]=s, args[1]=chars?
            CatalogFunction(
                name: "strip",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "chars", type: "string", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Remove leading and trailing whitespace from s. If chars is given, remove those characters instead of whitespace."
            ),
            // Source: StringXModule.swift lstripCallback — args[0]=s, args[1]=chars?
            CatalogFunction(
                name: "lstrip",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "chars", type: "string", isOptional: true),
                ],
                returns: "string",
                doc: "Remove leading whitespace (or chars) from s."
            ),
            // Source: StringXModule.swift rstripCallback — args[0]=s, args[1]=chars?
            CatalogFunction(
                name: "rstrip",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "chars", type: "string", isOptional: true),
                ],
                returns: "string",
                doc: "Remove trailing whitespace (or chars) from s."
            ),
            // Splitting and joining
            // Source: StringXModule.swift splitCallback — args[0]=s, args[1]=sep, args[2]=maxsplit?
            CatalogFunction(
                name: "split",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "sep", type: "string"),
                    CatalogParam(name: "maxsplit", type: "number", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Split s by the separator sep and return an array of substrings. Optional maxsplit limits the number of splits."
            ),
            // Source: StringXModule.swift replaceCallback — args[0]=s, args[1]=old, args[2]=new, args[3]=count?
            CatalogFunction(
                name: "replace",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "old", type: "string"),
                    CatalogParam(name: "new", type: "string"),
                    CatalogParam(name: "count", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Replace occurrences of old with new in s. Optional count limits the number of replacements (default: all)."
            ),
            // Source: StringXModule.swift joinCallback — args[0]=parts, args[1]=sep
            CatalogFunction(
                name: "join",
                params: [
                    CatalogParam(name: "parts", type: "table"),
                    CatalogParam(name: "sep", type: "string"),
                ],
                returns: "string",
                doc: "Join the string elements of array parts with sep between each element."
            ),
            // Predicates
            // Source: StringXModule.swift startswithCallback — args[0]=s, args[1]=prefix
            CatalogFunction(
                name: "startswith",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "prefix", type: "string"),
                ],
                returns: "boolean",
                doc: "Return true if s starts with prefix."
            ),
            // Source: StringXModule.swift endswithCallback — args[0]=s, args[1]=suffix
            CatalogFunction(
                name: "endswith",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "suffix", type: "string"),
                ],
                returns: "boolean",
                doc: "Return true if s ends with suffix."
            ),
            // Source: StringXModule.swift containsCallback — args[0]=s, args[1]=sub
            CatalogFunction(
                name: "contains",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "sub", type: "string"),
                ],
                returns: "boolean",
                doc: "Return true if s contains the substring sub."
            ),
            // Source: StringXModule.swift countCallback — args[0]=s, args[1]=sub
            CatalogFunction(
                name: "count",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "sub", type: "string"),
                ],
                returns: "number",
                doc: "Return the number of non-overlapping occurrences of sub in s."
            ),
            // Case transforms
            // Source: StringXModule.swift capitalizeCallback — args[0]=s
            CatalogFunction(
                name: "capitalize",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "string",
                doc: "Return s with the first character uppercased and the rest lowercased."
            ),
            // Source: StringXModule.swift titleCallback — args[0]=s
            CatalogFunction(
                name: "title",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "string",
                doc: "Return s in title case — first letter of each word uppercased, rest lowercased."
            ),
            // Padding and centering
            // Source: StringXModule.swift lpadCallback — args[0]=s, args[1]=width, args[2]=char?
            CatalogFunction(
                name: "lpad",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "width", type: "number"),
                    CatalogParam(name: "char", type: "string", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Left-pad s to at least width characters using char (default space). Returns s unchanged if already at or above width."
            ),
            // Source: StringXModule.swift rpadCallback — args[0]=s, args[1]=width, args[2]=char?
            CatalogFunction(
                name: "rpad",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "width", type: "number"),
                    CatalogParam(name: "char", type: "string", isOptional: true),
                ],
                returns: "string",
                doc: "Right-pad s to at least width characters using char (default space)."
            ),
            // Source: StringXModule.swift centerCallback — args[0]=s, args[1]=width, args[2]=char?
            CatalogFunction(
                name: "center",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "width", type: "number"),
                    CatalogParam(name: "char", type: "string", isOptional: true),
                ],
                returns: "string",
                doc: "Center s in a field of width characters, padding with char (default space) on both sides."
            ),
            // Character-class predicates (canonical is_<name> convention)
            // Source: StringXModule.swift isAlphaCallback — args[0]=s
            CatalogFunction(
                name: "is_alpha",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every character is alphabetic."
            ),
            CatalogFunction(
                name: "is_digit",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every character is a decimal digit."
            ),
            CatalogFunction(
                name: "is_alnum",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every character is alphanumeric."
            ),
            CatalogFunction(
                name: "is_space",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every character is whitespace."
            ),
            CatalogFunction(
                name: "is_upper",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every cased character is uppercase."
            ),
            CatalogFunction(
                name: "is_lower",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is non-empty and every cased character is lowercase."
            ),
            CatalogFunction(
                name: "is_empty",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s has zero length."
            ),
            CatalogFunction(
                name: "is_blank",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Return true if s is empty or contains only whitespace characters."
            ),
            // Backward-compatibility aliases (deprecated; prefer is_<name> forms)
            CatalogFunction(
                name: "isalpha",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_alpha. Prefer stringx.is_alpha."
            ),
            CatalogFunction(
                name: "isdigit",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_digit. Prefer stringx.is_digit."
            ),
            CatalogFunction(
                name: "isalnum",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_alnum. Prefer stringx.is_alnum."
            ),
            CatalogFunction(
                name: "isspace",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_space. Prefer stringx.is_space."
            ),
            CatalogFunction(
                name: "isupper",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_upper. Prefer stringx.is_upper."
            ),
            CatalogFunction(
                name: "islower",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_lower. Prefer stringx.is_lower."
            ),
            CatalogFunction(
                name: "isempty",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_empty. Prefer stringx.is_empty."
            ),
            CatalogFunction(
                name: "isblank",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "boolean",
                doc: "Deprecated alias for is_blank. Prefer stringx.is_blank."
            ),
            // Multi-line and wrapping
            // Source: StringXModule.swift splitlinesCallback — args[0]=s
            CatalogFunction(
                name: "splitlines",
                params: [CatalogParam(name: "s", type: "string")],
                returns: "table",
                doc: "Split s at line boundaries (\\n, \\r\\n, \\r) and return an array of lines without terminators."
            ),
            // Source: StringXModule.swift wrapCallback — args[0]=s, args[1]=width, args[2]=opts?
            CatalogFunction(
                name: "wrap",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "width", type: "number"),
                ],
                returns: "string",
                doc: "Word-wrap s to at most width characters per line. Returns a string with embedded newlines."
            ),
            // Source: StringXModule.swift truncateCallback — args[0]=s, args[1]=maxlen, args[2]=suffix?
            CatalogFunction(
                name: "truncate",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "maxlen", type: "number"),
                    CatalogParam(name: "suffix", type: "string", isOptional: true),
                ],
                returns: "string",
                doc: "Truncate s to maxlen characters, appending suffix (default \"…\") when truncation occurs."
            ),
            // Source: StringXModule.swift sliceCallback — args[0]=s, args[1]=i, args[2]=j?
            CatalogFunction(
                name: "slice",
                params: [
                    CatalogParam(name: "s", type: "string"),
                    CatalogParam(name: "i", type: "number"),
                    CatalogParam(name: "j", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Return the byte-level substring of s from index i to j (1-based, inclusive). Negative indices count from the end."
            ),
            // Stdlib injection helper
            // Source: StringXModule.swift Lua run block — import() extends string table
            CatalogFunction(
                name: "import",
                params: [],
                returns: nil,
                doc:
                    "Inject all stringx functions into the standard string table and string metatable, enabling (\"hello\"):strip() method syntax."
            ),
        ],
        availability: .base
    )
}
