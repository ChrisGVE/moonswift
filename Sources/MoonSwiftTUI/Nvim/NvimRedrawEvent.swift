// File: Sources/MoonSwiftTUI/Nvim/NvimRedrawEvent.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Sendable value types representing nvim ext_linegrid redraw sub-events.
//       These are TYPE DEFINITIONS ONLY — parsing a "redraw" notification into
//       these types is Inc-4's NvimRedrawHandler. The framer (Inc-1) decodes
//       raw bytes into [MessagePackValue]; the handler (Inc-4) maps those values
//       into NvimRedrawEvent instances.
//
// Architecture context (ARCHITECTURE.md §10.4.7):
//   NvimRPCClient (actor) delivers redraw batches to NvimRedrawHandler, which
//   maps them to [NvimRedrawEvent] and posts AppEvent.nvimRedrawBatch to the
//   EventChannel. The reducer applies the batch to AppState.nvimGrid before
//   the AppDriver issues a CellBuffer flush. Every batch in ext_linegrid mode
//   terminates with .flush — the handler must not post a batch without it.
//
// Relationships:
//   → NvimRedrawHandler.swift   (Inc-4): consumes these types
//   → AppState.nvimGrid         (Inc-4): NvimGridState updated by handler
//   → MsgpackRPCFramer.swift    (this increment): produces MessagePackValue input

// MARK: - Cell

/// A single character cell within a grid_line update.
///
/// `repeatCount` is the nvim run-length indicator: the same cell content applies
/// to `repeatCount` consecutive columns starting at the cell's position.
/// A value of 1 (the default) means no repetition.
public struct NvimCell: Sendable {
    /// The UTF-8 text to display. May be an empty string for wide-character
    /// continuation cells (nvim fills the second column of a wide char with "").
    public let text: String

    /// Highlight ID referencing an entry in the hl cache (hlAttrDefine).
    /// 0 means the default highlight (defaultColorsSet).
    public let hlId: Int

    /// Number of consecutive columns this cell occupies (nvim run-length).
    /// Minimum 1.
    public let repeatCount: Int
}

// MARK: - Highlight attributes

/// Resolved RGB highlight attributes for a single highlight ID.
///
/// Colours are 24-bit RGB packed as 0x00RRGGBB. `nil` means "inherit from
/// default" (the foreground or background from defaultColorsSet).
public struct HLAttrs: Sendable {
    public let fg: UInt32?
    public let bg: UInt32?
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let reverse: Bool
}

// MARK: - Redraw event

/// A single sub-event from a nvim `redraw` notification batch (ext_linegrid UI).
///
/// Only the subset required for P4 is represented. Unrecognised sub-events are
/// logged at `debug` and dropped by NvimRedrawHandler (Inc-4).
///
/// The full ext_linegrid protocol is documented at:
/// https://neovim.io/doc/user/ui.html#ui-linegrid
public enum NvimRedrawEvent: Sendable {

    /// A highlight attribute definition. The `id` is the integer key used in
    /// subsequent gridLine cells. `rgb` holds the resolved 24-bit RGB values
    /// and text attributes.
    case hlAttrDefine(id: Int, rgb: HLAttrs)

    /// The default terminal foreground/background/special colours (RGB).
    /// Sent at startup and whenever the colour scheme changes.
    case defaultColorsSet(fg: UInt32, bg: UInt32, sp: UInt32)

    /// The global grid (grid 1) has been resized to `width` × `height` columns
    /// and rows. NvimGridState.cells must be re-dimensioned to match.
    case gridResize(grid: Int, width: Int, height: Int)

    /// A horizontal run of cells on `grid` starting at (`row`, `colStart`).
    ///
    /// `cells` may contain run-length entries (NvimCell.repeatCount > 1).
    /// The row must be pre-sized to the grid width before applying colStart-
    /// relative writes — NvimRedrawHandler ensures this before dispatch.
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [NvimCell])

    /// Move the cursor to (`row`, `col`) on `grid`.
    case gridCursorGoto(grid: Int, row: Int, col: Int)

    /// Scroll a rectangular region of `grid` by `rows` lines.
    ///
    /// Positive `rows` scrolls content up (lines move toward lower row indices);
    /// negative scrolls down. The vacated rows are cleared.
    ///
    /// NvimRedrawHandler implements this as a reference-shift (O(1) row-slice
    /// re-index) rather than a cell-copy loop. See ARCHITECTURE.md §10.4.8.
    case gridScroll(grid: Int, top: Int, bot: Int, left: Int, right: Int, rows: Int)

    /// Clear all cells in `grid` to the default highlight.
    case gridClear(grid: Int)

    /// The editor mode changed. `name` is the mode string (e.g. "normal",
    /// "insert"); `modeIdx` is the index into the mode_info table.
    case modeChange(name: String, modeIdx: Int)

    /// End of a redraw batch. The renderer must flush to the terminal exactly
    /// once after a batch that ends with `.flush` (ARCHITECTURE.md §10.4.8
    /// flush invariant).
    case flush
}
