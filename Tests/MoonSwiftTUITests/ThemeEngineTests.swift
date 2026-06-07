// File: Tests/MoonSwiftTUITests/ThemeEngineTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for ThemeEngine and the "default" built-in theme. Covers:
//       capability detection for every env-var combination mandated by
//       ux-spec §8.3; exact color values for all 18 tokens in each tier
//       per ux-spec §8.1; and NO_COLOR mode colorless-but-marked semantics.
//       No FFI is linked in this target.
// Upstream: ThemeEngine.swift, DefaultTheme.swift, Capability.swift,
//           AppState (ThemeToken, TokenStyle, TerminalColor, ColorCapability)

import Testing

@testable import MoonSwiftTUI

// MARK: - Capability detection

/// Tests for detectCapability(environment:) (ux-spec §8.3 detection order).
@Suite("Capability detection")
struct CapabilityDetectionTests {

    // MARK: NO_COLOR (step 1)

    @Test("NO_COLOR set to non-empty value → noColor")
    func noColorWithValue() {
        let cap = detectCapability(environment: ["NO_COLOR": "1"])
        #expect(cap == .noColor)
    }

    @Test("NO_COLOR set to empty string → noColor (spec: any value incl. empty)")
    func noColorEmpty() {
        let cap = detectCapability(environment: ["NO_COLOR": ""])
        #expect(cap == .noColor)
    }

    @Test("NO_COLOR overrides COLORTERM=truecolor → noColor wins")
    func noColorOverridesColorterm() {
        let cap = detectCapability(environment: ["NO_COLOR": "", "COLORTERM": "truecolor"])
        #expect(cap == .noColor)
    }

    @Test("NO_COLOR overrides TERM with 256color → noColor wins")
    func noColorOverridesTerm() {
        let cap = detectCapability(environment: ["NO_COLOR": "1", "TERM": "xterm-256color"])
        #expect(cap == .noColor)
    }

    // MARK: COLORTERM truecolor (step 2)

    @Test("COLORTERM=truecolor → truecolor")
    func colortermTruecolor() {
        let cap = detectCapability(environment: ["COLORTERM": "truecolor"])
        #expect(cap == .truecolor)
    }

    @Test("COLORTERM=24bit → truecolor")
    func colorterm24bit() {
        let cap = detectCapability(environment: ["COLORTERM": "24bit"])
        #expect(cap == .truecolor)
    }

    @Test("COLORTERM=256color (not a truecolor value) → falls through")
    func colortermOtherValue() {
        // "256color" is not a recognized COLORTERM truecolor value; steps 3/4 apply
        let cap = detectCapability(environment: ["COLORTERM": "256color"])
        #expect(cap == .color256)
    }

    // MARK: TERM 256color (step 3)

    @Test("TERM=xterm-256color → color256")
    func termXterm256color() {
        let cap = detectCapability(environment: ["TERM": "xterm-256color"])
        #expect(cap == .color256)
    }

    @Test("TERM=screen-256color → color256")
    func termScreen256color() {
        let cap = detectCapability(environment: ["TERM": "screen-256color"])
        #expect(cap == .color256)
    }

    @Test("TERM=xterm-color (no '256color') → default color256")
    func termWithoutColor256() {
        let cap = detectCapability(environment: ["TERM": "xterm-color"])
        #expect(cap == .color256)
    }

    // MARK: Default (step 4)

    @Test("Empty environment → color256 (safe default)")
    func emptyEnvironment() {
        let cap = detectCapability(environment: [:])
        #expect(cap == .color256)
    }

    @Test("Unrelated variables only → color256 (safe default)")
    func unrelatedVariables() {
        let cap = detectCapability(environment: ["PATH": "/usr/bin", "HOME": "/Users/test"])
        #expect(cap == .color256)
    }
}

// MARK: - ThemeEngine.resolve — capability seam

@Suite("ThemeEngine resolve via environment seam")
struct ThemeEngineEnvironmentTests {

    @Test("NO_COLOR environment → noColor capability in resolved state")
    func noColorEnvironmentResolvesNoColor() {
        let state = ThemeEngine.resolve(environment: ["NO_COLOR": "1"])
        #expect(state.capability == .noColor)
    }

    @Test("COLORTERM=truecolor environment → truecolor in resolved state")
    func truecolorEnvironmentResolvesTrue() {
        let state = ThemeEngine.resolve(environment: ["COLORTERM": "truecolor"])
        #expect(state.capability == .truecolor)
    }

