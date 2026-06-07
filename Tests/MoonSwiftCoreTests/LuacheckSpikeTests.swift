// File: Tests/MoonSwiftCoreTests/LuacheckSpikeTests.swift
// Location: Tests/MoonSwiftCoreTests/
// Role: F4.0 spike — proves that the vendored pure-Lua luacheck subset runs
//       inside a LuaSwift engine via a package.preload shim. This test is a
//       REQUIRED CI check (PRD F4.0 / ARCHITECTURE.md §3d).
//
// What this test verifies:
//   • The vendor resource bundle is accessible at test time.
//   • All vendored .lua files can be read and registered in package.preload.
//   • require("luacheck") resolves through the preload shim.
//   • luacheck.check_strings returns a structured report for four fixtures:
//       (a) a clean script — zero issues reported,
//       (b) a script with an undefined global — W1xx reported,
//       (c) a script with a syntax error — E011 reported,
//       (d) a script with a declared global (in options) — lints clean.
//
// Design decisions (also recorded in docs/internals/lint.md):
//
//   Engine configuration: unrestricted. The shim installs module sources via
//   load(), which the sandbox removes. The lint engine runs only trusted
//   vendored code — no user script ever executes in it (ARCHITECTURE.md §3d).
//   If a future LuaSwift version exposes package.preload population without
//   load(), sandboxed mode could be revisited.
//
//   Shim mechanism: before require("luacheck"), a Lua snippet registers every
//   vendored module in package.preload under its dotted module name (e.g.
//   "luacheck.lexer"). Each entry is a factory closure that calls load() on
//   the source string captured as an upvalue. On first require() the closure
//   runs and returns the module; subsequent calls hit package.loaded as usual.
//
//   LuaValue table representation: LuaSwift converts Lua tables with mixed
//   integer+string keys to .table([String: LuaValue]), where integer keys N
//   are stored as string "N". Pure integer-keyed contiguous tables become
//   .array([LuaValue]) (0-indexed in Swift, 1-indexed in Lua).

import Foundation
import LuaSwift
import Testing

@testable import MoonSwiftCore

// MARK: - Vendor bundle helpers

/// Walk the luacheck vendor directory in Bundle.module and return a mapping
/// of Lua module name → source string for every .lua file in the subset.
///
/// Naming convention: the path relative to the luacheck/ root directory is
/// converted to a dotted require() name.
///   luacheck/init.lua            → "luacheck"
///   luacheck/lexer.lua           → "luacheck.lexer"
///   luacheck/stages/parse.lua    → "luacheck.stages.parse"
private func vendoredModules() throws -> [String: String] {
    // SPM copies the entire "Vendor/luacheck" directory into the bundle root,
    // preserving only the directory name ("luacheck"), not the "Vendor/" prefix.
    // The Lua module files live one level deeper: bundle/luacheck/luacheck/*.lua
    //
    // moonSwiftCoreBundle (VendorBundle.swift) resolves the MoonSwiftCore bundle,
    // not the test target's bundle. Bundle.module here would resolve the test
    // bundle, which does not contain the vendored luacheck sources.
    guard
        let luacheckDir = moonSwiftCoreBundle.resourceURL?
            .appendingPathComponent("luacheck")  // the copied "Vendor/luacheck" dir
            .appendingPathComponent("luacheck")  // the Lua module tree inside it
    else {
        throw SpikeError.bundleResourceMissing(
            "luacheck/luacheck not found in MoonSwiftCore bundle — "
                + "check that Package.swift declares .copy(\"Vendor/luacheck\") " + "on the MoonSwiftCore target"
        )
    }

    let fm = FileManager.default
    guard
        let enumerator = fm.enumerator(
            at: luacheckDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        throw SpikeError.bundleResourceMissing(
            "Could not enumerate \(luacheckDir.path)"
        )
    }

    var modules: [String: String] = [:]
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "lua" else { continue }

        // Relative path from the luacheck/ root, e.g. "stages/parse.lua".
        let relativePath = fileURL.path
            .replacingOccurrences(of: luacheckDir.path + "/", with: "")

        // Derive the require()-compatible dotted module name from the relative path.
        // Lua's require() resolves "luacheck.builtin_standards" via either
        // "luacheck/builtin_standards.lua" or "luacheck/builtin_standards/init.lua".
        // We use the init.lua form for sub-package init files: strip the
        // trailing "/init" so the module name matches what require() uses.
        let moduleName: String
        let withoutExt = relativePath.replacingOccurrences(of: ".lua", with: "")
        let withDots = withoutExt.replacingOccurrences(of: "/", with: ".")
        if withDots == "init" {
            // Top-level init.lua → "luacheck"
            moduleName = "luacheck"
        } else if withDots.hasSuffix(".init") {
            // Sub-package init.lua → strip ".init" suffix
            // e.g. "builtin_standards.init" → "luacheck.builtin_standards"
            moduleName = "luacheck." + String(withDots.dropLast(".init".count))
        } else {
            moduleName = "luacheck." + withDots
        }

        modules[moduleName] = try String(contentsOf: fileURL, encoding: .utf8)
    }
    return modules
}

