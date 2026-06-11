// File: Tests/MoonSwiftTUITests/Nvim/NvimDiffViewTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: TDD reducer sequence tests for Inc-9 — diff-view state transitions and
//       syntax pre-pass failure routing at the coordinator + reducer levels.
//       (ARCHITECTURE.md §10.8 Inc-9, §10.4.10, ux-spec §7.3, §7.4)
//
// Coverage:
//   1. DiffViewState off-thread construction (.building → .ready) at the
//      reducer level via AppEvent.diffViewReady.
//   2. diffView [c] cancel returns to .nvimPane (focus restored).
//   3. diffView j/k scrolling increments/decrements scrollOffset on .ready state.
//   4. Keys in .diffView(.building) are absorbed (no state change).
//   5. Syntax pre-pass failure in WriteBackCoordinator returns .spliceError whose
//      reason contains "line N" (integration with MockLintService seam).
//   6. writeBackBlocked event reducer path: transient text contains the message
//      and line number from the diagnostic (exact "Syntax error: <msg> (line N)").
//   7. DiffViewState equality — scrollOffset changes produce a new value.
//
// Relationships:
//   → Reducer.swift (Inc-9): reduceDiffViewKey, AppEvent.diffViewReady arm
//   → AppState.swift (Inc-9): DiffViewState, DiffViewPhase
//   → WriteBackCoordinator.swift: syntaxPrePass path (MockLintService seam)
//   → WriteBackTestSupport.swift: MockLintService, WriteBackFixtures

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Private helpers

/// Apply one event and return (state, effects).
private func dvApply(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    reduce(state, event)
}

/// Build a minimal AppState with focus on `.diffView(phase)`.
private func makeDiffViewState(phase: DiffViewPhase) -> AppState {
    AppState(
        focus: .diffView(phase),
        terminalSize: TerminalSize(cols: 120, rows: 40)
    )
}

/// Build a ready DiffViewState for tests.
private func makeReadyDiffState(
    leftLines: [String] = ["old line 1", "old line 2"],
    rightLines: [String] = ["new line 1", "new line 2"],
    scrollOffset: Int = 0
) -> DiffViewState {
    DiffViewState(
        leftTitle: "On disk — test.lua",
        rightTitle: "Edited",
        leftLines: leftLines,
        rightLines: rightLines,
        scrollOffset: scrollOffset
    )
}

// MARK: - Suite: DiffView state transitions

@Suite("NvimDiffView — state transitions")
struct DiffViewStateTransitionTests {

    @Test("diffViewReady from .building transitions to .ready(state)")
    func diffViewReadyTransitionFromBuilding() {
        let s = makeDiffViewState(phase: .building)
        let diffState = makeReadyDiffState()
        let (next, effects) = dvApply(s, .diffViewReady(diffState))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state == diffState)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
        #expect(effects.isEmpty)
    }

    @Test("diffViewReady from .ready replaces the existing DiffViewState")
    func diffViewReadyReplacesExisting() {
        let initial = makeReadyDiffState(leftLines: ["initial"])
        let s = makeDiffViewState(phase: .ready(initial))
        let replacement = makeReadyDiffState(leftLines: ["replaced"])

        let (next, _) = dvApply(s, .diffViewReady(replacement))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.leftLines == ["replaced"])
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }
}

// MARK: - Suite: DiffView key handling

@Suite("NvimDiffView — key handling")
struct DiffViewKeyHandlingTests {

