// File: Sources/MoonSwiftCore/Catalog/CatalogTypes.swift
// Folder: Sources/MoonSwiftCore/Catalog/
// Role: Core value types for the LuaModuleCatalog — module, function, parameter,
//       and generated-file descriptors. These types carry the P1 data shape
//       (names only) while leaving signature fields optional so P3a enrichment
//       can fill them without a breaking API change.
//
//       Availability describes when a module is present in a running engine:
//         .base          — always installed; no user action required.
//         .conditional   — installed when a startup probe confirms the
//                          backing library (e.g. TOML via TOMLKit).
//         .optIn         — the user must request the module explicitly via
//                          lint.extra_modules in moonswift.toml.
//         .compileFlagGated — present only in builds compiled with a
//                             specific Swift active-compilation flag
//                             (e.g. LUASWIFT_NUMERICSWIFT for NumericSwift).
//
//       Consumers:
//         - LuaModuleCatalog.luacheckGlobals(extraModules:)  → luacheck std table
//         - LuaModuleCatalog.completionItems(prefix:)         → [CompletionItem] (P3a)
//         - LuaModuleCatalog.luaLSMetaFiles()                 → [GeneratedFile]  (P3b)
//
// Upstream: (none — pure data)
// Downstream: LuaModuleCatalog, lint pipeline, completions (P3a), LuaLS meta (P3b)

// MARK: - Availability

/// When a luaswift.* module is present in a running Lua engine.
///
/// The catalog is the single source of truth for this classification.
/// Lint, completions, and LuaLS meta all derive their module sets from it.
public enum ModuleAvailability: Sendable, Equatable, Hashable {

    /// Always installed. No user action required.
    ///
    /// Examples: `luaswift.json`, `luaswift.regex`, `luaswift.mathx`.
    case base

    /// Installed only when a startup engine probe confirms the backing library.
    ///
    /// The probe is a separate concern (later task). This catalog entry provides
    /// the data the probe result will act on — specifically the `toml` module,
    /// which requires TOMLKit (`LUASWIFT_TOMLKIT` compile flag in LuaSwift).
    case conditional

    /// Not auto-installed. The user must declare the module in
    /// `lint.extra_modules` in `moonswift.toml`.
    ///
    /// Examples: `luaswift.iox`, `luaswift.http`, `luaswift.ui`.
    case optIn

    /// Present only in binaries compiled with a specific Swift
    /// active-compilation condition.
    ///
    /// Examples: `LUASWIFT_NUMERICSWIFT` (array, linalg, complex),
    ///           `LUASWIFT_ARRAYSWIFT` (array standalone build).
    /// Not included in catalog v0 — enumerated here for the type system's
    /// completeness so callers can pattern-match all cases.
    case compileFlagGated
}

// MARK: - Function descriptor

/// A single Lua-facing function exposed by a module.
///
/// P1 scope: only `name` is populated. The `params`, `returns`, and `doc`
/// fields exist so P3a can enrich the catalog without changing call sites.
public struct CatalogFunction: Sendable {

    /// The Lua-level name of the function within its module table.
    ///
    /// Example: `"decode"` for `luaswift.json.decode`.
    public let name: String

    /// Parameter descriptors. Empty in P1; populated in P3a.
    public let params: [CatalogParam]

    /// Human-readable return description. Nil in P1; populated in P3a.
    public let returns: String?

    /// Inline documentation string. Nil in P1; populated in P3a.
    public let doc: String?

    /// Convenience initialiser for P1 (name-only).
    public init(name: String) {
        self.name = name
        self.params = []
        self.returns = nil
        self.doc = nil
    }

    /// Full initialiser for P3a enrichment.
    public init(
        name: String,
        params: [CatalogParam] = [],
        returns: String? = nil,
        doc: String? = nil
    ) {
        self.name = name
        self.params = params
        self.returns = returns
        self.doc = doc
    }
}

// MARK: - Parameter descriptor

/// A single parameter of a Lua-facing function.
///
/// Present in the type for P3a; no catalog v0 entries populate this.
public struct CatalogParam: Sendable {

    /// Parameter name as it appears in Lua documentation.
    public let name: String

    /// Lua type string (e.g. `"string"`, `"table"`, `"number|string"`).
    /// Nil means type is unspecified or polymorphic.
    public let type: String?

    /// Whether the parameter may be omitted.
    public let isOptional: Bool

    public init(name: String, type: String? = nil, isOptional: Bool = false) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
    }
}

// MARK: - Module descriptor

/// Describes one module in the luaswift.* namespace.
///
/// The `tableName` is the bare Lua identifier (e.g. `"json"` for `luaswift.json`).
/// The special value `""` represents the root `luaswift` table itself.
public struct CatalogModule: Sendable {

    /// The module's Lua table name within the `luaswift` namespace.
    ///
    /// `""` is the sentinel for the root `luaswift` table. All other values
    /// are bare identifiers: `"json"`, `"regex"`, `"mathx"`, etc.
    public let tableName: String

    /// Functions this module registers on its table.
    public let functions: [CatalogFunction]

    /// When this module is present in a running engine.
    public let availability: ModuleAvailability

    public init(
        tableName: String,
        functions: [CatalogFunction],
        availability: ModuleAvailability
    ) {
        self.tableName = tableName
        self.functions = functions
        self.availability = availability
    }

    /// The fully-qualified Lua global name for this module.
    ///
    /// Returns `"luaswift"` for the root table, `"luaswift.<tableName>"` otherwise.
    public var qualifiedName: String {
        tableName.isEmpty ? "luaswift" : "luaswift.\(tableName)"
    }
}

// MARK: - Generated file

/// A file produced by the catalog for downstream tooling (LuaLS, P3b).
///
/// P1 and P3a callers do not use this type; it is declared here so the
/// `luaLSMetaFiles()` return type compiles without a stub.
public struct GeneratedFile: Sendable {

    /// Relative path for the file (e.g. `".luarc/meta/luaswift.json.lua"`).
    public let relativePath: String

    /// UTF-8 text content.
    public let content: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}
