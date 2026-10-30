# familiarise

Point an agent's shared memory at whichever framework's tunnel is open.

[Short demonstration](https://github.com/user-attachments/assets/6d568dbd-0fff-4487-8bef-682a4d4d7184)


## The problem

An agent's shared memory talks to one framework gateway, and each gateway needs its own token. Open a tunnel to a different framework and the agent still points at the old one, so searches and saves go to the wrong place or fail. Fixing it by hand means finding the right token file and pointing the shared-memory `.env` at it, with the risk of overwriting the token already there.  This is a Linux shell script, wrapped in a skill agents can use to point their shared memory skill to a different back end.  It is a helper skill for [Shared Memory](https://github.com/KanenasInGreece/Shared_Memory).

## What the skill does

1. The tunnel script announces the open framework in `~/.config/shared-memory/active-framework`.
2. You run `/familiarise`. The skill checks that the tunnel is alive and the gateway answers.
3. It links the shared-memory skill's .env to that framework's token file (a symlink; no token is read or copied).
4. If the current `.env` is a regular file (not a link), it is moved first to `frameworks/.env-unsaved-<timestamp>`, so nothing is lost.

The skill never opens tunnels, enters passwords or changes the gateway. The operator opens and closes tunnels and manages token files. Agents never start or stop tunnels; they link to an open one and check status.

## Requirements

Linux. Needs bash, ssh, curl, git, GNU coreutils and flock (util-linux).

## Repo layout

| Path | Purpose |
|---|---|
| `skill/familiarise/` | The skill, installed into each agent |
| `ops/framework-tunnel.sh` | Tunnel script, source of truth |
| `tests/` | Fake ssh and fake gateway for end-to-end tests |

## Licence

Zero-Clause BSD. See [LICENCE.md](LICENCE.md).
