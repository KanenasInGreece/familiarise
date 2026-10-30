---
name: familiarise
description: Use when the user runs /familiarise, or asks to connect shared memory to the framework they opened a tunnel to, or to switch which framework shared memory uses. Copies that framework's token file into the shared-memory skill directory. Do not use for any other memory task.
---

# Familiarise

This skill points the shared-memory skill at the framework whose tunnel is open. The tunnel
announces itself in `~/.config/shared-memory/active-framework`. It only copies a token file. It does not open tunnels, enter passwords or change the gateway.

## Run it

```bash
bash <this-skill-dir>/scripts/familiarise.sh
```

`<this-skill-dir>` is the directory that contains this file. The script reads its settings from
`.env` beside this file.

```bash
bash <this-skill-dir>/scripts/familiarise.sh --version   # prints "familiarise <version>"
bash <this-skill-dir>/scripts/familiarise.sh --update    # install the newest tagged release
```

`--update` needs no `.env`. It reads the newest `vX.Y.Z` tag of `FAMILIARISE_REPO` (default
`https://github.com/KanenasInGreece/familiarise.git`), never downgrades, backs up to
`.backup/<version>-<timestamp>/` (verified), then replaces only `SKILL.md`, `CONSTITUTION_SNIPPET.md`,
`VERSION` and `scripts/*`. It never touches `.env` or `frameworks/`, nor `~/framework-tunnel.sh`
(use `scripts/sync_local.sh` for that). Without a `VERSION` file the version is `0.1.0`; a `VERSION`
that is empty or not `X.Y.Z` is an error.

Requirements: Linux. Needs bash, ssh, curl and git.

## What it does

1. Reads `~/.config/shared-memory/active-framework`. The tunnel script writes it while the tunnel is open,
   and removes it when the tunnel closes.
   - Absent: nothing is changed. Say so and stop.
2. Checks that the session named in the file is still running and that `localhost:8888/health` answers.
3. Copies `FRAMEWORK_ENV_DIR/.env-<framework>` over `SHARED_MEMORY_SKILL_DIR/.env`.
   Before overwriting a different `.env`, it hashes only that `.env` and looks the hash up in
   `frameworks/.index` (mode 600, lines `<sha256>  .env-<host>`, hashes only, written atomically on each copy).
   No other token file is read. If the hash is not in the index (no index, or a token that predates it),
   the current `.env` is saved first as `.env-unsaved-<timestamp>`.

## Exit codes

- `0`: copied, or no framework session (nothing changed)
- `1`: not usable: config missing or incomplete, state file invalid, session ended, or gateway silent;
  or the existing `.env` could not be backed up (backup path exists, or the backup failed its check).
  Nothing is copied. (A failed copy or copy check also exits 1, after the backup.) Report the message.
- `2`: no token file for this framework. Nothing was copied. The operator must add it.

`--version` exits 0. `--update` exits 0 (up to date, or updated) or 1 (no git, no tags, network or clone
failure, symlink or non-regular file in the tag or among the installed files, empty or malformed local VERSION, VERSION mismatch, backup or
install failure; a failed install is rolled back from the backup, and VERSION is installed last). An unknown argument exits 1.

## Rules

- Never print, quote or summarise a token. The script prints the identity only.
- Never `source` a `.env`.
- Do not edit the token files. The operator owns them.
- Report the script's output as it is. If it failed, say why and what the user should do.
  Do not search for another way to connect.
- If the file is absent, tell the user to open the tunnel with `~/framework-tunnel.sh <host>`.
