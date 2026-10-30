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

# Test overrides must never reach the real state dir: if any is set, a scratch FRAMEWORK_TUNNEL_STATE_DIR is required.
if [ -n "${FRAMEWORK_TUNNEL_SSH:-}${FRAMEWORK_TUNNEL_LOCAL_PORT:-}${FRAMEWORK_TUNNEL_REMOTE_PORT:-}${FRAMEWORK_TUNNEL_STATE_DIR:-}" ]; then
    if [ -z "${FRAMEWORK_TUNNEL_STATE_DIR:-}" ]; then
        echo "✗ a test override is set, so FRAMEWORK_TUNNEL_STATE_DIR must be set to a scratch folder too." >&2
        exit 1
    fi
    # Compare resolved real paths against the passwd home, not $HOME, so HOME=/other cannot hide it.
    REAL_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
    if [ "$(readlink -f -m -- "$STATE_DIR")" = "$(readlink -f -m -- "${REAL_HOME:-$HOME}/.config/shared-memory")" ] ||
       [ "$(readlink -f -m -- "$STATE_DIR")" = "$(readlink -f -m -- "$HOME/.config/shared-memory")" ]; then
        echo "✗ FRAMEWORK_TUNNEL_STATE_DIR must not be the real state dir (${REAL_HOME:-$HOME}/.config/shared-memory)." >&2
        exit 1
    fi
fi

# start and stop are operator-only: they need a terminal on stdin. status is open to everyone (agents).
# This guards against accidents (an agent running stop by mistake). It is not authentication.
if [ "$ACTION" != "status" ] && [ ! -t 0 ]; then
    echo "✗ $ACTION is operator-only: run it from your own terminal." >&2
    exit 1
fi

SOCK="$STATE_DIR/ssh-$LOCAL_PORT.sock"

port_busy() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${LOCAL_PORT}\$"
}

gateway_ok() {
    curl -s -m 5 "http://localhost:${LOCAL_PORT}/health" | grep -q '"status": *"ok"'
}

master_up() {
    "$SSH" -S "${1:-$SOCK}" -O check "$HOST" >/dev/null 2>&1
}

pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# The state file is written by the session. It holds the session script pid and the shell pid.
read_state() {
    S_HOST=""; S_MAIN=""; S_SHELL=""; S_SOCK="$STATE_DIR/ssh-$LOCAL_PORT.sock"
    [ -f "$STATE_FILE" ] || return 1
    while IFS='=' read -r key val; do
        case "$key" in
            HOST) S_HOST="$val" ;;
            MAIN_PID) S_MAIN="$val" ;;
            SHELL_PID) S_SHELL="$val" ;;
            SOCK) S_SOCK="$val" ;;
        esac
    done < "$STATE_FILE"
    return 0
}

# Closes the ssh master on socket $1 (default: this session's own), which closes the forward.
close_master() {
    local s="${1:-$SOCK}"
    master_up "$s" && "$SSH" -S "$s" -O exit "$HOST" >/dev/null 2>&1
    rm -f "$s"
}

# Closes the master named by the state (S_SOCK) and removes the state.
close_tunnel() {
    close_master "${S_SOCK:-$SOCK}"
    rm -f "$STATE_FILE"
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

# Exit handler of a session. Every session has its own ssh socket ($SOCK, ssh-<port>-<pid>.sock), so it
# always closes that one master and never a socket another session made. The shared state file is
# removed only if it is missing or names this session.
own_cleanup() {
    close_master "$SOCK"
    if read_state && [ "$S_MAIN" != "$$" ]; then
        return 0
    fi
    rm -f "$STATE_FILE"
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
        # The session shell traps HUP and exits, but bash runs that trap only after the foreground
        # command ends. So HUP the shell, then HUP its running children (the foreground job).
        kill -HUP "$S_SHELL" 2>/dev/null
        for c in $(ps -o pid= --ppid "$S_SHELL" 2>/dev/null); do kill -HUP "$c" 2>/dev/null; done
        for _ in $(seq 1 40); do
            [ -f "$STATE_FILE" ] || break
            sleep 0.25
        done
        if pid_alive "$S_SHELL" && is_session_shell "$S_SHELL" "$S_MAIN"; then
            echo "! the session shell (pid $S_SHELL) is busy. The close is requested and still pending." >&2
            echo "  The tunnel stays up until the running command ends; then the shell exits and the tunnel closes by itself." >&2
            echo "  State stays in $STATE_FILE until then. Do not run stop again; check with: $NAME $HOST status" >&2
            exit 1
        fi
    elif pid_alive "$S_MAIN"; then
        echo "✗ the session (pid $S_MAIN) has not recorded its shell yet. Try again in a moment." >&2
        exit 1
    fi
    if [ -f "$STATE_FILE" ]; then
        close_tunnel
    fi
    echo "tunnel to '$HOST' closed"
}

# Start lock: held from the checks until the state file is written, so two starts cannot both pass.
# An atomic mkdir with the owner pid inside. It leaves no file behind once released (flock would leave
# an empty start.lock).
LOCK="$STATE_DIR/start.lock"
LOCK_KIND=""
acquire_lock() {
    local tries=0 owner stale
    while ! mkdir "$LOCK.d" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -le 5 ] || return 1
        owner="$(cat "$LOCK.d/pid" 2>/dev/null)"
        if [ -z "$owner" ]; then
            # The holder may be between mkdir and writing its pid: held, unless the dir is old.
            [ $(( $(date +%s) - $(stat -c %Y "$LOCK.d" 2>/dev/null || echo 0) )) -lt 5 ] && return 1
        elif pid_alive "$owner"; then
            return 1
        fi
        # Stale: take it by atomic rename, so only one contender wins. If what we moved is not the
        # stale lock we judged (a new holder got in first), put it back and report busy.
        stale="$LOCK.stale.$$"
        if mv "$LOCK.d" "$stale" 2>/dev/null; then
            if [ "$(cat "$stale/pid" 2>/dev/null)" != "$owner" ]; then
                mv "$stale" "$LOCK.d" 2>/dev/null || rm -rf "$stale"
                return 1
            fi
            rm -rf "$stale"
        fi
    done
    echo "$$" > "$LOCK.d/pid"
    rm -f "$LOCK"                   # empty file left by older versions that used flock
    LOCK_KIND=mkdir
}

release_lock() {
    case "$LOCK_KIND" in
        mkdir) [ "$(cat "$LOCK.d/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK.d" ;;
    esac
    LOCK_KIND=""
}

do_start() {
    SOCK="$STATE_DIR/ssh-$LOCAL_PORT-$$.sock"          # this session's own socket
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"   # only start creates the state dir; status stays read-only
    # Release the lock, and close this session's own master if ssh got that far, on every way out,
    # signals included (bash runs a trap after the foreground command ends; the EXIT trap runs after `exit 1`).
    trap 'release_lock; own_cleanup' EXIT
    trap 'exit 1' HUP INT TERM
    if ! acquire_lock; then
        echo "✗ another '$NAME start' is in progress (it holds $LOCK). Wait for it, or finish its ssh prompt." >&2
        exit 1
    fi
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
        close_master "$SOCK"
        exit 1
    fi

    local rc="$STATE_DIR/session-rc.$$"
    printf 'HOST=%s\nMAIN_PID=%s\nSOCK=%s\n' "$HOST" "$$" "$SOCK" > "$STATE_FILE"
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
    trap "release_lock; own_cleanup; rm -f '$rc'" EXIT
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
