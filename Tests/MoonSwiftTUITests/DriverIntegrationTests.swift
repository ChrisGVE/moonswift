// File: Tests/MoonSwiftTUITests/DriverIntegrationTests.swift
// Location: MoonSwiftTUITests/
// Role: End-to-end integration tests proving the AppDriver actually DISPATCHES
//       engine effects to the injected MoonSwiftCore services (CR-001 wiring).
//       Before this wiring, Effect.run/.lint were production no-ops; these tests
//       lock in that a real RunServiceProtocol / LintServiceProtocol is invoked
//       with the correct fragment when the user presses `r` / `l`.
//
//       Also covers saveDesignations wiring (fix-1): verifies that when the
//       picker saves designations for a source entry that has ZERO prior fields
//       the new fields are actually persisted to the project file on disk
//       (the pre-fix field-overlap strategy silently no-oped in this case).
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
///
/// Default timeout is 30 s — generous enough to absorb CI thread starvation on
/// x86_64 runners where Swift Testing's parallel pool delays async work well past
/// the original 5 s budget. The suite is also marked `.serialized` so tests do
/// not compete with each other for threads, but keeping a large ceiling here
/// ensures a single isolated test still passes under heavy system load.
private func waitUntil(timeout: TimeInterval = 30.0, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return predicate()
}

// MARK: - Tests

// .serialized prevents tests in this suite from running in parallel with each
// other or with the cooperative-thread-pool tasks they spawn. Under CI thread
// starvation the 5 s timeout was routinely exceeded when the suite competed with
// other parallel test tasks; serialisation keeps the background Thread and async
// spy within budget.
@Suite("DriverIntegration — engine effects dispatch to services", .serialized)
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

    /// Fix-1 regression guard: when the picker saves designations for a source entry
    /// that has ZERO prior fields, the new designations must actually be written to
    /// moonswift.toml. The pre-fix applyDesignations used field-overlap matching and
    /// silently no-oped when existingPaths was empty.
    ///
    /// Strategy: seed the driver with the project loaded and a picker open with a
    /// real PickerTree (so `s` is active) and two marks. Press `s` and poll the
    /// project file on disk until the designations appear (or 30 s timeout).
    @Test("saveDesignations with zero prior fields persists fields to project file")
    func saveDesignationsZeroPriorFieldsPersists() throws {
        // Create a temporary project directory with moonswift.toml containing
        // a JSON source entry that has no field designations.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a minimal JSON file that the picker will browse.
        let jsonContent = """
            {"host": "localhost", "port": "8080"}
            """
        let jsonPath = tmpDir.appendingPathComponent("data.json")
        try jsonContent.write(to: jsonPath, atomically: true, encoding: .utf8)

        // Write moonswift.toml with one source entry (data.json) with no fields.
        let sourceEntry = SourceEntry(path: "data.json")
        let projectFile = ProjectFile(luaVersion: "5.4", sources: [sourceEntry])
        let tomlURL = tmpDir.appendingPathComponent(ProjectStore.fileName)
        try ProjectStore.save(projectFile, to: tomlURL)

        // Build a PickerTree from the JSON so that `s` is active (the picker
        // reducer requires a non-nil tree to process the save key).
        // The JSON is a flat map with two string values; PickerTree.init already
        // shows the string fields at depth 0 without any explicit expansion.
        let tree = try decodeJSON(jsonContent)
        let pickerTree = PickerTree(root: tree)
        // Normalized paths for the two string keys.
        let hostPath = pickerNormalizedPath(steps: [.key("host")])
        let portPath = pickerNormalizedPath(steps: [.key("port")])

        let sourceID = SourceID(path: "data.json")
        let pickerSt = PickerState(
            sourceID: sourceID,
            filePath: "data.json",
            tree: pickerTree,
            parseError: nil,
            cursorRow: 0,
            marks: [hostPath, portPath],
            preExistingMarks: [],
            awaitingDiscardConfirmation: false
        )

        var seed = AppState()
        seed.launch = .project(tmpDir)
        seed.project = .loaded(projectFile, diagnostics: [])
        seed.pickerState = pickerSt
        seed.focus = .pickerModal
        seed.lintState = .idle  // avoid prewarm side effects in this test

        // Wire a real SourceStore (callback posts events back to the channel).
        let channel = EventChannel()
        let pump = EventPump(source: ScriptedEventSource([]), channel: channel)
        let tick = TickSource(channel: channel)
        let store = SourceStore { event in
            switch event {
            case .loaded(let id, let fragment):
                channel.post(.sourceLoaded(id: id, fragment: fragment))
            case .failed(let id, let state):
                channel.post(.sourceFailed(id: id, state: state))
            }
        }

        let driver = AppDriver(
            channel: channel,
            pump: pump,
            tickSource: tick,
            seed: seed,
            sourceStore: store
        )

        let driverThread = Thread { _ = driver.run() }
        driverThread.start()

        // Let the driver process .appStarted before pressing the picker key.
        Thread.sleep(forTimeInterval: 0.15)
        // Press 's' to save the current picker marks via the picker reducer arm.
        channel.post(.key(.char("s"), modifiers: []))

        // Wait for the file to be updated on disk. ProjectStore.load is non-throwing.
        let fileUpdated = waitUntil(timeout: 30.0) {
            let result = ProjectStore.load(at: tmpDir)
            guard case .loaded(let pf, _) = result else { return false }
            return pf.sources.first?.fields.isEmpty == false
        }

        // Quit the driver cleanly.
        channel.post(.key(.char("q"), modifiers: []))
        Thread.sleep(forTimeInterval: 0.2)
        pump.stop()
        tick.stop()

        #expect(fileUpdated, "designations must be persisted even when the entry had no prior fields")

        // Decode the saved file and assert the exact fields.
        let savedResult = ProjectStore.load(at: tmpDir)
        guard case .loaded(let savedFile, _) = savedResult else {
            Issue.record("Could not reload saved project file")
            return
        }
        let savedFields = savedFile.sources.first(where: { $0.path == "data.json" })?.fields ?? []
        let savedPaths = Set(savedFields.map(\.jsonpath))
        #expect(
            savedPaths == [hostPath, portPath],
            "both designated fields must be present in saved file; got \(savedPaths)"
        )
    }
}
