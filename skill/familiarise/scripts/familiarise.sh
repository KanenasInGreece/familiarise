#!/usr/bin/env bash
# familiarise.sh — point this agent's shared-memory skill at the framework whose tunnel is open.
#
# framework-tunnel.sh announces an open tunnel in ~/.config/shared-memory/active-framework. This script
# reads that file, checks that the tunnel session is alive and the gateway answers, then copies
# FRAMEWORK_ENV_DIR/.env-<framework> over SHARED_MEMORY_SKILL_DIR/.env. Nothing is copied unless every
# check passes.
#
# Exit codes:
#   0  .env copied (or no tunnel is open, which changes nothing)
#   1  not usable: config missing or incomplete, state file invalid, session ended, or gateway silent;
#      or the existing .env could not be backed up (backup path exists, or the backup failed its check).
#      Nothing is copied. (A failed copy or copy check also exits 1, after the backup.)
#   2  no token file exists for this framework
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
