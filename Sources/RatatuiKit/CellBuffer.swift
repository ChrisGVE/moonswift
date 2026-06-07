// File: Sources/RatatuiKit/CellBuffer.swift
// Role: Batched cell-write API that enforces the FFI batching contract:
//       one FFI call per contiguous same-attribute run per row — never per
//       individual cell (ARCHITECTURE.md §3b). The batcher groups cell spans
//       sharing the same style and flushes each run as a single rffi_write_cells
//       call. A protocol seam (`CellWriter`) keeps the batching logic testable
//       without a real terminal.
// Upstream: CRatatuiFFI (rffi_write_cells, rffi_clear_rect, rffi_clear_rect_widget)
// Downstream: MoonSwiftTUI/Render/RenderCommand.swift (cell-write commands),
//             MoonSwiftTUI/Render/Renderer.swift (interprets RenderCommands)

import CRatatuiFFI

// MARK: - CellStyle

/// Style attributes for a cell run: foreground, background, and text modifiers.
///
/// Colour encoding: `0x00RRGGBB` for an RGB colour; `0xFFFFFFFF` for the
/// terminal's default (no explicit colour — this is the shim's convention,
/// matching `RffiStyle.fg/bg` defaults).
///
/// `mods` is a bitfield of `RffiStyleMods` constants: BOLD | ITALIC | UNDERLINE
/// etc. as defined in the generated header.
public struct CellStyle: Sendable, Equatable {
    /// Foreground colour: `0x00RRGGBB` or `0xFFFFFFFF` (terminal default).
    public let fg: UInt32
    /// Background colour: `0x00RRGGBB` or `0xFFFFFFFF` (terminal default).
    public let bg: UInt32
    /// Style modifier bitfield (BOLD, ITALIC, UNDERLINE, …).
    public let mods: UInt16

    public init(fg: UInt32 = 0xFFFFFFFF, bg: UInt32 = 0xFFFFFFFF, mods: UInt16 = 0) {
        self.fg = fg
        self.bg = bg
        self.mods = mods
    }

    /// Terminal-default style: no explicit colours, no modifiers.
    public static let `default` = CellStyle()
}

// MARK: - CellWriter (testability seam)

/// Abstraction over the raw `rffi_write_cells` and `rffi_clear_rect` calls.
///
/// Production code uses `FFICellWriter`, which calls the real shim.
/// Tests inject a `MockCellWriter` that records calls instead of hitting the FFI,
/// letting the batching logic be verified without a real terminal.
public protocol CellWriter: AnyObject {

    /// Write a contiguous text run with a uniform style, starting at
    /// (`col`, `row`) in cell coordinates.
    func writeCells(
        col: UInt16,
        row: UInt16,
        text: String,
        style: CellStyle
    ) throws

    /// Clear a rectangular region to the terminal default background.
    func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) throws
}

// MARK: - FFICellWriter

/// Production `CellWriter` that forwards directly to CRatatuiFFI.
///
/// Package-internal: `CellBuffer` creates one by default; tests inject a mock.
final class FFICellWriter: CellWriter {

    private let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    func writeCells(
        col: UInt16,
        row: UInt16,
        text: String,
        style: CellStyle
    ) throws {
        let bold: UInt8      = style.mods & UInt16(BOLD)      != 0 ? 1 : 0
        let italic: UInt8    = style.mods & UInt16(ITALIC)    != 0 ? 1 : 0
        let underline: UInt8 = style.mods & UInt16(UNDERLINE) != 0 ? 1 : 0

        try text.withCString { ptr in
            try checkFFI(rffi_write_cells(
                handle,
                col, row,
                ptr, strlen(ptr),
                style.fg, style.bg,
                bold, italic, underline
            ))
        }
    }

    func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) throws {
        try checkFFI(rffi_clear_rect(handle, col, row, width, height))
    }
}

// MARK: - CellRun

/// A contiguous sequence of grapheme clusters sharing the same `CellStyle`,
/// all on the same row, starting at column `col`.
///
/// The batcher accumulates `CellRun`s as it scans input cells left-to-right
/// on each row, flushing a run whenever the style changes or the row ends.
struct CellRun {
    let col: UInt16
    let row: UInt16
    var text: String        // UTF-8 grapheme clusters appended in order
    let style: CellStyle

    init(col: UInt16, row: UInt16, firstChar: Character, style: CellStyle) {
        self.col = col
        self.row = row
        self.text = String(firstChar)
        self.style = style
    }

    mutating func append(_ char: Character) {
        text.append(char)
    }
}

// MARK: - CellBuffer

/// Accepts cell-level write commands and batches them into the minimum number
/// of FFI calls required by the ARCHITECTURE.md §3b contract.
///
/// **Batching contract:** one `CellWriter.writeCells` call per contiguous
/// same-`CellStyle` run per row. At 200×60 (12 000 cells) the ceiling is
/// ~1 500 calls (60 rows × ≤ 25 style runs worst case); a per-cell design
/// would produce 12 000 calls and is forbidden.
///
/// **Usage pattern:**
/// 1. Call `write(col:row:char:style:)` for each cell (from the Renderer).
/// 2. Call `flush(to:)` once per frame to dispatch all accumulated runs.
///
/// Thread class: render/terminal-class — the Renderer runs on the UI thread.
public final class CellBuffer {

