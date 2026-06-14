// File: Sources/MoonSwiftTUI/App/AppDriver+CompletionEffects.swift
// Location: MoonSwiftTUI/App/
// Role: P3 F7a.2 — the AppDriver's side-effectful completion/hover handlers. The
//       reducer emits `Effect.queryCompletions` / `Effect.queryHover` and never
//       touches the catalog directly. This extension reads the catalog on a
//       background Task and posts the result back as `AppEvent.completionsReady`
//       / `.hoverReady`. The catalog query is pure (no engine call, PERF-03);
//       `liveMocks`/`tomlProbed` arrive snapshotted from the reducer.
//
// Upstream: AppDriver (channel), MoonSwiftCore (LuaModuleCatalog, CompletionItem)
// Downstream: Reducer (completionsReady / hoverReady transitions)

import Foundation
import MoonSwiftCore

extension AppDriver {

    /// Query the catalog for `prefix` and post `.completionsReady` (F7a.2).
    func executeQueryCompletions(prefix: String, liveMocks: [CompletionItem], tomlProbed: Bool) {
        Task { [channel] in
            let items = LuaModuleCatalog.v0.completionItems(
                prefix: prefix,
                liveMocks: liveMocks,
                tomlProbed: tomlProbed
            )
            channel.post(.completionsReady(items))
        }
    }

    /// Resolve the hover symbol and post `.hoverReady` (F7a.2). The payload is
    /// `nil` when nothing matches — the reducer opens the overlay regardless
    /// (UX-R3-01).
    func executeQueryHover(symbolName: String, liveMocks: [CompletionItem], tomlProbed: Bool) {
        Task { [channel] in
            let item = resolveHoverItem(
                symbolName: symbolName,
                liveMocks: liveMocks,
                tomlProbed: tomlProbed
            )
            channel.post(.hoverReady(item))
        }
    }
}

/// Resolve a hover symbol to a `CompletionItem`, or `nil` when nothing matches.
///
/// A dotted catalog symbol (`luaswift.stringx.split`) resolves to its
/// module-level function item; a `luaswift.<table>` symbol to the namespace-level
/// item; any other bare name falls back to the live-mock slice. Free function so
/// it is unit-testable without the async driver.
func resolveHoverItem(
    symbolName: String,
    liveMocks: [CompletionItem],
    tomlProbed: Bool
) -> CompletionItem? {
    guard !symbolName.isEmpty else { return nil }
    let catalog = LuaModuleCatalog.v0

    if symbolName.hasPrefix("luaswift.") {
        let comps = symbolName.split(separator: ".").map(String.init)
        // comps[0] == "luaswift"
        if comps.count >= 3 {
            let table = comps[1]
            let function = comps[2]
            let items = catalog.completionItems(
                prefix: "luaswift.\(table).",
                liveMocks: [],
                tomlProbed: tomlProbed
            )
            if let hit = items.first(where: { $0.label == function }) { return hit }
        }
        if comps.count == 2 {
            let table = comps[1]
            let items = catalog.completionItems(
                prefix: "luaswift.",
                liveMocks: [],
                tomlProbed: tomlProbed
            )
            if let hit = items.first(where: { $0.label == table }) { return hit }
        }
    }

    // Live-mock / bare-name fallback.
    return liveMocks.first(where: { $0.label == symbolName })
}
