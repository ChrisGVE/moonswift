// File: Tests/MoonSwiftPerfTests/CompletionPerfTests.swift
// Location: Tests/MoonSwiftPerfTests/
// Role: Performance benchmarks for the P3 F7a completion and hover paths
//       (PERF-03). Two measurements verify the catalog query latency stays
//       within the PRD budget:
//
//         1. Completion popup — `LuaModuleCatalog.v0.completionItems(prefix:
//            liveMocks:tomlProbed:)` pure prefix filter + merge (PERF-03):
//            PRD target < 50 ms → CI threshold 100 ms.
//
//         2. Hover overlay — `resolveHoverItem(symbolName:liveMocks:tomlProbed:)`
//            free function resolving a dotted catalog symbol via two catalog
//            queries: PRD target < 50 ms → CI threshold 100 ms.
//
//       Both paths are pure (no engine call, PERF-03); the live-mock slice is
//       pre-cached and passed in — the catalog never sweeps the engine per
//       keystroke. All CI thresholds are 2× the PRD target, matching the
//       convention in PerfTests.swift.
//
//       Running locally:
//         MOONSWIFT_SHIM_SOURCE=1 LUASWIFT_INCLUDE_TOMLKIT=1 \
//           swift test --filter CompletionPerfTests
//
// Upstream: MoonSwiftCore (LuaModuleCatalog, CompletionItem, MockLiveState),
//           MoonSwiftTUI (resolveHoverItem — internal, exposed via @testable)
// Downstream: (test target — nothing imports this)

import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Thresholds
//
// PRD target → CI threshold (2×):
//   Completion popup latency   < 50 ms → 100 ms  (PERF-03)
//   Hover overlay latency      < 50 ms → 100 ms  (PERF-03)

private let completionThreshold: Duration = .milliseconds(100)
private let hoverThreshold: Duration = .milliseconds(100)

// MARK: - Fixture helpers

/// Builds a realistic `[CompletionItem]` live-mock slice to simulate a
/// post-run session with several mock values and function names.
///
/// The slice mirrors the shape that `MockLiveState.completionItems()` produces:
/// mock value items carry a `displayValue` detail; mock function name items
/// have no detail (DATA-N05 shape). Five entries is representative — a real
/// project might have 10–30; the catalog query is O(catalog size) anyway.
private func realisticLiveMocks() -> [CompletionItem] {
    let mockValues: [CompletionItem] = [
        CompletionItem(
            insertText: "config", label: "config",
            detail: "{timeout=5000, retries=3}", doc: nil, kind: .mock),
        CompletionItem(
            insertText: "config.timeout", label: "config.timeout",
            detail: "5000", doc: nil, kind: .mock),
        CompletionItem(
            insertText: "config.retries", label: "config.retries",
            detail: "3", doc: nil, kind: .mock),
        CompletionItem(
            insertText: "user.name", label: "user.name",
            detail: "\"alice\"", doc: nil, kind: .mock),
        CompletionItem(
            insertText: "user.role", label: "user.role",
            detail: "\"admin\"", doc: nil, kind: .mock),
    ]
    let mockFunctions: [CompletionItem] = [
        CompletionItem(
            insertText: "host_log", label: "host_log",
            detail: nil, doc: nil, kind: .mock),
        CompletionItem(
            insertText: "host_fetch", label: "host_fetch",
            detail: nil, doc: nil, kind: .mock),
    ]
    return mockValues + mockFunctions
}

/// Measures the wall-clock elapsed time for `body` and returns the duration.
/// Replicates the helper from PerfTests.swift for file-local use (shared
/// helpers cannot be declared across test files without a separate module).
private func measureSync(_ body: () -> Void) -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    body()
    return clock.now - start
}

// MARK: - 1. Completion popup latency (PERF-03)

/// Measures `LuaModuleCatalog.v0.completionItems(prefix:liveMocks:tomlProbed:)`
/// for a realistic module-level prefix (PRD target: < 50 ms, CI threshold: 100 ms).
///
/// The bench uses the `"luaswift.json."` prefix — the module-level case in
/// `CatalogConsumers+Completion.swift` — which exercises the full filter +
/// live-mock merge path. `tomlProbed: true` ensures the conditional `.toml`
/// module is included (the worst-case catalog slice).
///
/// What this bench does NOT measure:
/// The TUI keystroke dispatch and the AppDriver Task overhead (~1 ms on a fast
/// machine but non-deterministic). PERF-03 specifies the catalog query itself
/// (the pure computation); the AppDriver overhead is an implementation detail
/// that the integration tests already cover.
@Suite("Perf — Completion popup latency (PERF-03)")
struct CompletionPopupPerfTests {

