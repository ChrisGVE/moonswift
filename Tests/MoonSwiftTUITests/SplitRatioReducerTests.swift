// File: Tests/MoonSwiftTUITests/SplitRatioReducerTests.swift
// Location: MoonSwiftTUITests/
// Role: F5.6 (TUI half) — ratio↔absolute split reconciliation. Covers
//       `applySplitRatios` (ratio → absolute on load), the `projectLoaded`
//       wiring that calls it, and `splitPersistEffects` (absolute → ratio,
//       clamped, emitted on resize). The codec/validation half is in
//       MoonSwiftCoreTests/SettingsSplitTests.swift.
//
// Upstream: SplitRatioReducer.swift, Reducer.swift, Effect.persistSplitRatios
// Downstream: (test target)

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func loadedProject(nav: Double, bottom: Double) -> ProjectFile {
    ProjectFile(
        luaVersion: "5.4",
        settings: SettingsConfig(theme: "default", navigatorSplit: nav, bottomSplit: bottom)
    )
}

private func persistRatios(_ effects: [Effect]) -> (Double, Double)? {
    for e in effects {
        if case .persistSplitRatios(let nav, let bot) = e { return (nav, bot) }
    }
    return nil
}

// MARK: - Apply on load (ratio → absolute)

@Suite("F5.6 — applySplitRatios (ratio → absolute)")
struct ApplySplitRatiosTests {

    @Test("ratios convert to absolute cells/rows for the current terminal size")
    func ratiosConvertToAbsolute() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 100, rows: 40)
        applySplitRatios(&s, settings: SettingsConfig(navigatorSplit: 0.25, bottomSplit: 0.30))
        #expect(s.paneLayout.navigatorWidth == 25)  // 0.25 * 100
        #expect(s.paneLayout.bottomPaneHeight == 12)  // 0.30 * 40
    }

    @Test("converted navigator width is clamped to the layout max")
    func navigatorWidthClampedToMax() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 100, rows: 40)
        // 0.50 * 100 = 50 cells, but navigatorMax is 30.
        applySplitRatios(&s, settings: SettingsConfig(navigatorSplit: 0.50, bottomSplit: 0.30))
        #expect(s.paneLayout.navigatorWidth == PaneLayout.navigatorMax)
    }

    @Test("an out-of-range stored ratio is clamped before conversion")
    func outOfRangeRatioClamped() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 200, rows: 40)
        // navigatorSplit 0.9 is out of range → clampedNavigatorSplit 0.50 → 100 cells
        // → clamped to navigatorMax (30).
        applySplitRatios(&s, settings: SettingsConfig(navigatorSplit: 0.9, bottomSplit: 0.30))
        #expect(s.paneLayout.navigatorWidth == PaneLayout.navigatorMax)
    }

    @Test("projectLoaded applies the file's saved split ratios to the layout")
    func projectLoadedAppliesRatios() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 80, rows: 30)
        let file = loadedProject(nav: 0.25, bottom: 0.40)
        let (next, _) = reduce(s, .projectLoaded(file, diagnostics: []))
        #expect(next.paneLayout.navigatorWidth == 20)  // 0.25 * 80
        #expect(next.paneLayout.bottomPaneHeight == 12)  // 0.40 * 30
    }
}

// MARK: - Persist on resize (absolute → ratio)

@Suite("F5.6 — splitPersistEffects (absolute → ratio)")
struct SplitPersistEffectsTests {

    @Test("a loaded project produces a persist effect with the current ratio")
    func loadedProjectEmitsPersist() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 100, rows: 40)
        s.project = .loaded(loadedProject(nav: 0.25, bottom: 0.30), diagnostics: [])
        s.paneLayout.navigatorWidth = 30  // 0.30 of 100
        s.paneLayout.bottomPaneHeight = 12  // 0.30 of 40
        let ratios = persistRatios(splitPersistEffects(s))
        #expect(ratios != nil)
        #expect(ratios?.0 == 0.30)
        #expect(ratios?.1 == 0.30)
    }

    @Test("no project loaded → no persist effect (quick-file session)")
    func noProjectNoPersist() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 100, rows: 40)
        s.project = .none
        s.paneLayout.navigatorWidth = 30
        #expect(splitPersistEffects(s).isEmpty)
    }

    @Test("persisted ratio is clamped into the valid range")
    func persistedRatioClamped() {
        var s = AppState()
        // Narrow terminal: 30-cell navigator on 40 cols = 0.75 → clamped to 0.50.
        s.terminalSize = TerminalSize(cols: 40, rows: 40)
        s.project = .loaded(loadedProject(nav: 0.25, bottom: 0.30), diagnostics: [])
        s.paneLayout.navigatorWidth = 30
        s.paneLayout.bottomPaneHeight = 12
        let ratios = persistRatios(splitPersistEffects(s))
        #expect(ratios?.0 == SettingsConfig.navigatorSplitRange.upperBound)  // 0.50
    }

    @Test("nav-only resize falls back to the loaded file's bottom ratio")
    func bottomRatioFallback() {
        var s = AppState()
        s.terminalSize = TerminalSize(cols: 100, rows: 40)
        s.project = .loaded(loadedProject(nav: 0.25, bottom: 0.35), diagnostics: [])
        s.paneLayout.navigatorWidth = 25
        s.paneLayout.bottomPaneHeight = nil  // still deriving — use file's saved value
        let ratios = persistRatios(splitPersistEffects(s))
        #expect(ratios?.1 == 0.35)
    }
}
