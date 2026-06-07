// File: Sources/MoonSwiftTUI/Highlight/Highlighter.swift
// Location: MoonSwiftTUI/Highlight/
// Role: Tree-sitter–driven syntax highlighter. Schedules parses as effects
//       off the UI thread on a serial executor, keeps an LRU per-source tree
//       cache for incremental re-parse, and posts .highlightReady(SourceID, spans)
//       back through the EventChannel.
//
//       Ownership rule (ARCHITECTURE.md §2 Highlighter row):
//         • The parse task NEVER writes a shared span cache.
//         • It posts spans as the event payload.
//         • The reducer applies the payload to AppState.highlight (UI-thread,
//           value semantics) before the next render.
//
//       Threading model:
//         • All methods called on the parse executor (a serial DispatchQueue).
//         • EventChannel.post is thread-safe; called from the parse executor.
//         • The AppDriver calls highlight(_:text:via:) while on the UI thread —
//           it dispatches the work item to the serial queue and returns immediately.
//
// Upstream: AppDriver (dispatches highlight effects), EventChannel (result sink)
// Downstream: EventChannel → Reducer → AppState.highlight → Renderer

import CTreeSitterTOML
import Foundation
import MoonSwiftCore
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterLua
import TreeSitterYAML

// MARK: - Highlighter

/// Owns tree-sitter parsers and an LRU tree cache; runs parses on a serial
/// executor and posts `.highlightReady` payloads through the `EventChannel`.
///
/// `@unchecked Sendable`: all mutable state (`parsers`, `treeCache`) is
/// exclusively accessed from `parseQueue` — no concurrent access can occur.
public final class Highlighter: @unchecked Sendable {

    // MARK: - Serial parse executor

    /// Serial DispatchQueue that all tree-sitter work runs on.
    ///
    /// tree-sitter's C runtime is not thread-safe per parser instance.
    /// Confining all access to a single serial queue is the simplest and
    /// most correct approach (ARCHITECTURE.md §2 Highlighter row).
    private let parseQueue = DispatchQueue(label: "com.moonswift.highlighter.parse", qos: .utility)

    // MARK: - Parsers (confined to parseQueue)

    /// Lua parser — created eagerly at init time (ARCHITECTURE.md §3a).
    private var luaParser: Parser?

    /// JSON parser — created lazily on first JSON source.
    private var jsonParser: Parser?

    /// YAML parser — created lazily on first YAML source.
    private var yamlParser: Parser?

    /// TOML parser — created lazily on first TOML source.
    private var tomlParser: Parser?

    // MARK: - Query (confined to parseQueue)

    /// The compiled Lua highlights query, created once alongside `luaParser`.
    private var luaQuery: Query?

    // MARK: - LRU tree cache (confined to parseQueue)

    /// Maximum number of cached parse trees.
    private static let cacheCapacity = 8

    /// LRU cache entry: the old tree used for incremental re-parse.
    private struct CacheEntry {
        let tree: MutableTree
        let text: String
    }

    /// Ordered list of source IDs in LRU order (most recently used at the end).
    private var cacheOrder: [SourceID] = []

    /// Per-source cached tree from the previous parse.
    private var treeCache: [SourceID: CacheEntry] = [:]

    // MARK: - Init

    /// Creates the Highlighter and eagerly builds the Lua parser + query.
    ///
    /// All parse-executor setup is done asynchronously on `parseQueue` so that
    /// the caller (AppDriver) is never blocked during init.
    public init() {
        parseQueue.async { [weak self] in
            self?.bootstrapLua()
        }
    }

    // MARK: - Public API

    /// Schedule a tree-sitter parse for `id` with the given source `text`.
    ///
    /// Returns immediately; the parse runs on the serial executor.
    /// When done, posts `.highlightReady(id, spans:)` to `channel`.
    ///
    /// - Parameters:
    ///   - id:      The source being highlighted.
    ///   - text:    The Lua source text to parse.
    ///   - channel: The event channel to post the result to.
    public func highlight(
        _ id: SourceID,
        text: String,
        via channel: EventChannel
    ) {
        parseQueue.async { [weak self] in
            guard let self else { return }
            let spans = self.parseAndExtract(id: id, text: text)
            channel.post(.highlightReady(id, spans: spans))
        }
    }

    // MARK: - Bootstrap (parseQueue)

