// File: rust/ratatui-ffi/src/guard.rs
// Role: Panic guard (ffi_guard macro), thread-local last-error string, and
//       the rffi_last_error accessor. Every extern "C" entry point wraps its
//       body in ffi_guard!() so that a Rust panic becomes an i32 error code
//       rather than undefined behaviour across the C ABI.
//
// Error protocol (ARCHITECTURE.md §5.2):
//   - Entry points return i32: 0 = ok, nonzero = error code.
//   - On error, set_last_error() stores a human-readable description.
//   - rffi_last_error(buf, cap) copies the stored string to the caller.
//
// Upstream: std::panic (catch_unwind), std::thread_local
// Downstream: every src/*.rs module that defines extern "C" entry points

use std::any::Any;
use std::cell::RefCell;
use std::ffi::c_char;

// ---------------------------------------------------------------------------
// Thread-local last-error string
// ---------------------------------------------------------------------------

thread_local! {
    // The last error message produced on this thread. Empty string = no error.
    static LAST_ERROR: RefCell<String> = RefCell::new(String::new());
}

/// Store an error message in the thread-local slot.
///
/// Callers inside ffi_guard!() use this when the body returns an error code
/// so that rffi_last_error can retrieve the description.
pub(crate) fn set_last_error(msg: impl Into<String>) {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = msg.into();
    });
}

/// Clear the thread-local last-error slot (called at the top of ffi_guard!
/// before running the body, so a successful call leaves an empty slot).
pub(crate) fn clear_last_error() {
    LAST_ERROR.with(|cell| {
        cell.borrow_mut().clear();
    });
}

// ---------------------------------------------------------------------------
// Panic payload → human-readable string
// ---------------------------------------------------------------------------

pub(crate) fn panic_message(payload: Box<dyn Any + Send + 'static>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}

// ---------------------------------------------------------------------------
// ffi_guard! macro
// ---------------------------------------------------------------------------

/// Wrap an extern "C" entry-point body in a catch_unwind, translating Rust
/// panics into an i32 error code and storing the panic message in the
/// thread-local last-error slot.
///
/// Usage — returns i32 (0 = ok):
///
/// ```no_run
/// #[no_mangle]
/// pub extern "C" fn rffi_foo(x: u32) -> i32 {
///     ffi_guard!("rffi_foo", {
///         // body; return 0 on success, negative code on error
///         if x == 0 { set_last_error("x must be non-zero"); return -1; }
///         0
///     })
/// }
/// ```
///
/// On panic the macro sets the last-error string and returns
/// crate::error::RFFI_ERR_PANIC.
#[macro_export]
macro_rules! ffi_guard {
    ($name:expr, $body:block) => {{
        $crate::guard::clear_last_error();
        let result = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body));
        match result {
            Ok(v) => v,
            Err(payload) => {
                let msg = $crate::guard::panic_message(payload);
                let full = ::std::format!("panic in {}: {}", $name, msg);
                $crate::guard::set_last_error(full);
                $crate::error::RFFI_ERR_PANIC
            }
        }
    }};
}

// clear_last_error is pub(crate) so ffi_guard! can call it via `$crate::guard::clear_last_error`.

// ---------------------------------------------------------------------------
// ffi_guard_ptr! macro — for constructor functions that return *mut T
// ---------------------------------------------------------------------------

/// Like ffi_guard!, but for functions that return a raw pointer.
/// On panic, stores the error in the last-error slot and returns null.
///
/// Usage:
///
/// ```no_run
/// #[no_mangle]
/// pub extern "C" fn rffi_foo_new() -> *mut Foo {
///     ffi_guard_ptr!("rffi_foo_new", {
///         Box::into_raw(Box::new(Foo::default()))
///     })
/// }
/// ```
#[macro_export]
macro_rules! ffi_guard_ptr {
    ($name:expr, $body:block) => {{
        $crate::guard::clear_last_error();
        let result = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body));
        match result {
            Ok(v) => v,
            Err(payload) => {
                let msg = $crate::guard::panic_message(payload);
                let full = ::std::format!("panic in {}: {}", $name, msg);
                $crate::guard::set_last_error(full);
                ::std::ptr::null_mut()
            }
        }
    }};
}

// ---------------------------------------------------------------------------
// rffi_last_error — C-visible accessor
// ---------------------------------------------------------------------------

/// Copy the thread-local last-error string into `buf` (at most `cap - 1`
/// bytes, NUL-terminated). Returns the number of bytes written (excluding
/// NUL), or -1 if `buf` is NULL or `cap` is 0.
///
/// Call this immediately after any rffi_* function returns nonzero to
/// retrieve a human-readable error description.
#[no_mangle]
pub extern "C" fn rffi_last_error(buf: *mut c_char, cap: usize) -> i32 {
    if buf.is_null() || cap == 0 {
        return -1;
    }
    LAST_ERROR.with(|cell| {
        let msg = cell.borrow();
        let bytes = msg.as_bytes();
        // Write at most cap-1 bytes so there is always room for the NUL.
        let n = bytes.len().min(cap - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, buf, n);
            *buf.add(n) = 0;
        }
        n as i32
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::RFFI_ERR_PANIC;

    #[test]
    fn last_error_round_trip() {
        // Store a message and retrieve it through rffi_last_error.
        set_last_error("hello error");
        let mut buf = [0u8; 64];
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        assert_eq!(n, 11);
        let got = std::str::from_utf8(&buf[..n as usize]).unwrap();
        assert_eq!(got, "hello error");
    }

    #[test]
    fn last_error_null_buf_returns_minus_one() {
        let n = rffi_last_error(std::ptr::null_mut(), 64);
        assert_eq!(n, -1);
    }

    #[test]
    fn last_error_zero_cap_returns_minus_one() {
        set_last_error("x");
        let mut buf = [0u8; 1];
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, 0);
        assert_eq!(n, -1);
    }

    #[test]
    fn last_error_truncates_to_cap_minus_one() {
        set_last_error("abcde");
        let mut buf = [0u8; 4]; // cap = 4 → max 3 bytes + NUL
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        assert_eq!(n, 3);
        assert_eq!(buf[3], 0); // NUL terminator
        assert_eq!(&buf[..3], b"abc");
    }

    #[test]
    fn ffi_guard_catches_panic_and_returns_error_code() {
        // A deliberately-panicking closure must return RFFI_ERR_PANIC and
        // populate the last-error slot — not unwind across the test.
        let code = ffi_guard!("test_entry", { panic!("deliberate panic") });
        assert_eq!(code, RFFI_ERR_PANIC);

        // The last-error slot must contain something mentioning the entry name.
        let mut buf = [0u8; 128];
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        assert!(n > 0);
        let msg = std::str::from_utf8(&buf[..n as usize]).unwrap();
        assert!(msg.contains("test_entry"), "message was: {msg}");
        assert!(msg.contains("deliberate panic"), "message was: {msg}");
    }

    #[test]
    fn ffi_guard_clears_last_error_on_success() {
        // Leave a stale error from a previous call.
        set_last_error("stale");
        let code = ffi_guard!("ok_entry", { 0 });
        assert_eq!(code, 0);
        // After a successful call the slot should be empty.
        let mut buf = [0u8; 64];
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        assert_eq!(n, 0);
    }
}
