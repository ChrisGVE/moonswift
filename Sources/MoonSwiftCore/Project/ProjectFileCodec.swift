// File: Sources/MoonSwiftCore/Project/ProjectFileCodec.swift
// Role: TOMLKit-based codec for moonswift.toml. Provides a `decode` function
//       that returns a `ProjectFile` plus any unknown-key warnings, and a `save`
//       function that performs decode-modify-encode on the live document tree so
//       unknown keys and (where TOMLKit preserves them) comments survive
//       programmatic writes.
//
//       Comment-preservation caveat (PRD §4.2, DECIDED): programmatic writes use
//       decode-modify-encode on the TOMLKit document tree. TOML comments in the
//       file MAY be lost on programmatic write. This is an accepted P1 limitation
//       documented in user docs. Hand edits are never reformatted unless
//       MoonSwift writes.
//
//       Unknown-key handling (PRD §4.2): unknown top-level tables/keys produce
//       ONE warning diagnostic and are preserved on programmatic writes (forward
//       compatibility with P2+ schema additions).
//
// Upstream: TOMLKit (TOML parse/emit), ProjectFile model
// Downstream: ProjectStore (the public entry point), ProjectValidation (receives
//             decoded ProjectFile + unknown-key diagnostics)

import Foundation
import TOMLKit

// MARK: - ProjectFileCodec

/// Stateless codec. All operations are static functions.
///
/// Separation of concerns:
/// - `decode` turns TOML text into a `ProjectFile` model + unknown-key warnings.
/// - `save` serialises a `ProjectFile` back into TOML, preserving unknown keys
///   from the original document.
/// - Semantic validation (e.g. lua_version, extraModules allow-list) is handled
///   separately by `ProjectValidation`.
public enum ProjectFileCodec {

    // MARK: - Known top-level keys

    /// P1-recognised top-level keys. Unknown keys trigger one warn diagnostic.
    private static let knownTopLevelKeys: Set<String> = [
        "lua_version", "source", "run", "lint", "settings",
    ]

    // MARK: - Decode

    /// Decodes a TOML string into a `ProjectFile` model.
    ///
    /// - Returns: The decoded `ProjectFile` and a (possibly empty) list of
    ///   `Diagnostic`s for unknown keys. Pass both to
    ///   `ProjectValidation.validate(_:unknownKeyDiagnostics:)` for the full
    ///   diagnostic set.
    /// - Throws: `CodecError.parseFailure` when the TOML is not syntactically
    ///   valid; `CodecError.missingRequiredKey("lua_version")` when the
    ///   required field is absent.
    public static func decode(
        _ tomlString: String
    ) throws(CodecError) -> (projectFile: ProjectFile, unknownKeyDiagnostics: [Diagnostic]) {

        // 1. Parse the raw TOML document tree.
        let table: TOMLTable
        do {
            table = try TOMLTable(string: tomlString)
        } catch {
            throw .parseFailure(underlying: error)
        }

        // 2. Collect unknown-key warning (warn once per load).
        let unknownDiagnostics = collectUnknownKeyDiagnostics(from: table)

        // 3. Decode lua_version (required).
        guard let luaVersion = table["lua_version"]?.string else {
            throw .missingRequiredKey("lua_version")
        }

        // 4. Decode the typed sub-models.
        let sources = decodeSources(from: table)
        let run = decodeRunConfig(from: table)
        let lint = decodeLintConfig(from: table)
        let settings = decodeSettingsConfig(from: table)

        let projectFile = ProjectFile(
            luaVersion: luaVersion,
            sources: sources,
            run: run,
            lint: lint,
            settings: settings
        )
        return (projectFile, unknownDiagnostics)
    }

    // MARK: - Save (decode-modify-encode)

    /// Serialises `projectFile` back to TOML, preserving unknown keys from
    /// `existingTomlString`.
    ///
    /// **Comment-preservation caveat:** TOMLKit's document-tree round-trip may
    /// drop inline comments. This is accepted for P1 (PRD §4.2).
    ///
    /// - Parameters:
    ///   - projectFile: The updated model to serialise.
    ///   - existingTomlString: Current on-disk TOML used as the base document
    ///     so unknown keys survive. Pass `nil` to produce a fresh document.
    /// - Returns: TOML string ready for writing to disk.
    /// - Throws: `CodecError.parseFailure` when `existingTomlString` is invalid.
    public static func save(
        _ projectFile: ProjectFile,
        into existingTomlString: String?
    ) throws(CodecError) -> String {

        // Load the base document (preserves unknown keys from P2+ schema).
        let table: TOMLTable
        if let existing = existingTomlString {
            do {
                table = try TOMLTable(string: existing)
            } catch {
                throw .parseFailure(underlying: error)
            }
        } else {
            table = TOMLTable()
        }

        // Write lua_version.
        table["lua_version"] = TOMLValue(stringLiteral: projectFile.luaVersion)

        // Rebuild [[source]] array.
        table["source"] = TOMLValue(buildSourceArray(projectFile.sources))

        // Write [run] table.
        table["run"] = TOMLValue(buildRunTable(projectFile.run))

        // Write [lint] table.
        table["lint"] = TOMLValue(buildLintTable(projectFile.lint))

        // Write [settings] table.
        table["settings"] = TOMLValue(buildSettingsTable(projectFile.settings))

        return table.convert(to: .toml)
    }

    // MARK: - Private decode helpers

