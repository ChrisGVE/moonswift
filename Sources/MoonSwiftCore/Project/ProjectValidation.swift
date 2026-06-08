// File: Sources/MoonSwiftCore/Project/ProjectValidation.swift
// Role: All F2 validation rules for moonswift.toml. Each rule is a distinct,
//       separately-testable function that appends to a diagnostic collector.
//       Validation is collect-all (not fail-fast): every rule runs regardless of
//       prior failures so the user sees all problems in one load.
//
//       Catalog integration point for extraModules (ARCHITECTURE.md §7.3):
//       The allow-list of valid `.optIn` module names is injected as a closure
//       parameter `extraModulesAllowList`. The default is now the real catalog
//       query: `LuaModuleCatalog.v0.optInNames`. Tests that need a custom list
//       pass an explicit closure. The seam is fully wired as of task 27.
//
//       #22 compile-time condition (ARCHITECTURE.md §3c): `wall_clock_limit_ms`
//       requires the #22 cooperative-cancellation API. The warning is emitted
//       when the field is set > 0 in a binary compiled without #22 support. The
//       condition is driven by the `MOONSWIFT_HAS_LUASWIFT_22` compile
//       condition. Until LuaSwift#22 is released, no binary has it, so the
//       warning always fires for wall_clock_limit_ms > 0.
//
// Upstream: ProjectFile model, Diagnostic
// Downstream: ProjectStore (collects and surfaces diagnostics)

import Foundation

// MARK: - ProjectValidation

/// Stateless validator. Implements every F2 validation rule.
public enum ProjectValidation {

    // MARK: - Public entry point

    /// Validates `projectFile` and returns all diagnostics.
    ///
    /// - Parameters:
    ///   - projectFile: The decoded project file to validate.
    ///   - unknownKeyDiagnostics: Diagnostics collected by `ProjectFileCodec`
    ///     for unknown TOML keys (forwarded unchanged).
    ///   - extraModulesAllowList: Closure returning the set of valid `.optIn`
    ///     module names. Defaults to `LuaModuleCatalog.v0.optInNames` — the
    ///     canonical opt-in set from the catalog. Pass a custom closure in tests.
    ///     The closure is called at most once per validate invocation.
    /// - Returns: All collected diagnostics. Empty = the file is valid.
    public static func validate(
        _ projectFile: ProjectFile,
        unknownKeyDiagnostics: [Diagnostic] = [],
        extraModulesAllowList: () -> Set<String> = { LuaModuleCatalog.v0.optInNames }
    ) -> [Diagnostic] {

        var diagnostics: [Diagnostic] = []

        // Forward codec-collected unknown-key warnings.
        diagnostics.append(contentsOf: unknownKeyDiagnostics)

        // Rule 1 — lua_version.
        validateLuaVersion(projectFile.luaVersion, into: &diagnostics)

        // Rules 2-4 — sources (path presence handled by codec; we validate
        // absolute/escape and duplicates here).
        validateSources(projectFile.sources, into: &diagnostics)

        // Rule 5 — run.config.
        validateRunConfig(projectFile.run, into: &diagnostics)

        // Rules 6-7 — run limits.
        validateRunLimits(projectFile.run, into: &diagnostics)

        // Rule 8 — settings.theme.
        validateSettingsTheme(projectFile.settings, into: &diagnostics)

        // Rule 9 — lint.extra_modules allow-list.
        let allowList = extraModulesAllowList()
        validateExtraModules(projectFile.lint.extraModules, allowList: allowList, into: &diagnostics)

        return diagnostics
    }

    // MARK: - Rule 1: lua_version

