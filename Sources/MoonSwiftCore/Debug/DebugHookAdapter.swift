// File: Sources/MoonSwiftCore/Debug/DebugHookAdapter.swift
// Location: MoonSwiftCore/Debug/
// Role: The debug-hook adapter that bridges the LuaSwift synchronous handler
//       into MoonSwift's pause/resume model (PRD §F6.0). Runs entirely on the
//       session engine's serial executor (the "VM thread"); never touches the
//       TUI thread.
//
//       Lifecycle per pause (the core loop in `handler`):
//         1. Event arrives → map to DebugEventKind; check pauseRequested latch.
//         2. Snapshot: eagerly capture call stack + all-frame locals/upvalues.
//         3. Publish DebugSnapshot via onPause callback; set RunState to .paused.
//         4. Park: call mailbox.take() — the synchronous handler blocks here.
//         5a. Wake from serviceGlobals → capture globals in-place (inspector still
//             valid), republish a new snapshot, re-park (no VM advance).
//         5b. Wake from command → set RunState to .running, post debugResumed,
//             return LuaDebugCommand to the VM.
//
//       Globals capture (DOM-08 / DOM-09 / IMPL-01):
//         The adapter is still inside the SAME synchronous handler while parked
//         in mailbox.take(), so `inspector` is still valid. When the two-predicate
//         wake returns .serviceGlobals, inspector.globals() is called in-place —
//         no VM advance, no re-pause — and a new DebugSnapshot with globals
//         populated is published. The VM remains parked.
//
//       Security filter (SEC-02 / PRD §5 / §F6.0 §2):
//         Globals are filtered by subtracting the precomputed baseline stdlib-name
//         set (passed in at creation from SessionEngine.baselineStdlibNames) and
//         by applying the explicit blocklist (os/io/package/debug + __moonswift_).
//         The slice is breadth-capped at DebugSnapshot.globalsBreadthCap (256).
//
//       Thread-class note (ARCHITECTURE §5.2):
//         The LuaDebugHandler typealias is a synchronous closure on the VM thread.
//         NSCondition.wait(until:) inside mailbox.take() is a synchronous OS-thread
//         park — valid in a synchronous closure. Never call from an async context.
//
// Upstream: LuaSwift (LuaDebugHandler, LuaDebugEvent, LuaDebugCommand,
//           LuaDebugInspector, LuaStackFrame, LuaInspectedValue, LuaValue),
//           DebugSession, DebugCommandMailbox, DebugSnapshot, DebugFrame,
//           DebugVariable, LuaSourceFragment (for lineOffset)
// Downstream: SessionEngine.runForDebug (installs the handler via
//             engine.setDebugHandler(_:) and engine.runDebug(_:)), onPause
//             callback (AppDriver-injected, posts AppEvent.debugPaused),
//             onResumed callback (AppDriver-injected, posts AppEvent.debugResumed)

import Foundation
import LuaSwift

// MARK: - DebugHookRunState

/// Mirrors the two RunState transitions the adapter needs to signal back to the
/// SessionEngine. Declared `public` so the SessionEngine can use it in the
/// setRunState closure without introducing an import cycle.
public enum DebugHookRunState: Sendable {
    /// The VM is paused — the adapter is parked in mailbox.take().
    case paused
    /// The VM is resuming — the adapter returned a command to the VM.
    case running
}

// MARK: - makeDebugHookHandler

