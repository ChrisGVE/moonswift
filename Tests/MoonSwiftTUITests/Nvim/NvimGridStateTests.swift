// File: Tests/MoonSwiftTUITests/Nvim/NvimGridStateTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Unit tests for NvimGridState direct mutation methods — applyGridLine
//       (repeat-count expansion, row-bounds safety) and applyScroll (reference-
//       shift semantics in both directions, vacated-row clearing, no-op guard).
//       Split from NvimRedrawHandlerTests.swift to stay within the 400-line budget.
//
// Relationships:
//   → NvimGridState.swift (Inc-4): system under test

import Foundation
import MoonSwiftCore
import Testing

@testable import MoonSwiftTUI

// MARK: - Suite

@Suite("NvimGridStateTests")
struct NvimGridStateTests {

    // MARK: NvimGridState.applyGridLine

    @Test("applyGridLine expands repeat count into consecutive columns")
    func gridStateApplyGridLineRepeat() {
        var grid = NvimGridState(width: 10, height: 3)
        let cells = [NvimCell(text: "Z", hlId: 7, repeatCount: 4)]
        grid.applyGridLine(row: 1, colStart: 2, cells: cells)

        // Columns 2,3,4,5 should be "Z" with hlId 7.
        for col in 2...5 {
            #expect(grid.cells[1][col].text == "Z")
            #expect(grid.cells[1][col].hlId == 7)
        }
        // Column 6 untouched (blank).
        #expect(grid.cells[1][6].text == " ")
    }

    @Test("applyGridLine does not write beyond row bounds")
    func gridStateApplyGridLineRowBounds() {
        var grid = NvimGridState(width: 5, height: 2)
        // Row 99 is out of bounds — must not crash.
        grid.applyGridLine(
            row: 99, colStart: 0, cells: [NvimCell(text: "X", hlId: 0, repeatCount: 1)])
        // Grid unchanged.
        #expect(grid.cells[0][0].text == " ")
    }

    @Test("applyGridLine with colStart at end of row writes nothing")
    func gridStateApplyGridLineColBounds() {
        var grid = NvimGridState(width: 3, height: 2)
        grid.applyGridLine(
            row: 0, colStart: 3, cells: [NvimCell(text: "X", hlId: 0, repeatCount: 1)])
        // All cells untouched.
        for col in 0..<3 { #expect(grid.cells[0][col].text == " ") }
    }

    // MARK: NvimGridState.applyScroll

    @Test("applyScroll up (positive rows) shifts rows toward lower indices")
    func gridScrollUp() {
        var grid = NvimGridState(width: 5, height: 5)
        // Mark row 2 with "A".
        for col in 0..<5 { grid.cells[2][col] = NvimCellState(text: "A", hlId: 0) }
        // Mark row 3 with "B".
        for col in 0..<5 { grid.cells[3][col] = NvimCellState(text: "B", hlId: 0) }

        // Scroll up by 2 in the full region [0,5) × [0,5).
        grid.applyScroll(top: 0, bot: 5, left: 0, right: 5, rows: 2)

        // Old row 2 → row 0.
        #expect(grid.cells[0][0].text == "A")
        // Old row 3 → row 1.
        #expect(grid.cells[1][0].text == "B")
        // Rows 3,4 (vacated) → blank.
        #expect(grid.cells[3][0].text == " ")
        #expect(grid.cells[4][0].text == " ")
    }

    @Test("applyScroll down (negative rows) shifts rows toward higher indices")
    func gridScrollDown() {
        var grid = NvimGridState(width: 5, height: 5)
        // Mark row 1 with "C".
        for col in 0..<5 { grid.cells[1][col] = NvimCellState(text: "C", hlId: 0) }

        // Scroll down by 1 (rows = -1).
        grid.applyScroll(top: 0, bot: 5, left: 0, right: 5, rows: -1)

        // Old row 1 → row 2.
        #expect(grid.cells[2][0].text == "C")
        // Row 0 (vacated) → blank.
        #expect(grid.cells[0][0].text == " ")
        // Row 1 should be blank (content moved away).
        #expect(grid.cells[1][0].text == " ")
    }

    @Test("applyScroll up clears only vacated rows at bottom of region")
    func gridScrollUpVacatedRows() {
        var grid = NvimGridState(width: 4, height: 6)
        // Fill all rows with "X".
        for row in 0..<6 {
            for col in 0..<4 { grid.cells[row][col] = NvimCellState(text: "X", hlId: 0) }
        }
        // Scroll up by 2 in rows [1,5).
        grid.applyScroll(top: 1, bot: 5, left: 0, right: 4, rows: 2)

        // Rows 3,4 should be blank (vacated).
        #expect(grid.cells[3][0].text == " ")
        #expect(grid.cells[4][0].text == " ")
        // Row 0 and row 5 (outside scroll region) untouched.
        #expect(grid.cells[0][0].text == "X")
        #expect(grid.cells[5][0].text == "X")
    }

    @Test("applyScroll with rows=0 is a no-op")
    func gridScrollNoop() {
        var grid = NvimGridState(width: 3, height: 3)
        for col in 0..<3 { grid.cells[1][col] = NvimCellState(text: "Q", hlId: 0) }
        grid.applyScroll(top: 0, bot: 3, left: 0, right: 3, rows: 0)
        #expect(grid.cells[1][0].text == "Q")
    }

    // MARK: NvimGridState.resize

    @Test("resize expands grid to larger dimensions filling blanks")
    func resizeExpand() {
        var grid = NvimGridState(width: 3, height: 2)
        grid.cells[0][0] = NvimCellState(text: "A", hlId: 1)
        grid.resize(width: 5, height: 4)

        #expect(grid.width == 5)
        #expect(grid.height == 4)
        // Pre-existing cell preserved.
        #expect(grid.cells[0][0].text == "A")
        // New columns filled blank.
        #expect(grid.cells[0][3].text == " ")
        // New row filled blank.
        #expect(grid.cells[3][0].text == " ")
    }

    @Test("resize shrinks grid dropping excess rows and columns")
    func resizeShrink() {
        var grid = NvimGridState(width: 10, height: 5)
        grid.resize(width: 4, height: 3)

        #expect(grid.width == 4)
        #expect(grid.height == 3)
        #expect(grid.cells.count == 3)
        #expect(grid.cells[0].count == 4)
    }

    // MARK: NvimGridState.clearAll

    @Test("clearAll resets all cells to blank")
    func clearAll() {
        var grid = NvimGridState(width: 4, height: 3)
        for row in 0..<3 {
            for col in 0..<4 { grid.cells[row][col] = NvimCellState(text: "X", hlId: 5) }
        }
        grid.clearAll()
        for row in 0..<3 {
            for col in 0..<4 {
                #expect(grid.cells[row][col].text == " ")
                #expect(grid.cells[row][col].hlId == 0)
            }
        }
    }
}
