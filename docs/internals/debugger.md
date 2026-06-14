# MoonSwift Debugger Internals

This document covers the F6.0 debug-hook adapter: how the LuaSwift synchronous
handler is bridged into MoonSwift's pause/resume model, how snapshots are built,
how the globals path works, the threading contracts, and how stepping maps onto
LuaDebugCommand values.

Related files:
- `Sources/MoonSwiftCore/Debug/DebugHookAdapter.swift` — the adapter itself
- `Sources/MoonSwiftCore/Debug/DebugCommandMailbox.swift` — NSCondition-guarded park primitive
- `Sources/MoonSwiftCore/Debug/DebugSession.swift` — reference type owning the mailbox + breakpoints
- `Sources/MoonSwiftCore/Debug/DebugSnapshot.swift` — Sendable value models (DebugSnapshot, DebugFrame, DebugVariable)
- `Sources/MoonSwiftCore/Run/SessionEngine.swift` — installs the handler in `runForDebugOnQueue`

---

## Thread-class relationship

MoonSwift has four thread classes in a debug session (ARCHITECTURE §5.2 + F6.0):

| Class | Thread | Role |
|-------|--------|------|
| UI/render | main | Elm reducer, TUI rendering |
| EventPump | input pump | raw TTY event ingestion |
| AppDriver | async Swift concurrency | posts AppEvents, drives effects |
| VM / serial executor | GCD serial queue | runs LuaEngine; owns the debug hook |

The VM thread is a GCD serial queue (QoS `.userInteractive`), the same pattern as
`RunService` and `LintService`. All `LuaEngine` calls, including `runDebug`, run on
this queue. The debug handler is called synchronously on the VM thread; it may block
(park) there via `NSCondition.wait(until:)`. No other thread class blocks.

---

## Snapshot-publish-block-resume model

The adapter's per-pause loop runs entirely on the VM thread inside the synchronous
`LuaDebugHandler` closure:

```
handler fires (VM thread, synchronous)
    ├─ Step 1: classify event → DebugEventKind
    ├─ Step 2: eagerly snapshot call stack + all-frame locals/upvalues
    ├─ Step 3: publish DebugSnapshot via onPause; set RunState .paused
    └─ Step 4: park on mailbox.take()  ← VM thread blocks here
           ┌─ Wake from .serviceGlobals:
           │    capture globals in-place (inspector still valid)
           │    re-publish new DebugSnapshot (same fragmentLine)
           │    re-park  (loop, no VM advance)
           └─ Wake from .command(cmd):
                set RunState .running
                post debugResumed (for advancing commands only)
                return LuaDebugCommand to the VM
```

The handler never returns until a real `LuaDebugCommand` is ready. The VM thread
blocking in `mailbox.take()` is intentional and correct (synchronous closure; not
an `async` body). The UI thread and AppDriver never block.

---

## Eager snapshot: what is captured and when

The `LuaDebugInspector` is valid only for the duration of the handler call. Every
field the TUI may need is captured inside the handler before parking.

**At every pause (automatic):**
- `inspector.callStack` → `[DebugFrame]`, innermost first (level 0)
- For every frame index: `inspector.locals(frameLevel:)` + `inspector.upvalues(frameLevel:)` → stored in `DebugSnapshot.frameVars[level]`

This all-frame eager capture is what enables F6.3 call-stack frame navigation (user
selects a different frame in the TUI) as a pure view over already-held data, with no
re-entry into the engine.

**Not captured at pause time:**
- Globals — deferred to the explicit `g` key path (see below). Reason: `inspector.globals()` is unbounded by default in LuaSwift and can stall the VM thread for seconds on a large `_G`; additionally, `_G` in unrestricted mode may contain secrets (SEC-02). `DebugSnapshot.globals` is `nil` until the user explicitly requests it.

---

## DebugEventKind ↔ LuaDebugEvent mapping

| LuaDebugEvent | Condition | Action |
|---------------|-----------|--------|
| `.line(n)` | `n` ∈ breakpoint set OR `pauseRequested` consumed | pause as `.breakpoint` |
| `.line(n)` | `steppingMode == true` (last command was step variant) | pause as `.line` |
| `.line(n)` | `steppingMode == false` AND not a breakpoint | pass through (`.continueRun`) |
| `.call(frame)` | any mode | pass through, no pause |
| `.ret` | any mode | pass through, no pause |

### Breakpoint-mode vs stepping-mode disambiguation

`LuaDebugHandler` is called by the Lua debug hook on **every line** in breakpoint
mode (last command returned = `.continueRun`). In stepping mode (last command =
`.stepOver`/`.stepInto`/`.stepOut`), LuaSwift's `StepState` machine only calls the
user handler at the step-fire point. The adapter cannot tell these apart from the
event alone.

