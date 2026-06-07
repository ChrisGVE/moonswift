// File: Sources/CRatatuiFFI/include/ratatui_ffi.h
// Role: Umbrella header for the CRatatuiFFI C module. In production builds
//       (after F0.5) this file is replaced by the cbindgen-generated header
//       produced by `make shim` (F0.3). During bootstrap (source mode,
//       MOONSWIFT_SHIM_SOURCE=1) it is this hand-authored stub that declares
//       the full C ABI so RatatuiKit can compile without the Rust artifact.
//
//       The ABI follows the error protocol (ARCHITECTURE.md §5.2):
//         - Every entry point returns int32_t: 0 = ok, positive = soft
//         condition
//           (RFFI_TIMEOUT=1), negative = error code.
//         - Error detail lives in a thread-local string retrieved by
//           rffi_last_error(buf, cap).
//         - rffi_emergency_restore() is the single deliberate exception:
//           no return value, no thread-local, callable from signal handlers.
//         - Constructor functions return a pointer; NULL signals failure.
//
// Upstream: rust/ratatui-ffi (MoonSwift fork of holo-q/ratatui-ffi v0.2.x)
// Downstream: RatatuiKit (sole consumer of this header)

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Error codes (ARCHITECTURE.md §5.2)
// ---------------------------------------------------------------------------

/// Returned by rffi_poll_event when the timeout elapses with no event.
#define RFFI_TIMEOUT 1
/// Null pointer argument.
#define RFFI_ERR_NULL_PTR (-1)
/// Rust panic caught across the ABI boundary.
#define RFFI_ERR_PANIC (-2)
/// I/O error (terminal read/write failure).
#define RFFI_ERR_IO (-3)
/// rffi_terminal_init has not been called.
#define RFFI_ERR_NOT_INIT (-4)
/// A buffer or count exceeded its capacity.
#define RFFI_ERR_OVERFLOW (-5)
/// An argument value is out of the accepted range.
#define RFFI_ERR_INVALID_ARG (-6)

// ---------------------------------------------------------------------------
// Error protocol accessors
// ---------------------------------------------------------------------------

/// Copy the thread-local last-error string into buf (at most cap-1 bytes,
/// NUL-terminated). Returns the number of bytes written (excluding NUL), or
/// -1 if buf is NULL or cap is 0.
int32_t rffi_last_error(char *buf, size_t cap);

// ---------------------------------------------------------------------------
// Shared geometry type
// ---------------------------------------------------------------------------

/// A rectangle in terminal cell coordinates (0-based, columns x rows).
/// Matches ratatui::layout::Rect and is used by layout, widget draw, and
/// clear entry points.
typedef struct {
  uint16_t x;
  uint16_t y;
  uint16_t width;
  uint16_t height;
} RffiRect;

// ---------------------------------------------------------------------------
// Terminal lifecycle — render/terminal-class (UI thread only)
// ---------------------------------------------------------------------------

/// Enter raw mode, switch to the alternate screen, save the original termios
/// and tty fd in lock-free static storage, and set the atomic `initialized`
/// flag that arms rffi_emergency_restore (ARCHITECTURE.md §3f).
///
/// Returns an opaque heap-allocated *RffiTerminal pointer cast to void*.
/// Pass this handle to all render-class entry points. Returns NULL on failure
/// (error detail in rffi_last_error).
void *rffi_terminal_init(void);

/// Leave the alternate screen, show the cursor, restore the saved termios,
/// and clear the initialized flag. Frees the handle.
int32_t rffi_terminal_teardown(void *handle);

/// Suspend the terminal for $EDITOR handoff: leave alternate screen and
/// restore termios without clearing the initialized flag.
int32_t rffi_terminal_suspend(void *handle);

/// Resume after $EDITOR returns: re-enter raw mode and the alternate screen.
int32_t rffi_terminal_resume(void *handle);

/// Query the current terminal dimensions (columns x rows) into *cols_out and
/// *rows_out. Returns 0 on success, negative on failure.
int32_t rffi_terminal_size(uint16_t *cols_out, uint16_t *rows_out);