/// Build and return the `LuaDebugHandler` closure for one debug run.
///
/// The returned closure captures only `@Sendable` values and is itself
/// `@Sendable`, satisfying Swift 6 strict concurrency. All mutable state
/// touched inside the closure lives on the VM thread (the serial executor that
/// runs `engine.runDebug` synchronously); no cross-thread mutation occurs.
///
/// The `onPause` and `onResumed` closures are AppDriver-injected and must be
/// `@Sendable`; they post `AppEvent` values via `EventChannel` (callable from
/// any thread per `EventChannel.swift:45`).
///
/// - Parameters:
///   - session: The live `DebugSession` for this run (owns the mailbox).
///   - fragment: The fragment being debugged (provides `lineOffset` for
///     fragment-relative line mapping).
///   - baselineStdlibNames: The precomputed stdlib-name set from
///     `SessionEngine.baselineStdlibNames` (DATA-N04), used to filter user
///     globals.
///   - setRunState: Called `.paused` before parking and `.running` after a
///     resume command; runs on the VM thread, synchronous.
///   - onPause: The AppDriver snapshot publisher. Called each time the VM
///     pauses (and again when globals are captured in-place).
///   - onResumed: The AppDriver resume poster. Called once per advancing
///     command (`.stepOver`/`.stepInto`/`.stepOut`/`.continueRun`), never for
///     `.stop` or for globals-only wakes.
/// - Returns: A `LuaDebugHandler` ready for `engine.setDebugHandler(_:)`.
public func makeDebugHookHandler(
    session: DebugSession,
    fragment: LuaSourceFragment,
    baselineStdlibNames: Set<String>,
    setRunState: @escaping @Sendable (DebugHookRunState) -> Void,
    onPause: @escaping @Sendable (DebugSnapshot) -> Void,
    onResumed: @escaping @Sendable () -> Void
) -> LuaDebugHandler {
    let lineOffset = fragment.provenance.lineOffset
    // `breakpoints` is `Set<Int>`, value type, Sendable.
    let breakpoints = session.breakpoints
    // Capture the session id as a value so each snapshot carries it.
    let sessionID = session.id
    // Tracks whether the adapter is currently in stepping mode (last command was
    // a step variant). In stepping mode, LuaSwift only calls the handler at the
    // step-fire point — every delivered .line IS a stop. In breakpoint mode
    // (last command was .continueRun), the handler fires for every line and the
    // adapter must skip non-breakpoint lines explicitly.
    // `nonisolated(unsafe)`: accessed only from the VM thread (the serial executor
    // on which `engine.runDebug` runs synchronously). No concurrent access.
    nonisolated(unsafe) var steppingMode = false

    return { (event: LuaDebugEvent, inspector: LuaDebugInspector) -> LuaDebugCommand in

        // ── Step 1: classify the event ──────────────────────────────────────
        //
        // In BREAKPOINT mode (stepState == nil in LuaSwift, last cmd = .continueRun)
        // all three event kinds are delivered for every line. In STEPPING mode
        // (last cmd = .stepOver/.stepInto/.stepOut), LuaSwift only calls the
        // handler at the step-fire point. CONS-07: .call and .ret pass through.
        let pauseLine: Int
        let eventKind: DebugEventKind

        switch event {
        case .line(let engineLine):
            pauseLine = engineLine - lineOffset
            // The pauseRequested latch fires as a breakpoint-priority pause.
            let forcedPause = session.consumePauseRequested()
            if forcedPause || breakpoints.contains(pauseLine) {
                // Breakpoint hit or forced pause — always pause.
                eventKind = .breakpoint
            } else if steppingMode {
                // In stepping mode LuaSwift only delivers the handler at the step
                // stop — this event IS the step stop, so pause as a step line.
                eventKind = .line
            } else {
                // In breakpoint mode (continueRun active) and not a breakpoint:
                // pass through without pausing the VM.
                return .continueRun
            }

        case .call, .ret:
            // Breakpoint mode only; pass through without pausing.
            return .continueRun
        }

        // ── Step 2: eager snapshot ───────────────────────────────────────────
        //
        // The inspector is valid ONLY during this handler call. Capture all
        // frames' locals and upvalues now so the TUI can navigate the call
        // stack (F6.3) without any re-entry into the engine.
        let snapshot = buildPauseSnapshot(
            sessionID: sessionID,
            event: eventKind,
            pauseLine: pauseLine,
            inspector: inspector
        )

        // ── Step 3: publish + set paused state ──────────────────────────────
        session.setSnapshot(snapshot)
        setRunState(.paused)
        onPause(snapshot)

        // ── Step 4 / 5: park + service globals wakes, exit on command ───────
        //
        // The outer loop re-parks after each .serviceGlobals wake (globals
        // captured in-place, no VM advance). The loop exits only on a real
        // LuaDebugCommand wake.
        while true {
            let wake = session.mailbox.take()
            switch wake {

            case .serviceGlobals:
                // ── Step 5a: globals in-place capture (DOM-08) ───────────────
                //
                // `inspector` is still valid: the synchronous handler has not
                // returned. Call inspector.globals() right here, at the current
                // pause line. The VM does NOT advance.
                let globalsSlice = captureFilteredGlobals(
                    inspector: inspector,
                    baselineStdlibNames: baselineStdlibNames
                )
                let withGlobals = DebugSnapshot(
                    sessionID: sessionID,
                    event: snapshot.event,
                    fragmentLine: snapshot.fragmentLine,
                    callStack: snapshot.callStack,
                    frameVars: snapshot.frameVars,
                    globals: globalsSlice
                )
                session.setSnapshot(withGlobals)
                onPause(withGlobals)
                // Re-park without returning a command (no VM advance).
                continue

            case .command(let cmd):
                // ── Step 5b: command → resume ────────────────────────────────
                // Track stepping mode so the next .line event is correctly
                // classified (CONS-07, stepping vs breakpoint mode distinction).
                switch cmd {
                case .stepOver, .stepInto, .stepOut:
                    steppingMode = true
                case .continueRun, .stop:
                    steppingMode = false
                }
                setRunState(.running)
                // Post debugResumed for advancing commands only (ARCH-07).
                // .stop ends the session — debugFinished follows from the outer
                // SessionEngine; we must NOT post debugResumed for it.
                if cmd != .stop {
                    onResumed()
                }
                return cmd
            }
        }
    }
}

// MARK: - Snapshot builder

