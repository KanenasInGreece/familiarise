# familiarise

**Mission:** make an agent's shared-memory skill follow the framework whose tunnel is open. Design detail lives in `skill/familiarise/SKILL.md` and the script headers. This file holds only what a builder, reviewer or operator needs here.

## Ground rules

1. Token files never enter git, chat or output. Print identity and gateway version only. Never source a `.env`.
2. Each agent has its own `frameworks/`. Tokens are never shared between agents.
3. Never overwrite a token by accident. An unmatched `.env` is saved as `.env-unsaved-<timestamp>` first.
4. `~/framework-tunnel.sh` is edited in place, outside this repo. Do not copy it in.
5. The gateway sets identity from the token. Never guess `AGENT_NAME` locally.
6. Ask the operator before anything destructive or outward-facing: token files, installs into agent folders, pushes, system packages.
7. Verify each step before the next. Scripts are idempotent.
8. Shared-memory saves from this folder use project `familiarise`. Facts and decisions go to shared memory, not here.

## Components

| Part | Location |
|---|---|
| Tunnel script (not in repo) | `~/framework-tunnel.sh` |
| Skill source | `skill/familiarise/` |
| Skill installed per agent | `~/.claude/skills/familiarise/`, `~/.gemini/config/skills/familiarise/` |
| Token files (operator-managed) | `<agent skills dir>/familiarise/frameworks/.env-<host>` |
| Sync to local agents | `scripts/sync_local.sh [--dry-run]` (local to this folder; later replaced by `--update` from the repo) |
| Test doubles | `tests/fake_ssh.sh`, `tests/fake_gateway.py` |

## Roles and cooperation

- **Orchestrator** (the main session): splits work, creates one worktree per task, merges only after a clean review, runs the final checks, reports to the operator. Does not write a build task itself when a builder is available.
- **Builder** (Haiku; Sonnet for multi-file or security-sensitive work): one task, one worktree, one branch `build/<task>`. Edits only inside its worktree. Runs `bash -n` and the tests. Commits with the trailer for its own model. Does not merge, push, or touch other worktrees or installed agents.
- **Reviewer** (Opus 5.5 only; Haiku and Sonnet never review): reads `git diff main...build/<task>`, runs the checks, and reports findings with file, line, severity and a failure scenario. Read-only. Never fixes. Re-reviews after a fix.
- **Merge gate:** the orchestrator runs `git merge --no-ff build/<task>` only when the reviewer reports no open high or medium findings. Then it removes the worktree and branch.
- **Operator:** decides ground rule 6 items, token files, and identity names.

Worktrees live outside the repo: `git worktree add ../familiarise-wt/<task> -b build/<task> main`. Remove with `git worktree remove` and `git branch -d` after merge.

**Offline or on local models:** the same roles apply. A local model may take the builder role. Without a reachable Opus reviewer, nothing merges until the operator approves.

Every commit ends with `Co-Authored-By: <model that wrote it> <noreply@anthropic.com>`.

## Conventions

- Shell scripts: `set -uo pipefail`. Quote every path. Never `source` a `.env`.
- Exit codes live in the script header and SKILL.md. Change them in both.
- Constitution blocks are copied verbatim from `CONSTITUTION_SNIPPET.md` and placed with `scripts/place_snippet.sh`. The operator confirms the file first.
- `CONSTITUTION_SNIPPET.md` is the canonical text. Do not restate it here.

## Testing

Use only the test doubles, on a spare port and a scratch state dir:

```
FRAMEWORK_TUNNEL_SSH=tests/fake_ssh.sh
FRAMEWORK_TUNNEL_LOCAL_PORT=18888
FRAMEWORK_TUNNEL_STATE_DIR=<scratch>
```

Never use port 8888 or `~/.config/shared-memory` in a test.

## Known limits

- The session shell is bash only.
- Stopping from another terminal sends HUP to the session shell. Unsaved work there is lost.
- `familiarise` checks liveness through the state file and `/health`. It does not check the token. A bad token fails on the first search or save.

## Open items

- Operator: mint a token on each gateway for each local agent. The name minted is that agent's identity (Claude here: `chromebook-claude`).
- Gemini has no token yet. Its `frameworks/` is empty.
- Operator: decide whether to drop the `AGENT_NAME` mismatch warning in `familiarise.sh` and the `AGENT_NAME` line in the Claude `.env`.
- Operator: place the familiarise block in `~/.gemini/GEMINI.md` (needs confirmation).
- Review findings still open: tunnel script `stop` pid check, the start lock, and the trap comment (`~/framework-tunnel.sh`, outside the repo).
- Real ssh password prompt and the live workstation gateway are untested.
