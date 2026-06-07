#ifndef RATATUI_FFI_H
#define RATATUI_FFI_H

#pragma once

#include "stdbool.h"
#include "stddef.h"
#include "stdint.h"
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Returned by rffi_poll_event when the timeout elapsed with no event.
 * (Positive, distinct from error codes which are all negative.)
 */
#define RFFI_TIMEOUT 1

/**
 * Null pointer passed to an entry point that requires a valid pointer.
 */
#define RFFI_ERR_NULL_PTR -1

/**
 * A Rust panic occurred inside an ffi_guard!() body. The panic message is
 * available via rffi_last_error().
 */
#define RFFI_ERR_PANIC -2

/**
 * An I/O error from crossterm or the OS (raw-mode toggle, write, etc.).
 */
#define RFFI_ERR_IO -3

/**
 * Terminal is not initialised; rffi_terminal_init must be called first.
 */
#define RFFI_ERR_NOT_INIT -4

/**
 * An internal size or bounds overflow.
 */
#define RFFI_ERR_OVERFLOW -5

/**
 * Invalid argument (misaligned pointer, zero capacity, invalid UTF-8, etc.).
 */
#define RFFI_ERR_INVALID_ARG -6

/**
 * Maximum bytes stored inline for a bracketed-paste payload. Pastes longer
 * than this are truncated (NUL-terminated). Swift's EventPump coalesces
 * multi-chunk pastes before passing them up; this buffer handles typical
 * single-chunk pastes (a few thousand characters at most).
 */
#define PASTE_BUF_BYTES 4096

#define NONE 0

#define SHIFT (1 << 0)

#define ALT (1 << 1)

#define CTRL (1 << 2)

/**
 * Fixed cell count (value_a = length).
 */
#define LENGTH 0

/**
 * Percentage of the parent (value_a = percent 0–100).
 */
#define PERCENTAGE 1

/**
 * Minimum cell count (value_a = min).
 */
#define MIN 2

/**
 * Maximum cell count (value_a = max).
 */
#define MAX 3

/**
 * Ratio — value_a / value_b of the parent.
 */
#define RATIO 4

/**
 * Fill remaining space proportionally (value_a = weight, 1 if unused).
 */
#define FILL 5

#define BOLD (1 << 0)

#define ITALIC (1 << 1)

#define UNDERLINE (1 << 2)

#define DIM (1 << 3)

#define CROSSED (1 << 4)

#define REVERSED (1 << 5)

#define TOP (1 << 0)

#define RIGHT (1 << 1)

#define BOTTOM (1 << 2)

#define LEFT (1 << 3)

#define ALL (((TOP | RIGHT) | BOTTOM) | LEFT)

/**
 * Opaque list handle. Heap-allocated; Swift holds a `*mut RffiList`.
 */
typedef struct RffiList RffiList;

/**
 * Opaque list-state handle for stateful rendering.
 */
typedef struct RffiListState RffiListState;

/**
 * Opaque paragraph handle. Heap-allocated; Swift holds `*mut RffiParagraph`.
 */
typedef struct RffiParagraph RffiParagraph;

/**
 * Opaque tabs handle. Heap-allocated; Swift holds `*mut RffiTabs`.
 */
typedef struct RffiTabs RffiTabs;

/**
 * Decoded terminal event. Sent from the shim to RatatuiKit (EventPump).
 *
 * Layout is fixed — cbindgen generates the matching C declaration in
 * ratatui_ffi.h. All fields beyond `kind` are discriminant-dependent.
 */
typedef struct RffiEvent {
  /**
   * RffiEventKind discriminant.
   */
  uint32_t kind;
  /**
   * RffiKeyCode for the pressed key.
   */
  uint32_t key_code;
  /**
   * Unicode codepoint for Char keys; 0 for all others.
   */
  uint32_t key_char;
  /**
   * Modifier bitfield (key_mods::* constants).
   */
  uint8_t key_mods;
  uint8_t _pad0[3];
  uint16_t resize_cols;
  uint16_t resize_rows;
  uint16_t mouse_col;
  uint16_t mouse_row;
  /**
   * RffiMouseKind discriminant.
   */
  uint32_t mouse_kind;
  /**
   * RffiMouseButton discriminant.
   */
  uint32_t mouse_button;
  /**
   * Modifier bits for the mouse event.
   */
  uint8_t mouse_mods;
  uint8_t _pad1[3];
  /**
   * UTF-8 paste text, NUL-terminated, at most PASTE_BUF_BYTES bytes.
   */
  char paste_buf[PASTE_BUF_BYTES];
  /**
   * Actual byte count in paste_buf (excluding NUL terminator).
   */
  uint32_t paste_len;
  uint8_t _pad2[4];
} RffiEvent;

