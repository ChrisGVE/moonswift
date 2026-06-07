# MoonSwift — UX Specification

Status: **binding for P1 implementation**
Authority: [UX] = UX designer decision; [PRD §N] = PRD binding; [ARCH §N] = ARCHITECTURE binding
Supersedes: `tmp/prd-workspace/ux-contribution.md` (lost original; this document is the permanent record)
Referenced by: PRD §6, ARCHITECTURE §2 (Renderer/ThemeEngine rows), docs/internals table

---

## §1 Layout

### 1.1 Chrome rows

| Row | Content | Height |
|-----|---------|--------|
| Title bar | App name + mode badges | 1 row |
| Upper zone | Navigator ‖ Code pane (split) | variable |
| Lower zone | Bottom pane | variable |
| Status bar | State indicators + contextual hints | 1 row |

Total chrome: 2 rows. Usable rows = terminal rows − 2. [PRD §6.1]

### 1.2 Vertical split proportions

- Upper zone: **65%** of usable rows (rounded down). [PRD §6.1]
- Bottom pane: **35%** of usable rows, **minimum 5 rows**. [PRD §6.1, §6.7]
- When 35% rounds below 5 rows, the bottom pane is pinned at 5 rows and the upper zone takes the remainder.

### 1.3 Horizontal split — navigator width

- Default: **18 columns**. [PRD §6.1, §6.7]
- Minimum: **18 columns**. Maximum: **30 columns** (hard cap regardless of terminal width). [PRD §6.1]
- Runtime adjustment: `<` / `>` nudge the navigator ±2 columns per keypress, clamped to [18, 30]. [PRD §6.1]
- Bottom pane height adjustment: `{` / `}` nudge the bottom pane ±1 row per keypress, clamped to [5 rows, upper-zone-min-3 rows]. [PRD §6.1]
- Session-only in P1; persisted to `[settings]` in P2. [PRD §6.1]

### 1.4 Minimum terminal and resize behavior

- **Minimum supported size: 80 columns × 24 rows.** [PRD §6.1]
- At 80×24: upper zone = 14 rows (65% of 22 usable), bottom pane = 8 rows.
- On resize below 80×24: leave alternate screen, display the resize prompt on the raw terminal:

  ```
  Terminal too small (WxH). Please resize to at least 80×24.
  ```

  MoonSwift resumes losslessly when the terminal regrows to or above the minimum — no state is lost during the wait. [PRD §6.1]
- At 200×60: upper zone = 38 rows, bottom pane = 20 rows; navigator default 18 cols (user may expand to 30). [UX]

### 1.5 Border and focus rendering rules

- **Outer borders**: `Rounded` style (ratatui `Block::bordered().border_type(Rounded)`). [UX]
- **Unfocused pane border**: `border` token color. [UX]
- **Focused pane border**: `focus_border` token color. [UX]
- **Active tab** in the bottom pane tab bar: underlined in `focus_border` color. [PRD §6.3]
- The title bar and status bar have no borders — they are full-width rows. [UX]
- Gutter (line numbers + marks) is drawn with the cell-level API, not a widget border; it has no box-drawing characters. [UX]

### 1.6 Title bar content

- Left: `moonswift` (or the project display name if a project is loaded). [UX]
- Right badges (space-separated, shown only when relevant):
  - `[unrestricted]` in `warning` color when `run.config = "unrestricted"`. [PRD §5, ARCH §7.3]
  - `[Lua X.X: unsupported]` when the project specifies an unsupported Lua version. [PRD §6.5]
  - `[no project]` when launched in quick-file mode. [PRD §6.5]
- Left label is never truncated. Badges may be omitted right-to-left if the title bar is too narrow to fit all of them. [UX]

---

## §2 Focus and Navigation

### 2.1 Focus model

Single focus token. Focused pane renders its border in `focus_border` color and receives all keystrokes not handled globally. [PRD §6.2]

**Pane IDs (internal enum)**:
- `navigator`
- `codePane`
- `bottomPane`

Modal states (overlay the pane system, capture all input):
- `helpOverlay`
- `pickerModal`
- `initForm`

### 2.2 Pane-cycling keys

| Key | Action |
|-----|--------|
| `<Tab>` | Cycle focus: navigator → codePane → bottomPane → navigator (global); **context-sensitive: when bottomPane is focused, cycles bottom-pane tabs instead** [PRD §6.2, §6.7] |
| `<S-Tab>` | Reverse-cycle panes (global; no context-sensitivity) [PRD §6.2] |
| `<C-h>` | Jump focus to navigator [PRD §6.2] |
| `<C-l>` | Jump focus to codePane [PRD §6.2] |
| `<C-j>` | Jump focus to bottomPane [PRD §6.2] |

The `<Tab>` context-sensitivity is the **only** context-sensitive key in P1. The help overlay **must** document this explicitly. [PRD §6.2, §6.7]

