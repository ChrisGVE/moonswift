// File: Sources/MoonSwiftCore/Tree/TreeDecoderYAML.swift
// Role: Decodes a YAML document (or one document from a multi-document stream)
//       into a TreeValue tree using the Yams library.
// Upstream: (input — raw YAML text)
// Downstream: SourceStore (passes the tree to JSONPath evaluator)
//
// Anchor/alias resolution:
//   Yams.compose() resolves aliases inline, replacing each alias node with
//   a copy of the referenced anchor node. The resulting Node tree contains
//   no .alias cases; this decoder never needs to handle them explicitly.
//
// Multi-document:
//   Yams.compose_all() returns a lazy sequence of Node trees, one per
//   YAML document separated by "---" / "..." markers.
//   decodeYAML(_:document:) selects document N (default 0).
//
// Tags:
//   Tags outside the YAML core schema (!!str, !!int, !!float, !!bool,
//   !!null, !!seq, !!map) decode to their scalar string form as required by
//   PRD F1.2. The Yams default tag resolution applies: a scalar whose tag
//   resolves to !!int decodes as .int, !!float → .double, !!bool → .bool,
//   !!null → .null, !!str (or unresolved) → .string.

import Collections
import Yams

// MARK: - Public entry point

/// Decodes one document from a YAML string into a `TreeValue` tree.
///
/// - Parameters:
///   - text: A YAML document or multi-document stream as a Swift `String`.
///   - document: Zero-based index of the document to decode in a
///               multi-document stream (default: 0).
/// - Returns: The root `TreeValue` of the selected document.
/// - Throws:
///   - `TreeDecoderError.yamlMalformed` if the YAML is invalid.
///   - `TreeDecoderError.yamlDocumentIndexOutOfRange` if the stream contains
///     fewer documents than `document + 1`.
///   - `TreeDecoderError.nestingTooDeep` if the document exceeds
///     `treeDecoderMaxDepth` levels of nesting (CWE-674 guard).
public func decodeYAML(_ text: String, document: Int = 0) throws -> TreeValue {
    var nodes: [Node] = []
    do {
        // compose_all returns a lazy sequence; materialise only as many
        // documents as needed to reach the requested index.
        for node in try compose_all(yaml: text) {
            nodes.append(node)
            if nodes.count > document { break }
        }
    } catch {
        throw TreeDecoderError.yamlMalformed(error.localizedDescription)
    }

    guard nodes.count > document else {
        throw TreeDecoderError.yamlDocumentIndexOutOfRange(
            requested: document,
            available: nodes.count
        )
    }

    return try nodeToTreeValue(nodes[document], depth: 0)
}

// MARK: - Node → TreeValue conversion (internal)

/// Recursively converts a resolved Yams `Node` to a `TreeValue`.
///
/// Yams resolves aliases before returning the Node tree, so only `.scalar`,
/// `.mapping`, and `.sequence` cases appear here.
///
/// - Parameters:
///   - node:  The Yams node to convert.
///   - depth: Current recursion depth. Throws `nestingTooDeep` when it
///            exceeds `treeDecoderMaxDepth` (128) to prevent stack overflow
///            on pathologically nested documents (CWE-674).
private func nodeToTreeValue(_ node: Node, depth: Int) throws -> TreeValue {
    guard depth <= treeDecoderMaxDepth else {
        throw TreeDecoderError.nestingTooDeep
    }

    switch node {

    case .scalar(let scalar):
        return scalarToTreeValue(scalar)

    case .mapping(let mapping):
        // OrderedDictionary preserves the key order from the YAML source.
        var dict = OrderedDictionary<String, TreeValue>()
        for (keyNode, valueNode) in mapping {
            // YAML keys are themselves nodes; coerce to string for TreeValue.
            let key: String
            if case .scalar(let ks) = keyNode {
                key = ks.string
            } else {
                // Non-scalar key (rare in practice): render as YAML.
                key = (try? Yams.serialize(node: keyNode)) ?? "\(keyNode)"
            }
            dict[key] = try nodeToTreeValue(valueNode, depth: depth + 1)
        }
        return .map(dict)

    case .sequence(let sequence):
        let elements = try sequence.map { try nodeToTreeValue($0, depth: depth + 1) }
        return .array(elements)

    case .alias:
        // compose() resolves aliases; this branch is unreachable in practice.
        // Guard it defensively: treat an unresolved alias as .null.
        return .null
    }
}