The adapter tracks `steppingMode: Bool` (a closure-local `var`, VM-thread-only)
which is set `true` when a step command is returned and `false` when `.continueRun`
or `.stop` is returned. This allows the adapter to:
- In breakpoint mode (`steppingMode == false`): pass through non-breakpoint lines
- In stepping mode (`steppingMode == true`): pause at every delivered `.line` (which,
  by LuaSwift contract, is only delivered at the actual step stop)

The `pauseRequested` latch (set via `SessionEngine.requestPause` → `DebugSession.requestPause`) fires as `.breakpoint` priority, checked first before the stepping/passthrough decision.

## DebugSnapshot.sessionID

Every `DebugSnapshot` carries the `DebugSessionID` of the session that produced it.
This allows the TUI reducer and tests to address `sendDebugCommand` / `requestGlobals`
calls via the snapshot alone, without storing a separate out-of-band reference.
The adapter captures `session.id` once at handler creation time and embeds it in
every snapshot it builds (initial pause + globals republish). The session ID is the
same for every snapshot within one run.

---

## Globals two-predicate wake (DOM-09 / ARCH-08)

When the user presses `g`, the AppDriver calls `SessionEngine.requestGlobals(id)`,
which calls `DebugSession.requestGlobals()`, which calls `mailbox.signalGlobals()`.
This sets the `globalsRequested` boolean inside the mailbox under the NSCondition's
lock and `signal()`s the condition — without enqueuing any `LuaDebugCommand`.

The parked `mailbox.take()` wakes and checks two predicates in order:
1. Is the command slot non-nil? → return `.command(cmd)` (command priority)
2. Is `globalsRequested` set? → clear it, return `.serviceGlobals`
3. Neither → re-wait (spurious wake or watchdog not yet elapsed)

On `.serviceGlobals`, the adapter — still inside the same synchronous handler call,
inspector still valid — calls `inspector.globals()` in-place. This is the only path
that reads globals; there is no post-callback globals fetch anywhere in the design.

After capturing, the adapter:
1. Filters the raw slice (see Security filter below)
2. Builds a new `DebugSnapshot` with `globals` populated and `fragmentLine` identical to the original pause snapshot
3. Calls `onPause(withGlobals)` to re-publish
4. Loops back to `mailbox.take()` — no `LuaDebugCommand` returned, VM does not advance

---

## Empty-globals policy (DOM-10 / UX-R3-02)

`DebugSnapshot.globals` has three states:

| Value | Meaning | TUI rendering |
|-------|---------|---------------|
| `nil` | Not yet fetched (before user pressed `g`) | Section header only |
| `[]` (empty non-nil) | Fetched; no user globals survive the filter | `(no globals defined)` in `dim` |
| non-empty array | User globals present | list of name = value |

The `(no globals defined)` string is the single binding empty-state for any pause at
any depth, including the last line of a fragment and early top-level pauses with no
user globals yet assigned. The retired `(globals unavailable at fragment end)` string
must never appear (DOM-10). `nil` and `[]` are distinct: `nil` = not fetched;
`[]` = fetched and empty.

The `(globals pending…)` string appears in the TUI between the `g` press and the
re-published snapshot (the wake-service cycle). The AppDriver drives this by setting
a pending flag in `AppState` when it handles `Effect.requestGlobals` and clearing it
when the next `AppEvent.debugPaused` arrives (F6.2 reducer wiring).

---

## Security filter (SEC-02 / PRD §5)

The globals slice passed to the TUI is filtered in this order:

1. **Subtract the baseline stdlib-name set** (`SessionEngine.baselineStdlibNames`, captured once at `startSession`). This set is the full stdlib present at engine init, including all standard library tables, `print`, and any mock-installed names. It is passed to the adapter as a `Set<String>` parameter so the adapter never calls `engine.globalNames` (which fast-fails while paused — IMPL-01).

2. **Apply the security blocklist**: `os`, `io`, `package`, `debug`, and any name with the `__moonswift_` prefix are dropped. This applies in both `.sandboxed` and `.unrestricted` modes.

3. **Breadth-cap at 256** (`DebugSnapshot.globalsBreadthCap`). The adapter iterates the filtered slice and stops after 256 entries. Excess entries are silently dropped (the TUI shows the `(… N more globals)` elision marker, which the renderer derives from the capped slice length vs. the known cap).

The filter is name-based. A value that aliases a stripped stdlib module (e.g.
`local my_os = os` then `my_os = my_os`) is a documented limitation: the user
global `my_os` is present but its value is `os`, which is a table reference with
no special filter on its contents.