/// Emergency terminal restore callable from signal handlers. Performs a raw
/// write of reset sequences and best-effort tcsetattr. Is a guarded no-op
/// until rffi_terminal_init sets the initialized flag (async-signal-safe
/// atomic read). No return value, no thread-local, no locks, no allocation
/// (ARCHITECTURE.md §3f, §5.2).
void rffi_emergency_restore(void);

// ---------------------------------------------------------------------------
// Event pump — input-class (EventPump thread only)
// ---------------------------------------------------------------------------

/// Event kind tag. Matches RffiEventKind in Rust.
typedef int32_t RffiEventKind;
#define RFFI_EVENT_NONE 0
#define RFFI_EVENT_KEY 1
#define RFFI_EVENT_RESIZE 2
#define RFFI_EVENT_MOUSE 3
#define RFFI_EVENT_PASTE 4 // fork addition: bracketed-paste decoded string

/// Key modifier bit flags.
#define RFFI_MOD_NONE 0
#define RFFI_MOD_SHIFT 1
#define RFFI_MOD_ALT 2
#define RFFI_MOD_CTRL 4

/// Key code constants (RffiKeyCode values).
#define RFFI_KEY_CHAR 0
#define RFFI_KEY_ENTER 1
#define RFFI_KEY_BACKSPACE 2
#define RFFI_KEY_LEFT 3
#define RFFI_KEY_RIGHT 4
#define RFFI_KEY_UP 5
#define RFFI_KEY_DOWN 6
#define RFFI_KEY_HOME 7
#define RFFI_KEY_END 8
#define RFFI_KEY_PAGE_UP 9
#define RFFI_KEY_PAGE_DOWN 10
#define RFFI_KEY_TAB 11
#define RFFI_KEY_BACKTAB 12
#define RFFI_KEY_DELETE 13
#define RFFI_KEY_INSERT 14
#define RFFI_KEY_ESC 15
#define RFFI_KEY_F1 100
#define RFFI_KEY_F2 101
#define RFFI_KEY_F3 102
#define RFFI_KEY_F4 103
#define RFFI_KEY_F5 104
#define RFFI_KEY_F6 105
#define RFFI_KEY_F7 106
#define RFFI_KEY_F8 107
#define RFFI_KEY_F9 108
#define RFFI_KEY_F10 109
#define RFFI_KEY_F11 110
#define RFFI_KEY_F12 111
#define RFFI_KEY_UNKNOWN 255

/// Maximum byte length of the paste buffer embedded in RffiEvent.
#define RFFI_PASTE_BUF_BYTES 4096

/// Decoded keyboard/mouse/resize/paste event.
///
/// For RFFI_EVENT_KEY:    key_code contains an RFFI_KEY_* constant; if
///                        key_code == RFFI_KEY_CHAR then char_codepoint holds
///                        the Unicode codepoint; key_mods holds modifier bits.
/// For RFFI_EVENT_RESIZE: resize_cols / resize_rows hold the new dimensions.
/// For RFFI_EVENT_MOUSE:  mouse_col / mouse_row / mouse_button populated.
/// For RFFI_EVENT_PASTE:  paste_buf holds the decoded string (NUL-terminated);
///                        paste_len is the byte count (excluding NUL).
typedef struct {
  RffiEventKind kind;      // discriminant
  uint32_t key_code;       // RFFI_KEY_*; RFFI_EVENT_KEY only
  uint32_t char_codepoint; // Unicode codepoint; RFFI_KEY_CHAR only
  uint8_t key_mods;        // RFFI_MOD_* bitmask
  uint8_t _pad_key[3];
  uint16_t resize_cols; // RFFI_EVENT_RESIZE
  uint16_t resize_rows;
  uint16_t mouse_col; // RFFI_EVENT_MOUSE
  uint16_t mouse_row;
  uint8_t mouse_button;
  uint8_t _pad_mouse[3];
  uint32_t paste_len; // RFFI_EVENT_PASTE: byte count of paste_buf
  char paste_buf[RFFI_PASTE_BUF_BYTES]; // paste string (NUL-terminated)
} RffiEvent;

