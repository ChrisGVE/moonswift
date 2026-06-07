// File: Tests/MoonSwiftCoreTests/Catalog/LuaModuleCatalogTests.swift
// Role: Unit tests for LuaModuleCatalog v0. Verifies catalog completeness against
//       a fixture list, the luacheckGlobals output shape, extraModules merging,
//       availability filtering, and the optInNames seam used by ProjectValidation.
//
// Test strategy (from task 27 testStrategy):
//   - luacheckGlobals output includes base modules
//   - extraModules adds opt-in entries
//   - .conditional entries only appear when tomlProbed: true
//   - catalog completeness vs fixture lists
//   - luacheck nested-fields table shape
//   - optInNames seam correctness
//
// Upstream: LuaModuleCatalog, CatalogModule, CatalogTypes
// Downstream: (test target — nothing imports this)

import Testing
@testable import MoonSwiftCore

// MARK: - Fixture lists (ground truth verified against LuaSwift source)

/// Base module table names that must always be present.
private let expectedBaseTableNames: Set<String> = [
    "",         // root luaswift table
    "json",
    "yaml",
    "regex",
    "mathx",
    "stringx",
    "tablex",
    "types",
    "utf8x",
    "svg",
]

/// The single conditional module.
private let expectedConditionalTableNames: Set<String> = ["toml"]

/// The opt-in module names that ProjectValidation uses as its allow-list.
private let expectedOptInTableNames: Set<String> = ["iox", "http", "ui"]

// MARK: - Catalog structure tests

@Suite("LuaModuleCatalog — structure")
struct LuaModuleCatalogStructureTests {

    private let catalog = LuaModuleCatalog.v0

    @Test("v0 contains exactly 14 entries (1 root + 9 base + 1 conditional + 3 opt-in)")
    func totalModuleCount() {
        #expect(catalog.modules.count == 14)
    }

    @Test("base module set matches fixture list")
    func baseModuleNames() {
        let actual = Set(catalog.baseModules.map(\.tableName))
        #expect(actual == expectedBaseTableNames)
    }

    @Test("conditional module set is exactly [toml]")
    func conditionalModuleNames() {
        let actual = Set(catalog.conditionalModules.map(\.tableName))
        #expect(actual == expectedConditionalTableNames)
    }

    @Test("opt-in module set matches fixture list")
    func optInModuleNames() {
        let actual = Set(catalog.optInModules.map(\.tableName))
        #expect(actual == expectedOptInTableNames)
    }

    @Test("no compileFlagGated modules in v0")
    func noCompileFlagGatedModules() {
        let gated = catalog.modules.filter { $0.availability == .compileFlagGated }
        #expect(gated.isEmpty)
    }

    @Test("every module has at least one function")
    func everyModuleHasFunctions() {
        for module in catalog.modules {
            #expect(
                !module.functions.isEmpty,
                "Module '\(module.qualifiedName)' has no functions"
            )
        }
    }

    @Test("root module qualifiedName is 'luaswift'")
    func rootQualifiedName() {
        let root = catalog.modules.first { $0.tableName.isEmpty }
        #expect(root?.qualifiedName == "luaswift")
    }

    @Test("named module qualifiedName is 'luaswift.<tableName>'")
    func namedModuleQualifiedName() {
        let json = catalog.modules.first { $0.tableName == "json" }
        #expect(json?.qualifiedName == "luaswift.json")
    }
}

// MARK: - Per-module function count tests

@Suite("LuaModuleCatalog — per-module function counts")
struct LuaModuleCatalogFunctionCountTests {

    private let catalog = LuaModuleCatalog.v0

    private func functions(for tableName: String) -> [CatalogFunction] {
        catalog.modules.first { $0.tableName == tableName }?.functions ?? []
    }

    @Test("json has encode, decode, decode_jsonc, decode_json5, is_null")
    func jsonFunctions() {
        let fns = Set(functions(for: "json").map(\.name))
        #expect(fns.contains("encode"))
        #expect(fns.contains("decode"))
        #expect(fns.contains("decode_jsonc"))
        #expect(fns.contains("decode_json5"))
        #expect(fns.contains("is_null"))
    }

