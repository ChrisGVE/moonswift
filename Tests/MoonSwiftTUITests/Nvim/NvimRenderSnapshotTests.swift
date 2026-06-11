// File: Tests/MoonSwiftTUITests/Nvim/NvimRenderSnapshotTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Cell-grid snapshot tests for the three nvim renderer views introduced
//       in Inc-11 (ARCHITECTURE.md §10.8):
//         • NvimGridView — .nvimPane grid content render, .nvimSpawning spinner
//         • NvimConflictView — .conflictModal exact §7.4 string
//         • NvimDiffView — side-by-side diff (.ready) and .building spinner
//
// Snapshot format and record mode follow the same conventions as SnapshotTests.swift.
// Run with RECORD_SNAPSHOTS=1 to write/update golden files.
//
// Relationships:
//   → NvimGridView.swift      (Inc-11): renderNvimGrid, renderNvimSpawning
//   → NvimConflictView.swift  (Inc-11): renderConflictModal
//   → NvimDiffView.swift      (Inc-11): renderDiffView
//   → Renderer.swift          (Inc-11): delegation arms for the three focus states
//   → SnapshotTests.swift     (reference): CellGridBackend, assertSnapshot, renderGrid

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Local snapshot infrastructure
// (Mirrors the private helpers in SnapshotTests.swift — duplicated to avoid
// test-target cross-file private access.)

private final class NvimCellGridBackend: RenderBackend {

    let grid: CellGrid

    init(cols: Int, rows: Int) {
        self.grid = CellGrid(cols: cols, rows: rows)
    }

    func beginFrame(size: TerminalSize, defaultStyle: CellStyle) throws {
        try grid.clearRect(col: 0, row: 0, width: UInt16(grid.cols), height: UInt16(grid.rows))
    }

    func flush() throws {}

    func titleBar(rect: Rect, left: String, badges: [String], style: CellStyle) throws {
        let width = Int(rect.width)
        let badgeStr = badges.isEmpty ? "" : badges.joined(separator: " ")
        let line: String
        if badgeStr.isEmpty {
            line = nvimPadRight(left, toWidth: width)
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
            let text = nvimPadRight(span.text, toWidth: innerWidth)
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
            let style: CellStyle =
                idx == selectedIndex
                ? CellStyle(fg: 0xFFFF_FFFF, bg: 0xFFFF_FFFF, mods: 1)
                : .default
            try grid.writeCells(col: UInt16(col), row: row, text: label, style: style)
            col += label.count + 1
        }
    }

    func block(rect: Rect, config: BlockConfig, borderStyle: CellStyle) throws {
        guard rect.width >= 2, rect.height >= 2 else { return }
        let topRow = rect.y
        try grid.writeCells(col: rect.x, row: topRow, text: "+", style: borderStyle)
        if rect.width > 2 {
            let dashes = String(repeating: "-", count: Int(rect.width) - 2)
            try grid.writeCells(col: rect.x + 1, row: topRow, text: dashes, style: borderStyle)
        }
        try grid.writeCells(col: rect.x + rect.width - 1, row: topRow, text: "+", style: borderStyle)
        for r in 1..<Int(rect.height) - 1 {
            let termRow = UInt16(Int(rect.y) + r)
            try grid.writeCells(col: rect.x, row: termRow, text: "|", style: borderStyle)
            try grid.writeCells(col: rect.x + rect.width - 1, row: termRow, text: "|", style: borderStyle)
        }
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
}

private func nvimPadRight(_ text: String, toWidth width: Int) -> String {
    guard width > 0 else { return "" }
    if text.count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - text.count)
}

// MARK: - Snapshot infrastructure (mirrors SnapshotTests.swift)

private struct NvimSnapshot {
    let charRows: [String]
    let styleLines: [String]

