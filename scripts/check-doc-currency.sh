#!/usr/bin/env bash
# check-doc-currency.sh — Documentation-currency gate (First Principle 3).
#
# Fails when a change-set touches production code under Sources/ but none of the
# documentation artifacts listed in docs/DOC-CURRENCY.md changed — the gross
# "code changed, zero docs touched" case that signals documentation drift.
#
# Usage: scripts/check-doc-currency.sh [--base <ref>] [--head <ref>]
#   --base   base ref to diff against (default: origin/main, then main)
#   --head   head ref (default: HEAD)
#
# The compared range is `<merge-base of base..head> .. head`, so only the commits
# introduced on top of base are considered.
#
# Bypass: include the token `[skip doc-currency]` in any commit message in the
# range (for pure refactors / test-only / comment changes with no doc impact).
#
# Exit codes:
#   0  gate satisfied (no code change, OR code change with a doc change, OR bypass)
#   1  gate failed   (code changed under Sources/, no listed doc changed, no bypass)
#   2  usage / environment error (manifest missing, bad refs)

set -euo pipefail

MANIFEST="docs/DOC-CURRENCY.md"
BYPASS_TOKEN="[skip doc-currency]"
BASE_REF=""
HEAD_REF="HEAD"

# ── arguments ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
	case "$1" in
	--base)
		BASE_REF="${2:-}"
		shift 2
		;;
	--head)
		HEAD_REF="${2:-}"
		shift 2
		;;
	-h | --help)
		sed -n '2,20p' "$0"
		exit 0
		;;
	*)
		echo "check-doc-currency: unknown argument '$1'" >&2
		exit 2
		;;
	esac
done

if [[ ! -f "$MANIFEST" ]]; then
	echo "check-doc-currency: manifest not found at $MANIFEST" >&2
	exit 2
fi

# ── resolve the base ref ─────────────────────────────────────────────────────
# Default search order mirrors the repo's branching: origin/main, then main.
if [[ -z "$BASE_REF" ]]; then
	for candidate in origin/main main; do
		if git rev-parse --verify --quiet "$candidate" >/dev/null; then
			BASE_REF="$candidate"
			break
		fi
	done
fi
if [[ -z "$BASE_REF" ]]; then
	echo "check-doc-currency: could not resolve a base ref (tried origin/main, main); pass --base" >&2
	exit 2
fi

if ! MERGE_BASE="$(git merge-base "$BASE_REF" "$HEAD_REF" 2>/dev/null)"; then
	echo "check-doc-currency: git merge-base $BASE_REF $HEAD_REF failed" >&2
	exit 2
fi

# ── changed files in the range ───────────────────────────────────────────────
CHANGED="$(git diff --name-only "$MERGE_BASE" "$HEAD_REF")"
if [[ -z "$CHANGED" ]]; then
	echo "check-doc-currency: no changes in range ($BASE_REF..$HEAD_REF) — gate satisfied."
	exit 0
fi

# Production code = anything under Sources/ (Swift overlays, executable, FFI shim)
# plus the Rust shim sources. Tests, docs, scripts, CI, and manifests are excluded.
CODE_CHANGED="$(echo "$CHANGED" | grep -E '^(Sources/|rust/.+/src/)' || true)"
if [[ -z "$CODE_CHANGED" ]]; then
	echo "check-doc-currency: no production-code changes under Sources/ — gate satisfied."
	exit 0
fi

# ── bypass token ─────────────────────────────────────────────────────────────
RANGE_MSGS="$(git log --format='%B' "$MERGE_BASE..$HEAD_REF" 2>/dev/null || true)"
if echo "$RANGE_MSGS" | grep -qF "$BYPASS_TOKEN"; then
	echo "check-doc-currency: '$BYPASS_TOKEN' present in a commit message — gate bypassed."
	exit 0
fi

# ── parse the manifest ───────────────────────────────────────────────────────
# Only `- <path>` bullets under the "## Artifacts" section are read; the path is
# the first whitespace-delimited token after the bullet. Sub-headings and
# ordering are ignored.
MANIFEST_PATHS="$(
	awk '
    /^## Artifacts/    { insection = 1; next }
    /^## /             { insection = 0 }
    insection && /^- / { print $2 }
  ' "$MANIFEST"
)"

if [[ -z "$MANIFEST_PATHS" ]]; then
	echo "check-doc-currency: no artifact paths parsed from $MANIFEST (## Artifacts section empty?)" >&2
	exit 2
fi

# ── did any listed doc change? ───────────────────────────────────────────────
DOC_CHANGED=""
while IFS= read -r doc; do
	[[ -z "$doc" ]] && continue
	if echo "$CHANGED" | grep -qxF "$doc"; then
		DOC_CHANGED+="$doc"$'\n'
	fi
done <<<"$MANIFEST_PATHS"

if [[ -n "$DOC_CHANGED" ]]; then
	echo "check-doc-currency: production code changed and documentation was updated — gate satisfied."
	echo "  updated docs:"
	echo "$DOC_CHANGED" | sed '/^$/d; s/^/    /'
	exit 0
fi

# ── gate failure ─────────────────────────────────────────────────────────────
echo "check-doc-currency: FAIL — production code changed but no tracked documentation did." >&2
echo "  code changed under Sources/ (sample):" >&2
echo "$CODE_CHANGED" | head -10 | sed 's/^/    /' >&2
echo "" >&2
echo "  Update the relevant artifact in docs/DOC-CURRENCY.md in the same change-set," >&2
echo "  or, if this change genuinely has no documentation impact, add the token" >&2
echo "  '$BYPASS_TOKEN' to a commit message in the range." >&2
exit 1