    @Test("yaml has encode, decode, encode_all, decode_all")
    func yamlFunctions() {
        let fns = Set(functions(for: "yaml").map(\.name))
        #expect(fns.contains("encode"))
        #expect(fns.contains("decode"))
        #expect(fns.contains("encode_all"))
        #expect(fns.contains("decode_all"))
    }

    @Test("regex has compile and match")
    func regexFunctions() {
        let fns = Set(functions(for: "regex").map(\.name))
        #expect(fns.contains("compile"))
        #expect(fns.contains("match"))
    }

    @Test("mathx has expected statistical functions")
    func mathxStatFunctions() {
        let fns = Set(functions(for: "mathx").map(\.name))
        for expected in ["sum", "mean", "median", "variance", "stddev", "percentile"] {
            #expect(fns.contains(expected), "mathx missing '\(expected)'")
        }
    }

    @Test("mathx has trig, hyperbolic, and coordinate conversion functions")
    func mathxExtendedFunctions() {
        let fns = Set(functions(for: "mathx").map(\.name))
        for expected in ["sin", "cos", "sinh", "cosh", "polar_to_cart", "cart_to_polar"] {
            #expect(fns.contains(expected), "mathx missing '\(expected)'")
        }
    }

    @Test("stringx has is_<name> and deprecated isXxx forms")
    func stringxClassificationFunctions() {
        let fns = Set(functions(for: "stringx").map(\.name))
        // Canonical forms
        #expect(fns.contains("is_alpha"))
        #expect(fns.contains("is_digit"))
        // Deprecated backward-compat aliases
        #expect(fns.contains("isalpha"))
        #expect(fns.contains("isdigit"))
    }

    @Test("tablex has both Swift-backed and Lua-defined functions")
    func tablexFunctions() {
        let fns = Set(functions(for: "tablex").map(\.name))
        // Swift-backed
        for name in ["deepcopy", "deepmerge", "flatten", "keys", "values", "invert"] {
            #expect(fns.contains(name), "tablex missing Swift-backed '\(name)'")
        }
        // Lua-defined
        for name in ["map", "filter", "reduce", "sort", "union", "chain"] {
            #expect(fns.contains(name), "tablex missing Lua-defined '\(name)'")
        }
    }

    @Test("types has typeof, is, and conversion functions")
    func typesFunctions() {
        let fns = Set(functions(for: "types").map(\.name))
        for expected in ["typeof", "is", "is_luaswift", "to_array", "clone", "all_types"] {
            #expect(fns.contains(expected), "types missing '\(expected)'")
        }
    }

    @Test("utf8x has Unicode-aware string operations")
    func utf8xFunctions() {
        let fns = Set(functions(for: "utf8x").map(\.name))
        for expected in ["width", "sub", "reverse", "upper", "lower", "len", "chars", "slice"] {
            #expect(fns.contains(expected), "utf8x missing '\(expected)'")
        }
    }

    @Test("svg has create, translate, rotate, scale")
    func svgFunctions() {
        let fns = Set(functions(for: "svg").map(\.name))
        for expected in ["create", "translate", "rotate", "scale"] {
            #expect(fns.contains(expected), "svg missing '\(expected)'")
        }
    }

    @Test("toml has encode and decode")
    func tomlFunctions() {
        let fns = Set(functions(for: "toml").map(\.name))
        #expect(fns.contains("encode"))
        #expect(fns.contains("decode"))
    }

    @Test("iox has file operations and path sub-table")
    func ioxFunctions() {
        let fns = Set(functions(for: "iox").map(\.name))
        for expected in ["read_file", "write_file", "exists", "stat", "path.join", "path.extension"] {
            #expect(fns.contains(expected), "iox missing '\(expected)'")
        }
    }

