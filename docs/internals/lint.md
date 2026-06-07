# Lint internals — luacheck-in-engine loader mechanism

Status: F4.0 spike complete; loader promoted to production (`LuacheckLoader.swift`).
Relates to: PRD F4.0, F4.2; ARCHITECTURE.md §3d (lint flow), §2 (LintService).

---

## Overview

MoonSwift embeds a pure-Lua subset of
[luacheck](https://github.com/lunarmodules/luacheck) (MIT) inside a
LuaSwift engine. The engine loads the vendored modules at runtime through a
custom `package.preload` shim — no filesystem access from within Lua, no
`lfs`, no CLI dependency.

The spike test (F4.0) proved this works: luacheck runs in-engine, produces
structured reports with line/column/code fields, and handles all three
required fixture cases. The test is a permanent required CI check.

The loader logic from the spike is extracted into production code:
`Sources/MoonSwiftCore/Lint/LuacheckLoader.swift`. It exposes two functions:
`vendoredLuacheckModules()` (bundle enumeration) and
`installLuacheckPreloadShim(engine:modules:)` (shim registration).

---

## Vendored subset

**Location:** `Sources/MoonSwiftCore/Vendor/luacheck/`
**Pinned commit:** `f47ad699b5aab8eba5494a2b63e26c24dbf486ce` (lunarmodules/luacheck master, 2026-06-07)
**License:** MIT (see `Sources/MoonSwiftCore/Vendor/luacheck/NOTICE`)

### Included modules (38 files)

The subset covers only the code reachable from `luacheck.check_strings` and
`luacheck.get_report`. File-I/O, CLI, caching, threading, and rockspec
modules are excluded because they depend on `luafilesystem` or `argparse`.

| Module | Purpose |
|---|---|
| `luacheck` (init.lua) | Public API: `check_strings`, `get_report`, `process_reports`, `get_message` |
| `luacheck.check` | Per-source check driver — runs the stages pipeline |
| `luacheck.check_state` | Mutable state threaded through stages |
| `luacheck.core_utils` | `sort_by_location` and other shared helpers |
| `luacheck.decoder` | UTF-8 encoding helpers used by the lexer |
| `luacheck.filter` | Apply options to raw issue reports |
| `luacheck.format` | Issue → human-readable message conversion |
| `luacheck.lexer` | Lua lexer |
| `luacheck.options` | Option validation and merging |
| `luacheck.parser` | Lua parser (produces AST) |
| `luacheck.standards` | Globals-table and std-table validation |
| `luacheck.unicode` | Unicode character classification |
| `luacheck.unicode_printability_boundaries` | Printability boundary tables |
| `luacheck.utils` | Shared utilities (`array_to_set`, `try`, etc.) |
| `luacheck.stages` (init.lua) | Stage registry and pipeline runner |
| `luacheck.stages.parse` | AST entry point |
| `luacheck.stages.unwrap_parens` | Parenthesis-unwrap pass |
| `luacheck.stages.linearize` | Control-flow linearization |
| `luacheck.stages.parse_inline_options` | `--luacheck:` inline comment parsing |
| `luacheck.stages.name_functions` | Function-name inference |
| `luacheck.stages.resolve_locals` | Local-variable scope resolution |
| `luacheck.stages.detect_bad_whitespace` | Trailing whitespace, mixed indent |
| `luacheck.stages.detect_compound_operators` | `+=` / `-=` etc. in Lua 5.x |
| `luacheck.stages.detect_cyclomatic_complexity` | Complexity threshold |
| `luacheck.stages.detect_empty_blocks` | Empty `then`/`do`/`else` bodies |
| `luacheck.stages.detect_empty_statements` | Standalone semicolons |
| `luacheck.stages.detect_globals` | Undefined/unused globals (W1xx codes) |
| `luacheck.stages.detect_reversed_fornum_loops` | `for i=10,1 do` without -1 |
| `luacheck.stages.detect_unbalanced_assignments` | `a, b = f()` shape check |
| `luacheck.stages.detect_uninit_accesses` | Locals read before assignment |
| `luacheck.stages.detect_unreachable_code` | Dead code after `return`/`break` |
| `luacheck.stages.detect_unused_fields` | Unused struct-like fields |
| `luacheck.stages.detect_unused_locals` | Unused locals (W2xx codes) |
| `luacheck.builtin_standards` (init.lua) | Built-in globals catalog (lua51…lua54, etc.) |
| `luacheck.builtin_standards.love` | LÖVE framework globals |
| `luacheck.builtin_standards.luanti` | Luanti (Minetest) globals |
| `luacheck.builtin_standards.ngx` | OpenResty/nginx globals |
| `luacheck.builtin_standards.playdate` | Playdate SDK globals |

### Excluded modules

| Module | Reason |
|---|---|
| `luacheck.fs` | Requires `luafilesystem` |
| `luacheck.cache` | File-based cache, requires `luacheck.fs` |
| `luacheck.config` | Config-file loader, requires `luacheck.fs` and `cache` |
| `luacheck.expand_rockspec` | Rockspec reader, requires `luacheck.fs` |
| `luacheck.globbing` | Glob expansion, requires `luacheck.fs` |
| `luacheck.main` | CLI entry point |
| `luacheck.runner` | Multi-file runner, requires `fs` / `cache` / `config` |
| `luacheck.version` | Version reporter, requires `lfs` and `argparse` |
| `luacheck.multithreading` | LuaLanes threading |
| `luacheck.serializer` | Binary cache serializer |
| `luacheck.profiler` | Performance profiler |
| `luacheck.vendor.sha1` | Only used by `cache` and `profiler` |

### stdlib usage in the check_strings path

The `check_strings` code path uses only: `table`, `string`, `math`, `pcall`,
`error`, `type`, `tostring`, `pairs`, `ipairs`, `select`, `assert`, `setmetatable`,
`rawset`, `rawget`, `next`. It does not call `io.*`, `os.*`, `load()`, or
`loadstring()`. This was verified by static analysis (grep across all 38
included files).

---

## Loader mechanism (package.preload shim)

The shim runs before `require("luacheck")` and populates `package.preload`
with a factory closure for each vendored module. The factory captures the
module source as a Lua long-string upvalue and compiles it with `load()` on
first call.

```lua
local function make_loader(src, modname)
  return function()
    local chunk, err = load(src, '@luacheck/' .. modname, 't')
    if not chunk then error(err) end
    return chunk()
  end
end

package.preload["luacheck"] = make_loader(<long-string>, "luacheck")
package.preload["luacheck.lexer"] = make_loader(<long-string>, "luacheck.lexer")
-- … (one entry per vendored module)
```

### Why `package.preload` and not `package.path`

The vendored files live in the SPM resource bundle. Their absolute paths are
only known at Swift runtime. Feeding them to `package.path` would require
passing a filesystem path into the Lua engine, which is fragile (bundle paths
change between debug/release/device builds). The preload approach passes the
source *content* as strings — no filesystem access from within Lua.

### Why the engine must be unrestricted

`load()` is removed by the sandbox (`LuaEngineConfiguration.sandboxed = true`).
The shim uses `load()` to compile each module source. Therefore the lint engine
must run with `sandboxed: false`.

This is safe because the lint engine **never executes user code**. User scripts
enter only as string arguments to `luacheck.check_strings` — they are parsed
and analysed by luacheck's own Lua code, never `load()`'d or `eval()`'d.

The lint engine is confined to `LintService`'s serial executor (an Elm
effect — ARCHITECTURE.md §3d). Only vendored, pinned luacheck code runs in it.

