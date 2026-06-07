// File: rust/ratatui-ffi/src/events.rs
// Role: Terminal event polling with timeout (poll-with-timeout, never blocking
//       reads), crossterm event decoding to the RffiEvent C struct, EINTR
//       retry, and bracketed-paste decoding surfaced as a new event kind.
//
// Key design points (ARCHITECTURE.md §5.2):
//   - rffi_poll_event(out, timeout_ms): returns 0 + event on hit, 1 (RFFI_TIMEOUT)
//     on timeout, negative error code on failure. Retries internally on EINTR.
//   - Bracketed-paste: crossterm exposes `Event::Paste(String)`. We map this
//     to a new RffiEventKind::Paste discriminant and store the text (up to
//     PASTE_BUF_BYTES bytes) in a dedicated field of RffiEvent.
//   - Mouse events are decoded to an RffiMouseEvent embedded in RffiEvent.
//
// Thread class: input-class (EventPump thread only).
//
// Upstream: crossterm (event poll), libc (EINTR check)
// Downstream: lib.rs (re-exports), RatatuiKit/Events.swift (sole caller)

use crate::error::{RFFI_ERR_IO, RFFI_TIMEOUT};
use crate::ffi_guard;
use crate::guard::set_last_error;
use crossterm::event::{
    Event as CtEvent, KeyCode as CtKeyCode, KeyEvent as CtKeyEvent, KeyModifiers as CtKeyModifiers,
    MouseButton as CtMouseButton, MouseEventKind as CtMouseKind,
};
use std::ffi::c_char;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Event-kind discriminants (C-visible u32)
// ---------------------------------------------------------------------------

/// Discriminant for the `kind` field of RffiEvent.
#[repr(u32)]
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum RffiEventKind {
    /// Timeout elapsed; no event. rffi_poll_event returns RFFI_TIMEOUT.
    None = 0,
    /// Keyboard event; see RffiKeyEvent fields.
    Key = 1,
    /// Terminal resize; see width/height fields.
    Resize = 2,
    /// Mouse event; see mouse_* fields.
    Mouse = 3,
    /// Bracketed-paste event (fork addition — not in upstream union).
    /// The pasted text (UTF-8) is in paste_buf / paste_len.
    Paste = 4,
}

// ---------------------------------------------------------------------------
// Key-code discriminants (C-visible u32)
// ---------------------------------------------------------------------------

#[repr(u32)]
#[derive(Copy, Clone)]
pub enum RffiKeyCode {
    Char = 0,
    Enter = 1,
    Left = 2,
    Right = 3,
    Up = 4,
    Down = 5,
    Esc = 6,
    Backspace = 7,
    Tab = 8,
    Delete = 9,
    Home = 10,
    End = 11,
    PageUp = 12,
    PageDown = 13,
    Insert = 14,
    F1 = 100,
    F2 = 101,
    F3 = 102,
    F4 = 103,
    F5 = 104,
    F6 = 105,
    F7 = 106,
    F8 = 107,
    F9 = 108,
    F10 = 109,
    F11 = 110,
    F12 = 111,
    /// Any key code not representable above (mapped to 0 in ch).
    Unknown = 255,
}

// ---------------------------------------------------------------------------
// Modifier flags (C-visible u8 bitfield)
// ---------------------------------------------------------------------------

/// Keyboard modifier flags — bitfield stored in RffiKeyEvent.modifiers.
pub mod key_mods {
    pub const NONE: u8 = 0;
    pub const SHIFT: u8 = 1 << 0;
    pub const ALT: u8 = 1 << 1;
    pub const CTRL: u8 = 1 << 2;
}

// ---------------------------------------------------------------------------
// Mouse-event kind discriminants
// ---------------------------------------------------------------------------

#[repr(u32)]
#[derive(Copy, Clone)]
pub enum RffiMouseKind {
    Down = 1,
    Up = 2,
    Drag = 3,
    Moved = 4,
    ScrollUp = 5,
    ScrollDown = 6,
}

/// Mouse button — 0 = none/unknown.
#[repr(u32)]
#[derive(Copy, Clone)]
pub enum RffiMouseButton {
    None = 0,
    Left = 1,
    Right = 2,
    Middle = 3,
}

// ---------------------------------------------------------------------------
// The RffiEvent C struct
// ---------------------------------------------------------------------------

/// Maximum bytes stored inline for a bracketed-paste payload. Pastes longer
/// than this are truncated (NUL-terminated). Swift's EventPump coalesces
/// multi-chunk pastes before passing them up; this buffer handles typical
/// single-chunk pastes (a few thousand characters at most).
pub const PASTE_BUF_BYTES: usize = 4096;

