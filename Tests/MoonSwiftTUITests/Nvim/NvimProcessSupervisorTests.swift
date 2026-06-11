// File: Tests/MoonSwiftTUITests/Nvim/NvimProcessSupervisorTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Unit tests for NvimProcessSupervisor.probe() — verifying the nvim
//       discovery logic (search order, NVIM_PATH validation, version parsing)
//       and spawn failure behaviour.
//
// Architecture context (ARCHITECTURE.md §10.4.5):
//   NvimProcessSupervisor owns the nvim child process. probe() must return nil
//   when nvim is absent, too old (< 0.9), or not executable; it must accept a
//   valid NVIM_PATH override and reject a relative or non-executable one.
//   A testability seam (probe(environment:fileManager:versionProbe:)) lets
//   every path run in CI without a real nvim installation.
//
// Relationships:
//   → NvimProcessSupervisor.swift: the type under test
//   → MsgpackRPCFramer.swift:      unrelated (different inc); no dependency

import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Helpers

/// A minimal fake FileManager predicate used in tests.
///
/// `executablePaths` is the set of paths for which `isExecutableFile` returns
/// true; all others return false. `existsPaths` defaults to `executablePaths`
/// (a non-executable file that doesn't exist is irrelevant), but tests that
/// want to distinguish "file exists but not executable" can supply both sets.
private struct FakeFileManager {
    let existsPaths: Set<String>
    let executablePaths: Set<String>

    init(executable: Set<String>, exists: Set<String>? = nil) {
        executablePaths = executable
        existsPaths = exists ?? executable
    }
}

/// A fake version reader: returns a version string for known paths, nil for
/// unknown ones (simulating an exec-failure or unexpected output format).
private typealias FakeVersionProbe = (String) -> String?

// MARK: - Probe tests

@Suite("NvimProcessSupervisor.probe()")
struct NvimProcessSupervisorProbeTests {

    // MARK: Absent nvim

