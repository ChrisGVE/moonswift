// File: Sources/MoonSwiftCore/Run/RunConfig.swift
// Location: MoonSwiftCore/Run/
// Role: Core-side run configuration and outcome types for RunService. Defines
//       the LimitKind enum, the RunOutcome result enum, and the RunConfig value
//       (re-exported from ProjectFile.RunConfig for RunService callers). These
//       types are MoonSwiftCore-side; an identical RunOutcome/LimitKind exists
//       in MoonSwiftTUI/App/AppEvent.swift (added before core types were
//       defined) — deduplication is a follow-up task once the TUI imports core
//       types for this. No MoonSwiftTUI dependency is introduced here.
// Upstream: (none — foundational run types)
// Downstream: RunService (produces RunOutcome), AppDriver (consumes via callback)

import Foundation

// MARK: - LimitKind

/// The resource limit that ended a run early.
///
/// Produced in `RunOutcome.limitExceeded` when either the instruction count
/// or wall-clock timer fires before the script completes naturally. Each case
/// carries the **configured limit** (not the actual count executed) so the
/// renderer can emit the exact ux-spec §6.3 footer strings.
///
/// - Note: `wallClock` requires LuaSwift#22 cooperative cancellation. In
///   binaries compiled without that flag the `wallClockLimitMs` setting is
///   inert (a `ProjectValidation` warning documents this at load time).
public enum CoreLimitKind: Sendable, Equatable {
    /// The Lua instruction-count hook fired. `count` is the configured limit
    /// (from `RunConfig.instructionLimit`) — i.e. the threshold that was exceeded.
    case instructions(count: Int)
    /// The runner-side wall-clock timer expired and cancellation was signalled.
    /// `durationMs` is the configured timeout (from `RunConfig.wallClockLimitMs`).
    case wallClock(durationMs: Int)
}

// MARK: - RunOutcome

/// The result of a single script run, returned by `RunServiceProtocol.run`.
///
/// The AppDriver wraps this in an `AppEvent.runFinished` before posting to the
/// event channel; `RunService` itself never sees TUI types (ARCHITECTURE §5.1).
///
/// Cases align with the four terminal states documented in ARCHITECTURE §3c:
/// - `.done` — natural completion, optional return value, wall-clock duration
/// - `.error` — Lua syntax or runtime error, fragment-relative `Diagnostic`
/// - `.cancelled` — cooperative cancellation via LuaSwift#22 (not yet active
///   at the pinned revision — see `RunService` header)
/// - `.limitExceeded` — instruction or wall-clock limit tripped
public enum CoreRunOutcome: Sendable {
    /// The script ran to completion.
    ///
    /// `value` is `nil` when `evaluate` returned `.nil` or when the script
    /// explicitly returned nothing. `duration` is the wall-clock elapsed time
    /// from engine `evaluate` entry to return.
    case done(value: String?, duration: Duration)

    /// A Lua syntax or runtime error stopped the run.
    ///
    /// `diagnostic` is fragment-relative (line numbers relative to the fragment's
    /// first line, with `lineOffset` applied for structured-file fields). `traceback`
    /// holds any raw traceback lines extracted from the error string, or `nil` when
    /// none are available at this LuaSwift revision.
    case error(Diagnostic, traceback: String?)

    /// The run was cancelled by the user via the #22 cooperative cancellation API.
    ///
    /// Not reachable in binaries compiled without the `MOONSWIFT_LUASWIFT_22`
    /// compiler flag — that build's cancel path posts a transient instead and
    /// lets the run continue (ARCHITECTURE §3c honest degradation).
    case cancelled

    /// An instruction or wall-clock limit fired before the script finished.
    case limitExceeded(kind: CoreLimitKind)
}
