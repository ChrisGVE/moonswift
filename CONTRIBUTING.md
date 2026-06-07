# Contributing to MoonSwift

Thank you for your interest in contributing. This document covers everything
you need to build, test, and submit changes.

---

## Build requirements

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| macOS | 13 (Ventura) | Runtime and build host |
| Xcode | 16 | Provides the Swift 6 toolchain (`swift-format` included) |
| Rust toolchain | stable (via `rustup`) | Required to build the `ratatui-ffi` shim |
| `cbindgen` | any recent | Optional — only needed when the Rust FFI ABI changes |

Install the Rust toolchain with [rustup](https://rustup.rs/):

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Install `cbindgen` if you intend to change the Rust ABI:

```sh
cargo install cbindgen
```

---

## Building

### Standard contributor build

```sh
make build   # build the Rust shim, then the Swift package (source mode)
make test    # run Rust unit tests, then the Swift test suite (source mode)
make clean   # remove Rust and Swift build artifacts
make reset   # clear SPM manifest cache (see "Manifest cache" below)
```

`make build` and `make test` both export:

- `MOONSWIFT_SHIM_SOURCE=1` — source-build mode (stub C target + linker flags
  pointing at the Rust static library). This is the contributor default during
  bootstrap, before the first XCFramework release. See ARCHITECTURE.md §5.4.
- `LUASWIFT_INCLUDE_TOMLKIT=1` — includes the `luaswift.toml` module in the
  binary.

### Shim-only build (header regeneration)

If you change the Rust ABI (`rust/ratatui-ffi/src/lib.rs`), regenerate the
C header:

```sh
make shim    # cargo build --release + cbindgen (best-effort header regen)
```

If `cbindgen` is not installed, `make shim` still builds the static library
and logs a warning; the committed header at
`Sources/CRatatuiFFI/include/ratatui_ffi.h` remains the ABI source of record.

### Manual build (without Make)

```sh
cd rust/ratatui-ffi && cargo build --release
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift build
```

---

## Manifest cache footgun

SPM caches manifest evaluation. If you previously built without
`MOONSWIFT_SHIM_SOURCE=1` and then switch to source mode (or vice versa),
run:

```sh
make reset   # equivalent to: swift package reset
```

Without the reset, SPM may silently reuse a stale shim topology — a plain
`swift build` can appear to succeed while actually linking the wrong target.
This is the single most common source of mysterious build failures. When in
doubt, reset first.

See ARCHITECTURE.md §5.4 for the full explanation.

---

## Testing

```sh
make test    # Rust unit tests (cargo test) + Swift tests (swift test)
```

Or individually:

```sh
cd rust/ratatui-ffi && cargo test
MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 swift test
```

`MoonSwiftCore` has a ≥ 85% coverage gate. CI enforces it.

---

## Format and lint

Before opening a pull request, ensure your changes pass the format and lint
gates that CI enforces:

**Rust shim:**

```sh
cd rust/ratatui-ffi
cargo fmt --check   # formatter (rustfmt)
cargo clippy -- -D warnings   # linter (treat all warnings as errors)
```

**Swift package:**

```sh
swift-format lint --recursive Sources/ Tests/
```

`swift-format` ships with the Swift 6 toolchain (Xcode 16+); no separate
install is needed. The project configuration lives in `.swift-format` at the
repository root.

**Lua sources** (vendor excluded):

```sh
stylua --check Sources/MoonSwiftCore/Vendor/luacheck/
```

Configuration: `.stylua.toml` at the repository root.

---

## Commit conventions

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `chore`, `test`, `refactor`, `perf`.

Rules:
- Subject line ≤ 50 characters, imperative mood, no trailing period.
- One logical change per commit (atomic). Do not bundle unrelated changes.
- Update `CHANGELOG.md` (under `[Unreleased]`) in the same commit as any
  user-visible change.
- No AI-attribution lines (`Co-Authored-By: …`, `Generated with …`).

---

## Pull request process

1. Fork the repository and create a branch from `main`.
2. Run `make build` and `make test` — both must be green.
3. Run the format and lint checks above — CI will reject failures.
4. Update `CHANGELOG.md` under `[Unreleased]` for any user-visible change.
5. Open a pull request against `main`. The title should be a Conventional
   Commit subject line (e.g. `feat: add JSONPath wildcard selector`).
6. CI runs on every push: Rust and Swift format checks, lint, build, and full
   test suite. All checks must pass before merge.
7. At least one maintainer review is required.

---

## Architecture overview

See [ARCHITECTURE.md](ARCHITECTURE.md) for the component map, threading model,
FFI contracts, and dependency graph.

Key boundaries to respect:

- `MoonSwiftCore` has zero terminal I/O and never imports `MoonSwiftTUI` or
  `RatatuiKit`. Domain logic lives here; it is fully unit-testable without a
  terminal.
- Only `RatatuiKit` contains FFI calls into the Rust shim. No other target
  calls `CRatatuiFFI` directly.
- Render-class FFI calls (drawing, terminal resize) belong on the UI thread.
  Input-class FFI calls (event polling) belong on the pump thread. Mixing
  them is a threading violation; `RatatuiKit` asserts the calling thread in
  debug builds.

---

## License

By contributing you agree that your changes will be released under the
[Apache 2.0](LICENSE) license.
