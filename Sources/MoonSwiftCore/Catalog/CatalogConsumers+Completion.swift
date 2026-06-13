// File: Sources/MoonSwiftCore/Catalog/CatalogConsumers+Completion.swift
// Folder: Sources/MoonSwiftCore/Catalog/
// Role: The completion-item producer for LuaModuleCatalog (F7a.1). Implements
//       the SINGLE CANONICAL two-parameter
//       `completionItems(prefix:liveMocks:) -> [CompletionItem]` method
//       (CONS-R2-01 — no one-parameter overload exists).
//
//       Also provides the `MockLiveState → [CompletionItem]` helper that maps
//       the post-run engine snapshot into live-mock items (DATA-10 / DATA-N05).
//       Callers build this slice once from a cached snapshot and pass it in;
//       the catalog never sweeps the engine per-keystroke (PERF-03).
//
//       Prefix matching strategy:
//         The prefix is the Lua text immediately before the cursor. Matching
//         is purely textual: a catalog item is returned when its fully-qualified
//         name has the prefix as a prefix, after which the *tail* (the part
//         beyond the prefix) is used as insertText and label.
//
//         Three cases based on the structure of the prefix:
//           1. "luaswift."       → yield all top-level modules + root functions.
//           2. "luaswift.X."    → yield all functions on module X.
//           3. anything else    → yield nothing (no partial-table matching yet;
//                                  the popup activates only on explicit dot).
//
//       Toml conditional: modules with `availability == .conditional` are
//       included only when `tomlProbed == true`, exactly mirroring the
//       `luacheckGlobals(extraModules:tomlProbed:)` contract.
//
//       Opt-in modules (iox, http, ui) are ALWAYS included in completions
//       regardless of the project's `lint.extra_modules` declaration — the
//       completion engine surfaces what the engine CAN provide, not what lint
//       has whitelisted (the two concerns are orthogonal). Functions gated by
//       `.compileFlagGated` are excluded (they are not in catalog v0 anyway).
//
// Upstream: LuaModuleCatalog, CatalogModule, CatalogFunction, MockLiveState
// Downstream: MoonSwiftTUI completion popup (task #19, F7a.2) via AppDriver

import Foundation

// MARK: - Catalog → CompletionItem

extension LuaModuleCatalog {

    // MARK: Canonical completion accessor (CONS-R2-01)

    /// Returns completion items for the Lua text immediately before the cursor.
    ///
    /// This is the SINGLE canonical form of `completionItems` — the two-parameter
    /// `(prefix:liveMocks:)` method. No one-parameter overload exists (CONS-R2-01).
    ///
    /// The catalog emits items for the luaswift.* namespace; the caller appends
    /// live-mock items by passing the result of
    /// `MockLiveState.completionItems()` as `liveMocks`. Pass `liveMocks: []`
    /// when no session is active or the cache is empty.
    ///
    /// Toml conditional: `luaswift.toml.*` items appear only when `tomlProbed`
    /// was `true` at the time the app state was last updated. The caller
    /// sources this flag from `AppState.tomlModuleAvailable`, the same flag
    /// `luacheckGlobals(tomlProbed:)` uses (ARCHITECTURE §5.4).
    ///
    /// Prefix matching examples:
    /// - `"luaswift."` → all direct children of the luaswift namespace.
    /// - `"luaswift.json."` → all functions on luaswift.json.
    /// - `""` or `"lua"` → empty (no partial-table matching).
    ///
    /// - Parameters:
    ///   - prefix: The Lua text before the cursor (e.g. `"luaswift.json."`).
    ///   - liveMocks: Completion items sourced from a cached `MockLiveState`.
    ///     Built by the caller via `MockLiveState.completionItems()`. Pass
    ///     `[]` when no session snapshot is available (PERF-03).
    ///   - tomlProbed: `true` when the startup engine probe confirmed TOMLKit.
    ///     Defaults to `false` (conservative — omit until probe confirms).
    /// - Returns: Items whose qualified name starts with `prefix`, ordered
    ///   by module definition order, followed by the `liveMocks` slice.
    public func completionItems(
        prefix: String,
        liveMocks: [CompletionItem],
        tomlProbed: Bool = false
    ) -> [CompletionItem] {
        var result: [CompletionItem] = []

        // Namespace root: the caller typed "luaswift." and wants direct children.
        let namespaceDotPrefix = "luaswift."
        if prefix == namespaceDotPrefix {
            result = namespaceLevelItems(tomlProbed: tomlProbed)
            result.append(contentsOf: liveMocks)
            return result
        }

        // Module level: the caller typed "luaswift.X." and wants X's functions.
        if prefix.hasPrefix(namespaceDotPrefix) {
            let tail = String(prefix.dropFirst(namespaceDotPrefix.count))
            // tail must end in "." and the portion before "." is the table name.
            if tail.hasSuffix("."), !tail.dropLast().contains(".") {
                let tableName = String(tail.dropLast())
                result = moduleLevelItems(
                    tableName: tableName,
                    tomlProbed: tomlProbed
                )
                result.append(contentsOf: liveMocks)
                return result
            }
        }

        // No match for any other prefix form — the popup is not active.
        return []
    }

    // MARK: Short signature builder