### 2.3 Complete P1 keybinding table

**Global keys** (active in all panes unless a modal is open):

| Key | Action | Notes |
|-----|--------|-------|
| `r` | Run selected source | Preconditions: source loaded, version supported, no run in progress; transient on failure [PRD §6.2] |
| `x` | Cancel run | No-op if not running; degraded to status transient if #22 unavailable [PRD §6.2] |
| `l` | Run lint on selected source | Preconditions: source loaded, lint engine ready; "lint engine starting…" transient during `.initializing` [PRD §6.2, ARCH §3d] |
| `q` | Quit | Confirms cancels any run in progress [PRD §6.2] |
| `?` | Open help overlay | Centered modal, max 60×20, `Clear` widget; documents Tab context-sensitivity [PRD §6.2, §6.7] |
| `<C-p>` | Open project file in `$EDITOR` | Graceful transient if `$EDITOR` unset [PRD §6.2, F2] |
| `<C-r>` | Reload project file | [PRD §6.2, F2] |
| `<Tab>` | Cycle panes / cycle bottom tabs | Context-sensitive as above [PRD §6.2] |
| `<S-Tab>` | Reverse-cycle panes | [PRD §6.2] |
| `<C-h>` | Jump to navigator | [PRD §6.2] |
| `<C-l>` | Jump to code pane | [PRD §6.2] |
| `<C-j>` | Jump to bottom pane | [PRD §6.2] |

**Navigator keys** (focus = navigator):

| Key | Action |
|-----|--------|
| `j` / `k` | Move selection down / up |
| `g` | Jump to first entry |
| `G` | Jump to last entry |
| `<Enter>` | Load selected source into code pane |
| `o` | Same as `<Enter>` (open) |
| `<Space>` | Same as `<Enter>` |
| `/` | Filter navigator entries (inline search; `<Esc>` clears) |
| `m` | Open structured-file picker for the selected entry (only for structured-file entries; no-op otherwise) [PRD §6.7, F1.3] |

[PRD §6.2]

**Code pane keys** (focus = codePane):

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll down / up one line |
| `d` | Scroll down half-page (`Ctrl-d` vim equivalent) |
| `u` | Scroll up half-page |
| `f` | Scroll down full page |
| `b` | Scroll up full page |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `:<N><Enter>` | Jump to line N (the **only** `:` command in P1; `:q` shows "use q to quit" transient) |
| `n` | Jump to next diagnostic |
| `N` | Jump to previous diagnostic |
| `[d` | Jump to first diagnostic |
| `]d` | Jump to last diagnostic |

[PRD §6.2]

**Bottom pane keys** (focus = bottomPane):

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll output/diagnostics down / up |
| `<Enter>` | Jump code pane to error line (when focused on an error line); 500 ms highlight pulse [PRD F3] |
| `y` | Yank (copy to pbcopy) the focused line |
| `1` | Quick-jump to Output tab [PRD §6.7] |
| `2` | Quick-jump to Diagnostics tab [PRD §6.7] |
| `<Tab>` | Cycle to next tab (context-sensitive behavior) [PRD §6.2] |
| `<C-l>` | Clear output buffer [PRD §6.2] |

[PRD §6.2]

**Picker modal keys** (when picker is open — see §3.6):

| Key | Action |
|-----|--------|
| `j` / `k` | Move tree cursor down / up |
| `<Space>` / `<Right>` / `l` | Expand node |
| `<Left>` / `h` | Collapse node |
| `<Enter>` / `m` | Mark / unmark a string field |
| `s` | Save marks to project file and close picker |
| `<Esc>` | Cancel (with `Discard unsaved field marks? [y/N]` if dirty) |

[PRD F1.3]

### 2.4 Disabled-action behavior

Any action that cannot execute (precondition not met) consumes the key, displays a transient status-bar message for **1.5 s**, and produces no bell. [PRD §6.2, §6.7]

### 2.5 Help overlay requirement

The `?` help overlay is a centered modal (max 60 columns × 20 rows), rendered using ratatui's `Clear` widget behind the content box. It must include:

1. All global keybindings.
2. Per-pane keybindings (navigator, code pane, bottom pane).
3. An explicit note: **"`<Tab>`: cycles panes globally; cycles tabs when the bottom pane is focused."** [PRD §6.2]

`<Esc>` or `?` dismisses the overlay. [PRD §6.2]

---

## §3 Key Flows (Step-by-step)

### 3.1 First launch — no project

1. User runs `moonswift` in a directory with no `moonswift.toml`.
2. TUI opens in **empty state**: navigator is empty, code pane shows a centered prompt:
   ```
   No project file found.
   Press <i> to create moonswift.toml, or open a .lua file directly.
   ```
