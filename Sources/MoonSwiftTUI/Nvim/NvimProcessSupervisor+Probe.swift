// File: Sources/MoonSwiftTUI/Nvim/NvimProcessSupervisor+Probe.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: nvim binary discovery for NvimProcessSupervisor. Contains the probe
//       result type, the two probe() overloads (public + testability seam),
//       and the static version-parsing / version-probe helpers. Extracted from
//       NvimProcessSupervisor.swift to keep both files within the 400-line cap.
//
// Architecture context (ARCHITECTURE.md §10.4.5):
//   Probe priority order:
//     1. NVIM_PATH env var  (absolute, executable)
//     2. /opt/homebrew/bin/nvim  (Apple Silicon Homebrew)
//     3. /usr/local/bin/nvim     (Intel Homebrew)
//     4. /opt/local/bin/nvim     (MacPorts)
//     5. Each absolute component of $PATH
//   First candidate that passes existence + executable + version(≥0.9) check wins.
//
// Relationships:
//   ↔ NvimProcessSupervisor.swift: main class declaration — spawn, teardown,
//     stderr drain, XDG session directory. Probe helpers here are package-
//     internal static methods; NvimProbeResult is public.

import Darwin
import Foundation
import MoonSwiftCore

// MARK: - Probe result

/// The successful result of a nvim probe: a confirmed executable path and its
/// parsed version tuple.
///
/// The tuple is not `Equatable` by default; tests compare `.0`/`.1` directly.
public struct NvimProbeResult: Sendable {
    /// Absolute path confirmed as executable with version ≥ (0, 9).
    public let path: String
    /// Parsed version `(major, minor)` from the first line of `nvim --version`.
    public let version: (Int, Int)
}

// MARK: - NvimProcessSupervisor: probe extension

extension NvimProcessSupervisor {

    // MARK: - Probe

    /// Probe for nvim, searching in priority order (ARCHITECTURE.md §10.4.5).
    ///
    /// Public parameterless entry point — delegates to the injectable seam.
    /// Call this before `spawn(path:)`; if it returns nil, fall back to $EDITOR.
    public static func probe() -> NvimProbeResult? {
        probe(
            environment: ProcessInfo.processInfo.environment,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            versionProbe: { runVersionProbe(path: $0) }
        )
    }

    /// Testability seam: injectable probe logic.
    ///
    /// - Parameters:
    ///   - environment: The process environment dict (inject to override NVIM_PATH/PATH).
    ///   - isExecutableFile: Predicate for executable check (inject a fake for tests).
    ///   - fileExists: Predicate for existence check (inject a fake for tests).
    ///   - versionProbe: Runs `<path> --version` and returns the first output line.
    ///                   Return nil to simulate a run failure.
    static func probe(
        environment: [String: String],
        isExecutableFile: (String) -> Bool,
        fileExists: (String) -> Bool,
        versionProbe: (String) -> String?
    ) -> NvimProbeResult? {
        // Build the candidate list in priority order.
        var candidates: [String] = []

        // Step 1: NVIM_PATH override — absolute path + executable guard only.
        // A relative or non-executable value is silently skipped (spec: log debug).
        if let envPath = environment["NVIM_PATH"] {
            if envPath.hasPrefix("/") && fileExists(envPath) && isExecutableFile(envPath) {
                candidates.append(envPath)
            } else {
                Logger.shared.debug(
                    "NvimProcessSupervisor: NVIM_PATH '\(envPath)' rejected "
                        + "(not absolute, not found, or not executable); continuing search"
                )
            }
        }

        // Steps 2–4: Well-known package-manager install locations.
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/nvim",  // Apple Silicon Homebrew
            "/usr/local/bin/nvim",  // Intel Homebrew
            "/opt/local/bin/nvim",  // MacPorts
        ])

        // Step 5: Each absolute component of $PATH.
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":").map(String.init) where dir.hasPrefix("/") {
                candidates.append("\(dir)/nvim")
            }
        }

        // Evaluate candidates in order; return the first that passes all checks.
        for path in candidates {
            guard fileExists(path), isExecutableFile(path) else { continue }
            guard let version = parseVersion(from: versionProbe(path)) else { continue }
            guard meetsMinimumVersion(version) else { continue }
            return NvimProbeResult(path: path, version: version)
        }

        return nil
    }

    // MARK: - Private: version helpers

    /// Run `<path> --version` and return the first line of stdout.
    ///
    /// Bounded: the probe process is killed after ~3 s and stdout is capped at
    /// 4 KiB. Only the first newline-terminated line is needed to extract the
    /// version string; a hung or hostile binary cannot wedge the caller forever
    /// or exhaust memory.
    ///
    /// Returns nil if the process cannot be launched, times out, or produces no
    /// parseable output.
    static func runVersionProbe(path: String) -> String? {
        // Maximum bytes to read from the version probe stdout.
        let maxReadBytes = 4 * 1024
        // Hard deadline: kill the probe after this many seconds.
        let probeDeadlineSeconds = 3.0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard stderr during probe

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Schedule a kill in case the binary hangs indefinitely.
        let killItem = DispatchWorkItem { kill(proc.processIdentifier, SIGKILL) }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + probeDeadlineSeconds,
            execute: killItem
        )
        defer { killItem.cancel() }

        // Read at most `maxReadBytes` — only the first line is needed.
        let fd = pipe.fileHandleForReading.fileDescriptor
        var buf = [UInt8](repeating: 0, count: maxReadBytes)
        let n = buf.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress, maxReadBytes)
        }
        pipe.fileHandleForReading.closeFile()

        proc.waitUntilExit()

        guard n > 0 else { return nil }
        let data = Data(buf[0..<n])
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return output.components(separatedBy: "\n").first
    }

    /// Parse a version tuple from the first line of `nvim --version`.
    ///
    /// Expected format: `NVIM v<major>.<minor>.<patch>` (e.g. `NVIM v0.9.5`).
    /// Returns nil for any format that does not match.
    static func parseVersion(from line: String?) -> (Int, Int)? {
        guard let line else { return nil }

        // The first token of the first line is always "NVIM"; second is "v<x.y.z>".
        let tokens = line.split(separator: " ")
        guard tokens.count >= 2 else { return nil }

        let versionToken = tokens[1]
        guard versionToken.hasPrefix("v") else { return nil }

        let parts = versionToken.dropFirst().split(separator: ".")
        guard parts.count >= 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else { return nil }

        return (major, minor)
    }

    /// Returns true if `version` is at least (0, 9).
    static func meetsMinimumVersion(_ version: (Int, Int)) -> Bool {
        if version.0 > 0 { return true }
        if version.0 == 0 { return version.1 >= 9 }
        return false
    }
}
