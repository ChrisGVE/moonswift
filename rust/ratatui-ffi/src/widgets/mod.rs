// File: rust/ratatui-ffi/src/widgets/mod.rs
// Role: Widget module registry — only the KEEP list from PRD §4.5.
//       Trimmed: Table, Chart, BarChart, Sparkline, Gauge, LineGauge, Canvas,
//                Scrollbar, logo/mascot novelty widgets.
//
// Upstream: ratatui widget primitives
// Downstream: lib.rs (re-exports public handle types)

pub mod block;
pub mod clear;
pub mod list;
pub mod paragraph;
pub mod tabs;

// Public handle types consumed by RatatuiKit via lib.rs.
pub use list::{RffiList, RffiListState};
pub use tabs::{RffiTabs, RffiTabsStyles};
