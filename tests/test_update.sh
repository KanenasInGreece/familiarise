#!/usr/bin/env bash
# End-to-end test of familiarise.sh --version / --update against a local bare repo in a scratch dir.
# Never touches ~/.claude, ~/.config/shared-memory or port 8888.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)"; trap 'rm -rf -- "$S"' EXIT
FAIL=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkrepo() { # name version tagversion(optional; empty = no tag)
    local w="$S/w-$1"; mkdir -p "$w/skill/familiarise/scripts"
    cp -r "$REPO/skill/familiarise/." "$w/skill/familiarise/"
    printf '%s\n' "$2" > "$w/skill/familiarise/VERSION"
    echo "new skill $2" > "$w/skill/familiarise/SKILL.md"
    ( cd "$w" && git init -q . && git add -A && git commit -q -m x \
        && { [ -z "$3" ] || git tag "v$3"; } ) || return 1
    git clone -q --bare "$w" "$S/$1.git"
}
mkinst() { # dir
    mkdir -p "$1"; cp -r "$REPO/skill/familiarise/." "$1/"; rm -f "$1/VERSION"
    echo "old skill" > "$1/SKILL.md"
    echo "TOKEN=secret" > "$1/.env"; mkdir -p "$1/frameworks"; echo "TOKEN=x" > "$1/frameworks/.env-x"
}
snap() { ( cd "$1" && find . -path ./.backup -prune -o -type f -print | sort | xargs sha256sum ); }

mkrepo good 0.2.0 0.2.0; mkrepo mism 0.9.0 0.3.0; mkrepo notag 0.2.0 ""

# a. --version from repo copy
out="$(bash "$REPO/skill/familiarise/scripts/familiarise.sh" --version)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "familiarise 0.2.0" ]; check "a: --version" $?

# b. update 0.1.0 -> 0.2.0
I="$S/inst"; mkinst "$I"
envb="$(sha256sum "$I/.env" "$I/frameworks/.env-x")"
out="$(FAMILIARISE_REPO="$S/good.git" bash "$I/scripts/familiarise.sh" --update 2>&1)"; rc=$?
echo "$out"
bk="$(ls -d "$I"/.backup/0.1.0-* 2>/dev/null | head -1)"
[ "$rc" = 0 ] && [ "$(cat "$I/VERSION")" = "0.2.0" ] && [ "$(cat "$I/SKILL.md")" = "new skill 0.2.0" ] \
  && [ -n "$bk" ] && [ "$(cat "$bk/SKILL.md")" = "old skill" ] && [ -f "$bk/scripts/familiarise.sh" ] \
  && [ "$envb" = "$(sha256sum "$I/.env" "$I/frameworks/.env-x")" ] \
  && ! ls "$I"/scripts/.familiarise-new.* >/dev/null 2>&1
check "b: update installs, backs up, leaves .env and frameworks" $?

# c. second update
out="$(FAMILIARISE_REPO="$S/good.git" bash "$I/scripts/familiarise.sh" --update 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "up to date"; check "c: second update is up to date" $?

# d. VERSION mismatch
J="$S/inst-d"; mkinst "$J"; before="$(snap "$J")"
FAMILIARISE_REPO="$S/mism.git" bash "$J/scripts/familiarise.sh" --update >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$before" = "$(snap "$J")" ]; check "d: VERSION mismatch exits 1, nothing changed" $?

# e. no tags
K="$S/inst-e"; mkinst "$K"; before="$(snap "$K")"
FAMILIARISE_REPO="$S/notag.git" bash "$K/scripts/familiarise.sh" --update >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$before" = "$(snap "$K")" ]; check "e: no tags exits 1, nothing changed" $?

# f. missing remote
FAMILIARISE_REPO="$S/nonexistent.git" bash "$K/scripts/familiarise.sh" --update >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$before" = "$(snap "$K")" ]; check "f: missing remote exits 1" $?

# g. unknown argument
bash "$K/scripts/familiarise.sh" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ]; check "g: unknown argument exits 1" $?

