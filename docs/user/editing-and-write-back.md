# MoonSwift — editing and write-back

MoonSwift provides in-place editing via an embedded Neovim session or, when
Neovim is not available, via your `$EDITOR`. Both paths use the same write-back
contract: edits are spliced precisely into the source file without altering
anything outside the edited span.

---

## Opening the editor

Press `<C-e>` (Ctrl+e) with a source selected in the code pane to open the
editor. What happens next depends on whether `nvim` is available:

- **Neovim found** — Neovim opens embedded inside MoonSwift's code pane. The
  source text appears in the nvim buffer ready to edit.
- **Neovim not found** — a one-time status-bar note appears (once per session
  only; it will not repeat on subsequent edits) and your `$EDITOR` is launched
  instead. MoonSwift suspends its terminal, hands control to the editor, then
  resumes when the editor exits.

---

## Editing with embedded Neovim

Neovim 0.9 or later is required. MoonSwift probes the version at each `<C-e>`
press and falls back to `$EDITOR` if the requirement is not met.

The code pane becomes a full Neovim buffer. All standard Neovim commands work:
navigate with `hjkl`, enter insert mode with `i`, search with `/`, and so on.

**Keybindings inside the nvim pane:**

| Key | Action |
|-----|--------|
| `:w` or `:w!` | Write the buffer back to the source file |
| `<C-e>` | Exit the nvim pane and return to the normal code view |
| All other keys | Forwarded directly to Neovim |

Neovim runs `--clean` with XDG isolation: your full plugin stack does not load.
MoonSwift suppresses Neovim's own status bar (`laststatus=0`) so its chrome does
not overlap with MoonSwift's.

---

## Write-back contract

When you press `:w` inside the nvim pane (or save from `$EDITOR`), MoonSwift
runs the write-back pipeline. Three conditions must hold or the write is
aborted with a diagnostic:

1. **The file re-parses** — the edited Lua passes a syntax pre-pass. If it
   fails, the write is blocked and a diagnostic appears. For the `$EDITOR` path
   the error comment loop re-opens the editor with the diagnostic injected as a
   Lua comment at the top of the buffer (you can delete it and save to override).
2. **Bytes outside the span are preserved** — for structured-file fields
   (JSON/YAML/TOML), only the exact byte range of the Lua value is replaced.
   Everything else — comments, whitespace, other keys, the file format — is
   left byte-for-bit identical to the original. MoonSwift never re-encodes the
   host file.
3. **The re-extracted field matches** — after splicing, MoonSwift re-parses the
   host file and re-extracts the designated field. The result must equal the
   text you edited. If it does not (a theoretical case given the format rules
   below), the write is aborted with a diagnostic.

### Format-specific rules

| Format | How the value is represented |
|--------|------------------------------|
| **JSON** | JSON string with full escape handling (`\n`, `\"`, `\\`, control chars as `\uXXXX`); always single-line |
| **YAML** | Original block scalar style preserved; single-line replacements keep the original quoting style; multi-line replacements use `|-` (literal block, no trailing newline) |
| **TOML** | Multi-line text uses `"""` basic strings (escaping `"""`); single-line uses basic strings with escapes; literal strings (`'`) are upgraded when escapes are needed |
| **.lua files** | Full file overwrite — no span-splice required |

---

## Conflict detection

If the source file was modified on disk between the time MoonSwift loaded it and
the time you press `:w`, MoonSwift detects the mismatch and shows a prompt:

```
File changed externally. [r]eload / [o]verwrite / [d]iff / [c]ancel
```

Choose an action:

| Key | Action |
|-----|--------|
| `r` | Discard the edit. Reload the source from disk; the nvim pane closes. |
| `o` | Overwrite. Re-read the current file, re-locate the span, and write your edited text into the up-to-date bytes. |
| `d` | Open a side-by-side diff showing the on-disk version alongside your edit. You can then decide. |
| `c` | Cancel. Return to the nvim buffer unchanged; the on-disk file is untouched. |

---

## Syntax error loop (`$EDITOR` path)

When using `$EDITOR`, if your edit contains a Lua syntax error the editor
re-opens with a comment block at the top describing the error:

```lua
-- SYNTAX ERROR: unexpected symbol near 'end' (line 3)
-- Fix the error above, then save to continue. Delete this block to force-accept.
```

Fix the error and save, or delete the two-line comment block entirely and save
to force-accept the text as-is. The loop repeats until the syntax is clean or
the comment block is absent.

---

## `$EDITOR` fallback behaviour

When Neovim is not available:

- MoonSwift shows a one-time transient (once per session):
  *nvim not found. Using $EDITOR for editing.*
- For whole `.lua` files: your `$EDITOR` opens the file directly.
- For structured-file fragments (JSON/YAML/TOML fields): the Lua fragment is
  written to a temporary file; your editor opens the temporary file; on exit the
  content is spliced back into the host file using the same write-back contract.
- Temporary files use a UUID-based name and 0600 permissions; they are removed
  automatically after the edit session completes (on all exit paths, including
  errors).

If `$EDITOR` is not set when the fallback activates, pressing `<C-e>` shows
the transient:

```
$EDITOR is not set. Set it to open the project file.
```

No editor opens and no file is modified. Set the `EDITOR` environment variable
to an absolute path before launching MoonSwift.

---

## Sizing notes

The embedded Neovim grid is sized to match the code pane. When the terminal is
resized while a Neovim session is active, MoonSwift sends a resize notification
to Neovim so the buffer reflows to match.
