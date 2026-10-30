#!/usr/bin/env bash
# familiarise.sh — point this agent's shared-memory skill at the framework whose tunnel is open.
#
# Reads ~/.config/shared-memory/active-framework (written by framework-tunnel.sh), checks that
# the tunnel session is alive and the gateway answers, then makes SHARED_MEMORY_SKILL_DIR/.env a
# symlink to FRAMEWORK_ENV_DIR/.env-<framework>. Switching repoints the link, and a rotated token
# is seen through it at once. No token file is read, copied or hashed and no index is kept: only
# names and links are touched (readlink, test, ln, mv, chmod, mkdir).
#
# The target must be a regular file (not a symlink) resolving to FRAMEWORK_ENV_DIR/.env-<host>.
# DEST (the .env) cases: a link to the target: "already linked to <host>", nothing changed; a
# link to something else: replaced; a regular file (maybe an unsaved token): MOVED, not copied,
# to FRAMEWORK_ENV_DIR/.env-unsaved-<YYYYmmdd-HHMMSS> with mode 600, refused if that path
# exists; absent: linked. The link is made under a temp name (.env.link.<pid>) and renamed over
# DEST; the temp link is removed on any failure or kill. The parent of DEST must be writable,
# checked before any change. FAMILIARISE_NOW (A-Za-z0-9._- only) replaces the timestamp in the
# .env-unsaved name; for tests only.
#
# Usage:
#   familiarise.sh             point shared memory at the open framework (default)
#   familiarise.sh --version   print "familiarise <version>" (VERSION file beside SKILL.md;
#                              0.1.0 if the file is absent)
#   familiarise.sh --update    install the newest tagged release (vX.Y.Z) from FAMILIARISE_REPO
#                              (default https://github.com/KanenasInGreece/familiarise.git).
#                              Replaces only SKILL.md, VERSION and scripts/*, after a verified
#                              backup in .backup/<version>-<timestamp>/. Never touches .env or
#                              frameworks/. Never downgrades. Does not touch
#                              ~/framework-tunnel.sh (use sync_local.sh).
#
# Exit codes (default run):
#   0  linked, already linked, or no tunnel is open (which changes nothing)
#   1  any refusal or failure: config missing or incomplete, state file invalid, session ended,
#      or gateway silent; token file is a symlink or resolves outside FRAMEWORK_ENV_DIR; the
#      skill directory is not writable; DEST is neither a regular file nor a symlink; backup
#      path exists or the move failed; link creation or rename failed; verification failed.
#      On a refusal before the backup move, nothing changed.
#   2  no token file for this framework: missing, or not a regular file (a directory is exit 2);
#      nothing changed
# 143  killed by TERM/INT/HUP at any point after the trap is set (before the config, the health
#      check and any change): the temp link is removed and the lock released. If the backup move
#      had completed, stderr says the token is at the .env-unsaved path and DEST is absent. A
#      signal during the move is acted on after it. If the move was cut short, stderr says the
#      token is still in DEST and a partial copy may be at the .env-unsaved path. A signal after
#      the link has landed prints neither message.
# After the backup move, DEST is absent until the link lands: any failure then names the backup
# path. The backup move is no-clobber (mv -n). Across devices mv copies the bytes, and a failed
# move can leave a partial copy at the backup path while the original stays at DEST (that
# message names both).
# One run at a time: flock on FRAMEWORK_ENV_DIR/.lock; busy: exit 1 "another familiarise is
# running". FRAMEWORK_ENV_DIR must be an absolute path (exit 1 otherwise). The link is verified
# by resolution (readlink -f of DEST equals that of the target); a bad link is removed.
# Exit codes (--version): 0.
# Exit codes (--update): 0 up to date or updated; 143 killed by TERM, INT or HUP (a signal
#   during the install is not rolled back: rerun --update to reinstall); 1 any other failure (no
#   git, no tags, network or clone failure, unsafe tag content such as a symlink (also as skill/
#   or skill/familiarise), a symlink among the installed files, malformed or empty local
#   VERSION, VERSION mismatch, backup or install failure). On an install failure every replaced
#   file is restored from the backup; VERSION is installed last, so a failed update never
#   leaves a new VERSION over old files. If the rollback itself fails, the message says so and
#   names the backup.
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

