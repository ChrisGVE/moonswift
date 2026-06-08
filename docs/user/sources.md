# MoonSwift — source loading

MoonSwift loads Lua code from two kinds of sources: standalone `.lua` files
and designated string fields inside structured files (JSON, YAML, TOML). Both
are declared in `moonswift.toml` as `[[source]]` entries.

## Standalone .lua files

A `[[source]]` entry with no `[[source.field]]` sub-entries loads the whole
file as a single Lua fragment.

```toml
[[source]]
path = "scripts/init.lua"
```

The path is project-root-relative. Absolute paths and paths traversing above
the project root are rejected. The file is read as UTF-8; invalid byte
sequences are replaced with the Unicode replacement character so the file
remains viewable.

## Structured files: designating fields

JSON, YAML, and TOML files may contain multiple string fields, each holding a
Lua snippet. MoonSwift loads each designated field as a separate fragment
visible as a distinct navigator entry.

```toml
[[source]]
path = "config/app.yaml"

  [[source.field]]
  jsonpath = "$.scripts.init"

  [[source.field]]
  jsonpath = "$.scripts.cleanup"
```

Each `[[source.field]]` entry requires a `jsonpath` expression. The
`document` key is additionally available for YAML multi-document files (see
below).

### Interactive picker

For structured files listed in the navigator, press `m` to open the
interactive picker. The picker displays the file as a tree with scalar
values annotated by type. String fields are markable; pressing `<Enter>` or
`m` on a string field adds it to the selection. Press `s` to save the marks
to `moonswift.toml` and close the picker.

## JSONPath subset

MoonSwift implements the RFC 9535 JSONPath subset described below. Full RFC
9535 support (filter selectors, slice selectors, function extensions) is
outside the P1 scope and produces an error diagnostic.

### Supported constructs

| Construct | Syntax | Example |
|-----------|--------|---------|
| Root | `$` | `$` |
| Child (dot) | `$.key` | `$.scripts` |
| Child (bracket, quoted) | `$['key']` or `$["key"]` | `$['my-key']` |
| Child (bracket, index) | `$[N]` | `$[0]` |
| Wildcard (dot) | `.*` | `$.items.*` |
| Wildcard (bracket) | `$[*]` | `$[*]` |
| Descendant (name) | `$..key` | `$..handler` |
| Descendant (wildcard) | `$..*` | `$..*` |
| Descendant (bracket) | `$..[N]` or `$..['key']` | `$..[0]` |

Key names in dot notation must start with a letter or underscore and contain
only letters, digits, and underscores. Keys containing hyphens, spaces, or
Unicode characters outside the ASCII range must use bracket notation with
quotes: `$['my-key']`.

### Unsupported constructs (produce error diagnostics)

| Construct | Example | Reason |
|-----------|---------|--------|
| Filter selector | `$[?@.price < 10]` | Outside P1 scope |
| Slice selector | `$[0:3]` | Outside P1 scope |
| Negative index | `$[-1]` | Outside P1 scope |
| Function extensions | `$[length(@)]` | Outside P1 scope |

### Normalized form

MoonSwift normalizes all JSONPath expressions to a canonical form before
storing them in `moonswift.toml`. For example, the bracket form `$['scripts']`
normalizes to the dot form `$.scripts` when the key is a valid identifier.
The normalized path is shown in the picker status line and in diagnostic
messages.

## YAML multi-document files

YAML files may contain multiple documents separated by `---`. The `document`
key in a `[[source.field]]` entry selects which document to read from
(zero-based). The default is `0` (the first document).

```toml
[[source]]
path = "handlers.yaml"

  [[source.field]]
  jsonpath = "$.on_start"
  document = 0

  [[source.field]]
  jsonpath = "$.on_stop"
  document = 1
```

Setting `document` to a non-zero value on a `.json` or `.toml` source is an
error (those formats do not support multiple documents).

## YAML aliases

Designating a YAML alias node (a node that uses `*anchor` notation rather
than inline content) produces an error. Designate the anchor node instead.

## TOML mapping contract

TOML maps cleanly to the JSONPath model: TOML tables are objects (map nodes)
and TOML arrays are arrays. The full TOML type set is supported for tree
traversal; only the leaf node designated by the JSONPath expression must be a
string.

## Error states

Each source entry in the navigator reflects the current load state.

| State | Navigator decoration | Cause |
|-------|----------------------|-------|
| Loading | spinner (after 100 ms) | Background load in progress |
| Loaded | filename or `filename:$.path` | Load succeeded |
| Missing | `✖ <filename>` in red | File not found |
| Load error | `✖ <filename>` in red | File exists but cannot be read (I/O or parse error) |
| Unresolved path | `⚠ <filename>: <path>` in orange | JSONPath matched no fields |
| Non-string field | `⚠ <filename>: <path>` in orange | Designated field is not a string |

When a source fails to load, other sources are unaffected. The code pane
shows the error message when the failed entry is selected.
