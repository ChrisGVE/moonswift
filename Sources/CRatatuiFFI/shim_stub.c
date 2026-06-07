// File: Sources/CRatatuiFFI/shim_stub.c
// Role: Minimal translation unit for the CRatatuiFFI C target (source mode,
//       MOONSWIFT_SHIM_SOURCE=1). SPM requires a C target to contain at least
//       one compilable source file; this file exists solely to satisfy that.
//
//       It deliberately defines NO rffi_* symbols: every function declared in
//       ratatui_ffi.h is implemented by the Rust static library
//       (rust/ratatui-ffi/target/release/libratatui_ffi.a) linked via the
//       linkerSettings in Package.swift. Defining stub bodies here would
//       conflict with the real implementations (duplicate symbols at link
//       time, signature drift at compile time).
//
//       If `make shim` has not been run before `swift build`, the link step
//       fails with a missing-library error. Run `make shim` (or `make build`)
//       first — ARCHITECTURE.md §5.4 bootstrap rule, PRD F0.3.
//
// Upstream: ratatui_ffi.h (ABI declarations)
// Downstream: CRatatuiFFI module (C target, source mode)

#include "ratatui_ffi.h"

// Non-exported marker so this translation unit is never empty.
static const int moonswift_cratatuiffi_stub_marker = 0;

const int *moonswift_cratatuiffi_stub(void) {
  return &moonswift_cratatuiffi_stub_marker;
}
