---
name: estate-status
description: Answer "what is the state of Claude Code?" from the stored weekly reports — read, never re-run. Use when someone asks for the current state, the latest report, whether we can bump, whether there is anything to report to management, or what changed last week. For a fresh full pass instead, use estate-audit.
argument-hint: <optional: a question, or a period like "last month">
---

You are answering a question about the estate from the **stored weekly reports**.
You read; you do not re-derive. `bin/cc-report.sh` already ran every check as
root from a timer, which is the only way the evidence logs are readable at all —
re-running the checks here would produce a second answer that disagrees with the
record, and nobody would know which to trust.

Your contract row is `docs/OPERATIONS.md` §7.2. What the report contains and what
each field means is `docs/REPORTING.md`.

## Run steps

1. **Read `/var/log/claude-code/reports/latest.json`.** `latest.md` is the same
   content as prose if you need to quote it.
2. **Check its currency before answering anything.** If the file is missing, or
   `generated_at` is more than **9 days** old, or `partial` is `true` — **say
   that first and stop.** Offer `estate-audit` for a fresh pass. Never
   substitute a fresh run for a stale record silently: the whole value of the
   record is that it says when it was taken.
3. Confirm the timer is alive: `systemctl list-timers claude-code-report.timer`
   (LAST / NEXT). A stale report with a dead timer is a different problem from a
   stale report with a live one.
4. **Answer the two questions verbatim from the `verdict` fields** —
   `verdict.bump` and `verdict.management`. Do not recompute them. **If your own
   reading of the ledger disagrees with a verdict field, say so explicitly and
   report it as a defect in `cc-report.sh`** — do not quietly override it.
5. Present the ALERT ledger first, ranked ALERT → FYI → SKIP, each with its rule
   id. A SKIP is not a pass: say what could not be answered and why.
6. For "what changed", read the `counts` and `conditions` of the last few report
   JSONs in that directory. Do not recompute a delta from the registers.
7. Cite `internal/CURRENT-STATE.md` and `internal/LIMITATIONS-AND-RISKS.md`
   for findings and risks — **cite, never restate a row**. The registers are the
   authority for their own content.
8. If asked for a period older than the retention window, say so and give the
   oldest report held rather than implying the period is clean.

## What you must not do

- **Do not run** `cc-healthcheck.sh`, `cc-audit.sh`, `cc-bump-audit.sh`,
  `cc-ci-check.sh`, `dnf`, or `rpm`. That is `estate-audit`'s job.
- **Do not re-parse** `/var/log/claude-code/{activity,denied}` — that is
  `log-review`, and it needs root.
- **Do not restate** the finding register, the risk register or the policy.
- **Do not compute your own verdict.** The verdict is a field.
- No `sudo`, no apply, no commit. Agents propose; humans apply
  (`OPERATIONS.md` §7.0).
- If the question needs something the report does not carry, **name the skill
  that owns it** (`estate-audit`, `version-bump`, `fleet-drift`, `log-review`)
  rather than improvising the check here.

## Reporting back

Lead with the two verdicts, then the alerts, then what changed, then what is
owed and to whom. State the report's age in the first line — a reader must never
have to ask how old the answer is.
