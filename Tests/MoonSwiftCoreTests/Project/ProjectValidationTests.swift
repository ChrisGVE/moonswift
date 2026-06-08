// File: Tests/MoonSwiftCoreTests/Project/ProjectValidationTests.swift
// Role: Unit tests for ProjectValidation — every F2 validation rule with exact
//       diagnostic text verification and distinct test per rule. Tests run
//       collect-all validation (all rules run regardless of prior failures).
// Upstream: MoonSwiftCore/Project/ProjectValidation.swift
// Downstream: (test target — nothing imports this)

import Testing

@testable import MoonSwiftCore

// MARK: - Rule 1: lua_version

@Suite("ProjectValidation — Rule 1: lua_version")
struct ProjectValidationLuaVersionTests {

    @Test("valid lua_version 5.4 produces no diagnostic")
    func validLuaVersion() {
        let file = ProjectFile(luaVersion: "5.4")
        let diags = ProjectValidation.validate(file)
        let luaDiags = diags.filter { $0.message.contains("lua_version") }
        #expect(luaDiags.isEmpty)
    }

    @Test("unsupported lua_version 5.3 produces error")
    func unsupportedLuaVersion53() {
        let file = ProjectFile(luaVersion: "5.3")
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("5.3") && d.message.contains("5.4")
            })
    }

    @Test("unsupported lua_version 5.1 produces error with guidance")
    func unsupportedLuaVersion51() {
        let file = ProjectFile(luaVersion: "5.1")
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("disabled")
            })
    }

    @Test("empty lua_version produces error")
    func emptyLuaVersion() {
        let file = ProjectFile(luaVersion: "")
        let diags = ProjectValidation.validate(file)
        #expect(diags.contains { $0.severity == .error })
    }

    @Test("lua_version error source is projectConfig")
    func luaVersionDiagnosticSource() {
        let file = ProjectFile(luaVersion: "9.9")
        let diags = ProjectValidation.validate(file)
        let luaDiag = diags.first { d in d.message.contains("lua_version") || d.message.contains("9.9") }
        #expect(luaDiag?.source == .projectConfig)
    }
}

// MARK: - Rule 2: source.path absolute

@Suite("ProjectValidation — Rule 2: source.path must not be absolute")
struct ProjectValidationSourcePathAbsoluteTests {

    @Test("absolute path produces error")
    func absolutePathProducesError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [SourceEntry(path: "/usr/local/scripts/init.lua")]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("absolute")
                    && d.message.contains("/usr/local/scripts/init.lua")
            })
    }

    @Test("relative path does not produce absolute-path error")
    func relativePathNoError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [SourceEntry(path: "scripts/init.lua")]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("absolute") })
    }
}

// MARK: - Rule 3: source.path escapes project root

@Suite("ProjectValidation — Rule 3: source.path must not escape project root")
struct ProjectValidationSourcePathEscapeTests {

    @Test("path starting with ../ escapes project root")
    func pathWithDotDotEscapes() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [SourceEntry(path: "../secrets/credentials.lua")]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("escapes")
            })
    }

    @Test("deeply nested path that escapes via .. produces error")
    func deeplyNestedEscape() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [SourceEntry(path: "sub/dir/../../../../../../etc/passwd")]
        )
        let diags = ProjectValidation.validate(file)
        #expect(diags.contains { $0.message.contains("escapes") })
    }

    @Test("relative path with .. that stays in project root is valid")
    func relativeWithDotDotStaysInRoot() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [SourceEntry(path: "sub/../init.lua")]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("escapes") })
    }
}

// MARK: - Rule 4: duplicate source paths

@Suite("ProjectValidation — Rule 4: duplicate source paths")
struct ProjectValidationDuplicateSourceTests {

