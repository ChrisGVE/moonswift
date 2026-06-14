// File: Sources/MoonSwiftTUI/App/Reducers/HelpOverlayReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: Pure reducer logic for the help-overlay modal (#39) — scroll + close
//       key handling. Extracted from Reducer.swift per ARCHITECTURE §4.7 (the
//       top-level reducer keeps only minimal dispatch; feature logic lives in
//       the per-feature reducer file). Pairs with the renderer extraction in
//       Render/HelpOverlayView.swift (commit 9a481f4).
//
// Upstream: AppState, KeyCode/KeyModifiers (RatatuiKit),
//           helpOverlayMaxScrollOffset (Render/HelpOverlayView.swift)
// Downstream: Reducer.swift (reduceKey dispatch: `case .helpOverlay`)

import Foundation
import RatatuiKit

/// Handle a key while the help overlay is focused — scroll the keybinding list
/// or close/quit the overlay.
///
/// The keybinding list overflows the 60×20 overlay, so it scrolls (ux-spec
/// §2.5). The viewport reserves the last overlay row for the scroll footer;
/// `helpOverlayMaxScrollOffset` mirrors the renderer's window maths so the clamp
/// is exact. Keymap (vim/neovim, with keyboard-nav shadows):
///   ↑ / ↓                line up / down
///   <C-u> / <C-d>        half page up / down (no arrow equivalent)
///   <C-b> / <C-f>        full page up / down  (PgUp / PgDn shadow)
///   g / G                top / bottom         (Home / End shadow)
func reduceHelpOverlayKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    let overlayH = Int(min(20, s.terminalSize.rows))
    let contentViewport = max(1, overlayH - 1)  // -1 reserves the footer row
    let maxOffset = helpOverlayMaxScrollOffset(terminalRows: s.terminalSize.rows)
    let half = max(1, contentViewport / 2)
    let full = max(1, contentViewport)
    func clamp(_ v: Int) -> Int { min(max(0, v), maxOffset) }

    switch (code, modifiers) {
    case (.escape, []), (.char("?"), []):
        s.focus = .pane(.navigator)
        s.helpScrollOffset = 0
    case (.char("q"), []):
        // `q` quits from the help overlay (ux-spec §2.5 — overlay must not
        // trap the global quit shortcut).
        return (s, [.quit(exitCode: 0)])
    case (.down, []):
        s.helpScrollOffset = clamp(s.helpScrollOffset + 1)
    case (.up, []):
        s.helpScrollOffset = clamp(s.helpScrollOffset - 1)
    case (.char("d"), .ctrl):
        s.helpScrollOffset = clamp(s.helpScrollOffset + half)
    case (.char("u"), .ctrl):
        s.helpScrollOffset = clamp(s.helpScrollOffset - half)
    case (.char("f"), .ctrl), (.pageDown, []):
        s.helpScrollOffset = clamp(s.helpScrollOffset + full)
    case (.char("b"), .ctrl), (.pageUp, []):
        s.helpScrollOffset = clamp(s.helpScrollOffset - full)
    case (.char("g"), []), (.home, []):
        s.helpScrollOffset = 0
    case (.char("G"), []), (.end, []):
        s.helpScrollOffset = maxOffset
    default:
        break
    }
    return (s, [])
}