/// Build the Lua source for the package.preload shim.
///
/// Each module is registered as a factory closure in package.preload. The
/// factory captures the source string as an upvalue and compiles it with
/// load() on first require(). Subsequent require() calls hit package.loaded
/// as normal — the factory is invoked at most once per module per engine.
///
/// The source is embedded as a Lua long string at the lowest bracket level
/// that does not appear in the source, making the shim injection injection-
/// safe: the content is treated as data, not code.
private func buildPreloadShim(modules: [String: String]) -> String {
    var lines: [String] = [
        "-- preload shim: register all vendored luacheck modules",
        "local function make_loader(src, modname)",
        "  return function()",
        "    local chunk, err = load(src, '@luacheck/' .. modname, 't')",
        "    if not chunk then error(err) end",
        "    return chunk()",
        "  end",
        "end",
    ]
    for (name, source) in modules {
        let literal = luaLongString(source)
        lines.append("package.preload[\"\(name)\"] = make_loader(\(literal), \"\(name)\")")
    }
    return lines.joined(separator: "\n")
}

/// Wrap `source` in a Lua long string at the minimum bracket level that does
/// not conflict with any `]=*]` sequence already present in the content.
private func luaLongString(_ source: String) -> String {
    var level = 0
    while source.contains("]" + String(repeating: "=", count: level) + "]") {
        level += 1
    }
    let open = "[" + String(repeating: "=", count: level) + "["
    let close = "]" + String(repeating: "=", count: level) + "]"
    // Lua long strings strip one leading newline, so add one to avoid losing
    // the first line of the source.
    return "\(open)\n\(source)\(close)"
}

// MARK: - Internal error type

private enum SpikeError: Error, CustomStringConvertible {
    case bundleResourceMissing(String)
    case reportShapeError(String)

    var description: String {
        switch self {
        case .bundleResourceMissing(let m): return "Bundle resource missing: \(m)"
        case .reportShapeError(let m): return "Unexpected report shape: \(m)"
        }
    }
}

// MARK: - Report parsing helpers

/// Extract the per-file result table from a check_strings report.
///
/// check_strings returns a table (the "processed report"). Index [1] in that
/// table is the per-file result: an array of filtered issue tables. Because
/// LuaSwift converts mixed-key Lua tables to .table([String: LuaValue]) with
/// integer keys as decimal strings, we must handle both representations:
///   • .array([LuaValue])  — pure integer-keyed contiguous table (clean run)
///   • .table([String: LuaValue]) — mixed keys (file report with metadata)
private func fileReport(from report: LuaValue) throws -> LuaValue {
    switch report {
    case .table(let outer):
        if let r = outer["1"] { return r }
        throw SpikeError.reportShapeError("report has no key \"1\": \(outer.keys.sorted())")
    case .array(let arr):
        guard !arr.isEmpty else {
            throw SpikeError.reportShapeError("report array is empty")
        }
        return arr[0]  // 0-indexed in Swift; Lua index 1 is arr[0]
    default:
        throw SpikeError.reportShapeError("check_strings returned \(report), expected table")
    }
}

