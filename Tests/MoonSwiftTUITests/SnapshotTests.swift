// File: Tests/MoonSwiftTUITests/SnapshotTests.swift
// Location: MoonSwiftTUITests/
// Role: Cell-buffer snapshot tests for all UI states. The render pipeline is:
//
//   AppState → render() → [RenderCommand] → CommandInterpreter → CellGrid
//
// The CellGrid is serialised to a text file and compared against a committed
// golden file.  On first run (or when RECORD_SNAPSHOTS=1 is set) the golden
// files are written; on subsequent runs they are read and diffed.
//
// Intentional update flow
// -----------------------
// When a UI change is intentional, regenerate all goldens with:
//
//   RECORD_SNAPSHOTS=1 MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 \
//     swift test --filter SnapshotTests
//
// Review the diff with `git diff Tests/MoonSwiftTUITests/Snapshots/`.
// Commit the updated goldens together with the source change that caused them.
//
// Snapshot format
// ---------------
// Each golden file contains the rendered character grid, one row per line,
// followed by an empty line and a style block that records every non-default
// cell style as "row,col fg=RRGGBB bg=RRGGBB mods=N".  Character content is
// checked unconditionally; style content is checked only when the golden was
// recorded under the same color capability (i.e. both style sections non-empty).
//
// Coverage
// --------
// Layouts   : 80x24, 100x40, 200x60; navigator widths 18/25/30; bottom heights
// Panes     : navigator variants, code pane highlights+marks, output tab,
//             diagnostics tab, help overlay, picker modal, empty state, init form
// Color     : truecolor, 256-color, NO_COLOR (full-grid snapshots per mode)
// Errors    : malformed project, missing source, engine error
// Status bar: each elision step, indicator combos, transient
//
// Upstream : Renderer.swift, AppState.swift, RatatuiKit/CellBuffer.swift,
//            CommandInterpreter.swift (production interpreter, reused here)
// Downstream: (test target — nothing imports this)

import Collections
import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - CellGridBackend

/// A `RenderBackend` that writes every widget and cell command into an in-memory
/// `CellGrid`.
///
/// This backend is the snapshot-test seam: the production `RatatuiKitBackend`
/// forwards to the FFI shim; this backend writes to a `CellGrid` so test code
/// can inspect character and style content without a real terminal.
///
/// Widget commands (navigatorList, paragraph, tabBar, block, titleBar) are
/// rendered by writing the text content of each span or line into the grid.
/// Border characters are approximated with `+`/`-`/`|` — the focus of snapshot
/// tests is text content and per-cell styles, not pixel-perfect box-drawing.
/// The production ratatui renderer handles exact border glyphs via the FFI.
private final class CellGridBackend: RenderBackend {

    let grid: CellGrid

    init(cols: Int, rows: Int) {
        self.grid = CellGrid(cols: cols, rows: rows)
    }

    // MARK: Frame lifecycle

    func beginFrame(size: TerminalSize, defaultStyle: CellStyle) throws {
        try grid.clearRect(col: 0, row: 0, width: UInt16(grid.cols), height: UInt16(grid.rows))
    }

    func flush() throws {}

    // MARK: Widget commands

    func titleBar(rect: Rect, left: String, badges: [String], style: CellStyle) throws {
        let width = Int(rect.width)
        let badgeStr = badges.isEmpty ? "" : badges.joined(separator: " ")
        let line: String
        if badgeStr.isEmpty {
            line = padRight(left, toWidth: width)
        } else {
            let gap = max(0, width - left.count - badgeStr.count)
            let composed = left + String(repeating: " ", count: gap) + badgeStr
            line = String(composed.prefix(width))
        }
        try grid.writeCells(col: rect.x, row: rect.y, text: line, style: style)
    }

    func navigatorList(rect: Rect, items: [Span], selectedIndex: Int?, title: [Span]) throws {
        let innerWidth = Int(rect.width)
        for (idx, span) in items.enumerated() {
            guard idx < Int(rect.height) else { break }
            let row = UInt16(Int(rect.y) + idx)
            let text = padRight(span.text, toWidth: innerWidth)
            try grid.writeCells(col: rect.x, row: row, text: text, style: span.style)
        }
    }

