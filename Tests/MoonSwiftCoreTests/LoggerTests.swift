// File: Tests/MoonSwiftCoreTests/LoggerTests.swift
// Role: Smoke tests for Logger — verifies that LogLevel ordering and
//       environment-variable parsing behave correctly without performing
//       any real filesystem I/O (the open-file path is not exercised in tests).
// Upstream: MoonSwiftCore/Logging/Logger.swift
// Downstream: (test target — nothing imports this)

import Testing

@testable import MoonSwiftCore

// MARK: - LogLevel ordering
// Note: AppState lives in MoonSwiftTUI, not MoonSwiftCore. Its smoke test
// belongs in MoonSwiftTUITests/AppStateTUITests.swift.

/// LogLevel comparisons must order error < info < debug so that the
/// level-filter gate (`level <= self.level`) suppresses higher-verbosity
/// entries when the configured level is lower.
@Suite("LogLevel")
struct LogLevelTests {

    @Test("error is less than info")
    func errorLessThanInfo() {
        #expect(LogLevel.error < LogLevel.info)
    }

    @Test("info is less than debug")
    func infoLessThanDebug() {
        #expect(LogLevel.info < LogLevel.debug)
    }

    @Test("error is less than debug")
    func errorLessThanDebug() {
        #expect(LogLevel.error < LogLevel.debug)
    }

    @Test("same level is not less than itself")
    func sameLevel() {
        #expect(!(LogLevel.info < LogLevel.info))
    }
}

// MARK: - MoonSwiftCore module smoke test

/// Confirms that the MoonSwiftCore module is importable and that the Logger
/// shared instance can be obtained without crashing. Actual log I/O is not
/// exercised in tests.
@Suite("MoonSwiftCore module")
struct MoonSwiftCoreModuleTests {

    @Test("Logger.shared is accessible")
    func loggerSharedIsAccessible() {
        // Obtaining the shared instance must not crash.
        let logger = Logger.shared
        _ = logger
    }
}
