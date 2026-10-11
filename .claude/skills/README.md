# .claude/skills/ — the maintenance skills

*Directory map — one line per skill and where its procedure lives. Not a
second home for any fact: the `version-bump` skill executes
[`docs/OPERATIONS.md`](../../docs/OPERATIONS.md) §7.1 step by step; the
standing audits each carry their **own** run steps (the skill body is those
steps' one home) under their §7.2 contract row. No skill holds a copy of
anything written in Part 7.*

Nobody needs a skill's name: descriptions are matched semantically, so
"upgrade Claude Code to 2.1.x" or "run the full estate audit" said in plain
words invokes the right one. `/<name>` works too.

| Skill | Executes | One line |
| --- | --- | --- |
| [`version-bump/`](version-bump/SKILL.md) | §7.1 | The whole bump: audit script, four analysis lanes, the `UPGRADES.md` entry; prints the sudo steps for a human |
| [`settings-review/`](settings-review/SKILL.md) | §7.2 | Quarterly settings sweep: new vendor keys into `SETTINGS-REFERENCE.md` §6 with suggested positions |
| [`repo-audit/`](repo-audit/SKILL.md) | §7.2 | Are the documents still true? The judgment layer above `cc-ci-check.sh` |
| [`fleet-drift/`](fleet-drift/SKILL.md) | §7.2 | Deployed hosts vs this checkout; remedies always via §1.12 |
| [`log-review/`](log-review/SKILL.md) | §7.2 | Activity/denial log summary — output to `internal/` only |
| [`estate-status/`](estate-status/SKILL.md) | §7.2 | Answers "what is the state?" from the STORED weekly report — reads, never re-runs. Refuses to answer from a record more than 9 days old without saying so |
| [`estate-audit/`](estate-audit/SKILL.md) | §7.2 | The master: every child as a subagent, one synthesised report, owns no content |

The rules all seven obey — agents propose, humans apply; findings to
`internal/`; sections are an interface — are §7.0's, stated once there.
