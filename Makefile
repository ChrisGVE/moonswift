# Makefile — MoonSwift
#
# Location: repo root (MoonSwift/)
# Role: orchestrates the two-phase build: Rust shim first, then Swift package.
#       All build/test targets export LUASWIFT_INCLUDE_TOMLKIT=1 (controlled
#       build paths always carry the toml module; plain `swift build` without
#       the variable still produces a working binary — ARCHITECTURE.md §5.4).
#       Source mode (MOONSWIFT_SHIM_SOURCE=1) is the contributor default during
#       bootstrap, before the first shim release (ARCHITECTURE.md §5.4
#       bootstrap rule).
#
# Environment variables propagated to every Swift invocation:
#   MOONSWIFT_SHIM_SOURCE=1    — use the stub C target + linker flags
#   LUASWIFT_INCLUDE_TOMLKIT=1 — include the luaswift.toml module

# Repository root and Rust shim path, both resolved relative to this file so
# the Makefile works regardless of the working directory `make` is invoked from.
REPO_ROOT  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SHIM_DIR   := $(REPO_ROOT)/rust/ratatui-ffi

# The cbindgen-generated header and the module map live in CRatatuiFFI's
# include directory; `make shim` copies the freshly generated header there.
FFI_HEADER_SRC := $(SHIM_DIR)/include/ratatui_ffi.h
FFI_HEADER_DST := $(REPO_ROOT)/Sources/CRatatuiFFI/include/ratatui_ffi.h

# Environment exported to every Swift invocation in this file.
export MOONSWIFT_SHIM_SOURCE  := 1
export LUASWIFT_INCLUDE_TOMLKIT := 1

# Phony targets have no corresponding files; always re-run when requested.
.PHONY: build test clean reset shim

# ── shim ──────────────────────────────────────────────────────────────────────
# Build the Rust static library and regenerate the cbindgen header.
#
# Steps:
#   1. cargo build --release --features swift_ffi
#                     — produces libratatui_ffi.a in target/release/
#                       with the swift_ffi feature enabled: ffi_guard! omits
#                       catch_unwind so Rust's unwind TLS (LOCAL_PANIC_COUNT)
#                       is never referenced from compiled objects, eliminating
#                       arm64e SIGBUS from PAC-unsigned tlv_bootstrap pointers
#                       (ARCHITECTURE.md §5.4 arm64-TLS, guard.rs §note).
#   2. cbindgen               — regenerates ratatui_ffi.h from the Rust sources
#                               and copies it into Sources/CRatatuiFFI/include/.
#                               Treated as best-effort: if cbindgen fails (e.g.
#                               version incompatibility with the Rust source),
#                               the build continues with the committed header.
#                               The committed header at Sources/CRatatuiFFI/include/
#                               is the source-of-record ABI; regeneration is only
#                               required when the Rust ABI changes.
#
# cbindgen must be installed (`cargo install cbindgen`) for header regeneration;
# the underlying cargo build succeeds regardless of cbindgen availability.
shim:
	@echo "==> Building Rust shim (cargo build --release --features swift_ffi)"
	cd $(SHIM_DIR) && cargo build --release --features swift_ffi
	@echo "==> Regenerating FFI header (cbindgen, best-effort)"
	@if cbindgen --config $(SHIM_DIR)/cbindgen.toml \
	             --output $(FFI_HEADER_SRC) \
	             $(SHIM_DIR) 2>/dev/null; then \
	    echo "==> Copying regenerated header to Sources/CRatatuiFFI/include/"; \
	    cp $(FFI_HEADER_SRC) $(FFI_HEADER_DST); \
	else \
	    echo "WARN: cbindgen failed — using committed header (Sources/CRatatuiFFI/include/ratatui_ffi.h)"; \
	    echo "WARN: If you changed the Rust ABI, fix cbindgen compatibility before committing."; \
	fi
	@echo "==> Shim ready: $(SHIM_DIR)/target/release/libratatui_ffi.a"

# ── build ─────────────────────────────────────────────────────────────────────
# Full contributor build: Rust shim first, then the Swift package in source mode.
#
# `swift package reset` runs before `swift build` to clear SPM's manifest-
# evaluation cache. This is mandatory when MOONSWIFT_SHIM_SOURCE is toggled:
# without it, SPM may silently reuse a stale binaryTarget declaration from a
# previous plain `swift build` — `purge-cache` clears only the global download
# cache and would not help here (ARCHITECTURE.md §5.4 manifest-cache rule).
build: shim reset
	@echo "==> Building Swift package (source mode, toml enabled)"
	swift build

# ── test ──────────────────────────────────────────────────────────────────────
# Full test run: Rust unit tests, then the Swift test suite in source mode.
#
# `swift package reset` is included here for the same manifest-cache reason as
# `make build`; contributors switching between build modes invoke `make test`
# without a prior `make build`, so the reset guard belongs in both targets.
# cargo test runs single-threaded: the shim's last-error slot is process-global
# by design (single-UI-thread library; avoids TLS for arm64e — guard.rs §note),
# so concurrent test threads race on set/clear of the shared slot.
test:
	@echo "==> Running Rust unit tests (cargo test)"
	cd $(SHIM_DIR) && cargo test -- --test-threads=1
	@echo "==> Resetting SPM manifest cache"
	swift package reset
	@echo "==> Running Swift tests (source mode, toml enabled)"
	# --no-parallel mirrors CI: the DriverIntegration tests spawn an AppDriver
	# run loop whose engine effects run as Tasks on the global cooperative pool;
	# Swift Testing's default cross-suite parallelism can starve that pool and
	# flake the dispatch assertions. Serial execution keeps it deterministic so
	# a local `make test` reproduces the CI result. See ci.yml (TUI leg note).
	swift test --no-parallel

# ── reset ─────────────────────────────────────────────────────────────────────
# Clear SPM's manifest-evaluation cache (.build directory).
#
# Required when toggling MOONSWIFT_SHIM_SOURCE between source mode and
# binaryTarget mode: SPM caches the manifest evaluation result, so a stale
# cache can silently build the wrong shim topology. `swift package reset`
# targets exactly this cache — unlike `swift package purge-cache`, which clears
# only the global package download cache and leaves the manifest cache intact
# (ARCHITECTURE.md §5.4).
reset:
	@echo "==> Resetting SPM manifest cache (swift package reset)"
	swift package reset

# ── clean ─────────────────────────────────────────────────────────────────────
# Remove build artifacts from both the Rust shim and the Swift package.
#
# Does NOT remove Package.resolved or the committed header in
# Sources/CRatatuiFFI/include/ — those are source-controlled artifacts.
# Run `make shim` after `make clean` to rebuild the Rust artifacts.
clean:
	@echo "==> Cleaning Rust build artifacts"
	cd $(SHIM_DIR) && cargo clean
	@echo "==> Cleaning Swift build artifacts"
	swift package clean
	@echo "==> Clean complete"
