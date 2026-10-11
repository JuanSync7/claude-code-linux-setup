# share/ — session-facing assets

*Directory map — one line per file and where it is documented in full.*

Installed to `/usr/local/share/claude-code/` (0755 root:root, **local disk,
never NFS** — these run on every prompt render or session start).

| File | What it is |
| --- | --- |
| `statusline.sh` | The fleet status line, referenced by the managed `statusLine` key — one global copy, editing it changes the default for every session at once. A user's own `~/.claude/statusline.sh` replaces it. [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §7.7, [`docs/SETTINGS-REFERENCE.md`](../docs/SETTINGS-REFERENCE.md) §3.9 |
| `cc-vscode-claude-wrapper.sh` | The IDE wrapper: points the VSCodium Claude extension at the pinned CLI instead of the copy the extension bundles. Seeded via `--with-ide`; a user *can* undo it, which is an accepted risk. [`docs/IDE-INTEGRATION.md`](../docs/IDE-INTEGRATION.md) |
