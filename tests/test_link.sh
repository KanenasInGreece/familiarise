#!/usr/bin/env bash
# End-to-end test of the symlink design in familiarise.sh. Runs the real script against scratch dirs, a
# scratch state dir and tests/fake_gateway.py on a spare port. Never touches ~/.claude, ~/.gemini,
# ~/.config/shared-memory or port 8888.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)"; GW=""
cleanup() { [ -n "$GW" ] && kill "$GW" 2>/dev/null; chmod -R u+rwX "$S" 2>/dev/null; rm -rf -- "$S"; }
trap cleanup EXIT
FAIL=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

PORT=18932
python3 "$REPO/tests/fake_gateway.py" "$PORT" & GW=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 "http://localhost:$PORT/health" >/dev/null && break; sleep 0.3; done

INST="$S/inst"; SM="$S/sm"; FW="$S/fw"; ST="$S/state"; D="$SM/.env"
mkdir -p "$INST" "$SM/scripts" "$ST" "$FW"; chmod 700 "$FW"
cp -r "$REPO/skill/familiarise/." "$INST/"
touch "$SM/scripts/memory_bridge.py"
printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=%s\n' "$SM" "$FW" > "$S/config.env"
printf 'alpha-bytes\n' > "$FW/.env-alpha"; printf 'beta-bytes\n' > "$FW/.env-beta"; chmod 600 "$FW"/.env-*
export FAMILIARISE_ENV="$S/config.env" FRAMEWORK_TUNNEL_STATE_DIR="$ST" FRAMEWORK_TUNNEL_LOCAL_PORT="$PORT"
run() { printf 'HOST=%s\nMAIN_PID=%s\n' "$1" "$$" > "$ST/active-framework"
        bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; }
unsaved() { find "$FW" -maxdepth 1 -name '.env-unsaved-*' | wc -l; }

# a
run alpha; rc=$?
[ "$rc" = 0 ] && [ -L "$D" ] && [ "$(readlink "$D")" = "$FW/.env-alpha" ]; check "a: connect alpha on empty DEST links to .env-alpha" $?

# b
ino="$(stat -c %i "$D")"
run alpha; rc=$?
[ "$rc" = 0 ] && grep -q 'already linked to alpha' "$S/out" && [ "$(stat -c %i "$D")" = "$ino" ] && [ "$(readlink "$D")" = "$FW/.env-alpha" ]
check "b: second connect says already linked, link unchanged" $?

# c
run beta; rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$D")" = "$FW/.env-beta" ] && [ "$(cat "$D")" = "beta-bytes" ] && [ "$(cat "$FW/.env-alpha")" = "alpha-bytes" ] && [ "$(unsaved)" = 0 ]
check "c: switch to beta repoints the link, alpha untouched, no backup" $?

# d
printf 'rotated-beta-token-longer\n' > "$FW/.env-beta"
[ "$(cat "$D")" = "rotated-beta-token-longer" ]; check "d: rotation seen through the link without re-run" $?

# e
rm -f "$D"; printf 'foreign-unsaved\n' > "$D"; fino="$(stat -c %i "$D")"
run beta; rc=$?
b="$(find "$FW" -maxdepth 1 -name '.env-unsaved-*' | head -1)"
[ "$rc" = 0 ] && [ "$(unsaved)" = 1 ] && [ "$(cat "$b")" = "foreign-unsaved" ] && [ "$(stat -c %a "$b")" = 600 ] \
  && [ "$(stat -c %i "$b")" = "$fino" ] && [ -L "$D" ] && [ "$(readlink "$D")" = "$FW/.env-beta" ]
check "e: foreign regular DEST is moved (same inode) to .env-unsaved, mode 600, then linked" $?
rm -f "$FW"/.env-unsaved-*

# f
before="$(readlink "$D")"
run gamma; rc=$?
[ "$rc" = 2 ] && [ "$(readlink "$D")" = "$before" ]; check "f: missing target exits 2, DEST unchanged" $?

# g
ln -s .env-beta "$FW/.env-delta"
run delta; rc=$?
[ "$rc" = 1 ] && [ "$(readlink "$D")" = "$before" ]; check "g: symlinked target exits 1, DEST unchanged" $?

# h  (uses FAMILIARISE_NOW, an override for the backup name only)
rm -f "$D"; printf 'foreign-h\n' > "$D"; : > "$FW/.env-unsaved-T1"
printf 'HOST=alpha\nMAIN_PID=%s\n' "$$" > "$ST/active-framework"
FAMILIARISE_NOW=T1 bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -L "$D" ] && [ "$(cat "$D")" = "foreign-h" ] && [ ! -s "$FW/.env-unsaved-T1" ]
check "h: existing backup path exits 1, DEST unchanged (via FAMILIARISE_NOW)" $?
rm -f "$FW"/.env-unsaved-* "$D"; ln -s "$FW/.env-beta" "$D"

