#!/usr/bin/env bash
# End-to-end test of the fingerprint index in familiarise.sh. Runs the real script against a scratch
# install, a scratch state dir and tests/fake_gateway.py on a spare port. Never touches ~/.claude,
# ~/.gemini, ~/.config/shared-memory or port 8888.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)"; GW=""
cleanup() { [ -n "$GW" ] && kill "$GW" 2>/dev/null; chmod -R u+rwX "$S" 2>/dev/null; rm -rf -- "$S"; }
trap cleanup EXIT
FAIL=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

PORT=18931
python3 "$REPO/tests/fake_gateway.py" "$PORT" & GW=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 "http://localhost:$PORT/health" >/dev/null && break; sleep 0.3; done

INST="$S/inst"; SM="$S/sm"; FW="$INST/frameworks"; ST="$S/state"
mkdir -p "$INST" "$SM/scripts" "$ST"
cp -r "$REPO/skill/familiarise/." "$INST/"
[ -n "${OLD_SCRIPT:-}" ] && cp "$OLD_SCRIPT" "$INST/scripts/familiarise.sh"   # run the cases against another script
touch "$SM/scripts/memory_bridge.py"
# PATH shims: log every argument list, then exec the real tool.
SH="$S/shims"; CALLS="$S/calls.log"; mkdir -p "$SH"; : > "$CALLS"
for t in cmp sha256sum grep awk sed cat cp head tail stat; do
    real="$(command -v "$t")"
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexec "%s" "$@"\n' "$t" "$CALLS" "$real" > "$SH/$t"; chmod +x "$SH/$t"
done
printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=%s\n' "$SM" "$FW" > "$S/config.env"
mkdir -p "$FW"; chmod 700 "$FW"
for h in alpha beta gamma; do
    printf 'AGENT_ID=agent-%s\nTOKEN=sekret-token-%s-value\n' "$h" "$h" > "$FW/.env-$h"; chmod 600 "$FW/.env-$h"
done
export FAMILIARISE_ENV="$S/config.env" FRAMEWORK_TUNNEL_STATE_DIR="$ST" FRAMEWORK_TUNNEL_LOCAL_PORT="$PORT"
run() { printf 'HOST=%s\nMAIN_PID=%s\n' "$1" "$$" > "$ST/active-framework"
        PATH="$SH:$PATH" bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; }
reset() { rm -f "$SM/.env" "$FW/.index" "$FW"/.env-unsaved-*; rm -rf "$FW/.index"
          for h in alpha beta gamma; do printf 'AGENT_ID=agent-%s\nTOKEN=sekret-token-%s-value\n' "$h" "$h" > "$FW/.env-$h"; chmod 600 "$FW/.env-$h"; done; }
unsaved() { find "$FW" -maxdepth 1 -name '.env-unsaved-*' | wc -l; }
mode() { stat -c %a "$1"; }

# a. first connect
run alpha; rc=$?
[ "$rc" = 0 ] && cmp -s "$SM/.env" "$FW/.env-alpha" \
  && [ "$(awk '{print $1"  "$2}' "$FW/.index")" = "$(sha256sum < "$FW/.env-alpha" | cut -d' ' -f1)  .env-alpha" ] \
  && grep -qE '^[0-9a-f]{64}  \.env-alpha$' "$FW/.index" \
  && [ "$(mode "$FW/.index")" = 600 ] && [ "$(mode "$FW")" = 700 ] \
  && ! grep -q 'sekret' "$FW/.index" && ! grep -q 'sekret' "$S/out" && [ "$(unsaved)" = 0 ]
check "a: first connect copies, writes .index (hash only, mode 600)" $?

# b. switch to a second framework: no backup
run beta; rc=$?
[ "$rc" = 0 ] && cmp -s "$SM/.env" "$FW/.env-beta" && [ "$(unsaved)" = 0 ] \
  && [ "$(wc -l < "$FW/.index")" = 2 ] && grep -q '  \.env-alpha$' "$FW/.index" && grep -q '  \.env-beta$' "$FW/.index"
check "b: switch to beta, current .env is in the index, no .env-unsaved" $?

