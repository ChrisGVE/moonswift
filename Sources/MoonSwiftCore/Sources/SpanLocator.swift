// File: Sources/MoonSwiftCore/Sources/SpanLocator.swift
// Location: MoonSwiftCore/Sources/
// Role: Tree-sitter–based byte-span and line-offset locator for structured-file
//       field values. Given the raw UTF-8 file bytes, a format (JSON/YAML/TOML),
//       and a concrete resolved path ([ResolvedStep]), parses the file with the
//       format-appropriate grammar, walks the syntax tree to the target node,
//       and returns the UTF-8 byte range of the VALUE CONTENT (quotes excluded)
//       plus the 0-based line offset.
//       Also detects YAML alias nodes at the designated path (R7 invariant).
// Upstream: SourceStore (calls locateSpan)
// Downstream: (none — pure output to SourceStore)
//
// Tree-sitter encoding note:
//   SwiftTreeSitter's Parser.parse(_:) uses UTF-16LE internally; Node.byteRange
//   is therefore a Range<UInt32> of UTF-16 code-unit pairs (each BMP code point
//   = 2 bytes in the tree-sitter byte count). Node.pointRange gives (row, col)
//   where col is also in UTF-16 code units. SpanLocator converts to UTF-8 byte
//   offsets via UTF16ToUTF8OffsetMap built once per call.
//
// Grammar node-type contracts (see grammar.js / corpus for each format):
//   JSON:  document → object | array
//          object   → pair+ (pair: key: string, value: _value)
//          string   → string_content child (content without quotes)
//   YAML:  stream → document → block_node → block_mapping → block_mapping_pair
//          (fields: key: flow_node, value: block_node | flow_node)
//          plain string: string_scalar (plain text = the value directly)
//          quoted string: double_quote_scalar / single_quote_scalar (includes quotes)
//          alias node: "alias" (R7 error: user must designate the anchor)
//   TOML:  document → table* pair*
//          table   → [bare_key | dotted_key] pair+
//          pair    → (bare_key | quoted_key) = value
//          string  → includes surrounding quotes; content between them

import CTreeSitterTOML
import Foundation
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterYAML

// MARK: - StructuredFileFormat

/// The on-disk format of a structured source file.
public enum StructuredFileFormat: Sendable {
    case json
    case yaml
    case toml
}

extension StructuredFileFormat {
    /// Derive the format from a file extension (case-insensitive).
    static func from(extension ext: String) -> StructuredFileFormat? {
        switch ext.lowercased() {
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        default: return nil
        }
    }
}

// MARK: - SpanLocation

/// The byte span and line offset for a single field value in a structured file.
public struct SpanLocation: Sendable {
    /// UTF-8 byte range of the VALUE CONTENT in the original file (quotes excluded).
    ///
    /// For a JSON string `"hello"` at file offset 20, this is `21..<26`
    /// (the `hello` bytes without the surrounding double-quote bytes).
    public let byteRange: Range<Int>

    /// 0-based line number of the first byte of the value in the original file.
    ///
    /// `FragmentProvenance.lineOffset = spanLocation.lineOffset`.
    /// A 1-based fragment line `n` maps to `lineOffset + n` in the file.
    public let lineOffset: Int
}

// MARK: - SpanLocatorError

/// Errors returned when a node cannot be located or a grammar invariant is violated.
public enum SpanLocatorError: Error, Sendable, Equatable {
    /// The file could not be parsed by the tree-sitter grammar.
    case parseFailed
    /// The tree walk reached a YAML alias node at the designated path.
    /// The caller should report "designate the anchor" to the user.
    case yamlAliasAtDesignatedPath
    /// The resolved path could not be followed in the syntax tree.
    case nodeNotFound
}

// MARK: - SpanLocator

/// Stateless, format-aware tree-sitter span locator.
///
/// All methods are `static` and produce no shared mutable state: each call
/// creates a fresh `Parser` instance and a fresh `UTF16ToUTF8OffsetMap`.
public enum SpanLocator {

    // MARK: - Public entry point