/// Poll for the next terminal event, blocking for at most timeout_ms
/// milliseconds. Returns 0 and writes into *out if an event is available;
/// returns RFFI_TIMEOUT (1) if the timeout elapsed with no event; returns a
/// negative error code on failure. Retries internally on EINTR.
int32_t rffi_poll_event(RffiEvent *out, int32_t timeout_ms);

// ---------------------------------------------------------------------------
// Cell-level buffer writes — render/terminal-class (UI thread only)
// ---------------------------------------------------------------------------

/// Flush the current ratatui frame to the terminal (diff + write). Call once
/// per render cycle after all widget and cell writes.
int32_t rffi_flush(void *handle);

/// Write a contiguous run of cells with uniform style into the current frame
/// buffer. start_col/start_row are 0-based. text is UTF-8; each grapheme
/// cluster occupies exactly one cell. text_len is the byte length.
/// fg/bg are packed as 0x00RRGGBB; 0xFFFFFFFF = terminal default colour.
int32_t rffi_write_cells(void *handle, uint16_t start_col, uint16_t start_row,
                         const char *text, size_t text_len, uint32_t fg,
                         uint32_t bg, uint8_t bold, uint8_t italic,
                         uint8_t underline);

/// Clear a rectangular region to the default style (blank cells).
int32_t rffi_clear_rect(void *handle, uint16_t col, uint16_t row,
                        uint16_t width, uint16_t height);

// ---------------------------------------------------------------------------
// Layout — compute child rectangles from constraint arrays
// ---------------------------------------------------------------------------

/// Constraint kind constants for rffi_layout_split.
#define RFFI_CONSTRAINT_LENGTH 0
#define RFFI_CONSTRAINT_PERCENTAGE 1
#define RFFI_CONSTRAINT_MIN 2
#define RFFI_CONSTRAINT_MAX 3
#define RFFI_CONSTRAINT_RATIO 4
#define RFFI_CONSTRAINT_FILL 5

/// Split a parent rectangle into len children according to the given
/// constraints.
///
///   direction — 0 = vertical stacking (rows), 1 = horizontal stacking (cols).
///   kinds     — array of len RFFI_CONSTRAINT_* constants.
///   values_a  — primary constraint values (length/percent/min/max/fill-weight/
///               ratio numerator).
///   values_b  — ratio denominators; may be NULL for non-Ratio constraints.
///   spacing   — gap in cells between children (usually 0).
///   out_rects — caller-allocated array of at least len RffiRect.
///   out_len   — capacity of out_rects; must be >= len.
///
/// Returns the number of rects written (== len on success), or a negative
/// error code on failure.
int32_t rffi_layout_split(RffiRect parent, uint32_t direction,
                          const uint32_t *kinds, const uint16_t *values_a,
                          const uint16_t *values_b, size_t len,
                          uint16_t spacing, RffiRect *out_rects,
                          size_t out_len);

// ---------------------------------------------------------------------------
// Shared style types (used by widget entry points)
// ---------------------------------------------------------------------------

/// Style modifier bit flags (RFFI_STYLE_MOD_*).
#define RFFI_STYLE_MOD_NONE 0x0000
#define RFFI_STYLE_MOD_BOLD 0x0001
#define RFFI_STYLE_MOD_DIM 0x0002
#define RFFI_STYLE_MOD_ITALIC 0x0004
#define RFFI_STYLE_MOD_UNDERLINE 0x0008
#define RFFI_STYLE_MOD_SLOW_BLINK 0x0010
#define RFFI_STYLE_MOD_RAPID_BLINK 0x0020
#define RFFI_STYLE_MOD_REVERSED 0x0040
#define RFFI_STYLE_MOD_HIDDEN 0x0080
#define RFFI_STYLE_MOD_CROSSED_OUT 0x0100

/// A foreground + background colour pair with modifier bits.
/// fg/bg are packed 0x00RRGGBB; 0xFFFFFFFF = terminal default.
typedef struct {
  uint32_t fg;
  uint32_t bg;
  uint16_t mods; // RFFI_STYLE_MOD_* bitmask
  uint16_t _pad;
} RffiStyle;

/// A styled span: a pointer to a NUL-terminated UTF-8 string plus a style.
/// The string must remain valid for the duration of the rffi_*_draw call.
typedef struct {
  const char *text_utf8;
  RffiStyle style;
} RffiSpan;

