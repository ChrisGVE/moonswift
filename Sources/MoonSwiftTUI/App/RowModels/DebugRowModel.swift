// File: Sources/MoonSwiftTUI/App/RowModels/DebugRowModel.swift
// Location: MoonSwiftTUI/App/RowModels/
// Role: The Debug-tab row MODEL and its builder — pure `AppState → [DebugRow]`
//       logic with no rendering. Extracted from Render/DebugTabView.swift
//       (CR-012) so the reducer (DebugInspectionReducer: frame-select / expand /
//       j-k cursor) depends on a model-layer function, not on a view file. The
//       renderer (renderDebugTab) and the reducer both call `buildDebugRows`,
//       so the selectable rows the cursor walks are exactly the rows the user
//       sees — one source of truth, no parallel layout that could drift.
//
// Upstream: AppState (currentDebugSnapshot, lastPauseSnapshot, debugSelectedFrame,
//           debugSelectedRow, debugExpandedPaths, debugGlobalsRequested),
//           MoonSwiftCore (DebugSnapshot / DebugVariable / DebugFrame).
// Downstream: Render/DebugTabView.swift (renderDebugTab consumes these rows),
//             App/Reducers/DebugInspectionReducer.swift (row navigation + actions).

import Foundation
import MoonSwiftCore

// MARK: - DebugRow model

/// One rendered row of the Debug tab. Pure data: the renderer turns it into
/// spans, the reducer reads `isSelectable` to drive the `j`/`k` cursor and
/// `<Enter>`. Sections render in a fixed order: Locals, Upvalues, Globals,
/// Call Stack (ux-spec §7.2).
enum DebugRow: Equatable {
    /// A section divider, e.g. `── Locals ──` (dim, not selectable).
    case header(String)
    /// An informational / empty-state line, e.g. `(no locals)`,
    /// `(globals pending…)`, `(… N more globals)`, or a VM-running placeholder
    /// (dim, not selectable).
    case info(String)
    /// A variable / table-field row. Selectable only when `expandable`.
    case variable(DebugVariableRow)
    /// A call-stack frame row. Always selectable (`<Enter>` retargets the pane).
    case frame(DebugFrameRow)

    /// Whether the `j`/`k` cursor can land here and `<Enter>` can act on it.
    var isSelectable: Bool {
        switch self {
        case .variable(let v): return v.expandable
        case .frame: return true
        case .header, .info: return false
        }
    }
}

/// A Locals / Upvalues / Globals value row (or a nested table field).
struct DebugVariableRow: Equatable {
    /// Expansion key: section tag + name chain (`local:t/child`), so the same
    /// key under Locals vs Globals never collides in `debugExpandedPaths`.
    let path: String
    /// Indentation depth (0 = top of its section; children deeper).
    let depth: Int
    /// Section keyword for a top-level row (`local` / `upvalue` / `global`), or
    /// `nil` for a nested field (fields render `<name> = <value>` with no keyword).
    let keyword: String?
    let name: String
    let displayValue: String
    /// True when the value is an expandable table (`children != nil`).
    let expandable: Bool
    /// True when this row is currently expanded in `debugExpandedPaths`.
    let expanded: Bool
}

/// A call-stack frame row.
struct DebugFrameRow: Equatable {
    let level: Int
    /// Pre-rendered `#<level>  <source>:<line>  <name>`.
    let text: String
    /// True when this is the frame whose locals/upvalues are currently shown
    /// (`debugSelectedFrame`).
    let isViewed: Bool
}

// MARK: - Row builder

/// Build the full ordered Debug-tab row list for the current state.
///
/// Three modes (ux-spec §7.2, PRD §6.9):
///   - **Paused** (`currentDebugSnapshot != nil`): the live, interactive view —
///     the selected frame's locals/upvalues, the globals slice, and the call
///     stack. This is the only mode whose rows are selectable.
///   - **Case 2 — VM running after a pause** (`lastPauseSnapshot != nil`): the
///     retained last-pause data (the renderer dims it) under a
///     `VM running… (showing last pause)` header.
///   - **Case 1 — fresh open, never paused**: every section shows the
///     `(VM running — no snapshot yet)` placeholder under a `VM running…` header.
func buildDebugRows(_ state: AppState) -> [DebugRow] {
    if let snapshot = state.currentDebugSnapshot {
        return pausedRows(snapshot: snapshot, state: state)
    }
    if let last = state.lastPauseSnapshot {
        // Case 2: retained, dimmed by the renderer.
        var rows: [DebugRow] = [.info("VM running… (showing last pause)")]
        rows += pausedRows(snapshot: last, state: state, retained: true)
        return rows
    }
    // Case 1: fresh open, no snapshot yet.
    let placeholder = "(VM running — no snapshot yet)"
    return [
        .info("VM running…"),
        .header("── Locals ──"), .info(placeholder),
        .header("── Upvalues ──"), .info(placeholder),
        .header("── Globals ──"), .info(placeholder),
        .header("── Call Stack ──"), .info(placeholder),
    ]
}

