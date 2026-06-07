// File: rust/ratatui-ffi/src/widgets/list.rs
// Role: List widget — navigator panes, pickers, and popups in MoonSwift.
//       Supports item append (text or styled spans), highlight style/symbol,
//       scroll offset, and direction. Draw calls go through rffi_terminal_draw_*
//       which wrap the ratatui ListState machinery.
//
// Entry-point naming: rffi_list_* (ARCHITECTURE.md §5.2).
// Error protocol: i32 return, 0 = ok, negative = error code.
//
// Upstream: ratatui::widgets::List, ratatui::widgets::ListState
// Downstream: lib.rs (re-exports RffiList/RffiListState), RatatuiKit/Widgets.swift

use crate::ffi_guard;
use crate::ffi_guard_ptr;
use crate::guard::set_last_error;
use crate::terminal::RffiTerminal;
use crate::widgets::block::{build_block, decode_spans, decode_style, RffiSpan, RffiStyle};
use ratatui::layout::Rect;
use ratatui::prelude::{Line, Span};
use ratatui::widgets::{
    HighlightSpacing as RtHighlightSpacing, List as RtList, ListDirection as RtListDirection,
    ListItem,
};
use std::ffi::CStr;

// ---------------------------------------------------------------------------
// Handle types
// ---------------------------------------------------------------------------

/// Opaque list handle. Heap-allocated; Swift holds a `*mut RffiList`.
pub struct RffiList {
    items: Vec<Line<'static>>,
    block: Option<ratatui::widgets::Block<'static>>,
    selected: Option<usize>,
    highlight_style: Option<ratatui::style::Style>,
    highlight_symbol: Option<String>,
    direction: Option<RtListDirection>,
    scroll_offset: Option<usize>,
    highlight_spacing: Option<RtHighlightSpacing>,
}

/// Opaque list-state handle for stateful rendering.
pub struct RffiListState {
    selected: Option<usize>,
    offset: usize,
}

// ---------------------------------------------------------------------------
// Constructor / destructor
// ---------------------------------------------------------------------------

/// Create a new empty list handle. Returns NULL on OOM (infeasible in practice).
#[no_mangle]
pub extern "C" fn rffi_list_new() -> *mut RffiList {
    ffi_guard_ptr!("rffi_list_new", {
        Box::into_raw(Box::new(RffiList {
            items: Vec::new(),
            block: None,
            selected: None,
            highlight_style: None,
            highlight_symbol: None,
            direction: None,
            scroll_offset: None,
            highlight_spacing: None,
        }))
    })
}

/// Free a list handle.
#[no_mangle]
pub extern "C" fn rffi_list_free(lst: *mut RffiList) -> i32 {
    ffi_guard!("rffi_list_free", {
        if lst.is_null() {
            return 0; // no-op on null
        }
        unsafe { drop(Box::from_raw(lst)) };
        0
    })
}

/// Create a new list-state handle (for stateful highlight rendering).
#[no_mangle]
pub extern "C" fn rffi_list_state_new() -> *mut RffiListState {
    ffi_guard_ptr!("rffi_list_state_new", {
        Box::into_raw(Box::new(RffiListState {
            selected: None,
            offset: 0,
        }))
    })
}

/// Free a list-state handle.
#[no_mangle]
pub extern "C" fn rffi_list_state_free(st: *mut RffiListState) -> i32 {
    ffi_guard!("rffi_list_state_free", {
        if !st.is_null() {
            unsafe { drop(Box::from_raw(st)) };
        }
        0
    })
}

// ---------------------------------------------------------------------------
// Item builders
// ---------------------------------------------------------------------------

