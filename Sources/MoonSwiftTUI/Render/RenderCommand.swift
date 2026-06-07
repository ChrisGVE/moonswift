// File: Sources/MoonSwiftTUI/Render/RenderCommand.swift
// Location: MoonSwiftTUI/Render/
// Role: Defines the RenderCommand vocabulary — the pure output of Renderer.render
//       and the input to RatatuiKit's production interpreter. This type is the
//       snapshot-test seam: the test renderer writes commands into a CellGrid;
//       the production interpreter issues the same commands to the FFI shim.
//       (ARCHITECTURE.md §5.1, §3b)
// Upstream: AppState (LayoutRegion), RatatuiKit (Rect, CellStyle, BlockConfig,
//           Span, BorderType, BorderBits)
// Downstream: AppDriver.swift (interprets commands → RatatuiKit calls),
//             MoonSwiftTUITests (snapshot assertions against CellGrid)

import Foundation
import RatatuiKit

// MARK: - LayoutRegion

/// Named screen regions produced by the layout calculation.
///
/// The Renderer computes one `LayoutRegion` per frame from `AppState.paneLayout`
/// and the terminal size. All RenderCommand rects are expressed in absolute
/// terminal coordinates derived from these regions.
public struct LayoutRegion: Sendable, Equatable {
    /// Full terminal area.
    public let screen: Rect
    /// Title bar: row 0, full width.
    public let titleBar: Rect
    /// Upper zone: navigator + code pane together.
    public let upperZone: Rect
    /// Navigator pane within the upper zone.
    public let navigator: Rect
    /// Code pane within the upper zone.
    public let codePane: Rect
    /// Bottom pane (tabs + content).
    public let bottomPane: Rect
    /// Status bar: bottom row, full width.
    public let statusBar: Rect

    // swift-format-ignore
    public init(
        screen: Rect,
        titleBar: Rect,
        upperZone: Rect,
        navigator: Rect,
        codePane: Rect,
        bottomPane: Rect,
        statusBar: Rect
    ) {
        self.screen = screen
        self.titleBar = titleBar
        self.upperZone = upperZone
        self.navigator = navigator
        self.codePane = codePane
        self.bottomPane = bottomPane
        self.statusBar = statusBar
    }
}

// MARK: - RenderCommand

/// A single rendering instruction produced by the pure Renderer.
///
/// The command vocabulary covers two layers:
///   - **Widget commands** — high-level ratatui widgets (List, Paragraph, Tabs,
///     Block, Clear) that the production interpreter forwards to `RatatuiKit`.
///   - **Cell commands** — batched cell-level writes for the code pane gutter,
///     syntax highlight spans, and status-bar text that needs fine-grained
///     styling control (ARCHITECTURE.md §3b).
///
/// The test renderer interprets these commands against an in-memory `CellGrid`
/// (from RatatuiKit); the production interpreter issues the identical sequence
/// to the FFI shim — one code path, two backends.
public enum RenderCommand: Sendable {

    // MARK: Widget commands

    /// Render the full-width title bar row.
    ///
    /// `left`: app name / project name text. `badges`: right-aligned badge
    /// strings (e.g. `[unrestricted]`), rendered right-to-left eliding if
    /// there is not enough space.
    case titleBar(rect: Rect, left: String, badges: [String], style: CellStyle)

    /// Render a navigator list widget into `rect`.
    ///
    /// `items` are pre-formatted display strings; `selectedIndex` marks the
    /// highlighted row; `title` is the block title (if any).
    case navigatorList(rect: Rect, items: [Span], selectedIndex: Int?, title: [Span])

    /// Render a paragraph widget (code pane content, help text, error text)
    /// into `rect`.
    case paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?)

    /// Render the bottom pane tab bar widget into `rect`.
    ///
    /// `tabs` are tab titles; `selectedIndex` is the active tab.
    case tabBar(rect: Rect, tabs: [String], selectedIndex: Int)

    /// Render a bordered block frame (border only, no inner content) into `rect`.
    ///
    /// `borderStyle` sets the color of the border lines — used to express the
    /// focused (`focus_border` token) vs. unfocused (`border` token) state
    /// without modifying `BlockConfig` (ux-spec §1.5).
    case block(rect: Rect, config: BlockConfig, borderStyle: CellStyle)

    /// Clear a rectangular region to the terminal default background.
    case clear(rect: Rect)

    // MARK: Cell commands (batched, one per same-style run)

    /// Write a contiguous text run with a uniform style into the cell buffer.
    ///
    /// Calls must be issued in row-major order (left-to-right, top-to-bottom).
    /// The `AppDriver` accumulates these into a `CellBuffer` and flushes once
    /// per frame (ARCHITECTURE.md §3b FFI batching contract).
    case cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle)

    // MARK: Meta command

    /// Begin a new frame: clear the screen and set the default background.
    ///
    /// Issued first in every frame's command sequence.
    case beginFrame(size: TerminalSize, defaultStyle: CellStyle)

    /// A size below the supported minimum (80 × 24): leave the alternate screen
    /// and show the resize prompt on the raw terminal.
    ///
    /// When the terminal regrows to or above 80 × 24, the driver re-enters
    /// the alternate screen and resumes rendering (lossless — no state is lost).
    case belowMinimumSize(cols: UInt16, rows: UInt16)
}
