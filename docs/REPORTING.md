# Reporting and metrics — the weekly report, the version watch, and what a monitoring system can read

| | |
| --- | --- |
| **What** | The reporting interface of this control plane: what the weekly report contains and where it is stored, what the version watch answers, every rule that can raise an alert, and what a Prometheus-style scrape would find. Plus what none of them are permitted to do |
| **Who** | Whoever operates the governed hosts, and whoever operates monitoring — they may be two different teams, which is why the contract is written down rather than assumed. No prior knowledge of this repository, of systemd timers, or of a Prometheus textfile collector is assumed |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and [`UPGRADES.md`](UPGRADES.md) records every move of it |
| **Where** | Governed hosts built with `bin/cc-install.sh --apply`. **Not** `make quickstart`, which places governance only ([`QUICKSTART.md`](QUICKSTART.md)), and not the AWS per-user VDI, where one report per single-user instance is a different design ([`LOCAL-VS-AWS.md`](LOCAL-VS-AWS.md)) |
| **Why** | The procedures live in [`OPERATIONS.md`](OPERATIONS.md) and the reasons in [`RUNBOOK.md`](RUNBOOK.md), but a *contract another team builds alerts on* needs a lookup home that a runsheet cannot give it. This is the one page all three point at |
| **Status** | **In force on every host where `cc-install.sh --apply` has run: all three timers are enabled and §1's cadence is the schedule.** Scripts placed by hand, or by `make quickstart`, have no cadence at all. Two limits hold everywhere: the weekly units report on their own next fire, so "enabled" and "has produced a report" are separate questions worth asking separately; and **the metrics half has no consumer** — every health-check run renders it to `CC_METRICS_FILE`, but this repository installs no exporter and no scrape, and on a host where the textfile directory is absent §6 writes nothing. The live per-host answer is `internal/CURRENT-STATE.md`, never this row |
| **Owner** | The maintainer |

---

## 1. What runs, when, and what it writes

| | Weekly report | Version watch |
| --- | --- | --- |
| Script | `bin/cc-report.sh` → `/usr/local/sbin` | `bin/cc-version-watch.sh` → `/usr/local/sbin` |
| Timer | `claude-code-report.timer`, Mon 07:30 (+20m jitter) | `claude-code-version-watch.timer`, Mon 07:15 (+30m jitter) |
| Runs as | root, from the timer | root from the timer; anyone by hand |
| Writes | `/var/log/claude-code/reports/` | `/var/log/claude-code/version-watch.json` |
| Exit 0 | ran, no alerts | nothing above the pin |
| Exit 1 | ran, **at least one alert** | **a version above the pin exists** |
| Exit 2 | usage error | usage error |
| Exit 3 | **could not complete** — no report written | **could not tell** — no pin, no repository answer, or stale metadata |

Both use a non-zero exit to mark their unit failed, which is what makes
`systemctl --failed` a notice board without any monitoring glue. Both inherit the
same gap: **a failed unit reports to nobody until somebody attaches a route**.
Each unit file carries a commented `OnFailure=` line as the place
to attach one; neither ships a mailer, because delivery is a network write with a
named owner and this repository proposes rather than applies.

### Why the report runs as root

Not a preference — the material is unreadable otherwise, and half-readable is
worse than nothing:

- the activity and denial logs are `0600` per user inside `1733` directories, so
  an ordinary user cannot even *list* them;
- `healthcheck.log` is `0640 root:root`;
- probe **A5** cannot see a home whose `~/.local` is `0700`, and probe **A8**
  cannot see another user's processes.

An unprivileged run still works and is still useful. It simply says, in section
11, exactly which collectors it could not run — it never reports "clean" about
something it could not read.

---

## 2. Where the reports live, and who can read them

```
/var/log/claude-code/reports/          2750 root:<group>
  report-YYYYMMDD-HHMMSS.md            0640 root:<group>
  report-YYYYMMDD-HHMMSS.json          0640 root:<group>
  latest.md  latest.json               0640 root:<group>   (copies, not symlinks)
  state.json                           0640 root:<group>   (the delta baseline)
```

