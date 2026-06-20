// File: Tests/MoonSwiftCoreTests/Project/ProjectMockTests.swift
// Location: Tests/MoonSwiftCoreTests/Project/
// Role: Tests for F5.5 mock-table codec (ProjectFileCodec+Mock) and validation
//       (ProjectValidation+Mock). Each test is scoped to exactly ONE rule.
//       The exact diagnostic strings asserted here are NORMATIVE — they match
//       the ux-spec §6.9 binding strings verbatim (EM DASH U+2014 in type/behavior
//       rules; plain text elsewhere).
//
//       LintService dependency: validation tests that exercise the
//       "unparseable mock value" rule need a real LintServiceProtocol instance.
//       Tests that exercise other rules pass `mockLintService: nil` so they
//       are independent of the lint engine. All tests are synchronous.
//
// Upstream: ProjectFileCodec+Mock, ProjectValidation+Mock, MockStore,
//           MockValueDef, MockFunctionDef
// Downstream: (test target only)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Codec: [[mock.value]] round-trip

@Suite("ProjectFileCodec — mock.value decode / encode")
struct ProjectFileCodecMockValueTests {

    @Test("decodes a single [[mock.value]] entry")
    func decodesOneMockValue() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "myapp"
            path = "settings.debug"
            type = "boolean"
            value = "true"
            writable = true
            """
        let (file, diags) = try ProjectFileCodec.decode(toml)
        #expect(diags.isEmpty)
        #expect(file.mocks.values.count == 1)
        let v = file.mocks.values[0]
        #expect(v.namespace == "myapp")
        #expect(v.path == "settings.debug")
        #expect(v.type == .boolean)
        #expect(v.value == "true")
        #expect(v.writable == true)
    }

    @Test("decodes multiple [[mock.value]] entries preserving order")
    func decodesMultipleMockValues() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "a"
            path = "x"
            type = "string"
            value = '"hello"'
            writable = false

            [[mock.value]]
            namespace = "b"
            path = "y"
            type = "number"
            value = "42"
            writable = true
            """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.mocks.values.count == 2)
        #expect(file.mocks.values[0].namespace == "a")
        #expect(file.mocks.values[1].namespace == "b")
    }

    @Test("absent [[mock.value]] table produces empty MockStore")
    func absentMockProducesEmpty() throws {
        let toml = #"lua_version = "5.4""#
        let (file, diags) = try ProjectFileCodec.decode(toml)
        #expect(file.mocks.isEmpty)
        #expect(diags.isEmpty)
    }

    @Test("round-trip [[mock.value]] decode → encode → decode is stable")
    func roundTripMockValue() throws {
        let store = MockStore(
            values: [
                MockValueDef(
                    namespace: "myapp",
                    path: "settings.debug",
                    type: .boolean,
                    value: "true",
                    writable: true
                ),
                MockValueDef(
                    namespace: "myapp",
                    path: "count",
                    type: .number,
                    value: "99",
                    writable: false
                ),
            ],
            functions: []
        )
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.mocks == store)
    }

    @Test("all MockValueType raw values round-trip correctly")
    func roundTripAllValueTypes() throws {
        let types: [MockValueType] = [.string, .number, .boolean, .table, .expr]
        for valueType in types {
            let store = MockStore(
                values: [MockValueDef(namespace: "ns", path: "p", type: valueType, value: "0", writable: false)],
                functions: []
            )
            let file = ProjectFile(luaVersion: "5.4", mocks: store)
            let encoded = try ProjectFileCodec.save(file, into: nil)
            let (reloaded, _) = try ProjectFileCodec.decode(encoded)
            #expect(reloaded.mocks.values[0].type == valueType)
        }
    }

    @Test("P2 file with mock tables produces no unknown-key warning (back-compat)")
    func mockKeyIsKnownInP2Build() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "ns"
            path = "p"
            type = "string"
            value = '"hi"'
            writable = false
            """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        // No "unrecognised key" warning should be produced for the "mock" key.
        let unknownKeyDiags = diags.filter { $0.message.contains("unrecognised key") }
        #expect(unknownKeyDiags.isEmpty)
    }
}

// MARK: - Codec: [[mock.function]] round-trip

@Suite("ProjectFileCodec — mock.function decode / encode")
struct ProjectFileCodecMockFunctionTests {

    @Test("decodes echo-args function (no conditional fields)")
    func decodesEchoArgs() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.function]]
            name = "host_log"
            behavior = "echo-args"
            """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.mocks.functions.count == 1)
        let fn = file.mocks.functions[0]
        #expect(fn.name == "host_log")
        #expect(fn.behavior == .echoArgs)
        #expect(fn.returnValue == nil)
        #expect(fn.errorMessage == nil)
    }

    @Test("decodes fixed-return function with return_value")
    func decodesFixedReturn() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.function]]
            name = "get_count"
            behavior = "fixed-return"
            return_value = "42"
            """
        let (file, _) = try ProjectFileCodec.decode(toml)
        let fn = file.mocks.functions[0]
        #expect(fn.behavior == .fixedReturn)
        #expect(fn.returnValue == "42")
        #expect(fn.errorMessage == nil)
    }

    @Test("decodes raise-error function with error_message")
    func decodesRaiseError() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.function]]
            name = "fail_now"
            behavior = "raise-error"
            error_message = "simulated failure"
            """
        let (file, _) = try ProjectFileCodec.decode(toml)
        let fn = file.mocks.functions[0]
        #expect(fn.behavior == .raiseError)
        #expect(fn.errorMessage == "simulated failure")
        #expect(fn.returnValue == nil)
    }

    @Test("round-trip [[mock.function]] decode → encode → decode is stable")
    func roundTripMockFunctions() throws {
        let store = MockStore(
            values: [],
            functions: [
                MockFunctionDef(name: "host_log", behavior: .echoArgs),
                MockFunctionDef(name: "get_val", behavior: .fixedReturn, returnValue: "99"),
                MockFunctionDef(name: "boom", behavior: .raiseError, errorMessage: "oops"),
            ]
        )
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.mocks == store)
    }

    @Test("DATA-06: fixed-return function does not gain error_message key on round-trip")
    func conditionalFieldOmittedOnEncode() throws {
        let fn = MockFunctionDef(name: "f", behavior: .fixedReturn, returnValue: "1", errorMessage: nil)
        let store = MockStore(values: [], functions: [fn])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let encoded = try ProjectFileCodec.save(file, into: nil)
        // The encoded TOML must not contain an error_message key at all.
        #expect(!encoded.contains("error_message"))
    }

    @Test("DATA-06: raise-error function does not gain return_value key on round-trip")
    func raiseErrorOmitsReturnValue() throws {
        let fn = MockFunctionDef(name: "f", behavior: .raiseError, returnValue: nil, errorMessage: "e")
        let store = MockStore(values: [], functions: [fn])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let encoded = try ProjectFileCodec.save(file, into: nil)
        #expect(!encoded.contains("return_value"))
    }
}