    /// Create the Lua parser and pre-compile the highlights query.
    ///
    /// Called once from init's async block; all subsequent calls to
    /// `parseAndExtract` can reuse the pre-built parser and query.
    private func bootstrapLua() {
        let parser = Parser()
        let lang = Language(language: tree_sitter_lua())
        do {
            try parser.setLanguage(lang)
            luaParser = parser
            luaQuery = try buildLuaQuery(for: lang)
        } catch {
            // If the grammar or query fails to load, Lua sources render
            // unhighlighted — not a fatal error. Log so failures are visible.
            fputs("Highlighter: bootstrap failed: \(error)\n", stderr)
        }
    }

    // MARK: - Parse + extract (parseQueue)

    /// Parse `text` for source `id`, extract highlight spans, and return them.
    ///
    /// Uses the cached tree from the previous parse (if any) for incremental
    /// re-parse. Stores the new tree in the LRU cache.
    private func parseAndExtract(id: SourceID, text: String) -> [HighlightSpan] {
        let format = sourceFormat(for: id)

        switch format {
        case .lua:
            return parseLua(id: id, text: text)
        case .json:
            return parseStructured(id: id, text: text, format: .json)
        case .yaml:
            return parseStructured(id: id, text: text, format: .yaml)
        case .toml:
            return parseStructured(id: id, text: text, format: .toml)
        }
    }

    // MARK: - Lua parse path (parseQueue)

    private func parseLua(id: SourceID, text: String) -> [HighlightSpan] {
        guard let parser = luaParser, let query = luaQuery else { return [] }

        // Always perform a fresh parse. Passing the old tree to ts_parser_parse
        // for incremental re-use requires a precise TSInputEdit describing which
        // byte ranges changed; without it, tree-sitter may reuse stale nodes at
        // wrong positions when lines are inserted or deleted. The LRU cache
        // retains the new tree for potential future use once InputEdit tracking
        // is implemented (ARCHITECTURE.md §2 Highlighter row, incremental note).
        let newTree = parser.parse(text)

        guard let tree = newTree else { return [] }
        storeCacheEntry(CacheEntry(tree: tree, text: text), for: id)

        return extractLuaSpans(query: query, tree: tree, text: text)
    }

    // MARK: - Structured-file parse path (parseQueue)

    private func parseStructured(id: SourceID, text: String, format: ParseFormat) -> [HighlightSpan] {
        let parser: Parser
        do {
            parser = try structuredParser(for: format)
        } catch {
            return []
        }

        // Fresh parse (see parseLua comment on why incremental re-use requires InputEdit).
        let newTree = parser.parse(text)

        guard let tree = newTree else { return [] }
        storeCacheEntry(CacheEntry(tree: tree, text: text), for: id)

        let offsetMap = UTF16ToUTF8ColumnMap(text: text)
        return extractStructuredSpans(tree: tree, text: text, offsetMap: offsetMap)
    }

    // MARK: - Lua span extraction (parseQueue)

    /// Run the highlights query over `tree` and convert each capture to a
    /// `HighlightSpan` using `CaptureMapping`.
    private func extractLuaSpans(query: Query, tree: MutableTree, text: String) -> [HighlightSpan] {
        let offsetMap = UTF16ToUTF8ColumnMap(text: text)
        var spans: [HighlightSpan] = []

        let cursor = query.execute(in: tree)
        for match in cursor {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let token = CaptureMapping.token(for: name)
                if let span = highlightSpan(from: capture.node, token: token, offsetMap: offsetMap) {
                    spans.append(span)
                }
            }
        }

