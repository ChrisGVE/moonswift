# Tests/Fixtures — Integration Test Fixture Projects

Each subdirectory here is a self-contained MoonSwift *scenario project*:
a `moonswift.toml` project file plus the source files it references.
Integration tests load these directories through the **real** production
stack — `SourceStore`, `RunService`, `LintService`, and the TUI reducer —
so they exercise the full end-to-end path without any mocks.

The fixtures live outside `MoonSwiftCoreTests/Fixtures/` (which holds unit
test data) to keep concerns separate: unit fixtures are individual files
exercised by a single service in isolation; scenario fixtures are whole
project directories driven through the combined stack.

---

## Directory structure

```
Tests/Fixtures/
  <scenario>/
    moonswift.toml      # project file declaring Lua version and sources
    <source>.(lua|yaml|json|toml)  # source files referenced by the project
  README.md             # this file
```

---

## Scenario catalogue

### Run fixtures — `RunService` behaviour

| Directory | Script | Expected outcome |
|-----------|--------|------------------|
| `run-print-and-error/` | Prints one line then calls `error()` | `output == ["before error"]`, outcome `.error` |
| `run-return-value/` | Three scripts returning string, number, nil | `.done(value: "hello")`, `.done(value: "42")`, `.done(value: nil)` |
| `run-runaway-loop/` | `while true do end` | `.limitExceeded(.instructions)` — test arms limit ≤ 1 000 |
| `run-sandbox-test/` | Probes `os.getenv` availability | `"sandboxed"` in sandbox mode; `"unrestricted"` in unrestricted mode |
| `run-instruction-limit/` | Prints before infinite loop | `output == ["before limit"]`, outcome `.limitExceeded(.instructions)` |

**Runaway-loop note:** `runaway-loop.lua` is an unbounded `while true do end`.
Tests that drive this file **must** set `instructionLimit` in `RunConfig` (≤
10 000 is enough for < 1 ms wall-clock).  The fixture `moonswift.toml`
documents the intended limit; the test sets it explicitly so the CI runner
is never blocked.

---

### Lint fixtures — `LintService` behaviour

| Directory | Script | Expected diagnostics |
|-----------|--------|----------------------|
| `lint-clean/` | Style-clean Lua function | Zero diagnostics |
| `lint-undefined-global/` | References `notDeclaredAnywhere` | ≥ 1 W1xx warning |
| `lint-syntax-error/` | Parse error on line 3 | `syntaxPrePass` returns non-nil with `line >= 3` |
| `lint-luaswift-modules/` | Uses `luaswift.json.decode` and `luaswift` root | Zero W1xx with catalog globals |
| `lint-opt-in-modules/` | Uses `luaswift.iox` | Fewer W1xx with `extra_modules = ["iox"]` than without |

---

### Structured-file fixtures — `SourceStore` loading

| Directory | File type | JSONPath / notes | Expected events |
|-----------|-----------|------------------|-----------------|
| `structured-yaml/` | YAML | `$.scripts.init`, `$.scripts.run` | 2 `.loaded` events |
| `structured-json/` | JSON | `$.handlers.onCreate` | 1 `.loaded` event |
| `structured-toml/` | TOML | `$.hooks[0].script` | 1 `.loaded` event |
| `structured-multi-doc/` | YAML multi-doc | `$.script` document 0 and 1 | 2 `.loaded` events from separate documents |
| `structured-wildcard/` | YAML | `$.handlers.*` (wildcard) | 2 `.loaded` events (one per handler) |

---

### Error fixtures — `SourceStore` failure cases

| Directory | Error kind | Expected `.failed` state |
|-----------|------------|--------------------------|
| `error-missing-source/` | Referenced `.lua` file absent from disk | `.missing` |
| `error-malformed-yaml/` | YAML with intentional parse error | `.failed(Diagnostic)` with `message` starting `"✖"` |
| `error-non-string-field/` | JSONPath resolves to integer (`$.version`) | `.failed(Diagnostic)` containing `"expected string"` |
| `error-unresolved-path/` | JSONPath matches no nodes | `.failed(Diagnostic)` with `message` starting `"⚠"` |

---

### Parser fixtures — hostile input strings

| Directory | Scenario | Key assertion |
|-----------|----------|---------------|
| `parser-hostile-chunkname/` | String literals containing `"]:N:"` | `syntaxPrePass` returns `nil`; luacheck long-string encoder survives the round-trip |
| `parser-hostile-message/` | `error()` with `"]:1:"` in the message | `Diagnostic.message` preserves the full error string; the location parser does not strip message content |

---

## Using fixtures in tests

### Core integration tests (`IntegrationTests.swift`)

Load fixture source files through `SourceStore.loadLuaFile` or
`SourceStore.loadStructuredFile`, run them through `RunService.run` or
`LintService.lint`, and assert outcomes.  All fixtures are bundled into
`MoonSwiftCoreTests` via the `Package.swift` `.copy("Fixtures")` resource
rule for `MoonSwiftCoreTests`; access them via `Bundle.module`:

```swift
// Resolve the scenario directory inside the test bundle.
let fixtureDir = Bundle.module.url(
    forResource: "Fixtures/run-print-and-error", withExtension: nil
)!
```

### TUI flow tests (`FixtureFlowTests.swift`)

Drive the reducer with scripted `AppEvent` sequences and assert
`AppState` transitions.  Fixture source code is embedded directly as
inline strings derived from the fixture Lua files so the TUI tests have
no bundle dependency.
