// File: Tests/MoonSwiftCoreTests/Run/LuaValueDisplayTests.swift
// Location: MoonSwiftCoreTests/Run/
// Role: Exhaustiveness + contract tests for the single shared `LuaValue`
//       renderer (Run/LuaValueDisplay.swift). CR-007/CR-036 unified three
//       former copies (SessionEngine run path, DebugHookAdapter trace path,
//       AppDriver invoke path) onto `renderLuaValue`; this test pins the
//       output for EVERY `LuaValue` case so a new case (or a divergent edit)
//       fails loudly rather than rendering differently across surfaces.
//
// Upstream: LuaSwift (LuaValue, LuaRefKind)
// Downstream: renderLuaValue, luaValueDisplayOrNil

import LuaSwift
import Testing

@testable import MoonSwiftCore

@Suite("LuaValue display rendering")
struct LuaValueDisplayTests {
    /// One expectation per `LuaValue` case — exhaustive by construction. If a
    /// new case is added to `LuaValue`, the `switch` in `renderLuaValue` stops
    /// compiling; this list is the companion reminder to extend the contract.
    @Test("renderLuaValue covers every LuaValue case")
    func rendersEveryCase() {
        #expect(renderLuaValue(.string("hi")) == "hi")
        // Integer-valued numbers drop the `.0`; true fractions keep it.
        #expect(renderLuaValue(.number(42)) == "42")
        #expect(renderLuaValue(.number(-7)) == "-7")
        #expect(renderLuaValue(.number(3.5)) == "3.5")
        #expect(renderLuaValue(.bool(true)) == "true")
        #expect(renderLuaValue(.bool(false)) == "false")
        #expect(renderLuaValue(.nil) == "nil")
        #expect(renderLuaValue(.table([:])) == "table")
        #expect(renderLuaValue(.array([])) == "table")
        #expect(renderLuaValue(.complex(re: 3, im: 4)) == "3.0+4.0i")
        #expect(renderLuaValue(.luaFunction(1)) == "function")
        #expect(renderLuaValue(.opaqueReference(.function)) == "function")
        #expect(renderLuaValue(.opaqueReference(.table)) == "table")
        #expect(renderLuaValue(.opaqueReference(.userdata)) == "userdata")
        #expect(renderLuaValue(.opaqueReference(.thread)) == "thread")
    }

    /// Large integer-valued doubles past the `1e15` exact-integer threshold fall
    /// back to the floating-point form rather than a truncated `Int64`.
    @Test("renderLuaValue keeps the float form beyond the exact-integer range")
    func rendersHugeNumberAsFloat() {
        // Past 1e15 the exact-integer guard fails, so the float form is used
        // verbatim rather than a truncated Int64 conversion.
        #expect(renderLuaValue(.number(1e16)) == String(1e16))
        #expect(renderLuaValue(.number(1e16)) != "10000000000000000")
    }

    /// `luaValueDisplayOrNil` suppresses Lua `nil` (the run-return contract) but
    /// otherwise matches `renderLuaValue`.
    @Test("luaValueDisplayOrNil suppresses nil, delegates otherwise")
    func displayOrNilContract() {
        #expect(luaValueDisplayOrNil(.nil) == nil)
        #expect(luaValueDisplayOrNil(.number(42)) == "42")
        #expect(luaValueDisplayOrNil(.string("x")) == "x")
        #expect(luaValueDisplayOrNil(.opaqueReference(.thread)) == "thread")
    }
}