---

## `nonisolated` command-delivery threading contract (PERF-11)

Three methods on `SessionEngine` deliver commands to the parked VM thread:

- `sendDebugCommand(_ id:, _ command:)` → calls `DebugSession.deliver(_:)` → `mailbox.put(_:)`
- `requestPause(_ id:)` → calls `DebugSession.requestPause()` → sets `pauseRequested` boolean
- `requestGlobals(_ id:)` → calls `DebugSession.requestGlobals()` → `mailbox.signalGlobals()`

All three are declared `nonisolated func` (not `async`). They MUST NOT be `async`
because the VM serial executor is occupied by the parked `runForDebug` block; an
executor-hopping `async` call would queue behind it and deadlock. They run on the
AppDriver's calling thread, resolve `id` under the `NSLock`-guarded session registry
(a thread-safe lookup), and call the live mailbox/atomics directly. A stale `id`
(session already torn down) resolves to `nil` and the call is a silent no-op (ARCH-06).

---

## `debugResumed` poster/reducer contract (ARCH-07)

`debugResumed` is the `AppEvent` that drives the "VM running between pauses" TUI
state (§6.9 Case 2). It is posted by the adapter (via the `onResumed` closure) on
the VM thread, immediately after `mailbox.take()` returns an advancing command
(`.stepOver`/`.stepInto`/`.stepOut`/`.continueRun`) and before the VM proceeds to
the next event.

It is NOT posted for:
- `.stop` — the session ends; `debugFinished` follows from the outer SessionEngine
- `.serviceGlobals` wakes — the VM does not advance; no "running" state should be entered

The `onResumed` closure is injected by the AppDriver at `runForDebug` call time
(F6.2 wiring). The F6.0 SessionEngine wiring installs an empty closure as a seam;
F6.2 replaces it with a real `EventChannel.post(.debugResumed)` call.

---

## Coroutine handling (DOM-03)

LuaSwift's coroutine-debug shim (`LuaEngine+CoroutineDebug.swift`) arms the debug
hook mask on newly created coroutine threads for the duration of a `runDebug` call.
When a user script creates and resumes a coroutine that hits a breakpoint, the debug
handler fires on the coroutine thread — which is still running on the same VM serial
executor (Lua coroutines are cooperative, single-threaded). The adapter treats
coroutine pauses identically to main-thread pauses: snapshot, publish, park.

Coroutine frames appear in `inspector.callStack` and are snapshotted into
`DebugSnapshot.callStack` / `frameVars` alongside main-chunk frames. The adapter
does not distinguish coroutine frames from regular frames; the TUI renders them the
same way.

---

## Watchdog timeout (SEC-01)

`mailbox.take()` uses `NSCondition.wait(until:)` with a hard ceiling of 5 minutes
(`DebugCommandMailbox.takeTimeout`). If no command and no globals request arrives
within that window, `take()` returns `.command(.stop)` as a fail-safe: the VM
unwinds via the cancellation path, the session ends cleanly, and the alternate screen
is restored. The adapter posts an internal diagnostic string
`Debug session timed out waiting for a command — session ended.` so the condition
is visible in the output rather than silent. This is a watchdog for an AppDriver bug
path, not a normal-operation limit.

## Structured errors & tracebacks (F6.4)

Runtime errors flow through the LuaSwift #19 structured surface
(`LuaError.runtimeFailure(LuaRuntimeFailure)`), which carries the stripped
`message`, the 1-based source `line`, and a full `traceback` (newest frame
first), all captured by the engine's error-message handler **while the failing
stack is still intact** — `lua_pcall` has already unwound by the time the Swift
`catch` runs, so there is nothing left to parse there.

`Diagnostic.from(luaError:provenance:)` consumes `failure.line`/`failure.message`
directly for runtime errors; `SessionEngine.outcome(for:)` carries
`failure.traceback` through to `CoreRunOutcome.error(_, traceback:)`, which the
TUI renders in the Output tab (`tracebackLines` splits it into one line per
frame). Both the plain run (`evaluate(_:chunkName:)`) and the debug run
(`runDebug(_:chunkName:)`) pass the fragment's `provenance.displayName` as the
#23 **chunkName**, so engine-reported frames carry faithful names
(`config.yaml:$.scripts.init`) rather than truncated source text.

The standalone `LuaErrorLineParser` regex seam was **deleted** in F6.4: runtime
errors no longer need string parsing. Only compile errors (`LuaError.syntaxError`)
and the rare legacy `.runtimeError` string still need a line number — a compact
bounded-anchor extractor (`compileErrorLineNumber`, private to
`LuaErrorDiagnostics`) handles those two cases.