    @Test("duplicate paths produce error")
    func duplicatePathsProducesError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(path: "a.lua"),
                SourceEntry(path: "b.lua"),
                SourceEntry(path: "a.lua"),  // duplicate
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("duplicate") && d.message.contains("a.lua")
            })
    }

    @Test("unique paths produce no duplicate error")
    func uniquePathsNoError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(path: "a.lua"),
                SourceEntry(path: "b.lua"),
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("duplicate") })
    }

    @Test("duplicate error references both original and duplicate indices")
    func duplicateErrorReferencesIndices() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(path: "x.lua"),
                SourceEntry(path: "x.lua"),
            ]
        )
        let diags = ProjectValidation.validate(file)
        let dupDiag = diags.first { $0.message.contains("duplicate") }
        #expect(dupDiag?.message.contains("source[0]") == true)
        #expect(dupDiag?.message.contains("source[1]") == true)
    }
}

// MARK: - Rule 4b: document != 0 for non-YAML

@Suite("ProjectValidation — Rule 4b: document index invalid for JSON/TOML")
struct ProjectValidationDocumentIndexTests {

    @Test("document != 0 on .json file produces error")
    func documentNonZeroOnJson() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.json",
                    fields: [FieldDesignation(jsonpath: "$.foo", document: 1)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("document") && d.message.contains("YAML")
            })
    }

    @Test("document != 0 on .toml file produces error")
    func documentNonZeroOnToml() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.toml",
                    fields: [FieldDesignation(jsonpath: "$.foo", document: 2)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(diags.contains { $0.message.contains("document") })
    }

    @Test("document != 0 on .yaml file is valid")
    func documentNonZeroOnYaml() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$.foo", document: 1)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("document") && $0.severity == .error })
    }
}

// MARK: - Rule: JSONPath syntax (real parser — CR-005)

/// CR-005 remediation: `validateJSONPathSyntax` now calls
/// `JSONPathExpression(parsing:)` instead of accepting any non-empty string.
/// Invalid expressions produce a project-config error whose message contains
/// the JSONPath string and the parser's `diagnosticMessage`.
@Suite("ProjectValidation — JSONPath syntax")
struct ProjectValidationJSONPathSyntaxTests {

    @Test("empty jsonpath produces error")
    func emptyJsonPath() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("jsonpath") && d.message.contains("empty")
            })
    }

    @Test("valid jsonpath $.foo produces no error")
    func validJsonPathProducesNoError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$.foo", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("not a valid JSONPath") })
    }

    @Test("valid jsonpath with array index and wildcard produces no error")
    func validComplexJsonPathProducesNoError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$.scripts[0].*", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("not a valid JSONPath") })
    }

    @Test("filter selector ?() produces a validation error (CR-005)")
    func filterSelectorProducesError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$[?()]", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("not a valid JSONPath")
                    && d.message.contains("$[?()]")
            })
    }

    @Test("slice selector [1:3] produces a validation error (CR-005)")
    func sliceSelectorProducesError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$.a[1:3]", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("not a valid JSONPath")
            })
    }

    @Test("expression missing root $ produces a validation error (CR-005)")
    func missingRootProducesError() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "scripts.init", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("not a valid JSONPath")
                    && d.message.contains("scripts.init")
            })
    }

    @Test("invalid jsonpath error source is projectConfig (CR-005)")
    func invalidJsonPathErrorSource() {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [FieldDesignation(jsonpath: "$[?()]", document: 0)]
                )
            ]
        )
        let diags = ProjectValidation.validate(file)
        let jsonPathDiag = diags.first { $0.message.contains("not a valid JSONPath") }
        #expect(jsonPathDiag?.source == .projectConfig)
    }
}

// MARK: - Rule 5: run.config value

@Suite("ProjectValidation — Rule 5: run.config")
struct ProjectValidationRunConfigTests {

    @Test("valid sandboxed config produces no run.config error")
    func validSandboxedConfig() {
        var diags: [Diagnostic] = []
        ProjectValidation.validateRunConfig(rawConfigString: "sandboxed", into: &diags)
        #expect(diags.isEmpty)
    }

    @Test("valid unrestricted config produces no run.config error")
    func validUnrestrictedConfig() {
        var diags: [Diagnostic] = []
        ProjectValidation.validateRunConfig(rawConfigString: "unrestricted", into: &diags)
        #expect(diags.isEmpty)
    }