/**
 * A rectangle in terminal cell coordinates (0-based, columns × rows).
 */
typedef struct RffiRect {
  uint16_t x;
  uint16_t y;
  uint16_t width;
  uint16_t height;
} RffiRect;

/**
 * Style encoding: fg/bg as 0x00RRGGBB (0xFFFFFFFF = terminal default),
 * mods as the RffiStyleMods bitfield.
 */
typedef struct RffiStyle {
  uint32_t fg;
  uint32_t bg;
  uint16_t mods;
  uint16_t _pad;
} RffiStyle;

/**
 * A span: a NUL-terminated UTF-8 string pointer + style.
 */
typedef struct RffiSpan {
  const char *text_utf8;
  struct RffiStyle style;
} RffiSpan;

/**
 * Combined selected + unselected styles — convenience for Swift callers.
 */
typedef struct RffiTabsStyles {
  struct RffiStyle selected;
  struct RffiStyle unselected;
} RffiTabsStyles;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Copy the thread-local last-error string into `buf` (at most `cap - 1`
 * bytes, NUL-terminated). Returns the number of bytes written (excluding
 * NUL), or -1 if `buf` is NULL or `cap` is 0.
 *
 * Call this immediately after any rffi_* function returns nonzero to
 * retrieve a human-readable error description.
 */
int32_t rffi_last_error(char *buf, size_t cap);

/**
 * Flush the current ratatui frame (diff + write). Call once per render cycle
 * after all widget and cell writes.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_flush(void *handle);

/**
 * Write a run of cells with uniform style into the current frame buffer.
 *
 * Parameters:
 *   handle    — opaque RffiTerminal pointer from rffi_terminal_init.
 *   start_col — 0-based column of the first cell.
 *   start_row — 0-based row.
 *   text      — UTF-8 string; each grapheme cluster occupies exactly one cell.
 *   text_len  — byte length of `text` (not the grapheme count).
 *   fg        — foreground colour: 0x00RRGGBB for RGB; 0xFFFFFFFF = default.
 *   bg        — background colour: same encoding.
 *   bold      — 1 = bold; 0 = normal.
 *   italic    — 1 = italic.
 *   underline — 1 = underline.
 *
 * Returns 0 on success.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_write_cells(void *handle, uint16_t start_col, uint16_t start_row,
                         const char *text, size_t text_len, uint32_t fg,
                         uint32_t bg, uint8_t bold, uint8_t italic,
                         uint8_t underline);

/**
 * Clear a rectangular region to the terminal default style (blank cells).
 *
 * Parameters:
 *   handle — opaque RffiTerminal pointer.
 *   col, row, width, height — 0-based rectangle in cell coordinates.
 *
 * Returns 0 on success.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_clear_rect(void *handle, uint16_t col, uint16_t row,
                        uint16_t width, uint16_t height);

/**
 * Poll for the next terminal event, blocking for at most `timeout_ms`
 * milliseconds.
 *
 * Return values:
 *   0           — event decoded; `*out` is valid.
 *   RFFI_TIMEOUT (1) — timeout elapsed; `*out` is zeroed.
 *   negative    — I/O error; call rffi_last_error() for detail.
 *
 * Retries internally on EINTR (SIGTSTP, debugger attach) — the pump loop
 * never sees EINTR as an error (ARCHITECTURE.md §5.2).
 *
 * Thread class: input-class (EventPump thread only).
 */
int32_t rffi_poll_event(struct RffiEvent *out, int32_t timeout_ms);

/**
 * Split a parent rectangle into `len` children according to the given
 * constraints, writing results into `out_rects[0..len]`.
 *
 * Parameters:
 *   parent    — the rectangle to split.
 *   direction — 0 = vertical (horizontal stacks), 1 = horizontal (side by
 * side). kinds     — array of `len` constraint-kind constants
 * (constraint_kind::*). values_a  — primary values (length / percent / min /
 * max / fill-weight / ratio numerator). values_b  — secondary values; only used
 * for RATIO (denominator); may be NULL for all other kinds (treated as all-1s).
 *   spacing   — gap in cells between each child (usually 0).
 *   out_rects — caller-allocated output array of at least `len` RffiRect.
 *   out_len   — capacity of `out_rects`; must be >= `len`.
 *
 * Returns the number of rects written (== `len` on success), or a negative
 * error code on failure.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_layout_split(struct RffiRect parent, uint32_t direction,
                          const uint32_t *kinds, const uint16_t *values_a,
                          const uint16_t *values_b, size_t len,
                          uint16_t spacing, struct RffiRect *out_rects,
                          size_t out_len);

/**
 * Enter raw mode, switch to the alternate screen, hide the cursor, save the
 * original termios and tty fd for emergency restore, and set the `INITIALIZED`
 * flag that arms rffi_emergency_restore.
 *
 * Returns a heap-allocated `*mut RffiTerminal` cast to `*mut ()`. Swift stores
 * this opaque pointer and passes it back on every render-class call.
 * Returns NULL on failure (error detail in rffi_last_error).
 *
 * Thread class: render/terminal (UI thread only).
 */
