// File: Tests/MoonSwiftTUITests/Nvim/NvimKeyTranslatorTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Unit tests for NvimKeyTranslator — verifying the KeyCode+KeyModifiers →
//       nvim key-notation mapping required by nvim_input calls.
//
// Architecture context (ARCHITECTURE.md §10.4.8, §10.8 Inc-5):
//   NvimKeyTranslator is the pure translation layer between RatatuiKit events and
//   the nvim input protocol. These tests are table-driven and cover every named
//   key, F1–F12, representative printable ASCII, the `<` → `<lt>` escape, all
//   modifier combos on chars and named keys, and nil cases for keys nvim has
//   no notation for.
//
// Relationships:
//   → NvimKeyTranslator.swift  (unit under test)
//   → RatatuiKit/Events.swift  (KeyCode and KeyModifiers types)

import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Printable characters

@Suite("NvimKeyTranslator — printable characters")
struct PrintableCharTests {

    @Test("lowercase letter passes through as-is")
    func lowercaseLetter() {
        #expect(NvimKeyTranslator.translate(.char("a"), modifiers: []) == "a")
    }

    @Test("uppercase letter passes through as-is (shift already encoded in scalar)")
    func uppercaseLetter() {
        // Terminal sends 'A' with Shift set; translator emits the char, not <S-A>.
        #expect(NvimKeyTranslator.translate(.char("A"), modifiers: .shift) == "A")
    }

    @Test("digit passes through as-is")
    func digit() {
        #expect(NvimKeyTranslator.translate(.char("1"), modifiers: []) == "1")
    }

    @Test("slash passes through as-is")
    func slash() {
        #expect(NvimKeyTranslator.translate(.char("/"), modifiers: []) == "/")
    }

    @Test("space with no modifiers passes through as a literal space")
    func plainSpace() {
        #expect(NvimKeyTranslator.translate(.char(" "), modifiers: []) == " ")
    }

    @Test("space with Ctrl produces <C-Space>")
    func ctrlSpace() {
        #expect(NvimKeyTranslator.translate(.char(" "), modifiers: .ctrl) == "<C-Space>")
    }

    @Test("less-than sign escapes to <lt>")
    func lessThan() {
        #expect(NvimKeyTranslator.translate(.char("<"), modifiers: []) == "<lt>")
    }

    @Test("less-than with Ctrl produces <C-lt>")
    func ctrlLessThan() {
        #expect(NvimKeyTranslator.translate(.char("<"), modifiers: .ctrl) == "<C-lt>")
    }

    @Test("less-than with Alt produces <M-lt>")
    func altLessThan() {
        #expect(NvimKeyTranslator.translate(.char("<"), modifiers: .alt) == "<M-lt>")
    }

    @Test("less-than with Ctrl+Alt produces <C-M-lt>")
    func ctrlAltLessThan() {
        #expect(NvimKeyTranslator.translate(.char("<"), modifiers: [.ctrl, .alt]) == "<C-M-lt>")
    }
}

// MARK: - Named keys (no modifiers)

@Suite("NvimKeyTranslator — named keys, no modifiers")
struct NamedKeyTests {

    @Test("enter → <CR>")
    func enter() {
        #expect(NvimKeyTranslator.translate(.enter, modifiers: []) == "<CR>")
    }

    @Test("escape → <Esc>")
    func escape() {
        #expect(NvimKeyTranslator.translate(.escape, modifiers: []) == "<Esc>")
    }

    @Test("backspace → <BS>")
    func backspace() {
        #expect(NvimKeyTranslator.translate(.backspace, modifiers: []) == "<BS>")
    }

    @Test("tab → <Tab>")
    func tab() {
        #expect(NvimKeyTranslator.translate(.tab, modifiers: []) == "<Tab>")
    }

    @Test("backTab → <S-Tab>")
    func backTab() {
        // BackTab is inherently shift; nvim's notation is <S-Tab>.
        #expect(NvimKeyTranslator.translate(.backTab, modifiers: []) == "<S-Tab>")
    }

    @Test("delete → <Del>")
    func delete() {
        #expect(NvimKeyTranslator.translate(.delete, modifiers: []) == "<Del>")
    }

    @Test("insert → <Insert>")
    func insert() {
        #expect(NvimKeyTranslator.translate(.insert, modifiers: []) == "<Insert>")
    }

    @Test("left → <Left>")
    func left() {
        #expect(NvimKeyTranslator.translate(.left, modifiers: []) == "<Left>")
    }

    @Test("right → <Right>")
    func right() {
        #expect(NvimKeyTranslator.translate(.right, modifiers: []) == "<Right>")
    }

    @Test("up → <Up>")
    func up() {
        #expect(NvimKeyTranslator.translate(.up, modifiers: []) == "<Up>")
    }

    @Test("down → <Down>")
    func down() {
        #expect(NvimKeyTranslator.translate(.down, modifiers: []) == "<Down>")
    }

    @Test("home → <Home>")
    func home() {
        #expect(NvimKeyTranslator.translate(.home, modifiers: []) == "<Home>")
    }

    @Test("end → <End>")
    func end() {
        #expect(NvimKeyTranslator.translate(.end, modifiers: []) == "<End>")
    }

    @Test("pageUp → <PageUp>")
    func pageUp() {
        #expect(NvimKeyTranslator.translate(.pageUp, modifiers: []) == "<PageUp>")
    }

    @Test("pageDown → <PageDown>")
    func pageDown() {
        #expect(NvimKeyTranslator.translate(.pageDown, modifiers: []) == "<PageDown>")
    }
}

