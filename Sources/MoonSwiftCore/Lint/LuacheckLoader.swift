// File: Sources/MoonSwiftCore/Lint/LuacheckLoader.swift
// Location: MoonSwiftCore/Lint/
// Role: Loads the vendored pure-Lua luacheck subset into a LuaSwift engine via
//       the package.preload shim mechanism proven in the F4.0 spike test.
//
//       Two operations:
//         1. vendoredModules() — walks the MoonSwiftCore bundle and returns a
//            mapping of dotted Lua module name → source string.
//         2. installPreloadShim(engine:modules:) — registers each module as a
//            factory closure in package.preload so that require("luacheck")
//            resolves in-engine without any filesystem access from Lua.
//
//       This file extracts the loader logic from LuacheckSpikeTests.swift
//       (F4.0) into production code, promoting the proven pattern instead of
//       reinventing it. See docs/internals/lint.md §Loader mechanism.
//
// Upstream: MoonSwiftCore bundle (Vendor/luacheck .lua files via Bundle.module),
//           LuaSwift (LuaEngine.run)
// Downstream: LintService (calls installPreloadShim after creating the engine)

import Foundation
import LuaSwift

// MARK: - Loader errors

/// Errors surfaced by the luacheck loader during engine setup.
enum LuacheckLoaderError: Error, CustomStringConvertible {
    /// The luacheck resource directory was missing from the bundle.
    case bundleResourceMissing(String)

    var description: String {
        switch self {
        case .bundleResourceMissing(let m): return "Bundle resource missing: \(m)"
        }
    }
}

// MARK: - Module discovery

/// Walk the luacheck vendor directory in the MoonSwiftCore bundle and return a
/// mapping of Lua module name → source string for every .lua file in the subset.
///
/// Naming convention: the path relative to the `luacheck/` root directory is
/// converted to a dotted `require()` name:
///   - `init.lua`                          → `"luacheck"`
///   - `lexer.lua`                          → `"luacheck.lexer"`
///   - `stages/parse.lua`                   → `"luacheck.stages.parse"`
///   - `builtin_standards/init.lua`         → `"luacheck.builtin_standards"`
///
/// Uses `moonSwiftCoreBundle` (not `Bundle.module`) so the function works from
/// both the production target and the test target.
func vendoredLuacheckModules() throws -> [String: String] {
    // SPM copies the entire "Vendor/luacheck" directory into the bundle root,
    // preserving only the directory name ("luacheck"), not the "Vendor/" prefix.
    // The Lua module files live one level deeper: bundle/luacheck/luacheck/*.lua
    guard
        let luacheckDir = moonSwiftCoreBundle.resourceURL?
            .appendingPathComponent("luacheck")
            .appendingPathComponent("luacheck")
    else {
        throw LuacheckLoaderError.bundleResourceMissing(
            "luacheck/luacheck not found in MoonSwiftCore bundle — "
                + "check that Package.swift declares .copy(\"Vendor/luacheck\") "
                + "on the MoonSwiftCore target"
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
        throw LuacheckLoaderError.bundleResourceMissing(
            "Could not enumerate \(luacheckDir.path)"
        )
    }

    var modules: [String: String] = [:]
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "lua" else { continue }

        // Relative path from the luacheck/ root, e.g. "stages/parse.lua".
        let relativePath = fileURL.path
            .replacingOccurrences(of: luacheckDir.path + "/", with: "")

        // Derive the require()-compatible dotted module name.
        let moduleName = luaModuleName(fromRelativePath: relativePath)
        modules[moduleName] = try String(contentsOf: fileURL, encoding: .utf8)
    }
    return modules
}

// MARK: - Shim installation

/// Install the package.preload shim in `engine`, registering all `modules`.
///
/// After this call, `require("luacheck")` and any sub-module in the mapping
/// will be resolved by the shim's factory closures — no filesystem access from
/// within Lua, no `lfs` dependency.
///
/// The engine must be **unrestricted** (`sandboxed: false`): the shim uses
/// `load()` to compile each module source, and `load()` is removed by the
/// sandbox. See docs/internals/lint.md §Why the engine must be unrestricted.
func installLuacheckPreloadShim(engine: LuaEngine, modules: [String: String]) throws {
    let shim = buildPreloadShim(modules: modules)
    try engine.run(shim)
}

// MARK: - Lua long-string helper

/// Wrap `source` in a Lua long string at the minimum bracket level that avoids
/// conflicting with any `]=*]` sequences already in the content.
///
/// Lua long strings strip one leading newline, so a newline is added after the
/// opening bracket to preserve the first line of the source.
///
/// This encoding is injection-safe: the content is treated as data by the Lua
/// parser, never as code.
func luaLongString(_ source: String) -> String {
    var level = 0
    while source.contains("]" + String(repeating: "=", count: level) + "]") {
        level += 1
    }
    let open = "[" + String(repeating: "=", count: level) + "["
    let close = "]" + String(repeating: "=", count: level) + "]"
    return "\(open)\n\(source)\(close)"
}

// MARK: - Private helpers

/// Build the Lua source for the package.preload shim.
///
/// Each module is registered as a factory closure. The factory captures the
/// source string as an upvalue and compiles it with `load()` on first
/// `require()`. Subsequent `require()` calls hit `package.loaded` as normal.
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

/// Convert a relative file path inside the luacheck module tree to a dotted
/// Lua `require()` name.
///
/// Examples:
///   - `"init.lua"`                      → `"luacheck"`
///   - `"lexer.lua"`                     → `"luacheck.lexer"`
///   - `"stages/parse.lua"`              → `"luacheck.stages.parse"`
///   - `"builtin_standards/init.lua"`    → `"luacheck.builtin_standards"`
private func luaModuleName(fromRelativePath relativePath: String) -> String {
    let withoutExt = relativePath.replacingOccurrences(of: ".lua", with: "")
    let withDots = withoutExt.replacingOccurrences(of: "/", with: ".")
    if withDots == "init" {
        return "luacheck"
    } else if withDots.hasSuffix(".init") {
        return "luacheck." + String(withDots.dropLast(".init".count))
    } else {
        return "luacheck." + withDots
    }
}
