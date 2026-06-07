// File: Sources/MoonSwiftTUI/Highlight/CaptureMapping.swift
// Location: MoonSwiftTUI/Highlight/
// Role: Maps tree-sitter capture names to ThemeToken values as specified in
//       ux-spec.md §8.2. This is the BINDING mapping: every entry in the spec
//       table appears here exactly; all unmapped captures fall back to
//       ThemeToken.identifier (the `identifier` token role) per the spec rule.
//
// Spec reference: docs/internals/ux-spec.md §8.2
//       "Tree-sitter capture-name → token mapping" (Lua grammar,
//       SwiftTreeSitter capture names). [UX]
//
// NOTE: Only the tree-sitter-lua grammar uses this mapping in P1.
//       JSON/YAML/TOML sources use a separate, simpler mapping that
//       distinguishes keys, values, strings, and comments using node types
//       directly, not capture names. That logic lives in Highlighter.swift.

// MARK: - CaptureMapping

/// Translates a tree-sitter-lua capture name into the corresponding ThemeToken.
///
/// The mapping is the authoritative ux-spec.md §8.2 table — no deviation.
/// Callers pass the full dotted capture name (e.g. `"keyword.function"`) and
/// receive the correct token. Unknown capture names return `.variable` (the
/// `identifier` role per the spec).
enum CaptureMapping {

    // MARK: - Primary lookup

    /// Return the ThemeToken for the given capture name.
    ///
    /// `captureName` is the full dotted name returned by `QueryCapture.name`
    /// (e.g. `"keyword"`, `"keyword.function"`, `"variable.builtin"`).
    /// The lookup is exact — no prefix folding at this layer.
    ///
    /// Unmapped names fall back to `.identifier` per
    /// ux-spec.md §8.2: "All unmapped captures fall back to `identifier`."
    static func token(for captureName: String) -> ThemeToken {
        switch captureName {

        // MARK: keyword family → .keyword
        case "keyword":
            return .keyword
        case "keyword.function":
            return .keyword
        case "keyword.return":
            return .keyword
        case "keyword.operator":
            return .keyword
        case "keyword.conditional":
            return .keyword
        case "keyword.repeat":
            return .keyword
        case "keyword.exception":
            return .keyword

        // MARK: string family → .string / .keyword
        case "string":
            return .string
        case "string.escape":
            // Reuses keyword pink as specified: "distinct visual; reuses keyword pink"
            return .keyword

        // MARK: comment → .comment
        case "comment":
            return .comment

        // MARK: number / constant → .number
        case "number":
            return .number
        case "constant":
            return .number
        case "constant.builtin":
            // nil, true, false — keyword per spec
            return .keyword

        // MARK: function family → .functionName (spec: function_name)
        case "function":
            return .functionName
        case "method":
            return .functionName
        case "constructor":
            return .functionName
        case "type":
            return .functionName

        // MARK: variable / field / parameter → .identifier (spec: identifier)
        case "variable":
            return .identifier
        case "variable.builtin":
            // _G, _ENV, self — keyword per spec
            return .keyword
        case "field":
            return .identifier
        case "parameter":
            return .identifier

        // MARK: operator → .operatorToken
        case "operator":
            return .operatorToken

        // MARK: punctuation → .identifier (spec: identifier)
        // ux-spec §8.2: punctuation.bracket/delimiter map to the `identifier` token.
        case "punctuation.bracket":
            return .identifier
        case "punctuation.delimiter":
            return .identifier

        // MARK: label → .keyword (goto labels)
        case "label":
            return .keyword

        // MARK: fallback
        // ux-spec §8.2: "All unmapped captures fall back to `identifier`."
        default:
            return .identifier
        }
    }
}
