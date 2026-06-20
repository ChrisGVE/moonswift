// File: Tests/MoonSwiftTUITests/MockFormTests.swift
// Location: MoonSwiftTUITests/
// Role: P2 F5.4 — the Mock Environment add/edit/delete form reducer: opening
//       (a/e), the type popup, field text entry + enum/bool fields, confirm
//       (commit + Effect.saveMockStore), validation errors, and the
//       `d → [y/N]` delete confirm. Drives reduce() directly.
//
// Upstream: MockFormReducer.swift, MockFormState, Reducer.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func loadedState(
    values: [MockValueDef] = [],
    functions: [MockFunctionDef] = []
) -> AppState {
    var s = AppState()
    let id = SourceID(path: "a.lua")
    let data = Data("x=1".utf8)
    s.sources[id] = .loaded(
        LuaSourceFragment(
            code: "x=1",
            provenance: FragmentProvenance(
                file: URL(fileURLWithPath: "/p/a.lua"), jsonpath: nil, document: 0,
                byteRange: 0..<data.count, lineOffset: 0, contentHash: SHA256.hash(data: data))))
    s.navigatorOrder = [id]
    s.selection = id
    let file = ProjectFile(luaVersion: "5.4", mocks: MockStore(values: values, functions: functions))
    s.project = .loaded(file, diagnostics: [])
    s.mockStore = file.mocks
    s.focus = .pane(.navigator)
    return s
}

private func typeText(_ s: AppState, _ text: String) -> AppState {
    var s = s
    for ch in text.unicodeScalars {
        s = reduce(s, .key(.char(ch), modifiers: [])).0
    }
    return s
}

private func hasSaveMockStore(_ effects: [Effect]) -> Bool {
    effects.contains { if case .saveMockStore = $0 { return true } else { return false } }
}

// MARK: - Open

@Suite("F5.4 — mock form open/cancel")
struct MockFormOpenTests {

    @Test("a opens the type popup with focus on the form")
    func aOpensPopup() {
        let (next, _) = reduce(loadedState(), .key(.char("a"), modifiers: []))
        #expect(next.focus == .mockForm)
        #expect(next.mockFormState?.stage == .typePopup)
    }

    @Test("Esc from the form returns to the navigator")
    func escCancels() {
        var s = reduce(loadedState(), .key(.char("a"), modifiers: [])).0
        s = reduce(s, .key(.escape, modifiers: [])).0
        #expect(s.mockFormState == nil)
        #expect(s.focus == .pane(.navigator))
    }
}

// MARK: - Add value

@Suite("F5.4 — add mock value")
struct MockFormAddValueTests {

    @Test("typing a value form and confirming appends to the store and auto-saves")
    func addValueConfirm() {
        var s = reduce(loadedState(), .key(.char("a"), modifiers: [])).0
        s = reduce(s, .key(.char("v"), modifiers: [])).0  // → value fields
        #expect(s.mockFormState?.kind == .value)
        #expect(s.mockFormState?.stage == .fields)

        s = typeText(s, "myapp")  // Namespace (field 0)
        s = reduce(s, .key(.tab, modifiers: [])).0
        s = typeText(s, "timeout")  // Key path (field 1)
        s = reduce(s, .key(.tab, modifiers: [])).0  // → Type (field 2)
        s = reduce(s, .key(.tab, modifiers: [])).0  // → Value (field 3)
        s = typeText(s, "30")  // Value

        let (after, effects) = reduce(s, .key(.enter, modifiers: []))
        #expect(after.focus == .pane(.navigator))
        #expect(after.mockFormState == nil)
        #expect(
            after.mockStore.values.contains {
                $0.namespace == "myapp" && $0.path == "timeout" && $0.value == "30"
            })
        #expect(hasSaveMockStore(effects))
    }

    @Test("empty namespace is rejected with an inline error; form stays open")
    func emptyNamespaceError() {
        var s = reduce(loadedState(), .key(.char("a"), modifiers: [])).0
        s = reduce(s, .key(.char("v"), modifiers: [])).0
        let (after, effects) = reduce(s, .key(.enter, modifiers: []))  // all fields empty
        #expect(after.focus == .mockForm)
        #expect(after.mockFormState?.error != nil)
        #expect(after.mockStore.values.isEmpty)
        #expect(effects.isEmpty)
    }

    @Test("Writable toggles with space")
    func writableToggle() {
        var s = reduce(loadedState(), .key(.char("a"), modifiers: [])).0
        s = reduce(s, .key(.char("v"), modifiers: [])).0
        // Move to field 4 (Writable): Tab x4.
        for _ in 0..<4 { s = reduce(s, .key(.tab, modifiers: [])).0 }
        #expect(s.mockFormState?.writable == false)
        s = reduce(s, .key(.char(" "), modifiers: [])).0
        #expect(s.mockFormState?.writable == true)
    }
}

