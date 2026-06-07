// File: rust/ratatui-ffi/src/error.rs
// Role: i32 error-code constants returned by every rffi_* entry point.
//       0 = ok; negative codes = error. Positive 1 is the "timeout, no event"
//       sentinel for rffi_poll_event (ARCHITECTURE.md §5.2).
//
// Upstream: nothing — pure constants
// Downstream: guard.rs (RFFI_ERR_PANIC), terminal.rs, events.rs, cells.rs,
//             layout.rs, widgets/*.rs, C header (rffi_errors section)

// ---------------------------------------------------------------------------
// Success / timeout sentinels
// ---------------------------------------------------------------------------

/// Returned by rffi_poll_event when the timeout elapsed with no event.
/// (Positive, distinct from error codes which are all negative.)
pub const RFFI_TIMEOUT: i32 = 1;

// ---------------------------------------------------------------------------
// Error codes (all negative)
// ---------------------------------------------------------------------------

/// Null pointer passed to an entry point that requires a valid pointer.
pub const RFFI_ERR_NULL_PTR: i32 = -1;

/// A Rust panic occurred inside an ffi_guard!() body. The panic message is
/// available via rffi_last_error().
pub const RFFI_ERR_PANIC: i32 = -2;

/// An I/O error from crossterm or the OS (raw-mode toggle, write, etc.).
pub const RFFI_ERR_IO: i32 = -3;

/// Terminal is not initialised; rffi_terminal_init must be called first.
pub const RFFI_ERR_NOT_INIT: i32 = -4;

/// An internal size or bounds overflow.
pub const RFFI_ERR_OVERFLOW: i32 = -5;

/// Invalid argument (misaligned pointer, zero capacity, invalid UTF-8, etc.).
pub const RFFI_ERR_INVALID_ARG: i32 = -6;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_is_positive() {
        // rffi_poll_event callers check `ret == RFFI_TIMEOUT` for the
        // no-event case; it must be strictly positive.
        assert!(RFFI_TIMEOUT > 0);
    }

    #[test]
    fn error_codes_are_negative() {
        let codes = [
            RFFI_ERR_NULL_PTR,
            RFFI_ERR_PANIC,
            RFFI_ERR_IO,
            RFFI_ERR_NOT_INIT,
            RFFI_ERR_OVERFLOW,
            RFFI_ERR_INVALID_ARG,
        ];
        for &c in &codes {
            assert!(c < 0, "error code {c} must be negative");
        }
    }

    #[test]
    fn error_codes_are_distinct() {
        let codes = [
            RFFI_ERR_NULL_PTR,
            RFFI_ERR_PANIC,
            RFFI_ERR_IO,
            RFFI_ERR_NOT_INIT,
            RFFI_ERR_OVERFLOW,
            RFFI_ERR_INVALID_ARG,
            RFFI_TIMEOUT,
        ];
        // All codes must be unique.
        let mut seen = std::collections::HashSet::new();
        for &c in &codes {
            assert!(seen.insert(c), "duplicate error code {c}");
        }
    }
}
