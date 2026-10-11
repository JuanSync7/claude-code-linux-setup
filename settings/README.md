# settings/ — the policies

*Directory map — one line per file. Every key is documented in
[`docs/SETTINGS-REFERENCE.md`](../docs/SETTINGS-REFERENCE.md); this directory
holds the files themselves.*

| File | What it is |
| --- | --- |
| `managed-settings.json` | **The live fleet policy — this file IS what gets deployed** to `/etc/claude-code/managed-settings.json` by `cc-install.sh --apply` / `make quickstart`. Deny rules, hooks, status line, version floor. Deliberately never generated from `config.sh`: an operator must be able to read the literal effective value, and the installer refuses a placeholder. A site's repository holds it concrete; the public template edition holds listed placeholders until a site fills them ([`docs/PUBLISHING.md`](../docs/PUBLISHING.md) §1) |
| `managed-settings-admin.json` | The privileged-session policy (a much shorter deny list), placed to `/etc/claude-code-admin/` **only** by `--with-admin` and bind-mounted over the fleet policy for one process tree ([`docs/ADMIN-SESSION.md`](../docs/ADMIN-SESSION.md)) |

`_comment_*` keys are commentary, not policy — the installer ignores them, so
they can go stale; the keys themselves are the record. **Do not add a third policy variant** —
per-host differences belong in `config.sh`, not here.
