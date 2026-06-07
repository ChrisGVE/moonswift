// File: Sources/MoonSwiftTUI/App/AppState.swift
// Location: MoonSwiftTUI/App/
// Role: Defines the single value-semantics application state that the
//       Elm-style reducer owns. Every mutable piece of UI truth lives here;
//       nothing else mutates anything (ARCHITECTURE.md §1, §4.2).
//       `AppState` is a `Sendable` struct so it can cross actor boundaries
//       safely under Swift 6 strict concurrency.
// Upstream: MoonSwiftCore (ProjectFile, SourceID, SourceState, Diagnostic,
//           LuaSourceFragment), AppEvent (HighlightSpan, ThemeToken, RunOutcome)
// Downstream: Reducer.swift (produces AppState), Renderer.swift (reads AppState)

import Foundation
import MoonSwiftCore

// MARK: - PaneID

/// Identifies the focused pane (ARCHITECTURE.md §4.2, ux-spec.md §2.1).
///
/// The single focus token is held in `AppState.focus`. Only one pane or
/// modal receives keyboard input at a time.
public enum PaneID: Sendable, Equatable {
    case navigator
    case codePane
    case bottomPane
}

// MARK: - FocusState

/// The current focus: which pane is active and whether a modal overlay is open.
///
/// Modal states capture all keyboard input and overlay the pane system.
/// Only one modal may be open at a time; modals are stacked conceptually
/// but in P1 only one level of overlay exists.
public enum FocusState: Sendable, Equatable {
    /// One of the three panes holds focus; no modal is open.
    case pane(PaneID)
    /// The help overlay is visible.
    case helpOverlay
    /// The structured-file picker modal is open.
    case pickerModal
    /// The project-initialisation form is open.
    case initForm
}

// MARK: - LaunchMode

/// How `moonswift` was invoked (ARCHITECTURE.md §4.2).
public enum LaunchMode: Sendable, Equatable {
    /// Opened a directory or the current working directory as a project.
    case project(URL)
    /// Opened a single `.lua` file directly (no project file needed).
    case quickFile(URL)
    /// No path argument — empty state, offering to create a project file.
    case empty
}

// MARK: - ProjectState

/// The load/validation state of the project file (ARCHITECTURE.md §4.2).
public enum ProjectState: Sendable, Equatable {
    /// No project file has been loaded (empty mode or loading in progress).
    case none
    /// The project file decoded and validated successfully.
    case loaded(ProjectFile, diagnostics: [Diagnostic])
    /// The project file exists but could not be decoded (TOML parse error).
    case malformed(Diagnostic)
    /// The project file decoded but specifies an unsupported Lua version.
    case unsupportedVersion(String)
}

// MARK: - RunState

/// The state of the most recent or active script run.
public enum RunState: Sendable {
    /// No run has been started this session.
    case idle
    /// A run is in progress. `id` disambiguates concurrent-run guards.
    case running(id: UUID, startedAt: Date)
    /// The last run completed.
    case completed(RunOutcome)
}

extension RunState: Equatable {
    public static func == (lhs: RunState, rhs: RunState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.running(let lid, _), .running(let rid, _)):
            return lid == rid
        case (.completed(let lo), .completed(let ro)):
            return lo == ro
        default:
            return false
        }
    }
}

// MARK: - LintState

/// The state of the lint engine and any in-progress lint.
public enum LintState: Sendable, Equatable {
    /// The lint engine has not yet been pre-warmed.
    case initializing
    /// The engine is ready; no lint is running.
    case idle
    /// A lint pass is running.
    case running
    /// The lint engine failed to start or crashed; message carries the reason.
    case failed(String)
}

// MARK: - CodePaneState

/// Scroll and cursor state for the code pane.
public struct CodePaneState: Sendable, Equatable {
    /// First visible line (0-based).
    public var scrollOffset: Int
    /// The line the cursor is on (0-based, for jump / highlight pulse).
    public var cursorLine: Int
    /// When non-nil, the code pane is showing a 500 ms highlight pulse on this
    /// line (posted after a diagnostic jump — ux-spec.md §3.5).
    public var jumpPulseLine: Int?
    /// Gutter diagnostic marks by line (0-based fragment-relative lines).
    public var gutterMarks: [Int: GutterMark]

    public init(
        scrollOffset: Int = 0,
        cursorLine: Int = 0,
        jumpPulseLine: Int? = nil,
        gutterMarks: [Int: GutterMark] = [:]
    ) {
        self.scrollOffset = scrollOffset
        self.cursorLine = cursorLine
        self.jumpPulseLine = jumpPulseLine
        self.gutterMarks = gutterMarks
    }
}

/// A gutter mark indicating a lint/run diagnostic at a specific line.
public enum GutterMark: Sendable, Equatable {
    case error
    case warning
}