# helper: extra bare repo built by a callback
mkrepo2() { # name version tag ; then runs $4 (a function) in the work tree before commit
    local w="$S/w-$1"; mkdir -p "$w/skill/familiarise/scripts"
    cp -r "$REPO/skill/familiarise/." "$w/skill/familiarise/"
    printf '%s\n' "$2" > "$w/skill/familiarise/VERSION"
    echo "new skill $2" > "$w/skill/familiarise/SKILL.md"
    [ -z "${4:-}" ] || ( cd "$w/skill/familiarise" && "$4" )
    ( cd "$w" && git init -q . && git add -A && git commit -q -m x && git tag "v$3" ) || return 1
    git clone -q --bare "$w" "$S/$1.git"
}
mkinst2() { mkinst "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" > "$1/VERSION"; }
upd() { FAMILIARISE_REPO="$S/$1.git" bash "$2/scripts/familiarise.sh" --update 2>&1; }

# h. install failure rolls back, VERSION stays old, rerun can update
mkrepo good2 0.2.0 0.2.0
H="$S/inst-h"; mkinst2 "$H" 0.1.0
mv "$H/scripts/place_snippet.sh" "$S/ps.bak"; mkdir "$H/scripts/place_snippet.sh"
before="$(snap "$H")"
out="$(upd good2 "$H")"; rc=$?; echo "$out"
[ "$rc" = 1 ] && [ "$(cat "$H/VERSION")" = "0.1.0" ] && [ "$(cat "$H/SKILL.md")" = "old skill" ] \
  && [ "$before" = "$(snap "$H")" ] && ! ls "$H"/scripts/.familiarise-new.* >/dev/null 2>&1
check "h: install failure rolls back, VERSION unchanged" $?
rmdir "$H/scripts/place_snippet.sh"; mv "$S/ps.bak" "$H/scripts/place_snippet.sh"
sleep 1  # backup dir name has 1 s resolution
upd good2 "$H" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$H/VERSION")" = "0.2.0" ] && [ "$(cat "$H/SKILL.md")" = "new skill 0.2.0" ]
check "h2: rerun after failure updates" $?

# i. symlink as SKILL.md in the tag
linkit() { ln -sf "$S/inst-i/.env" SKILL.md; }
I2="$S/inst-i"; mkinst2 "$I2" 0.1.0
mkrepo2 sym 0.2.0 0.2.0 linkit
before="$(snap "$I2")"
out="$(upd sym "$I2")"; rc=$?; echo "$out"
[ "$rc" = 1 ] && [ "$before" = "$(snap "$I2")" ] && ! grep -q "secret" "$I2/SKILL.md" && [ ! -L "$I2/SKILL.md" ]
check "i: symlink in tag rejected, nothing changed, no secret" $?

# j. malformed local VERSION
for bad in v0.2.0 abc 0.2.0-rc1; do
    Jm="$S/inst-j"; rm -rf "$Jm"; mkinst2 "$Jm" "$bad"; before="$(snap "$Jm")"
    out="$(upd good2 "$Jm")"; rc=$?
    [ "$rc" = 1 ] && echo "$out" | grep -q "not X.Y.Z" && [ "$before" = "$(snap "$Jm")" ]
    check "j: malformed local VERSION '$bad' exits 1, nothing changed" $?
done

# k. branch vX named like the tag must not win
brn() { :; }
w="$S/w-br"; mkdir -p "$w/skill/familiarise/scripts"
cp -r "$REPO/skill/familiarise/." "$w/skill/familiarise/"
printf '0.3.0\n' > "$w/skill/familiarise/VERSION"; echo "TAG content" > "$w/skill/familiarise/SKILL.md"
( cd "$w" && git init -q . && git add -A && git commit -q -m tag && git tag v0.3.0 \
  && git checkout -q -b v0.3.0 && echo "BRANCH content" > skill/familiarise/SKILL.md && git commit -qam br ) 
git clone -q --bare "$w" "$S/br.git"
K2="$S/inst-k"; mkinst2 "$K2" 0.1.0
upd br "$K2" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$K2/SKILL.md")" = "TAG content" ] && [ "$(cat "$K2/VERSION")" = "0.3.0" ]
check "k: tag installed, same-named branch ignored" $?

# l. downgrade refused
mkrepo old 0.2.0 0.2.0
L="$S/inst-l"; mkinst2 "$L" 0.3.0; before="$(snap "$L")"
out="$(upd old "$L")"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "up to date" && [ "$before" = "$(snap "$L")" ]
check "l: downgrade refused, nothing changed" $?

# m. version ordering 0.10.0 > 0.2.0
mkrepo ten 0.10.0 0.10.0
M="$S/inst-m"; mkinst2 "$M" 0.2.0
upd ten "$M" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$M/VERSION")" = "0.10.0" ]
check "m: 0.10.0 installs over 0.2.0" $?

[ "$FAIL" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$FAIL"
