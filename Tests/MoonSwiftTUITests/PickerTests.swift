// File: Tests/MoonSwiftTUITests/PickerTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for the structured-file picker modal — PickerTree traversal,
//       PickerState lifecycle, reducer key handling, save/cancel flows,
//       dirty-state confirmation, parse-error handling, and pickerTreeReady
//       event wiring.
// Upstream: Reducer.swift, AppState.swift (PickerState), Picker/PickerTree.swift,
//           AppEvent.swift, Effect.swift
// Downstream: (test target)

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Fixtures

/// A small JSON document for tree-traversal tests.
private let sampleJSON = """
    {
        "name": "moonswift",
        "version": "1.0",
        "nested": {
            "key": "value",
            "flag": true
        },
        "scripts": ["run.lua", "lint.lua"]
    }
    """

/// Decodes the sample JSON into a TreeValue, asserting success.
private func sampleTree() -> TreeValue {
    let tree = try? decodeJSON(sampleJSON)
    precondition(tree != nil, "sampleJSON must decode successfully")
    return tree!
}

/// Builds a minimal AppState with the picker open and a loaded tree.
private func pickerState(
    sourceID: SourceID = SourceID(path: "conf.json", jsonpath: nil),
    filePath: String = "conf.json",
    tree: PickerTree? = nil,
    parseError: String? = nil,
    marks: Set<String> = [],
    preExistingMarks: Set<String> = [],
    cursorRow: Int = 0,
    awaitingDiscardConfirmation: Bool = false
) -> PickerState {
    PickerState(
        sourceID: sourceID,
        filePath: filePath,
        tree: tree,
        parseError: parseError,
        cursorRow: cursorRow,
        marks: marks,
        preExistingMarks: preExistingMarks,
        awaitingDiscardConfirmation: awaitingDiscardConfirmation
    )
}

/// Builds a minimal AppState with focus = .pickerModal and pickerState set.
private func appStateWithPicker(_ picker: PickerState) -> AppState {
    var state = AppState()
    state.pickerState = picker
    state.focus = .pickerModal
    return state
}

// MARK: - PickerTree traversal

@Suite("PickerTree — visibleRows")
struct PickerTreeTraversalTests {

    @Test("flat map: all top-level keys appear as depth-0 rows")
    func flatMapDepthZero() throws {
        let root = try decodeJSON(
            """
            {"a": "hello", "b": 42, "c": true}
            """)
        let tree = PickerTree(root: root)
        let rows = tree.visibleRows()

        #expect(rows.count == 3, "three top-level keys")
        #expect(rows.allSatisfy { $0.depth == 0 }, "all depth 0")

        let labels = rows.map(\.label)
        #expect(labels.contains("a"))
        #expect(labels.contains("b"))
        #expect(labels.contains("c"))
    }

    @Test("str row has kind .str and is markable")
    func strRowKind() throws {
        let root = try decodeJSON("{\"x\": \"hello\"}")
        let tree = PickerTree(root: root)
        let rows = tree.visibleRows()
        let row = try #require(rows.first)
        #expect(row.kind == .str)
        #expect(row.kind.isMarkable)
        #expect(row.stringValue == "hello")
    }

    @Test("bool row has kind .bool and is not markable")
    func boolRowKind() throws {
        let root = try decodeJSON("{\"x\": true}")
        let tree = PickerTree(root: root)
        let row = try #require(tree.visibleRows().first)
        #expect(row.kind == .bool)
        #expect(!row.kind.isMarkable)
    }

    @Test("int row has kind .int and is not markable")
    func intRowKind() throws {
        let root = try decodeJSON("{\"x\": 99}")
        let tree = PickerTree(root: root)
        let row = try #require(tree.visibleRows().first)
        #expect(row.kind == .int)
        #expect(!row.kind.isMarkable)
    }

    @Test("null row has kind .nullValue")
    func nullRowKind() throws {
        let root = try decodeJSON("{\"x\": null}")
        let tree = PickerTree(root: root)
        let row = try #require(tree.visibleRows().first)
        #expect(row.kind == .nullValue)
        #expect(!row.kind.isMarkable)
    }