    @Test("unknown run.config value produces error")
    func unknownRunConfig() {
        var diags: [Diagnostic] = []
        ProjectValidation.validateRunConfig(rawConfigString: "turbo", into: &diags)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("turbo") && d.message.contains("sandboxed")
            })
    }

    @Test("run.config error source is projectConfig")
    func runConfigDiagnosticSource() {
        var diags: [Diagnostic] = []
        ProjectValidation.validateRunConfig(rawConfigString: "bad", into: &diags)
        #expect(diags.first?.source == .projectConfig)
    }
}

// MARK: - Rules 6-7: run limits

@Suite("ProjectValidation — Rules 6-7: run limits")
struct ProjectValidationRunLimitsTests {

    @Test("negative instruction_limit produces error")
    func negativeInstructionLimit() {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: -1, wallClockLimitMs: 0)
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("instruction_limit") && d.message.contains("-1")
            })
    }

    @Test("zero instruction_limit is valid (unlimited)")
    func zeroInstructionLimitIsValid() {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: 0, wallClockLimitMs: 0)
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("instruction_limit") })
    }

    @Test("positive instruction_limit is valid")
    func positiveInstructionLimitIsValid() {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: 1000, wallClockLimitMs: 0)
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("instruction_limit") && $0.severity == .error })
    }

    @Test("negative wall_clock_limit_ms produces error")
    func negativeWallClockLimit() {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: 0, wallClockLimitMs: -100)
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("wall_clock_limit_ms") && d.message.contains("-100")
            })
    }

    @Test("positive wall_clock_limit_ms without #22 produces warning")
    func positiveWallClockLimitWithout22() {
        // When MOONSWIFT_HAS_LUASWIFT_22 is not set (current state), a
        // wall_clock_limit_ms > 0 should produce a warning.
        // If the test is compiled with #22 support, this test is vacuously true
        // (the warning would not fire — but that's the correct behaviour).
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: 0, wallClockLimitMs: 5000)
        )
        let diags = ProjectValidation.validate(file)
        if !ProjectValidation.hasLuaSwift22Support {
            #expect(
                diags.contains { d in
                    d.severity == .warning && d.message.contains("wall_clock_limit_ms")
                        && d.message.contains("LuaSwift")
                })
        }
    }

    @Test("zero wall_clock_limit_ms produces no warning")
    func zeroWallClockNoWarning() {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .sandboxed, instructionLimit: 0, wallClockLimitMs: 0)
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("wall_clock_limit_ms") })
    }
}

// MARK: - Rule 8: settings.theme

@Suite("ProjectValidation — Rule 8: settings.theme")
struct ProjectValidationThemeTests {

    @Test("valid theme 'default' produces no error")
    func validThemeDefault() {
        let file = ProjectFile(
            luaVersion: "5.4",
            settings: SettingsConfig(theme: "default")
        )
        let diags = ProjectValidation.validate(file)
        #expect(!diags.contains { $0.message.contains("theme") && $0.severity == .error })
    }

    @Test("unknown theme produces error")
    func unknownTheme() {
        let file = ProjectFile(
            luaVersion: "5.4",
            settings: SettingsConfig(theme: "dracula")
        )
        let diags = ProjectValidation.validate(file)
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("dracula") && d.message.contains("theme")
            })
    }

    @Test("theme error source is projectConfig")
    func themeErrorSource() {
        let file = ProjectFile(
            luaVersion: "5.4",
            settings: SettingsConfig(theme: "bad")
        )
        let diags = ProjectValidation.validate(file)
        let themeDiag = diags.first { $0.message.contains("theme") && $0.severity == .error }
        #expect(themeDiag?.source == .projectConfig)
    }
}

// MARK: - Rule 9: lint.extra_modules allow-list

@Suite("ProjectValidation — Rule 9: lint.extra_modules")
struct ProjectValidationExtraModulesTests {

    private let stubAllowList: Set<String> = ["iox", "http", "ui"]

