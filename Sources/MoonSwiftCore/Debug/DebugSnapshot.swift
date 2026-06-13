// File: Sources/MoonSwiftCore/Debug/DebugSnapshot.swift
// Location: MoonSwiftCore/Debug/
// Role: The Sendable value models that cross the service→loop boundary for the
//       debugger: the opaque session handle, the UI-facing event kind, the frame
//       and variable models, and the immutable pause snapshot itself.
//
//       These are pure data models with no behaviour. F5.0 (the SessionEngine
//       foundation) defines them because `SessionEngineProtocol.runForDebug`
//       returns a `DebugSessionID` and publishes `DebugSnapshot`s, so the types
//       must exist before any dependant (F6.0 #9) can build the hook adapter that
//       PRODUCES them. F6.0 fills the snapshot via the debug hook; F6.3 enriches
//       the frame/variable detail. No producer logic lives here (PRD §4.3).
//
// Upstream: LuaSwift (LuaStackFrame / LuaInspectedValue are wrapped into these
//           Sendable models so the TUI never holds a LuaSwift inspector type —
//           boundary hygiene, mirrors the CoreRunOutcome↔RunOutcome split).
// Downstream: SessionEngineProtocol (return + callback payloads), DebugSession
//             (holds the current snapshot), F6.0 DebugHookAdapter (builds them).

import Foundation

// MARK: - DebugSessionID

/// Opaque handle for one live debug session.
///
/// Held by `AppState` (a `Sendable` value type) so the reducer can address
/// command-delivery effects at the live session WITHOUT embedding the
/// reference-typed `DebugSession` or its mailbox in state (IMPL-02 / ARCH-04).
/// The `SessionEngine` keeps the id→`DebugSession` mapping in its private
/// registry; a stale id (session already torn down) resolves to a silent no-op
/// (ARCH-06).
public struct DebugSessionID: Sendable, Hashable {
    /// Process-unique identity. `UUID` gives a collision-free handle without any
    /// shared counter that would need its own synchronisation.
    private let raw: UUID

    /// Creates a fresh, unique session id.
    public init() {
        raw = UUID()
    }
}

// MARK: - DebugEventKind

/// The UI-facing reduction of LuaSwift's richer `LuaDebugEvent` (CONS-07).
///
/// The F6.0 adapter maps a `.line(n)` whose fragment line is in the breakpoint
/// set to `.breakpoint`; any other stepping stop maps to `.line`. LuaSwift's
/// `.call` / `.ret` events are consumed by the adapter for stepping-depth
/// tracking and never surface as a published event kind (documented in
/// `docs/internals/debugger.md`).
public enum DebugEventKind: Sendable, Equatable {
    /// A stepping stop on a source line that is not a breakpoint.
    case line
    /// A pause on a line that is in the active breakpoint set.
    case breakpoint
}

// MARK: - DebugVariable

/// A single inspected Lua value rendered into a `Sendable` model.
///
/// Wraps LuaSwift's `LuaInspectedValue` so the TUI never holds an inspector
/// type. `displayValue` is the already-rendered display string (depth-capped:
/// a value past the depth cap renders as the `(…)` sentinel, never a truncated
/// or empty string — §6.5). `children` is non-`nil` only for expandable
/// (table) values; F6.3 populates the nested structure.
public struct DebugVariable: Sendable, Equatable {
    /// The variable / field name (local name, upvalue name, or table key).
    public let name: String
    /// The rendered current value; `(…)` when depth-capped.
    public let displayValue: String
    /// Nested children for an expandable value, or `nil` for a leaf.
    public let children: [DebugVariable]?

    public init(name: String, displayValue: String, children: [DebugVariable]? = nil) {
        self.name = name
        self.displayValue = displayValue
        self.children = children
    }
}

// MARK: - DebugFrame

