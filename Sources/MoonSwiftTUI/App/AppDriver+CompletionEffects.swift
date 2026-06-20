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
/// A dotted catalog symbol resolves to its module-level function item
/// (`luaswift.stringx.split`, and also flat dotted names like
/// `luaswift.iox.path.join` whose catalog label is `"path.join"` — CR-007); a
/// `luaswift.<table>` symbol resolves to the namespace-level item; any other
/// bare name falls back to the live-mock slice. Kept module-private so the
/// Effect → driver → event pipeline stays the only catalog path (CR-018), while
/// remaining unit-testable without the async driver.
func resolveHoverItem(
    symbolName: String,
    liveMocks: [CompletionItem],
    tomlProbed: Bool
) -> CompletionItem? {
    guard !symbolName.isEmpty else { return nil }
    let catalog = LuaModuleCatalog.v0

    if symbolName.hasPrefix("luaswift.") {
        // parts: ["luaswift", table, functionName...]. Functions may carry a
        // dotted name (e.g. iox's "path.join"), so everything after the table is
        // rejoined into the function label rather than taking only parts[2].
        let parts = symbolName.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            let table = parts[1]
            let functionLabel = parts[2...].joined(separator: ".")
            let items = catalog.completionItems(
                prefix: "luaswift.\(table).",
                liveMocks: [],
                tomlProbed: tomlProbed
            )
            if let hit = items.first(where: { $0.label == functionLabel }) { return hit }
        }
        if parts.count == 2 {
            let table = parts[1]
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
