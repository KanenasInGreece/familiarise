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

## What it does

1. Reads `~/.config/shared-memory/active-framework`. The tunnel script writes it while the tunnel is open,
   and removes it when the tunnel closes.
   - Absent: nothing is changed. Say so and stop.
2. Checks that the session named in the file is still running and that `localhost:8888/health` answers.
3. Copies `FRAMEWORK_ENV_DIR/.env-<framework>` over `SHARED_MEMORY_SKILL_DIR/.env`.
   If the current `.env` matches no framework file, it is saved first as `.env-unsaved-<timestamp>`.

## Exit codes

- `0`: copied, or no framework session (nothing changed)
- `1`: the session or tunnel is not usable. Nothing was copied. Report the message.
- `2`: no token file for this framework. Nothing was copied. The operator must add it.

## Rules

- Never print, quote or summarise a token. The script prints the identity only.
- Never `source` a `.env`.
- Do not edit the token files. The operator owns them.
- Report the script's output as it is. If it failed, say why and what the user should do.
  Do not search for another way to connect.
- If the file is absent, tell the user to open the tunnel with `~/framework-tunnel.sh <host>`.
