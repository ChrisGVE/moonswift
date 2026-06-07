// File: Tests/RatatuiKitTests/WidgetSmokeTests.swift
// Role: Smoke tests for the four widget wrappers in RatatuiKit: ListWidget,
//       ParagraphWidget, TabsWidget, and clearWidget. Every public method is
//       called at least once, asserting non-throwing construction and mutation.
//       Construction and mutation are fully headless — the Rust shim allocates
//       an in-memory struct and mutates it without touching a TTY. Only the
//       draw() method on each widget and the clearWidget() function need a real
//       terminal handle; those tests are TTY-gated with the same .enabled(if:)
//       pattern used in TerminalLifecycleTests.
// Upstream:  RatatuiKit/Widgets.swift (ListWidget, ParagraphWidget, TabsWidget,
//            clearWidget, Span, BlockConfig, BorderBits, BorderType)
// Downstream: (test target — nothing imports this)

import Testing
@testable import RatatuiKit
import CRatatuiFFI
import Foundation

// MARK: - TTY detection (shared with TerminalLifecycleTests convention)

private var hasTTY: Bool {
    Darwin.isatty(STDOUT_FILENO) != 0
}

// MARK: - ListWidget

@Suite("ListWidget — headless construction and mutation")
struct ListWidgetHeadlessTests {

    @Test("ListWidget init does not throw")
    func initDoesNotThrow() throws {
        _ = try ListWidget()
    }

    @Test("appendItem plain text does not throw")
    func appendItemPlain() throws {
        let list = try ListWidget()
        try list.appendItem("Hello")
        try list.appendItem("World", style: CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0))
    }

    @Test("appendItem with spans does not throw")
    func appendItemSpans() throws {
        let list = try ListWidget()
        let spans: [Span] = [
            Span("bold part", style: CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: UInt16(BOLD))),
            Span(" plain", style: .default),
        ]
        try list.appendItem(spans: spans)
    }

    @Test("appendItem with empty spans array does not throw")
    func appendItemEmptySpans() throws {
        let list = try ListWidget()
        try list.appendItem(spans: [])
    }

    @Test("setSelected positive index does not throw")
    func setSelectedPositive() throws {
        let list = try ListWidget()
        try list.appendItem("item 0")
        try list.setSelected(0)
    }

    @Test("setSelected -1 clears the selection without throwing")
    func setSelectedClear() throws {
        let list = try ListWidget()
        try list.setSelected(-1)
    }

    @Test("setHighlightStyle does not throw")
    func setHighlightStyle() throws {
        let list = try ListWidget()
        let style = CellStyle(fg: 0x00FF00, bg: 0x000000, mods: 0)
        try list.setHighlightStyle(style)
    }

    @Test("setHighlightSymbol non-nil does not throw")
    func setHighlightSymbolNonNil() throws {
        let list = try ListWidget()
        try list.setHighlightSymbol("» ")
    }

    @Test("setHighlightSymbol nil clears without throwing")
    func setHighlightSymbolNil() throws {
        let list = try ListWidget()
        try list.setHighlightSymbol(nil)
    }

    @Test("setScrollOffset does not throw")
    func setScrollOffset() throws {
        let list = try ListWidget()
        try list.setScrollOffset(5)
    }

    @Test("setBlock with no title spans does not throw")
    func setBlockNoTitle() throws {
        let list = try ListWidget()
        let config = BlockConfig(borders: .all, borderType: .rounded)
        try list.setBlock(config)
    }

    @Test("setBlock with title spans does not throw")
    func setBlockWithTitle() throws {
        let list = try ListWidget()
        let config = BlockConfig(
            borders: .all,
            borderType: .thick,
            padLeft: 1, padTop: 0, padRight: 1, padBottom: 0,
            titleSpans: [Span("Items", style: .default)]
        )
        try list.setBlock(config)
    }

    @Test("multiple items and mutations do not throw")
    func multipleItemsAndMutations() throws {
        let list = try ListWidget()
        for i in 0..<10 {
            try list.appendItem("item \(i)")
        }
        try list.setSelected(3)
        try list.setHighlightStyle(CellStyle(fg: 0xFFFFFF, bg: 0x0000FF, mods: 0))
        try list.setHighlightSymbol("> ")
        try list.setScrollOffset(2)
    }
}

@Suite("ListWidget draw — TTY-gated")
struct ListWidgetDrawTests {

    @Test(
        "ListWidget draw does not throw on a real terminal",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func draw() throws {
        let terminal = try Terminal()
        defer { try? terminal.teardown() }

        let list = try ListWidget()
        try list.appendItem("alpha")
        try list.appendItem("beta")
        try list.setSelected(0)

        let rect = Rect(x: 0, y: 0, width: 20, height: 5)
        try list.draw(handle: terminal.rawHandle, rect: rect)
    }
}

// MARK: - ParagraphWidget

@Suite("ParagraphWidget — headless construction and mutation")
struct ParagraphWidgetHeadlessTests {