        return spans
    }

    // MARK: - Structured-file span extraction (parseQueue)

    /// Walk the tree for JSON/YAML/TOML and emit spans based on node types.
    ///
    /// The structured-file grammars don't have captures that map cleanly to
    /// the Lua capture vocabulary, so we use a simpler node-type heuristic:
    /// strings → .string, comments → .comment, numbers → .number,
    /// keys → .keyword, booleans/nulls → .keyword, all else → .variable.
    private func extractStructuredSpans(
        tree: MutableTree,
        text: String,
        offsetMap: UTF16ToUTF8ColumnMap
    ) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        guard let root = tree.rootNode else { return [] }
        walkForStructuredSpans(root, offsetMap: offsetMap, spans: &spans)
        return spans
    }

    private func walkForStructuredSpans(
        _ node: Node,
        offsetMap: UTF16ToUTF8ColumnMap,
        spans: inout [HighlightSpan]
    ) {
        let token = structuredToken(for: node.nodeType ?? "")
        if let token, let span = highlightSpan(from: node, token: token, offsetMap: offsetMap) {
            spans.append(span)
        }
        // Recurse into named children.
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            walkForStructuredSpans(child, offsetMap: offsetMap, spans: &spans)
        }
    }

    /// Map a structured-file node type to a ThemeToken, returning nil for
    /// uninteresting container nodes.
    private func structuredToken(for nodeType: String) -> ThemeToken? {
        switch nodeType {
        // Strings
        case "string", "string_content",
            "double_quote_scalar", "single_quote_scalar",
            "string_scalar", "quoted_scalar":
            return .string
        // Comments
        case "comment", "line_comment", "block_comment":
            return .comment
        // Numbers
        case "integer", "float", "number", "integer_scalar", "float_scalar":
            return .number
        // Booleans / null / special keys
        case "true", "false", "null", "boolean_scalar",
            "null_scalar", "boolean":
            return .keyword
        // Keys in mappings / objects
        case "bare_key", "string_key", "key":
            return .keyword
        default:
            return nil
        }
    }

    // MARK: - Span construction helpers (parseQueue)

    /// Build a `HighlightSpan` from a tree-sitter node and offset map.
    ///
    /// Tree-sitter reports column offsets in UTF-16 code units; the offset
    /// map converts them to character (grapheme cluster) counts consistent
    /// with how the Renderer draws the source text.
    private func highlightSpan(
        from node: Node,
        token: ThemeToken,
        offsetMap: UTF16ToUTF8ColumnMap
    ) -> HighlightSpan? {
        let start = node.pointRange.lowerBound
        let end = node.pointRange.upperBound

        let line = Int(start.row)
        let column = offsetMap.utf8Column(utf16Column: Int(start.column), row: line)
        let endColumn = offsetMap.utf8Column(utf16Column: Int(end.column), row: Int(end.row))

        // Multi-line nodes: length is from start to end of the start line only.
        // The Renderer handles multi-line spans by clamping to each line's content.
        let length: Int
        if start.row == end.row {
            length = max(0, endColumn - column)
        } else {
            // Use end-of-start-line length; exact multi-line support is post-P1.
            // Zero-length spans are filtered by the renderer.
            length = max(0, offsetMap.lineLength(row: line) - column)
        }

        guard length > 0 else { return nil }
        return HighlightSpan(line: line, column: column, length: length, tokenKind: token)
    }

    // MARK: - LRU cache management (parseQueue)

    /// Insert or update `entry` for `id`, evicting the least-recently-used
    /// entry when the cache is at capacity.
    private func storeCacheEntry(_ entry: CacheEntry, for id: SourceID) {
        // Remove existing order entry (LRU touch).
        cacheOrder.removeAll { $0 == id }
        // Evict if at capacity.
        if cacheOrder.count >= Highlighter.cacheCapacity,
            let lru = cacheOrder.first
        {
            treeCache.removeValue(forKey: lru)
            cacheOrder.removeFirst()
        }
        treeCache[id] = entry
        cacheOrder.append(id)
    }

    // MARK: - Parser factory (parseQueue, lazy)

    private enum ParseFormat {
        case lua, json, yaml, toml
    }

    private func structuredParser(for format: ParseFormat) throws -> Parser {
        switch format {
        case .json:
            if let p = jsonParser { return p }
            let p = Parser()
            try p.setLanguage(Language(language: tree_sitter_json()))
            jsonParser = p
            return p
        case .yaml:
            if let p = yamlParser { return p }
            let p = Parser()
            try p.setLanguage(Language(language: tree_sitter_yaml()))
            yamlParser = p
            return p
        case .toml:
            if let p = tomlParser { return p }
            let p = Parser()
            try p.setLanguage(Language(language: tree_sitter_toml()))
            tomlParser = p
            return p
        case .lua:
            preconditionFailure("Lua parser is managed separately")
        }
    }

    // MARK: - Format detection (pure)

    private func sourceFormat(for id: SourceID) -> ParseFormat {
        let path = id.path.lowercased()
        if path.hasSuffix(".json") { return .json }
        if path.hasSuffix(".yaml") || path.hasSuffix(".yml") { return .yaml }
        if path.hasSuffix(".toml") { return .toml }
        // Default: Lua (whole .lua files and structured-file fragments all
        // contain Lua code).
        return .lua
    }

    // MARK: - Lua highlights query (parseQueue)

    /// Build the Lua highlights query from the inline S-expression source.
    ///
    /// The query targets the Azganoth tree-sitter-lua v2.1.3 grammar node types.
    /// It uses anonymous nodes for keywords (matching the literal text) so that
    /// all Lua keywords receive the `.keyword` token regardless of which statement
    /// type contains them.
    private func buildLuaQuery(for language: Language) throws -> Query {
        // The query source uses tree-sitter S-expression syntax:
        //   (node_type) @capture_name
        // Anonymous nodes are matched by their literal string: "keyword_text"
        //
        // Reference: ux-spec.md §8.2 capture-name → token mapping.
        let source = """
            (comment) @comment
            (string) @string
            (number) @number

            (true) @constant.builtin
            (false) @constant.builtin
            (nil) @constant.builtin

            "and" @keyword.operator
            "or" @keyword.operator
            "not" @keyword.operator
            "in" @keyword.operator
            ".." @operator
            "+" @operator
            "-" @operator
            "*" @operator
            "/" @operator
            "//" @operator
            "%" @operator
            "^" @operator
            "&" @operator
            "|" @operator
            "~" @operator
            "<<" @operator
            ">>" @operator
            "#" @operator
            "==" @operator
            "~=" @operator
            "<" @operator
            "<=" @operator
            ">" @operator
            ">=" @operator
            "=" @operator
            "," @punctuation.delimiter
            ";" @punctuation.delimiter
            "." @punctuation.delimiter
            ":" @punctuation.delimiter
            "(" @punctuation.bracket
            ")" @punctuation.bracket
            "[" @punctuation.bracket
            "]" @punctuation.bracket
            "{" @punctuation.bracket
            "}" @punctuation.bracket

            "if" @keyword.conditional
            "then" @keyword.conditional
            "else" @keyword.conditional
            "elseif" @keyword.conditional
            "end" @keyword
            "do" @keyword
            "while" @keyword.repeat
            "repeat" @keyword.repeat
            "until" @keyword.repeat
            "for" @keyword.repeat
            (break_statement) @keyword
            "goto" @keyword
            "return" @keyword.return
            "local" @keyword
            "function" @keyword.function

            (label_statement) @label

            (function_definition_statement
              name: (identifier) @function)
            (local_function_definition_statement
              name: (identifier) @function)

            (identifier) @variable
            """

        guard let queryData = source.data(using: .utf8) else {
            throw HighlighterError.queryEncodingFailed
        }
        return try Query(language: language, data: queryData)
    }
}

