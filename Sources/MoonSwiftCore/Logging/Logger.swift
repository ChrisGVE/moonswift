// File: Sources/MoonSwiftCore/Logging/Logger.swift
// Role: Async file logger writing to ~/Library/Logs/moonswift/moonswift.log.
//       Internal logs cannot use stdout/stderr while the TUI owns the tty
//       (ARCHITECTURE.md §7.2). Level is controlled by the MOONSWIFT_LOG env
//       variable (error | info | debug; default: error). Log writes never
//       block the UI thread: they are buffered and flushed on a background
//       continuation.
// Upstream: (none — foundation service)
// Downstream: All MoonSwiftCore services; MoonSwiftTUI via AppDriver

import Foundation

// MARK: - Log level

/// The verbosity level for the internal file logger.
public enum LogLevel: Int, Sendable, Comparable {
    case error = 0
    case info = 1
    case debug = 2

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Reads the active level from the MOONSWIFT_LOG environment variable.
    /// Falls back to `.error` for unrecognised values.
    static func fromEnvironment() -> LogLevel {
        switch ProcessInfo.processInfo.environment["MOONSWIFT_LOG"]?.lowercased() {
        case "info": return .info
        case "debug": return .debug
        default: return .error
        }
    }
}

// MARK: - Logger

/// A lightweight async file logger for MoonSwift internal diagnostics.
///
/// One shared instance is used throughout the app. Log writes are dispatched
/// to a background serial queue so callers on the UI thread never block.
public final class Logger: Sendable {

    // Shared instance — initialised once at startup.
    public static let shared: Logger = Logger()

    private let queue = DispatchQueue(label: "moonswift.logger", qos: .utility)
    private let level: LogLevel
    // fileHandle is guarded by `queue`; nonisolated(unsafe) is correct here
    // because all accesses are serialised through `queue`.
    nonisolated(unsafe) private var fileHandle: FileHandle?

    private init() {
        level = LogLevel.fromEnvironment()
        fileHandle = Logger.openLogFile()
    }

    // MARK: Public interface

    /// Logs a message at the given level. The call returns immediately;
    /// the write happens on the logger's background queue.
    public func log(_ message: String, level: LogLevel = .info) {
        guard level <= self.level else { return }
        let line = "\(timestamp()) [\(level)] \(message)\n"
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    public func error(_ message: String) { log(message, level: .error) }
    public func info(_ message: String) { log(message, level: .info) }
    public func debug(_ message: String) { log(message, level: .debug) }

    // MARK: Private helpers

    private func timestamp() -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now)
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private static func openLogFile() -> FileHandle? {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/moonswift", isDirectory: true)
        let logURL = dir.appendingPathComponent("moonswift.log")

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            return try FileHandle(forWritingTo: logURL)
        } catch {
            // Cannot log — stderr is the only fallback before TUI init.
            fputs("moonswift: failed to open log file: \(error)\n", stderr)
            return nil
        }
    }
}
