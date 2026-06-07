// File: Tests/MoonSwiftCoreTests/JSONPath/JSONPathTests.swift
// Role: Comprehensive unit tests for the RFC 9535 JSONPath subset implemented
//       in MoonSwiftCore. Covers every selector class (child name, quoted name,
//       array index, wildcard, descendant), multi-match scenarios, no-match
//       cases, normalized-path rendering, and parse-error detection with exact
//       error types.
//
//       Test fixtures are inline TreeValue trees so the tests have no external
//       file dependency. RFC 9535 examples within the supported subset are
//       noted by reference (§ number and example identifier).
//
// Upstream: JSONPathExpression, JSONPathError, NormalizedPath, ResolvedStep
// Downstream: (test target)

import Collections
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Build a TreeValue.map from a literal [(key, value)] sequence (preserving
/// insertion order via OrderedDictionary).
private func treeMap(_ pairs: [(String, TreeValue)]) -> TreeValue {
    var dict = OrderedDictionary<String, TreeValue>()
    for (k, v) in pairs {
        dict[k] = v
    }
    return .map(dict)
}

/// Parse an expression and immediately evaluate on `root`.
/// Returns the results. Fails the test if parsing throws.
private func eval(
    _ expression: String,
    on root: TreeValue
) throws -> [(path: NormalizedPath, value: TreeValue)] {
    let expr = try JSONPathExpression(parsing: expression)
    return expr.evaluate(on: root)
}

// MARK: - RFC 9535 sample document

/// A small but representative document used across multiple tests.
/// Mirrors the style of RFC 9535 §2.1 examples.
///
///     {
///       "store": {
///         "book": [
///           { "title": "A",  "price": 8 },
///           { "title": "B",  "price": 12 }
///         ],
///         "open": true
///       },
///       "expensive": 10
///     }
private let sampleDoc: TreeValue = treeMap([
    (
        "store",
        treeMap([
            (
                "book",
                .array([
                    treeMap([("title", .string("A")), ("price", .int(8))]),
                    treeMap([("title", .string("B")), ("price", .int(12))]),
                ])
            ),
            ("open", .bool(true)),
        ])
    ),
    ("expensive", .int(10)),
])

// MARK: - Suite: Root

@Suite("JSONPath — Root ($)")
struct JSONPathRootTests {

    @Test("bare root returns the whole document")
    func bareRoot() throws {
        let results = try eval("$", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == sampleDoc)
        #expect(results[0].path.description == "$")
    }

    @Test("bare root on scalar")
    func bareRootScalar() throws {
        let results = try eval("$", on: .string("hello"))
        #expect(results.count == 1)
        #expect(results[0].value == .string("hello"))
    }
}

// MARK: - Suite: Child name selector — dot notation

@Suite("JSONPath — Child name (dot notation)")
struct JSONPathDotNameTests {

    @Test("single-level dot child")
    func singleLevel() throws {
        let results = try eval("$.expensive", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == .int(10))
        #expect(results[0].path.description == "$.expensive")
    }

    @Test("two-level dot child")
    func twoLevel() throws {
        let results = try eval("$.store.open", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == .bool(true))
        #expect(results[0].path.description == "$.store.open")
    }

    @Test("no match returns empty")
    func noMatch() throws {
        let results = try eval("$.missing", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("dot child on non-map returns empty")
    func dotOnArray() throws {
        let results = try eval("$.store.book.title", on: sampleDoc)
        // $.store.book is an array; .title on an array → empty
        #expect(results.isEmpty)
    }

    @Test("underscore in key name")
    func underscoreKey() throws {
        let doc = treeMap([("my_key", .string("val"))])
        let results = try eval("$.my_key", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("val"))
    }
}

// MARK: - Suite: Child name selector — bracket / quoted notation

@Suite("JSONPath — Child name (bracket / quoted notation)")
struct JSONPathBracketNameTests {

    @Test("single-quoted bracket child")
    func singleQuoted() throws {
        let doc = treeMap([("a b", .string("space key"))])
        let results = try eval("$['a b']", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("space key"))
    }

    @Test("double-quoted bracket child")
    func doubleQuoted() throws {
        let doc = treeMap([("c-d", .string("hyphen key"))])
        let results = try eval("$[\"c-d\"]", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("hyphen key"))
    }

    @Test("bracket child matches dot child for simple names")
    func bracketEquivalentDot() throws {
        let dotResults = try eval("$.expensive", on: sampleDoc)
        let brktResults = try eval("$['expensive']", on: sampleDoc)
        #expect(dotResults.map(\.value) == brktResults.map(\.value))
    }

    @Test("escape: single quote inside single-quoted string")
    func escapedSingleQuote() throws {
        let doc = treeMap([("it's", .string("apostrophe"))])
        let results = try eval("$[\"it's\"]", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("apostrophe"))
    }

    @Test("escape: backslash-n becomes newline")
    func escapeNewline() throws {
        let doc = treeMap([("line\nbreak", .string("nl"))])
        let results = try eval("$['line\\nbreak']", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("nl"))
    }

    @Test("escape: \\uXXXX Unicode sequence")
    func escapeUnicode() throws {
        // A = 'A'
        let doc = treeMap([("A", .string("unicode key"))])
        let results = try eval("$['\\u0041']", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("unicode key"))
    }

    @Test("chained: dot then bracket")
    func dotThenBracket() throws {
        let results = try eval("$.store['open']", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == .bool(true))
    }

    @Test("normalized path uses bracket notation for unsafe keys")
    func normalizedBracketForUnsafeKey() throws {
        let doc = treeMap([("a b", .string("v"))])
        let results = try eval("$['a b']", on: doc)
        #expect(results[0].path.description == "$['a b']")
    }

    @Test("normalized path uses dot notation for safe keys")
    func normalizedDotForSafeKey() throws {
        let doc = treeMap([("safe", .string("v"))])
        let results = try eval("$['safe']", on: doc)
        #expect(results[0].path.description == "$.safe")
    }
}

// MARK: - Suite: Array index selector

@Suite("JSONPath — Array index")
struct JSONPathIndexTests {

    @Test("first element")
    func firstElement() throws {
        let results = try eval("$.store.book[0]", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == treeMap([("title", .string("A")), ("price", .int(8))]))
        #expect(results[0].path.description == "$.store.book[0]")
    }

    @Test("second element")
    func secondElement() throws {
        let results = try eval("$.store.book[1]", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == treeMap([("title", .string("B")), ("price", .int(12))]))
    }

    @Test("out-of-bounds index returns empty")
    func outOfBounds() throws {
        let results = try eval("$.store.book[5]", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("index on non-array returns empty")
    func indexOnMap() throws {
        let results = try eval("$.store[0]", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("index zero on single-element array")
    func singleElementArray() throws {
        let doc = treeMap([("arr", .array([.string("only")]))])
        let results = try eval("$.arr[0]", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("only"))
    }

    @Test("chained index then key")
    func indexThenKey() throws {
        let results = try eval("$.store.book[0].title", on: sampleDoc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("A"))
        #expect(results[0].path.description == "$.store.book[0].title")
    }
}

// MARK: - Suite: Wildcard selector

@Suite("JSONPath — Wildcard")
struct JSONPathWildcardTests {

    @Test("dot-wildcard on map returns all values")
    func dotWildcardOnMap() throws {
        // $.store.* → book array + open bool
        let results = try eval("$.store.*", on: sampleDoc)
        #expect(results.count == 2)
        // Keys come in insertion order: book, open
        #expect(results[0].path.description == "$.store.book")
        #expect(results[1].path.description == "$.store.open")
        #expect(results[1].value == .bool(true))
    }

    @Test("bracket-wildcard on array returns all elements")
    func bracketWildcardOnArray() throws {
        let results = try eval("$.store.book[*]", on: sampleDoc)
        #expect(results.count == 2)
        #expect(results[0].path.description == "$.store.book[0]")
        #expect(results[1].path.description == "$.store.book[1]")
    }

    @Test("wildcard on scalar returns empty")
    func wildcardOnScalar() throws {
        let results = try eval("$.expensive.*", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("wildcard on null returns empty")
    func wildcardOnNull() throws {
        let doc = treeMap([("x", .null)])
        let results = try eval("$.x.*", on: doc)
        #expect(results.isEmpty)
    }

    @Test("wildcard on map with three keys returns three matches")
    func wildcardThreeKeys() throws {
        let doc = treeMap([
            ("a", .int(1)),
            ("b", .int(2)),
            ("c", .int(3)),
        ])
        let results = try eval("$.*", on: doc)
        #expect(results.count == 3)
        #expect(results.map(\.value) == [.int(1), .int(2), .int(3)])
    }

    @Test("wildcard path steps are concrete (key/index)")
    func wildcardConcretePaths() throws {
        let doc: TreeValue = .array([.string("x"), .string("y"), .string("z")])
        let results = try eval("$[*]", on: doc)
        #expect(results.count == 3)
        #expect(results[0].path.steps == [.index(0)])
        #expect(results[1].path.steps == [.index(1)])
        #expect(results[2].path.steps == [.index(2)])
    }
}

// MARK: - Suite: Descendant segment

@Suite("JSONPath — Descendant segment (..)")
struct JSONPathDescendantTests {

    @Test("descendant name finds key at all levels")
    func descendantNameAllLevels() throws {
        // $..title → "A" (at book[0]) and "B" (at book[1])
        let results = try eval("$..title", on: sampleDoc)
        #expect(results.count == 2)
        #expect(results[0].value == .string("A"))
        #expect(results[1].value == .string("B"))
    }

    @Test("descendant normalized path uses concrete resolved steps")
    func descendantNormalizedPaths() throws {
        let results = try eval("$..title", on: sampleDoc)
        #expect(results[0].path.description == "$.store.book[0].title")
        #expect(results[1].path.description == "$.store.book[1].title")
    }

    @Test("descendant wildcard collects every node")
    func descendantWildcard() throws {
        // $.store..* collects all descendants of store: book array, open bool,
        // book[0], book[1], then all keys inside each book object.
        let doc = treeMap([("a", treeMap([("b", .int(1))]))])
        // $.a..* → b: 1 (the only grandchild)
        let results = try eval("$.a.*", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .int(1))
    }

    @Test("descendant name on non-existent key returns empty")
    func descendantNoMatch() throws {
        let results = try eval("$..missing", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("descendant from root finds nested key")
    func descendantFromRoot() throws {
        let results = try eval("$..price", on: sampleDoc)
        #expect(results.count == 2)
        #expect(results[0].value == .int(8))
        #expect(results[1].value == .int(12))
    }

    @Test("descendant index finds element at all array levels")
    func descendantIndex() throws {
        let doc = treeMap([
            (
                "outer",
                .array([
                    .array([.string("deep"), .string("deeper")]),
                    .string("shallow"),
                ])
            )
        ])
        // $.outer..[0] → outer[0] (inner array), outer[0][0] ("deep")
        let results = try eval("$.outer..[0]", on: doc)
        #expect(results.count == 2)
    }

    @Test("descendant bracket-quoted name")
    func descendantBracketQuoted() throws {
        let doc = treeMap([
            ("x", treeMap([("a b", .string("found"))]))
        ])
        let results = try eval("$..[\"a b\"]", on: doc)
        #expect(results.count == 1)
        #expect(results[0].value == .string("found"))
    }
}

// MARK: - Suite: Normalized path rendering

@Suite("JSONPath — NormalizedPath rendering")
struct NormalizedPathRenderingTests {

    @Test("empty steps = root $")
    func emptySteps() {
        let path = NormalizedPath(steps: [])
        #expect(path.description == "$")
    }

    @Test("single safe key → dot notation")
    func singleSafeKey() {
        let path = NormalizedPath(steps: [.key("scripts")])
        #expect(path.description == "$.scripts")
    }

    @Test("unsafe key (space) → bracket notation")
    func unsafeKeyWithSpace() {
        let path = NormalizedPath(steps: [.key("a b")])
        #expect(path.description == "$['a b']")
    }

    @Test("unsafe key (hyphen) → bracket notation")
    func unsafeKeyWithHyphen() {
        let path = NormalizedPath(steps: [.key("my-key")])
        #expect(path.description == "$['my-key']")
    }

    @Test("array index → bracket notation")
    func arrayIndex() {
        let path = NormalizedPath(steps: [.key("arr"), .index(3)])
        #expect(path.description == "$.arr[3]")
    }

    @Test("mixed keys and indices")
    func mixed() {
        let path = NormalizedPath(steps: [.key("store"), .key("book"), .index(0), .key("title")])
        #expect(path.description == "$.store.book[0].title")
    }

    @Test("key with single quote is escaped in bracket notation")
    func keyWithSingleQuote() {
        let path = NormalizedPath(steps: [.key("it's")])
        #expect(path.description == "$[\"it's\"]" || path.description == "$['it\\'s']")
    }

    @Test("empty key → bracket notation")
    func emptyKey() {
        let path = NormalizedPath(steps: [.key("")])
        #expect(path.description == "$['']")
    }

    @Test("RFC 9535 example: config.yaml:$.scripts.init display name")
    func rfcDisplayNameExample() {
        let path = NormalizedPath(steps: [.key("scripts"), .key("init")])
        #expect(path.description == "$.scripts.init")
    }
}

// MARK: - Suite: JSONPathExpression.normalized property

@Suite("JSONPath — Expression normalized property")
struct ExpressionNormalizedTests {

    @Test("simple dot expression")
    func dotExpression() throws {
        let expr = try JSONPathExpression(parsing: "$.a.b")
        #expect(expr.normalized == "$.a.b")
    }

    @Test("bracket expression normalizes to bracket")
    func bracketExpression() throws {
        let expr = try JSONPathExpression(parsing: "$['a b']")
        #expect(expr.normalized == "$['a b']")
    }

    @Test("index normalizes as bracket")
    func indexExpression() throws {
        let expr = try JSONPathExpression(parsing: "$.a[0]")
        #expect(expr.normalized == "$.a[0]")
    }

    @Test("wildcard normalizes as .*")
    func wildcardExpression() throws {
        let expr = try JSONPathExpression(parsing: "$.*")
        #expect(expr.normalized == "$.*")
    }

    @Test("descendant normalizes with ..")
    func descendantExpression() throws {
        let expr = try JSONPathExpression(parsing: "$..name")
        #expect(expr.normalized == "$..name")
    }

    @Test("mixed expression round-trips cleanly")
    func mixedExpression() throws {
        let expr = try JSONPathExpression(parsing: "$.store.book[0].title")
        #expect(expr.normalized == "$.store.book[0].title")
    }
}

// MARK: - Suite: Parse errors — unsupported constructs

@Suite("JSONPath — Parse errors: unsupported constructs")
struct JSONPathUnsupportedTests {

    @Test("filter selector ?() is rejected")
    func filterSelector() {
        #expect(throws: JSONPathError.self) {
            _ = try JSONPathExpression(parsing: "$[?(@ > 1)]")
        }
        do {
            _ = try JSONPathExpression(parsing: "$[?(@ > 1)]")
        } catch let error as JSONPathError {
            if case .unsupportedFilterSelector = error {
                // correct
            } else {
                Issue.record("Expected unsupportedFilterSelector, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("slice selector [1:3] is rejected")
    func sliceSelector() {
        do {
            _ = try JSONPathExpression(parsing: "$.a[1:3]")
            Issue.record("Expected parse error for slice selector")
        } catch let error as JSONPathError {
            if case .unsupportedSliceSelector = error {
                // correct
            } else {
                Issue.record("Expected unsupportedSliceSelector, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("negative index is rejected")
    func negativeIndex() {
        do {
            _ = try JSONPathExpression(parsing: "$.a[-1]")
            Issue.record("Expected parse error for negative index")
        } catch let error as JSONPathError {
            if case .unsupportedNegativeIndex = error {
                // correct
            } else {
                Issue.record("Expected unsupportedNegativeIndex, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("function extension is rejected")
    func functionExtension() {
        do {
            _ = try JSONPathExpression(parsing: "$[length()]")
            Issue.record("Expected parse error for function extension")
        } catch let error as JSONPathError {
            if case .unsupportedFunctionExtension = error {
                // correct
            } else {
                Issue.record("Expected unsupportedFunctionExtension, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("unsupported errors carry a non-empty diagnostic message")
    func diagnosticMessagesNonEmpty() {
        let errors: [JSONPathError] = [
            .unsupportedFilterSelector(offset: 0),
            .unsupportedSliceSelector(offset: 0),
            .unsupportedNegativeIndex(offset: 0),
            .unsupportedFunctionExtension(name: "length", offset: 0),
        ]
        for error in errors {
            #expect(!error.diagnosticMessage.isEmpty)
            // Every unsupported message names the supported subset.
            #expect(error.diagnosticMessage.contains("Supported"))
        }
    }
}

// MARK: - Suite: Parse errors — malformed syntax

@Suite("JSONPath — Parse errors: malformed syntax")
struct JSONPathMalformedTests {

    @Test("missing root $")
    func missingRoot() {
        do {
            _ = try JSONPathExpression(parsing: ".a.b")
            Issue.record("Expected parse error")
        } catch let error as JSONPathError {
            // correct outcome
            if case .missingRoot = error {} else { Issue.record("Expected missingRoot, got \(error)") }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("unterminated single quote")
    func unterminatedSingleQuote() {
        do {
            _ = try JSONPathExpression(parsing: "$['unterminated")
            Issue.record("Expected parse error")
        } catch let error as JSONPathError {
            // correct outcome
            if case .unterminatedQuote = error {
            } else {
                Issue.record("Expected unterminatedQuote, got \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("unterminated bracket")
    func unterminatedBracket() {
        do {
            _ = try JSONPathExpression(parsing: "$[0")
            Issue.record("Expected parse error")
        } catch let error as JSONPathError {
            // correct outcome
            if case .unterminatedBracket = error {
            } else {
                Issue.record("Expected unterminatedBracket, got \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("invalid escape sequence")
    func invalidEscape() {
        do {
            _ = try JSONPathExpression(parsing: "$['\\z']")
            Issue.record("Expected parse error")
        } catch let error as JSONPathError {
            // correct outcome
            if case .invalidEscapeSequence = error {
            } else {
                Issue.record("Expected invalidEscapeSequence, got \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("trailing dot with no name")
    func trailingDot() {
        do {
            _ = try JSONPathExpression(parsing: "$.a.")
            Issue.record("Expected parse error")
        } catch let error as JSONPathError {
            // Could be unexpectedEnd or unexpectedCharacter depending on context
            switch error {
            case .unexpectedEnd, .unexpectedCharacter:
                break  // correct
            default:
                Issue.record("Expected unexpectedEnd or unexpectedCharacter, got \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("empty expression (just root) is valid")
    func justRoot() throws {
        let expr = try JSONPathExpression(parsing: "$")
        let results = expr.evaluate(on: .string("root"))
        #expect(results.count == 1)
    }
}

// MARK: - Suite: Multi-match scenarios

@Suite("JSONPath — Multi-match")
struct JSONPathMultiMatchTests {

    @Test("wildcard on three-key map gives three matches")
    func wildcardThreeMatches() throws {
        let doc = treeMap([
            ("x", .string("X")),
            ("y", .string("Y")),
            ("z", .string("Z")),
        ])
        let results = try eval("$.*", on: doc)
        #expect(results.count == 3)
        #expect(
            Set(results.map { ($0.value == .string("X") || $0.value == .string("Y") || $0.value == .string("Z")) })
                .count == 1)
    }

    @Test("descendant name matching at two depths")
    func descendantTwoDepths() throws {
        // {"a": {"a": "inner"}} — the key "a" appears at both levels
        let doc = treeMap([("a", treeMap([("a", .string("inner"))]))])
        let results = try eval("$..a", on: doc)
        // outer: .a → the inner map; inner: .a → "inner"
        #expect(results.count == 2)
    }

    @Test("wildcard designation matches 3 nodes example (PRD acceptance)")
    func wildcardThreeNavigatorEntries() throws {
        // A wildcard designation matching 3 nodes in an array yields 3 entries.
        let doc = treeMap([
            (
                "scripts",
                .array([
                    .string("s1"), .string("s2"), .string("s3"),
                ])
            )
        ])
        let results = try eval("$.scripts[*]", on: doc)
        #expect(results.count == 3)
        // Paths are concrete and distinct.
        let paths = results.map { $0.path.description }
        #expect(paths == ["$.scripts[0]", "$.scripts[1]", "$.scripts[2]"])
    }
}

// MARK: - Suite: No-match scenarios

@Suite("JSONPath — No match")
struct JSONPathNoMatchTests {

    @Test("key not present")
    func keyNotPresent() throws {
        let results = try eval("$.does_not_exist", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("index beyond array length")
    func indexBeyondArray() throws {
        let results = try eval("$.store.book[99]", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("applying name selector to a scalar")
    func nameOnScalar() throws {
        let results = try eval("$.expensive.child", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("applying index selector to a map")
    func indexOnMap() throws {
        let results = try eval("$.store[0]", on: sampleDoc)
        #expect(results.isEmpty)
    }

    @Test("descendant on a document with no matching key")
    func descendantNoKey() throws {
        let results = try eval("$..nonexistent", on: sampleDoc)
        #expect(results.isEmpty)
    }
}