    func paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?) throws {
        for (idx, spans) in lines.enumerated() {
            guard idx < Int(rect.height) else { break }
            let row = UInt16(Int(rect.y) + idx)
            var col = Int(rect.x)
            for span in spans {
                let available = Int(rect.width) - (col - Int(rect.x))
                guard available > 0 else { break }
                let text = String(span.text.prefix(available))
                try grid.writeCells(col: UInt16(col), row: row, text: text, style: span.style)
                col += text.count
            }
        }
    }

    func tabBar(rect: Rect, tabs: [String], selectedIndex: Int) throws {
        var col = Int(rect.x)
        let row = rect.y
        for (idx, label) in tabs.enumerated() {
            guard col < Int(rect.x) + Int(rect.width) else { break }
            let style: CellStyle = idx == selectedIndex ? .default : .default
            try grid.writeCells(col: UInt16(col), row: row, text: label, style: style)
            col += label.count + 1
        }
    }

    func block(rect: Rect, config: BlockConfig, borderStyle: CellStyle) throws {
        guard rect.width >= 2, rect.height >= 2 else { return }

        // Top row: +---+
        let topRow = rect.y
        try grid.writeCells(col: rect.x, row: topRow, text: "+", style: borderStyle)
        if rect.width > 2 {
            let dashes = String(repeating: "-", count: Int(rect.width) - 2)
            try grid.writeCells(col: rect.x + 1, row: topRow, text: dashes, style: borderStyle)
        }
        try grid.writeCells(col: rect.x + rect.width - 1, row: topRow, text: "+", style: borderStyle)

        // Side rows: | ... |
        for r in 1..<Int(rect.height) - 1 {
            let termRow = UInt16(Int(rect.y) + r)
            try grid.writeCells(col: rect.x, row: termRow, text: "|", style: borderStyle)
            try grid.writeCells(col: rect.x + rect.width - 1, row: termRow, text: "|", style: borderStyle)
        }

        // Bottom row: +---+
        let bottomRow = UInt16(Int(rect.y) + Int(rect.height) - 1)
        try grid.writeCells(col: rect.x, row: bottomRow, text: "+", style: borderStyle)
        if rect.width > 2 {
            let dashes = String(repeating: "-", count: Int(rect.width) - 2)
            try grid.writeCells(col: rect.x + 1, row: bottomRow, text: dashes, style: borderStyle)
        }
        try grid.writeCells(col: rect.x + rect.width - 1, row: bottomRow, text: "+", style: borderStyle)
    }

    func clear(rect: Rect) throws {
        try grid.clearRect(col: rect.x, row: rect.y, width: rect.width, height: rect.height)
    }

    func cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle) throws {
        try grid.writeCells(col: col, row: row, text: text, style: style)
    }

    func leaveAltScreenWithMessage(cols: UInt16, rows: UInt16) throws {}

    func resumeAltScreen() throws {}

    func teardown() throws {}

    // MARK: Helpers

    private func padRight(_ text: String, toWidth width: Int) -> String {
        guard width > 0 else { return "" }
        if text.count >= width { return String(text.prefix(width)) }
        return text + String(repeating: " ", count: width - text.count)
    }
}

// MARK: - Snapshot serialization

/// A serialised snapshot: character content rows plus an optional style section.
private struct Snapshot {

    let charRows: [String]
    let styleLines: [String]

    // MARK: Produce from grid

    static func from(grid: CellGrid) -> Snapshot {
        var charRows: [String] = []
        var styleLines: [String] = []

        for r in 0..<grid.rows {
            charRows.append(grid.rowText(r))
            for c in 0..<grid.cols {
                let cell = grid.cells[r][c]
                if cell.style != .default {
                    let fg = colorHex(cell.style.fg)
                    let bg = colorHex(cell.style.bg)
                    styleLines.append("\(r),\(c) fg=\(fg) bg=\(bg) mods=\(cell.style.mods)")
                }
            }
        }
        return Snapshot(charRows: charRows, styleLines: styleLines)
    }

