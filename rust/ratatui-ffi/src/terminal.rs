// File: rust/ratatui-ffi/src/terminal.rs
// Role: Terminal lifecycle — init, teardown, suspend, resume, and the
//       emergency restore primitive callable from signal handlers.
//       Every entry point follows the rffi_ naming convention and returns i32
//       (0 = ok, negative = error code; see error.rs).
//
// Design (ARCHITECTURE.md §3f, §5.2):
//   - rffi_terminal_init: enter raw mode + alternate screen, save the
//     original termios and the tty fd in lock-free AtomicI32/OnceLock
//     statics, then set the atomic `INITIALIZED` flag.
//   - rffi_terminal_teardown: reverse of init (leave alt screen, restore
//     termios). Does NOT clear INITIALIZED so rffi_emergency_restore remains
//     safe to call after teardown.
//   - rffi_terminal_suspend / rffi_terminal_resume: the $EDITOR handoff path
//     (pump-park bracketed leave/re-enter; ARCHITECTURE.md §5.2).
//   - rffi_emergency_restore: async-signal-safe best-effort restore. Reads
//     INITIALIZED with an atomic load (signal-safe). Uses only write(2) for
//     the escape sequences and best-effort tcsetattr for the termios. Returns
//     nothing, stores nothing — exempt from the error protocol.
//
// Thread-safety: init/teardown/suspend/resume are render/terminal-class
// (UI thread only). rffi_emergency_restore is signal-safe and lock-free.
//
// Upstream: crossterm, libc, std::sync::atomic
// Downstream: lib.rs (re-exports), C header (rffi_terminal_* section)