    private static func collectUnknownKeyDiagnostics(from table: TOMLTable) -> [Diagnostic] {
        var hasUnknown = false
        for (key, _) in table where !knownTopLevelKeys.contains(key) {
            hasUnknown = true
            break
        }
        guard hasUnknown else { return [] }
        return [
            .projectWarning(
                "moonswift.toml contains unrecognised key(s) — they are ignored "
                    + "by this build but will be preserved on programmatic writes"
            )
        ]
    }

    private static func decodeSources(from table: TOMLTable) -> [SourceEntry] {
        guard let sourceArray = table["source"]?.array else { return [] }
        var entries: [SourceEntry] = []
        for index in 0..<sourceArray.count {
            guard let sourceTable = sourceArray[index]?.table else { continue }
            guard let path = sourceTable["path"]?.string else { continue }
            let fields = decodeFields(from: sourceTable)
            entries.append(SourceEntry(path: path, fields: fields))
        }
        return entries
    }

    private static func decodeFields(from sourceTable: TOMLTable) -> [FieldDesignation] {
        guard let fieldArray = sourceTable["field"]?.array else { return [] }
        var fields: [FieldDesignation] = []
        for index in 0..<fieldArray.count {
            guard let fieldTable = fieldArray[index]?.table else { continue }
            guard let jsonpath = fieldTable["jsonpath"]?.string else { continue }
            let document = fieldTable["document"]?.int ?? 0
            fields.append(FieldDesignation(jsonpath: jsonpath, document: document))
        }
        return fields
    }

    private static func decodeRunConfig(from table: TOMLTable) -> RunConfig {
        guard let runTable = table["run"]?.table else { return RunConfig() }
        let configRaw = runTable["config"]?.string ?? RunConfigMode.sandboxed.rawValue
        let config = RunConfigMode(rawValue: configRaw) ?? .sandboxed
        let instructionLimit = runTable["instruction_limit"]?.int ?? 0
        let wallClockLimitMs = runTable["wall_clock_limit_ms"]?.int ?? 0
        return RunConfig(
            config: config,
            instructionLimit: instructionLimit,
            wallClockLimitMs: wallClockLimitMs
        )
    }

    private static func decodeLintConfig(from table: TOMLTable) -> LintConfig {
        guard let lintTable = table["lint"]?.table else { return LintConfig() }
        guard let extraArray = lintTable["extra_modules"]?.array else {
            return LintConfig()
        }
        var modules: [String] = []
        for index in 0..<extraArray.count {
            if let name = extraArray[index]?.string {
                modules.append(name)
            }
        }
        return LintConfig(extraModules: modules)
    }

    private static func decodeSettingsConfig(from table: TOMLTable) -> SettingsConfig {
        guard let settingsTable = table["settings"]?.table else {
            return SettingsConfig()
        }
        let theme = settingsTable["theme"]?.string ?? "default"
        return SettingsConfig(theme: theme)
    }

    // MARK: - Private save helpers

    private static func buildSourceArray(_ sources: [SourceEntry]) -> TOMLArray {
        let array = TOMLArray()
        for entry in sources {
            let sourceTable = TOMLTable()
            sourceTable["path"] = TOMLValue(stringLiteral: entry.path)
            if !entry.fields.isEmpty {
                sourceTable["field"] = TOMLValue(buildFieldArray(entry.fields))
            }
            array.append(TOMLValue(sourceTable))
        }
        return array
    }

    private static func buildFieldArray(_ fields: [FieldDesignation]) -> TOMLArray {
        let array = TOMLArray()
        for field in fields {
            let fieldTable = TOMLTable()
            fieldTable["jsonpath"] = TOMLValue(stringLiteral: field.jsonpath)
            if field.document != 0 {
                fieldTable["document"] = TOMLValue(integerLiteral: field.document)
            }
            array.append(TOMLValue(fieldTable))
        }
        return array
    }

    private static func buildRunTable(_ run: RunConfig) -> TOMLTable {
        let t = TOMLTable()
        t["config"] = TOMLValue(stringLiteral: run.config.rawValue)
        t["instruction_limit"] = TOMLValue(integerLiteral: run.instructionLimit)
        t["wall_clock_limit_ms"] = TOMLValue(integerLiteral: run.wallClockLimitMs)
        return t
    }

    private static func buildLintTable(_ lint: LintConfig) -> TOMLTable {
        let t = TOMLTable()
        let array = TOMLArray()
        for mod in lint.extraModules {
            array.append(TOMLValue(stringLiteral: mod))
        }
        t["extra_modules"] = TOMLValue(array)
        return t
    }

    private static func buildSettingsTable(_ settings: SettingsConfig) -> TOMLTable {
        let t = TOMLTable()
        t["theme"] = TOMLValue(stringLiteral: settings.theme)
        return t
    }
}

// MARK: - CodecError

/// Errors emitted by `ProjectFileCodec`.
public enum CodecError: Error, Sendable {

    /// The TOML source is syntactically invalid. The `underlying` error is a
    /// `TOMLParseError` from TOMLKit with line/column information.
    case parseFailure(underlying: Error)

    /// A required key was absent from the document. The associated value is
    /// the key name.
    case missingRequiredKey(String)
}

// Custom `Equatable` so tests can pattern-match without comparing `Error`.
extension CodecError: Equatable {
    public static func == (lhs: CodecError, rhs: CodecError) -> Bool {
        switch (lhs, rhs) {
        case (.parseFailure, .parseFailure): return true
        case let (.missingRequiredKey(a), .missingRequiredKey(b)): return a == b
        default: return false
        }
    }
}