/// Decoded terminal event. Sent from the shim to RatatuiKit (EventPump).
///
/// Layout is fixed — cbindgen generates the matching C declaration in
/// ratatui_ffi.h. All fields beyond `kind` are discriminant-dependent.
#[repr(C)]
pub struct RffiEvent {
    /// RffiEventKind discriminant.
    pub kind: u32,

    // --- Key fields (kind == Key) ------------------------------------------
    /// RffiKeyCode for the pressed key.
    pub key_code: u32,
    /// Unicode codepoint for Char keys; 0 for all others.
    pub key_char: u32,
    /// Modifier bitfield (key_mods::* constants).
    pub key_mods: u8,
    pub _pad0: [u8; 3],

    // --- Resize fields (kind == Resize) ------------------------------------
    pub resize_cols: u16,
    pub resize_rows: u16,

    // --- Mouse fields (kind == Mouse) --------------------------------------
    pub mouse_col: u16,
    pub mouse_row: u16,
    /// RffiMouseKind discriminant.
    pub mouse_kind: u32,
    /// RffiMouseButton discriminant.
    pub mouse_button: u32,
    /// Modifier bits for the mouse event.
    pub mouse_mods: u8,
    pub _pad1: [u8; 3],

    // --- Paste fields (kind == Paste) --------------------------------------
    /// UTF-8 paste text, NUL-terminated, at most PASTE_BUF_BYTES bytes.
    pub paste_buf: [c_char; PASTE_BUF_BYTES],
    /// Actual byte count in paste_buf (excluding NUL terminator).
    pub paste_len: u32,
    pub _pad2: [u8; 4],
}

impl Default for RffiEvent {
    fn default() -> Self {
        // SAFETY: RffiEvent contains only numeric types and arrays; zeroing is
        // a valid initialiser.
        unsafe { std::mem::zeroed() }
    }
}

// ---------------------------------------------------------------------------
// Decoding helpers
// ---------------------------------------------------------------------------

fn decode_key_mods(m: CtKeyModifiers) -> u8 {
    let mut out = key_mods::NONE;
    if m.contains(CtKeyModifiers::SHIFT) {
        out |= key_mods::SHIFT;
    }
    if m.contains(CtKeyModifiers::ALT) {
        out |= key_mods::ALT;
    }
    if m.contains(CtKeyModifiers::CONTROL) {
        out |= key_mods::CTRL;
    }
    out
}

fn decode_key_event(k: CtKeyEvent, out: &mut RffiEvent) {
    out.key_mods = decode_key_mods(k.modifiers);
    match k.code {
        CtKeyCode::Char(c) => {
            out.key_code = RffiKeyCode::Char as u32;
            out.key_char = c as u32;
        }
        CtKeyCode::Enter => out.key_code = RffiKeyCode::Enter as u32,
        CtKeyCode::Left => out.key_code = RffiKeyCode::Left as u32,
        CtKeyCode::Right => out.key_code = RffiKeyCode::Right as u32,
        CtKeyCode::Up => out.key_code = RffiKeyCode::Up as u32,
        CtKeyCode::Down => out.key_code = RffiKeyCode::Down as u32,
        CtKeyCode::Esc => out.key_code = RffiKeyCode::Esc as u32,
        CtKeyCode::Backspace => out.key_code = RffiKeyCode::Backspace as u32,
        CtKeyCode::Tab => out.key_code = RffiKeyCode::Tab as u32,
        CtKeyCode::Delete => out.key_code = RffiKeyCode::Delete as u32,
        CtKeyCode::Home => out.key_code = RffiKeyCode::Home as u32,
        CtKeyCode::End => out.key_code = RffiKeyCode::End as u32,
        CtKeyCode::PageUp => out.key_code = RffiKeyCode::PageUp as u32,
        CtKeyCode::PageDown => out.key_code = RffiKeyCode::PageDown as u32,
        CtKeyCode::Insert => out.key_code = RffiKeyCode::Insert as u32,
        CtKeyCode::F(n) => {
            // F1=100, F2=101, … F12=111
            out.key_code = RffiKeyCode::F1 as u32 + (n.saturating_sub(1)) as u32;
        }
        _ => out.key_code = RffiKeyCode::Unknown as u32,
    }
}

fn decode_mouse_button(b: CtMouseButton) -> u32 {
    match b {
        CtMouseButton::Left => RffiMouseButton::Left as u32,
        CtMouseButton::Right => RffiMouseButton::Right as u32,
        CtMouseButton::Middle => RffiMouseButton::Middle as u32,
    }
}

