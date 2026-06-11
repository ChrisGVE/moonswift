// File: Sources/MoonSwiftTUI/Nvim/NvimRedrawHandler.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Decodes nvim `redraw` notification batches — arrays of sub-event arrays
//       in the ext_linegrid UI protocol — into [NvimRedrawEvent] and posts an
//       AppEvent.nvimRedrawBatch only when the terminating `.flush` sub-event
//       is observed. Events before flush are buffered; partial batches are held.
//
// Architecture context (ARCHITECTURE.md §10.4.7, §10.4.8):
//   NvimRPCClient (actor) registers NvimRedrawHandler.handleRedraw as the
//   "redraw" notification handler via onNotification("redraw", …). The handler
//   runs on the actor's executor (actor-isolation guarantee). It decodes the
//   raw MessagePackValue params array, appends to a mutable buffer, and posts
//   AppEvent.nvimRedrawBatch([NvimRedrawEvent]) ONLY when the batch terminates
//   with a .flush sub-event.
//
//   Flush invariant (binding): every nvim redraw notification in ext_linegrid
//   mode ends with a flush sub-event. A batch without flush is a protocol
//   error: events are buffered until the next flush rather than posted
//   partially (ARCHITECTURE.md §10.4.8).
//
//   hl_attr_define carry: each batch may define new highlight IDs before using
//   them in grid_line events. The handler carries hlId forward within a
//   gridLine cell run — when a NvimCell.hlId is 0 (nvim's "same hl as
//   previous"), the last non-zero hlId from that run is reused.
//
// Relationships:
//   ← NvimRPCClient (Inc-3): calls handleRedraw via onNotification
//   → EventChannel  (App):   posts AppEvent.nvimRedrawBatch
//   → NvimRedrawEvent.swift  (Inc-3): type definitions consumed here

import Foundation
import MoonSwiftCore

// MARK: - NvimRedrawHandler

/// Stateful decoder for nvim's `redraw` RPC notification stream.
///
/// One instance is created per nvim session and registered on `NvimRPCClient`
/// via `onNotification("redraw", handler.handleRedraw)`. The handler is always
/// invoked on the actor's executor (serialised), so no additional locking is
/// needed.
///
/// The handler accumulates events across multiple `redraw` notification calls
/// (nvim may coalesce several logical batches into one call, or split them).
/// A batch is posted to the `EventChannel` exactly once, when `.flush` is seen.
public final class NvimRedrawHandler: @unchecked Sendable {

    // MARK: - Dependencies

    /// The channel to post AppEvent.nvimRedrawBatch on flush.
    private let post: @Sendable ([NvimRedrawEvent]) -> Void

    // MARK: - Mutable buffer (accessed only on the actor's executor)

    /// Accumulated events since the last posted batch (or since init).
    private var pending: [NvimRedrawEvent] = []

    // MARK: - Init

    /// - Parameter post: Called with the complete event list each time a
    ///   terminating `flush` sub-event is observed. The closure should post
    ///   `AppEvent.nvimRedrawBatch(events)` to the `EventChannel`.
    public init(post: @Sendable @escaping ([NvimRedrawEvent]) -> Void) {
        self.post = post
    }

    // MARK: - Main entry point