    @Test("nested map: top-level map starts expanded, child rows visible")
    func nestedMapAutoExpanded() throws {
        let root = try decodeJSON(
            """
            {"parent": {"child": "value"}}
            """)
        let tree = PickerTree(root: root)
        let rows = tree.visibleRows()

        // "parent" row at depth 0 + "child" row at depth 1
        #expect(rows.count == 2)
        let parentRow = try #require(rows.first)
        #expect(parentRow.label == "parent")
        #expect(parentRow.kind == .obj)
        #expect(parentRow.isExpanded)
        let childRow = rows[1]
        #expect(childRow.label == "child")
        #expect(childRow.depth == 1)
    }

    @Test("array: top-level array auto-expanded, elements visible as [0], [1], …")
    func arrayAutoExpanded() throws {
        let root = try decodeJSON(
            """
            {"items": ["a", "b"]}
            """)
        let tree = PickerTree(root: root)
        let rows = tree.visibleRows()
        // "items" row + 2 element rows
        #expect(rows.count == 3)
        let itemsRow = rows[0]
        #expect(itemsRow.kind == .arr)
        #expect(itemsRow.isExpanded)
        #expect(rows[1].label == "[0]")
        #expect(rows[2].label == "[1]")
    }

    @Test("collapsed obj: children hidden, expand reveals them")
    func collapseExpandObj() throws {
        let root = try decodeJSON(
            """
            {"parent": {"child": "value"}}
            """)
        var tree = PickerTree(root: root)

        // Collapse the parent node.
        let parentID = pickerNormalizedPath(steps: [.key("parent")])
        tree.expanded.remove(parentID)
        #expect(tree.visibleRows().count == 1, "only parent row when collapsed")

        // Expand again.
        tree.expanded.insert(parentID)
        #expect(tree.visibleRows().count == 2, "parent + child after expand")
    }

    @Test("normalized path uses dot notation for safe keys")
    func normalizedPathDotNotation() {
        let path = pickerNormalizedPath(steps: [.key("name")])
        #expect(path == "$.name")
    }

    @Test("normalized path uses bracket notation for unsafe keys")
    func normalizedPathBracketNotation() {
        let path = pickerNormalizedPath(steps: [.key("my-key")])
        #expect(path == "$['my-key']")
    }

    @Test("normalized path uses index notation for array elements")
    func normalizedPathIndex() {
        let path = pickerNormalizedPath(steps: [.key("scripts"), .index(0)])
        #expect(path == "$.scripts[0]")
    }

    @Test("nodeID equals normalized for stable expansion set")
    func nodeIDEqualsNormalized() throws {
        let root = try decodeJSON("{\"x\": \"v\"}")
        let tree = PickerTree(root: root)
        let row = try #require(tree.visibleRows().first)
        #expect(row.nodeID == row.normalized)
    }

    @Test("scalar root: shown as single row at depth 0")
    func scalarRoot() throws {
        let root = try decodeJSON(
            """
            "hello"
            """)
        let tree = PickerTree(root: root)
        let rows = tree.visibleRows()
        #expect(rows.count == 1)
        #expect(rows[0].depth == 0)
        #expect(rows[0].kind == .str)
    }

    @Test("sample tree: all expected labels appear")
    func sampleTreeLabels() {
        let tree = PickerTree(root: sampleTree())
        let rows = tree.visibleRows()
        let labels = Set(rows.map(\.label))
        // Top-level keys always visible.
        #expect(labels.contains("name"))
        #expect(labels.contains("version"))
        #expect(labels.contains("nested"))
        #expect(labels.contains("scripts"))
        // Auto-expanded children.
        #expect(labels.contains("key"))
        #expect(labels.contains("flag"))
        #expect(labels.contains("[0]"))
        #expect(labels.contains("[1]"))
    }
}

// MARK: - PickerState dirty flag

