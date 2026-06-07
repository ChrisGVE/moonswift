// File: Sources/RatatuiKit/Widgets.swift
// Role: Swift-idiomatic wrappers for the CRatatuiFFI widget API: List,
//       Paragraph, Tabs, Block (via list/paragraph/tabs set-block), and Clear.
//       All drawing calls are render/terminal-class (UI thread only).
// Upstream: CRatatuiFFI (rffi_list_*, rffi_paragraph_*, rffi_tabs_*,
//           rffi_clear_rect_widget, RffiList, RffiParagraph, RffiTabs, RffiStyle)
// Downstream: MoonSwiftTUI/Render/Renderer.swift (populates and draws widgets)

import CRatatuiFFI

// MARK: - Style helpers

/// Converts a `CellStyle` to the C `RffiStyle` struct expected by widget calls.
private func rffiStyle(from style: CellStyle) -> RffiStyle {
    RffiStyle(fg: style.fg, bg: style.bg, mods: style.mods, _pad: 0)
}

// MARK: - Span

/// A text span with a uniform `CellStyle`: the building block for mixed-style
/// list items, paragraph lines, and widget titles.
public struct Span: Sendable {
    public let text: String
    public let style: CellStyle

    public init(_ text: String, style: CellStyle = .default) {
        self.text = text
        self.style = style
    }
}

// MARK: - BorderType / BorderBits

/// The visual style of widget borders.
public enum BorderType: UInt32, Sendable {
    case plain = 0
    case rounded = 1
    case double = 2
    case thick = 3
}

/// Selects which edges of a widget border are rendered.
///
/// Matches the `border_bits` constants in the generated header.
/// `ALL` is a compound macro not directly importable by Swift, so we compute
/// it here as `top | right | bottom | left`.
public struct BorderBits: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let top = BorderBits(rawValue: UInt8(TOP))
    public static let right = BorderBits(rawValue: UInt8(RIGHT))
    public static let bottom = BorderBits(rawValue: UInt8(BOTTOM))
    public static let left = BorderBits(rawValue: UInt8(LEFT))
    /// All four borders. Computed because the `ALL` macro is a compound
    /// expression that the Swift importer cannot inline.
    public static let all = BorderBits([.top, .right, .bottom, .left])
}

// MARK: - BlockConfig

/// Configuration for the border + title decoration that List, Paragraph,
/// and Tabs each accept via their respective `set_block` shim call.
public struct BlockConfig: Sendable {
    public let borders: BorderBits
    public let borderType: BorderType
    public let padLeft: UInt16
    public let padTop: UInt16
    public let padRight: UInt16
    public let padBottom: UInt16
    public let titleSpans: [Span]

    public init(
        borders: BorderBits = .all,
        borderType: BorderType = .rounded,
        padLeft: UInt16 = 0,
        padTop: UInt16 = 0,
        padRight: UInt16 = 0,
        padBottom: UInt16 = 0,
        titleSpans: [Span] = []
    ) {
        self.borders = borders
        self.borderType = borderType
        self.padLeft = padLeft
        self.padTop = padTop
        self.padRight = padRight
        self.padBottom = padBottom
        self.titleSpans = titleSpans
    }
}

// MARK: - Span FFI helpers

/// Calls `body` with a temporary `[RffiSpan]` array constructed from `spans`.
///
/// The `RffiSpan.text_utf8` pointers are only valid within `body`; the
/// owning `String` values remain alive for the duration of the call via the
/// recursive `withCString` scoping pattern.
private func withRffiSpans<T>(
    _ spans: [Span],
    body: ([RffiSpan]) throws -> T
) rethrows -> T {
    func recurse(
        _ remaining: ArraySlice<Span>,
        _ acc: inout [RffiSpan],
        _ body: ([RffiSpan]) throws -> T
    ) rethrows -> T {
        guard let span = remaining.first else { return try body(acc) }
        return try span.text.withCString { ptr in
            let rffiSpan = RffiSpan(text_utf8: ptr, style: rffiStyle(from: span.style))
            acc.append(rffiSpan)
            defer { acc.removeLast() }
            return try recurse(remaining.dropFirst(), &acc, body)
        }
    }
    var acc: [RffiSpan] = []
    acc.reserveCapacity(spans.count)
    return try recurse(spans[...], &acc, body)
}

// MARK: - ListWidget

/// A managed handle for the CRatatuiFFI list widget.
///
/// Create, configure, draw, and then let it deinit — the destructor calls
/// `rffi_list_free` automatically (RAII). Thread class: render/terminal-class.
///
/// `RffiList` is a forward-declared opaque C struct. Swift imports pointers to
/// such types as `OpaquePointer`; the C functions accept `struct RffiList *`
/// which Swift bridges from `OpaquePointer` automatically at call sites.
public final class ListWidget {

