// File: Sources/MoonSwiftTUI/Render/CommandInterpreter.swift
// Location: MoonSwiftTUI/Render/
// Role: Translates a [RenderCommand] sequence into backend calls. The pure
//       interpretation logic (ordering, rect math, batching contract) lives here
//       and is shared between the production RatatuiKit backend and in-memory
//       recording fakes used by tests. No FFI is touched in this file.
//       (ARCHITECTURE.md §3b, §5.1; ux-spec.md §1.4)
// Upstream: RenderCommand.swift (command vocabulary)
// Downstream: RatatuiKitBackend.swift (production), RecordingRenderBackend.swift
//             (test double), AppDriver.swift (calls apply())

import Foundation
import RatatuiKit

// MARK: - RenderBackend

/// The interface that separates pure command interpretation from the actual
/// rendering surface.
///
/// Two implementations exist:
/// - `RatatuiKitBackend` — production; delegates to RatatuiKit FFI calls on the
///   UI (render/terminal-class) thread.
/// - `RecordingRenderBackend` — test double; records calls without touching
///   the FFI, allowing every interpreter branch to be exercised in unit tests.
///
/// The seam follows the same pattern as `TerminalSuspender` / `EventSource`.
///
/// Thread class: all methods must be called from the UI (render/terminal-class)
/// thread. Implementations that forward to RatatuiKit assert this at each site.
public protocol RenderBackend: AnyObject {

    // MARK: Frame lifecycle

    /// Begin a new frame: sets the default background colour and prepares the
    /// surface for widget and cell writes. Called once at the top of each frame.
    func beginFrame(size: TerminalSize, defaultStyle: CellStyle) throws

    /// Flush the completed frame to the physical terminal. Called once at the
    /// end of each frame, after all widget and cell writes.
    func flush() throws

    // MARK: Widget commands

    /// Render the full-width title bar row: left label plus right-aligned badges.
    func titleBar(rect: Rect, left: String, badges: [String], style: CellStyle) throws

    /// Render a navigator list with optional selection and block border.
    func navigatorList(
        rect: Rect,
        items: [Span],
        selectedIndex: Int?,
        title: [Span]
    ) throws

    /// Render a paragraph (code pane content, help text, error text).
    func paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?) throws

    /// Render the bottom-pane tab bar.
    func tabBar(rect: Rect, tabs: [String], selectedIndex: Int) throws

    /// Render a block border frame (border only, no inner content).
    func block(rect: Rect, config: BlockConfig, borderStyle: CellStyle) throws

    /// Clear a rectangular region to the terminal default background.
    func clear(rect: Rect) throws

    // MARK: Cell command (batching contract)

    /// Write a contiguous text run with a uniform style.
    ///
    /// The interpreter guarantees that one `cellRun` call maps to exactly one
    /// backend call — the batching contract from ARCHITECTURE.md §3b. The
    /// production backend forwards to `CellBuffer.write` accumulation, then
    /// `CellBuffer.flush(to:)` is called once per frame in `flush()`.
    func cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle) throws

    // MARK: Below-minimum-size

    /// Leave the alternate screen and print the ux-spec §1.4 resize prompt.
    ///
    /// Called when the terminal is below 80×24. The backend leaves alt screen
    /// and emits the literal string:
    /// `Terminal too small (WxH). Please resize to at least 80×24.`
    /// where W and H are the supplied dimensions.
    ///
    /// The counterpart `resumeAltScreen()` is called when the terminal regrows.
    func leaveAltScreenWithMessage(cols: UInt16, rows: UInt16) throws

    /// Re-enter the alternate screen after the terminal regrew to ≥ 80×24.
    ///
    /// A full redraw follows immediately: `apply(_:)` is called again with the
    /// normal frame commands. The backend re-enters raw mode + alt screen here.
    func resumeAltScreen() throws

    // MARK: Session teardown

    /// Restore the terminal and free any resources when the session ends.
    ///
    /// Called once by `AppDriver.teardown()` after the event loop exits. The
    /// production backend calls `Terminal.teardown()`; the recording fake is
    /// a no-op. After this call the backend is invalid; do not call other methods.
    func teardown() throws
}

// MARK: - CommandInterpreter

/// Translates an ordered [RenderCommand] sequence into `RenderBackend` calls.
///
/// One interpreter instance is held by the AppDriver for the lifetime of the
/// app session. The driver calls `apply(_:)` once per render frame.
///
/// The interpreter owns no mutable rendering state; it relies entirely on the
/// backend for surface management. The `CellBuffer` batching for `cellRun`
/// commands is managed by the `RatatuiKitBackend` (not here), preserving the
/// one-FFI-call-per-contiguous-same-style-run contract.
///
/// Below-minimum-size handling: if a `belowMinimumSize` command is the sole
/// content of a frame, the interpreter instructs the backend to leave the alt
/// screen. On the next normal frame the interpreter instructs the backend to
/// resume. This keeps lossless state: the reducer's AppState is unchanged, and
/// the next normal frame replays the full widget tree.
public final class CommandInterpreter {