/// Append a plain-text item (single uniform style) to the list.
#[no_mangle]
pub extern "C" fn rffi_list_append_item(
    lst: *mut RffiList,
    text_utf8: *const std::ffi::c_char,
    style: RffiStyle,
) -> i32 {
    ffi_guard!("rffi_list_append_item", {
        if lst.is_null() || text_utf8.is_null() {
            set_last_error("rffi_list_append_item: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let c = unsafe { CStr::from_ptr(text_utf8) };
        if let Ok(s) = c.to_str() {
            let st = decode_style(style);
            unsafe { &mut *lst }
                .items
                .push(Line::from(Span::styled(s.to_string(), st)));
        }
        0
    })
}

/// Append a span-array item (mixed styles on one line) to the list.
#[no_mangle]
pub extern "C" fn rffi_list_append_item_spans(
    lst: *mut RffiList,
    spans: *const RffiSpan,
    len: usize,
) -> i32 {
    ffi_guard!("rffi_list_append_item_spans", {
        if lst.is_null() {
            set_last_error("rffi_list_append_item_spans: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if let Some(sp) = decode_spans(spans, len) {
            unsafe { &mut *lst }.items.push(Line::from(sp));
        }
        0
    })
}

// ---------------------------------------------------------------------------
// Style / property setters
// ---------------------------------------------------------------------------

/// Set the selected item index. Pass -1 to clear the selection.
#[no_mangle]
pub extern "C" fn rffi_list_set_selected(lst: *mut RffiList, index: i32) -> i32 {
    ffi_guard!("rffi_list_set_selected", {
        if lst.is_null() {
            set_last_error("rffi_list_set_selected: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let l = unsafe { &mut *lst };
        l.selected = if index < 0 {
            None
        } else {
            Some(index as usize)
        };
        0
    })
}

/// Set the highlight style applied to the selected row.
#[no_mangle]
pub extern "C" fn rffi_list_set_highlight_style(lst: *mut RffiList, style: RffiStyle) -> i32 {
    ffi_guard!("rffi_list_set_highlight_style", {
        if lst.is_null() {
            set_last_error("rffi_list_set_highlight_style: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *lst }.highlight_style = Some(decode_style(style));
        0
    })
}

/// Set the highlight symbol prefix (e.g. "» "). NULL clears it.
#[no_mangle]
pub extern "C" fn rffi_list_set_highlight_symbol(
    lst: *mut RffiList,
    sym_utf8: *const std::ffi::c_char,
) -> i32 {
    ffi_guard!("rffi_list_set_highlight_symbol", {
        if lst.is_null() {
            set_last_error("rffi_list_set_highlight_symbol: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let l = unsafe { &mut *lst };
        l.highlight_symbol = if sym_utf8.is_null() {
            None
        } else {
            unsafe { CStr::from_ptr(sym_utf8) }
                .to_str()
                .ok()
                .map(|s| s.to_string())
        };
        0
    })
}

/// Set scroll offset within the list.
#[no_mangle]
pub extern "C" fn rffi_list_set_scroll_offset(lst: *mut RffiList, offset: usize) -> i32 {
    ffi_guard!("rffi_list_set_scroll_offset", {
        if lst.is_null() {
            set_last_error("rffi_list_set_scroll_offset: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *lst }.scroll_offset = Some(offset);
        0
    })
}

/// Set item direction: 0 = TopToBottom (default), 1 = BottomToTop.
#[no_mangle]
pub extern "C" fn rffi_list_set_direction(lst: *mut RffiList, dir: u32) -> i32 {
    ffi_guard!("rffi_list_set_direction", {
        if lst.is_null() {
            set_last_error("rffi_list_set_direction: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *lst }.direction = Some(match dir {
            1 => RtListDirection::BottomToTop,
            _ => RtListDirection::TopToBottom,
        });
        0
    })
}

/// Set the block (borders + title) for this list.
///
/// border_type: 0 = Plain, 1 = Rounded, 2 = Double, 3 = Thick.
/// borders_bits: bitfield (see block::border_bits).
#[no_mangle]
pub extern "C" fn rffi_list_set_block(
    lst: *mut RffiList,
    borders_bits: u8,
    border_type: u32,
    pad_left: u16,
    pad_top: u16,
    pad_right: u16,
    pad_bottom: u16,
    title_spans: *const RffiSpan,
    title_len: usize,
) -> i32 {
    ffi_guard!("rffi_list_set_block", {
        if lst.is_null() {
            set_last_error("rffi_list_set_block: null list");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *lst }.block = Some(build_block(
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

/// Set the list-state's selected index. -1 = no selection.
#[no_mangle]
pub extern "C" fn rffi_list_state_set_selected(st: *mut RffiListState, index: i32) -> i32 {
    ffi_guard!("rffi_list_state_set_selected", {
        if st.is_null() {
            set_last_error("rffi_list_state_set_selected: null state");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *st }.selected = if index < 0 {
            None
        } else {
            Some(index as usize)
        };
        0
    })
}

/// Set the list-state scroll offset.
#[no_mangle]
pub extern "C" fn rffi_list_state_set_offset(st: *mut RffiListState, offset: usize) -> i32 {
    ffi_guard!("rffi_list_state_set_offset", {
        if st.is_null() {
            set_last_error("rffi_list_state_set_offset: null state");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        unsafe { &mut *st }.offset = offset;
        0
    })
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

/// Internal widget builder — shared between draw functions.
fn build_rt_list(l: &RffiList) -> RtList<'_> {
    let items: Vec<ListItem> = l.items.iter().cloned().map(ListItem::new).collect();
    let mut w = RtList::new(items);
    if let Some(d) = l.direction {
        w = w.direction(d);
    }
    if let Some(b) = &l.block {
        w = w.block(b.clone());
    }
    if let Some(sty) = &l.highlight_style {
        w = w.highlight_style(*sty);
    }
    if let Some(sym) = &l.highlight_symbol {
        w = w.highlight_symbol(sym.as_str());
    }
    if let Some(sp) = &l.highlight_spacing {
        w = w.highlight_spacing(sp.clone());
    }
    w
}

/// Draw the list into a rect of the terminal frame buffer.
///
/// If the list has a selected index, renders with stateful highlighting.
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_list_draw(
    handle: *mut (),
    lst: *const RffiList,
    rect: crate::layout::RffiRect,
) -> i32 {
    ffi_guard!("rffi_list_draw", {
        if handle.is_null() || lst.is_null() {
            set_last_error("rffi_list_draw: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let l = unsafe { &*lst };
        let widget = build_rt_list(l);
        let area = Rect {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
        let res = t.terminal.draw(|frame| {
            if let Some(sel) = l.selected {
                let mut state = ratatui::widgets::ListState::default();
                state.select(Some(sel));
                if let Some(off) = l.scroll_offset {
                    state = state.with_offset(off);
                }
                frame.render_stateful_widget(widget.clone(), area, &mut state);
            } else {
                frame.render_widget(widget.clone(), area);
            }
        });
        match res {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_list_draw: {e}"));
                crate::error::RFFI_ERR_IO
            }
        }
    })
}

/// Draw the list with an explicit list-state (external selection tracking).
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_list_draw_stateful(
    handle: *mut (),
    lst: *const RffiList,
    st: *const RffiListState,
    rect: crate::layout::RffiRect,
) -> i32 {
    ffi_guard!("rffi_list_draw_stateful", {
        if handle.is_null() || lst.is_null() || st.is_null() {
            set_last_error("rffi_list_draw_stateful: null pointer");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        let t = unsafe { &mut *(handle as *mut RffiTerminal) };
        let l = unsafe { &*lst };
        let s = unsafe { &*st };
        let widget = build_rt_list(l);
        let area = Rect {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
        let mut state = ratatui::widgets::ListState::default();
        if let Some(sel) = s.selected {
            state.select(Some(sel));
        }
        state = state.with_offset(s.offset);
        let res = t.terminal.draw(|frame| {
            frame.render_stateful_widget(widget.clone(), area, &mut state);
        });
        match res {
            Ok(_) => 0,
            Err(e) => {
                set_last_error(format!("rffi_list_draw_stateful: {e}"));
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
        let lst = rffi_list_new();
        assert!(!lst.is_null());
        let code = rffi_list_free(lst);
        assert_eq!(code, 0);
    }

    #[test]
    fn free_null_is_ok() {
        assert_eq!(rffi_list_free(std::ptr::null_mut()), 0);
    }

    #[test]
    fn append_item_null_list_errors() {
        let style = RffiStyle::default();
        let text = b"hello\0";
        let code = rffi_list_append_item(std::ptr::null_mut(), text.as_ptr() as *const _, style);
        assert!(code < 0);
    }

    #[test]
    fn append_item_and_verify_count() {
        let lst = rffi_list_new();
        assert!(!lst.is_null());
        let text = b"item one\0";
        let code = rffi_list_append_item(lst, text.as_ptr() as *const _, RffiStyle::default());
        assert_eq!(code, 0);
        assert_eq!(unsafe { &*lst }.items.len(), 1);
        rffi_list_free(lst);
    }

    #[test]
    fn set_selected_and_clear() {
        let lst = rffi_list_new();
        rffi_list_set_selected(lst, 3);
        assert_eq!(unsafe { &*lst }.selected, Some(3));
        rffi_list_set_selected(lst, -1);
        assert_eq!(unsafe { &*lst }.selected, None);
        rffi_list_free(lst);
    }

    #[test]
    fn state_new_and_free() {
        let st = rffi_list_state_new();
        assert!(!st.is_null());
        assert_eq!(rffi_list_state_free(st), 0);
    }

    #[test]
    fn draw_null_handle_errors() {
        let lst = rffi_list_new();
        let rect = crate::layout::RffiRect::default();
        let code = rffi_list_draw(std::ptr::null_mut(), lst, rect);
        assert!(code < 0);
        rffi_list_free(lst);
    }
}