    @Test("returns nil when no nvim candidate exists anywhere")
    func probeReturnsNilWhenAbsent() {
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { _ in false },
            fileExists: { _ in false },
            versionProbe: { _ in nil }
        )
        #expect(result == nil)
    }

    // MARK: Version gate

    @Test("returns nil when the only candidate is version 0.8")
    func probeReturnsNilForTooOldVersion() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "NVIM v0.8.3" }
        )
        #expect(result == nil)
    }

    @Test("returns nil when the only candidate is version 0.0")
    func probeReturnsNilForVersionZero() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "NVIM v0.0.0" }
        )
        #expect(result == nil)
    }

    @Test("accepts version exactly 0.9")
    func probeAcceptsVersionZeroNine() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result != nil)
        #expect(result?.path == path)
        #expect(result?.version.0 == 0)
        #expect(result?.version.1 == 9)
    }

    @Test("accepts version 0.10")
    func probeAcceptsVersionZeroTen() {
        let path = "/usr/local/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "NVIM v0.10.2" }
        )
        #expect(result != nil)
        #expect(result?.version.1 == 10)
    }

    @Test("accepts version 1.0")
    func probeAcceptsVersionOne() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "NVIM v1.0.0" }
        )
        #expect(result != nil)
        #expect(result?.version.0 == 1)
        #expect(result?.version.1 == 0)
    }

    // MARK: Non-executable

    @Test("returns nil when candidate exists but is not executable")
    func probeReturnsNilForNonExecutable() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { _ in false },  // not executable
            fileExists: { $0 == path },  // file exists
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result == nil)
    }

    // MARK: NVIM_PATH override — accepted

    @Test("NVIM_PATH accepted when absolute and executable")
    func probeAcceptsAbsoluteExecutableNvimPath() {
        let customPath = "/custom/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: ["NVIM_PATH": customPath],
            isExecutableFile: { $0 == customPath },
            fileExists: { $0 == customPath },
            versionProbe: { _ in "NVIM v0.9.5" }
        )
        #expect(result != nil)
        #expect(result?.path == customPath)
    }

    // MARK: NVIM_PATH override — rejected

    @Test("NVIM_PATH ignored when relative path; falls through to normal search")
    func probeIgnoresRelativeNvimPath() {
        let relativePath = "bin/nvim"
        let fallback = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: ["NVIM_PATH": relativePath],
            isExecutableFile: { $0 == fallback },
            fileExists: { $0 == fallback },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        // The relative path must be skipped; the fallback must be picked up.
        #expect(result != nil)
        #expect(result?.path == fallback)
    }

    @Test("NVIM_PATH ignored when path is not executable; falls through")
    func probeIgnoresNonExecutableNvimPath() {
        let badPath = "/custom/bin/nvim"
        let fallback = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: ["NVIM_PATH": badPath],
            isExecutableFile: { $0 == fallback },  // only fallback is executable
            fileExists: { $0 == badPath || $0 == fallback },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result != nil)
        #expect(result?.path == fallback)
    }

    @Test("NVIM_PATH ignored when file does not exist; falls through")
    func probeIgnoresMissingNvimPath() {
        let missingPath = "/does/not/exist/nvim"
        let fallback = "/opt/local/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: ["NVIM_PATH": missingPath],
            isExecutableFile: { $0 == fallback },
            fileExists: { $0 == fallback },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result != nil)
        #expect(result?.path == fallback)
    }

    // MARK: Search order

    @Test("homebrew Apple Silicon path takes priority over Intel path")
    func probeSearchOrderAppleSiliconFirst() {
        let asSilicon = "/opt/homebrew/bin/nvim"
        let intel = "/usr/local/bin/nvim"
        // Both are executable; Apple Silicon must win.
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == asSilicon || $0 == intel },
            fileExists: { $0 == asSilicon || $0 == intel },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result?.path == asSilicon)
    }

    @Test("falls through to Intel path when Apple Silicon absent")
    func probeSearchOrderIntelFallback() {
        let intel = "/usr/local/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == intel },
            fileExists: { $0 == intel },
            versionProbe: { _ in "NVIM v0.9.1" }
        )
        #expect(result?.path == intel)
    }

    @Test("MacPorts path used when Homebrew absent")
    func probeSearchOrderMacPortsFallback() {
        let macports = "/opt/local/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == macports },
            fileExists: { $0 == macports },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result?.path == macports)
    }

    @Test("PATH component used when all well-known paths absent")
    func probeSearchOrderPathFallback() {
        let customDir = "/some/custom/dir"
        let customNvim = "/some/custom/dir/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: ["PATH": customDir],
            isExecutableFile: { $0 == customNvim },
            fileExists: { $0 == customNvim },
            versionProbe: { _ in "NVIM v0.9.0" }
        )
        #expect(result?.path == customNvim)
    }

    // MARK: Version string parsing edge cases

    @Test("returns nil when version string cannot be parsed")
    func probeReturnsNilForUnparsableVersion() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in "something unexpected" }
        )
        #expect(result == nil)
    }

    @Test("returns nil when versionProbe returns nil (exec failure)")
    func probeReturnsNilWhenVersionProbeFails() {
        let path = "/opt/homebrew/bin/nvim"
        let result = NvimProcessSupervisor.probe(
            environment: [:],
            isExecutableFile: { $0 == path },
            fileExists: { $0 == path },
            versionProbe: { _ in nil }
        )
        #expect(result == nil)
    }
}

// MARK: - Spawn tests

@Suite("NvimProcessSupervisor.spawn()")
struct NvimProcessSupervisorSpawnTests {

    @Test("spawn throws when executable path does not exist")
    func spawnThrowsForMissingPath() {
        let supervisor = NvimProcessSupervisor()
        // A path that definitely does not exist on any CI machine.
        #expect(throws: CocoaError.self) {
            try supervisor.spawn(path: "/nonexistent/nvim-missing-12345") { _ in }
        }
    }
}