/// Extract all issue tables (integer-keyed entries) from a per-file report.
///
/// LuaSwift converts Lua arrays/mixed tables to either .array or .table.
/// An issue table has fields: code (string), line (number), column (number), etc.
private func issues(in fileRep: LuaValue) -> [[String: LuaValue]] {
    switch fileRep {
    case .array(let arr):
        // Pure integer-keyed: each element is an issue table.
        return arr.compactMap { if case .table(let t) = $0 { return t } else { return nil } }
    case .table(let dict):
        // Mixed keys: integer-keyed entries (as decimal strings) are issues.
        return dict.compactMap { (key, val) -> [String: LuaValue]? in
            guard Int(key) != nil, case .table(let t) = val else { return nil }
            return t
        }
    default:
        return []
    }
}

// MARK: - Spike test suite

/// Spike: vendored pure-Lua luacheck runs in a LuaSwift engine (F4.0).
///
/// This suite is a permanent required CI check per PRD F4.0. It must remain
/// fast (< 5 s total): the engine and shim are set up once per test via a
/// helper; the actual check_strings calls are sub-millisecond.
@Suite("LuacheckSpike — vendored luacheck in LuaSwift engine")
struct LuacheckSpikeTests {

    // MARK: - Engine factory

    /// Build a fresh unrestricted LuaEngine with the package.preload shim
    /// installed for all vendored luacheck modules.
    ///
    /// Unrestricted is required because the shim uses load() to compile each
    /// module source at require() time. The sandbox removes load(). This engine
    /// only ever runs trusted vendored code; no user script enters it.
    private func makeEngine() throws -> LuaEngine {
        let config = LuaEngineConfiguration(
            sandboxed: false,
            packagePath: nil,
            memoryLimit: 0
        )
        let engine = try LuaEngine(configuration: config)
        let modules = try vendoredModules()
        let shim = buildPreloadShim(modules: modules)
        try engine.run(shim)
        return engine
    }

    // MARK: - Prerequisite: bundle presence

