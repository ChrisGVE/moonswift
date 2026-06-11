// File: Tests/MoonSwiftTUITests/Nvim/NvimConflictModalTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer sequence tests for Inc-9 — conflict-modal resolution paths.
//       (ARCHITECTURE.md §10.8 Inc-9, ux-spec §7.4)
//       Write-back outcomes: NvimWriteBackOutcomeTests.swift.
//       DiffView transitions: NvimDiffViewTests.swift.

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func cmMakeFragment(path: String = "/tmp/conflict_test.lua") -> LuaSourceFragment {
    let prov = FragmentProvenance(
        file: URL(fileURLWithPath: path), jsonpath: nil, document: 0,
        byteRange: 0..<9, lineOffset: 0, contentHash: SHA256.hash(data: Data()))
    return LuaSourceFragment(code: "return 1\n", provenance: prov)
}

private func makeNvimPaneAppState(path: String = "/tmp/conflict_test.lua") -> AppState {
    let sid = SourceID(path: "conflict_test.lua")
    return AppState(
        sources: [sid: .loaded(cmMakeFragment(path: path))],
        navigatorOrder: [sid], selection: sid,
        focus: .nvimPane(NvimPaneState(attachedRect: Rect(x: 18, y: 1, width: 102, height: 22))),
        terminalSize: TerminalSize(cols: 120, rows: 40))
}

private func makeConflictModalAppState(
    modal: ConflictModalState,
    path: String = "/tmp/conflict_test.lua"
) -> AppState {
    let sid = SourceID(path: "conflict_test.lua")
    return AppState(
        sources: [sid: .loaded(cmMakeFragment(path: path))],
        navigatorOrder: [sid], selection: sid,
        focus: .conflictModal(modal),
        terminalSize: TerminalSize(cols: 120, rows: 40))
}

private func hashOf(_ s: String) -> SHA256Digest { SHA256.hash(data: Data(s.utf8)) }

private func makeModal(
    path: String = "/tmp/conflict_test.lua",
    editedText: String = "return 99\n"
) -> ConflictModalState {
    ConflictModalState(
        fileURL: URL(fileURLWithPath: path),
        expectedHash: hashOf("original"), editedText: editedText,
        fragment: cmMakeFragment(path: path))
}

private func apply(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

private func containsDetach(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .nvimDetach = $0 { return true }
        return false
    }
}

private func loadSourceID(from effects: [Effect]) -> SourceID? {
    for e in effects { if case .loadSource(let id) = e { return id } }
    return nil
}

private func extractWriteBack(
    from effects: [Effect]
) -> (LuaSourceFragment, editedText: String, force: Bool)? {
    for e in effects {
        if case .writeBack(let f, let t, let force) = e { return (f, t, force) }
    }
    return nil
}

private func extractBuildDiffView(from effects: [Effect]) -> (fileURL: URL, editedText: String)? {
    for e in effects {
        if case .buildDiffView(let url, _, let text, _) = e { return (url, text) }
    }
    return nil
}

// MARK: - Suite: conflictDetected event

@Suite("NvimConflictModal — conflictDetected event")
struct ConflictDetectedEventTests {

    @Test("conflictDetected opens the conflict modal with correct ConflictModalState")
    func conflictDetectedOpensModal() {
        let s = makeNvimPaneAppState()
        let fileURL = URL(fileURLWithPath: "/tmp/conflict_test.lua")
        let expectedHash = hashOf("original content")
        let editedText = "return 99\n"

        let (next, effects) = apply(
            s,
            .conflictDetected(fileURL: fileURL, expectedHash: expectedHash, editedText: editedText)
        )

        guard case .conflictModal(let modal) = next.focus else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
            return
        }
        #expect(modal.fileURL == fileURL)
        #expect(modal.editedText == editedText)
        #expect(effects.isEmpty)
    }

    @Test("conflictDetected requires a loaded selection — no-op otherwise")
    func conflictDetectedNoOpWithoutSelection() {
        var s = AppState()
        s.focus = .nvimPane(NvimPaneState(attachedRect: Rect(x: 0, y: 0, width: 80, height: 24)))

        let (next, effects) = apply(
            s,
            .conflictDetected(
                fileURL: URL(fileURLWithPath: "/tmp/x.lua"),
                expectedHash: hashOf("x"),
                editedText: "return 1\n"
            )
        )

        // No selection in state → no state change
        #expect(next.focus == s.focus)
        #expect(effects.isEmpty)
    }
}

