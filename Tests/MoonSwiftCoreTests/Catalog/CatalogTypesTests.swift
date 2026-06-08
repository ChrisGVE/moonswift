// File: Tests/MoonSwiftCoreTests/Catalog/CatalogTypesTests.swift
// Folder: Tests/MoonSwiftCoreTests/Catalog/
// Role: Unit tests for the value types in CatalogTypes.swift —
//       CatalogFunction (both initialisers), CatalogParam, CatalogModule,
//       GeneratedFile, and ModuleAvailability. These types are mostly exercised
//       indirectly via LuaModuleCatalogTests, but the full (P3a) initialisers
//       and the GeneratedFile type are never touched by catalog v0, so they
//       require direct tests to move their coverage into the measured range.
//
// Upstream: MoonSwiftCore/Catalog/CatalogTypes.swift
// Downstream: (test target — nothing imports this)

import Testing

@testable import MoonSwiftCore

// MARK: - CatalogFunction

@Suite("CatalogFunction — initialisers")
struct CatalogFunctionInitTests {

    // MARK: Convenience (P1) initialiser

    @Test("convenience init sets name and leaves optional fields nil/empty")
    func convenienceInit() {
        let fn = CatalogFunction(name: "decode")
        #expect(fn.name == "decode")
        #expect(fn.params.isEmpty)
        #expect(fn.returns == nil)
        #expect(fn.doc == nil)
    }

    // MARK: Full (P3a) initialiser

    @Test("full init with all fields stores every value")
    func fullInitAllFields() {
        let param = CatalogParam(name: "input", type: "string", isOptional: false)
        let fn = CatalogFunction(
            name: "encode",
            params: [param],
            returns: "string",
            doc: "Encodes a value to JSON."
        )
        #expect(fn.name == "encode")
        #expect(fn.params.count == 1)
        #expect(fn.params[0].name == "input")
        #expect(fn.returns == "string")
        #expect(fn.doc == "Encodes a value to JSON.")
    }

    @Test("full init with default params is equivalent to name-only construction")
    func fullInitDefaults() {
        let full = CatalogFunction(name: "decode", params: [], returns: nil, doc: nil)
        let convenience = CatalogFunction(name: "decode")
        #expect(full.name == convenience.name)
        #expect(full.params.count == convenience.params.count)
        #expect(full.returns == convenience.returns)
        #expect(full.doc == convenience.doc)
    }

    @Test("full init with nil returns is distinct from an empty-string return")
    func fullInitNilVsEmptyReturns() {
        let nilReturns = CatalogFunction(name: "f", params: [], returns: nil, doc: nil)
        let emptyReturns = CatalogFunction(name: "f", params: [], returns: "", doc: nil)
        #expect(nilReturns.returns == nil)
        #expect(emptyReturns.returns == "")
    }

    @Test("full init preserves multiple parameters in order")
    func fullInitMultipleParams() {
        let p1 = CatalogParam(name: "key", type: "string")
        let p2 = CatalogParam(name: "value", type: "number|string", isOptional: true)
        let fn = CatalogFunction(name: "set", params: [p1, p2])
        #expect(fn.params.count == 2)
        #expect(fn.params[0].name == "key")
        #expect(fn.params[1].name == "value")
        #expect(fn.params[1].isOptional)
    }
}

// MARK: - CatalogParam

@Suite("CatalogParam — initialiser")
struct CatalogParamInitTests {

    @Test("init with name only leaves type nil and isOptional false")
    func nameOnly() {
        let p = CatalogParam(name: "src")
        #expect(p.name == "src")
        #expect(p.type == nil)
        #expect(!p.isOptional)
    }

    @Test("init with explicit type and isOptional true stores both")
    func withTypeAndOptional() {
        let p = CatalogParam(name: "flags", type: "table", isOptional: true)
        #expect(p.name == "flags")
        #expect(p.type == "table")
        #expect(p.isOptional)
    }

    @Test("init with union type string is stored verbatim")
    func unionType() {
        let p = CatalogParam(name: "x", type: "number|string")
        #expect(p.type == "number|string")
    }

    @Test("init with nil type is distinct from an empty-string type")
    func nilVsEmptyType() {
        let nilType = CatalogParam(name: "v", type: nil)
        let emptyType = CatalogParam(name: "v", type: "")
        #expect(nilType.type == nil)
        #expect(emptyType.type == "")
    }
}

// MARK: - GeneratedFile

@Suite("GeneratedFile — initialiser")
struct GeneratedFileInitTests {

    @Test("init stores relativePath and content verbatim")
    func storesFields() {
        let file = GeneratedFile(
            relativePath: ".luarc/meta/luaswift.json.lua",
            content: "---@class luaswift.json\n"
        )
        #expect(file.relativePath == ".luarc/meta/luaswift.json.lua")
        #expect(file.content == "---@class luaswift.json\n")
    }

    @Test("init with empty content stores empty string")
    func emptyContent() {
        let file = GeneratedFile(relativePath: "meta/empty.lua", content: "")
        #expect(file.content == "")
        #expect(file.relativePath == "meta/empty.lua")
    }

    @Test("init with multi-line content preserves newlines")
    func multiLineContent() {
        let content = "line1\nline2\nline3\n"
        let file = GeneratedFile(relativePath: "out.lua", content: content)
        #expect(file.content == content)
        #expect(file.content.components(separatedBy: "\n").count == 4)
    }
}

// MARK: - ModuleAvailability

@Suite("ModuleAvailability — equality and hashability")
struct ModuleAvailabilityTests {

    @Test("each case equals itself")
    func selfEquality() {
        #expect(ModuleAvailability.base == .base)
        #expect(ModuleAvailability.conditional == .conditional)
        #expect(ModuleAvailability.optIn == .optIn)
        #expect(ModuleAvailability.compileFlagGated == .compileFlagGated)
    }

    @Test("different cases are not equal")
    func crossCaseInequality() {
        #expect(ModuleAvailability.base != .conditional)
        #expect(ModuleAvailability.base != .optIn)
        #expect(ModuleAvailability.base != .compileFlagGated)
        #expect(ModuleAvailability.conditional != .optIn)
    }

    @Test("all four cases can be collected in a Set (Hashable)")
    func hashableInSet() {
        let set: Set<ModuleAvailability> = [.base, .conditional, .optIn, .compileFlagGated]
        #expect(set.count == 4)
        #expect(set.contains(.base))
        #expect(set.contains(.compileFlagGated))
    }
}
