// File: Sources/CRatatuiFFI/shim_stub.c
// Role: Compile-time stub for source mode (MOONSWIFT_SHIM_SOURCE=1).
//       Provides empty-body definitions of every function declared in
//       ratatui_ffi.h so that SPM can compile CRatatuiFFI without the Rust
//       static library present. The real implementations are supplied at link
//       time by rust/ratatui-ffi/target/release/libratatui_ffi.a via the
//       linkerSettings in Package.swift.
//
//       IMPORTANT: These stubs must never be called. Their only purpose is to
//       satisfy the Swift compiler's requirement that a C target contains at
//       least one compilable source file. At runtime the linker resolves every
//       symbol to the Rust implementation; the stub bodies are dead code.
//
//       If `make shim` has not been run before `swift build`, the link step
//       will fail with a missing-library error. Run `make shim` first
//       (ARCHITECTURE.md §5.4 bootstrap rule, F0.3).
//
// Upstream: ratatui_ffi.h (stub ABI mirror)
// Downstream: CRatatuiFFI module (compiled as a C target in source mode)

#include "ratatui_ffi.h"

// Error protocol
int32_t rffi_last_error(char *buf, size_t cap) {
  (void)buf;
  (void)cap;
  return -1;
}

// Terminal lifecycle
int32_t rffi_terminal_init(void) { return -1; }
int32_t rffi_terminal_teardown(void) { return -1; }
int32_t rffi_terminal_suspend(void) { return -1; }
int32_t rffi_terminal_resume(void) { return -1; }
void rffi_emergency_restore(void) {}

// Event pump
int32_t rffi_poll_event(RffiEvent *out, int32_t timeout_ms) {
  (void)out;
  (void)timeout_ms;
  return -1;
}

// Rendering
int32_t rffi_flush(void) { return -1; }

int32_t rffi_write_cells(uint16_t start_col, uint16_t start_row,
                         const char *text, size_t text_len, uint32_t fg,
                         uint32_t bg, uint8_t bold, uint8_t italic,
                         uint8_t underline) {
  (void)start_col;
  (void)start_row;
  (void)text;
  (void)text_len;
  (void)fg;
  (void)bg;
  (void)bold;
  (void)italic;
  (void)underline;
  return -1;
}

int32_t rffi_clear_rect(uint16_t col, uint16_t row, uint16_t width,
                        uint16_t height) {
  (void)col;
  (void)row;
  (void)width;
  (void)height;
  return -1;
}

int32_t rffi_terminal_size(uint16_t *cols_out, uint16_t *rows_out) {
  (void)cols_out;
  (void)rows_out;
  return -1;
}