// MARK: - Suite: conflict modal [r] reload

@Suite("NvimConflictModal — [r] reload")
struct ConflictModalReloadTests {

    @Test("[r] sets focus to .pane(.codePane)")
    func reloadSetsFocusToCodePane() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, _) = apply(s, .key(.char("r"), modifiers: []))
        #expect(next.focus == .pane(.codePane))
    }

    @Test("[r] emits Effect.nvimDetach")
    func reloadEmitsDetach() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("r"), modifiers: []))
        #expect(containsDetach(effects))
    }

    @Test("[r] emits Effect.loadSource for the selected source")
    func reloadEmitsLoadSource() {
        let modal = makeModal()
        let sid = SourceID(path: "conflict_test.lua")
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("r"), modifiers: []))
        #expect(loadSourceID(from: effects) == sid)
    }

    @Test("[r] clears nvimGrid")
    func reloadClearsNvimGrid() {
        let modal = makeModal()
        var s = makeConflictModalAppState(modal: modal)
        s.nvimGrid = NvimGridState(width: 80, height: 24)
        let (next, _) = apply(s, .key(.char("r"), modifiers: []))
        #expect(next.nvimGrid == nil)
    }
}

// MARK: - Suite: conflict modal [o] overwrite

@Suite("NvimConflictModal — [o] overwrite")
struct ConflictModalOverwriteTests {

    @Test("[o] returns focus to .nvimPane")
    func overwriteReturnsFocusToNvimPane() {
        let modal = makeModal(editedText: "return 99\n")
        let s = makeConflictModalAppState(modal: modal)
        let (next, _) = apply(s, .key(.char("o"), modifiers: []))
        if case .nvimPane = next.focus {
            // correct
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }

    @Test("[o] emits Effect.writeBack with force: true")
    func overwriteEmitsForceWriteBack() {
        let modal = makeModal(editedText: "return 99\n")
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("o"), modifiers: []))
        guard let wb = extractWriteBack(from: effects) else {
            Issue.record("No writeBack effect emitted")
            return
        }
        #expect(wb.force == true)
    }

    @Test("[o] writeBack carries the edited text from ConflictModalState")
    func overwriteCarriesEditedText() {
        let editedText = "return overwritten\n"
        let modal = makeModal(editedText: editedText)
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("o"), modifiers: []))
        guard let wb = extractWriteBack(from: effects) else {
            Issue.record("No writeBack effect emitted")
            return
        }
        #expect(wb.editedText == editedText)
    }

    @Test("[o] writeBack carries the fragment from ConflictModalState (not stale sources)")
    func overwriteCarriesFragmentFromModal() {
        let modal = makeModal(path: "/tmp/conflict_test.lua", editedText: "return 1\n")
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("o"), modifiers: []))
        guard let wb = extractWriteBack(from: effects) else {
            Issue.record("No writeBack effect emitted")
            return
        }
        // The fragment should come from the modal, not the (potentially stale) sources entry.
        #expect(wb.0.provenance.file == modal.fragment.provenance.file)
    }
}

// MARK: - Suite: conflict modal [d] diff

@Suite("NvimConflictModal — [d] diff")
struct ConflictModalDiffTests {

