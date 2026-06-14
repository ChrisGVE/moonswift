// File: Sources/MoonSwiftCore/Run/LuaValueDisplay.swift
// Location: MoonSwiftCore/Run/
// Role: The single PUBLIC `LuaValue` → display-string renderer. Both the engine
//       run path (SessionEngine return-value rendering) and the TUI F5.3 invoke
//       path (AppDriver, rendering the `invokeLuaCall` result for the Output-tab
//       `→ <display>` line, ux-spec §6.3/§7.5) need to turn an introspected
//       `LuaValue` into a Lua-`print`-compatible string. Previously this switch
//       was replicated file-private in SessionEngine (and RunService); promoting
//       ONE copy here removes the duplication and gives the TUI layer access
//       without widening the SessionEngine API.
//
//       Scalars render literally (integers without a fractional part drop the
//       `.0`); compound and reference values render their Lua type name
//       (function-typed → `function`, matching the live-state DATA-N07 rule).
//
// Upstream: LuaSwift (LuaValue)
// Downstream: SessionEngine (return-value rendering), AppDriver+InvokeEffects
//             (F5.3 invoke result), MockLiveState producers

import Foundation
import LuaSwift

/// Render a `LuaValue` to a Lua-`print`-compatible display string.
///
/// `nil` renders as the literal `"nil"`. Use ``luaValueDisplayOrNil(_:)`` when a
/// Lua `nil` should instead suppress output (the run-return-value path).
///
/// - Parameter value: The introspected Lua value.
/// - Returns: The display string.
public func renderLuaValue(_ value: LuaValue) -> String {
    switch value {
    case .string(let s):
        return s
    case .number(let n):
        if n == n.rounded() && !n.isInfinite && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    case .bool(let b):
        return b ? "true" : "false"
    case .nil:
        return "nil"
    case .table, .array:
        return "table"
    case .complex(let re, let im):
        return "\(re)+\(im)i"
    case .luaFunction:
        return "function"
    case .opaqueReference(let kind):
        switch kind {
        case .function: return "function"
        case .table: return "table"
        case .userdata: return "userdata"
        case .thread: return "thread"
        }
    }
}

/// Render a `LuaValue` to a display string, returning `nil` for a Lua `nil` so
/// the caller can suppress the line (the engine run-return-value contract).
///
/// - Parameter value: The introspected Lua value.
/// - Returns: The display string, or `nil` when the value is Lua `nil`.
public func luaValueDisplayOrNil(_ value: LuaValue) -> String? {
    if case .nil = value { return nil }
    return renderLuaValue(value)
}
