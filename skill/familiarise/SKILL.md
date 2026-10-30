---
name: familiarise
description: Use when the user runs /familiarise, asks to connect shared memory to the framework whose tunnel they just opened, asks to switch shared memory to another framework, or asks to update the familiarise skill. Links the shared-memory skill's .env to that framework's token file. Do not use for any other memory task, such as search, save or lineage.
---

# Familiarise

Points the shared-memory skill at the framework whose tunnel is open. It changes one symlink. If a plain `.env` file is there, it is moved aside, never deleted. It never reads, copies or prints a token, and it never opens a tunnel, enters a password or changes the gateway.

## Connect

Run the script and report its output as printed:

```bash
bash <this-skill-dir>/scripts/familiarise.sh
```

`<this-skill-dir>` is the directory that contains this file. A successful link prints lines like these (paths and version differ):

```
familiarise: framework: workstation
familiarise: linked: <...>/shared-memory/.env -> <...>/frameworks/.env-workstation
familiarise: gateway:   localhost:8888 answers, version 1.0.39
```

`--version` prints the installed version.

## Outcomes

| Exit | Situation | Tell the user |
|---|---|---|
| 0 | Linked, or already linked to that framework | The framework name and the gateway line. |
| 0 | No tunnel open (no state file). Nothing changed | Open the tunnel with `~/framework-tunnel.sh <host>`, then run this again. |
| 1 | Refused or failed. Nothing changed, or the message names a backup path | The message as printed. If it names a `.env-unsaved-` path, the token is there. |
| 2 | No token file for this framework. Nothing changed | The operator must add `frameworks/.env-<framework>`. |
| 143 | Killed by a signal. The temp link is removed | The message as printed. |

## Rules

- Never print, quote or summarise a token. Never `source` a `.env`. Do not edit token files; the operator owns them.
- Do not run `start` or `stop` on the tunnel script. They need a terminal for the ssh password prompt, so only the operator runs them. Agents may run `status`.
- When the script fails, report why and what the user should do. Do not look for another way to connect: the tunnel is the control, and a workaround would skip it.

## Update

```bash
bash <this-skill-dir>/scripts/familiarise.sh --update
```

Installs the newest `vX.Y.Z` tag of the repo. It backs up the current files to `.backup/` and verifies the backup, then replaces only `SKILL.md`, `VERSION` and `scripts/*`. A failed install is rolled back. It never touches `.env`, `frameworks/` or `~/framework-tunnel.sh`, which `scripts/sync_local.sh` updates in the source repo. Exit 0 means up to date or updated. Exit 1 means the message says why; report it.

## Design detail

The script header holds the mechanics: the state file, the link and its verification, the lock, the backup move, and every exit code. Read it when debugging. You do not need it to run the skill.

Requirements: Linux, with bash, ssh, curl and git.