// MARK: - Codec: unknown sibling key preservation

@Suite("ProjectFileCodec — unknown sibling key preservation")
struct ProjectFileCodecUnknownSiblingKeyTests {

    @Test("unknown top-level keys outside mock are preserved on round-trip")
    func unknownTopLevelKeyPreserved() throws {
        let toml = """
            lua_version = "5.4"

            [future_feature]
            enabled = true

            [[mock.value]]
            namespace = "ns"
            path = "p"
            type = "string"
            value = '"v"'
            writable = false
            """
        let (file, _) = try ProjectFileCodec.decode(toml)
        // Re-encode preserving the unknown [future_feature] block.
        let encoded = try ProjectFileCodec.save(file, into: toml)
        #expect(encoded.contains("future_feature"))
        #expect(encoded.contains("enabled"))
    }
}

// MARK: - Validation: mock.value rules

@Suite("ProjectValidation — mock.value rules")
struct ProjectValidationMockValueTests {

    // Helper: build a file with a single value def and run validation.
    private func validate(_ def: MockValueDef) -> [Diagnostic] {
        let store = MockStore(values: [def], functions: [])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        return ProjectValidation.validate(file, extraModulesAllowList: { [] })
    }

    @Test("valid mock value produces no diagnostic")
    func validMockValueNoDiag() {
        let def = MockValueDef(namespace: "myapp", path: "debug", type: .boolean, value: "true", writable: false)
        let diags = validate(def)
        #expect(
            !diags.contains {
                $0.message.hasPrefix("mock") || $0.message.hasPrefix("unparseable") || $0.message.hasPrefix("duplicate")
            })
    }

    @Test("empty namespace produces exact diagnostic")
    func emptyNamespaceExactMessage() {
        let def = MockValueDef(namespace: "", path: "p", type: .string, value: #""hi""#, writable: false)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "mock namespace must not be empty" })
    }

    @Test("empty path produces exact diagnostic")
    func emptyPathExactMessage() {
        let def = MockValueDef(namespace: "ns", path: "", type: .string, value: #""hi""#, writable: false)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "mock name must not be empty" })
    }

    @Test("DATA-03: duplicate (namespace, path) produces exact diagnostic")
    func duplicateMockValueExactMessage() {
        let def1 = MockValueDef(namespace: "myapp", path: "cfg.debug", type: .boolean, value: "true", writable: false)
        let def2 = MockValueDef(namespace: "myapp", path: "cfg.debug", type: .boolean, value: "false", writable: false)
        let store = MockStore(values: [def1, def2], functions: [])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { [] })
        #expect(diags.contains { $0.message == #"duplicate mock value "myapp.cfg.debug""# })
    }

    @Test("duplicate mock value severity is error")
    func duplicateMockValueIsError() {
        let def = MockValueDef(namespace: "ns", path: "k", type: .boolean, value: "true", writable: false)
        let store = MockStore(values: [def, def], functions: [])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { [] })
        let dup = diags.first { $0.message.hasPrefix("duplicate mock value") }
        #expect(dup?.severity == .error)
    }
}

