// File: Sources/RatatuiKit/Layout.swift
// Role: Swift-idiomatic wrapper around rffi_layout_split, which partitions a
//       parent rectangle into child rectangles according to a set of constraints.
//       Exposes Constraint and Direction enums matching the shim's constants.
// Upstream: CRatatuiFFI (rffi_layout_split, RffiRect, constraint_kind constants)
// Downstream: MoonSwiftTUI/Render/Renderer.swift (layout math for pane splits)

import CRatatuiFFI

// MARK: - Rect

/// A rectangle in terminal cell coordinates (0-based, columns × rows).
///
/// Mirrors `RffiRect` exactly so callers never hold a raw C struct.
public struct Rect: Sendable, Equatable {
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts to the C `RffiRect` for FFI calls.
    var rffi: RffiRect {
        RffiRect(x: x, y: y, width: width, height: height)
    }
}

extension Rect {
    /// Constructs a `Rect` from the C `RffiRect` received from the shim.
    init(_ rffi: RffiRect) {
        self.init(x: rffi.x, y: rffi.y, width: rffi.width, height: rffi.height)
    }
}

// MARK: - Constraint

/// A layout constraint expressing how a child rectangle claims space from
/// its parent. Matches the `constraint_kind` constants from the shim header.
///
/// - `length(n)`: fixed cell count.
/// - `percentage(pct)`: percentage of the parent (0–100).
/// - `min(n)`: minimum cell count; takes as much as available above `n`.
/// - `max(n)`: maximum cell count.
/// - `fill(weight)`: proportional share of remaining space; `weight` is the
///   numerator of a fill-weight ratio among all sibling `fill` constraints.
/// - `ratio(num, den)`: `num/den` of the parent.
public enum Constraint: Sendable {
    case length(UInt16)
    case percentage(UInt16)
    case min(UInt16)
    case max(UInt16)
    case fill(UInt16 = 1)
    case ratio(UInt16, UInt16)

    // The shim's `constraint_kind` discriminant values (ratatui_ffi.h).
    var kind: UInt32 {
        switch self {
        case .length:     return UInt32(LENGTH)
        case .percentage: return UInt32(PERCENTAGE)
        case .min:        return UInt32(MIN)
        case .max:        return UInt32(MAX)
        case .fill:       return UInt32(FILL)
        case .ratio:      return UInt32(RATIO)
        }
    }

    /// Primary value (`value_a` in the shim parameter list).
    var valueA: UInt16 {
        switch self {
        case .length(let n):     return n
        case .percentage(let p): return p
        case .min(let n):        return n
        case .max(let n):        return n
        case .fill(let w):       return w
        case .ratio(let n, _):   return n
        }
    }

    /// Secondary value (`value_b` in the shim — only meaningful for `.ratio`).
    var valueB: UInt16 {
        switch self {
        case .ratio(_, let d): return d
        default:               return 1
        }
    }
}

// MARK: - Direction

/// The axis along which a layout split partitions the parent rectangle.
///
/// - `vertical`: children are stacked top-to-bottom (rows are split).
/// - `horizontal`: children sit side-by-side (columns are split).
public enum Direction: UInt32, Sendable {
    /// Children stacked vertically (top to bottom). `direction = 0` in shim.
    case vertical   = 0
    /// Children arranged horizontally (left to right). `direction = 1` in shim.
    case horizontal = 1
}

// MARK: - layout(parent:direction:constraints:spacing:)

/// Splits a parent rectangle into child rectangles according to the given
/// constraints, with an optional gap between each child.
///
/// Thread class: render/terminal-class (UI thread only).
///
/// - Parameters:
///   - parent: The rectangle to partition.
///   - direction: The split axis.
///   - constraints: One `Constraint` per desired child rectangle.
///   - spacing: Gap in cells between consecutive children (default 0).
/// - Returns: An array of `Rect` values, one per constraint, in order.
/// - Throws: `FFIError` if the shim returns an error code.
public func layout(
    parent: Rect,
    direction: Direction,
    constraints: [Constraint],
    spacing: UInt16 = 0
) throws -> [Rect] {
    let count = constraints.count
    guard count > 0 else { return [] }

    let kinds  = constraints.map { $0.kind }
    let valA   = constraints.map { $0.valueA }
    let valB   = constraints.map { $0.valueB }

    // Allocate the output buffer on the stack via a Swift array.
    var outRects = [RffiRect](repeating: RffiRect(), count: count)

    let written = try kinds.withUnsafeBufferPointer { kindsBuf in
        try valA.withUnsafeBufferPointer { aBuf in
            try valB.withUnsafeBufferPointer { bBuf in
                try outRects.withUnsafeMutableBufferPointer { outBuf in
                    let result = rffi_layout_split(
                        parent.rffi,
                        direction.rawValue,
                        kindsBuf.baseAddress,
                        aBuf.baseAddress,
                        bBuf.baseAddress,
                        count,
                        spacing,
                        outBuf.baseAddress,
                        count
                    )
                    if result < 0 {
                        throw FFIError(code: result, message: FFIError.lastErrorMessage())
                    }
                    return Int(result)
                }
            }
        }
    }

    return outRects.prefix(written).map { Rect($0) }
}