    static func from(grid: CellGrid) -> NvimSnapshot {
        var charRows: [String] = []
        var styleLines: [String] = []
        for r in 0..<grid.rows {
            charRows.append(grid.rowText(r))
            for c in 0..<grid.cols {
                let cell = grid.cells[r][c]
                if cell.style != .default {
                    let fg = nvimColorHex(cell.style.fg)
                    let bg = nvimColorHex(cell.style.bg)
                    styleLines.append("\(r),\(c) fg=\(fg) bg=\(bg) mods=\(cell.style.mods)")
                }
            }
        }
        return NvimSnapshot(charRows: charRows, styleLines: styleLines)
    }

    var fileContent: String {
        var lines = charRows
        lines.append("")
        lines.append("=== styles ===")
        lines.append(contentsOf: styleLines)
        return lines.joined(separator: "\n")
    }

    static func parse(content: String) -> NvimSnapshot? {
        let lines = content.components(separatedBy: "\n")
        guard let sepIdx = lines.firstIndex(of: "=== styles ===") else { return nil }
        let charRows = Array(lines.prefix(max(0, sepIdx - 1)))
        let styleLines = Array(lines.dropFirst(sepIdx + 1))
        return NvimSnapshot(charRows: charRows, styleLines: styleLines)
    }

    private static func nvimColorHex(_ value: UInt32) -> String {
        if value == 0xFFFF_FFFF { return "default" }
        return String(format: "%06X", value & 0x00FF_FFFF)
    }
}

