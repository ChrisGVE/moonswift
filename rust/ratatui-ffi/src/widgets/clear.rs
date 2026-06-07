// File: rust/ratatui-ffi/src/widgets/clear.rs
// Role: Clear widget — erase a rectangular region to the default background.
//       Used for help overlay and popup rendering in MoonSwift.
//
// Entry-point naming: rffi_clear_* (ARCHITECTURE.md §5.2).
// Error protocol: i32, 0 = ok, negative = error code.
//
// Upstream: ratatui::widgets::Clear
// Downstream: lib.rs (re-exports), RatatuiKit/Widgets.swift

use crate::ffi_guard;
use crate::guard::set_last_error;
use crate::terminal::RffiTerminal;
use ratatui::layout::Rect;
use ratatui::widgets::Clear as RtClear;

/// Clear (erase) a rectangular region to the terminal default background.
///
/// Parameters:
///   handle — opaque RffiTerminal pointer from rffi_terminal_init.
///   rect   — the region to clear in cell coordinates.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_clear_rect_widget(handle: *mut (), rect: crate::layout::RffiRect) -> i32 {
    ffi_guard!("rffi_clear_rect_widget", {
        if handle.is_null() {
            set_last_error("rffi_clear_rect_widget: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let area = Rect {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
        match t.terminal.draw(|frame| frame.render_widget(RtClear, area)) {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_clear_rect_widget: {e}"));
                crate::error::RFFI_ERR_IO
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

    #[test]
    fn clear_null_handle_returns_error() {
        let code = rffi_clear_rect_widget(std::ptr::null_mut(), crate::layout::RffiRect::default());
        assert!(code < 0);
    }
}
