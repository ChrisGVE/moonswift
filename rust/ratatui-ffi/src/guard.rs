// File: rust/ratatui-ffi/src/guard.rs
// Role: Panic guard (ffi_guard macro), single-process last-error string, and
//       the rffi_last_error accessor. Every extern "C" entry point wraps its
//       body in ffi_guard!() so that errors produce an i32 error code rather
//       than undefined behaviour across the C ABI.
//
// Error protocol (ARCHITECTURE.md §5.2):
//   - Entry points return i32: 0 = ok, nonzero = error code.
//   - On error, set_last_error() stores a human-readable description.
//   - rffi_last_error(buf, cap) copies the stored string to the caller.
//
// Implementation note (arm64 / Swift interop — ARCHITECTURE.md §5.4):
//   Rust std's own thread_local! machinery (thread::current, HashMap random
//   state, panic bookkeeping) embeds $tlv$init TLS stubs in the __thread_vars
//   Mach-O section.  On macOS arm64 these stubs conflict with Swift's TLS
//   initialisation when the Rust static lib is linked into a Swift test binary,
//   causing SIGBUS.  nm -j misses them (they are local symbols); objdump --syms
//   reveals them.
//
//   To eliminate all reachable TLS from the release static lib:
//
//   1. Last-error state is stored in a single global Mutex<String> rather than
//      a HashMap<ThreadId, String>.  HashMap uses std::hash::random::RandomState
//      (TLS); thread::current().id() uses std::thread TLS.  A single mutex is
//      correct for a UI-thread-only library.
//
//   2. catch_unwind is removed from ffi_guard! in the release profile (where
//      panic = "abort" applies).  std::panicking::panic_count::LOCAL_PANIC_COUNT
//      (TLS) is pulled in only by catch_unwind.  With panic = "abort", a Rust
//      panic aborts the process immediately — visible and debuggable, not UB.
//
//   3. The dev profile retains panic = "unwind" so cargo test (dev binary) still
//      catches panics and reports them as test failures.
//
// Upstream: std::sync, std::ffi
// Downstream: every src/*.rs module that defines extern "C" entry points

use std::ffi::c_char;
use std::sync::{Mutex, OnceLock};

// ---------------------------------------------------------------------------
// Process-global last-error string
// ---------------------------------------------------------------------------
//
// A single global string rather than a per-thread map:
//   - Eliminates HashMap (which pulls in std::hash::random TLS via RandomState)
//   - Eliminates thread::current() calls (which pull in std::thread TLS)
//   - Correct for a single-UI-thread library: the caller always checks the
//     last error on the same thread that made the FFI call.
//
// The Mutex is initialised once (OnceLock) and never destroyed.

static LAST_ERROR: OnceLock<Mutex<String>> = OnceLock::new();

fn last_error() -> &'static Mutex<String> {
    LAST_ERROR.get_or_init(|| Mutex::new(String::new()))
}

/// Store an error message for the last FFI call.
///
/// Called from ffi_guard! when the body returns an error code, so that
/// rffi_last_error can retrieve the description.
pub(crate) fn set_last_error(msg: impl Into<String>) {
    if let Ok(mut s) = last_error().lock() {
        *s = msg.into();
    }
}

/// Clear the last-error slot.
///
/// Called at the entry of every ffi_guard! body so a successful call leaves
/// an empty error slot.
pub(crate) fn clear_last_error() {
    if let Ok(mut s) = last_error().lock() {
        s.clear();
    }
}

// ---------------------------------------------------------------------------
// Panic payload → human-readable string (dev profile only)
// ---------------------------------------------------------------------------
//
// In the release profile (panic = "abort") panics abort the process before
// any unwinding occurs, so this function is unreachable.  It is preserved for
// the dev profile where ffi_guard! uses catch_unwind.

