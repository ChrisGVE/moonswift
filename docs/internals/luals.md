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
| `ProcessEnv` | 1.0.1 | `552f611479a4f28243a1ef2a7376a216d6899f42` | github.com/ChimeHQ/ProcessEnv | no advisories |

`swift-glob` and `ProcessEnv` are additional transitive dependencies pulled by
`LanguageClient` that were not anticipated in the F7b PRD (which named only
`LanguageServerProtocol` and `JSONRPC`); they are included here for completeness
and audited alongside the rest. MoonSwift does not `import ProcessEnv` — the
LuaLS transport spawns the child directly (`LuaLSProcess`) rather than via
`DataChannel.localProcessChannel`, so it never depends on `ProcessEnv`'s
`Process.ExecutionParameters` — but the package is still in the resolved graph,
hence the audit row.

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

## Per-project cache layout

The generated files live under a per-project directory (`LuaLSCache`,
`Sources/MoonSwiftTUI/LuaLS/LuaLSCache.swift`):

```
~/Library/Caches/moonswift/luals/<project-hash>/
  .luarc.json          # runtime.version + workspace.library + diagnostics.globals
  meta/<qualified>.lua # one ---@meta file per catalog module
  meta-version         # the catalog signature (sentinel)
  source-path          # absolute, symlink-resolved moonswift.toml path
```

The directory is created mode **0700** (re-asserted on reuse).
`<project-hash>` is the lowercase-hex **SHA-256 of the ABSOLUTE,
symlink-resolved (`realpath`) path** of the project's `moonswift.toml`
(SEC-06/DATA-05) — so two paths to the same project (e.g. via a symlink) share
one cache, and unrelated projects never collide.

LuaLS is pointed at this directory as its workspace root (`rootUri`), so it
reads `.luarc.json` from here: `workspace.library` (the `meta` dir) makes the
`luaswift.*` surface known, `runtime.version` is `Lua 5.4` (the active engine),
and `diagnostics.globals` declares `luaswift`.

### Regeneration sentinel

`meta-version` holds the catalog signature (a SHA-256 over every generated
file's path + content). On each project load the cache is rewritten **only when
the signature differs** from the stored sentinel — a no-op for an unchanged
catalog. The `meta/` directory is wiped wholesale on rewrite so modules removed
from the catalog do not linger.

### Eviction (30-day grace, AND predicate)

Orphaned caches are reclaimed by `evictStale`, which runs as best-effort
housekeeping at spawn time (only when LuaLS is actually present). A project
subdirectory is removed **only when BOTH**:

1. its recorded `source-path` no longer resolves on disk, **AND**
2. its `source-path` record is older than **30 days** (DATA-N02 grace period).

Either condition alone leaves the directory untouched — a project that is merely
unopened for a while, or temporarily unmounted, is never evicted prematurely.
The active project's `source-path` timestamp is refreshed on every load, so it
never drifts into the grace window while in use.

## Child-process spawn and environment policy

The server is spawned by `LuaLSProcess`
(`Sources/MoonSwiftTUI/LuaLS/LuaLSProcess.swift`) using the same hardening as
`NvimProcessSupervisor` (ARCHITECTURE §7.3): a **direct exec** of an
**absolute path** that is checked to be an **executable file**, an explicit
argument vector (empty — LuaLS defaults to stdio LSP transport), and the cache
directory as the working directory. `F_SETNOSIGPIPE` is set on the child's
stdin so a write after the child dies surfaces as a thrown error rather than
killing the host. Teardown is idempotent (a double-call guard prevents
double-SIGTERM / double-close), and the child is SIGTERM'd on clean exit and on
project reload so it never orphans.

### Curated environment (SEC-05, strict pass-list)

Unlike `NvimProcessSupervisor` (which inherits the full parent environment and
overrides XDG — nvim runs vendored, trusted config), the LuaLS child gets a
**curated allow-list** built from scratch (`LuaLSEnvironment`). This is the
OPPOSITE policy: the child is an arbitrary user-installed third party that must
never see credential variables. Only these pass through:

- exact: `PATH`, `HOME`, `TMPDIR`, `LANG`;
- by prefix: `LC_*` (locale), `XDG_*` (base directories).

Because it is a **pass-list, not a deny-list**, anything not named is dropped by
default — including a newly-invented `SOME_NEW_TOKEN`. The variables this keeps
OUT are every credential a developer shell carries; examples (NOT exhaustive):
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `VAULT_TOKEN`,
`CONSUL_TOKEN`, `NOMAD_TOKEN`, `CARGO_REGISTRY_TOKEN`, `NPM_AUTHTOKEN`,
`DOCKER_PASSWORD`, `HEROKU_API_KEY`, `ANTHROPIC_KEY` (SEC-N02 allow-list review).

## Diagnostics flow and degradation

`LuaLSClient` (`Sources/MoonSwiftTUI/LuaLS/LuaLSClient.swift`) is a long-lived
actor owned by the `AppDriver`. On project load (`Effect.spawnLuaLS`) it tears
down any prior child, prepares the cache, and spawns the server. The current
code fragment is pushed to the server as a full-document sync
(`Effect.lualsSync`, emitted alongside each `.lint`), and the server's published
diagnostics are mapped (`LuaLSDiagnosticMapper`: LSP 0-based line/character →
MoonSwift 1-based; severity `error` → `.error`, `warning`/`information`/`hint` →
`.warning`) into `.luals`-sourced `Diagnostic`s and merged into the Diagnostics
tab beside the luacheck/pre-pass findings.

**Degradation is silent.** When `lua-language-server` is absent from `PATH` (or
the spawn fails), the client posts `AppEvent.lualsUnavailable` once, which shows
the one-time status note `lua-language-server not found — using native catalog.`
(ux-spec §5.3) and otherwise leaves the native F7a behaviour intact. If the
child dies mid-session, document syncs degrade quietly to F7a (teardown is
idempotent, so a racing termination is harmless).

> **Scope note (F7b).** LuaLS document sync is wired at the `.lint` seam (each
> `l` press feeds the current fragment), not on every keystroke — a deliberate
> minimal coupling. LuaLS's `param-type-mismatch` group is opt-in in LuaLS's
> own defaults; the meta library makes the `luaswift.*` surface type-aware, but
> the diagnostics that fire out-of-the-box are LuaLS's default-on set
> (`undefined-global`, `undefined-field`, syntax errors, …).
