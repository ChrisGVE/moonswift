// File: Sources/moonswift/Main.swift
// Role: Process entry point. Parses CLI arguments, installs signal handlers
//       (guarded no-ops until terminal init, ARCHITECTURE.md §3a/§3f),
//       loads the project file, initialises the terminal, constructs and
//       starts the AppDriver, maps termination to sysexits codes (PRD §4.7).
//       Contains no domain logic and no UI rendering.
// Upstream: CLIArguments.swift (parsed args), MoonSwiftTUI (AppDriver)
// Downstream: (process entry — nothing imports this target)

import Darwin
import MoonSwiftTUI

// The skeleton executable. Full implementation arrives in F1 (AppDriver
// bootstrap) and F2 (project-file load). Until then, the binary exits
// immediately with a placeholder message written to stderr (pre-TUI path —
// stdout is for future TUI use only).
@main
struct MoonSwift {
    static func main() {
        fputs("moonswift: skeleton build — TUI not yet initialised\n", stderr)
    }
}
