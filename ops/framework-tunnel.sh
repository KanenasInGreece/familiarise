#!/usr/bin/env bash
# framework-tunnel.sh — open a tunnel to one framework's shared-memory gateway for one session.
#
# Usage:
#   framework-tunnel.sh <host>           open the tunnel and start a session shell
#   framework-tunnel.sh <host> stop      close the tunnel (run from another terminal)
#   framework-tunnel.sh <host> status    report whether the tunnel to <host> is up
#
# start and stop refuse unless stdin is a terminal (operator-only; a guard against accidents, not
# authentication). status works from anywhere.
#
# <host> is an ssh alias from ~/.ssh/config. The tunnel is localhost:8888 -> <host>:localhost:8888.
#
# Opening: ssh asks for passphrases or passwords in this terminal, by hand. Then the tunnel is
# announced in ~/.config/shared-memory/active-framework, and a session shell starts. Any agent can read
# that file. Exiting the session shell closes the tunnel and removes the file.
# `stop` closes the tunnel, ends the session shell and removes the file the same way.
#
# Test overrides (leave unset in normal use): FRAMEWORK_TUNNEL_SSH, FRAMEWORK_TUNNEL_LOCAL_PORT,
# FRAMEWORK_TUNNEL_REMOTE_PORT, FRAMEWORK_TUNNEL_STATE_DIR.
set -uo pipefail

SSH="${FRAMEWORK_TUNNEL_SSH:-ssh}"
LOCAL_PORT="${FRAMEWORK_TUNNEL_LOCAL_PORT:-8888}"
REMOTE_PORT="${FRAMEWORK_TUNNEL_REMOTE_PORT:-8888}"
STATE_DIR="${FRAMEWORK_TUNNEL_STATE_DIR:-$HOME/.config/shared-memory}"
STATE_FILE="$STATE_DIR/active-framework"
NAME="$(basename "$0")"

usage() {
    echo "usage: $NAME <host> [start|stop|status]" >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
HOST="$1"
ACTION="${2:-start}"
case "$HOST" in
    ""|*[!A-Za-z0-9._-]*) echo "✗ invalid host name: '$HOST'" >&2; exit 2 ;;
esac
case "$ACTION" in
    start|stop|status) ;;
    *) usage ;;
esac

# start and stop are operator-only: they need a terminal on stdin. status is open to everyone (agents).
# This guards against accidents (an agent running stop by mistake). It is not authentication.
if [ "$ACTION" != "status" ] && [ ! -t 0 ]; then
    echo "✗ $ACTION is operator-only: run it from your own terminal." >&2
    exit 1
fi

SOCK="$STATE_DIR/ssh-$LOCAL_PORT.sock"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

port_busy() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${LOCAL_PORT}\$"
}

gateway_ok() {
    curl -s -m 5 "http://localhost:${LOCAL_PORT}/health" | grep -q '"status": *"ok"'
}

master_up() {
    "$SSH" -S "$SOCK" -O check "$HOST" >/dev/null 2>&1
}

pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# The state file is written by the session. It holds the session script pid and the shell pid.
read_state() {
    S_HOST=""; S_MAIN=""; S_SHELL=""
    [ -f "$STATE_FILE" ] || return 1
    while IFS='=' read -r key val; do
        case "$key" in
            HOST) S_HOST="$val" ;;
            MAIN_PID) S_MAIN="$val" ;;
            SHELL_PID) S_SHELL="$val" ;;
        esac
    done < "$STATE_FILE"
    return 0
}

# Closes the ssh master, which closes the forward, and removes the state.
close_tunnel() {
    master_up && "$SSH" -S "$SOCK" -O exit "$HOST" >/dev/null 2>&1
    rm -f "$SOCK" "$STATE_FILE"
}

# True if pid $1 is the session shell started by session script pid $2.
is_session_shell() {
    local pid="$1" main="$2" ppid cmd
    ppid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
    [ "$ppid" = "$main" ] || return 1
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmd" in
        *"--rcfile $STATE_DIR/session-rc.$main -i"*) return 0 ;;
    esac
    return 1
}

do_status() {
    if ! read_state; then
        echo "tunnel: DOWN (no session open)"
        exit 1
    fi
    if [ "$S_HOST" != "$HOST" ]; then
        echo "tunnel: DOWN for '$HOST' (the open session is to '$S_HOST')"
        exit 1
    fi
    if ! pid_alive "$S_MAIN"; then
        echo "tunnel: STALE for '$HOST' (session pid $S_MAIN is gone). Run: $NAME $HOST start"
        exit 1
    fi
    if gateway_ok; then
        echo "tunnel: UP   localhost:$LOCAL_PORT -> $HOST (session pid $S_MAIN)"
        exit 0
    fi
    echo "tunnel: session is open, but the gateway on localhost:$LOCAL_PORT does not answer"
    exit 1
}