/// One call-stack frame, rendered into a `Sendable` model.
///
/// Wraps LuaSwift's `LuaStackFrame`. Level 0 is the current executing frame
/// (matching `inspector.callStack[0]`); higher levels are progressively-older
/// caller frames (DATA-N01). The per-frame locals/upvalues live in
/// `DebugSnapshot.frameVars`, keyed by this `level`.
public struct DebugFrame: Sendable, Equatable {
    /// Stack level; 0 = current executing frame.
    public let level: Int
    /// Function name when known (Lua cannot always recover one), else `nil`.
    public let name: String?
    /// Source chunk identifier when known, else `nil`.
    public let source: String?
    /// Current line within `source` for this frame.
    public let line: Int

    public init(level: Int, name: String?, source: String?, line: Int) {
        self.level = level
        self.name = name
        self.source = source
        self.line = line
    }
}

// MARK: - DebugSnapshot

/// An immutable snapshot of the VM at a pause point.
///
/// Built eagerly by the F6.0 hook adapter while the inspector is valid, then
/// posted to the loop as `AppEvent.debugPaused`. Immutability is binding
/// (DATA-08): every field is `let`. The `g` (globals) path PUBLISHES A NEW
/// snapshot with `globals` populated rather than mutating a shared value — a
/// `var` would invite a Swift 6 data race on a `Sendable` value shared across
/// threads.
///
/// `sessionID` carries the opaque handle for the session that produced this
/// snapshot. The TUI (and tests) use it to address `sendDebugCommand` /
/// `requestGlobals` without holding a separate reference to the session registry.
/// It is always the same value for every snapshot emitted within one run.
public struct DebugSnapshot: Sendable {
    /// Hard cap on the breadth of the user-globals slice (F6.0 §2).
    public static let globalsBreadthCap = 256

    /// Opaque handle for the live session that produced this snapshot.
    ///
    /// Used by the TUI reducer and tests to address `sendDebugCommand` /
    /// `requestGlobals` calls without storing a separate out-of-band reference.
    /// A stale id (session already ended) is a silent no-op (ARCH-06).
    public let sessionID: DebugSessionID
    /// Whether this pause landed on a stepping line or a breakpoint.
    public let event: DebugEventKind
    /// The fragment-relative line of the pause (`lineOffset` already applied).
    public let fragmentLine: Int
    /// The full call stack, level 0 first. All frames are eagerly captured.
    public let callStack: [DebugFrame]
    /// Per-frame `(locals, upvalues)`, keyed by frame level (0 = current).
    public let frameVars: [Int: ([DebugVariable], [DebugVariable])]
    /// User-defined globals — `nil` until the user presses `g`. Populated
    /// (bounded + filtered) on the globals path, which republishes a new
    /// snapshot rather than mutating this one.
    public let globals: [DebugVariable]?
    /// How many user-globals were dropped by the breadth cap (F6.0 §2). `0`
    /// when `globals` is `nil` (not yet fetched) or when the filtered slice fit
    /// within `globalsBreadthCap`. When positive, the Debug tab renders the
    /// `(… N more globals)` elision marker (ux-spec §6.5) after the slice.
    ///
    /// This is the encoding chosen for the breadth-cap marker (D2): an explicit
    /// count on the snapshot, rather than a synthetic sentinel `DebugVariable`,
    /// keeps the `globals` array a clean list of real globals and lets the view
    /// render the marker without parsing names. `0` is the safe default so every
    /// pre-existing construction site (and the no-globals path) compiles and
    /// behaves unchanged.
    public let globalsElided: Int

    public init(
        sessionID: DebugSessionID,
        event: DebugEventKind,
        fragmentLine: Int,
        callStack: [DebugFrame],
        frameVars: [Int: ([DebugVariable], [DebugVariable])],
        globals: [DebugVariable]?,
        globalsElided: Int = 0
    ) {
        self.sessionID = sessionID
        self.event = event
        self.fragmentLine = fragmentLine
        self.callStack = callStack
        self.frameVars = frameVars
        self.globals = globals
        self.globalsElided = globalsElided
    }
}
