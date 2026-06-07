// File: Tests/RatatuiKitTests/EventDecodingTests.swift
// Role: Verifies that RffiEvent structs are decoded correctly into Swift Event
//       values by Events.swift. Uses constructed RffiEvent structs — no real
//       terminal or FFI call is made.
// Upstream: RatatuiKit/Events.swift (Event.init?(reading:), KeyCode, KeyModifiers)
// Downstream: (test target — nothing imports this)
//
// Stack discipline: RffiEvent is ~4 KB (inline paste buffer). Tests construct
// events through EventBox, a heap-allocating helper, and decode them via the
// pointer-based Event(reading:) — never holding an RffiEvent on the stack.
// By-value RffiEvent locals multiplied into 13–20 KB debug-build frames, which
// overflowed the small stacks swift-testing runs tests on in CI (SIGBUS in
// __chkstk_darwin on Apple Silicon runners).

import Testing
import CRatatuiFFI
@testable import RatatuiKit

// MARK: - Helpers

/// Heap-boxed RffiEvent for test construction.
///
/// Owns a heap allocation and zero-fills it with memset-style initialization —
/// no RffiEvent value ever materialises on a stack frame (a debug-build
/// `RffiEvent()` temporary alone is ~4 KB).  Tests mutate fields through the
/// `ev` pointee accessor and decode in place via `decode()`.
private final class EventBox {
    let ptr: UnsafeMutablePointer<RffiEvent>

    /// Direct field access to the boxed event (pointee mutation — field-sized
    /// loads/stores only, never a whole-struct copy).
    var ev: RffiEvent {
        get { ptr.pointee }
        _modify { yield &ptr.pointee }
    }

    /// Creates a zeroed RffiEvent with the given kind discriminant.
    init(kind: UInt32) {
        ptr = .allocate(capacity: 1)
        // Zero-fill in place; RffiEvent is a trivial C struct, so byte-zeroing
        // is a valid initialization and avoids a 4 KB stack temporary.
        UnsafeMutableRawPointer(ptr)
            .initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<RffiEvent>.size)
        ptr.pointee.kind = kind
    }

    deinit {
        ptr.deallocate()
    }

    /// Decodes the boxed event in place (no stack copy of RffiEvent).
    func decode() -> Event? {
        Event(reading: ptr)
    }
}

// MARK: - Key event decoding

@Suite("Event decoding — key events")
struct KeyEventDecodingTests {

    @Test("char key: scalar 'a' (code 26, char 97)")
    func charKeyA() {
        let box = EventBox(kind: 0) // RffiEventKind.key
        box.ev.key_code = 26        // RffiKeyCode.char
        box.ev.key_char = 97        // Unicode scalar for 'a'
        box.ev.key_mods = 0

        let event = box.decode()
        guard case let .key(code, mods) = event else {
            Issue.record("Expected .key, got \(String(describing: event))")
            return
        }
        guard case let .char(scalar) = code else {
            Issue.record("Expected .char, got \(code)")
            return
        }
        #expect(scalar == Unicode.Scalar("a"))
        #expect(mods == [])
    }

    @Test("char key with Ctrl modifier (code 26, char 99, mods 4)")
    func charKeyCtrlC() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 26
        box.ev.key_char = 99   // 'c'
        box.ev.key_mods = 4    // CTRL

        let event = box.decode()
        guard case let .key(code, mods) = event else {
            Issue.record("Expected .key"); return
        }
        guard case .char = code else {
            Issue.record("Expected .char"); return
        }
        #expect(mods.contains(.ctrl))
        #expect(!mods.contains(.shift))
        #expect(!mods.contains(.alt))
    }

    @Test("backspace key (code 0)")
    func backspaceKey() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 0
        let event = box.decode()
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .backspace)
    }

    @Test("enter key (code 1)")
    func enterKey() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 1
        let event = box.decode()
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .enter)
    }

    @Test("escape key (code 27)")
    func escapeKey() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 27
        let event = box.decode()
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .escape)
    }

    @Test("F5 key (code 18)")
    func f5Key() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 18
        let event = box.decode()
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .f(5))
    }

    @Test("unknown key code falls back to .unknown")
    func unknownKeyCode() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 9999
        let event = box.decode()
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        guard case .unknown(let raw) = code else {
            Issue.record("Expected .unknown, got \(code)"); return
        }
        #expect(raw == 9999)
    }

    @Test("Shift+Alt modifier combination (mods = 3)")
    func shiftAltModifiers() {
        let box = EventBox(kind: 0)
        box.ev.key_code = 1   // enter
        box.ev.key_mods = 3   // SHIFT | ALT
        let event = box.decode()
        guard case let .key(_, mods) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(mods.contains(.shift))
        #expect(mods.contains(.alt))
        #expect(!mods.contains(.ctrl))
    }

    @Test("arrow keys decode to directional codes")
    func arrowKeys() {
        // left=2, right=3, up=4, down=5
        let cases: [(UInt32, KeyCode)] = [
            (2, .left), (3, .right), (4, .up), (5, .down)
        ]
        for (code, expected) in cases {
            let box = EventBox(kind: 0)
            box.ev.key_code = code
            let event = box.decode()
            guard case let .key(kc, _) = event else {
                Issue.record("Expected .key for code \(code)"); continue
            }
            #expect(kc == expected, "Code \(code) should produce \(expected), got \(kc)")
        }
    }
}