saved=""; MOVED=0; DEST=""

# Report where the token is if the backup move was reached, then exit 143.
# Trapped from the first command on, so every interrupted run exits 143 (see the header).
# Globals: saved, DEST (read). Checks the files, not MOVED, because a signal during mv is
#   handled only after mv returns.
# Outputs: a one-line warning on stderr when the token moved or may be half-copied.
on_signal() {
    if [ -n "$saved" ] && [ -f "$saved" ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
        echo "familiarise: ✗ killed. The previous .env token is at $saved; $DEST is now absent." >&2
    elif [ -n "$saved" ] && [ -e "$saved" ] && [ -f "$DEST" ] && [ ! -L "$DEST" ]; then
        # A move interrupted across devices can leave a partial copy at $saved while DEST
        # still holds the token. A link in DEST means the token is gone from it: no message.
        echo "familiarise: ✗ killed during the backup move. The token is still in $DEST; a partial copy may be at $saved." >&2
    fi
    exit 143
}
trap on_signal TERM INT HUP

# --- version and self-update (handled before the config block; no .env needed) -------
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

# Copy a file over another through an unpredictable temp name beside it, verify, then rename.
# Arguments: $1 source file, $2 destination (refused if a directory or symlink).
# Returns: 1 on any failure, with the destination unchanged.
install_one() {
    local s="$1" d="$2" t
    { [ -d "$d" ] || [ -L "$d" ]; } && return 1
    t="$(mktemp "$(dirname -- "$d")/.familiarise-new.XXXXXX")" || return 1
    { cp -p -- "$s" "$t" && cmp -s "$s" "$t" && mv -T -f -- "$t" "$d"; } \
        || { rm -f -- "$t"; return 1; }
}

# Install the newest tagged release over this skill, or report it is up to date. Exits.
# Order: validate the tag content, back up, install SKILL.md and scripts/*, VERSION last,
#   rolling back every replaced file from the backup if any install fails.
# Globals: SKILL_ROOT (read), FAMILIARISE_REPO (optional).
# Outputs: progress on stdout, failures on stderr via fail.
# Returns: never; exits 0 (done or up to date) or 1 (see the header).
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
    for f in SKILL.md VERSION; do
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
    for f in "$SKILL_ROOT/SKILL.md" "$SKILL_ROOT/VERSION" "$SKILL_ROOT"/scripts/*; do
        [ -L "$f" ] && fail "installed ${f#"$SKILL_ROOT/"} is a symlink. Remove it first. Nothing changed."
    done
    # Backup first, verified byte for byte.
    stamp="$(date +%Y%m%d-%H%M%S)"
    bdir="$SKILL_ROOT/.backup/$local_v-$stamp"
    { [ -e "$bdir" ] || [ -L "$bdir" ]; } && fail "backup path $bdir already exists. Nothing changed."
    ( umask 077; mkdir -p -- "$SKILL_ROOT/.backup" "$bdir/scripts" ) \
        && chmod 700 "$SKILL_ROOT/.backup" "$bdir" "$bdir/scripts" \
        || fail "could not create backup dir $bdir. Nothing changed."
    for f in SKILL.md VERSION; do
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

    # Install SKILL.md and scripts first, VERSION last. Record each replaced file; on any
    # failure restore all of them (from the backup, or delete if it did not exist before).
    local -a done_rel=()
    local failed="" i
    # A file is recorded only after its install succeeds: a failed install leaves its target
    # unchanged, and restoring it would write into the directory that just refused the install.
    for rel in SKILL.md; do
        install_one "$src/$rel" "$SKILL_ROOT/$rel" || { failed="$rel"; break; }
        done_rel+=("$rel")
    done
    if [ -z "$failed" ]; then
        for f in "$src"/scripts/*; do
            [ -e "$f" ] || continue
            rel="scripts/$(basename -- "$f")"
            install_one "$f" "$SKILL_ROOT/$rel" || { failed="$rel"; break; }
            done_rel+=("$rel")
        done
    fi
    if [ -z "$failed" ]; then
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

# --- config (per agent, written when the skill is installed) -----------------------
[ -f "$CONFIG" ] || fail "no config at $CONFIG. Copy .env.example there and set the paths for this agent."

SHARED_MEMORY_SKILL_DIR=""; FRAMEWORK_ENV_DIR=""
while IFS='=' read -r key val; do
    val="${val%\"}"; val="${val#\"}"
    case "$key" in
        SHARED_MEMORY_SKILL_DIR) SHARED_MEMORY_SKILL_DIR="${val/#\~/$HOME}" ;;
        FRAMEWORK_ENV_DIR)       FRAMEWORK_ENV_DIR="${val/#\~/$HOME}" ;;
    esac
done < <(grep -E '^[A-Z_]+=' "$CONFIG")

[ -n "$SHARED_MEMORY_SKILL_DIR" ] || fail "SHARED_MEMORY_SKILL_DIR is not set in $CONFIG"
[ -n "$FRAMEWORK_ENV_DIR" ]       || fail "FRAMEWORK_ENV_DIR is not set in $CONFIG"
case "$FRAMEWORK_ENV_DIR" in
    /*) ;;
    *) fail "FRAMEWORK_ENV_DIR must be an absolute path ($FRAMEWORK_ENV_DIR). Nothing changed." ;;
esac
[ -f "$SHARED_MEMORY_SKILL_DIR/scripts/memory_bridge.py" ] \
    || fail "no shared-memory skill at $SHARED_MEMORY_SKILL_DIR (memory_bridge.py not found)"

# --- announced tunnel --------------------------------------------------------------
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

# --- gateway must answer on localhost ----------------------------------------------
HEALTH="$(curl -s -m 5 "http://localhost:${LOCAL_PORT}/health")"
echo "$HEALTH" | grep -q '"status": *"ok"' \
    || fail "localhost:$LOCAL_PORT does not answer /health. Nothing changed."
GATEWAY_VERSION="$(echo "$HEALTH" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"

# --- token file --------------------------------------------------------------------
# Only file names and links are touched from here on: no token file is read, copied or hashed.
mkdir -p "$FRAMEWORK_ENV_DIR" && chmod 700 "$FRAMEWORK_ENV_DIR" \
    || fail "could not create or secure $FRAMEWORK_ENV_DIR. Nothing changed."
# One familiarise at a time (lock on fd 9, released when the script exits).
exec 9>"$FRAMEWORK_ENV_DIR/.lock" && flock -n 9 \
    || fail "another familiarise is running; nothing changed."
TARGET="$FRAMEWORK_ENV_DIR/.env-$HOST"
if [ -L "$TARGET" ]; then
    fail "token file for '$HOST' is a symlink ($TARGET). Nothing changed."
fi
if [ ! -f "$TARGET" ]; then
    say "✗ no token file for '$HOST' (missing or not a regular file, e.g. a directory). Expected: $TARGET"
    say "The operator adds it. .env was not changed."; exit 2
fi
FW_REAL="$(readlink -f -- "$FRAMEWORK_ENV_DIR")" && [ "$(readlink -f -- "$TARGET")" = "$FW_REAL/.env-$HOST" ] \
    || fail "token file for '$HOST' resolves outside $FRAMEWORK_ENV_DIR. Nothing changed."

DEST="$SHARED_MEMORY_SKILL_DIR/.env"
# (a) already linked: nothing to do.
if [ -L "$DEST" ] && [ "$(readlink -- "$DEST")" = "$TARGET" ]; then
    say "already linked to $HOST"
    say "framework: $HOST"
    say "linked: $DEST -> $TARGET"
    say "gateway:   localhost:$LOCAL_PORT answers, version ${GATEWAY_VERSION:-unknown}"
    exit 0
fi
# The parent directory must allow creating and renaming entries; checked before any change.
{ [ -d "$SHARED_MEMORY_SKILL_DIR" ] && [ -w "$SHARED_MEMORY_SKILL_DIR" ] && [ -x "$SHARED_MEMORY_SKILL_DIR" ]; } \
    || fail "$SHARED_MEMORY_SKILL_DIR is not writable. Nothing changed."
# A DEST that is neither a link nor a regular file (e.g. a directory) is not touched.
if [ -e "$DEST" ] && [ ! -L "$DEST" ] && [ ! -f "$DEST" ]; then
    fail "$DEST exists and is not a regular file or a symlink. Nothing changed."
fi
saved=""; MOVED=0
if [ -f "$DEST" ] && [ ! -L "$DEST" ]; then
    # (c) a regular file may be an unsaved token: MOVE it (bytes unread) into the framework dir.
    stamp="${FAMILIARISE_NOW:-$(date +%Y%m%d-%H%M%S)}"
    case "$stamp" in
        ""|*[!A-Za-z0-9._-]*) fail "FAMILIARISE_NOW has characters outside A-Za-z0-9._-. Nothing changed." ;;
    esac
    saved="$FRAMEWORK_ENV_DIR/.env-unsaved-$stamp"
    { [ -e "$saved" ] || [ -L "$saved" ]; } \
        && fail "backup path $saved already exists. Nothing changed."
fi

# Fail with $1, naming the backup if the move already happened (DEST is absent until the
# link lands). Globals: MOVED, saved, DEST (read). Exits 1 via fail.
fail_post() {
    if [ "$MOVED" = 1 ]; then
        fail "$1 The previous .env token is at $saved; $DEST is now absent."
    else
        fail "$1 Nothing changed."
    fi
}
# Atomic link: create the link under a temp name beside DEST, then rename it over DEST.
LINK_TMP="$SHARED_MEMORY_SKILL_DIR/.env.link.$$"
trap 'rm -f -- "$LINK_TMP"' EXIT
if [ -n "$saved" ]; then
    # No-clobber move. A same-filesystem move reads no bytes; across devices mv copies them,
    # so a failed move can leave a partial copy at $saved while the original stays at DEST.
    mv -n -T -- "$DEST" "$saved" \
        || fail "could not move the current .env to $saved (a cross-device move copies bytes). Check $DEST and $saved."
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        fail "backup path appeared during the run; nothing changed. ($saved)"
    fi
    MOVED=1
    { [ -f "$saved" ] && [ ! -L "$saved" ]; } \
        || fail_post "backup $saved is not a regular file after the move."
    chmod 600 -- "$saved" || fail_post "could not set mode 600 on $saved."
    say "saved the previous .env to $saved"
fi
rm -f -- "$LINK_TMP"
ln -s -- "$TARGET" "$LINK_TMP" || fail_post "could not create a link in $SHARED_MEMORY_SKILL_DIR."
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    fail_post "$DEST became a regular file during the run; not replaced."
fi
mv -T -f -- "$LINK_TMP" "$DEST" || fail_post "could not replace $DEST with the link."
if [ -L "$DEST" ] && [ "$(readlink -f -- "$DEST")" = "$(readlink -f -- "$TARGET")" ]; then
    trap - EXIT
else
    [ -L "$DEST" ] && rm -f -- "$DEST"
    fail_post "verification failed: $DEST does not resolve to $TARGET (bad link removed)."
fi

# --- report (never reads a token) ---------------------------------------------------
say "framework: $HOST"
say "linked: $DEST -> $TARGET"
say "gateway:   localhost:$LOCAL_PORT answers, version ${GATEWAY_VERSION:-unknown}"
exit 0