/// Build an eager `DebugSnapshot` capturing call stack and all-frame variables.
///
/// Globals are left `nil` — they are captured lazily via the `g` key path
/// (PRD §F6.0 §2, DOM-05 / PERF-01 / SEC-02).
private func buildPauseSnapshot(
    sessionID: DebugSessionID,
    event: DebugEventKind,
    pauseLine: Int,
    inspector: LuaDebugInspector
) -> DebugSnapshot {
    let rawStack = inspector.callStack

    // Map LuaStackFrame → DebugFrame. Level index = position in the array
    // (0 = innermost, matches LuaSwift documentation).
    let callStack = rawStack.enumerated().map { idx, frame in
        DebugFrame(
            level: idx,
            name: frame.name,
            source: frame.source,
            line: frame.currentLine ?? 0
        )
    }

    // Per-frame locals and upvalues — all frames, captured eagerly.
    var frameVars: [Int: ([DebugVariable], [DebugVariable])] = [:]
    for (idx, _) in rawStack.enumerated() {
        let locals = inspector.locals(frameLevel: idx).map { pair in
            inspectedValueToDebugVariable(name: pair.name, value: pair.value)
        }
        let upvalues = inspector.upvalues(frameLevel: idx).map { pair in
            inspectedValueToDebugVariable(name: pair.name, value: pair.value)
        }
        frameVars[idx] = (locals, upvalues)
    }

    return DebugSnapshot(
        sessionID: sessionID,
        event: event,
        fragmentLine: pauseLine,
        callStack: callStack,
        frameVars: frameVars,
        globals: nil
    )
}

// MARK: - Globals capture

/// Capture the user-globals slice in-place while the inspector is still valid.
///
/// Filter order (PRD §F6.0 §2, SEC-02):
///   1. Subtract the precomputed baseline stdlib-name set (DATA-N04).
///   2. Apply the security blocklist: os / io / package / debug + __moonswift_.
///   3. Breadth-cap at `DebugSnapshot.globalsBreadthCap` (256).
///
/// Returns an empty array `[]` (not `nil`) when no user globals survive
/// filtering. The empty non-nil slice renders as `(no globals defined)` in the
/// Debug tab (DOM-10 / UX-R3-02); `nil` means "not yet fetched".
private func captureFilteredGlobals(
    inspector: LuaDebugInspector,
    baselineStdlibNames: Set<String>
) -> [DebugVariable] {
    let allGlobals = inspector.globals()
    var result: [DebugVariable] = []
    result.reserveCapacity(min(allGlobals.count, DebugSnapshot.globalsBreadthCap))

    for pair in allGlobals {
        guard result.count < DebugSnapshot.globalsBreadthCap else { break }
        let name = pair.name
        guard !baselineStdlibNames.contains(name) else { continue }
        guard !isSecurityBlocklisted(name) else { continue }
        result.append(inspectedValueToDebugVariable(name: name, value: pair.value))
    }
    return result
}

/// Returns `true` for names the security blocklist excludes from the globals
/// slice (PRD §5: os / io / package / debug + __moonswift_ reserved prefix).
private func isSecurityBlocklisted(_ name: String) -> Bool {
    switch name {
    case "os", "io", "package", "debug": return true
    default: return name.hasPrefix("__moonswift_")
    }
}

// MARK: - LuaInspectedValue → DebugVariable

/// Convert a `LuaInspectedValue` snapshot to a `DebugVariable` model.
///
/// The mapping preserves the depth-cap and cycle sentinels from LuaSwift:
///   - Depth-capped table → `displayValue: "(…)"` (§6.5 contract).
///   - Cycle → `displayValue: "<cycle>"`.
///   - Table with children → recursively mapped; breadth-limit sentinels are
///     filtered out of the children list (they are LuaSwift internals, not
///     user-visible keys).
///   - Scalars → rendered to display string.
private func inspectedValueToDebugVariable(
    name: String,
    value: LuaInspectedValue
) -> DebugVariable {
    switch value {
    case .scalar(let luaVal):
        return DebugVariable(
            name: name,
            displayValue: luaValueDisplayString(luaVal),
            children: nil
        )
    case .reference(_, let preview, let rawChildren):
        if value.isDepthLimited {
            return DebugVariable(name: name, displayValue: "(…)", children: nil)
        }
        if value.isCycle {
            return DebugVariable(name: name, displayValue: "<cycle>", children: nil)
        }
        // Map table children recursively, dropping breadth-limit sentinels.
        let children: [DebugVariable]? = rawChildren.map { childList in
            childList
                .filter { !$0.value.isBreadthLimited }
                .map { child in
                    inspectedValueToDebugVariable(name: child.key, value: child.value)
                }
        }
        return DebugVariable(name: name, displayValue: preview, children: children)
    }
}

/// Render a `LuaValue` scalar to a Lua-compatible display string.
///
/// Matches the `luaValueToString` logic in `SessionEngine` (private there;
/// replicated here to avoid widening that file's API surface).
private func luaValueDisplayString(_ value: LuaValue) -> String {
    switch value {
    case .nil: return "nil"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        if n == n.rounded() && !n.isInfinite && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    case .string(let s): return s
    case .table, .array: return "table"
    case .complex(let re, let im): return "\(re)+\(im)i"
    case .luaFunction: return "function"
    case .opaqueReference(let kind):
        switch kind {
        case .function: return "function"
        case .table: return "table"
        case .userdata: return "userdata"
        case .thread: return "thread"
        }
    }
}