    /// Decode a `redraw` notification's params array and buffer decoded events.
    ///
    /// Called by `NvimRPCClient.onNotification("redraw", …)` on the actor's
    /// executor. `params` is the top-level array from the RPC notification:
    /// `[[subEventName, arg1, arg2, …], [subEventName, …], …]`.
    ///
    /// Each outer element is itself an array whose first element is the
    /// sub-event name string, followed by one or more argument tuples.
    /// For example, `grid_line` is encoded as:
    ///   `["grid_line", [grid, row, col_start, cells], [grid, row, …], …]`
    /// where multiple argument tuples share the same sub-event name.
    ///
    /// When `.flush` is found, the buffered events (including the flush) are
    /// posted and the buffer is cleared.
    public func handleRedraw(params: [MessagePackValue]) {
        for outerValue in params {
            guard case .array(let subArray) = outerValue,
                !subArray.isEmpty,
                case .string(let eventName) = subArray[0]
            else {
                Logger.shared.debug(
                    "NvimRedrawHandler: unexpected outer element shape — dropped"
                )
                continue
            }

            // Each sub-array is [eventName, argTuple1, argTuple2, …].
            // Iterate over argument tuples (indices 1…).
            // Special case: sub-events with no argument tuples (e.g. "flush")
            // have subArray.count == 1. Synthesise a .nil sentinel so the
            // decoder sees the event name even with no args.
            if subArray.count == 1 {
                let event = decode(eventName: eventName, args: .nil)
                if let event {
                    pending.append(event)
                    if case .flush = event {
                        let batch = pending
                        pending = []
                        post(batch)
                    }
                }
            } else {
                for argIndex in 1..<subArray.count {
                    let event = decode(eventName: eventName, args: subArray[argIndex])
                    if let event {
                        pending.append(event)
                        if case .flush = event {
                            let batch = pending
                            pending = []
                            post(batch)
                        }
                    } else {
                        Logger.shared.debug(
                            "NvimRedrawHandler: unrecognised sub-event '\(eventName)' — dropped"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Decoder

    /// Decode one argument tuple for the given sub-event name.
    ///
    /// Returns `nil` for unrecognised event names or malformed argument shapes.
    /// `.flush` has no arguments; nvim encodes it as `["flush"]` so this
    /// method is called with `args == .nil` for that case (we synthesise the
    /// `.nil` sentinel above when argIndex >= subArray.count). To handle
    /// `flush` properly we call decode with a sentinel nil when there are no
    /// arg tuples (handled in the special flush path below).
    ///
    /// Note: this private method is always called on the actor's executor
    /// because handleRedraw is called there and calls this synchronously.
    private func decode(eventName: String, args: MessagePackValue) -> NvimRedrawEvent? {
        switch eventName {

        case "flush":
            return .flush

        case "hl_attr_define":
            return decodeHlAttrDefine(args)

        case "default_colors_set":
            return decodeDefaultColorsSet(args)

        case "grid_resize":
            return decodeGridResize(args)

        case "grid_line":
            return decodeGridLine(args)

        case "grid_cursor_goto":
            return decodeGridCursorGoto(args)

        case "grid_scroll":
            return decodeGridScroll(args)

        case "grid_clear":
            return decodeGridClear(args)

        case "mode_change":
            return decodeModeChange(args)

        default:
            return nil
        }
    }

    // MARK: - Per-event decoders

    private func decodeHlAttrDefine(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // hl_attr_define: [id, rgb_attrs_map, cterm_attrs_map, info]
        guard case .array(let a) = args, a.count >= 2 else { return nil }
        guard let id = intValue(a[0]) else { return nil }

        var fg: UInt32? = nil
        var bg: UInt32? = nil
        var bold = false
        var italic = false
        var underline = false
        var reverse = false

        if case .map(let m) = a[1] {
            for (k, v) in m {
                guard case .string(let key) = k else { continue }
                switch key {
                case "foreground":
                    fg = uint32Value(v)
                case "background":
                    bg = uint32Value(v)
                case "bold":
                    bold = boolValue(v)
                case "italic":
                    italic = boolValue(v)
                case "underline":
                    underline = boolValue(v)
                case "reverse":
                    reverse = boolValue(v)
                default:
                    break
                }
            }
        }

        let attrs = HLAttrs(
            fg: fg, bg: bg,
            bold: bold, italic: italic, underline: underline, reverse: reverse
        )
        return .hlAttrDefine(id: id, rgb: attrs)
    }

    private func decodeDefaultColorsSet(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // default_colors_set: [fg, bg, sp, cterm_fg, cterm_bg]
        guard case .array(let a) = args, a.count >= 3 else { return nil }
        guard let fg = uint32Value(a[0]),
            let bg = uint32Value(a[1]),
            let sp = uint32Value(a[2])
        else { return nil }
        return .defaultColorsSet(fg: fg, bg: bg, sp: sp)
    }

    private func decodeGridResize(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // grid_resize: [grid, width, height]
        guard case .array(let a) = args, a.count >= 3 else { return nil }
        guard let grid = intValue(a[0]),
            let width = intValue(a[1]),
            let height = intValue(a[2])
        else { return nil }
        return .gridResize(grid: grid, width: width, height: height)
    }

    private func decodeGridLine(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // grid_line: [grid, row, col_start, cells, wrap]
        // cells: [[text, hl_id?, repeat?], …]
        guard case .array(let a) = args, a.count >= 4 else { return nil }
        guard let grid = intValue(a[0]),
            let row = intValue(a[1]),
            let colStart = intValue(a[2]),
            case .array(let rawCells) = a[3]
        else { return nil }

        var cells: [NvimCell] = []
        cells.reserveCapacity(rawCells.count)
        var lastHlId = 0

        for rawCell in rawCells {
            guard case .array(let c) = rawCell, !c.isEmpty else { continue }
            guard case .string(let text) = c[0] else { continue }

            // hl_id is element [1] when present; omit = carry last.
            let hlId: Int
            if c.count >= 2, let h = intValue(c[1]) {
                hlId = h
                lastHlId = h
            } else {
                hlId = lastHlId
            }

            // repeat count is element [2] when present; default 1.
            let repeatCount: Int
            if c.count >= 3, let r = intValue(c[2]), r > 1 {
                repeatCount = r
            } else {
                repeatCount = 1
            }

            cells.append(NvimCell(text: text, hlId: hlId, repeatCount: repeatCount))
        }

        return .gridLine(grid: grid, row: row, colStart: colStart, cells: cells)
    }

    private func decodeGridCursorGoto(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // grid_cursor_goto: [grid, row, col]
        guard case .array(let a) = args, a.count >= 3 else { return nil }
        guard let grid = intValue(a[0]),
            let row = intValue(a[1]),
            let col = intValue(a[2])
        else { return nil }
        return .gridCursorGoto(grid: grid, row: row, col: col)
    }

    private func decodeGridScroll(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // grid_scroll: [grid, top, bot, left, right, rows, cols]
        guard case .array(let a) = args, a.count >= 6 else { return nil }
        guard let grid = intValue(a[0]),
            let top = intValue(a[1]),
            let bot = intValue(a[2]),
            let left = intValue(a[3]),
            let right = intValue(a[4]),
            let rows = intValue(a[5])
        else { return nil }
        return .gridScroll(grid: grid, top: top, bot: bot, left: left, right: right, rows: rows)
    }

    private func decodeGridClear(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // grid_clear: [grid]
        guard case .array(let a) = args, !a.isEmpty else { return nil }
        guard let grid = intValue(a[0]) else { return nil }
        return .gridClear(grid: grid)
    }

    private func decodeModeChange(_ args: MessagePackValue) -> NvimRedrawEvent? {
        // mode_change: [name, mode_idx]
        guard case .array(let a) = args, a.count >= 2 else { return nil }
        guard case .string(let name) = a[0],
            let modeIdx = intValue(a[1])
        else { return nil }
        return .modeChange(name: name, modeIdx: modeIdx)
    }

    // MARK: - MessagePackValue helpers

    private func intValue(_ v: MessagePackValue) -> Int? {
        switch v {
        case .int(let i): return Int(i)
        case .uint(let u): return Int(exactly: u)
        default: return nil
        }
    }

    private func uint32Value(_ v: MessagePackValue) -> UInt32? {
        switch v {
        case .int(let i) where i >= 0: return UInt32(exactly: i)
        case .uint(let u): return UInt32(exactly: u)
        default: return nil
        }
    }

    private func boolValue(_ v: MessagePackValue) -> Bool {
        if case .bool(let b) = v { return b }
        return false
    }
}