    private let ptr: OpaquePointer

    // MARK: - Init / Deinit

    /// Creates a new empty list handle.
    ///
    /// - Throws: `FFIError` with code -1 if the shim returns NULL (OOM, unlikely).
    public init() throws {
        guard let p = rffi_list_new() else {
            throw FFIError(code: -1, message: "rffi_list_new returned NULL")
        }
        self.ptr = p
    }

    deinit {
        _ = rffi_list_free(ptr)
    }

    // MARK: - Item population

    /// Appends a plain-text item (single uniform style).
    public func appendItem(_ text: String, style: CellStyle = .default) throws {
        try text.withCString { cstr in
            try checkFFI(rffi_list_append_item(ptr, cstr, rffiStyle(from: style)))
        }
    }

    /// Appends a span-array item (mixed styles on one line).
    public func appendItem(spans: [Span]) throws {
        try withRffiSpans(spans) { rffiSpans in
            try rffiSpans.withUnsafeBufferPointer { buf in
                try checkFFI(rffi_list_append_item_spans(ptr, buf.baseAddress, rffiSpans.count))
            }
        }
    }

    // MARK: - Selection & display

    /// Sets the selected item index; pass -1 to clear the selection.
    public func setSelected(_ index: Int32) throws {
        try checkFFI(rffi_list_set_selected(ptr, index))
    }

    /// Sets the highlight style applied to the selected row.
    public func setHighlightStyle(_ style: CellStyle) throws {
        try checkFFI(rffi_list_set_highlight_style(ptr, rffiStyle(from: style)))
    }

    /// Sets the highlight symbol prefix (e.g. `"» "`). Pass `nil` to clear.
    public func setHighlightSymbol(_ symbol: String?) throws {
        if let sym = symbol {
            try sym.withCString { cstr in
                try checkFFI(rffi_list_set_highlight_symbol(ptr, cstr))
            }
        } else {
            try checkFFI(rffi_list_set_highlight_symbol(ptr, nil))
        }
    }

    /// Sets the scroll offset within the list.
    public func setScrollOffset(_ offset: Int) throws {
        try checkFFI(rffi_list_set_scroll_offset(ptr, offset))
    }

    /// Sets the item direction: `true` = bottom-to-top; `false` = top-to-bottom.
    public func setBottomToTop(_ bottomToTop: Bool) throws {
        try checkFFI(rffi_list_set_direction(ptr, bottomToTop ? 1 : 0))
    }

    /// Attaches a border + title block to the list.
    public func setBlock(_ config: BlockConfig) throws {
        try withRffiSpans(config.titleSpans) { rffiSpans in
            try rffiSpans.withUnsafeBufferPointer { buf in
                try checkFFI(
                    rffi_list_set_block(
                        ptr,
                        config.borders.rawValue,
                        config.borderType.rawValue,
                        config.padLeft, config.padTop,
                        config.padRight, config.padBottom,
                        buf.baseAddress, rffiSpans.count
                    ))
            }
        }
    }

    // MARK: - Draw

    /// Draws the list into the given rect of the terminal frame buffer.
    ///
    /// Thread class: render/terminal-class.
    public func draw(handle: UnsafeMutableRawPointer, rect: Rect) throws {
        try checkFFI(rffi_list_draw(handle, ptr, rect.rffi))
    }
}

// MARK: - ParagraphWidget

/// A managed handle for the CRatatuiFFI paragraph widget.
///
/// RAII: `rffi_paragraph_free` is called in `deinit`. Thread class: render/terminal-class.
///
/// `RffiParagraph` is a forward-declared opaque C struct; stored and passed as
/// `OpaquePointer` (see `ListWidget` note above for the bridging rule).
public final class ParagraphWidget {

    private let ptr: OpaquePointer

    // MARK: - Init / Deinit

    public init() throws {
        guard let p = rffi_paragraph_new() else {
            throw FFIError(code: -1, message: "rffi_paragraph_new returned NULL")
        }
        self.ptr = p
    }

    deinit {
        _ = rffi_paragraph_free(ptr)
    }

    // MARK: - Content

    /// Appends a plain-text line (single uniform style).
    public func appendLine(_ text: String, style: CellStyle = .default) throws {
        try text.withCString { cstr in
            try checkFFI(rffi_paragraph_append_line(ptr, cstr, rffiStyle(from: style)))
        }
    }

    /// Appends a span-array line (mixed styles).
    public func appendLine(spans: [Span]) throws {
        try withRffiSpans(spans) { rffiSpans in
            try rffiSpans.withUnsafeBufferPointer { buf in
                try checkFFI(rffi_paragraph_append_line_spans(ptr, buf.baseAddress, rffiSpans.count))
            }
        }
    }

