# MoonSwift — mocking

Mocking lets you develop and test Lua scripts against a stable, controlled
interface without a real host application running. You declare the values and
functions your script expects as entries in `moonswift.toml`; MoonSwift
installs them into the Lua engine before each run.

## Mock values

A mock value is a Lua value — scalar, table, function, or any value expression
— injected under a namespace global at session start.

### Declaring a mock value

Add a `[[mock.value]]` entry to `moonswift.toml`:

```toml
[[mock.value]]
namespace = "myapp"
path      = "settings.debug"
type      = "boolean"
value     = "true"
writable  = false
```

The fields:

| Field | Required | Description |
|-------|----------|-------------|
| `namespace` | yes | The top-level Lua global name (e.g. `myapp`). Must not collide with catalog symbols. |
| `path` | yes | Dotted key path within the namespace (e.g. `settings.debug` for `myapp.settings.debug`). |
| `type` | yes | Informational label: `string`, `number`, `boolean`, `table`, or `expr`. Does not restrict the expression. |
| `value` | yes | Any syntactically valid Lua value expression. Evaluated at session start. |
| `writable` | yes | Whether Lua scripts may assign to this path during a run. |

### How mock values work at runtime

When a session starts, MoonSwift evaluates each `value` expression via

```
evaluate("return <value>")
```

under the project's configured engine mode (sandboxed or unrestricted). The
materialized result is served to Lua scripts through a `LuaValueServer`
registered as the namespace global. The registration happens before the
stdlib baseline is captured, so mock namespaces are correctly excluded from
the "user globals" column in the navigator.

Your Lua script reads the value with ordinary dot notation:

```lua
if myapp.settings.debug then
    print("debug mode")
end
```

### Value expressions (RQ1)

The `value` field is a Lua value expression — not a bare literal. Any
expression that `return <value>` can evaluate is valid:

| `type` | Example `value` | What Lua sees |
|--------|----------------|---------------|
| `boolean` | `true` | `true` |
| `number` | `1 + 2 * 3` | `7` |
| `string` | `"hello"` | `"hello"` |
| `table` | `{1, 2, 3}` | a table with three entries |
| `expr` | `function() return 42 end` | a callable function |

A syntax error in `value` is caught at load time and reported as a project
diagnostic. No run starts with an invalid mock value.

### Function literals

An `expr`-typed mock can carry a function literal:

```toml
[[mock.value]]
namespace = "myapp"
path      = "factory"
type      = "expr"
value     = "function() return 42 end"
writable  = false
```

The function materialises as a callable. A script can invoke it:

```lua
local n = myapp.factory()  -- n == 42
```

**Sandbox note:** a function literal that calls a sandbox-stripped API
(such as `os.execute`) compiles at load time but raises a runtime error
when the script invokes it under `sandboxed` mode. This is consistent with
the engine's sandbox contract — the function body runs under the same rules
as all other Lua code. Under `unrestricted` mode the function has full host
authority.

### Writable paths

When `writable = true`, scripts may assign to the path:

```lua
myapp.counter = myapp.counter + 1
```

The assigned value is stored in the server's in-memory state and is visible
in the navigator's live-state view after the run. Writes do not persist
across sessions.

A write to a path declared `writable = false` raises a Lua runtime error,
which surfaces as a structured diagnostic in the output pane.

### Multiple paths in one namespace

All `[[mock.value]]` entries sharing the same `namespace` are served by one
server. Paths within that namespace are independent:

```toml
[[mock.value]]
namespace = "config"
path      = "database.host"
type      = "string"
value     = '"localhost"'
writable  = false

[[mock.value]]
namespace = "config"
path      = "database.port"
type      = "number"
value     = "5432"
writable  = false
```

```lua
print(config.database.host)  -- "localhost"
print(config.database.port)  -- 5432.0
```

### Duplicate detection

Two `[[mock.value]]` entries with the same `namespace` and `path` are a
load-time error. Each `(namespace, path)` pair must be unique across the
project file.

---

## Mock functions

A mock function is a callable Lua global — not a namespace value — that
responds to calls with a fixed behaviour: echo its arguments back, return a
configured value, or raise an error. Declare it with `[[mock.function]]` in
`moonswift.toml`; MoonSwift registers it in the Lua engine before the run
begins.

### Declaring a mock function

```toml
[[mock.function]]
name     = "host_log"
behavior = "echo-args"
```

The fields:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | The Lua global name the script calls. Must not collide with catalog symbols or the reserved `__moonswift_` prefix. |
| `behavior` | yes | What the function does: `"echo-args"`, `"fixed-return"`, or `"raise-error"`. |
| `return_value` | conditional | A Lua value expression. Required when `behavior = "fixed-return"`. Omit for all other behaviors. |
| `error_message` | conditional | The error string raised into Lua. Required when `behavior = "raise-error"`. Omit for all other behaviors. |

