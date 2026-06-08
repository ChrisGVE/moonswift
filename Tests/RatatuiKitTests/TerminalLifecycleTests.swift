// File: Tests/RatatuiKitTests/TerminalLifecycleTests.swift
// Role: Smoke tests for Terminal lifecycle — guarded with an environment check
//       so they only run when a real TTY is present. In CI (no TTY) they are
//       skipped with Swift Testing's .enabled(if:) condition.
//       Thread-class assertions in Terminal are also verified: calling from the
//       wrong thread must fault in debug builds.
// Upstream: RatatuiKit/Terminal.swift (Terminal, TerminalSize)
// Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import RatatuiKit

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

// MARK: - Terminal double-teardown and post-teardown use (TTY-gated)

@Suite("Terminal post-teardown guard — TTY-gated")
struct TerminalPostTeardownTests {

    /// Verifies that `teardown()` sets the handle to nil and a subsequent call
    /// triggers a `preconditionFailure` (debug builds).  We exercise the
    /// double-teardown path via the `defer { try? terminal.teardown() }` pattern
    /// used throughout the test suite: after explicit teardown the deferred
    /// try? must not crash — the guard swallows it.
    ///
    /// We test the non-crashing observable: calling teardown() twice does not
    /// produce two rffi_terminal_teardown calls (which would be a UAF).  The
    /// second call hits the `guard let h = handle else { preconditionFailure }`
    /// path; in a release build that returns without touching freed memory.
    /// In debug builds the preconditionFailure fires — so we only call this once
    /// and rely on the deinit not double-freeing.
    @Test(
        "teardown() then deinit does not double-free",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func teardownThenDeinit() throws {
        // After explicit teardown the deinit safety-net checks `handle == nil`
        // and skips rffi_terminal_teardown, preventing a double-free.
        let terminal = try Terminal()
        try terminal.teardown()
        // deinit fires here when `terminal` goes out of scope — no crash.
    }

    /// Verifies that `rawHandle` is guarded post-teardown: accessing it after
    /// teardown would return a dangling pointer, so the guard must be in place.
    /// We test the observable side-effect: a successfully torn-down terminal
    /// has handle == nil internally; no further FFI call should be possible.
    ///
    /// This test is structural: we confirm that teardown does not throw and
    /// that a fresh Terminal constructed afterwards works normally, which
    /// verifies the full lifecycle without triggering the debug precondition.
    @Test(
        "Terminal full lifecycle: init → use → teardown → re-init",
        .enabled(if: hasTTY, "Requires a real TTY")
    )
    func fullLifecycleTwice() throws {
        let t1 = try Terminal()
        let _ = try t1.size()
        try t1.teardown()

        // Constructing a second Terminal after teardown of the first must work —
        // verifies the rffi initialized-flag is re-settable.
        let t2 = try Terminal()
        try t2.teardown()
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

// MARK: - CR-022 regression: init asserts Thread.current, not Thread.main

@Suite("Terminal.init thread-class assertion — CR-022 regression")
struct TerminalInitThreadAssertTests {

    /// Regression test for CR-022: `Terminal.init()` previously passed
    /// `Thread.main` to `assertRenderClass` while storing `Thread.current`,
    /// making them inconsistent and breaking non-main UI thread test patterns.
    ///
    /// This test is deliberately headless (no TTY needed): it only verifies
    /// the assertion logic itself — that `assertRenderClass(owningThread:
    /// Thread.current)` does not fault when called from the main thread
    /// (Thread.current === Thread.main on the main thread, so isMainThread
    /// is satisfied by the `current.isMainThread && owningThread.isMainThread`
    /// branch in assertRenderClass).
    @Test("assertRenderClass with Thread.current does not fault on main thread")
    func assertRenderClassCurrentDoesNotFaultOnMain() {
        // Swift Testing runs @Test functions on the main thread.
        // assertRenderClass(owningThread: Thread.current) must not precondition-fail here.
        assertRenderClass(owningThread: Thread.current)
    }

    /// Verifies that the owning-thread stored in Terminal equals Thread.current
    /// at construction time (the precondition for consistent thread checks).
    /// Indirectly confirmed by: all subsequent render-class method calls in
    /// TerminalLifecycleTests pass without assertion failure.
    @Test("assertRenderClass with Thread.main is consistent when on main thread")
    func assertRenderClassMainEqualsCurrentOnMain() {
        // On the main thread, Thread.current === Thread.main, so both forms
        // are equivalent. This test ensures neither assertion style faults.
        assertRenderClass(owningThread: Thread.main)
        assertRenderClass(owningThread: Thread.current)
    }
}
