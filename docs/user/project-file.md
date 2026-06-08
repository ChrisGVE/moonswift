# MoonSwift — project file reference

The `moonswift.toml` file at the root of a project directory is the single
configuration source for MoonSwift. It is a standard [TOML](https://toml.io)
file. MoonSwift reads it at launch and on `<C-r>` reload.

## Minimal example

```toml
lua_version = "5.4"

[[source]]
path = "scripts/init.lua"
```

This is the smallest valid project file: one required field and one source
entry. All other fields have defaults.

## Top-level fields

### `lua_version` (required, string)

The Lua version the project targets. MoonSwift P1 supports only `"5.4"`.

```toml
lua_version = "5.4"
```

Any other value loads the project in a degraded read-only state: sources are
browsable and syntax-highlighted, but run and lint are disabled. A persistent
error header is shown in the bottom pane and the status bar shows
`[Lua X.X: unsupported]`.

---

## `[[source]]` entries

Each `[[source]]` entry declares one source to load. Entries are ordered;
the navigator lists them in declaration order.

### `path` (required, string)

Project-root-relative path to the source file. Absolute paths and paths that
escape the project root (`../`) are rejected.

```toml
[[source]]
path = "scripts/init.lua"
```

Supported file types:

| Extension | Role |
|-----------|------|
| `.lua` | Standalone Lua script — loaded as-is |
| `.json` | Structured file — requires `[[source.field]]` designations |
| `.yaml` | Structured file — requires `[[source.field]]` designations |
| `.toml` | Structured file — requires `[[source.field]]` designations |

A `[[source]]` entry with no `[[source.field]]` sub-entries must point to a
`.lua` file. Structured files without designations produce no loaded
fragments.

### `[[source.field]]` — field designations

Each `[[source.field]]` entry designates one string field inside a structured
file. A single `[[source]]` entry may have multiple `[[source.field]]`
entries.

```toml
[[source]]
path = "config/app.yaml"

  [[source.field]]
  jsonpath = "$.scripts.init"

  [[source.field]]
  jsonpath = "$.scripts.cleanup"
```

#### `jsonpath` (required, string)

An RFC 9535 JSONPath expression selecting the target string value. See
[docs/user/sources.md](sources.md) for the supported subset.

#### `document` (optional, integer, default `0`)

Zero-based YAML multi-document index. Only valid for `.yaml` files; setting
it on `.json` or `.toml` sources is an error. Defaults to `0` (the first
document).

```toml
  [[source.field]]
  jsonpath = "$.handler"
  document = 1   # second YAML document in the file
```

---

## `[run]` — run configuration

The `[run]` table controls how scripts are executed. All keys are optional;
the default is sandboxed execution with no limits.

```toml
[run]
config             = "sandboxed"  # default
instruction_limit  = 0            # 0 = unlimited (default)
wall_clock_limit_ms = 0           # 0 = unlimited (default)
```

### `config` (string, default `"sandboxed"`)

Engine execution mode.

| Value | Behaviour |
|-------|-----------|
| `"sandboxed"` | Safe subset: `io`, `debug`, and unsafe OS/load functions are stripped. Default. |
| `"unrestricted"` | All Lua globals available, including `io.*` and `os.*`. A `[unrestricted]` badge is shown in the title bar. |

### `instruction_limit` (integer, default `0`)

Maximum number of Lua VM instructions before the run is terminated with an
"instruction limit exceeded" outcome. `0` disables the limit.

```toml
instruction_limit = 1_000_000
```

### `wall_clock_limit_ms` (integer, default `0`)

Wall-clock timeout in milliseconds. `0` disables the timeout.

**Current limitation:** wall-clock cancellation requires LuaSwift cooperative
cancellation support (LuaSwift#22), which is not yet available at the current
pin. Setting this field to a value greater than `0` will trigger a project
warning at load time and the limit will have no effect — the run continues to
its natural end or `instruction_limit`. See [docs/user/running.md](running.md)
for details.

---

## `[lint]` — lint configuration

### `extra_modules` (array of strings, default `[]`)

Names of opt-in catalog modules to declare as known globals during linting.
Modules not declared here will produce "undefined global" warnings when
referenced in scripts.

```toml
[lint]
extra_modules = ["iox", "http"]
```

Valid values in P1 are the `.optIn` modules from the catalog: `"iox"`,
`"http"`, `"ui"`. Unknown names are rejected at load time with an error
diagnostic. See [docs/user/linting.md](linting.md) for the full module list.

---

## `[settings]` — UI settings

### `theme` (string, default `"default"`)

The active UI theme. P1 provides only `"default"` (Dracula-derived). Other
values are rejected at load time.

```toml
[settings]
theme = "default"
```

---

## Forward compatibility

Unknown top-level keys produce one warning diagnostic and are preserved on
programmatic writes (such as when MoonSwift saves field designations from the
picker). This ensures that files written by a future MoonSwift version remain
loadable by the current version.

## Comment preservation

Inline comments in `moonswift.toml` may be lost when MoonSwift writes back
to the file (for example after the picker saves new field designations). This
is an accepted P1 limitation. Hand-edited formatting is never changed unless
MoonSwift writes.