// MARK: - Function keys

@Suite("NvimKeyTranslator — function keys")
struct FunctionKeyTests {

    @Test("F1 through F12 produce <F1>…<F12>")
    func fKeys() {
        let expected = (1...12).map { "<F\($0)>" }
        let actual = (1...12).map {
            NvimKeyTranslator.translate(.f(UInt8($0)), modifiers: []) ?? "nil"
        }
        #expect(actual == expected)
    }

    @Test("Shift+F1 produces <S-F1>")
    func shiftF1() {
        #expect(NvimKeyTranslator.translate(.f(1), modifiers: .shift) == "<S-F1>")
    }

    @Test("Ctrl+F5 produces <C-F5>")
    func ctrlF5() {
        #expect(NvimKeyTranslator.translate(.f(5), modifiers: .ctrl) == "<C-F5>")
    }

    @Test("Alt+F12 produces <M-F12>")
    func altF12() {
        #expect(NvimKeyTranslator.translate(.f(12), modifiers: .alt) == "<M-F12>")
    }
}

// MARK: - Modifier combos on printable chars

@Suite("NvimKeyTranslator — modifier combos on chars")
struct ModifierCharTests {

    @Test("Ctrl+x produces <C-x>")
    func ctrlX() {
        #expect(NvimKeyTranslator.translate(.char("x"), modifiers: .ctrl) == "<C-x>")
    }

    @Test("Alt+x produces <M-x>")
    func altX() {
        #expect(NvimKeyTranslator.translate(.char("x"), modifiers: .alt) == "<M-x>")
    }

    @Test("Ctrl+Shift+x produces <C-S-x> (modifier combo preserves shift flag)")
    func ctrlShiftX() {
        // When Ctrl is present with a printable char, S- is added for Shift.
        #expect(NvimKeyTranslator.translate(.char("x"), modifiers: [.ctrl, .shift]) == "<C-S-x>")
    }

    @Test("Ctrl+Alt+x produces <C-M-x>")
    func ctrlAltX() {
        #expect(NvimKeyTranslator.translate(.char("x"), modifiers: [.ctrl, .alt]) == "<C-M-x>")
    }

    @Test("Ctrl+Alt+Shift+x produces <C-S-M-x>")
    func ctrlAltShiftX() {
        #expect(NvimKeyTranslator.translate(.char("x"), modifiers: [.ctrl, .shift, .alt]) == "<C-S-M-x>")
    }
}

// MARK: - Modifier combos on named keys

@Suite("NvimKeyTranslator — modifier combos on named keys")
struct ModifierNamedKeyTests {

    @Test("Ctrl+Enter produces <C-CR>")
    func ctrlEnter() {
        #expect(NvimKeyTranslator.translate(.enter, modifiers: .ctrl) == "<C-CR>")
    }

    @Test("Alt+Escape produces <M-Esc>")
    func altEscape() {
        #expect(NvimKeyTranslator.translate(.escape, modifiers: .alt) == "<M-Esc>")
    }

    @Test("Ctrl+Left produces <C-Left>")
    func ctrlLeft() {
        #expect(NvimKeyTranslator.translate(.left, modifiers: .ctrl) == "<C-Left>")
    }

    @Test("Shift+Delete produces <S-Del>")
    func shiftDelete() {
        #expect(NvimKeyTranslator.translate(.delete, modifiers: .shift) == "<S-Del>")
    }

    @Test("Ctrl+Shift+Up produces <C-S-Up>")
    func ctrlShiftUp() {
        #expect(NvimKeyTranslator.translate(.up, modifiers: [.ctrl, .shift]) == "<C-S-Up>")
    }

    @Test("Alt+Backspace produces <M-BS>")
    func altBackspace() {
        #expect(NvimKeyTranslator.translate(.backspace, modifiers: .alt) == "<M-BS>")
    }

    @Test("backTab with Ctrl produces <C-S-Tab> (S- preserved from backTab base)")
    func ctrlBackTab() {
        // backTab always carries an implicit S; adding Ctrl → <C-S-Tab>.
        #expect(NvimKeyTranslator.translate(.backTab, modifiers: .ctrl) == "<C-S-Tab>")
    }
}

// MARK: - Nil cases

@Suite("NvimKeyTranslator — untranslatable keys return nil")
struct NilCaseTests {

    @Test("capsLock returns nil")
    func capsLock() {
        #expect(NvimKeyTranslator.translate(.capsLock, modifiers: []) == nil)
    }

    @Test("scrollLock returns nil")
    func scrollLock() {
        #expect(NvimKeyTranslator.translate(.scrollLock, modifiers: []) == nil)
    }

    @Test("numLock returns nil")
    func numLock() {
        #expect(NvimKeyTranslator.translate(.numLock, modifiers: []) == nil)
    }

    @Test("printScreen returns nil")
    func printScreen() {
        #expect(NvimKeyTranslator.translate(.printScreen, modifiers: []) == nil)
    }

    @Test("pause returns nil")
    func pause() {
        #expect(NvimKeyTranslator.translate(.pause, modifiers: []) == nil)
    }

    @Test("menu returns nil")
    func menu() {
        #expect(NvimKeyTranslator.translate(.menu, modifiers: []) == nil)
    }

    @Test("null returns nil")
    func null() {
        #expect(NvimKeyTranslator.translate(.null, modifiers: []) == nil)
    }

    @Test("unknown returns nil")
    func unknown() {
        #expect(NvimKeyTranslator.translate(.unknown(0xFFFF), modifiers: []) == nil)
    }
}