use crate::error::{RFFI_ERR_IO, RFFI_ERR_NOT_INIT};
use crate::ffi_guard;
use crate::guard::set_last_error;
use crossterm::{
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io::{stdout, Stdout};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::OnceLock;

// ---------------------------------------------------------------------------
// Lock-free static storage for emergency restore
// ---------------------------------------------------------------------------

/// Whether rffi_terminal_init has completed. Checked by rffi_emergency_restore
/// with an atomic load — the only async-signal-safe access pattern.
static INITIALIZED: AtomicBool = AtomicBool::new(false);

/// The tty file descriptor saved at init time (POSIX fileno(stdout)).
/// -1 = not yet set.
static TTY_FD: AtomicI32 = AtomicI32::new(-1);

/// The original termios captured at init time.
/// OnceLock is initialised once by rffi_terminal_init.
static SAVED_TERMIOS: OnceLock<libc::termios> = OnceLock::new();

// ---------------------------------------------------------------------------
// Terminal handle (heap-allocated, pointer handed to Swift)
// ---------------------------------------------------------------------------

use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

/// Heap-allocated terminal handle. Swift receives an opaque `*mut RffiTerminal`
/// and passes it back on every render/terminal-class call.
pub struct RffiTerminal {
    pub(crate) terminal: Terminal<CrosstermBackend<Stdout>>,
}

// ---------------------------------------------------------------------------
// Helper: save termios + fd for emergency restore
// ---------------------------------------------------------------------------

/// Capture the current termios from the tty fd and store both in the statics.
/// Called once from rffi_terminal_init before INITIALIZED is set.
#[cfg(unix)]
fn save_termios_and_fd() {
    use std::os::unix::io::AsRawFd;
    let fd = stdout().as_raw_fd();
    TTY_FD.store(fd, Ordering::Release);

    let _ = SAVED_TERMIOS.get_or_init(|| {
        // SAFETY: fd is our own tty; zeroed termios is a valid initialiser.
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        unsafe {
            libc::tcgetattr(fd, &mut t);
        }
        t
    });
}

#[cfg(not(unix))]
fn save_termios_and_fd() {
    // Non-Unix: no-op (emergency restore is a no-op too).
}

// ---------------------------------------------------------------------------
// rffi_terminal_init
// ---------------------------------------------------------------------------

/// Enter raw mode, switch to the alternate screen, hide the cursor, save the
/// original termios and tty fd for emergency restore, and set the `INITIALIZED`
/// flag that arms rffi_emergency_restore.
///
/// Returns a heap-allocated `*mut RffiTerminal` cast to `*mut ()`. Swift stores
/// this opaque pointer and passes it back on every render-class call.
/// Returns NULL on failure (error detail in rffi_last_error).
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_terminal_init() -> *mut () {
    // Save state before INITIALIZED is set — order matters.
    save_termios_and_fd();

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut out = stdout();
        if let Err(e) = enable_raw_mode() {
            set_last_error(format!("rffi_terminal_init: enable_raw_mode: {e}"));
            return std::ptr::null_mut();
        }
        if let Err(e) = execute!(out, EnterAlternateScreen) {
            let _ = disable_raw_mode();
            set_last_error(format!("rffi_terminal_init: EnterAlternateScreen: {e}"));
            return std::ptr::null_mut();
        }
        let backend = CrosstermBackend::new(out);
        match Terminal::new(backend) {
            Ok(mut term) => {
                let _ = term.hide_cursor();
                let _ = term.clear();
                let handle = Box::new(RffiTerminal { terminal: term });
                INITIALIZED.store(true, Ordering::Release);
                Box::into_raw(handle) as *mut ()
            }
            Err(e) => {
                let _ = execute!(stdout(), LeaveAlternateScreen);
                let _ = disable_raw_mode();
                set_last_error(format!("rffi_terminal_init: Terminal::new: {e}"));
                std::ptr::null_mut()
            }
        }
    }));

    match result {
        Ok(ptr) => ptr,
        Err(payload) => {
            let msg = crate::guard::panic_message(payload);
            set_last_error(format!("rffi_terminal_init: panic: {msg}"));
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// rffi_terminal_teardown
// ---------------------------------------------------------------------------

/// Leave the alternate screen, show the cursor, restore termios, and free the
/// terminal handle. After this call the pointer is invalid.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_terminal_teardown(handle: *mut ()) -> i32 {
    ffi_guard!("rffi_terminal_teardown", {
        if handle.is_null() {
            set_last_error("rffi_terminal_teardown: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let mut boxed = unsafe { Box::from_raw(handle as *mut RffiTerminal) };
        let _ = boxed.terminal.show_cursor();
        if let Err(e) = execute!(stdout(), LeaveAlternateScreen) {
            set_last_error(format!("rffi_terminal_teardown: LeaveAlternateScreen: {e}"));
            return RFFI_ERR_IO;
        }
        if let Err(e) = disable_raw_mode() {
            set_last_error(format!("rffi_terminal_teardown: disable_raw_mode: {e}"));
            return RFFI_ERR_IO;
        }
        drop(boxed);
        0
    })
}

// ---------------------------------------------------------------------------
// rffi_terminal_suspend / rffi_terminal_resume
// ---------------------------------------------------------------------------

/// Suspend the terminal for the $EDITOR handoff: leave the alternate screen
/// and restore termios WITHOUT clearing INITIALIZED. The pump must be parked
/// before this call (ARCHITECTURE.md §5.2 pump-park handshake).
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_terminal_suspend(handle: *mut ()) -> i32 {
    ffi_guard!("rffi_terminal_suspend", {
        if handle.is_null() {
            set_last_error("rffi_terminal_suspend: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if !INITIALIZED.load(Ordering::Acquire) {
            set_last_error("rffi_terminal_suspend: terminal not initialised");
            return RFFI_ERR_NOT_INIT;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let _ = t.terminal.show_cursor();
        if let Err(e) = execute!(stdout(), LeaveAlternateScreen) {
            set_last_error(format!("rffi_terminal_suspend: LeaveAlternateScreen: {e}"));
            return RFFI_ERR_IO;
        }
        if let Err(e) = disable_raw_mode() {
            set_last_error(format!("rffi_terminal_suspend: disable_raw_mode: {e}"));
            return RFFI_ERR_IO;
        }
        0
    })
}

/// Resume after the editor returns: re-enter raw mode and the alternate
/// screen. Unparks the pump after this returns (Swift side orchestrates).
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_terminal_resume(handle: *mut ()) -> i32 {
    ffi_guard!("rffi_terminal_resume", {
        if handle.is_null() {
            set_last_error("rffi_terminal_resume: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if !INITIALIZED.load(Ordering::Acquire) {
            set_last_error("rffi_terminal_resume: terminal not initialised");
            return RFFI_ERR_NOT_INIT;
        }
        if let Err(e) = enable_raw_mode() {
            set_last_error(format!("rffi_terminal_resume: enable_raw_mode: {e}"));
            return RFFI_ERR_IO;
        }
        if let Err(e) = execute!(stdout(), EnterAlternateScreen) {
            let _ = disable_raw_mode();
            set_last_error(format!("rffi_terminal_resume: EnterAlternateScreen: {e}"));
            return RFFI_ERR_IO;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let _ = t.terminal.hide_cursor();
        if let Err(e) = t.terminal.clear() {
            set_last_error(format!("rffi_terminal_resume: clear: {e}"));
            return RFFI_ERR_IO;
        }
        0
    })
}

// ---------------------------------------------------------------------------
// rffi_emergency_restore — async-signal-safe, exempt from error protocol
// ---------------------------------------------------------------------------

/// Emergency terminal restore callable from signal handlers (ARCHITECTURE.md
/// §3f, §5.2). Performs:
///   1. Atomic read of INITIALIZED — if false, returns immediately (no-op).
///   2. write(2) of `ESC[?1049l ESC[?25h ESC[0m` to the saved tty fd.
///   3. best-effort tcsetattr to restore the saved termios.
///
/// This function:
///   - Returns nothing and stores nothing (no thread-local, no allocation).
///   - Uses only async-signal-safe primitives (write(2) is safe; tcsetattr
///     is technically not, but the worst case is a silent no-op).
///   - Is a guarded no-op until rffi_terminal_init sets INITIALIZED.
///
/// Never call this from normal code paths; it is the crash-path primitive.
#[no_mangle]
pub extern "C" fn rffi_emergency_restore() {
    // Async-signal-safe atomic check — is the terminal even initialised?
    if !INITIALIZED.load(Ordering::Acquire) {
        return;
    }

    let fd = TTY_FD.load(Ordering::Acquire);
    if fd < 0 {
        return;
    }

    // ESC[?1049l — leave alternate screen
    // ESC[?25h  — show cursor
    // ESC[0m    — reset attributes
    #[cfg(unix)]
    {
        let seq = b"\x1b[?1049l\x1b[?25h\x1b[0m";
        unsafe {
            libc::write(fd, seq.as_ptr() as *const libc::c_void, seq.len());
        }

        // Best-effort termios restore — not signal-safe but best-effort.
        if let Some(saved) = SAVED_TERMIOS.get() {
            unsafe {
                libc::tcsetattr(fd, libc::TCSANOW, saved);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// rffi_terminal_size
// ---------------------------------------------------------------------------

/// Query the current terminal dimensions. Returns 0 and writes into
/// *cols_out / *rows_out on success.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_terminal_size(cols_out: *mut u16, rows_out: *mut u16) -> i32 {
    ffi_guard!("rffi_terminal_size", {
        if cols_out.is_null() || rows_out.is_null() {
            set_last_error("rffi_terminal_size: null output pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        match crossterm::terminal::size() {
            Ok((w, h)) => {
                unsafe {
                    *cols_out = w;
                    *rows_out = h;
                }
                0
            }
            Err(e) => {
                set_last_error(format!("rffi_terminal_size: {e}"));
                RFFI_ERR_IO
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// rffi_terminal_size with null pointers must return an error, not crash.
    #[test]
    fn terminal_size_null_pointers_returns_error() {
        let code = rffi_terminal_size(std::ptr::null_mut(), std::ptr::null_mut());
        assert!(code < 0);
    }

    /// rffi_terminal_teardown with a null handle must return an error code.
    #[test]
    fn teardown_null_handle_returns_error() {
        let code = rffi_terminal_teardown(std::ptr::null_mut());
        assert!(code < 0);
    }

    /// rffi_terminal_suspend with null handle must return an error code.
    #[test]
    fn suspend_null_handle_returns_error() {
        let code = rffi_terminal_suspend(std::ptr::null_mut());
        assert!(code < 0);
    }

    /// rffi_emergency_restore is a no-op before init — must not crash.
    #[test]
    fn emergency_restore_is_noop_before_init() {
        // In the test process the terminal is never initialised, so this is
        // a pure no-op. We only verify it does not panic.
        rffi_emergency_restore();
    }
}
