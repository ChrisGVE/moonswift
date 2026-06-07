# LuaModuleCatalog — Internals

The catalog is the single source of truth for all modules exposed under the
`luaswift.*` namespace by the embedded LuaSwift engine. Lint, completions,
and LuaLS meta-file generation all derive their module sets from it.

## Location

```
Sources/MoonSwiftCore/Catalog/
  CatalogTypes.swift          — ModuleAvailability, CatalogModule, CatalogFunction,
                                CatalogParam, GeneratedFile value types
  LuaModuleCatalog.swift      — LuaModuleCatalog struct, .v0 instance, consumers
  Modules/
    Module+Root.swift         — luaswift root table
    Module+JSON.swift         — luaswift.json
    Module+YAML.swift         — luaswift.yaml
    Module+Regex.swift        — luaswift.regex
    Module+MathX.swift        — luaswift.mathx
    Module+StringX.swift      — luaswift.stringx
    Module+TableX.swift       — luaswift.tablex
    Module+Types.swift        — luaswift.types
    Module+UTF8X.swift        — luaswift.utf8x
    Module+SVG.swift          — luaswift.svg
    Module+TOML.swift         — luaswift.toml  (.conditional)
    Module+IOx.swift          — luaswift.iox   (.optIn)
    Module+HTTP.swift         — luaswift.http  (.optIn)
    Module+UI.swift           — luaswift.ui    (.optIn)
```

## Catalog v0 contents

| Entry              | Availability      | Function count | Notes                          |
|--------------------|-------------------|---------------:|--------------------------------|
| `luaswift` (root)  | `.base`           |              1 | `extend_stdlib`                |
| `luaswift.json`    | `.base`           |              5 | encode/decode/jsonc/json5/null |
| `luaswift.yaml`    | `.base`           |              4 | encode/decode/all variants     |
| `luaswift.regex`   | `.base`           |              2 | compile, match                 |
| `luaswift.mathx`   | `.base`           |             38 | trig/hyp/stats/combinator/…    |
| `luaswift.stringx` | `.base`           |             30 | strip/split/pad/classify/…     |
| `luaswift.tablex`  | `.base`           |             31 | deepcopy/map/filter/chain/…    |
| `luaswift.types`   | `.base`           |             17 | typeof/is/to_*/clone/…         |
| `luaswift.utf8x`   | `.base`           |              9 | width/sub/reverse/…            |
| `luaswift.svg`     | `.base`           |              4 | create/translate/rotate/scale  |
| `luaswift.toml`    | `.conditional`    |              2 | encode/decode                  |
| `luaswift.iox`     | `.optIn`          |             17 | file ops + path.* sub-table    |
| `luaswift.http`    | `.optIn`          |              8 | get/post/put/patch/delete/…    |
| `luaswift.ui`      | `.optIn`          |              2 | alert/confirm                  |

**Total:** 14 entries, 170 catalogued functions.

## Availability categories

**`.base`** — always present in a running MoonSwift engine. No user action needed.

**`.conditional`** — present when a startup engine probe confirms the backing
library is functional. For `toml`, this means TOMLKit loaded and the Lua module
was registered without error. The probe result (a future task) calls
`luacheckGlobals(tomlProbed: true)` to include the module in the lint globals.

**`.optIn`** — not auto-installed. The user must declare the module name in
`lint.extra_modules` in `moonswift.toml`. Validation rejects unknown names using
`LuaModuleCatalog.v0.optInNames` as the allow-list (wired via the
`extraModulesAllowList` closure in `ProjectValidation` and `ProjectStore`).

**`.compileFlagGated`** — present only in binaries compiled with a specific Swift
active-compilation flag. Not represented in catalog v0 — no MoonSwift P1 module
requires this. The case exists for type-system completeness.

## Consumers

### luacheckGlobals

`LuaModuleCatalog.v0.luacheckGlobals(extraModules:tomlProbed:)` returns a
`[String: Any]` that serialises directly into a luacheck `std=` globals table:

```
{
  "luaswift": {
    "fields": {
      "json":   { "fields": { "decode": {}, "encode": {}, … } },
      "mathx":  { "fields": { "sin": {}, "cos": {}, … } },
      "iox":    { "fields": { "read_file": {}, …, "path": { "fields": { "join": {}, … } } } },
      …
    }
  }
}
```

The `luaswift` root functions (e.g. `extend_stdlib`) appear directly in
`luaswift.fields` rather than nested under a sub-key.

The `path` sub-table in `iox` functions are catalogued as `"path.join"` etc.
and are automatically nested one level deeper by `luacheckGlobals`.

### optInNames (ProjectValidation seam)

`LuaModuleCatalog.v0.optInNames` returns `Set<String>` — the bare names of all
`.optIn` modules (`{"iox", "http", "ui"}` in v0). This value is the default
for `ProjectValidation.validate(_:extraModulesAllowList:)` and all
`ProjectStore.load` variants. Tests that need isolation pass explicit closures.

### completionItems (P3a stub)

`LuaModuleCatalog.v0.completionItems(prefix:)` returns `[]` in P1. P3a replaces
the body with filtered completion construction from the catalog data.

### luaLSMetaFiles (P3b stub)

`LuaModuleCatalog.v0.luaLSMetaFiles()` returns `[]` in P1. P3b generates
`.luarc/meta/luaswift.*.lua` files from the catalog data.

## Maintenance

Every LuaSwift minimum-version bump **must** include a catalog review:

1. Check `LuaSwift/Sources/LuaSwift/Modules/Swift/*.swift` for added or
   removed functions in each module's `install(in:)` method.
2. Update the relevant `Module+<Name>.swift` file.
3. Update the fixture list in `Tests/MoonSwiftCoreTests/Catalog/LuaModuleCatalogTests.swift`.
4. Run `swift test --filter LuaModuleCatalog` to confirm.

Each `Module+<Name>.swift` header cites the LuaSwift source file it was
verified against, making review diffs straightforward.