    @Test("ParagraphWidget init does not throw")
    func initDoesNotThrow() throws {
        _ = try ParagraphWidget()
    }

    @Test("appendLine plain text does not throw")
    func appendLinePlain() throws {
        let para = try ParagraphWidget()
        try para.appendLine("First line")
        try para.appendLine("Second line", style: CellStyle(fg: 0x0000FF, bg: 0xFFFFFF, mods: 0))
    }

    @Test("appendLine with spans does not throw")
    func appendLineSpans() throws {
        let para = try ParagraphWidget()
        let spans: [Span] = [
            Span("italic ", style: CellStyle(fg: 0xFFFFFF, bg: 0x000000, mods: UInt16(ITALIC))),
            Span("normal", style: .default),
        ]
        try para.appendLine(spans: spans)
    }

    @Test("lineBreak does not throw")
    func lineBreak() throws {
        let para = try ParagraphWidget()
        try para.appendLine("before break")
        try para.lineBreak()
        try para.appendLine("after break")
    }

    @Test("setAlignment left (0) does not throw")
    func setAlignmentLeft() throws {
        let para = try ParagraphWidget()
        try para.setAlignment(0)
    }

    @Test("setAlignment center (1) does not throw")
    func setAlignmentCenter() throws {
        let para = try ParagraphWidget()
        try para.setAlignment(1)
    }

    @Test("setAlignment right (2) does not throw")
    func setAlignmentRight() throws {
        let para = try ParagraphWidget()
        try para.setAlignment(2)
    }

    @Test("setWrap without trim does not throw")
    func setWrapNoTrim() throws {
        let para = try ParagraphWidget()
        try para.setWrap(trim: false)
    }

    @Test("setWrap with trim does not throw")
    func setWrapTrim() throws {
        let para = try ParagraphWidget()
        try para.setWrap(trim: true)
    }

    @Test("setScroll does not throw")
    func setScroll() throws {
        let para = try ParagraphWidget()
        try para.setScroll(x: 0, y: 3)
    }

    @Test("setStyle does not throw")
    func setStyle() throws {
        let para = try ParagraphWidget()
        let style = CellStyle(fg: 0xFFFFFF, bg: 0x000000, mods: 0)
        try para.setStyle(style)
    }

    @Test("setBlock with no title spans does not throw")
    func setBlockNoTitle() throws {
        let para = try ParagraphWidget()
        let config = BlockConfig(borders: .all, borderType: .plain)
        try para.setBlock(config)
    }

    @Test("setBlock with title spans does not throw")
    func setBlockWithTitle() throws {
        let para = try ParagraphWidget()
        let config = BlockConfig(
            borders: [.top, .bottom],
            borderType: .double,
            titleSpans: [Span("Log", style: .default)]
        )
        try para.setBlock(config)
    }

    @Test("full mutation chain does not throw")
    func fullMutationChain() throws {
        let para = try ParagraphWidget()
        try para.appendLine("line one")
        try para.appendLine(spans: [Span("styled", style: CellStyle(fg: 0xFF0000, bg: 0xFFFFFF, mods: 0))])
        try para.lineBreak()
        try para.appendLine("line three")
        try para.setAlignment(1)
        try para.setWrap(trim: true)
        try para.setScroll(x: 0, y: 0)
        try para.setStyle(.default)
        try para.setBlock(BlockConfig(borders: .all, borderType: .rounded, titleSpans: [Span("Para")]))
    }
}

@Suite("ParagraphWidget draw — TTY-gated")
struct ParagraphWidgetDrawTests {

    @Test(
        "ParagraphWidget draw does not throw on a real terminal",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func draw() throws {
        let terminal = try Terminal()
        defer { try? terminal.teardown() }

        let para = try ParagraphWidget()
        try para.appendLine("Hello, ratatui!")
        try para.setAlignment(1)

        let rect = Rect(x: 0, y: 0, width: 40, height: 3)
        try para.draw(handle: terminal.rawHandle, rect: rect)
    }
}

// MARK: - TabsWidget

@Suite("TabsWidget — headless construction and mutation")
struct TabsWidgetHeadlessTests {

    @Test("TabsWidget init does not throw")
    func initDoesNotThrow() throws {
        _ = try TabsWidget()
    }

    @Test("appendTitle does not throw")
    func appendTitle() throws {
        let tabs = try TabsWidget()
        try tabs.appendTitle("Tab One")
        try tabs.appendTitle("Tab Two")
        try tabs.appendTitle("Tab Three")
    }

