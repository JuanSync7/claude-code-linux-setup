# bin/ — operator scripts and repo tooling

*Directory map — one line per file and where it is documented in full. Not a
second home for any fact; the canonical docs are linked.*

Two families. **Host scripts** install to `/usr/local/sbin` (root-owned, 0750)
via `cc-install.sh --apply` and are documented in
[`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §12. **Repo tooling** runs from the
checkout, never installs to a host, and is documented in the repository
[`README.md`](../README.md) under *Working on this repository*.

| File | Family | What it is |
| --- | --- | --- |
| `cc-preflight.sh` | host | Is this host suitable? Read-only; gates an automated build |
| `cc-install.sh` | host | Places the full control plane, policy last; idempotent; atomic per file, with backups and an install record that drives removal of dropped files; refuses on placeholder policy, path disagreement, a policy floor above the version installed here (`--allow-below-floor` overrides), from inside an admin session, while the control lock is held, or on an admin host without `--with-admin`/`--remove-admin`. `--gates-only` runs the gates for `make quickstart` |
| `cc-healthcheck.sh` | host | Daily drift/integrity check, run by the systemd timer. Exit 1 = items need attention; exit 3 = it could not run. `--metrics <path>` renders the same run as a Prometheus textfile — a rendering, not a second source — and writes nothing when the parent directory is absent ([`docs/REPORTING.md`](../docs/REPORTING.md) §6) |
| `cc-report.sh` | host | The weekly estate report: runs every check, ranks what came back, compares it to last week, and answers **BUMP:** and **REPORT TO MANAGEMENT:** as fields. Exit 1 = at least one alert; exit 3 = the run could not complete. Writes `/var/log/claude-code/reports/`, never the checkout |
| `cc-version-watch.sh` | host | Asks the vendor repository whether anything above the pin is published. Reads the pin from the policy, carries no version of its own, moves nothing. Exit 1 = a newer version exists, 3 = could not tell |
| `cc-drift.sh` | host | Read-only: what differs between the last apply's install record, the host now, and the checkout. Exit 1 = drift, 3 = could not tell. `--out` writes the same answer as JSON, which the health check leaves at `$CC_LOGDIR/drift.json` for the dashboard |
| `cc-update.sh` | host | The only supported version move: `sessions` / `check` / `stage` / `apply` / `rollback`. Refuses to apply while anything is running the managed binary or to a version below the installed one or the policy floor, and to roll back below the floor; records `approved-version` only after the smoke test |
| `cc-audit.sh` | host | Read-only evidence-grade snapshot, filed with change records. Record 0640; exit 0 when written (findings counted, not judged), 3 when it could not run |
| `cc-admin-session.sh` | host | Privileged-session launcher; lands **only** with `--with-admin` ([`docs/ADMIN-SESSION.md`](../docs/ADMIN-SESSION.md)) |
| `cc-repo-perms.sh` | repo | Re-asserts the shared checkout's group-only modes — git does not record them |
| `cc-repo-setup.sh` | repo | Enables `githooks/`, creates `config.sh`; **run in every clone**, nothing enforces it |
| `cc-ci-check.sh` | repo | Every CI check, one script; both platform configs call it; the GitHub workflow also runs the test suite and shellcheck beside it |
| `cc-publish.sh` | repo | Builds the public template edition in a separate clone: exports `HEAD` without `internal/`, lays `publish/overlay/` over it, swaps the site map's values for placeholders, and refuses to commit while a denied term, a secret, or a failing check remains. `--scan` is the public repository's CI entry point ([`docs/PUBLISHING.md`](../docs/PUBLISHING.md)) |
| `cc-template-fill.sh` | repo | Writes a filled copy of a template edition for testing: every tracked file except `template.json` and `TEMPLATE.md`, each listed placeholder replaced by the example `template.json` gives for it. `--list` prints the listed names, and is where CI check [2] reads them. CI check [6] and the test suite run on that copy, because the installer refuses the unfilled tree. Refuses a clone with no `template.json`, and a destination that already holds files. [`PUBLISHING.md`](../docs/PUBLISHING.md) §1 |
| `cc-bump-audit.sh` | **both** — repo *and* host (`/usr/local/sbin`, so root can run it: probes A5 and A8 under-report unprivileged) | The deterministic lane of a version bump: pin coherence + the probe manifest, every version-anchored question re-asked ([`docs/OPERATIONS.md`](../docs/OPERATIONS.md) Part 7, [`docs/UPGRADES.md`](../docs/UPGRADES.md)) |
