# familiarise

Connects an agent's shared-memory skill to the framework whose tunnel is open. Each framework (site) has its own gateway and its own tokens. This project makes the switch safe: the tunnel decides which framework is live, and the skill copies only that framework's token file.

## Components

| Part | Location | Who runs it |
|---|---|---|
| Tunnel script | `~/framework-tunnel.sh` (home directory, not in this project) | Xenofon, by hand, in a terminal |
| Familiarise skill (source) | `skill/familiarise/` | — (installed per agent) |
| Familiarise skill (installed) | `~/.claude/skills/familiarise/` | the agent, via `/familiarise` |
| Token files | `<agent's familiarise skill>/frameworks/.env-<host>`, e.g. `~/.claude/skills/familiarise/frameworks/.env-workstation` | operator; one per framework, per agent |
| Shared-memory skill | `~/.claude/skills/shared-memory/` | updated by its own `update_skill.sh` |
| Test doubles | `tests/` | manual tests of the tunnel script |

The tunnel script stays in the home directory, as Xenofon asked. Do not keep a second copy in this project. Edit `~/framework-tunnel.sh` directly, and record changes here.

## The flow (Xenofon's example)

1. In a terminal, run `~/framework-tunnel.sh workstation`.
2. ssh asks for the passphrase or password in that terminal. Nothing else prompts, and the agent never sees it.
3. The tunnel comes up: `localhost:8888` forwards to the workstation gateway. The script checks `/health`.
4. The script writes `~/.config/shared-memory/active-framework` (the framework, the session pid), then opens a **session shell**. The session shell holds the tunnel open. Agents read the file, so they can run from any shell.
5. In the agent, run `/familiarise`. It reads the file, checks that the session in it is alive, and that `localhost:8888/health` answers. Then it copies `~/.claude/skills/familiarise/frameworks/.env-workstation` over the shared-memory skill's `.env`.
6. Shared memory now uses the workstation token and identifies as `claude-chromebook`.
7. To close, exit the session shell. The tunnel closes, and the file is removed. From another terminal, `~/framework-tunnel.sh workstation stop` does the same: it ends the session shell and closes the tunnel.

## Why a state file, not an environment variable

The first design set `SHARED_MEMORY_FRAMEWORK` in a session shell. It worked only for agents started from that shell. A running script cannot set a variable in other processes. The state file in `~/.config/shared-memory/` is visible to any agent in any shell. The tunnel script creates it when the tunnel opens and removes it when the tunnel closes. A file left behind by a crash is caught by the pid check, because `familiarise` refuses when the session pid is gone.

## Conventions

- **Framework name = the ssh alias** from `~/.ssh/config` (for example `workstation`). The token file is `.env-<alias>`. Names are limited to `A-Za-z0-9._-`.
- **Identity is chosen on the gateway, never on the client.** The gateway keeps a registry, `AGENT_TOKENS`, of `name:sha256(token)`. It stamps every write with the name bound to the presented token, and it ignores the body `agent_id`. `AGENT_ID` in a framework `.env` is only a label the client sends; the gateway overrides it. Source: `SECURITY.md` in the Shared_memory repo (v0.3.5 auth, "verified agent identity is stamped server-side"). Local agents pick no identity. Each agent's name is whatever the gateway minted its token under: `doctor` reports it as `agent` (for this Chromebook's workstation token it is `chromebook-claude`). Do not set `AGENT_NAME` locally to guess one.
- **Token files are never printed, quoted, summarised or sourced.** `familiarise` prints the identity and the gateway version only.
- **Token files are operator-managed.** `familiarise` never creates or edits them. It creates the folder if it is missing, and it reports a missing file (exit 2) instead of guessing.
- **Per agent, never shared:** `frameworks/` is a folder in the **familiarise** skill, not in the shared-memory skill. Each agent has its own, at `<agent skills dir>/familiarise/frameworks/` (for Claude: `~/.claude/skills/familiarise/frameworks/`). The shared-memory skill folder never holds or refers to this folder. The copied `.env` is the only thing that goes into the shared-memory skill. No agent reads another agent's tokens. The tunnel state file in `~/.config/shared-memory/active-framework` is the one shared item, because a machine has one tunnel at a time. It holds no tokens.
- **Never overwrite a token by accident.** If the current `.env` matches no framework file, both the tunnel script and `familiarise` save it as `.env-unsaved-<timestamp>` (mode 600) before copying.

