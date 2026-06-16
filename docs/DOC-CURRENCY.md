# Documentation-currency manifest

This file is the **tracked source of truth** for the documentation-currency gate
(First Principle 3 — documentation reflects the current state of the project,
updated in the same change-set as the work it describes). It lists every
documentation artifact that must stay in lock-step with the code.

`scripts/check-doc-currency.sh` parses the `- path` bullets under
**## Artifacts** below. The gate's rule: **if a change-set touches production
code under `Sources/` but none of the listed artifacts changed, the gate fails**
— surfacing likely documentation drift for review. A change with no documentation
impact (a pure refactor, a test-only change, a comment fix) can bypass the gate
by including the token `[skip doc-currency]` in any commit message in the range.

This is a heuristic, not a per-feature mapping: it cannot prove the *right* doc
was updated, only that *some* tracked doc moved when code did. The reviewer (and
the post-tag audit) remains the real check; the gate stops the gross case of
shipping code with zero documentation touched.

## Artifacts

User documentation (`docs/user/`):

- docs/user/mocking.md
- docs/user/debugging.md
- docs/user/completions.md
- docs/user/project-file.md
- docs/user/running.md

Internal documentation (`docs/internals/`):

- docs/internals/session-engine.md
- docs/internals/debugger.md
- docs/internals/luals.md
- docs/internals/catalog.md
- docs/internals/ux-spec.md

Project-level narrative:

- ARCHITECTURE.md
- CLAUDE.md
- README.md
- CHANGELOG.md

## Maintaining this manifest

When a new long-lived documentation artifact is added (a new `docs/user/*.md`,
`docs/internals/*.md`, or a top-level narrative file), add its path here in the
same change-set. Removing an artifact from the repo must remove its line here.
The gate reads only the `- <path>` bullets under **## Artifacts**; ordering and
the section sub-headings are for human readers and are ignored by the script.