    @Test("[d] sets focus to .diffView(.building)")
    func diffSetsBuildingPhase() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, _) = apply(s, .key(.char("d"), modifiers: []))
        if case .diffView(.building) = next.focus {
            // correct
        } else {
            Issue.record("Expected .diffView(.building), got \(next.focus)")
        }
    }

    @Test("[d] emits Effect.buildDiffView with the correct fileURL")
    func diffEmitsBuildDiffView() {
        let path = "/tmp/conflict_test.lua"
        let modal = makeModal(path: path)
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("d"), modifiers: []))
        guard let extracted = extractBuildDiffView(from: effects) else {
            Issue.record("No buildDiffView effect emitted")
            return
        }
        #expect(extracted.fileURL.path == path)
    }

    @Test("[d] emits Effect.buildDiffView with the edited text from modal")
    func diffEmitsBuildDiffViewWithEditedText() {
        let editedText = "return diff_me\n"
        let modal = makeModal(editedText: editedText)
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("d"), modifiers: []))
        guard let extracted = extractBuildDiffView(from: effects) else {
            Issue.record("No buildDiffView effect emitted")
            return
        }
        #expect(extracted.editedText == editedText)
    }

    @Test("diffViewReady transitions to .diffView(.ready(state))")
    func diffViewReadyTransition() {
        let diffState = DiffViewState(
            leftTitle: "On disk",
            rightTitle: "Edited",
            leftLines: ["line1"],
            rightLines: ["edited_line1"]
        )
        let modal = makeModal()
        var s = makeConflictModalAppState(modal: modal)
        s.focus = .diffView(.building)

        let (next, effects) = apply(s, .diffViewReady(diffState))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state == diffState)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
        #expect(effects.isEmpty)
    }
}

// MARK: - Suite: conflict modal [c] cancel

@Suite("NvimConflictModal — [c] cancel")
struct ConflictModalCancelTests {

    @Test("[c] returns focus to .nvimPane")
    func cancelReturnsFocusToNvimPane() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, _) = apply(s, .key(.char("c"), modifiers: []))
        if case .nvimPane = next.focus {
            // correct
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }

    @Test("[c] emits no effects")
    func cancelEmitsNoEffects() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (_, effects) = apply(s, .key(.char("c"), modifiers: []))
        // Only tick effects are acceptable (transient expiry); no action effects.
        let actionEffects = effects.filter {
            switch $0 {
            case .startTick, .stopTick: return false
            default: return true
            }
        }
        #expect(actionEffects.isEmpty)
    }
}

// MARK: - Suite: key absorption in conflict modal

@Suite("NvimConflictModal — key absorption")
struct ConflictModalKeyAbsorptionTests {

    @Test("key 'a' in conflict modal is absorbed — no state change")
    func absorbA() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, effects) = apply(s, .key(.char("a"), modifiers: []))
        // Focus must remain .conflictModal
        if case .conflictModal = next.focus {
            // correct
        } else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
        }
        let actionEffects = effects.filter {
            switch $0 {
            case .startTick, .stopTick: return false
            default: return true
            }
        }
        #expect(actionEffects.isEmpty)
    }

    @Test("key 'z' in conflict modal is absorbed — no state change")
    func absorbZ() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, effects) = apply(s, .key(.char("z"), modifiers: []))
        if case .conflictModal = next.focus {
            // correct
        } else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
        }
        #expect(effects.isEmpty)
    }

    @Test("escape key in conflict modal is absorbed — no state change")
    func absorbEscape() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, effects) = apply(s, .key(.escape, modifiers: []))
        if case .conflictModal = next.focus {
            // correct
        } else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
        }
        #expect(effects.isEmpty)
    }

    @Test("enter key in conflict modal is absorbed — no state change")
    func absorbEnter() {
        let modal = makeModal()
        let s = makeConflictModalAppState(modal: modal)
        let (next, effects) = apply(s, .key(.enter, modifiers: []))
        if case .conflictModal = next.focus {
            // correct
        } else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
        }
        #expect(effects.isEmpty)
    }
}

// Write-back outcome mapping, writeBackBlocked, and nvimWriteRequested tests
// live in NvimWriteBackOutcomeTests.swift (split to respect 400-line file cap).
