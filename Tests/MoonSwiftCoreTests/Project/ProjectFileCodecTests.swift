// File: Tests/MoonSwiftCoreTests/Project/ProjectFileCodecTests.swift
// Role: Unit tests for ProjectFileCodec — decode, save (round-trip), and
//       codec-level error handling. Covers every schema field, round-trip
//       stability, unknown-key warn-once, and error paths.
// Upstream: MoonSwiftCore/Project/ProjectFileCodec.swift
// Downstream: (test target — nothing imports this)

import Testing
import Foundation
@testable import MoonSwiftCore

// MARK: - Decode: happy paths

@Suite("ProjectFileCodec.decode — happy paths")
struct ProjectFileCodecDecodeTests {

    @Test("decodes minimal file (lua_version only)")
    func decodesMinimal() throws {
        let toml = #"lua_version = "5.4""#
        let (file, diags) = try ProjectFileCodec.decode(toml)
        #expect(file.luaVersion == "5.4")
        #expect(file.sources.isEmpty)
        #expect(file.run.config == .sandboxed)
        #expect(file.run.instructionLimit == 0)
        #expect(file.run.wallClockLimitMs == 0)
        #expect(file.lint.extraModules.isEmpty)
        #expect(file.settings.theme == "default")
        #expect(diags.isEmpty)
    }

    @Test("decodes standalone lua source entry")
    func decodesLuaSource() throws {
        let toml = """
        lua_version = "5.4"

        [[source]]
        path = "scripts/init.lua"
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.sources.count == 1)
        #expect(file.sources[0].path == "scripts/init.lua")
        #expect(file.sources[0].fields.isEmpty)
    }

    @Test("decodes structured source with field designation")
    func decodesStructuredSource() throws {
        let toml = """
        lua_version = "5.4"

        [[source]]
        path = "config.yaml"

          [[source.field]]
          jsonpath = "$.scripts.init"
          document = 0
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.sources.count == 1)
        let entry = file.sources[0]
        #expect(entry.path == "config.yaml")
        #expect(entry.fields.count == 1)
        #expect(entry.fields[0].jsonpath == "$.scripts.init")
        #expect(entry.fields[0].document == 0)
    }

    @Test("decodes multiple sources")
    func decodesMultipleSources() throws {
        let toml = """
        lua_version = "5.4"

        [[source]]
        path = "a.lua"

        [[source]]
        path = "b.lua"
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.sources.count == 2)
        #expect(file.sources[0].path == "a.lua")
        #expect(file.sources[1].path == "b.lua")
    }

    @Test("decodes [run] table — sandboxed, limits")
    func decodesRunTable() throws {
        let toml = """
        lua_version = "5.4"

        [run]
        config = "sandboxed"
        instruction_limit = 500
        wall_clock_limit_ms = 0
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.run.config == .sandboxed)
        #expect(file.run.instructionLimit == 500)
        #expect(file.run.wallClockLimitMs == 0)
    }

    @Test("decodes [run] table — unrestricted config")
    func decodesRunUnrestricted() throws {
        let toml = """
        lua_version = "5.4"

        [run]
        config = "unrestricted"
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.run.config == .unrestricted)
    }

    @Test("decodes [lint] table — extra_modules")
    func decodesLintTable() throws {
        let toml = """
        lua_version = "5.4"

        [lint]
        extra_modules = ["iox", "http"]
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.lint.extraModules == ["iox", "http"])
    }

    @Test("decodes [settings] table — theme")
    func decodesSettingsTable() throws {
        let toml = """
        lua_version = "5.4"

        [settings]
        theme = "default"
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.settings.theme == "default")
    }

    @Test("absent optional tables produce defaults")
    func absentOptionalTablesProduceDefaults() throws {
        let toml = #"lua_version = "5.4""#
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.run.config == .sandboxed)
        #expect(file.run.instructionLimit == 0)
        #expect(file.run.wallClockLimitMs == 0)
        #expect(file.lint.extraModules.isEmpty)
        #expect(file.settings.theme == "default")
    }

    @Test("absent run.config defaults to sandboxed")
    func absentRunConfigDefaultsSandboxed() throws {
        let toml = """
        lua_version = "5.4"

        [run]
        instruction_limit = 100
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.run.config == .sandboxed)
    }

    @Test("document defaults to 0 when absent")
    func documentDefaultsToZero() throws {
        let toml = """
        lua_version = "5.4"

        [[source]]
        path = "config.yaml"

          [[source.field]]
          jsonpath = "$.foo"
        """
        let (file, _) = try ProjectFileCodec.decode(toml)
        #expect(file.sources[0].fields[0].document == 0)
    }
}

// MARK: - Decode: unknown-key handling

@Suite("ProjectFileCodec.decode — unknown keys")
struct ProjectFileCodecUnknownKeyTests {

    @Test("unknown top-level key produces exactly one warning")
    func unknownKeyOneWarning() throws {
        let toml = """
        lua_version = "5.4"

        [future_feature]
        enabled = true
        """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(diags.count == 1)
        #expect(diags[0].severity == .warning)
        #expect(diags[0].source == .projectConfig)
    }

