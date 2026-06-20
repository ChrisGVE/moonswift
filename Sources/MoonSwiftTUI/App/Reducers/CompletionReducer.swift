// File: Sources/MoonSwiftTUI/App/Reducers/CompletionReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: Pure reducer logic for the F7a.2 completion popup + hover overlay —
//       <C-space>/K gestures in the code pane, popup navigation, hover scroll,
//       and the completionsReady/hoverReady event transitions. Kept out of
//       Reducer.swift per ARCHITECTURE §4.7 (the top-level reducer carries only
//       minimal dispatch). Pairs with the renderer extractions in
//       Render/CompletionView.swift and Render/HoverView.swift.
//
// Upstream: AppState (FocusState, CompletionPopupState, HoverOverlayState),
//           KeyCode/KeyModifiers (RatatuiKit), MockLiveState.completionItems()
//           (MoonSwiftCore), completionPopupMaxVisible (CompletionView.swift),
//           hoverOverlayMaxScrollOffset (HoverView.swift)
// Downstream: Reducer.swift (reduceKey dispatch + reduce() event dispatch)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - Code-pane gestures (open)

/// `<C-space>` in the code pane: extract the completion prefix at the cursor line
/// and emit `Effect.queryCompletions` (F7a.2, ux-spec §7.6).
///
/// The catalog only completes at a `luaswift.` / `luaswift.X.` boundary, so an
/// off-prefix press yields an empty query and no popup (handled by
/// `reduceCompletionsReady`). `liveMocks` is snapshotted from the CACHED
/// `mockLiveState` — never a fresh introspection (PERF-03).
func reduceCodePaneOpenCompletion(_ s: AppState) -> (AppState, [Effect]) {
    let prefix = currentCodeLine(s).map(completionPrefix(forLine:)) ?? ""
    let liveMocks = s.mockLiveState?.completionItems() ?? []
    let tomlProbed = s.tomlModuleAvailable ?? false
    return (s, [.queryCompletions(prefix: prefix, liveMocks: liveMocks, tomlProbed: tomlProbed)])
}

/// `K` in the code pane: resolve the symbol under the cursor and emit
/// `Effect.queryHover` (F7a.2). The overlay always opens on `hoverReady`, even
/// when nothing resolves (UX-R3-01) — the symbol name is stashed in
/// `hoverPendingSymbol` so the no-doc overlay can be titled.
func reduceCodePaneOpenHover(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    let symbol = currentCodeLine(s).map(symbolUnderCursor(line:)) ?? ""
    s.hoverPendingSymbol = symbol
    let liveMocks = s.mockLiveState?.completionItems() ?? []
    let tomlProbed = s.tomlModuleAvailable ?? false
    return (s, [.queryHover(symbolName: symbol, liveMocks: liveMocks, tomlProbed: tomlProbed)])
}

// MARK: - Popup key handling

/// Handle a key while the completion popup is focused — navigate, open hover on
/// the selected item, or dismiss (ux-spec §7.6).
func reduceCompletionPopupKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    guard case .completionPopup(var popup) = s.focus else { return (s, []) }
    var s = s

    switch (code, modifiers) {
    case (.escape, []):
        s.focus = .pane(.codePane)
    case (.char("j"), []), (.down, []):
        moveSelection(&popup, by: 1)
        s.focus = .completionPopup(popup)
    case (.char("k"), []), (.up, []):
        moveSelection(&popup, by: -1)
        s.focus = .completionPopup(popup)
    case (.enter, []):
        // <Enter> opens the hover overlay for the selected item (no insertion —
        // the code pane is read-only). We already hold the item, so the overlay
        // opens directly without a queryHover round-trip.
        guard !popup.items.isEmpty else {
            s.focus = .pane(.codePane)
            break
        }
        let item = popup.items[popup.selectedIndex]
        s.focus = .hoverOverlay(HoverOverlayState(item: item, symbolName: item.label))
    default:
        break
    }
    return (s, [])
}

/// Move the popup selection by `delta`, keeping the selected row inside the
/// `completionPopupMaxVisible`-row scroll window.
private func moveSelection(_ popup: inout CompletionPopupState, by delta: Int) {
    guard !popup.items.isEmpty else { return }
    popup.selectedIndex = min(max(0, popup.selectedIndex + delta), popup.items.count - 1)
    if popup.selectedIndex < popup.scrollOffset {
        popup.scrollOffset = popup.selectedIndex
    } else if popup.selectedIndex >= popup.scrollOffset + completionPopupMaxVisible {
        popup.scrollOffset = popup.selectedIndex - completionPopupMaxVisible + 1
    }
}

