// File: Sources/MoonSwiftTUI/App/Reducers/SplitRatioReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: F5.6 split-ratio persistence — the TUI half. The codec/validation half
//       lives in MoonSwiftCore (SettingsConfig + ProjectFileCodec + Project
//       Validation). This file bridges the persisted RATIOS (`[settings]
//       navigator_split` / `bottom_split`, fractions of the terminal) and the
//       reducer's ABSOLUTE layout (`PaneLayout.navigatorWidth` cells /
//       `bottomPaneHeight` rows):
//         - `applySplitRatios` — ratio → absolute, applied on project load.
//         - `splitPersistEffects` — absolute → ratio, emitted on a resize so the
//           new ratio auto-saves to `moonswift.toml`.
//       Kept out of the 2325-line Reducer.swift per §4.7 (Reducer.swift only
//       gains the one-line calls).
//
// Upstream: AppState (paneLayout, terminalSize, project), SettingsConfig,
//           Effect.persistSplitRatios
// Downstream: Reducer.swift (projectLoaded → applySplitRatios; the
//             `<`/`>`/`{`/`}` resize handlers → splitPersistEffects)

import Foundation
import MoonSwiftCore

// MARK: - Ratio → absolute (apply on load)

/// Apply persisted split ratios to the absolute pane layout, using the current
/// terminal size. Each ratio is clamped to its valid range first (an out-of-range
/// stored value was already surfaced as a validation diagnostic), then converted
/// to cells/rows and clamped to the layout's hard bounds — so a saved layout is
/// always restored to a usable shape (F5.6 acceptance: reload restores layout).
func applySplitRatios(_ s: inout AppState, settings: SettingsConfig) {
    let cols = Double(s.terminalSize.cols)
    let rows = Double(s.terminalSize.rows)

    let navCells = Int((settings.clampedNavigatorSplit * cols).rounded())
    s.paneLayout.navigatorWidth = min(
        max(navCells, PaneLayout.navigatorMin), PaneLayout.navigatorMax)

    let botRows = Int((settings.clampedBottomSplit * rows).rounded())
    s.paneLayout.bottomPaneHeight = min(
        max(botRows, PaneLayout.bottomPaneMin), PaneLayout.bottomPaneMaxRatio)
}

// MARK: - Absolute → ratio (persist on resize)

/// Build the auto-save effect for the current layout after a split resize.
///
/// Returns `[.persistSplitRatios(...)]` when a project is loaded (so there is a
/// `moonswift.toml` to write), else `[]` (a quick-file session has no project
/// file to persist to). Both ratios are recomputed from the current absolute
/// layout and clamped into their valid ranges so the written file never holds an
/// out-of-range value. The bottom ratio falls back to the loaded project's saved
/// value when `bottomPaneHeight` is still deriving (nil).
func splitPersistEffects(_ s: AppState) -> [Effect] {
    guard case .loaded(let file, _) = s.project else { return [] }

    let cols = Double(s.terminalSize.cols)
    let rows = Double(s.terminalSize.rows)
    guard cols > 0, rows > 0 else { return [] }

    let navRatio = Double(s.paneLayout.navigatorWidth) / cols
    let botRatio =
        s.paneLayout.bottomPaneHeight.map { Double($0) / rows } ?? file.settings.bottomSplit

    let navClamped = min(
        max(navRatio, SettingsConfig.navigatorSplitRange.lowerBound),
        SettingsConfig.navigatorSplitRange.upperBound)
    let botClamped = min(
        max(botRatio, SettingsConfig.bottomSplitRange.lowerBound),
        SettingsConfig.bottomSplitRange.upperBound)

    return [.persistSplitRatios(navigatorSplit: navClamped, bottomSplit: botClamped)]
}