3. User presses `<i>` to open the **init form** (inline modal in the code pane area):
   - Field 1: `Lua version` — pre-filled `5.4` (only valid P1 value).
   - Field 2: `Source files` — multi-select file picker (lists `.lua`, `.json`, `.yaml`, `.toml` files relative to cwd).
   - `<Enter>` confirms each field; `<Tab>` moves between fields; `<Esc>` cancels without writing.
4. On confirm: `moonswift.toml` is written; TUI transitions to normal loaded state; navigator populates.
5. On `<Esc>`: nothing written; user remains in empty state. [PRD F2]

### 3.2 Open project (normal launch)

1. User runs `moonswift` or `moonswift <directory>`.
2. `moonswift.toml` is parsed; on success, `AppState` is seeded with the decoded `ProjectFile`.
3. First frame renders immediately: navigator shows all source entries in `.loading` state (spinner after 100 ms). [ARCH §3a]
4. Source loads complete asynchronously; entries transition to `.loaded` or `.failed` state.
5. If Lua version is unsupported: navigator populates normally, but `r` and `l` are disabled; bottom pane shows a persistent header:
   ```
   ✖ Lua version "X.X" is not supported. Supported: 5.4.
   ```
   Status bar shows `[Lua X.X: unsupported]`. [PRD F2, §6.1]
6. If project file is malformed: see §4.2. [PRD F2]

### 3.3 Browse and load a source

1. Navigator has focus; user presses `j`/`k` to move the selection.
2. User presses `<Enter>` to load the highlighted entry.
3. Code pane updates: source text is displayed with syntax highlighting, line numbers, and gutter marks if any diagnostics exist.
4. Status bar contextual hint updates for code pane focus.
5. If the source has a `.failed` state: code pane shows the error message (see §4.2). [PRD F1.4]

### 3.4 Run and read output

1. User presses `r` from any pane.
2. Reducer checks preconditions (source loaded, version supported, not already running).
3. Bottom pane auto-switches to Output tab; run header appears:
   ```
   ── Run N · <timestamp> ──
   ```
4. Status bar shows `[running…]` transient (persistent until run ends).
5. Print output lines stream into the Output tab in real time (coalesced; at most one render per 16 ms). [ARCH §3c]
6. On completion: footer appended per §6.4.
7. Bottom pane tab bar remains on Output. Code pane is not scrolled unless the user presses `<Enter>` on an error line. [PRD F3]

### 3.5 Diagnostic → source-line jump

1. A run or lint completes with diagnostics.
2. Error footer in Output tab shows: `error — <message> → jump to line N`. [PRD F3]
3. With focus on bottomPane, user presses `<Enter>` on a diagnostic line.
4. Code pane scrolls to the target fragment line; the line is highlighted with a **500 ms highlight pulse** (background color transitions from `highlight_pulse` to normal). [PRD §6.7, F3]
5. Code pane does not take focus automatically; user presses `<C-l>` to jump focus. [UX]

### 3.6 Structured-file picker (browse / mark / persist)

1. Navigator is focused on a structured-file entry (`.json`, `.yaml`, `.toml`).
2. User presses `m`. [PRD §6.7]
3. The picker modal opens: the code pane area is replaced with a tree view of the parsed file.
   - Keys with indentation; scalars annotated by type (`str`, `int`, `bool`, `arr`, `obj`).
   - Only `str` fields are markable; non-string fields render in `dim` color.
   - Pre-existing designations are pre-filled in `keyword` color.
4. User navigates with `j`/`k`, expands/collapses with `<Space>`/`l`/`h`.
5. User presses `<Enter>` or `m` on a `str` field to mark it; a `●` marker appears in `added` color. The status line at the bottom of the picker shows the generated normalized JSONPath.
6. User may mark multiple fields.
7. Pressing `s` saves all marks to `moonswift.toml` and closes the picker; the navigator updates to show the new entries.
8. Pressing `<Esc>` prompts `Discard unsaved field marks? [y/N]` if any marks are unsaved; `y` closes without writing, `N` returns to the picker.
9. If the file is malformed: picker shows `Cannot parse file: <error>`, nothing is markable, `<Esc>` exits. [PRD F1.3]

### 3.7 Unsupported-version degraded state

1. Project file specifies `lua_version = "5.3"` (or any non-`5.4` value in P1).
2. Project loads normally; sources are browsable; syntax highlighting works.
3. Bottom pane shows a persistent header (pinned above tab content):
   ```
   ✖ Lua version "5.3" is not supported. MoonSwift P1 supports Lua 5.4 only.
   ```
4. `r` and `l` are disabled; pressing them shows the 1.5 s transient:
   ```
   Run disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>.
   ```
5. `<C-p>` opens the project file in `$EDITOR`; `<C-r>` reloads after editing.
6. On reload with a supported version: normal state is restored without restart. [PRD F2, §6.1]

---

## §4 States

### 4.1 Normal states

