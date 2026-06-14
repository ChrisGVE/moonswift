// File: Tests/MoonSwiftCoreTests/Catalog/MetaFileGeneratorTests.swift
// Location: MoonSwiftCoreTests/Catalog/
// Role: Tests for the F7b LuaLS meta-file generator (MetaFileGenerator) and the
//       catalog consumer luaLSMetaFiles(). Verifies ---@meta structure, @param/
//       @return/doc annotations, dotted-name subtable declarations, optional
//       params, and the .luarc.json shape (runtime.version + workspace.library).
// Upstream: MetaFileGenerator, LuaModuleCatalog.luaLSMetaFiles()

import Foundation
import Testing

@testable import MoonSwiftCore

@Suite("F7b — MetaFileGenerator")
struct MetaFileGeneratorTests {

    @Test("a module meta file opens with ---@meta and declares its class table")
    func metaHeaderAndTable() {
        let module = CatalogModule(
            tableName: "json",
            functions: [CatalogFunction(name: "encode")],
            availability: .base
        )
        let file = MetaFileGenerator.metaFile(for: module)
        #expect(file.relativePath == "meta/luaswift.json.lua")
        #expect(file.content.hasPrefix("---@meta"))
        #expect(file.content.contains("---@class luaswift.json"))
        #expect(file.content.contains("luaswift.json = {}"))
        #expect(file.content.contains("function luaswift.json.encode() end"))
    }

    @Test("the root module declares the bare luaswift global")
    func rootTable() {
        let root = CatalogModule(tableName: "", functions: [], availability: .base)
        let file = MetaFileGenerator.metaFile(for: root)
        #expect(file.relativePath == "meta/luaswift.lua")
        #expect(file.content.contains("luaswift = {}"))
    }

    @Test("function annotations carry @param (with optional ?), @return, and doc")
    func functionAnnotations() {
        let module = CatalogModule(
            tableName: "stringx",
            functions: [
                CatalogFunction(
                    name: "split",
                    params: [
                        CatalogParam(name: "s", type: "string"),
                        CatalogParam(name: "sep", type: "string", isOptional: true),
                    ],
                    returns: "table",
                    doc: "Split a string."
                )
            ],
            availability: .base
        )
        let content = MetaFileGenerator.metaFile(for: module).content
        #expect(content.contains("---Split a string."))
        #expect(content.contains("---@param s string"))
        #expect(content.contains("---@param sep? string"))
        #expect(content.contains("---@return table"))
        #expect(content.contains("function luaswift.stringx.split(s, sep) end"))
    }

    @Test("a dotted function name declares its intermediate subtable")
    func dottedFunctionSubtable() {
        let module = CatalogModule(
            tableName: "iox",
            functions: [
                CatalogFunction(
                    name: "path.join",
                    params: [CatalogParam(name: "a"), CatalogParam(name: "b")],
                    returns: "string"
                )
            ],
            availability: .optIn
        )
        let content = MetaFileGenerator.metaFile(for: module).content
        #expect(content.contains("luaswift.iox.path = {}"))
        #expect(content.contains("function luaswift.iox.path.join(a, b) end"))
    }

    @Test(".luarc.json pins runtime.version and points at the meta directory")
    func luarcShape() {
        let file = MetaFileGenerator.luarcJSON()
        #expect(file.relativePath == ".luarc.json")
        #expect(file.content.contains("\"runtime.version\": \"Lua 5.4\""))
        #expect(file.content.contains("\"workspace.library\": [\"meta\"]"))
    }
}

@Suite("F7b — luaLSMetaFiles consumer")
struct LuaLSMetaFilesTests {

    @Test("emits one meta file per module plus a .luarc.json")
    func fileSet() {
        let catalog = LuaModuleCatalog.v0
        let files = catalog.luaLSMetaFiles()
        #expect(files.count == catalog.modules.count + 1)
        #expect(files.contains { $0.relativePath == ".luarc.json" })
        #expect(files.contains { $0.relativePath == "meta/luaswift.json.lua" })
    }

    @Test("the json meta file carries the enriched encode signature (F7a.0)")
    func enrichedSignaturePresent() {
        let files = LuaModuleCatalog.v0.luaLSMetaFiles()
        let jsonMeta = files.first { $0.relativePath == "meta/luaswift.json.lua" }
        #expect(jsonMeta != nil)
        #expect(jsonMeta?.content.contains("function luaswift.json.encode") == true)
        // F7a.0 enrichment means encode carries at least one @param annotation.
        #expect(jsonMeta?.content.contains("---@param") == true)
    }

    @Test("the result is deterministic across calls (sentinel-hash stable)")
    func deterministic() {
        let a = LuaModuleCatalog.v0.luaLSMetaFiles().map(\.content).joined()
        let b = LuaModuleCatalog.v0.luaLSMetaFiles().map(\.content).joined()
        #expect(a == b)
    }
}
