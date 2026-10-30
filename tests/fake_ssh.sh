#!/usr/bin/env bash
# Test double for ssh: control-master ops, and a fake forward that serves /health locally.
SOCK=""; OP=""; FWD=""; HOSTARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -S) SOCK="$2"; shift 2 ;; -O) OP="$2"; shift 2 ;; -L) FWD="$2"; shift 2 ;;
    -o) shift 2 ;; -M|-f|-N) shift ;; *) HOSTARG="$1"; shift ;;
  esac
done
PIDF="$SOCK.pid"
echo "fake_ssh: op=${OP:-connect} host=$HOSTARG fwd=$FWD" >> "$(dirname "$SOCK")/fake_ssh.log"
case "$OP" in
  check) [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && { echo "Master running"; exit 0; }; exit 255 ;;
  exit)  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; exit 0 ;;
esac
[ "$HOSTARG" = "nosuch" ] && { echo "ssh: Could not resolve hostname nosuch" >&2; exit 255; }
[ -n "${FAKE_SSH_FAIL:-}" ] && { echo "Permission denied (publickey)." >&2; exit 255; }
LPORT="${FWD%%:*}"
if [ -n "${FAKE_SSH_NO_GATEWAY:-}" ]; then
  sleep 600 & echo $! > "$PIDF"; exit 0
fi
python3 "$(dirname "$0")/fake_gateway.py" "$LPORT" >/dev/null 2>&1 &
echo $! > "$PIDF"
sleep 0.3
exit 0