@Suite("PickerState — isDirty")
struct PickerStateDirtyTests {

    @Test("clean when marks equal preExistingMarks")
    func cleanWhenEqual() {
        let marks: Set<String> = ["$.name", "$.version"]
        let picker = pickerState(marks: marks, preExistingMarks: marks)
        #expect(!picker.isDirty)
    }

    @Test("dirty when a mark is added")
    func dirtyWhenMarkAdded() {
        let picker = pickerState(marks: ["$.name"], preExistingMarks: [])
        #expect(picker.isDirty)
    }

    @Test("dirty when a mark is removed")
    func dirtyWhenMarkRemoved() {
        let picker = pickerState(marks: [], preExistingMarks: ["$.name"])
        #expect(picker.isDirty)
    }
}

// MARK: - Reducer: picker key handling

@Suite("Picker — Reducer key handling")
struct PickerReducerTests {

    // MARK: Nil pickerState guard

    @Test("nil pickerState: Esc closes picker modal")
    func nilPickerStateEscCloses() {
        var state = AppState()
        state.focus = .pickerModal
        // pickerState is nil

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator))
    }

    @Test("nil pickerState: non-Esc keys absorbed (focus unchanged)")
    func nilPickerStateAbsorbsKeys() {
        var state = AppState()
        state.focus = .pickerModal

        for code: KeyCode in [.char("j"), .char("k"), .char("s"), .enter, .tab] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(next.focus == .pickerModal, "Key \(code) must not change focus when pickerState is nil")
        }
    }

    // MARK: Loading state (tree is nil, no parseError)

    @Test("loading state: Esc closes")
    func loadingEscCloses() {
        let picker = pickerState(tree: nil, parseError: nil)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator))
        #expect(next.pickerState == nil)
    }

    @Test("loading state: j/k/s/Enter absorbed without changing focus")
    func loadingAbsorbsKeys() {
        let picker = pickerState(tree: nil, parseError: nil)
        let state = appStateWithPicker(picker)

        for code: KeyCode in [.char("j"), .char("k"), .char("s"), .enter] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(next.focus == .pickerModal, "Key \(code) must be absorbed during loading")
        }
    }

    // MARK: Parse error state

    @Test("parse error state: Esc closes")
    func parseErrorEscCloses() {
        let picker = pickerState(parseError: "unexpected token at offset 5")
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator))
        #expect(next.pickerState == nil)
    }

    @Test("parse error state: non-Esc keys absorbed")
    func parseErrorAbsorbsKeys() {
        let picker = pickerState(parseError: "bad JSON")
        let state = appStateWithPicker(picker)

        for code: KeyCode in [.char("j"), .char("s"), .enter] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(next.focus == .pickerModal)
        }
    }

    // MARK: Navigation

    @Test("j moves cursor down, clamped at last row")
    func jMovesDown() throws {
        let root = try decodeJSON("{\"a\": \"x\", \"b\": \"y\", \"c\": \"z\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.pickerState?.cursorRow == 1)

        let (s2, _) = reduce(s1, .key(.char("j"), modifiers: []))
        #expect(s2.pickerState?.cursorRow == 2)

        // Clamp at last row (index 2 of 3 rows)
        let (s3, _) = reduce(s2, .key(.char("j"), modifiers: []))
        #expect(s3.pickerState?.cursorRow == 2, "must clamp at last row")
    }

    @Test("k moves cursor up, clamped at 0")
    func kMovesUp() throws {
        let root = try decodeJSON("{\"a\": \"x\", \"b\": \"y\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, cursorRow: 1)
        let state = appStateWithPicker(picker)

        let (s1, _) = reduce(state, .key(.char("k"), modifiers: []))
        #expect(s1.pickerState?.cursorRow == 0)

        // Clamp at 0
        let (s2, _) = reduce(s1, .key(.char("k"), modifiers: []))
        #expect(s2.pickerState?.cursorRow == 0, "must clamp at 0")
    }

    // MARK: Expand / Collapse

    @Test("Space expands a collapsed obj node")
    func spaceExpandsObj() throws {
        let root = try decodeJSON("{\"parent\": {\"child\": \"v\"}}")
        var tree = PickerTree(root: root)
        // Collapse parent first.
        let parentID = pickerNormalizedPath(steps: [.key("parent")])
        tree.expanded.remove(parentID)
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.char(" "), modifiers: []))
        let expanded = next.pickerState?.tree?.expanded ?? []
        #expect(expanded.contains(parentID), "Space must expand the cursor node")
    }

    @Test("Right arrow expands a collapsed arr node")
    func rightExpandsArr() throws {
        let root = try decodeJSON("{\"items\": [\"a\", \"b\"]}")
        var tree = PickerTree(root: root)
        let itemsID = pickerNormalizedPath(steps: [.key("items")])
        tree.expanded.remove(itemsID)
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.right, modifiers: []))
        let expanded = next.pickerState?.tree?.expanded ?? []
        #expect(expanded.contains(itemsID))
    }

    @Test("Left arrow collapses an expanded obj node")
    func leftCollapsesObj() throws {
        let root = try decodeJSON("{\"parent\": {\"child\": \"v\"}}")
        let tree = PickerTree(root: root)
        // parent is auto-expanded in init.
        let parentID = pickerNormalizedPath(steps: [.key("parent")])
        #expect(tree.expanded.contains(parentID), "precondition: parent is expanded")

        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.left, modifiers: []))
        let expanded = next.pickerState?.tree?.expanded ?? []
        #expect(!expanded.contains(parentID), "Left must collapse the cursor node")
    }

    @Test("collapse clamps cursor to last visible row")
    func collapseClampsCursor() throws {
        let root = try decodeJSON("{\"parent\": {\"c1\": \"v\", \"c2\": \"v\"}}")
        let tree = PickerTree(root: root)
        // parent expanded: rows = [parent(0), c1(1), c2(2)] → 3 rows
        // cursor at row 2 (c2)
        let picker = pickerState(tree: tree, cursorRow: 2)
        let state = appStateWithPicker(picker)

        // Collapse parent (cursor row 0 is parent): press Left from row 0 first.
        // To collapse from row 2 cursor, move cursor to parent (row 0) then collapse.
        let (s1, _) = reduce(state, .key(.char("k"), modifiers: []))
        let (s2, _) = reduce(s1, .key(.char("k"), modifiers: []))
        // cursor now at 0 (parent)
        let (s3, _) = reduce(s2, .key(.left, modifiers: []))
        // after collapse: only 1 row visible → cursor clamped to 0
        #expect(s3.pickerState?.cursorRow == 0)
    }

    // MARK: Mark / Unmark

    @Test("Enter marks a str row")
    func enterMarksStr() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        let marks = next.pickerState?.marks ?? []
        let nameID = pickerNormalizedPath(steps: [.key("name")])
        #expect(marks.contains(nameID), "Enter on str row must add its normalized path to marks")
    }

    @Test("m key marks a str row")
    func mKeyMarksStr() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.char("m"), modifiers: []))
        let marks = next.pickerState?.marks ?? []
        let nameID = pickerNormalizedPath(steps: [.key("name")])
        #expect(marks.contains(nameID))
    }

    @Test("Enter unmarks an already-marked str row")
    func enterUnmarks() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let nameID = pickerNormalizedPath(steps: [.key("name")])
        let picker = pickerState(tree: tree, marks: [nameID], cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        let marks = next.pickerState?.marks ?? []
        #expect(!marks.contains(nameID), "Enter on marked str row must remove the mark")
    }

    @Test("Enter on non-str row (obj) does not add a mark")
    func enterOnObjNoMark() throws {
        let root = try decodeJSON("{\"parent\": {\"child\": \"v\"}}")
        let tree = PickerTree(root: root)
        // Row 0 is the parent (obj kind).
        let picker = pickerState(tree: tree, cursorRow: 0)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        let marks = next.pickerState?.marks ?? []
        #expect(marks.isEmpty, "Enter on obj row must not add any mark")
    }

    // MARK: Save flow

    @Test("s emits saveDesignations with sorted marks and does not close picker directly")
    func sSavesDesignations() throws {
        let root = try decodeJSON("{\"a\": \"x\", \"b\": \"y\"}")
        let tree = PickerTree(root: root)
        let aID = pickerNormalizedPath(steps: [.key("a")])
        let bID = pickerNormalizedPath(steps: [.key("b")])
        let picker = pickerState(tree: tree, marks: [bID, aID])
        let state = appStateWithPicker(picker)

        let (_, effects) = reduce(state, .key(.char("s"), modifiers: []))

        let saveEffect = effects.first {
            if case .saveDesignations = $0 { return true }
            return false
        }
        guard case .saveDesignations(let designations) = saveEffect else {
            #expect(Bool(false), "must emit .saveDesignations effect")
            return
        }
        // Must be sorted alphabetically.
        #expect(designations.map(\.jsonpath) == [aID, bID].sorted())
    }

    @Test("designationsSaved event closes picker and returns focus to navigator")
    func designationsSavedClosesPicker() throws {
        let root = try decodeJSON("{\"a\": \"x\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, marks: ["$.a"])
        var state = appStateWithPicker(picker)
        state.project = .loaded(
            ProjectFile(luaVersion: "5.4"),
            diagnostics: []
        )

        let (next, _) = reduce(state, .designationsSaved)
        #expect(next.pickerState == nil, "picker must be closed after designationsSaved")
        #expect(next.focus == .pane(.navigator), "focus must return to navigator")
    }

    // MARK: Cancel — clean (Esc with no dirty state)

    @Test("Esc on clean picker closes immediately")
    func escCleanCloses() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, marks: [], preExistingMarks: [])
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.pickerState == nil)
        #expect(next.focus == .pane(.navigator))
    }

    // MARK: Cancel — dirty (Esc triggers confirmation)

    @Test("Esc on dirty picker sets awaitingDiscardConfirmation")
    func escDirtyShowsConfirmation() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree, marks: ["$.name"], preExistingMarks: [])
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.escape, modifiers: []))
        #expect(next.pickerState?.awaitingDiscardConfirmation == true)
        #expect(next.focus == .pickerModal, "focus must stay in picker during confirmation")
    }

    @Test("y confirms discard and closes picker")
    func yConfirmsDiscard() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(
            tree: tree,
            marks: ["$.name"],
            preExistingMarks: [],
            awaitingDiscardConfirmation: true
        )
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .key(.char("y"), modifiers: []))
        #expect(next.pickerState == nil, "y must close the picker")
        #expect(next.focus == .pane(.navigator))
    }

    @Test("non-y key during confirmation cancels confirmation and returns to picker")
    func nonYCancelsConfirmation() throws {
        let root = try decodeJSON("{\"name\": \"moonswift\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(
            tree: tree,
            marks: ["$.name"],
            preExistingMarks: [],
            awaitingDiscardConfirmation: true
        )
        let state = appStateWithPicker(picker)

        // 'n' (or any non-y key) returns to the picker without closing.
        let (next, _) = reduce(state, .key(.char("n"), modifiers: []))
        #expect(next.pickerState?.awaitingDiscardConfirmation == false)
        #expect(next.pickerState != nil, "picker must remain open")
        #expect(next.focus == .pickerModal)
    }

    // MARK: pickerTreeReady event

    @Test("pickerTreeReady with matching sourceID populates tree")
    func pickerTreeReadyPopulatesTree() throws {
        let id = SourceID(path: "conf.json", jsonpath: nil)
        let root = try decodeJSON("{\"x\": \"v\"}")
        let picker = pickerState(sourceID: id, tree: nil, parseError: nil)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .pickerTreeReady(id, tree: root, errorMessage: nil))
        #expect(next.pickerState?.tree != nil, "tree must be populated on success")
        #expect(next.pickerState?.parseError == nil)
    }

    @Test("pickerTreeReady with error sets parseError")
    func pickerTreeReadySetsError() {
        let id = SourceID(path: "conf.json", jsonpath: nil)
        let picker = pickerState(sourceID: id, tree: nil, parseError: nil)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .pickerTreeReady(id, tree: nil, errorMessage: "unexpected token"))
        #expect(next.pickerState?.parseError == "unexpected token")
        #expect(next.pickerState?.tree == nil)
    }

    @Test("pickerTreeReady with mismatched sourceID is ignored")
    func pickerTreeReadyMismatchIgnored() {
        let id = SourceID(path: "conf.json", jsonpath: nil)
        let otherId = SourceID(path: "other.json", jsonpath: nil)
        let picker = pickerState(sourceID: id, tree: nil)
        let state = appStateWithPicker(picker)

        let (next, _) = reduce(state, .pickerTreeReady(otherId, tree: nil, errorMessage: "err"))
        // State must be unchanged (neither tree set nor error set)
        #expect(next.pickerState?.tree == nil)
        #expect(next.pickerState?.parseError == nil)
    }

    // MARK: openPickerOrTransient wiring (m key in navigator)

    @Test("m on structured-file in project mode opens picker modal")
    func mOnStructuredFileInProjectMode() {
        let id = SourceID(path: "data.json", jsonpath: "$.scripts[0]")
        let projectRoot = URL(fileURLWithPath: "/project")
        var state = AppState()
        state.navigatorOrder = [id]
        state.navigator = NavigatorState(selectedIndex: 0)
        state.focus = .pane(.navigator)
        state.launch = .project(projectRoot)

        let (next, effects) = reduce(state, .key(.char("m"), modifiers: []))
        #expect(next.focus == .pickerModal)
        #expect(next.pickerState != nil)
        let hasLoad = effects.contains {
            if case .loadPickerTree(let sid, _) = $0 { return sid == id }
            return false
        }
        #expect(hasLoad, "must emit loadPickerTree for the selected source")
    }

    @Test("m on structured-file without project mode shows transient, does not open picker")
    func mOnStructuredFileStandaloneModeTransient() {
        let id = SourceID(path: "data.json", jsonpath: "$.scripts[0]")
        var state = AppState()
        state.navigatorOrder = [id]
        state.navigator = NavigatorState(selectedIndex: 0)
        state.focus = .pane(.navigator)
        state.launch = .empty

        let (next, _) = reduce(state, .key(.char("m"), modifiers: []))
        #expect(next.focus == .pane(.navigator), "picker must not open without project mode")
        #expect(next.transient != nil, "a transient must be shown instead")
    }

    @Test("m on lua-only file shows transient, does not open picker")
    func mOnLuaFileShowsTransient() {
        let id = SourceID(path: "script.lua", jsonpath: nil)
        let projectRoot = URL(fileURLWithPath: "/project")
        var state = AppState()
        state.navigatorOrder = [id]
        state.navigator = NavigatorState(selectedIndex: 0)
        state.focus = .pane(.navigator)
        state.launch = .project(projectRoot)

        let (next, _) = reduce(state, .key(.char("m"), modifiers: []))
        #expect(next.focus == .pane(.navigator))
        #expect(next.transient != nil)
    }

    // MARK: Focus stays in pickerModal under all key inputs

    @Test("all non-navigation keys are absorbed when picker is open with tree")
    func pickerAbsorbsUnknownKeys() throws {
        let root = try decodeJSON("{\"x\": \"v\"}")
        let tree = PickerTree(root: root)
        let picker = pickerState(tree: tree)
        let state = appStateWithPicker(picker)

        // These keys have no picker-specific binding and should be absorbed.
        for code: KeyCode in [.tab, .char("q"), .char("?"), .char("/")] {
            let (next, _) = reduce(state, .key(code, modifiers: []))
            #expect(next.focus == .pickerModal, "Key \(code) must be absorbed in picker")
        }
    }
}
