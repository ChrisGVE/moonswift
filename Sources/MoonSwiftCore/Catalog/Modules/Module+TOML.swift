// File: Sources/MoonSwiftCore/Catalog/Modules/Module+TOML.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.toml — TOML encode/decode, conditional on
//       the TOMLKit backing library being present at startup.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/TOMLModule.swift
//       (Lua run block: luaswift.toml = { encode, decode }). The module is gated
//       on LUASWIFT_TOMLKIT in ModuleRegistry; MoonSwift ships TOMLKit as a
//       direct dependency but availability depends on a startup engine probe
//       (later task) that verifies TOMLKit is functional in the running binary.
//
//       Availability: .conditional — present only when the startup probe posts
//       `.catalogProbed(tomlAvailable: true)`. Until that probe result is
//       received, lint consumers treat the module as absent.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0, startup probe (future task)

extension CatalogModule {

    /// `luaswift.toml` — TOML encode and decode.
    ///
    /// Classified `.conditional`: MoonSwift ships TOMLKit but the module is
    /// only confirmed available once the startup probe succeeds. The probe
    /// result flips the effective availability for lint and completion consumers.
    static let toml = CatalogModule(
        tableName: "toml",
        functions: [
            CatalogFunction(name: "encode"),
            CatalogFunction(name: "decode"),
        ],
        availability: .conditional
    )
}