    // Accumulated runs, keyed by (row, run-start-col) in insertion order.
    // Stored as an ordered array of `CellRun`; we never need random access by
    // key — only sequential append + a full pass on flush.
    private var runs: [CellRun] = []
    private var currentRun: CellRun?

    /// The last column where a cell was written (for contiguity detection).
    private var lastCol: UInt16 = 0
    /// The last row where a cell was written (for row-change detection).
    private var lastRow: UInt16 = 0

    public init() {}

    // MARK: - Accumulate

    /// Accumulates a single cell into the current batch.
    ///
    /// Cells must be written in row-major order (left to right within a row,
    /// top to bottom across rows). A new run starts whenever:
    ///   - the style changes from the preceding cell, or
    ///   - the column is not exactly `lastCol + 1` (gap in the run), or
    ///   - the row changes.
    ///
    /// - Parameters:
    ///   - col: 0-based column.
    ///   - row: 0-based row.
    ///   - char: The grapheme cluster to place at this cell.
    ///   - style: The cell's style attributes.
    public func write(col: UInt16, row: UInt16, char: Character, style: CellStyle) {
        let contiguous = currentRun != nil
            && row == lastRow
            && col == lastCol &+ 1
            && currentRun!.style == style

        if contiguous {
            currentRun!.append(char)
        } else {
            flushCurrentRun()
            currentRun = CellRun(col: col, row: row, firstChar: char, style: style)
        }
        lastCol = col
        lastRow = row
    }

    // MARK: - Flush

    /// Dispatches all accumulated runs to `writer`, then resets the buffer.
    ///
    /// Call once per render frame, after all `write(...)` calls for that frame.
    ///
    /// - Parameter writer: The `CellWriter` that forwards calls to the shim
    ///   (production) or records them for test assertion (mock).
    /// - Throws: `FFIError` if any shim call fails.
    public func flush(to writer: CellWriter) throws {
        flushCurrentRun()
        for run in runs {
            try writer.writeCells(
                col: run.col,
                row: run.row,
                text: run.text,
                style: run.style
            )
        }
        runs.removeAll(keepingCapacity: true)
    }

    /// Clears a rectangular region via `writer`, then resets the buffer.
    ///
    /// - Throws: `FFIError` if the shim call fails.
    public func clearRect(
        col: UInt16, row: UInt16,
        width: UInt16, height: UInt16,
        writer: CellWriter
    ) throws {
        try writer.clearRect(col: col, row: row, width: width, height: height)
    }

    // MARK: - Private

    private func flushCurrentRun() {
        if let run = currentRun {
            runs.append(run)
            currentRun = nil
        }
    }
}

// MARK: - CellGrid (in-memory backend for snapshot testing)

/// An in-memory terminal surface: a 2-D grid of (character, style) cells.
///
/// The Renderer's snapshot tests write into a `CellGrid` via a `CellGridWriter`
/// (which conforms to `CellWriter`) instead of a real terminal, allowing
/// exact cell-level assertion without any FFI. A `CellGrid` implements
/// `CellWriter` directly so it can be used as a drop-in writer.
///
/// Row-major storage: `cells[row][col]`.
public final class CellGrid: CellWriter {

    // MARK: - Cell

    /// A single cell in the grid.
    public struct Cell: Sendable, Equatable {
        public var char: Character
        public var style: CellStyle

        public init(char: Character = " ", style: CellStyle = .default) {
            self.char = char
            self.style = style
        }
    }

    // MARK: - Properties

    public let cols: Int
    public let rows: Int

    /// Row-major cell storage: `cells[row][col]`.
    private(set) public var cells: [[Cell]]

    // MARK: - Init

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.cells = Array(
            repeating: Array(repeating: Cell(), count: cols),
            count: rows
        )
    }

    // MARK: - CellWriter

    /// Writes a text run into the grid starting at (`col`, `row`).
    ///
    /// Each Unicode scalar is treated as one cell. Runs that extend past the
    /// grid edge are silently clipped.
    public func writeCells(
        col: UInt16,
        row: UInt16,
        text: String,
        style: CellStyle
    ) throws {
        let r = Int(row)
        guard r < rows else { return }
        var c = Int(col)
        for ch in text {
            guard c < cols else { break }
            cells[r][c] = Cell(char: ch, style: style)
            c += 1
        }
    }

    /// Fills a rectangular region with blank cells at the default style.
    public func clearRect(col: UInt16, row: UInt16, width: UInt16, height: UInt16) throws {
        let blank = Cell()
        for r in Int(row) ..< min(Int(row) + Int(height), rows) {
            for c in Int(col) ..< min(Int(col) + Int(width), cols) {
                cells[r][c] = blank
            }
        }
    }

    // MARK: - Helpers

    /// Returns the text content of a single row as a `String`.
    public func rowText(_ row: Int) -> String {
        guard row < rows else { return "" }
        return String(cells[row].map { $0.char })
    }
}
