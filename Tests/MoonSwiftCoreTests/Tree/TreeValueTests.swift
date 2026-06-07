// File: Tests/MoonSwiftCoreTests/Tree/TreeValueTests.swift
// Role: Unit tests for the TreeValue enum itself — Equatable conformance,
//       Sendable (compile-time), and structural correctness.
// Upstream: MoonSwiftCore/Tree/TreeValue.swift
// Downstream: (test target)

import Testing
import Collections
@testable import MoonSwiftCore

// MARK: - Equatable

@Suite("TreeValue — Equatable")
struct TreeValueEquatableTests {

    @Test("equal scalars")
    func equalScalars() {
        #expect(TreeValue.string("hi") == TreeValue.string("hi"))
        #expect(TreeValue.int(42) == TreeValue.int(42))
        #expect(TreeValue.double(1.5) == TreeValue.double(1.5))
        #expect(TreeValue.bool(true) == TreeValue.bool(true))
        #expect(TreeValue.null == TreeValue.null)
    }

    @Test("unequal scalars of same case")
    func unequalScalars() {
        #expect(TreeValue.string("a") != TreeValue.string("b"))
        #expect(TreeValue.int(1) != TreeValue.int(2))
        #expect(TreeValue.double(1.0) != TreeValue.double(2.0))
        #expect(TreeValue.bool(true) != TreeValue.bool(false))
    }

    @Test("unequal across different cases")
    func unequalCrossCases() {
        #expect(TreeValue.int(1) != TreeValue.double(1.0))
        #expect(TreeValue.string("null") != TreeValue.null)
        #expect(TreeValue.bool(false) != TreeValue.null)
    }

    @Test("equal empty array and map")
    func emptyCollections() {
        #expect(TreeValue.array([]) == TreeValue.array([]))
        #expect(TreeValue.map([:]) == TreeValue.map([:]))
    }

    @Test("equal arrays with elements")
    func equalArrays() {
        let a: TreeValue = .array([.int(1), .string("x")])
        let b: TreeValue = .array([.int(1), .string("x")])
        #expect(a == b)
    }

    @Test("unequal arrays — different element")
    func unequalArrays() {
        let a: TreeValue = .array([.int(1)])
        let b: TreeValue = .array([.int(2)])
        #expect(a != b)
    }

    @Test("equal maps with same keys and values")
    func equalMaps() {
        var m1 = OrderedDictionary<String, TreeValue>()
        m1["a"] = .int(1)
        m1["b"] = .string("x")
        var m2 = OrderedDictionary<String, TreeValue>()
        m2["a"] = .int(1)
        m2["b"] = .string("x")
        #expect(TreeValue.map(m1) == TreeValue.map(m2))
    }

    @Test("maps with same keys different order are unequal")
    func mapsOrderMatters() {
        // OrderedDictionary equality is order-sensitive.
        var m1 = OrderedDictionary<String, TreeValue>()
        m1["a"] = .int(1)
        m1["b"] = .int(2)
        var m2 = OrderedDictionary<String, TreeValue>()
        m2["b"] = .int(2)
        m2["a"] = .int(1)
        // Two OrderedDictionaries with the same keys/values but different
        // insertion order are NOT equal (by OrderedDictionary semantics).
        #expect(TreeValue.map(m1) != TreeValue.map(m2))
    }
}

// MARK: - Sendable (compile-time verification)

// If TreeValue is not Sendable the code below will not compile.
// No runtime assertion needed — the test is the successful build.

@Suite("TreeValue — Sendable")
struct TreeValueSendableTests {

    @Test("TreeValue can be passed across concurrency boundaries")
    func sendable() async {
        let value: TreeValue = .string("concurrent")
        let result = await Task.detached { value }.value
        #expect(result == .string("concurrent"))
    }
}
