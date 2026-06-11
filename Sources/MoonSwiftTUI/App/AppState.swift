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
//
// Picker state (PickerState): holds the tree-browse state while the picker
// modal is open. Populated by reducePickerKey when .pickerTreeReady arrives;
// cleared on save or cancel.
//
// Inc-8 additions (ARCHITECTURE.md §10.8):
//   FocusState gains four nvim cases; AppState gains conflictModal, diffView,
//   nvimFallbackNotedThisSession, and nvimPendingResize (debounce scratch).

import Foundation
import MoonSwiftCore
import RatatuiKit

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
///
/// The four P4 nvim cases are added in Inc-8 (ARCHITECTURE.md §10.8):
/// `reduceKey`'s exhaustive switch — no `default:` arm — forces handling of
/// every case in the same change-set as their reducer logic and tests.
public enum FocusState: Sendable, Equatable {
    /// One of the three panes holds focus; no modal is open.
    case pane(PaneID)
    /// The help overlay is visible.
    case helpOverlay
    /// The structured-file picker modal is open.
    case pickerModal
    /// The project-initialisation form is open.
    case initForm

    // MARK: P4 nvim focus cases (ARCHITECTURE.md §10.4.3)

    /// The nvim embed grid is shown in the code pane and receives key input.
    ///
    /// `NvimPaneState` carries per-session state (attached rect, mode, modified
    /// flag) that is only meaningful while the pane is active — hence it lives
    /// here rather than as a top-level optional in `AppState`.
    case nvimPane(NvimPaneState)

    /// The nvim probe + attach sequence is in progress; a spinner is shown.
    case nvimSpawning

    /// The conflict-resolution modal is shown over the code pane.
    ///
    /// Key handling (`[r]/[o]/[d]/[c]`) is wired in Inc-9
    /// (ARCHITECTURE.md §10.8 Inc-9).
    case conflictModal(ConflictModalState)

    /// The side-by-side diff view is open.
    ///
    /// Key handling (scroll, `[c]ancel`) is wired in Inc-9
    /// (ARCHITECTURE.md §10.8 Inc-9).
    case diffView(DiffViewPhase)
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
    /// Wall-clock deadline for the pulse. The tick handler clears the pulse
    /// only once this has passed — ticks may arrive earlier than 500 ms when a
    /// faster consumer (e.g. the 100 ms run tick) is also armed, and those
    /// early ticks must not end the animation (same pattern as
    /// `TransientMessage.expiry`).
    public var jumpPulseExpiry: Date?
    /// Gutter diagnostic marks by line (0-based fragment-relative lines).
    public var gutterMarks: [Int: GutterMark]
    /// Digit accumulator for the `:N<Enter>` jump command (ux-spec §2.3).
    ///
    /// `nil` = no active command entry. When the user types `:`, this is set to
    /// the empty string `""`. Each subsequent digit is appended. On `<Enter>`
    /// the accumulated string is parsed as the target line. On `<Esc>` or any
    /// non-digit (except `q` which shows a transient) the command is cancelled.
    public var colonCommand: String?
    /// Index of the currently selected diagnostic for `n`/`N` navigation
    /// (0-based into `BottomPaneState.diagnostics`). `nil` before first jump.
    ///
    /// Reset to `nil` whenever the active source changes so navigation restarts
    /// from the cursor position rather than an out-of-bounds index.
    public var diagnosticIndex: Int?