    // MARK: Serialise to file string

    var fileContent: String {
        var lines = charRows
        lines.append("")
        lines.append("=== styles ===")
        lines.append(contentsOf: styleLines)
        return lines.joined(separator: "\n")
    }

    // MARK: Parse from file string

    static func parse(content: String) -> Snapshot? {
        let lines = content.components(separatedBy: "\n")
        guard let sepIdx = lines.firstIndex(of: "=== styles ===") else { return nil }
        // Drop the blank separator line before the section header.
        let charRows = Array(lines.prefix(max(0, sepIdx - 1)))
        let styleLines = Array(lines.dropFirst(sepIdx + 1))
        return Snapshot(charRows: charRows, styleLines: styleLines)
    }

    // MARK: Helpers

    private static func colorHex(_ value: UInt32) -> String {
        if value == 0xFFFF_FFFF { return "default" }
        return String(format: "%06X", value & 0x00FF_FFFF)
    }
}

// MARK: - Golden file I/O

/// The directory that holds committed golden snapshot files, resolved relative
/// to this source file so the path works regardless of build working directory.
private let snapshotsDir: URL = {
    let thisFile = URL(fileURLWithPath: #filePath)
    return thisFile.deletingLastPathComponent().appendingPathComponent("Snapshots")
}()

/// When `RECORD_SNAPSHOTS=1` is set, golden files are written instead of compared.
private let recordMode: Bool = {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
}()

/// Asserts that the `CellGrid` matches the committed golden at `name`.
///
/// In record mode, the golden is created or overwritten.  In compare mode, the
/// character content is always checked; the style section is checked only when
/// both the current run and the golden have non-empty style sections (so goldens
/// recorded under one color capability still validate chars under another).
private func assertSnapshot(
    grid: CellGrid,
    name: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws {
    let snapshot = Snapshot.from(grid: grid)
    let fileURL = snapshotsDir.appendingPathComponent("\(name).txt")

    if recordMode {
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try snapshot.fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        Issue.record(
            "Golden file missing for '\(name)'. Run with RECORD_SNAPSHOTS=1 to create it.",
            sourceLocation: sourceLocation
        )
        return
    }

    let stored = try String(contentsOf: fileURL, encoding: .utf8)
    guard let golden = Snapshot.parse(content: stored) else {
        Issue.record("Cannot parse golden file '\(name)'.", sourceLocation: sourceLocation)
        return
    }

    // Always check character rows.
    let rowCount = min(snapshot.charRows.count, golden.charRows.count)
    for idx in 0..<rowCount {
        let actual = snapshot.charRows[idx]
        let expected = golden.charRows[idx]
        if actual != expected {
            Issue.record(
                "Character mismatch in '\(name)' at row \(idx):\n\(buildLineDiff(row: idx, actual: actual, expected: expected))",
                sourceLocation: sourceLocation
            )
        }
    }
    if snapshot.charRows.count != golden.charRows.count {
        Issue.record(
            "Row count mismatch in '\(name)': got \(snapshot.charRows.count), want \(golden.charRows.count)",
            sourceLocation: sourceLocation
        )
    }

    // Style check: only when both sides have style entries.
    if !golden.styleLines.isEmpty, !snapshot.styleLines.isEmpty {
        let actualSet = Set(snapshot.styleLines)
        let goldenSet = Set(golden.styleLines)
        let extra = actualSet.subtracting(goldenSet)
        let missing = goldenSet.subtracting(actualSet)
        if !extra.isEmpty || !missing.isEmpty {
            var msg = "Style mismatch in '\(name)':"
            if !missing.isEmpty { msg += "\n  missing: \(missing.sorted().joined(separator: "; "))" }
            if !extra.isEmpty { msg += "\n  extra:   \(extra.sorted().joined(separator: "; "))" }
            Issue.record(Comment(rawValue: msg), sourceLocation: sourceLocation)
        }
    }
}

/// Formats a one-line diff showing the first differing column between two rows.
private func buildLineDiff(row: Int, actual: String, expected: String) -> String {
    let aChars = Array(actual)
    let eChars = Array(expected)
    var firstDiff: Int?
    for i in 0..<min(aChars.count, eChars.count) where aChars[i] != eChars[i] {
        firstDiff = i
        break
    }
    let col = firstDiff ?? min(aChars.count, eChars.count)
    return "  row=\(row) first diff col=\(col)\n  want: \(expected)\n  got:  \(actual)"
}

// MARK: - Render pipeline

/// Runs the full render → CommandInterpreter → CellGrid pipeline.
///
/// Uses the production `CommandInterpreter` with an in-memory `CellGridBackend`
/// so snapshot tests exercise the same code path as the production renderer.
private func renderGrid(state: AppState, cols: UInt16, rows: UInt16) throws -> CellGrid {
    let size = TerminalSize(cols: cols, rows: rows)
    let commands = render(state, size: size)
    let backend = CellGridBackend(cols: Int(cols), rows: Int(rows))
    let interpreter = CommandInterpreter(backend: backend)
    try interpreter.apply(commands)
    return backend.grid
}

// MARK: - State builder helpers

/// A fixed-content fragment for use in code-pane tests.
private func sampleFragment(
    path: String = "hello.lua",
    code: String = """
    -- A sample Lua module
    local M = {}

    function M.greet(name)
        print("Hello, " .. name)
    end

    return M
    """
) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: "/project/\(path)")
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: hash
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}