**Group-readable, world-blind.** `<group>` is the repository group (`CC_REPO_GROUP`
in `config.sh`). A member of it — and an agent session running as one — reads the report with no `sudo`; the world cannot list the
directory. That matters because the report quotes command shapes and finding
text, which is group-only material for the same reason `internal/` never ships.

**If the group does not resolve on the host** — a group that is local to one
host resolves on no other — the directory is created `0700 root:root` and the
report says so in its own ledger. It never falls back to world-readable.

**Retention is the script's own job, not logrotate's.** `--keep` (default **52**,
one year) prunes `report-*` pairs *after* a successful run, so a failed run
cannot delete history; `latest.*` and `state.json` cannot match the prune pattern
by construction. logrotate is deliberately not used here: its model is an open,
appended file, and applied to timestamped artefacts it leaves a zero-byte
tombstone under the original name.

**A partial run (`--section` / `--skip-section`) never updates `latest.*` or
`state.json`**, and says `PARTIAL` in its header. A selective pass is not a pass —
the same doctrine as `CC_CI_ONLY`.

---

## 3. The two verdicts

At the top of every report, and as fields in the JSON:

```
BUMP: ok to plan                 |  BUMP: hold — POL-02 INS-01
REPORT TO MANAGEMENT: no major errors flagged
                                 |  REPORT TO MANAGEMENT: 2 alert(s) need a named owner before this is reportable
```

Both are **derived from the ledger, not written by hand**, and a reader should
take them verbatim rather than re-deriving them. `BUMP: hold` fires when any
alert is in a class that makes a version move unwise — deployed-vs-repository
drift, a probe that regressed, a red CI, a version state that could not be read,
or a private install below the floor (bumping again strands that colleague
further; `OPERATIONS.md` §3.4 makes notification a precondition).

**If your reading of the ledger disagrees with a verdict, that is a defect in
`cc-report.sh`** — report it as one rather than overriding it. One derivation,
one place.

---

## 4. The alert rules

`cc-report.sh --list-rules` prints the authoritative list. **Read it from the
host rather than trusting any prose about it, including this page** — no rule
table is reproduced here, deliberately.

What makes that list trustworthy is a test, not its location. The list is a
literal block inside the script, and a literal block inside a script cannot
drift from a *document* but drifts from the *code* just as easily as anything
else. Suite case **RP11** compares the
advertised ids against the ids the code can actually raise, at their call sites,
and fails on a difference either way. A rule advertised but unimplemented claims
coverage that does not exist; a rule that fires but is not advertised arrives
with no entry to look up.

The shape of the ranking:

| Level | Meaning |
| --- | --- |
| **ALERT** | Blocks a clean "all good" until a named human dispositions it |
| **FYI** | Recorded and counted; no action this week |
| **SKIP** | **Could not be answered.** Never a pass — the reason is always printed |

Two principles a junior can apply without memorising the table:

- **A breach is an alert every week it persists.** A missing hook is not less bad
  in week six.
- **"Could not tell" is never "fine".** A repository that did not answer, a home
  the sweep could not see, a collector that did not run — each is reported as
  what it is. A health check that audits one account out of many and reports
  *healthy* is the failure this rule exists to prevent.

Section **11 of every report is the run inventory** — every collector, whether it
ran, its exit code, and the reason for any skip. It is mandatory and it is the
first thing to read when a report looks suspiciously clean.

---

## 5. Asking the agent instead of reading the file

**Which of the three is authoritative, since all three "run everything".** The
weekly report is the **record**: it runs as root on a schedule, so it is the only
one that can read the evidence logs, and its verdict fields are what a reader
quotes. `estate-audit` is the **fresh pass**: it re-runs the standing audits with
judgment applied, on demand, and it can see things a script cannot — a stale
document, a register row whose trigger has fired. `estate-status` is the
**reader**: it re-derives nothing. When the report and an audit disagree, the
audit is newer and the report is reproducible; say both, and treat the difference
itself as the finding. None of the three supersedes another, and none of them
applies anything.

The `estate-status` skill answers "what is the state of Claude Code?" **from the
stored report** — it reads, it never re-runs. Say it in plain words; the skill
name is not something anyone needs to remember.