    @Test("Empty environment → color256 in resolved state")
    func emptyEnvironmentResolvesColor256() {
        let state = ThemeEngine.resolve(environment: [:])
        #expect(state.capability == .color256)
    }

    @Test("Resolved theme name is 'default'")
    func resolvedThemeNameIsDefault() {
        let state = ThemeEngine.resolve(environment: [:])
        #expect(state.name == "default")
    }

    @Test("All 18 ThemeToken cases present in resolved state")
    func allTokensPresent() {
        let state = ThemeEngine.resolve(environment: ["COLORTERM": "truecolor"])
        for token in ThemeToken.allCases {
            #expect(state.tokens[token] != nil, "Expected token \(token) to be present")
        }
    }
}

// MARK: - Truecolor token values (ux-spec §8.1 exact hex values)

/// Verifies every token's exact truecolor RGB against ux-spec §8.1.
@Suite("Default theme — truecolor values (ux-spec §8.1)")
struct TruecolorTokenTests {

    private let theme = ThemeEngine.resolve(capability: .truecolor)

    // MARK: Code syntax tokens

    @Test("keyword fg = #FF79C6 (Dracula pink)")
    func keywordFg() {
        #expect(theme.tokens[.keyword]?.fg == .rgb(0xFF, 0x79, 0xC6))
    }

    @Test("string fg = #F1FA8C (Dracula yellow)")
    func stringFg() {
        #expect(theme.tokens[.string]?.fg == .rgb(0xF1, 0xFA, 0x8C))
    }

    @Test("comment fg = #6272A4 (Dracula comment)")
    func commentFg() {
        #expect(theme.tokens[.comment]?.fg == .rgb(0x62, 0x72, 0xA4))
    }

    @Test("number fg = #BD93F9 (Dracula purple)")
    func numberFg() {
        #expect(theme.tokens[.number]?.fg == .rgb(0xBD, 0x93, 0xF9))
    }

    @Test("functionName (function_name) fg = #50FA7B (Dracula green)")
    func functionNameFg() {
        #expect(theme.tokens[.functionName]?.fg == .rgb(0x50, 0xFA, 0x7B))
    }

    @Test("identifier fg = #F8F8F2 (Dracula foreground)")
    func identifierFg() {
        #expect(theme.tokens[.identifier]?.fg == .rgb(0xF8, 0xF8, 0xF2))
    }

    @Test("operatorToken fg = #FF79C6 (Dracula pink, same as keyword)")
    func operatorTokenFg() {
        #expect(theme.tokens[.operatorToken]?.fg == .rgb(0xFF, 0x79, 0xC6))
    }

    // MARK: Diagnostic / status tokens

    @Test("error fg = #FF5555 (Dracula red)")
    func errorFg() {
        #expect(theme.tokens[.error]?.fg == .rgb(0xFF, 0x55, 0x55))
    }

    @Test("warning fg = #FFB86C (Dracula orange)")
    func warningFg() {
        #expect(theme.tokens[.warning]?.fg == .rgb(0xFF, 0xB8, 0x6C))
    }

    @Test("added fg = #50FA7B (Dracula green, same as functionName)")
    func addedFg() {
        #expect(theme.tokens[.added]?.fg == .rgb(0x50, 0xFA, 0x7B))
    }

    // MARK: UI chrome tokens

    @Test("focusBorder (focus_border) fg = #BD93F9 (Dracula purple)")
    func focusBorderFg() {
        #expect(theme.tokens[.focusBorder]?.fg == .rgb(0xBD, 0x93, 0xF9))
    }

    @Test("focusBg (focus_bg) bg = #44475A (Dracula selection — cursor-line background)")
    func focusBgBg() {
        #expect(theme.tokens[.focusBg]?.bg == .rgb(0x44, 0x47, 0x5A))
    }

    @Test("highlightBg (highlight_bg) bg = #3D4455 (jump-target line background)")
    func highlightBgBg() {
        #expect(theme.tokens[.highlightBg]?.bg == .rgb(0x3D, 0x44, 0x55))
    }

    @Test("highlightPulse (highlight_pulse) bg = #6272A4 (Dracula comment blue)")
    func highlightPulseBg() {
        #expect(theme.tokens[.highlightPulse]?.bg == .rgb(0x62, 0x72, 0xA4))
    }

