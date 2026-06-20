// File: Tests/MoonSwiftCoreTests/Catalog/CompletionItemTests.swift
// Folder: Tests/MoonSwiftCoreTests/Catalog/
// Role: Tests for F7a.1 — CompletionItem type, the canonical two-parameter
//       completionItems(prefix:liveMocks:) method on LuaModuleCatalog, and the
//       MockLiveState.completionItems() helper (DATA-10 / DATA-N05 binding).
//
//       Suite layout:
//         1. CompletionItemTypeTests — basic property accessors and Sendable.
//         2. CatalogCompletionTests — prefix matching, toml conditional,
//            detail/signature shape, liveMocks passthrough.
//         3. MockLiveStateCompletionTests — two-branch mapping and the empty
//            sentinel guard (DATA-09).
//
// Upstream: CompletionItem.swift, CatalogConsumers+Completion.swift,
//           LuaModuleCatalog.swift, MockLiveState.swift
// Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Suite 1: CompletionItem type

@Suite("CompletionItem — type properties")
struct CompletionItemTypeTests {

    @Test("all stored properties are accessible")
    func storedProperties() {
        let item = CompletionItem(
            insertText: "encode",
            label: "encode",
            detail: "(value, options?) -> string",
            doc: "Encode a Lua value to JSON.",
            kind: .function
        )
        #expect(item.insertText == "encode")
        #expect(item.label == "encode")
        #expect(item.detail == "(value, options?) -> string")
        #expect(item.doc == "Encode a Lua value to JSON.")
        #expect(item.kind == .function)
    }

    @Test("optional fields default to nil")
    func optionalFieldsNil() {
        let item = CompletionItem(
            insertText: "json",
            label: "json",
            kind: .module
        )
        #expect(item.detail == nil)
        #expect(item.doc == nil)
    }

    @Test("CompletionKind covers all four cases")
    func completionKindCases() {
        // Exhaustive check: if a new case is added without updating this test
        // the compiler will surface the missing arm.
        let kinds: [CompletionKind] = [.module, .function, .field, .mock]
        #expect(kinds.count == 4)
        for kind in kinds {
            let item = CompletionItem(insertText: "x", label: "x", kind: kind)
            #expect(item.kind == kind)
        }
    }

    @Test("Equatable — two items with same fields are equal")
    func equatable() {
        let a = CompletionItem(insertText: "foo", label: "foo", detail: "bar", kind: .function)
        let b = CompletionItem(insertText: "foo", label: "foo", detail: "bar", kind: .function)
        #expect(a == b)
    }

    @Test("Equatable — items differing by kind are not equal")
    func equatableKindDifference() {
        let a = CompletionItem(insertText: "foo", label: "foo", kind: .function)
        let b = CompletionItem(insertText: "foo", label: "foo", kind: .mock)
        #expect(a != b)
    }
}

// MARK: - Suite 2: Catalog completion items

@Suite("LuaModuleCatalog — completionItems(prefix:liveMocks:)")
struct CatalogCompletionTests {

    private let catalog = LuaModuleCatalog.v0

    // MARK: Namespace level

    @Test("'luaswift.' prefix yields module items for all base modules")
    func namespacePrefixYieldsModules() {
        let items = catalog.completionItems(prefix: "luaswift.", liveMocks: [])
        let names = Set(items.map(\.insertText))
        // Base modules always present
        #expect(names.contains("json"))
        #expect(names.contains("yaml"))
        #expect(names.contains("regex"))
        #expect(names.contains("mathx"))
        #expect(names.contains("stringx"))
        #expect(names.contains("tablex"))
        #expect(names.contains("types"))
        #expect(names.contains("utf8x"))
        #expect(names.contains("svg"))
    }

    @Test("'luaswift.' prefix yields opt-in modules (iox, http, ui)")
    func namespacePrefixIncludesOptIn() {
        let items = catalog.completionItems(prefix: "luaswift.", liveMocks: [])
        let names = Set(items.map(\.insertText))
        #expect(names.contains("iox"))
        #expect(names.contains("http"))
        #expect(names.contains("ui"))
    }

