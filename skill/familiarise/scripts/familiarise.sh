#!/usr/bin/env bash
# familiarise.sh — point this agent's shared-memory skill at the framework whose tunnel is open.
#
# framework-tunnel.sh announces an open tunnel in ~/.config/shared-memory/active-framework. This script
# reads that file, checks that the tunnel session is alive and the gateway answers, then copies
# FRAMEWORK_ENV_DIR/.env-<framework> over SHARED_MEMORY_SKILL_DIR/.env. Nothing is copied unless every
# check passes.
#
# Usage:
#   familiarise.sh             point shared memory at the open framework (default)
#   familiarise.sh --version   print "familiarise <version>" (VERSION file beside SKILL.md; 0.1.0 if the file is absent)
#   familiarise.sh --update    install the newest tagged release (vX.Y.Z) from FAMILIARISE_REPO
#                              (default https://github.com/KanenasInGreece/familiarise.git). Replaces only
#                              SKILL.md, CONSTITUTION_SNIPPET.md, VERSION and scripts/*, after a verified
#                              backup in .backup/<version>-<timestamp>/. Never touches .env or frameworks/.
#                              Never downgrades. Does not touch ~/framework-tunnel.sh (use sync_local.sh).
#
# Exit codes (default run):
#   0  .env copied (or no tunnel is open, which changes nothing)
#   1  not usable: config missing or incomplete, state file invalid, session ended, or gateway silent;
#      or the existing .env could not be backed up (backup path exists, or the backup failed its check).
#      Nothing is copied. (A failed copy or copy check also exits 1, after the backup.)
#   2  no token file exists for this framework
# Exit codes (--version): 0.
# Exit codes (--update): 0 up to date or updated; 1 any failure (no git, no tags, network or clone
#   failure, unsafe tag content such as a symlink (also as skill/ or skill/familiarise), a symlink among the
#   installed files, malformed or empty local VERSION, VERSION mismatch, backup or
#   install failure). On an install failure every replaced file is restored from the backup; VERSION is
#   installed last, so a failed update never leaves a new VERSION over old files. If the rollback itself
#   fails, the message says so and names the backup.
# Unknown arguments: usage on stderr, exit 1.
#
# Never prints a token. Never sources a .env.
set -uo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${FAMILIARISE_ENV:-$SKILL_ROOT/.env}"
STATE_DIR="${FRAMEWORK_TUNNEL_STATE_DIR:-$HOME/.config/shared-memory}"
STATE_FILE="$STATE_DIR/active-framework"
LOCAL_PORT="${FRAMEWORK_TUNNEL_LOCAL_PORT:-8888}"

say() { echo "familiarise: $*"; }
fail() { echo "familiarise: ✗ $*" >&2; exit "${2:-1}"; }

# --- version and self-update (handled before the config block; no .env needed) ----------------------
local_version() {
    # Missing VERSION file: 0.1.0. A present file is returned as is (empty is rejected by --update).
    if [ -f "$SKILL_ROOT/VERSION" ]; then
        head -n 1 "$SKILL_ROOT/VERSION" | tr -d '[:space:]'; echo
    else
        echo "0.1.0"
    fi
}

# git with a 60 s limit when `timeout` exists.
gitt() {
    if command -v timeout >/dev/null 2>&1; then timeout 60 git "$@"; else git "$@"; fi
}

# Copy $1 to $2 through an unpredictable temp name in the destination dir, verify, rename over.
# Refuses a destination that is a directory or symlink. Returns 1 on any failure (dest unchanged).
install_one() {
    local s="$1" d="$2" t
    { [ -d "$d" ] || [ -L "$d" ]; } && return 1
    t="$(mktemp "$(dirname -- "$d")/.familiarise-new.XXXXXX")" || return 1
    { cp -p -- "$s" "$t" && cmp -s "$s" "$t" && mv -T -f -- "$t" "$d"; } \
        || { rm -f -- "$t"; return 1; }
}

