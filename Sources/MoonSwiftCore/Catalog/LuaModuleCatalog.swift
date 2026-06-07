// File: Sources/MoonSwiftCore/Catalog/LuaModuleCatalog.swift
// Folder: Sources/MoonSwiftCore/Catalog/
// Role: Single source of truth for the luaswift.* module namespace exposed by
//       the embedded LuaSwift engine. The catalog feeds three consumers:
//
//         1. luacheckGlobals(extraModules:) — produces the options table shape
//            that luacheck's std= key expects, so the linter knows which globals
//            are valid.
//
//         2. completionItems(prefix:) — returns [CompletionItem] for the TUI
//            completion engine (P3a scope; stub in P1).
//
//         3. luaLSMetaFiles() — returns [GeneratedFile] for LuaLS meta files
//            (P3b scope; stub in P1).
//
//       The catalog is pure data — no I/O, no engine access, no side effects.
//       All availability decisions are encoded in the CatalogModule entries.
//
//       Conditional-module handling (e.g. `toml`):
//         A startup engine probe (separate task) posts the probe result.
//         Consumers call `luacheckGlobals(extraModules:)` and check whether
//         `.conditional` entries should be included by passing the probe result
//         via `tomlProbed`. The catalog does not manage probe state — it provides
//         the data; callers decide which availability tiers to include.
//
//       Maintenance rule:
//         Every LuaSwift minimum-version bump must include a catalog review.
//         This requirement is documented in CLAUDE.md (project-level), and every
//         catalog file header cites the LuaSwift source file it was verified against.
//
// Upstream: CatalogModule, CatalogFunction, ModuleAvailability (CatalogTypes.swift)
// Downstream: luacheck lint pipeline, completions (P3a), LuaLS meta (P3b),
//             ProjectValidation.extraModulesAllowList seam

// MARK: - LuaModuleCatalog

/// The hand-maintained catalog of luaswift.* modules for the embedded LuaSwift engine.
///
/// Use `LuaModuleCatalog.v0` to obtain the catalog, then call one of the
/// consumer accessors to produce the shape your pipeline needs.
///
/// ```swift
/// // Generate a luacheck globals table for the base + conditional modules.
/// let globals = LuaModuleCatalog.v0.luacheckGlobals(
///     extraModules: [],
///     tomlProbed: true   // startup probe confirmed toml is available
/// )
///
/// // Obtain the set of valid opt-in module names for validation.
/// let allowList = LuaModuleCatalog.v0.optInNames
/// ```
public struct LuaModuleCatalog: Sendable {

    // MARK: - Catalog data

    /// All modules registered in this catalog, in definition order.
    public let modules: [CatalogModule]

    // MARK: - Canonical instance

    /// Catalog v0 — hand-maintained, P1 scope.
    ///
    /// Covers the full luaswift.* namespace as shipped with MoonSwift:
    ///   - 1 root entry (`luaswift` table itself)
    ///   - 9 base modules (json, yaml, regex, mathx, stringx, tablex, types, utf8x, svg)
    ///   - 1 conditional module (toml)
    ///   - 3 opt-in modules (iox, http, ui)
    ///
    /// Function lists contain names only (P1 scope); signatures and doc strings
    /// are populated in P3a via the full `CatalogFunction` initialiser.
    public static let v0 = LuaModuleCatalog(modules: [
        // Root luaswift table
        .root,
        // Base — always present
        .json,
        .yaml,
        .regex,
        .mathx,
        .stringx,
        .tablex,
        .types,
        .utf8x,
        .svg,
        // Conditional — present when startup probe confirms TOMLKit
        .toml,
        // Opt-in — user must declare in lint.extra_modules
        .iox,
        .http,
        .ui,
    ])

    // MARK: - Availability accessors

    /// All modules whose availability is `.base`.
    public var baseModules: [CatalogModule] {
        modules.filter { $0.availability == .base }
    }

    /// All modules whose availability is `.conditional`.
    public var conditionalModules: [CatalogModule] {
        modules.filter { $0.availability == .conditional }
    }

    /// All modules whose availability is `.optIn`.
    public var optInModules: [CatalogModule] {
        modules.filter { $0.availability == .optIn }
    }

    /// The set of valid opt-in module names (bare table names, e.g. `"iox"`).
    ///
    /// This is the value injected into `ProjectValidation.extraModulesAllowList`
    /// (the catalog integration seam defined in ProjectValidation.swift §9).
    public var optInNames: Set<String> {
        Set(optInModules.map(\.tableName))
    }

    // MARK: - luacheck globals producer