| State | Navigator | Code pane | Bottom pane |
|-------|-----------|-----------|-------------|
| **Empty** (no project, no sources) | Empty with `(empty)` label | Centered prompt (see §3.1) | Tabs visible; all empty |
| **Loading** (sources loading, > 100 ms elapsed) | Entries with spinner animation | `Loading…` placeholder | — |
| **Loaded** | Entries with filenames; selected entry highlighted | Source text with highlights and gutter | Output / Diagnostics tabs populated |
| **Running** | Normal | Normal (scroll still works) | Output tab, run header visible, `[running…]` in status bar |
| **Lint running** | Normal | Normal | Diagnostics tab with `linting…` indicator |
| **Lintengine initializing** | Normal | Normal | Status bar: `lint engine starting…` on `l` press |

Spinner animation: braille set `⠁⠂⠄⡀⢀⠠⠐⠈` (truecolor); ASCII `|/-\` (256-color & NO_COLOR). [PRD §6.4, §6.7]

### 4.2 Error states

**Malformed project file** [PRD F2, §6.4]:
- Navigator shows single entry: `Project file error` in `error` color.
- Code pane shows:
  ```
  ✖ Project file error

  moonswift.toml: <parse error message, line N>

  Edit the file to correct the error, then press <C-r> to reload.
  ```
- Active keys: `<C-p>`, `<C-r>`, `q`, `?`. All others produce the disabled transient.
- Literal status bar: `[project error]`

**Missing source file** [PRD F1.1, F1.4]:
- Navigator entry: `✖ <filename>` in `error` color.
- Selecting it shows in the code pane:
  ```
  ✖ File not found: <project-relative-path>
  ```
- Other sources remain usable.
- Bottom pane diagnostic at project load:
  ```
  ⚠ N source(s) not found — see navigator
  ```

**Unresolved JSONPath** (path matches nothing) [PRD F1.4]:
- Navigator entry: `⚠ <filename>: <path>` in `warning` color.
- Selecting it shows in the code pane:
  ```
  ⚠ No match: <jsonpath> in <filename>
  The path expression did not match any field.
  ```
- Bottom pane diagnostic:
  ```
  ⚠ <filename>: JSONPath "<path>" matched no fields
  ```

**Non-string field** (path resolves to a non-string value) [PRD F1.4]:
- Navigator entry: `⚠ <filename>: <path>` in `warning` color.
- Selecting it shows in the code pane:
  ```
  ⚠ Non-string field: <jsonpath> in <filename>
  Field value is <type>, not a string. Only string fields can contain Lua code.
  ```
- Bottom pane diagnostic:
  ```
  ⚠ <filename>: JSONPath "<path>" resolves to <type>, expected string
  ```

**Malformed structured file** [PRD F1.4]:
- Navigator entry: `✖ <filename>` in `error` color.
- Bottom pane diagnostic:
  ```
  ✖ Cannot parse <filename>: <format error message>
  ```
- Selecting it shows in the code pane:
  ```
  ✖ Cannot parse <filename>

  <format error message>
  ```

**Lua engine error** (run-time engine failure, distinct from script error) [PRD F3, ARCH §7.1]:
- Output tab footer:
  ```
  ✖ Engine error: <message>
  ```
- Logged to `~/Library/Logs/moonswift/moonswift.log`.

**Lint engine error** [PRD F4.2, ARCH §3d]:
- Diagnostics tab shows:
  ```
  ✖ Lint engine error: <message>
  ```
- Pre-pass result is retained as the best available answer; gutter marks are not updated. [PRD F4.2]

### 4.3 Degraded states

**Small terminal (below 80×24)** [PRD §6.4]:
- Leave alternate screen; show resize prompt (see §1.4).
- No `NO_COLOR` downgrade needed — the terminal is not in use during the wait.

**256-color fallback** [PRD §6.6]:
- Detected via: `COLORTERM` not set to `truecolor`/`24bit` AND `$TERM` does not imply truecolor.
- All 18 semantic tokens use their 256-color index values (see §8 token table).
- Spinner falls back to ASCII `|/-\`.
- All other rendering is identical to truecolor mode.

**NO_COLOR** (full compliance per no-color.org) [PRD §6.4, §6.6]:
- `NO_COLOR` env var set (any value, including empty string) overrides all theme settings.
- Color output is entirely off.
- Box-drawing characters are retained (borders still drawn).
- Severity uses character prefixes: `E` (error), `W` (warning), `I` (info).
- Gutter marks: `E` and `W` characters (same as the `E`/`W` gutter marks — see §6.3 below).
- Diagnostic prefixes: `✖` and `⚠` are retained as they are symbolic, not color-only. [UX]
- Focus is indicated with **Bold** on the focused pane's border and content. [PRD §6.4]
- Spinner: ASCII `|/-\`. [PRD §6.4, §6.7]

**No `$EDITOR`** [PRD F2, §6.4]:
- `<C-p>` shows transient:
  ```
  $EDITOR is not set. Set it to open the project file.
  ```

---

## §5 Status Bar

### 5.1 Layout

The status bar is a single row at the bottom of the screen (below the bottom pane, above nothing). Two zones:

- **Left**: state indicators — never truncated. [PRD §6.5]
- **Right**: contextual hints for the focused pane — subject to the elision ladder. [PRD §6.5]

### 5.2 Persistent left indicators

Displayed as a space-separated sequence of bracketed labels. Multiple may coexist.

| Indicator | Condition |
|-----------|-----------|
| `[running…]` | A run is in progress |
| `[linting…]` | A lint pass is in progress |
| `[Lua X.X: unsupported]` | Project specifies an unsupported Lua version |
| `[no project]` | Quick-file mode (launched with `moonswift <file.lua>`) |
| `[project error]` | Malformed project file |

[PRD §6.5, §6.1]

### 5.3 Transient messages

- Displayed in the left zone, replacing normal indicators for **1.5 s**. [PRD §6.5, §6.7]
- Never stacked: a new transient replaces any active transient immediately. [PRD §6.5]
- Examples: "Run disabled: no source selected.", "lint engine starting…", "cancellation requires LuaSwift ≥ <version>".

### 5.4 Contextual hints per pane (right zone)

**Navigator focused**: `j/k navigate  Enter load  m picker  / filter`

**Code pane focused**: `j/k scroll  :N jump  n/N diag  r run  l lint`

**Bottom pane focused** (Output tab): `j/k scroll  Enter jump  y yank  1/2 tabs  C-l clear`

**Bottom pane focused** (Diagnostics tab): `j/k scroll  Enter jump  n/N diag  1/2 tabs`

### 5.5 Elision ladder (below 100 columns)

When the terminal width is less than 100 columns, contextual hints on the right are elided in four steps. The ladder is applied to the combined left + right content, left zone is never elided. [PRD §6.5, §6.7]

| Step | Column threshold | Action |
|------|-----------------|--------|
| 1 | < 100 | Drop long hints, keep short key-only hints: `j/k  Enter  r  l` |
| 2 | < 80 | Drop all contextual hints; show only state indicators on the left |
| 3 | < 60 | Abbreviate state indicators: `[run]`, `[lint]`, `[unsup]`, `[noprj]`, `[err]` |
| 4 | < 40 | Show only the most critical single indicator (highest priority: `[run]` > `[err]` > `[unsup]` > others) |

[PRD §6.5, UX]

---

## §6 Output Pane

### 6.1 Tab bar

The bottom pane has a tab bar row at its top. Tabs in P1:

- `[ Output ]` — always present
- `[ Diagnostics ]` — always present
- `[ Debug ]` — present only when the P2 debugger is active [PRD §6.3]

Active tab: underlined text in `focus_border` color. [PRD §6.3]

Source provenance (`<display-name>`) is right-justified in the tab bar row when a source is selected. [PRD §6.3]

### 6.2 Tab interaction spec

- `<Tab>` when bottomPane is focused: cycles Output → Diagnostics (→ Debug if active) → Output. [PRD §6.2]
- `1` quick-jumps to Output tab; `2` quick-jumps to Diagnostics tab. [PRD §6.7]
- `r` auto-switches to Output tab when a run starts. [PRD §6.3]
- `l` auto-switches to Diagnostics tab when a lint pass starts. [PRD §6.3]

### 6.3 Output tab — run header/footer formats

**Run header** (exact format):
```
── Run N · <timestamp> ──
```
Where `N` is the 1-based run counter for the session; `<timestamp>` is `HH:MM:SS`. [PRD F3, §6.7]

**Run footers** (exact format, one of):

| Outcome | Footer text |
|---------|-------------|
| Success | `done — Xms` |
| Script error | `error — <message> → jump to line N` |
| Cancelled | `cancelled` |
| Instruction limit | `instruction limit exceeded (N instructions)` |
| Wall-clock limit | `wall-clock limit exceeded (Xms)` |
| Engine error | `✖ Engine error: <message>` |

[PRD F3]

The `→ jump to line N` affordance is an interactive element: pressing `<Enter>` in the bottom pane while this line is focused scrolls the code pane to line N with a 500 ms highlight pulse. [PRD F3, §6.7]

Return value (non-nil `LuaValue`): rendered as a line between output and footer:
```
→ <display string>
```
Tables rendered shallow with `{…}` beyond depth 2. `nil` and no-return both display `(no value)`. [PRD F3]

### 6.4 Output tab — FIFO buffer

- Maximum **1000 lines**. [PRD §6.7]
- On overflow: oldest lines are discarded; a notice line is inserted:
  ```
  [cleared — N lines discarded]
  ```
- `<C-l>` clears the buffer manually (with a `[cleared]` notice at top). [PRD §6.2]

### 6.5 Diagnostics tab

- **Syntax pre-pass section**: always shown, even if clean. Header: `── Syntax ──`. Content: one line per diagnostic, or `✔ No syntax errors.`. [PRD F4.1, §6.3]
- **luacheck section**: header `── Lint ──`. Content: diagnostics sorted by line, severity prefix (`E`/`W`), or `✔ No issues found.`. [PRD §6.3]
- Each diagnostic line format: `<E|W> <line>:<col> <message> [<code>]`
- Empty overall Diagnostics tab (no pre-pass result yet, no lint run): shows `No diagnostics.` centered. [PRD §6.3]

### 6.6 Gutter marks in the code pane

The gutter is rendered left of line numbers using the cell-level API. [PRD F4.2, ARCH §2 Renderer row]

| Mark | Character | Color token | Condition |
|------|-----------|-------------|-----------|
| Error | `E` | `error` | Line has a luacheck error-severity diagnostic |
| Warning | `W` | `warning` | Line has a luacheck warning-severity diagnostic |
| Error + Warning | `E` | `error` | Line has both (error takes precedence) |
| Cursor line | `▶` (truecolor/256) / `>` (NO_COLOR) | `focus_bg` | Focused code pane, cursor row |
| Debug paused line (P2) | `▶` | `highlight_pulse` | Debugger paused at this line |
| Breakpoint set (P2) | `●` | `error` | Breakpoint on this line |
| Breakpoint + paused (P2) | `●` | `highlight_pulse` | Both conditions |

Character markers are **always present alongside color** — never color-only. [PRD §6.6]

### 6.7 Inline diagnostic hover

A single-row inline diagnostic hint is shown below the cursor line in the code pane when the cursor is on a line with a diagnostic. Format: `  ^ <message>` indented to the diagnostic column. [PRD F4.2, §6.7] Rendered as a cell-level overlay row (may push content down if near the bottom of the pane). [UX]

### 6.8 Narrow-width elision ladder for status bar and Output tab

The 4-step ladder (§5.5) applies to the status bar. For the Output tab header line, a separate 4-step ladder governs the run-header format: [PRD §6.5, UX]

| Step | Column threshold | Run header |
|------|-----------------|------------|
| 1 | ≥ 80 | `── Run N · HH:MM:SS ──` |
| 2 | ≥ 60 | `── Run N · HH:MM ──` |
| 3 | ≥ 40 | `── Run N ──` |
| 4 | < 40 | `──N──` |

---

## §7 P2–P4 Flow Sketches

### 7.1 P2 — Mock Environment forms

**Navigator structure in P2**:
- Upper section: source entries (unchanged from P1).
- Divider row: `─── Mock Environment ───` in `dim` color.
- Lower section: mock environment tree (namespaces → values, mock functions).

**Add mock** (`a` key in navigator, focus on Mock Environment section):
- Code pane area becomes an inline form: popup selects type (Value / Function / Namespace).
- **Value form fields**: Namespace, Key path, Type (`string`/`number`/`boolean`/`table`), Value (Lua literal), Writable (toggle).
- **Function form fields**: Function name, Behavior (`echo-args` / `fixed-return` / `raise-error`), Return value (Lua literal, shown only for `fixed-return`), Error message (shown only for `raise-error`).
- **Namespace form fields**: Namespace name only.
- `<Enter>` confirms; `<Esc>` cancels; fields validate on confirm.

**Edit mock** (`e` key, focused on an existing mock entry): same form pre-filled.

**Delete mock** (`d` key): confirms with `Delete this mock? [y/N]`.

**Live state**: post-run, mock values that were written by the script reflect the actual engine state (via LuaSwift#21 introspection). [PRD F5]

### 7.2 P2 — Debugger keys and variable pane placement

**Debug run**: `<C-g>` starts a debug run (distinct from `r` plain run). [PRD F6]

**Breakpoints**: `b` in the code pane toggles a breakpoint on the cursor line. Gutter marks: `○` (no breakpoint) / `●` (breakpoint set). [PRD F6]

**While paused** (debug session active, execution stopped at a line):

| Key | Action |
|-----|--------|
| `s` | Step over |
| `i` | Step into |
| `o` | Step out |
| `c` | Continue |
| `x` | Stop debug session |

[PRD F6]

**Variable / Debug tab placement**: the bottom pane gains a `[ Debug ]` tab (auto-shown when `<C-g>` starts). Tab content:
- **Locals** section: `local <name> = <value>` per local in the current frame.
- **Upvalues** section: `upvalue <name> = <value>`.
- **Globals** section: on-demand, expanded with a key (`g` to toggle).
- **Call stack** section: one line per frame, `<Enter>` on a frame retargets the code pane to that frame's source line.

Table values support inline expansion with `<Enter>` on the value line. [PRD F6]

Status bar while paused: `[paused at <display-name>:<line>]  s/i/o step  c continue  x stop`.

### 7.3 P4a — Suspend-to-`$EDITOR` round trip

1. User presses `<C-e>` (source file) from the code pane. [PRD F8a]
2. MoonSwift leaves alternate screen (pump parks, terminal handed to `$EDITOR`). [ARCH §5.2]
3. For whole `.lua` files: `$EDITOR` opens the file directly.
4. For structured-file fragments: `$EDITOR` opens a temp buffer (`/tmp/moonswift-<pid>-<hash>.lua`) containing only the fragment text.
5. User edits and saves; `$EDITOR` exits.
6. MoonSwift re-enters alternate screen; runs syntax pre-pass.
7. On syntax error: re-opens `$EDITOR` with a Lua comment block at the top:
   ```lua
   -- SYNTAX ERROR: <message> (line N)
   -- Fix the error above, then save to continue. Delete this block to force-accept.
   ```
   (kubectl pattern) [PRD F8a]
8. On success: write-back is performed (span-splice for fragments; overwrite for whole files). [PRD F8a]
9. Conflict guard: if the file hash changed since load, prompt:
   ```
   File changed externally. [r]eload / [o]verwrite / [d]iff / [c]ancel
   ```
   [PRD F8a]

### 7.4 P4b — Embedded Neovim (ext_linegrid) pane

1. `nvim --embed` is spawned when `<C-e>` is pressed and `nvim` is on PATH (P4b behavior; P4a is the fallback). [PRD F8b]
2. The code pane becomes the nvim grid: MoonSwift renders the single ext_linegrid grid into the code pane area using the cell-level API. [PRD F8b]
3. Input: crossterm key events are translated to nvim key notation and sent via msgpack-RPC.
4. `:w` is intercepted by MoonSwift (not forwarded to nvim) and triggers the write-back contract.
5. MoonSwift's own status bar and tab bar remain; nvim `laststatus=0`.
6. No `nvim` on PATH: fall back silently to P4a behavior with a one-time status-bar note:
   ```
   nvim not found. Using $EDITOR for editing.
   ```
   [PRD F8b]

### 7.5 P3 — Lua function invocation picker

1. In the P2 Mock Environment navigator section, user focuses on a Lua function entry.
2. User presses `<Enter>` to open the invocation form in the code pane area.
3. Form fields: one text input per expected argument (type shown from catalog if available).
4. `<Enter>` confirms; MoonSwift calls `callAndReleaseLuaFunction` with the constructed `LuaValue` args.
5. Result appears in the Output tab as `→ <result display string>`. [PRD F5]

### 7.6 P3 — Completion popup and hover overlay

**Completion popup** (`<C-space>` in code pane) [PRD F7a]:
- Popup appears below the cursor, max 10 items visible, scrollable with `j`/`k`.
- Each item: `<function-or-module-name>  <short signature>` if available.
- `<Enter>` opens the hover overlay for the selected item (code pane is read-only pre-P4, so no insertion).
- `<Esc>` dismisses.

**Hover overlay** (`K` in code pane, or `<Enter>` in the completion popup) [PRD F7a]:
- Centered modal, max 60 columns × 15 rows.
- Content: function/module name, full signature, doc string.
- `<Esc>` or `K` dismisses.

---

## §8 Theme

### 8.1 Complete semantic token table

18 tokens. Each has a truecolor hex value, a 256-color palette index, and a usage description. The truecolor palette is derived from Dracula (perceptual-contrast adjusted). The 256-color index is chosen for maximum perceptual contrast against the pane background on a standard 256-color terminal palette. [PRD §6.6, §6.7]

| Token | Role / Usage | Truecolor hex | 256-color index |
|-------|-------------|---------------|-----------------|
| `keyword` | Lua keywords (`if`, `then`, `end`, `function`, `local`, `return`, `for`, `while`, `do`, `in`, `not`, `and`, `or`, `nil`, `true`, `false`, `repeat`, `until`, `break`, `goto`) | `#FF79C6` (Dracula pink) | 212 (medium pink) |
| `string` | String literals (single/double-quoted, long strings) | `#F1FA8C` (Dracula yellow) | 228 (light yellow) |
| `comment` | Line comments (`--`), block comments (`--[[ ]]`) | `#6272A4` (Dracula comment) | 61 (muted blue-purple) |
| `number` | Numeric literals (integer, float, hex) | `#BD93F9` (Dracula purple) | 141 (soft purple) |
| `function_name` | Function declaration names, method names | `#50FA7B` (Dracula green) | 84 (bright green) |
| `identifier` | Local variables, parameters, field access | `#F8F8F2` (Dracula foreground) | 255 (near-white) |
| `operator` | Operators (`+`, `-`, `*`, `/`, `..`, `#`, `~=`, `==`, `<`, `>`, `<=`, `>=`, `=`, `.`) | `#FF79C6` (Dracula pink, same as keyword) | 212 |
| `error` | Error severity diagnostics; `✖` prefixes; missing-source navigator entries | `#FF5555` (Dracula red) | 203 (bright red) |
| `warning` | Warning severity diagnostics; `⚠` prefixes; unresolved-path navigator entries | `#FFB86C` (Dracula orange) | 215 (soft orange) |
| `added` | Picker marks (`●`); newly-added items | `#50FA7B` (Dracula green) | 84 |
| `focus_border` | Focused pane border; active tab underline | `#BD93F9` (Dracula purple) | 141 |
| `focus_bg` | Cursor-line background in code pane; cursor-row `▶` gutter mark | `#44475A` (Dracula selection) | 237 (dark gray) |
| `highlight_bg` | Jump-target line background (persistent highlight after jump) | `#3D4455` (slightly lighter than selection) | 238 |
| `highlight_pulse` | 500 ms pulse animation start color for jump-target lines; debug paused-line background | `#6272A4` (Dracula comment blue) | 61 |
| `dim` | Non-markable fields in picker; divider rows; secondary labels | `#6272A4` (Dracula comment) | 61 |
| `running` | `[running…]` status bar indicator; spinner color | `#8BE9FD` (Dracula cyan) | 117 (light cyan) |
| `gutter_bg` | Gutter background (line numbers + marks column) | `#282A36` (Dracula background, slightly offset) | 236 (very dark gray) |
| `pane_bg` | Default pane content background | `#282A36` (Dracula background) | 235 (dark gray) |

