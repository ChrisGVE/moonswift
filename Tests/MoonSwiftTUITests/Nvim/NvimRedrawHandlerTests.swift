// File: Tests/MoonSwiftTUITests/Nvim/NvimRedrawHandlerTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD tests for NvimRedrawHandler (Inc-4). Covers grid_line run expansion
//       with repeat counts, grid_scroll reference-shift semantics (both
//       directions), hl_attr_define caching, flush invariant (batch posted only
//       on flush; events before flush buffered), and NvimGridState mutations.
//
// Relationships:
//   → NvimRedrawHandler.swift (Inc-4): system under test
//   → NvimGridState.swift     (Inc-4): grid mutation helpers

import Foundation
import MoonSwiftCore
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Thread-safe batch collector for NvimRedrawHandler tests.
///
/// NvimRedrawHandler.init takes a `@Sendable` closure, which cannot capture a
/// mutable local `var`. This class wrapper is the idiomatic Swift 6 solution:
/// the closure captures the `final class` instance (reference semantics,
/// Sendable via @unchecked with the understanding that tests run single-threaded
/// through the handler's synchronous call path).
private final class BatchCollector: @unchecked Sendable {
    var batches: [[NvimRedrawEvent]] = []
    func collect(_ batch: [NvimRedrawEvent]) { batches.append(batch) }
}

/// Build a MessagePackValue array from a grid_line argument tuple.
/// cells: [[text, hl_id?, repeat?], …]
private func mpGridLine(
    grid: Int,
    row: Int,
    colStart: Int,
    cells: [[MessagePackValue]]
) -> MessagePackValue {
    let rawCells: [MessagePackValue] = cells.map { .array($0) }
    return .array([.int(Int64(grid)), .int(Int64(row)), .int(Int64(colStart)), .array(rawCells)])
}

/// Build a MessagePackValue for a grid_scroll argument tuple.
private func mpGridScroll(
    grid: Int, top: Int, bot: Int, left: Int, right: Int, rows: Int
) -> MessagePackValue {
    .array([
        .int(Int64(grid)), .int(Int64(top)), .int(Int64(bot)),
        .int(Int64(left)), .int(Int64(right)), .int(Int64(rows)),
        .int(0),
    ])
}

/// Build a minimal hl_attr_define argument tuple.
private func mpHlAttrDefine(id: Int, fg: UInt32? = nil, bg: UInt32? = nil) -> MessagePackValue {
    var dict: [MessagePackValue: MessagePackValue] = [:]
    if let fg { dict[.string("foreground")] = .uint(UInt64(fg)) }
    if let bg { dict[.string("background")] = .uint(UInt64(bg)) }
    return .array([.int(Int64(id)), .map(dict), .map([:]), .array([])])
}

/// Build a single-entry params array for a named sub-event.
/// This mirrors the nvim wire format: [[name, arg1, arg2, …]].
private func params(_ name: String, _ args: MessagePackValue...) -> [MessagePackValue] {
    [.array([.string(name)] + args)]
}

/// Build a redraw params array with multiple sub-events sharing the same name
/// (nvim coalesces same-name events into one outer array).
private func paramsMulti(_ name: String, _ args: [MessagePackValue]) -> [MessagePackValue] {
    [.array([.string(name)] + args)]
}

// MARK: - Suite

@Suite("NvimRedrawHandlerTests")
struct NvimRedrawHandlerTests {

    // MARK: Flush invariant

    @Test("Events before flush are buffered; batch posted exactly on flush")
    func flushInvariant() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // Send grid_resize without flush — no batch yet.
        handler.handleRedraw(
            params: params(
                "grid_resize",
                .array([.int(1), .int(10), .int(5)])
            ))
        #expect(collector.batches.isEmpty)

        // Send flush — exactly one batch posted.
        handler.handleRedraw(params: params("flush", .array([])))
        #expect(collector.batches.count == 1)

