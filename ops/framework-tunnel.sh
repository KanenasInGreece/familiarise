#!/usr/bin/env bash
# framework-tunnel.sh — open a tunnel to one framework's shared-memory gateway for one session.
#
# Usage:
#   framework-tunnel.sh <host>           open the tunnel and start a session shell
#   framework-tunnel.sh <host> stop      close the tunnel (run from another terminal)
#   framework-tunnel.sh <host> status    report whether the tunnel to <host> is up
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
    if pid_alive "$S_SHELL"; then
        # HUP ends an interactive bash. Its exit lets the session script close the tunnel.
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

do_start() {
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
            -o ConnectTimeout=15 -L "$LOCAL_PORT:localhost:$REMOTE_PORT" "$HOST"; then
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
    # The session shell records its own pid, so `stop` can end it.
    cat > "$rc" <<EOF
[ -f ~/.bashrc ] && . ~/.bashrc
echo "SHELL_PID=\$\$" >> "$STATE_FILE"
rm -f "$rc"
EOF
    trap "close_tunnel; rm -f '$rc'" EXIT
    # Ctrl-C goes to the session shell, not the script. HUP and TERM to the script end the session.
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