/// A convenience diagnostic with a runtime source.
private func runtimeDiag(
    severity: Diagnostic.Severity = .error,
    line: Int = 1,
    column: Int? = nil,
    message: String,
    code: String? = nil
) -> Diagnostic {
    Diagnostic(
        severity: severity,
        line: line,
        column: column,
        code: code,
        message: message,
        source: .runtime
    )
}

/// A convenience diagnostic with a luacheck source.
private func luacheckDiag(
    severity: Diagnostic.Severity = .error,
    line: Int = 1,
    column: Int? = nil,
    message: String,
    code: String? = nil
) -> Diagnostic {
    Diagnostic(
        severity: severity,
        line: line,
        column: column,
        code: code,
        message: message,
        source: .luacheck
    )
}

/// A convenience diagnostic with a syntax pre-pass source.
private func syntaxDiag(
    severity: Diagnostic.Severity = .error,
    line: Int = 1,
    column: Int? = nil,
    message: String
) -> Diagnostic {
    Diagnostic(
        severity: severity,
        line: line,
        column: column,
        message: message,
        source: .syntaxPrePass
    )
}

/// A convenience diagnostic with a project-config source.
private func projectDiag(severity: Diagnostic.Severity = .error, message: String) -> Diagnostic {
    Diagnostic(severity: severity, line: 0, column: nil, message: message, source: .projectConfig)
}

/// Builds a state with a single loaded source selected in the code pane.
///
/// Returns the state and the source ID so callers can add gutter marks or
/// highlights to the specific source.
private func stateWithLoadedSource(
    theme: ThemeState = ThemeEngine.resolve(capability: .truecolor),
    code: String = """
    -- A sample Lua module
    local M = {}

    function M.greet(name)
        print("Hello, " .. name)
    end

    return M
    """
) -> (state: AppState, id: SourceID) {
    let id = SourceID(path: "hello.lua")
    var state = AppState()
    state.theme = theme
    state.launch = .project(URL(fileURLWithPath: "/project"))
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.sources[id] = .loaded(sampleFragment(code: code))
    state.navigatorOrder = [id]
    state.selection = id
    state.focus = .pane(.navigator)
    return (state, id)
}

