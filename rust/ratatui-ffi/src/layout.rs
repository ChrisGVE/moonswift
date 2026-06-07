// File: rust/ratatui-ffi/src/layout.rs
// Role: Layout splitting — compute rectangular regions from constraints and
//       a parent area. Used by RatatuiKit to split the terminal into panes
//       (navigator / code pane / bottom pane, etc.).
//
// All entry points follow the rffi_ naming convention and the i32 error
// protocol (ARCHITECTURE.md §5.2): 0 = ok / count, negative = error code.
//
// Upstream: ratatui::layout (Layout, Constraint, Direction, Rect)
// Downstream: lib.rs (re-exports), RatatuiKit/Layout.swift

use crate::error::RFFI_ERR_INVALID_ARG;
use crate::ffi_guard;
use crate::guard::set_last_error;
use ratatui::layout::{Constraint, Direction, Layout, Rect};

// ---------------------------------------------------------------------------
// RffiRect — C-visible rectangle (identical to ratatui::layout::Rect)
// ---------------------------------------------------------------------------

/// A rectangle in terminal cell coordinates (0-based, columns × rows).
#[repr(C)]
#[derive(Copy, Clone, Default, Debug, PartialEq, Eq)]
pub struct RffiRect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

// ---------------------------------------------------------------------------
// Constraint kind constants
// ---------------------------------------------------------------------------

/// Constraint-kind values for the `kinds` array in rffi_layout_split.
pub mod constraint_kind {
    /// Fixed cell count (value_a = length).
    pub const LENGTH: u32 = 0;
    /// Percentage of the parent (value_a = percent 0–100).
    pub const PERCENTAGE: u32 = 1;
    /// Minimum cell count (value_a = min).
    pub const MIN: u32 = 2;
    /// Maximum cell count (value_a = max).
    pub const MAX: u32 = 3;
    /// Ratio — value_a / value_b of the parent.
    pub const RATIO: u32 = 4;
    /// Fill remaining space proportionally (value_a = weight, 1 if unused).
    pub const FILL: u32 = 5;
}

// ---------------------------------------------------------------------------
// rffi_layout_split
// ---------------------------------------------------------------------------

