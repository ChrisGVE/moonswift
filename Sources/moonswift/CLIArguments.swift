// File: Sources/moonswift/CLIArguments.swift
// Location: Sources/moonswift/
// Role: Pure CLI argument parser. Maps the raw `CommandLine.arguments` array
//       to a typed `ParseResult` that Main.swift dispatches on. No I/O here —
//       all output (version string, usage text) is constructed here as `String`
//       values and printed by the caller. This separation keeps the parsing
//       logic unit-testable without any process side-effects.
// Upstream: CommandLine.arguments (injected as [String] in tests)
// Downstream: Main.swift (dispatches on the result)

import Foundation

// MARK: - ExitCode

/// Exit codes aligned with sysexits(3) (PRD §4.7).
///
/// These are the only four valid exit codes for the moonswift binary.
/// The numeric values are fixed and must not change — they are documented
/// in `--help` and the user documentation.
enum ExitCode {
    /// Normal exit — the user quit gracefully.
    static let success: Int32 = 0
    /// Usage error — bad arguments (EX_USAGE).
    static let usage: Int32 = 64
    /// Data error — project-file or source error fatal at startup in non-TUI
    /// contexts (EX_DATAERR).
    static let dataErr: Int32 = 65
    /// Internal error — FFI failure, invariant violation (EX_SOFTWARE).
    static let software: Int32 = 70
}

// MARK: - ParseResult

/// The outcome of parsing `CommandLine.arguments`.
///
/// The cases are mutually exclusive; `Main.swift` reads this once and
/// branches immediately. No intermediate state is stored.
enum ParseResult {
    /// Print the version string to stdout and exit 0.
    case printVersion(String)
    /// Print the usage text to stdout and exit 0.
    case printHelp(String)
    /// Open the cwd as a project root (no argument given), or use
    /// empty/init-flow state if no `moonswift.toml` is present.
    case projectCwd(URL)
    /// A directory path was given — use it as the project root.
    case projectDirectory(URL)
    /// A `.lua` path was given — quick one-off mode (no project file).
    case quickFile(URL)
    /// The argument list was invalid (unknown flag, too many args, etc.).
    /// `message` is a human-readable description suitable for stderr.
    case usageError(String)
}

// MARK: - CLIParser

/// Parses a flat `[String]` argument list (the raw `CommandLine.arguments`)
/// into a `ParseResult`. Stateless: every call is independent.
///
/// The binary name (argv[0]) is dropped before parsing; `arguments` should be
/// the full `CommandLine.arguments` slice, not a pre-stripped copy.
enum CLIParser {

    // MARK: - Public interface

    /// Parse the given argument list.
    ///
    /// - Parameter arguments: The full `CommandLine.arguments` array,
    ///   including argv[0].
    /// - Returns: A `ParseResult` describing the parsed intent.
    static func parse(_ arguments: [String]) -> ParseResult {
        // Drop argv[0] (the binary path).
        let args = Array(arguments.dropFirst())
        return parseArgs(args)
    }

    // MARK: - Version / help text

    /// The version string printed by `--version`.
    ///
    /// Format: `moonswift 0.1.0` (SemVer, updated in sync with the git tag).
    static let versionString: String = "moonswift 0.1.0"

    /// The usage text printed by `--help`.
    ///
    /// Uses a man-style compact layout: synopsis first, then flagged options,
    /// then the exit-code table. Fits in 80 columns.
    static let helpText: String = """
        moonswift — Lua script workbench for LuaSwift embeddings

        USAGE
          moonswift                   open current directory as a project
          moonswift <dir>             open <dir> as a project root
          moonswift <file.lua>        quick one-off: run/lint a single .lua file
          moonswift --version         print version and exit
          moonswift --help            print this help and exit

        EXIT CODES
          0   normal exit
         64   usage error (EX_USAGE)
         65   project-file or source error at startup (EX_DATAERR)
         70   internal error (EX_SOFTWARE)

        ENVIRONMENT
          NO_COLOR                    disable color output
          MOONSWIFT_LOG               log level: error (default), info, debug

        NOTES
          A project directory must contain a moonswift.toml file.
          If one is not found, moonswift offers to create it.
        """

    // MARK: - Private parsing

    private static func parseArgs(_ args: [String]) -> ParseResult {
        // No arguments: open the cwd as a project root.
        if args.isEmpty {
            return .projectCwd(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }

        // Exactly one argument.
        if args.count == 1 {
            let arg = args[0]

            switch arg {
            case "--version", "-V":
                return .printVersion(versionString)

            case "--help", "-h":
                return .printHelp(helpText)

            default:
                if arg.hasPrefix("-") {
                    return .usageError("unknown option '\(arg)' — try --help")
                }
                return resolvePathArg(arg)
            }
        }

        // More than one argument: only --help or --version are allowed as
        // the sole argument; everything else is a usage error.
        // (No combination of flags is currently defined.)
        let unknown = args.filter { $0.hasPrefix("-") }
        if !unknown.isEmpty {
            return .usageError("unknown option '\(unknown[0])' — try --help")
        }
        return .usageError("too many arguments — try --help")
    }

    /// Resolve a bare path argument to `.quickFile` or `.projectDirectory`.
    private static func resolvePathArg(_ path: String) -> ParseResult {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if !exists {
            return .usageError("path not found: \(url.path)")
        }
        if isDir.boolValue {
            return .projectDirectory(url)
        }
        // File exists — accept only .lua files for quick-launch mode.
        if url.pathExtension.lowercased() == "lua" {
            return .quickFile(url)
        }
        return .usageError(
            "unsupported file type '\(url.pathExtension)' — pass a .lua file or a project directory"
        )
    }
}
