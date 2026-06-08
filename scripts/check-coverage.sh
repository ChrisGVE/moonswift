#!/usr/bin/env bash
# check-coverage.sh — Verify MoonSwiftCore line coverage meets the ≥85% gate.
#
# Usage: scripts/check-coverage.sh [--threshold N]
#
# Expects `swift test --filter MoonSwiftCoreTests --enable-code-coverage` to
# have already been run (or the coverage artifacts to be present in .build/).
# Locates the .profdata and the MoonSwiftPackageTests.xctest binary produced by
# SwiftPM, then uses `xcrun llvm-cov export` to extract per-file coverage for
# every file under Sources/MoonSwiftCore/, aggregates to a single line-coverage
# percentage, and exits non-zero if it falls below the threshold.
#
# Environment / assumptions:
#   • SwiftPM writes profdata to .build/<config>/codecov/default.profdata
#   • The test executable is .build/<config>/MoonSwiftPackageTests.xctest/
#     Contents/MacOS/MoonSwiftPackageTests  (macOS bundle layout on GitHub runners)
#   • xcrun (Xcode) is available on PATH
#   • jq is available on PATH (standard on macOS; installed in CI via brew or
#     pre-installed by the runner image)
#
# Exit codes:
#   0  coverage ≥ threshold
#   1  coverage < threshold (gate fail)
#   2  usage / environment error (missing artifacts)

set -euo pipefail

# ── arguments ────────────────────────────────────────────────────────────────
THRESHOLD=85
while [[ $# -gt 0 ]]; do
	case "$1" in
	--threshold)
		THRESHOLD="$2"
		shift 2
		;;
	--threshold=*)
		THRESHOLD="${1#*=}"
		shift
		;;
	*)
		echo "Unknown argument: $1" >&2
		exit 2
		;;
	esac
done

# ── locate build artifacts ────────────────────────────────────────────────────
# SwiftPM uses 'debug' by default; CI doesn't pass -c release, so we look
# for debug first, then release.
PROFDATA=""
TEST_BIN=""

for CONFIG in debug release; do
	CANDIDATE_PROF=".build/${CONFIG}/codecov/default.profdata"
	if [[ -f "$CANDIDATE_PROF" ]]; then
		PROFDATA="$CANDIDATE_PROF"
		# The test binary sits next to the bundle; bundle layout on macOS:
		#   .build/<cfg>/MoonSwiftPackageTests.xctest/Contents/MacOS/MoonSwiftPackageTests
		BUNDLE=$(find -L ".build/${CONFIG}" -maxdepth 2 \
			-name "MoonSwiftPackageTests.xctest" -type d 2>/dev/null | head -1)
		if [[ -n "$BUNDLE" ]]; then
			TEST_BIN="${BUNDLE}/Contents/MacOS/MoonSwiftPackageTests"
		fi
		break
	fi
done

if [[ -z "$PROFDATA" ]]; then
	echo "ERROR: No coverage data found." >&2
	echo "  Run: swift test --filter MoonSwiftCoreTests --enable-code-coverage" >&2
	exit 2
fi

if [[ -z "$TEST_BIN" || ! -x "$TEST_BIN" ]]; then
	echo "ERROR: MoonSwiftPackageTests executable not found in .build/." >&2
	echo "  Expected: .build/<config>/MoonSwiftPackageTests.xctest/Contents/MacOS/MoonSwiftPackageTests" >&2
	exit 2
fi

echo "Using profdata : $PROFDATA"
echo "Using test bin : $TEST_BIN"

# ── extract coverage ──────────────────────────────────────────────────────────
# llvm-cov export emits JSON with per-file hit/count arrays.
# We filter to only files under Sources/MoonSwiftCore/ (path contains the
# literal segment) and sum lines_covered / lines_valid across all matching files.
#
# jq expression:
#   .data[].files[]
#   | select(.filename contains("/Sources/MoonSwiftCore/"))
#   | [.summary.lines.count, .summary.lines.covered]
# Then sum both columns and compute percentage.

COVERAGE_JSON=$(xcrun llvm-cov export \
	--format=text \
	--instr-profile="$PROFDATA" \
	"$TEST_BIN" \
	--ignore-filename-regex="(/Tests/|/Vendor/|/vendor/)" \
	2>/dev/null)

if [[ -z "$COVERAGE_JSON" ]]; then
	echo "ERROR: llvm-cov export produced no output." >&2
	exit 2
fi

# Sum lines across all MoonSwiftCore source files.
TOTALS=$(printf '%s' "$COVERAGE_JSON" | jq -r '
  [
    .data[].files[]
    | select(.filename | contains("/Sources/MoonSwiftCore/"))
    | [.summary.lines.count, .summary.lines.covered]
  ]
  | if length == 0 then "0 0"
    else
      ( map(.[0]) | add ) as $total |
      ( map(.[1]) | add ) as $covered |
      "\($total) \($covered)"
    end
')

TOTAL_LINES=$(echo "$TOTALS" | awk '{print $1}')
COVERED_LINES=$(echo "$TOTALS" | awk '{print $2}')

if [[ "$TOTAL_LINES" -eq 0 ]]; then
	echo "ERROR: No MoonSwiftCore source files found in coverage data." >&2
	echo "  Verify --filter MoonSwiftCoreTests ran and the path filter is correct." >&2
	exit 2
fi

# Compute percentage with one decimal place.
PCT=$(awk "BEGIN { printf \"%.1f\", ($COVERED_LINES / $TOTAL_LINES) * 100 }")
PCT_INT=$(awk "BEGIN { printf \"%d\", ($COVERED_LINES / $TOTAL_LINES) * 100 }")

echo ""
echo "MoonSwiftCore line coverage: ${PCT}%  (${COVERED_LINES}/${TOTAL_LINES} lines)"
echo "Gate threshold             : ${THRESHOLD}%"

if [[ "$PCT_INT" -ge "$THRESHOLD" ]]; then
	echo "PASS: coverage ${PCT}% >= ${THRESHOLD}%"
	exit 0
else
	echo "FAIL: coverage ${PCT}% < ${THRESHOLD}% — gate not met" >&2
	exit 1
fi
