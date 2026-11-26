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
familiarise: gateway:   localhost:8888 health status ok, version 1.0.39
```

The script does not judge the health status. Any `/health` reply with a status (`ok`, `degraded`, or other) links the framework and prints that status. A silent gateway, or a reply with no status, refuses.

After linking, if the status is not `ok`, run the shared-memory doctor to see which backend is down:

```bash
uv run --with httpx python <shared-memory-dir>/scripts/memory_bridge.py doctor
```

`<shared-memory-dir>` is the shared-memory skill directory (the `SHARED_MEMORY_SKILL_DIR` setting in this skill's `.env`; read that one value, never the token). A degraded framework can still work, so a non-ok status is not a failed link.

`--version` prints the installed version.

## Citing records

Record ids (`fact:N`, `decision:N`, `retrospective:N`) are numbered per framework store, so the same id can be a different record on another framework. The link output puts this rule into context: every record saved from then on belongs to the linked framework. Cite records as `<host> fact:N`, and add `"framework": "<host>"` to the metadata JSON when you save.

Retrieval goes to whichever tunnel is open, with the linked token. If the tunnel is down, or the token does not match the open gateway, the search fails. A failed search means the framework is not connected: say so, and do not answer from memory.

The file `<this-skill-dir>/frameworks/linked` names the last framework linked. It stays after the tunnel closes, so use it only to qualify citations.

## Outcomes

| Exit | Situation | Tell the user |
|---|---|---|
| 0 | Linked, or already linked to that framework | The framework name and the gateway line. If the output says `saved the previous .env to <path>`, also give that path: the user's unsaved token is there. |
| 0 | No tunnel open (no state file). Nothing changed | Open the tunnel with `~/framework-tunnel.sh <host>`, then run this again. |
| 1 | Refused or failed (includes a gateway that gives no `/health` reply with a status) | The message as printed. Only a message starting `The previous .env token is at <path>` means the token is at that path. Any other message means `.env` still holds the token, or nothing changed: do not name a backup path as the token's location. |
| 2 | No token file for this framework. Nothing changed | The operator must add `frameworks/.env-<framework>`. |
| 143 | Killed by a signal. The temp link is removed | The message as printed, including any "token is at" path. |

## Rules

- Never print, quote or summarise a token. Never `source` a `.env`. Do not edit token files; the operator owns them.
- Do not run `start` or `stop` on the tunnel script. They need a terminal for the ssh password prompt, so only the operator runs them. Agents may run `status`.
- When the script fails, report why and what the user should do. Do not look for another way to connect: the tunnel is the control, and a workaround would skip it.

## Update

```bash
bash <this-skill-dir>/scripts/familiarise.sh --update
```

Installs the newest `vX.Y.Z` tag of the repo. It backs up the current files to `.backup/` and verifies the backup, then replaces only `SKILL.md`, `VERSION` and `scripts/*`. A failed install is rolled back. It never touches `.env` (the shared-memory link), `frameworks/` or `~/framework-tunnel.sh`. The tunnel script is installed from the repo by `scripts/sync_local.sh`, which runs only in the operator's local checkout. Exit 0 means up to date or updated. Exit 1 means the message says why; report it. Exit 143 means a signal stopped the update. A signal during the install is not rolled back, so the files can be mixed until you run `--update` again, which backs up and installs the release again.

## Design detail

The script header holds the mechanics: the state file, the link and its verification, the lock, the backup move, and every exit code. Read it when debugging. You do not need it to run the skill.

Settings come from a `.env` beside this file (the skill's own config, not the shared-memory link). `--update` needs none.

Requirements: Linux, with bash, curl, git, `cmp` (diffutils), `flock` (util-linux) and GNU coreutils (`readlink -f`, `mv -T`, `mv -n`, `sort -V`).
