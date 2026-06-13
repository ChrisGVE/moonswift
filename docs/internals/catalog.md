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

## Signature authoring (F7a.0, task #17)

Starting with P3a (task #17), every `CatalogFunction` entry is enriched with
`params`, `returns`, and `doc` sourced directly from the LuaSwift module source
files. This section documents the authoring rules.

### Rules

1. **Evidence-based only.** Every signature must be traceable to a real LuaSwift
   source file. The `Source:` comment inside each `CatalogFunction(…)` block
   names the Swift file and callback or Lua block that defines the behaviour.
   Never invent a signature.

2. **Exact param names.** Use the parameter names from the LuaSwift callback
   implementation or its Lua API doc comment — not abbreviations or aliases.

3. **Optional flag.** Mark a `CatalogParam` as `isOptional: true` if and only if
   the LuaSwift source explicitly skips or defaults it when absent (e.g. `args[1]`
   checked with `if args.count > 1`).

4. **Return type.** Use Lua type strings: `"string"`, `"number"`, `"boolean"`,
   `"table"`, `"function"`, `"any"`, `"nil"`. Use `|` for unions:
   `"number|table"`. Use `"X, Y"` for multiple return values.
   Use Swift `nil` (not the string `"nil"`) when the function returns nothing.

5. **Doc string.** Every function must carry a `doc` string — even void helpers
   like `import()`. The string is one to three sentences describing what the
   function does, key parameters, and any caveats. Match the level of detail in
   the LuaSwift module-level Lua API doc comment.

6. **DATA-07 invariant.** `luacheckGlobals` reads only `CatalogFunction.name`.
   Signature fields (`params`, `returns`, `doc`) are invisible to it. Adding or
   changing these fields must never alter the luacheckGlobals output.
   `Tests/MoonSwiftCoreTests/Catalog/CatalogSignatureTests.swift` asserts this
   byte-stability; run it after every signature edit.

### Where to find LuaSwift signatures

The canonical source is `.build/checkouts/LuaSwift/Sources/LuaSwift/Modules/Swift/`:

| Module file         | Catalog file         |
|---------------------|----------------------|
| `JSONModule.swift`  | `Module+JSON.swift`  |
| `YAMLModule.swift`  | `Module+YAML.swift`  |
| `RegexModule.swift` | `Module+Regex.swift` |
| `MathXModule.swift` | `Module+MathX.swift` |
| `StringXModule.swift`| `Module+StringX.swift`|
| `TableXModule.swift`| `Module+TableX.swift`|
| `TypesModule.swift` | `Module+Types.swift` |
| `UTF8XModule.swift` | `Module+UTF8X.swift` |
| `SVGModule.swift`   | `Module+SVG.swift`   |
| `TOMLModule.swift`  | `Module+TOML.swift`  |
| `IOModule.swift`    | `Module+IOx.swift`   |
| `HTTPModule.swift`  | `Module+HTTP.swift`  |
| `UIModule.swift`    | `Module+UI.swift`    |
| `ModuleRegistry.swift`| `Module+Root.swift`|

For each module, look at:
- The `install(in:)` method's `engine.run("""…""")` Lua block for the exact
  function table shape and parameter names.
- The `// MARK: - Callbacks` section for argument parsing details (which
  `args[N]` are optional, what types are expected).
- The module-level `/// ## Lua API` doc comment for usage examples.

## Maintenance

Every LuaSwift minimum-version bump **must** include a catalog review:

1. Check `LuaSwift/Sources/LuaSwift/Modules/Swift/*.swift` for added or
   removed functions in each module's `install(in:)` method.
2. Update the relevant `Module+<Name>.swift` file — function list AND signatures.
3. Update the fixture list in `Tests/MoonSwiftCoreTests/Catalog/LuaModuleCatalogTests.swift`.
4. Run `swift test --filter LuaModuleCatalog` and
   `swift test --filter CatalogSignature` to confirm both suites pass.

Each `Module+<Name>.swift` header cites the LuaSwift source file it was
verified against, making review diffs straightforward.