// MARK: - BottomPaneState

/// The state of the bottom pane (tabs, output buffer, diagnostics).
public struct BottomPaneState: Sendable, Equatable {

    /// The active tab in the bottom pane.
    public enum Tab: Sendable, Equatable {
        case output
        case diagnostics
    }

    public var activeTab: Tab
    /// Output lines from the current/last run (capped at 1000 — ARCH §3c).
    public var outputBuffer: [String]
    /// Diagnostics from the most recent pre-pass or luacheck run.
    public var diagnostics: [Diagnostic]
    /// Diagnostic from the most recent syntax pre-pass (nil = clean).
    public var prePassDiagnostic: Diagnostic?
    /// Scroll position for the active tab (0 = top).
    public var scrollOffset: Int

    public init(
        activeTab: Tab = .output,
        outputBuffer: [String] = [],
        diagnostics: [Diagnostic] = [],
        prePassDiagnostic: Diagnostic? = nil,
        scrollOffset: Int = 0
    ) {
        self.activeTab = activeTab
        self.outputBuffer = outputBuffer
        self.diagnostics = diagnostics
        self.prePassDiagnostic = prePassDiagnostic
        self.scrollOffset = scrollOffset
    }

    // MARK: 1000-line FIFO bound

    /// Append lines to the output buffer, enforcing the 1000-line FIFO cap.
    mutating func appendOutputLines(_ lines: [String]) {
        outputBuffer.append(contentsOf: lines)
        if outputBuffer.count > 1_000 {
            outputBuffer.removeFirst(outputBuffer.count - 1_000)
        }
    }
}

// MARK: - TransientMessage

/// A time-limited status-bar message with an expiry date.
///
/// The TickSource is armed at 1.5 s while a transient is active; on each
/// `.tick` the reducer checks whether the expiry has passed and clears it.
public struct TransientMessage: Sendable, Equatable {
    public let text: String
    public let expiry: Date

    public init(text: String, duration: Duration = TickInterval.transientExpiry) {
        self.text = text
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        self.expiry = Date(timeIntervalSinceNow: seconds)
    }
}

// MARK: - ThemeState

/// The resolved theme token table plus the terminal capability tier.
public struct ThemeState: Sendable, Equatable {

    /// The active color scheme name (e.g. `"default"`).
    public var name: String

    /// Terminal capability tier detected at startup.
    public var capability: ColorCapability

    /// Resolved color attributes for each semantic token.
    public var tokens: [ThemeToken: TokenStyle]

    public init(
        name: String = "default",
        capability: ColorCapability = .truecolor,
        tokens: [ThemeToken: TokenStyle] = [:]
    ) {
        self.name = name
        self.capability = capability
        self.tokens = tokens
    }
}

/// Terminal color capability.
public enum ColorCapability: Sendable, Equatable {
    case truecolor
    case color256
    case noColor
}

/// Resolved visual style for one theme token.
public struct TokenStyle: Sendable, Equatable {
    public let fg: TerminalColor?
    public let bg: TerminalColor?
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool

