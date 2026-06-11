// File: Sources/MoonSwiftTUI/Nvim/NvimGridState.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Value types for the nvim editing subsystem that live at the AppState
//       boundary — NvimGridState (the rendered cell grid), NvimSession (the
//       live session references), and the modal/pane states required by P4.
//       These are pure data; no I/O or side effects.
//
// Architecture context (ARCHITECTURE.md §10.4.3, §10.4.4, §10.4.6, §10.4.8):
//   NvimGridState is top-level in AppState because the renderer reads it
//   independently of FocusState. NvimPaneState lives inside
//   FocusState.nvimPane(…) — only valid while the pane is active.
//   NvimSession is Sendable: supervisor is @unchecked Sendable (set-once
//   model), NvimRPCClient is an actor (Sendable by definition).
//   ConflictModalState and DiffViewState are Sendable/Equatable value types
//   moved here to stay within the 400-line budget for AppState.swift.
//
// Relationships:
//   → AppState.swift     (Inc-4): holds NvimGridState?, ConflictModalState?,
//                                  DiffViewState?, nvimFallbackNotedThisSession
//   → AppEvent.swift     (Inc-4): AppEvent.nvimReady(NvimSession) payload
//   → NvimRedrawHandler  (Inc-4): produces NvimGridState updates
//   → Reducer.swift      (Inc-4): applies NvimRedrawEvent batches to nvimGrid

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - NvimCellState

/// A single rendered cell in the nvim grid.
///
/// `text` is the UTF-8 character at this cell (empty string for wide-character
/// continuation columns). `hlId` references an entry in `NvimGridState.hlCache`
/// (0 = default highlight from `defaultColorsSet`).
public struct NvimCellState: Sendable, Equatable {
    public var text: String
    public var hlId: Int

    public init(text: String = " ", hlId: Int = 0) {
        self.text = text
        self.hlId = hlId
    }
}

// MARK: - NvimGridState

/// The current rendered state of the nvim cell grid.
///
/// Updated by the reducer on every `.nvimRedrawBatch` event.
/// `Sendable` because all fields are value types. `Equatable` to allow
/// snapshot-based testing of the reducer.
///
/// Flush invariant: AppDriver only renders this after a batch whose last event
/// was `.flush` (ARCHITECTURE.md §10.4.8). Partial batches are never visible
/// through AppState — the reducer accumulates them before posting.
public struct NvimGridState: Sendable, Equatable {
    /// Grid width in columns. Updated by `gridResize`.
    public var width: Int
    /// Grid height in rows. Updated by `gridResize`.
    public var height: Int
    /// Cell contents indexed [row][col]. Each row is pre-sized to `width`.
    public var cells: [[NvimCellState]]
    /// Current cursor position (0-based row).
    public var cursorRow: Int
    /// Current cursor position (0-based column).
    public var cursorCol: Int
    /// Highlight attribute cache: hlId → resolved RGB+style attributes.
    public var hlCache: [Int: HLAttrs]

    // MARK: Init

    /// Create a blank grid of the given dimensions.
    public init(width: Int = 0, height: Int = 0) {
        self.width = width
        self.height = height
        self.cells = Array(
            repeating: Array(repeating: NvimCellState(), count: max(width, 0)),
            count: max(height, 0)
        )
        self.cursorRow = 0
        self.cursorCol = 0
        self.hlCache = [:]
    }

    // MARK: Resize

    /// Resize the grid to `newWidth` × `newHeight`, preserving existing cell
    /// content where it fits. New rows/columns are filled with blank cells.
    public mutating func resize(width newWidth: Int, height newHeight: Int) {
        let blank = NvimCellState()
        // Adjust existing rows to the new width.
        for i in 0..<cells.count {
            if cells[i].count < newWidth {
                cells[i].append(contentsOf: Array(repeating: blank, count: newWidth - cells[i].count))
            } else if cells[i].count > newWidth {
                cells[i].removeLast(cells[i].count - newWidth)
            }
        }
        // Add or remove rows.
        if cells.count < newHeight {
            let newRow = Array(repeating: blank, count: newWidth)
            cells.append(contentsOf: Array(repeating: newRow, count: newHeight - cells.count))
        } else if cells.count > newHeight {
            cells.removeLast(cells.count - newHeight)
        }
        width = newWidth
        height = newHeight
    }

