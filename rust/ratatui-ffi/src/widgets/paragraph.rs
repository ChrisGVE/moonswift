// File: rust/ratatui-ffi/src/widgets/paragraph.rs
// Role: Paragraph widget — scrollable text content for the Output and
//       Diagnostics tabs in MoonSwift's bottom pane.
//
// Supports: multi-line text via line/span append, optional block borders,
// alignment, wrapping, and scroll offset (x, y).
//
// Entry-point naming: rffi_paragraph_* (ARCHITECTURE.md §5.2).
// Error protocol: i32, 0 = ok, negative = error code.
//
// Upstream: ratatui::widgets::Paragraph
// Downstream: lib.rs (re-exports), RatatuiKit/Widgets.swift

use crate::ffi_guard;
use crate::ffi_guard_ptr;
use crate::guard::set_last_error;
use crate::terminal::RffiTerminal;
use crate::widgets::block::{build_block, decode_spans, decode_style, RffiSpan, RffiStyle};
use ratatui::layout::Rect;
use ratatui::prelude::{Alignment, Line, Span};
use ratatui::style::Style;
use ratatui::widgets::{Block, Paragraph, Wrap};
use std::ffi::CStr;

// ---------------------------------------------------------------------------
// Handle type
// ---------------------------------------------------------------------------

/// Opaque paragraph handle. Heap-allocated; Swift holds `*mut RffiParagraph`.
pub struct RffiParagraph {
    lines: Vec<Line<'static>>,
    block: Option<Block<'static>>,
    align: Option<Alignment>,
    wrap_trim: Option<bool>,
    scroll_x: Option<u16>,
    scroll_y: Option<u16>,
    base_style: Option<Style>,
}

// ---------------------------------------------------------------------------
// Constructors / destructor
// ---------------------------------------------------------------------------

/// Create a new empty paragraph.
#[no_mangle]
pub extern "C" fn rffi_paragraph_new() -> *mut RffiParagraph {
    ffi_guard_ptr!("rffi_paragraph_new", {
        Box::into_raw(Box::new(RffiParagraph {
            lines: Vec::new(),
            block: None,
            align: None,
            wrap_trim: None,
            scroll_x: None,
            scroll_y: None,
            base_style: None,
        }))
    })
}

/// Free a paragraph handle.
#[no_mangle]
pub extern "C" fn rffi_paragraph_free(para: *mut RffiParagraph) -> i32 {
    ffi_guard!("rffi_paragraph_free", {
        if !para.is_null() {
            unsafe { drop(Box::from_raw(para)) };
        }
        0
    })
}

// ---------------------------------------------------------------------------
// Content builders
// ---------------------------------------------------------------------------