// MARK: - Hover overlay key handling

/// Handle a key while the hover overlay is focused — scroll the doc or dismiss
/// (ux-spec §7.6). `K` toggles the overlay closed, mirroring the open gesture.
func reduceHoverOverlayKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    guard case .hoverOverlay(var hov) = s.focus else { return (s, []) }
    var s = s
    let maxOffset = hoverOverlayMaxScrollOffset(state: hov, terminalSize: s.terminalSize)
    func clamp(_ v: Int) -> Int { min(max(0, v), maxOffset) }

    switch (code, modifiers) {
    case (.escape, []), (.char("K"), []):
        s.focus = .pane(.codePane)
    case (.char("j"), []), (.down, []):
        hov.scrollOffset = clamp(hov.scrollOffset + 1)
        s.focus = .hoverOverlay(hov)
    case (.char("k"), []), (.up, []):
        hov.scrollOffset = clamp(hov.scrollOffset - 1)
        s.focus = .hoverOverlay(hov)
    default:
        break
    }
    return (s, [])
}

// MARK: - Event transitions

/// `AppEvent.completionsReady`: open the popup over the code pane. An empty list
/// is a no-op — there is nothing to complete at the cursor prefix (ux-spec §7.6).
/// If focus moved away from the code pane while the query ran, drop silently.
func reduceCompletionsReady(_ s: AppState, items: [CompletionItem]) -> (AppState, [Effect]) {
    var s = s
    guard case .pane(.codePane) = s.focus else { return (s, []) }
    guard !items.isEmpty else { return (s, []) }
    s.focus = .completionPopup(CompletionPopupState(items: items))
    return (s, [])
}

/// `AppEvent.hoverReady`: open the hover overlay. The overlay opens whether or
/// not `item` resolved — a `nil` payload renders `hoverPendingSymbol` over
/// `(no documentation available)` (UX-R3-01; `K` is never a silent no-op).
func reduceHoverReady(_ s: AppState, item: CompletionItem?) -> (AppState, [Effect]) {
    var s = s
    guard case .pane(.codePane) = s.focus else { return (s, []) }
    let name = item?.label ?? s.hoverPendingSymbol
    s.hoverPendingSymbol = ""
    s.focus = .hoverOverlay(HoverOverlayState(item: item, symbolName: name))
    return (s, [])
}

// MARK: - Text extraction helpers

/// The text of the code pane's current cursor line, or `nil` when no source is
/// loaded or the cursor index is out of range.
func currentCodeLine(_ s: AppState) -> String? {
    guard let sid = s.selection, case .loaded(let fragment) = s.sources[sid] else { return nil }
    let lines = fragment.code.components(separatedBy: "\n")
    let idx = s.codePane.cursorLine
    guard idx >= 0, idx < lines.count else { return nil }
    return lines[idx]
}

/// Extract the completion prefix from a line: the trailing run of identifier and
/// `.` characters (e.g. `… = luaswift.json.` → `luaswift.json.`). The catalog
/// only responds to the `luaswift.` / `luaswift.X.` forms; any other trailing
/// run yields an empty completion list.
func completionPrefix(forLine line: String) -> String {
    var tail: [Character] = []
    for ch in line.reversed() {
        if ch == "." || ch == "_" || ch.isLetter || ch.isNumber {
            tail.append(ch)
        } else {
            break
        }
    }
    return String(tail.reversed())
}

/// Best-effort symbol-under-cursor extraction for `K` hover. With no text-column
/// cursor in the read-only code pane, this prefers the first dotted (qualified)
/// token on the line — the likely hover target, e.g. `luaswift.stringx.split`
/// from `local s = luaswift.stringx.split(x)` — falling back to the longest
/// bare identifier, or `""` when the line has none.
func symbolUnderCursor(line: String) -> String {
    var tokens: [String] = []
    var current = ""
    for ch in line {
        if ch == "." || ch == "_" || ch.isLetter || ch.isNumber {
            current.append(ch)
        } else if !current.isEmpty {
            tokens.append(current)
            current = ""
        }
    }
    if !current.isEmpty { tokens.append(current) }

    if let dotted = tokens.first(where: { $0.contains(".") && !$0.hasSuffix(".") }) {
        return dotted
    }
    return tokens.max(by: { $0.count < $1.count }) ?? ""
}