    @Test("multiple unknown keys produce exactly one warning (warn-once)")
    func multipleUnknownKeysOneWarning() throws {
        let toml = """
        lua_version = "5.4"

        [alpha]
        x = 1

        [beta]
        y = 2
        """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(diags.count == 1)
    }

    @Test("no warning for all-known keys")
    func noWarningAllKnownKeys() throws {
        let toml = """
        lua_version = "5.4"

        [run]
        config = "sandboxed"
        """
        let (_, diags) = try ProjectFileCodec.decode(toml)
        #expect(diags.isEmpty)
    }
}

// MARK: - Decode: error paths

@Suite("ProjectFileCodec.decode — errors")
struct ProjectFileCodecDecodeErrorTests {

    @Test("throws parseFailure on invalid TOML")
    func throwsParseFailureOnInvalidTOML() {
        let toml = "lua_version = \"5.4\"\ninvalid [[[syntax"
        #expect(throws: CodecError.parseFailure(underlying: AnyError())) {
            try ProjectFileCodec.decode(toml)
        }
    }

    @Test("throws missingRequiredKey when lua_version absent")
    func throwsMissingLuaVersion() {
        let toml = "[run]\nconfig = \"sandboxed\""
        #expect(throws: CodecError.missingRequiredKey("lua_version")) {
            try ProjectFileCodec.decode(toml)
        }
    }
}

// MARK: - Round-trip tests

@Suite("ProjectFileCodec round-trip")
struct ProjectFileCodecRoundTripTests {

    @Test("decode → encode → decode is stable (minimal)")
    func roundTripMinimal() throws {
        let toml = #"lua_version = "5.4""#
        let (original, _) = try ProjectFileCodec.decode(toml)
        let encoded = try ProjectFileCodec.save(original, into: toml)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded == original)
    }

    @Test("decode → encode → decode is stable (full schema)")
    func roundTripFull() throws {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "scripts/init.lua",
                    fields: []
                ),
                SourceEntry(
                    path: "config.yaml",
                    fields: [
                        FieldDesignation(jsonpath: "$.scripts.init", document: 0)
                    ]
                ),
            ],
            run: RunConfig(config: .sandboxed, instructionLimit: 1000, wallClockLimitMs: 0),
            lint: LintConfig(extraModules: ["iox"]),
            settings: SettingsConfig(theme: "default")
        )
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded == file)
    }

    @Test("save from nil base produces valid decodable TOML")
    func saveFromNilBase() throws {
        let file = ProjectFile(luaVersion: "5.4")
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.luaVersion == "5.4")
    }

    @Test("round-trip preserves multiple field designations")
    func roundTripMultipleFields() throws {
        let file = ProjectFile(
            luaVersion: "5.4",
            sources: [
                SourceEntry(
                    path: "config.yaml",
                    fields: [
                        FieldDesignation(jsonpath: "$.a", document: 0),
                        FieldDesignation(jsonpath: "$.b", document: 0),
                    ]
                )
            ]
        )
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.sources[0].fields.count == 2)
        #expect(reloaded.sources[0].fields[0].jsonpath == "$.a")
        #expect(reloaded.sources[0].fields[1].jsonpath == "$.b")
    }

    @Test("round-trip preserves unrestricted run config")
    func roundTripUnrestrictedConfig() throws {
        let file = ProjectFile(
            luaVersion: "5.4",
            run: RunConfig(config: .unrestricted, instructionLimit: 0, wallClockLimitMs: 0)
        )
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.run.config == .unrestricted)
    }

    @Test("round-trip preserves lint.extra_modules")
    func roundTripExtraModules() throws {
        let file = ProjectFile(
            luaVersion: "5.4",
            lint: LintConfig(extraModules: ["iox", "http"])
        )
        let encoded = try ProjectFileCodec.save(file, into: nil)
        let (reloaded, _) = try ProjectFileCodec.decode(encoded)
        #expect(reloaded.lint.extraModules == ["iox", "http"])
    }

    @Test("fixture file full.toml decodes correctly")
    func fixtureFullToml() throws {
        let url = Bundle.module.url(forResource: "Fixtures/Project/full", withExtension: "toml")!
        let content = try String(contentsOf: url, encoding: .utf8)
        let (file, _) = try ProjectFileCodec.decode(content)
        #expect(file.luaVersion == "5.4")
        #expect(file.sources.count == 2)
        #expect(file.run.instructionLimit == 1000)
        #expect(file.lint.extraModules == ["iox"])
    }
}

// MARK: - AnyError helper for pattern matching

/// Placeholder `Error` for use in `#expect(throws:)` pattern matching where
/// only the case matters, not the underlying error.
private struct AnyError: Error {}

// Custom equality for CodecError pattern matching in #expect(throws:).
// Swift Testing's `throws:` checks if the thrown error equals the expected via
// `==`. We need CodecError to be Equatable (it is) and AnyError to match only
// the parseFailure case.
// However, `#expect(throws:)` checks the error TYPE, not equality — so we
// use the type-based form here.