    @Test("known extra_module produces no error")
    func knownExtraModule() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["iox"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { stubAllowList })
        #expect(!diags.contains { $0.message.contains("extra_modules") && $0.severity == .error })
    }

    @Test("unknown extra_module produces error")
    func unknownExtraModule() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["unknownmod"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { stubAllowList })
        #expect(
            diags.contains { d in
                d.severity == .error && d.message.contains("unknownmod")
            })
    }

    @Test("multiple unknown modules each produce their own error")
    func multipleUnknownModules() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["bad1", "bad2"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { stubAllowList })
        let modErrors = diags.filter {
            $0.severity == .error && ($0.message.contains("bad1") || $0.message.contains("bad2"))
        }
        #expect(modErrors.count == 2)
    }

    @Test("mixed known and unknown modules — only unknown errors")
    func mixedModules() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["iox", "badmod"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { stubAllowList })
        // Only one error: for "badmod". "iox" is valid so no error for it.
        let errors = diags.filter { $0.severity == .error && $0.message.contains("extra_modules") }
        #expect(errors.count == 1)
        // The single error is about "badmod", not "iox".
        #expect(errors[0].message.contains("badmod"))
        // No error whose subject is "iox" (it may appear in the valid-list portion
        // of the "badmod" error message, but there should be no separate iox error).
        let ioxErrors = diags.filter {
            $0.severity == .error && $0.message.hasPrefix("lint.extra_modules contains unknown module \"iox\"")
        }
        #expect(ioxErrors.isEmpty)
    }

    @Test("empty extra_modules produces no error")
    func emptyExtraModules() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: [])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { stubAllowList })
        #expect(!diags.contains { $0.message.contains("extra_modules") })
    }

    @Test("extra_module error references valid modules in message")
    func extraModuleErrorListsValid() {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["nope"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { ["iox", "http"] })
        let err = diags.first { $0.message.contains("nope") }
        #expect(err?.message.contains("iox") == true || err?.message.contains("http") == true)
    }

    @Test("extra_modules allow-list is injected (catalog integration point)")
    func allowListIsInjected() {
        // Verify the closure is called — the injected list determines validity.
        let customAllowList: Set<String> = ["mymodule"]
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["mymodule"])
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { customAllowList })
        #expect(!diags.contains { $0.message.contains("mymodule") && $0.severity == .error })
    }
}

// MARK: - Collect-all behaviour

@Suite("ProjectValidation — collect-all")
struct ProjectValidationCollectAllTests {

    @Test("multiple rule violations all appear in one validation pass")
    func collectAllViolations() {
        let file = ProjectFile(
            luaVersion: "5.3",  // Rule 1 violation
            sources: [
                SourceEntry(path: "/bad.lua"),  // Rule 2 violation
                SourceEntry(path: "a.lua"),
                SourceEntry(path: "a.lua"),  // Rule 4 violation
            ],
            run: RunConfig(config: .sandboxed, instructionLimit: -5, wallClockLimitMs: 0),  // Rule 6
            lint: LintConfig(extraModules: ["notamodule"]),  // Rule 9
            settings: SettingsConfig(theme: "bad")  // Rule 8
        )
        let diags = ProjectValidation.validate(file, extraModulesAllowList: { ["iox"] })
        // Should have errors for: lua_version, absolute path, duplicate path,
        // instruction_limit, settings.theme, extra_modules.
        #expect(diags.filter { $0.severity == .error }.count >= 5)
    }
}

// MARK: - Unknown-key diagnostics forwarding

@Suite("ProjectValidation — unknown-key forwarding")
struct ProjectValidationUnknownKeyForwardingTests {

    @Test("unknown-key diagnostics from codec are forwarded")
    func unknownKeyDiagnosticsForwarded() {
        let file = ProjectFile(luaVersion: "5.4")
        let preExisting = [Diagnostic.projectWarning("unrecognised key")]
        let diags = ProjectValidation.validate(file, unknownKeyDiagnostics: preExisting)
        #expect(diags.contains { $0.message == "unrecognised key" })
    }
}
