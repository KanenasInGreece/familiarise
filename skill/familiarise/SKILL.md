---
name: familiarise
description: Use when the user runs /familiarise, or asks to connect shared memory to the framework they opened a tunnel to, or to switch which framework shared memory uses. Links the shared-memory skill's .env to that framework's token file. Do not use for any other memory task.
---

# Familiarise

This skill points the shared-memory skill at the framework whose tunnel is open. The tunnel
announces itself in `~/.config/shared-memory/active-framework`. It only repoints a symlink; it never reads a token. It does not open tunnels, enter passwords or change the gateway.

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
3. Makes `SHARED_MEMORY_SKILL_DIR/.env` a symlink to `FRAMEWORK_ENV_DIR/.env-<framework>`. No token file is
   read, copied or hashed, and no index is kept. The target must be a regular file (not a symlink) that
   resolves to `FRAMEWORK_ENV_DIR/.env-<framework>`.
   - `.env` already links to it: prints "already linked to <framework>", changes nothing.
   - `.env` links elsewhere: the link is replaced.
   - `.env` is a regular file (possibly an unsaved token): it is moved (not copied) to
     `FRAMEWORK_ENV_DIR/.env-unsaved-<YYYYmmdd-HHMMSS>`, mode 600, then linked. If that path exists, refused.
   - `.env` is absent: linked.
   The link is made under a temp name (`.env.link.<pid>`) and renamed over `.env`; the temp link is removed on
   failure or kill. The skill directory must be writable. After linking, `readlink` must show the target.
   A rotated token needs no re-run: the link shows the new bytes.

## Exit codes

- `0`: linked, already linked, or no framework session (nothing changed)
- `1`: any refusal or failure: config missing or incomplete, state file invalid, session ended, or gateway
  silent; token file is a symlink or resolves outside `FRAMEWORK_ENV_DIR`; the skill directory is not
  writable; `.env` is neither a regular file nor a symlink; backup path exists or the move failed; link
  creation or rename failed; verification failed. On a refusal before the backup move, nothing changed.
  Report the message.
- `2`: no token file for this framework. Nothing changed. The operator must add it.

`--version` exits 0. `--update` exits 0 (up to date, or updated) or 1 (no git, no tags, network or clone
failure, symlink or non-regular file in the tag or among the installed files, empty or malformed local VERSION, VERSION mismatch, backup or
install failure; a failed install is rolled back from the backup, and VERSION is installed last). An unknown argument exits 1.

## Rules

- Never print, quote or summarise a token. The script prints the framework name and gateway version only.
- Never `source` a `.env`.
- Do not edit the token files. The operator owns them.
- Report the script's output as it is. If it failed, say why and what the user should do.
  Do not search for another way to connect.
- If the file is absent, tell the user to open the tunnel with `~/framework-tunnel.sh <host>`.