/// Append a plain-text line (single uniform style).
#[no_mangle]
pub extern "C" fn rffi_paragraph_append_line(
    para: *mut RffiParagraph,
    text_utf8: *const std::ffi::c_char,
    style: RffiStyle,
) -> i32 {
    ffi_guard!("rffi_paragraph_append_line", {
        if para.is_null() || text_utf8.is_null() {
            set_last_error("rffi_paragraph_append_line: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let c = unsafe { CStr::from_ptr(text_utf8) };
        if let Ok(s) = c.to_str() {
            let st = decode_style(style);
            unsafe { &mut *para }
                .lines
                .push(Line::from(Span::styled(s.to_string(), st)));
        }
        0
    })
}

/// Append a span-array line (mixed styles).
#[no_mangle]
pub extern "C" fn rffi_paragraph_append_line_spans(
    para: *mut RffiParagraph,
    spans: *const RffiSpan,
    len: usize,
) -> i32 {
    ffi_guard!("rffi_paragraph_append_line_spans", {
        if para.is_null() {
            set_last_error("rffi_paragraph_append_line_spans: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if let Some(sp) = decode_spans(spans, len) {
            unsafe { &mut *para }.lines.push(Line::from(sp));
        }
        0
    })
}

/// Insert a blank line separator.
#[no_mangle]
pub extern "C" fn rffi_paragraph_line_break(para: *mut RffiParagraph) -> i32 {
    ffi_guard!("rffi_paragraph_line_break", {
        if para.is_null() {
            set_last_error("rffi_paragraph_line_break: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *para }.lines.push(Line::default());
        0
    })
}

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

/// Set text alignment: 0 = Left, 1 = Center, 2 = Right.
#[no_mangle]
pub extern "C" fn rffi_paragraph_set_alignment(para: *mut RffiParagraph, align: u32) -> i32 {
    ffi_guard!("rffi_paragraph_set_alignment", {
        if para.is_null() {
            set_last_error("rffi_paragraph_set_alignment: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *para }.align = Some(match align {
            1 => Alignment::Center,
            2 => Alignment::Right,
            _ => Alignment::Left,
        });
        0
    })
}

/// Enable or disable word-wrapping. trim = 1 trims leading whitespace.
#[no_mangle]
pub extern "C" fn rffi_paragraph_set_wrap(para: *mut RffiParagraph, trim: u8) -> i32 {
    ffi_guard!("rffi_paragraph_set_wrap", {
        if para.is_null() {
            set_last_error("rffi_paragraph_set_wrap: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *para }.wrap_trim = Some(trim != 0);
        0
    })
}

/// Set scroll offset (x = column offset, y = row offset).
#[no_mangle]
pub extern "C" fn rffi_paragraph_set_scroll(para: *mut RffiParagraph, x: u16, y: u16) -> i32 {
    ffi_guard!("rffi_paragraph_set_scroll", {
        if para.is_null() {
            set_last_error("rffi_paragraph_set_scroll: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let p = unsafe { &mut *para };
        p.scroll_x = Some(x);
        p.scroll_y = Some(y);
        0
    })
}

/// Set the base style applied to the paragraph as a whole.
#[no_mangle]
pub extern "C" fn rffi_paragraph_set_style(para: *mut RffiParagraph, style: RffiStyle) -> i32 {
    ffi_guard!("rffi_paragraph_set_style", {
        if para.is_null() {
            set_last_error("rffi_paragraph_set_style: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *para }.base_style = Some(decode_style(style));
        0
    })
}

/// Set the block (borders + title) for this paragraph.
#[no_mangle]
pub extern "C" fn rffi_paragraph_set_block(
    para: *mut RffiParagraph,
    borders_bits: u8,
    border_type: u32,
    pad_left: u16,
    pad_top: u16,
    pad_right: u16,
    pad_bottom: u16,
    title_spans: *const RffiSpan,
    title_len: usize,
) -> i32 {
    ffi_guard!("rffi_paragraph_set_block", {
        if para.is_null() {
            set_last_error("rffi_paragraph_set_block: null paragraph");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *para }.block = Some(build_block(
            borders_bits,
            border_type,
            pad_left,
            pad_top,
            pad_right,
            pad_bottom,
            title_spans,
            title_len,
        ));
        0
    })
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

/// Internal widget builder.
fn build_rt_paragraph(p: &RffiParagraph) -> Paragraph<'static> {
    let mut w = Paragraph::new(p.lines.clone());
    if let Some(a) = p.align {
        w = w.alignment(a);
    }
    if let Some(trim) = p.wrap_trim {
        w = w.wrap(Wrap { trim });
    }
    if let (Some(sx), Some(sy)) = (p.scroll_x, p.scroll_y) {
        w = w.scroll((sy, sx)); // ratatui scroll = (vertical, horizontal)
    }
    if let Some(st) = &p.base_style {
        w = w.style(*st);
    }
    if let Some(b) = &p.block {
        w = w.block(b.clone());
    }
    w
}

/// Draw the paragraph into a rect of the terminal frame buffer.
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_paragraph_draw(
    handle: *mut (),
    para: *const RffiParagraph,
    rect: crate::layout::RffiRect,
) -> i32 {
    ffi_guard!("rffi_paragraph_draw", {
        if handle.is_null() || para.is_null() {
            set_last_error("rffi_paragraph_draw: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let p = unsafe { &*para };
        let widget = build_rt_paragraph(p);
        let area = Rect {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
        match t.terminal.draw(|frame| frame.render_widget(widget, area)) {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_paragraph_draw: {e}"));
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
    fn new_and_free() {
        let p = rffi_paragraph_new();
        assert!(!p.is_null());
        assert_eq!(rffi_paragraph_free(p), 0);
    }

    #[test]
    fn free_null_is_ok() {
        assert_eq!(rffi_paragraph_free(std::ptr::null_mut()), 0);
    }

    #[test]
    fn append_line_null_errors() {
        let code = rffi_paragraph_append_line(
            std::ptr::null_mut(),
            b"text\0".as_ptr() as *const _,
            RffiStyle::default(),
        );
        assert!(code < 0);
    }

    #[test]
    fn append_line_and_count() {
        let p = rffi_paragraph_new();
        let code =
            rffi_paragraph_append_line(p, b"hello\0".as_ptr() as *const _, RffiStyle::default());
        assert_eq!(code, 0);
        assert_eq!(unsafe { &*p }.lines.len(), 1);
        rffi_paragraph_free(p);
    }

    #[test]
    fn line_break_adds_empty_line() {
        let p = rffi_paragraph_new();
        rffi_paragraph_line_break(p);
        assert_eq!(unsafe { &*p }.lines.len(), 1);
        rffi_paragraph_free(p);
    }

    #[test]
    fn draw_null_handle_errors() {
        let p = rffi_paragraph_new();
        let code = rffi_paragraph_draw(std::ptr::null_mut(), p, crate::layout::RffiRect::default());
        assert!(code < 0);
        rffi_paragraph_free(p);
    }
}