    @Test("setSelected does not throw")
    func setSelected() throws {
        let tabs = try TabsWidget()
        try tabs.appendTitle("A")
        try tabs.appendTitle("B")
        try tabs.setSelected(1)
    }

    @Test("setSelected index 0 does not throw")
    func setSelectedZero() throws {
        let tabs = try TabsWidget()
        try tabs.setSelected(0)
    }

    @Test("setStyles does not throw")
    func setStyles() throws {
        let tabs = try TabsWidget()
        let selected   = CellStyle(fg: 0xFFFFFF, bg: 0x0000FF, mods: UInt16(BOLD))
        let unselected = CellStyle(fg: 0xAAAAAA, bg: 0x000000, mods: 0)
        try tabs.setStyles(selected: selected, unselected: unselected)
    }

    @Test("setBlock with no title spans does not throw")
    func setBlockNoTitle() throws {
        let tabs = try TabsWidget()
        let config = BlockConfig(borders: .all, borderType: .rounded)
        try tabs.setBlock(config)
    }

    @Test("setBlock with title spans does not throw")
    func setBlockWithTitle() throws {
        let tabs = try TabsWidget()
        let config = BlockConfig(
            borders: [.top, .left, .right],
            borderType: .plain,
            titleSpans: [Span("Navigation", style: .default)]
        )
        try tabs.setBlock(config)
    }

    @Test("full mutation chain does not throw")
    func fullMutationChain() throws {
        let tabs = try TabsWidget()
        try tabs.appendTitle("Files")
        try tabs.appendTitle("Search")
        try tabs.appendTitle("Debug")
        try tabs.setSelected(0)
        try tabs.setStyles(
            selected: CellStyle(fg: 0xFFFFFF, bg: 0x005FFF, mods: UInt16(BOLD)),
            unselected: CellStyle(fg: 0x888888, bg: 0x000000, mods: 0)
        )
        try tabs.setBlock(BlockConfig(borders: .all, borderType: .rounded))
    }
}

@Suite("TabsWidget draw — TTY-gated")
struct TabsWidgetDrawTests {

    @Test(
        "TabsWidget draw does not throw on a real terminal",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func draw() throws {
        let terminal = try Terminal()
        defer { try? terminal.teardown() }

        let tabs = try TabsWidget()
        try tabs.appendTitle("Files")
        try tabs.appendTitle("Search")
        try tabs.setSelected(0)

        let rect = Rect(x: 0, y: 0, width: 40, height: 3)
        try tabs.draw(handle: terminal.rawHandle, rect: rect)
    }
}

// MARK: - clearWidget

@Suite("clearWidget — TTY-gated")
struct ClearWidgetTests {

    @Test(
        "clearWidget does not throw on a real terminal",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func clearWidgetDoesNotThrow() throws {
        let terminal = try Terminal()
        defer { try? terminal.teardown() }

        let rect = Rect(x: 0, y: 0, width: 20, height: 5)
        try clearWidget(handle: terminal.rawHandle, rect: rect)
    }
}

// MARK: - Span and BlockConfig value types

@Suite("Span — value type")
struct SpanTests {

    @Test("Span stores text and style")
    func storesTextAndStyle() {
        let style = CellStyle(fg: 0xFF0000, bg: 0x000000, mods: 0)
        let span = Span("hello", style: style)
        #expect(span.text == "hello")
        #expect(span.style == style)
    }

    @Test("Span default style is CellStyle.default")
    func defaultStyle() {
        let span = Span("plain")
        #expect(span.style == .default)
    }
}

@Suite("BlockConfig — value type")
struct BlockConfigTests {

    @Test("BlockConfig stores all fields")
    func storesFields() {
        let spans: [Span] = [Span("Title")]
        let config = BlockConfig(
            borders: .all,
            borderType: .rounded,
            padLeft: 1, padTop: 2, padRight: 3, padBottom: 4,
            titleSpans: spans
        )
        #expect(config.borders == .all)
        #expect(config.borderType == .rounded)
        #expect(config.padLeft == 1)
        #expect(config.padTop == 2)
        #expect(config.padRight == 3)
        #expect(config.padBottom == 4)
        #expect(config.titleSpans.count == 1)
        #expect(config.titleSpans[0].text == "Title")
    }

    @Test("BlockConfig default init has no padding and no title spans")
    func defaultInit() {
        let config = BlockConfig()
        #expect(config.padLeft == 0)
        #expect(config.padTop == 0)
        #expect(config.padRight == 0)
        #expect(config.padBottom == 0)
        #expect(config.titleSpans.isEmpty)
    }
}
