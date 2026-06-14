# MoonSwift — breakpoints and debug run

MoonSwift's debug run lets you pause a Lua script at specific lines and
inspect the call stack at each pause.

## Setting breakpoints

With the **code pane focused**, position the cursor on any line and press `b`
to toggle a breakpoint:

- `○` (empty gutter) — no breakpoint on this line.
- `●` (filled, error color) — breakpoint set.

Press `b` again on the same line to remove the breakpoint.

Breakpoints are stored per-source (per `SourceID`). They persist for the
session but are not saved to disk.

**Key moved:** `b` was previously "scroll up one full page". That action is
now on `<C-b>` (Ctrl+b).

## Starting a debug run

Press `<C-g>` from any pane to start a debug run with the current
breakpoints.

### Preconditions

| Situation | What happens |
|-----------|--------------|
| No source loaded | Transient: `No source to debug.` |
| A normal run is in progress | Transient: `A run is already in progress.` |
| A debug session is already active | Transient: `Restart debug session? [y/N]` |
| Lua version does not support debug hooks | Transient: `Debugging unavailable for this Lua version.` |

When all preconditions are satisfied the debug run starts immediately and the
bottom pane switches to the **Debug** tab.

## The Debug tab

The Debug tab (key `3`, or `<Tab>` to cycle) appears only while a debug session
is active. Pressing `3` with no session shows `Debug tab not active.`

### Inspecting variables & the call stack

While **paused**, the tab shows four sections:

```
── Locals ──
  local count = 3
  ▸ local cfg = {table}
── Upvalues ──
  upvalue base = 10
── Globals ──
── Call Stack ──
▸ #0  test.lua:7  main
  #1  test.lua:2  helper
```

- **Locals** / **Upvalues** — the variables of the *selected* frame, as
  `local <name> = <value>` / `upvalue <name> = <value>`.
- **Globals** — not captured automatically. Press `g` while paused to capture a
  bounded, filtered slice of user-defined globals (standard-library and reserved
  names are excluded). While the capture is in flight the section shows
  `(globals pending…)` and the status bar appends `[globals pending…]`. The
  states are: header only (not yet fetched), `(no globals defined)` (fetched, no
  user globals), and `(… N more globals)` when the slice is capped at 256.
- **Call Stack** — one line per frame, `#<level>  <source>:<line>  <name>`.

Navigate with `j`/`k` (the `❯` cursor marks the active row) and act with
`<Enter>`:

- On a **call-stack frame**, `<Enter>` selects it (marked `▸`) — the Locals and
  Upvalues sections re-render for that frame and the code pane jumps to its line.
  Frame data is captured eagerly at the pause, so switching frames never
  re-enters the engine.
- On an **expandable table value** (`▸`), `<Enter>` expands it inline (`▾`) to
  show its children; `<Enter>` again collapses it. Values past the depth limit
  render `(…)` and cyclic references render `(cycle)`.

### While the VM is running between pauses

The Debug tab stays visible between pauses. Before the first pause it shows
`VM running…` with each section reading `(VM running — no snapshot yet)`. After a
step or continue it shows `VM running… (showing last pause)` and keeps the last
pause's data, dimmed, so you don't lose your place.

## Gutter marks during a debug session

| Mark | Style | Meaning |
|------|-------|---------|
| `●` | error color | Breakpoint set, not currently paused here |
| `●` | highlight-pulse color | Breakpoint set AND VM is paused here |
| `▶` | highlight-pulse color | VM is paused here (no breakpoint) |
| `E` | error color | Lint/run error on this line |
| `W` | warning color | Lint warning on this line |

Priority when marks overlap: `●` paused > `▶` paused > `●` breakpoint >
`E` error > `W` warning.

## Stepping through code

When the VM is paused (the Debug tab shows the call stack), use these keys
from the **code pane** or the **Debug tab**:

| Key | Action |
|-----|--------|
| `s` | Step over — advance to the next line in the current function |
| `i` | Step into — descend into the called function |
| `o` | Step out — run until the current function returns |
| `c` | Continue — run until the next breakpoint (or end of script) |
| `x` | Stop — terminate the debug session immediately |

The status bar shows a reminder while paused:

```
[paused at test.lua:7]  s/i/o step  c continue  x stop
```

### While the VM is running between pauses

After a step or continue command the VM runs until it hits the next breakpoint
or stop point. During this interval, `s`/`i`/`o`/`c` show a brief `VM running…`
notice and have no effect. Wait for the next pause before issuing another
stepping command.

### Stepping from the navigator

The navigator does not handle stepping keys. If you press `s`, `i`, `o`, or
`c` while the navigator is focused and a session is paused, MoonSwift shows:

```
Stepping is in the Debug tab — press 3.
```

Switch to the Debug tab (key `3`) or the code pane to step.

### Stopping a session

Pressing `x` while a debug session is active terminates the session
immediately, regardless of whether the VM is paused or running. The status bar
shows `Session stopped.` briefly. After stopping, you can start a new debug
run with `<C-g>`.

Note: `x` normally cancels a plain run. While a debug session is active `x`
targets the debug session instead.

## Restarting a session

If a debug session is active and you press `<C-g>` again, MoonSwift asks:

```
Restart debug session? [y/N]
```

- Press `y` to stop the running session and launch a new one with the
  current breakpoints.
- Press any other key (including `n` or `Esc`) to cancel and keep the
  existing session.

## Finishing a session

A debug run ends when:

- The script reaches its natural end (no more breakpoints).
- The session is stopped via the restart-confirmation `y` path.

When a session ends, all paused-line markers are cleared from the gutter and
the Debug tab returns to the idle message.

## Errors & tracebacks

When a run or debug run hits a runtime error, the Output tab shows the error
footer (`error — <message> → jump to line N`) followed by the **traceback** —
one line per stack frame, newest frame first. The traceback comes straight from
the Lua engine's structured error (it captures the failing stack while it is
still intact), so the line numbers are accurate.

Frame names are **faithful**: each frame is labelled with the fragment's display
name — the filename for whole `.lua` files, or `<filename>:<jsonpath>` for a
script embedded in a JSON/YAML/TOML field (e.g. `config.yaml:$.scripts.init`) —
instead of a truncated snippet of the source text. This makes a traceback that
crosses several embedded fragments readable at a glance.

A debug run that ends in an error surfaces the same footer and traceback in the
Output tab (the Debug tab closes when the session ends).

## Line mapping

Breakpoints are stored as fragment-relative line numbers (1-based). For
scripts embedded in JSON/YAML/TOML files the fragment is the Lua code block
extracted by MoonSwift; line 1 of the fragment corresponds to the first line
of the extracted code, not the first line of the structured file. The gutter
line numbers reflect this fragment-relative numbering.
