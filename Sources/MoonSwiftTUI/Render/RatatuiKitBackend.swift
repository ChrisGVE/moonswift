// File: Sources/MoonSwiftTUI/Render/RatatuiKitBackend.swift
// Location: MoonSwiftTUI/Render/
// Role: Production RenderBackend that delegates every call 1:1 to RatatuiKit
//       (Terminal lifecycle, widget wrappers, CellBuffer batched drawing).
//       All methods must be called from the UI (render/terminal-class) thread;
//       debug builds assert this via RatatuiKit's assertRenderClass helper.
//       The only mutable state it holds is the CellBuffer accumulator — reset
//       on each flush().
//       (ARCHITECTURE.md §3b, §5.2; ux-spec.md §1.4)
// Upstream: RatatuiKit (Terminal, ListWidget, ParagraphWidget, TabsWidget,
//           clearWidget, CellBuffer, CellStyle, Rect, BlockConfig, Span)
// Downstream: CommandInterpreter (calls this as a RenderBackend)

import Darwin
import Foundation
import RatatuiKit

// MARK: - RatatuiKitBackend

/// Production `RenderBackend` that forwards rendering commands to the FFI shim
/// via the RatatuiKit overlay.
///
/// **Thread class:** every method is render/terminal-class — the AppDriver calls
/// them from the UI thread inside `renderNow()`. In debug builds each method
/// asserts the calling thread via `assertRenderClass`.
///
/// **CellBuffer contract:** `cellRun` accumulates into a `CellBuffer`; `flush()`
/// calls `CellBuffer.flush(to:)` once per frame, producing exactly one FFI call
/// per contiguous same-`CellStyle` run (ARCHITECTURE.md §3b). The buffer is
/// never flushed mid-frame.
///
/// **Below-minimum-size:** `leaveAltScreenWithMessage` prints the ux-spec §1.4
/// literal to stdout and calls `Terminal.teardown()` to leave the alt screen.
/// `resumeAltScreen()` calls `Terminal.init()` to re-enter raw mode + alt screen
/// (re-using the stored terminal handle slot). The AppDriver drives this via the
/// `CommandInterpreter`'s `isBelowMinimum` flag.
///
/// **TTY-gated:** this class holds a live `Terminal` handle. It cannot be
/// instantiated in a headless test environment (the FFI will fail or corrupt the
/// terminal). Tests inject `RecordingRenderBackend` instead. The guard is
/// structural — tests never link `CRatatuiFFI` directly (see Package.swift
/// `MoonSwiftTUITests` target dependencies).
public final class RatatuiKitBackend: RenderBackend {

    // MARK: Terminal handle

    /// The live terminal handle. Held for the full session; re-created after a
    /// below-minimum resume (see `resumeAltScreen`).
    private var terminal: Terminal

    // MARK: Cell accumulator

    /// Accumulates `cellRun` commands within a frame; flushed once in `flush()`.
    private let cellBuffer = CellBuffer()

    // MARK: Init

    /// Wraps an already-initialized `Terminal`.
    ///
    /// The caller (AppDriver) owns the `Terminal` lifecycle and must not call
    /// `Terminal.teardown()` independently once this backend is active — the
    /// backend calls teardown during `leaveAltScreenWithMessage` and teardown()
    /// when the session ends.
    ///
    /// - Parameter terminal: An active terminal session from `Terminal.init()`.
    public init(terminal: Terminal) {
        self.terminal = terminal
    }

    // MARK: - RenderBackend

    // MARK: Frame lifecycle

    public func beginFrame(size: TerminalSize, defaultStyle: CellStyle) throws {
        // beginFrame has no dedicated FFI entry point — the clear below fills
        // the role of "reset the frame buffer". Widgets draw on top of it.
        // A full-screen clear with the default background is the idiomatic
        // ratatui frame start.
        let fullRect = Rect(x: 0, y: 0, width: size.cols, height: size.rows)
        try clearWidget(handle: terminal.rawHandle, rect: fullRect)
    }

    public func flush() throws {
        // Flush accumulated cellRuns to the FFI shim (one call per contiguous
        // same-style run — ARCHITECTURE.md §3b). Terminal.flushCells constructs
        // the FFICellWriter internally so the raw handle stays encapsulated.
        try terminal.flushCells(cellBuffer)
        // Commit the completed frame to the physical terminal.
        try terminal.flush()
    }

    // MARK: Widget commands

    public func titleBar(rect: Rect, left: String, badges: [String], style: CellStyle) throws {
        // The title bar is a one-row paragraph: left label and right-aligned
        // badges on the same line, separated by spaces.
        // Compose the single display line from the label and elided badges.
        let line = composeTitleBarLine(
            rect: rect, left: left, badges: badges, style: style)
        let widget = try ParagraphWidget()
        try widget.appendLine(spans: line)
        try widget.setStyle(style)
        try widget.draw(handle: terminal.rawHandle, rect: rect)
    }