    /// Validates `lua_version`. P1 accepts only `"5.4"`. Any other value loads
    /// the project read-only with run/lint disabled. The diagnostic message is
    /// guidance-style so the user knows what to do.
    static func validateLuaVersion(_ version: String, into diagnostics: inout [Diagnostic]) {
        guard version == "5.4" else {
            diagnostics.append(
                .projectError(
                    "lua_version \"\(version)\" is not supported by this build — "
                        + "MoonSwift P1 requires lua_version = \"5.4\"; "
                        + "run and lint are disabled until the version is updated"
                )
            )
            return
        }
    }

    // MARK: - Rules 2-4: sources

    /// Validates all `[[source]]` entries:
    /// - Rule 2: `path` must not be absolute.
    /// - Rule 3: `path` must not escape the project root (leading `../`).
    /// - Rule 4: No duplicate source paths.
    /// - Rule 4b: `document` must be 0 for non-YAML files (JSON/TOML do not
    ///   support multi-document; validation is by extension).
    static func validateSources(_ sources: [SourceEntry], into diagnostics: inout [Diagnostic]) {
        var seenPaths: [String: Int] = [:]  // path → first-seen index

        for (index, entry) in sources.enumerated() {
            let path = entry.path

            // Rule 2: absolute path rejected.
            if path.hasPrefix("/") {
                diagnostics.append(
                    .projectError(
                        "source[\(index)].path \"\(path)\" is an absolute path — "
                            + "source paths must be relative to the project root"
                    )
                )
            }

            // Rule 3: must not escape the project root.
            if escapesProjectRoot(path) {
                diagnostics.append(
                    .projectError(
                        "source[\(index)].path \"\(path)\" escapes the project root — "
                            + "paths must not traverse above the project directory"
                    )
                )
            }

            // Rule 4: duplicate path.
            if let firstIndex = seenPaths[path] {
                diagnostics.append(
                    .projectError(
                        "source[\(index)].path \"\(path)\" is a duplicate of "
                            + "source[\(firstIndex)].path — each source path must be unique"
                    )
                )
            } else {
                seenPaths[path] = index
            }

            // Rule 4b: document index on non-YAML files.
            for (fieldIndex, field) in entry.fields.enumerated() where field.document != 0 {
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                if ext == "json" || ext == "toml" {
                    diagnostics.append(
                        .projectError(
                            "source[\(index)].field[\(fieldIndex)].document = \(field.document) "
                                + "is not valid for \"\(path)\" — "
                                + "the `document` key is only meaningful for YAML multi-document files"
                        )
                    )
                }
            }

            // Rule: JSONPath syntax — parsed and validated via JSONPathExpression.
            for (fieldIndex, field) in entry.fields.enumerated() {
                validateJSONPathSyntax(
                    field.jsonpath,
                    sourceIndex: index,
                    fieldIndex: fieldIndex,
                    into: &diagnostics
                )
            }
        }
    }

    // MARK: - Rule 5: run.config

