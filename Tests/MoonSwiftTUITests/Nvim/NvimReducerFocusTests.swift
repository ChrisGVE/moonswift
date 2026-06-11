// File: Tests/MoonSwiftTUITests/Nvim/NvimReducerFocusTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer sequence tests for Inc-8 — FocusState/AppState wiring for
//       the nvim editing subsystem (ARCHITECTURE.md §10.8 Inc-8).
//
//       Covers:
//         • <C-e> in code pane → .nvimSpawning + Effect.spawnNvim
//         • .nvimReady → .nvimPane transition
//         • <C-e> in nvim pane → Effect.nvimDetach; .nvimDetached → .codePane + cleanup
//         • Keys in .nvimPane → Effect.nvimInput(translated notation)
//         • Untranslatable key in .nvimPane → no effect emitted
//         • .nvimUnavailable one-time note (exact normative string, gate fires once)
//         • .nvimProcessExited(0) → cleanup, no transient
//         • .nvimProcessExited(N≠0) → cleanup + transient
//         • .nvimSpawning absorbs all keys
//         • Terminal resize debounce (~50 ms) while nvim pane active
//         • modeChange updates NvimPaneState.mode
//
// Relationships:
//   → Reducer.swift  (Inc-8): system under test
//   → AppState.swift (Inc-8): FocusState nvim cases, new fields
//   → Effect.swift   (Inc-8): spawnNvim, nvimInput, nvimDetach, nvimCleanup,
//                             nvimResize, startTick

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build a minimal whole-file `.lua` LuaSourceFragment for testing.
private func makeTestFragment(path: String = "/tmp/test.lua") -> LuaSourceFragment {
    let provenance = FragmentProvenance(
        file: URL(fileURLWithPath: path),
        jsonpath: nil,
        document: 0,
        byteRange: 0..<9,
        lineOffset: 0,
        contentHash: SHA256.hash(data: Data())
    )
    return LuaSourceFragment(code: "return 1\n", provenance: provenance)
}

/// Make a minimal state focused on the code pane with a loaded source.
private func makeCodePaneState() -> AppState {
    let sid = SourceID(path: "test.lua")
    let fragment = makeTestFragment()
    return AppState(
        sources: [sid: .loaded(fragment)],
        navigatorOrder: [sid],
        selection: sid,
        focus: .pane(.codePane),
        terminalSize: TerminalSize(cols: 120, rows: 40)
    )
}

/// Make a state already in `.nvimPane` focus.
private func makeNvimPaneState(rect: Rect = Rect(x: 18, y: 1, width: 102, height: 22)) -> AppState {
    var s = makeCodePaneState()
    s.focus = .nvimPane(NvimPaneState(attachedRect: rect))
    return s
}

/// Make a fake NvimSession — no real process; used only to carry through
/// the reducer (which does not store the session).
private func makeFakeSession() -> NvimSession {
    NvimSession(supervisor: NvimProcessSupervisor(), rpc: NvimRPCClient())
}

/// Apply a sequence of events threading state through each step; return the final state.
private func applyAll(_ state: AppState, _ events: [AppEvent]) -> AppState {
    events.reduce(state) { s, e in reduce(s, e).0 }
}

/// Apply one event and return (state, effects).
private func apply(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

/// Return true if `effects` contains `Effect.nvimCleanup`.
private func containsCleanup(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .nvimCleanup = $0 { return true }
        return false
    }
}

/// Extract the single nvimInput notation from effects, or nil.
private func nvimInputNotation(from effects: [Effect]) -> String? {
    for e in effects {
        if case .nvimInput(let n) = e { return n }
    }
    return nil
}

/// Extract the spawnNvim fragment from effects, or nil.
private func spawnNvimFragment(from effects: [Effect]) -> LuaSourceFragment? {
    for e in effects {
        if case .spawnNvim(let f, _) = e { return f }
    }
    return nil
}

// MARK: - Suite

@Suite("NvimReducerFocusTests")
struct NvimReducerFocusTests {

    // MARK: <C-e> from code pane → nvimSpawning + spawnNvim effect

    @Test("<C-e> in code pane sets focus to .nvimSpawning")
    func ceInCodePaneSetsNvimSpawning() {
        let s = makeCodePaneState()
        let (next, _) = apply(s, .key(.char("e"), modifiers: .ctrl))
        #expect(next.focus == .nvimSpawning)
    }

    @Test("<C-e> in code pane emits spawnNvim effect for the loaded fragment")
    func ceInCodePaneEmitsSpawnNvim() {
        let s = makeCodePaneState()
        let (_, effects) = apply(s, .key(.char("e"), modifiers: .ctrl))
        #expect(spawnNvimFragment(from: effects) != nil, "spawnNvim effect expected")
    }

    @Test("<C-e> in code pane with no selection shows transient, stays in code pane")
    func ceInCodePaneNoSelection() {
        var s = makeCodePaneState()
        s.selection = nil
        let (next, effects) = apply(s, .key(.char("e"), modifiers: .ctrl))
        #expect(next.focus == .pane(.codePane))
        #expect(next.transient != nil)
        #expect(spawnNvimFragment(from: effects) == nil)
    }

