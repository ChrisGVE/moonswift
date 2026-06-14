// File: Sources/MoonSwiftCore/LuaLS/MetaFileGenerator.swift
// Folder: Sources/MoonSwiftCore/LuaLS/
// Role: Pure transform from the module catalog to lua-language-server (LuaLS)
//       project files — one `---@meta` Lua file per module plus a `.luarc.json`
//       (F7b). The third catalog consumer alongside luacheck globals (F4) and
//       native completion (F7a). No process, no I/O, no AppEvent — Core-side and
//       fully unit-testable. The TUI's LuaLSClient writes the returned
//       GeneratedFile values into the per-project cache dir and points LuaLS at
//       them via `.luarc.json` (ARCHITECTURE §7.3, PRD §F7b).
//
// Upstream: CatalogModule / CatalogFunction / CatalogParam (CatalogTypes.swift)
// Downstream: LuaModuleCatalog.luaLSMetaFiles() (CatalogConsumers+Meta.swift),
//             LuaLSClient (writes files, TUI side)

import Foundation

/// Synthesises LuaLS `---@meta` files and a `.luarc.json` from catalog data.
///
/// The generator is a pure value transform: given the catalog modules it
/// produces deterministic file contents (no clock, no filesystem). LuaLS reads
/// all files in `workspace.library` together, so cross-file references (a
/// submodule extending the `luaswift` global declared in the root file) resolve
/// regardless of file order.
public enum MetaFileGenerator {

    /// LuaLS `runtime.version` matching the active engine (Lua 5.4).
    public static let luaRuntimeVersion = "Lua 5.4"

    /// Directory (relative to the cache root) that holds the generated `---@meta`
    /// files; `.luarc.json` lists it under `workspace.library`.
    public static let metaDirectory = "meta"

    /// One `---@meta` file declaring `module`'s table and its functions with
    /// LuaLS `@param`/`@return`/doc annotations.
    public static func metaFile(for module: CatalogModule) -> GeneratedFile {
        let qualified = module.qualifiedName
        var lines: [String] = ["---@meta", ""]

        // Declare the module table. Submodule tables (luaswift.json) assume the
        // `luaswift` root global, which the root module's file declares.
        lines.append("---@class \(qualified)")
        lines.append("\(qualified) = {}")
        lines.append("")

        // Declare any intermediate subtables for dotted function names
        // (e.g. luaswift.iox.path.join needs luaswift.iox.path).
        var declaredSubtables: Set<String> = []
        for function in module.functions where function.name.contains(".") {
            let parts = function.name.split(separator: ".").map(String.init)
            var path = qualified
            for component in parts.dropLast() {
                path += ".\(component)"
                if declaredSubtables.insert(path).inserted {
                    lines.append("\(path) = {}")
                }
            }
        }
        if !declaredSubtables.isEmpty { lines.append("") }

        for function in module.functions {
            lines.append(contentsOf: functionDeclaration(qualified: qualified, function: function))
            lines.append("")
        }

        let content = lines.joined(separator: "\n").appending("\n")
        return GeneratedFile(relativePath: "\(metaDirectory)/\(qualified).lua", content: content)
    }

    /// The `.luarc.json` pointing LuaLS at the generated meta directory with the
    /// active runtime version.
    public static func luarcJSON(runtimeVersion: String = luaRuntimeVersion) -> GeneratedFile {
        // Hand-built so key order is deterministic (stable across runs for the
        // meta-version sentinel comparison). Flat dotted keys are valid LuaLS
        // configuration keys.
        let content = """
            {
              "runtime.version": "\(runtimeVersion)",
              "workspace.library": ["\(metaDirectory)"],
              "diagnostics.globals": ["luaswift"]
            }

            """
        return GeneratedFile(relativePath: ".luarc.json", content: content)
    }

    // MARK: - Private builders

    /// The annotated declaration lines for one function: doc comment, `@param`
    /// per parameter, `@return`, and the stub `function … end`.
    private static func functionDeclaration(qualified: String, function: CatalogFunction) -> [String] {
        var lines: [String] = []
        if let doc = function.doc, !doc.isEmpty {
            for docLine in doc.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("---\(docLine)")
            }
        }
        for param in function.params {
            let optional = param.isOptional ? "?" : ""
            lines.append("---@param \(param.name)\(optional) \(param.type ?? "any")")
        }
        if let returns = function.returns, !returns.isEmpty {
            lines.append("---@return \(returns)")
        }
        let signature = function.params.map { $0.name }.joined(separator: ", ")
        lines.append("function \(qualified).\(function.name)(\(signature)) end")
        return lines
    }
}