It refuses to answer from a record more than **9 days** old, or from a partial
run, without saying so first — and it offers `estate-audit` for a fresh pass
instead. For a full live pass, ask for the estate audit; for a version move, say
*version bump*.

---

## 6. Metrics — what a monitoring system could read, and the honest verdict

**This repository ships no monitoring stack.** No `node_exporter`, no
Prometheus, no Grafana. That is host-infrastructure work owned outside this
repository, and on a site without one this section describes a contract with no
consumer.

**The recommended shape, where one exists, is the node_exporter *textfile
collector*** — a script writes a `.prom` file, an already-present exporter serves
it. We own a file, not a service: no daemon, no listening port, no TLS, no auth,
no patch treadmill, and nothing new in the deny-list threat model. Running our
own HTTP exporter was considered and rejected: on a host with no active
firewall it is an unauthenticated port exposing governance state to anything that
can route to it, and nothing else in this control plane opens a socket.

**What is worth a time series here, and what is not.** Most of what this control plane
tracks is an *event*, not a trend — a policy that stopped matching its baseline
wants a page, not a graph. What genuinely varies over time is: which hosts are
governed (the coverage figure), the health-check finding count **and its
denominator**, and how many private installs sit below the floor. Session volume
is deliberately excluded: per-person counts on a dashboard is employee
monitoring, which is the line `RUNBOOK.md` §11.7 draws and the reason
`OTEL_LOG_USER_PROMPTS` stays off.

**The staleness rule, which matters more than the metrics.** A textfile collector
fails silently and in the worst direction: if the writer stops, the exporter
serves the last file forever and every dashboard stays green on a frozen
snapshot. Any dashboard built on this **must** alert on the file's own timestamp
metric — a healthy file is at most ~26 hours old given a daily writer.

### The metric set

Written by `cc-healthcheck.sh` to `CC_METRICS_FILE` from config.sh — a
*rendering* of the daily run, not a second source, which is why it is part of
that script rather than a script of its own. An empty `CC_METRICS_FILE` turns it
off; `--metrics <path>` redirects one run. The script writes nothing at all when
the parent directory is absent.

| Metric | Type | What it answers |
| --- | --- | --- |
| `claude_code_build_info{version,approved}` | gauge (always 1) | What is this host running, and what is it supposed to run? Version strings live in labels so they stay out of the numeric series |
| `claude_code_version_drift` | gauge 0/1 | Did the versionlock hold, or is a private install winning `PATH`? |
| `claude_code_healthcheck_issues` | gauge | How much needs attention, and is the trend up or down? |
| `claude_code_healthcheck_accounts_audited` | gauge | **The denominator.** A check that audited one account out of many can still report *healthy* — graph this or the verdict above it means nothing |
| `claude_code_managed_file_ok{file}` | gauge 0/1 | Is each hook and the status line present, root-owned and unwritable by others? A missing hook is a **silent** failure: calls proceed unaudited |
| `claude_code_private_installs{state}` | gauge | How many private installs remain, and in which state? `shadowing` / `tree_only` / `preserved`. **Counts only, never names** |
| `claude_code_textfile_timestamp_seconds` | gauge | **The staleness detector** — see below. Alert above ~26h (a daily writer plus jitter and one `Persistent=true` catch-up) |

Two alert rules are enough to start:

```promql
# the writer stopped and every other panel is now a frozen snapshot
time() - claude_code_textfile_timestamp_seconds > 93600
# the check went blind rather than clean
claude_code_healthcheck_accounts_audited < 2
```

**What must never become a label:** a file path, a command line, a URL, a user
name. Those are the group-only fields the evidence logs carry, and a metrics
system has a different audience. The `.prom` file must be world-readable for an
exporter to serve it, which is itself the test: anything that would need
`internal/`'s group-only mode cannot go in it.

---

*The procedures that run all of this are [`OPERATIONS.md`](OPERATIONS.md) §7.4
(the version watch) and Part 7 generally; the scripts are catalogued in
[`RUNBOOK.md`](RUNBOOK.md) §12; live state is `internal/CURRENT-STATE.md`.*