// ---------------------------------------------------------------------------
// Block (borders + title) — shared argument for widget setters
// ---------------------------------------------------------------------------

/// Border side bit flags passed to rffi_*_set_block.
#define RFFI_BORDER_NONE 0x00
#define RFFI_BORDER_TOP 0x01
#define RFFI_BORDER_RIGHT 0x02
#define RFFI_BORDER_BOTTOM 0x04
#define RFFI_BORDER_LEFT 0x08
#define RFFI_BORDER_ALL 0x0F

/// Border type constants passed to rffi_*_set_block.
#define RFFI_BORDER_TYPE_PLAIN 0
#define RFFI_BORDER_TYPE_ROUNDED 1
#define RFFI_BORDER_TYPE_DOUBLE 2
#define RFFI_BORDER_TYPE_THICK 3
#define RFFI_BORDER_TYPE_QUADRANT_INSIDE 4
#define RFFI_BORDER_TYPE_QUADRANT_OUTSIDE 5

// ---------------------------------------------------------------------------
// List widget — navigator panes, pickers, popups
// ---------------------------------------------------------------------------

/// Opaque list handle. Freed by rffi_list_free.
typedef struct RffiList RffiList;

/// Opaque list-state handle (external selection tracking). Freed by
/// rffi_list_state_free.
typedef struct RffiListState RffiListState;

/// List direction constants.
#define RFFI_LIST_TOP_TO_BOTTOM 0
#define RFFI_LIST_BOTTOM_TO_TOP 1

/// Highlight spacing constants.
#define RFFI_HIGHLIGHT_SPACING_WHEN_SELECTED 0
#define RFFI_HIGHLIGHT_SPACING_ALWAYS 1
#define RFFI_HIGHLIGHT_SPACING_NEVER 2

/// Create a new empty list handle. Returns NULL on failure.
RffiList *rffi_list_new(void);

/// Free a list handle.
int32_t rffi_list_free(RffiList *lst);

/// Append a plain-text item (single uniform style).
int32_t rffi_list_append_item(RffiList *lst, const char *text_utf8,
                              RffiStyle style);

/// Append a styled-span item (mixed styles per item).
int32_t rffi_list_append_item_spans(RffiList *lst, const RffiSpan *spans,
                                    size_t len);

/// Set the block (borders + title) for this list.
int32_t rffi_list_set_block(RffiList *lst, uint8_t borders_bits,
                            uint32_t border_type, uint16_t pad_left,
                            uint16_t pad_top, uint16_t pad_right,
                            uint16_t pad_bottom, const RffiSpan *title_spans,
                            size_t title_len);

/// Set the highlight style for the selected item.
int32_t rffi_list_set_highlight_style(RffiList *lst, RffiStyle style);

/// Set the highlight symbol prefix string (NUL-terminated UTF-8).
int32_t rffi_list_set_highlight_symbol(RffiList *lst, const char *symbol_utf8);

/// Set the direction: RFFI_LIST_TOP_TO_BOTTOM or RFFI_LIST_BOTTOM_TO_TOP.
int32_t rffi_list_set_direction(RffiList *lst, uint32_t direction);

/// Set the scroll offset (number of items scrolled past the top).
int32_t rffi_list_set_scroll_offset(RffiList *lst, size_t offset);

/// Set the selected item index (SIZE_MAX = no selection).
int32_t rffi_list_set_selected(RffiList *lst, size_t index);

/// Draw the list widget into a terminal frame buffer rect.
int32_t rffi_list_draw(void *handle, const RffiList *lst, RffiRect rect);

// --- List state (external selection tracking) ---

/// Create a new list-state handle. Returns NULL on failure.
RffiListState *rffi_list_state_new(void);

/// Free a list-state handle.
int32_t rffi_list_state_free(RffiListState *st);

/// Set the selected item index in an external list state.
int32_t rffi_list_state_set_selected(RffiListState *st, size_t index);

/// Set the scroll offset in an external list state.
int32_t rffi_list_state_set_offset(RffiListState *st, size_t offset);

