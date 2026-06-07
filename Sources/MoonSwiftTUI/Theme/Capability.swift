// File: Sources/MoonSwiftTUI/Theme/Capability.swift
// Location: MoonSwiftTUI/Theme/
// Role: Terminal color capability detection. Reads environment variables
//       following the detection order mandated by ux-spec.md §8.3 and
//       PRD §6.4/§6.6. The core logic accepts an environment dictionary
//       so it is testable without process-level I/O; a convenience wrapper
//       reads ProcessInfo.processInfo.environment for production use.
// Upstream: AppState (ColorCapability enum)
// Downstream: ThemeEngine (calls detectCapability to seed ThemeState)

import Foundation

// MARK: - Capability detection

/// Detects the terminal color capability tier from an environment dictionary.
///
/// Detection order (ux-spec.md §8.3 — binding):
/// 1. `NO_COLOR` set to any value (including the empty string) → `.noColor`.
/// 2. `COLORTERM` equals `"truecolor"` or `"24bit"` → `.truecolor`.
/// 3. `TERM` contains the substring `"256color"` → `.color256`.
/// 4. Default → `.color256` (safe for any modern terminal).
///
/// - Parameter environment: A string-keyed dictionary of environment variable
///   values. Pass `ProcessInfo.processInfo.environment` for production; pass a
///   hand-crafted dictionary in tests.
/// - Returns: The resolved `ColorCapability` for the given environment.
public func detectCapability(environment: [String: String]) -> ColorCapability {
    // Step 1: NO_COLOR overrides everything. The spec requires checking for the
    // key's presence, not its value — even an empty string activates NO_COLOR.
    // Reference: https://no-color.org
    if environment.keys.contains("NO_COLOR") {
        return .noColor
    }

    // Step 2: COLORTERM = "truecolor" or "24bit" signals full 24-bit support.
    if let colorterm = environment["COLORTERM"] {
        if colorterm == "truecolor" || colorterm == "24bit" {
            return .truecolor
        }
    }

    // Step 3: TERM containing "256color" signals indexed 256-color support.
    if let term = environment["TERM"], term.contains("256color") {
        return .color256
    }

    // Step 4: Safe default. Most modern terminals handle 256-color.
    return .color256
}

/// Detects the terminal color capability from the running process environment.
///
/// This is the production convenience wrapper over `detectCapability(environment:)`.
/// Use `detectCapability(environment:)` directly in tests.
///
/// - Returns: The resolved `ColorCapability` for the current process.
public func detectCapability() -> ColorCapability {
    return detectCapability(environment: ProcessInfo.processInfo.environment)
}
