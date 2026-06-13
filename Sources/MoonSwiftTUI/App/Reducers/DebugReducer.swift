// File: Sources/MoonSwiftTUI/App/Reducers/DebugReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: Pure reducer logic for F6.1 — breakpoint toggling, <C-g> debug-run
//       preconditions, and AppEvent.debug* event handlers. Called by Reducer.swift;
//       never calls impure code. All impure work (calling runForDebug, posting
//       debug events) is done by AppDriver+DebugEffects.swift.
//
//       Key UX decisions (ux-spec §7.2, §2.3 amended):
//         - `b` toggles a breakpoint on the cursor line, context-scoped: only when
//           code-pane focus AND a fragment is selected AND cursor is on a code line.
//           Otherwise a disabled-action transient (ux-spec §2.4).
//         - `b` for scroll-up-full-page is RETIRED; that binding moves to `<C-b>`
//           (UX-01 collision resolution). `b` in the code pane now = breakpoint.
//         - `<C-g>` starts a debug run with four precondition gates (ux-spec §7.2).
//         - Restart confirmation (`y`/`N`) gates a live debug-session restart.
//         - Breakpoints are stored fragment-relative (1-based cursor line),
//           per-SourceID, in AppState.breakpoints.
//
// Upstream: AppState, AppEvent, Effect (Effect.debugRun, .stopDebug)
// Downstream: Reducer.swift (calls reduceDebugEvent, tryDebugRun,
//             reduceBreakpointToggle), AppDriver+DebugEffects.swift

import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit

// MARK: - Breakpoint toggle (b key in code pane)

/// Handle the `b` key in the code pane — toggle a breakpoint on the cursor line.
///
/// Context preconditions (all must hold; else a disabled-action transient):
///   1. Focus is `.pane(.codePane)`.
///   2. A fragment is selected and loaded.
///   3. The cursor line is a valid code line (≥ 0 within the fragment).
///
/// Breakpoints are stored 1-based (matching the ux-spec §7.2 gutter `○`/`●`
/// display and the engine's 1-based line convention). The cursor line in
/// `AppState.codePane.cursorLine` is 0-based, so we add 1 when storing.
func reduceBreakpointToggle(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    // Context guard 1: code pane must be focused.
    guard case .pane(.codePane) = s.focus else {
        return disabledTransient(s, text: "Breakpoints only available in the code pane")
    }

    // Context guard 2: a fragment must be selected and loaded.
    guard let sid = s.selection,
        case .loaded(let fragment) = s.sources[sid]
    else {
        return disabledTransient(s, text: "No source loaded")
    }

    // Context guard 3: cursor line must be a valid code line.
    let cursorLine0 = s.codePane.cursorLine  // 0-based
    let fragmentLineCount = fragment.code.components(separatedBy: "\n").count
    guard cursorLine0 >= 0, cursorLine0 < fragmentLineCount else {
        return disabledTransient(s, text: "Cursor is not on a code line")
    }

    // Toggle: store 1-based line number.
    let line1 = cursorLine0 + 1
    var bps = s.breakpoints[sid] ?? []
    if bps.contains(line1) {
        bps.remove(line1)
    } else {
        bps.insert(line1)
    }
    s.breakpoints[sid] = bps.isEmpty ? nil : bps

    // Recompute gutter marks so `○`/`●` render immediately (no separate event).
    s.codePane.gutterMarks = debugGutterMarks(
        diagnosticMarks: diagnosticGutterMarks(s),
        breakpoints: bps,
        pausedLine: s.currentDebugSnapshot?.fragmentLine
    )

    return (s, [])
}

// MARK: - Debug run (<C-g> in global or code-pane context)