    // MARK: Clear

    /// Clear all cells to blank (default highlight, space character).
    public mutating func clearAll() {
        let blank = NvimCellState()
        for row in 0..<cells.count {
            for col in 0..<cells[row].count {
                cells[row][col] = blank
            }
        }
    }

    // MARK: Apply grid_line

    /// Apply a `gridLine` event: write `cells` starting at (`row`, `colStart`),
    /// expanding run-length entries and carrying `hlId` forward when omitted.
    ///
    /// The row is pre-sized to `width` by the caller (NvimRedrawHandler) before
    /// this is called, so out-of-bounds writes are impossible.
    public mutating func applyGridLine(row: Int, colStart: Int, cells eventCells: [NvimCell]) {
        guard row >= 0, row < cells.count else { return }
        var col = colStart
        var lastHlId = 0
        for cell in eventCells {
            // nvim ext_linegrid protocol (https://neovim.io/doc/user/ui.html#ui-linegrid):
            // within a grid_line event, `hlId == 0` means "same highlight as the
            // previous cell in this run" (carry semantics), NOT "default highlight".
            // A real hlId of 0 (default palette entry) is only sent explicitly on
            // the first cell or when the highlight changes back to the default; nvim
            // never sends 0 to mean "same as previous" for the default id itself.
            // We therefore carry `lastHlId` forward whenever `cell.hlId == 0`.
            let hlId = cell.hlId
            if hlId != 0 { lastHlId = hlId }
            let effectiveHlId = (hlId != 0) ? hlId : lastHlId
            let repeatN = max(1, cell.repeatCount)
            for _ in 0..<repeatN {
                guard col < cells[row].count else { break }
                cells[row][col] = NvimCellState(text: cell.text, hlId: effectiveHlId)
                col += 1
            }
        }
    }

    // MARK: Apply grid_scroll

    /// Apply a `gridScroll` event by copying cells within the scroll region.
    ///
    /// Iterates over each row in the scroll range and copies columns
    /// `left..<right` from the source row to the destination row, then blanks
    /// the vacated rows. Time complexity is O((bot-top) × (right-left)) — a
    /// cell-by-cell copy, not a reference shift. This matches the nvim
    /// ext_linegrid scroll semantics documented at
    /// https://neovim.io/doc/user/ui.html#ui-linegrid .
    ///
    /// Positive `rows` scrolls content up (rows move toward lower indices).
    /// Negative `rows` scrolls down (rows move toward higher indices).
    /// The vacated rows are reset to blank cells. Only the `top…bot` row range
    /// and `left…right` column range are affected; the rest is untouched.
    public mutating func applyScroll(top: Int, bot: Int, left: Int, right: Int, rows: Int) {
        guard rows != 0 else { return }
        let blank = NvimCellState()

        if rows > 0 {
            // Scroll up: move row[src] → row[dst] where dst = src - rows.
            for dst in top..<(bot - rows) {
                let src = dst + rows
                guard src < cells.count, dst < cells.count else { continue }
                for col in left..<right {
                    guard col < cells[dst].count, col < cells[src].count else { continue }
                    cells[dst][col] = cells[src][col]
                }
            }
            // Clear vacated rows at the bottom of the scroll region.
            for row in max(top, bot - rows)..<bot {
                guard row < cells.count else { continue }
                for col in left..<right {
                    guard col < cells[row].count else { continue }
                    cells[row][col] = blank
                }
            }
        } else {
            // Scroll down: move row[src] → row[dst] where dst = src - rows (rows < 0).
            let shift = -rows
            for dst in stride(from: bot - 1, through: top + shift, by: -1) {
                let src = dst - shift
                guard src >= 0, src < cells.count, dst < cells.count else { continue }
                for col in left..<right {
                    guard col < cells[dst].count, col < cells[src].count else { continue }
                    cells[dst][col] = cells[src][col]
                }
            }
            // Clear vacated rows at the top of the scroll region.
            for row in top..<(top + shift) {
                guard row < cells.count else { continue }
                for col in left..<right {
                    guard col < cells[row].count else { continue }
                    cells[row][col] = blank
                }
            }
        }
    }
}

