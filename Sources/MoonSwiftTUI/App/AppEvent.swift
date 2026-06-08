// File: Sources/MoonSwiftTUI/App/AppEvent.swift
// Location: MoonSwiftTUI/App/
// Role: Defines every input the Elm-style reducer can process. All mutations
//       to AppState enter as an AppEvent — key presses, service callbacks,
//       terminal resizes, tick pulses, and lifecycle signals. Nothing writes
//       AppState except the reducer after receiving one of these events.
// Upstream: RatatuiKit (KeyCode, KeyModifiers, TerminalSize), MoonSwiftCore
//           (SourceID, LuaSourceFragment, Diagnostic, SourceLoadEvent)
// Downstream: EventChannel (carries events), Reducer (consumes events),
//             EventPump (produces key/resize/mouse/paste events),
//             TickSource (produces .tick), AppDriver (posts service results)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - RunOutcome

/// The result of a single run attempt, posted via AppEvent.runFinished.
///
/// Mirrors the terminal-free `RunServiceProtocol.run` return (PRD §4.3) but is
/// declared here because it lives in AppEvent, which is TUI-layer.
public enum RunOutcome: Sendable {
    /// The script executed to completion. `value` is a non-nil return if the
    /// evaluated chunk returned one; `duration` is wall-clock run time.
    case done(value: String?, duration: Duration)
    /// A syntax or runtime error occurred. The `Diagnostic` is fragment-relative.
    case error(Diagnostic, traceback: [String])
    /// The user cancelled the run (#22 cooperative cancellation).
    case cancelled
    /// An instruction or wall-clock limit was exceeded.
    case limitExceeded(kind: LimitKind)
    /// The Lua engine itself failed (not a script error) — e.g. state corruption,
    /// sandboxing failure, or LuaSwift internal error. Distinct from `.error`
    /// which is a script-level runtime error (ux-spec §4.2 "Lua engine error").
    case engineError(String)
}

extension RunOutcome: Equatable {
    public static func == (lhs: RunOutcome, rhs: RunOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.done(let lv, _), .done(let rv, _)):
            return lv == rv
        case (.error(let ld, let lt), .error(let rd, let rt)):
            return ld == rd && lt == rt
        case (.cancelled, .cancelled):
            return true
        case (.limitExceeded(let lk), .limitExceeded(let rk)):
            return lk == rk
        case (.engineError(let lm), .engineError(let rm)):
            return lm == rm
        default:
            return false
        }
    }
}

/// The kind of resource limit that ended a run.
public enum LimitKind: Sendable {
    case instructions
    case wallClock
}

// MARK: - AppEvent

/// Every input that can change `AppState`.
///
/// The event vocabulary covers five sources:
///   1. Terminal input (key, resize, mouse, paste) — from EventPump
///   2. Tick pulses — from TickSource
///   3. Lifecycle signals — from AppDriver at startup / quit
///   4. Service callbacks — from RunService, LintService, SourceStore,
///      ProjectStore, Highlighter, posted by AppDriver-constructed closures
///   5. Internal state signals — from the reducer itself via effects
///
/// All cross-thread events are `Sendable`; the EventChannel is the only
/// conduit into the loop (ARCHITECTURE.md §5.1).
public enum AppEvent: Sendable {

    // MARK: Lifecycle

    /// Posted by the AppDriver immediately after construction; the reducer
    /// returns Effect.loadSources and other startup effects (ARCH §3a).
    case appStarted

    // MARK: Terminal input (EventPump → EventChannel)

    /// A key was pressed. The reducer dispatches based on focus and key.
    case key(KeyCode, modifiers: KeyModifiers)

    /// The terminal was resized.
    case resize(TerminalSize)

    /// A mouse event occurred.
    case mouse(
        kind: MouseKind,
        button: MouseButton,
        col: UInt16,
        row: UInt16,
        modifiers: KeyModifiers
    )

    /// Bracketed-paste text was received.
    case paste(String)

    // MARK: Tick source

    /// Posted by TickSource at the armed interval; drives coalescer flushes,
    /// highlight pulses, and transient expiry (ARCHITECTURE.md §3b, §3c).
    case tick

    // MARK: Project and source loading (SourceStore / ProjectStore callbacks)

    /// A source loaded successfully.
    case sourceLoaded(id: SourceID, fragment: LuaSourceFragment)

    /// A source failed to load (missing file, I/O error, structured-file error).
    case sourceFailed(id: SourceID, state: SourceState)

    /// The project file was (re)loaded.
    case projectLoaded(ProjectFile, diagnostics: [Diagnostic])

    /// The project file is malformed and could not be decoded.
    case projectMalformed(Diagnostic)