/// Fill an RffiEvent from a crossterm event. Returns false if the event is a
/// crossterm variant we intentionally ignore (rare internal events).
fn fill_event(evt: CtEvent, out: &mut RffiEvent) -> bool {
    *out = RffiEvent::default();
    match evt {
        CtEvent::Key(k) => {
            out.kind = RffiEventKind::Key as u32;
            decode_key_event(k, out);
            true
        }
        CtEvent::Resize(cols, rows) => {
            out.kind = RffiEventKind::Resize as u32;
            out.resize_cols = cols;
            out.resize_rows = rows;
            true
        }
        CtEvent::Mouse(m) => {
            out.kind = RffiEventKind::Mouse as u32;
            out.mouse_col = m.column;
            out.mouse_row = m.row;
            out.mouse_mods = decode_key_mods(m.modifiers);
            match m.kind {
                CtMouseKind::Down(btn) => {
                    out.mouse_kind = RffiMouseKind::Down as u32;
                    out.mouse_button = decode_mouse_button(btn);
                }
                CtMouseKind::Up(btn) => {
                    out.mouse_kind = RffiMouseKind::Up as u32;
                    out.mouse_button = decode_mouse_button(btn);
                }
                CtMouseKind::Drag(btn) => {
                    out.mouse_kind = RffiMouseKind::Drag as u32;
                    out.mouse_button = decode_mouse_button(btn);
                }
                CtMouseKind::Moved => out.mouse_kind = RffiMouseKind::Moved as u32,
                CtMouseKind::ScrollUp => out.mouse_kind = RffiMouseKind::ScrollUp as u32,
                CtMouseKind::ScrollDown => out.mouse_kind = RffiMouseKind::ScrollDown as u32,
                _ => {}
            }
            true
        }
        CtEvent::Paste(text) => {
            // Bracketed-paste: fork addition (ARCHITECTURE.md §4.5 ADD list).
            out.kind = RffiEventKind::Paste as u32;
            let bytes = text.as_bytes();
            // Reserve 1 byte for the NUL terminator.
            let n = bytes.len().min(PASTE_BUF_BYTES - 1);
            unsafe {
                std::ptr::copy_nonoverlapping(
                    bytes.as_ptr() as *const c_char,
                    out.paste_buf.as_mut_ptr(),
                    n,
                );
            }
            out.paste_buf[n] = 0;
            out.paste_len = n as u32;
            true
        }
        _ => false, // FocusGained/FocusLost: ignored.
    }
}

// ---------------------------------------------------------------------------
// rffi_poll_event
// ---------------------------------------------------------------------------

