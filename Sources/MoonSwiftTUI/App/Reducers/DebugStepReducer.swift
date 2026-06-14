// File: Sources/MoonSwiftTUI/App/Reducers/DebugStepReducer.swift
// Location: MoonSwiftTUI/App/Reducers/
// Role: Pure reducer logic for the P2 F6.2 stepping controls — the s/i/o/c step
//       keys, the `x` stop, the navigator paused-key guard transient, and the
//       status-bar paused hint. Split from DebugReducer.swift (CS-2 codesize) so
//       the lifecycle/event handlers and the stepping handlers live in focused
//       files; both are pure functions sharing only the module-internal
//       `disabledTransient` / `debugGutterMarks` / `gutterMarks(from:)` helpers.
//
// Upstream: AppState, Effect (sendDebugCommand), LuaDebugCommand (LuaSwift),
//           disabledTransient / debugGutterMarks (DebugReducer.swift),
//           gutterMarks(from:) (Reducer.swift),
//           clearDebugInspectionState (DebugInspectionReducer.swift)
// Downstream: Reducer.swift (reduceDebugStepKey / reduceDebugStop /
//             reduceNavigatorDebugKeyTransient dispatch; buildPausedStatusHint render)

import Foundation
import LuaSwift
import MoonSwiftCore
import RatatuiKit

// MARK: - F6.2 Stepping key handlers

/// Handle s/i/o/c step keys while the code pane or Debug tab is focused.
///
/// Paused (snapshot present): emit `Effect.sendDebugCommand` and clear the
/// snapshot so the Debug tab enters §6.9 Case-2 "VM running between pauses".
/// VM running (session active, no snapshot): show `"VM running…"` disabled
/// transient (step keys are inert while the VM is between pauses).
/// No active session: silent no-op (keys have no meaning outside debug).
func reduceDebugStepKey(
    _ s: AppState,
    command: LuaDebugCommand
) -> (AppState, [Effect]) {
    // No session → these keys have no debug meaning in this context.
    guard let sessionID = s.activeDebugSessionID else { return (s, []) }

    // Session active but NOT paused → VM is running between pauses (§6.9 Case-2).
    guard s.currentDebugSnapshot != nil else {
        return disabledTransient(s, text: "VM running…")
    }

    // Paused: deliver the command and clear the snapshot (Case-2 transition).
    var s = s
    s.currentDebugSnapshot = nil
    // A latched-but-unresolved `g` is discarded on resume (§6.9 Case-2).
    s.debugGlobalsRequested = false
    // Rebuild gutter marks: remove the ▶ paused-line marker (VM no longer at that line).
    if let sid = s.selection {
        let bps = s.breakpoints[sid] ?? []
        s.codePane.gutterMarks = debugGutterMarks(
            diagnosticMarks: gutterMarks(from: s.bottomPane.diagnostics),
            breakpoints: bps,
            pausedLine: nil
        )
    }
    return (s, [.sendDebugCommand(sessionID, command)])
}

/// Handle `x` stop key while a debug session is active (F6.2 override of global cancel).
///
/// Posts `.stop` to the session, clears the session ID and snapshot, and shows
/// the neutral `"Session stopped."` message (DOM-N01 — `LuaError.cancelled`
/// raised internally by `.stop` is mapped here, never surfaced as a `.cancelled`
/// error diagnostic).
func reduceDebugStop(_ s: AppState, sessionID: DebugSessionID) -> (AppState, [Effect]) {
    var s = s
    s.activeDebugSessionID = nil
    s.currentDebugSnapshot = nil
    s.debugRestartPending = false
    s.debugLaunchPending = false
    clearDebugInspectionState(&s)
    // Rebuild gutter marks: remove the paused-line marker.
    if let sid = s.selection {
        let bps = s.breakpoints[sid] ?? []
        s.codePane.gutterMarks = debugGutterMarks(
            diagnosticMarks: gutterMarks(from: s.bottomPane.diagnostics),
            breakpoints: bps,
            pausedLine: nil
        )
    }
    s.transient = TransientMessage(text: "Session stopped.")
    return (
        s,
        [
            .sendDebugCommand(sessionID, .stop),
            .startTick(interval: TickInterval.transientExpiry),
        ]
    )
}

/// Show transient directing paused-mode step keys to the Debug tab (F6.2 navigator guard).
///
/// Exact string (PRD §2566, ux-spec binding): `"Stepping is in the Debug tab — press 3."`
func reduceNavigatorDebugKeyTransient(_ s: AppState) -> (AppState, [Effect]) {
    return disabledTransient(s, text: "Stepping is in the Debug tab — press 3.")
}

// MARK: - Status bar paused hint

/// Build status-bar paused hint string (ux-spec §7.2, PRD §1473–1474).
///
/// Format (binding — snapshot tests depend on exact spacing):
/// `[paused at <display-name>:<line>]  s/i/o step  c continue  x stop`
/// Two spaces between groups per PRD.
func buildPausedStatusHint(displayName: String, line: Int) -> String {
    "[paused at \(displayName):\(line)]  s/i/o step  c continue  x stop"
}