// MARK: - Scalar resolution

/// Maps a `Node.Scalar` to a `TreeValue` scalar using its resolved tag.
///
/// The YAML core schema tags (YAML 1.2 §10.3) are:
///   - `tag:yaml.org,2002:null`  → `.null`
///   - `tag:yaml.org,2002:bool`  → `.bool`
///   - `tag:yaml.org,2002:int`   → `.int` (Int64) or `.double` on overflow
///   - `tag:yaml.org,2002:float` → `.double`
///   - `tag:yaml.org,2002:str`   → `.string`
///
/// Implicit tags (empty rawValue — the default when no explicit `!!tag` is
/// written) are resolved against `Resolver.default`, which applies the full
/// YAML core schema regex rules for bool/int/float/null/timestamp. Without
/// this resolution step, `compose()` returns all scalars with the implicit
/// tag, and numeric/boolean literals would all decode as `.string`.
///
/// Any other tag (custom or unknown) falls back to `.string` with the raw
/// scalar text, matching the PRD F1.2 "tags beyond core schema → scalar
/// string form" contract.
private func scalarToTreeValue(_ scalar: Node.Scalar) -> TreeValue {
    // Tag.name is internal in Yams; Tag.rawValue is public.
    // Resolve implicit tags using the YAML core schema resolver so that
    // "3.14", "true", "42", "null" etc. decode to their proper types.
    // compose() returns all untagged scalars with Tag.Name.implicit (rawValue "");
    // without resolution they would all decode as strings.
    // Resolver.resolveTag(of:Node) is the public API that applies the
    // core-schema regex rules.
    let tagName: String
    if scalar.tag.rawValue == Tag.Name.implicit.rawValue {
        tagName = Resolver.default.resolveTag(of: .scalar(scalar)).rawValue
    } else {
        tagName = scalar.tag.rawValue
    }

    switch tagName {
    case Tag.Name.null.rawValue:
        return .null

    case Tag.Name.bool.rawValue:
        // Yams resolves canonical bool values; true/false/yes/no/on/off.
        let lower = scalar.string.lowercased()
        let boolValue = lower == "true" || lower == "yes" || lower == "on"
        return .bool(boolValue)

    case Tag.Name.int.rawValue:
        let raw = scalar.string
        // YAML integers may use decimal, octal (0o…), or hex (0x…) notation.
        let parsed: Int64?
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            parsed = Int64(raw.dropFirst(2), radix: 16)
        } else if raw.hasPrefix("0o") || raw.hasPrefix("0O") {
            parsed = Int64(raw.dropFirst(2), radix: 8)
        } else if raw.hasPrefix("-0x") || raw.hasPrefix("-0X") {
            parsed = Int64(raw.dropFirst(3), radix: 16).map { -$0 }
        } else {
            parsed = Int64(raw)
        }
        if let value = parsed {
            return .int(value)
        }
        // Overflow: promote to Double.
        return .double(Double(raw) ?? 0)

    case Tag.Name.float.rawValue:
        let raw = scalar.string.lowercased()
        // YAML special float literals.
        if raw == ".inf" || raw == "+.inf" || raw == ".infinity" || raw == "+.infinity" {
            return .double(Double.infinity)
        }
        if raw == "-.inf" || raw == "-.infinity" {
            return .double(-Double.infinity)
        }
        if raw == ".nan" {
            return .double(Double.nan)
        }
        return .double(Double(scalar.string) ?? 0)

    default:
        // All other tags (including !!str, implicit, and unknown custom tags) → string.
        return .string(scalar.string)
    }
}