/// Split a parent rectangle into `len` children according to the given
/// constraints, writing results into `out_rects[0..len]`.
///
/// Parameters:
///   parent    — the rectangle to split.
///   direction — 0 = vertical (horizontal stacks), 1 = horizontal (side by side).
///   kinds     — array of `len` constraint-kind constants (constraint_kind::*).
///   values_a  — primary values (length / percent / min / max / fill-weight /
///               ratio numerator).
///   values_b  — secondary values; only used for RATIO (denominator); may be
///               NULL for all other kinds (treated as all-1s).
///   spacing   — gap in cells between each child (usually 0).
///   out_rects — caller-allocated output array of at least `len` RffiRect.
///   out_len   — capacity of `out_rects`; must be >= `len`.
///
/// Returns the number of rects written (== `len` on success), or a negative
/// error code on failure.
///
/// Thread class: render/terminal (UI thread only).
#[no_mangle]
pub extern "C" fn rffi_layout_split(
    parent: RffiRect,
    direction: u32,
    kinds: *const u32,
    values_a: *const u16,
    values_b: *const u16,
    len: usize,
    spacing: u16,
    out_rects: *mut RffiRect,
    out_len: usize,
) -> i32 {
    ffi_guard!("rffi_layout_split", {
        if kinds.is_null() || values_a.is_null() || out_rects.is_null() {
            set_last_error("rffi_layout_split: null pointer argument");
            return crate::error::RFFI_ERR_NULL_PTR;
        }
        if len == 0 || out_len < len {
            set_last_error(format!(
                "rffi_layout_split: len={len} out_len={out_len}: insufficient output capacity"
            ));
            return RFFI_ERR_INVALID_ARG;
        }

        let kinds_slice = unsafe { std::slice::from_raw_parts(kinds, len) };
        let a_slice = unsafe { std::slice::from_raw_parts(values_a, len) };
        let b_slice: &[u16] = if values_b.is_null() {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(values_b, len) }
        };

        let mut constraints: Vec<Constraint> = Vec::with_capacity(len);
        for i in 0..len {
            let kind = kinds_slice[i];
            let a = a_slice[i];
            let constraint = match kind {
                constraint_kind::LENGTH => Constraint::Length(a),
                constraint_kind::PERCENTAGE => Constraint::Percentage(a),
                constraint_kind::MIN => Constraint::Min(a),
                constraint_kind::MAX => Constraint::Max(a),
                constraint_kind::RATIO => {
                    let b = b_slice.get(i).copied().unwrap_or(1).max(1);
                    Constraint::Ratio(a as u32, b as u32)
                }
                constraint_kind::FILL => Constraint::Fill(a),
                _ => {
                    set_last_error(format!("rffi_layout_split: unknown constraint kind {kind}"));
                    return RFFI_ERR_INVALID_ARG;
                }
            };
            constraints.push(constraint);
        }

        let rt_direction = if direction == 1 {
            Direction::Horizontal
        } else {
            Direction::Vertical
        };

        let parent_rect = Rect {
            x: parent.x,
            y: parent.y,
            width: parent.width,
            height: parent.height,
        };

        let layout = Layout::new(rt_direction, constraints).spacing(spacing);
        let chunks = layout.split(parent_rect);

        let n = chunks.len().min(out_len);
        for i in 0..n {
            let r = chunks[i];
            unsafe {
                *out_rects.add(i) = RffiRect {
                    x: r.x,
                    y: r.y,
                    width: r.width,
                    height: r.height,
                };
            }
        }

        n as i32
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use constraint_kind::*;

    fn split(
        parent: RffiRect,
        dir: u32,
        kinds: &[u32],
        a: &[u16],
        b: Option<&[u16]>,
        spacing: u16,
    ) -> Vec<RffiRect> {
        let mut out = vec![RffiRect::default(); kinds.len()];
        let n = rffi_layout_split(
            parent,
            dir,
            kinds.as_ptr(),
            a.as_ptr(),
            b.map(|s| s.as_ptr()).unwrap_or(std::ptr::null()),
            kinds.len(),
            spacing,
            out.as_mut_ptr(),
            out.len(),
        );
        assert!(n >= 0, "split returned error {n}");
        out[..n as usize].to_vec()
    }

    #[test]
    fn vertical_split_two_equal_halves() {
        let parent = RffiRect {
            x: 0,
            y: 0,
            width: 100,
            height: 80,
        };
        let rects = split(parent, 0, &[PERCENTAGE, PERCENTAGE], &[50, 50], None, 0);
        assert_eq!(rects.len(), 2);
        assert_eq!(rects[0].y, 0);
        assert_eq!(rects[1].y, 40);
        assert_eq!(rects[0].height, 40);
        assert_eq!(rects[1].height, 40);
    }

    #[test]
    fn horizontal_split_fixed_lengths() {
        let parent = RffiRect {
            x: 0,
            y: 0,
            width: 80,
            height: 24,
        };
        let rects = split(parent, 1, &[LENGTH, LENGTH, LENGTH], &[18, 42, 20], None, 0);
        assert_eq!(rects.len(), 3);
        assert_eq!(rects[0].width, 18);
        assert_eq!(rects[1].width, 42);
        assert_eq!(rects[2].width, 20);
    }

    #[test]
    fn null_kinds_returns_error() {
        let parent = RffiRect {
            x: 0,
            y: 0,
            width: 80,
            height: 24,
        };
        let a = [50u16, 50u16];
        let mut out = [RffiRect::default(); 2];
        let n = rffi_layout_split(
            parent,
            0,
            std::ptr::null(),
            a.as_ptr(),
            std::ptr::null(),
            2,
            0,
            out.as_mut_ptr(),
            2,
        );
        assert!(n < 0);
    }

    #[test]
    fn out_len_less_than_len_returns_error() {
        let parent = RffiRect {
            x: 0,
            y: 0,
            width: 80,
            height: 24,
        };
        let kinds = [PERCENTAGE, PERCENTAGE];
        let a = [50u16, 50u16];
        let mut out = [RffiRect::default(); 1]; // too small
        let n = rffi_layout_split(
            parent,
            0,
            kinds.as_ptr(),
            a.as_ptr(),
            std::ptr::null(),
            2,
            0,
            out.as_mut_ptr(),
            1, // out_len < len
        );
        assert!(n < 0);
    }

    #[test]
    fn ratio_constraint_splits_proportionally() {
        let parent = RffiRect {
            x: 0,
            y: 0,
            width: 60,
            height: 10,
        };
        let kinds = [RATIO, RATIO];
        let a = [1u16, 2u16]; // 1/3 : 2/3
        let b = [3u16, 3u16];
        let rects = split(parent, 1, &kinds, &a, Some(&b), 0);
        assert_eq!(rects.len(), 2);
        // Combined widths must equal the parent width.
        assert_eq!(rects[0].width + rects[1].width, 60);
        // 2/3 chunk should be larger than the 1/3 chunk.
        assert!(rects[1].width > rects[0].width);
    }
}
