// File: rust/ratatui-ffi/src/lib.rs
// Role: Crate root — module declarations and public re-exports for the
//       trimmed MoonSwift fork of holo-q/ratatui-ffi.
//
// Fork changes from upstream (recorded in NOTICE):
//   - crate-type: "staticlib" added alongside "cdylib" for XCFramework
//     consumption by Swift (ARCHITECTURE.md §5.4).
//   - Entire surface restructured to the rffi_ naming convention with i32
//     error protocol and ffi_guard! panic safety (ARCHITECTURE.md §5.2).
//   - TRIM: Table, Chart, BarChart, Sparkline, Gauge, LineGauge, Canvas,
//     Scrollbar, logo/mascot widgets removed (PRD §4.5).
//   - ADD: bracketed-paste event kind, suspend/resume entry points,
//     rffi_emergency_restore (ARCHITECTURE.md §3f), rffi_last_error,
//     ffi_guard! macro (guard.rs), i32 error-code enum (error.rs),
//     cell-region batch writes (cells.rs), rffi_layout_split (layout.rs).
//
// Upstream: holo-q/ratatui-ffi v0.2.x (MIT OR Apache-2.0)
//           ratatui 0.29, crossterm 0.28.1 (pinned — single crossterm)
// Downstream: CRatatuiFFI C module → RatatuiKit → MoonSwiftTUI

// ---------------------------------------------------------------------------
// libc — required by terminal.rs for async-signal-safe primitives
// ---------------------------------------------------------------------------

extern crate libc;

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

// Infrastructure modules (ordered by dependency: error ← guard ← rest)
pub mod error;
pub mod guard;

// Functional modules
pub mod cells;
pub mod events;
pub mod layout;
pub mod terminal;
pub mod widgets;

// ---------------------------------------------------------------------------
// Re-exports — public C ABI types and entry points
// ---------------------------------------------------------------------------

// Guard / error
pub use guard::rffi_last_error;

// Terminal lifecycle
pub use terminal::{
    rffi_emergency_restore, rffi_terminal_init, rffi_terminal_resume, rffi_terminal_size,
    rffi_terminal_suspend, rffi_terminal_teardown,
};

// Event pump
pub use events::{rffi_poll_event, RffiEvent, RffiEventKind, RffiKeyCode};

// Layout
pub use layout::{rffi_layout_split, RffiRect};

// Cell writes
pub use cells::{rffi_clear_rect, rffi_flush, rffi_write_cells};

// Widget handle types (opaque to C callers; Swift code references by pointer)
pub use widgets::list::{
    rffi_list_append_item, rffi_list_append_item_spans, rffi_list_draw, rffi_list_draw_stateful,
    rffi_list_free, rffi_list_new, rffi_list_set_block, rffi_list_set_direction,
    rffi_list_set_highlight_style, rffi_list_set_highlight_symbol, rffi_list_set_scroll_offset,
    rffi_list_set_selected, rffi_list_state_free, rffi_list_state_new, rffi_list_state_set_offset,
    rffi_list_state_set_selected, RffiList, RffiListState,
};

pub use widgets::paragraph::{
    rffi_paragraph_append_line, rffi_paragraph_append_line_spans, rffi_paragraph_draw,
    rffi_paragraph_free, rffi_paragraph_line_break, rffi_paragraph_new,
    rffi_paragraph_set_alignment, rffi_paragraph_set_block, rffi_paragraph_set_scroll,
    rffi_paragraph_set_style, rffi_paragraph_set_wrap, RffiParagraph,
};

pub use widgets::tabs::{
    rffi_tabs_append_title, rffi_tabs_draw, rffi_tabs_free, rffi_tabs_new, rffi_tabs_set_block,
    rffi_tabs_set_selected, rffi_tabs_set_styles, RffiTabs, RffiTabsStyles,
};

pub use widgets::clear::rffi_clear_rect_widget;

pub use widgets::block::{RffiSpan, RffiStyle};
