# ratatui-ffi — MoonSwift vendored fork

This directory is a vendored fork of [holo-q/ratatui-ffi] used internally by
MoonSwift as the Rust side of its terminal (TUI) layer.

**This is not a standalone library.** It is built as part of the MoonSwift
toolchain via `make shim` and consumed by the Swift `CRatatuiFFI` module.
See `ARCHITECTURE.md §5.2/§5.4` and `PRD §4.5` for the full design rationale.

## Origin and pin

| Field         | Value                                                          |
|---------------|----------------------------------------------------------------|
| Upstream      | https://github.com/holo-q/ratatui-ffi                         |
| Tag           | v0.2.6                                                         |
| Pinned commit | 56858ea9dfe0d6ea2a6aa37f024921e01e07b956                       |
| ratatui       | 0.29 (pinned to this minor)                                    |
| crossterm     | 0.28.1 (the version ratatui 0.29 uses internally)              |
| License       | MIT OR Apache-2.0 (see LICENSE-MIT, LICENSE-APACHE)            |

## What this fork changes

Modifications on top of v0.2.6 are tracked in the git history starting from
the vendor commit (recorded in `NOTICE`). Current differences from upstream:

- **cargo fmt** applied (project pre-commit hook; no logic change).
- **crate-type**: `["cdylib", "staticlib"]` — `staticlib` added so the Swift
  package can consume a universal static lib wrapped in an XCFramework
  `binaryTarget` (upstream only builds `cdylib`).
- **crossterm**: updated from `"0.27"` to `"0.28.1"` to match ratatui 0.29's
  internal dependency — a single crossterm in the link graph is required
  (ARCH §5.4).
- **libc**: added as an explicit dependency for async-signal-safe emergency
  restore (`write(2)`, `tcsetattr`, `termios`) on Unix.
- **Full surface restructure** (task 8, 2026-06-07):
  - `rffi_` naming convention on all `extern "C"` entry points.
  - `error.rs`: `RFFI_ERR_*` i32 constants (see `docs/internals/ffi-boundary.md`).
  - `guard.rs`: `ffi_guard!` / `ffi_guard_ptr!` macros; process-global
    last-error string (`Mutex<String>` — deliberate TLS avoidance for arm64e
    PAC compatibility); `rffi_last_error` C accessor.
  - `terminal.rs`: `rffi_terminal_init` (returns opaque `*mut ()`),
    `rffi_terminal_teardown`, `rffi_terminal_suspend`, `rffi_terminal_resume`,
    `rffi_terminal_size`, and `rffi_emergency_restore` (lock-free, void,
    async-signal-safe).
  - `events.rs`: `rffi_poll_event` with EINTR retry; `RffiEvent` struct with
    a 4096-byte inline `paste_buf` for bracketed-paste (fork addition).
  - `cells.rs`: `rffi_write_cells` (contiguous grapheme-cluster run),
    `rffi_clear_rect`, `rffi_flush`.
  - `layout.rs`: `rffi_layout_split`, `RffiRect`.
  - `widgets/`: `RffiList`, `RffiParagraph`, `RffiTabs`, `RffiStyle`,
    `RffiSpan`, `rffi_clear_rect_widget`.
  - `lib.rs`: wiring, module declarations, public re-exports.
- **Surface trim** (PRD §4.5): Table, Chart, BarChart, Sparkline,
  Gauge/LineGauge, Canvas, Scrollbar, and logo/mascot widgets deleted.

## Building

From the MoonSwift repo root:

```bash
make shim          # cargo build --release + cbindgen header gen + artifact copy
```

Direct build (for development/testing):

```bash
cargo build --release
cargo test
```

The `target/release/libratatui_ffi.a` static lib and the generated
`include/ratatui_ffi.h` header are the artifacts consumed by `CRatatuiFFI`.

## Pin policy and upgrade procedure

Upgrades are deliberate, dedicated tasks — never opportunistic.

**When to upgrade:** only when ratatui releases a minor that fixes a required
bug or adds a needed surface, and only as a planned task.

**How to upgrade:**

1. Record the target tag and its commit hash.
2. Re-apply each modification listed above as intent against the new source;
   do not diff-merge mechanically.
3. Update the crossterm pin to match the new ratatui minor's internal version
   (check the new `ratatui` Cargo.toml).
4. Update NOTICE with the new commit hash and date.
5. Run `cargo build --release` and `cargo test`; verify the CI suite.
6. Commit as a single vendor commit followed by per-modification commits.

**Reference point:** the commit hash in the Origin table above is the base for
the next upgrade diff.

## License

holo-q/ratatui-ffi is dual-licensed MIT OR Apache-2.0. Full texts:

- [LICENSE-MIT](./LICENSE-MIT)
- [LICENSE-APACHE](./LICENSE-APACHE)

Attribution: [NOTICE](./NOTICE)

[holo-q/ratatui-ffi]: https://github.com/holo-q/ratatui-ffi