    /// Validates `run.config`. The codec decodes unknown values as `.sandboxed`
    /// (the safe default), but we also validate the raw string from the model to
    /// catch any value that wasn't in `RunConfigMode.allCases`.
    ///
    /// Note: because `ProjectFileCodec` uses `RunConfigMode(rawValue:) ?? .sandboxed`,
    /// an unrecognised value silently falls back. ProjectStore must pass the raw
    /// config string through a separate path to detect this, OR we validate by
    /// checking the model against the original string. Since the model carries the
    /// decoded enum, this rule is enforced at the codec level by keeping the
    /// `rawConfigString` on the model — however, for P1 the model does not expose
    /// the raw string. Instead we note that validation of the enum is already
    /// enforced by the codec's `RunConfigMode(rawValue:) ?? .sandboxed` pattern.
    /// A separate raw-string check requires threading through the raw value, which
    /// is a P1 scope decision. This rule therefore validates that the codec's
    /// fallback did not silently accept a bad value by checking through ProjectStore.
    ///
    /// **Decision:** `ProjectFileCodec` is updated to expose `rawRunConfig` as
    /// a separate return value in `ProjectStore.load`. For task 12, the validation
    /// function accepts the raw string obtained before RunConfigMode parsing so the
    /// rule fires correctly.
    static func validateRunConfig(rawConfigString: String, into diagnostics: inout [Diagnostic]) {
        let valid = RunConfigMode.allCases.map(\.rawValue)
        guard valid.contains(rawConfigString) else {
            diagnostics.append(
                .projectError(
                    "run.config \"\(rawConfigString)\" is not valid — "
                        + "accepted values: \(valid.map { "\"\($0)\"" }.joined(separator: ", "))"
                )
            )
            return
        }
    }

    // Overload called from `validate(_:)` which uses the already-decoded model.
    // The codec always normalises unknown run.config values to .sandboxed, so an
    // unrecognised string is silently swallowed unless the raw string is checked.
    // ProjectStore.load does this check before constructing ProjectFile.
    private static func validateRunConfig(_ run: RunConfig, into diagnostics: inout [Diagnostic]) {
        // At this point run.config is already a typed enum — any invalid raw string
        // was caught by ProjectStore before calling validate(). Nothing to do here.
        _ = run
    }

    // MARK: - Rules 6-7: run limits

    /// Validates `instruction_limit` and `wall_clock_limit_ms`.
    /// - Negative instruction_limit: error.
    /// - Negative wall_clock_limit_ms: error.
    /// - wall_clock_limit_ms > 0 without #22: warning.
    static func validateRunLimits(_ run: RunConfig, into diagnostics: inout [Diagnostic]) {

        // Rule 6: instruction_limit must not be negative.
        if run.instructionLimit < 0 {
            diagnostics.append(
                .projectError(
                    "run.instruction_limit \(run.instructionLimit) is negative — "
                        + "use 0 for unlimited or a positive integer to set a limit"
                )
            )
        }

        // Rule 7: wall_clock_limit_ms must not be negative.
        if run.wallClockLimitMs < 0 {
            diagnostics.append(
                .projectError(
                    "run.wall_clock_limit_ms \(run.wallClockLimitMs) is negative — "
                        + "use 0 for unlimited or a positive integer to set a limit"
                )
            )
        }

        // Rule 7b: wall_clock_limit_ms > 0 without #22 — warning.
        // The #22 compile condition is represented by
        // MOONSWIFT_HAS_LUASWIFT_22. Until that condition is set (i.e. until
        // LuaSwift#22 is released and MoonSwift is updated to consume it),
        // this warning fires for any wall_clock_limit_ms > 0.
        if run.wallClockLimitMs > 0 && !ProjectValidation.hasLuaSwift22Support {
            diagnostics.append(
                .projectWarning(
                    "run.wall_clock_limit_ms is set but has no effect in this build — "
                        + "wall-clock limits require LuaSwift cooperative-cancellation support "
                        + "(LuaSwift#22), which is not yet available; "
                        + "the run will continue to its natural end or instruction_limit"
                )
            )
        }
    }

    // MARK: - Rule 8: settings.theme

    /// Validates `settings.theme`. P1 valid value: `"default"`.
    static func validateSettingsTheme(_ settings: SettingsConfig, into diagnostics: inout [Diagnostic]) {
        let validThemes: Set<String> = ["default"]
        guard validThemes.contains(settings.theme) else {
            diagnostics.append(
                .projectError(
                    "settings.theme \"\(settings.theme)\" is not recognised — " + "P1 supports only theme = \"default\""
                )
            )
            return
        }
    }

    // MARK: - Rule 9: lint.extra_modules allow-list

    /// Validates that each name in `extraModules` is in `allowList`.
    ///
    /// The allow-list is exactly the catalog's `.optIn` module names, sourced
    /// from `LuaModuleCatalog.v0.optInNames` via the `extraModulesAllowList`
    /// closure. Tests that need isolation pass a custom closure.
    static func validateExtraModules(
        _ extraModules: [String],
        allowList: Set<String>,
        into diagnostics: inout [Diagnostic]
    ) {
        for name in extraModules where !allowList.contains(name) {
            diagnostics.append(
                .projectError(
                    "lint.extra_modules contains unknown module \"\(name)\" — "
                        + "valid opt-in modules: \(allowList.sorted().map { "\"\($0)\"" }.joined(separator: ", "))"
                )
            )
        }
    }

    // MARK: - JSONPath syntax validation

    /// Validates JSONPath syntax for a field designation using the RFC 9535
    /// subset parser (`JSONPathExpression(parsing:)`).
    ///
    /// An empty string is rejected with a guidance-style message. A non-empty
    /// but syntactically invalid expression (filter selector, slice, negative
    /// index, etc.) is rejected by the parser and the `JSONPathError`'s
    /// `diagnosticMessage` is surfaced as a project-config error. A valid
    /// expression produces no diagnostic.
    static func validateJSONPathSyntax(
        _ jsonpath: String,
        sourceIndex: Int,
        fieldIndex: Int,
        into diagnostics: inout [Diagnostic]
    ) {
        if jsonpath.isEmpty {
            diagnostics.append(
                .projectError(
                    "source[\(sourceIndex)].field[\(fieldIndex)].jsonpath is empty — "
                        + "a valid RFC 9535 JSONPath expression is required (e.g. \"$.scripts.init\")"
                )
            )
            return
        }
        do {
            _ = try JSONPathExpression(parsing: jsonpath)
        } catch let error {
            diagnostics.append(
                .projectError(
                    "source[\(sourceIndex)].field[\(fieldIndex)].jsonpath \"\(jsonpath)\" "
                        + "is not a valid JSONPath expression — \(error.diagnosticMessage)"
                )
            )
        }
    }

    // MARK: - #22 availability (compile-time condition)

    /// Whether the running binary was compiled with LuaSwift #22 support.
    ///
    /// Controlled by the `MOONSWIFT_HAS_LUASWIFT_22` active compilation
    /// condition. When that condition is absent (i.e. LuaSwift#22 has not
    /// shipped), `wall_clock_limit_ms > 0` emits a warning diagnostic.
    static var hasLuaSwift22Support: Bool {
        #if MOONSWIFT_HAS_LUASWIFT_22
            return true
        #else
            return false
        #endif
    }

    // MARK: - Private helpers

    /// Returns `true` if `path` traverses above the project root.
    ///
    /// A path escapes the project root if any normalised component is `..`
    /// and would ascend past the root. We check by simulating the stack.
    private static func escapesProjectRoot(_ path: String) -> Bool {
        // Split by path separator and simulate navigation.
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty && $0 != "." }
        var depth = 0
        for component in components {
            if component == ".." {
                depth -= 1
                if depth < 0 { return true }
            } else {
                depth += 1
            }
        }
        return false
    }
}

// MARK: - Raw-config validation entry point used by ProjectStore

extension ProjectValidation {

    /// Full validation pass that also checks the raw run.config string (before
    /// the codec normalises unknown values to `.sandboxed`).
    ///
    /// `ProjectStore.load` calls this variant so that an unrecognised
    /// `run.config` value produces a diagnostic rather than silently defaulting.
    public static func validate(
        _ projectFile: ProjectFile,
        rawRunConfig: String?,
        unknownKeyDiagnostics: [Diagnostic] = [],
        extraModulesAllowList: () -> Set<String> = { LuaModuleCatalog.v0.optInNames }
    ) -> [Diagnostic] {

        var diagnostics = validate(
            projectFile,
            unknownKeyDiagnostics: unknownKeyDiagnostics,
            extraModulesAllowList: extraModulesAllowList
        )

        // If a raw run.config string was provided, validate it explicitly.
        if let raw = rawRunConfig {
            validateRunConfig(rawConfigString: raw, into: &diagnostics)
        }

        return diagnostics
    }
}
