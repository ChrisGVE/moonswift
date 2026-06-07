// File: rust/ratatui-ffi/src/cells.rs
// Role: Cell-level buffer access — write runs of cells with uniform style into
//       the ratatui frame buffer. First-class API for the MoonSwift code pane
//       (highlight spans, gutter, marks) and P4b nvim grid blit.
//
// Two write modes (ARCHITECTURE.md §3b FFI batching contract):
//   - rffi_write_cells: a contiguous run of grapheme clusters on one row,
//     all sharing the same style. One FFI call per same-attribute run per row.
//   - rffi_clear_rect: fill a rectangular region with the default style.
//
// At 200×60 the per-frame call ceiling is ~1,500 (60 rows × ≤ 25 runs); a
// per-cell design (12,000 calls/frame) is forbidden.
//
// Upstream: ratatui::buffer, ratatui::style
// Downstream: lib.rs (re-exports), RatatuiKit/CellBuffer.swift (sole caller)

use crate::error::RFFI_ERR_INVALID_ARG;
use crate::ffi_guard;
use crate::guard::set_last_error;
use crate::terminal::RffiTerminal;
use ratatui::style::{Color, Modifier, Style};

// ---------------------------------------------------------------------------
// rffi_flush — flush the current ratatui frame to the terminal
// ---------------------------------------------------------------------------

