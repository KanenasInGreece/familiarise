#!/usr/bin/env bash
# sync_local.sh — install or refresh the familiarise skill in every local agent that has shared memory.
#
# Local to this project, not part of the skill. Once the skill is in a repo, use its --update instead.
#
#   sync_local.sh [--dry-run]
#
# For each known agent whose skills dir holds a shared-memory skill:
#   - copies SKILL.md, CONSTITUTION_SNIPPET.md and scripts/ from skill/familiarise/
#   - creates frameworks/ (mode 700) if missing; never touches its contents
#   - creates .env from .env.example if missing; an existing .env is never changed
# Also installs ops/framework-tunnel.sh to ~/framework-tunnel.sh: temp file in the same folder, chmod 755,
# then mv (atomic, safe while a tunnel is open). An old, different copy is kept as
# ~/framework-tunnel.sh.bak-<timestamp>. An identical copy is left alone.
# Never edits a constitution file. Placing the block is a separate, operator-confirmed step.
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJECT/skill/familiarise"

# name | agent's skills dir. Identity is set by the gateway from the token, so no AGENT_NAME is guessed here.
CLIENTS=(
    "claude|$HOME/.claude/skills"
    "gemini|$HOME/.gemini/config/skills"
)

dry=0
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--dry-run" ]; }; then
    echo "usage: sync_local.sh [--dry-run]" >&2
    exit 2
fi
if [ "${1:-}" = "--dry-run" ]; then dry=1; fi

run() { if [ "$dry" -eq 1 ]; then echo "  would: $*"; else "$@"; fi; }

for entry in "${CLIENTS[@]}"; do
    IFS='|' read -r name skills <<< "$entry"
    sm="$skills/shared-memory"
    if [ ! -f "$sm/scripts/memory_bridge.py" ]; then
        echo "$name: no shared-memory skill at $sm, skipped"
        continue
    fi

    dst="$skills/familiarise"
    echo "$name: $dst"
    run mkdir -p "$dst/scripts" "$dst/frameworks"
    run chmod 700 "$dst/frameworks"
    for f in SKILL.md CONSTITUTION_SNIPPET.md; do
        run cp "$SRC/$f" "$dst/$f"
    done
    for f in "$SRC"/scripts/*; do
        run cp "$f" "$dst/scripts/"
    done
    run chmod +x "$dst/scripts/"*.sh

    if [ -f "$dst/.env" ]; then
        echo "  .env exists, left unchanged"
    elif [ "$dry" -eq 1 ]; then
        echo "  would create .env (shared memory $sm)"
    else
        # Fixed template, values passed through ENVIRON: any character in a path is safe (|, &, \).
        ( umask 077
          SM_DIR="$sm" FW_DIR="$dst/frameworks" awk '
            /^SHARED_MEMORY_SKILL_DIR=/ { print "SHARED_MEMORY_SKILL_DIR=" ENVIRON["SM_DIR"]; next }
            /^FRAMEWORK_ENV_DIR=/       { print "FRAMEWORK_ENV_DIR=" ENVIRON["FW_DIR"]; next }
            { print }' "$SRC/.env.example" > "$dst/.env" )
        chmod 600 "$dst/.env"
        echo "  .env created (shared memory $sm)"
    fi
done

# Tunnel script: ops/ is the source of truth, the home file is installed from it.
TUNNEL_SRC="$PROJECT/ops/framework-tunnel.sh"
TUNNEL_DST="$HOME/framework-tunnel.sh"
echo "tunnel script: $TUNNEL_DST"
if [ -f "$TUNNEL_DST" ] && cmp -s "$TUNNEL_SRC" "$TUNNEL_DST"; then
    echo "  identical, nothing to do"
elif [ "$dry" -eq 1 ]; then
    [ -f "$TUNNEL_DST" ] && echo "  would: back up to $TUNNEL_DST.bak-<timestamp>"
    echo "  would: install $TUNNEL_SRC (mode 755, atomic mv)"
else
    if [ -f "$TUNNEL_DST" ]; then
        bak="$TUNNEL_DST.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$TUNNEL_DST" "$bak"
        chmod 644 "$bak"
        echo "  backup: $bak"
    fi
    tmp="$(mktemp "$HOME/.framework-tunnel.sh.XXXXXX")"
    cp "$TUNNEL_SRC" "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" "$TUNNEL_DST"
    echo "  installed"
fi
