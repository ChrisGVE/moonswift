# LuaSwift — MoonSwift Phase-2 API Requirements PRD v4 (CONVERGED)

> **Status:** v4 — CONVERGED. Four rounds of adversarial audit across 5 disciplines
> (architecture, implementation/buildability, Lua-VM domain semantics, security,
> consolidation); Round 4 returned zero substantive must-fix (final round fixed two
> leftover text remnants only). All existing-state claims verified against the
> LuaSwift v1.10.1 source tree.
> **Origin:** Authored in the MoonSwift repo as a dependency-requirement spec.
> **Handoff:** Chris takes this to a separate `ChrisGVE/LuaSwift` session for
> implementation. MoonSwift does not modify LuaSwift; this document only states
> what MoonSwift consumes and the contracts it depends on.
> **Target library:** `ChrisGVE/LuaSwift` (Swift 6, Lua 5.1–5.5 via
> `CLua`/`CLua51`/`CLua52`/`CLua53`/`CLua55`). Current release **v1.10.1**.
> **Pin baseline note:** MoonSwift currently pins **v1.9.1** (`2fd31bcd`); all
> existing-state claims below are verified against **v1.10.1 source** (which adds
> `precompile`/`CompiledChunk`, the VM memory limit, and throwing module install).
> The implementing session should branch from v1.10.1 or later, not the pin.

---

## 1. Overview & Problem Statement

MoonSwift is a TUI editor/runner for Lua fragments. Its Phase-1 (P1, shipped as
`moonswift 0.1.0`) runs and lints fragments through LuaSwift. Phase-2 (P2 —
sharing-area mocking + interactive debugger) and one deferred P1 capability
(true cooperative cancellation) are **blocked on five LuaSwift API additions**,
tracked as LuaSwift issues **#19, #20, #21, #22, #23** (all OPEN as of v1.10.1).

This PRD specifies those five APIs from the consumer's side. It is deliberately
scoped to MoonSwift's needs — not a complete LuaSwift roadmap. Where the LuaSwift
maintainer has implementation latitude, this PRD states the **observable
contract** MoonSwift depends on and marks the rest as the maintainer's call.

