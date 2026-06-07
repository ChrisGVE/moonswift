// File: Sources/MoonSwiftCore/JSONPath/JSONPathExpression.swift
// Role: Public facade for the RFC 9535 JSONPath subset. Combines the parser
//       (string → [PathSegment]) and evaluator ([PathSegment] × TreeValue →
//       [(path, value)]). Also provides NormalizedPath — the concrete resolved
//       path rendered to RFC 9535 normalized form — used for picker persistence
//       and fragment display names.
//
//       This is the only type callers outside the JSONPath folder import.
//       Internal types (JSONPathAST, JSONPathParser, JSONPathEvaluator) remain
//       package-internal.
//
// Reference: RFC 9535 §2.7 (normalized path representation)
//
// Upstream: (callers — SourceStore, picker, ProjectFile validator)
// Downstream: JSONPathParser, JSONPathEvaluator

// MARK: - NormalizedPath

/// A fully-resolved, concrete path from the document root to a matched node,
/// rendered in RFC 9535 normalized form.
///
/// The string representation uses:
/// - Dot notation for keys that contain only `[A-Za-z0-9_]` characters.
/// - Bracket notation `['…']` for keys that contain any other character
///   (spaces, hyphens, dots, Unicode, etc.).
/// - Index notation `[N]` for array positions.
///
/// The `steps` array gives programmatic access to the same path, e.g. for
/// provenance tracking or round-trip verification.
///
/// Example: a match at key `"scripts"` → key `"init"` renders as
/// `$.scripts.init`; a match at key `"a b"` → index 2 renders as
/// `$['a b'][2]`.
public struct NormalizedPath: Sendable, Equatable, CustomStringConvertible {

    /// The concrete resolved steps from root to the matched node.
    public let steps: [ResolvedStep]

    /// The RFC 9535 normalized-form string, starting with `$`.
    public var description: String {
        var out = "$"
        for step in steps {
            switch step {
            case let .key(name):
                if isDotNotationSafe(name) {
                    out += ".\(name)"
                } else {
                    // Escape single quotes and backslashes inside the bracket name.
                    let escaped =
                        name
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    out += "['\(escaped)']"
                }
            case let .index(idx):
                out += "[\(idx)]"
            }
        }
        return out
    }

    /// Returns `true` when `name` qualifies for dot notation — only contains
    /// ASCII letters, digits, and underscores, and is non-empty.
    ///
    /// RFC 9535 §2.7 uses a broader definition for normalized paths (it always
    /// uses bracket notation). MoonSwift's picker generates dot notation for
    /// readability when safe; the evaluator accepts both at parse time.
    private func isDotNotationSafe(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { ch in
            (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
        }
    }
}

// MARK: - JSONPathExpression

/// A parsed and validated RFC 9535 JSONPath subset expression.
///
/// Parse once with `init(parsing:)`, then evaluate against any `TreeValue`
/// tree. The expression is immutable and `Sendable` — safe to share across
/// concurrent tasks.
///
/// ## Supported constructs (P1)
///
/// | Syntax | Example | Description |
/// |--------|---------|-------------|
/// | Root | `$` | Document root |
/// | Dot child | `$.a.b` | Named map key via dot |
/// | Bracket child | `$['a b']` | Named map key via brackets (supports RFC 9535 escapes) |
/// | Array index | `$.a[0]` | Non-negative element position |
/// | Wildcard | `$.a.*` or `$[*]` | All direct children |
/// | Descendant | `$..name` | Recursive descent |
///
/// ## Unsupported (parse-time error)
///
/// Filter selectors `?()`, slice selectors `[1:3]`, negative indices,
/// function extensions. Each produces a distinct `JSONPathError` with a
/// diagnostic message naming the construct and listing the supported subset.
///
/// ## Normalized path
///
/// `normalized` returns the canonical dot/bracket rendering of the original
/// expression, canonicalizing whitespace and quoting. Wildcards and
/// descendants are preserved as-is; concrete normalized paths come from
/// `evaluate(on:)` results.
public struct JSONPathExpression: Sendable {

    // MARK: Stored state

    /// The parsed segment sequence.
    private let segments: [PathSegment]

    /// The canonical rendering of the original expression (not a concrete
    /// resolved path — that comes from `evaluate(on:)` results).
    public let normalized: String

    // MARK: Init

    /// Parse `expression` into an `JSONPathExpression`.
    ///
    /// - Parameter parsing: A JSONPath expression string, e.g. `"$.a.b[0]"`.
    /// - Throws: `JSONPathError` if the expression is syntactically invalid or
    ///   uses a construct outside the P1 subset.
    public init(parsing expression: String) throws(JSONPathError) {
        var parser = JSONPathParser(expression)
        segments = try parser.parse()
        normalized = JSONPathExpression.buildNormalized(from: segments)
    }

    // MARK: Evaluation

    /// Evaluate the expression against `root` and return every matching pair.
    ///
    /// - Parameter root: The `TreeValue` decoded tree (the entire document).
    /// - Returns: All `(path, value)` pairs in document order. An empty array
    ///   means the path matched nothing — not an error.
    public func evaluate(on root: TreeValue) -> [(path: NormalizedPath, value: TreeValue)] {
        let evaluator = JSONPathEvaluator()
        let raw = evaluator.evaluate(segments: segments, on: root)
        return raw.map { (steps, value) in
            (path: NormalizedPath(steps: steps), value: value)
        }
    }

    // MARK: - Normalized rendering

    /// Build a canonical string representation of the segment array.
    ///
    /// This is the normalized form of the *expression* (not of a concrete
    /// resolved path). Wildcard and descendant segments stay as `.*`, `..*`,
    /// etc.
    private static func buildNormalized(from segments: [PathSegment]) -> String {
        var out = "$"
        for segment in segments {
            switch segment {
            case let .child(selector):
                out += renderSelector(selector, descendant: false)
            case let .descendant(selector):
                out += ".." + renderSelectorRaw(selector)
            }
        }
        return out
    }

    /// Render one selector as a child step string (`.name`, `.*`, `[N]`,
    /// `['…']`).
    private static func renderSelector(_ selector: Selector, descendant: Bool) -> String {
        switch selector {
        case let .name(key):
            if isDotSafe(key) {
                return ".\(key)"
            } else {
                let escaped =
                    key
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                return "['\(escaped)']"
            }
        case let .index(idx):
            return "[\(idx)]"
        case .wildcard:
            return ".*"
        }
    }

    /// Render a selector for inline use after `..` (no leading dot/bracket).
    private static func renderSelectorRaw(_ selector: Selector) -> String {
        switch selector {
        case let .name(key):
            if isDotSafe(key) {
                return key
            } else {
                let escaped =
                    key
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                return "['\(escaped)']"
            }
        case let .index(idx):
            return "[\(idx)]"
        case .wildcard:
            return "*"
        }
    }

    /// `true` when `key` can be expressed in dot notation.
    private static func isDotSafe(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { ch in
            (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
        }
    }
}