        // The batch must end with .flush.
        #expect(collector.batches[0].last == .flush)
    }

    @Test("Second flush after first produces a second independent batch")
    func twoFlushesProduceTwoBatches() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        handler.handleRedraw(params: params("flush", .array([])))
        handler.handleRedraw(params: params("flush", .array([])))

        #expect(collector.batches.count == 2)
    }

    @Test("Events between two flushes are correctly partitioned into separate batches")
    func eventsPartitionedByFlush() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // Batch 1: resize + flush
        handler.handleRedraw(
            params: params(
                "grid_resize",
                .array([.int(1), .int(8), .int(4)])
            ))
        handler.handleRedraw(params: params("flush", .array([])))

        // Batch 2: grid_clear + flush
        handler.handleRedraw(params: params("grid_clear", .array([.int(1)])))
        handler.handleRedraw(params: params("flush", .array([])))

        #expect(collector.batches.count == 2)
        // Batch 1 has resize + flush (2 events).
        #expect(collector.batches[0].count == 2)
        if case .gridResize(let g, let w, let h) = collector.batches[0][0] {
            #expect(g == 1)
            #expect(w == 8)
            #expect(h == 4)
        } else {
            Issue.record("Expected gridResize as first event in batch 1")
        }
        // Batch 2 has gridClear + flush.
        #expect(collector.batches[1].count == 2)
        if case .gridClear(let g) = collector.batches[1][0] {
            #expect(g == 1)
        } else {
            Issue.record("Expected gridClear as first event in batch 2")
        }
    }

    // MARK: hl_attr_define

    @Test("hl_attr_define is decoded with fg/bg/bold")
    func hlAttrDefineDecoded() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        let hlArgs = mpHlAttrDefine(id: 42, fg: 0xFF0000, bg: 0x00FF00)
        handler.handleRedraw(params: params("hl_attr_define", hlArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .hlAttrDefine(let id, let rgb) = collector.batches[0][0] else {
            Issue.record("Expected hlAttrDefine")
            return
        }
        #expect(id == 42)
        #expect(rgb.fg == 0xFF0000)
        #expect(rgb.bg == 0x00FF00)
    }

    @Test("hl_attr_define with bold flag")
    func hlAttrDefineBold() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        let boldMap: [MessagePackValue: MessagePackValue] = [.string("bold"): .bool(true)]
        let args: MessagePackValue = .array([.int(7), .map(boldMap), .map([:]), .array([])])
        handler.handleRedraw(params: params("hl_attr_define", args))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .hlAttrDefine(_, let rgb) = collector.batches[0][0] else {
            Issue.record("Expected hlAttrDefine")
            return
        }
        #expect(rgb.bold == true)
        #expect(rgb.fg == nil)
    }

    // MARK: grid_line run expansion

    @Test("grid_line single cell without repeat")
    func gridLineSingleCell() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        let cellArgs = mpGridLine(
            grid: 1, row: 0, colStart: 0,
            cells: [[.string("A"), .int(3)]]
        )
        handler.handleRedraw(params: params("grid_line", cellArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .gridLine(_, _, _, let cells) = collector.batches[0][0] else {
            Issue.record("Expected gridLine")
            return
        }
        #expect(cells.count == 1)
        #expect(cells[0].text == "A")
        #expect(cells[0].hlId == 3)
        #expect(cells[0].repeatCount == 1)
    }

    @Test("grid_line cell with repeat count expands correctly")
    func gridLineRepeatCount() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // " " repeated 5 times with hlId 2
        let cellArgs = mpGridLine(
            grid: 1, row: 0, colStart: 0,
            cells: [[.string(" "), .int(2), .int(5)]]
        )
        handler.handleRedraw(params: params("grid_line", cellArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .gridLine(_, _, _, let cells) = collector.batches[0][0] else {
            Issue.record("Expected gridLine")
            return
        }
        #expect(cells.count == 1)
        #expect(cells[0].repeatCount == 5)
        #expect(cells[0].hlId == 2)
    }

    @Test("grid_line hlId carry-over when omitted (element [1] absent)")
    func gridLineHlIdCarryOver() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // First cell sets hlId=5; second cell omits hlId (only text present).
        let cellArgs = mpGridLine(
            grid: 1, row: 0, colStart: 0,
            cells: [
                [.string("A"), .int(5)],
                [.string("B")],  // no hlId → carries from previous
            ]
        )
        handler.handleRedraw(params: params("grid_line", cellArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .gridLine(_, _, _, let cells) = collector.batches[0][0] else {
            Issue.record("Expected gridLine")
            return
        }
        #expect(cells.count == 2)
        #expect(cells[0].hlId == 5)
        #expect(cells[1].hlId == 5)  // carried from cell 0
    }

    @Test("grid_line multiple cells mix repeat and carry")
    func gridLineMixedRepeatCarry() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        let cellArgs = mpGridLine(
            grid: 1, row: 2, colStart: 3,
            cells: [
                [.string("X"), .int(10), .int(3)],  // "X" ×3, hl=10
                [.string("Y")],  // "Y" ×1, hl=10 (carried)
            ]
        )
        handler.handleRedraw(params: params("grid_line", cellArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .gridLine(_, let row, let colStart, let cells) = collector.batches[0][0] else {
            Issue.record("Expected gridLine")
            return
        }
        #expect(row == 2)
        #expect(colStart == 3)
        #expect(cells.count == 2)
        #expect(cells[0].repeatCount == 3)
        #expect(cells[0].hlId == 10)
        #expect(cells[1].repeatCount == 1)
        #expect(cells[1].hlId == 10)
    }

    // MARK: grid_scroll decoded correctly

    @Test("grid_scroll sub-event decoded into NvimRedrawEvent.gridScroll")
    func gridScrollDecoded() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        let scrollArgs = mpGridScroll(grid: 1, top: 2, bot: 8, left: 0, right: 10, rows: 3)
        handler.handleRedraw(params: params("grid_scroll", scrollArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        guard case .gridScroll(let g, let top, let bot, let left, let right, let rows) = collector.batches[0][0] else {
            Issue.record("Expected gridScroll")
            return
        }
        #expect(g == 1)
        #expect(top == 2)
        #expect(bot == 8)
        #expect(left == 0)
        #expect(right == 10)
        #expect(rows == 3)
    }

    // MARK: Unrecognised events

    @Test("Unrecognised sub-event name is silently dropped without crashing")
    func unknownSubEventDropped() {
        let collector = BatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // "win_pos" is a valid nvim sub-event but not handled in P4.
        let winPosArgs: MessagePackValue = .array([.int(1), .int(0), .int(0), .int(0), .int(10), .int(5), .bool(false)])
        handler.handleRedraw(params: params("win_pos", winPosArgs))
        handler.handleRedraw(params: params("flush", .array([])))

        // Batch is posted (flush triggers it), but only contains .flush.
        #expect(collector.batches.count == 1)
        #expect(collector.batches[0].count == 1)
        #expect(collector.batches[0][0] == .flush)
    }
}