Note: `status_bar` is not a separate token — the status bar row uses `pane_bg` as background with `identifier` for normal text and the respective indicator tokens for bracketed labels. [UX]

### 8.2 Tree-sitter capture-name → token mapping

Mapping for the `tree-sitter-lua` grammar (SwiftTreeSitter capture names). All unmapped captures fall back to `identifier`. [PRD §6.6, ARCH §2 Highlighter row]

| tree-sitter-lua capture name | Token |
|------------------------------|-------|
| `keyword` | `keyword` |
| `keyword.function` | `keyword` |
| `keyword.return` | `keyword` |
| `keyword.operator` | `keyword` |
| `keyword.conditional` | `keyword` |
| `keyword.repeat` | `keyword` |
| `keyword.exception` | `keyword` |
| `string` | `string` |
| `string.escape` | `keyword` (distinct visual; reuses keyword pink) |
| `comment` | `comment` |
| `number` | `number` |
| `function` | `function_name` |
| `method` | `function_name` |
| `constructor` | `function_name` |
| `variable` | `identifier` |
| `variable.builtin` | `keyword` (`_G`, `_ENV`, `self`) |
| `field` | `identifier` |
| `parameter` | `identifier` |
| `operator` | `operator` |
| `punctuation.bracket` | `identifier` |
| `punctuation.delimiter` | `identifier` |
| `constant` | `number` |
| `constant.builtin` | `keyword` (`nil`, `true`, `false`) |
| `type` | `function_name` |
| `label` | `keyword` (goto labels) |

