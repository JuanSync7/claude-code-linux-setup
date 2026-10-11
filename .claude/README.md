# .claude/ — project-level Claude Code assets

*Directory map — one line per entry and where it is documented in full.*

| Entry | What it is |
| --- | --- |
| [`skills/`](skills/README.md) | The maintenance skills any session in this repository can run — see its own map |
| `settings.local.json`, `.cc-writes/`, `scheduled_tasks.lock` | Per-session state, gitignored — never tracked, never shared |

Skills load here because the managed policy leaves project-level skills enabled
([`docs/SETTINGS-REFERENCE.md`](../docs/SETTINGS-REFERENCE.md) §3.4). Their
governing contract is [`docs/OPERATIONS.md`](../docs/OPERATIONS.md) Part 7 —
a skill is a reader of that Part, never a second home for anything in it.