do_update() {
    local repo="${FAMILIARISE_REPO:-https://github.com/KanenasInGreece/familiarise.git}"
    local local_v remote_v tags latest tmp stamp bdir f base rel
    command -v git >/dev/null 2>&1 || fail "git is not installed. Nothing changed."
    export GIT_TERMINAL_PROMPT=0
    local_v="$(local_version)"
    printf '%s\n' "$local_v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || fail "local VERSION '$local_v' is not X.Y.Z. Fix or remove the VERSION file. Nothing changed."
    tags="$(gitt ls-remote --tags --refs -- "$repo" 2>/dev/null)" \
        || fail "could not reach $repo. Nothing changed."
    latest="$(printf '%s\n' "$tags" | sed -nE 's|^[0-9a-f]+[[:space:]]+refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$|\1|p' | sort -V | tail -n 1)"
    [ -n "$latest" ] || fail "no release tags (vX.Y.Z) found at $repo. Nothing changed."
    printf '%s\n' "$latest" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        || fail "unexpected tag name. Nothing changed."
    remote_v="${latest#v}"
    if [ "$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -n 1)" = "$local_v" ]; then
        say "up to date ($local_v)"
        exit 0
    fi

    tmp="$(mktemp -d)" || fail "could not create a temp dir. Nothing changed."
    trap 'rm -rf -- "$tmp"' EXIT
    # Fetch only the tag ref (refs/tags/...), so a branch of the same name is never used.
    { git init -q -- "$tmp/src" >/dev/null 2>&1 \
        && gitt -C "$tmp/src" fetch -q --depth 1 -- "$repo" "refs/tags/$latest" >/dev/null 2>&1 \
        && git -C "$tmp/src" checkout -q FETCH_HEAD >/dev/null 2>&1; } \
        || fail "could not fetch tag $latest from $repo. Nothing changed."
    local src="$tmp/src/skill/familiarise"
    # The clone's own parent directories must be real directories, not links out of the clone.
    for f in "$tmp/src/skill" "$src"; do
        { [ -d "$f" ] && [ ! -L "$f" ]; } \
            || fail "tag $latest: ${f#"$tmp/src/"} is missing, not a directory, or a symlink. Nothing changed."
    done
    # Every source must be a regular file, not a symlink (a link could pull in a local file).
    for f in SKILL.md CONSTITUTION_SNIPPET.md VERSION; do
        { [ -f "$src/$f" ] && [ ! -L "$src/$f" ]; } \
            || fail "tag $latest: $f is missing or not a regular file. Nothing changed."
    done
    { [ -d "$src/scripts" ] && [ ! -L "$src/scripts" ]; } \
        || fail "tag $latest: scripts/ is missing or a symlink. Nothing changed."
    for f in "$src"/scripts/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        { [ -f "$f" ] && [ ! -L "$f" ]; } \
            || fail "tag $latest: scripts/$(basename -- "$f") is not a regular file. Nothing changed."
    done
    [ "$(head -n 1 "$src/VERSION" | tr -d '[:space:]')" = "$remote_v" ] \
        || fail "tag $latest does not carry VERSION $remote_v. Nothing changed."

    # Installed targets must not be symlinks (a backup would follow them).
    [ -L "$SKILL_ROOT/scripts" ] && fail "$SKILL_ROOT/scripts is a symlink. Nothing changed."
    for f in "$SKILL_ROOT/SKILL.md" "$SKILL_ROOT/CONSTITUTION_SNIPPET.md" "$SKILL_ROOT/VERSION" "$SKILL_ROOT"/scripts/*; do
        [ -L "$f" ] && fail "installed ${f#"$SKILL_ROOT/"} is a symlink. Remove it first. Nothing changed."
    done
    # Backup first, verified byte for byte.
    stamp="$(date +%Y%m%d-%H%M%S)"
    bdir="$SKILL_ROOT/.backup/$local_v-$stamp"
    { [ -e "$bdir" ] || [ -L "$bdir" ]; } && fail "backup path $bdir already exists. Nothing changed."
    ( umask 077; mkdir -p -- "$SKILL_ROOT/.backup" "$bdir/scripts" ) \
        && chmod 700 "$SKILL_ROOT/.backup" "$bdir" "$bdir/scripts" \
        || fail "could not create backup dir $bdir. Nothing changed."
    for f in SKILL.md CONSTITUTION_SNIPPET.md VERSION; do
        [ -f "$SKILL_ROOT/$f" ] || continue
        cp -p -- "$SKILL_ROOT/$f" "$bdir/$f" && cmp -s "$SKILL_ROOT/$f" "$bdir/$f" \
            || fail "backup of $f failed verification ($bdir). Nothing changed."
    done
    for f in "$SKILL_ROOT"/scripts/*; do
        [ -f "$f" ] || continue
        base="$(basename -- "$f")"
        cp -p -- "$f" "$bdir/scripts/$base" && cmp -s "$f" "$bdir/scripts/$base" \
            || fail "backup of scripts/$base failed verification ($bdir). Nothing changed."
    done

    # Install SKILL.md, snippet and scripts first, VERSION last. Record each replaced file; on any
    # failure restore all of them (from the backup, or delete if it did not exist before).
    local -a done_rel=()
    local failed="" i
    for rel in SKILL.md CONSTITUTION_SNIPPET.md; do
        done_rel+=("$rel")
        install_one "$src/$rel" "$SKILL_ROOT/$rel" || { failed="$rel"; break; }
    done
    if [ -z "$failed" ]; then
        for f in "$src"/scripts/*; do
            [ -e "$f" ] || continue
            rel="scripts/$(basename -- "$f")"
            done_rel+=("$rel")
            install_one "$f" "$SKILL_ROOT/$rel" || { failed="$rel"; break; }
        done
    fi
    if [ -z "$failed" ]; then
        done_rel+=("VERSION")
        install_one "$src/VERSION" "$SKILL_ROOT/VERSION" || failed="VERSION"
    fi
    if [ -n "$failed" ]; then
        local rb=0
        for (( i=${#done_rel[@]}-1; i>=0; i-- )); do
            rel="${done_rel[$i]}"
            if [ -f "$bdir/$rel" ]; then
                install_one "$bdir/$rel" "$SKILL_ROOT/$rel" || rb=1
            elif [ -f "$SKILL_ROOT/$rel" ] && [ ! -L "$SKILL_ROOT/$rel" ]; then
                rm -f -- "$SKILL_ROOT/$rel" || rb=1
            fi
        done
        if [ "$rb" = 0 ]; then
            fail "could not install $failed; earlier changes were rolled back. Backup is at $bdir."
        else
            fail "could not install $failed and the rollback was incomplete. Restore from $bdir."
        fi
    fi
    say "updated $local_v -> $remote_v"
    say "backup: $bdir"
    say "note: ~/framework-tunnel.sh is not touched by --update; use scripts/sync_local.sh for the tunnel script."
    exit 0
}

case "${1:-}" in
    "") ;;
    --version) [ "$#" -eq 1 ] || { echo "usage: familiarise.sh [--version | --update]" >&2; exit 1; }
               echo "familiarise $(local_version)"; exit 0 ;;
    --update)  [ "$#" -eq 1 ] || { echo "usage: familiarise.sh [--version | --update]" >&2; exit 1; }
               do_update ;;
    *) echo "usage: familiarise.sh [--version | --update]" >&2; exit 1 ;;
esac

# --- config (per agent, written when the skill is installed) ---------------------------------
[ -f "$CONFIG" ] || fail "no config at $CONFIG. Copy .env.example there and set the paths for this agent."

SHARED_MEMORY_SKILL_DIR=""; FRAMEWORK_ENV_DIR=""; AGENT_NAME=""
while IFS='=' read -r key val; do
    val="${val%\"}"; val="${val#\"}"
    case "$key" in
        SHARED_MEMORY_SKILL_DIR) SHARED_MEMORY_SKILL_DIR="${val/#\~/$HOME}" ;;
        FRAMEWORK_ENV_DIR)       FRAMEWORK_ENV_DIR="${val/#\~/$HOME}" ;;
        AGENT_NAME)              AGENT_NAME="$val" ;;
    esac
done < <(grep -E '^[A-Z_]+=' "$CONFIG")

[ -n "$SHARED_MEMORY_SKILL_DIR" ] || fail "SHARED_MEMORY_SKILL_DIR is not set in $CONFIG"
[ -n "$FRAMEWORK_ENV_DIR" ]       || fail "FRAMEWORK_ENV_DIR is not set in $CONFIG"
[ -f "$SHARED_MEMORY_SKILL_DIR/scripts/memory_bridge.py" ] \
    || fail "no shared-memory skill at $SHARED_MEMORY_SKILL_DIR (memory_bridge.py not found)"

# --- announced tunnel ----------------------------------------------------------------------------
if [ ! -f "$STATE_FILE" ]; then
    say "no framework tunnel is open ($STATE_FILE is absent). Nothing changed."
    say "Open one from a terminal with: ~/framework-tunnel.sh <host>"
    exit 0
fi
HOST=""; S_MAIN=""
while IFS='=' read -r key val; do
    case "$key" in
        HOST) HOST="$val" ;;
        MAIN_PID) S_MAIN="$val" ;;
    esac
done < "$STATE_FILE"
[ -n "$HOST" ] || fail "$STATE_FILE names no framework. Nothing changed."
case "$HOST" in
    *[!A-Za-z0-9._-]*) fail "$STATE_FILE names an invalid host. Nothing changed." ;;
esac
[ -n "$S_MAIN" ] && kill -0 "$S_MAIN" 2>/dev/null \
    || fail "the tunnel session for '$HOST' has ended (stale $STATE_FILE). Nothing changed."

# --- gateway must answer on localhost -------------------------------------------------------------
HEALTH="$(curl -s -m 5 "http://localhost:${LOCAL_PORT}/health")"
echo "$HEALTH" | grep -q '"status": *"ok"' \
    || fail "localhost:$LOCAL_PORT does not answer /health. Nothing changed."
GATEWAY_VERSION="$(echo "$HEALTH" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"

# --- token file ------------------------------------------------------------------------------------
mkdir -p "$FRAMEWORK_ENV_DIR" && chmod 700 "$FRAMEWORK_ENV_DIR"
SRC="$FRAMEWORK_ENV_DIR/.env-$HOST"
[ -f "$SRC" ] || { say "✗ no token file for '$HOST'. Expected: $SRC"; say "The operator adds it. .env was not changed."; exit 2; }

DEST="$SHARED_MEMORY_SKILL_DIR/.env"
if [ -f "$DEST" ] && ! cmp -s "$DEST" "$SRC"; then
    # Keep the current .env if no framework file matches it, so a token is never lost.
    matched=0
    for f in "$FRAMEWORK_ENV_DIR"/.env-*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in .env-unsaved-*) continue ;; esac
        cmp -s "$f" "$DEST" && { matched=1; break; }
    done
    if [ "$matched" -eq 0 ]; then
        saved="$FRAMEWORK_ENV_DIR/.env-unsaved-$(date +%Y%m%d-%H%M%S)"
        # Never write through an existing path (a directory or symlink would receive the token copy).
        { [ -e "$saved" ] || [ -L "$saved" ]; } \
            && fail "backup path $saved already exists. Nothing copied."
        # Backup first, mode 600 from the start, verified byte for byte. Any failure stops here,
        # before the overwrite, so the unmatched token is never lost.
        ( umask 077; cp -- "$DEST" "$saved" ) 2>/dev/null \
            || { rm -f -- "$saved"; fail "could not back up the current .env to $saved. Nothing copied."; }
        chmod 600 "$saved" 2>/dev/null && cmp -s "$DEST" "$saved" \
            || { rm -f -- "$saved"; fail "backup of the current .env to $saved failed verification. Nothing copied."; }
        say "saved the previous .env (matched no framework file) to $saved"
    fi
fi

cp "$SRC" "$DEST" && chmod 600 "$DEST" || fail "could not copy $SRC to $DEST"
cmp -s "$SRC" "$DEST" || fail "copy verification failed"

# --- report (identity only, never the token) ------------------------------------------------------
AGENT_ID_IN_ENV="$(grep -E '^AGENT_ID=' "$DEST" | head -1 | cut -d= -f2-)"
say "framework: $HOST"
say ".env copied from $SRC"
say "identity:  ${AGENT_ID_IN_ENV:-(AGENT_ID not set in the framework file)}"
say "gateway:   localhost:$LOCAL_PORT answers, version ${GATEWAY_VERSION:-unknown}"
if [ -n "$AGENT_NAME" ] && [ "$AGENT_ID_IN_ENV" != "$AGENT_NAME" ]; then
    say "warning: this agent is configured as '$AGENT_NAME', but the framework file sets '${AGENT_ID_IN_ENV:-no AGENT_ID}'"
fi
exit 0