/// Handle `<C-g>` — start or restart a debug run.
///
/// Four preconditions (ux-spec §7.2 / task #10 details, exact transients):
///   (a) no source loaded      → `"No source to debug."`
///   (b) run in progress       → `"A run is already in progress."`
///   (c) debug session active  → confirmation `"Restart debug session? [y/N]"`
///   (d) unsupported Lua ver   → `"Debugging unavailable for this Lua version."`
func tryDebugRun(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    // Precondition (a): no source.
    guard let sid = s.selection,
        case .loaded(let fragment) = s.sources[sid]
    else {
        return disabledTransient(s, text: "No source to debug.")
    }

    // Precondition (b): run in progress.
    if case .running = s.runState {
        return disabledTransient(s, text: "A run is already in progress.")
    }

    // Precondition (c): debug session already active → request restart confirmation.
    if s.activeDebugSessionID != nil {
        s.transient = TransientMessage(text: "Restart debug session? [y/N]")
        s.debugRestartPending = true
        return (s, [armDebugTickIfNeeded(s)].compactMap { $0 })
    }

    // Precondition (d): unsupported Lua version.
    if case .unsupportedVersion = s.project {
        return disabledTransient(s, text: "Debugging unavailable for this Lua version.")
    }

    return launchDebugRun(s, fragment: fragment, sourceID: sid)
}

/// Handle the restart-confirmation response (`y` confirms; anything else cancels).
///
/// Called by `Reducer.swift` when `debugRestartPending` is true and a key arrives
/// in the code pane or globally. Only `y` re-launches; any other key clears the
/// pending state silently per the `[y/N]` convention (matching picker discard).
func reduceDebugRestartKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("y"), []):
        // Tear down the active session, then relaunch.
        guard let sid = s.selection,
            case .loaded(let fragment) = s.sources[sid]
        else {
            s.debugRestartPending = false
            return (s, [])
        }
        var effects: [Effect] = []
        if let activeID = s.activeDebugSessionID {
            effects.append(.stopDebug(activeID))
        }
        s.activeDebugSessionID = nil
        s.currentDebugSnapshot = nil
        s.debugRestartPending = false

        let (newState, launchEffects) = launchDebugRun(s, fragment: fragment, sourceID: sid)
        effects += launchEffects
        return (newState, effects)

    default:
        // N or anything else — cancel the confirmation.
        s.debugRestartPending = false
        s.transient = nil
        return (s, [])
    }
}

// MARK: - Debug event handlers

/// Handle `AppEvent.debugPaused` — update state with the pause snapshot.
///
/// Updates the current snapshot, switches the bottom pane to the Debug tab
/// (auto-shows per ux-spec §6.1), and rebuilds gutter marks to show `▶`/`●`
/// on the paused line.
func reduceDebugPaused(_ s: AppState, snapshot: DebugSnapshot) -> (AppState, [Effect]) {
    var s = s
    s.currentDebugSnapshot = snapshot
    s.activeDebugSessionID = snapshot.sessionID

    // Auto-show the Debug tab (ux-spec §6.1, §7.2).
    s.bottomPane.activeTab = .debug

    // Rebuild gutter marks: breakpoints + paused line.
    if let sid = s.selection {
        let bps = s.breakpoints[sid] ?? []
        s.codePane.gutterMarks = debugGutterMarks(
            diagnosticMarks: diagnosticGutterMarks(s),
            breakpoints: bps,
            pausedLine: snapshot.fragmentLine
        )
    }

    return (s, [armDebugTickIfNeeded(s)].compactMap { $0 })
}

/// Handle `AppEvent.debugFinished` — clear the active debug session.
func reduceDebugFinished(
    _ s: AppState,
    sessionID: DebugSessionID,
    outcome: CoreRunOutcome
) -> (AppState, [Effect]) {
    var s = s

    // Only clear if this event matches the active session (stale IDs are no-ops).
    guard s.activeDebugSessionID == sessionID else { return (s, []) }

    s.activeDebugSessionID = nil
    s.currentDebugSnapshot = nil
    s.debugRestartPending = false

    // Rebuild gutter marks: remove the `▶`/`●` paused marker.
    if let sid = s.selection {
        let bps = s.breakpoints[sid] ?? []
        s.codePane.gutterMarks = debugGutterMarks(
            diagnosticMarks: diagnosticGutterMarks(s),
            breakpoints: bps,
            pausedLine: nil
        )
    }

    // Log engine-level failures.
    if case .error(let diag, _) = outcome {
        Logger.shared.error("Debug run error: \(diag.message)")
    }

    return (s, [armDebugTickIfNeeded(s)].compactMap { $0 })
}

