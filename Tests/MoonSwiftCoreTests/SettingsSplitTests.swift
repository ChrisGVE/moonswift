// File: Tests/MoonSwiftCoreTests/SettingsSplitTests.swift
// Location: MoonSwiftCoreTests/
// Role: F5.6 — split-ratio persistence. Covers the codec/validation half of
//       task #14: SettingsConfig.navigator_split / bottom_split decode/encode
//       round-trip, back-compat with theme-only [settings], the out-of-range
//       validation diagnostics (exact binding text), and the clamp-on-apply
//       accessors. The TUI resize→auto-save / load→apply half is exercised by
//       the reducer tests.
//
// Upstream: SettingsConfig, ProjectFileCodec, ProjectValidation
// Downstream: (test target only)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Codec round-trip + back-compat

@Suite("F5.6 — SettingsConfig split codec")
struct SettingsSplitCodecTests {

    @Test("theme + both splits round-trip through save → decode")
    func splitsRoundTrip() throws {
        let original = ProjectFile(
            luaVersion: "5.4",
            settings: SettingsConfig(theme: "default", navigatorSplit: 0.4, bottomSplit: 0.45)
        )
        let toml = try ProjectFileCodec.save(original, into: nil)
        let (decoded, _) = try ProjectFileCodec.decode(toml)
        #expect(decoded.settings.navigatorSplit == 0.4)
        #expect(decoded.settings.bottomSplit == 0.45)
        #expect(decoded.settings == original.settings)
    }

    @Test("save is byte-stable across a decode→save cycle")
    func splitsByteStable() throws {
        let pf = ProjectFile(
            luaVersion: "5.4",
            settings: SettingsConfig(theme: "default", navigatorSplit: 0.3, bottomSplit: 0.5)
        )
        let first = try ProjectFileCodec.save(pf, into: nil)
        let (decoded, _) = try ProjectFileCodec.decode(first)
        let second = try ProjectFileCodec.save(decoded, into: first)
        #expect(first == second)
    }

    @Test("[settings] with only theme decodes to default splits (back-compat)")
    func themeOnlyDefaultsSplits() throws {
        let toml = """
            lua_version = "5.4"

            [settings]
            theme = "default"
            """
        let (decoded, _) = try ProjectFileCodec.decode(toml)
        #expect(decoded.settings.navigatorSplit == SettingsConfig.navigatorSplitDefault)
        #expect(decoded.settings.bottomSplit == SettingsConfig.bottomSplitDefault)
    }

    @Test("explicit split values decode verbatim (no clamp at decode)")
    func splitsDecodeVerbatim() throws {
        let toml = """
            lua_version = "5.4"

            [settings]
            navigator_split = 0.9
            bottom_split = 0.45
            """
        let (decoded, _) = try ProjectFileCodec.decode(toml)
        // Out-of-range value is preserved (validation flags it; clamp is on apply).
        #expect(decoded.settings.navigatorSplit == 0.9)
        #expect(decoded.settings.bottomSplit == 0.45)
    }
}

// MARK: - Validation (exact binding diagnostics) + clamp-on-apply

@Suite("F5.6 — split-ratio validation + clamp")
struct SettingsSplitValidationTests {

    @Test("out-of-range navigator_split yields the exact diagnostic and clamps to 0.50")
    func navigatorSplitOutOfRange() {
        let settings = SettingsConfig(theme: "default", navigatorSplit: 0.9, bottomSplit: 0.30)
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateSettingsSplits(settings, into: &diagnostics)
        #expect(
            diagnostics.contains { $0.message == "settings.navigator_split 0.9 out of range [0.10, 0.50]" },
            "expected the exact navigator_split range diagnostic")
        #expect(settings.clampedNavigatorSplit == 0.50)
    }

    @Test("out-of-range bottom_split yields the exact diagnostic and clamps to 0.10")
    func bottomSplitOutOfRange() {
        let settings = SettingsConfig(theme: "default", navigatorSplit: 0.25, bottomSplit: 0.05)
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateSettingsSplits(settings, into: &diagnostics)
        #expect(
            diagnostics.contains { $0.message == "settings.bottom_split 0.05 out of range [0.10, 0.60]" },
            "expected the exact bottom_split range diagnostic")
        #expect(settings.clampedBottomSplit == 0.10)
    }

    @Test("in-range splits produce no diagnostic")
    func inRangeNoDiagnostic() {
        let settings = SettingsConfig(theme: "default", navigatorSplit: 0.25, bottomSplit: 0.30)
        var diagnostics: [Diagnostic] = []
        ProjectValidation.validateSettingsSplits(settings, into: &diagnostics)
        #expect(diagnostics.isEmpty)
    }

    @Test("boundary values are in range (inclusive)")
    func boundariesInclusive() {
        for nav in [0.10, 0.50] {
            var d: [Diagnostic] = []
            ProjectValidation.validateSettingsSplits(
                SettingsConfig(navigatorSplit: nav, bottomSplit: 0.30), into: &d)
            #expect(d.isEmpty, "navigator_split \(nav) should be in range")
        }
    }
}