    @Test("[c] in .diffView(.ready) returns focus to .nvimPane")
    func cancelReturnsFocusToNvimPane() {
        let diffState = makeReadyDiffState()
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.char("c"), modifiers: []))

        if case .nvimPane = next.focus {
            // correct
        } else {
            Issue.record("Expected .nvimPane, got \(next.focus)")
        }
    }

    @Test("[c] in .diffView(.ready) emits no action effects")
    func cancelEmitsNoEffects() {
        let diffState = makeReadyDiffState()
        let s = makeDiffViewState(phase: .ready(diffState))
        let (_, effects) = dvApply(s, .key(.char("c"), modifiers: []))
        let actionEffects = effects.filter {
            switch $0 {
            case .startTick, .stopTick: return false
            default: return true
            }
        }
        #expect(actionEffects.isEmpty)
    }

    @Test("[j] in .diffView(.ready) increments scrollOffset by 1")
    func jScrollsDown() {
        let diffState = makeReadyDiffState(scrollOffset: 0)
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.char("j"), modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 1)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("[k] in .diffView(.ready) decrements scrollOffset by 1")
    func kScrollsUp() {
        let diffState = makeReadyDiffState(scrollOffset: 2)
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.char("k"), modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 1)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("[k] does not decrement scrollOffset below zero")
    func kDoesNotGoNegative() {
        let diffState = makeReadyDiffState(scrollOffset: 0)
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.char("k"), modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 0)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("down arrow in .diffView(.ready) increments scrollOffset by 1")
    func downArrowScrolls() {
        let diffState = makeReadyDiffState(scrollOffset: 0)
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.down, modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 1)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("up arrow in .diffView(.ready) decrements scrollOffset by 1")
    func upArrowScrolls() {
        let diffState = makeReadyDiffState(scrollOffset: 3)
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.up, modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 2)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("[j] does not scroll past max offset (left or right line count - 1)")
    func jClampsAtMax() {
        // 2 lines each → max offset = 1
        let diffState = makeReadyDiffState(
            leftLines: ["a", "b"],
            rightLines: ["x", "y"],
            scrollOffset: 1
        )
        let s = makeDiffViewState(phase: .ready(diffState))
        let (next, _) = dvApply(s, .key(.char("j"), modifiers: []))

        if case .diffView(.ready(let state)) = next.focus {
            #expect(state.scrollOffset == 1)
        } else {
            Issue.record("Expected .diffView(.ready), got \(next.focus)")
        }
    }

    @Test("all keys absorbed while .diffView(.building)")
    func keysAbsorbedWhileBuilding() {
        let s = makeDiffViewState(phase: .building)
        for key: KeyCode in [.char("j"), .char("k"), .char("c"), .enter, .escape] {
            let (next, effects) = dvApply(s, .key(key, modifiers: []))
            // Focus must remain .diffView(.building)
            if case .diffView(.building) = next.focus {
                // correct
            } else {
                Issue.record("Key \(key) changed focus from .building")
            }
            let actionEffects = effects.filter {
                switch $0 {
                case .startTick, .stopTick: return false
                default: return true
                }
            }
            #expect(actionEffects.isEmpty)
        }
    }
}

// MARK: - Suite: DiffViewState value semantics

@Suite("NvimDiffView — DiffViewState value semantics")
struct DiffViewStateValueSemanticsTests {

    @Test("DiffViewState with different scrollOffset is not equal")
    func diffScrollOffsetEquality() {
        let a = DiffViewState(
            leftTitle: "A",
            rightTitle: "B",
            leftLines: ["line"],
            rightLines: ["line"],
            scrollOffset: 0
        )
        var b = a
        b.scrollOffset = 1
        #expect(a != b)
    }

    @Test("DiffViewState with same fields is equal")
    func diffStateEquality() {
        let a = makeReadyDiffState()
        let b = makeReadyDiffState()
        #expect(a == b)
    }
}

// MARK: - Suite: Syntax pre-pass failure in WriteBackCoordinator

@Suite("NvimDiffView — WriteBackCoordinator syntax pre-pass failure")
struct WriteBackSyntaxPrePassTests {

    @Test("syntaxPrePass failure returns .spliceError(.reparseFailed) containing 'line N'")
    func syntaxPrePassFailureProducesReparseFailed() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "return 1\n", provenance: provenance)

        // Stub: diagnostic whose message contains "(line N)" as the coordinator formats it.
        let diagnostic = Diagnostic(
            severity: .error,
            line: 5,
            message: "unexpected symbol",
            source: .syntaxPrePass
        )
        let lint = MockLintService(stubbedDiagnostic: diagnostic)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "function(",
            projectRoot: dir,
            lintService: lint,
            force: false
        )

        guard case .spliceError(let err) = result.outcome else {
            Issue.record("Expected .spliceError, got \(result.outcome)")
            return
        }
        // The coordinator formats the reason as "<message> (line <line>)".
        if case .reparseFailed(let reason) = err {
            #expect(reason.contains("line"))
            #expect(reason.contains("5"))
        } else {
            Issue.record("Expected .reparseFailed, got \(err)")
        }
        #expect(result.newData == nil)
    }

    @Test("syntaxPrePass failure reason propagates the diagnostic message")
    func syntaxPrePassReasonContainsDiagnosticMessage() async throws {
        let dir = try WriteBackFixtures.tempDir()
        let fileURL = try WriteBackFixtures.copyFixture("hello.lua", into: dir)
        let provenance = try WriteBackFixtures.luaProvenance(fileURL: fileURL)
        let fragment = LuaSourceFragment(code: "return 1\n", provenance: provenance)

        let diagnostic = Diagnostic(
            severity: .error,
            line: 3,
            message: "unexpected symbol near '<eof>'",
            source: .syntaxPrePass
        )
        let lint = MockLintService(stubbedDiagnostic: diagnostic)

        let result = await WriteBackCoordinator.write(
            fragment: fragment,
            editedText: "function(",
            projectRoot: dir,
            lintService: lint,
            force: false
        )

        guard case .spliceError(.reparseFailed(let reason)) = result.outcome else {
            Issue.record("Expected .spliceError(.reparseFailed), got \(result.outcome)")
            return
        }
        #expect(reason.contains("unexpected symbol near '<eof>'"))
    }
}

// writeBackBlocked and nvimWriteRequested reducer tests live in
// NvimWriteBackOutcomeTests.swift.
