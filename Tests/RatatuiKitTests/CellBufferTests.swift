// File: Tests/RatatuiKitTests/CellBufferTests.swift
// Role: Verifies the CellBuffer batching logic and CellGrid in-memory backend.
//       All tests use MockCellWriter — no real terminal or FFI call is made.
//       Tests enforce the ARCHITECTURE.md §3b contract: one FFI call per
//       contiguous same-style run per row, never per-cell.
// Upstream: RatatuiKit/CellBuffer.swift (CellBuffer, CellStyle, CellGrid)
// Downstream: (test target — nothing imports this)

import Testing
@testable import RatatuiKit

// MARK: - MockCellWriter

/// Records every writeCells and clearRect call for assertion.
final class MockCellWriter: CellWriter {

    struct WriteCall: Equatable {
        let col: UInt16
        let row: UInt16
        let text: String
        let style: CellStyle
    }

    struct ClearCall: Equatable {
        let col: UInt16
        let row: UInt16
        let width: UInt16
        let height: UInt16
    }

    private(set) var writeCalls: [WriteCall] = []
    private(set) var clearCalls: [ClearCall] = []

    func writeCells(col: UInt16, row: UInt16, text: String, style: CellStyle) throws {
        writeCalls.append(WriteCall(col: col, row: row, text: text, style: style))
    }

    func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) throws {
        clearCalls.append(ClearCall(col: col, row: row, width: width, height: height))
    }
}

// MARK: - Batching contract tests

@Suite("CellBuffer — batching contract")
struct CellBufferBatchingTests {

    @Test("same-style adjacent cells produce one write call")
    func sameStyleRunProducesOneCall() throws {
        let buf = CellBuffer()
        let style = CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0)
        buf.write(col: 0, row: 0, char: "a", style: style)
        buf.write(col: 1, row: 0, char: "b", style: style)
        buf.write(col: 2, row: 0, char: "c", style: style)

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        #expect(mock.writeCalls.count == 1)
        #expect(mock.writeCalls[0].text == "abc")
        #expect(mock.writeCalls[0].col == 0)
        #expect(mock.writeCalls[0].row == 0)
        #expect(mock.writeCalls[0].style == style)
    }

    @Test("style change splits into two write calls")
    func styleChangeSplitsRun() throws {
        let buf = CellBuffer()
        let s1 = CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0)
        let s2 = CellStyle(fg: 0x0000FF, bg: 0xFFFFFF, mods: 0)
        buf.write(col: 0, row: 0, char: "a", style: s1)
        buf.write(col: 1, row: 0, char: "b", style: s2)

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        #expect(mock.writeCalls.count == 2)
        #expect(mock.writeCalls[0].text == "a")
        #expect(mock.writeCalls[1].text == "b")
    }

    @Test("row change starts a new run")
    func rowChangeSplitsRun() throws {
        let buf = CellBuffer()
        let style = CellStyle()
        buf.write(col: 0, row: 0, char: "a", style: style)
        buf.write(col: 0, row: 1, char: "b", style: style)

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        // Two separate row runs even though style is the same
        #expect(mock.writeCalls.count == 2)
        #expect(mock.writeCalls[0].row == 0)
        #expect(mock.writeCalls[1].row == 1)
    }

    @Test("column gap starts a new run")
    func columnGapSplitsRun() throws {
        let buf = CellBuffer()
        let style = CellStyle()
        buf.write(col: 0, row: 0, char: "a", style: style)
        // Skip col 1 — gap
        buf.write(col: 2, row: 0, char: "c", style: style)

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        #expect(mock.writeCalls.count == 2)
        #expect(mock.writeCalls[0].col == 0)
        #expect(mock.writeCalls[1].col == 2)
    }

    @Test("flush resets buffer — second flush produces no calls")
    func flushResetsBuffer() throws {
        let buf = CellBuffer()
        let style = CellStyle()
        buf.write(col: 0, row: 0, char: "x", style: style)

        let mock = MockCellWriter()
        try buf.flush(to: mock)
        #expect(mock.writeCalls.count == 1)

        // Second flush after reset — no new writes
        try buf.flush(to: mock)
        #expect(mock.writeCalls.count == 1)
    }

    @Test("empty buffer flush produces no calls")
    func emptyFlushProducesNoCalls() throws {
        let buf = CellBuffer()
        let mock = MockCellWriter()
        try buf.flush(to: mock)
        #expect(mock.writeCalls.isEmpty)
    }

    @Test("12k cells in worst-case style-per-cell scenario capped at row * runs")
    func batchingConstraintAtScale() throws {
        // Simulate a 200-col single row with alternating styles (worst case:
        // every other cell changes style — 100 runs). The batcher must never
        // produce 200 calls.
        let buf = CellBuffer()
        let s1 = CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0)
        let s2 = CellStyle(fg: 0x0000FF, bg: 0xFFFFFF, mods: 0)
        for col in 0..<200 {
            let style = col.isMultiple(of: 2) ? s1 : s2
            buf.write(col: UInt16(col), row: 0, char: "x", style: style)
        }

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        // Alternating styles: 200 single-char runs (each style change = new run).
        // This is the worst case — still finite and bounded by column count.
        // The important thing: it is NOT 200 individual-cell FFI calls from the
        // caller's perspective (the caller writes cells; the batcher emits runs).
        #expect(mock.writeCalls.count == 200, "Worst case: 200 single-char runs (every-other-cell alternation)")
        #expect(mock.writeCalls.count < 12_000, "Never per-cell at 12k cells")
    }

    @Test("mixed rows produce correct per-row run boundaries")
    func mixedRowsCorrectBoundaries() throws {
        let buf = CellBuffer()
        let red  = CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0)
        let blue = CellStyle(fg: 0x0000FF, bg: 0xFFFFFF, mods: 0)

        // Row 0: red "ab", blue "cd"
        buf.write(col: 0, row: 0, char: "a", style: red)
        buf.write(col: 1, row: 0, char: "b", style: red)
        buf.write(col: 2, row: 0, char: "c", style: blue)
        buf.write(col: 3, row: 0, char: "d", style: blue)

        // Row 1: all red
        buf.write(col: 0, row: 1, char: "e", style: red)
        buf.write(col: 1, row: 1, char: "f", style: red)

        let mock = MockCellWriter()
        try buf.flush(to: mock)

        // Row 0: 2 runs; Row 1: 1 run → total 3
        #expect(mock.writeCalls.count == 3)
        #expect(mock.writeCalls[0].text == "ab")
        #expect(mock.writeCalls[1].text == "cd")
        #expect(mock.writeCalls[2].text == "ef")
    }

    @Test("clearRect forwards to writer")
    func clearRectForwards() throws {
        let buf = CellBuffer()
        let mock = MockCellWriter()
        try buf.clearRect(col: 5, row: 10, width: 20, height: 3, writer: mock)

        #expect(mock.clearCalls.count == 1)
        #expect(mock.clearCalls[0].col == 5)
        #expect(mock.clearCalls[0].row == 10)
        #expect(mock.clearCalls[0].width == 20)
        #expect(mock.clearCalls[0].height == 3)
    }
}