/// Builds a state with multiple navigator entries in various loading states.
private func stateWithNavigatorVariants(
    theme: ThemeState = ThemeEngine.resolve(capability: .truecolor)
) -> AppState {
    var state = AppState()
    state.theme = theme
    state.launch = .project(URL(fileURLWithPath: "/project"))
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.focus = .pane(.navigator)

    let id1 = SourceID(path: "main.lua")
    let id2 = SourceID(path: "utils.lua")
    let id3 = SourceID(path: "missing.lua")
    let id4 = SourceID(path: "config.json")

    state.navigatorOrder = [id1, id2, id3, id4]
    state.sources[id1] = .loaded(sampleFragment(path: "main.lua"))
    state.sources[id2] = .loading
    state.sources[id3] = .missing
    state.sources[id4] = .failed(projectDiag(message: "parse error"))
    state.navigator = NavigatorState(selectedIndex: 0, spinnerPhase: 2)
    return state
}

// MARK: - Layout snapshot tests

@Suite("Snapshots — Layout geometry")
struct SnapshotLayoutTests {

    @Test("80x24 default layout with empty state")
    func layout80x24Empty() throws {
        let state = AppState()
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "layout_80x24_empty")
    }

    @Test("100x40 default layout with empty state")
    func layout100x40Empty() throws {
        let state = AppState()
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "layout_100x40_empty")
    }

    @Test("200x60 default layout with empty state")
    func layout200x60Empty() throws {
        let state = AppState()
        let grid = try renderGrid(state: state, cols: 200, rows: 60)
        try assertSnapshot(grid: grid, name: "layout_200x60_empty")
    }

    @Test("Navigator width 18 at 80x24")
    func navigatorWidth18() throws {
        var state = AppState()
        state.paneLayout.navigatorWidth = 18
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "layout_navigator_width18")
    }

    @Test("Navigator width 25 at 100x40")
    func navigatorWidth25() throws {
        var state = AppState()
        state.paneLayout.navigatorWidth = 25
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "layout_navigator_width25")
    }

    @Test("Navigator width 30 at 100x40")
    func navigatorWidth30() throws {
        var state = AppState()
        state.paneLayout.navigatorWidth = 30
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "layout_navigator_width30")
    }

    @Test("Bottom pane at minimum height (5 rows)")
    func bottomPaneMinHeight() throws {
        var state = AppState()
        state.paneLayout.bottomPaneHeight = 5
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "layout_bottom_height5")
    }

    @Test("Bottom pane at large height (15 rows)")
    func bottomPaneLargeHeight() throws {
        var state = AppState()
        state.paneLayout.bottomPaneHeight = 15
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "layout_bottom_height15")
    }
}

// MARK: - Navigator pane snapshot tests

@Suite("Snapshots — Navigator pane")
struct SnapshotNavigatorTests {

    @Test("Navigator with multiple source states")
    func navigatorVariants() throws {
        let state = stateWithNavigatorVariants()
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "navigator_variants")
    }

    @Test("Navigator focused with selection on first entry")
    func navigatorFocused() throws {
        var state = stateWithNavigatorVariants()
        state.focus = .pane(.navigator)
        state.navigator.selectedIndex = 0
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "navigator_focused")
    }

    @Test("Navigator with active filter text 'main'")
    func navigatorFilter() throws {
        var state = stateWithNavigatorVariants()
        state.navigator.filterText = "main"
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "navigator_filter_active")
    }

    @Test("Navigator shows single error entry for malformed project")
    func navigatorMalformed() throws {
        var state = AppState()
        state.project = .malformed(projectDiag(message: "TOML parse error"))
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "navigator_malformed_project")
    }

    @Test("Navigator spinner braille phase 0 (truecolor)")
    func navigatorSpinnerTruecolor() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        let id = SourceID(path: "loading.lua")
        state.navigatorOrder = [id]
        state.sources[id] = .loading
        state.navigator.spinnerPhase = 0
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "navigator_spinner_phase0")
    }
}

// MARK: - Code pane snapshot tests

@Suite("Snapshots — Code pane")
struct SnapshotCodePaneTests {

    @Test("Code pane with loaded source — basic render")
    func codePaneBasic() throws {
        let (state, _) = stateWithLoadedSource()
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_basic")
    }

