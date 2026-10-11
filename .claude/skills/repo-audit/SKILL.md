---
name: repo-audit
description: Audit this repository's documents against reality. Use when the user asks whether the docs are still true, to check documentation drift, to verify the repo is consistent, or after a large structural change.
---

You are executing the repo audit. The contract is `docs/OPERATIONS.md`
**Part 7, §7.2** (the `repo-audit` row). CI already holds the mechanical
invariants (links resolve, files are documented, JSON parses — `bin/cc-ci-check.sh`);
your job is the judgment layer CI cannot do: **is what the documents claim
still true?**

Run these as parallel subagents, each returning findings:

1. **Directory maps** — every `*/README.md` map against its directory's actual
   contents and each file's one-line description. A stale description is a
   finding; CI only catches a missing name.
2. **Host claims** — run both, read-only, and compare their output against what
   `docs/RUNBOOK.md` and `internal/CURRENT-STATE.md` claim about this host.
   **Both need a writable output path**, or the first line of your "audit" is a
   permission error and the rest is missing:

   ```bash
   CC_REPORT=/tmp/hc-$$.log bash bin/cc-healthcheck.sh
   bash bin/cc-audit.sh /tmp/audit-$$.txt
   ```

   **From a `claude-admin` session, lane 2 is not valid for the policy.** The
   fleet policy path is bind-mounted to the admin policy there, so `cc-audit.sh`
   describes the admin policy's short deny list, not the fleet's. It says so in
   its own header — read that line before comparing anything policy-shaped, and run
   this lane from a plain session when it appears.
3. **Register triggers** — every row in `internal/LIMITATIONS-AND-RISKS.md`
   and finding in `internal/CURRENT-STATE.md` whose stated review trigger or
   date has fired.
4. **Style drift** — the `docs/DOC-STYLE.md` §8 checklist greps (changelog
   voice, wrong-value-beside-correction) across `docs/` and `README.md`.

Then: fix what is mechanical yourself in a reviewable commit (stale one-liners,
style hits); file what needs a decision as findings to `internal/` and surface
them to the user.

`CURRENT-STATE.md` is the authority for state, so when a document disagrees with
it, the document is normally what you fix. **The exception, and it matters: a
fact you have just OBSERVED on the host outranks both.** A register goes
stale like any other document: it can name a version the host has moved past, or
call a peer host powered off while it answers on tcp/22. When your
measurement and the register disagree, the register is the finding: correct it,
say what you measured and how, and do not "fix" a correct document to match it.

Report back with: fixes committed, findings filed, decisions owed.
