// File: rust/ratatui-ffi/src/widgets/block.rs
// Role: Shared block-builder helpers used by the List, Paragraph, and Tabs
//       widgets. A Block frames a widget with optional borders, border type,
//       title text, padding, and title alignment.
//
// All public functions in this module are helpers (not extern "C" entry
// points); each widget module creates its own block setters via inline calls.
//
// Upstream: ratatui::widgets (Block, BorderType, Borders, Padding)
// Downstream: widgets/list.rs, widgets/paragraph.rs, widgets/tabs.rs

use ratatui::prelude::{Line, Span};
use ratatui::style::{Color, Modifier, Style};
use ratatui::widgets::{Block, BorderType as RtBorderType, Borders, Padding as RtPadding};
use std::ffi::CStr;

// ---------------------------------------------------------------------------
// FfiStyle / FfiSpan — mirror types shared across widget modules
// ---------------------------------------------------------------------------

/// Style encoding: fg/bg as 0x00RRGGBB (0xFFFFFFFF = terminal default),
/// mods as the RffiStyleMods bitfield.
#[repr(C)]
#[derive(Copy, Clone, Default)]
pub struct RffiStyle {
    pub fg: u32,
    pub bg: u32,
    pub mods: u16,
    pub _pad: u16,
}

/// Modifier flag bits for RffiStyle.mods (mirrors ratatui Modifier).
pub mod style_mods {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const DIM: u16 = 1 << 3;
    pub const CROSSED: u16 = 1 << 4;
    pub const REVERSED: u16 = 1 << 5;
}

/// A span: a NUL-terminated UTF-8 string pointer + style.
#[repr(C)]
pub struct RffiSpan {
    pub text_utf8: *const std::ffi::c_char,
    pub style: RffiStyle,
}

// ---------------------------------------------------------------------------
// Style helpers (used by all widget modules)
// ---------------------------------------------------------------------------

/// Decode a packed colour word into a ratatui `Color`.
/// 0xFFFFFFFF = terminal default (Color::Reset); 0x00RRGGBB = RGB.
pub(super) fn decode_color(packed: u32) -> Color {
    if packed == 0xFFFF_FFFF {
        Color::Reset
    } else {
        let r = ((packed >> 16) & 0xFF) as u8;
        let g = ((packed >> 8) & 0xFF) as u8;
        let b = (packed & 0xFF) as u8;
        Color::Rgb(r, g, b)
    }
}

/// Decode RffiStyle into a ratatui Style.
pub(super) fn decode_style(s: RffiStyle) -> Style {
    let mut mods = Modifier::empty();
    if s.mods & style_mods::BOLD != 0 {
        mods |= Modifier::BOLD;
    }
    if s.mods & style_mods::ITALIC != 0 {
        mods |= Modifier::ITALIC;
    }
    if s.mods & style_mods::UNDERLINE != 0 {
        mods |= Modifier::UNDERLINED;
    }
    if s.mods & style_mods::DIM != 0 {
        mods |= Modifier::DIM;
    }
    if s.mods & style_mods::CROSSED != 0 {
        mods |= Modifier::CROSSED_OUT;
    }
    if s.mods & style_mods::REVERSED != 0 {
        mods |= Modifier::REVERSED;
    }
    Style::default()
        .fg(decode_color(s.fg))
        .bg(decode_color(s.bg))
        .add_modifier(mods)
}

/// Decode an RffiSpan slice into a Vec<Span<'static>>.
/// Skips NULL text pointers and invalid UTF-8 silently.
pub(super) fn decode_spans(spans: *const RffiSpan, len: usize) -> Option<Vec<Span<'static>>> {
    if spans.is_null() || len == 0 {
        return None;
    }
    const MAX_SPANS: usize = 65_536;
    if len > MAX_SPANS {
        return None;
    }
    let slice = unsafe { std::slice::from_raw_parts(spans, len) };
    let mut out = Vec::with_capacity(len);
    for s in slice {
        if s.text_utf8.is_null() {
            continue;
        }
        let c = unsafe { CStr::from_ptr(s.text_utf8) };
        if let Ok(txt) = c.to_str() {
            out.push(Span::styled(txt.to_string(), decode_style(s.style)));
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// Border bits
// ---------------------------------------------------------------------------

/// Border-flags encoding (1-bit per side, matching upstream FfiBorders).
pub mod border_bits {
    pub const NONE: u8 = 0;
    pub const TOP: u8 = 1 << 0;
    pub const RIGHT: u8 = 1 << 1;
    pub const BOTTOM: u8 = 1 << 2;
    pub const LEFT: u8 = 1 << 3;
    pub const ALL: u8 = TOP | RIGHT | BOTTOM | LEFT;
}

fn borders_from_bits(bits: u8) -> Borders {
    let mut b = Borders::empty();
    if bits & border_bits::TOP != 0 {
        b |= Borders::TOP;
    }
    if bits & border_bits::RIGHT != 0 {
        b |= Borders::RIGHT;
    }
    if bits & border_bits::BOTTOM != 0 {
        b |= Borders::BOTTOM;
    }
    if bits & border_bits::LEFT != 0 {
        b |= Borders::LEFT;
    }
    b
}

// ---------------------------------------------------------------------------
// build_block — shared block construction used by all widgets
// ---------------------------------------------------------------------------

/// Construct a ratatui Block from its C-ABI parameters.
///
/// border_type: 0 = Plain, 1 = Rounded, 2 = Double, 3 = Thick.
pub(super) fn build_block(
    borders_bits: u8,
    border_type: u32,
    pad_left: u16,
    pad_top: u16,
    pad_right: u16,
    pad_bottom: u16,
    title_spans: *const RffiSpan,
    title_len: usize,
) -> Block<'static> {
    let mut block = Block::default()
        .borders(borders_from_bits(borders_bits))
        .border_type(match border_type {
            1 => RtBorderType::Rounded,
            2 => RtBorderType::Double,
            3 => RtBorderType::Thick,
            _ => RtBorderType::Plain,
        })
        .padding(RtPadding {
            left: pad_left,
            right: pad_right,
            top: pad_top,
            bottom: pad_bottom,
        });

    if let Some(spans) = decode_spans(title_spans, title_len) {
        block = block.title(Line::from(spans));
    }
    block
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
        assert_eq!(decode_color(0x00FF_0080), Color::Rgb(0xFF, 0x00, 0x80));
    }

    #[test]
    fn decode_style_bold_italic() {
        let s = RffiStyle {
            fg: 0xFFFF_FFFF,
            bg: 0xFFFF_FFFF,
            mods: style_mods::BOLD | style_mods::ITALIC,
            _pad: 0,
        };
        let style = decode_style(s);
        assert!(style.add_modifier.contains(Modifier::BOLD));
        assert!(style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn decode_spans_null_returns_none() {
        let result = decode_spans(std::ptr::null(), 0);
        assert!(result.is_none());
    }

    #[test]
    fn borders_all_bits() {
        let b = borders_from_bits(border_bits::ALL);
        assert!(b.contains(Borders::TOP));
        assert!(b.contains(Borders::BOTTOM));
        assert!(b.contains(Borders::LEFT));
        assert!(b.contains(Borders::RIGHT));
    }

    #[test]
    fn borders_none_bits() {
        let b = borders_from_bits(border_bits::NONE);
        assert!(!b.contains(Borders::TOP));
    }
}
