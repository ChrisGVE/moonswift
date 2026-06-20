// File: Sources/MoonSwiftCore/Catalog/CompletionItem.swift
// Folder: Sources/MoonSwiftCore/Catalog/
// Role: The completion-item value type produced by LuaModuleCatalog for the TUI
//       completion engine (F7a.1). Also carries the live-mock layer items built
//       from a cached MockLiveState (F5.0 / PERF-03).
//
//       `CompletionItem` is the single type that flows from Core → TUI for
//       completions. The TUI popup/hover overlay (task #19, F7a.2) consumes
//       it directly — no translation needed at the boundary.
//
//       `CompletionKind` drives UI rendering in F7a.2: modules get a different
//       glyph/color from functions, and live-mock items are visually distinct.
//
// Upstream: LuaModuleCatalog (catalog items), MockLiveState (live-mock items)
// Downstream: CatalogConsumers+Completion (builder), MoonSwiftTUI completion
//             popup (#19, F7a.2)

import Foundation

// MARK: - CompletionKind

/// How a completion item was sourced. Carried on every item and reserved to
/// drive per-kind glyph/colour in the popup; the F7a renderer does not yet read
/// it (all kinds render identically — CR-017), and no producer currently emits
/// `.field`. Kept on the model so that differentiation is a render-only change.
public enum CompletionKind: Sendable, Equatable, Hashable {
    /// A luaswift.* module table (e.g. `luaswift.json`).
    case module
    /// A function on a module or the root luaswift table (e.g. `json.encode`).
    case function
    /// A non-function field on a module table (e.g. `json.null`).
    case field
    /// A live name from the post-run engine snapshot: a mock value, a mock
    /// function, or a user-defined global (DATA-10 / DATA-N05).
    case mock
}

// MARK: - CompletionItem

/// One entry in a completion list, carrying both the text to insert and the
/// metadata the popup overlay uses to render a signature or doc string.
///
/// All fields are value types; `Sendable` synthesis is unconditional.
///
/// The canonical source of completion items is
/// `LuaModuleCatalog.completionItems(prefix:liveMocks:)`. Items sourced from
/// the catalog carry `kind` of `.module`, `.function`, or `.field`; items
/// sourced from a `MockLiveState` carry `kind` of `.mock`.
public struct CompletionItem: Sendable, Equatable {

    /// The text inserted into the editor when the user accepts the item.
    ///
    /// For catalog items this is the bare symbol name (e.g. `"encode"`).
    /// For live-mock items this is the mock name or user-global name.
    public let insertText: String

    /// The label shown in the popup list — typically the same as `insertText`
    /// but may include a decorating prefix for disambiguation in future.
    public let label: String

    /// Short signature or value summary shown on the right of the popup row.
    ///
    /// For catalog functions: the rendered parameter/return signature built
    /// from `CatalogFunction.params` and `CatalogFunction.returns`.
    /// For live-mock values / user globals: the `displayValue` from
    /// `MockLiveValue` (already depth-capped by F5.0).
    /// For mock function names: `nil` (no value to show, DATA-N05).
    public let detail: String?

    /// Documentation string shown in the hover overlay (F7a.2).
    ///
    /// Sourced from `CatalogFunction.doc` for catalog items. Always `nil` for
    /// live-mock items (the engine snapshot carries no Lua doc strings).
    public let doc: String?

    /// How this item was sourced — used by the popup for glyph and color.
    public let kind: CompletionKind

    public init(
        insertText: String,
        label: String,
        detail: String? = nil,
        doc: String? = nil,
        kind: CompletionKind
    ) {
        self.insertText = insertText
        self.label = label
        self.detail = detail
        self.doc = doc
        self.kind = kind
    }
}
