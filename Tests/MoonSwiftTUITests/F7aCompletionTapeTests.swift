// File: Tests/MoonSwiftTUITests/F7aCompletionTapeTests.swift
// Location: MoonSwiftTUITests/
// Role: F7a acceptance tape (tapes 3 and 6) — reducer-level completion flow
//       that verifies catalog items and live-mock items appear together in one
//       popup result.
//
//       Tape 3: static reducer check — build a state with a pre-populated
//         mockLiveState, emit the C-space completion event (via reduce()), and
//         assert the resulting queryCompletions effect carries both a liveMocks
//         slice and a tomlProbed flag; then drive completionsReady and assert
//         the popup contains both a catalog item and a .mock-kind item.
//
//       Tape 6 (CONS-05): session-dependent path — build state from a
//         MockLiveState that contains a mock function name, emit the C-space
//         gesture, resolve the completions using LuaModuleCatalog directly
//         (mirrors what AppDriver+CompletionEffects does), and assert the final
//         popup contains both a .mock item AND a catalog (.function) item.
//
//       Both tapes are purely synchronous reducer-level; no engine, no FFI.
//       Helper names are prefixed `f7aTape` to avoid clashes with CompletionTests.
//
// Upstream: Reducer (reduceCodePaneOpenCompletion, reduceCompletionsReady),
//           CompletionReducer (queryCompletions effect, completionsReady),
//           LuaModuleCatalog.completionItems, MockLiveState.completionItems,
//           AppState (mockLiveState, focus, CompletionPopupState)
// Downstream: (test target only)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers (f7aTape-prefixed)

/// Build a code-pane-focused state with a loaded source and an optional
/// `mockLiveState`. The `code` parameter is the last line visible to the cursor
/// (used for prefix extraction).
private func f7aTapeState(
    code: String,
    mockLiveState: MockLiveState? = nil
) -> AppState {
    let id = SourceID(path: "f7a-tape.lua")
    var state = AppState()
    let url = URL(fileURLWithPath: "/project/f7a-tape.lua")
    let data = Data(code.utf8)
    let prov = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: SHA256.hash(data: data)
    )
    state.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: prov))
    state.navigatorOrder = [id]
    state.selection = id
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    state.codePane.cursorLine = 0
    state.codePane.scrollOffset = 0
    state.focus = .pane(.codePane)
    state.mockLiveState = mockLiveState
    return state
}

/// Build a `MockLiveState` with one mock function name and one mock value.
private func f7aTapeLiveState(functionName: String, valueName: String) -> MockLiveState {
    MockLiveState(
        mockValues: [MockLiveValue(name: valueName, displayValue: "42")],
        mockFunctionNames: [functionName],
        userGlobals: [],
        isEmpty: false
    )
}

// MARK: - Suite: Tape 3 — static reducer completion check

@Suite("F7a acceptance tape 3 — static catalog + live-mock in one popup")
struct F7aStaticCompletionTapeTests {

    /// Tape 3a: <C-space> emits queryCompletions with the live-mock slice.
    ///
    /// Asserts:
    ///   - Pressing <C-space> on a `luaswift.json.` line emits a `.queryCompletions`
    ///     effect that includes the liveMocks slice from the cached mockLiveState.
    ///   - The liveMocks slice contains both the mock function name and value name.
    @Test("<C-space> includes live-mock slice in queryCompletions effect")
    func ctrlSpaceIncludesLiveMocksInEffect() {
        let live = f7aTapeLiveState(functionName: "fetch_data", valueName: "config.timeout")
        let state = f7aTapeState(code: "luaswift.json.", mockLiveState: live)

        let (_, effects) = reduce(state, .key(.char(" "), modifiers: .ctrl))

        guard let first = effects.first,
            case .queryCompletions(let prefix, let liveMocks, _) = first
        else {
            Issue.record(
                "expected .queryCompletions effect; got \(effects.map { "\($0)" })")
            return
        }
        #expect(prefix == "luaswift.json.", "prefix must match the cursor line prefix")
        let mockNames = liveMocks.map(\.insertText)
        #expect(mockNames.contains("fetch_data"), "liveMocks must contain the mock function name")
        #expect(mockNames.contains("config.timeout"), "liveMocks must contain the mock value name")
    }