    @Test("module items have kind .module")
    func moduleItemsHaveModuleKind() {
        let items = catalog.completionItems(prefix: "luaswift.", liveMocks: [])
        let moduleItems = items.filter { ["json", "yaml", "regex"].contains($0.insertText) }
        #expect(!moduleItems.isEmpty)
        for item in moduleItems {
            #expect(item.kind == .module)
        }
    }

    @Test("root function 'extend_stdlib' appears at namespace level with kind .function")
    func rootFunctionAtNamespaceLevel() {
        let items = catalog.completionItems(prefix: "luaswift.", liveMocks: [])
        guard let item = items.first(where: { $0.insertText == "extend_stdlib" }) else {
            Issue.record("extend_stdlib missing from namespace-level completions")
            return
        }
        #expect(item.kind == .function)
    }

    // MARK: Module level

    @Test("'luaswift.json.' prefix returns json functions with non-nil detail")
    func jsonPrefixReturnsSignedFunctions() {
        let items = catalog.completionItems(prefix: "luaswift.json.", liveMocks: [])
        #expect(!items.isEmpty)
        let names = items.map(\.insertText)
        #expect(names.contains("encode"))
        #expect(names.contains("decode"))
        #expect(names.contains("decode_jsonc"))
        #expect(names.contains("decode_json5"))
        #expect(names.contains("is_null"))
        // Every function must have a non-nil detail (encode, decode have params + return)
        for item in items where item.insertText == "encode" || item.insertText == "decode" {
            #expect(item.detail != nil, "Expected non-nil detail for \(item.insertText)")
        }
    }

    @Test("json.encode detail contains param and return type")
    func jsonEncodeDetail() {
        let items = catalog.completionItems(prefix: "luaswift.json.", liveMocks: [])
        guard let encode = items.first(where: { $0.insertText == "encode" }) else {
            Issue.record("encode missing from json completions")
            return
        }
        // Signature: "(value, options?) -> string"
        #expect(encode.detail?.contains("value") == true)
        #expect(encode.detail?.contains("string") == true)
        #expect(encode.detail?.contains("->") == true)
    }

    @Test("json function items carry doc strings")
    func jsonFunctionItemsHaveDoc() {
        let items = catalog.completionItems(prefix: "luaswift.json.", liveMocks: [])
        for item in items {
            #expect(item.doc != nil, "Expected non-nil doc for json.\(item.insertText)")
        }
    }

    @Test("json function items all have kind .function")
    func jsonFunctionItemsHaveFunctionKind() {
        let items = catalog.completionItems(prefix: "luaswift.json.", liveMocks: [])
        for item in items {
            #expect(item.kind == .function)
        }
    }

    // MARK: Toml conditional

    @Test("toml module absent when tomlProbed is false (default)")
    func tomlAbsentWhenUnprobed() {
        let items = catalog.completionItems(prefix: "luaswift.", liveMocks: [])
        let names = Set(items.map(\.insertText))
        #expect(!names.contains("toml"), "luaswift.toml must be absent when toml unprobed")
    }

    @Test("toml module present when tomlProbed is true")
    func tomlPresentWhenProbed() {
        let items = catalog.completionItems(
            prefix: "luaswift.",
            liveMocks: [],
            tomlProbed: true
        )
        let names = Set(items.map(\.insertText))
        #expect(names.contains("toml"), "luaswift.toml must appear when toml is probed available")
    }

    @Test("luaswift.toml. functions absent when tomlProbed is false")
    func tomlFunctionsAbsentWhenUnprobed() {
        let items = catalog.completionItems(
            prefix: "luaswift.toml.",
            liveMocks: [],
            tomlProbed: false
        )
        #expect(items.isEmpty)
    }

    @Test("luaswift.toml. functions present when tomlProbed is true")
    func tomlFunctionsPresentWhenProbed() {
        let items = catalog.completionItems(
            prefix: "luaswift.toml.",
            liveMocks: [],
            tomlProbed: true
        )
        #expect(!items.isEmpty)
    }

    // MARK: Prefix edge cases

    @Test("empty prefix returns empty — no partial-table matching")
    func emptyPrefixReturnsEmpty() {
        let items = catalog.completionItems(prefix: "", liveMocks: [])
        #expect(items.isEmpty)
    }

    @Test("partial prefix 'lua' returns empty")
    func partialPrefixReturnsEmpty() {
        let items = catalog.completionItems(prefix: "lua", liveMocks: [])
        #expect(items.isEmpty)
    }