# c. foreign .env matching nothing in the index
printf 'AGENT_ID=foreign\nTOKEN=foreign-token\n' > "$SM/.env"; cp "$SM/.env" "$S/foreign.copy"
run alpha; rc=$?
b="$(find "$FW" -maxdepth 1 -name '.env-unsaved-*' | head -1)"
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && [ -n "$b" ] && cmp -s "$b" "$S/foreign.copy" && [ "$(mode "$b")" = 600 ] \
  && cmp -s "$SM/.env" "$FW/.env-alpha"
check "c: foreign .env is backed up (identical, mode 600)" $?

# c2. token that predates the index (no index at all) is also backed up
rm -f "$FW/.index" "$FW"/.env-unsaved-*
cp "$FW/.env-beta" "$SM/.env"
run alpha; rc=$?
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && cmp -s "$(find "$FW" -maxdepth 1 -name '.env-unsaved-*')" "$FW/.env-beta"
check "c2: no index: differing .env is backed up, index recreated" $?
rm -f "$FW"/.env-unsaved-*

# d. an unrelated token file is never opened (observed through PATH shims, not inferred from success)
reset; run alpha
# .env-aaa sorts before .env-alpha, so the old glob scan would reach it first
printf 'AGENT_ID=agent-aaa\nTOKEN=sekret-token-aaa-value\n' > "$FW/.env-aaa"; chmod 000 "$FW/.env-aaa"; : > "$CALLS"
run beta; rc=$?
chmod 600 "$FW/.env-aaa"
[ "$rc" = 0 ] && cmp -s "$SM/.env" "$FW/.env-beta" && [ "$(unsaved)" = 0 ] \
  && [ -s "$CALLS" ] && ! grep -q 'env-aaa' "$CALLS" && ! grep -q 'env-aaa' "$S/out"; r=$?; rm -f "$FW/.env-aaa"; (exit $r)
check "d: unrelated token file never named in any tool call (and connect succeeds)" $?

# e. no temp files left, index mode 600
left="$(find "$FW" -maxdepth 1 -name '.index.tmp.*' | wc -l)"
[ "$left" = 0 ] && [ "$(mode "$FW/.index")" = 600 ]
check "e: no leftover index temp files" $?

# g. stale entry: indexed token file deleted, token lives only in .env
reset; run alpha; cp "$SM/.env" "$S/old.copy"; rm -f "$FW/.env-alpha"
run beta; rc=$?
b="$(find "$FW" -maxdepth 1 -name '.env-unsaved-*' | head -1)"
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && [ -n "$b" ] && cmp -s "$b" "$S/old.copy" && cmp -s "$SM/.env" "$FW/.env-beta"
check "g: deleted .env-alpha: old token is backed up" $?

# g2. rotation: .env-alpha rewritten with different bytes after indexing
reset; run alpha; cp "$SM/.env" "$S/old.copy"
printf 'AGENT_ID=agent-alpha\nTOKEN=rotated-longer-token-value-xxxxxxxx\n' > "$FW/.env-alpha"
run beta; rc=$?
b="$(find "$FW" -maxdepth 1 -name '.env-unsaved-*' | head -1)"
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && [ -n "$b" ] && cmp -s "$b" "$S/old.copy"
check "g2: rotated .env-alpha (size changed): old token is backed up" $?

# g3. same-size rewrite, different bytes: caught by the hash
reset; run alpha; cp "$SM/.env" "$S/old.copy"
sleep 0.05; printf 'AGENT_ID=agent-alpha\nTOKEN=sekret-token-ALPHA-value\n' > "$FW/.env-alpha"
run beta; rc=$?
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && cmp -s "$(find "$FW" -maxdepth 1 -name '.env-unsaved-*')" "$S/old.copy"
check "g3: same-size rewrite (different bytes): old token is backed up" $?

