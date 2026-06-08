# MoonSwift — running scripts

## Starting a run

Press `r` from any pane to run the currently selected source. Preconditions:

- A source must be selected and in the loaded state.
- The project's `lua_version` must be `"5.4"`.
- No run is currently in progress.

When a precondition is not met, `r` produces a 1.5-second transient message
and no run starts.

The bottom pane switches to the Output tab automatically. A run header
appears at the top of the output:

```
── Run N · HH:MM:SS ──
```

where `N` is the run counter for the session (1-based) and `HH:MM:SS` is
the wall clock at start.

## Output capture

`print` output is captured and streamed into the Output tab line by line.
The buffer holds up to 1000 lines; when it overflows the oldest lines are
discarded and a notice is inserted:

```
[cleared — N lines discarded]
```

Press `<C-l>` with the bottom pane focused to clear the output buffer
manually.

**Known limitation — `io.write`:** In `unrestricted` mode, `io.write` and
other `io.*` functions write directly to process stdout, bypassing the
capture mechanism. This produces visible corruption of the terminal alternate
screen until the next redraw. Use `print` instead of `io.write` when running
inside MoonSwift. This limitation affects `unrestricted` mode only;
`sandboxed` mode removes the `io` library entirely.

## Return value display

A non-nil return value from the script is displayed between the last output
line and the footer:

```
→ 42
```

Tables are shown shallow (`{…}` beyond depth 2). A script that returns
nothing or explicitly returns `nil` displays `(no value)`.

## Run footer

When a run completes, a footer line is appended:

| Outcome | Footer |
|---------|--------|
| Normal completion | `done — Xms` |
| Script error | `error — <message> → jump to line N` |
| Cancelled | `cancelled` |
| Instruction limit | `instruction limit exceeded (N instructions)` |
| Wall-clock limit | `wall-clock limit exceeded (Xms)` |
| Engine error | `✖ Engine error: <message>` |

When a script error footer is shown, pressing `<Enter>` on that line in the
bottom pane scrolls the code pane to the error line with a 500 ms highlight
pulse.

## Cancellation

Press `x` to cancel a running script.

**Current limitation:** cancellation requires LuaSwift cooperative
cancellation support (LuaSwift#22), which is not yet available at the current
pin. Pressing `x` shows a transient message and the run continues to its
natural end or instruction limit. The `x` key will cancel immediately once
the required LuaSwift version is available.

## Instruction limit

Set `run.instruction_limit` in `moonswift.toml` to a positive integer to
stop a run after that many Lua VM instructions:

```toml
[run]
instruction_limit = 1_000_000
```

`0` (the default) means no limit. When the limit fires the run ends with the
"instruction limit exceeded" footer immediately.

## Wall-clock limit

Set `run.wall_clock_limit_ms` to a positive integer (milliseconds) to impose
a time limit:

```toml
[run]
wall_clock_limit_ms = 5000   # 5 seconds
```

**Current limitation:** this setting has no effect in the current build.
Wall-clock limits require LuaSwift cooperative cancellation (LuaSwift#22).
MoonSwift emits a project warning at load time when this field is set to a
non-zero value in a binary compiled without #22 support. The run will
continue to its natural end or instruction limit.

## Sandbox vs unrestricted

The `run.config` field controls the engine mode:

| Mode | Lua globals | When to use |
|------|-------------|-------------|
| `"sandboxed"` (default) | Standard library minus `io`, `debug`, and unsafe functions | General development |
| `"unrestricted"` | All Lua globals, including `io.*`, `os.*`, `debug.*` | When the script needs filesystem or system access |

Unrestricted mode is indicated by an `[unrestricted]` badge in the title bar.
Use it only when the script genuinely needs the removed globals.

## Engine lifecycle

Each run creates a fresh Lua engine and discards it when the run completes.
State does not persist between runs. This ensures each run is reproducible
regardless of what previous runs produced.