    /// Tape 3b: completionsReady with catalog + mock items opens popup with both kinds.
    ///
    /// Asserts:
    ///   - After completionsReady, focus is `.completionPopup`.
    ///   - The popup contains at least one `.function` item (catalog) and at least
    ///     one `.mock` item (live-mock).
    @Test("completionsReady popup contains both catalog (.function) and live-mock (.mock) items")
    func completionsReadyContainsBothKinds() {
        let state = f7aTapeState(code: "luaswift.json.")

        // Build a mixed list: one catalog item + one mock item.
        let catalogItem = CompletionItem(
            insertText: "encode",
            label: "encode",
            detail: "(value) -> string",
            doc: "Encode a Lua value as JSON.",
            kind: .function
        )
        let mockItem = CompletionItem(
            insertText: "fetch_data",
            label: "fetch_data",
            detail: nil,
            doc: nil,
            kind: .mock
        )
        let (next, _) = reduce(state, .completionsReady([catalogItem, mockItem]))

        guard case .completionPopup(let popup) = next.focus else {
            Issue.record("expected .completionPopup focus after completionsReady")
            return
        }
        #expect(popup.items.count == 2, "popup must have exactly 2 items")
        let kinds = popup.items.map(\.kind)
        #expect(kinds.contains(.function), "popup must contain a .function item (catalog)")
        #expect(kinds.contains(.mock), "popup must contain a .mock item (live-mock)")
        #expect(popup.selectedIndex == 0, "initial selection must be 0")
    }
}

// MARK: - Suite: Tape 6 (CONS-05) — session-dependent completion end-to-end

/// CONS-05 tape: sequence the full mock-function → run → completion path at the
/// reducer + catalog level (no live engine — uses the MockLiveState directly as
/// the AppDriver would after a run).
@Suite("F7a acceptance tape 6 (CONS-05) — mock function appears in popup after mock-aware run")
struct F7aLiveMockCompletionTapeTests {

    /// Full CONS-05 sequence:
    ///   1. Build a state that represents post-run conditions: mockLiveState has a
    ///      mock function name "process_event".
    ///   2. Emit <C-space> on a `luaswift.json.` line — this exercises the same
    ///      reducer path as a real keypress.
    ///   3. Extract the liveMocks from the resulting queryCompletions effect.
    ///   4. Resolve completions via LuaModuleCatalog.v0.completionItems (mirrors
    ///      AppDriver+CompletionEffects.executeQueryCompletions).
    ///   5. Assert: result contains a catalog (.function) item AND a (.mock) item
    ///      for "process_event" in the SAME list.
    @Test("CONS-05: mock function and catalog item appear in the same popup result")
    func cons05MockFunctionAndCatalogInSamePopup() {
        let live = MockLiveState(
            mockValues: [],
            mockFunctionNames: ["process_event"],
            userGlobals: [],
            isEmpty: false
        )
        let state = f7aTapeState(code: "luaswift.json.", mockLiveState: live)

        // Step 1: C-space gesture emits queryCompletions.
        let (_, effects) = reduce(state, .key(.char(" "), modifiers: .ctrl))
        guard let first = effects.first,
            case .queryCompletions(let prefix, let liveMocks, let tomlProbed) = first
        else {
            Issue.record("expected .queryCompletions; got \(effects)")
            return
        }

        // Step 2: resolve via the catalog (same call as AppDriver+CompletionEffects).
        let items = LuaModuleCatalog.v0.completionItems(
            prefix: prefix,
            liveMocks: liveMocks,
            tomlProbed: tomlProbed
        )

        // Step 3: assert both kinds are present.
        #expect(!items.isEmpty, "completionItems must be non-empty for luaswift.json. prefix")
        let kinds = Set(items.map(\.kind))
        #expect(kinds.contains(.function), "popup must contain a catalog .function item")
        #expect(kinds.contains(.mock), "popup must contain a .mock item for process_event")

        // The mock item must specifically be for "process_event".
        let mockItems = items.filter { $0.kind == .mock }
        let mockNames = mockItems.map(\.insertText)
        #expect(
            mockNames.contains("process_event"),
            "mock item 'process_event' must be in the popup; got \(mockNames)")

        // Step 4: drive completionsReady and assert popup state.
        let (next, _) = reduce(state, .completionsReady(items))
        guard case .completionPopup(let popup) = next.focus else {
            Issue.record("expected .completionPopup after completionsReady")
            return
        }
        let popupKinds = Set(popup.items.map(\.kind))
        #expect(popupKinds.contains(.function), "popup items must include .function")
        #expect(popupKinds.contains(.mock), "popup items must include .mock")
    }
}
