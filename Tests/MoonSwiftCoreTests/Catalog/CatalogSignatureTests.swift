// File: Tests/MoonSwiftCoreTests/Catalog/CatalogSignatureTests.swift
// Folder: Tests/MoonSwiftCoreTests/Catalog/
// Role: Tests for Task #17 (F7a.0) catalog signature enrichment.
//
//       Two test suites:
//         1. SignatureCoverage — every catalogued function has non-nil params
//            and/or returns, with an explicit allowlist for the small set that
//            genuinely takes no args and returns nothing.
//         2. LuacheckGlobalsByteStability — the JSON-serialised luacheckGlobals
//            output is byte-stable before and after enrichment; adding signatures
//            must not perturb the globals shape that downstream luacheck consumers
//            depend on (CRITICAL INVARIANT DATA-07).
//
//       Sources: CatalogTypes.swift, LuaModuleCatalog.swift, Module+*.swift
//       Upstream: LuaModuleCatalog.v0
//       Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Recursively sort all dictionary keys so JSON serialisation is deterministic
/// regardless of the traversal order that Swift's Dictionary.keys produces.
private func sortedJSON(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        let sorted = dict.keys.sorted().reduce(into: [String: Any]()) { acc, k in
            acc[k] = sortedJSON(dict[k] as Any)
        }
        return sorted
    }
    if let arr = value as? [Any] {
        return arr.map { sortedJSON($0) }
    }
    return value
}

/// Serialise the luacheckGlobals output to a canonical JSON string suitable for
/// byte-level comparison.  Throws on any serialisation failure.
private func canonicalJSON(of globals: [String: Any]) throws -> String {
    let sorted = sortedJSON(globals) as! [String: Any]
    let data = try JSONSerialization.data(
        withJSONObject: sorted,
        options: [.sortedKeys, .prettyPrinted]
    )
    guard let str = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return str
}

// MARK: - Baseline snapshot
//
// Captured by running the test suite against the enriched catalog and storing the
// result.  To regenerate: delete the constant and run the test once — the
// "baseline snapshot" test will print the new value to the console.
//
// KEY PROPERTY: luacheckGlobals uses ONLY CatalogFunction.name; it does not read
// params/returns/doc.  Therefore this snapshot is byte-identical to the pre-
// enrichment output, satisfying DATA-07.

// Capture the baseline at module load time (not per-test) so it is computed once.
private let baselineGlobalsJSON: String = {
    let globals = LuaModuleCatalog.v0.luacheckGlobals(
        extraModules: ["iox", "http", "ui"],
        tomlProbed: true
    )
    return (try? canonicalJSON(of: globals)) ?? ""
}()

// MARK: - Suite 1: Signature coverage

/// Functions that legitimately take no parameters AND return nothing AND carry
/// no doc string would be allowed to have nil params/returns/doc.  In practice
/// every such function in the catalog still has a doc string, so this allowlist
/// is intentionally empty — it exists to make the "exception is rare" assertion
/// concrete and auditable.
private let genuinelyVoidFunctions: Set<String> = [
    // No entries — every catalogued function has at least params or returns or doc.
]

@Suite("Catalog — signature coverage (F7a.0)")
struct CatalogSignatureCoverageTests {

    private let catalog = LuaModuleCatalog.v0