    @Test("completionItems(prefix:liveMocks:) < 100 ms for luaswift.json. prefix (2× PRD 50 ms target)")
    func completionPopupLatency() {
        let catalog = LuaModuleCatalog.v0
        let liveMocks = realisticLiveMocks()
        let prefix = "luaswift.json."

        // One warm-up call to avoid cold-path initialisation costs in the
        // first catalog scan (array iteration over the module list).
        _ = catalog.completionItems(prefix: prefix, liveMocks: liveMocks, tomlProbed: true)

        let elapsed = measureSync {
            _ = catalog.completionItems(prefix: prefix, liveMocks: liveMocks, tomlProbed: true)
        }

        print("[perf] completionItems(luaswift.json.): \(elapsed)")
        #expect(
            elapsed < completionThreshold,
            "completionItems took \(elapsed) — over 2× PRD target of 50 ms (CI threshold: 100 ms)"
        )
    }

    /// Measures the namespace-root prefix case ("luaswift.") which iterates all
    /// modules and all root functions — the wider scan, hence potentially slower.
    @Test("completionItems(prefix:liveMocks:) < 100 ms for luaswift. prefix (namespace root case)")
    func completionPopupNamespaceRootLatency() {
        let catalog = LuaModuleCatalog.v0
        let liveMocks = realisticLiveMocks()
        let prefix = "luaswift."

        _ = catalog.completionItems(prefix: prefix, liveMocks: liveMocks, tomlProbed: true)

        let elapsed = measureSync {
            _ = catalog.completionItems(prefix: prefix, liveMocks: liveMocks, tomlProbed: true)
        }

        print("[perf] completionItems(luaswift.): \(elapsed)")
        #expect(
            elapsed < completionThreshold,
            "completionItems(namespace root) took \(elapsed) — over 2× PRD target of 50 ms (CI threshold: 100 ms)"
        )
    }
}

// MARK: - 2. Hover overlay latency (PERF-03)

/// Measures `resolveHoverItem(symbolName:liveMocks:tomlProbed:)` for a
/// realistic dotted catalog symbol (PRD target: < 50 ms, CI threshold: 100 ms).
///
/// `resolveHoverItem` is a free function in `AppDriver+CompletionEffects.swift`
/// (internal visibility, exposed here via `@testable import MoonSwiftTUI`). For
/// a `luaswift.X.fn` symbol it issues TWO catalog queries — the most expensive
/// hover path — making it the correct worst-case for the latency budget.
///
/// The bench uses `"luaswift.json.encode"`, a real catalog entry, so the
/// `first(where:)` search terminates after finding the hit rather than scanning
/// the whole module function list. The worst case is a symbol NOT in the
/// catalog (scans to end); both paths are below threshold given the catalog size.
@Suite("Perf — Hover overlay latency (PERF-03)")
struct HoverOverlayPerfTests {

    @Test("resolveHoverItem for a dotted catalog symbol < 100 ms (2× PRD 50 ms target)")
    func hoverOverlayDottedSymbolLatency() {
        let liveMocks = realisticLiveMocks()
        let symbolName = "luaswift.json.encode"

        // Warm-up.
        _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)

        let elapsed = measureSync {
            _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)
        }

        print("[perf] resolveHoverItem(luaswift.json.encode): \(elapsed)")
        #expect(
            elapsed < hoverThreshold,
            "resolveHoverItem took \(elapsed) — over 2× PRD target of 50 ms (CI threshold: 100 ms)"
        )
    }

    /// Measures the namespace-table hover case (`"luaswift.json"`) — one
    /// catalog query instead of two, so strictly faster.
    @Test("resolveHoverItem for a namespace-table symbol < 100 ms (2× PRD 50 ms target)")
    func hoverOverlayTableSymbolLatency() {
        let liveMocks = realisticLiveMocks()
        let symbolName = "luaswift.json"

        _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)

        let elapsed = measureSync {
            _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)
        }

        print("[perf] resolveHoverItem(luaswift.json): \(elapsed)")
        #expect(
            elapsed < hoverThreshold,
            "resolveHoverItem(table) took \(elapsed) — over 2× PRD target of 50 ms (CI threshold: 100 ms)"
        )
    }

    /// Measures the live-mock fallback path (bare name not in the catalog):
    /// covers `liveMocks.first(where:)` — the cheapest path, but still bounded.
    @Test("resolveHoverItem for a live-mock bare name < 100 ms (2× PRD 50 ms target)")
    func hoverOverlayLiveMockFallbackLatency() {
        let liveMocks = realisticLiveMocks()
        let symbolName = "host_log"  // In liveMocks, not in catalog.

        _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)

        let elapsed = measureSync {
            _ = resolveHoverItem(symbolName: symbolName, liveMocks: liveMocks, tomlProbed: true)
        }

        print("[perf] resolveHoverItem(host_log — live-mock fallback): \(elapsed)")
        #expect(
            elapsed < hoverThreshold,
            "resolveHoverItem(live-mock fallback) took \(elapsed) — over 2× PRD target of 50 ms (CI threshold: 100 ms)"
        )
    }
}
