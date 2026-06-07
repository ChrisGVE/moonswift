// File: Sources/MoonSwiftCore/Catalog/Modules/Module+SVG.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.svg — SVG document generation via a Lua
//       Drawing object whose methods are installed as a metatable.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/SVGModule.swift
//       (svgLuaWrapper: luaswift.svg = {} + Drawing metatable methods rect, circle,
//        ellipse, line, polyline, polygon, path, text, group, render, clear, count;
//        module-level: new, translate, rotate, scale; greek sub-table omitted as
//        a data table, not a callable).
//
//       Note: Drawing:method() syntax lives on the metatable of objects returned
//       by svg.new(). For luacheck globals we list the module-table callables only.
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.svg` — SVG document generation (also aliased as `svg_module` global).
    static let svg = CatalogModule(
        tableName: "svg",
        functions: [
            // Factory: creates a new Drawing object with the given width/height
            CatalogFunction(name: "create"),
            // Transform string helpers
            CatalogFunction(name: "translate"),
            CatalogFunction(name: "rotate"),
            CatalogFunction(name: "scale"),
        ],
        availability: .base
    )
}
