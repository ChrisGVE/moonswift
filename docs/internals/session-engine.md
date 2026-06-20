# Session engine (F5.0)

The **SessionEngine** is MoonSwift's long-lived Lua execution path. Unlike
`RunService` — which builds a fresh `LuaEngine` per run and discards it
(`Sources/MoonSwiftCore/Run/RunService.swift`) — the SessionEngine keeps ONE
engine alive across a run so the user can interact with its post-run state:
invoke Lua functions, inspect live globals, and (P3/F6) step the debugger.

It is the foundation for the F5 mocking features and the F6 debugger. This
document is the authoritative internal reference for its lifecycle, concurrency
model, and contracts.

## Relationship to RunService and LintService

| Service | Engine | Executor | Lifetime |
| ------- | ------ | -------- | -------- |
| `RunService` | fresh per run | `Task.detached` | discarded after each run |
| `LintService` | one luacheck engine | serial `DispatchQueue` | session-long |
| `SessionEngine` | one session engine | serial `DispatchQueue`, QoS `.userInteractive` (PERF-07) | per mock/debug session |

The SessionEngine is modeled directly on the `LintService` pattern: a
`final class` whose single `LuaEngine` is confined to a private serial queue,
with the engine field carrying the CR-014 isolation invariant (every read/write
of the engine happens on the queue; `nonisolated(unsafe)` is sound because the
queue — not the compiler — serialises access).

The plain `r` key continues to use `RunService` (run-and-discard) when there are
no mocks and no live-session need. A **mock-aware run** (mocks present, or
post-run invocation / live state desired) and a **debug run** use the
SessionEngine.

## Lifecycle

A session begins with `startSession(config:mocks:)`, which:

1. Creates the engine with the project's configured `RunConfigMode` — `.sandboxed`
   → `LuaEngineConfiguration.default`, `.unrestricted` → `.unrestricted`. **Never
   hardcoded** (§5); the mode is inherited from the `ProjectFile`.
2. Arms the instruction limit once (only when `> 0`).
3. Installs the hardened `print` capture (`__moonswift_sink` upvalue mechanism,
   identical to `RunService`) on the long-lived engine, so both `sessionRun` and
   `invokeLuaCall` route `print` to the injected `onOutput` callback.
4. Captures the **stdlib baseline** — the set of global names present after the
   engine and mocks are set up, before any user code runs (DATA-N04). `liveState`
   subtracts this baseline to isolate user-defined globals.

The session then serves runs and interactions until it ends. A session **ends**
on: explicit stop (a debug `x`, or a navigator end-session affordance), starting
a **new run**, or **reloading** the project (`<C-r>`). Ending discards the engine
and any live `DebugSession`.

> **Mock SERVER registration** (a `MockValueServer` per namespace; a synthesized
> callback per function) is the F5.1 / F5.2 increment to `startSession`, applied
> at the marked seam *before* the baseline capture. The F6.0 increment installs
> the debug **pause hook** into `runForDebug`. Both are clean extension points,
> not stubs — F5.0 establishes the lifecycle the increments hang off.

## Concurrency: serial-executor confinement

All engine work runs on the SessionEngine's private serial queue; the UI thread
never touches `LuaEngine`. Results flow back to the loop only via the
AppDriver-injected `onOutput` callback and the `async` returns (ARCHITECTURE
§5.1). Engine confinement is debug-asserted (`dispatchPrecondition(.onQueue)`)
in every engine-touching helper, mirroring RatatuiKit's thread-class asserts.

The one-shot request/response methods (`startSession`, `sessionRun`,
`invokeLuaCall`, `liveState`, `endSession`) are plain `async`: they dispatch
their body onto the serial queue via a checked continuation.

### Command delivery is `nonisolated` (PERF-11)

The three debug command-delivery methods — `sendDebugCommand`, `requestPause`,
`requestGlobals` — are `nonisolated`, NOT `async`. During a debug pause the
serial executor is **occupied** by the parked `runForDebug` block (blocked in
`DebugCommandMailbox.take()`). An executor-hopping `async` call would queue
behind that block and never run — a permanent deadlock. Instead these methods
run on the caller's thread, resolve the `DebugSessionID` under an NSLock-guarded
session registry, and call the live `DebugSession`'s mailbox / atomics directly.
The mailbox is `@unchecked Sendable` + `NSCondition`-guarded, so the cross-thread
direct call is safe.

A **stale `DebugSessionID`** (the session was already torn down — an
architecturally-guaranteed race, ARCH-06) resolves to a **silent no-op**: never
a trap, throw, or diagnostic.

## RunState gate (DOM-02 / PERF-02)

`globalNames` / `globalValue` are *between-runs only*: calling them while the VM
is executing is C-level undefined behaviour (`lua_next` on an executing
`lua_State` is non-reentrant). The SessionEngine owns an explicit

```
enum RunState { case idle, running, paused }
```

a lock-guarded atomic, written on the serial executor during each run
transition: `.running` for the body of any `sessionRun` / `runForDebug` /
`invokeLuaCall`, `.paused` while parked in the debug mailbox, `.idle` otherwise.

