// File: Sources/MoonSwiftTUI/Render/RecordingRenderBackend.swift
// Location: MoonSwiftTUI/Render/
// Role: Test double for RenderBackend. Records every call in the order it
//       was received so tests can assert command ordering, batching contract,
//       and below-minimum-size behavior without touching the FFI shim.
//       Follows the same pattern as RecordingTerminalSuspender (TerminalSuspender.swift).
//       (ARCHITECTURE.md §5.1; ux-spec.md §1.4)
// Upstream: RenderBackend (protocol)
// Downstream: CommandInterpreterTests (injected via CommandInterpreter init)

import Foundation
import RatatuiKit

// MARK: - RecordingRenderBackend

/// A `RenderBackend` that records every call as a `BackendCall` value.
///
/// Use this in tests to verify:
/// - that every `RenderCommand` case dispatches to the expected backend method,
/// - that the batching contract holds (N `cellRun` commands → N `cellRun` calls),
/// - that `belowMinimumSize` causes `leaveAltScreenWithMessage` without any
///   widget calls, and
/// - that a subsequent normal frame causes `resumeAltScreen` before widgets.
///
/// Configurable failure: set `errorOnCall` to a `BackendCallKind` to have the
/// backend throw a `RecordingError` when that method is invoked. Useful for
/// testing the interpreter's first-error-wins accumulation behavior.
public final class RecordingRenderBackend: RenderBackend {

    // MARK: - Recorded call

    /// One recorded invocation of a backend method.
    public enum BackendCall: Equatable {
        case beginFrame(size: TerminalSize, defaultStyle: CellStyle)
        case flush
        case titleBar(rect: Rect, left: String, badges: [String], style: CellStyle)
        case navigatorList(rect: Rect, items: [Span], selectedIndex: Int?, title: [Span])
        case paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?)
        case tabBar(rect: Rect, tabs: [String], selectedIndex: Int)
        case block(rect: Rect, config: BlockConfig, borderStyle: CellStyle)
        case clear(rect: Rect)
        case cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle)
        case leaveAltScreenWithMessage(cols: UInt16, rows: UInt16)
        case resumeAltScreen
    }

    /// The kind discriminant used by `errorOnCall` (without associated values).
    public enum BackendCallKind {
        case beginFrame
        case flush
        case titleBar
        case navigatorList
        case paragraph
        case tabBar
        case block
        case clear
        case cellRun
        case leaveAltScreenWithMessage
        case resumeAltScreen
    }

    // MARK: - State

    /// All calls received, in order.
    public private(set) var calls: [BackendCall] = []

    /// When non-nil, the named method throws `RecordingError.injected` instead
    /// of recording the call. The call is still appended before throwing.
    public var errorOnCall: BackendCallKind? = nil

    // MARK: - Init

    public init() {}

    // MARK: - RenderBackend

    public func beginFrame(size: TerminalSize, defaultStyle: CellStyle) throws {
        calls.append(.beginFrame(size: size, defaultStyle: defaultStyle))
        if errorOnCall == .beginFrame { throw RecordingError.injected }
    }

    public func flush() throws {
        calls.append(.flush)
        if errorOnCall == .flush { throw RecordingError.injected }
    }

    public func titleBar(rect: Rect, left: String, badges: [String], style: CellStyle) throws {
        calls.append(.titleBar(rect: rect, left: left, badges: badges, style: style))
        if errorOnCall == .titleBar { throw RecordingError.injected }
    }

    public func navigatorList(
        rect: Rect,
        items: [Span],
        selectedIndex: Int?,
        title: [Span]
    ) throws {
        calls.append(.navigatorList(rect: rect, items: items, selectedIndex: selectedIndex, title: title))
        if errorOnCall == .navigatorList { throw RecordingError.injected }
    }

    public func paragraph(rect: Rect, lines: [[Span]], block: BlockConfig?) throws {
        calls.append(.paragraph(rect: rect, lines: lines, block: block))
        if errorOnCall == .paragraph { throw RecordingError.injected }
    }

    public func tabBar(rect: Rect, tabs: [String], selectedIndex: Int) throws {
        calls.append(.tabBar(rect: rect, tabs: tabs, selectedIndex: selectedIndex))
        if errorOnCall == .tabBar { throw RecordingError.injected }
    }

    public func block(rect: Rect, config: BlockConfig, borderStyle: CellStyle) throws {
        calls.append(.block(rect: rect, config: config, borderStyle: borderStyle))
        if errorOnCall == .block { throw RecordingError.injected }
    }

    public func clear(rect: Rect) throws {
        calls.append(.clear(rect: rect))
        if errorOnCall == .clear { throw RecordingError.injected }
    }

    public func cellRun(col: UInt16, row: UInt16, text: String, style: CellStyle) throws {
        calls.append(.cellRun(col: col, row: row, text: text, style: style))
        if errorOnCall == .cellRun { throw RecordingError.injected }
    }

    public func leaveAltScreenWithMessage(cols: UInt16, rows: UInt16) throws {
        calls.append(.leaveAltScreenWithMessage(cols: cols, rows: rows))
        if errorOnCall == .leaveAltScreenWithMessage { throw RecordingError.injected }
    }

    public func resumeAltScreen() throws {
        calls.append(.resumeAltScreen)
        if errorOnCall == .resumeAltScreen { throw RecordingError.injected }
    }

    public func teardown() throws {
        // Recording fake: teardown is a silent no-op (no real terminal to restore).
    }

    // MARK: - Helpers

    /// Clears the recorded call log, resetting to an empty state.
    public func reset() {
        calls.removeAll()
    }
}

// MARK: - Equatable conformances for associated types

// Span does not conform to Equatable in RatatuiKit (it holds a String + CellStyle,
// both Equatable). We provide a conditional conformance here for test assertions.
extension Span: Equatable {
    public static func == (lhs: Span, rhs: Span) -> Bool {
        lhs.text == rhs.text && lhs.style == rhs.style
    }
}

// BlockConfig needs Equatable for BackendCall.paragraph / .block assertions.
extension BlockConfig: Equatable {
    public static func == (lhs: BlockConfig, rhs: BlockConfig) -> Bool {
        lhs.borders == rhs.borders
            && lhs.borderType == rhs.borderType
            && lhs.padLeft == rhs.padLeft
            && lhs.padTop == rhs.padTop
            && lhs.padRight == rhs.padRight
            && lhs.padBottom == rhs.padBottom
            && lhs.titleSpans == rhs.titleSpans
    }
}

// MARK: - RecordingError

/// Error thrown by `RecordingRenderBackend` when `errorOnCall` is set.
public enum RecordingError: Error, Equatable {
    case injected
}