    @Test("dim fg = #6272A4 (Dracula comment)")
    func dimFg() {
        #expect(theme.tokens[.dim]?.fg == .rgb(0x62, 0x72, 0xA4))
    }

    @Test("running fg = #8BE9FD (Dracula cyan — [running…] indicator and spinner)")
    func runningFg() {
        #expect(theme.tokens[.running]?.fg == .rgb(0x8B, 0xE9, 0xFD))
    }

    @Test("gutterBg (gutter_bg) bg = #282A36 (Dracula background — gutter column)")
    func gutterBgBg() {
        #expect(theme.tokens[.gutterBg]?.bg == .rgb(0x28, 0x2A, 0x36))
    }

    @Test("paneBg (pane_bg) fg = #F8F8F2 and bg = #282A36")
    func paneBgStyle() {
        let style = theme.tokens[.paneBg]
        #expect(style?.fg == .rgb(0xF8, 0xF8, 0xF2))
        #expect(style?.bg == .rgb(0x28, 0x2A, 0x36))
    }
}

// MARK: - 256-color token values (ux-spec §8.1 exact indices)

/// Verifies every token's exact 256-color palette index against ux-spec §8.1.
@Suite("Default theme — 256-color values (ux-spec §8.1)")
struct Color256TokenTests {

    private let theme = ThemeEngine.resolve(capability: .color256)

    @Test("keyword fg = index 212 (medium pink)")
    func keywordFg() {
        #expect(theme.tokens[.keyword]?.fg == .index(212))
    }

    @Test("string fg = index 228 (light yellow)")
    func stringFg() {
        #expect(theme.tokens[.string]?.fg == .index(228))
    }

    @Test("comment fg = index 61 (muted blue-purple)")
    func commentFg() {
        #expect(theme.tokens[.comment]?.fg == .index(61))
    }

    @Test("number fg = index 141 (soft purple)")
    func numberFg() {
        #expect(theme.tokens[.number]?.fg == .index(141))
    }

    @Test("functionName (function_name) fg = index 84 (bright green)")
    func functionNameFg() {
        #expect(theme.tokens[.functionName]?.fg == .index(84))
    }

    @Test("identifier fg = index 255 (near-white)")
    func identifierFg() {
        #expect(theme.tokens[.identifier]?.fg == .index(255))
    }

    @Test("operatorToken fg = index 212 (medium pink)")
    func operatorTokenFg() {
        #expect(theme.tokens[.operatorToken]?.fg == .index(212))
    }

    @Test("error fg = index 203 (bright red)")
    func errorFg() {
        #expect(theme.tokens[.error]?.fg == .index(203))
    }

    @Test("warning fg = index 215 (soft orange)")
    func warningFg() {
        #expect(theme.tokens[.warning]?.fg == .index(215))
    }

    @Test("added fg = index 84 (bright green)")
    func addedFg() {
        #expect(theme.tokens[.added]?.fg == .index(84))
    }

    @Test("focusBorder fg = index 141 (soft purple)")
    func focusBorderFg() {
        #expect(theme.tokens[.focusBorder]?.fg == .index(141))
    }

    @Test("focusBg (focus_bg) bg = index 237 (dark gray — cursor-line background)")
    func focusBgBg() {
        #expect(theme.tokens[.focusBg]?.bg == .index(237))
    }

    @Test("highlightBg (highlight_bg) bg = index 238 (slightly lighter gray)")
    func highlightBgBg() {
        #expect(theme.tokens[.highlightBg]?.bg == .index(238))
    }

    @Test("highlightPulse bg = index 61 (muted blue-purple)")
    func highlightPulseBg() {
        #expect(theme.tokens[.highlightPulse]?.bg == .index(61))
    }

    @Test("dim fg = index 61 (muted blue-purple)")
    func dimFg() {
        #expect(theme.tokens[.dim]?.fg == .index(61))
    }

    @Test("running fg = index 117 (light cyan — [running…] indicator and spinner)")
    func runningFg() {
        #expect(theme.tokens[.running]?.fg == .index(117))
    }

    @Test("gutterBg (gutter_bg) bg = index 236 (very dark gray — gutter column)")
    func gutterBgBg() {
        #expect(theme.tokens[.gutterBg]?.bg == .index(236))
    }