**Problem:** Without these APIs MoonSwift cannot (a) cancel a runaway script
(#22), (b) show faithful error locations and tracebacks (#19, #23), (c) offer an
interactive debugger (#20), or (d) display live engine state in its mock
navigator without error-prone parallel bookkeeping (#21).

**Non-goals:** No changes to LuaSwift's module system, bytecode format, sandbox,
or value-bridging beyond the five APIs. No prescription of LuaSwift's internal
data structures except where they surface in the public contract.

### 1.1 Current LuaSwift state (verified against v1.10.1 source)

- `LuaError` is an `enum` of flat-`String`-payload cases (`syntaxError(String)`,
  `runtimeError(String)`, …, `instructionLimitExceeded`). No structured
  line/source/traceback. (`Sources/LuaSwift/LuaError.swift`.)
- **The instruction hook fires ONCE, not periodically.** `armInstructionHook`
  (`LuaEngine+Execution.swift:73–78`) installs `lua_sethook` with
  `count == instructionLimit` (so it fires a single time at the limit) and
  **disarms entirely when `instructionLimit == 0`** — non-limited runs currently
  pay zero hook overhead. The abort is `lua_error` raised from the count hook
  (version-proven). This shape must change for #22 (see F1).
- `lua_pcall` is currently called with **`errfunc = 0`** (no message handler),
  `LuaEngine+Execution.swift:113`/`:156`. Structured errors (#19) require a
  handler installed *before* the call (see F2).
- The engine holds an `NSRecursiveLock` (`lock`) across the whole run
  (`LuaEngine+Execution.swift`); `requestCancellation()` must **not** take it.
- Value-server / callback plumbing for mocking **already exists**:
  `register(server:)`, `registerFunction(name:callback:)`/`unregisterFunction`,
  `callAndReleaseLuaFunction(_:args:)`, and the `LuaValueServer` protocol
  (`namespace`/`resolve`/`canWrite`/`write`). The engine keeps `servers` and
  `callbacks` dictionaries for these. **It does NOT track installed modules**
  (`ModuleRegistry` is a static-method `struct`) — #21's module enumeration
  needs new bookkeeping.
- `precompile(_:)` → `CompiledChunk` (`Codable`, `formatVersion`, decode
  tolerance) and the `run`/`evaluate` `CompiledChunk` overloads shipped v1.10.0.
  No `chunkName` parameter anywhere. The `CompiledChunk` path compiles via
  `luaL_loadstring(code)` so the **embedded source name is `[string "<code>"]`**;
  the `"=bytecode"` literal is only the *load-time* name passed at undump, which
  Lua **ignores for binary chunks** (`lundump.c`). This is why #23 must embed the
  name at precompile time (F3).
- All run entry points unwind through `lua_pcall` with **`errfunc = 0`** today:
  `run`/`evaluate` (`Execution.swift:113`/`:156`), the `CompiledChunk` run
  (`Bytecode.swift`), and `callLuaFunction` (`FunctionCalls.swift`). #19's handler
  and #22's hook must be installed on **all** of them (see §4).
- The current instruction-limit/cancel detection is **string-sentinel based**
  (`message.contains(…)`, `Execution.swift:191–194`) — fragile once a #19 handler
  reshapes the error; #22/limit must move to out-of-band flags (F1/F2).
- No public debug-hook API; `lua_sethook` exists only in vendored C, takes no
  user-data, and `lua_getextraspace` is absent on 5.1/5.2 (engine recovery must
  use LuaSwift's existing `setAsCurrentEngine()` TLS — see §4).
- `LUA_IDSIZE == 60` on all versions; `luaL_traceback` exists 5.2+ but **not 5.1**.

---

## 2. Personas & Stories

- **P-A — LuaSwift maintainer (Chris).** Implements these APIs in a focused
  session; needs each requirement buildable in isolation, version-aware, and
  testable without MoonSwift present.
- **P-B — MoonSwift engine (`MoonSwiftCore`).** Consumes via `RunService`,
  `LintService`, the future `DebugSession`, and the mock store.

Stories:

- **S1 (#22):** As `RunService`, pressing `x` calls `requestCancellation()` and
  the in-flight run aborts within 200 ms with `LuaError.cancelled`.
- **S2 (#22):** As `RunService`, I enforce `run.wall_clock_limit_ms` from a timer
  via `requestCancellation()` **with NO instruction limit configured** (MoonSwift's
  default path — `run.instruction_limit` defaults to 0).
- **S3 (#19):** As `RunService`/`LintService`, I read a runtime error's source
  line and full traceback as structured data, map onto fragment provenance, and
  delete `LuaErrorLineParser`.
- **S4 (#20):** As `DebugSession`, I install a debug controller, receive
  line/call/return events, pause the VM, inspect locals/upvalues/globals + the
  call stack, then step or continue.
- **S5 (#21):** As the mock navigator, I enumerate registered value servers,
  functions, installed modules, and live globals from real engine state.
- **S6 (#23):** As `RunService`, I pass each fragment's display name as the chunk
  name so tracebacks show it instead of truncated source.

---

## 3. Core Features

One feature per issue. Implementation order (see §7/§8) is **#22 → #23 → #19 →
#21 → #20** (#23 precedes #19 because faithful frame names depend on it).

### F1 — Cooperative cancellation (#22)  *(also unblocks MoonSwift P1)*

**MoonSwift consumer:** `RunService.cancel()` and `run.wall_clock_limit_ms`
(`MoonSwiftCore/Run/RunService.swift`), today gated behind compile flag
`MOONSWIFT_LUASWIFT_22` with an honest no-cancel fallback.

**Proposed Swift surface (on `LuaEngine`):**
```swift
/// Request cooperative cancellation of the in-flight execution. Thread-safe and
/// LOCK-FREE: sets an atomic flag; callable from a different thread/queue than
/// the running VM and MUST NOT acquire the engine's run lock (which is held for
/// the entire run). No effect if no run is active.
func requestCancellation()

/// Clear a prior cancellation request so a retained engine can run again.
/// Called by the owner before the next run. No effect mid-run.
func resetCancellation()
```
```swift
enum LuaError: Error {
    // … existing cases unchanged …
    case cancelled   // execution aborted by requestCancellation()
}
```

**Hook mechanism (this is the crux — replaces the once-fire hook):**
- LuaSwift installs a **single, periodic count hook** (`lua_sethook` with
  `LUA_MASKCOUNT`, `count = K`) that **re-fires every K instructions**, replacing
  the current fire-once-at-limit design. The hook is a **compositor callback**
  that, on each fire, in order: (1) checks the **atomic cancellation flag** →
  raises `lua_error` (→ `LuaError.cancelled`) if set; (2) accumulates instruction
  count and enforces `instructionLimit` if non-zero (→ `instructionLimitExceeded`);
  (3) dispatches debug events when debugging (F5). **One `lua_sethook` slot,
  multiplexed** — see §4. This resolves the slot conflict between #22, the
  instruction limit, and #20.
- **Engine recovery in the C hook:** `lua_sethook` carries no user-data and
  `lua_getextraspace` is absent on 5.1/5.2, so the compositor callback recovers
  the owning `LuaEngine` via LuaSwift's **existing `setAsCurrentEngine()` TLS
  pattern** (already used by the callback trampolines) — never a process-global
  `L`→engine map (which would break concurrent engines).
- **Per-run counter reset:** the accumulated-instruction counter is zeroed each
  time the hook is armed. Without this, a retained engine (P2 session-engine mode)
  accumulates counts across runs and trips a spurious `instructionLimitExceeded`.
- **Applies to ALL run entry points:** a shared internal helper installs the
  compositor hook for `run`/`evaluate`, the `CompiledChunk` run path,
  `callLuaFunction`, and coroutine `resume` — not just `Execution.swift`. A Lua
  function invoked through the callback system or a coroutine tight loop must be
  cancellable too.
- **Cancel & limit classified OUT-OF-BAND, not by message text.** Because #19
  installs an `errfunc` handler on every `pcall` (F2), the cancel/limit `lua_error`
  raises would otherwise pass through it and be repackaged as structured runtime
  errors, breaking detection (and the current `message.contains` sentinel check).
  The compositor sets a dedicated reason flag BEFORE raising; the run wrapper reads
  that flag **after `lua_pcall` returns** to yield `LuaError.cancelled` /
  `instructionLimitExceeded`. The #19 handler detects these sentinels and passes
  them through untouched (F2). **The reason flag is per-engine-instance and atomic**
  (NOT a module-scope mutable like the legacy string sentinel — two engines on
  separate threads must not clobber each other); `resetCancellation()` clears it.
- The hook is **armed whenever a run is cancellable** (i.e. always, for runs that
  the host can cancel) — NOT gated on `instructionLimit > 0`. Because step (2)
  treats `instructionLimit == 0` as "no limit", arming the periodic hook for
  cancellation does not impose a limit. Per-fire overhead is one atomic read plus
  a counter add; document the measured overhead.
- **Abort is `lua_error` ONLY** (longjmp to the `lua_pcall` boundary) — the same
  mechanism the current instruction hook already uses successfully. **`lua_yield`
  is NOT a valid abort path** (it cannot unwind a `pcall`, hits the C-call
  boundary under `pcall`, and 5.1 has no yieldable hooks).
- **Count interval K:** a tunable with a documented default chosen so a CPU-bound
  loop is interrupted within the **200 ms** target (MoonSwift's CI threshold is
  2× = 400 ms). MoonSwift accepts LuaSwift's default. (Open: the exact default —
  OQ1.)
- **C-function limitation:** a C function that does not return to the VM loop
  (e.g. `string.rep('A',1e9)`) cannot be interrupted by a count hook — the **same
  documented limitation** as the instruction limit (LuaSwift #11). Cancellation
  is best-effort for code that never re-enters the VM loop.

**Engine-reuse contract (post-cancel):** because the abort is `lua_error`
unwinding to the `lua_pcall` boundary, the Lua stack is restored to its pre-call
state exactly as it already is for `instructionLimitExceeded` today. LuaSwift
therefore **guarantees a cancelled engine is safe to reuse** after
`resetCancellation()`, and **asserts `lua_gettop` is at the expected base** at the
Swift boundary after the unwind. (If a future change makes a clean unwind
impossible in some path, LuaSwift must instead document a discard-the-engine
requirement — MoonSwift's P2 session-engine mode needs a definite answer.)

**Cross-version (5.1–5.5):** `lua_sethook`/`LUA_MASKCOUNT` and raise-from-count-
hook abort exist on all versions (proven by the shipping instruction hook). The
periodic-count change is version-independent. Validate the unwind through
`lua_pcall` on 5.1 (different hook internals, no `lua_callk`).

**Acceptance (F1):**
- Running `while true do end`, `requestCancellation()` makes the call throw
  `LuaError.cancelled` within 400 ms **with NO instruction limit set** (the S2
  default path) — an explicit test, distinct from any instruction-limit test.
- Cancellation also works **with** an instruction limit set (both compositor
  paths coexist; whichever triggers first wins).
- After `.cancelled` + `resetCancellation()`, the same engine runs a new fragment
  to completion; post-cancel `lua_gettop` assertion holds.
- A finite script finishing before any request returns normally (no false cancel).
- A request that races a natural completion resolves deterministically (either a
  normal result or `.cancelled`, never a corrupt engine) — explicit test; and the
  **next** run on the retained engine (after `resetCancellation()`) completes
  without spurious cancellation (asserts the flag + accumulator were reset).
- Document whether `resetCancellation()` is required before EVERY run on a retained
  engine or only after a `.cancelled` outcome.
- Verified on 5.4; smoke-tested 5.1 + 5.5.
- **Docs:** CHANGELOG + API docs note the C-function limit, the 200 ms target, the
  reuse-safety guarantee, and the lock-free thread-safety contract.

### F2 — Structured errors (#19)

**MoonSwift consumer:** `RunService` produces
`RunOutcome.error(Diagnostic, traceback:)`; `LintService` maps runtime errors to
`Diagnostic`. On availability MoonSwift **deletes `LuaErrorLineParser`** — an
isolated change at its diagnostics boundary (MoonSwift `ARCHITECTURE.md` records
it as a two-edit change: `LuaErrorDiagnostics.swift` call sites). MoonSwift
currently pattern-matches `LuaError.runtimeError` in ≥2 files, so the new surface
must remain catchable as `LuaError` (below).

**Mechanism (must be additive + handler-based):**
- The structured info **must be captured by a message handler installed as the
  `errfunc` argument to `lua_pcall`** (today `errfunc = 0`). The handler runs
  while the failing stack is **still intact** — by the time `lua_pcall` returns,
  the stack is unwound and `luaL_traceback`/`lua_getinfo` have nothing to walk.
  The handler calls `luaL_traceback` (5.2+) or a **manual `lua_getstack`/
  `lua_getinfo` walk (5.1)**, and reads `currentline` from **the first frame whose
  `lua_getinfo("S")` `what != "C"`, scanning upward from level 1** — NOT
  unconditionally level 1. For an explicit `error()`/`assert()`, level 1 is the C
  frame of the `error` builtin (`currentline == -1 → nil`) and the raising Lua
  frame is at level 2; for a VM-internal error (nil-index, arithmetic, type) the
  Lua frame is at level 1. Scanning to the first non-C frame yields the correct
  line in both cases. It packages message + line + traceback.
- **Same handler on ALL entry points** (Round-2): `run`/`evaluate`, the
  `CompiledChunk` run path, and `callLuaFunction` all currently pass `errfunc=0`;
  the handler is installed by the shared run helper so a precompiled-fragment or
  callback-invoked runtime error also gets structured info.
- **Sentinel pass-through (Round-2):** the cancel and instruction-limit raises
  (F1) reach this handler too. The handler **detects the out-of-band reason flag
  and returns those errors untouched** (it does not build a `LuaRuntimeFailure`
  for them), so `LuaError.cancelled` / `instructionLimitExceeded` survive. The run
  wrapper resolves them from the flag after `lua_pcall` returns.
- **Additive API — do NOT change existing case signatures** (changing
  `runtimeError(String)` to a payload tuple is source-breaking and breaks
  MoonSwift's matches). The structured payload ships as a **NEW `LuaError` case**
  so it is caught by MoonSwift's existing `catch … as LuaError` (a standalone
  `Error` type would slip that catch and silently degrade to the generic
  fallback, blocking the `LuaErrorLineParser` deletion):
```swift
enum LuaError: Error {
    // … existing cases (incl. runtimeError(String)) unchanged …
    case runtimeFailure(LuaRuntimeFailure)   // NEW; structured runtime error
}
// NOT `: Error` — delivered ONLY wrapped in LuaError.runtimeFailure, so it can
// never be thrown standalone and slip MoonSwift's `catch … as LuaError`.
struct LuaRuntimeFailure: Sendable {
    let message: String      // Lua message, chunkname/line PREFIX stripped
    let rawMessage: String   // original, prefix intact (fallback)
    let line: Int?           // 1-based line in the raising chunk; nil if none
    let traceback: String    // full traceback, newest frame first
    let frames: [LuaStackFrame]?   // OPTIONAL structured frames (see F5); deferrable
}
```
**Contract MoonSwift depends on (shape-agnostic):**
- `message`: the Lua message with the `chunkname:line:` prefix stripped (MoonSwift
  renders location itself); provide `rawMessage` too.
- `line`: 1-based source line in the **raising** chunk (read from the first non-C
  frame, scanning up from level 1), `nil`
  for C-level errors (an error raised inside a registered Swift function, or a
  level-0 `error(msg, 0)` call). MoonSwift adds the fragment line offset.
- **Non-string errors (Round-2 — no metamethods):** Lua allows `error({table})` /
  `error(obj)`. The handler **checks `lua_type` and emits a typed placeholder
  (e.g. `"<error: table>"`) WITHOUT invoking any metamethod** — it must NOT call
  `__tostring`/`luaL_tolstring`, which can themselves raise (→ `LUA_ERRERR`,
  destroying the structured data), blow the cancellation budget, or re-enter the
  error path.
- `traceback`: full string; with #23, frame source names are the supplied chunk
  names.

**Cross-version:** 5.1 lacks `luaL_traceback` → manual walk fallback (non-nil
traceback on all versions). `currentline` via `lua_getinfo` exists everywhere.

**Acceptance (F2):**
- `error("boom")` on line 3 → `line == 3` (resolved via the first non-C frame, NOT
  level 1 which is the C `error` builtin), `message == "boom"` (no `chunk:3:`).
- A VM-internal error (e.g. `local x = nil + 1`) on line 5 → `line == 5` (its Lua
  frame IS at level 1) — proves the scan handles both error origins.
- A nested-call error → `traceback` contains every frame.
- A runtime error from a **precompiled `CompiledChunk`** and from a
  **`callLuaFunction`-invoked** function both carry structured info (handler on
  all entry points).
- An error raised inside a registered Swift function → `line == nil`, no crash.
- `error({code=1})` (non-string) → a typed-placeholder `message`, with an
  assertion that no `__tostring` metamethod fired.
- **Combined-feature:** a cancelled run and a limit-exceeded run still surface
  `LuaError.cancelled` / `instructionLimitExceeded` (NOT `runtimeFailure`) with
  the #19 handler installed.
- Works 5.1–5.5; 5.1 yields a non-nil traceback via the fallback walk.
- Existing `LuaError.runtimeError(String)` still compiles and matches (no break).
- **Docs:** the message/line/traceback contract, first-non-C-frame line read,
  non-string
  no-metamethod handling, sentinel pass-through, 5.1 fallback.

### F3 — Chunk names (#23)

**MoonSwift consumer:** `RunService` passes `FragmentProvenance.displayName`
(e.g. `config.yaml:$.scripts.init`) so #19/#20 tracebacks and paused-frame labels
show fragment names instead of truncated source.

**Proposed Swift surface (optional, additive, default preserves behavior):**
```swift
func run(_ source: String, chunkName: String? = nil) throws -> LuaValue
func evaluate(_ source: String, chunkName: String? = nil) throws -> LuaValue
func precompile(_ source: String, chunkName: String? = nil) throws -> CompiledChunk
```

**Two distinct mechanisms — the PRD keeps them separate (Round-1 fix):**
1. **Source chunks** (`run`/`evaluate` of a string): pass `chunkName` as the
   `name` argument to `luaL_loadbuffer` (the implementation must switch off any
   `luaL_loadstring`/`=bytecode` shortcut that ignores a caller name). Lua stores
   the full name in the `Proto`'s `source`; `short_src` (used by some tracebacks)
   truncates to `LUA_IDSIZE = 60`. **The `@`/`=`/literal source-prefix convention
   changes WHICH end is truncated** (`@name` keeps the tail with a leading `...`;
   `=name` shows verbatim up to 60; bare is treated as a string snippet). LuaSwift
   must pick and **document** the prefix it uses and whether tracebacks expose the
   full `source` or truncated `short_src`. MoonSwift prefers the full `source`;
   if only `short_src` is available, MoonSwift needs the **tail** (the fragment
   path's most specific component), i.e. the `@`-style truncation.
2. **Bytecode chunks** (`CompiledChunk`): **the load-time `name` arg is ignored
   for binary chunks** — Lua's `lua_load`/undump reads the name from the embedded
   `Proto.source`. Therefore the chunk name must be **embedded at `precompile`
   time** (set as the `Proto` source before `lua_dump`) **and the dump must NOT
   strip debug info**: on 5.3+ pass `strip = 0` to `lua_dump`; 5.1/5.2 `lua_dump`
   has no strip parameter (debug info is retained). The Swift-side `Codable`
   `chunkName` field is metadata for the host; the **traceback name comes from the
   embedded `source`**, so `precompile(_, chunkName:)` must embed it, not merely
   store it.

**Cross-version:** `luaL_loadbuffer` name handling is uniform 5.1–5.5; `LUA_IDSIZE`
is 60 throughout; `lua_dump` strip parameter exists 5.3+ only.

**Acceptance (F3):**
- `run("error('x')", chunkName: "config.yaml:$.scripts.init")` → traceback frame
  names contain `config.yaml:$.scripts.init` (full, or documented-truncated tail).
- Omitting `chunkName` reproduces current behavior exactly (no regression).
- A `CompiledChunk` precompiled with a chunk name reports it in a traceback after
  a `Codable` encode/decode round-trip AND a `lua_dump`/undump round-trip.
- Documented: which of `short_src`/`source` tracebacks expose, and the truncation
  end.
- **Docs:** the source-vs-bytecode mechanisms and the truncation behavior.

### F4 — Introspection (#21)

**MoonSwift consumer:** the Mock Environment navigator renders **live** engine
state — registered value servers, registered functions, installed modules,
user-defined globals — never parallel bookkeeping (MoonSwift PRD F5). The mocking
plumbing it pairs with already exists; only this read surface is missing.

**Proposed Swift surface (read-only, on `LuaEngine`):**
```swift
/// Names of value servers registered via register(server:). Reads the engine's
/// existing `servers` registry under the engine lock.
var registeredValueServerNames: [String] { get }
/// Names of functions registered via registerFunction(name:). Reads `callbacks`.
var registeredFunctionNames: [String] { get }
/// Names of installed modules. REQUIRES NEW BOOKKEEPING: the engine does not
/// currently record installed modules (ModuleRegistry is static); LuaSwift must
/// add an installed-modules record updated by install(in:).
var installedModuleNames: [String] { get }
/// String keys of the engine's globals table. RAW enumeration only.
func globalNames(includingStandardLibrary: Bool) -> [String]
/// Typed read of a global by name. RAW access only.
func globalValue(_ name: String) -> LuaValue?
```

**Safety contract (Round-1 fix — read-only must be REALLY read-only):**
- **Raw access only, at every depth (Round-2).** `globalValue` uses `lua_rawget`
  (NOT `lua_getglobal`, which triggers `__index`); `globalNames` uses a raw
  `lua_next` loop (NOT `pairs`, which triggers `__pairs` on 5.2+). The
  **recursive materialization** of any returned table value must ALSO use raw
  `lua_next` at every nesting level — a shared `valueFromStack`-style helper that
  falls back to `pairs`/`__index` on nested tables would re-introduce metamethod
  execution. Inspection MUST NOT invoke metamethods (`__index`/`__pairs`/`__gc`)
  at any depth. **Acceptance asserts raw access on a nested table.**
- **Between-runs only (Round-2).** F4 methods are safe to call **only when no run
  is executing or paused** — the `lua_State` is not re-entrant, so a raw `lua_next`
  against an actively-executing VM is UB at the C level even though the
  `NSRecursiveLock` would permit a same-thread call. Document this; MoonSwift
  calls introspection after a run completes (or, during debugging, only while the
  engine thread is blocked at a pause AND the lock is released — see F5).
- **Enumerate the engine's globals table directly** — the registry globals table
  (`LUA_RIDX_GLOBALS` on 5.2+) or the globals pseudo-index on 5.1 — not "the
  `_ENV` variable" (which a chunk may have swapped). Document that a chunk that
  reassigns `_ENV` does not affect what `globalNames` enumerates.
- **No value re-injection.** Any `LuaValue` returned by `globalValue`/the inspector
  that wraps a Lua reference (function/table via `luaL_ref`) is bound to THIS
  engine; the contract prohibits re-injecting it into a different engine
  (especially a sandboxed one). Document this.
- **Concurrency.** All introspection acquires the engine `lock` before reading the
  registries/globals (MoonSwift renders on the UI thread while the engine may be
  between runs; Swift 6 strict concurrency forbids the unsynchronized read).

**Cross-version:** globals-table access differs (5.1 globals pseudo-index vs 5.2+
`LUA_RIDX_GLOBALS`); module registry is version-independent.

**Acceptance (F4):**
- After `register(server:)` for `game` and `registerFunction(name:"log")`,
  the two `registered*Names` contain `game` / `log`.
- After a run defines `x = 5`, `globalNames(includingStandardLibrary:false)`
  contains `x` and not `print`.
- A global whose metatable has a side-effecting `__index`/`__pairs` is enumerated
  and read WITHOUT invoking the metamethod (assert the side effect did NOT occur),
  including a **nested table** with a side-effecting `__pairs` (recursive raw).
- `installedModuleNames` lists modules installed via the registry.
- Introspection does not alter a subsequent run's behavior.
- Works on 5.1 and 5.2–5.5.
- **Docs:** read-only/raw guarantees, no-re-injection, globals-table semantics.

### F5 — Public debug-hook API (#20)

**MoonSwift consumer:** MoonSwift's `DebugSession` (F6) — breakpoints, step
over/into/out, continue, pause UI, locals/upvalues/globals/call-stack inspection,
built against the event/command vocabulary this API defines.

**Pause concurrency model — RESOLVED to blocking (Round-1 fix):** the debug hook
**blocks the engine thread** on a semaphore/channel until a command arrives. This
is the **only** model that satisfies the full contract: a coroutine/yield model
**cannot pause on call/return events** (yield only legal at specific points) and
is **impossible on 5.1** (no yieldable hooks). MoonSwift drives the engine on a
dedicated thread and exchanges events/commands across the semaphore. (This closes
former OQ on the model.)

**Pause-model details (Round-2):**
- **The engine lock is RELEASED before the hook blocks** so the host can issue the
  next command from another thread without deadlock. The inspector reads are valid
  because the engine thread is parked inside the hook, not executing VM
  instructions.
- **An `isPaused` guard fences off the released lock (Round-3 security).** Releasing
  the lock would otherwise let another thread acquire it and call `run`/`evaluate`/
  `registerFunction` against the **same `lua_State` that is mid-execution** (C-level
  UB). While paused, LuaSwift sets `isPaused` and any public method that touches
  `L` (run/evaluate/callLuaFunction/registerFunction/F4 introspection) **throws
  `LuaError.enginePaused`**. Only resume commands (issued through the debug
  controller) and the validity-checked inspector may proceed.
- **The handler MUST NOT call back into `LuaEngine`** (`run`/`callLuaFunction`/F4
  introspection-that-runs-Lua). The `lua_State` is non-re-entrant mid-execution
  even though the recursive lock would permit the call. The inspector is the ONLY
  sanctioned interaction surface while paused; it does not execute Lua.
- **Cancel-while-paused ordering:** `requestCancellation()` while the VM is parked
  at a pause sets the atomic flag but cannot fire the hook (the VM is not
  executing). On the next resume command the compositor re-enters and the cancel
  flag is observed, aborting via the F1 unwind. The contract: a cancel issued
  during a pause takes effect on resume (it does not unblock the semaphore by
  itself). Optionally LuaSwift may also treat a pending cancel as an implicit
  `stop`. **Document the chosen behavior.**
- **Optional watchdog:** LuaSwift MAY bound the blocking duration and auto-abort
  via the cancel path; not required by MoonSwift (its `DebugSession` always issues
  a command), but state whether one exists.

**Proposed Swift surface (contract; exact shape negotiable):**
```swift
enum LuaDebugEvent {
    case line(Int)                 // about to execute this line
    case call(LuaStackFrame)       // entered a function
    case ret                       // returning from a function
}
struct LuaStackFrame {
    let name: String?              // function name if known
    let source: String             // chunk name (see #23)
    let currentLine: Int?
    let level: Int                 // 0 = innermost
}
enum LuaDebugCommand { case continueRun, stepOver, stepInto, stepOut, stop }

// The handler receives an inspector valid ONLY for the call's duration. Because
// `setDebugHandler` stores the handler @escaping, a `borrowing`/~Escapable
// PROTOCOL parameter is NOT compiler-enforceable in Swift 6.0–6.3 (that machinery
// is for value types, not protocol existentials). So the inspector enforces its
// lifetime at RUNTIME with a fail-fast validity token: every method precondition-
// checks `isValid`, which LuaSwift flips false when the callback returns. Use
// after the callback traps deterministically (never silent stack corruption).
// (Equivalent alternative LuaSwift may choose: a `withInspection(event:_ body:)`
// scoped-closure shape that hands `body` a non-escaping inspector — also fine;
// document which.)
typealias LuaDebugHandler =
    (_ event: LuaDebugEvent, _ inspector: LuaDebugInspector) -> LuaDebugCommand

protocol LuaDebugInspector: AnyObject {
    var isValid: Bool { get }   // false once the callback has returned; methods trap if used after
    var callStack: [LuaStackFrame] { get }
    func locals(frameLevel: Int) -> [(name: String, value: LuaInspectedValue)]
    func upvalues(frameLevel: Int) -> [(name: String, value: LuaInspectedValue)]
    func globals() -> [(name: String, value: LuaInspectedValue)]   // raw, like F4
}

// Reference-typed Lua values (function/table/userdata) are NOT returned as a
// re-invokable LuaValue: LuaValue.luaFunction(Int32) carries a raw registry index
// with no engine identity, so it could be re-injected into another lua_State
// (dangling-ref UB). Instead the inspector yields a SELF-CONTAINED snapshot taken
// EAGERLY at pause time (no external handle, no lifetime dependency, never
// re-injectable): scalars are copied; a table's children are materialized into
// `children` up to a DEPTH CAP (64, matching MoonSwift's alias-bomb budget) with
// raw-pointer CYCLE DETECTION (a repeated table → `.reference(... children: nil,
// preview: "<cycle>")`); functions/userdata/threads carry only a metamethod-free
// preview. All materialization uses raw `lua_next` (no __index/__pairs), F4 rules.
indirect enum LuaInspectedValue: Sendable {
    case scalar(LuaValue)                 // nil/bool/int/number/string — safe to copy
    case reference(kind: LuaRefKind,
                   preview: String,       // raw, metamethod-free
                   children: [(key: String, value: LuaInspectedValue)]?)  // nil = leaf/cycle/depth-capped
}
enum LuaRefKind: Sendable { case function, table, userdata, thread }

extension LuaEngine {
    func setDebugHandler(_ handler: LuaDebugHandler?)
    func runDebug(_ source: String, chunkName: String?) throws -> LuaValue
    func runDebug(_ chunk: CompiledChunk) throws -> LuaValue   // parity with run()
}
```

**Contract MoonSwift depends on:**
- **Events:** line/call/return with the frame's source (chunk name) + line — enough
  for breakpoints (MoonSwift compares the line event to its breakpoint set) and
  stepping.
- **Native stepping (Round-1 fix — host-side depth tracking is NOT acceptable):**
  LuaSwift **provides** `stepOver`/`stepInto`/`stepOut` natively. The host cannot
  reliably synthesize them from call-depth counting because **tail-call hook
  events diverge per version** — 5.1 emits `LUA_HOOKTAILRET`, 5.2+ emit
  `LUA_HOOKTAILCALL` with **no matching return event** — so a host depth counter
  overshoots `stepOut` to the grandparent frame. LuaSwift handles tail-call frame
  accounting internally and exposes correct over/into/out.
- **Pause + inspect:** while paused, the non-escaping `inspector` exposes the call
  stack and per-frame locals/upvalues (`lua_getlocal`/`lua_getupvalue`) + globals
  (raw, per F4). Values come back as **`LuaInspectedValue`** — scalars copied;
  reference types returned as a **self-contained, eagerly-snapshotted, non-callable
  descriptor** (children materialized at pause to a depth cap of 64 with cycle
  detection — see the type). This makes re-injection **impossible by construction**
  (no free-floating registry index escapes) AND removes any cross-callback handle
  lifetime (the snapshot is owned by the returned value, valid after the callback
  ends; MoonSwift renders the already-materialized tree on `<Enter>`).
- **`stop`:** **reuses the cancellation unwind** (F1's `lua_error` path); a
  `runDebug` run aborted by `stop` surfaces a **distinct terminal state** so
  MoonSwift can tell debugger-stop from a UI-cancel of a normal run. Recommended:
  `stop` → throw `LuaError.cancelled` from `runDebug` (MoonSwift's `DebugSession`
  owns the distinction by knowing it issued `stop`); if LuaSwift prefers a
  separate `LuaError.debugStopped`, that is acceptable — **document which.**
- **Normal `run` is unaffected:** `setDebugHandler(nil)` / plain `run` installs no
  line hook and pays no debug overhead (the compositor hook's debug step is a
  no-op when no handler is set).

**Cross-version:** `lua_sethook` masks (`LINE|CALL|RET`) exist on all versions;
`lua_getlocal`/`lua_getupvalue` are consistent 5.1–5.5; **tail-call frame
numbering differs** (documented above) and LuaSwift owns the reconciliation.

**Acceptance (F5):**
- A 3-line script yields line events 1,2,3 in order; returning `.stop` at line 2
  aborts before line 3 (assert line 3 never fired).
- At a pause, `inspector.locals(frameLevel:0)` returns a local defined above the
  paused line with its value.
- **Breakpoint test:** handler returns `.continueRun` until line N then pauses;
  reaches N and inspects state.
- **Concrete stepping test incl. a tail call:** given a script where `f` ends in
  `return g()` (a tail call), `stepOut` from inside `g` returns to `f`'s **caller**
  (not `f`), with an asserted exact paused-line sequence — proving native
  over/into/out handle the tail-call divergence.
- A nested call yields a `callStack` with ≥2 frames at the inner pause.
- `runDebug(CompiledChunk)` behaves like `runDebug(source)`.
- `stop` surfaces the documented terminal state.
- **Cancel-while-paused:** `requestCancellation()` issued while paused, then a
  `.continueRun`, aborts on resume (asserts the run ends in the cancel terminal
  state, not normal completion).
- **Inspector reference value:** a local holding a function/table is returned as a
  `.reference` descriptor (asserts it is NOT a re-invokable `LuaValue`).
- Works on 5.4; smoke-tested 5.1 + 5.5 with the tail-call test on each.
- **Docs:** an internals/debug article specifying the event/command vocabulary,
  the blocking concurrency model, native stepping + tail-call handling, the
  non-escaping inspector lifetime, and the `stop` terminal state.

---

## 4. Technical Architecture

LuaSwift's per-concern `LuaEngine` extension structure accommodates all five
additively:

| Feature | Likely file(s) | Nature |
|---|---|---|
| #22 cancellation | `LuaEngine+Execution.swift`, `LuaError.swift` | periodic compositor hook + atomic flag + enum case |
| #19 structured errors | `LuaError.swift`, `LuaEngine+Execution.swift` | message handler as `errfunc` before `lua_pcall` |
| #23 chunk names | `LuaEngine+Execution.swift`, `LuaEngine+Bytecode.swift`, `CompiledChunk.swift` | name → `luaL_loadbuffer` (source); embed in `Proto.source` + `strip=0` (bytecode) |
| #21 introspection | `LuaEngine+ValueServer.swift`, `LuaEngine+Callbacks.swift`, `Modules/ModuleRegistry.swift`, new `LuaEngine+Introspection.swift` | expose `servers`/`callbacks`; NEW installed-modules record; raw globals walk |
| #20 debug hooks | new `LuaEngine+Debug.swift` (+ types) | debug step of the compositor hook + blocking event loop + non-escaping inspector |

**The single-hook-slot compositor is the central architectural constraint.** Lua
exposes one `lua_sethook` slot per `lua_State`. The current code overwrites it
(last-writer-wins). #22, the instruction limit, and #20 all need it. LuaSwift must
install **one** periodic count hook whose callback multiplexes: cancellation-flag
check → instruction-limit accounting → debug-event dispatch (when a handler is
set). Line/call/return masks are added to the same hook only while a debug handler
is active. This is the design that lets the three features coexist.

**One shared run helper — but the hook and the errfunc cover DIFFERENT path sets
(Round-3).** The two installs are NOT congruent because `lua_resume` takes no
error-handler argument:
- **Compositor hook → 4 paths:** `run`/`evaluate` (`Execution.swift`), the
  `CompiledChunk` run (`Bytecode.swift`), `callLuaFunction` (`FunctionCalls.swift`),
  AND coroutine `resume` (`Coroutines.swift`, via `lua_resume`). The hook is
  per-`lua_State`, so a resumed coroutine thread gets its own `lua_sethook`.
- **#19 `errfunc` message handler → the 3 `lua_pcall` paths only**
  (`run`/`evaluate`, `CompiledChunk` run, `callLuaFunction`). `lua_resume` has no
  `errfunc`; a coroutine error surfaces at its `lua_resume` site, where the
  enclosing `pcall` path's handler (or the resume wrapper) reports it.

The helper also (a) zeroes the instruction accumulator per run (else session-engine
reuse trips a spurious limit), and (b) recovers the owning `LuaEngine` inside the C
hook via the existing `setAsCurrentEngine()` TLS (`LuaEngine.swift:251`; no
`lua_getextraspace` on 5.1/5.2). Cancel/limit are recorded in the per-engine atomic
reason flag read after the call returns, so the #19 handler never misclassifies
them.

**Shared internals:** #19 and #20 both walk the stack (`lua_getstack`/`getinfo`) —
a shared internal helper. #23 feeds #19/#20 frame names — implement #23 with/before
#19. #20's `stop` reuses #22's unwind. #20/F4 share the raw globals walk.

**Data-model: one additive `CompiledChunk` field.** `CompiledChunk` gains an
optional chunk-name field; bump `formatVersion` (e.g. 1 → 2) and, per the existing
decode-tolerance rule, **decode of a v1 chunk defaults the field to nil** (no break
for chunks persisted before this change). The embedded `Proto.source` (F3) is the
authoritative traceback name; the Swift field is host metadata.

---

## 5. Security Considerations

- **Introspection (#21) is read-only via RAW access** (F4): `lua_rawget` + raw
  `lua_next`, never `__index`/`__pairs`. This prevents a malicious
  `__index`/`__pairs`/`__gc` from executing Lua code or mutating state during
  passive inspection (CWE-orthogonal: confused-deputy via metamethod). Acceptance
  asserts no metamethod fires.
- **Inspector reference values cannot be re-injected — by construction (Round-2).**
  The debug inspector never returns a re-invokable `LuaValue` for a function/table:
  it returns a non-callable `LuaInspectedValue.reference` descriptor (F5). A raw
  `LuaValue.luaFunction(idx)` would carry a free-floating registry index usable
  against any `lua_State`, so a function captured in an unrestricted debug session
  could otherwise be smuggled into a sandboxed run; the opaque descriptor removes
  that capability entirely (not merely by policy). The inspector is also
  non-escaping (`borrowing`/closure-param) so it cannot leak past the callback.
- **#19 handler runs no metamethods (Round-2).** The message handler stringifies a
  non-string error value via a `lua_type` check + typed placeholder only — never
  `__tostring`/`luaL_tolstring` — so a hostile `__tostring` cannot execute during
  error unwind (which would risk `LUA_ERRERR`, a blown cancellation budget, or
  re-entrancy).
- **Blocking debug pause is not a DoS/deadlock surface (Round-2).** The engine lock
  is released before the hook blocks; the handler must not re-enter `LuaEngine`;
  the `lua_State` is touched only by the parked engine thread. A pending cancel is
  observed on resume.
- **Cancellation (#22) leaves a reusable, non-corrupt VM** (F1 reuse contract) —
  the `lua_error` unwind restores the stack (as `instructionLimitExceeded` already
  does), with a `lua_gettop` assertion; otherwise discard-the-engine is mandated.
- **Traceback information disclosure (#19/#23):** chunk names appear verbatim in
  user-visible tracebacks. MoonSwift passes **display labels**
  (`config.yaml:$.scripts.init`), not absolute host paths; LuaSwift should treat
  the name as opaque and not augment it with host paths (CWE-209, low severity in
  a developer tool, but avoid leaking the host filesystem layout).
- No new network, filesystem, or process surface is introduced.

---

## 6. Performance Requirements

- **#22 latency:** effective within 200 ms for CPU-bound loops (bounds the count
  interval K). When armed only for cancellation, per-fire cost ≈ one atomic read +
  a counter add; document the measured overhead and the default K.
- **#20 debug overhead:** line/call/return hooks fire per line/call — inherently
  costly. Acceptable because debugging is opt-in via `runDebug`/`setDebugHandler`;
  a plain `run` installs NO line/call/ret mask and the compositor hook's debug
  step is a no-op. Document that debug mode is slower.
- **#21 introspection:** O(globals)/O(registry) per call, invoked after a run, not
  in a hot path. No specific latency target.

## 7. Roadmap (phased, no timelines)

1. **#22 cancellation** — unblocks MoonSwift P1 immediately; establishes the
   periodic compositor hook the others build on. Small–medium.
2. **#23 chunk names** — small; foundational for faithful tracebacks.
3. **#19 structured errors** — depends on #23 (frame names) + the errfunc handler;
   medium.
4. **#21 introspection** — independent; medium.
5. **#20 debug hooks** — largest; reuses the compositor hook, #19's stack-walk
   helper, #23's names, #22's `stop` unwind, F4's raw globals walk.

A single LuaSwift release shipping all five satisfies MoonSwift's P2 gate
(#19/#20/#21/#23) and the P1 cancellation item (#22). MoonSwift then bumps the
pin, drops `MOONSWIFT_LUASWIFT_22`, and deletes `LuaErrorLineParser`.

## 8. Logical Dependency Chain

```
#22 cancellation (periodic compositor hook) ──┬─→ #20 stop reuses unwind
                                              └─→ (foundation for #20 hook slot)
#23 chunk names ──┬─→ #19 structured errors (frame names)
                  └─→ #20 debug hooks (frame source names)
#19 stack-walk helper ─→ #20 (shared lua_getstack/getinfo)
#21 introspection (raw globals walk) ─→ #20 inspector.globals()
```

## 9. Test Strategy

- Each §3 acceptance criterion → a LuaSwift unit test, run on each vendored Lua
  version where the criterion is version-relevant.
- **#22:** cancellation-latency test asserting `<400 ms` + `.cancelled`, run BOTH
  with no instruction limit (S2 path) and with one; plus a reuse-after-cancel test
  and a cancel-races-completion test. (This is portable from MoonSwift's
  `Tests/MoonSwiftPerfTests/` cancellation test, today gated by
  `MOONSWIFT_LUASWIFT_22`.)
- **#19:** error-line, nested traceback, C-function `line == nil`, non-string
  error, and 5.1 fallback-walk tests; assert the existing `runtimeError(String)`
  case still matches.
- **#23:** chunk-name-in-traceback for source AND for a `CompiledChunk` after a
  `lua_dump`/undump + `Codable` round-trip; no-regression when omitted; **a v1
  (pre-chunk-name) `CompiledChunk` decodes under formatVersion 2 with the field
  defaulting to nil** (forward-compat, no `keyNotFound`).
- **#21:** registry/globals enumeration after register + run; a metamethod-not-
  fired assertion; post-introspection run unaffected.
- **#20:** event-order, breakpoint, pause-inspection, nested-frame, and the
  concrete **tail-call step-out** test, on 5.1/5.4/5.5.
- **Cross-version matrix:** 5.4 full; 5.1 + 5.5 for divergent paths (traceback
  fallback, `_G`/globals-table, tail-call stepping, periodic-hook unwind).

## 10. Documentation Plan

Per feature, LuaSwift updates **in the same change-set as the code**:
- **CHANGELOG.md** — one entry per issue (#19–#23).
- **API docs / DocC** — new symbols + contracts: cancellation C-function limit +
  reuse safety + lock-free thread-safety; error message/line/traceback + non-string
  + 5.1 fallback; chunk-name source-vs-bytecode + truncation end; introspection
  raw/read-only + no-re-injection + globals-table semantics; debug event/command
  vocabulary + blocking model + native stepping + tail-call handling + non-escaping
  inspector + `stop` terminal state.
- **A debug internals article** for #20.

MoonSwift, on the pin bump (separate change-set), deletes `LuaErrorLineParser`,
drops `MOONSWIFT_LUASWIFT_22`, wires #19/#20/#21/#23 into F5/F6, and updates its
user docs (running/debugging/mocking).

## 11. Risks & Mitigations

- **R1 — compositor hook regressions.** Folding instruction-limit + cancel +
  debug into one periodic hook could change instruction-limit timing or overhead.
  *Mitigation:* keep the limit semantics (accumulate to `instructionLimit`),
  regression-test the existing instruction-limit suite, measure per-fire overhead.
- **R2 — 5.1 divergence** (no `luaL_traceback`, tail-call hook differences, no
  yieldable hooks). *Mitigation:* explicit 5.1 fallbacks + tests (F2/F5); blocking
  pause model (not coroutine) sidesteps the 5.1 yield gap.
- **R3 — chunk-name truncation / bytecode embedding.** Names may not reach
  tracebacks if dumped stripped or only passed at load. *Mitigation:* F3 embeds at
  precompile + `strip=0`; round-trip test.
- **R4 — cancelled/stopped engine reuse corruption.** *Mitigation:* F1 reuse
  contract + `lua_gettop` assertion, or discard mandate.
- **R5 — metamethod-triggering introspection.** *Mitigation:* F4 raw-access
  mandate + metamethod-not-fired test.

## 12. Open Questions (genuinely undecided — LuaSwift's call)

- **OQ1 — count interval K default** for #22 (and the per-fire overhead it
  implies). MoonSwift accepts LuaSwift's default that meets the 200 ms target.
- **OQ2 — #19 frames array.** Ship `[LuaStackFrame]` on the error now (cheap if the
  #20 stack walk lands together) or string-traceback only for #19 and frames via
  #20's inspector? MoonSwift works with either; prefers frames if cheap.
- **OQ3 — `stop` terminal state shape:** reuse `LuaError.cancelled` vs a new
  `LuaError.debugStopped`. MoonSwift handles either; document the choice.

## 13. Deferred Items

- Structured `[LuaStackFrame]` on `LuaError` for #19 (vs string traceback only) —
  ship with #20 if not cheap with #19 (OQ2).
- Watchpoints / conditional breakpoints — MoonSwift implements conditions host-side
  on line events; no LuaSwift change needed.
- Swift codegen export of mock definitions — MoonSwift-side, not LuaSwift.

## 14. Appendix — MoonSwift consumer references

- Cancellation fallback + flag: `MoonSwiftCore/Run/RunService.swift`
  (`#if MOONSWIFT_LUASWIFT_22`).
- Error mapping + parser to delete: `LuaErrorLineParser`, `Diagnostic`,
  `RunOutcome` (MoonSwift PRD §4.3).
- Mocking plumbing (already in LuaSwift): `register(server:)`,
  `registerFunction(name:callback:)`, `callAndReleaseLuaFunction(_:args:)`,
  `LuaValueServer`.
- Authority for MoonSwift needs:
  `.taskmaster/docs/20260607-1156_moonswift_v1_PRD_full-roadmap.txt` §F3, §F5,
  §F6, §4.3.
- LuaSwift issues: #19, #20, #21, #22, #23 (all OPEN at v1.10.1).
- Existing-state claims verified against the v1.10.1 source tree (LuaError.swift,
  LuaEngine+Execution.swift:73–78/113/156, LuaEngine+ValueServer.swift,
  LuaEngine+Callbacks.swift, CompiledChunk.swift, Modules/ModuleRegistry.swift,
  and vendored CLua*/include + ldebug.c/ldo.c/lundump.c/ldump.c).
