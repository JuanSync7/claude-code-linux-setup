# hooks/ — the managed policy's hooks

*Directory map — one line per file and where it is documented in full.*

Installed to `/usr/local/sbin`, **0755 root:root** — they run as the engineer,
inside the session, invoked by the `hooks[]` blocks of
[`settings/managed-settings.json`](../settings/managed-settings.json). Tighten
the mode and they silently stop: a missing or unrunnable hook is a
**non-blocking** error — the tool call proceeds unaudited with only a
transcript warning. Only a hook's own exit 2 blocks. Contract and walkthrough:
[`docs/QUICKSTART.md`](../docs/QUICKSTART.md) §3, [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §11.7,
[`docs/SETTINGS-REFERENCE.md`](../docs/SETTINGS-REFERENCE.md) §3.7.

| File | Event | Role |
| --- | --- | --- |
| `cc-audit-hook.sh` | PreToolUse (Bash, Edit, Write, WebFetch) | **Evidence** — one JSON line per call to `/var/log/claude-code/activity/<user>.jsonl`; call shape, never contents |
| `cc-secret-guard-hook.sh` | PreToolUse (Read, Edit, Write, NotebookEdit) | **Enforcement** — exit 2 on credential-shaped target basenames |
| `cc-denied-hook.sh` | PermissionDenied | **Evidence** — the denial record; sole source for the quarterly allow-list review |
| `cc-upgrade-guard-hook.sh` | PreToolUse (Bash) | **Signpost** — exit 2 on self-update attempts (`claude update`, npm sideload, vendor installer, package-manager transaction verbs on `claude-code`), pointing at the version-bump procedure instead of a bare denial. Package-manager **queries** (`list`, `info`, `check-update`, `repoquery`) pass — the bump procedure runs them |
| `cc-redact-hook.sh` | PostToolUse (every tool) | **Enforcement** — replaces credential-shaped text in a tool's *output* (keys, fixed-prefix tokens, JWTs, URL passwords, and their base64/hex copies) before the model sees it; logs kind and count, never the text. Fails closed when its scan raises. Shape-matching only — see its header for what it does not catch |

The loggers `umask 077`: the log directories' `1733` stops listing, not reading —
file mode 0600 is what keeps one engineer's history from another. The upgrade
guard writes nothing.