### Behaviors

#### `"echo-args"` — return all arguments as one table

The function returns its arguments packaged as a single Lua table. The first
argument becomes index 1, the second index 2, and so on.

```lua
local t = host_log("tick", 42)
-- t[1] == "tick", t[2] == 42
```

Because `registerFunction` returns exactly one Lua value, multiple returns are
not possible. A multi-variable assignment gets the table as the first variable
and `nil` for every subsequent one:

```lua
local a, b = host_log("x", "y")
-- a == {"x", "y"}, b == nil
```

This is the intended contract (DOM-04). Document it in any Lua code that
destructures the return.

#### `"fixed-return"` — return a configured value (RQ1)

The function always returns the same value, which you specify as a Lua value
expression in `return_value`. Any expression that `return <value>` can evaluate
is valid: scalars, table constructors, computed expressions, and function
literals.

```toml
[[mock.function]]
name         = "get_level"
behavior     = "fixed-return"
return_value = "42"
```

```lua
local n = get_level()   -- n == 42
```

Computed expressions work too:

```toml
return_value = "10 * 2"   -- returns 20
```

A function literal makes the mock return a callable:

```toml
[[mock.function]]
name         = "get_handler"
behavior     = "fixed-return"
return_value = "function(x) return x + 1 end"
```

```lua
local fn = get_handler()
local n  = fn(5)          -- n == 6
```

The expression is evaluated **once at session start**, before any script code
runs, under the project's configured engine mode (sandboxed or unrestricted).
The materialized value is returned unchanged on every subsequent call. A
sandbox-stripped API inside a function literal (such as `os.execute`) will
raise at runtime when invoked under sandboxed mode — the same rule that applies
to mock values.

A syntax error in `return_value` is caught at load time and reported as a
project diagnostic. No run starts with an invalid expression.

#### `"raise-error"` — raise a Lua error

The function raises a Lua runtime error with the configured message. The
running script stops at the call site, and MoonSwift surfaces a structured
diagnostic in the output pane — including a traceback that identifies the
fragment line where the call occurred.

```toml
[[mock.function]]
name          = "host_connect"
behavior      = "raise-error"
error_message = "simulated network failure"
```

```lua
-- Calling host_connect() produces a runtime error:
-- error: simulated network failure (line N)
local ok = host_connect()   -- not reached
```

Use this to test how your script handles error conditions from the host.

### How mock functions are installed

At session start, MoonSwift installs each `[[mock.function]]` as a Lua global
before the stdlib baseline is captured. The function is therefore correctly
excluded from the "user globals" column in the navigator — the same policy as
mock values.

Registration happens through `registerFunction(name:callback:)` (LuaSwift's
callback surface). The callback for `fixed-return` materializes the
`return_value` expression at this point; the callbacks for `echo-args` and
`raise-error` are lightweight closures with no up-front evaluation cost.

### Uniqueness constraint

Two `[[mock.function]]` entries with the same `name` are a load-time error.
Each function name must be unique across the project file.

---

See the [project file reference](project-file.md#mock-function-definitions)
for the complete `[[mock.function]]` schema.

---

## The Mock Environment navigator

The navigator has a second section below the source list, under a
`─── Mock Environment ───` divider. It shows the declared mock values
(`namespace.path = value`) and functions (`name (behavior)`), and — after a run —
the live state (introspected current values), or `(run to populate live state)`
before the first run.

Move between the two sections with `j`/`k`: pressing `j` on the last source steps
into the Mock Environment, and `k` on its first row steps back out (the divider
is skipped). `g`/`G` return to the source list.

### Editing mocks from the navigator

| Key | Action |
|-----|--------|
| `a` | Add a mock — a popup chooses Value / Function / Namespace, then an inline form |
| `e` | Edit the selected mock (form pre-filled) |
| `d` | Delete the selected mock (`Delete this mock? [y/N]`) |

In the form, `Tab` moves between fields, typing edits text fields, `Space`/`←`/`→`
cycle the Type / Behavior / Writable fields, `Enter` confirms, and `Esc` cancels.
Every add, edit, or delete is saved to `moonswift.toml` immediately.

- **Value form**: Namespace, Key path, Type, Value, Writable.
- **Function form**: Function name, Behavior, then Return value (for
  `fixed-return`) or Error message (for `raise-error`).

## Running against mocks

See [running.md](running.md) for how mock setup integrates with the run
lifecycle.