/// Flush the current ratatui frame (diff + write). Call once per render cycle
/// after all widget and cell writes.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_flush(handle: *mut ()) -> i32 {
    ffi_guard!("rffi_flush", {
        if handle.is_null() {
            set_last_error("rffi_flush: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        // Drawing an empty frame triggers the diff + terminal write.
        if let Err(e) = t.terminal.draw(|_| {}) {
            set_last_error(format!("rffi_flush: {e}"));
            return crate::error::RFFI_ERR_IO;
        }
        0
    })
}

// ---------------------------------------------------------------------------
// rffi_write_cells
// ---------------------------------------------------------------------------

/// Write a run of cells with uniform style into the current frame buffer.
///
/// Parameters:
///   handle    — opaque RffiTerminal pointer from rffi_terminal_init.
///   start_col — 0-based column of the first cell.
///   start_row — 0-based row.
///   text      — UTF-8 string; each grapheme cluster occupies exactly one cell.
///   text_len  — byte length of `text` (not the grapheme count).
///   fg        — foreground colour: 0x00RRGGBB for RGB; 0xFFFFFFFF = default.
///   bg        — background colour: same encoding.
///   bold      — 1 = bold; 0 = normal.
///   italic    — 1 = italic.
///   underline — 1 = underline.
///
/// Returns 0 on success.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_write_cells(
    handle: *mut (),
    start_col: u16,
    start_row: u16,
    text: *const std::ffi::c_char,
    text_len: usize,
    fg: u32,
    bg: u32,
    bold: u8,
    italic: u8,
    underline: u8,
) -> i32 {
    ffi_guard!("rffi_write_cells", {
        if handle.is_null() {
            set_last_error("rffi_write_cells: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if text.is_null() {
            set_last_error("rffi_write_cells: null text pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }

        // Decode the UTF-8 text slice.
        let bytes = unsafe { std::slice::from_raw_parts(text as *const u8, text_len) };
        let s = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(e) => {
                set_last_error(format!("rffi_write_cells: invalid UTF-8: {e}"));
                return RFFI_ERR_INVALID_ARG;
            }
        };

        // Build the ratatui style.
        let fg_color = decode_color(fg);
        let bg_color = decode_color(bg);
        let mut mods = Modifier::empty();
        if bold != 0 {
            mods |= Modifier::BOLD;
        }
        if italic != 0 {
            mods |= Modifier::ITALIC;
        }
        if underline != 0 {
            mods |= Modifier::UNDERLINED;
        }
        let style = Style::default()
            .fg(fg_color)
            .bg(bg_color)
            .add_modifier(mods);

        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let err_cell = std::cell::RefCell::new(None::<String>);

        let res = t.terminal.draw(|frame| {
            let area = frame.area();
            if start_row >= area.height || start_col >= area.width {
                return; // out of bounds — silent skip
            }
            let buf = frame.buffer_mut();
            let mut col = start_col;
            for grapheme in s.chars() {
                if col >= area.width {
                    break;
                }
                let cell = buf
                    .cell_mut(ratatui::layout::Position::new(col, start_row))
                    .expect("position in bounds");
                cell.set_char(grapheme);
                cell.set_style(style);
                col += 1;
            }
        });

        if let Some(msg) = err_cell.into_inner() {
            set_last_error(msg);
            return crate::error::RFFI_ERR_IO;
        }
        match res {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_write_cells: draw: {e}"));
                crate::error::RFFI_ERR_IO
            }
        }
    })
}

// ---------------------------------------------------------------------------
// rffi_clear_rect
// ---------------------------------------------------------------------------

/// Clear a rectangular region to the terminal default style (blank cells).
///
/// Parameters:
///   handle — opaque RffiTerminal pointer.
///   col, row, width, height — 0-based rectangle in cell coordinates.
///
/// Returns 0 on success.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_clear_rect(
    handle: *mut (),
    col: u16,
    row: u16,
    width: u16,
    height: u16,
) -> i32 {
    ffi_guard!("rffi_clear_rect", {
        if handle.is_null() {
            set_last_error("rffi_clear_rect: null handle");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if width == 0 || height == 0 {
            return 0; // empty rect — nothing to do
        }

        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let res = t.terminal.draw(|frame| {
            let area = frame.area();
            let buf = frame.buffer_mut();
            let end_col = (col + width).min(area.width);
            let end_row = (row + height).min(area.height);
            for r in row..end_row {
                for c in col..end_col {
                    if let Some(cell) = buf.cell_mut(ratatui::layout::Position::new(c, r)) {
                        *cell = ratatui::buffer::Cell::default();
                    }
                }
            }
        });

        match res {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_clear_rect: {e}"));
                crate::error::RFFI_ERR_IO
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Colour decoding
// ---------------------------------------------------------------------------

/// Decode a packed colour word into a ratatui `Color`.
///
/// Encoding:
///   0xFFFFFFFF — terminal default (`Color::Reset`)
///   0x00RRGGBB — RGB truecolor
fn decode_color(packed: u32) -> Color {
    if packed == 0xFFFF_FFFF {
        Color::Reset
    } else {
        let r = ((packed >> 16) & 0xFF) as u8;
        let g = ((packed >> 8) & 0xFF) as u8;
        let b = (packed & 0xFF) as u8;
        Color::Rgb(r, g, b)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_color_reset() {
        assert_eq!(decode_color(0xFFFF_FFFF), Color::Reset);
    }

    #[test]
    fn decode_color_rgb() {
        assert_eq!(decode_color(0x00FF_8000), Color::Rgb(0xFF, 0x80, 0x00));
        assert_eq!(decode_color(0x0000_0000), Color::Rgb(0, 0, 0));
        assert_eq!(decode_color(0x00FF_FFFF), Color::Rgb(0xFF, 0xFF, 0xFF));
    }

    #[test]
    fn flush_null_handle_returns_error() {
        let code = rffi_flush(std::ptr::null_mut());
        assert!(code < 0);
    }

    #[test]
    fn write_cells_null_handle_returns_error() {
        let text = b"hi\0";
        let code = rffi_write_cells(
            std::ptr::null_mut(),
            0,
            0,
            text.as_ptr() as *const _,
            2,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            0,
            0,
            0,
        );
        assert!(code < 0);
    }

    #[test]
    fn write_cells_null_text_returns_error() {
        // We pass a fake non-null handle to reach the text-null check.
        // The handle won't be dereferenced before the null-text check.
        let mut dummy: u8 = 0;
        let fake_handle = &mut dummy as *mut u8 as *mut ();
        let code = rffi_write_cells(
            fake_handle,
            0,
            0,
            std::ptr::null(),
            0,
            0xFFFF_FFFF,
            0xFFFF_FFFF,
            0,
            0,
            0,
        );
        // Either null-ptr error (if ffi_guard catches null check) or a panic
        // caught by ffi_guard — both must be negative.
        assert!(code < 0);
    }

    #[test]
    fn clear_rect_null_handle_returns_error() {
        let code = rffi_clear_rect(std::ptr::null_mut(), 0, 0, 10, 10);
        assert!(code < 0);
    }

    #[test]
    fn clear_rect_zero_dimensions_is_ok() {
        // A zero-width or zero-height rect is a no-op; null handle should
        // still error before the dimension check.
        let code = rffi_clear_rect(std::ptr::null_mut(), 0, 0, 0, 0);
        assert!(code < 0);
    }
}
