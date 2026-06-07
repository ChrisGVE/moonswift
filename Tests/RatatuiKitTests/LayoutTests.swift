// File: Tests/RatatuiKitTests/LayoutTests.swift
// Role: Verifies the RatatuiKit Layout wrappers: Rect, Constraint, Direction,
//       BorderBits, and the layout() split call via the real Rust shim.
//       The shim is available in source mode (MOONSWIFT_SHIM_SOURCE=1 +
//       make shim); these tests call real FFI but require no tty.
// Upstream: RatatuiKit/Layout.swift (layout(), Rect, Constraint, Direction)
// Downstream: (test target — nothing imports this)

import Testing

@testable import RatatuiKit

// MARK: - Rect

@Suite("Rect")
struct RectTests {

    @Test("Rect stores fields correctly")
    func rectFields() {
        let r = Rect(x: 1, y: 2, width: 80, height: 24)
        #expect(r.x == 1)
        #expect(r.y == 2)
        #expect(r.width == 80)
        #expect(r.height == 24)
    }

    @Test("Rect equality")
    func rectEquality() {
        let a = Rect(x: 0, y: 0, width: 40, height: 12)
        let b = Rect(x: 0, y: 0, width: 40, height: 12)
        let c = Rect(x: 1, y: 0, width: 40, height: 12)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Constraint

@Suite("Constraint values")
struct ConstraintTests {

    @Test("Constraint.length kind and valueA")
    func lengthConstraint() {
        let c = Constraint.length(30)
        #expect(c.kind == 0)  // LENGTH = 0 from ratatui_ffi.h
        #expect(c.valueA == 30)
        #expect(c.valueB == 1)  // unused
    }

    @Test("Constraint.percentage kind and valueA")
    func percentageConstraint() {
        let c = Constraint.percentage(50)
        #expect(c.kind == 1)  // PERCENTAGE = 1
        #expect(c.valueA == 50)
    }

    @Test("Constraint.fill default weight is 1")
    func fillDefaultWeight() {
        let c = Constraint.fill()
        #expect(c.kind == 5)  // FILL = 5
        #expect(c.valueA == 1)
    }

    @Test("Constraint.ratio carries numerator and denominator")
    func ratioConstraint() {
        let c = Constraint.ratio(1, 3)
        #expect(c.kind == 4)  // RATIO = 4
        #expect(c.valueA == 1)
        #expect(c.valueB == 3)
    }
}

// MARK: - BorderBits

@Suite("BorderBits")
struct BorderBitsTests {

    @Test("BorderBits.all includes all four edges")
    func allIncludesFourEdges() {
        let all = BorderBits.all
        #expect(all.contains(.top))
        #expect(all.contains(.right))
        #expect(all.contains(.bottom))
        #expect(all.contains(.left))
    }

    @Test("BorderBits individual edges are distinct")
    func individualEdgesDistinct() {
        let top = BorderBits.top
        let right = BorderBits.right
        let bottom = BorderBits.bottom
        let left = BorderBits.left
        #expect(!top.contains(.right))
        #expect(!right.contains(.bottom))
        #expect(!bottom.contains(.left))
        #expect(!left.contains(.top))
    }

    @Test("BorderBits union combines edges")
    func unionCombinesEdges() {
        let tb: BorderBits = [.top, .bottom]
        #expect(tb.contains(.top))
        #expect(tb.contains(.bottom))
        #expect(!tb.contains(.left))
        #expect(!tb.contains(.right))
    }
}

// MARK: - Direction

@Suite("Direction")
struct DirectionTests {

    @Test("Direction raw values match shim constants")
    func directionRawValues() {
        #expect(Direction.vertical.rawValue == 0)
        #expect(Direction.horizontal.rawValue == 1)
    }
}

// MARK: - layout() FFI call

@Suite("layout() — FFI split call")
struct LayoutSplitTests {

    @Test("empty constraints returns empty array")
    func emptyConstraints() throws {
        let parent = Rect(x: 0, y: 0, width: 80, height: 24)
        let result = try layout(parent: parent, direction: .vertical, constraints: [])
        #expect(result.isEmpty)
    }

    @Test("single length constraint returns parent region")
    func singleLengthConstraint() throws {
        let parent = Rect(x: 0, y: 0, width: 80, height: 24)
        let result = try layout(
            parent: parent,
            direction: .vertical,
            constraints: [.length(24)]
        )
        #expect(result.count == 1)
        #expect(result[0].x == 0)
        #expect(result[0].y == 0)
        #expect(result[0].width == 80)
    }

    @Test("two percentage constraints produce two non-overlapping rects")
    func twoPercentageSplit() throws {
        let parent = Rect(x: 0, y: 0, width: 80, height: 24)
        let result = try layout(
            parent: parent,
            direction: .vertical,
            constraints: [.percentage(50), .percentage(50)]
        )
        #expect(result.count == 2)
        // First rect starts at top, second at bottom — no overlap.
        #expect(result[0].y == 0)
        #expect(result[1].y >= result[0].height)
    }

    @Test("horizontal split produces side-by-side rects sharing same row")
    func horizontalSplit() throws {
        let parent = Rect(x: 0, y: 0, width: 80, height: 24)
        let result = try layout(
            parent: parent,
            direction: .horizontal,
            constraints: [.percentage(30), .percentage(70)]
        )
        #expect(result.count == 2)
        // Both rects should be on row 0 (same y).
        #expect(result[0].y == result[1].y)
        // Second rect starts after the first.
        #expect(result[1].x >= result[0].width)
    }

    @Test("three fill constraints produce three non-zero-width rects")
    func threeFillConstraints() throws {
        let parent = Rect(x: 0, y: 0, width: 90, height: 30)
        let result = try layout(
            parent: parent,
            direction: .horizontal,
            constraints: [.fill(), .fill(), .fill()]
        )
        #expect(result.count == 3)
        for rect in result {
            #expect(rect.width > 0)
        }
    }
}