    @Test("Vendor bundle contains the expected luacheck module files")
    func vendorBundlePresent() throws {
        let modules = try vendoredModules()
        // The subset has 38 .lua files (14 core + 5 builtin_standards +
        // 19 stages). Require at minimum 30 to guard against accidental
        // subset shrinkage.
        #expect(
            modules.count >= 30,
            "Expected ≥30 vendored modules, found \(modules.count)"
        )
        #expect(modules["luacheck"] != nil, "luacheck/init.lua must map to \"luacheck\"")
        #expect(modules["luacheck.lexer"] != nil, "luacheck.lexer must be present")
        #expect(
            modules["luacheck.stages.detect_globals"] != nil,
            "luacheck.stages.detect_globals must be present")
        #expect(
            modules["luacheck.builtin_standards"] != nil,
            "luacheck.builtin_standards must be present")
    }

    // MARK: - Fixture (a): clean script → zero issues

    /// A script with no problems should produce an empty issue list.
    @Test("(a) Clean script reports zero issues")
    func cleanScriptReportsZeroIssues() throws {
        let engine = try makeEngine()

        let report = try engine.evaluate(
            """
                local luacheck = require("luacheck")
                return luacheck.check_strings(
                    {[[local x = 1; return x]]},
                    {}
                )
            """)

        let fileRep = try fileReport(from: report)
        let issueList = issues(in: fileRep)
        #expect(
            issueList.isEmpty,
            "Expected zero issues for clean script, found \(issueList.count): \(issueList)"
        )
    }

    // MARK: - Fixture (b): undefined global → W1xx

    /// A reference to an undeclared global should produce a W1xx warning
    /// with valid line and column numbers.
    @Test("(b) Undefined global reports W1xx with line/column")
    func undefinedGlobalReportsWarning() throws {
        let engine = try makeEngine()

        // Two-line script: line 1 is clean; line 2 references an undefined global.
        // The Lua source uses a [[ ]] long string inside the Swift multi-line
        // string. The content must start at column 0 within the long brackets to
        // avoid Lua interpreting leading whitespace as part of the script.
        let snippet = "[[" + "\nlocal clean = 1\nreturn undefinedGlobal\n" + "]]"
        let report = try engine.evaluate(
            """
                local luacheck = require("luacheck")
                return luacheck.check_strings({\(snippet)}, {})
            """)

        let fileRep = try fileReport(from: report)
        let issueList = issues(in: fileRep)
        #expect(!issueList.isEmpty, "Expected at least one warning for undefined global")

        // Find the W113 "accessing undefined variable" issue. The fixture also
        // produces a W211 "unused local" for `local clean = 1`; we look across
        // all issues for the global-related one (code starts with "1").
        let globalIssues = issueList.filter { issue in
            guard let codeVal = issue["code"], case .string(let code) = codeVal else {
                return false
            }
            return code.hasPrefix("1")
        }
        #expect(
            !globalIssues.isEmpty,
            "Expected a W1xx issue for undefined global in \(issueList)"
        )

        guard let globalIssue = globalIssues.first else { return }

        // Line number must be present and positive.
        if let lineVal = globalIssue["line"], let lineNum = lineVal.intValue {
            #expect(lineNum > 0, "Line number must be positive, got \(lineNum)")
        } else {
            throw SpikeError.reportShapeError(
                "Global issue missing integer 'line' field: \(globalIssue)"
            )
        }

        // Column number must be present and positive.
        if let colVal = globalIssue["column"], let colNum = colVal.intValue {
            #expect(colNum > 0, "Column must be positive, got \(colNum)")
        } else {
            throw SpikeError.reportShapeError(
                "Global issue missing integer 'column' field: \(globalIssue)"
            )
        }
    }

    // MARK: - Fixture (c): syntax error → E011

    /// Invalid Lua syntax should produce an E011 diagnostic.
    @Test("(c) Syntax error reports E011")
    func syntaxErrorReportsE011() throws {
        let engine = try makeEngine()

        let report = try engine.evaluate(
            """
                local luacheck = require("luacheck")
                return luacheck.check_strings(
                    {[[this is not valid lua syntax !!]]},
                    {}
                )
            """)

        let fileRep = try fileReport(from: report)
        let issueList = issues(in: fileRep)
        #expect(!issueList.isEmpty, "Expected E011 for invalid syntax")

        guard let first = issueList.first else { return }
        if let codeVal = first["code"], case .string(let code) = codeVal {
            #expect(
                code == "011",
                "Expected code=\"011\" (syntax error), got \"\(code)\"")
        } else {
            throw SpikeError.reportShapeError("Issue missing string 'code' field: \(first)")
        }
    }

    // MARK: - Fixture (d): declared global in options → clean

    /// When a global is listed in the `globals` option table, luacheck must
    /// not flag it as undefined. The report should be empty.
    @Test("(d) Declared global in options lints clean")
    func declaredGlobalLintsClean() throws {
        let engine = try makeEngine()

        // Without globals = {"myGlobal"} this would produce a W1xx warning.
        let report = try engine.evaluate(
            """
                local luacheck = require("luacheck")
                return luacheck.check_strings(
                    {[[return myGlobal]]},
                    {globals = {"myGlobal"}}
                )
            """)

        let fileRep = try fileReport(from: report)
        let issueList = issues(in: fileRep)
        let issueDesc = issueList.map { "\($0)" }.joined(separator: ", ")
        #expect(
            issueList.isEmpty,
            "Expected zero issues when global declared in options, found \(issueList.count): \(issueDesc)"
        )
    }
}
