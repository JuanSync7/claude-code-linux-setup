# systemd/ — units, limits, and log rotation

*Directory map — one line per file and where it is documented in full.*

| File | Installs to | What it is |
| --- | --- | --- |
| `claude-code-healthcheck.service` + `.timer` | `/etc/systemd/system/` | The daily drift check — runs `cc-healthcheck.sh` from `/usr/local/sbin` with no repo present; a non-zero exit marks the unit failed so `systemctl --failed` surfaces it. [`docs/OPERATIONS.md`](../docs/OPERATIONS.md) §4.1 |
| `claude-code-report.service` | `/etc/systemd/system/` | The weekly estate report; oneshot, runs as root because the evidence logs are unreadable otherwise. Exit 1 = alerts exist |
| `claude-code-report.timer` | `/etc/systemd/system/` | `Mon 07:30`, `RandomizedDelaySec=20m`, `Persistent=true`. After the health check and the version watch, so three failed units are distinguishable by timestamp |
| `claude-code-version-watch.service` | `/etc/systemd/system/` | Weekly version watch; oneshot. Exits 1 when a version above the pin exists, which marks the unit failed on purpose |
| `claude-code-version-watch.timer` | `/etc/systemd/system/` | `Mon 07:15`, `RandomizedDelaySec=30m`, `Persistent=true`. Offset from the 06:30 health check so two failed units are distinguishable |
| `claude-code-logrotate` | `/etc/logrotate.d/claude-code` | Rotation for **`healthcheck.log` and `update.log`** (weekly, `rotate 26`) **`audit-*.txt`** and **`admin.log`** (monthly, `rotate 24`; `reports/` is pruned by `cc-report.sh` instead), and the **`activity/` and denial JSONL logs** (weekly, `rotate 52`, `copytruncate` — the hooks append as the engineer into per-user `0600` files, so `create` would hand each rotated file to root and silently stop the audit trail; the file's own header explains it at length). [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §11 capacity table |
| `user-.slice.d/50-claude-code.conf` | `/etc/systemd/system/user-.slice.d/` | Per-user resource limits. **`TasksMax=12288` is the only directive**, valid on cgroup v1 and v2 alike; the file's own header comment is the ground truth for why CPU, memory and I/O limits were removed. Applies to everything a user runs, not just Claude Code — size any limit added here for the whole login, not for one tool |