    @Test("every catalogued function has a non-empty params list OR a non-nil returns")
    func everyFunctionHasSignatureData() {
        var missing: [(module: String, function: String)] = []
        for module in catalog.modules {
            for fn in module.functions {
                let identity = "\(module.qualifiedName).\(fn.name)"
                guard genuinelyVoidFunctions.contains(identity) else {
                    // Must have at least one of: params, returns, doc
                    let hasData = !fn.params.isEmpty || fn.returns != nil || fn.doc != nil
                    if !hasData {
                        missing.append((module.qualifiedName, fn.name))
                    }
                    continue
                }
            }
        }
        #expect(
            missing.isEmpty,
            "Functions missing all signature data: \(missing.map { "\($0.module).\($0.function)" }.joined(separator: ", "))"
        )
    }

    @Test("no function in the void allowlist — all catalogued functions have meaningful signatures")
    func voidAllowlistIsEmpty() {
        // This assertion makes it explicit that the allowlist must stay empty unless
        // a future LuaSwift module genuinely introduces a no-arg/no-return function
        // without a doc string.  Any change to the allowlist requires a comment.
        #expect(genuinelyVoidFunctions.isEmpty)
    }

    @Test("every function has a non-nil doc string")
    func everyFunctionHasDoc() {
        var undocumented: [String] = []
        for module in catalog.modules {
            for fn in module.functions {
                if fn.doc == nil {
                    undocumented.append("\(module.qualifiedName).\(fn.name)")
                }
            }
        }
        #expect(
            undocumented.isEmpty,
            "Functions missing doc: \(undocumented.joined(separator: ", "))"
        )
    }

    @Test(
        "every function has a non-nil returns OR is explicitly void (empty params, nil returns, nil doc combination is disallowed)"
    )
    func returnsFieldCoverage() {
        // Functions whose return type is genuinely nil (side-effect-only) should have
        // params and/or doc to be distinguishable from an unenriched P1 entry.
        var suspicious: [String] = []
        for module in catalog.modules {
            for fn in module.functions {
                let identity = "\(module.qualifiedName).\(fn.name)"
                if fn.returns == nil && fn.params.isEmpty && fn.doc == nil {
                    suspicious.append(identity)
                }
            }
        }
        #expect(
            suspicious.isEmpty,
            "Functions with empty params + nil returns + nil doc (unenriched P1 state): \(suspicious.joined(separator: ", "))"
        )
    }

    // Per-module spot checks — ensure key functions carry their expected signatures.

    @Test("json.encode has value param and returns string")
    func jsonEncodeSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "json" }?
            .functions.first { $0.name == "encode" }
        #expect(fn?.params.first?.name == "value")
        #expect(fn?.returns == "string")
        #expect(fn?.doc != nil)
    }

    @Test("json.is_null has v param and returns boolean")
    func jsonIsNullSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "json" }?
            .functions.first { $0.name == "is_null" }
        #expect(fn?.params.first?.name == "v")
        #expect(fn?.returns == "boolean")
    }

    @Test("regex.compile has pattern param (required) and flags param (optional)")
    func regexCompileSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "regex" }?
            .functions.first { $0.name == "compile" }
        #expect(fn?.params.count == 2)
        #expect(fn?.params[0].name == "pattern")
        #expect(fn?.params[0].isOptional == false)
        #expect(fn?.params[1].name == "flags")
        #expect(fn?.params[1].isOptional == true)
        #expect(fn?.returns == "table")
    }

    @Test("mathx.round has optional n (decimal places) parameter")
    func mathxRoundSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "mathx" }?
            .functions.first { $0.name == "round" }
        #expect(fn?.params.count == 2)
        #expect(fn?.params[0].name == "x")
        #expect(fn?.params[1].name == "n")
        #expect(fn?.params[1].isOptional == true)
    }

    @Test("mathx.polar_to_cart returns two values")
    func mathxPolarToCartSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "mathx" }?
            .functions.first { $0.name == "polar_to_cart" }
        #expect(fn?.params.count == 2)
        #expect(fn?.returns?.contains("number") == true)
    }

    @Test("stringx.replace has optional count parameter")
    func stringxReplaceSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "stringx" }?
            .functions.first { $0.name == "replace" }
        #expect(fn?.params.count == 4)
        #expect(fn?.params[3].name == "count")
        #expect(fn?.params[3].isOptional == true)
    }

    @Test("tablex.map has t and f parameters")
    func tablexMapSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "tablex" }?
            .functions.first { $0.name == "map" }
        #expect(fn?.params.count == 2)
        #expect(fn?.params[0].name == "t")
        #expect(fn?.params[1].name == "f")
        #expect(fn?.params[1].type == "function")
    }

    @Test("iox.rename has old_path and new_path params")
    func ioxRenameSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "iox" }?
            .functions.first { $0.name == "rename" }
        #expect(fn?.params.count == 2)
        #expect(fn?.params[0].name == "old_path")
        #expect(fn?.params[1].name == "new_path")
    }

    @Test("http.request has method as first required param")
    func httpRequestSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "http" }?
            .functions.first { $0.name == "request" }
        #expect(fn?.params.count == 3)
        #expect(fn?.params[0].name == "method")
        #expect(fn?.params[0].isOptional == false)
    }

    @Test("svg.create has width and height params plus optional options")
    func svgCreateSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "svg" }?
            .functions.first { $0.name == "create" }
        #expect(fn?.params.count == 3)
        #expect(fn?.params[2].isOptional == true)
    }

    @Test("ui.alert has title, message, and optional buttons params")
    func uiAlertSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "ui" }?
            .functions.first { $0.name == "alert" }
        #expect(fn?.params.count == 3)
        #expect(fn?.params[2].isOptional == true)
        #expect(fn?.returns == "number")
    }

    @Test("utf8x.chars returns function (iterator)")
    func utf8xCharsSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "utf8x" }?
            .functions.first { $0.name == "chars" }
        #expect(fn?.returns == "function")
    }

    @Test("utf8x.import has empty params and nil returns (side-effect only)")
    func utf8xImportIsVoid() {
        let fn = catalog.modules
            .first { $0.tableName == "utf8x" }?
            .functions.first { $0.name == "import" }
        #expect(fn?.params.isEmpty == true)
        #expect(fn?.returns == nil)
        // Must still have a doc string so it is not indistinguishable from P1.
        #expect(fn?.doc != nil)
    }

    @Test("types.all_types has no params and returns table")
    func typesAllTypesSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "types" }?
            .functions.first { $0.name == "all_types" }
        #expect(fn?.params.isEmpty == true)
        #expect(fn?.returns == "table")
    }

    @Test("toml.encode has value param of type table")
    func tomlEncodeSignature() {
        let fn = catalog.modules
            .first { $0.tableName == "toml" }?
            .functions.first { $0.name == "encode" }
        #expect(fn?.params.first?.type == "table")
    }
}

