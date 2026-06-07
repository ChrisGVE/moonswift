// File: Sources/MoonSwiftCore/Project/ProjectFile.swift
// Role: Typed model for moonswift.toml — the decoded, validated representation
//       of a project file. All fields map directly to the normative schema
//       (PRD §4.2). Encoding/decoding lives in ProjectFileCodec.swift;
//       validation rules live in ProjectValidation.swift.
// Upstream: (none — pure data model)
// Downstream: ProjectFileCodec (decode target), ProjectValidation (validates),
//             AppState (holds ProjectFile after load), RunService (RunConfig),
//             LintService (LintConfig.extraModules)

import Foundation

// MARK: - Top-level model

/// The decoded, in-memory representation of a `moonswift.toml` project file.
///
/// All fields carry their decoded values; validation diagnostics are computed
/// separately by `ProjectValidation` so load and validation are decoupled.
/// Unknown TOML keys are not modelled here — `ProjectFileCodec` collects them
/// for the warn-once diagnostic and preserves them in the document tree.
public struct ProjectFile: Sendable, Equatable {

    /// Lua version declared by the project. P1 accepts only `"5.4"`.
    /// Other values load the project read-only with run/lint disabled.
    public let luaVersion: String

    /// Ordered list of source entries (files or structured fields).
    public let sources: [SourceEntry]

    /// Run-time configuration. Nil means the `[run]` table was absent;
    /// defaults apply (sandboxed, unlimited).
    public let run: RunConfig

    /// Lint configuration. Nil means `[lint]` was absent; defaults apply.
    public let lint: LintConfig

    /// User-visible settings (theme). Nil means `[settings]` was absent.
    public let settings: SettingsConfig

    public init(
        luaVersion: String,
        sources: [SourceEntry] = [],
        run: RunConfig = RunConfig(),
        lint: LintConfig = LintConfig(),
        settings: SettingsConfig = SettingsConfig()
    ) {
        self.luaVersion = luaVersion
        self.sources = sources
        self.run = run
        self.lint = lint
        self.settings = settings
    }
}

// MARK: - SourceEntry

/// One `[[source]]` entry in the project file.
///
/// A source entry refers to either a standalone `.lua` file (`fields` is
/// empty) or a structured file (JSON/YAML/TOML) whose designated string
/// fields each contain a Lua snippet.
public struct SourceEntry: Sendable, Equatable {

    /// Project-root-relative path to the source file. Absolute paths and
    /// paths that escape the project root are rejected by `ProjectValidation`.
    public let path: String

    /// Zero or more field designations for structured files. Empty for
    /// standalone `.lua` files.
    public let fields: [FieldDesignation]

    public init(path: String, fields: [FieldDesignation] = []) {
        self.path = path
        self.fields = fields
    }
}

// MARK: - FieldDesignation

/// One `[[source.field]]` designation — a JSONPath expression selecting a
/// string value inside a structured source file.
public struct FieldDesignation: Sendable, Equatable {

    /// RFC 9535 subset JSONPath expression (e.g. `"$.scripts.init"`).
    public let jsonpath: String

    /// YAML multi-document index. Defaults to 0; invalid for JSON/TOML.
    public let document: Int

    public init(jsonpath: String, document: Int = 0) {
        self.jsonpath = jsonpath
        self.document = document
    }
}

// MARK: - RunConfig

/// Decoded `[run]` table. All fields carry defaults when the table or key
/// was absent in the TOML source.
public struct RunConfig: Sendable, Equatable {

    /// Engine configuration mode. Maps to `LuaEngineConfiguration.default`
    /// (sandboxed) or `.unrestricted`. Default: `.sandboxed`.
    public let config: RunConfigMode

    /// Instruction limit passed to `setInstructionLimit(_:)` after engine
    /// creation. `0` means unlimited (default).
    public let instructionLimit: Int

    /// Wall-clock timeout in milliseconds, using the #22 cancellation path.
    /// `0` means unlimited (default). Requires the `#22` build condition;
    /// `ProjectValidation` emits a warning when > 0 in a binary compiled
    /// without #22 support.
    public let wallClockLimitMs: Int

    public init(
        config: RunConfigMode = .sandboxed,
        instructionLimit: Int = 0,
        wallClockLimitMs: Int = 0
    ) {
        self.config = config
        self.instructionLimit = instructionLimit
        self.wallClockLimitMs = wallClockLimitMs
    }
}

/// Engine configuration mode declared by the project.
public enum RunConfigMode: String, Sendable, Equatable, CaseIterable {
    /// Sandboxed execution: `io`, `debug`, and unsafe OS/load functions are
    /// stripped. Maps to `LuaEngineConfiguration.default`.
    case sandboxed

    /// Unrestricted execution: all Lua globals available.
    /// Maps to `LuaEngineConfiguration.unrestricted`. Surfaced in the title
    /// bar with a warning indicator.
    case unrestricted
}

// MARK: - LintConfig

/// Decoded `[lint]` table.
public struct LintConfig: Sendable, Equatable {

    /// Names of `.optIn` catalog modules to treat as known globals during
    /// linting. Each name must appear in the catalog's `.optIn` allow-list;
    /// unknown names are rejected by `ProjectValidation`.
    ///
    /// P1 allow-list: `["iox", "http", "ui"]`. The catalog integration point
    /// is the `extraModulesAllowList` closure injected into
    /// `ProjectValidation` — task 27 replaces the stub list with the real
    /// catalog query.
    public let extraModules: [String]

    public init(extraModules: [String] = []) {
        self.extraModules = extraModules
    }
}

// MARK: - SettingsConfig

/// Decoded `[settings]` table.
public struct SettingsConfig: Sendable, Equatable {

    /// Active UI theme. P1 valid value: `"default"`. P2 will add more.
    public let theme: String

    public init(theme: String = "default") {
        self.theme = theme
    }
}
