// File: Tests/RatatuiKitTests/EventDecodingTests.swift
// Role: Verifies that RffiEvent structs are decoded correctly into Swift Event
//       values by Events.swift. Uses constructed RffiEvent structs — no real
//       terminal or FFI call is made.
// Upstream: RatatuiKit/Events.swift (Event.init?(from:), KeyCode, KeyModifiers)
// Downstream: (test target — nothing imports this)

import Testing
import CRatatuiFFI
@testable import RatatuiKit

// MARK: - Helpers

/// Constructs a zeroed RffiEvent with the given kind discriminant.
private func makeEvent(kind: UInt32) -> RffiEvent {
    var ev = RffiEvent()
    ev.kind = kind
    return ev
}

// MARK: - Key event decoding

@Suite("Event decoding — key events")
struct KeyEventDecodingTests {

    @Test("char key: scalar 'a' (code 26, char 97)")
    func charKeyA() {
        var ev = makeEvent(kind: 0) // RffiEventKind.key
        ev.key_code = 26            // RffiKeyCode.char
        ev.key_char = 97            // Unicode scalar for 'a'
        ev.key_mods = 0

        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 0)
        ev.key_code = 26
        ev.key_char = 99   // 'c'
        ev.key_mods = 4    // CTRL

        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 0)
        ev.key_code = 0
        let event = Event(from: ev)
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .backspace)
    }

    @Test("enter key (code 1)")
    func enterKey() {
        var ev = makeEvent(kind: 0)
        ev.key_code = 1
        let event = Event(from: ev)
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .enter)
    }

    @Test("escape key (code 27)")
    func escapeKey() {
        var ev = makeEvent(kind: 0)
        ev.key_code = 27
        let event = Event(from: ev)
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .escape)
    }

    @Test("F5 key (code 18)")
    func f5Key() {
        var ev = makeEvent(kind: 0)
        ev.key_code = 18
        let event = Event(from: ev)
        guard case let .key(code, _) = event else {
            Issue.record("Expected .key"); return
        }
        #expect(code == .f(5))
    }

    @Test("unknown key code falls back to .unknown")
    func unknownKeyCode() {
        var ev = makeEvent(kind: 0)
        ev.key_code = 9999
        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 0)
        ev.key_code = 1   // enter
        ev.key_mods = 3   // SHIFT | ALT
        let event = Event(from: ev)
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
            var ev = makeEvent(kind: 0)
            ev.key_code = code
            let event = Event(from: ev)
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
        var ev = makeEvent(kind: 1) // RffiEventKind.resize
        ev.resize_cols = 200
        ev.resize_rows = 60
        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 2) // RffiEventKind.mouse
        ev.mouse_kind = 0           // MouseKind.down
        ev.mouse_button = 0         // MouseButton.left
        ev.mouse_col = 10
        ev.mouse_row = 5
        ev.mouse_mods = 0

        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 2)
        ev.mouse_kind = 9999  // unknown
        ev.mouse_button = 0
        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 3) // RffiEventKind.paste
        let text = "hello world"
        let bytes = Array(text.utf8)
        ev.paste_len = UInt32(bytes.count)
        // Copy bytes into the fixed paste_buf tuple via withUnsafeMutableBytes.
        withUnsafeMutableBytes(of: &ev.paste_buf) { buf in
            for (i, b) in bytes.enumerated() {
                buf[i] = b
            }
        }

        let event = Event(from: ev)
        guard case let .paste(str) = event else {
            Issue.record("Expected .paste, got \(String(describing: event))")
            return
        }
        #expect(str == "hello world")
    }

    @Test("empty paste event gives empty string")
    func emptyPaste() {
        var ev = makeEvent(kind: 3)
        ev.paste_len = 0
        let event = Event(from: ev)
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
        var ev = makeEvent(kind: 9999)
        let event = Event(from: ev)
        #expect(event == nil)
    }
}