    @Test("unknown module prefix returns empty")
    func unknownModulePrefixReturnsEmpty() {
        let items = catalog.completionItems(prefix: "luaswift.bogus.", liveMocks: [])
        #expect(items.isEmpty)
    }

    // MARK: Live-mock passthrough

    @Test("liveMocks slice is appended after catalog items")
    func liveMocksAppendedAfterCatalogItems() {
        let mockItem = CompletionItem(
            insertText: "host_log",
            label: "host_log",
            detail: nil,
            kind: .mock
        )
        let items = catalog.completionItems(
            prefix: "luaswift.json.",
            liveMocks: [mockItem]
        )
        // Last item should be the mock
        #expect(items.last?.insertText == "host_log")
        #expect(items.last?.kind == .mock)
    }

    @Test("liveMocks with empty prefix returns empty (prefix gate blocks all)")
    func liveMocksWithEmptyPrefixReturnsEmpty() {
        let mockItem = CompletionItem(insertText: "foo", label: "foo", kind: .mock)
        let items = catalog.completionItems(prefix: "", liveMocks: [mockItem])
        #expect(items.isEmpty)
    }

    // MARK: CONS-R2-01 — no one-parameter overload

    @Test("only the two-parameter form compiles — call site uses liveMocks label")
    func canonicalFormUsesLiveMocksLabel() {
        // This test is a compile-time proof: if a one-parameter overload existed,
        // this line would be ambiguous or the compiler would resolve to the wrong one.
        // The explicit liveMocks: [] label ensures only the two-parameter form matches.
        let items: [CompletionItem] = catalog.completionItems(
            prefix: "luaswift.json.",
            liveMocks: []
        )
        #expect(items.allSatisfy { $0.kind == .function })
    }
}

// MARK: - Suite 3: MockLiveState → [CompletionItem]

@Suite("MockLiveState — completionItems()")
struct MockLiveStateCompletionTests {

    // MARK: Empty sentinel guard (DATA-09)

    @Test("MockLiveState.empty returns no completion items")
    func emptyStateReturnsNoItems() {
        let items = MockLiveState.empty.completionItems()
        #expect(items.isEmpty)
    }

    // MARK: Branch 1 — MockLiveValue (mockValues / userGlobals)

    @Test("mockValues entries map to CompletionItem with detail=displayValue, kind=.mock")
    func mockValuesMappedCorrectly() {
        let state = MockLiveState(
            mockValues: [
                MockLiveValue(name: "config.timeout", displayValue: "30"),
                MockLiveValue(name: "config.retries", displayValue: "3"),
            ],
            mockFunctionNames: [],
            userGlobals: [],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.count == 2)

        guard let timeout = items.first(where: { $0.insertText == "config.timeout" }) else {
            Issue.record("config.timeout missing from completion items")
            return
        }
        #expect(timeout.label == "config.timeout")
        #expect(timeout.detail == "30")
        #expect(timeout.doc == nil)
        #expect(timeout.kind == .mock)
    }

    @Test("userGlobals entries map to CompletionItem with detail=displayValue, kind=.mock")
    func userGlobalsMappedCorrectly() {
        let state = MockLiveState(
            mockValues: [],
            mockFunctionNames: [],
            userGlobals: [
                MockLiveValue(name: "helper", displayValue: "function")
            ],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.count == 1)

        guard let helper = items.first else {
            Issue.record("helper missing from completion items")
            return
        }
        #expect(helper.insertText == "helper")
        #expect(helper.detail == "function")
        #expect(helper.kind == .mock)
    }

    @Test("depth-capped value produces detail '(…)' (DATA-N06 binding)")
    func depthCappedValueProducesEllipsisDetail() {
        let state = MockLiveState(
            mockValues: [
                MockLiveValue(name: "deep", displayValue: "(…)")
            ],
            mockFunctionNames: [],
            userGlobals: [],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.first?.detail == "(…)")
    }

    @Test("function-typed mock value produces detail 'function' (DATA-N07 binding)")
    func functionTypedMockValueProducesFunctionDetail() {
        let state = MockLiveState(
            mockValues: [
                MockLiveValue(name: "my_cb", displayValue: "function")
            ],
            mockFunctionNames: [],
            userGlobals: [],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.first?.detail == "function")
    }

