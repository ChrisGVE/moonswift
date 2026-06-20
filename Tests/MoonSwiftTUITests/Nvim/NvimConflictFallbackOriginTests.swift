// File: Tests/MoonSwiftTUITests/Nvim/NvimConflictFallbackOriginTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Regression tests for conflict-modal origin tracking — a conflict raised
//       from the $EDITOR-suspend fallback (no live nvim session) must resolve
//       back to the code pane, never to a dead .nvimPane placeholder.
//       (ARCHITECTURE.md §10.3e / §10.4.9, ux-spec §7.4; P4 audit gap #1.)
//       Core conflict-modal resolution paths: NvimConflictModalTests.swift.

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

private func foMakeFragment(path: String = "/tmp/fallback_conflict.lua") -> LuaSourceFragment {
    let prov = FragmentProvenance(
        file: URL(fileURLWithPath: path), jsonpath: nil, document: 0,
        byteRange: 0..<9, lineOffset: 0, contentHash: SHA256.hash(data: Data()))
    return LuaSourceFragment(code: "return 1\n", provenance: prov)
}

private func foSourceID() -> SourceID { SourceID(path: "fallback_conflict.lua") }

/// A loaded project state whose focus is the read-only code pane — the state the
/// `$EDITOR` fallback path is in when its post-edit write-back detects a conflict
/// (the editor process has already exited; there is no nvim session).
private func foCodePaneAppState(path: String = "/tmp/fallback_conflict.lua") -> AppState {
    let sid = foSourceID()
    return AppState(
        sources: [sid: .loaded(foMakeFragment(path: path))],
        navigatorOrder: [sid], selection: sid,
        focus: .pane(.codePane),
        terminalSize: TerminalSize(cols: 120, rows: 40))
}

/// A loaded project state whose focus is a live nvim pane — the embedded-nvim
/// `:w` path's state when its write-back detects a conflict.
private func foNvimPaneAppState(path: String = "/tmp/fallback_conflict.lua") -> AppState {
    let sid = foSourceID()
    return AppState(
        sources: [sid: .loaded(foMakeFragment(path: path))],
        navigatorOrder: [sid], selection: sid,
        focus: .nvimPane(NvimPaneState(attachedRect: Rect(x: 18, y: 1, width: 102, height: 22))),
        terminalSize: TerminalSize(cols: 120, rows: 40))
}

private func foHash(_ s: String) -> SHA256Digest { SHA256.hash(data: Data(s.utf8)) }

private func foApply(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

private func foConflictEvent(path: String = "/tmp/fallback_conflict.lua") -> AppEvent {
    .conflictDetected(
        fileURL: URL(fileURLWithPath: path),
        expectedHash: foHash("original"),
        editedText: "return 99\n")
}

// MARK: - Suite: origin capture from pre-modal focus

@Suite("NvimConflictModal — origin capture")
struct ConflictModalOriginCaptureTests {

    @Test("conflictDetected from the code pane ($EDITOR fallback) marks returnsToNvim = false")
    func fallbackOriginMarksReturnsToNvimFalse() {
        let s = foCodePaneAppState()
        let (next, _) = foApply(s, foConflictEvent())
        guard case .conflictModal(let modal) = next.focus else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
            return
        }
        #expect(modal.returnsToNvim == false)
    }

    @Test("conflictDetected from the nvim pane (:w path) marks returnsToNvim = true")
    func nvimOriginMarksReturnsToNvimTrue() {
        let s = foNvimPaneAppState()
        let (next, _) = foApply(s, foConflictEvent())
        guard case .conflictModal(let modal) = next.focus else {
            Issue.record("Expected .conflictModal, got \(next.focus)")
            return
        }
        #expect(modal.returnsToNvim == true)
    }
}

// MARK: - Suite: fallback-origin resolution lands in the code pane

@Suite("NvimConflictModal — fallback-origin resolution")
struct ConflictModalFallbackResolutionTests {

    private func fallbackModalState() -> AppState {
        let s = foCodePaneAppState()
        let (next, _) = foApply(s, foConflictEvent())
        return next
    }

    @Test("[o] overwrite from a fallback-origin conflict returns to the code pane, not a dead nvim pane")
    func overwriteReturnsToCodePane() {
        let s = fallbackModalState()
        let (next, effects) = foApply(s, .key(.char("o"), modifiers: []))
        if case .pane(.codePane) = next.focus {
            // correct
        } else {
            Issue.record("Expected .pane(.codePane), got \(next.focus)")
        }
        // The force write-back must still be issued.
        let hasForceWriteBack = effects.contains {
            if case .writeBack(_, _, let force) = $0 { return force }
            return false
        }
        #expect(hasForceWriteBack)
    }

    @Test("[c] cancel from a fallback-origin conflict returns to the code pane, not a dead nvim pane")
    func cancelReturnsToCodePane() {
        let s = fallbackModalState()
        let (next, _) = foApply(s, .key(.char("c"), modifiers: []))
        if case .pane(.codePane) = next.focus {
            // correct
        } else {
            Issue.record("Expected .pane(.codePane), got \(next.focus)")
        }
    }

    @Test("[r] reload from a fallback-origin conflict returns to the code pane and detaches")
    func reloadReturnsToCodePane() {
        let s = fallbackModalState()
        let (next, effects) = foApply(s, .key(.char("r"), modifiers: []))
        if case .pane(.codePane) = next.focus {
            // correct
        } else {
            Issue.record("Expected .pane(.codePane), got \(next.focus)")
        }
        let hasDetach = effects.contains {
            if case .nvimDetach = $0 { return true }
            return false
        }
        #expect(hasDetach)
    }

    @Test("[d]→diff→[c] preserves returnsToNvim=false through the round-trip")
    func diffRoundTripPreservesFallbackOrigin() {
        let s = fallbackModalState()
        let (afterD, _) = foApply(s, .key(.char("d"), modifiers: []))
        let diffState = DiffViewState(
            leftTitle: "On disk", rightTitle: "Edited",
            leftLines: ["a"], rightLines: ["b"])
        let (afterReady, _) = foApply(afterD, .diffViewReady(diffState))
        let (afterC, _) = foApply(afterReady, .key(.char("c"), modifiers: []))
        guard case .conflictModal(let restored) = afterC.focus else {
            Issue.record("Expected .conflictModal, got \(afterC.focus)")
            return
        }
        #expect(restored.returnsToNvim == false)
    }
}

// MARK: - Suite: diff-view cancel with no pending modal

@Suite("NvimConflictModal — diff cancel nil-pending fallback")
struct DiffCancelNilPendingTests {

    @Test("[c] in the diff view with no pending modal returns to the code pane, not a dead nvim pane")
    func diffCancelNilPendingReturnsToCodePane() {
        var s = foCodePaneAppState()
        let diffState = DiffViewState(
            leftTitle: "On disk", rightTitle: "Edited",
            leftLines: ["a"], rightLines: ["b"])
        s.focus = .diffView(.ready(diffState))
        s.pendingConflictModal = nil
        let (next, _) = foApply(s, .key(.char("c"), modifiers: []))
        if case .pane(.codePane) = next.focus {
            // correct
        } else {
            Issue.record("Expected .pane(.codePane), got \(next.focus)")
        }
    }
}
