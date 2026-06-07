// File: Tests/MoonSwiftCoreTests/Project/ProjectStoreTests.swift
// Role: Unit tests for ProjectStore.loadFromString and init flow.
//       Filesystem scenarios are NOT tested directly (coding.md §II TDD rule:
//       always mock filesystem). Tests use loadFromString and the fixture files
//       via Bundle.module to avoid live filesystem manipulation.
// Upstream: MoonSwiftCore/Project/ProjectStore.swift
// Downstream: (test target — nothing imports this)

import Testing
import Foundation
@testable import MoonSwiftCore

// MARK: - ProjectStore.loadFromString

@Suite("ProjectStore.loadFromString")
struct ProjectStoreLoadFromStringTests {

    @Test("loaded result for valid minimal file")
    func loadMinimalReturnsLoaded() {
        let result = ProjectStore.loadFromString(#"lua_version = "5.4""#)
        if case let .loaded(file, diags) = result {
            #expect(file.luaVersion == "5.4")
            #expect(diags.isEmpty)
        } else {
            Issue.record("Expected .loaded but got \(result)")
        }
    }

    @Test("malformed TOML returns .malformed")
    func malformedTomlReturnsMalformed() {
        let result = ProjectStore.loadFromString("lua_version = \"5.4\"\nbad [[[")
        if case .malformed = result {
            // correct
        } else {
            Issue.record("Expected .malformed but got \(result)")
        }
    }

    @Test("malformed diagnostic message mentions moonswift.toml")
    func malformedDiagnosticMentionsFile() {
        let result = ProjectStore.loadFromString("bad [[[")
        if case let .malformed(diag) = result {
            #expect(diag.message.contains("moonswift.toml") || diag.message.contains("TOML"))
        } else {
            Issue.record("Expected .malformed but got \(result)")
        }
    }

    @Test("missing lua_version returns .malformed")
    func missingLuaVersionReturnsMalformed() {
        let result = ProjectStore.loadFromString("[run]\nconfig = \"sandboxed\"")
        if case .malformed = result {
            // correct
        } else {
            Issue.record("Expected .malformed but got \(result)")
        }
    }

    @Test("unsupported lua_version returns .unsupportedVersion")
    func unsupportedVersionReturnsUnsupportedVersion() {
        let result = ProjectStore.loadFromString(#"lua_version = "5.3""#)
        if case let .unsupportedVersion(file, diags) = result {
            #expect(file.luaVersion == "5.3")
            #expect(diags.contains { $0.severity == .error })
        } else {
            Issue.record("Expected .unsupportedVersion but got \(result)")
        }
    }

    @Test("unsupportedVersion result carries run-disabled diagnostic")
    func unsupportedVersionCarriesDisabledDiagnostic() {
        let result = ProjectStore.loadFromString(#"lua_version = "5.1""#)
        if case let .unsupportedVersion(_, diags) = result {
            #expect(diags.contains { $0.message.contains("disabled") })
        } else {
            Issue.record("Expected .unsupportedVersion but got \(result)")
        }
    }

    @Test("loaded result for valid full file — diagnostics may have warnings only")
    func loadFullFileReturnsLoaded() {
        let toml = """
        lua_version = "5.4"

        [[source]]
        path = "scripts/init.lua"

        [run]
        config = "sandboxed"
        instruction_limit = 500

        [lint]
        extra_modules = ["iox"]

        [settings]
        theme = "default"
        """
        let result = ProjectStore.loadFromString(toml)
        if case let .loaded(file, diags) = result {
            #expect(file.luaVersion == "5.4")
            #expect(file.sources.count == 1)
            #expect(file.run.instructionLimit == 500)
            // All diagnostics should be warnings at most (no errors for valid input).
            #expect(diags.allSatisfy { $0.severity == .warning })
        } else {
            Issue.record("Expected .loaded but got \(result)")
        }
    }

    @Test("unknown keys produce loaded result with one warning")
    func unknownKeysProduceLoadedWithWarning() {
        let toml = """
        lua_version = "5.4"

        [future_feature]
        enabled = true
        """
        let result = ProjectStore.loadFromString(toml)
        if case let .loaded(_, diags) = result {
            #expect(diags.count == 1)
            #expect(diags[0].severity == .warning)
        } else {
            Issue.record("Expected .loaded but got \(result)")
        }
    }

    @Test("invalid extra_module produces loaded result with error diagnostic")
    func invalidExtraModuleProducesError() {
        let toml = """
        lua_version = "5.4"

        [lint]
        extra_modules = ["notvalid"]
        """
        let result = ProjectStore.loadFromString(
            toml,
            extraModulesAllowList: { ["iox", "http", "ui"] }
        )
        if case let .loaded(_, diags) = result {
            #expect(diags.contains { $0.severity == .error && $0.message.contains("notvalid") })
        } else {
            Issue.record("Expected .loaded (with error diagnostic) but got \(result)")
        }
    }

    @Test("unrecognised run.config in TOML produces error diagnostic")
    func unrecognisedRunConfig() {
        let toml = """
        lua_version = "5.4"

        [run]
        config = "turbo"
        """
        let result = ProjectStore.loadFromString(toml)
        if case let .loaded(_, diags) = result {
            #expect(diags.contains { $0.severity == .error && $0.message.contains("turbo") })
        } else {
            Issue.record("Expected .loaded (with error diagnostic) but got \(result)")
        }
    }
}

// MARK: - LoadResult pattern helpers

@Suite("ProjectStore.LoadResult")
struct ProjectStoreLoadResultTests {

    @Test("LoadResult.loaded is not malformed")
    func loadedIsNotMalformed() {
        let result = ProjectStore.loadFromString(#"lua_version = "5.4""#)
        if case .malformed = result {
            Issue.record("Expected .loaded but got malformed")
        }
    }

    @Test("LoadResult.malformed for syntactically bad TOML")
    func malformedForBadToml() {
        let result = ProjectStore.loadFromString("]]]invalid")
        if case .malformed = result {
            // correct
        } else {
            Issue.record("Expected .malformed but got \(result)")
        }
    }
}

// MARK: - Fixture-based tests

@Suite("ProjectStore — fixture files")
struct ProjectStoreFixtureTests {

    @Test("fixture minimal.toml loads cleanly")
    func fixtureMinimal() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Project/minimal", withExtension: "toml"))
        let content = try String(contentsOf: url, encoding: .utf8)
        let result = ProjectStore.loadFromString(content)
        if case let .loaded(file, _) = result {
            #expect(file.luaVersion == "5.4")
        } else {
            Issue.record("Expected .loaded for minimal.toml but got \(result)")
        }
    }

    @Test("fixture invalid_lua_version.toml returns unsupportedVersion")
    func fixtureInvalidLuaVersion() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Project/invalid_lua_version", withExtension: "toml"))
        let content = try String(contentsOf: url, encoding: .utf8)
        let result = ProjectStore.loadFromString(content)
        if case .unsupportedVersion = result {
            // correct
        } else {
            Issue.record("Expected .unsupportedVersion for invalid_lua_version.toml but got \(result)")
        }
    }

    @Test("fixture malformed.toml returns malformed")
    func fixtureMalformed() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Project/malformed", withExtension: "toml"))
        let content = try String(contentsOf: url, encoding: .utf8)
        let result = ProjectStore.loadFromString(content)
        if case .malformed = result {
            // correct
        } else {
            Issue.record("Expected .malformed for malformed.toml but got \(result)")
        }
    }

    @Test("fixture unknown_keys.toml returns loaded with warning")
    func fixtureUnknownKeys() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Project/unknown_keys", withExtension: "toml"))
        let content = try String(contentsOf: url, encoding: .utf8)
        let result = ProjectStore.loadFromString(content)
        if case let .loaded(_, diags) = result {
            #expect(diags.contains { $0.severity == .warning })
        } else {
            Issue.record("Expected .loaded for unknown_keys.toml but got \(result)")
        }
    }
}