    @Test("Code pane with gutter marks (error and warning)")
    func codePaneGutterMarks() throws {
        var (state, _) = stateWithLoadedSource()
        state.codePane.gutterMarks[2] = .error
        state.codePane.gutterMarks[5] = .warning
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_gutter_marks")
    }

    @Test("Code pane cursor on line 3 uses focus_bg background")
    func codePane_cursorLine() throws {
        var (state, _) = stateWithLoadedSource()
        state.codePane.cursorLine = 3
        state.focus = .pane(.codePane)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_cursor_line")
    }

    @Test("Code pane with highlight spans (keyword and number)")
    func codePaneHighlights() throws {
        let code = "local x = 42\nprint(x)"
        var (state, id) = stateWithLoadedSource(code: code)
        state.highlight[id] = [
            HighlightSpan(line: 0, column: 0, length: 5, tokenKind: .keyword),
            HighlightSpan(line: 0, column: 10, length: 2, tokenKind: .number),
        ]
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_highlights")
    }

    @Test("Code pane missing source shows error message")
    func codePane_missingSource() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .project(URL(fileURLWithPath: "/project"))
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        let id = SourceID(path: "missing.lua")
        state.sources[id] = .missing
        state.navigatorOrder = [id]
        state.selection = id
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_missing_source")
    }

    @Test("Code pane failed source shows parse-error message")
    func codePane_failedSource() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .project(URL(fileURLWithPath: "/project"))
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        let id = SourceID(path: "broken.json")
        state.sources[id] = .failed(projectDiag(message: "Unexpected token"))
        state.navigatorOrder = [id]
        state.selection = id
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "code_pane_failed_source")
    }
}

// MARK: - Bottom pane snapshot tests

@Suite("Snapshots — Bottom pane")
struct SnapshotBottomPaneTests {

    @Test("Output tab with run header and content lines")
    func outputTabWithContent() throws {
        var (state, _) = stateWithLoadedSource()
        var bp = BottomPaneState()
        bp.activeTab = .output
        bp.runNumber = 1
        bp.runStartTime = Date(timeIntervalSince1970: 0)  // 00:00:00 UTC
        bp.outputBuffer = ["Hello, world!", "→ done"]
        state.bottomPane = bp
        state.focus = .pane(.bottomPane)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "bottom_output_with_content")
    }

    @Test("Output tab empty before first run")
    func outputTabEmpty() throws {
        var (state, _) = stateWithLoadedSource()
        state.bottomPane.activeTab = .output
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "bottom_output_empty")
    }

    @Test("Diagnostics tab with syntax error and lint diagnostics")
    func diagnosticsTabWithErrors() throws {
        var (state, _) = stateWithLoadedSource()
        state.bottomPane.activeTab = .diagnostics
        state.bottomPane.diagnostics = [
            luacheckDiag(severity: .error, line: 3, column: 5, message: "undefined variable 'x'", code: "W111"),
            luacheckDiag(severity: .warning, line: 7, column: nil, message: "unused variable", code: "W212"),
        ]
        state.bottomPane.prePassDiagnostic = syntaxDiag(
            severity: .error, line: 1, column: 1, message: "unexpected symbol near '}'")
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "bottom_diagnostics_with_errors")
    }

    @Test("Diagnostics tab shows 'No diagnostics.' when empty")
    func diagnosticsTabEmpty() throws {
        var (state, _) = stateWithLoadedSource()
        state.bottomPane.activeTab = .diagnostics
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "bottom_diagnostics_empty")
    }

    @Test("Diagnostics tab shows lint engine failure message")
    func diagnosticsTabEngineFailed() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.bottomPane.activeTab = .diagnostics
        state.lintState = .failed("luacheck binary not found")
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "bottom_diagnostics_engine_failed")
    }
}

// MARK: - Overlay snapshot tests

@Suite("Snapshots — Overlays")
struct SnapshotOverlayTests {