void *rffi_terminal_init(void);

/**
 * Leave the alternate screen, show the cursor, restore termios, and free the
 * terminal handle. After this call the pointer is invalid.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_terminal_teardown(void *handle);

/**
 * Suspend the terminal for the $EDITOR handoff: leave the alternate screen
 * and restore termios WITHOUT clearing INITIALIZED. The pump must be parked
 * before this call (ARCHITECTURE.md §5.2 pump-park handshake).
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_terminal_suspend(void *handle);

/**
 * Resume after the editor returns: re-enter raw mode and the alternate
 * screen. Unparks the pump after this returns (Swift side orchestrates).
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_terminal_resume(void *handle);

/**
 * Emergency terminal restore callable from signal handlers (ARCHITECTURE.md
 * §3f, §5.2). Performs:
 *   1. Atomic read of INITIALIZED — if false, returns immediately (no-op).
 *   2. write(2) of `ESC[?1049l ESC[?25h ESC[0m` to the saved tty fd.
 *   3. best-effort tcsetattr to restore the saved termios.
 *
 * This function:
 *   - Returns nothing and stores nothing (no thread-local, no allocation).
 *   - Uses only async-signal-safe primitives (write(2) is safe; tcsetattr
 *     is technically not, but the worst case is a silent no-op).
 *   - Is a guarded no-op until rffi_terminal_init sets INITIALIZED.
 *
 * Never call this from normal code paths; it is the crash-path primitive.
 */
void rffi_emergency_restore(void);

/**
 * Query the current terminal dimensions. Returns 0 and writes into
 * *cols_out / *rows_out on success.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_terminal_size(uint16_t *cols_out, uint16_t *rows_out);

/**
 * Clear (erase) a rectangular region to the terminal default background.
 *
 * Parameters:
 *   handle — opaque RffiTerminal pointer from rffi_terminal_init.
 *   rect   — the region to clear in cell coordinates.
 *
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_clear_rect_widget(void *handle, struct RffiRect rect);

/**
 * Create a new empty list handle. Returns NULL on OOM (infeasible in practice).
 */
struct RffiList *rffi_list_new(void);

/**
 * Free a list handle.
 */
int32_t rffi_list_free(struct RffiList *lst);

/**
 * Create a new list-state handle (for stateful highlight rendering).
 */
struct RffiListState *rffi_list_state_new(void);

/**
 * Free a list-state handle.
 */
int32_t rffi_list_state_free(struct RffiListState *st);

/**
 * Append a plain-text item (single uniform style) to the list.
 */
int32_t rffi_list_append_item(struct RffiList *lst, const char *text_utf8,
                              struct RffiStyle style);

/**
 * Append a span-array item (mixed styles on one line) to the list.
 */
int32_t rffi_list_append_item_spans(struct RffiList *lst,
                                    const struct RffiSpan *spans, size_t len);

/**
 * Set the selected item index. Pass -1 to clear the selection.
 */
int32_t rffi_list_set_selected(struct RffiList *lst, int32_t index);

/**
 * Set the highlight style applied to the selected row.
 */
int32_t rffi_list_set_highlight_style(struct RffiList *lst,
                                      struct RffiStyle style);

/**
 * Set the highlight symbol prefix (e.g. "» "). NULL clears it.
 */
int32_t rffi_list_set_highlight_symbol(struct RffiList *lst,
                                       const char *sym_utf8);

/**
 * Set scroll offset within the list.
 */
int32_t rffi_list_set_scroll_offset(struct RffiList *lst, size_t offset);

/**
 * Set item direction: 0 = TopToBottom (default), 1 = BottomToTop.
 */
int32_t rffi_list_set_direction(struct RffiList *lst, uint32_t dir);

/**
 * Set the block (borders + title) for this list.
 *
 * border_type: 0 = Plain, 1 = Rounded, 2 = Double, 3 = Thick.
 * borders_bits: bitfield (see block::border_bits).
 */
