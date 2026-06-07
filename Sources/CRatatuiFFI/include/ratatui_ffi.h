// File: Sources/CRatatuiFFI/include/ratatui_ffi.h
// Role: Umbrella header for the CRatatuiFFI C module. In production builds
//       (after F0.5) this file is replaced by the cbindgen-generated header
//       produced by `make shim` (F0.3). During bootstrap (source mode,
//       MOONSWIFT_SHIM_SOURCE=1) it is this hand-authored stub that declares
//       the full C ABI so RatatuiKit can compile without the Rust artifact.
//
//       The ABI follows the error protocol (ARCHITECTURE.md §5.2):
//         - Every entry point returns int32_t: 0 = ok, nonzero = error code.
//         - Error detail lives in a thread-local string retrieved by
//           rffi_last_error(buf, cap).
//         - rffi_emergency_restore() is the single deliberate exception:
//           no return value, no thread-local, callable from signal handlers.
//
// Upstream: rust/ratatui-ffi (stub until F0.2 vendors the fork; replaced by
//           cbindgen output at F0.3)
// Downstream: RatatuiKit (sole consumer of this header)

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Error protocol (ARCHITECTURE.md §5.2)
// ---------------------------------------------------------------------------

/// Copy the thread-local last-error string into buf (at most cap-1 bytes,
/// NUL-terminated). Returns the number of bytes written (excluding NUL), or
/// -1 if buf is NULL or cap is 0.
int32_t rffi_last_error(char *buf, size_t cap);

// ---------------------------------------------------------------------------
// Terminal lifecycle — render/terminal-class (UI thread only)
// ---------------------------------------------------------------------------

/// Enter raw mode, switch to the alternate screen, save the original termios
/// and tty fd in lock-free static storage, and set the atomic `initialized`
/// flag that arms rffi_emergency_restore (ARCHITECTURE.md §3f).
int32_t rffi_terminal_init(void);

/// Leave the alternate screen, show the cursor, and restore the saved termios.
int32_t rffi_terminal_teardown(void);

/// Suspend the terminal for $EDITOR handoff: leave alternate screen and
/// restore termios without clearing the initialized flag.
int32_t rffi_terminal_suspend(void);

/// Resume after $EDITOR returns: re-enter raw mode and the alternate screen.
int32_t rffi_terminal_resume(void);

/// Emergency terminal restore callable from signal handlers. Performs a raw
/// write of reset sequences and best-effort tcsetattr. Is a guarded no-op
/// until rffi_terminal_init sets the initialized flag (async-signal-safe
/// atomic read). No return value, no thread-local, no locks, no allocation
/// (ARCHITECTURE.md §3f, §5.2).
void rffi_emergency_restore(void);

// ---------------------------------------------------------------------------
// Event pump — input-class (EventPump thread only)
// ---------------------------------------------------------------------------

/// Opaque event type tag. Matches the FfiEvent discriminant in the Rust shim.
typedef int32_t RffiEventKind;

/// Decoded keyboard/mouse event. Layout matches the cbindgen output.
typedef struct {
  RffiEventKind kind;
  uint32_t key_code;
  uint8_t modifiers;
  uint8_t _pad[3];
} RffiEvent;

/// Poll for the next terminal event, blocking for at most timeout_ms
/// milliseconds. Returns 0 and writes into *out if an event is available;
/// returns 1 if the timeout elapsed with no event; returns a negative error
/// code on failure. Retries internally on EINTR (ARCHITECTURE.md §5.2).
int32_t rffi_poll_event(RffiEvent *out, int32_t timeout_ms);

// ---------------------------------------------------------------------------
// Rendering — render/terminal-class (UI thread only)
// ---------------------------------------------------------------------------

/// Flush the current ratatui frame to the terminal (diff + write).
int32_t rffi_flush(void);

/// Write a run of cells with uniform style. start_col/start_row are 0-based.
/// text is a UTF-8 string of exactly cell_count grapheme clusters.
/// fg/bg are RGB triples packed as 0x00RRGGBB; 0xFFFFFFFF = terminal default.
int32_t rffi_write_cells(uint16_t start_col, uint16_t start_row,
                         const char *text, size_t text_len, uint32_t fg,
                         uint32_t bg, uint8_t bold, uint8_t italic,
                         uint8_t underline);

/// Clear a rectangular region to the default style.
int32_t rffi_clear_rect(uint16_t col, uint16_t row, uint16_t width,
                        uint16_t height);

/// Query the current terminal dimensions.
int32_t rffi_terminal_size(uint16_t *cols_out, uint16_t *rows_out);

#ifdef __cplusplus
} // extern "C"
#endif