    @Test("http has all HTTP method names and request")
    func httpFunctions() {
        let fns = Set(functions(for: "http").map(\.name))
        for expected in ["get", "post", "put", "patch", "delete", "head", "options", "request"] {
            #expect(fns.contains(expected), "http missing '\(expected)'")
        }
    }

    @Test("ui has alert and confirm")
    func uiFunctions() {
        let fns = Set(functions(for: "ui").map(\.name))
        #expect(fns.contains("alert"))
        #expect(fns.contains("confirm"))
    }
}

// MARK: - luacheckGlobals output shape tests

@Suite("LuaModuleCatalog — luacheckGlobals output shape")
struct LuaModuleCatalogLuacheckTests {

    private let catalog = LuaModuleCatalog.v0

    // Helper: drill into the globals dict to reach a nested value.
    private func fields(
        _ globals: [String: Any],
        path: [String]
    ) -> [String: Any]? {
        var cursor: Any = globals
        for key in path {
            guard let dict = cursor as? [String: Any] else { return nil }
            cursor = dict[key] as Any
        }
        return cursor as? [String: Any]
    }

    @Test("top-level key is 'luaswift'")
    func topLevelKey() {
        let globals = catalog.luacheckGlobals()
        #expect(globals["luaswift"] != nil)
    }

    @Test("luaswift contains 'fields' key")
    func luaswiftHasFields() {
        let globals = catalog.luacheckGlobals()
        let luaswift = globals["luaswift"] as? [String: Any]
        #expect(luaswift?["fields"] != nil)
    }

    @Test("base modules appear in luaswift.fields without extraModules")
    func baseModulesInFields() {
        let globals = catalog.luacheckGlobals()
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        for tableName in ["json", "yaml", "regex", "mathx", "stringx", "tablex", "types", "utf8x", "svg"] {
            #expect(
                luaswiftFields[tableName] != nil,
                "Base module '\(tableName)' missing from luacheck globals"
            )
        }
    }

    @Test("root functions appear directly in luaswift.fields")
    func rootFunctionsInLuaswiftFields() {
        let globals = catalog.luacheckGlobals()
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        // extend_stdlib is the one root-level function
        #expect(luaswiftFields["extend_stdlib"] != nil)
    }

    @Test("toml absent when tomlProbed is false (default)")
    func tomlAbsentByDefault() {
        let globals = catalog.luacheckGlobals()
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["toml"] == nil)
    }

    @Test("toml present when tomlProbed is true")
    func tomlPresentWhenProbed() {
        let globals = catalog.luacheckGlobals(tomlProbed: true)
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["toml"] != nil)
    }

    @Test("opt-in module absent without extraModules")
    func optInAbsentWithoutRequest() {
        let globals = catalog.luacheckGlobals()
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["iox"] == nil)
        #expect(luaswiftFields["http"] == nil)
        #expect(luaswiftFields["ui"] == nil)
    }

    @Test("extraModules adds opt-in entry to globals")
    func extraModulesAddsOptIn() {
        let globals = catalog.luacheckGlobals(extraModules: ["iox"])
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["iox"] != nil)
        // Other opt-in modules remain absent.
        #expect(luaswiftFields["http"] == nil)
    }

    @Test("extraModules with all opt-in names adds all three")
    func extraModulesAllThree() {
        let globals = catalog.luacheckGlobals(extraModules: ["iox", "http", "ui"])
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["iox"] != nil)
        #expect(luaswiftFields["http"] != nil)
        #expect(luaswiftFields["ui"] != nil)
    }

    @Test("unknown extraModules name is silently ignored")
    func unknownExtraModuleIgnored() {
        // "bogus" is not an opt-in module; should not appear and must not crash.
        let globals = catalog.luacheckGlobals(extraModules: ["bogus"])
        let luaswiftFields = fields(globals, path: ["luaswift", "fields"])!
        #expect(luaswiftFields["bogus"] == nil)
    }

    @Test("sub-module fields dict has 'fields' key with function entries")
    func subModuleFieldsShape() {
        let globals = catalog.luacheckGlobals()
        // json should have fields: { encode: {}, decode: {}, … }
        let jsonEntry = fields(globals, path: ["luaswift", "fields", "json"])
        let jsonFields = jsonEntry?["fields"] as? [String: Any]
        #expect(jsonFields != nil)
        #expect(jsonFields?["encode"] != nil)
        #expect(jsonFields?["decode"] != nil)
    }

    @Test("iox path sub-table nested correctly in globals")
    func ioxPathSubTable() {
        let globals = catalog.luacheckGlobals(extraModules: ["iox"])
        // iox.path.join should appear as: luaswift.fields.iox.fields.path.fields.join
        let pathEntry = fields(globals, path: ["luaswift", "fields", "iox", "fields", "path"])
        let pathFields = pathEntry?["fields"] as? [String: Any]
        #expect(pathFields != nil)
        #expect(pathFields?["join"] != nil)
        #expect(pathFields?["extension"] != nil)
    }

    @Test("mathx entry has more than 10 function fields")
    func mathxFunctionFieldCount() {
        let globals = catalog.luacheckGlobals()
        let mathxFields = fields(globals, path: ["luaswift", "fields", "mathx", "fields"])
        #expect((mathxFields?.count ?? 0) > 10)
    }
}