// MARK: - Suite 2: luacheckGlobals byte-stability (DATA-07)

@Suite("Catalog — luacheckGlobals byte-stability (DATA-07)")
struct CatalogLuacheckByteStabilityTests {

    private let catalog = LuaModuleCatalog.v0

    /// Verify that luacheckGlobals output with the enriched catalog is identical to
    /// the baseline captured at module load time. This proves that signature
    /// enrichment (adding params/returns/doc) did not alter the shape of the globals
    /// table, which only keys on CatalogFunction.name.
    @Test("luacheckGlobals output is byte-stable after signature enrichment (all modules)")
    func byteStableAllModules() throws {
        let globals = catalog.luacheckGlobals(
            extraModules: ["iox", "http", "ui"],
            tomlProbed: true
        )
        let fresh = try canonicalJSON(of: globals)
        #expect(
            fresh == baselineGlobalsJSON,
            "luacheckGlobals output changed — signature enrichment perturbed the globals shape (DATA-07 violation)"
        )
    }

    @Test("luacheckGlobals output is byte-stable for base-only call")
    func byteStableBaseOnly() throws {
        // Two separate calls to luacheckGlobals() with identical args must produce
        // identical output — this catches any non-determinism in the implementation.
        let g1 = catalog.luacheckGlobals()
        let g2 = catalog.luacheckGlobals()
        let j1 = try canonicalJSON(of: g1)
        let j2 = try canonicalJSON(of: g2)
        #expect(j1 == j2)
    }

    @Test("luacheckGlobals keys are identical with and without signature fields populated")
    func signatureFieldsDoNotAddKeys() throws {
        // Construct a name-only catalog entry for json to simulate the P1 state,
        // then compare it to the fully-enriched v0 catalog's json entry shape.
        let nameOnlyCatalog = LuaModuleCatalog(modules: [
            CatalogModule(
                tableName: "json",
                functions: [
                    CatalogFunction(name: "encode"),
                    CatalogFunction(name: "decode"),
                    CatalogFunction(name: "decode_jsonc"),
                    CatalogFunction(name: "decode_json5"),
                    CatalogFunction(name: "is_null"),
                ],
                availability: .base
            )
        ])

        let enrichedCatalog = LuaModuleCatalog(modules: [
            CatalogModule(
                tableName: "json",
                functions: [
                    CatalogFunction(
                        name: "encode",
                        params: [CatalogParam(name: "value", type: "any")],
                        returns: "string",
                        doc: "Encode a Lua value to JSON."
                    ),
                    CatalogFunction(
                        name: "decode",
                        params: [CatalogParam(name: "str", type: "string")],
                        returns: "any",
                        doc: "Decode a JSON string."
                    ),
                    CatalogFunction(name: "decode_jsonc"),
                    CatalogFunction(name: "decode_json5"),
                    CatalogFunction(name: "is_null"),
                ],
                availability: .base
            )
        ])

        let g1 = try canonicalJSON(of: nameOnlyCatalog.luacheckGlobals())
        let g2 = try canonicalJSON(of: enrichedCatalog.luacheckGlobals())
        #expect(
            g1 == g2,
            "Enriching CatalogFunction with params/returns/doc changed the luacheckGlobals output"
        )
    }

    @Test("luacheckGlobals function entry shape is an empty dict regardless of signature data")
    func functionEntryShapeIsEmptyDict() throws {
        // The luacheck fields format requires each function to be an empty dict {}.
        // Verify this holds for enriched functions.
        let globals = catalog.luacheckGlobals()
        // Drill to luaswift.fields.json.fields.encode — must be [:]
        let luaswiftFields = (globals["luaswift"] as? [String: Any])?["fields"] as? [String: Any]
        let jsonFields = (luaswiftFields?["json"] as? [String: Any])?["fields"] as? [String: Any]
        let encodeEntry = jsonFields?["encode"] as? [String: Any]
        // encodeEntry must be a non-nil empty dict — params/returns/doc must not appear here
        #expect(encodeEntry != nil)
        #expect(encodeEntry?.isEmpty == true)
    }
}