# i
before="$(readlink "$D")"; chmod 500 "$SM"
if [ -w "$SM" ]; then echo "SKIP: i: directory still writable (running as root?)"; else
  run alpha; rc=$?
  chmod 700 "$SM"
  [ "$rc" = 1 ] && [ "$(readlink "$D")" = "$before" ]; check "i: unwritable skill dir exits 1, DEST unchanged" $?
fi
chmod 700 "$SM"

# j
SH="$S/shimj"; mkdir -p "$SH"
printf '#!/bin/sh\nkill -TERM $PPID\nexit 1\n' > "$SH/mv"; chmod +x "$SH/mv"
printf 'HOST=alpha\nMAIN_PID=%s\n' "$$" > "$ST/active-framework"
PATH="$SH:$PATH" bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; rc=$?
[ "$rc" != 0 ] && [ -z "$(find "$SM" -maxdepth 1 -name '.env.link.*')" ] && [ "$(readlink "$D")" = "$before" ]
check "j: TERM after temp link leaves no .env.link.* (rc=$rc)" $?

# k
SH="$S/shimk"; CALLS="$S/calls.log"; mkdir -p "$SH"; : > "$CALLS"
for t in cmp sha256sum grep awk sed cat head tail cp stat; do
    real="$(command -v "$t")"
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexec "%s" "$@"\n' "$t" "$CALLS" "$real" > "$SH/$t"; chmod +x "$SH/$t"
done
rm -f "$D"; ln -s "$FW/.env-alpha" "$D"
printf 'HOST=beta\nMAIN_PID=%s\n' "$$" > "$ST/active-framework"
PATH="$SH:$PATH" bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$D")" = "$FW/.env-beta" ] && [ -s "$CALLS" ] \
  && ! grep -qF -e "$FW" -e "$SM" -e '.env-' "$CALLS" 2>/dev/null
r=$?
# the config file may be read by grep; no call may name a token file, the link, or the framework dir
if [ "$r" = 0 ]; then ok "k: no cat/cmp/sha256sum/grep/cp/... call names a token file ($(wc -l < "$CALLS") shimmed calls)"
else bad "k: shimmed tool touched a token path"; cat "$CALLS"; fi

# l: M1 backup path appears just before the real mv: earlier backup bytes kept, DEST unchanged
rm -f "$D" "$FW"/.env-unsaved-*; printf 'foreign-l\n' > "$D"
SH="$S/shiml"; mkdir -p "$SH"; REALMV="$(command -v mv)"
printf '#!/bin/sh\nfor a; do l=$a; done\nprintf earlier-backup > "$l"\nexec "%s" "$@"\n' "$REALMV" > "$SH/mv"; chmod +x "$SH/mv"
printf 'HOST=alpha\nMAIN_PID=%s\n' "$$" > "$ST/active-framework"
FAMILIARISE_NOW=T2 PATH="$SH:$PATH" bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$FW/.env-unsaved-T2")" = "earlier-backup" ] && [ -f "$D" ] && [ ! -L "$D" ] && [ "$(cat "$D")" = "foreign-l" ] \
  && grep -q 'appeared during the run' "$S/out"
check "l: backup path appearing before mv is not overwritten, DEST unchanged" $?
rm -f "$FW"/.env-unsaved-* "$D"; ln -s "$FW/.env-beta" "$D"

# m: lock held elsewhere
( exec 8>"$FW/.lock"; flock 8; sleep 5 ) & LP=$!
sleep 0.5
before="$(readlink "$D")"; run alpha; rc=$?
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
[ "$rc" = 1 ] && grep -q 'another familiarise is running' "$S/out" && [ "$(readlink "$D")" = "$before" ]
check "m: busy lock exits 1, DEST unchanged" $?

# n: relative FRAMEWORK_ENV_DIR
printf 'SHARED_MEMORY_SKILL_DIR=%s\nFRAMEWORK_ENV_DIR=relfw\n' "$SM" > "$S/config-rel.env"
printf 'HOST=alpha\nMAIN_PID=%s\n' "$$" > "$ST/active-framework"
FAMILIARISE_ENV="$S/config-rel.env" bash "$INST/scripts/familiarise.sh" >"$S/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'absolute' "$S/out" && [ "$(readlink "$D")" = "$before" ]
check "n: relative FRAMEWORK_ENV_DIR exits 1, nothing changed" $?

# o: directory target exits 2
mkdir "$FW/.env-dirhost"; run dirhost; rc=$?
[ "$rc" = 2 ] && [ "$(readlink "$D")" = "$before" ]; check "o: directory target exits 2, DEST unchanged" $?

[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"