/// Rows for a concrete snapshot (used for both the live paused view and the
/// retained Case-2 view). `retained` flips the Globals `nil` empty-state from
/// "header only" to the Case-1 placeholder (§6.9 globals interaction).
private func pausedRows(snapshot: DebugSnapshot, state: AppState, retained: Bool = false) -> [DebugRow] {
    var rows: [DebugRow] = []
    let frameVars = snapshot.frameVars[state.debugSelectedFrame] ?? ([], [])

    // ── Locals ──
    rows.append(.header("── Locals ──"))
    rows += variableRows(frameVars.0, section: "local", expanded: state.debugExpandedPaths)
    if frameVars.0.isEmpty { rows.append(.info("(no locals)")) }

    // ── Upvalues ──
    rows.append(.header("── Upvalues ──"))
    rows += variableRows(frameVars.1, section: "upvalue", expanded: state.debugExpandedPaths)
    if frameVars.1.isEmpty { rows.append(.info("(no upvalues)")) }

    // ── Globals ── (on demand; ux-spec §7.2 binding strings)
    rows.append(.header("── Globals ──"))
    rows += globalsRows(snapshot: snapshot, state: state, retained: retained)

    // ── Call Stack ──
    rows.append(.header("── Call Stack ──"))
    if snapshot.callStack.isEmpty {
        rows.append(.info("(no frames)"))
    } else {
        for frame in snapshot.callStack {
            rows.append(
                .frame(
                    DebugFrameRow(
                        level: frame.level,
                        text: frameText(frame),
                        isViewed: frame.level == state.debugSelectedFrame
                    )))
        }
    }
    return rows
}

/// The Globals section body per the ux-spec §7.2 state table.
private func globalsRows(snapshot: DebugSnapshot, state: AppState, retained: Bool) -> [DebugRow] {
    // Capture in flight: only meaningful in the live paused view (cleared on
    // resume, so never reached when `retained`).
    if !retained && state.debugGlobalsRequested && snapshot.globals == nil {
        return [.info("(globals pending…)")]
    }
    guard let globals = snapshot.globals else {
        // Not yet fetched: header only when live; Case-1 placeholder when retained.
        return retained ? [.info("(VM running — no snapshot yet)")] : []
    }
    if globals.isEmpty {
        return [.info("(no globals defined)")]
    }
    var rows = variableRows(globals, section: "global", expanded: state.debugExpandedPaths)
    if snapshot.globalsElided > 0 {
        rows.append(.info("(… \(snapshot.globalsElided) more globals)"))
    }
    return rows
}

/// Flatten a variable list into rows, recursing into expanded tables. `section`
/// is the top-level keyword and the path prefix.
private func variableRows(
    _ vars: [DebugVariable],
    section: String,
    expanded: Set<String>
) -> [DebugRow] {
    var rows: [DebugRow] = []
    for v in vars {
        appendVariable(v, keyword: section, parentPath: "\(section):", depth: 0, expanded: expanded, into: &rows)
    }
    return rows
}

/// Append one variable row (and, when expanded, its children) to `rows`.
private func appendVariable(
    _ v: DebugVariable,
    keyword: String?,
    parentPath: String,
    depth: Int,
    expanded: Set<String>,
    into rows: inout [DebugRow]
) {
    let path = depth == 0 ? "\(parentPath)\(v.name)" : "\(parentPath)/\(v.name)"
    let isExpandable = v.children != nil
    let isExpanded = isExpandable && expanded.contains(path)
    rows.append(
        .variable(
            DebugVariableRow(
                path: path,
                depth: depth,
                keyword: depth == 0 ? keyword : nil,
                name: v.name,
                displayValue: v.displayValue,
                expandable: isExpandable,
                expanded: isExpanded
            )))
    if isExpanded, let children = v.children {
        for child in children {
            appendVariable(child, keyword: nil, parentPath: path, depth: depth + 1, expanded: expanded, into: &rows)
        }
    }
}

/// `#<level>  <source>:<line>  <name>` — a single call-stack frame.
private func frameText(_ frame: DebugFrame) -> String {
    let src = frame.source ?? "<chunk>"
    let linePart = frame.line > 0 ? ":\(frame.line)" : ""
    let namePart = frame.name.map { "  \($0)" } ?? ""
    return "#\(frame.level)  \(src)\(linePart)\(namePart)"
}
