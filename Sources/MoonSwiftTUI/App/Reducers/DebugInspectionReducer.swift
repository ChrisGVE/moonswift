// File: Sources/MoonSwiftTUI/App/Reducers/DebugInspectionReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: Pure reducer logic for P2 F6.3 — the Debug tab's variable-inspection
//       interactions: `g` globals request, `<Enter>` frame-select / inline
//       expand, `j`/`k` row cursor, the per-pause inspection reset, and the
//       session-teardown clear. Split from DebugReducer.swift so F6.3 feature
//       logic lives in its own file (§4.1 file ownership / §4.7 codesize).
//
//       All functions are pure: they emit `Effect.requestGlobals` for the one
//       side-effecting action (the in-place globals capture, serviced by the
//       core mailbox) and otherwise only transition `AppState`. The row layout
//       they navigate comes from `buildDebugRows` (DebugTabView.swift), the same
//       function the renderer uses, so the cursor walks exactly the rows shown.
//
// Upstream: AppState, DebugSnapshot (MoonSwiftCore), Effect.requestGlobals,
//           buildDebugRows (DebugTabView.swift)
// Downstream: DebugReducer.swift (reduceDebugPaused → applyPauseInspection;
//             reduceDebugFinished / reduceDebugStop → clearDebugInspectionState),
//             Reducer.swift (reduceBottomPaneKey dispatch for g / Enter / j / k)

import Foundation
import MoonSwiftCore

// MARK: - Pause-snapshot inspection transition

/// Apply the F6.3 inspection-state transition for a new pause snapshot.
///
/// Sets the live (`currentDebugSnapshot`) and retained (`lastPauseSnapshot`)
/// snapshots, resolves any in-flight globals request, and resets the per-pause
/// inspection cursor — but ONLY for a fresh pause. A globals-republish (the `g`
/// path captures in-place and re-publishes at the SAME line WITHOUT resuming the
/// VM, §F6.0 §2 / DOM-08) must preserve the user's frame selection / expansion /
/// cursor. We tell the two apart because a fresh pause is always preceded by a
/// resume that nils `currentDebugSnapshot`: a snapshot already present at the
/// same session + line means this is the in-place globals refresh.
func applyPauseInspection(_ s: inout AppState, snapshot: DebugSnapshot) {
    let isGlobalsRepublish =
        s.currentDebugSnapshot.map {
            $0.sessionID == snapshot.sessionID && $0.fragmentLine == snapshot.fragmentLine
        } ?? false

    s.currentDebugSnapshot = snapshot
    s.lastPauseSnapshot = snapshot
    s.activeDebugSessionID = snapshot.sessionID
    // The launch has resolved into a real session ID (CR-002).
    s.debugLaunchPending = false
    // The globals capture (if any) has now resolved into this snapshot.
    s.debugGlobalsRequested = false
    if !isGlobalsRepublish {
        s.debugSelectedFrame = 0
        s.debugSelectedRow = 0
        s.debugExpandedPaths = []
    }
}

/// Reset the per-session Debug-tab inspection cursor + globals state.
///
/// Called on session teardown (`debugFinished` / `x` stop) so a later session
/// starts from a clean frame/expansion/cursor and never inherits a stale
/// `(globals pending…)` latch.
func clearDebugInspectionState(_ s: inout AppState) {
    s.lastPauseSnapshot = nil
    s.debugSelectedFrame = 0
    s.debugSelectedRow = 0
    s.debugExpandedPaths = []
    s.debugGlobalsRequested = false
}

// MARK: - Debug-tab key handlers (g / Enter / j / k)

/// Handle `g` in the Debug tab — request the bounded/filtered globals slice.
///
/// Only meaningful while paused (the inspector must be live for the in-place
/// capture, §F6.0 §2). Sets the `(globals pending…)` latch and emits
/// `Effect.requestGlobals`; the republished snapshot clears the latch. When the
/// VM is not paused, `g` has no debug meaning here → silent no-op.
func reduceDebugGlobalsRequest(_ s: AppState) -> (AppState, [Effect]) {
    guard let snapshot = s.currentDebugSnapshot else { return (s, []) }
    var s = s
    s.debugGlobalsRequested = true
    return (
        s,
        [
            .requestGlobals(snapshot.sessionID),
            .startTick(interval: TickInterval.transientExpiry),
        ]
    )
}

/// Handle `<Enter>` in the Debug tab — act on the row under the `j`/`k` cursor.
///
/// A Call-Stack frame row selects that frame (its locals/upvalues then render
/// from the cached `frameVars`, NO engine re-entry) and retargets the code pane
/// to the frame's source line. An expandable value row toggles its inline
/// expansion. Only active while paused; the cursor is clamped to the new row
/// list after the action changes it.
func reduceDebugTabEnter(_ s: AppState) -> (AppState, [Effect]) {
    guard s.currentDebugSnapshot != nil else { return (s, []) }
    let selectable = buildDebugRows(s).filter { $0.isSelectable }
    guard s.debugSelectedRow >= 0, s.debugSelectedRow < selectable.count else { return (s, []) }

    var s = s
    switch selectable[s.debugSelectedRow] {
    case .frame(let f):
        s.debugSelectedFrame = f.level
        // Retarget the code pane to the frame's line (1-based → 0-based offset).
        if let frame = s.currentDebugSnapshot?.callStack.first(where: { $0.level == f.level }),
            frame.line > 0
        {
            s.codePane.scrollOffset = max(0, frame.line - 1)
            s.codePane.cursorLine = s.codePane.scrollOffset
        }
    case .variable(let v):
        if s.debugExpandedPaths.contains(v.path) {
            s.debugExpandedPaths.remove(v.path)
        } else {
            s.debugExpandedPaths.insert(v.path)
        }
    case .header, .info:
        return (s, [])
    }

    // Selecting a frame or toggling expansion changes the row list; clamp.
    let newCount = buildDebugRows(s).filter { $0.isSelectable }.count
    s.debugSelectedRow = newCount == 0 ? 0 : min(s.debugSelectedRow, newCount - 1)
    return (s, [])
}

/// Move the Debug-tab `j`/`k` cursor by `delta` over the selectable rows.
///
/// Clamped to `[0, selectableCount)`. No-op when not paused or when there are no
/// selectable rows (all sections empty).
func reduceDebugRowMove(_ s: AppState, delta: Int) -> (AppState, [Effect]) {
    guard s.currentDebugSnapshot != nil else { return (s, []) }
    let count = buildDebugRows(s).filter { $0.isSelectable }.count
    guard count > 0 else { return (s, []) }
    var s = s
    s.debugSelectedRow = max(0, min(count - 1, s.debugSelectedRow + delta))
    return (s, [])
}