// MARK: - Availability filtering tests

@Suite("LuaModuleCatalog — availability filtering")
struct LuaModuleCatalogAvailabilityTests {

    private let catalog = LuaModuleCatalog.v0

    @Test("toml availability is .conditional")
    func tomlIsConditional() {
        let toml = catalog.modules.first { $0.tableName == "toml" }
        #expect(toml?.availability == .conditional)
    }

    @Test("iox, http, ui availability is .optIn")
    func optInAvailability() {
        for tableName in ["iox", "http", "ui"] {
            let module = catalog.modules.first { $0.tableName == tableName }
            #expect(
                module?.availability == .optIn,
                "'\(tableName)' should be .optIn"
            )
        }
    }

    @Test("base modules have .base availability")
    func baseAvailability() {
        let nonRootBase = catalog.modules.filter {
            !$0.tableName.isEmpty && $0.availability == .base
        }
        let names = Set(nonRootBase.map(\.tableName))
        let expected: Set<String> = ["json", "yaml", "regex", "mathx", "stringx",
                                     "tablex", "types", "utf8x", "svg"]
        #expect(names == expected)
    }
}

// MARK: - optInNames seam tests (ProjectValidation integration)

@Suite("LuaModuleCatalog — optInNames seam")
struct LuaModuleCatalogOptInNamesTests {

    private let catalog = LuaModuleCatalog.v0

    @Test("optInNames returns exactly the three opt-in module names")
    func optInNamesSet() {
        #expect(catalog.optInNames == expectedOptInTableNames)
    }

    @Test("optInNames can substitute for the ProjectValidation stub allow-list")
    func optInNamesAsAllowList() {
        // This mirrors how ProjectStore wires the catalog into ProjectValidation:
        //   extraModulesAllowList: { LuaModuleCatalog.v0.optInNames }
        let allowList = catalog.optInNames
        #expect(allowList.contains("iox"))
        #expect(allowList.contains("http"))
        #expect(allowList.contains("ui"))
        #expect(!allowList.contains("json"))   // base module — not opt-in
        #expect(!allowList.contains("toml"))   // conditional — not opt-in
        #expect(!allowList.contains("bogus"))  // unknown — not in catalog
    }
}

// MARK: - P3a/P3b stub tests

@Suite("LuaModuleCatalog — P3a/P3b stubs")
struct LuaModuleCatalogStubTests {

    private let catalog = LuaModuleCatalog.v0

    @Test("completionItems returns empty array in P1")
    func completionItemsIsEmptyStub() {
        let items = catalog.completionItems(prefix: "luaswift.json.")
        #expect(items.isEmpty)
    }

    @Test("luaLSMetaFiles returns empty array in P1")
    func luaLSMetaFilesIsEmptyStub() {
        let files = catalog.luaLSMetaFiles()
        #expect(files.isEmpty)
    }
}