    /// Produces the globals table that luacheck's `std=` option expects.
    ///
    /// The returned dictionary maps each Lua global to a nested `fields`
    /// dictionary following the luacheck standard-definition format:
    ///
    /// ```
    /// {
    ///   "luaswift": {
    ///     "fields": {
    ///       "json":   { "fields": { "decode": {}, "encode": {}, … } },
    ///       "mathx":  { "fields": { "sin": {}, "cos": {}, … } },
    ///       …
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - extraModules: Bare module names (e.g. `["iox", "http"]`) declared by
    ///     the user in `lint.extra_modules`. Only names matching `.optIn` catalog
    ///     entries are included; unknown names are silently ignored at this level
    ///     (ProjectValidation rejects them earlier with a diagnostic).
    ///   - tomlProbed: When `true`, `.conditional` modules are included in the
    ///     output. Pass the result of the startup engine probe. Defaults to `false`
    ///     (conservative — omit until probe confirms availability).
    /// - Returns: A nested string-keyed dictionary ready for JSON serialisation
    ///   into a luacheck `std` globals table. The outer key is the top-level Lua
    ///   global (always `"luaswift"` for this catalog).
    public func luacheckGlobals(
        extraModules: [String] = [],
        tomlProbed: Bool = false
    ) -> [String: Any] {

        let requestedOptIn = Set(extraModules)

        // Collect the sub-modules that belong inside the luaswift.* namespace.
        var luaswiftFields: [String: Any] = [:]

        for module in modules {
            // Decide whether this module is active.
            let include: Bool
            switch module.availability {
            case .base:
                include = true
            case .conditional:
                include = tomlProbed
            case .optIn:
                include = requestedOptIn.contains(module.tableName)
            case .compileFlagGated:
                include = false
            }

            guard include else { continue }

            if module.tableName.isEmpty {
                // Root luaswift table — its functions go directly into the
                // luaswift fields (not nested under a sub-key).
                for fn in module.functions {
                    luaswiftFields[fn.name] = [String: Any]()
                }
            } else {
                // Named sub-module — nest its functions one level deeper.
                let functionFields = functionFieldsDict(for: module)
                luaswiftFields[module.tableName] = ["fields": functionFields]
            }
        }

        return ["luaswift": ["fields": luaswiftFields]]
    }

    // MARK: - Completion items (P3a stub)

    /// Returns completion items for the given prefix string.
    ///
    /// P1 stub — returns an empty array. P3a replaces this body with real
    /// prefix-filtered completion construction from the catalog data.
    ///
    /// - Parameter prefix: The Lua text before the cursor (e.g. `"luaswift.json."`).
    /// - Returns: An empty array in P1. P3a populates this with `CompletionItem` values.
    public func completionItems(prefix: String) -> [String] {
        // P3a integration point: replace with CompletionItem construction.
        _ = prefix
        return []
    }

    // MARK: - LuaLS meta files (P3b stub)

    /// Returns generated LuaLS meta files describing the luaswift namespace.
    ///
    /// P1 stub — returns an empty array. P3b replaces this body with real
    /// `.luarc/meta/` file generation from the catalog data.
    ///
    /// - Returns: An empty array in P1. P3b populates this with `GeneratedFile` values.
    public func luaLSMetaFiles() -> [GeneratedFile] {
        // P3b integration point: generate LuaLS-compatible meta stubs.
        return []
    }

    // MARK: - Private helpers

    /// Builds the luacheck `fields` dictionary for one module's function list.
    ///
    /// Functions with a dot in their name (e.g. `"path.join"` from iox) are
    /// nested one level deeper to match the Lua table structure.
    private func functionFieldsDict(for module: CatalogModule) -> [String: Any] {
        var fields: [String: Any] = [:]
        var nestedTables: [String: [String: Any]] = [:]

        for fn in module.functions {
            if let dotIndex = fn.name.firstIndex(of: ".") {
                // Nested table function: e.g. "path.join" → fields["path"]["fields"]["join"]
                let tableKey = String(fn.name[fn.name.startIndex..<dotIndex])
                let fnKey = String(fn.name[fn.name.index(after: dotIndex)...])
                if nestedTables[tableKey] == nil {
                    nestedTables[tableKey] = [:]
                }
                nestedTables[tableKey]![fnKey] = [String: Any]()
            } else {
                fields[fn.name] = [String: Any]()
            }
        }

        // Fold nested tables into the fields dict.
        for (tableKey, fnMap) in nestedTables {
            fields[tableKey] = ["fields": fnMap]
        }

        return fields
    }
}