// MARK: - Gutter mark helpers

/// Build the merged gutter mark dictionary for the code pane.
///
/// Priority (ux-spec §6.6 row order, highest first):
///   `pausedBreakpoint` > `debugPaused` > `breakpoint` > `error` > `warning`
///
/// - Parameters:
///   - diagnosticMarks: Existing lint/run marks (error/warning) keyed 0-based.
///   - breakpoints: Fragment-relative breakpoint lines (1-based) for the current source.
///   - pausedLine: Fragment-relative pause line (1-based) from `DebugSnapshot.fragmentLine`,
///     or `nil` when no session is paused.
func debugGutterMarks(
    diagnosticMarks: [Int: GutterMark],
    breakpoints: Set<Int>,
    pausedLine: Int?
) -> [Int: GutterMark] {
    // Start with the diagnostic marks.
    var marks = diagnosticMarks

    // Apply breakpoint marks (0-based key = line1 - 1).
    for line1 in breakpoints {
        let key = line1 - 1
        marks[key] = .breakpoint
    }

    // Apply the paused-line mark, overriding any breakpoint mark on the same line.
    if let paused = pausedLine {
        let key = paused - 1
        if marks[key] == .breakpoint {
            marks[key] = .pausedBreakpoint
        } else {
            marks[key] = .debugPaused
        }
    }

    return marks
}

// MARK: - Private helpers

/// Launch a debug run for `fragment` using the current breakpoints for `sourceID`.
///
/// Translates fragment-relative breakpoints to engine-line numbers via
/// `fragment.provenance.lineOffset` at the boundary (NOT double-applied):
/// engine line = fragment-relative line (the adapter already stores them 1-based).
/// The `lineOffset` is NOT added here; the adapter uses the fragment directly and
/// the breakpoints are already in fragment-relative space.
private func launchDebugRun(
    _ s: AppState,
    fragment: LuaSourceFragment,
    sourceID: SourceID
) -> (AppState, [Effect]) {
    var s = s
    let bps = s.breakpoints[sourceID] ?? []

    // Auto-show Debug tab (ux-spec §7.2).
    s.bottomPane.activeTab = .debug

    let effects: [Effect] = [
        .debugRun(fragment, breakpoints: bps),
        armDebugTickIfNeeded(s) ?? .startTick(interval: TickInterval.transientExpiry),
    ]
    return (s, effects)
}

/// Returns a tick effect if needed, accounting for debug-session activity.
private func armDebugTickIfNeeded(_ s: AppState) -> Effect? {
    // A transient is showing.
    if s.transient != nil {
        return .startTick(interval: TickInterval.transientExpiry)
    }
    // A debug session is active — keep the tick alive for UI updates.
    if s.activeDebugSessionID != nil {
        return .startTick(interval: TickInterval.transientExpiry)
    }
    return nil
}

/// Build diagnostic-only gutter marks from the current bottom pane state.
///
/// Produces `error`/`warning` keyed by 0-based fragment-relative line.
/// Mirror of `gutterMarks(from:)` in Reducer.swift — kept here so DebugReducer
/// can recompute the merged mark set without a cross-file call.
private func diagnosticGutterMarks(_ s: AppState) -> [Int: GutterMark] {
    var marks: [Int: GutterMark] = [:]
    for d in s.bottomPane.diagnostics {
        let line = max(0, d.line - 1)
        switch d.severity {
        case .error:
            marks[line] = .error
        case .warning:
            if marks[line] == nil {
                marks[line] = .warning
            }
        }
    }
    return marks
}

/// Return a disabled-action transient with the standard 1.5 s duration (ux-spec §2.4).
private func disabledTransient(_ s: AppState, text: String) -> (AppState, [Effect]) {
    var s = s
    s.transient = TransientMessage(text: text)
    return (s, [.startTick(interval: TickInterval.transientExpiry)])
}
