// File: Sources/MoonSwiftCore/Diagnostics/Diagnostic.swift
// Role: Diagnostic model — a single finding emitted by validation, lint, run,
//       or syntax pre-pass. All user-visible error/warning information funnels
//       through this type (ARCHITECTURE.md §7.1). The `Diagnostic.from(luaError:
//       provenance:)` helper seam lives in LuaErrorDiagnostics.swift (P2 swaps
//       that body for structured errors from LuaSwift#19 without touching
//       callers). DiagnosticSource is extended as new sources are added in later
//       tasks; project-config diagnostics are the first consumer.
// Upstream: (none — foundational model)
// Downstream: ProjectValidation, LintService, RunService, AppState (via events)

// MARK: - DiagnosticSource

/// The subsystem that produced a `Diagnostic`.
///
/// Extended as new diagnostic sources are added in later tasks. Current sources:
/// - `.projectConfig` — F2 validation rules for `moonswift.toml`
/// - `.syntaxPrePass` — LintService bytecode pre-pass (added with LintService)
/// - `.luacheck`     — vendored luacheck pass (added with LintService)
/// - `.runtime`      — RunService execution error (added with RunService)
/// - `.luals`        — Language Server (P3b)
public enum DiagnosticSource: Sendable, Equatable {
    /// Emitted by `ProjectValidation` for `moonswift.toml` rule violations.
    case projectConfig
    /// Emitted by `LintService`'s `precompile`-based syntax pre-pass.
    case syntaxPrePass
    /// Emitted by the vendored luacheck engine.
    case luacheck
    /// Emitted by `RunService` for runtime or syntax errors.
    case runtime
    /// Emitted by the Lua Language Server (P3b).
    case luals
    /// Emitted by `SourceStore` for file-read failures (I/O errors,
    /// unreadable bytes). Distinct from `.projectConfig` so the renderer can
    /// label source-load errors separately from project-validation errors.
    case sourceLoad
}

// MARK: - Diagnostic

/// A single diagnostic finding — an error or warning with optional location.
///
/// Location fields (`line`, `column`) are fragment-relative (line 1 = first
/// line of the fragment, not the containing file) for code diagnostics.
/// Project-config diagnostics typically omit location (line 0, column nil).
public struct Diagnostic: Sendable, Equatable {

    // MARK: Severity

    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    // MARK: Fields

    /// Error or warning.
    public let severity: Severity

    /// Fragment-relative line number (1-based). Use 0 for diagnostics without
    /// a specific line (e.g. project-config errors).
    public let line: Int

    /// Column (1-based), if known. Nil for diagnostics without column info.
    public let column: Int?

    /// Diagnostic code (e.g. luacheck code `"113"`). Nil if not applicable.
    public let code: String?

    /// Human-readable diagnostic message.
    public let message: String

    /// The subsystem that produced this diagnostic.
    public let source: DiagnosticSource

    // MARK: Initialiser

    public init(
        severity: Severity,
        line: Int = 0,
        column: Int? = nil,
        code: String? = nil,
        message: String,
        source: DiagnosticSource
    ) {
        self.severity = severity
        self.line = line
        self.column = column
        self.code = code
        self.message = message
        self.source = source
    }
}

// MARK: - Convenience factory

extension Diagnostic {

    /// Produces an error-level project-config diagnostic.
    public static func projectError(_ message: String, code: String? = nil) -> Diagnostic {
        Diagnostic(
            severity: .error,
            line: 0,
            column: nil,
            code: code,
            message: message,
            source: .projectConfig
        )
    }

    /// Produces a warning-level project-config diagnostic.
    public static func projectWarning(_ message: String, code: String? = nil) -> Diagnostic {
        Diagnostic(
            severity: .warning,
            line: 0,
            column: nil,
            code: code,
            message: message,
            source: .projectConfig
        )
    }
}