## Per-agent install

Each agent that uses shared memory gets its own copy:

1. Copy `skill/familiarise/` to that agent's skills directory, for example `~/.claude/skills/familiarise/`.
2. Copy `.env.example` to `.env` beside `SKILL.md`, and set:
   - `SHARED_MEMORY_SKILL_DIR`: this agent's shared-memory skill directory
   - `FRAMEWORK_ENV_DIR`: this agent's token folder, `frameworks/` inside its own familiarise skill directory (for Claude: `~/.claude/skills/familiarise/frameworks`)
   - `AGENT_NAME`: a local label only. The gateway decides identity from the token, so do not guess it. It drives only the mismatch warning in `familiarise`.
3. Keep `.env` mode 600. It is never shipped.
4. Place the constitution block: `scripts/place_snippet.sh [--dry-run] <constitution-file>`. It copies the `CONSTITUTION_SNIPPET.md` block verbatim above the shared-memory block, or at the top when that block is absent. A re-run replaces the block, it never duplicates it. The operator confirms the file before it is written.

The snippet is the prerequisite: it tells an agent that `/familiarise` must run before any shared-memory call, and that a "no framework tunnel" result means not connected.

Installed on this Chromebook: `~/.claude/skills/familiarise/` for Claude (`AGENT_NAME=claude-chromebook`, a label) and `~/.gemini/config/skills/familiarise/` for Gemini (`AGENT_NAME=gemini-chromebook`, a guess). Both labels should be dropped; see the open items.

## Exit codes (`scripts/familiarise.sh`)

- `0`: `.env` copied, or no framework session (nothing changed)
- `1`: session or tunnel not usable. Nothing copied.
- `2`: no token file for this framework. Nothing copied.

## Testing

`tests/fake_ssh.sh` and `tests/fake_gateway.py` stand in for ssh and the gateway, so the lifecycle can be tested on a spare port without touching a live tunnel. Set `FRAMEWORK_TUNNEL_SSH=<path>/fake_ssh.sh`, `FRAMEWORK_TUNNEL_LOCAL_PORT=18888` and `FRAMEWORK_TUNNEL_STATE_DIR=<scratch>`.

Cases that were run and passed on 2026-10-30:

- Tunnel (re-run after the state-file change): start, status during the session, a second start refused, a different host refused, clean exit, stop from another terminal (the session shell gets HUP), a crashed session (`kill -9`) shown as STALE and recovered by the next start, ssh failure, gateway not answering, invalid host, bad action, stop when nothing is open, and start refused while port 8888 is held by something else.
- Familiarise: copy on the happy path (mode 600, byte-identical, no token in output), no session, host mismatch, stale state, no state file, no token file, gateway down, unsaved `.env` preserved, identity warning.

**Not tested:** the real ssh password prompt, and the real workstation gateway. Both need a terminal and the live workstation.

## Known limits

- The session shell is bash. Other shells are not supported.
- Stopping from another terminal ends the session shell with HUP. Unsaved work in that shell is lost.
- `familiarise` checks liveness through the state file and `/health`. It does not check that the token is valid. A bad token shows up when the first search or save fails.

## Shared-memory saves

Saves made from this folder go to the shared-memory project `familiarise`. Use the domain `architecture` for design and architecture facts. Pass `"project":"familiarise"` in the metadata JSON, or leave the client to derive it. The project and the `architecture` section are both registered on the gateway.

## Open items (not done yet)

- Mint a token on each gateway for each local agent. The name it is minted under is that agent's identity (for Claude here, `chromebook-claude`). This needs the operator on each site.
- Token files for the other frameworks. Only `workstation` exists.
- Shared-memory project in this folder. Xenofon asked for it to be created once this folder is in use.
- The `~/framework-tunnel.sh` script is not yet tested with a real ssh prompt.
