# Optional lua-language-server integration (F7b)

MoonSwift can use [`lua-language-server`][luals] (LuaLS) as an **optional**
type-aware analysis backend. When LuaLS is on `PATH`, MoonSwift spawns it as a
stdio LSP child, feeds it generated `---@meta` files describing the `luaswift.*`
namespace, and merges its diagnostics into the Diagnostics tab. When LuaLS is
absent, MoonSwift degrades silently to the native catalog (F7a) — the feature is
purely additive.

This document records the supply-chain decisions for the LSP client dependency,
the meta-file/`.luarc.json` generation, the child-process spawn and environment
policy, the per-project cache layout, and the degradation behaviour.

[luals]: https://github.com/LuaLS/lua-language-server

## Dependency: ChimeHQ LanguageClient (supply-chain gate)

The stdio LSP client is [ChimeHQ `LanguageClient`][lc] (BSD-3-Clause), pinned in
`Package.swift` as `.upToNextMinor(from: "0.8.2")` and linked into the
`MoonSwiftTUI` target only (ARCH-01 — the client is TUI-side; the pure
meta-file generator lives in `MoonSwiftCore`). This is the project's first
ChimeHQ LSP dependency; it shares the ChimeHQ org with the existing
`SwiftTreeSitter` dependency.

`LanguageClient` is OPTIONAL at runtime (absence degrades to F7a) but the SPM
dependency is unconditional once declared, so it expands the transitive
dependency graph. The full resolved set (from `Package.resolved`) and its
OSV.dev audit:

| Package | Version | Resolved revision | Source | OSV.dev |
|---|---|---|---|---|
| `LanguageClient` | 0.8.2 | `4f28cc3cad7512470275f65ca2048359553a86f5` | github.com/ChimeHQ/LanguageClient | no advisories |
| `LanguageServerProtocol` | 0.14.1 | `82770aa7d6e54e52f3b4339c49a64ee794ad1cfe` | github.com/ChimeHQ/LanguageServerProtocol | no advisories |
| `JSONRPC` | 0.9.2 | `29987f721374f30e686af40ccffd0b13b14dde1f` | github.com/ChimeHQ/JSONRPC | no advisories |
| `swift-glob` | 0.2.0 | `07ba6f47d903a0b1b59f12ca70d6de9949b975d6` | github.com/davbeck/swift-glob | no advisories |

`swift-glob` is an additional transitive dependency pulled by `LanguageClient`
that was not anticipated in the F7b PRD (which named only `LanguageServerProtocol`
and `JSONRPC`); it is included here for completeness and audited alongside the
rest.

**Audit method.** Each resolved revision was queried against the OSV.dev
database by commit:

```sh
curl -X POST -d '{"commit":"<resolved-revision>"}' https://api.osv.dev/v1/query
```

All four returned `{}` (no known vulnerabilities) as of the F7b change-set
(2026-06-14). Re-run this audit on every dependency bump; record the result and
the new revisions in this table in the same change-set (FP-3).

[lc]: https://github.com/ChimeHQ/LanguageClient

## Meta files and `.luarc.json`

The catalog is the single source of truth. `LuaModuleCatalog.luaLSMetaFiles()`
(`Sources/MoonSwiftCore/Catalog/CatalogConsumers+Meta.swift`) delegates to the
pure `MetaFileGenerator` (`Sources/MoonSwiftCore/LuaLS/MetaFileGenerator.swift`)
to produce, deterministically:

- one `meta/<qualified>.lua` `---@meta` file per catalog module — a class table
  plus `@param`/`@return`/doc annotations per function (optional params rendered
  as `name?`, intermediate subtables declared for dotted function names);
- a `.luarc.json` pinning `runtime.version` to `Lua 5.4` (the active engine) and
  listing the `meta` directory under `workspace.library`.

The output is deterministic for a given catalog, which lets a stable hash of it
back the meta-version sentinel that triggers regeneration when the catalog (its
signatures) changes.
