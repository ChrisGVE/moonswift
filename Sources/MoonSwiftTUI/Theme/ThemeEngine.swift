// File: Sources/MoonSwiftTUI/Theme/ThemeEngine.swift
// Location: MoonSwiftTUI/Theme/
// Role: ThemeEngine builds a resolved ThemeState from a named theme and
//       detected terminal capability. It is a pure, stateless transformer:
//       given a capability and an optional override map, it returns a fully
//       populated ThemeState ready for the Renderer.
//       One built-in theme "default" ships in P1; additional themes supply
//       only the tokens they override — missing tokens fall back to the
//       default (ux-spec §8.4 additive model).
// Upstream: Capability.swift (detectCapability), DefaultTheme.swift
//           (defaultTheme), AppState (ThemeState, TokenStyle, TerminalColor,
//           ColorCapability), AppEvent (ThemeToken)
// Downstream: AppDriver (calls ThemeEngine.resolve at startup to seed
//             AppState.theme), ThemeEngineTests

// MARK: - ThemeEngine

/// Resolves a named theme to a fully populated `ThemeState`.
///
/// Typical usage: call `ThemeEngine.resolve()` at app startup; the result is
/// stored in `AppState.theme` and never mutated by the reducer (themes are
/// resolved once, at startup, because capability detection requires the process
/// environment which is stable for the lifetime of the process).
///
/// Theme override model (ux-spec §8.4):
/// Additional themes are additive: they provide a partial `[ThemeToken: TokenStyle]`
/// table that is merged on top of the default. Tokens absent from the override
/// inherit the default-theme value. The built-in theme name is `"default"`.
public enum ThemeEngine {

    // MARK: Public interface

    /// Resolves the built-in "default" theme using the current process environment.
    ///
    /// This is the production entry point. The resolved `ThemeState` is stable
    /// for the process lifetime and should be computed once at startup.
    ///
    /// - Returns: A fully populated `ThemeState` for the running terminal.
    public static func resolve() -> ThemeState {
        let capability = detectCapability()
        return resolve(capability: capability)
    }

    /// Resolves the built-in "default" theme for a given capability tier.
    ///
    /// Useful when the capability was detected separately, or in tests where a
    /// specific tier must be exercised.
    ///
    /// - Parameter capability: The terminal color capability to resolve for.
    /// - Returns: A `ThemeState` with all 18 tokens populated for `capability`.
    public static func resolve(capability: ColorCapability) -> ThemeState {
        return resolve(capability: capability, overrides: [:])
    }

    /// Resolves a theme by merging caller-supplied overrides on top of the default.
    ///
    /// Intended for additional themes in P2+. An override entry replaces the
    /// corresponding default entry; tokens absent from `overrides` keep their
    /// default value.
    ///
    /// - Parameters:
    ///   - capability: The terminal color capability to resolve for.
    ///   - overrides: A partial token map that replaces default entries where present.
    /// - Returns: A merged `ThemeState` using `"default"` as the base.
    public static func resolve(
        capability: ColorCapability,
        overrides: [ThemeToken: TokenStyle]
    ) -> ThemeState {
        var tokens = defaultTheme(for: capability)
        for (token, style) in overrides {
            tokens[token] = style
        }
        return ThemeState(name: "default", capability: capability, tokens: tokens)
    }

    /// Detects capability from the given environment dictionary and resolves the theme.
    ///
    /// This is the testable seam: pass a hand-crafted environment dictionary
    /// to exercise the full pipeline (environment → capability → token table)
    /// without touching `ProcessInfo`.
    ///
    /// - Parameter environment: An environment variable dictionary.
    /// - Returns: A fully populated `ThemeState` for the capability implied by
    ///   the environment.
    public static func resolve(environment: [String: String]) -> ThemeState {
        let capability = detectCapability(environment: environment)
        return resolve(capability: capability)
    }
}