    /// Locate the UTF-8 byte span and line offset of the value at `path` in `data`.
    ///
    /// For YAML multi-document streams, `document` selects which document
    /// (0-based) the span is located in. Ignored for JSON and TOML (always 0).
    ///
    /// - Parameters:
    ///   - data:     Raw UTF-8 file bytes (used for key-text extraction and R7 check).
    ///   - format:   The on-disk format of the file.
    ///   - path:     The concrete resolved path produced by `JSONPathEvaluator`.
    ///   - document: 0-based document index for YAML multi-doc streams (default: 0).
    /// - Returns: A `SpanLocation` with the UTF-8 byte range of value content
    ///   (quotes excluded) and the 0-based line offset.
    /// - Throws: `SpanLocatorError` on parse failure, alias node, or missing path.
    public static func locateSpan(
        in data: Data,
        format: StructuredFileFormat,
        path: [ResolvedStep],
        document: Int = 0
    ) throws -> SpanLocation {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpanLocatorError.parseFailed
        }
        return try locateSpan(data: data, text: text, format: format, path: path, document: document)
    }

    // MARK: - Internal implementation

    /// Core implementation that reuses a pre-decoded `text` and raw `data`.
    static func locateSpan(
        data: Data,
        text: String,
        format: StructuredFileFormat,
        path: [ResolvedStep],
        document: Int = 0
    ) throws -> SpanLocation {
        let parser = Parser()
        try parser.setLanguage(language(for: format))

        guard let tree = parser.parse(text), let root = tree.rootNode else {
            throw SpanLocatorError.parseFailed
        }

        let offsetMap = UTF16ToUTF8OffsetMap(text: text)

        let node = try walk(
            root: root,
            format: format,
            path: path,
            data: data,
            offsetMap: offsetMap,
            document: document
        )

        let utf8Range = offsetMap.utf8Range(for: node.byteRange)
        let contentRange = stripDelimiters(
            utf8Range: utf8Range,
            nodeType: node.nodeType ?? ""
        )
        let lineOffset = Int(node.pointRange.lowerBound.row)

        return SpanLocation(byteRange: contentRange, lineOffset: lineOffset)
    }

    // MARK: - Language factory

    private static func language(for format: StructuredFileFormat) -> Language {
        switch format {
        case .json: return Language(language: tree_sitter_json())
        case .yaml: return Language(language: tree_sitter_yaml())
        case .toml: return Language(language: tree_sitter_toml())
        }
    }

    // MARK: - Top-level walk dispatcher

    private static func walk(
        root: Node,
        format: StructuredFileFormat,
        path: [ResolvedStep],
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap,
        document: Int = 0
    ) throws -> Node {
        switch format {
        case .json:
            return try walkJSON(node: root, path: path, idx: 0, data: data, offsetMap: offsetMap)
        case .yaml:
            // For multi-doc YAML, select the correct document before walking.
            let docRoot = try yamlSelectDocument(root: root, at: document)
            return try walkYAML(node: docRoot, path: path, idx: 0, data: data, offsetMap: offsetMap)
        case .toml:
            return try walkTOML(node: root, path: path, idx: 0, data: data, offsetMap: offsetMap)
        }
    }

    /// Return the `document` child of a YAML `stream` node at the given index.
    ///
    /// The YAML grammar wraps each document in a `document` node inside the
    /// top-level `stream`. Document markers (`---`, `...`) are anonymous; only
    /// the named `document` children are counted.
    private static func yamlSelectDocument(root: Node, at index: Int) throws -> Node {
        // If the root is already inside a document (no stream wrapper), return it.
        if root.nodeType != "stream" { return root }
        var count = 0
        for i in 0..<root.childCount {
            guard let child = root.child(at: i), child.isNamed else { continue }
            guard child.nodeType == "document" else { continue }
            if count == index { return child }
            count += 1
        }
        throw SpanLocatorError.nodeNotFound
    }

    // MARK: - JSON walk

    /// Walk a JSON syntax tree following `path[idx...]`.
    ///
    /// Grammar: document → object | array; object → pair+ (key:string, value:_value);
    /// string → string_content child (the text between the double-quote delimiters).
    private static func walkJSON(
        node: Node,
        path: [ResolvedStep],
        idx: Int,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) throws -> Node {
        // Unwrap `document` wrapper to reach the top-level object or array.
        let current = unwrapJSON(node)

        if idx >= path.count {
            // Terminal: return string_content child for strings (no quotes in range),
            // or the node itself for other value types.
            return jsonStringContent(current) ?? current
        }

        switch path[idx] {
        case .key(let name):
            guard current.nodeType == "object" else { throw SpanLocatorError.nodeNotFound }
            guard let pair = jsonFindPair(in: current, key: name, data: data, offsetMap: offsetMap) else {
                throw SpanLocatorError.nodeNotFound
            }
            guard let value = pair.child(byFieldName: "value") else {
                throw SpanLocatorError.nodeNotFound
            }
            return try walkJSON(node: value, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)

        case .index(let n):
            guard current.nodeType == "array" else { throw SpanLocatorError.nodeNotFound }
            guard let element = jsonArrayElement(current, at: n) else {
                throw SpanLocatorError.nodeNotFound
            }
            return try walkJSON(node: element, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
        }
    }

    /// Descend past `document` (and any other single-child wrappers) to reach
    /// the actual top-level JSON value node.
    private static func unwrapJSON(_ node: Node) -> Node {
        var current = node
        while current.nodeType == "document" {
            guard let child = firstNamed(current) else { break }
            current = child
        }
        return current
    }

    /// For a JSON `string` node, return its `string_content` named child (if any).
    /// An empty JSON string `""` has no `string_content` child.
    private static func jsonStringContent(_ node: Node) -> Node? {
        guard node.nodeType == "string" else { return nil }
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            if child.nodeType == "string_content" { return child }
        }
        return nil
    }

    /// Find the JSON `pair` child of `objectNode` whose key text equals `key`.
    private static func jsonFindPair(
        in objectNode: Node,
        key: String,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> Node? {
        for i in 0..<objectNode.childCount {
            guard let child = objectNode.child(at: i),
                child.nodeType == "pair"
            else { continue }
            guard let keyNode = child.child(byFieldName: "key"),
                keyNode.nodeType == "string"
            else { continue }
            // Key content = bytes between the surrounding double quotes.
            let fullRange = offsetMap.utf8Range(for: keyNode.byteRange)
            let contentStart = fullRange.lowerBound + 1
            let contentEnd = fullRange.upperBound - 1
            guard contentEnd > contentStart,
                let keyText = String(data: data[contentStart..<contentEnd], encoding: .utf8)
            else {
                continue
            }
            if keyText == key { return child }
        }
        return nil
    }

    /// Return the `n`-th named value child of a JSON `array` node.
    private static func jsonArrayElement(_ arrayNode: Node, at index: Int) -> Node? {
        var count = 0
        for i in 0..<arrayNode.childCount {
            guard let child = arrayNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            if t == "[" || t == "]" || t == "," { continue }
            if count == index { return child }
            count += 1
        }
        return nil
    }

    // MARK: - YAML walk

    /// Walk a YAML syntax tree following `path[idx...]`.
    ///
    /// Grammar: stream → document → block_node → block_mapping → block_mapping_pair
    /// (fields: key: flow_node, value: block_node | flow_node).
    /// Alias nodes throw `.yamlAliasAtDesignatedPath`.
    private static func walkYAML(
        node: Node,
        path: [ResolvedStep],
        idx: Int,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) throws -> Node {
        let current = unwrapYAML(node)

        if idx >= path.count {
            // Terminal: detect alias and return the value node.
            return try yamlTerminal(current)
        }

        switch path[idx] {
        case .key(let name):
            guard yamlIsMapping(current) else { throw SpanLocatorError.nodeNotFound }
            guard
                let pair = yamlFindPair(
                    in: current, key: name, data: data, offsetMap: offsetMap
                )
            else {
                throw SpanLocatorError.nodeNotFound
            }
            guard let value = pair.child(byFieldName: "value") else {
                throw SpanLocatorError.nodeNotFound
            }
            return try walkYAML(node: value, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)

        case .index(let n):
            guard yamlIsSequence(current) else { throw SpanLocatorError.nodeNotFound }
            guard let element = yamlSequenceElement(current, at: n) else {
                throw SpanLocatorError.nodeNotFound
            }
            return try walkYAML(node: element, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
        }
    }

    /// Descend through YAML wrapper nodes (`stream`, `document`, `block_node`,
    /// `flow_node`) to the first meaningful structural content node.
    private static func unwrapYAML(_ node: Node) -> Node {
        let wrappers: Set<String> = ["stream", "document", "block_node", "flow_node"]
        var current = node
        while let t = current.nodeType, wrappers.contains(t) {
            guard let child = firstMeaningfulYAML(current) else { break }
            current = child
        }
        return current
    }

    /// Return the first named child of `node` that is not a YAML document marker
    /// (`---` or `...`).
    private static func firstMeaningfulYAML(_ node: Node) -> Node? {
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            if t == "---" || t == "..." { continue }
            return child
        }
        return nil
    }

    private static func yamlIsMapping(_ node: Node) -> Bool {
        let t = node.nodeType ?? ""
        return t == "block_mapping" || t == "flow_mapping"
    }

    private static func yamlIsSequence(_ node: Node) -> Bool {
        let t = node.nodeType ?? ""
        return t == "block_sequence" || t == "flow_sequence"
    }

    /// At a terminal YAML node, detect alias and return the content node.
    private static func yamlTerminal(_ node: Node) throws -> Node {
        let t = node.nodeType ?? ""
        if t == "alias" { throw SpanLocatorError.yamlAliasAtDesignatedPath }
        return node
    }

    /// Find the YAML mapping pair whose key text equals `key`.
    private static func yamlFindPair(
        in mappingNode: Node,
        key: String,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> Node? {
        for i in 0..<mappingNode.childCount {
            guard let child = mappingNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            guard t == "block_mapping_pair" || t == "flow_pair" else { continue }
            if yamlKeyText(child, data: data, offsetMap: offsetMap) == key { return child }
        }
        return nil
    }

    /// Extract the key text from a YAML mapping pair using raw file bytes.
    private static func yamlKeyText(
        _ pairNode: Node,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> String? {
        guard let keyWrapper = pairNode.child(byFieldName: "key") else { return nil }
        let scalar = unwrapYAML(keyWrapper)
        let t = scalar.nodeType ?? ""

        // Plain scalar types: the node bytes are the key text directly.
        let plainTypes: Set<String> = [
            "string_scalar", "plain_scalar", "boolean_scalar",
            "integer_scalar", "float_scalar", "null_scalar",
        ]
        if plainTypes.contains(t) {
            return nodeBytes(scalar, data: data, offsetMap: offsetMap)
        }

        // If still in plain_scalar wrapper, get first named child.
        if t == "plain_scalar" {
            if let child = firstNamed(scalar) {
                return nodeBytes(child, data: data, offsetMap: offsetMap)
            }
            return nodeBytes(scalar, data: data, offsetMap: offsetMap)
        }

        // Quoted scalars: strip the surrounding quote character.
        if t == "double_quote_scalar" || t == "single_quote_scalar" {
            let r = offsetMap.utf8Range(for: scalar.byteRange)
            let s = r.lowerBound + 1
            let e = r.upperBound - 1
            guard e > s else { return nil }
            return String(data: data[s..<e], encoding: .utf8)
        }

        // Fallback: raw bytes of the node.
        return nodeBytes(scalar, data: data, offsetMap: offsetMap)
    }

    /// Return the `n`-th element from a YAML sequence node.
    private static func yamlSequenceElement(_ seqNode: Node, at index: Int) -> Node? {
        var count = 0
        for i in 0..<seqNode.childCount {
            guard let child = seqNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            if t == "block_sequence_item" {
                if count == index { return firstMeaningfulYAML(child) }
                count += 1
            } else if t == "flow_node" {
                if count == index { return child }
                count += 1
            }
        }
        return nil
    }

    // MARK: - TOML walk

    /// Walk a TOML syntax tree following `path[idx...]`.
    ///
    /// Grammar: document → table* pair*
    /// table → [bare_key/dotted_key] pair*; pair → key = value; string → "…"
    private static func walkTOML(
        node: Node,
        path: [ResolvedStep],
        idx: Int,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) throws -> Node {
        if idx >= path.count { return node }

        switch path[idx] {
        case .key(let name):
            // Search pairs at the current level first.
            if let value = tomlFindPairValue(
                in: node, key: name, data: data, offsetMap: offsetMap
            ) {
                return try walkTOML(node: value, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
            }
            // Search for a [name] table header.
            if let table = tomlFindTable(
                in: node, key: name, data: data, offsetMap: offsetMap
            ) {
                return try walkTOML(node: table, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
            }
            throw SpanLocatorError.nodeNotFound

        case .index(let n):
            // Inline array: node is an "array" node whose children are the elements.
            if node.nodeType == "array" {
                guard let element = tomlArrayElement(node, at: n) else {
                    throw SpanLocatorError.nodeNotFound
                }
                return try walkTOML(node: element, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
            }
            // Array-of-tables: the key step already resolved to a single
            // `table_array_element` node. The logical array is formed by sibling
            // `table_array_element` nodes in the parent (document) that share the
            // same header key.  Collect them in document order and pick the n-th.
            if node.nodeType == "table_array_element" {
                guard let parent = node.parent else { throw SpanLocatorError.nodeNotFound }
                let headerKey = tomlTableHeaderKey(node, data: data, offsetMap: offsetMap)
                guard
                    let element = tomlArrayOfTablesElement(
                        parent: parent, headerKey: headerKey, at: n,
                        data: data, offsetMap: offsetMap
                    )
                else {
                    throw SpanLocatorError.nodeNotFound
                }
                return try walkTOML(node: element, path: path, idx: idx + 1, data: data, offsetMap: offsetMap)
            }
            throw SpanLocatorError.nodeNotFound
        }
    }

    /// Find the value of a `pair` child of `node` (document or table) whose key
    /// matches `key`.
    private static func tomlFindPairValue(
        in node: Node,
        key: String,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> Node? {
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            guard child.nodeType == "pair" else { continue }
            if tomlPairKey(child, data: data, offsetMap: offsetMap) == key {
                return tomlPairValue(child)
            }
        }
        return nil
    }

    /// Find a `table` or `table_array_element` child of `node` whose header key
    /// matches `key`, and return the table node (for further descent into its pairs).
    private static func tomlFindTable(
        in node: Node,
        key: String,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> Node? {
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            guard t == "table" || t == "table_array_element" else { continue }
            if tomlTableHeaderKey(child, data: data, offsetMap: offsetMap) == key {
                return child
            }
        }
        return nil
    }

    /// Extract the key text from a TOML `pair` node.
    private static func tomlPairKey(
        _ pairNode: Node,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> String? {
        for i in 0..<pairNode.childCount {
            guard let child = pairNode.child(at: i), child.isNamed else { continue }
            return tomlKeyNodeText(child, data: data, offsetMap: offsetMap)
        }
        return nil
    }

    /// Extract the header key from a TOML `table` node (the first named child).
    private static func tomlTableHeaderKey(
        _ tableNode: Node,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> String? {
        for i in 0..<tableNode.childCount {
            guard let child = tableNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            // Skip the `[` bracket tokens (they're not named but guard anyway).
            if t == "bare_key" || t == "quoted_key" || t == "dotted_key" {
                return tomlKeyNodeText(child, data: data, offsetMap: offsetMap)
            }
        }
        return nil
    }

    /// Extract the text of a TOML key node (bare_key, quoted_key, dotted_key).
    private static func tomlKeyNodeText(
        _ keyNode: Node,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> String? {
        let t = keyNode.nodeType ?? ""
        if t == "bare_key" {
            return nodeBytes(keyNode, data: data, offsetMap: offsetMap)
        }
        if t == "quoted_key" {
            let r = offsetMap.utf8Range(for: keyNode.byteRange)
            let s = r.lowerBound + 1
            let e = r.upperBound - 1
            guard e > s else { return nil }
            return String(data: data[s..<e], encoding: .utf8)
        }
        if t == "dotted_key" {
            // Dotted key: return the first component only for table-header matching.
            // Full dotted-key expansion is not implemented in P1; the JSONPath
            // evaluator already resolved the structure via TreeValue decode.
            return nodeBytes(keyNode, data: data, offsetMap: offsetMap)
        }
        return nil
    }

    /// Return the value child of a TOML `pair` node (the last named child after
    /// skipping the key node).
    private static func tomlPairValue(_ pairNode: Node) -> Node? {
        var last: Node? = nil
        for i in 0..<pairNode.childCount {
            guard let child = pairNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            if t == "bare_key" || t == "quoted_key" || t == "dotted_key" { continue }
            last = child
        }
        return last
    }

    /// Return the `n`-th named element of a TOML `array` node.
    private static func tomlArrayElement(_ arrayNode: Node, at index: Int) -> Node? {
        var count = 0
        for i in 0..<arrayNode.childCount {
            guard let child = arrayNode.child(at: i), child.isNamed else { continue }
            let t = child.nodeType ?? ""
            if t == "[" || t == "]" || t == "," || t == "comment" { continue }
            if count == index { return child }
            count += 1
        }
        return nil
    }

    /// Return the `n`-th `table_array_element` child of `parent` whose header key
    /// matches `headerKey`, collecting siblings in document order.
    ///
    /// TOML `[[array-of-tables]]` has no wrapping array node in the tree-sitter
    /// grammar.  All `[[name]]` sections appear as sibling `table_array_element`
    /// children of the document root.  This helper scans them in document order
    /// and returns the zero-based n-th match.
    private static func tomlArrayOfTablesElement(
        parent: Node,
        headerKey: String?,
        at index: Int,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> Node? {
        var count = 0
        for i in 0..<parent.childCount {
            guard let child = parent.child(at: i), child.isNamed else { continue }
            guard child.nodeType == "table_array_element" else { continue }
            guard tomlTableHeaderKey(child, data: data, offsetMap: offsetMap) == headerKey else { continue }
            if count == index { return child }
            count += 1
        }
        return nil
    }

    // MARK: - Delimiter stripping

    /// Return the UTF-8 byte range of VALUE CONTENT, excluding surrounding quote
    /// delimiters for string-typed nodes.
    ///
    /// Nodes whose full byte span includes surrounding quotes are:
    /// - JSON `string` (when returned directly, before string_content optimisation)
    /// - TOML `string`
    /// - YAML `double_quote_scalar` / `single_quote_scalar`
    ///
    /// Note: for JSON the walk already returns the `string_content` child, so
    /// the full `string` node is normally not the terminal. This function is a
    /// safety net for any case that slips through.
    private static func stripDelimiters(
        utf8Range: Range<Int>,
        nodeType: String
    ) -> Range<Int> {
        let quoted: Set<String> = [
            "string",  // JSON (safety net) + TOML
            "double_quote_scalar",  // YAML double-quoted
            "single_quote_scalar",  // YAML single-quoted
        ]
        guard quoted.contains(nodeType) else { return utf8Range }
        let s = utf8Range.lowerBound
        let e = utf8Range.upperBound
        guard e - s >= 2 else { return utf8Range }
        return (s + 1)..<(e - 1)
    }

    // MARK: - Generic node helpers

    /// Return the first named child of `node`.
    private static func firstNamed(_ node: Node) -> Node? {
        for i in 0..<node.childCount {
            if let child = node.child(at: i), child.isNamed { return child }
        }
        return nil
    }

    /// Extract the raw UTF-8 bytes of `node` from the file data using `offsetMap`.
    private static func nodeBytes(
        _ node: Node,
        data: Data,
        offsetMap: UTF16ToUTF8OffsetMap
    ) -> String? {
        let r = offsetMap.utf8Range(for: node.byteRange)
        guard r.lowerBound < data.count, r.upperBound <= data.count else { return nil }
        return String(data: data[r], encoding: .utf8)
    }
}

// MARK: - UTF16ToUTF8OffsetMap

/// A precomputed table mapping UTF-16 code-unit indices to UTF-8 byte offsets.
///
/// Built once per file in O(n) time. Each lookup is O(1) via array indexing.
///
/// Tree-sitter reports byte positions as offsets into the UTF-16LE encoding
/// (2 bytes per BMP code unit, 4 bytes per supplementary code point). This map
/// translates those positions to byte offsets in the original UTF-8 file data.
struct UTF16ToUTF8OffsetMap: Sendable {

    /// `offsets[i]` = UTF-8 byte offset corresponding to UTF-16 code-unit index `i`.
    /// `offsets[count]` = total UTF-8 byte length (past-the-end sentinel).
    private let offsets: [Int]
    private let totalUTF8: Int

    /// Build the map from the file text.
    init(text: String) {
        var table: [Int] = []
        table.reserveCapacity(text.utf16.count + 1)
        var utf8Pos = 0
        for scalar in text.unicodeScalars {
            // One BMP scalar = 1 UTF-16 unit; one supplementary scalar = 2 UTF-16 units.
            table.append(utf8Pos)
            if scalar.utf16.count == 2 {
                // Second surrogate: maps to same UTF-8 start byte as the first.
                table.append(utf8Pos)
            }
            utf8Pos += scalar.utf8.count
        }
        table.append(utf8Pos)  // sentinel for the end position
        self.offsets = table
        self.totalUTF8 = utf8Pos
    }

    /// Convert a tree-sitter UTF-16 byte range to a UTF-8 byte range.
    ///
    /// - Parameter utf16Range: Tree-sitter range where each unit is 2 bytes
    ///   (i.e. divide by 2 to get the UTF-16 code-unit index).
    func utf8Range(for utf16Range: Range<UInt32>) -> Range<Int> {
        let startCU = Int(utf16Range.lowerBound) / 2
        let endCU = Int(utf16Range.upperBound) / 2
        let start = startCU < offsets.count ? offsets[startCU] : totalUTF8
        let end = endCU < offsets.count ? offsets[endCU] : totalUTF8
        return start..<end
    }
}
