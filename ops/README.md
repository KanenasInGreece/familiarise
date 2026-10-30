# ops

`framework-tunnel.sh` opens the ssh tunnel to one framework's gateway and announces it in `~/.config/shared-memory/active-framework`.

- **Owner:** the operator (Xenofon). Agents never run `start` or `stop`; they use `status` only.
- **Source of truth:** this folder. Edit `ops/framework-tunnel.sh` here, never `~/framework-tunnel.sh`.
- **Install:** `scripts/sync_local.sh` installs it to `~/framework-tunnel.sh` (backup `~/framework-tunnel.sh.bak-<timestamp>`, atomic replace, safe while a tunnel is open). Use `--dry-run` first.
- **Operator-only:** `start` and `stop` refuse unless stdin is a terminal. This guards against accidents; it is not authentication.
- **Tests:** see `tests/` and the Testing section of `CLAUDE.md`.
