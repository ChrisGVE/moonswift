// File: Tests/MoonSwiftCoreTests/Debug/DebugSnapshotTests.swift
// Location: MoonSwiftCoreTests/Debug/
// Role: Contract tests for the DebugSnapshot value-model family (#25).
//
//       DebugSnapshot, DebugVariable, DebugFrame, DebugSessionID and
//       DebugEventKind are PURE data models with NO behaviour (see the type's
//       own header: "No producer logic lives here"). The meaningful MAPPING
//       logic — fragmentLine = engineLine - lineOffset, the (cycle)/(…) value
//       markers, and the 256-entry globals breadth cap + elision marker — all
//       lives in the F6.0 hook adapter and is exercised against a real LuaSwift
//       engine in DebugHookAdapterTests. THIS file therefore asserts only the
//       container contracts the models themselves own: field round-trip, the
//       frameVars level-keying convention (DATA-N01), the published breadth-cap
//       constant, and DebugSessionID identity. It deliberately does NOT restate
//       marker/elision strings as constructed-then-read-back values — that would
//       be test theatre that passes regardless of the adapter's real output.
//
// Upstream: DebugSnapshot, DebugFrame, DebugVariable, DebugSessionID,
//           DebugEventKind

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

/// Builds a minimal DebugSnapshot with the given fields defaulted.
private func snapshot(
    fragmentLine: Int = 1,
    callStack: [DebugFrame] = [],
    frameVars: [Int: ([DebugVariable], [DebugVariable])] = [:],
    globals: [DebugVariable]? = nil
) -> DebugSnapshot {
    DebugSnapshot(
        sessionID: DebugSessionID(),
        event: .line,
        fragmentLine: fragmentLine,
        callStack: callStack,
        frameVars: frameVars,
        globals: globals
    )
}

// MARK: - Suite

@Suite("DebugSnapshot value models")
struct DebugSnapshotTests {

    // MARK: fragmentLine — container contract only

    // The offset SUBTRACTION (engineLine - lineOffset) is the adapter's job and
    // is proven against a real engine in DebugHookAdapterTests
    // (`fragmentLine == 1`, `== 2` with offset fragments). Here we only assert
    // the field carries the already-applied value faithfully.
    @Test("fragmentLine carries the offset-applied value the adapter passed in")
    func fragmentLineRoundTrips() {
        #expect(snapshot(fragmentLine: 32).fragmentLine == 32)
        #expect(snapshot(fragmentLine: 1).fragmentLine == 1)
    }

    // MARK: frameVars — level-keying convention (DATA-N01)

    @Test("frameVars is keyed by frame level; level 0 is the current frame")
    func frameVarsKeyedByLevel() {
        let currentLocals = [DebugVariable(name: "x", displayValue: "1")]
        let callerLocals = [DebugVariable(name: "y", displayValue: "2")]
        let snap = snapshot(frameVars: [
            0: (currentLocals, []),
            1: (callerLocals, []),
        ])

        let (locals0, upvalues0) = try! #require(snap.frameVars[0])
        #expect(locals0 == currentLocals)
        #expect(upvalues0.isEmpty)
        #expect(snap.frameVars[1]?.0 == callerLocals)
    }

    @Test("frameVars returns nil for an absent frame level")
    func frameVarsMissingLevelIsNil() {
        let snap = snapshot(frameVars: [:])
        #expect(snap.frameVars[0] == nil)
        #expect(snap.frameVars[99] == nil)
    }

    // MARK: DebugVariable — children wiring

    @Test("an expandable value carries its children; a leaf carries nil")
    func variableChildrenWiring() {
        let child = DebugVariable(name: "key", displayValue: "\"value\"")
        let table = DebugVariable(name: "t", displayValue: "table", children: [child])
        let leaf = DebugVariable(name: "n", displayValue: "1")
        #expect(table.children == [child])
        #expect(leaf.children == nil)
    }

    // MARK: Globals breadth-cap constant

    // The published cap. The actual capping + `(… N more globals)` elision
    // marker is adapter behaviour, asserted against a real engine in
    // DebugHookAdapterTests once the elision marker is implemented (see the
    // tracked globals-elision issue).
    @Test("globalsBreadthCap is the published 256-entry ceiling")
    func globalsBreadthCapIs256() {
        #expect(DebugSnapshot.globalsBreadthCap == 256)
    }

    // MARK: DebugSessionID identity

    @Test("each DebugSessionID is unique and usable as a Dictionary key")
    func sessionIDIdentity() {
        let a = DebugSessionID()
        let b = DebugSessionID()
        #expect(a != b)
        var registry: [DebugSessionID: Int] = [:]
        registry[a] = 1
        registry[b] = 2
        #expect(registry[a] == 1)
        #expect(registry[b] == 2)
    }

    // MARK: DebugEventKind

    @Test("DebugEventKind cases are distinct and Equatable")
    func eventKindEquatable() {
        #expect(DebugEventKind.line == .line)
        #expect(DebugEventKind.breakpoint == .breakpoint)
        #expect(DebugEventKind.line != .breakpoint)
    }
}
