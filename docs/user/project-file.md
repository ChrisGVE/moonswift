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

### `navigator_split` (float, default `0.25`) and `bottom_split` (float, default `0.30`)

The navigator/main and bottom-pane/main split ratios, as fractions of the
terminal. They persist the pane layout across sessions: resizing a split in the
TUI (`<`/`>` for the navigator, `{`/`}` for the bottom pane) auto-saves the new
ratio here, and the saved ratio is reapplied to the layout when the project is
loaded.

- `navigator_split` must be in `[0.10, 0.50]`.
- `bottom_split` must be in `[0.10, 0.60]`.

A value outside its range produces a validation diagnostic
(`settings.navigator_split <v> out of range [0.10, 0.50]`) and is clamped to the
nearest bound when applied to the layout. Both keys are optional — a `[settings]`
table with only `theme` loads with the defaults.

```toml
[settings]
theme = "default"
navigator_split = 0.25
bottom_split = 0.30
```

---

## `[[mock.value]]` — mock value definitions

Each `[[mock.value]]` entry injects a named Lua value into the engine's global
table at session start. Scripts can read (and optionally write) the value
without a real host implementation.

```toml
[[mock.value]]
namespace = "myapp"         # required, non-empty; must not collide with catalog
path = "settings.debug"     # required key path within the namespace
type = "boolean"            # "string" | "number" | "boolean" | "table" | "expr"
value = "true"              # required Lua value expression (see below)
writable = true             # required boolean: whether scripts may write this path
```

### `namespace` (required, string)

The top-level Lua table name for the mock. Must not be empty and must not
equal a known catalog symbol name (e.g. `"luaswift"`, `"json"`, `"yaml"`).

### `path` (required, string)

The dotted key path within the namespace (e.g. `"settings.debug"` for
`myapp.settings.debug`). Must not be empty.

### `type` (required, string)

Informational label for the mock value. Does not restrict what the `value`
expression produces. Valid values:

| Value | Meaning |
|-------|---------|
| `"string"` | The value is expected to be a Lua string |
| `"number"` | The value is expected to be a Lua number |
| `"boolean"` | The value is expected to be a Lua boolean |
| `"table"` | The value is expected to be a Lua table constructor |
| `"expr"` | An arbitrary Lua value expression (function literal, computed value, etc.) |

### `value` (required, string)

A Lua value expression that is syntax-checked at load time and evaluated at
session start via `evaluate("return <value>")`. Any syntactically valid Lua
value expression is accepted: scalar literals, table constructors, function
literals (`function() return os.time() end`), or computed expressions.

### `writable` (required, boolean)

When `true`, Lua scripts may write to the mock path during a run and the
post-run navigator reflects the written value.

### Runtime behaviour

At session start, MoonSwift evaluates each `value` expression with
`evaluate("return <value>")` under the project's configured engine mode.
The result is served to Lua through a value server registered as the
`namespace` global — before the stdlib baseline is captured, so mock
namespaces are excluded from the navigator's user-globals view. A write to
a non-writable path raises a Lua runtime error surfaced as a structured
diagnostic. See [docs/user/mocking.md](mocking.md) for the full runtime
contract.

### Duplicate detection

Two `[[mock.value]]` entries with the same `namespace` and `path` are a
load-time error. Each `(namespace, path)` pair must be unique.

---

## `[[mock.function]]` — mock function definitions

Each `[[mock.function]]` entry registers a callable Lua function that scripts
can invoke without a real host implementation.

```toml
[[mock.function]]
name = "host_log"           # required; no catalog or __moonswift_ collision
behavior = "echo-args"      # "echo-args" | "fixed-return" | "raise-error"
```

### `name` (required, string)

The bare Lua function name (no dots). Must not be empty, must not begin with
`__moonswift_`, and must not equal a catalog symbol name.

### `behavior` (required, string)

Controls what the function does when called:

| Value | Behaviour | Conditional field |
|-------|-----------|-------------------|
| `"echo-args"` | Returns all arguments as a single Lua table | (none) |
| `"fixed-return"` | Returns a fixed Lua value expression | `return_value` (required) |
| `"raise-error"` | Raises a Lua error with a given message | `error_message` (required) |

### `return_value` (string, conditional)

Present only when `behavior = "fixed-return"`. A Lua value expression
syntax-checked and materialized the same way as `[[mock.value]].value`.
Omit for all other behaviors.

```toml
[[mock.function]]
name = "get_count"
behavior = "fixed-return"
return_value = "42"
```

### `error_message` (string, conditional)

Present only when `behavior = "raise-error"`. The error string raised into
the Lua environment. Omit for all other behaviors.

```toml
[[mock.function]]
name = "fail_now"
behavior = "raise-error"
error_message = "simulated failure"
```

### Duplicate detection

Two `[[mock.function]]` entries with the same `name` are a load-time error.

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
