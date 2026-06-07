// File: Sources/MoonSwiftCore/Catalog/Modules/Module+MathX.swift
// Folder: Sources/MoonSwiftCore/Catalog/Modules/
// Role: Catalog entry for luaswift.mathx — extended math: hyperbolic, rounding,
//       statistics, combinatorics, coordinate conversions, complex dispatch,
//       and the import() helper.
//
//       Verified against: LuaSwift/Sources/LuaSwift/Modules/Swift/MathXModule.swift
//       (Lua run block: luaswift.mathx = { ... }). Constants (phi, inf, nan) are
//       table fields, not functions; they are omitted from this list because
//       luacheck globals tracks callable symbols. import() is included because
//       luacheck must recognise it as a valid field access.
//
//       Availability: .base — unconditional in ModuleRegistry.
//
// Upstream: CatalogTypes
// Downstream: LuaModuleCatalog.v0

extension CatalogModule {

    /// `luaswift.mathx` — extended math functions (also aliased as `mathx` global).
    static let mathx = CatalogModule(
        tableName: "mathx",
        functions: [
            // Trig with complex dispatch
            CatalogFunction(name: "sin"),
            CatalogFunction(name: "cos"),
            CatalogFunction(name: "tan"),
            // Exponential/log/sqrt with complex dispatch
            CatalogFunction(name: "exp"),
            CatalogFunction(name: "log"),
            CatalogFunction(name: "sqrt"),
            // Hyperbolic functions
            CatalogFunction(name: "sinh"),
            CatalogFunction(name: "cosh"),
            CatalogFunction(name: "tanh"),
            CatalogFunction(name: "asinh"),
            CatalogFunction(name: "acosh"),
            CatalogFunction(name: "atanh"),
            // Rounding
            CatalogFunction(name: "round"),
            CatalogFunction(name: "trunc"),
            CatalogFunction(name: "sign"),
            // Logarithms
            CatalogFunction(name: "log10"),
            CatalogFunction(name: "log2"),
            // Statistics
            CatalogFunction(name: "sum"),
            CatalogFunction(name: "mean"),
            CatalogFunction(name: "median"),
            CatalogFunction(name: "variance"),
            CatalogFunction(name: "stddev"),
            CatalogFunction(name: "percentile"),
            CatalogFunction(name: "gmean"),
            CatalogFunction(name: "hmean"),
            CatalogFunction(name: "mode"),
            // Special functions
            CatalogFunction(name: "factorial"),
            CatalogFunction(name: "gamma"),
            CatalogFunction(name: "lgamma"),
            // Combinatorics
            CatalogFunction(name: "perm"),
            CatalogFunction(name: "comb"),
            CatalogFunction(name: "binomial"),
            // Coordinate conversions
            CatalogFunction(name: "polar_to_cart"),
            CatalogFunction(name: "cart_to_polar"),
            CatalogFunction(name: "spherical_to_cart"),
            CatalogFunction(name: "cart_to_spherical"),
            // Complex-only functions
            CatalogFunction(name: "csqrt"),
            CatalogFunction(name: "clog"),
            // Stdlib injection helper
            CatalogFunction(name: "import"),
        ],
        availability: .base
    )
}
