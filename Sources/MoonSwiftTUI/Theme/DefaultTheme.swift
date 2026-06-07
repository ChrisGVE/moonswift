// File: Sources/MoonSwiftTUI/Theme/DefaultTheme.swift
// Location: MoonSwiftTUI/Theme/
// Role: Built-in "default" theme definition. Provides exact Dracula-derived
//       color values for all 18 semantic tokens in both truecolor (24-bit RGB)
//       and 256-color (palette index) tiers, and colorless NO_COLOR styles.
//       All values are normative per ux-spec.md §8.1 — do not change without
//       a spec revision. Additional themes follow the same structure and need
//       only supply the tokens they override (§8.4 additive model).
// Upstream: AppState (ThemeToken, TokenStyle, TerminalColor, ColorCapability)
// Downstream: ThemeEngine (calls defaultTheme(for:) to seed ThemeState)

// MARK: - ux-spec §8.1 token → ThemeToken mapping
//
// The ux-spec uses snake_case names; ThemeToken uses Swift camelCase.
// The mapping is 1:1 except for `operator` (reserved Swift keyword):
//
//   ux-spec name     ThemeToken case    Notes
//   keyword          .keyword           Lua keywords
//   string           .string            String literals
//   comment          .comment           Line/block comments
//   number           .number            Numeric literals
//   function_name    .functionName      Function/method declaration names
//   identifier       .identifier        Local vars, parameters, field access
//   operator         .operatorToken     Operators (operator is a reserved word)
//   error            .error             Error diagnostics, ✖ prefixes
//   warning          .warning           Warning diagnostics, ⚠ prefixes
//   added            .added             Picker marks (●), new items
//   focus_border     .focusBorder       Focused pane border, active tab underline
//   focus_bg         .focusBg           Cursor-line background; cursor-row ▶ gutter mark
//   highlight_bg     .highlightBg       Jump-target line background (persistent)
//   highlight_pulse  .highlightPulse    500 ms pulse animation start color
//   dim              .dim               Secondary labels, non-markable fields
//   running          .running           [running…] status indicator, spinner color
//   gutter_bg        .gutterBg          Gutter column background (line numbers)
//   pane_bg          .paneBg            Default pane content background + text

// MARK: - Accessibility contract (ux-spec §8.5)
//
// Color is never the sole carrier of meaning. Every color-coded semantic
// distinction has a paired character or shape marker:
//   - Diagnostics:       E/W prefix alongside error/warning color
//   - Missing-source:    ✖ prefix alongside error color
//   - Unresolved path:   ⚠ prefix alongside warning color
//   - Gutter marks:      E/W characters alongside color
//   - Focus:             Bold modifier alongside focus_border color;
//                        in NO_COLOR mode, Bold is the only indicator
//   - Active tab:        Underline modifier alongside focus_border color
//   - Running indicator: "[running…]" text alongside running color
//   - Picker marks:      ● character alongside added color
//
// NO_COLOR mode enforces this rule by definition — all color is removed and
// only character/shape markers and Bold remain.

// MARK: - defaultTheme(for:)

/// Returns the complete "default" token style table for the given capability.
///
/// Truecolor and 256-color tiers both cover all 18 tokens with Dracula-derived
/// palette values per ux-spec §8.1. NO_COLOR mode returns colorless styles;
/// severity-bearing tokens retain the Bold modifier so focus is still
/// distinguishable (ux-spec §8.3, §4.3).
///
/// - Parameter capability: The resolved terminal color capability.
/// - Returns: A complete `[ThemeToken: TokenStyle]` map for the "default" theme.
public func defaultTheme(for capability: ColorCapability) -> [ThemeToken: TokenStyle] {
    switch capability {
    case .truecolor:
        return truecolorTable
    case .color256:
        return color256Table
    case .noColor:
        return noColorTable
    }
}

// MARK: - Truecolor table (ux-spec §8.1 hex values, exact)

