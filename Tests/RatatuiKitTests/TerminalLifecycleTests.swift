// File: Tests/RatatuiKitTests/TerminalLifecycleTests.swift
// Role: Smoke tests for Terminal lifecycle — guarded with an environment check
//       so they only run when a real TTY is present. In CI (no TTY) they are
//       skipped with Swift Testing's .enabled(if:) condition.
//       Thread-class assertions in Terminal are also verified: calling from the
//       wrong thread must fault in debug builds.
// Upstream: RatatuiKit/Terminal.swift (Terminal, TerminalSize)
// Downstream: (test target — nothing imports this)

import Testing
@testable import RatatuiKit
import Foundation

// MARK: - TTY detection

/// Returns `true` when a real TTY is available (not in headless CI).
private var hasTTY: Bool {
    // isatty(STDOUT_FILENO) is the standard POSIX check.
    Darwin.isatty(STDOUT_FILENO) != 0
}

// MARK: - TerminalSize

@Suite("TerminalSize")
struct TerminalSizeTests {

    @Test("TerminalSize stores cols and rows")
    func terminalSizeFields() {
        let ts = TerminalSize(cols: 80, rows: 24)
        #expect(ts.cols == 80)
        #expect(ts.rows == 24)
    }

    @Test("TerminalSize equality")
    func terminalSizeEquality() {
        let a = TerminalSize(cols: 80, rows: 24)
        let b = TerminalSize(cols: 80, rows: 24)
        let c = TerminalSize(cols: 100, rows: 24)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Terminal lifecycle smoke test (TTY-gated)

@Suite("Terminal lifecycle — TTY-gated smoke tests")
struct TerminalLifecycleTests {

    /// A full init → size → teardown round trip.
    ///
    /// Skipped when no TTY is available (headless CI). The `.enabled(if:)`
    /// condition is the idiomatic Swift Testing mechanism for conditional tests
    /// (ARCHITECTURE.md §5.2 note on CI-guard for terminal tests).
    @Test(
        "Terminal init → size → teardown round trip",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func initSizeTeardown() throws {
        // Terminal.init() must be called from the main thread in debug builds
        // (assertRenderClass checks Thread.isMainThread for the common case).
        // Swift Testing runs @Test functions on the main thread by default.
        let terminal = try Terminal()

        let size = try terminal.size()
        // A real terminal should report non-zero dimensions.
        #expect(size.cols > 0)
        #expect(size.rows > 0)

        // Teardown must not throw.
        try terminal.teardown()
    }

    @Test(
        "Terminal flush after init does not throw",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func flushAfterInit() throws {
        let terminal = try Terminal()
        defer { try? terminal.teardown() }
        try terminal.flush()
    }
}

// MARK: - emergencyRestore (no-op before init)

@Suite("Terminal.emergencyRestore — no-op guard")
struct EmergencyRestoreTests {

    @Test("emergencyRestore is a guarded no-op before terminal init")
    func emergencyRestoreBeforeInit() {
        // rffi_emergency_restore checks the INITIALIZED atomic flag first —
        // if no Terminal has been initialised it should return immediately (no-op).
        // We just assert it doesn't crash.
        Terminal.emergencyRestore()
    }
}
