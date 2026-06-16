# How completions are sourced

MoonSwift offers completion suggestions as you type Lua in the editor. This
page explains where the suggestions come from and how they are selected.

## Two sources, one list

Every completion list is the union of two slices:

1. **Catalog items** — the built-in `luaswift.*` namespace, populated from the
   hand-maintained module catalog at startup. These never require a script run.

2. **Live-mock items** — names that appeared in the engine after the last
   successful run: registered mock values, mock function names, and user-defined
   globals written by the script. These are sourced from the post-run snapshot
   and are absent until you run the script at least once.

## Catalog items

The catalog covers the full `luaswift.*` namespace:

| Prefix typed | Items offered |
|---|---|
| `luaswift.` | All module names (`json`, `yaml`, `mathx`, …) plus root helpers |
| `luaswift.json.` | All functions on `luaswift.json` |
| `luaswift.stringx.` | All functions on `luaswift.stringx` |
| … | … |

Each function item shows a short signature in the popup (`(value, options?) ->
string`) and a documentation string in the hover overlay.

### Conditional module: `luaswift.toml`

The `luaswift.toml` module is only available when the underlying TOMLKit
library is compiled in. MoonSwift probes for it at startup. If the probe
succeeds, `luaswift.toml.*` completions appear; otherwise they are suppressed.

### Opt-in modules: `luaswift.iox`, `luaswift.http`, `luaswift.ui`

These modules must be declared in `lint.extra_modules` for the linter, but
completions always include them — the popup shows what the engine *can* offer
regardless of what lint has whitelisted.

## Live-mock items

After a successful script run, MoonSwift captures a snapshot of the live engine
state. Names from that snapshot are added to every completion list with a
distinct visual marker (kind: mock). Three categories contribute:

- **Mock values** — namespace paths you registered as mock values, e.g.
  `config.timeout`. The popup detail shows the live value (`30`).

- **Mock functions** — names you registered as mock functions, e.g. `fetch`.
  No detail value is shown (mock functions have no introspectable return value).

- **User globals** — globals written by your script that are not part of the
  standard Lua baseline, e.g. `helper`. The detail shows the live value or
  `function` for function-typed globals.

Live-mock items disappear if you reload without running again, because the
snapshot is cleared when a new session starts.

## Completion popup & hover

Completions and documentation are reached with two keys in the code pane:

- **`<C-space>`** opens the completion popup at the cursor. It shows up to 10
  items at a time; scroll the list with `j`/`k`. Each row is the name plus a
  short signature when one is available.
- **`<Enter>`** on the selected popup item opens its hover overlay. The code
  pane is read-only, so nothing is inserted — `<Enter>` is a "show me the docs"
  gesture, not an accept.
- **`K`** on a symbol opens the hover overlay directly, without going through the
  popup. The hover overlay is a centered box showing the symbol name, its full
  signature, and its documentation, scrolling when the text overflows.
- **`<Esc>`** dismisses the popup or the overlay; **`K`** also closes the hover
  overlay (press it again to toggle off).

If the symbol under the cursor has no documentation — or `K` does not land on a
known symbol — the overlay still opens and shows `(no documentation available)`
under the symbol name. `K` never silently does nothing.

## When completions do not appear

The popup activates only on an explicit dot after a known prefix
(`luaswift.`, `luaswift.json.`, etc.). Partial prefixes (`lua`, `luaswift`)
do not trigger completions. This keeps the list focused and avoids spurious
suggestions for non-luaswift identifiers.

## Optional `lua-language-server`

If [`lua-language-server`][luals] (LuaLS) is on your `PATH`, MoonSwift uses it as
an **optional** type-aware analysis backend on top of the built-in completions.
When you lint (`l`), MoonSwift feeds the current fragment to LuaLS along with
generated type descriptions of the `luaswift.*` namespace, and merges any
diagnostics it reports into the **Diagnostics** tab beside the luacheck findings
(same `E`/`W` format).

This is entirely additive and degrades silently:

- **LuaLS installed** — you get extra type-aware diagnostics (undefined fields on
  `luaswift.*` tables, undefined globals, type checks LuaLS surfaces by default)
  in addition to the native catalog completions and luacheck.
- **LuaLS absent** — completions and luacheck work exactly as documented above;
  on the first project load you see a one-time status note
  `lua-language-server not found — using native catalog.` and nothing else
  changes.

Install it with `brew install lua-language-server` (or any method that puts the
binary on `PATH`). MoonSwift runs it with a curated, credential-free environment
and generates its type files into a per-project cache under
`~/Library/Caches/moonswift/luals/`. See
[`docs/internals/luals.md`](../internals/luals.md) for the full design.

[luals]: https://github.com/LuaLS/lua-language-server
