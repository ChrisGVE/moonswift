// File: Tests/MoonSwiftTUITests/DriverIntegrationTests.swift
// Location: MoonSwiftTUITests/
// Role: End-to-end integration tests proving the AppDriver actually DISPATCHES
//       engine effects to the injected MoonSwiftCore services (CR-001 wiring).
//       Before this wiring, Effect.run/.lint were production no-ops; these tests
//       lock in that a real RunServiceProtocol / LintServiceProtocol is invoked
//       with the correct fragment when the user presses `r` / `l`.
//
//       Observation strategy: the AppDriver consumes events from the EventChannel
//       in its own run loop, so a test CANNOT observe the driver's internal
//       events by draining that same channel. Instead we inject SPY services and
//       assert on the spy (a thread-safe object the driver calls), which is the
//       true seam being verified. Real Lua execution itself is covered separately
//       by RunServiceTests / LintServiceTests; here we verify only the wiring.
//
// Construction pattern follows AppDriverEditorTests.swift: ScriptedEventSource /
// EventPump / EventChannel / TickSource, no FFI, no real TTY. The driver loop
// runs on a background Thread; the test thread posts key events and polls the
// spy with a generous deadline (CI runners starve threads — see handover).
//
// Upstream: AppDriver.swift, RunService.swift (RunServiceProtocol),
//           LintService.swift (LintServiceProtocol), EventChannel/Pump/Tick
// Downstream: (test target only)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing
import os

@testable import MoonSwiftTUI

// MARK: - Test fragment helper

/// Assembles a minimal `LuaSourceFragment` with a synthetic provenance.
private func makeDriverTestFragment(
    code: String,
    path: String = "/tests/driver_integration.lua"
) -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
    let data = Data(code.utf8)
    let provenance = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    return LuaSourceFragment(code: code, provenance: provenance)
}

// MARK: - Spy services

/// Records the fragment the driver dispatched to `run`, without executing Lua.
private final class SpyRunService: RunServiceProtocol, @unchecked Sendable {
    private let storedCode = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The `code` of the fragment passed to the most recent `run`, or nil.
    var capturedCode: String? { storedCode.withLock { $0 } }

    func run(
        _ fragment: LuaSourceFragment,
        config: RunConfig,
        output: @escaping @Sendable (String) -> Void
    ) async -> CoreRunOutcome {
        storedCode.withLock { $0 = fragment.code }
        // Emit one output line to exercise the Coalescer round-trip, then finish.
        output("spy-line")
        return .done(value: "spy-ok", duration: .zero)
    }

    func cancel() {}
}

/// Records the fragment the driver dispatched to `lint`, without running luacheck.
private final class SpyLintService: LintServiceProtocol, @unchecked Sendable {
    private let storedLintCode = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The `code` of the fragment passed to the most recent `lint`, or nil.
    var capturedLintCode: String? { storedLintCode.withLock { $0 } }

    func syntaxPrePass(_ fragment: LuaSourceFragment) -> Diagnostic? { nil }

    func lint(
        _ fragment: LuaSourceFragment,
        knownGlobals: [String: Any]
    ) async throws -> [Diagnostic] {
        storedLintCode.withLock { $0 = fragment.code }
        return []
    }

    func prewarm(
        onReady: @escaping @Sendable () -> Void,
        onCatalogProbed: @escaping @Sendable (_ tomlAvailable: Bool) -> Void,
        onFailed: @escaping @Sendable (_ message: String) -> Void
    ) async {
        // Report ready so the reducer leaves the initializing state.
        onReady()
        onCatalogProbed(false)
    }
}

// MARK: - Helpers

/// A seed AppState with one loaded, selected source and an idle lint engine —
/// the minimal state in which `r` produces `.run` and `l` produces `.lint`.
private func readyToRunSeed(code: String) -> AppState {
    let id = SourceID(path: "driver_integration.lua")
    let fragment = makeDriverTestFragment(code: code)
    return AppState(
        sources: [id: .loaded(fragment)],
        navigatorOrder: [id],
        selection: id,
        runState: .idle,
        lintState: .idle
    )
}

