# familiarise

Point an agent's shared memory at whichever framework's tunnel is open.

## The problem

An agent's shared memory talks to one framework gateway, and each gateway needs its own token. Open a tunnel to a different framework and the agent still points at the old one, so searches and saves go to the wrong place or fail. Fixing it by hand means finding the right token file, copying it into the skill folder, and risking an existing token being overwritten.

## What the skill does

1. The tunnel script announces the open framework in `~/.config/shared-memory/active-framework`.
2. You run `/familiarise`. The skill checks that the tunnel is alive and the gateway answers.
3. It copies that framework's token file into the shared-memory skill directory.
4. If the current token matches no known framework, it is saved first as `.env-unsaved-<timestamp>`, so nothing is lost.

The skill never opens tunnels, enters passwords or changes the gateway. The operator opens and closes tunnels and manages token files. Agents only check status.

## Repo layout

| Path | Purpose |
|---|---|
| `skill/familiarise/` | The skill, installed into each agent |
| `ops/framework-tunnel.sh` | Tunnel script, source of truth |
| `tests/` | Fake ssh and fake gateway for end-to-end tests |

## Licence

Zero-Clause BSD. See [LICENCE.md](LICENCE.md).
