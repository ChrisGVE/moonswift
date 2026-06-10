// File: Tests/MoonSwiftTUITests/Nvim/NvimReducerTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer sequence tests for the nvim editing subsystem (Inc-4).
//       Verifies that AppEvent.nvimRedrawBatch correctly updates AppState.nvimGrid
//       — snapshot equality after a sequence of grid_resize, grid_line, grid_scroll,
//       grid_clear, hl_attr_define, and flush events applied via the pure reducer.
//
// Relationships:
//   → Reducer.swift      (Inc-4): system under test (reduceNvimRedrawBatch)
//   → AppState.swift     (Inc-4): holds nvimGrid field
//   → NvimGridState.swift (Inc-4): NvimGridState, NvimCellState, NvimGridState helpers

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func makeState() -> AppState {
    AppState()
}

/// Apply a sequence of events threading state through each step.
private func applyAll(_ state: AppState, _ events: [AppEvent]) -> AppState {
    events.reduce(state) { s, e in reduce(s, e).0 }
}

/// Convenience: build a .nvimRedrawBatch from a list of events.
private func batch(_ events: NvimRedrawEvent...) -> AppEvent {
    .nvimRedrawBatch(events)
}

// MARK: - Suite

@Suite("NvimReducerTests")
struct NvimReducerTests {

    // MARK: Grid initialisation

