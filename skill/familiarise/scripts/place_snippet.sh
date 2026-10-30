#!/usr/bin/env bash
# place_snippet.sh — put the familiarise block in a constitution file, above the shared-memory block.
#
#   place_snippet.sh [--dry-run] <constitution-file>
#
# Copies the block between the familiarise markers from CONSTITUTION_SNIPPET.md, verbatim.
# If the file already has a familiarise block, that block is replaced (never duplicated).
# The block goes directly above the shared-memory block. If there is none, it goes at the top.
# --dry-run prints the resulting file to stdout and writes nothing.
set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET="$SKILL_ROOT/CONSTITUTION_SNIPPET.md"
START='<!-- familiarise:constitution-snippet'  # prefix: matches any version
END='<!-- /familiarise:constitution-snippet -->'
SHARED='<!-- shared-memory:constitution-snippet'

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
TARGET="${1:?usage: place_snippet.sh [--dry-run] <constitution-file>}"
[ -f "$SNIPPET" ] || { echo "place_snippet: no snippet at $SNIPPET" >&2; exit 1; }

block="$(awk -v s="$START" -v e="$END" 'index($0,s)==1{p=1} p{print} index($0,e)==1{p=0}' "$SNIPPET")"
[ -n "$block" ] || { echo "place_snippet: markers not found in $SNIPPET" >&2; exit 1; }

current=""
[ -f "$TARGET" ] && current="$(cat "$TARGET")"

# Remove any existing familiarise block, so a re-run replaces it rather than duplicating it.
# The blank line that follows the block is removed with it, or every re-run would add one.
stripped="$(printf '%s\n' "$current" | awk -v s="$START" -v e="$END" '
    index($0,s)==1 { skip=1 }
    skip { if (index($0,e)==1) { skip=0; after=1 }; next }
    after && $0=="" { after=0; next }
    { after=0; print }')"

if printf '%s\n' "$stripped" | grep -qF -- "$SHARED"; then
    placed="above the shared-memory block"
    out="$(printf '%s\n' "$stripped" | awk -v b="$block" -v sh="$SHARED" '
        !done && index($0,sh)==1 { print b; print ""; done=1 }
        { print }')"
else
    placed="at the top (no shared-memory block found)"
    out="$block"$'\n\n'"$stripped"
fi

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "$out"
    echo "place_snippet: dry run, $TARGET not changed (would place block $placed)" >&2
    exit 0
fi

if [ "$(printf '%s\n' "$out")" = "$current" ]; then
    echo "place_snippet: $TARGET already up to date"
    exit 0
fi

printf '%s\n' "$out" > "$TARGET"
echo "place_snippet: block placed $placed in $TARGET"