/// Draw the list using an explicit external list state for selection tracking.
int32_t rffi_list_draw_stateful(void *handle, const RffiList *lst,
                                const RffiListState *st, RffiRect rect);

// ---------------------------------------------------------------------------
// Paragraph widget — scrollable text content (Output / Diagnostics tabs)
// ---------------------------------------------------------------------------

/// Opaque paragraph handle. Freed by rffi_paragraph_free.
typedef struct RffiParagraph RffiParagraph;

/// Create a new empty paragraph handle. Returns NULL on failure.
RffiParagraph *rffi_paragraph_new(void);

/// Free a paragraph handle.
int32_t rffi_paragraph_free(RffiParagraph *para);

/// Append a plain-text line (single uniform style).
int32_t rffi_paragraph_append_line(RffiParagraph *para, const char *text_utf8,
                                   RffiStyle style);

/// Append a styled-span line (mixed styles).
int32_t rffi_paragraph_append_line_spans(RffiParagraph *para,
                                         const RffiSpan *spans, size_t len);

/// Insert a blank line separator.
int32_t rffi_paragraph_line_break(RffiParagraph *para);

/// Set text alignment: 0 = Left, 1 = Center, 2 = Right.
int32_t rffi_paragraph_set_alignment(RffiParagraph *para, uint32_t align);

/// Enable word-wrapping. trim != 0 trims leading whitespace.
int32_t rffi_paragraph_set_wrap(RffiParagraph *para, uint8_t trim);

/// Set scroll offset (x = column offset, y = row offset).
int32_t rffi_paragraph_set_scroll(RffiParagraph *para, uint16_t x, uint16_t y);

/// Set the base style applied to the paragraph as a whole.
int32_t rffi_paragraph_set_style(RffiParagraph *para, RffiStyle style);

/// Set the block (borders + title) for this paragraph.
int32_t rffi_paragraph_set_block(RffiParagraph *para, uint8_t borders_bits,
                                 uint32_t border_type, uint16_t pad_left,
                                 uint16_t pad_top, uint16_t pad_right,
                                 uint16_t pad_bottom,
                                 const RffiSpan *title_spans, size_t title_len);

/// Draw the paragraph into a terminal frame buffer rect.
int32_t rffi_paragraph_draw(void *handle, const RffiParagraph *para,
                            RffiRect rect);

// ---------------------------------------------------------------------------
// Tabs widget — tab bar (Output / Diagnostics / Debug)
// ---------------------------------------------------------------------------

/// Opaque tabs handle. Freed by rffi_tabs_free.
typedef struct RffiTabs RffiTabs;

/// Combined selected + unselected tab styles.
typedef struct {
  RffiStyle selected;
  RffiStyle unselected;
} RffiTabsStyles;

/// Create a new empty tabs handle. Returns NULL on failure.
RffiTabs *rffi_tabs_new(void);

/// Free a tabs handle.
int32_t rffi_tabs_free(RffiTabs *t);

/// Append a tab title (NUL-terminated UTF-8).
int32_t rffi_tabs_append_title(RffiTabs *t, const char *title_utf8);

/// Set the index of the currently selected tab.
int32_t rffi_tabs_set_selected(RffiTabs *t, uint16_t index);

/// Set both selected and unselected tab styles in one call.
int32_t rffi_tabs_set_styles(RffiTabs *t, RffiTabsStyles styles);

/// Set the block (borders + title) for the tabs bar.
int32_t rffi_tabs_set_block(RffiTabs *t, uint8_t borders_bits,
                            uint32_t border_type, uint16_t pad_left,
                            uint16_t pad_top, uint16_t pad_right,
                            uint16_t pad_bottom, const RffiSpan *title_spans,
                            size_t title_len);

/// Draw the tabs bar into a terminal frame buffer rect.
int32_t rffi_tabs_draw(void *handle, const RffiTabs *t, RffiRect rect);

// ---------------------------------------------------------------------------
// Clear widget — erase a rect via ratatui Clear widget
// ---------------------------------------------------------------------------

/// Render the ratatui Clear widget over a rect (clears with background style).
int32_t rffi_clear_rect_widget(void *handle, RffiRect rect);

#ifdef __cplusplus
} // extern "C"
#endif