    public init(
        fg: TerminalColor? = nil,
        bg: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// A terminal color — either true 24-bit RGB or an indexed 256-color value.
public enum TerminalColor: Sendable, Equatable {
    case rgb(UInt8, UInt8, UInt8)
    case index(UInt8)
}

// MARK: - NavigatorWidth / BottomPaneHeight

/// User-adjustable pane sizes (session-only in P1; ux-spec.md §1.3).
public struct PaneLayout: Sendable, Equatable {
    /// Navigator column width in cells. Clamped to [18, 30].
    public var navigatorWidth: Int
    /// Bottom pane height in rows. `nil` = derive from the 35% rule at render time.
    /// When set, clamped to [5, upperZoneMinusThree] by the layout engine.
    public var bottomPaneHeight: Int?

    // MARK: Navigator constants (ux-spec.md §1.3)

    /// Default navigator width in columns.
    public static let navigatorDefault = 18
    /// Minimum navigator width (hard lower bound).
    public static let navigatorMin = 18
    /// Maximum navigator width (hard upper cap).
    public static let navigatorMax = 30

    // MARK: Bottom pane constants (ux-spec.md §1.2, §1.3)

    /// Minimum bottom pane height in rows.
    public static let bottomPaneMin = 5
    /// Fallback bottom pane height when no override is set (used by the reducer
    /// when the user first presses `{`/`}` before a terminal size is known).
    public static let defaultBottomRows = 8
    /// Soft upper cap for `{`/`}` key adjustment stored in the reducer.
    /// The layout engine applies a tighter bound (usable − 3) at render time.
    public static let bottomPaneMaxRatio = 40

    public init(navigatorWidth: Int = navigatorDefault, bottomPaneHeight: Int? = nil) {
        self.navigatorWidth = navigatorWidth
        self.bottomPaneHeight = bottomPaneHeight
    }
}

// MARK: - NavigatorState

/// The navigator pane state: selection, filter, and spinner phase.
public struct NavigatorState: Sendable, Equatable {
    /// The currently selected row index (0-based) in the navigator listing.
    public var selectedIndex: Int
    /// Active inline filter text (nil = no filter active).
    public var filterText: String?
    /// Spinner animation phase (0-based, advanced on each .tick).
    public var spinnerPhase: Int

    public init(
        selectedIndex: Int = 0,
        filterText: String? = nil,
        spinnerPhase: Int = 0
    ) {
        self.selectedIndex = selectedIndex
        self.filterText = filterText
        self.spinnerPhase = spinnerPhase
    }
}

// MARK: - AppState

/// The entire mutable state of the MoonSwift TUI.
///
/// All fields live here; the reducer returns a new value on every event
/// (value semantics — no in-place mutation visible outside the reducer).
/// Nothing outside the reducer writes this struct (ARCHITECTURE.md §1, §4.2).
public struct AppState: Sendable {

    // MARK: Launch context

    /// How the binary was invoked (project, quick-file, or empty).
    public var launch: LaunchMode

    // MARK: Project

    /// Current project file state.
    public var project: ProjectState

    // MARK: Sources

    /// Per-source loading and content state, keyed by `SourceID`.
    public var sources: [SourceID: SourceState]

    /// Ordered list of source IDs for navigator rendering.
    /// Order matches the project file declaration order; new sources are
    /// appended as they load.
    public var navigatorOrder: [SourceID]

    // MARK: Selection

    /// The source currently displayed in the code pane. `nil` = no selection.
    public var selection: SourceID?

    // MARK: Pane state

    /// Code pane scroll, cursor, and gutter.
    public var codePane: CodePaneState

    /// Bottom pane tabs, output buffer, and diagnostics.
    public var bottomPane: BottomPaneState

    // MARK: Service state

    /// State of the most recent or active run.
    public var runState: RunState

    /// State of the lint engine.
    public var lintState: LintState

    // MARK: Highlight spans

    /// Tree-sitter highlight spans per loaded source.
    ///
    /// Entries are added by the reducer when it handles `.highlightReady`.
    /// The renderer reads only this copy — it never parses source text.
    public var highlight: [SourceID: [HighlightSpan]]

    // MARK: Catalog availability

    /// Whether `luaswift.toml` is available in the running binary.
    /// Set after the one-shot startup probe (`.catalogProbed`).
    public var tomlModuleAvailable: Bool?

    // MARK: Focus

    /// The current focus — which pane or modal receives keyboard input.
    public var focus: FocusState

    // MARK: Theme

    /// Resolved theme token table and capability tier.
    public var theme: ThemeState

    // MARK: Transient message

    /// Active status-bar transient message, or `nil` when none is showing.
    public var transient: TransientMessage?

    // MARK: Navigator

    /// Navigator selection and filter state.
    public var navigator: NavigatorState

    // MARK: Layout

    /// User-adjustable pane dimensions.
    public var paneLayout: PaneLayout

    // MARK: Initialiser

    /// Seed state: constructed by the AppDriver before the first `reduce` call.
    ///
    /// `sources` starts empty — they load asynchronously after `.appStarted`
    /// triggers `Effect.loadSources` (ARCHITECTURE.md §3a).
    public init(
        launch: LaunchMode = .empty,
        project: ProjectState = .none,
        sources: [SourceID: SourceState] = [:],
        navigatorOrder: [SourceID] = [],
        selection: SourceID? = nil,
        codePane: CodePaneState = CodePaneState(),
        bottomPane: BottomPaneState = BottomPaneState(),
        runState: RunState = .idle,
        lintState: LintState = .initializing,
        highlight: [SourceID: [HighlightSpan]] = [:],
        tomlModuleAvailable: Bool? = nil,
        focus: FocusState = .pane(.navigator),
        theme: ThemeState = ThemeState(),
        transient: TransientMessage? = nil,
        navigator: NavigatorState = NavigatorState(),
        paneLayout: PaneLayout = PaneLayout()
    ) {
        self.launch = launch
        self.project = project
        self.sources = sources
        self.navigatorOrder = navigatorOrder
        self.selection = selection
        self.codePane = codePane
        self.bottomPane = bottomPane
        self.runState = runState
        self.lintState = lintState
        self.highlight = highlight
        self.tomlModuleAvailable = tomlModuleAvailable
        self.focus = focus
        self.theme = theme
        self.transient = transient
        self.navigator = navigator
        self.paneLayout = paneLayout
    }
}
