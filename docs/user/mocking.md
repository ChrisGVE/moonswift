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
returns a fixed response or echoes its arguments. See the
[project file reference](project-file.md#mock-function-definitions) for
the `[[mock.function]]` schema.

---

## Running against mocks

See [running.md](running.md) for how mock setup integrates with the run
lifecycle.