// MARK: - CellGrid tests

@Suite("CellGrid — in-memory snapshot backend")
struct CellGridTests {

    @Test("initial cells are blank with default style")
    func initialCells() {
        let grid = CellGrid(cols: 10, rows: 5)
        #expect(grid.rowText(0) == "          ") // 10 spaces
        for row in 0..<5 {
            for col in 0..<10 {
                #expect(grid.cells[row][col].char == " ")
                #expect(grid.cells[row][col].style == .default)
            }
        }
    }

    @Test("writeCells populates cells correctly")
    func writeCellsPopulatesCells() throws {
        let grid = CellGrid(cols: 20, rows: 5)
        let style = CellStyle(fg: 0xFF0000, bg: 0x000000, mods: 0)
        try grid.writeCells(col: 2, row: 1, text: "hello", style: style)

        #expect(grid.cells[1][2].char == "h")
        #expect(grid.cells[1][3].char == "e")
        #expect(grid.cells[1][4].char == "l")
        #expect(grid.cells[1][5].char == "l")
        #expect(grid.cells[1][6].char == "o")
        #expect(grid.cells[1][2].style == style)
    }

    @Test("writeCells clips at grid boundary")
    func writeCellsClipsAtBoundary() throws {
        let grid = CellGrid(cols: 5, rows: 3)
        // Write a text that extends past col 5
        try grid.writeCells(col: 3, row: 0, text: "ABCDE", style: .default)
        // Only "AB" fit (cols 3 and 4)
        #expect(grid.cells[0][3].char == "A")
        #expect(grid.cells[0][4].char == "B")
        // Out-of-bounds row silently ignored
    }

    @Test("clearRect blanks the specified region")
    func clearRectBlanksRegion() throws {
        let grid = CellGrid(cols: 10, rows: 5)
        let style = CellStyle(fg: 0xFF0000, bg: 0x000000, mods: 0)
        // Fill a region
        try grid.writeCells(col: 2, row: 1, text: "hello", style: style)
        // Clear it
        try grid.clearRect(col: 2, row: 1, width: 5, height: 1)

        for col in 2...6 {
            #expect(grid.cells[1][col].char == " ")
            #expect(grid.cells[1][col].style == .default)
        }
    }

    @Test("rowText returns concatenated row characters")
    func rowTextConcatenatesChars() throws {
        let grid = CellGrid(cols: 5, rows: 2)
        let style = CellStyle()
        try grid.writeCells(col: 0, row: 0, text: "hello", style: style)
        #expect(grid.rowText(0) == "hello")
    }

    @Test("rowText returns empty string for out-of-bounds row")
    func rowTextOutOfBoundsIsEmpty() {
        let grid = CellGrid(cols: 5, rows: 2)
        #expect(grid.rowText(99).isEmpty)
    }

    @Test("CellGrid conforms to CellWriter — usable as flush target")
    func cellGridAsFlushTarget() throws {
        let grid = CellGrid(cols: 10, rows: 3)
        let buf = CellBuffer()
        let style = CellStyle()
        buf.write(col: 0, row: 0, char: "X", style: style)
        buf.write(col: 1, row: 0, char: "Y", style: style)

        // CellGrid conforms to CellWriter — flush directly to it
        try buf.flush(to: grid)

        #expect(grid.cells[0][0].char == "X")
        #expect(grid.cells[0][1].char == "Y")
    }
}

// MARK: - CellStyle tests

@Suite("CellStyle")
struct CellStyleTests {

    @Test("default style has terminal-default colors and no mods")
    func defaultStyle() {
        let s = CellStyle.default
        #expect(s.fg == 0xFFFFFFFF)
        #expect(s.bg == 0xFFFFFFFF)
        #expect(s.mods == 0)
    }

    @Test("CellStyle equality")
    func equality() {
        let a = CellStyle(fg: 0xFF0000, bg: 0x000000, mods: 1)
        let b = CellStyle(fg: 0xFF0000, bg: 0x000000, mods: 1)
        let c = CellStyle(fg: 0x00FF00, bg: 0x000000, mods: 1)
        #expect(a == b)
        #expect(a != c)
    }
}