    @Test("nvimRedrawBatch with gridResize creates NvimGridState of correct dimensions")
    func gridResizeCreatesGrid() {
        let state = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 20, height: 10), .flush)
            ])

        guard let grid = state.nvimGrid else {
            Issue.record("nvimGrid should be non-nil after resize")
            return
        }
        #expect(grid.width == 20)
        #expect(grid.height == 10)
        #expect(grid.cells.count == 10)
        #expect(grid.cells[0].count == 20)
    }

    @Test("nvimGrid starts nil before any batch")
    func nvimGridStartsNil() {
        #expect(makeState().nvimGrid == nil)
    }

    @Test("nvimGrid is non-nil after any batch (lazy init)")
    func nvimGridLazyInit() {
        let state = applyAll(makeState(), [batch(.flush)])
        #expect(state.nvimGrid != nil)
    }

    // MARK: hl_attr_define caching

    @Test("hlAttrDefine populates hlCache in nvimGrid")
    func hlCachePopulated() {
        let attrs = HLAttrs(
            fg: 0xFF0000, bg: 0x0000FF, bold: true,
            italic: false, underline: false, reverse: false)
        let state = applyAll(
            makeState(),
            [
                batch(
                    .hlAttrDefine(id: 5, rgb: attrs),
                    .flush
                )
            ])
        #expect(state.nvimGrid?.hlCache[5] == attrs)
    }

    @Test("hlCache accumulates across multiple batches")
    func hlCacheAccumulates() {
        let a1 = HLAttrs(
            fg: 0xFF0000, bg: nil, bold: false,
            italic: false, underline: false, reverse: false)
        let a2 = HLAttrs(
            fg: nil, bg: 0x00FF00, bold: false,
            italic: false, underline: false, reverse: false)
        let state = applyAll(
            makeState(),
            [
                batch(.hlAttrDefine(id: 1, rgb: a1), .flush),
                batch(.hlAttrDefine(id: 2, rgb: a2), .flush),
            ])
        #expect(state.nvimGrid?.hlCache[1] == a1)
        #expect(state.nvimGrid?.hlCache[2] == a2)
    }

    // MARK: grid_line

    @Test("gridLine writes cells at correct position")
    func gridLineWritesCells() {
        let cells = [
            NvimCell(text: "H", hlId: 1, repeatCount: 1),
            NvimCell(text: "i", hlId: 1, repeatCount: 1),
        ]
        let state = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 10, height: 5), .flush),
                batch(.gridLine(grid: 1, row: 2, colStart: 3, cells: cells), .flush),
            ])
        guard let grid = state.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        #expect(grid.cells[2][3].text == "H")
        #expect(grid.cells[2][4].text == "i")
        // Column 2 (before colStart) is untouched.
        #expect(grid.cells[2][2].text == " ")
    }

    @Test("gridLine repeat count expands into consecutive columns in AppState")
    func gridLineRepeatInState() {
        let cells = [NvimCell(text: ".", hlId: 2, repeatCount: 4)]
        let state = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 10, height: 3), .flush),
                batch(.gridLine(grid: 1, row: 0, colStart: 1, cells: cells), .flush),
            ])
        guard let grid = state.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        for col in 1...4 {
            #expect(grid.cells[0][col].text == ".")
            #expect(grid.cells[0][col].hlId == 2)
        }
        // col 5 untouched.
        #expect(grid.cells[0][5].text == " ")
    }

    // MARK: grid_scroll

    @Test("gridScroll up moves rows toward lower indices and clears vacated rows")
    func gridScrollUpReducer() {
        // Fill row 3 with "S" to verify it moves to row 1 (scroll up by 2).
        var seed = makeState()
        seed = applyAll(
            seed,
            [
                batch(.gridResize(grid: 1, width: 5, height: 6), .flush)
            ])
        // Directly seed a cell on row 3 via another gridLine batch.
        let cells = [NvimCell(text: "S", hlId: 0, repeatCount: 5)]
        seed = applyAll(
            seed,
            [
                batch(.gridLine(grid: 1, row: 3, colStart: 0, cells: cells), .flush)
            ])

        // Scroll up by 2 across the full grid height.
        let final = applyAll(
            seed,
            [
                batch(.gridScroll(grid: 1, top: 0, bot: 6, left: 0, right: 5, rows: 2), .flush)
            ])
        guard let grid = final.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        // Old row 3 → new row 1.
        #expect(grid.cells[1][0].text == "S")
        // Old rows 4,5 → vacated → blank.
        #expect(grid.cells[4][0].text == " ")
        #expect(grid.cells[5][0].text == " ")
    }

    @Test("gridScroll down moves rows toward higher indices and clears vacated rows")
    func gridScrollDownReducer() {
        var seed = makeState()
        seed = applyAll(
            seed,
            [
                batch(.gridResize(grid: 1, width: 4, height: 5), .flush)
            ])
        let cells = [NvimCell(text: "D", hlId: 0, repeatCount: 4)]
        seed = applyAll(
            seed,
            [
                batch(.gridLine(grid: 1, row: 1, colStart: 0, cells: cells), .flush)
            ])

        // Scroll down by 1 (rows = -1).
        let final = applyAll(
            seed,
            [
                batch(.gridScroll(grid: 1, top: 0, bot: 5, left: 0, right: 4, rows: -1), .flush)
            ])
        guard let grid = final.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        // Old row 1 → new row 2.
        #expect(grid.cells[2][0].text == "D")
        // Row 0 (vacated) → blank.
        #expect(grid.cells[0][0].text == " ")
    }

    // MARK: grid_clear

    @Test("gridClear resets all cells to blank")
    func gridClearReducer() {
        let cells = [NvimCell(text: "Z", hlId: 3, repeatCount: 5)]
        let state = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 5, height: 3), .flush),
                batch(.gridLine(grid: 1, row: 1, colStart: 0, cells: cells), .flush),
                batch(.gridClear(grid: 1), .flush),
            ])
        guard let grid = state.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        #expect(grid.cells[1][0].text == " ")
        #expect(grid.cells[1][0].hlId == 0)
    }

    // MARK: cursor position

    @Test("gridCursorGoto updates cursorRow and cursorCol")
    func cursorGotoReducer() {
        let state = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 10, height: 5), .flush),
                batch(.gridCursorGoto(grid: 1, row: 3, col: 7), .flush),
            ])
        #expect(state.nvimGrid?.cursorRow == 3)
        #expect(state.nvimGrid?.cursorCol == 7)
    }

    // MARK: modeChange

    /// Mode storage lives on NvimPaneState, carried by FocusState.nvimPane —
    /// both arrive with the focus wiring in Inc-8 (ARCHITECTURE.md §10.8).
    /// Until then the reducer consumes modeChange without state change.
    @Test("modeChange in a batch is consumed without state change")
    func modeChangeConsumedWithoutStateChange() {
        let state = applyAll(
            makeState(),
            [
                batch(.modeChange(name: "insert", modeIdx: 1), .flush)
            ])
        // Focus unchanged (pane(.navigator) default).
        #expect(state.focus == .pane(.navigator))
    }

    // MARK: Flush invariant (reducer level)

    @Test("Reducer snapshot: nvimGrid state matches expected after resize+gridLine sequence")
    func snapshotAfterResizeAndGridLine() {
        let c1 = NvimCell(text: "H", hlId: 0, repeatCount: 1)
        let c2 = NvimCell(text: "i", hlId: 0, repeatCount: 1)
        let final = applyAll(
            makeState(),
            [
                batch(.gridResize(grid: 1, width: 5, height: 3), .flush),
                batch(.gridLine(grid: 1, row: 0, colStart: 0, cells: [c1, c2]), .flush),
            ])

        guard let grid = final.nvimGrid else {
            Issue.record("nvimGrid nil")
            return
        }
        var expected = NvimGridState(width: 5, height: 3)
        expected.applyGridLine(row: 0, colStart: 0, cells: [c1, c2])
        #expect(grid == expected)
    }
}