    @Test("paneBg (pane_bg) fg = index 255, bg = index 235")
    func paneBgStyle() {
        let style = theme.tokens[.paneBg]
        #expect(style?.fg == .index(255))
        #expect(style?.bg == .index(235))
    }
}

// MARK: - NO_COLOR mode

/// Verifies that NO_COLOR mode strips all color while retaining Bold/Underline
/// on semantics-bearing tokens (ux-spec §8.3, §4.3, §8.5 accessibility rule).
@Suite("Default theme — NO_COLOR mode")
struct NoColorTokenTests {

    private let theme = ThemeEngine.resolve(capability: .noColor)

    // MARK: Color is absent

    @Test("All tokens have nil fg in NO_COLOR mode")
    func allForegroundsNil() {
        for token in ThemeToken.allCases {
            #expect(theme.tokens[token]?.fg == nil, "Token \(token) should have nil fg in NO_COLOR mode")
        }
    }

    @Test("All tokens have nil bg in NO_COLOR mode")
    func allBackgroundsNil() {
        for token in ThemeToken.allCases {
            #expect(theme.tokens[token]?.bg == nil, "Token \(token) should have nil bg in NO_COLOR mode")
        }
    }

    // MARK: Semantic markers retained via modifiers

    @Test("error token has Bold in NO_COLOR (E-prefix char is the paired marker)")
    func errorBold() {
        #expect(theme.tokens[.error]?.bold == true)
    }

    @Test("warning token has Bold in NO_COLOR (W-prefix char is the paired marker)")
    func warningBold() {
        #expect(theme.tokens[.warning]?.bold == true)
    }

    @Test("focusBorder has Bold in NO_COLOR (only focus indicator without color — ux-spec §4.3)")
    func focusBorderBold() {
        #expect(theme.tokens[.focusBorder]?.bold == true)
    }

    @Test("focusBg has no underline in NO_COLOR (cursor line indicated by ▶ gutter mark)")
    func focusBgPlainInNoColor() {
        // focus_bg is the cursor-line background; in NO_COLOR the ▶ gutter mark
        // is the sole indicator — no color modifier needed (ux-spec §6.6, §8.5).
        #expect(theme.tokens[.focusBg]?.underline == false)
    }

    // MARK: Non-semantic tokens are plain

    @Test("keyword has no modifiers in NO_COLOR (plain text is sufficient)")
    func keywordPlain() {
        let style = theme.tokens[.keyword]
        #expect(style?.bold == false)
        #expect(style?.italic == false)
        #expect(style?.underline == false)
    }

    @Test("dim has no modifiers in NO_COLOR")
    func dimPlain() {
        let style = theme.tokens[.dim]
        #expect(style?.bold == false)
        #expect(style?.italic == false)
        #expect(style?.underline == false)
    }
}

// MARK: - Override / additive model (ux-spec §8.4)

@Suite("ThemeEngine override model (ux-spec §8.4)")
struct ThemeEngineOverrideTests {

    @Test("Override single token replaces it while others inherit default")
    func singleOverridePreservesDefault() {
        let customRed = TokenStyle(fg: .rgb(0xFF, 0x00, 0x00))
        let state = ThemeEngine.resolve(capability: .truecolor, overrides: [.keyword: customRed])

        // Overridden token uses the custom value
        #expect(state.tokens[.keyword]?.fg == .rgb(0xFF, 0x00, 0x00))

        // Non-overridden tokens keep default values
        #expect(state.tokens[.string]?.fg == .rgb(0xF1, 0xFA, 0x8C))
        #expect(state.tokens[.error]?.fg == .rgb(0xFF, 0x55, 0x55))
    }

    @Test("Empty overrides produce standard default theme")
    func emptyOverridesProducesDefault() {
        let withOverrides = ThemeEngine.resolve(capability: .color256, overrides: [:])
        let direct = ThemeEngine.resolve(capability: .color256)
        #expect(withOverrides.tokens == direct.tokens)
    }

    @Test("Theme name is always 'default' for built-in theme")
    func themeNameAlwaysDefault() {
        let overrides: [ThemeToken: TokenStyle] = [.keyword: TokenStyle(fg: .rgb(0, 0, 0))]
        let state = ThemeEngine.resolve(capability: .truecolor, overrides: overrides)
        #expect(state.name == "default")
    }
}