    @Test("Help overlay shows all keybinding sections")
    func helpOverlay() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.focus = .helpOverlay
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "overlay_help")
    }

    @Test("Picker modal with a simple tree (one string field)")
    func pickerModalWithTree() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .project(URL(fileURLWithPath: "/project"))
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        let id = SourceID(path: "config.json")
        state.navigatorOrder = [id]
        state.sources[id] = .loaded(sampleFragment(path: "config.json", code: "{}"))
        state.focus = .pickerModal

        // Build a minimal PickerTree with one string field.
        var dict = OrderedDictionary<String, TreeValue>()
        dict["name"] = .string("Alice")
        let tree = PickerTree(root: .map(dict))
        state.pickerState = PickerState(
            sourceID: id,
            filePath: "config.json",
            tree: tree,
            cursorRow: 0,
            marks: [],
            preExistingMarks: []
        )
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "overlay_picker_with_tree")
    }

    @Test("Picker modal in loading state (tree not yet ready)")
    func pickerModalLoading() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .project(URL(fileURLWithPath: "/project"))
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        let id = SourceID(path: "config.json")
        state.focus = .pickerModal
        // tree: nil → picker shows "Loading…"
        state.pickerState = PickerState(sourceID: id, filePath: "config.json", tree: nil)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "overlay_picker_loading")
    }

    @Test("Init form in scanning state (file list still loading)")
    func initFormScanning() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .empty
        state.focus = .initForm
        state.initFormState = InitFormState(
            luaVersion: "5.4",
            candidateFiles: [],
            isScanning: true,
            selectedFiles: [],
            focusedField: .luaVersion
        )
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "init_form_scanning")
    }

    @Test("Init form with candidate files and one file selected")
    func initFormWithFiles() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .empty
        state.focus = .initForm
        state.initFormState = InitFormState(
            luaVersion: "5.4",
            candidateFiles: ["main.lua", "utils.lua", "config.json"],
            isScanning: false,
            selectedFiles: ["main.lua"],
            focusedField: .sourceFiles,
            fileListCursor: 0
        )
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "init_form_with_files")
    }
}

// MARK: - Empty state snapshot tests

@Suite("Snapshots — Empty state")
struct SnapshotEmptyStateTests {

    @Test("Empty launch mode shows 'No project file found.' prompt")
    func emptyState() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .empty
        state.project = .none
        state.focus = .pane(.codePane)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "empty_state_prompt")
    }

    @Test("Quick-file launch shows [no project] badge in title bar")
    func quickFileState() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .quickFile(URL(fileURLWithPath: "/tmp/test.lua"))
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "empty_state_quick_file")
    }
}

// MARK: - Color mode snapshot tests

@Suite("Snapshots — Color modes")
struct SnapshotColorModeTests {

    /// A representative state that exercises diagnostics, running indicator, and
    /// code-pane gutter marks so that color differences between modes are visible.
    private func representativeState(capability: ColorCapability) -> AppState {
        let theme = ThemeEngine.resolve(capability: capability)
        var (state, id) = stateWithLoadedSource(theme: theme)
        state.runState = .running(id: UUID(), startedAt: Date(timeIntervalSince1970: 0))
        state.focus = .pane(.codePane)
        state.bottomPane.diagnostics = [
            luacheckDiag(severity: .error, line: 3, column: 2, message: "undef variable")
        ]
        state.codePane.gutterMarks[2] = .error
        _ = id
        return state
    }

    @Test("Truecolor mode — representative state at 80x24")
    func truecolorMode() throws {
        let state = representativeState(capability: .truecolor)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "colormode_truecolor_80x24")
    }

    @Test("256-color mode — representative state at 80x24")
    func color256Mode() throws {
        let state = representativeState(capability: .color256)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "colormode_256_80x24")
    }

    @Test("NO_COLOR mode — representative state at 80x24")
    func noColorMode() throws {
        let state = representativeState(capability: .noColor)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "colormode_nocolor_80x24")
    }

    @Test("NO_COLOR mode uses ASCII spinner (|/-\\) not braille")
    func noColorSpinner() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .noColor)
        let id = SourceID(path: "loading.lua")
        state.navigatorOrder = [id]
        state.sources[id] = .loading
        state.navigator.spinnerPhase = 1  // '/' in ASCII spinner set
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "colormode_nocolor_spinner")
    }
}