do_stop() {
    if ! read_state; then
        echo "no tunnel open"
        exit 0
    fi
    if [ "$S_HOST" != "$HOST" ]; then
        echo "✗ the open tunnel is to '$S_HOST', not '$HOST'" >&2
        exit 1
    fi
    if [ -n "$S_SHELL" ]; then
        # Only signal a pid that is still this session's shell: the session script must be alive,
        # and the pid must be its child, started as `bash --rcfile <state dir>/session-rc.<main pid> -i`.
        # After a crash the pid may have been reused by an unrelated process.
        if ! pid_alive "$S_MAIN"; then
            echo "✗ session pid $S_MAIN is gone, so shell pid $S_SHELL cannot be trusted. Not signalling it." >&2
            echo "  State left in $STATE_FILE. Run: $NAME $HOST start (clears stale state), or remove it by hand." >&2
            exit 1
        fi
        if ! is_session_shell "$S_SHELL" "$S_MAIN"; then
            echo "✗ pid $S_SHELL is not the session shell of pid $S_MAIN. Not signalling it." >&2
            echo "  State left in $STATE_FILE for you to inspect." >&2
            exit 1
        fi
        # The session shell traps HUP and exits; that lets the session script close the tunnel.
        kill -HUP "$S_SHELL" 2>/dev/null
        for _ in $(seq 1 40); do
            [ -f "$STATE_FILE" ] || break
            sleep 0.25
        done
    fi
    if [ -f "$STATE_FILE" ]; then
        close_tunnel
    fi
    echo "tunnel to '$HOST' closed"
}

# Start lock: held from the checks until the state file is written, so two starts cannot both pass.
# flock when available (fd 9, released on exit); otherwise an atomic mkdir with the owner pid inside.
LOCK="$STATE_DIR/start.lock"
LOCK_KIND=""
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK"
        flock -n 9 || return 1
        LOCK_KIND=flock
        return 0
    fi
    if ! mkdir "$LOCK.d" 2>/dev/null; then
        local owner
        owner="$(cat "$LOCK.d/pid" 2>/dev/null)"
        pid_alive "$owner" && return 1
        rm -rf "$LOCK.d"            # owner is gone: stale lock
        mkdir "$LOCK.d" 2>/dev/null || return 1
    fi
    echo "$$" > "$LOCK.d/pid"
    LOCK_KIND=mkdir
}

release_lock() {
    case "$LOCK_KIND" in
        flock) exec 9>&- ;;
        mkdir) rm -rf "$LOCK.d" ;;
    esac
    LOCK_KIND=""
}

do_start() {
    if ! acquire_lock; then
        echo "✗ another '$NAME start' is in progress (it holds $LOCK). Wait for it, or finish its ssh prompt." >&2
        exit 1
    fi
    trap release_lock EXIT
    if read_state; then
        if pid_alive "$S_MAIN"; then
            echo "✗ a tunnel to '$S_HOST' is already open (session pid $S_MAIN)." >&2
            echo "  Close it first: $NAME $S_HOST stop" >&2
            exit 1
        fi
        echo "removing stale tunnel state for '$S_HOST'"
        close_tunnel
    fi

    if port_busy; then
        echo "✗ localhost:$LOCAL_PORT is in use by something this script did not start" >&2
        exit 1
    fi

    echo "Opening tunnel: localhost:$LOCAL_PORT -> $HOST:localhost:$REMOTE_PORT"
    echo "ssh may ask for your passphrase or password here."
    rm -f "$SOCK"
    # ssh authenticates in this terminal, then forks into the background as the control master.
    if ! "$SSH" -M -S "$SOCK" -f -N \
            -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
            -o ConnectTimeout=15 -L "$LOCAL_PORT:localhost:$REMOTE_PORT" "$HOST" 9>&-; then
        rm -f "$SOCK"
        echo "✗ could not open the ssh tunnel to '$HOST'" >&2
        echo "  If the key is passphrase-protected: ssh-add ~/.ssh/id_ed25519" >&2
        exit 1
    fi

    for _ in $(seq 1 20); do
        gateway_ok && break
        sleep 0.5
    done
    if ! gateway_ok; then
        echo "✗ the tunnel is up, but the gateway on localhost:$LOCAL_PORT does not answer /health" >&2
        close_tunnel
        exit 1
    fi

    local rc="$STATE_DIR/session-rc.$$"
    printf 'HOST=%s\nMAIN_PID=%s\n' "$HOST" "$$" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    release_lock
    # The session shell records its own pid, so `stop` can end it.
    cat > "$rc" <<EOF
[ -f ~/.bashrc ] && . ~/.bashrc
echo "SHELL_PID=\$\$" >> "$STATE_FILE"
rm -f "$rc"
# \`stop\` sends HUP to this shell. End the shell on it, so the session script can close the tunnel.
trap 'exit 0' HUP
EOF
    trap "release_lock; close_tunnel; rm -f '$rc'" EXIT
    # While the session shell runs, bash waits for it, so a HUP or TERM sent to this script is only
    # handled after the shell exits; it then exits with status 1 (the EXIT trap closes the tunnel).
    # Ctrl-C is ignored here, so it goes to the session shell only.
    trap : INT
    trap 'exit 1' HUP TERM

    echo ""
    echo "Tunnel to '$HOST' is up on localhost:$LOCAL_PORT."
    echo "Announced in $STATE_FILE. Exit this shell to close the tunnel."
    echo ""
    bash --rcfile "$rc" -i
    echo "tunnel to '$HOST' closed"
}

case "$ACTION" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
esac