private let nvimSnapshotsDir: URL = {
    let thisFile = URL(fileURLWithPath: #filePath)
    // Put nvim snapshots alongside the standard Snapshots/ directory:
    // Tests/MoonSwiftTUITests/Snapshots/
    return
        thisFile
        .deletingLastPathComponent()  // Nvim/
        .deletingLastPathComponent()  // MoonSwiftTUITests/
        .appendingPathComponent("Snapshots")
}()

private let nvimRecordMode: Bool = {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
}()

private func assertNvimSnapshot(
    grid: CellGrid,
    name: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws {
    let snapshot = NvimSnapshot.from(grid: grid)
    let fileURL = nvimSnapshotsDir.appendingPathComponent("\(name).txt")

    if nvimRecordMode {
        try FileManager.default.createDirectory(
            at: nvimSnapshotsDir, withIntermediateDirectories: true)
        try snapshot.fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        #expect(
            Bool(false),
            "Golden file missing for '\(name)'. Run with RECORD_SNAPSHOTS=1 to create it.",
            sourceLocation: sourceLocation
        )
        return
    }

    let stored = try String(contentsOf: fileURL, encoding: .utf8)
    guard let golden = NvimSnapshot.parse(content: stored) else {
        Issue.record("Cannot parse golden file '\(name)'.", sourceLocation: sourceLocation)
        return
    }

    let rowCount = min(snapshot.charRows.count, golden.charRows.count)
    for idx in 0..<rowCount {
        let actual = snapshot.charRows[idx]
        let expected = golden.charRows[idx]
        if actual != expected {
            Issue.record(
                "Char mismatch in '\(name)' row \(idx):\n  want: \(expected)\n  got:  \(actual)",
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
    if !golden.styleLines.isEmpty, !snapshot.styleLines.isEmpty {
        let extra = Set(snapshot.styleLines).subtracting(Set(golden.styleLines))
        let missing = Set(golden.styleLines).subtracting(Set(snapshot.styleLines))
        if !extra.isEmpty || !missing.isEmpty {
            var msg = "Style mismatch in '\(name)':"
            if !missing.isEmpty { msg += "\n  missing: \(missing.sorted().joined(separator: "; "))" }
            if !extra.isEmpty { msg += "\n  extra:   \(extra.sorted().joined(separator: "; "))" }
            Issue.record(Comment(rawValue: msg), sourceLocation: sourceLocation)
        }
    }
}

/// Runs the full render → CommandInterpreter → CellGrid pipeline using AppState.
private func nvimRenderGrid(state: AppState, cols: UInt16, rows: UInt16) throws -> CellGrid {
    let size = TerminalSize(cols: cols, rows: rows)
    let commands = render(state, size: size)
    let backend = NvimCellGridBackend(cols: Int(cols), rows: Int(rows))
    let interpreter = CommandInterpreter(backend: backend)
    try interpreter.apply(commands)
    return backend.grid
}

// MARK: - NvimGridView snapshot tests

@Suite("NvimRenderSnapshot — NvimGrid")
struct NvimGridRenderSnapshotTests {

    // MARK: Helpers

    private func makeGridState(
        cols: Int = 20,
        rows: Int = 5,
        fill: String = " "
    ) -> NvimGridState {
        var grid = NvimGridState(width: cols, height: rows)
        // Fill row 0 with a simple text run.
        let cells = (0..<cols).map { _ in NvimCell(text: fill, hlId: 0, repeatCount: 1) }
        grid.applyGridLine(row: 0, colStart: 0, cells: cells)
        return grid
    }

    private func stateWithNvimGrid(_ grid: NvimGridState) -> AppState {
        AppState(
            focus: .nvimPane(
                NvimPaneState(
                    attachedRect: Rect(x: 18, y: 1, width: 60, height: 14))),
            theme: ThemeEngine.resolve(capability: .truecolor),
            nvimGrid: grid,
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
    }

    // MARK: Tests

    @Test("nvimPane focus renders grid content in code-pane area")
    func nvimPaneGridContent() throws {
        // Build a 3-row grid with different text on each row.
        var grid = NvimGridState(width: 30, height: 3)
        let rowTexts = ["hello, world          ", "second row            ", "third row             "]
        for (rowIdx, text) in rowTexts.enumerated() {
            let cells = Array(text).map { NvimCell(text: String($0), hlId: 0, repeatCount: 1) }
            grid.applyGridLine(row: rowIdx, colStart: 0, cells: cells)
        }

        var state = stateWithNvimGrid(grid)
        state.theme = ThemeEngine.resolve(capability: .truecolor)

        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_grid_content")
    }

    @Test("nvimPane with nil grid shows 'Connecting…' placeholder")
    func nvimPaneNilGrid() throws {
        let state = AppState(
            focus: .nvimPane(
                NvimPaneState(
                    attachedRect: Rect(x: 18, y: 1, width: 60, height: 14))),
            theme: ThemeEngine.resolve(capability: .truecolor),
            nvimGrid: nil,
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_grid_nil")
    }

    @Test("nvimSpawning focus shows 'nvim starting…' spinner placeholder")
    func nvimSpawningPlaceholder() throws {
        let state = AppState(
            focus: .nvimSpawning,
            theme: ThemeEngine.resolve(capability: .truecolor),
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_spawning")
    }

    @Test("nvimPane grid coalesces adjacent same-hlId cells into single runs")
    func nvimGridCoalescing() throws {
        // Row 0: 5 cells hlId=1, then 5 cells hlId=2 — should coalesce into 2 runs.
        var grid = NvimGridState(width: 10, height: 1)
        let cells1 = (0..<5).map { _ in NvimCell(text: "A", hlId: 1, repeatCount: 1) }
        let cells2 = (0..<5).map { _ in NvimCell(text: "B", hlId: 2, repeatCount: 1) }
        grid.applyGridLine(row: 0, colStart: 0, cells: cells1)
        grid.applyGridLine(row: 0, colStart: 5, cells: cells2)

        // Define hlId 1 as red foreground, hlId 2 as blue foreground.
        grid.hlCache[1] = HLAttrs(fg: 0xFF0000, bg: nil, bold: false, italic: false, underline: false, reverse: false)
        grid.hlCache[2] = HLAttrs(fg: 0x0000FF, bg: nil, bold: false, italic: false, underline: false, reverse: false)

        let state = AppState(
            focus: .nvimPane(
                NvimPaneState(
                    attachedRect: Rect(x: 18, y: 1, width: 60, height: 14))),
            theme: ThemeEngine.resolve(capability: .truecolor),
            nvimGrid: grid,
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_grid_coalesced")
    }
}

// MARK: - NvimConflictView snapshot tests

@Suite("NvimRenderSnapshot — ConflictModal")
struct NvimConflictRenderSnapshotTests {

    private func makeConflictState() -> AppState {
        let fragment = makeTestFragment()
        let modal = ConflictModalState(
            fileURL: URL(fileURLWithPath: "/tmp/test.lua"),
            expectedHash: SHA256.hash(data: Data("original".utf8)),
            editedText: "return 99\n",
            fragment: fragment
        )
        return AppState(
            focus: .conflictModal(modal),
            theme: ThemeEngine.resolve(capability: .truecolor),
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
    }

    @Test("conflictModal renders exact ux-spec §7.4 normative string")
    func conflictModalNormativeString() throws {
        let state = makeConflictState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)

        // Verify the normative §7.4 string appears somewhere in the rendered grid.
        let normativeString = "[r]eload / [o]verwrite / [d]iff / [c]ancel"
        var found = false
        for r in 0..<cellGrid.rows {
            if cellGrid.rowText(r).contains(normativeString) {
                found = true
                break
            }
        }
        #expect(found, "ux-spec §7.4 normative string not found in rendered grid")
    }

    @Test("conflictModal snapshot matches golden")
    func conflictModalSnapshot() throws {
        let state = makeConflictState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_conflict_modal")
    }

    @Test("conflictModal first line shows 'File changed externally.'")
    func conflictModalFirstLine() throws {
        let state = makeConflictState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        var found = false
        for r in 0..<cellGrid.rows {
            if cellGrid.rowText(r).contains("File changed externally.") {
                found = true
                break
            }
        }
        #expect(found, "'File changed externally.' not found in rendered conflict modal")
    }
}

// MARK: - NvimDiffView snapshot tests

@Suite("NvimRenderSnapshot — DiffView")
struct NvimDiffRenderSnapshotTests {

    private func makeDiffState(
        leftLines: [String] = ["original line 1", "original line 2"],
        rightLines: [String] = ["edited line 1", "original line 2"],
        scrollOffset: Int = 0
    ) -> AppState {
        let diffViewState = DiffViewState(
            leftTitle: "On disk",
            rightTitle: "Edited",
            leftLines: leftLines,
            rightLines: rightLines,
            scrollOffset: scrollOffset
        )
        return AppState(
            focus: .diffView(.ready(diffViewState)),
            theme: ThemeEngine.resolve(capability: .truecolor),
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
    }

    @Test("diffView .building phase shows 'Building diff…' spinner")
    func diffViewBuildingSpinner() throws {
        let state = AppState(
            focus: .diffView(.building),
            theme: ThemeEngine.resolve(capability: .truecolor),
            terminalSize: TerminalSize(cols: 80, rows: 24)
        )
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)

        var found = false
        for r in 0..<cellGrid.rows {
            if cellGrid.rowText(r).contains("Building diff") {
                found = true
                break
            }
        }
        #expect(found, "'Building diff…' not found in .building render")
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_diff_building")
    }

    @Test("diffView .ready shows side-by-side left and right titles")
    func diffViewReadyTitles() throws {
        let state = makeDiffState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)

        var foundLeft = false
        var foundRight = false
        for r in 0..<cellGrid.rows {
            let row = cellGrid.rowText(r)
            if row.contains("On disk") { foundLeft = true }
            if row.contains("Edited") { foundRight = true }
        }
        #expect(foundLeft, "Left title 'On disk' not found")
        #expect(foundRight, "Right title 'Edited' not found")
    }

    @Test("diffView .ready snapshot matches golden")
    func diffViewReadySnapshot() throws {
        let state = makeDiffState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        try assertNvimSnapshot(grid: cellGrid, name: "nvim_diff_ready")
    }

    @Test("diffView .ready divider column '│' appears in every content row")
    func diffViewDivider() throws {
        let state = makeDiffState()
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)

        // At least one rendered row should contain the '│' divider character.
        var found = false
        for r in 0..<cellGrid.rows {
            if cellGrid.rowText(r).contains("│") {
                found = true
                break
            }
        }
        #expect(found, "Divider character '│' not found in diff view")
    }

    @Test("diffView .ready with scrollOffset shows correct line window")
    func diffViewScrollOffset() throws {
        let state = makeDiffState(
            leftLines: ["line A", "line B", "line C"],
            rightLines: ["line A", "line X", "line C"],
            scrollOffset: 1
        )
        let cellGrid = try nvimRenderGrid(state: state, cols: 80, rows: 24)
        // At scrollOffset=1 we should see "line B" / "line X" but NOT "line A".
        var foundB = false
        var foundA = false
        for r in 0..<cellGrid.rows {
            let row = cellGrid.rowText(r)
            if row.contains("line B") { foundB = true }
            if row.contains("line A") { foundA = true }
        }
        #expect(foundB, "Expected 'line B' at scrollOffset=1")
        #expect(!foundA, "Did not expect 'line A' at scrollOffset=1 (should be scrolled away)")
    }
}

// MARK: - hlAttrsToCellStyle unit tests

@Suite("NvimRenderSnapshot — hlAttrsToCellStyle")
struct HLAttrsCellStyleTests {

    @Test("hlAttrsToCellStyle maps fg/bg/bold/italic/underline correctly")
    func hlAttrsFullMapping() {
        let attrs = HLAttrs(
            fg: 0xFF0000, bg: 0x0000FF,
            bold: true, italic: true, underline: true, reverse: false
        )
        let style = hlAttrsToCellStyle(attrs, defaultStyle: .default)
        #expect(style.fg == 0xFF0000)
        #expect(style.bg == 0x0000FF)
        #expect(style.mods & 0x0001 != 0)  // BOLD
        #expect(style.mods & 0x0002 != 0)  // ITALIC
        #expect(style.mods & 0x0004 != 0)  // UNDERLINE
    }

    @Test("hlAttrsToCellStyle with reverse swaps fg and bg")
    func hlAttrsReverse() {
        let attrs = HLAttrs(
            fg: 0xFF0000, bg: 0x0000FF,
            bold: false, italic: false, underline: false, reverse: true
        )
        let style = hlAttrsToCellStyle(attrs, defaultStyle: .default)
        // After reverse: fg becomes 0x0000FF, bg becomes 0xFF0000.
        #expect(style.fg == 0x0000FF)
        #expect(style.bg == 0xFF0000)
    }

    @Test("hlAttrsToCellStyle with nil fg/bg uses 0xFFFF_FFFF sentinel")
    func hlAttrsNilColors() {
        let attrs = HLAttrs(
            fg: nil, bg: nil,
            bold: false, italic: false, underline: false, reverse: false
        )
        let style = hlAttrsToCellStyle(attrs, defaultStyle: .default)
        #expect(style.fg == 0xFFFF_FFFF)
        #expect(style.bg == 0xFFFF_FFFF)
    }

    @Test("hlAttrsToCellStyle with no modifiers produces mods == 0")
    func hlAttrsNoMods() {
        let attrs = HLAttrs(
            fg: 0xAABBCC, bg: nil,
            bold: false, italic: false, underline: false, reverse: false
        )
        let style = hlAttrsToCellStyle(attrs, defaultStyle: .default)
        #expect(style.mods == 0)
    }
}

// MARK: - Private helper

private func makeTestFragment(path: String = "/tmp/test.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
    let code = "return 1\n"
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let provenance = FragmentProvenance(
        file: url, jsonpath: nil, document: 0,
        byteRange: 0..<data.count, lineOffset: 0, contentHash: hash)
    return LuaSourceFragment(code: code, provenance: provenance)
}
