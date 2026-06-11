// File: Tests/MoonSwiftTUITests/Nvim/NvimWriteBackOutcomeTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer sequence tests for Inc-9 write-back outcome paths.
//       (ARCHITECTURE.md §10.8 Inc-9, §10.6 error taxonomy)
//
// Coverage:
//   - writeBackSucceeded → Effect.loadSource emitted
//   - writeBackFailed outcome mapping (exact transient strings per §10.6)
//   - writeBackBlocked (syntax pre-pass): exact transient format
//   - nvimWriteRequested: Effect.writeBack sentinel emission
//
// Relationships:
//   → Reducer.swift (Inc-9): reduceWriteBackFailed, writeBackBlocked arm,
//                            reduceNvimWriteRequested
//   → AppEvent.swift (Inc-9): writeBackSucceeded, writeBackFailed, writeBackBlocked,
//                             nvimWriteRequested

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Private helpers

private func wboMakeFragment(path: String = "/tmp/wb_test.lua") -> LuaSourceFragment {
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

private func wboMakeNvimPaneState(path: String = "/tmp/wb_test.lua") -> AppState {
    let sid = SourceID(path: "wb_test.lua")
    let fragment = wboMakeFragment(path: path)
    return AppState(
        sources: [sid: .loaded(fragment)],
        navigatorOrder: [sid],
        selection: sid,
        focus: .nvimPane(NvimPaneState(attachedRect: Rect(x: 18, y: 1, width: 102, height: 22))),
        terminalSize: TerminalSize(cols: 120, rows: 40)
    )
}

private func wboApply(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

private func wboLoadSourceID(from effects: [Effect]) -> SourceID? {
    for e in effects {
        if case .loadSource(let id) = e { return id }
    }
    return nil
}

private func wboExtractWriteBack(
    from effects: [Effect]
) -> (fragment: LuaSourceFragment, editedText: String, force: Bool)? {
    for e in effects {
        if case .writeBack(let frag, let text, let force) = e {
            return (frag, text, force)
        }
    }
    return nil
}

private func wboActionEffects(_ effects: [Effect]) -> [Effect] {
    effects.filter {
        switch $0 {
        case .startTick, .stopTick: return false
        default: return true
        }
    }
}

// MARK: - Suite: writeBackSucceeded

@Suite("NvimWriteBackOutcome — writeBackSucceeded")
struct WriteBackSucceededTests {

    @Test("writeBackSucceeded emits Effect.loadSource for the given source")
    func writeBackSucceededEmitsLoadSource() {
        let sid = SourceID(path: "wb_test.lua")
        let s = wboMakeNvimPaneState()
        let (_, effects) = wboApply(s, .writeBackSucceeded(sid))
        #expect(wboLoadSourceID(from: effects) == sid)
    }

    @Test("writeBackSucceeded does not change focus")
    func writeBackSucceededPreservesFocus() {
        let sid = SourceID(path: "wb_test.lua")
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(s, .writeBackSucceeded(sid))
        if case .nvimPane = next.focus {
            // correct
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }
}

// MARK: - Suite: writeBackFailed outcome mapping

@Suite("NvimWriteBackOutcome — writeBackFailed mapping")
struct WriteBackFailedMappingTests {

    @Test(".validateReadableRejection(.notRegularFile) → 'Cannot read file: not a regular file'")
    func failedNotRegularFile() {
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(s, .writeBackFailed(.validateReadableRejection(.notRegularFile)))
        #expect(next.transient?.text == "Cannot read file: not a regular file")
    }

    @Test(".validateReadableRejection(.outsideProjectRoot) → 'Cannot read file: path is outside project root'")
    func failedOutsideRoot() {
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(
            s, .writeBackFailed(.validateReadableRejection(.outsideProjectRoot)))
        #expect(next.transient?.text == "Cannot read file: path is outside project root")
    }

    @Test(".validateReadableRejection(.tooLarge(50)) → 'Cannot read file: exceeds 50 MiB limit'")
    func failedTooLarge() {
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(
            s, .writeBackFailed(.validateReadableRejection(.tooLarge(limitMiB: 50))))
        #expect(next.transient?.text == "Cannot read file: exceeds 50 MiB limit")
    }

    @Test(".ioFailure('boom') → 'Write failed: boom'")
    func failedIOFailure() {
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(s, .writeBackFailed(.ioFailure("boom")))
        #expect(next.transient?.text == "Write failed: boom")
    }

    @Test(".spliceError produces a 'Write failed:' transient")
    func failedSpliceError() {
        let s = wboMakeNvimPaneState()
        let (next, _) = wboApply(s, .writeBackFailed(.spliceError(.fieldMismatch)))
        guard let text = next.transient?.text else {
            Issue.record("Expected a transient message")
            return
        }
        #expect(text.hasPrefix("Write failed:"))
    }

    @Test(".success is a no-op (defensive — should not arrive on failed path)")
    func failedSuccessNoOp() {
        let s = wboMakeNvimPaneState()
        let (next, effects) = wboApply(s, .writeBackFailed(.success))
        #expect(next.transient == nil)
        #expect(wboActionEffects(effects).isEmpty)
    }

    @Test(".conflictDetected is a no-op (handled by its own event path)")
    func failedConflictDetectedNoOp() {
        let s = wboMakeNvimPaneState()
        let (next, effects) = wboApply(s, .writeBackFailed(.conflictDetected))
        #expect(next.transient == nil)
        #expect(wboActionEffects(effects).isEmpty)
    }
}

// MARK: - Suite: writeBackBlocked (syntax pre-pass reducer path)

@Suite("NvimWriteBackOutcome — writeBackBlocked")
struct WriteBackBlockedReducerTests {

    @Test("writeBackBlocked transient is exactly 'Syntax error: <msg> (line N)'")
    func blockedExactFormat() {
        let s = wboMakeNvimPaneState()
        let diag = Diagnostic(
            severity: .error,
            line: 7,
            message: "bad argument",
            source: .syntaxPrePass
        )
        let (next, _) = wboApply(s, .writeBackBlocked(diag))
        #expect(next.transient?.text == "Syntax error: bad argument (line 7)")
    }

    @Test("writeBackBlocked includes the message and line number from the diagnostic")
    func blockedContainsDiagFields() {
        let s = wboMakeNvimPaneState()
        let diag = Diagnostic(
            severity: .error,
            line: 3,
            message: "unexpected symbol near '<eof>'",
            source: .syntaxPrePass
        )
        let (next, _) = wboApply(s, .writeBackBlocked(diag))
        guard let text = next.transient?.text else {
            Issue.record("Expected a transient message")
            return
        }
        #expect(text.contains("unexpected symbol near '<eof>'"))
        #expect(text.contains("3"))
    }

    @Test("writeBackBlocked does not change focus")
    func blockedDoesNotChangeFocus() {
        let s = wboMakeNvimPaneState()
        let diag = Diagnostic(severity: .error, line: 1, message: "e", source: .syntaxPrePass)
        let (next, _) = wboApply(s, .writeBackBlocked(diag))
        if case .nvimPane = next.focus {
            // correct
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }

    @Test("writeBackBlocked arms the tick source for transient expiry")
    func blockedArmsTickSource() {
        let s = wboMakeNvimPaneState()
        let diag = Diagnostic(severity: .error, line: 1, message: "e", source: .syntaxPrePass)
        let (_, effects) = wboApply(s, .writeBackBlocked(diag))
        let hasTick = effects.contains {
            if case .startTick = $0 { return true }
            return false
        }
        #expect(hasTick)
    }
}

// MARK: - Suite: nvimWriteRequested

@Suite("NvimWriteBackOutcome — nvimWriteRequested")
struct NvimWriteRequestedOutcomeTests {

    @Test("nvimWriteRequested emits Effect.writeBack with empty sentinel editedText")
    func writeRequestedEmitsWriteBack() {
        let s = wboMakeNvimPaneState()
        let (_, effects) = wboApply(s, .nvimWriteRequested)
        guard let wb = wboExtractWriteBack(from: effects) else {
            Issue.record("Expected writeBack effect")
            return
        }
        // Empty string is the sentinel: AppDriver fills it from nvim_buf_get_lines.
        #expect(wb.editedText == "")
        #expect(wb.force == false)
    }

    @Test("nvimWriteRequested is no-op when focus is not nvimPane")
    func writeRequestedNoOpOutsideNvimPane() {
        var s = wboMakeNvimPaneState()
        s.focus = .pane(.codePane)
        let (_, effects) = wboApply(s, .nvimWriteRequested)
        #expect(wboActionEffects(effects).isEmpty)
    }
}
