// File: Tests/MoonSwiftTUITests/AppStateTUITests.swift
// Role: Smoke tests for MoonSwiftTUI — verifies that the module compiles and
//       that AppState is importable from the TUI target. No FFI is linked in
//       this test target (ARCHITECTURE.md §5.1 — EventSource protocol allows
//       scripted-event injection without the shim).
// Upstream: MoonSwiftTUI/App/AppState.swift
// Downstream: (test target — nothing imports this)

import Testing
@testable import MoonSwiftTUI

@Suite("MoonSwiftTUI skeleton")
struct MoonSwiftTUISkeletonTests {

    @Test("AppState is constructible from TUI target")
    func appStateInit() {
        let state = AppState()
        _ = state
    }
}