    public func navigatorList(
        rect: Rect,
        items: [Span],
        selectedIndex: Int?,
        title: [Span]
    ) throws {
        let widget = try ListWidget()
        for item in items {
            try widget.appendItem(spans: [item])
        }
        if let idx = selectedIndex {
            try widget.setSelected(Int32(idx))
        } else {
            try widget.setSelected(-1)
        }
        let blockConfig = BlockConfig(
            borders: .all,
            borderType: .rounded,
            titleSpans: title
        )
        try widget.setBlock(blockConfig)
        try widget.draw(handle: terminal.rawHandle, rect: rect)
    }

    public func paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?) throws {
        let widget = try ParagraphWidget()
        for lineSpans in lines {
            if lineSpans.isEmpty {
                try widget.lineBreak()
            } else {
                try widget.appendLine(spans: lineSpans)
            }
        }
        if let config = block {
            try widget.setBlock(config)
        }
        try widget.draw(handle: terminal.rawHandle, rect: rect)
    }

    public func tabBar(rect: Rect, tabs: [String], selectedIndex: Int) throws {
        let widget = try TabsWidget()
        for title in tabs {
            try widget.appendTitle(title)
        }
        try widget.setSelected(UInt16(selectedIndex))
        try widget.draw(handle: terminal.rawHandle, rect: rect)
    }

    public func block(rect: Rect, config: BlockConfig, borderStyle: CellStyle) throws {
        // A block with no content — border only. We render a paragraph with
        // no text but with the block decoration attached, using the borderStyle
        // for the overall widget style (which ratatui applies to border lines).
        let widget = try ParagraphWidget()
        try widget.setBlock(config)
        try widget.setStyle(borderStyle)
        try widget.draw(handle: terminal.rawHandle, rect: rect)
    }

    public func clear(rect: Rect) throws {
        try clearWidget(handle: terminal.rawHandle, rect: rect)
    }

    // MARK: Cell command

    public func cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle) throws {
        // Accumulate into the CellBuffer — no FFI call here. The buffer batches
        // contiguous same-style runs; flush() issues the actual FFI calls.
        // Each character advances the column by one cell position.
        var c = col
        for char in text {
            cellBuffer.write(col: c, row: row, char: char, style: style)
            c = c &+ 1
        }
    }

    // MARK: Below-minimum-size

    public func leaveAltScreenWithMessage(cols: UInt16, rows: UInt16) throws {
        // Leave alt screen so the prompt appears on the normal terminal surface.
        try terminal.teardown()
        // Emit the ux-spec §1.4 literal — W and H are the actual dimensions.
        let prompt = "Terminal too small (\(cols)x\(rows)). Please resize to at least 80×24."
        print(prompt)
    }

    public func resumeAltScreen() throws {
        // Re-enter raw mode and alternate screen.
        terminal = try Terminal()
    }

    // MARK: Session teardown

    public func teardown() throws {
        // Restore the terminal: leave alt screen, show cursor, restore termios.
        // Main.swift must NOT call Terminal.teardown() independently when this
        // backend is active — the backend owns teardown from construction onward.
        try terminal.teardown()
    }

    // MARK: - Private helpers

    /// Builds the title-bar display line: left label then right-aligned badges,
    /// eliding badges right-to-left when they do not fit (ux-spec §1.6).
    ///
    /// Returns a span array for a single ParagraphWidget line.
    private func composeTitleBarLine(
        rect: Rect,
        left: String,
        badges: [String],
        style: CellStyle
    ) -> [Span] {
        let availableWidth = Int(rect.width)
        guard availableWidth > 0 else { return [Span(left, style: style)] }

        // Build the badge suffix from right to left, eliding when too wide.
        var badgeParts: [String] = []
        var badgeWidth = 0
        for badge in badges.reversed() {
            let needed = badge.count + (badgeWidth > 0 ? 1 : 0)  // space separator
            if left.count + badgeWidth + needed <= availableWidth {
                badgeParts.insert(badge, at: 0)
                badgeWidth += needed
            }
        }

        if badgeParts.isEmpty {
            return [Span(left, style: style)]
        }

        let badgeSuffix = badgeParts.joined(separator: " ")
        let gapCount = availableWidth - left.count - badgeSuffix.count
        let gap = gapCount > 0 ? String(repeating: " ", count: gapCount) : " "
        return [
            Span(left, style: style),
            Span(gap, style: style),
            Span(badgeSuffix, style: style),
        ]
    }
}