### Module name derivation

Swift maps each `.lua` file's path (relative to the `luacheck/` root in the
bundle) to a dotted `require()` name:

| File path (relative to bundle `luacheck/luacheck/`) | Module name |
|---|---|
| `init.lua` | `luacheck` |
| `lexer.lua` | `luacheck.lexer` |
| `stages/parse.lua` | `luacheck.stages.parse` |
| `builtin_standards/init.lua` | `luacheck.builtin_standards` |
| `stages/init.lua` | `luacheck.stages` |

Sub-package `init.lua` files have the `.init` suffix stripped from the dotted
name so `require("luacheck.builtin_standards")` resolves correctly.

---

## Spike test verdict

**Runs in-engine: YES.**

All four fixture cases pass:
- (a) Clean script → zero issues.
- (b) Undefined global → W113 reported with line > 0 and column > 0.
- (c) Syntax error → E011 reported.
- (d) Declared global in options → zero issues.

Test location: `Tests/MoonSwiftCoreTests/LuacheckSpikeTests.swift`
Run time: ~70 ms total (engine creation + shim registration + 4 × check_strings).

### Report shape

`check_strings` returns a Lua table. LuaSwift bridges it as:
- `.table([String: LuaValue])` — the outer processed report (mixed keys).
  Integer key `"1"` is the per-file result.
- The per-file result is also `.table([String: LuaValue])` (issues at
  integer string keys `"1"`, `"2"`, …; aggregate counts at `"warnings"`,
  `"errors"`, `"fatals"`).
- Each issue table: `code` (string, e.g. `"113"`), `line` (number), `column`
  (number), `end_column` (number), `msg` (string from `get_message`).

LuaSwift converts Lua integer keys to their decimal string representation when
a table has mixed keys. Pure integer-keyed contiguous tables become `.array`.
The `LintService` implementation (F4.2) must handle both representations.

---

## Upgrade path

1. Pin a new luacheck commit.
2. Re-run the subset copy (see NOTICE for the file list).
3. Update `NOTICE` with the new commit hash.
4. Run `MOONSWIFT_SHIM_SOURCE=1 swift test` — the spike test serves as the
   acceptance gate.

Do not add `fs.lua`, `cache.lua`, or any other lfs-dependent module to the
subset without a plan for how the shim will handle them (lfs cannot run inside
the Lua engine).
