// File: Tests/MoonSwiftTUITests/InvokeFormTests.swift
// Location: MoonSwiftTUITests/
// Role: P2 F5.3 — the Lua-invocation form reducer (ux-spec §7.5, PRD §6.6):
//       opening from a live function row (`<Enter>` pre-fills `<name>(`), single-
//       line editing, `<Enter>` emitting `Effect.invokeLuaCall` with the RAW
//       typed expression, `<Esc>` cancel, and the four outcome events
//       (result closes + writes `→ <display>`; lint / target / runtime keep the
//       form open with the inline error and text preserved). Drives reduce()
//       directly; the side-effectful three controls are AppDriver-side and are
//       covered by the SessionEngine integration + CallTargetExtractor tests.
//
// Upstream: InvokeFormReducer.swift, InvokeFormState, MockNavigatorView.swift,
//           Reducer.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// A loaded project with no declared mocks and one live function row
/// (`name`) discovered post-run, with the mock-section cursor on it.
private func stateOnLiveFunction(
    name: String = "on_event",
    declaredValues: [MockValueDef] = [],
    declaredFunctions: [MockFunctionDef] = []
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
    let file = ProjectFile(
        luaVersion: "5.4",
        mocks: MockStore(values: declaredValues, functions: declaredFunctions))
    s.project = .loaded(file, diagnostics: [])
    s.mockStore = file.mocks
    s.mockLiveState = MockLiveState(
        mockValues: [], mockFunctionNames: [name], userGlobals: [], isEmpty: false)
    s.focus = .pane(.navigator)
    s.navigator.inMockSection = true
    // Cursor on the first selectable mock row — the live function, since there
    // are no declared mocks ahead of it by default.
    s.navigator.mockSelectedIndex = declaredValues.count + declaredFunctions.count
    return s
}

private func typeText(_ s: AppState, _ text: String) -> AppState {
    var s = s
    for ch in text.unicodeScalars {
        s = reduce(s, .key(.char(ch), modifiers: [])).0
    }
    return s
}

private func hasInvokeEffect(_ effects: [Effect]) -> String? {
    for e in effects {
        if case .invokeLuaCall(let expr) = e { return expr }
    }
    return nil
}

// MARK: - Open

@Suite("F5.3 — invoke form open from a live function row")
struct InvokeFormOpenTests {

    @Test("Enter on a live function row opens the form pre-filled with name(")
    func enterOpensPreFilled() {
        let s = stateOnLiveFunction(name: "on_event")
        let (next, effects) = reduce(s, .key(.enter, modifiers: []))
        #expect(next.focus == .invokeForm)
        #expect(next.invokeFormState?.functionName == "on_event")
        #expect(next.invokeFormState?.expression == "on_event(")
        #expect(effects.isEmpty)  // opening is pure — no effect until <Enter> in the form
    }

    @Test("Enter on a DECLARED mock row does not open the invoke form")
    func enterOnDeclaredIsNoop() {
        // One declared value, cursor on it (index 0); the live function follows.
        var s = stateOnLiveFunction(
            declaredValues: [
                MockValueDef(
                    namespace: "app", path: "k", type: .number, value: "1", writable: false)
            ])
        s.navigator.mockSelectedIndex = 0  // the declared value, not the live function
        let (next, _) = reduce(s, .key(.enter, modifiers: []))
        #expect(next.focus == .pane(.navigator))
        #expect(next.invokeFormState == nil)
    }

    @Test("the live function row is selectable; j crosses onto it")
    func liveFunctionSelectable() {
        var s = stateOnLiveFunction()
        s.navigator.inMockSection = false
        s.navigator.selectedIndex = 0  // the single source
        // j → cross into the mock section onto the live function row.
        s = reduce(s, .key(.char("j"), modifiers: [])).0
        #expect(s.navigator.inMockSection)
        #expect(selectedLiveFunctionName(s) == "on_event")
    }
}

// MARK: - Editing + submit