/// Token style table for 24-bit truecolor terminals.
///
/// Hex values are normative — they are Dracula-palette colors, perceptual-
/// contrast adjusted per ux-spec §8.1. Do not modify without a spec revision.
// swift-format-ignore
private let truecolorTable: [ThemeToken: TokenStyle] = [
    // Code syntax tokens
    .keyword:       TokenStyle(fg: .rgb(0xFF, 0x79, 0xC6)),          // #FF79C6 Dracula pink
    .string:        TokenStyle(fg: .rgb(0xF1, 0xFA, 0x8C)),          // #F1FA8C Dracula yellow
    .comment:       TokenStyle(fg: .rgb(0x62, 0x72, 0xA4), italic: true), // #6272A4 Dracula comment
    .number:        TokenStyle(fg: .rgb(0xBD, 0x93, 0xF9)),          // #BD93F9 Dracula purple
    .functionName:  TokenStyle(fg: .rgb(0x50, 0xFA, 0x7B)),          // #50FA7B Dracula green
    .identifier:    TokenStyle(fg: .rgb(0xF8, 0xF8, 0xF2)),          // #F8F8F2 Dracula foreground
    .operatorToken: TokenStyle(fg: .rgb(0xFF, 0x79, 0xC6)),          // #FF79C6 same as keyword
    // Diagnostic / status tokens
    .error:         TokenStyle(fg: .rgb(0xFF, 0x55, 0x55)),          // #FF5555 Dracula red
    .warning:       TokenStyle(fg: .rgb(0xFF, 0xB8, 0x6C)),          // #FFB86C Dracula orange
    .added:         TokenStyle(fg: .rgb(0x50, 0xFA, 0x7B)),          // #50FA7B Dracula green (same as functionName)
    // UI chrome tokens
    .focusBorder:   TokenStyle(fg: .rgb(0xBD, 0x93, 0xF9)),          // #BD93F9 Dracula purple
    .focusBg:       TokenStyle(bg: .rgb(0x44, 0x47, 0x5A)),          // #44475A Dracula selection (cursor-line bg)
    .highlightBg:   TokenStyle(bg: .rgb(0x3D, 0x44, 0x55)),          // #3D4455 jump-target line bg
    .highlightPulse: TokenStyle(bg: .rgb(0x62, 0x72, 0xA4)),         // #6272A4 Dracula comment blue (pulse start)
    .dim:           TokenStyle(fg: .rgb(0x62, 0x72, 0xA4)),          // #6272A4 Dracula comment
    .running:       TokenStyle(fg: .rgb(0x8B, 0xE9, 0xFD)),          // #8BE9FD Dracula cyan (running indicator)
    .gutterBg:      TokenStyle(bg: .rgb(0x28, 0x2A, 0x36)),          // #282A36 Dracula bg (gutter column)
    .paneBg:        TokenStyle(fg: .rgb(0xF8, 0xF8, 0xF2), bg: .rgb(0x28, 0x2A, 0x36)), // #F8F8F2 fg / #282A36 bg
]

// MARK: - 256-color table (ux-spec §8.1 palette indices, exact)

/// Token style table for indexed 256-color terminals.
///
/// Palette indices are normative — chosen for maximum perceptual contrast
/// against pane background on a standard 256-color terminal per ux-spec §8.1.
// swift-format-ignore
private let color256Table: [ThemeToken: TokenStyle] = [
    // Code syntax tokens
    .keyword:       TokenStyle(fg: .index(212)),    // medium pink
    .string:        TokenStyle(fg: .index(228)),    // light yellow
    .comment:       TokenStyle(fg: .index(61), italic: true),  // muted blue-purple
    .number:        TokenStyle(fg: .index(141)),    // soft purple
    .functionName:  TokenStyle(fg: .index(84)),     // bright green
    .identifier:    TokenStyle(fg: .index(255)),    // near-white
    .operatorToken: TokenStyle(fg: .index(212)),    // medium pink (same as keyword)
    // Diagnostic / status tokens
    .error:         TokenStyle(fg: .index(203)),    // bright red
    .warning:       TokenStyle(fg: .index(215)),    // soft orange
    .added:         TokenStyle(fg: .index(84)),     // bright green (same as functionName)
    // UI chrome tokens
    .focusBorder:   TokenStyle(fg: .index(141)),    // soft purple
    .focusBg:       TokenStyle(bg: .index(237)),    // dark gray (cursor-line bg)
    .highlightBg:   TokenStyle(bg: .index(238)),    // slightly lighter gray (jump-target bg)
    .highlightPulse: TokenStyle(bg: .index(61)),   // muted blue-purple (pulse start)
    .dim:           TokenStyle(fg: .index(61)),     // muted blue-purple
    .running:       TokenStyle(fg: .index(117)),    // light cyan (running indicator)
    .gutterBg:      TokenStyle(bg: .index(236)),    // very dark gray (gutter column)
    .paneBg:        TokenStyle(fg: .index(255), bg: .index(235)), // near-white fg / dark gray bg
]

// MARK: - NO_COLOR table (ux-spec §8.3, §4.3)

/// Token style table for NO_COLOR mode.
///
/// All foreground and background colors are suppressed. Meaning is conveyed
/// entirely through character markers paired with Bold modifiers for focus
/// indicators (ux-spec §8.5 accessibility rule — color alone is never the
/// sole carrier of meaning).
///
/// NO_COLOR compliance reference: https://no-color.org
// swift-format-ignore
private let noColorTable: [ThemeToken: TokenStyle] = [
    // Code syntax tokens: no color; text reads as plain terminal default
    .keyword:        TokenStyle(),
    .string:         TokenStyle(),
    .comment:        TokenStyle(),
    .number:         TokenStyle(),
    .functionName:   TokenStyle(),
    .identifier:     TokenStyle(),
    .operatorToken:  TokenStyle(),
    // Diagnostic / status tokens: Bold on severity markers (E/W chars always present)
    .error:          TokenStyle(bold: true),    // E-prefix char is the primary marker
    .warning:        TokenStyle(bold: true),    // W-prefix char is the primary marker
    .added:          TokenStyle(),              // ● char is the marker
    // UI chrome tokens: Bold for focus (the only focus indicator in NO_COLOR)
    .focusBorder:    TokenStyle(bold: true),    // Bold border signals focus (ux-spec §4.3)
    .focusBg:        TokenStyle(),              // Cursor-line bg: ▶ gutter mark is the indicator
    .highlightBg:    TokenStyle(),
    .highlightPulse: TokenStyle(),
    .dim:            TokenStyle(),
    .running:        TokenStyle(),              // [running…] text is the marker
    .gutterBg:       TokenStyle(),
    .paneBg:         TokenStyle(),
]