    public init(
        scrollOffset: Int = 0,
        cursorLine: Int = 0,
        jumpPulseLine: Int? = nil,
        jumpPulseExpiry: Date? = nil,
        gutterMarks: [Int: GutterMark] = [:],
        colonCommand: String? = nil,
        diagnosticIndex: Int? = nil
    ) {
        self.scrollOffset = scrollOffset
        self.cursorLine = cursorLine
        self.jumpPulseLine = jumpPulseLine
        self.jumpPulseExpiry = jumpPulseExpiry
        self.gutterMarks = gutterMarks
        self.colonCommand = colonCommand
        self.diagnosticIndex = diagnosticIndex
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

    // MARK: Run tracking (ux-spec §6.3)

    /// 1-based counter incremented each time a run begins (session-scoped).
    ///
    /// The renderer formats this as `── Run N · HH:MM:SS ──`. Starts at 0
    /// (no run yet); first run sets it to 1 via the `startRun` helper.
    public var runNumber: Int

    /// Wall-clock timestamp when the most recent run started.
    ///
    /// Formatted as `HH:MM:SS` in the run header (ux-spec §6.3). `nil` when
    /// no run has been started this session.
    public var runStartTime: Date?

    public init(
        activeTab: Tab = .output,
        outputBuffer: [String] = [],
        diagnostics: [Diagnostic] = [],
        prePassDiagnostic: Diagnostic? = nil,
        scrollOffset: Int = 0,
        runNumber: Int = 0,
        runStartTime: Date? = nil
    ) {
        self.activeTab = activeTab
        self.outputBuffer = outputBuffer
        self.diagnostics = diagnostics
        self.prePassDiagnostic = prePassDiagnostic
        self.scrollOffset = scrollOffset
        self.runNumber = runNumber
        self.runStartTime = runStartTime
    }

    // MARK: 1000-line FIFO bound (ux-spec §6.4)

    /// Append lines to the output buffer, enforcing the 1000-line FIFO cap.
    ///
    /// When overflow occurs the oldest lines are discarded and a notice line
    /// `[cleared — N lines discarded]` is inserted at the discard boundary
    /// (ux-spec §6.4 exact format). `N` equals the number of content lines
    /// actually removed (`excess + 1`) — one extra slot is freed to make room
    /// for the notice itself.
    mutating func appendOutputLines(_ lines: [String]) {
        outputBuffer.append(contentsOf: lines)
        let cap = 1_000
        if outputBuffer.count > cap {
            // `excess` = number of lines over the cap. We evict `excess + 1`
            // old content lines: `excess` to get to cap, plus 1 more to make
            // room for the notice. The notice then fills that slot, keeping
            // the total at exactly `cap`.
            let excess = outputBuffer.count - cap
            let evicted = excess + 1
            outputBuffer.removeFirst(evicted)
            // Insert the cleared notice at position 0 so it appears at the top
            // of the visible buffer (ux-spec §6.4 exact format). `evicted` is
            // the true count of removed content lines.
            let notice = "[cleared — \(evicted) lines discarded]"
            outputBuffer.insert(notice, at: 0)
        }
    }

    /// Clear the output buffer manually (C-l) and insert the `[cleared]` notice
    /// at the top of the fresh buffer (ux-spec §6.4).
    mutating func clearOutputWithNotice() {
        outputBuffer = ["[cleared]"]
        scrollOffset = 0
    }

    /// Record the start of a new run: increment the run counter and capture
    /// the start timestamp (ux-spec §6.3).
    mutating func startRun(at date: Date) {
        runNumber += 1
        runStartTime = date
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

// MARK: - PickerState

/// The state of the structured-file picker modal (ux-spec.md §3.6).
///
/// Held as an Optional in AppState — non-nil only while the picker is open.
/// Populated by the reducer when .pickerTreeReady arrives, cleared on save or
/// cancel. The picker shows the parsed TreeValue of the selected structured file
/// as an interactive tree; users navigate to string fields and mark them for
/// persistence as FieldDesignation entries in moonswift.toml.
public struct PickerState: Sendable, Equatable {

    // MARK: Source identity

    /// The structured-file SourceID whose tree is being browsed.
    ///
    /// Used by the save path to determine which file's designations to update
    /// and by the renderer to label the picker header.
    public var sourceID: SourceID

    /// Human-readable file path for the picker title (e.g. "data/config.json").
    public var filePath: String

    // MARK: Tree content

    /// The decoded TreeValue for the file (root node).
    ///
    /// nil when the file failed to parse — in that case `parseError` is set.
    public var tree: PickerTree?

    /// When non-nil, the file could not be parsed. The picker shows
    /// "Cannot parse file: <parseError>" and nothing is markable (ux-spec §3.6).
    public var parseError: String?

    // MARK: Navigation

    /// The 0-based index of the currently focused row in the flattened visible
    /// row list produced by `PickerTree.visibleRows`.
    public var cursorRow: Int

    // MARK: Marks

    /// The set of normalized JSONPath strings the user has toggled ON in this
    /// session (added or kept). Pre-existing designations from the project file
    /// are populated here when the picker opens so they appear pre-marked.
    public var marks: Set<String>

    /// Normalized JSONPaths that were already saved in moonswift.toml before
    /// the picker opened. Used to determine whether the picker is dirty (any
    /// marks differ from the pre-existing set) and to style pre-existing marks
    /// in `keyword` color vs. newly-added marks in `added` color.
    public var preExistingMarks: Set<String>

    // MARK: Discard confirmation

    /// When true, the reducer has received Esc on a dirty picker and is waiting
    /// for the user to confirm discard with y/N (ux-spec §3.6).
    public var awaitingDiscardConfirmation: Bool

    // MARK: Computed

    /// True when the current marks differ from the marks that were pre-existing
    /// when the picker opened — i.e., the user has made unsaved changes.
    public var isDirty: Bool {
        marks != preExistingMarks
    }

    // MARK: Init

    public init(
        sourceID: SourceID,
        filePath: String,
        tree: PickerTree? = nil,
        parseError: String? = nil,
        cursorRow: Int = 0,
        marks: Set<String> = [],
        preExistingMarks: Set<String> = [],
        awaitingDiscardConfirmation: Bool = false
    ) {
        self.sourceID = sourceID
        self.filePath = filePath
        self.tree = tree
        self.parseError = parseError
        self.cursorRow = cursorRow
        self.marks = marks
        self.preExistingMarks = preExistingMarks
        self.awaitingDiscardConfirmation = awaitingDiscardConfirmation
    }
}

// MARK: - InitFormState

/// The state of the project-initialisation form modal (ux-spec §3.1).
///
/// Held as an Optional in AppState — non-nil only while the init form is open.
/// The form has two fields: Lua version (pre-filled "5.4") and source files
/// (multi-select of .lua/.json/.yaml/.toml files discovered in the cwd).
/// Opened when the user presses `i` in empty state; closed on confirm or Esc.
public struct InitFormState: Sendable, Equatable {

    // MARK: Focus within the form

    /// Which field currently has focus.
    public enum Field: Sendable, Equatable {
        /// Field 1: Lua version (read-only in P1, pre-filled "5.4").
        case luaVersion
        /// Field 2: Source files multi-select list.
        case sourceFiles
    }

    // MARK: Fields

    /// The Lua version field value. Pre-filled "5.4"; only valid P1 value.
    public var luaVersion: String

    /// All candidate files discovered in cwd (.lua / .json / .yaml / .toml).
    /// Populated by the `.scanProjectDirectory` effect result; empty while scanning.
    public var candidateFiles: [String]

    /// True while the file scan is still in flight.
    public var isScanning: Bool

    /// The set of selected candidate file paths (selected = will be added to project).
    public var selectedFiles: Set<String>

    // MARK: Navigation

    /// Which form field is currently focused.
    public var focusedField: Field

    /// Cursor index within the `candidateFiles` list (for the source-files field).
    public var fileListCursor: Int

    // MARK: Init

    public init(
        luaVersion: String = "5.4",
        candidateFiles: [String] = [],
        isScanning: Bool = true,
        selectedFiles: Set<String> = [],
        focusedField: Field = .luaVersion,
        fileListCursor: Int = 0
    ) {
        self.luaVersion = luaVersion
        self.candidateFiles = candidateFiles
        self.isScanning = isScanning
        self.selectedFiles = selectedFiles
        self.focusedField = focusedField
        self.fileListCursor = fileListCursor
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

    // MARK: Picker modal

    /// Non-nil while the structured-file picker modal is open (ux-spec §3.6).
    ///
    /// The picker occupies the code-pane area and intercepts all keyboard input.
    /// Set when the user presses `m` on a structured-file navigator entry (after
    /// the tree loads via Effect.loadPickerTree); cleared on save or cancel.
    public var pickerState: PickerState?

    // MARK: Init form modal

    /// Non-nil while the project-init form is open (ux-spec §3.1).
    ///
    /// Opened in `LaunchMode.empty` when the user presses `i`. The form
    /// occupies the code-pane area. On confirm the project file is written and
    /// the app transitions to the loaded state.
    public var initFormState: InitFormState?

    // MARK: Nvim editing state (P4 F8b, ARCHITECTURE.md §10.4.4)

    /// Current rendered nvim cell grid. Non-nil while a nvim session is active
    /// and the first redraw batch has been applied. The renderer reads this
    /// independently of `FocusState`; it is top-level in `AppState` for that reason.
    public var nvimGrid: NvimGridState?

    /// Non-nil while the conflict-resolution modal is open.
    ///
    /// The modal's key handling (`[r]/[o]/[d]/[c]`) is wired in Inc-9
    /// (ARCHITECTURE.md §10.8 Inc-9). Set when `AppEvent.conflictDetected` arrives.
    public var conflictModal: ConflictModalState?

    /// Non-nil while the side-by-side diff view is open.
    ///
    /// The diff view's key handling is wired in Inc-9 (ARCHITECTURE.md §10.8 Inc-9).
    public var diffView: DiffViewState?

    /// The conflict modal state preserved while the diff view is open.
    ///
    /// Set when `[d]` transitions from `.conflictModal` to `.diffView(.building)`;
    /// cleared when `[c]` in the diff view restores focus to `.conflictModal`.
    /// Implements ARCHITECTURE.md §10.3d: diff-view `[c]` must return to the
    /// conflict modal with state preserved, not to an empty nvim pane (CR-022).
    public var pendingConflictModal: ConflictModalState?

    /// True once the one-time "nvim not found" fallback note has been posted this
    /// session. Prevents the transient from repeating on subsequent `nvimUnavailable`
    /// events (ARCHITECTURE.md §10.6 "One-time fallback note"; ux-spec §7.4 step 6).
    public var nvimFallbackNotedThisSession: Bool

    /// Pending terminal resize for nvim, held until the ~50 ms debounce expires.
    ///
    /// Set when a `.resize` event arrives while focus is `.nvimPane` or
    /// `.nvimSpawning`. The tick handler (armed at `TickInterval.nvimResize`)
    /// checks the deadline and emits `Effect.nvimResize` once the window passes,
    /// then clears this field (ARCHITECTURE.md §10.8 Inc-8 "nvimResize debounce").
    public var nvimPendingResize: TerminalSize?

    /// Deadline for the nvim-resize debounce; compared against `Date()` in the
    /// tick handler.
    public var nvimResizeDeadline: Date?

    /// Most recent terminal size received from `.resize` events.
    ///
    /// Updated by the reducer on every `.resize` event so it is available for
    /// computing `codePaneRect` when spawning nvim (Inc-8). Seeded to 80×24
    /// so the reducer always has a valid fallback before the first resize event.
    public var terminalSize: TerminalSize

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
        paneLayout: PaneLayout = PaneLayout(),
        pickerState: PickerState? = nil,
        initFormState: InitFormState? = nil,
        nvimGrid: NvimGridState? = nil,
        conflictModal: ConflictModalState? = nil,
        diffView: DiffViewState? = nil,
        pendingConflictModal: ConflictModalState? = nil,
        nvimFallbackNotedThisSession: Bool = false,
        nvimPendingResize: TerminalSize? = nil,
        nvimResizeDeadline: Date? = nil,
        terminalSize: TerminalSize = TerminalSize(cols: 80, rows: 24)
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
        self.pickerState = pickerState
        self.initFormState = initFormState
        self.nvimGrid = nvimGrid
        self.conflictModal = conflictModal
        self.diffView = diffView
        self.pendingConflictModal = pendingConflictModal
        self.nvimFallbackNotedThisSession = nvimFallbackNotedThisSession
        self.nvimPendingResize = nvimPendingResize
        self.nvimResizeDeadline = nvimResizeDeadline
        self.terminalSize = terminalSize
    }
}
