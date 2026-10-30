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
        sed -e "s|^SHARED_MEMORY_SKILL_DIR=.*|SHARED_MEMORY_SKILL_DIR=$sm|" \
            -e "s|^FRAMEWORK_ENV_DIR=.*|FRAMEWORK_ENV_DIR=$dst/frameworks|" \
            "$SRC/.env.example" > "$dst/.env"
        chmod 600 "$dst/.env"
        echo "  .env created (shared memory $sm)"
    fi
done
