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
  && ! ls "$I"/scripts/.*.new.* >/dev/null 2>&1
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

[ "$FAIL" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$FAIL"
