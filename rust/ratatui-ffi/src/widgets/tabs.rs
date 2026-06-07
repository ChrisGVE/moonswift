// File: rust/ratatui-ffi/src/widgets/tabs.rs
// Role: Tabs widget — the bottom-pane tab bar in MoonSwift (Output /
//       Diagnostics / Debug tabs). Supports titled tabs with optional block,
//       selected-tab highlight style, and unselected style.
//
// Entry-point naming: rffi_tabs_* (ARCHITECTURE.md §5.2).
// Error protocol: i32, 0 = ok, negative = error code.
//
// Upstream: ratatui::widgets::Tabs
// Downstream: lib.rs (re-exports RffiTabs/RffiTabsStyles), RatatuiKit/Widgets.swift

use crate::ffi_guard;
use crate::ffi_guard_ptr;
use crate::guard::set_last_error;
use crate::terminal::RffiTerminal;
use crate::widgets::block::{build_block, decode_style, RffiSpan, RffiStyle};
use ratatui::layout::Rect;
use ratatui::prelude::{Line, Span};
use ratatui::style::Style;
use ratatui::widgets::{Block, Tabs};
use std::ffi::CStr;

// ---------------------------------------------------------------------------
// Handle types
// ---------------------------------------------------------------------------

/// Opaque tabs handle. Heap-allocated; Swift holds `*mut RffiTabs`.
pub struct RffiTabs {
    titles: Vec<String>,
    selected: u16,
    block: Option<Block<'static>>,
    selected_style: Option<Style>,
    unselected_style: Option<Style>,
}

/// Combined selected + unselected styles — convenience for Swift callers.
#[repr(C)]
pub struct RffiTabsStyles {
    pub selected: RffiStyle,
    pub unselected: RffiStyle,
}

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

/// Create a new empty tabs handle.
#[no_mangle]
pub extern "C" fn rffi_tabs_new() -> *mut RffiTabs {
    ffi_guard_ptr!("rffi_tabs_new", {
        Box::into_raw(Box::new(RffiTabs {
            titles: Vec::new(),
            selected: 0,
            block: None,
            selected_style: None,
            unselected_style: None,
        }))
    })
}

/// Free a tabs handle.
#[no_mangle]
pub extern "C" fn rffi_tabs_free(t: *mut RffiTabs) -> i32 {
    ffi_guard!("rffi_tabs_free", {
        if !t.is_null() {
            unsafe { drop(Box::from_raw(t)) };
        }
        0
    })
}

// ---------------------------------------------------------------------------
// Tab builders
// ---------------------------------------------------------------------------

/// Append a tab title (UTF-8 NUL-terminated string).
#[no_mangle]
pub extern "C" fn rffi_tabs_append_title(
    t: *mut RffiTabs,
    title_utf8: *const std::ffi::c_char,
) -> i32 {
    ffi_guard!("rffi_tabs_append_title", {
        if t.is_null() || title_utf8.is_null() {
            set_last_error("rffi_tabs_append_title: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let c = unsafe { CStr::from_ptr(title_utf8) };
        if let Ok(s) = c.to_str() {
            unsafe { &mut *t }.titles.push(s.to_string());
        }
        0
    })
}

// ---------------------------------------------------------------------------
// Property setters
// ---------------------------------------------------------------------------

/// Set the index of the currently selected tab.
#[no_mangle]
pub extern "C" fn rffi_tabs_set_selected(t: *mut RffiTabs, index: u16) -> i32 {
    ffi_guard!("rffi_tabs_set_selected", {
        if t.is_null() {
            set_last_error("rffi_tabs_set_selected: null tabs");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *t }.selected = index;
        0
    })
}

/// Set both selected and unselected tab styles in one call.
#[no_mangle]
pub extern "C" fn rffi_tabs_set_styles(t: *mut RffiTabs, styles: RffiTabsStyles) -> i32 {
    ffi_guard!("rffi_tabs_set_styles", {
        if t.is_null() {
            set_last_error("rffi_tabs_set_styles: null tabs");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let tabs = unsafe { &mut *t };
        tabs.selected_style = Some(decode_style(styles.selected));
        tabs.unselected_style = Some(decode_style(styles.unselected));
        0
    })
}

/// Set the block (borders + title) for the tabs bar.
#[no_mangle]
pub extern "C" fn rffi_tabs_set_block(
    t: *mut RffiTabs,
    borders_bits: u8,
    border_type: u32,
    pad_left: u16,
    pad_top: u16,
    pad_right: u16,
    pad_bottom: u16,
    title_spans: *const RffiSpan,
    title_len: usize,
) -> i32 {
    ffi_guard!("rffi_tabs_set_block", {
        if t.is_null() {
            set_last_error("rffi_tabs_set_block: null tabs");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *t }.block = Some(build_block(
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

/// Draw the tabs bar into a rect of the terminal frame buffer.
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_tabs_draw(
    handle: *mut (),
    t: *const RffiTabs,
    rect: crate::layout::RffiRect,
) -> i32 {
    ffi_guard!("rffi_tabs_draw", {
        if handle.is_null() || t.is_null() {
            set_last_error("rffi_tabs_draw: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let term = unsafe { &mut *(handle as *mut RffiTerminal) };
        let tabs = unsafe { &*t };

        let titles: Vec<Line> = tabs
            .titles
            .iter()
            .map(|s| Line::from(Span::raw(s.clone())))
            .collect();
        let mut widget = Tabs::new(titles).select(tabs.selected as usize);

        if let Some(b) = &tabs.block {
            widget = widget.block(b.clone());
        }
        if let Some(sel) = tabs.selected_style {
            widget = widget.highlight_style(sel);
        }
        // Note: ratatui 0.29 uses style() for the unselected tab style.
        if let Some(unsel) = tabs.unselected_style {
            widget = widget.style(unsel);
        }

        let area = Rect {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
        match term
            .terminal
            .draw(|frame| frame.render_widget(widget, area))
        {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_tabs_draw: {e}"));
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
        let t = rffi_tabs_new();
        assert!(!t.is_null());
        assert_eq!(rffi_tabs_free(t), 0);
    }

    #[test]
    fn free_null_is_ok() {
        assert_eq!(rffi_tabs_free(std::ptr::null_mut()), 0);
    }

    #[test]
    fn append_title_and_verify() {
        let t = rffi_tabs_new();
        let code = rffi_tabs_append_title(t, b"Output\0".as_ptr() as *const _);
        assert_eq!(code, 0);
        assert_eq!(unsafe { &*t }.titles.len(), 1);
        assert_eq!(unsafe { &*t }.titles[0], "Output");
        rffi_tabs_free(t);
    }

    #[test]
    fn set_selected_and_read() {
        let t = rffi_tabs_new();
        rffi_tabs_append_title(t, b"A\0".as_ptr() as *const _);
        rffi_tabs_append_title(t, b"B\0".as_ptr() as *const _);
        rffi_tabs_set_selected(t, 1);
        assert_eq!(unsafe { &*t }.selected, 1);
        rffi_tabs_free(t);
    }

    #[test]
    fn append_title_null_errors() {
        let code = rffi_tabs_append_title(std::ptr::null_mut(), b"x\0".as_ptr() as *const _);
        assert!(code < 0);
    }

    #[test]
    fn draw_null_handle_errors() {
        let t = rffi_tabs_new();
        let code = rffi_tabs_draw(std::ptr::null_mut(), t, crate::layout::RffiRect::default());
        assert!(code < 0);
        rffi_tabs_free(t);
    }
}
