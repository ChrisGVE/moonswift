// File: Sources/MoonSwiftCore/Catalog/Modules/Module+SVG.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.svg — SVG document generation via a Lua
//       Drawing object whose methods are installed as a metatable.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/SVGModule.swift
//       (svgLuaWrapper: luaswift.svg = {} + Drawing metatable methods rect, circle,
//        ellipse, line, polyline, polygon, path, text, group, render, clear, count;
//        module-level: create, translate, rotate, scale; greek sub-table omitted as
//        a data table, not a callable).
//       Signatures sourced from SVGModule.swift svgLuaWrapper Lua block — each
//       function's parameter list is explicit in the Lua source.
//
//       Note: Drawing:method() syntax lives on the metatable of objects returned
//       by svg.create(). For luacheck globals we list the module-table callables only.
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
            // Source: SVGModule.swift svgLuaWrapper — function svg.create(width, height, options)
            // options: {viewBox=string, background=string}
            CatalogFunction(
                name: "create",
                params: [
                    CatalogParam(name: "width", type: "number"),
                    CatalogParam(name: "height", type: "number"),
                    CatalogParam(name: "options", type: "table", isOptional: true),
                ],
                returns: "table",
                doc:
                    "Create a new SVG Drawing object with the given pixel dimensions. Optional options table accepts {viewBox=string, background=string}. The returned Drawing object has :rect, :circle, :ellipse, :line, :polyline, :polygon, :path, :text, :group, :render, :clear, and :count methods."
            ),
            // Source: SVGModule.swift svgLuaWrapper — function svg.translate(tx, ty)
            CatalogFunction(
                name: "translate",
                params: [
                    CatalogParam(name: "tx", type: "number"),
                    CatalogParam(name: "ty", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Return an SVG transform string for translation by (tx, ty). ty defaults to 0. Use as the transform argument to Drawing:group()."
            ),
            // Source: SVGModule.swift svgLuaWrapper — function svg.rotate(angle, cx, cy)
            CatalogFunction(
                name: "rotate",
                params: [
                    CatalogParam(name: "angle", type: "number"),
                    CatalogParam(name: "cx", type: "number", isOptional: true),
                    CatalogParam(name: "cy", type: "number", isOptional: true),
                ],
                returns: "string",
                doc:
                    "Return an SVG transform string for rotation by angle degrees. Optional cx/cy specify the rotation center point."
            ),
            // Source: SVGModule.swift svgLuaWrapper — function svg.scale(sx, sy)
            CatalogFunction(
                name: "scale",
                params: [
                    CatalogParam(name: "sx", type: "number"),
                    CatalogParam(name: "sy", type: "number", isOptional: true),
                ],
                returns: "string",
                doc: "Return an SVG transform string for scaling by (sx, sy). sy defaults to sx for uniform scaling."
            ),
        ],
        availability: .base
    )
}