#[cfg(debug_assertions)]
pub(crate) fn panic_message(payload: Box<dyn std::any::Any + Send + 'static>) -> String {
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
//
// Release profile (panic = "abort"): guard is a thin call-through.  A Rust
// panic aborts the process — intentional for a library (bug, not user error).
//
// Dev/test profile (panic = "unwind"): catch_unwind converts panics to an
// i32 error code so cargo test reports failures instead of crashing.

/// Wrap an extern "C" entry-point body in the FFI guard.
///
/// On success the body's i32 return value is propagated.
/// In debug builds (dev profile), Rust panics are caught and returned as
/// RFFI_ERR_PANIC with the panic message stored in the last-error slot.
/// In release builds (panic = "abort"), panics terminate the process.
///
/// Usage:
/// ```no_run
/// #[no_mangle]
/// pub extern "C" fn rffi_foo(x: u32) -> i32 {
///     ffi_guard!("rffi_foo", {
///         if x == 0 { set_last_error("x must be non-zero"); return -1; }
///         0
///     })
/// }
/// ```
#[macro_export]
macro_rules! ffi_guard {
    ($name:expr, $body:block) => {{
        $crate::guard::clear_last_error();
        #[cfg(debug_assertions)]
        {
            // Dev profile: catch_unwind converts panics to error codes.
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
        }
        #[cfg(not(debug_assertions))]
        {
            // Release profile (panic = "abort"): no unwind machinery needed.
            // A panic aborts the process; the guard is a transparent call-through.
            $body
        }
    }};
}

// ---------------------------------------------------------------------------
// ffi_guard_ptr! macro — for constructor functions that return *mut T
// ---------------------------------------------------------------------------

/// Like ffi_guard!, but for functions that return a raw pointer.
/// In debug builds, panics store the error and return null.
/// In release builds, panics abort the process.
///
/// Usage:
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
        #[cfg(debug_assertions)]
        {
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
        }
        #[cfg(not(debug_assertions))]
        {
            $body
        }
    }};
}

// ---------------------------------------------------------------------------
// rffi_last_error — C-visible accessor
// ---------------------------------------------------------------------------

/// Copy the last-error string into `buf` (at most `cap - 1` bytes,
/// NUL-terminated). Returns the number of bytes written (excluding NUL),
/// or -1 if `buf` is NULL or `cap` is 0.
///
/// Call this immediately after any rffi_* function returns nonzero to
/// retrieve a human-readable error description.
#[no_mangle]
pub extern "C" fn rffi_last_error(buf: *mut c_char, cap: usize) -> i32 {
    if buf.is_null() || cap == 0 {
        return -1;
    }
    let n = if let Ok(s) = last_error().lock() {
        let bytes = s.as_bytes();
        // Write at most cap-1 bytes so there is always room for the NUL.
        let n = bytes.len().min(cap - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, buf, n);
            *buf.add(n) = 0;
        }
        n as i32
    } else {
        unsafe { *buf = 0 };
        0
    };
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::RFFI_ERR_PANIC;
    use std::sync::Mutex;

    // Guard tests share the process-global LAST_ERROR; serialise them so
    // concurrent cargo test threads don't interleave set/read sequences.
    static GUARD_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn last_error_round_trip() {
        let _guard = GUARD_TEST_LOCK.lock().unwrap();
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
        // No shared state access; no lock needed.
        let n = rffi_last_error(std::ptr::null_mut(), 64);
        assert_eq!(n, -1);
    }

    #[test]
    fn last_error_zero_cap_returns_minus_one() {
        let _guard = GUARD_TEST_LOCK.lock().unwrap();
        set_last_error("x");
        let mut buf = [0u8; 1];
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, 0);
        assert_eq!(n, -1);
    }

    #[test]
    fn last_error_truncates_to_cap_minus_one() {
        let _guard = GUARD_TEST_LOCK.lock().unwrap();
        set_last_error("abcde");
        let mut buf = [0u8; 4]; // cap = 4 → max 3 bytes + NUL
        let n = rffi_last_error(buf.as_mut_ptr() as *mut c_char, buf.len());
        assert_eq!(n, 3);
        assert_eq!(buf[3], 0); // NUL terminator
        assert_eq!(&buf[..3], b"abc");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn ffi_guard_catches_panic_and_returns_error_code() {
        let _guard = GUARD_TEST_LOCK.lock().unwrap();
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
        let _guard = GUARD_TEST_LOCK.lock().unwrap();
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
