# MoonSwift — CLI reference

## Usage

```
moonswift                   open current directory as a project
moonswift <dir>             open <dir> as a project root
moonswift <file.lua>        quick one-off: run/lint a single .lua file
moonswift --version         print version and exit
moonswift --help            print this help and exit
```

A bare invocation opens the current working directory as a project root. If
the directory does not contain a `moonswift.toml`, the TUI offers to create
one.

Passing a directory opens that directory as the project root. The directory
must contain (or will be offered to contain) a `moonswift.toml`.

Passing a `.lua` file enters **quick-file mode**: the TUI loads that single
file without a project context. No `moonswift.toml` is read or required. Run
and lint work normally; structured-file features are unavailable.

Only one argument is accepted. Multiple arguments, unknown flags, or
non-`.lua` file paths all result in exit code 64.

## Flags

| Flag | Short | Action |
|------|-------|--------|
| `--version` | `-V` | Print `moonswift 0.1.0` to stdout and exit 0 |
| `--help` | `-h` | Print the usage text to stdout and exit 0 |

## Exit codes

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `EX_OK` | Normal exit — the user quit gracefully |
| 64 | `EX_USAGE` | Usage error — unrecognised flag, too many arguments |
| 65 | `EX_DATAERR` | Project-file or source error that is fatal in non-TUI contexts |
| 70 | `EX_SOFTWARE` | Internal error — FFI failure or invariant violation |

Exit code 65 (`EX_DATAERR`) is produced when a project-file or source error
is encountered in a context where the TUI cannot recover — for example when
the binary is invoked purely for its exit status in a script. In interactive
TUI operation the same errors are surfaced as diagnostics without exiting.

The codes follow the `sysexits(3)` convention used by macOS system tools.

## Environment variables

| Variable | Effect |
|----------|--------|
| `NO_COLOR` | Disable all color output. Box-drawing characters are kept; severity is shown with character prefixes (`E`/`W`). Any value (including empty string) activates this mode, per [no-color.org](https://no-color.org). |
| `MOONSWIFT_LOG` | Log verbosity: `error` (default), `info`, `debug`. Logs are written to `~/Library/Logs/moonswift/moonswift.log`. |

The following variables affect builds and tests (contributors):

| Variable | Effect |
|----------|--------|
| `MOONSWIFT_SHIM_SOURCE` | Set to `1` to link the Rust shim from source (`rust/ratatui-ffi/`). Required for contributor builds via `make build`. |
| `LUASWIFT_INCLUDE_TOMLKIT` | Set to `1` to include the `luaswift.toml` module. Required at build time; exported automatically by `make`. |