// MARK: - Validation: mock.function rules

@Suite("ProjectValidation — mock.function rules")
struct ProjectValidationMockFunctionTests {

    private func validate(_ def: MockFunctionDef, symbols: Set<String> = []) -> [Diagnostic] {
        let store = MockStore(values: [], functions: [def])
        var diags: [Diagnostic] = []
        ProjectValidation.validateMocks(
            store,
            lintService: nil,
            catalogSymbols: { symbols },
            into: &diags
        )
        return diags
    }

    @Test("valid echo-args function produces no mock diagnostic")
    func validEchoArgsNoDiag() {
        let def = MockFunctionDef(name: "host_log", behavior: .echoArgs)
        let diags = validate(def)
        #expect(!diags.contains { $0.message.hasPrefix("mock") || $0.message.hasPrefix("duplicate") })
    }

    @Test("empty name produces exact diagnostic")
    func emptyNameExactMessage() {
        let def = MockFunctionDef(name: "", behavior: .echoArgs)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "mock name must not be empty" })
    }

    @Test("DATA-03: duplicate function name produces exact diagnostic")
    func duplicateFunctionNameExactMessage() {
        let def1 = MockFunctionDef(name: "host_log", behavior: .echoArgs)
        let def2 = MockFunctionDef(name: "host_log", behavior: .echoArgs)
        let store = MockStore(values: [], functions: [def1, def2])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { [] })
        #expect(diags.contains { $0.message == #"duplicate mock function "host_log""# })
    }

    @Test("reserved prefix produces exact diagnostic")
    func reservedPrefixExactMessage() {
        let def = MockFunctionDef(name: "__moonswift_internal", behavior: .echoArgs)
        let diags = validate(def)
        #expect(diags.contains { $0.message == #"mock name "__moonswift_internal" uses reserved prefix __moonswift_"# })
    }

    @Test("catalog collision produces exact diagnostic")
    func catalogCollisionExactMessage() {
        let def = MockFunctionDef(name: "json", behavior: .echoArgs)
        let diags = validate(def, symbols: ["json", "luaswift"])
        #expect(diags.contains { $0.message == #"mock name "json" collides with catalog symbol"# })
    }

    @Test("catalog collision check uses default catalog symbol set")
    func catalogCollisionUsesDefaultCatalog() {
        // "luaswift" is always in the catalog symbol set.
        let def = MockFunctionDef(name: "luaswift", behavior: .echoArgs)
        let store = MockStore(values: [], functions: [def])
        let file = ProjectFile(luaVersion: "5.4", mocks: store)
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { [] })
        #expect(diags.contains { $0.message == #"mock name "luaswift" collides with catalog symbol"# })
    }

    @Test("return_value required for fixed-return — exact diagnostic")
    func returnValueRequiredExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .fixedReturn, returnValue: nil)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "return_value is required for behavior fixed-return" })
    }

    @Test("error_message required for raise-error — exact diagnostic")
    func errorMessageRequiredExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .raiseError, errorMessage: nil)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "error_message is required for behavior raise-error" })
    }

    @Test("irrelevant return_value for echo-args — exact diagnostic")
    func irrelevantReturnValueForEchoArgsExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .echoArgs, returnValue: "1", errorMessage: nil)
        let diags = validate(def)
        #expect(diags.contains { $0.message == "irrelevant field return_value for behavior echo-args" })
    }

    @Test("irrelevant error_message for echo-args — exact diagnostic")
    func irrelevantErrorMessageForEchoArgsExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .echoArgs, returnValue: nil, errorMessage: "e")
        let diags = validate(def)
        #expect(diags.contains { $0.message == "irrelevant field error_message for behavior echo-args" })
    }

    @Test("irrelevant error_message for fixed-return — exact diagnostic")
    func irrelevantErrorMessageForFixedReturnExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .fixedReturn, returnValue: "1", errorMessage: "e")
        let diags = validate(def)
        #expect(diags.contains { $0.message == "irrelevant field error_message for behavior fixed-return" })
    }

    @Test("irrelevant return_value for raise-error — exact diagnostic")
    func irrelevantReturnValueForRaiseErrorExactMessage() {
        let def = MockFunctionDef(name: "f", behavior: .raiseError, returnValue: "1", errorMessage: "e")
        let diags = validate(def)
        #expect(diags.contains { $0.message == "irrelevant field return_value for behavior raise-error" })
    }

    @Test("valid fixed-return with return_value produces no conditional-field diagnostic")
    func validFixedReturnNoDiag() {
        let def = MockFunctionDef(name: "f", behavior: .fixedReturn, returnValue: "42")
        let diags = validate(def)
        let mockDiags = diags.filter {
            $0.message.contains("required") || $0.message.contains("irrelevant")
        }
        #expect(mockDiags.isEmpty)
    }

    @Test("valid raise-error with error_message produces no conditional-field diagnostic")
    func validRaiseErrorNoDiag() {
        let def = MockFunctionDef(name: "f", behavior: .raiseError, errorMessage: "oops")
        let diags = validate(def)
        let mockDiags = diags.filter {
            $0.message.contains("required") || $0.message.contains("irrelevant")
        }
        #expect(mockDiags.isEmpty)
    }
}