// MARK: - NvimSession

/// Carries the live nvim session references. Sendable: supervisor is
/// `@unchecked Sendable` (set-once model documented in NvimProcessSupervisor);
/// `NvimRPCClient` is an `actor`, which is `Sendable` by definition.
///
/// `NvimSession` is owned by the AppDriver as `AppDriver.nvimSession?`.
/// The reducer receives it via `AppEvent.nvimReady(NvimSession)` and stores a
/// copy in `AppState` only if it needs to expose session identity to the
/// renderer (it does not in P4 — the driver holds the authoritative copy).
public struct NvimSession: Sendable {
    public let supervisor: NvimProcessSupervisor
    public let rpc: NvimRPCClient

    public init(supervisor: NvimProcessSupervisor, rpc: NvimRPCClient) {
        self.supervisor = supervisor
        self.rpc = rpc
    }
}

// MARK: - NvimPaneState

/// Per-session nvim pane state, valid only while `FocusState.nvimPane` is active.
///
/// Lives inside `FocusState.nvimPane(…)` rather than as a top-level optional
/// in `AppState` because it has no meaning outside the nvim-pane focus.
public struct NvimPaneState: Sendable, Equatable {
    /// The rect this session was attached with (passed to nvim_ui_attach).
    public var attachedRect: Rect
    /// Current nvim mode string (e.g. "normal", "insert").
    public var mode: String
    /// Whether the nvim buffer has unsaved changes.
    public var modified: Bool

    public init(attachedRect: Rect, mode: String = "normal", modified: Bool = false) {
        self.attachedRect = attachedRect
        self.mode = mode
        self.modified = modified
    }
}

// MARK: - ConflictModalState

/// State for the conflict-resolution modal shown when the on-disk file has
/// changed since the fragment was loaded.
///
/// Stores only what is needed to trigger resolution at [o]/[d] decision time —
/// not the full file data (AppState must not carry up to 50 MiB of file bytes).
public struct ConflictModalState: Sendable, Equatable {
    /// The file to re-read at decision time.
    public let fileURL: URL
    /// SHA-256 hash of the fragment's host file captured at load time.
    ///
    /// Stored as `SHA256Digest` (32 bytes) rather than the full file bytes
    /// so AppState never carries up to 50 MiB of file content in memory. At
    /// conflict-resolution time the file is re-read and its hash is compared
    /// against this value to detect a second on-disk change since the modal
    /// was shown (ARCHITECTURE.md §10.4.9).
    public let expectedHash: SHA256Digest
    /// The edited buffer content the user wants to preserve.
    public let editedText: String
    /// Provenance for re-location (format, jsonpath, document).
    public let fragment: LuaSourceFragment

    public init(
        fileURL: URL,
        expectedHash: SHA256Digest,
        editedText: String,
        fragment: LuaSourceFragment
    ) {
        self.fileURL = fileURL
        self.expectedHash = expectedHash
        self.editedText = editedText
        self.fragment = fragment
    }
}

// MARK: - DiffViewState / DiffViewPhase

/// The phase of the diff view build.
public enum DiffViewPhase: Sendable, Equatable {
    /// Spinner shown while the off-thread Task builds the diff.
    case building
    /// Diff is ready to display.
    case ready(DiffViewState)
}

/// State for the side-by-side diff view (ARCHITECTURE.md §10.4.10).
public struct DiffViewState: Sendable, Equatable {
    /// Left column header, e.g. "On disk (config.yaml:$.scripts.init)".
    public let leftTitle: String
    /// Right column header, e.g. "Edited".
    public let rightTitle: String
    /// Fresh on-disk lines extracted via SpanLocator.
    public let leftLines: [String]
    /// Edited-buffer lines.
    public let rightLines: [String]
    /// Current scroll offset in the diff view.
    public var scrollOffset: Int

    public init(
        leftTitle: String,
        rightTitle: String,
        leftLines: [String],
        rightLines: [String],
        scrollOffset: Int = 0
    ) {
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.leftLines = leftLines
        self.rightLines = rightLines
        self.scrollOffset = scrollOffset
    }
}