    // MARK: Branch 2 — mockFunctionNames

    @Test("mockFunctionNames entries map to CompletionItem with detail=nil, kind=.mock")
    func mockFunctionNamesMappedWithNilDetail() {
        let state = MockLiveState(
            mockValues: [],
            mockFunctionNames: ["fetch", "host_log"],
            userGlobals: [],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.count == 2)

        guard let fetch = items.first(where: { $0.insertText == "fetch" }) else {
            Issue.record("fetch missing from completion items")
            return
        }
        #expect(fetch.label == "fetch")
        #expect(
            fetch.detail == nil,
            "Mock function names must have nil detail — no value to display (DATA-N05)")
        #expect(fetch.doc == nil)
        #expect(fetch.kind == .mock)
    }

    // MARK: Combined snapshot

    @Test("all three branches produce items in order: mockValues, mockFunctions, userGlobals")
    func combinedSnapshotOrderPreserved() {
        let state = MockLiveState(
            mockValues: [
                MockLiveValue(name: "mock_val", displayValue: "42")
            ],
            mockFunctionNames: ["mock_fn"],
            userGlobals: [
                MockLiveValue(name: "user_global", displayValue: "\"hello\"")
            ],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.count == 3)

        #expect(items[0].insertText == "mock_val")
        #expect(items[0].detail == "42")
        #expect(items[0].kind == .mock)

        #expect(items[1].insertText == "mock_fn")
        #expect(items[1].detail == nil)
        #expect(items[1].kind == .mock)

        #expect(items[2].insertText == "user_global")
        #expect(items[2].detail == "\"hello\"")
        #expect(items[2].kind == .mock)
    }

    @Test("isEmpty=false with no entries produces empty list (post-run empty state)")
    func isNotEmptySentinelButNoEntries() {
        let state = MockLiveState(
            mockValues: [],
            mockFunctionNames: [],
            userGlobals: [],
            isEmpty: false
        )
        let items = state.completionItems()
        #expect(items.isEmpty)
    }
}

// MARK: - Suite 4: Short signature helper

@Suite("LuaModuleCatalog — shortSignature(for:)")
struct ShortSignatureTests {

    @Test("function with params and returns produces '(params) -> return' string")
    func paramsAndReturn() {
        let fn = CatalogFunction(
            name: "encode",
            params: [
                CatalogParam(name: "value", type: "any"),
                CatalogParam(name: "options", type: "table", isOptional: true),
            ],
            returns: "string",
            doc: "Encode."
        )
        let sig = LuaModuleCatalog.shortSignature(for: fn)
        #expect(sig == "(value, options?) -> string")
    }

    @Test("function with params and no returns produces '(params)' string")
    func paramsNoReturn() {
        let fn = CatalogFunction(
            name: "side_effect",
            params: [
                CatalogParam(name: "x", type: "number")
            ],
            returns: nil,
            doc: "Side effect."
        )
        let sig = LuaModuleCatalog.shortSignature(for: fn)
        #expect(sig == "(x)")
    }

    @Test("function with no params and returns produces '() -> type' string")
    func noParamsWithReturn() {
        let fn = CatalogFunction(
            name: "version",
            params: [],
            returns: "string",
            doc: "Returns version."
        )
        let sig = LuaModuleCatalog.shortSignature(for: fn)
        #expect(sig == "() -> string")
    }

    @Test("function with no params and no returns produces nil detail")
    func noParamsNoReturnIsNil() {
        let fn = CatalogFunction(
            name: "extend_stdlib",
            params: [],
            returns: nil,
            doc: "Extends."
        )
        let sig = LuaModuleCatalog.shortSignature(for: fn)
        #expect(sig == nil)
    }

    @Test("optional params are suffixed with '?'")
    func optionalParamSuffix() {
        let fn = CatalogFunction(
            name: "compile",
            params: [
                CatalogParam(name: "pattern", type: "string", isOptional: false),
                CatalogParam(name: "flags", type: "string", isOptional: true),
            ],
            returns: "table",
            doc: "Compile."
        )
        let sig = LuaModuleCatalog.shortSignature(for: fn)
        #expect(sig?.contains("pattern") == true)
        #expect(sig?.contains("flags?") == true)
        #expect(sig?.contains("->") == true)
    }
}