// MARK: - Validation: back-compat (mock tables load with no unknown-key warning)

@Suite("ProjectValidation — back-compat: mock recognized in P2")
struct ProjectValidationMockBackCompatTests {

    @Test("mock tables in P2 project file produce no unknown-key warning")
    func mockTablesNoUnknownKeyWarning() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "ns"
            path = "k"
            type = "boolean"
            value = "true"
            writable = false
            """
        // Decode produces (file, unknownKeyDiagnostics).
        let (file, unknownKeyDiags) = try ProjectFileCodec.decode(toml)

        // Full validation pass.
        let allDiags = ProjectValidation.validate(
            file,
            unknownKeyDiagnostics: unknownKeyDiags,
            extraModulesAllowList: { [] }
        )

        // No "unrecognised key" warning must appear.
        let unrecognisedWarnings = allDiags.filter { $0.message.contains("unrecognised key") }
        #expect(unrecognisedWarnings.isEmpty)
    }
}

// MARK: - Validation: validate() signature backward compat

@Suite("ProjectValidation — existing call sites unaffected by new mocks parameter")
struct ProjectValidationExistingCallSiteTests {

    @Test("validate without mocks parameter still works for non-mock files")
    func existingCallSiteCompiles() {
        // This test verifies the `mockLintService: nil` default doesn't break
        // existing callers that pass only the standard parameters.
        let file = ProjectFile(luaVersion: "5.4")
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { ["iox"] })
        // The file has no mocks and valid lua_version — the only diagnostics
        // would be non-mock ones. Just ensure the call compiles and runs.
        let mockDiags = diags.filter { $0.message.hasPrefix("mock") }
        #expect(mockDiags.isEmpty)
    }
}

// MARK: - Codec: raw-string diagnostic rules (unknown type / behavior / writable)

@Suite("ProjectFileCodec — codec-level mock diagnostics")
struct ProjectFileCodecMockDiagnosticTests {

    @Test("unknown mock type produces exact diagnostic")
    func unknownMockTypeExactMessage() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "ns"
            path = "p"
            type = "integer"
            value = "1"
            writable = false
            """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(
            diags.contains {
                $0.message == "unknown mock type \"integer\" \u{2014} "
                    + "expected string | number | boolean | table | expr"
            }
        )
    }

    @Test("unknown mock behavior produces exact diagnostic")
    func unknownMockBehaviorExactMessage() throws {
        let toml = """
            lua_version = "5.4"

            [[mock.function]]
            name = "f"
            behavior = "do-nothing"
            """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(
            diags.contains {
                $0.message == "unknown mock behavior \"do-nothing\" \u{2014} "
                    + "expected echo-args | fixed-return | raise-error"
            }
        )
    }

    @Test("mock writable not a boolean produces exact diagnostic")
    func mockWritableNotBooleanExactMessage() throws {
        // TOML: writable = "yes" is a string, not a boolean — rejected by codec.
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "ns"
            path = "p"
            type = "string"
            value = '"hi"'
            writable = "yes"
            """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(diags.contains { $0.message == "mock writable must be a boolean" })
    }

    @Test("codec diagnostics are propagated through the decode return value")
    func codecDiagnosticsArePropagated() throws {
        // An unknown type produces a diagnostic in the second element of the
        // decode result, where the caller (ProjectStore / tests) can surface it.
        let toml = """
            lua_version = "5.4"

            [[mock.value]]
            namespace = "ns"
            path = "p"
            type = "bogus"
            value = "1"
            writable = true
            """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(!diags.isEmpty)
        #expect(diags[0].severity == .error)
    }
}
