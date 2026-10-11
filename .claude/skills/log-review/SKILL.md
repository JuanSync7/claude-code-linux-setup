---
name: log-review
description: Summarise the Claude Code activity and denial logs for anomalies. Use when the user asks to review the logs, check what sessions have been doing, run the monthly log review, or investigate denied tool calls.
---

You are executing the log review. The contract is `docs/OPERATIONS.md`
**Part 7, §7.2** (the `log-review` row); how to read the logs and what they
deliberately do not contain is `docs/RUNBOOK.md` §11.7.

Boundaries before anything else:

- Output goes to **`internal/` only** — command shapes reveal project names,
  tool stacks and working patterns. Never quote log lines into `docs/`, a
  commit message, or anything that ships.
- The logs are `0600` per user **inside `1733` directories**, by design. That
  second half matters more than the first: you cannot *list* the directory, so a
  `glob` over it returns an EMPTY LIST and any summariser built on that prints
  nothing and exits 0 — indistinguishable from a quiet week. `OPERATIONS.md`
  §4.2's snippet has exactly that shape; run it under `sudo`, or say plainly
  that you saw only your own file.

  ```bash
  . /etc/claude-code/cc-config.sh                   # this site's paths (QUICKSTART.md §9)
  sudo ls "$CC_DENIED_LOG_DIR"/                     # the only way to enumerate
  cat "$CC_DENIED_LOG_DIR/$(id -un).jsonl"          # your own, by exact path
  ```

  Reading a colleague's log needs root: ask the operator to run the collection
  step and hand you the material; do not escalate. **Always report the
  denominator** — "1 of N accounts' logs were readable" is a fact about the run,
  and without it a partial review reads as a clean one.
- Log **contents were never recorded** — only call shapes. Do not present an
  absence in the log as an absence of activity (subprocess file access was
  never visible to the hooks; the README's ceiling statement applies).

Then, over what is readable:

1. `/var/log/claude-code/denied/` — every denial: which rule, which user, any
   repeat pattern. Repeated denials of the same command are either an attack
   surface probe or a missing legitimate allowance — classify each, and feed
   the §4.2 allow-list review.
2. `/var/log/claude-code/activity/` — volume and shape outliers only: bursts,
   odd hours, tools that never appeared before. Not a content review.
3. Cross-check: any denial with no matching activity-log context, and whether
   the **headless caveat** could explain it — a permission-rule denial inside
   `claude -p` writes nothing at all (probe **M5**). Cite the caveat, not a
   hook failure: the hook fires interactively, and only the headless path is
   silent.
4. **Check whether the denial reason is still legible.** Every record carries
   `denied_by`, and the useful values name a category. If a run finds records
   whose reason is only the opaque literal `Blocked by classifier`, count them
   SEPARATELY and report the count: those cannot be triaged by reason at all,
   only by inspecting `detail`. An estate's only triage field going blind is a
   finding about the product, not a quiet week.

Report back with: a summary written to `internal/`, the anomaly list with your
classification, and any allow-list change worth proposing (proposal only —
policy changes go through `SETTINGS-REFERENCE.md` §2.1, run by a human).
