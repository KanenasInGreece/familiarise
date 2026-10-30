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

usage="usage: place_snippet.sh [--dry-run] <constitution-file>"
dry_run=0
if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
if [ "$#" -ne 1 ] || [ -z "$1" ] || [ "${1#-}" != "$1" ]; then echo "$usage" >&2; exit 2; fi
TARGET="$1"
[ -f "$SNIPPET" ] || { echo "place_snippet: no snippet at $SNIPPET" >&2; exit 1; }

block="$(awk -v s="$START" -v e="$END" 'index($0,s)==1{p=1} p{print} index($0,e)==1{p=0}' "$SNIPPET")"
[ -n "$block" ] || { echo "place_snippet: markers not found in $SNIPPET" >&2; exit 1; }

current=""
[ -f "$TARGET" ] && current="$(cat "$TARGET")"

# Remove any existing familiarise block, so a re-run replaces it rather than duplicating it.
# The blank line that follows the block is removed with it, or every re-run would add one.
# Lines are dropped only when a matching END is seen. A START with no END (end of file, or
# another START first) aborts with exit 3 and nothing is written. A lone END line is kept.
rc=0
stripped="$(awk -v s="$START" -v e="$END" '
    index($0,s)==1 {
        if (skip) { print "place_snippet: a second familiarise START before the END (line " NR ")" > "/dev/stderr"; exit 3 }
        skip=1; startline=NR; next }
    skip { if (index($0,e)==1) { skip=0; after=1 }; next }
    after && $0=="" { after=0; next }
    { after=0; print }
    END { if (skip) { print "place_snippet: familiarise START at line " startline " has no END" > "/dev/stderr"; exit 3 } }' <<< "$current")" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "place_snippet: $TARGET not changed (unterminated or nested familiarise block; fix it by hand)" >&2
    exit 3
fi

# One test places the block: the first line that is the shared-memory marker, optionally indented.
# Not found (awk exit 4) falls back to the top, never to silent loss.
placed="above the shared-memory block"
rc=0
out="$(BLOCK="$block" awk -v sh="$SHARED" '
    function is_shared(l,   i) { i=index(l,sh); return i>0 && substr(l,1,i-1) ~ /^[ \t]*$/ }
    !done && is_shared($0) { print ENVIRON["BLOCK"]; print ""; done=1 }
    { print }
    END { if (!done) exit 4 }' <<< "$stripped")" || rc=$?
if [ "$rc" -eq 4 ]; then
    placed="at the top (no shared-memory block found)"
    out="$block"$'\n\n'"$stripped"
elif [ "$rc" -ne 0 ]; then
    echo "place_snippet: insertion failed (awk exit $rc), $TARGET not changed" >&2
    exit 1
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
