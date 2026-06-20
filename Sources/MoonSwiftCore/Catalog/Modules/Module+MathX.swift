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
//       Signatures sourced from MathXModule.swift callback implementations and
//       the module-level Lua API doc comment.
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
            // Source: MathXModule.swift sinCallback — real or complex number
            CatalogFunction(
                name: "sin",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Sine of x. Accepts real numbers or complex tables; returns complex when x is complex."
            ),
            CatalogFunction(
                name: "cos",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Cosine of x. Accepts real numbers or complex tables; returns complex when x is complex."
            ),
            CatalogFunction(
                name: "tan",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Tangent of x. Accepts real numbers or complex tables; returns complex when x is complex."
            ),
            // Exponential/log/sqrt with complex dispatch
            // Source: MathXModule.swift expCallback
            CatalogFunction(
                name: "exp",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "e^x. Accepts real numbers or complex tables; returns complex when x is complex."
            ),
            // Source: MathXModule.swift logCallback
            CatalogFunction(
                name: "log",
                params: [
                    CatalogParam(name: "x", type: "number|table"),
                    CatalogParam(name: "base", type: "number", isOptional: true),
                ],
                returns: "number|table",
                doc:
                    "Natural logarithm of x (or log base `base` if provided). Accepts real or complex; returns complex for negative real input."
            ),
            // Source: MathXModule.swift sqrtCallback
            CatalogFunction(
                name: "sqrt",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Square root of x. Returns complex when x is negative or complex."
            ),
            // Hyperbolic functions
            // Source: MathXModule.swift sinhCallback — real or complex
            CatalogFunction(
                name: "sinh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Hyperbolic sine of x. Accepts real or complex."
            ),
            CatalogFunction(
                name: "cosh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Hyperbolic cosine of x. Accepts real or complex."
            ),
            CatalogFunction(
                name: "tanh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Hyperbolic tangent of x. Accepts real or complex."
            ),
            CatalogFunction(
                name: "asinh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Inverse hyperbolic sine of x. Accepts real or complex."
            ),
            CatalogFunction(
                name: "acosh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Inverse hyperbolic cosine of x. For real x < 1 returns complex. Accepts real or complex."
            ),
            CatalogFunction(
                name: "atanh",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc:
                    "Inverse hyperbolic tangent of x. For real |x| >= 1 returns complex or ±inf. Accepts real or complex."
            ),
            // Rounding
            // Source: MathXModule.swift roundCallback — args[0]=x, args[1]=n?
            CatalogFunction(
                name: "round",
                params: [
                    CatalogParam(name: "x", type: "number"),
                    CatalogParam(name: "n", type: "number", isOptional: true),
                ],
                returns: "number",
                doc: "Round x to the nearest integer, or to n decimal places when n is given."
            ),
            // Source: MathXModule.swift truncCallback — args[0]=x
            CatalogFunction(
                name: "trunc",
                params: [CatalogParam(name: "x", type: "number")],
                returns: "number",
                doc: "Truncate x toward zero (remove fractional part)."
            ),
            // Source: MathXModule.swift signCallback — args[0]=x; returns -1, 0, or 1
            CatalogFunction(
                name: "sign",
                params: [CatalogParam(name: "x", type: "number")],
                returns: "number",
                doc: "Return the sign of x: -1, 0, or 1."
            ),
            // Logarithms
            // Source: MathXModule.swift log10Callback — real or complex
            CatalogFunction(
                name: "log10",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Base-10 logarithm of x. Returns complex for negative real input."
            ),
            CatalogFunction(
                name: "log2",
                params: [CatalogParam(name: "x", type: "number|table")],
                returns: "number|table",
                doc: "Base-2 logarithm of x. Returns complex for negative real input."
            ),
            // Statistics
            // Source: MathXModule.swift sumCallback — args[0]=array table
            CatalogFunction(
                name: "sum",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc: "Return the sum of all numeric values in array t."
            ),
            CatalogFunction(
                name: "mean",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc: "Return the arithmetic mean of the numeric values in array t."
            ),
            CatalogFunction(
                name: "median",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc: "Return the median of the numeric values in array t."
            ),
            // Source: MathXModule.swift varianceCallback — args[0]=t, args[1]=ddof?
            CatalogFunction(
                name: "variance",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "ddof", type: "number", isOptional: true),
                ],
                returns: "number",
                doc:
                    "Return the variance of the numeric values in array t. ddof (delta degrees of freedom) defaults to 0 (population variance); pass 1 for sample variance."
            ),
            CatalogFunction(
                name: "stddev",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "ddof", type: "number", isOptional: true),
                ],
                returns: "number",
                doc:
                    "Return the standard deviation of the numeric values in array t. ddof defaults to 0 (population); pass 1 for sample standard deviation."
            ),
            // Source: MathXModule.swift percentileCallback — args[0]=t, args[1]=p
            CatalogFunction(
                name: "percentile",
                params: [
                    CatalogParam(name: "t", type: "table"),
                    CatalogParam(name: "p", type: "number"),
                ],
                returns: "number",
                doc: "Return the p-th percentile (0–100) of the numeric values in array t using linear interpolation."
            ),
            CatalogFunction(
                name: "gmean",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc: "Return the geometric mean of the positive numeric values in array t."
            ),
            CatalogFunction(
                name: "hmean",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "number",
                doc: "Return the harmonic mean of the positive numeric values in array t."
            ),
            // Source: MathXModule.swift modeCallback — returns most frequent value(s)
            CatalogFunction(
                name: "mode",
                params: [CatalogParam(name: "t", type: "table")],
                returns: "any",
                doc:
                    "Return the most frequently occurring value(s) in array t. Returns a single value when the mode is unique, or a table of values when there are ties."
            ),
            // Special functions
            // Source: MathXModule.swift factorialCallback — args[0]=n (integer)
            CatalogFunction(
                name: "factorial",
                params: [CatalogParam(name: "n", type: "number")],
                returns: "number",
                doc: "Return n! (n factorial). n must be a non-negative integer."
            ),
            // Source: MathXModule.swift gammaCallback — args[0]=x
            CatalogFunction(
                name: "gamma",
                params: [CatalogParam(name: "x", type: "number")],
                returns: "number",
                doc: "Return the gamma function Γ(x). For positive integers, Γ(n) = (n-1)!."
            ),
            // Source: MathXModule.swift lgammaCallback — args[0]=x
            CatalogFunction(
                name: "lgamma",
                params: [CatalogParam(name: "x", type: "number")],
                returns: "number",
                doc: "Return the natural logarithm of the absolute value of the gamma function ln|Γ(x)|."
            ),
            // Combinatorics
            // Source: MathXModule.swift permCallback — args[0]=n, args[1]=k
            CatalogFunction(
                name: "perm",
                params: [
                    CatalogParam(name: "n", type: "number"),
                    CatalogParam(name: "k", type: "number"),
                ],
                returns: "number",
                doc: "Return the number of k-permutations of n: P(n,k) = n! / (n-k)!."
            ),
            // Source: MathXModule.swift combCallback — args[0]=n, args[1]=k
            CatalogFunction(
                name: "comb",
                params: [
                    CatalogParam(name: "n", type: "number"),
                    CatalogParam(name: "k", type: "number"),
                ],
                returns: "number",
                doc: "Return the binomial coefficient C(n,k) = n! / (k! * (n-k)!). Alias: mathx.binomial."
            ),
            // Source: MathXModule.swift — registered as alias for combCallback
            CatalogFunction(
                name: "binomial",
                params: [
                    CatalogParam(name: "n", type: "number"),
                    CatalogParam(name: "k", type: "number"),
                ],
                returns: "number",
                doc: "Alias for mathx.comb. Return the binomial coefficient C(n,k)."
            ),
            // Coordinate conversions
            // Source: MathXModule.swift polarToCartCallback — args[0]=r, args[1]=theta
            CatalogFunction(
                name: "polar_to_cart",
                params: [
                    CatalogParam(name: "r", type: "number"),
                    CatalogParam(name: "theta", type: "number"),
                ],
                returns: "number, number",
                doc: "Convert polar (r, theta) to Cartesian (x, y). theta is in radians. Returns two values: x, y."
            ),
            // Source: MathXModule.swift cartToPolarCallback — args[0]=x, args[1]=y
            CatalogFunction(
                name: "cart_to_polar",
                params: [
                    CatalogParam(name: "x", type: "number"),
                    CatalogParam(name: "y", type: "number"),
                ],
                returns: "number, number",
                doc: "Convert Cartesian (x, y) to polar (r, theta). theta is in radians. Returns two values: r, theta."
            ),
            // Source: MathXModule.swift sphericalToCartCallback — args[0]=r, args[1]=theta, args[2]=phi
            CatalogFunction(
                name: "spherical_to_cart",
                params: [
                    CatalogParam(name: "r", type: "number"),
                    CatalogParam(name: "theta", type: "number"),
                    CatalogParam(name: "phi", type: "number"),
                ],
                returns: "number, number, number",
                doc:
                    "Convert spherical (r, theta, phi) to Cartesian (x, y, z). theta is polar angle, phi is azimuthal angle, both in radians. Returns three values: x, y, z."
            ),
            // Source: MathXModule.swift cartToSphericalCallback — args[0]=x, args[1]=y, args[2]=z
            CatalogFunction(
                name: "cart_to_spherical",
                params: [
                    CatalogParam(name: "x", type: "number"),
                    CatalogParam(name: "y", type: "number"),
                    CatalogParam(name: "z", type: "number"),
                ],
                returns: "number, number, number",
                doc:
                    "Convert Cartesian (x, y, z) to spherical (r, theta, phi). Returns three values: r, theta, phi (angles in radians)."
            ),
            // Complex-only functions
            // Source: MathXModule.swift csqrtCallback — complex-aware sqrt
            CatalogFunction(
                name: "csqrt",
                params: [CatalogParam(name: "z", type: "table")],
                returns: "table",
                doc:
                    "Complex square root of z. Unlike mathx.sqrt, always returns a complex result even for positive real input."
            ),
            // Source: MathXModule.swift clogCallback — complex-aware log
            CatalogFunction(
                name: "clog",
                params: [CatalogParam(name: "z", type: "table")],
                returns: "table",
                doc: "Complex natural logarithm of z. Always returns a complex result."
            ),
            // Stdlib injection helper
            // Source: MathXModule.swift Lua run block — import() extends math table
            CatalogFunction(
                name: "import",
                params: [],
                returns: nil,
                doc:
                    "Inject all mathx functions and constants into the standard math table, enabling math.sinh, math.round, math.sum, etc."
            ),
        ],
        availability: .base
    )
}