    /// Designations were saved to the project file.
    case designationsSaved

    /// The structured-file picker tree has been parsed and is ready to display.
    ///
    /// Posted by the AppDriver after `Effect.loadPickerTree` completes. On
    /// success, `tree` is non-nil. On parse failure, `tree` is nil and
    /// `errorMessage` carries the human-readable parse error — the picker
    /// shows "Cannot parse file: <errorMessage>" (ux-spec §3.6).
    case pickerTreeReady(SourceID, tree: TreeValue?, errorMessage: String?)

    // MARK: Run service (RunService callbacks)

    /// One or more output lines from the running script (batched by Coalescer).
    case runOutput([String])

    /// The run completed (success, error, cancelled, or limit).
    case runFinished(RunOutcome)

    /// A transient status-bar message requested by a service callback.
    ///
    /// Posted by AppDriver-constructed closures — currently `RunService`'s
    /// `onTransient` (the LuaSwift#22-absent cancel degradation path). The
    /// reducer sets `AppState.transient` and arms the tick for its expiry.
    case transient(String)

    // MARK: Lint service (LintService callbacks)

    /// The lint engine is ready to accept requests.
    case lintEngineReady

    /// The lint engine failed to initialise (diagnostic carries the reason).
    case lintEngineFailed(String)

    /// The one-shot startup probe determined whether luaswift.toml is available.
    case catalogProbed(tomlAvailable: Bool)

    /// The syntax pre-pass completed. `nil` means no syntax error.
    case prePassResult(Diagnostic?)

    /// A full luacheck pass completed with zero or more diagnostics.
    case lintFinished([Diagnostic])

    // MARK: Highlighter (Highlighter callback)

    /// Tree-sitter highlight spans are ready for the given source. The reducer
    /// applies these to AppState.highlight (ARCHITECTURE.md §2 Highlighter row).
    case highlightReady(SourceID, spans: [HighlightSpan])

    // MARK: Init form (task 24)

    /// The project-directory scan completed. `files` is the sorted list of
    /// candidate paths (.lua/.json/.yaml/.toml relative to the project directory).
    case projectDirectoryScanned([String])

    /// The project file write completed. On success `projectURL` is the written
    /// file URL; on failure `error` carries the reason (used for a transient).
    case projectFileWritten(projectURL: URL?, error: String?)
}

// MARK: - HighlightSpan

/// One syntax-highlighted span within a source fragment.
///
/// `line` and `column` are 0-based fragment-relative positions. `length` is
/// the span's character count. `tokenKind` identifies the semantic token type
/// mapped from a tree-sitter capture name via CaptureMapping.
public struct HighlightSpan: Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let length: Int
    public let tokenKind: ThemeToken

    public init(line: Int, column: Int, length: Int, tokenKind: ThemeToken) {
        self.line = line
        self.column = column
        self.length = length
        self.tokenKind = tokenKind
    }
}

// MARK: - ThemeToken

/// Semantic token types used by the ThemeEngine and Highlighter.
///
/// The 18 canonical tokens are defined in ux-spec.md §8.1 and cover all P1 UI
/// surfaces. Swift case names follow camelCase; the spec uses snake_case. All
/// names match the spec directly except `operatorToken`: `operator` is a Swift
/// reserved word, so the case is spelled `operatorToken` while the spec name
/// is `operator`. This deviation is intentional and documented here to prevent
/// any future reader from "fixing" it back to `.operator`.
public enum ThemeToken: Sendable, Equatable, CaseIterable {
    // Syntax highlight tokens (ux-spec §8.1, §8.2)
    case keyword  // Lua keywords
    case string  // String literals
    case comment  // Line/block comments
    case number  // Numeric literals
    case functionName  // Function/method declaration names (spec: function_name)
    case identifier  // Local variables, parameters, field access
    case operatorToken  // Operators (spec: operator — reserved word in Swift)
    // Diagnostic and status tokens
    case error  // Error-severity diagnostics; ✖ prefixes
    case warning  // Warning-severity diagnostics; ⚠ prefixes
    case added  // Picker marks (●); newly-added items
    // UI chrome tokens
    case focusBorder  // Focused pane border; active tab underline (spec: focus_border)
    case focusBg  // Cursor-line background; cursor-row ▶ gutter mark (spec: focus_bg)
    case highlightBg  // Jump-target line background, persistent (spec: highlight_bg)
    case highlightPulse  // 500 ms pulse animation start color (spec: highlight_pulse)
    case dim  // Non-markable fields, dividers, secondary labels
    case running  // [running…] status indicator; spinner color
    case gutterBg  // Gutter column background (line numbers + marks) (spec: gutter_bg)
    case paneBg  // Default pane content background (spec: pane_bg)
}