// MARK: - Add function

@Suite("F5.4 — add mock function")
struct MockFormAddFunctionTests {

    @Test("behavior cycles and fixed-return requires a return value")
    func functionBehaviorCycleAndConfirm() {
        var s = reduce(loadedState(), .key(.char("a"), modifiers: [])).0
        s = reduce(s, .key(.char("f"), modifiers: [])).0  // → function fields
        s = typeText(s, "fetch")  // Function name (field 0)
        s = reduce(s, .key(.tab, modifiers: [])).0  // → Behavior (field 1)
        // echoArgs → fixedReturn (cycle forward once).
        s = reduce(s, .key(.char(" "), modifiers: [])).0
        #expect(s.mockFormState?.behavior == .fixedReturn)

        // Confirm without a return value → error.
        let (err, errEff) = reduce(s, .key(.enter, modifiers: []))
        #expect(err.mockFormState?.error != nil)
        #expect(errEff.isEmpty)

        // Provide the return value (field 2) and confirm.
        s = reduce(s, .key(.tab, modifiers: [])).0  // → Return value (field 2)
        s = typeText(s, "42")
        let (ok, eff) = reduce(s, .key(.enter, modifiers: []))
        #expect(
            ok.mockStore.functions.contains {
                $0.name == "fetch" && $0.behavior == .fixedReturn && $0.returnValue == "42"
            })
        #expect(hasSaveMockStore(eff))
    }
}

// MARK: - Edit + delete

@Suite("F5.4 — edit and delete")
struct MockFormEditDeleteTests {

    private func stateWithOneValue() -> AppState {
        var s = loadedState(values: [
            MockValueDef(namespace: "myapp", path: "k", type: .number, value: "1", writable: false)
        ])
        s.navigator.inMockSection = true
        s.navigator.mockSelectedIndex = 0
        return s
    }

    @Test("e opens the form pre-filled from the selected value")
    func editPrefilled() {
        let (next, _) = reduce(stateWithOneValue(), .key(.char("e"), modifiers: []))
        #expect(next.focus == .mockForm)
        #expect(next.mockFormState?.editingIndex == 0)
        #expect(next.mockFormState?.namespace == "myapp")
        #expect(next.mockFormState?.keyPath == "k")
    }

    @Test("editing and confirming replaces the entry (no append)")
    func editReplaces() {
        var s = reduce(stateWithOneValue(), .key(.char("e"), modifiers: [])).0
        // Append "2" to the Value field (field 3).
        for _ in 0..<3 { s = reduce(s, .key(.tab, modifiers: [])).0 }
        s = typeText(s, "2")  // value "1" → "12"
        let (after, eff) = reduce(s, .key(.enter, modifiers: []))
        #expect(after.mockStore.values.count == 1)  // replaced, not appended
        #expect(after.mockStore.values[0].value == "12")
        #expect(hasSaveMockStore(eff))
    }

    @Test("d asks for confirmation; y deletes and auto-saves")
    func deleteConfirm() {
        let (pending, _) = reduce(stateWithOneValue(), .key(.char("d"), modifiers: []))
        #expect(pending.mockDeletePending)
        #expect(pending.transient?.text == "Delete this mock? [y/N]")
        let (done, eff) = reduce(pending, .key(.char("y"), modifiers: []))
        #expect(done.mockStore.values.isEmpty)
        #expect(!done.mockDeletePending)
        #expect(hasSaveMockStore(eff))
    }

    @Test("d then any non-y cancels the delete")
    func deleteCancel() {
        let (pending, _) = reduce(stateWithOneValue(), .key(.char("d"), modifiers: []))
        let (cancelled, eff) = reduce(pending, .key(.char("n"), modifiers: []))
        #expect(!cancelled.mockDeletePending)
        #expect(cancelled.mockStore.values.count == 1)  // not deleted
        #expect(eff.isEmpty)
    }
}
