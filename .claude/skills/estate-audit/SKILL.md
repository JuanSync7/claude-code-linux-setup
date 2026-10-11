---
name: estate-audit
description: Run the full estate audit - every standing maintenance check in one pass. Use when the user asks for the full audit, a complete health review of the deployment, or to check everything.
---

You are executing the estate audit — the master run. The contract is
`docs/OPERATIONS.md` **Part 7, §7.2** (the `estate-audit` row), and its one
architectural rule binds you: **this run owns no content**. Every check
belongs to a child skill; you sequence, collect and synthesise.

Do exactly this:

1. Spawn the children in **this** order, because their targets DO overlap and
   the safe parallel set is smaller than it looks:

   | Wave | Children | Why together, or why alone |
   | --- | --- | --- |
   | 1 | `log-review` **and** `fleet-drift`, in parallel | Read-only, and they write to different files under `internal/`. Neither commits |
   | 2 | `repo-audit`, **alone** | The first child that COMMITS. Its DOC-STYLE sweep covers all of `docs/`, which includes the file the next child rewrites |
   | 3 | `settings-review`, **alone** | Commits `SETTINGS-REFERENCE.md` §6 |

   **Never run `repo-audit` and `settings-review` concurrently.** Both commit,
   both touch `docs/SETTINGS-REFERENCE.md`, and two `git commit` runs in one
   checkout collide on `.git/index.lock` — whichever wins stages the other's
   half-finished edits. This checkout is shared with colleagues' sessions too,
   so that risk is not confined to your own children.

   Waves 1 and 2 also feed wave 3: `log-review`'s denial classification is an
   input to the §4.2 allow-list review that `settings-review` performs, and
   `repo-audit`'s corrections land before `settings-review` edits the same file.

   Each subagent invokes its skill and returns that skill's report shape —
   nothing else. `version-bump` is deliberately **not** a child: it is §7.1, it
   moves a pin, and it is never part of a read-only audit.
2. Do not re-run, second-guess or extend a child's checks inline. If a child's
   report looks wrong, re-run that child; if a check is missing from every
   child, that is a finding about Part 7 itself — file it, do not improvise
   the check here.
3. Synthesise one report: per child, the material findings; across children,
   anything that compounds (a settings key flagged `decide` **and** a denial
   pattern touching it is one story, not two).
4. Group-sensitive material stays where the children put it (`internal/`).
   The synthesis may cite those files; it may not quote them into anything
   that ships.

Report back with: one section per child (outcome + material findings, each
citing the child's fuller output), the compound findings, and the decisions
owed with your recommendation — humans apply, per §7.0.
