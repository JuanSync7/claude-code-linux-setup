---
name: version-bump
description: Run the Claude Code version bump for this deployment. Use when the user asks to upgrade, update, bump, move or pin the Claude Code version, mentions a new claude-code release, or asks what a new version would change. Executes the analysis and record; prints the privileged steps for a human.
argument-hint: <target-version, e.g. 2.1.240>
---

You are executing the version-bump procedure. The procedure is
`docs/OPERATIONS.md` **Part 7, §7.1** — read it now and follow its six steps
exactly, with §7.0's ground rules binding throughout (agents propose, humans
apply; findings quoting anything live go to `internal/`). The record you
produce follows the entry contract at the top of `docs/UPGRADES.md`.

What this skill adds to §7.1 — nothing but execution discipline:

- Treat every script exit code in the procedure as a gate, not a suggestion.
- Run the step-3 analysis lanes as parallel subagents; apply their findings
  yourself in reviewable commits.
- At the step where privileged commands appear, print them and stop until the
  user confirms a human ran them in a real terminal.

Report back with: the audit result, each lane's material findings, the drafted
entry, and the exact human steps that remain.