@Suite("F5.3 — invoke form editing and submit")
struct InvokeFormEditTests {

    @Test("typing appends to the expression; Enter emits invokeLuaCall with the raw string")
    func typeAndSubmit() {
        var s = stateOnLiveFunction(name: "on_event")
        s = reduce(s, .key(.enter, modifiers: [])).0  // open → "on_event("
        s = typeText(s, "\"tick\", 42)")
        #expect(s.invokeFormState?.expression == "on_event(\"tick\", 42)")
        let (next, effects) = reduce(s, .key(.enter, modifiers: []))
        #expect(hasInvokeEffect(effects) == "on_event(\"tick\", 42)")
        // Form stays open until an outcome event arrives.
        #expect(next.focus == .invokeForm)
        #expect(next.invokeFormState != nil)
    }

    @Test("backspace deletes the last character")
    func backspace() {
        var s = stateOnLiveFunction(name: "f")
        s = reduce(s, .key(.enter, modifiers: [])).0  // "f("
        s = reduce(s, .key(.backspace, modifiers: [])).0
        #expect(s.invokeFormState?.expression == "f")
    }

    @Test("Esc cancels without evaluating and returns focus to the navigator")
    func escCancels() {
        var s = stateOnLiveFunction()
        s = reduce(s, .key(.enter, modifiers: [])).0
        let (next, effects) = reduce(s, .key(.escape, modifiers: []))
        #expect(next.focus == .pane(.navigator))
        #expect(next.invokeFormState == nil)
        #expect(effects.isEmpty)
    }
}

// MARK: - Outcome events

@Suite("F5.3 — invoke outcome events (lifecycle §6.6)")
struct InvokeFormOutcomeTests {

    private func openedForm() -> AppState {
        var s = stateOnLiveFunction(name: "on_event")
        s = reduce(s, .key(.enter, modifiers: [])).0
        return s
    }

    @Test("luaInvocationResult writes → <display>, closes the form, focus to navigator")
    func resultClosesAndWrites() {
        let s = openedForm()
        let (next, _) = reduce(s, .luaInvocationResult("42"))
        #expect(next.invokeFormState == nil)
        #expect(next.focus == .pane(.navigator))
        #expect(next.bottomPane.outputBuffer.last == "→ 42")
    }

    @Test("luaInvocationLintFailed shows Invalid call expression: <detail> inline, keeps form open")
    func lintFailedKeepsOpen() {
        var s = openedForm()
        s = typeText(s, "1,")  // make the text non-trivial so we can assert preservation
        let expr = s.invokeFormState?.expression
        let (next, _) = reduce(s, .luaInvocationLintFailed("unexpected symbol"))
        #expect(next.focus == .invokeForm)
        #expect(next.invokeFormState?.error == "Invalid call expression: unexpected symbol")
        #expect(next.invokeFormState?.expression == expr)  // text preserved
    }

    @Test("luaInvocationTargetInvalid shows Invalid function name. inline, keeps form open")
    func targetInvalidKeepsOpen() {
        let s = openedForm()
        let (next, _) = reduce(s, .luaInvocationTargetInvalid)
        #expect(next.focus == .invokeForm)
        #expect(next.invokeFormState?.error == "Invalid function name.")
    }

    @Test("luaInvocationFailed shows the runtime message inline, keeps form open")
    func runtimeFailedKeepsOpen() {
        let s = openedForm()
        let (next, _) = reduce(s, .luaInvocationFailed("boom"))
        #expect(next.focus == .invokeForm)
        #expect(next.invokeFormState?.error == "boom")
    }

    @Test("the next edit clears the inline error")
    func editClearsError() {
        var s = openedForm()
        s = reduce(s, .luaInvocationTargetInvalid).0
        #expect(s.invokeFormState?.error != nil)
        s = reduce(s, .key(.char("x"), modifiers: [])).0
        #expect(s.invokeFormState?.error == nil)
    }
}