// MARK: - Resize event decoding

@Suite("Event decoding — resize")
struct ResizeEventDecodingTests {

    @Test("resize event carries cols and rows")
    func resizeEvent() {
        let box = EventBox(kind: 1) // RffiEventKind.resize
        box.ev.resize_cols = 200
        box.ev.resize_rows = 60
        let event = box.decode()
        guard case let .resize(cols, rows) = event else {
            Issue.record("Expected .resize, got \(String(describing: event))")
            return
        }
        #expect(cols == 200)
        #expect(rows == 60)
    }
}

// MARK: - Mouse event decoding

@Suite("Event decoding — mouse")
struct MouseEventDecodingTests {

    @Test("mouse down event carries position and button")
    func mouseDown() {
        let box = EventBox(kind: 2) // RffiEventKind.mouse
        box.ev.mouse_kind = 0       // MouseKind.down
        box.ev.mouse_button = 0     // MouseButton.left
        box.ev.mouse_col = 10
        box.ev.mouse_row = 5
        box.ev.mouse_mods = 0

        let event = box.decode()
        guard case let .mouse(kind, button, col, row, mods) = event else {
            Issue.record("Expected .mouse, got \(String(describing: event))")
            return
        }
        #expect(kind == .down)
        #expect(button == .left)
        #expect(col == 10)
        #expect(row == 5)
        #expect(mods == [])
    }

    @Test("unknown mouse kind falls back to .moved")
    func unknownMouseKind() {
        let box = EventBox(kind: 2)
        box.ev.mouse_kind = 9999  // unknown
        box.ev.mouse_button = 0
        let event = box.decode()
        guard case let .mouse(kind, _, _, _, _) = event else {
            Issue.record("Expected .mouse"); return
        }
        // Unknown kind maps to .moved (MouseKind(rawValue:) returns nil → default)
        #expect(kind == .moved)
    }
}

// MARK: - Paste event decoding

@Suite("Event decoding — paste")
struct PasteEventDecodingTests {

    @Test("paste event carries text content")
    func pasteText() {
        let box = EventBox(kind: 3) // RffiEventKind.paste
        let text = "hello world"
        let bytes = Array(text.utf8)
        box.ev.paste_len = UInt32(bytes.count)
        // Copy bytes into the fixed paste_buf tuple via withUnsafeMutableBytes.
        withUnsafeMutableBytes(of: &box.ev.paste_buf) { buf in
            for (i, b) in bytes.enumerated() {
                buf[i] = b
            }
        }

        let event = box.decode()
        guard case let .paste(str) = event else {
            Issue.record("Expected .paste, got \(String(describing: event))")
            return
        }
        #expect(str == "hello world")
    }

    @Test("empty paste event gives empty string")
    func emptyPaste() {
        let box = EventBox(kind: 3)
        box.ev.paste_len = 0
        let event = box.decode()
        guard case let .paste(str) = event else {
            Issue.record("Expected .paste"); return
        }
        #expect(str.isEmpty)
    }

    @Test("by-value decode path (Event.init?(from:)) still works")
    func byValueDecode() {
        // Covers the by-value convenience initializer. One deliberate stack
        // copy — the only such copy in the suite.
        let box = EventBox(kind: 3)
        box.ev.paste_len = 0
        let event = Event(from: box.ev)
        guard case let .paste(str) = event else {
            Issue.record("Expected .paste"); return
        }
        #expect(str.isEmpty)
    }
}

// MARK: - Unknown event kind

@Suite("Event decoding — unknown kind")
struct UnknownEventKindTests {

    @Test("unknown event kind returns nil (forward compat)")
    func unknownKind() {
        let box = EventBox(kind: 9999)
        let event = box.decode()
        #expect(event == nil)
    }
}