/// Polls `predicate` until true or `timeout` elapses. Returns the final value.
private func waitUntil(timeout: TimeInterval = 5.0, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return predicate()
}

// MARK: - Tests

@Suite("DriverIntegration — engine effects dispatch to services")
struct DriverIntegrationTests {

    @Test("r dispatches Effect.run to the injected RunService with the selected fragment")
    func runDispatchedToService() {
        let channel = EventChannel()
        let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
        let tick = TickSource(channel: channel)
        let spy = SpyRunService()
        let seed = readyToRunSeed(code: "print('hi'); return 1")

        let driver = AppDriver(
            channel: channel,
            pump: pump,
            tickSource: tick,
            seed: seed,
            runService: spy
        )

        let driverThread = Thread { _ = driver.run() }
        driverThread.start()

        // Let the driver boot and process .appStarted before pressing a key.
        Thread.sleep(forTimeInterval: 0.1)
        channel.post(.key(.char("r"), modifiers: []))

        let dispatched = waitUntil { spy.capturedCode != nil }

        // Quit cleanly so the driver thread exits.
        channel.post(.key(.char("q"), modifiers: []))
        Thread.sleep(forTimeInterval: 0.2)
        pump.stop()
        tick.stop()

        #expect(dispatched, "RunService.run was never invoked after pressing r")
        #expect(
            spy.capturedCode == "print('hi'); return 1",
            "RunService received the wrong fragment: \(String(describing: spy.capturedCode))"
        )
    }

    /// CR-019: EventPump posts resize(0,0) when the terminal I/O source throws.
    /// The AppDriver must exit its run loop immediately (clean quit, code 0) rather
    /// than looping forever on an unresponsive channel.
    @Test("resize(0,0) sentinel causes driver to exit cleanly (CR-019)")
    func zeroSizeResizeCausesCleanQuit() {
        let channel = EventChannel()
        let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
        let tick = TickSource(channel: channel)
        let seed = AppState()

        let driver = AppDriver(
            channel: channel,
            pump: pump,
            tickSource: tick,
            seed: seed
        )

        let exitCode = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let driverThread = Thread {
            let code = driver.run()
            exitCode.withLock { $0 = code }
        }
        driverThread.start()

        // Let the driver boot.
        Thread.sleep(forTimeInterval: 0.1)
        // Post the zero-size sentinel that EventPump emits on I/O error.
        channel.post(.resize(TerminalSize(cols: 0, rows: 0)))

        // The driver must exit within a generous deadline.
        let exited = waitUntil(timeout: 3.0) { exitCode.withLock { $0 } != nil }
        pump.stop()
        tick.stop()

        #expect(exited, "Driver must exit when resize(0,0) sentinel is posted (was hanging)")
        #expect(exitCode.withLock { $0 } == 0, "Clean EOF must produce exit code 0")
    }

    @Test("l dispatches Effect.lint to the injected LintService with the selected fragment")
    func lintDispatchedToService() {
        let channel = EventChannel()
        let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
        let tick = TickSource(channel: channel)
        let spy = SpyLintService()
        let seed = readyToRunSeed(code: "return undefined_global")

        let driver = AppDriver(
            channel: channel,
            pump: pump,
            tickSource: tick,
            seed: seed,
            lintService: spy
        )

        let driverThread = Thread { _ = driver.run() }
        driverThread.start()

        Thread.sleep(forTimeInterval: 0.1)
        channel.post(.key(.char("l"), modifiers: []))

        let dispatched = waitUntil { spy.capturedLintCode != nil }

        channel.post(.key(.char("q"), modifiers: []))
        Thread.sleep(forTimeInterval: 0.2)
        pump.stop()
        tick.stop()

        #expect(dispatched, "LintService.lint was never invoked after pressing l")
        #expect(
            spy.capturedLintCode == "return undefined_global",
            "LintService received the wrong fragment: \(String(describing: spy.capturedLintCode))"
        )
    }
}