[UX]

### 8.3 Capability detection order

1. Check `NO_COLOR` environment variable (any value including empty string): if set, enter NO_COLOR mode. [PRD §6.4]
2. Check `COLORTERM` environment variable: if value is `truecolor` or `24bit`, use truecolor. [PRD §6.6]
3. Check `$TERM`: if value contains `256color` (e.g. `xterm-256color`), use 256-color.
4. Default to 256-color (safe for any modern terminal). [PRD §6.6]
5. NO_COLOR override beats every theme setting. [PRD §6.4]

### 8.4 Theme extensibility

One built-in theme in P1 (`theme = "default"`). The theme is a flat `token → color` map; additional themes are additive (new entries in the map, same 18 tokens). Future themes set only the tokens they override; missing tokens fall back to the default. [PRD §6.6]

### 8.5 Accessibility rule

**Never encode meaning in color alone.** Every semantic distinction made by color must also be expressed by a character or shape marker. [PRD §6.6]

This is an enforced rule, not a guideline. Implementation checklist:
- Diagnostics: `E`/`W` character prefix alongside `error`/`warning` color. [PRD §6.6]
- Navigator missing-source: `✖` prefix alongside `error` color. [PRD F1.1]
- Navigator unresolved-path: `⚠` prefix alongside `warning` color. [PRD F1.4]
- Gutter marks: `E`/`W` characters alongside colors. [PRD F4.2]
- Focus: border color change + Bold (in NO_COLOR mode, Bold is the only indicator). [PRD §6.4]
- Active tab: underline alongside `focus_border` color. [PRD §6.3]
- Running indicator: `[running…]` text alongside `running` color. [PRD §6.5]
- Picker marks: `●` character alongside `added` color. [PRD F1.3]

---

*End of UX specification. This document is the permanent, binding record for P1 implementation. Updates require a spec revision here first; `docs/internals/ux-spec.md` is the single source of truth for all UX decisions.*