// MARK: - Error state snapshot tests

@Suite("Snapshots — Error states")
struct SnapshotErrorStateTests {

    @Test("Malformed project shows error block in code pane")
    func malformedProject() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.project = .malformed(projectDiag(message: "key 'lua_version' must be a string"))
        state.focus = .pane(.codePane)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "error_malformed_project")
    }

    @Test("Unsupported Lua version shows persistent error header in bottom pane")
    func unsupportedVersion() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.project = .unsupportedVersion("5.1")
        state.bottomPane.activeTab = .output
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "error_unsupported_lua_version")
    }

    @Test("Engine error appears in output buffer as formatted footer")
    func engineError() throws {
        var (state, _) = stateWithLoadedSource()
        state.bottomPane.activeTab = .output
        state.bottomPane.runNumber = 1
        state.bottomPane.runStartTime = Date(timeIntervalSince1970: 0)
        state.bottomPane.outputBuffer = [
            buildRunFooter(outcome: .engineError("state corruption detected"))
        ]
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "error_engine_error")
    }

    @Test("Missing source in code pane shows checkmark-prefixed message")
    func missingSingleSource() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .project(URL(fileURLWithPath: "/project"))
        state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
        let id = SourceID(path: "gone.lua")
        state.sources[id] = .missing
        state.navigatorOrder = [id]
        state.selection = id
        state.focus = .pane(.codePane)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "error_missing_source")
    }
}

// MARK: - Status bar snapshot tests

@Suite("Snapshots — Status bar")
struct SnapshotStatusBarTests {

    @Test("Status bar empty — no indicators, no hints at 80 cols")
    func statusBarEmpty80() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "statusbar_empty_80")
    }

    @Test("Status bar [running...] at 100 cols — full indicator + full hints")
    func statusBarRunningFull() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.runState = .running(id: UUID(), startedAt: Date(timeIntervalSince1970: 0))
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "statusbar_running_100cols")
    }

    @Test("Status bar [running...] + [linting...] at 80 cols — full indicators, short hints")
    func statusBarRunning80() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.runState = .running(id: UUID(), startedAt: Date(timeIntervalSince1970: 0))
        state.lintState = .running
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "statusbar_running_linting_80cols")
    }

    @Test("Status bar transient message overrides persistent indicators")
    func statusBarTransient() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.runState = .running(id: UUID(), startedAt: Date(timeIntervalSince1970: 0))
        state.transient = TransientMessage(text: "yanked to clipboard")
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "statusbar_transient")
    }

    @Test("Status bar [project error] indicator for malformed project")
    func statusBarProjectError() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.project = .malformed(projectDiag(message: "bad key"))
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "statusbar_project_error")
    }

    @Test("Status bar [no project] indicator in quick-file mode")
    func statusBarNoProject() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.launch = .quickFile(URL(fileURLWithPath: "/tmp/test.lua"))
        state.focus = .pane(.navigator)
        let grid = try renderGrid(state: state, cols: 80, rows: 24)
        try assertSnapshot(grid: grid, name: "statusbar_no_project")
    }

    @Test("Status bar code pane hints at 100 cols (full hint string)")
    func statusBarHintsCodePane() throws {
        var (state, _) = stateWithLoadedSource()
        state.focus = .pane(.codePane)
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "statusbar_hints_code_pane")
    }

    @Test("Status bar bottom-pane output hints at 100 cols")
    func statusBarHintsBottomOutput() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "statusbar_hints_bottom_output")
    }

    @Test("Status bar bottom-pane diagnostics hints at 100 cols")
    func statusBarHintsBottomDiag() throws {
        var state = AppState()
        state.theme = ThemeEngine.resolve(capability: .truecolor)
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .diagnostics
        let grid = try renderGrid(state: state, cols: 100, rows: 40)
        try assertSnapshot(grid: grid, name: "statusbar_hints_bottom_diag")
    }
}