    /// Renders the short signature string shown in the popup `detail` column.
    ///
    /// Format: `(param, param?) -> returnType`
    /// When params are empty and returns is nil, returns nil (no detail shown).
    /// Optional parameters are suffixed with `?` (e.g. `options?`).
    ///
    /// Examples:
    ///   - `encode(value, options?) -> string`
    ///   - `decode(str, options?) -> any`
    ///   - `extend_stdlib()` (nil returns, no suffix arrow)
    static func shortSignature(for fn: CatalogFunction) -> String? {
        let paramsText = fn.params.map { p in
            p.isOptional ? "\(p.name)?" : p.name
        }.joined(separator: ", ")

        let paramsPart = "(\(paramsText))"

        if let ret = fn.returns {
            return "\(paramsPart) -> \(ret)"
        }
        // When there are no params AND no return type, omit the detail entirely
        // (the popup row just shows the name; the doc covers meaning).
        if fn.params.isEmpty {
            return nil
        }
        return paramsPart
    }

    // MARK: - Private helpers

    /// Items at the `luaswift.` level: modules + root functions.
    private func namespaceLevelItems(tomlProbed: Bool) -> [CompletionItem] {
        var items: [CompletionItem] = []

        for module in modules {
            guard isActive(module, tomlProbed: tomlProbed) else { continue }

            if module.tableName.isEmpty {
                // Root module — its functions appear directly under luaswift.
                for fn in module.functions {
                    items.append(
                        CompletionItem(
                            insertText: fn.name,
                            label: fn.name,
                            detail: LuaModuleCatalog.shortSignature(for: fn),
                            doc: fn.doc,
                            kind: .function
                        )
                    )
                }
            } else {
                // Named sub-module — the module table itself is the completion.
                items.append(
                    CompletionItem(
                        insertText: module.tableName,
                        label: module.tableName,
                        detail: nil,
                        doc: nil,
                        kind: .module
                    )
                )
            }
        }

        return items
    }

    /// Items at the `luaswift.X.` level: functions of module `tableName`.
    private func moduleLevelItems(
        tableName: String,
        tomlProbed: Bool
    ) -> [CompletionItem] {
        guard
            let module = modules.first(where: { $0.tableName == tableName }),
            isActive(module, tomlProbed: tomlProbed)
        else { return [] }

        return module.functions.map { fn in
            CompletionItem(
                insertText: fn.name,
                label: fn.name,
                detail: LuaModuleCatalog.shortSignature(for: fn),
                doc: fn.doc,
                kind: .function
            )
        }
    }

    /// Whether a module should appear in completions given the probe result.
    ///
    /// Opt-in modules are always included (completions show what the engine
    /// can offer; lint whitelisting is a separate concern). Compile-flag-gated
    /// modules are excluded — they are absent from catalog v0 in any case.
    private func isActive(_ module: CatalogModule, tomlProbed: Bool) -> Bool {
        switch module.availability {
        case .base:
            return true
        case .conditional:
            return tomlProbed
        case .optIn:
            return true
        case .compileFlagGated:
            return false
        }
    }
}

// MARK: - MockLiveState → [CompletionItem]

extension MockLiveState {

    /// Maps this post-run snapshot to a flat list of live-mock `CompletionItem`s.
    ///
    /// Implements the DATA-10 / DATA-N05 two-branch binding:
    ///
    ///   • A `MockLiveValue` (from `mockValues` or `userGlobals`) maps to:
    ///     ```
    ///     CompletionItem(
    ///       insertText: name, label: name,
    ///       detail: displayValue,  // depth-capped by F5.0; "(...)" or "function"
    ///       doc: nil, kind: .mock
    ///     )
    ///     ```
    ///   • A bare function name string (from `mockFunctionNames`) maps to:
    ///     ```
    ///     CompletionItem(
    ///       insertText: fn, label: fn,
    ///       detail: nil,   // no value to display, DATA-N05
    ///       doc: nil, kind: .mock
    ///     )
    ///     ```
    ///
    /// Returns an empty array when `isEmpty == true` (the no-cache / mid-run
    /// sentinel state — DATA-09).
    ///
    /// The caller caches this snapshot and passes the resulting slice to
    /// `LuaModuleCatalog.completionItems(prefix:liveMocks:)`. The catalog
    /// never re-sweeps the engine on each keystroke (PERF-03).
    public func completionItems() -> [CompletionItem] {
        guard !isEmpty else { return [] }

        var items: [CompletionItem] = []

        // Branch 1: mock VALUES — name + rendered value as detail.
        for lv in mockValues {
            items.append(
                CompletionItem(
                    insertText: lv.name,
                    label: lv.name,
                    detail: lv.displayValue,
                    doc: nil,
                    kind: .mock
                )
            )
        }

        // Branch 2: mock FUNCTION NAMES — name only, no value detail.
        for fn in mockFunctionNames {
            items.append(
                CompletionItem(
                    insertText: fn,
                    label: fn,
                    detail: nil,
                    doc: nil,
                    kind: .mock
                )
            )
        }

        // Branch 1 continued: user-defined globals — same shape as mock values.
        for lv in userGlobals {
            items.append(
                CompletionItem(
                    insertText: lv.name,
                    label: lv.name,
                    detail: lv.displayValue,
                    doc: nil,
                    kind: .mock
                )
            )
        }

        return items
    }
}
