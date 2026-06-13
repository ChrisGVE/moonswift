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

The Debug tab (key `3`, or `<Tab>` to cycle) shows the current pause state:

- **No debug session** — idle message.
- **Running** — `Running…` while the VM is executing between pauses.
- **Paused** — pause header and call stack:

```
── Paused at line N ──
  #0  test.lua:7  main
  #1  test.lua:2  helper
```

Each stack frame shows: level, source file, current line, and function name
(when available). Up to 8 frames are shown; deeper stacks show a `… N
more frame(s)` suffix.

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

## Line mapping

Breakpoints are stored as fragment-relative line numbers (1-based). For
scripts embedded in JSON/YAML/TOML files the fragment is the Lua code block
extracted by MoonSwift; line 1 of the fragment corresponds to the first line
of the extracted code, not the first line of the structured file. The gutter
line numbers reflect this fragment-relative numbering.
