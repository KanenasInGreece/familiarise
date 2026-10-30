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
touch "$SM/scripts/memory_bridge.py"
printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=%s\n' "$SM" "$FW" > "$S/config.env"
mkdir -p "$FW"; chmod 700 "$FW"
for h in alpha beta gamma; do
    printf 'AGENT_ID=agent-%s\nTOKEN=sekret-token-%s-value\n' "$h" "$h" > "$FW/.env-$h"; chmod 600 "$FW/.env-$h"
done
export FAMILIARISE_ENV="$S/config.env" FRAMEWORK_TUNNEL_STATE_DIR="$ST" FRAMEWORK_TUNNEL_LOCAL_PORT="$PORT"
run() { printf 'HOST=%s\nMAIN_PID=%s\n' "$1" "$$" > "$ST/active-framework"
        bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; }
unsaved() { find "$FW" -maxdepth 1 -name '.env-unsaved-*' | wc -l; }
mode() { stat -c %a "$1"; }

# a. first connect
run alpha; rc=$?
[ "$rc" = 0 ] && cmp -s "$SM/.env" "$FW/.env-alpha" \
  && [ "$(cat "$FW/.index")" = "$(sha256sum "$FW/.env-alpha" | cut -d' ' -f1)  .env-alpha" ] \
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

# d. an unrelated token file is never opened
run alpha   # make sure DEST is alpha and indexed
chmod 000 "$FW/.env-gamma"
run beta; rc=$?
chmod 600 "$FW/.env-gamma"
[ "$rc" = 0 ] && cmp -s "$SM/.env" "$FW/.env-beta" && [ "$(unsaved)" = 0 ]
check "d: connect succeeds with an unreadable unrelated token file" $?

# e. no temp files left, index mode 600
left="$(find "$FW" -maxdepth 1 -name '.index.tmp.*' | wc -l)"
[ "$left" = 0 ] && [ "$(mode "$FW/.index")" = 600 ]
check "e: no leftover index temp files" $?

# f. existing tests
for t in "$REPO"/tests/test_*.sh; do
    [ "$(basename "$t")" = test_token_index.sh ] && continue
    echo "--- $(basename "$t")"; bash "$t"; check "f: $(basename "$t") passes" $?
done

[ "$FAIL" = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
