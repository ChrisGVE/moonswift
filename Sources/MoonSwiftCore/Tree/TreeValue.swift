// File: Sources/MoonSwiftCore/Tree/TreeValue.swift
// Role: Neutral decoded tree shared by all three format decoders (JSON, YAML,
//       TOML). One tree representation lets a single JSONPath evaluator work
//       across all formats. Byte-span location lives in SpanLocator (separate
//       task); this file is the decoded-value side only.
// Upstream: TreeDecoderJSON, TreeDecoderYAML, TreeDecoderTOML (produce it)
// Downstream: JSONPathEvaluator (consumes it), SourceStore (holds it)

import Collections

// MARK: - TreeValue

/// A format-neutral decoded tree node.
///
/// Every JSON, YAML, or TOML document decodes into this representation before
/// JSONPath evaluation. The `map` case uses `OrderedDictionary` to preserve
/// the key insertion order of the source document — important for the picker
/// tree view and for round-trip fidelity.
///
/// Numeric precision rules:
/// - An integer-valued number whose value fits in `Int64` decodes as `.int`.
/// - A number with a fractional part, or one outside `Int64` range, decodes
///   as `.double`.
///
/// YAML specifics: anchors and aliases are resolved by Yams before the tree
/// is built; this type never sees raw alias nodes.
///
/// TOML specifics: datetime values (`TOMLDate`, `TOMLTime`, `TOMLDateTime`)
/// are non-designatable (they carry no `.string` representation here) and are
/// stored as `.null` — callers that require datetime access should use the raw
/// TOMLKit API. This matches the PRD F1.2 contract: datetime fields are
/// "non-string" errors and cannot be designated as Lua field targets.
public enum TreeValue: Sendable, Equatable {

    // MARK: Scalar cases

    /// A UTF-8 string value.
    case string(String)

    /// An integer that fits in 64-bit signed range.
    case int(Int64)

    /// A floating-point number, or an integer outside `Int64` range.
    case double(Double)

    /// A boolean value.
    case bool(Bool)

    // MARK: Collection cases

    /// An ordered sequence of values.
    case array([TreeValue])

    /// A key-value map preserving insertion order.
    ///
    /// `OrderedDictionary` from `swift-collections` is used instead of
    /// `Dictionary` so that the key order authored in the source document is
    /// preserved through decode and surfaced faithfully in the picker tree
    /// view.
    case map(OrderedDictionary<String, TreeValue>)

    // MARK: Null

    /// An absent or null value.
    ///
    /// Produced by JSON `null`, YAML `~` / `null`, TOML datetime types
    /// (which are not string-designatable), or any value that has no
    /// representation in the scalar cases above.
    case null
}