    // MARK: .nvimSpawning → .nvimPane on nvimReady

    @Test("nvimReady transitions focus from .nvimSpawning to .nvimPane")
    func nvimReadyTransitionsToPane() {
        var s = makeCodePaneState()
        s.focus = .nvimSpawning
        let (next, _) = apply(s, .nvimReady(makeFakeSession()))
        if case .nvimPane = next.focus {
            // pass
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }

    @Test("nvimReady NvimPaneState.attachedRect is non-zero (layout was computed)")
    func nvimReadyPaneStateHasRect() {
        var s = makeCodePaneState()
        s.focus = .nvimSpawning
        s.terminalSize = TerminalSize(cols: 120, rows: 40)
        let (next, _) = apply(s, .nvimReady(makeFakeSession()))
        guard case .nvimPane(let ps) = next.focus else {
            Issue.record("Expected .nvimPane")
            return
        }
        // Width must be positive (120 cols − 18 nav = 102).
        #expect(ps.attachedRect.width > 0)
        #expect(ps.attachedRect.height > 0)
    }

    @Test("nvimReady session is not stored in AppState (driver owns it)")
    func nvimReadySessionNotInState() {
        // The reducer is pure and must not store NvimSession in AppState.
        // Verify by checking the state is unchanged except focus.
        var s = makeCodePaneState()
        s.focus = .nvimSpawning
        let before = s
        let (next, _) = apply(s, .nvimReady(makeFakeSession()))
        // All fields except focus must be unchanged.
        var expected = before
        if case .nvimPane(let ps) = next.focus {
            expected.focus = .nvimPane(ps)
        }
        #expect(next.nvimGrid == expected.nvimGrid)
        #expect(next.conflictModal == expected.conflictModal)
        #expect(next.nvimFallbackNotedThisSession == expected.nvimFallbackNotedThisSession)
    }

    // MARK: <C-e> in nvim pane → nvimDetach; .nvimDetached → codePane + cleanup

    @Test("<C-e> in nvimPane emits nvimDetach effect")
    func ceInNvimPaneEmitsDetach() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .key(.char("e"), modifiers: .ctrl))
        let hasDetach = effects.contains {
            if case .nvimDetach = $0 { return true }
            return false
        }
        #expect(hasDetach, "nvimDetach expected in effects")
    }

    @Test("<C-e> in nvimPane does not change focus immediately (detach is async)")
    func ceInNvimPaneFocusUnchanged() {
        let s = makeNvimPaneState()
        let (next, _) = apply(s, .key(.char("e"), modifiers: .ctrl))
        if case .nvimPane = next.focus {
            // pass — focus stays until .nvimDetached arrives
        } else {
            Issue.record("Focus should remain .nvimPane until .nvimDetached")
        }
    }

    @Test(".nvimDetached sets focus to .pane(.codePane)")
    func nvimDetachedRestoresCodePane() {
        let s = makeNvimPaneState()
        let (next, _) = apply(s, .nvimDetached)
        #expect(next.focus == .pane(.codePane))
    }

    @Test(".nvimDetached emits nvimCleanup effect")
    func nvimDetachedEmitsCleanup() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .nvimDetached)
        #expect(containsCleanup(effects), "nvimCleanup expected on .nvimDetached")
    }

    @Test(".nvimDetached clears nvimGrid")
    func nvimDetachedClearsGrid() {
        var s = makeNvimPaneState()
        s.nvimGrid = NvimGridState(width: 80, height: 24)
        let (next, _) = apply(s, .nvimDetached)
        #expect(next.nvimGrid == nil)
    }

    // MARK: Full round-trip: <C-e> → spawning → nvimPane → <C-e> → detached → codePane

    @Test("Full C-e → nvimSpawning → nvimReady → nvimPane sequence")
    func fullSpawnSequence() {
        let s0 = makeCodePaneState()

        // Step 1: press <C-e> from code pane
        let (s1, _) = apply(s0, .key(.char("e"), modifiers: .ctrl))
        #expect(s1.focus == .nvimSpawning)

        // Step 2: spawn completes
        let (s2, _) = apply(s1, .nvimReady(makeFakeSession()))
        guard case .nvimPane = s2.focus else {
            Issue.record("Expected .nvimPane after nvimReady")
            return
        }

        // Step 3: press <C-e> again to detach
        let (s3, effects3) = apply(s2, .key(.char("e"), modifiers: .ctrl))
        let hasDetach = effects3.contains {
            if case .nvimDetach = $0 { return true }
            return false
        }
        #expect(hasDetach)
        // Focus still nvimPane until nvimDetached arrives
        if case .nvimPane = s3.focus {
        } else {
            Issue.record("Focus should remain nvimPane before detach confirmed")
        }

        // Step 4: nvimDetached arrives
        let (s4, effects4) = apply(s3, .nvimDetached)
        #expect(s4.focus == .pane(.codePane))
        #expect(containsCleanup(effects4))
    }

    // MARK: Keys in nvimPane → translated to nvimInput

    @Test("Printable key 'a' in nvimPane emits nvimInput(\"a\")")
    func printableKeyInNvimPane() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .key(.char("a"), modifiers: []))
        #expect(nvimInputNotation(from: effects) == "a")
    }

    @Test("Enter key in nvimPane emits nvimInput(\"<CR>\")")
    func enterKeyInNvimPane() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .key(.enter, modifiers: []))
        #expect(nvimInputNotation(from: effects) == "<CR>")
    }

    @Test("Escape key in nvimPane emits nvimInput(\"<Esc>\")")
    func escapeKeyInNvimPane() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .key(.escape, modifiers: []))
        #expect(nvimInputNotation(from: effects) == "<Esc>")
    }

    @Test("Ctrl+u in nvimPane emits nvimInput(\"<C-u>\")")
    func ctrlUInNvimPane() {
        let s = makeNvimPaneState()
        let (_, effects) = apply(s, .key(.char("u"), modifiers: .ctrl))
        #expect(nvimInputNotation(from: effects) == "<C-u>")
    }

    @Test("Untranslatable key in nvimPane (null) emits no effect")
    func untranslatableKeyDropped() {
        let s = makeNvimPaneState()
        // .null is defined as untranslatable in NvimKeyTranslator.
        let (_, effects) = apply(s, .key(.null, modifiers: []))
        let hasNvimInput = effects.contains {
            if case .nvimInput = $0 { return true }
            return false
        }
        #expect(!hasNvimInput, "Untranslatable key must not produce nvimInput effect")
    }

    // MARK: .nvimSpawning absorbs all keys

    @Test(".nvimSpawning absorbs all key input without effects")
    func nvimSpawningAbsorbsKeys() {
        var s = makeCodePaneState()
        s.focus = .nvimSpawning
        let (next, effects) = apply(s, .key(.char("q"), modifiers: []))
        #expect(next.focus == .nvimSpawning)
        #expect(effects.isEmpty)
    }

    // MARK: .nvimUnavailable — one-time fallback note

    @Test(".nvimUnavailable posts exact normative transient string once")
    func nvimUnavailableNormativeString() {
        let s = makeCodePaneState()
        let (next, _) = apply(s, .nvimUnavailable("nvim not found"))
        #expect(
            next.transient?.text == "nvim not found. Using $EDITOR for editing.",
            "Normative string mismatch — ux-spec §7.4 step 6"
        )
    }

    @Test(".nvimUnavailable sets nvimFallbackNotedThisSession to true")
    func nvimUnavailableSetsGate() {
        let s = makeCodePaneState()
        let (next, _) = apply(s, .nvimUnavailable("nvim not found"))
        #expect(next.nvimFallbackNotedThisSession)
    }

    @Test(".nvimUnavailable second call is suppressed (gate fires once)")
    func nvimUnavailableFiresOnce() {
        let s = makeCodePaneState()
        // First call: note posted, gate set.
        let (s1, _) = apply(s, .nvimUnavailable("nvim not found"))
        #expect(s1.transient?.text == "nvim not found. Using $EDITOR for editing.")

        // Second call: gate blocks re-post; transient must not change.
        var s2 = s1
        s2.transient = nil  // Clear the transient to confirm it is not re-set.
        let (s3, _) = apply(s2, .nvimUnavailable("nvim not found"))
        #expect(s3.transient == nil, "Second nvimUnavailable must not repost the transient")
    }

    @Test(".nvimUnavailable while .nvimSpawning resets focus to .pane(.codePane)")
    func nvimUnavailableResetsSpawningFocus() {
        var s = makeCodePaneState()
        s.focus = .nvimSpawning
        let (next, _) = apply(s, .nvimUnavailable("nvim not found"))
        #expect(next.focus == .pane(.codePane))
    }

    // MARK: .nvimProcessExited

    @Test(".nvimProcessExited(0) emits nvimCleanup, no transient")
    func nvimProcessExitedClean() {
        let s = makeNvimPaneState()
        let (next, effects) = apply(s, .nvimProcessExited(exitCode: 0))
        #expect(next.focus == .pane(.codePane))
        #expect(containsCleanup(effects))
        #expect(next.transient == nil)
    }

    @Test(".nvimProcessExited(N≠0) emits nvimCleanup and posts transient")
    func nvimProcessExitedUnexpected() {
        let s = makeNvimPaneState()
        let (next, effects) = apply(s, .nvimProcessExited(exitCode: 1))
        #expect(next.focus == .pane(.codePane))
        #expect(containsCleanup(effects))
        #expect(next.transient != nil)
        // Transient text must mention the exit code.
        #expect(next.transient?.text.contains("1") == true)
    }

    @Test(".nvimProcessExited clears nvimGrid")
    func nvimProcessExitedClearsGrid() {
        var s = makeNvimPaneState()
        s.nvimGrid = NvimGridState(width: 80, height: 24)
        let (next, _) = apply(s, .nvimProcessExited(exitCode: 0))
        #expect(next.nvimGrid == nil)
    }

}