# g4. different bytes, mtime restored with touch -r: still backed up (mtime is not used)
reset; run alpha; cp "$SM/.env" "$S/old.copy"
cp -p "$FW/.env-alpha" "$S/mtime.ref"
printf 'AGENT_ID=agent-alpha\nTOKEN=sekret-token-ALPHA-value\n' > "$FW/.env-alpha"; touch -r "$S/mtime.ref" "$FW/.env-alpha"
[ "$(stat -c %Y.%y "$FW/.env-alpha")" = "$(stat -c %Y.%y "$S/mtime.ref")" ] && [ "$(stat -c %s "$FW/.env-alpha")" = "$(stat -c %s "$S/old.copy")" ]
mt=$?
run beta; rc=$?
[ "$mt" = 0 ] && [ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && cmp -s "$(find "$FW" -maxdepth 1 -name '.env-unsaved-*')" "$S/old.copy"
check "g4: different bytes, same size and restored mtime (touch -r): old token is backed up" $?

# h. symlinked .index is not followed and is replaced by a regular file
reset; ln -s .env-beta "$FW/.index"
run alpha; rc=$?
[ "$rc" = 0 ] && [ -f "$FW/.index" ] && [ ! -L "$FW/.index" ] && ! grep -q 'sekret' "$FW/.index" \
  && [ "$(wc -l < "$FW/.index")" = 1 ] && [ "$(mode "$FW/.env-beta")" = 600 ] && grep -q 'TOKEN=sekret-token-beta-value' "$FW/.env-beta"
check "h: symlinked .index becomes a regular file with no token text" $?

# i. backslash in the .env path: hash is parsed correctly, a matching switch does not back up
reset; SM_SAVE="$SM"; SM="$S/s\\m"; mkdir -p "$SM/scripts"; touch "$SM/scripts/memory_bridge.py"
printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=%s\n' "$SM" "$FW" > "$S/config.env"
run alpha; run beta; rc=$?
[ "$rc" = 0 ] && [ "$(unsaved)" = 0 ] && cmp -s "$SM/.env" "$FW/.env-beta"
check "i: backslash in SHARED_MEMORY_SKILL_DIR: indexed switch makes no backup" $?
SM="$SM_SAVE"; printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=%s\n' "$SM" "$FW" > "$S/config.env"

# j1. DEST is a symlink to .env-alpha: refuse, token untouched
reset; cp "$FW/.env-alpha" "$S/alpha.copy"; ln -s "$FW/.env-alpha" "$SM/.env"
run beta; rc=$?
[ "$rc" = 1 ] && grep -q 'is a symlink' "$S/out" && cmp -s "$FW/.env-alpha" "$S/alpha.copy" && [ -L "$SM/.env" ] && [ "$(unsaved)" = 0 ]
check "j1: DEST symlink to .env-alpha: exit 1, .env-alpha unchanged, nothing copied" $?
rm -f "$SM/.env"

# j2. DEST is a hard link of .env-alpha (indexed): back up first, .env-alpha keeps its bytes
reset; run alpha; rm -f "$SM/.env"; ln "$FW/.env-alpha" "$SM/.env"
run beta; rc=$?
b="$(find "$FW" -maxdepth 1 -name '.env-unsaved-*' | head -1)"
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && [ -n "$b" ] && cmp -s "$b" "$S/alpha.copy" && cmp -s "$FW/.env-alpha" "$S/alpha.copy" \
  && cmp -s "$SM/.env" "$FW/.env-beta" && [ ! "$SM/.env" -ef "$FW/.env-alpha" ]
check "j2: DEST hard link of .env-alpha: backed up first, .env-alpha keeps its bytes" $?

# j3. normal switch: DEST is a regular file with the new bytes, no temp files
reset; run alpha; run beta; rc=$?
[ "$rc" = 0 ] && [ -f "$SM/.env" ] && [ ! -L "$SM/.env" ] && cmp -s "$SM/.env" "$FW/.env-beta" && [ "$(mode "$SM/.env")" = 600 ] \
  && [ "$(find "$SM" -maxdepth 1 -name '.env.tmp.*' | wc -l)" = 0 ]
check "j3: switch leaves a regular 600 .env with the new bytes and no temp files" $?

# f. existing tests
for t in "$REPO"/tests/test_*.sh; do
    [ "$(basename "$t")" = test_token_index.sh ] && continue
    echo "--- $(basename "$t")"; bash "$t"; check "f: $(basename "$t") passes" $?
done

[ "$FAIL" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
