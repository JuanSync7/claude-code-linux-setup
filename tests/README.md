# tests/ — the self-test suite

*Directory map — the suite, the opt-in live harness, and the contract a case in it owes. The scripts'
own exit-code and message contract lives in [`docs/RUNBOOK.md`](../docs/RUNBOOK.md)
§12.2b; this page is about the suite, not about them.*

| File | What it is |
| --- | --- |
| `test-cc-scripts.sh` | Every case, in one file. **CI runs this one file** — a separate test script would lint and never run, which is why `cc-e2e.sh` is opt-in by design rather than by omission. `make test` is the wrapper. **Run as root for the full result**: unprivileged, the root-gated cases skip cleanly, except the `cc-admin-session.sh` gates and the logrotate syntax case, which run as root inside a user namespace (`unshare -r`) where the host allows one. Prints `PASS n FAIL n SKIP n`; compare against the baseline before blaming a change |
| `cc-e2e.sh` | The **live** end-to-end harness, opt-in and **never run by CI**: real `claude -p` sessions, one tool call each, against the policy, checking the side effects - permission denials, tool results, whether a planted marker leaked, new activity-log lines - never the model's wording. `--staged` builds the policy and hooks from this checkout and loads them with `--settings` (not managed); `--installed` uses the host's installed policy. `--profile admin` runs inside an admin session. It spends model tokens (about \$0.015 a profile on haiku, printed at the end; notional on a claude.ai login). Exit 0 all PASS/GAP, 1 any FAIL or INCONCLUSIVE, 2 setup. `--help` lists the options |

## Running it

```bash
bash tests/test-cc-scripts.sh              # every case
bash tests/test-cc-scripts.sh -v           # and print the output of any failure
bash tests/test-cc-scripts.sh --coverage   # which script has which cases
```

**Pass:** exit 0. **Fail:** exit 1, and `-v` prints the captured output of each
failing case. **Exit 2** is a usage error — the same contract the scripts under
test honour (`RUNBOOK.md` §12.2b).

## `--coverage` — the script-to-test map, derived rather than written

There is no hand-maintained coverage table anywhere in this repository, on
purpose. `--coverage` maps every executable shell script in the tree to the
cases that exercise it, reading the suite's own `head2` section markers and
assertion call sites. A table typed out by a person is a second copy of a fact,
and a second copy drifts: a hand-written rule list can advertise a rule nothing
raises and omit one the code does raise.

Attribution follows **what the suite invokes**, not where a line sits: one
section exercises several hooks, so a per-section count would credit each of
them with every case.

It exits **1** when a script has no cases **and** no entry in the suite's
`ACKNOWLEDGED_UNTESTED` list. That list is the point of the mechanism:

> **Untested is allowed. Untested and unremarked is not.** An entry records that
> someone looked and decided, with the reason. Without it, "nobody has tested
> this" and "we decided not to, because the logic is covered elsewhere" are
> indistinguishable — and only one of them is a decision.

Remove an entry when you add the cases. **Do not add one to make `--coverage`
quiet**; that inverts the mechanism into a way of hiding exactly what it exists
to show. CI check **[10]** runs it on every push, so a new script arrives with
cases or with a reason.

`--coverage` is static, so it credits a case by where it **sits**: an assertion
inside `if false`, or in a helper nothing calls, counts. A full run closes that.
Every pass, fail and skip records the line numbers on its call stack in a
ledger, and the run ends with a **COV** verdict. It fails any script none of
whose attributed call sites ran, and reports as a SKIP a script whose only
cases were skipped on this host. `COV1`–`COV5` test the verdict itself on
fixtures.

## What a case owes

1. **Fabricate the condition, then assert the script detects it.** A case that
   only exercises the happy path leaves the branch that matters untested. The
   health check's denominator guard (`USER_COUNT <= 1`) is the example: a
   fixture that inherits the live account population can never reach it, so the
   guard would never run in the suite.
2. **Assert both directions where a false positive costs something.** The secret
   guard blocks tool calls fleet-wide; its allow cases matter as much as its
   deny cases. An alarm that fires on healthy input gets ignored, and that is the
   road back to the original defect.
3. **Assert against what the code actually prints.** Copy the literal out of the
   script. A case that asserts a string the script never prints cannot pass
   however correct the code is.
4. **A condition this host cannot fabricate SKIPs with a stated reason** — never
   a silent pass, and never a failure left to be explained by folklore.
5. **Name the seam the fixture needs.** The scripts take their paths from `CC_*`
   variables so a case can stand in for the host. A seam the harness forgets to
   set does not fail loudly; it quietly tests the live system: an
   account-count assertion then runs against the real home root instead of its
   fixture.

## Parked failures

A case may be expected to fail on one host because of a property of that host
that the case cannot fabricate away. Which cases those are on a given host is a
site fact: it goes in `internal/CURRENT-STATE.md`, each with the property that
makes the case unreachable there. None is parked in this repository.

**A parked failure is a claim and needs the same evidence as any other.** A
failure labelled "environment-explained" that is in fact a test bug stays
unfixed, because the label stops anyone looking at it. Before parking a case, state
which property of the environment makes the case unreachable. If you cannot name
one, it is a defect.

## In CI

The suite is a **gating** job in both CI configs, run as root in a Rocky 8
container, beside `bin/cc-ci-check.sh` (whose check [10] runs `--coverage`). As
root the root-only cases run, and the run-time COV verdict gates too. A
container cannot fabricate some conditions (an AVX-less CPU, a live session on
a real RPM, tcsh); those cases skip with the reason, and the SKIP footer lists
every one.

**A case that runs as root writes only under its own scratch tree** - that is
what makes `sudo bash tests/test-cc-scripts.sh` safe on a governed host. A full
root run in the container changes nothing outside scratch but rpm's `__db`
lock files and dnf's own logs (from `cc-audit.sh`'s read-only `dnf versionlock
list`, which has no seam). I8 applies into the same
rewritten fake-root tree as the IA cases, never over the live `/etc/claude-code`;
A40 reads its repo file through the `CC_REPO_FILE` seam, never from
`/etc/yum.repos.d`. Where a case needs a non-root account as root (an
admin-session invoker, a `CC_REPO_RUNAS`), it uses `SUDO_USER` or, in a
container, a stock system account (`NONROOT` in the suite).

The container baseline is reproducible locally: `podman run` the
`rockylinux:8` image with this tree mounted, install the suite job's `dnf`
line, and run the suite. Rootless podman is close to, not identical to, the
runners' root (H12's `chown` skips under it).