int32_t rffi_list_set_block(struct RffiList *lst, uint8_t borders_bits,
                            uint32_t border_type, uint16_t pad_left,
                            uint16_t pad_top, uint16_t pad_right,
                            uint16_t pad_bottom,
                            const struct RffiSpan *title_spans,
                            size_t title_len);

/**
 * Set the list-state's selected index. -1 = no selection.
 */
int32_t rffi_list_state_set_selected(struct RffiListState *st, int32_t index);

/**
 * Set the list-state scroll offset.
 */
int32_t rffi_list_state_set_offset(struct RffiListState *st, size_t offset);

/**
 * Draw the list into a rect of the terminal frame buffer.
 *
 * If the list has a selected index, renders with stateful highlighting.
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_list_draw(void *handle, const struct RffiList *lst,
                       struct RffiRect rect);

/**
 * Draw the list with an explicit list-state (external selection tracking).
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_list_draw_stateful(void *handle, const struct RffiList *lst,
                                const struct RffiListState *st,
                                struct RffiRect rect);

/**
 * Create a new empty paragraph.
 */
struct RffiParagraph *rffi_paragraph_new(void);

/**
 * Free a paragraph handle.
 */
int32_t rffi_paragraph_free(struct RffiParagraph *para);

/**
 * Append a plain-text line (single uniform style).
 */
int32_t rffi_paragraph_append_line(struct RffiParagraph *para,
                                   const char *text_utf8,
                                   struct RffiStyle style);

/**
 * Append a span-array line (mixed styles).
 */
int32_t rffi_paragraph_append_line_spans(struct RffiParagraph *para,
                                         const struct RffiSpan *spans,
                                         size_t len);

/**
 * Insert a blank line separator.
 */
int32_t rffi_paragraph_line_break(struct RffiParagraph *para);

/**
 * Set text alignment: 0 = Left, 1 = Center, 2 = Right.
 */
int32_t rffi_paragraph_set_alignment(struct RffiParagraph *para,
                                     uint32_t align);

/**
 * Enable or disable word-wrapping. trim = 1 trims leading whitespace.
 */
int32_t rffi_paragraph_set_wrap(struct RffiParagraph *para, uint8_t trim);

/**
 * Set scroll offset (x = column offset, y = row offset).
 */
int32_t rffi_paragraph_set_scroll(struct RffiParagraph *para, uint16_t x,
                                  uint16_t y);

/**
 * Set the base style applied to the paragraph as a whole.
 */
int32_t rffi_paragraph_set_style(struct RffiParagraph *para,
                                 struct RffiStyle style);

/**
 * Set the block (borders + title) for this paragraph.
 */
int32_t rffi_paragraph_set_block(struct RffiParagraph *para,
                                 uint8_t borders_bits, uint32_t border_type,
                                 uint16_t pad_left, uint16_t pad_top,
                                 uint16_t pad_right, uint16_t pad_bottom,
                                 const struct RffiSpan *title_spans,
                                 size_t title_len);

/**
 * Draw the paragraph into a rect of the terminal frame buffer.
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_paragraph_draw(void *handle, const struct RffiParagraph *para,
                            struct RffiRect rect);

/**
 * Create a new empty tabs handle.
 */
struct RffiTabs *rffi_tabs_new(void);

/**
 * Free a tabs handle.
 */
int32_t rffi_tabs_free(struct RffiTabs *t);

/**
 * Append a tab title (UTF-8 NUL-terminated string).
 */
int32_t rffi_tabs_append_title(struct RffiTabs *t, const char *title_utf8);

/**
 * Set the index of the currently selected tab.
 */
int32_t rffi_tabs_set_selected(struct RffiTabs *t, uint16_t index);

/**
 * Set both selected and unselected tab styles in one call.
 */
int32_t rffi_tabs_set_styles(struct RffiTabs *t, struct RffiTabsStyles styles);

/**
 * Set the block (borders + title) for the tabs bar.
 */
int32_t rffi_tabs_set_block(struct RffiTabs *t, uint8_t borders_bits,
                            uint32_t border_type, uint16_t pad_left,
                            uint16_t pad_top, uint16_t pad_right,
                            uint16_t pad_bottom,
                            const struct RffiSpan *title_spans,
                            size_t title_len);

/**
 * Draw the tabs bar into a rect of the terminal frame buffer.
 * Thread class: render/terminal (UI thread only).
 */
int32_t rffi_tabs_draw(void *handle, const struct RffiTabs *t,
                       struct RffiRect rect);

#ifdef __cplusplus
} // extern "C"
#endif // __cplusplus

#endif /* RATATUI_FFI_H */