/// Poll for the next terminal event, blocking for at most `timeout_ms`
/// milliseconds.
///
/// Return values:
///   0           — event decoded; `*out` is valid.
///   RFFI_TIMEOUT (1) — timeout elapsed; `*out` is zeroed.
///   negative    — I/O error; call rffi_last_error() for detail.
///
/// Retries internally on EINTR (SIGTSTP, debugger attach) — the pump loop
/// never sees EINTR as an error (ARCHITECTURE.md §5.2).
///
/// Thread class: input-class (EventPump thread only).
#[no_mangle]
pub extern "C" fn rffi_poll_event(out: *mut RffiEvent, timeout_ms: i32) -> i32 {
    ffi_guard!("rffi_poll_event", {
        if out.is_null() {
            set_last_error("rffi_poll_event: null output pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }

        let timeout = if timeout_ms < 0 {
            Duration::from_millis(50)
        } else {
            Duration::from_millis(timeout_ms as u64)
        };

        // EINTR retry loop: crossterm::event::poll may return Err(EINTR) when
        // a signal interrupts the underlying poll(2)/select(2) syscall.
        // We retry rather than surfacing the interruption as an error.
        loop {
            match crossterm::event::poll(timeout) {
                Ok(true) => {
                    // Event available — read it.
                    match crossterm::event::read() {
                        Ok(evt) => {
                            let event_ref = unsafe { &mut *out };
                            if fill_event(evt, event_ref) {
                                return 0;
                            } else {
                                // Ignored variant (focus events etc.): treat
                                // as if no event arrived.
                                return RFFI_TIMEOUT;
                            }
                        }
                        Err(e) => {
                            // Check for EINTR on the read side.
                            if is_eintr(&e) {
                                continue;
                            }
                            set_last_error(format!("rffi_poll_event: read: {e}"));
                            return RFFI_ERR_IO;
                        }
                    }
                }
                Ok(false) => {
                    // Timeout — zero the output and signal the caller.
                    unsafe { *out = RffiEvent::default() };
                    return RFFI_TIMEOUT;
                }
                Err(e) => {
                    if is_eintr(&e) {
                        // EINTR from poll — retry with the same timeout.
                        continue;
                    }
                    set_last_error(format!("rffi_poll_event: poll: {e}"));
                    return RFFI_ERR_IO;
                }
            }
        }
    })
}

/// Returns true if the I/O error is EINTR (signal-interrupted syscall).
fn is_eintr(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::Interrupted
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Helper: build a fake crossterm key event.
    fn fake_key(code: CtKeyCode, mods: CtKeyModifiers) -> CtEvent {
        CtEvent::Key(CtKeyEvent {
            code,
            modifiers: mods,
            kind: crossterm::event::KeyEventKind::Press,
            state: crossterm::event::KeyEventState::NONE,
        })
    }

    #[test]
    fn decode_char_key() {
        let mut out = RffiEvent::default();
        let ok = fill_event(
            fake_key(CtKeyCode::Char('j'), CtKeyModifiers::NONE),
            &mut out,
        );
        assert!(ok);
        assert_eq!(out.kind, RffiEventKind::Key as u32);
        assert_eq!(out.key_code, RffiKeyCode::Char as u32);
        assert_eq!(out.key_char, 'j' as u32);
        assert_eq!(out.key_mods, key_mods::NONE);
    }

    #[test]
    fn decode_ctrl_modifier() {
        let mut out = RffiEvent::default();
        fill_event(
            fake_key(CtKeyCode::Char('c'), CtKeyModifiers::CONTROL),
            &mut out,
        );
        assert_eq!(out.key_mods & key_mods::CTRL, key_mods::CTRL);
    }

    #[test]
    fn decode_shift_alt_modifiers() {
        let mut out = RffiEvent::default();
        fill_event(
            fake_key(
                CtKeyCode::Char('x'),
                CtKeyModifiers::SHIFT | CtKeyModifiers::ALT,
            ),
            &mut out,
        );
        assert_eq!(out.key_mods & key_mods::SHIFT, key_mods::SHIFT);
        assert_eq!(out.key_mods & key_mods::ALT, key_mods::ALT);
        assert_eq!(out.key_mods & key_mods::CTRL, 0);
    }

    #[test]
    fn decode_enter_key() {
        let mut out = RffiEvent::default();
        fill_event(fake_key(CtKeyCode::Enter, CtKeyModifiers::NONE), &mut out);
        assert_eq!(out.key_code, RffiKeyCode::Enter as u32);
    }

    #[test]
    fn decode_f_keys() {
        for n in 1u8..=12 {
            let mut out = RffiEvent::default();
            fill_event(fake_key(CtKeyCode::F(n), CtKeyModifiers::NONE), &mut out);
            let expected = RffiKeyCode::F1 as u32 + (n - 1) as u32;
            assert_eq!(out.key_code, expected, "F{n}");
        }
    }

    #[test]
    fn decode_resize_event() {
        let mut out = RffiEvent::default();
        let ok = fill_event(CtEvent::Resize(80, 24), &mut out);
        assert!(ok);
        assert_eq!(out.kind, RffiEventKind::Resize as u32);
        assert_eq!(out.resize_cols, 80);
        assert_eq!(out.resize_rows, 24);
    }

    #[test]
    fn decode_paste_event() {
        let text = "hello paste";
        let mut out = RffiEvent::default();
        let ok = fill_event(CtEvent::Paste(text.to_string()), &mut out);
        assert!(ok);
        assert_eq!(out.kind, RffiEventKind::Paste as u32);
        assert_eq!(out.paste_len as usize, text.len());
        let stored = std::str::from_utf8(unsafe {
            std::slice::from_raw_parts(out.paste_buf.as_ptr() as *const u8, out.paste_len as usize)
        })
        .unwrap();
        assert_eq!(stored, text);
        // Verify NUL terminator is present.
        assert_eq!(out.paste_buf[text.len()], 0);
    }

    #[test]
    fn decode_long_paste_truncates() {
        // A paste longer than PASTE_BUF_BYTES-1 must be truncated with a NUL.
        let long_text = "a".repeat(PASTE_BUF_BYTES + 100);
        let mut out = RffiEvent::default();
        fill_event(CtEvent::Paste(long_text), &mut out);
        assert_eq!(out.kind, RffiEventKind::Paste as u32);
        assert_eq!(out.paste_len as usize, PASTE_BUF_BYTES - 1);
        // Last byte of the buffer must be NUL.
        assert_eq!(out.paste_buf[PASTE_BUF_BYTES - 1], 0);
    }

    #[test]
    fn poll_event_null_ptr_returns_error() {
        let code = rffi_poll_event(std::ptr::null_mut(), 0);
        assert!(code < 0);
    }

    #[test]
    fn poll_event_zero_timeout_returns_timeout_on_no_tty() {
        // In the test process there is no real tty; a zero-timeout poll
        // should return RFFI_TIMEOUT (1) — not crash.
        let mut evt = RffiEvent::default();
        let code = rffi_poll_event(&mut evt as *mut _, 0);
        // Either RFFI_TIMEOUT or an I/O error — both are acceptable without a tty.
        assert!(code == RFFI_TIMEOUT || code < 0);
    }
}
