# familiarise

**Mission:** make an agent's shared-memory skill follow the framework whose tunnel is open. Design detail lives in `skill/familiarise/SKILL.md` and the script headers. This file holds only what a builder, reviewer or operator needs here.

## Ground rules

1. Token files never enter git, chat or output. Print identity and gateway version only. Never source a `.env`.
2. Each agent has its own `frameworks/`. Tokens are never shared between agents.
3. Never overwrite a token by accident. An unmatched `.env` is saved as `.env-unsaved-<timestamp>` first.
4. `ops/framework-tunnel.sh` is the source of truth. `~/framework-tunnel.sh` is installed from it by `scripts/sync_local.sh`; never edit the home file. `start` and `stop` are operator-only (they refuse without a terminal on stdin; a guard against accidents, not authentication). Agents use `status` only.
5. The gateway sets identity from the token. Never guess `AGENT_NAME` locally.
6. Ask the operator before anything destructive or outward-facing: token files, installs into agent folders, pushes, system packages.
7. Verify each step before the next. Scripts are idempotent.
8. Shared-memory saves from this folder use project `familiarise`. Facts and decisions go to shared memory, not here.

## Components

| Part | Location |
|---|---|
| Tunnel script (source of truth) | `ops/framework-tunnel.sh`, installed to `~/framework-tunnel.sh` by `scripts/sync_local.sh` (see `ops/README.md`) |
| Skill source | `skill/familiarise/` |
| Skill installed per agent | `~/.claude/skills/familiarise/`, `~/.gemini/config/skills/familiarise/` |
| Token files (operator-managed) | `<agent skills dir>/familiarise/frameworks/.env-<host>` |
| Sync | `scripts/sync_local.sh [--dry-run]`: skill to each agent, tunnel script to home (backup, atomic mv) |
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
- `place_snippet.sh` exits: 0 placed, already up to date, or dry run; 1 error (no snippet, markers missing, insertion or write failed; target unchanged); 2 usage; 3 unterminated or nested familiarise block (target unchanged). 4 is awk-internal ("no shared-memory block", handled by placing at the top); the script never exits 4.
- `familiarise.sh` exit 1 also covers a backup failure: the `.env-unsaved-*` path already exists, or the copy or its check fails. Nothing is copied.
- Constitution blocks are copied verbatim from `CONSTITUTION_SNIPPET.md` and placed with `scripts/place_snippet.sh`. The operator confirms the file first.
- `CONSTITUTION_SNIPPET.md` is the canonical text. Do not restate it here.

## Testing

- **End to end first.** A test is valid only if it runs the real flow and checks the result. Unit tests of single variables pass when logic is wrong, so do not write them as proof.
- **Connect proves the script connects.** The real `~/framework-tunnel.sh workstation`, then `/familiarise`, then the status check.
- **Disconnect proves the state resets.** Exit the session shell, then check that the state file is gone, the tunnel is down, and the `.env` copy is in its expected state.
- **Targeted checks only** for functions where a regression would be silent (for example, a marker-strip in `place_snippet.sh`). Run them against scratch copies, never live files.
- The operator runs the live connect and disconnect, since it needs the ssh prompt. An agent can run the fake-based flow below.

Fake-based flow, on a spare port and a scratch state dir:

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
- Real ssh password prompt and the live workstation gateway are untested.
