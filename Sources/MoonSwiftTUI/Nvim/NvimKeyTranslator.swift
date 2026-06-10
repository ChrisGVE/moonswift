// File: Sources/MoonSwiftTUI/Nvim/NvimKeyTranslator.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Translates RatatuiKit KeyCode + KeyModifiers into nvim key-notation
//       strings suitable for passing to nvim_input. Returns nil for keys that
//       have no nvim notation (lock keys, pause, menu, null, unknown).
//
// Key-notation reference: https://neovim.io/doc/user/intro.html#key-notation
//   (`:help key-notation` in nvim). Rules implemented here:
//     - Plain printable char → the char itself ("a", "1", "/").
//     - `<` literal → `<lt>` (must escape — nvim treats `<` as special-key start).
//     - Named keys have angle-bracket forms: <CR>, <Esc>, <BS>, <Tab>, etc.
//     - Modifier prefixes inside the brackets, canonical order C-S-M:
//         Ctrl → "C-", Shift → "S-", Alt/Meta → "M-"
//     - Shift+printable char: the terminal already encodes case in the scalar
//       (e.g. Shift+a arrives as .char("A") with .shift set). For plain
//       printable output we emit the char as-is — no "S-" prefix added.
//       "S-" is added only when Ctrl or Alt is also present, or for named keys.
//     - Space: plain space is a literal " "; space with Ctrl/Alt → <C-Space> etc.
//     - backTab: always produces <S-Tab> (the S is part of the base name).
//
// Architecture context (ARCHITECTURE.md §10.4.8, §10.8 Inc-5):
//   Used by the Reducer (Inc-8) whenever the editor is in .nvimPane focus:
//   each raw KeyCode event is translated here before being forwarded via
//   Effect.nvimInput(string). If translate returns nil the event is dropped.
//
// Upstream:  RatatuiKit/Events.swift — KeyCode, KeyModifiers
// Downstream: Reducer.swift (Inc-8) — Effect.nvimInput(string)

import RatatuiKit

// MARK: - NvimKeyTranslator

/// Translates terminal key events into nvim key-notation strings for `nvim_input`.
///
/// This is a static-namespace enum (no instances). All logic lives in
/// `translate(_:modifiers:)`.
public enum NvimKeyTranslator {

    // MARK: - Public interface

    /// Returns the nvim key-notation string for `key` + `modifiers`, or `nil`
    /// if the key has no nvim notation.
    ///
    /// The caller (Reducer, Inc-8) should drop events where this returns `nil`.
    ///
    /// - Parameters:
    ///   - key: The decoded key code from RatatuiKit.
    ///   - modifiers: The modifier keys active during the event.
    /// - Returns: An nvim key-notation string, or `nil` for untranslatable keys.
    public static func translate(_ key: KeyCode, modifiers: KeyModifiers) -> String? {
        switch key {
        case .char(let scalar):
            return translateChar(scalar, modifiers: modifiers)

        case .enter:
            return wrap("CR", modifiers: modifiers)

        case .escape:
            return wrap("Esc", modifiers: modifiers)

        case .backspace:
            return wrap("BS", modifiers: modifiers)

        case .tab:
            return wrap("Tab", modifiers: modifiers)

        case .backTab:
            // backTab is intrinsically Shift+Tab; its base notation is <S-Tab>.
            // Additional modifiers (e.g. Ctrl) are prepended: <C-S-Tab>.
            return wrap("S-Tab", modifiers: modifiers.subtracting(.shift))

        case .delete:
            return wrap("Del", modifiers: modifiers)

        case .insert:
            return wrap("Insert", modifiers: modifiers)

        case .left:
            return wrap("Left", modifiers: modifiers)

        case .right:
            return wrap("Right", modifiers: modifiers)

        case .up:
            return wrap("Up", modifiers: modifiers)

        case .down:
            return wrap("Down", modifiers: modifiers)

        case .home:
            return wrap("Home", modifiers: modifiers)

        case .end:
            return wrap("End", modifiers: modifiers)

        case .pageUp:
            return wrap("PageUp", modifiers: modifiers)

        case .pageDown:
            return wrap("PageDown", modifiers: modifiers)

        case .f(let n):
            return wrap("F\(n)", modifiers: modifiers)

        // Keys with no nvim notation — drop them.
        case .capsLock, .scrollLock, .numLock, .printScreen, .pause, .menu, .null, .unknown:
            return nil
        }
    }
}

// MARK: - Private helpers

extension NvimKeyTranslator {

    /// Translates a printable Unicode scalar, respecting modifier rules.
    ///
    /// Plain printable chars (no Ctrl/Alt): emit the char directly. The terminal
    /// already encodes case in the scalar (Shift+a → 'A'), so no S- prefix.
    /// Space without modifiers → literal " ". Space with Ctrl/Alt → <C-Space>.
    /// `<` always escapes to `lt` inside angle brackets (or `<lt>` bare).
    /// When Ctrl or Alt is present, wrap in angle brackets with modifier prefix.
    private static func translateChar(
        _ scalar: Unicode.Scalar,
        modifiers: KeyModifiers
    ) -> String {
        let isSpace = scalar == " "
        let isLessThan = scalar == "<"

        // Plain char: no Ctrl, no Alt.
        guard modifiers.contains(.ctrl) || modifiers.contains(.alt) else {
            if isLessThan { return "<lt>" }
            return String(scalar)
        }

        // Ctrl or Alt present — must bracket.
        // For space and `<` use symbolic names; for others use the char itself.
        let keyName: String
        if isSpace {
            keyName = "Space"
        } else if isLessThan {
            keyName = "lt"
        } else {
            keyName = String(scalar)
        }

        return wrap(keyName, modifiers: modifiers)
    }

    /// Wraps `name` in angle brackets with the canonical C-S-M modifier prefix.
    ///
    /// If no modifiers are set, returns `<\(name)>` directly.
    /// Modifier order inside the brackets: C (ctrl) → S (shift) → M (alt/meta).
    private static func wrap(_ name: String, modifiers: KeyModifiers) -> String {
        let prefix = modifierPrefix(for: modifiers)
        return "<\(prefix)\(name)>"
    }

    /// Returns the canonical modifier prefix string for `modifiers`.
    ///
    /// Order: C- then S- then M-, matching nvim's canonical form.
    /// An empty OptionSet produces an empty string.
    private static func modifierPrefix(for modifiers: KeyModifiers) -> String {
        var prefix = ""
        if modifiers.contains(.ctrl) { prefix += "C-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        if modifiers.contains(.alt) { prefix += "M-" }
        return prefix
    }
}