- `liveState()` returns `MockLiveState.empty` when RunState is not `.idle`,
  NEVER reaching `globalValue` / `globalNames` mid-run.
- `invokeLuaCall()` throws `SessionEngineError.enginePaused` when not `.idle`.

The atomic is read on the **fast path** — so the gate is observable without
dispatching onto a busy or parked executor — and re-checked inside the queue
block. All RunState writes happen on the serial executor, so transitions are
totally ordered: there is no window where a caller observes `.idle` and the
engine then re-enters `.running` before the guarded read. (This reconciles
ARCH-N04's "transitions ordered on the executor" with the gate's need to observe
a non-idle state without entering the executor.)

## liveState trigger + cache policy (PERF-02)

`liveState()` is an O(N) engine sweep (`globalNames` + per-name `globalValue`,
plus `registeredValueServerNames` / `registeredFunctionNames`). It is **never**
called per-keystroke. It is invoked at exactly two trigger points:

1. On a session-engine run completion — either `AppEvent.debugFinished` (debug
   run) or `AppEvent.sessionRunFinished` (plain mock-aware run, CONS-R4-01). In
   both the engine just went `.idle`; the reducer responds by emitting
   `Effect.queryLiveState`, producing one `MockLiveState` posted as
   `AppEvent.mockLiveStateReady`.
2. On an explicit navigator refresh (re-running the source implicitly refreshes).

The reducer **caches** the last `MockLiveState` in `AppState`; the navigator and
the F7a.1 live-mock completion layer read the cached snapshot, never calling the
engine directly. The cache is cleared **eagerly** (clear-on-run-start, and
reducer-time on a mock edit or end-session). During the no-cache window the
live-mock completion slice is `[]` and the navigator shows
`(run to populate live state)`.

> The reducer-side trigger and cache mechanics land with the reducer tasks; F5.0
> provides the engine-side `liveState()` that produces the snapshot under the
> gate.

## Mailbox + session ownership (IMPL-02 / ARCH-04)

The `DebugCommandMailbox` is a reference type whose lifetime spans `runForDebug`
(where the VM thread parks on it) and the subsequent step/continue/stop commands.
It **must not** be stored in `AppState` — `AppState` is a `Sendable` value type
and the Elm single-writer model forbids embedding a live mutable reference there.

- The SessionEngine owns a reference-typed `DebugSession` (created at debug-run
  start, torn down at stop/timeout/completion/new-run/reload). `DebugSession`
  holds the live `DebugCommandMailbox`, the breakpoint set, the
  `pauseRequested` / `globalsRequested` latches, and the current `DebugSnapshot`.
- `AppState` holds ONLY an opaque `DebugSessionID` and the latest published
  `DebugSnapshot` for rendering — never the mailbox or any reference.
- Command delivery is an EFFECT, not direct mutation: the reducer emits
  `Effect.debugCommand`, the AppDriver routes it to the live `DebugSession` by id,
  and the SessionEngine is the sole owner.

### DebugCommandMailbox two-predicate wake (ARCH-08 / DOM-09)

`take()` parks the VM thread on an `NSCondition`. On each wake it checks, in
order: (1) a filled command slot → `.command`; (2) a pending globals latch →
`.serviceGlobals` (consuming the latch); else it re-waits. The globals path
therefore wakes the parked VM **without** enqueuing a `LuaDebugCommand` (no
command means "capture globals, do not advance"); the VM services the globals in
place and re-parks without advancing the VM (DOM-08). A pause never resumed
within `takeTimeout` (300 s, SEC-01) auto-resolves to `.command(.stop)`.

## Implicit end-session (RQ3)

A non-debug mock session — kept alive after a plain mock-aware `sessionRun` for
invocation / live state — ends **implicitly** on a new run, a reload, or `<C-r>`.
There is **no** dedicated end-session key (`<C-x>` is NOT added). A subsequent
run discards the prior session engine. This is documented for users in
`docs/user/mocking.md` ("a mock session lasts until the next run or a reload;
there is no separate end-session key").

## Scope note (F5.0 vs dependants)

F5.0 creates the real, complete foundational types its protocol references —
because the dependent tasks are sequenced *after* it (F6.0 / #9 and F5.1 / #5
both depend on #1):

- `Run/SessionEngineProtocol.swift`, `Run/SessionEngine.swift`
- `Debug/DebugSnapshot.swift` (DebugSessionID, DebugEventKind, DebugFrame,
  DebugVariable, DebugSnapshot), `Debug/DebugCommandMailbox.swift`,
  `Debug/DebugSession.swift`
- `Mock/MockLiveState.swift`, `Mock/MockStore.swift`, `Mock/MockValue.swift`
  (MockValueDef), `Mock/MockFunction.swift` (MockFunctionDef)

The mock DTOs (`MockValueDef` / `MockFunctionDef`) migrated into F5.0 from the
F5.5 task because `startSession(config:mocks:)` depends on them; F5.5 retains the
codec + validation, and F5.1 / F5.2 add the `MockValueServer` / callback
synthesis and value materialization in the same files.