    // MARK: Dependencies

    /// The rendering surface this interpreter drives. Exposed so that the
    /// AppDriver can call `backend.teardown()` after the event loop exits.
    let backend: any RenderBackend

    // MARK: State

    /// True while the terminal is below the minimum size. The next normal frame
    /// (no `belowMinimumSize` command) triggers a `resumeAltScreen()` call
    /// before dispatching widget commands.
    private var isBelowMinimum: Bool = false

    // MARK: Init

    /// Creates an interpreter that forwards commands to `backend`.
    ///
    /// - Parameter backend: The rendering surface to drive. Must be alive for
    ///   the entire session.
    public init(backend: any RenderBackend) {
        self.backend = backend
    }

    // MARK: Apply

    /// Interprets `commands` against the backend for one render frame.
    ///
    /// The command sequence must begin with `.beginFrame` for a normal frame,
    /// or contain exactly `.belowMinimumSize` for a degraded frame. Widget
    /// commands follow in any order; cell commands must be in row-major order
    /// (left-to-right, top-to-bottom) as guaranteed by the Renderer.
    ///
    /// Errors from individual backend calls are collected and the first error
    /// is re-thrown after attempting all commands so that a transient FFI
    /// failure does not silently drop subsequent commands in the frame.
    ///
    /// - Parameter commands: The frame's command list from `render(_:size:)`.
    /// - Throws: The first `FFIError` encountered during the frame, if any.
    public func apply(_ commands: [RenderCommand]) throws {
        // Determine whether this is a degraded frame (below minimum size).
        let hasBelowMinimum = commands.contains {
            if case .belowMinimumSize = $0 { return true }
            return false
        }

        if hasBelowMinimum {
            try applyBelowMinimum(commands)
        } else {
            try applyNormalFrame(commands)
        }
    }

    // MARK: - Normal frame

    private func applyNormalFrame(_ commands: [RenderCommand]) throws {
        // If we were below the minimum, instruct the backend to re-enter alt
        // screen before dispatching any widget commands for this frame.
        if isBelowMinimum {
            isBelowMinimum = false
            try backend.resumeAltScreen()
        }

        // Dispatch each command; accumulate the first error.
        var firstError: Error? = nil

        for command in commands {
            do {
                try dispatchNormal(command)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Flush the frame after all commands (also flushes accumulated cellRuns).
        do {
            try backend.flush()
        } catch {
            if firstError == nil { firstError = error }
        }

        if let err = firstError { throw err }
    }

    // MARK: - Below-minimum frame

    private func applyBelowMinimum(_ commands: [RenderCommand]) throws {
        // A repeated below-minimum does not call leaveAltScreen again.
        if isBelowMinimum { return }
        isBelowMinimum = true

        // Find the first belowMinimumSize command for the dimensions.
        for command in commands {
            if case .belowMinimumSize(let cols, let rows) = command {
                try backend.leaveAltScreenWithMessage(cols: cols, rows: rows)
                return
            }
        }
    }

    // MARK: - Per-command dispatch

    private func dispatchNormal(_ command: RenderCommand) throws {
        switch command {

        case .beginFrame(let size, let defaultStyle):
            try backend.beginFrame(size: size, defaultStyle: defaultStyle)

        case .titleBar(let rect, let left, let badges, let style):
            try backend.titleBar(rect: rect, left: left, badges: badges, style: style)

        case .navigatorList(let rect, let items, let selectedIndex, let title):
            try backend.navigatorList(
                rect: rect,
                items: items,
                selectedIndex: selectedIndex,
                title: title
            )

        case .paragraph(let rect, let lines, let block):
            try backend.paragraph(rect: rect, lines: lines, block: block)

        case .tabBar(let rect, let tabs, let selectedIndex):
            try backend.tabBar(rect: rect, tabs: tabs, selectedIndex: selectedIndex)

        case .block(let rect, let config, let borderStyle):
            try backend.block(rect: rect, config: config, borderStyle: borderStyle)

        case .clear(let rect):
            try backend.clear(rect: rect)

        case .cellRun(let col, let row, let text, let style):
            try backend.cellRun(col: col, row: row, text: text, style: style)

        case .belowMinimumSize:
            // belowMinimumSize is handled by applyBelowMinimum; it should not
            // appear in a normal frame. Treat as a no-op if it somehow arrives.
            break
        }
    }
}