    /// Inserts a blank line separator.
    public func lineBreak() throws {
        try checkFFI(rffi_paragraph_line_break(ptr))
    }

    // MARK: - Display options

    /// Sets text alignment: 0 = left, 1 = centre, 2 = right.
    public func setAlignment(_ alignment: UInt32) throws {
        try checkFFI(rffi_paragraph_set_alignment(ptr, alignment))
    }

    /// Enables word-wrapping; `trim` = true trims leading whitespace.
    public func setWrap(trim: Bool = false) throws {
        try checkFFI(rffi_paragraph_set_wrap(ptr, trim ? 1 : 0))
    }

    /// Sets the scroll offset: `x` = column offset, `y` = row offset.
    public func setScroll(x: UInt16, y: UInt16) throws {
        try checkFFI(rffi_paragraph_set_scroll(ptr, x, y))
    }

    /// Sets the base style applied to the paragraph as a whole.
    public func setStyle(_ style: CellStyle) throws {
        try checkFFI(rffi_paragraph_set_style(ptr, rffiStyle(from: style)))
    }

    /// Attaches a border + title block to the paragraph.
    public func setBlock(_ config: BlockConfig) throws {
        try withRffiSpans(config.titleSpans) { rffiSpans in
            try rffiSpans.withUnsafeBufferPointer { buf in
                try checkFFI(
                    rffi_paragraph_set_block(
                        ptr,
                        config.borders.rawValue,
                        config.borderType.rawValue,
                        config.padLeft, config.padTop,
                        config.padRight, config.padBottom,
                        buf.baseAddress, rffiSpans.count
                    ))
            }
        }
    }

    // MARK: - Draw

    /// Draws the paragraph into the given rect of the terminal frame buffer.
    ///
    /// Thread class: render/terminal-class.
    public func draw(handle: UnsafeMutableRawPointer, rect: Rect) throws {
        try checkFFI(rffi_paragraph_draw(handle, ptr, rect.rffi))
    }
}

// MARK: - TabsWidget

/// A managed handle for the CRatatuiFFI tabs bar widget.
///
/// RAII: `rffi_tabs_free` is called in `deinit`. Thread class: render/terminal-class.
///
/// `RffiTabs` is a forward-declared opaque C struct; stored and passed as
/// `OpaquePointer` (see `ListWidget` note above for the bridging rule).
public final class TabsWidget {

    private let ptr: OpaquePointer

    // MARK: - Init / Deinit

    public init() throws {
        guard let p = rffi_tabs_new() else {
            throw FFIError(code: -1, message: "rffi_tabs_new returned NULL")
        }
        self.ptr = p
    }

    deinit {
        _ = rffi_tabs_free(ptr)
    }

    // MARK: - Titles

    /// Appends a tab title (UTF-8 string).
    public func appendTitle(_ title: String) throws {
        try title.withCString { cstr in
            try checkFFI(rffi_tabs_append_title(ptr, cstr))
        }
    }

    /// Sets the index of the currently selected tab.
    public func setSelected(_ index: UInt16) throws {
        try checkFFI(rffi_tabs_set_selected(ptr, index))
    }

    /// Sets both selected and unselected tab styles in one call.
    public func setStyles(selected: CellStyle, unselected: CellStyle) throws {
        let styles = RffiTabsStyles(
            selected: rffiStyle(from: selected),
            unselected: rffiStyle(from: unselected)
        )
        try checkFFI(rffi_tabs_set_styles(ptr, styles))
    }

    /// Attaches a border + title block to the tabs bar.
    public func setBlock(_ config: BlockConfig) throws {
        try withRffiSpans(config.titleSpans) { rffiSpans in
            try rffiSpans.withUnsafeBufferPointer { buf in
                try checkFFI(
                    rffi_tabs_set_block(
                        ptr,
                        config.borders.rawValue,
                        config.borderType.rawValue,
                        config.padLeft, config.padTop,
                        config.padRight, config.padBottom,
                        buf.baseAddress, rffiSpans.count
                    ))
            }
        }
    }

    // MARK: - Draw

    /// Draws the tabs bar into the given rect of the terminal frame buffer.
    ///
    /// Thread class: render/terminal-class.
    public func draw(handle: UnsafeMutableRawPointer, rect: Rect) throws {
        try checkFFI(rffi_tabs_draw(handle, ptr, rect.rffi))
    }
}

// MARK: - Clear widget

/// Clears a rectangular region of the terminal frame buffer to the default
/// background. Thin wrapper over `rffi_clear_rect_widget`.
///
/// Thread class: render/terminal-class.
public func clearWidget(handle: UnsafeMutableRawPointer, rect: Rect) throws {
    try checkFFI(rffi_clear_rect_widget(handle, rect.rffi))
}
