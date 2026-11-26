# ops

`framework-tunnel.sh` opens the ssh tunnel to one framework's gateway and announces it in `~/.config/shared-memory/active-framework`.

- **Owner:** the operator. Agents never run `start` or `stop`; they use `status` only.
- **Source of truth:** this folder. Edit `ops/framework-tunnel.sh` here, never `~/framework-tunnel.sh`.
- **Install:** `scripts/sync_local.sh` (local checkout only) installs it to `~/framework-tunnel.sh` (backup `~/framework-tunnel.sh.bak-<timestamp>`, atomic replace, safe while a tunnel is open). Use `--dry-run` first.
- **Operator-only:** `start` and `stop` refuse unless stdin is a terminal. This guards against accidents; it is not authentication.
- **Tests:** `tests/test_link.sh` and `tests/test_update.sh`. They use scratch dirs and a spare port, never the real state dir or port 8888.