// MARK: - HighlighterError

/// Errors that can occur during Highlighter setup.
enum HighlighterError: Error {
    case queryEncodingFailed
}

// MARK: - UTF16ToUTF8ColumnMap

/// Per-line mapping from UTF-16 byte offsets to character-count columns.
///
/// SwiftTreeSitter parses strings as UTF-16LE (`TSInputEncodingUTF16LE`) and
/// therefore `TSPoint.column` is a **UTF-16 byte offset** from the start of
/// the row — not a UTF-16 code-unit count and not a byte count in the original
/// UTF-8 source. Each BMP scalar (U+0000–U+FFFF) contributes 2 bytes; each
/// supplementary scalar (U+10000+) contributes 4 bytes (two surrogate pairs).
///
/// `HighlightSpan` uses character-count columns so the Renderer can index into
/// the source string by Swift character index. This map converts between the two.
///
/// Built once per parse call; kept within `parseAndExtract` stack frame so
/// it is never shared across threads.
private struct UTF16ToUTF8ColumnMap {

    /// Lines of the source text, pre-split for O(1) line access.
    private let lines: [Substring]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Convert a UTF-16 byte offset on `row` to a Swift character count.
    ///
    /// Each Unicode scalar contributes `scalar.utf16.count * 2` bytes (2 per
    /// BMP code unit, 4 per surrogate pair). The loop accumulates bytes and
    /// breaks when the byte count reaches `utf16ByteOffset`.
    ///
    /// If `row` is out of range or `utf16ByteOffset` exceeds the line length,
    /// the result is clamped to the line length.
    func utf8Column(utf16Column utf16ByteOffset: Int, row: Int) -> Int {
        guard row < lines.count else { return 0 }
        let line = lines[row]
        var charIdx = 0
        var byteCount = 0
        for scalar in line.unicodeScalars {
            if byteCount >= utf16ByteOffset { break }
            // Each UTF-16 code unit = 2 bytes in the UTF-16LE stream.
            byteCount += scalar.utf16.count * 2
            charIdx += 1
        }
        return charIdx
    }

    /// Return the character count of line `row`, or 0 if out of range.
    func lineLength(row: Int) -> Int {
        guard row < lines.count else { return 0 }
        return lines[row].count
    }
}
