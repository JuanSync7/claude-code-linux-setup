# Claude Code on Linux — the fleet control plane

| | |
| --- | --- |
| **What** | Centrally governed [Claude Code](https://claude.com/claude-code) for a shared Linux engineering fleet. This page is the index: what the repository delivers, how to install and verify it, and which document answers which question |
| **Who** | Anyone opening this repository — operators, reviewers, auditors. No prior knowledge of the deployment is assumed |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and `docs/UPGRADES.md` records every move of it |
| **Where** | Shared Linux hosts running Rocky Linux 8 or RHEL 8. The per-user cloud image under `aws/` is planned, not built ([`docs/LOCAL-VS-AWS.md`](docs/LOCAL-VS-AWS.md)) |
| **Why** | The front door. It states each conclusion once and points at the canonical home of everything else — the detail lives in `docs/` and `internal/`, not here |
| **Status** | In force on every host where `cc-install.sh --apply` has run. Each host is deployed on its own, by hand; which hosts are governed is recorded in [`internal/CURRENT-STATE.md`](internal/CURRENT-STATE.md) |
| **Owner** | The maintainer |

This repository is the deployment: the managed policy, the hooks that enforce and record it, the
operator scripts that install and verify it, and the documentation for running it. Cloning it and
running one command builds a host.

In the public template edition the site's values are placeholders. Fill them first, following
`TEMPLATE.md` at the root of that edition: the installer refuses a policy that still carries one
(`docs/PUBLISHING.md` section 1).

---

## What this is for

Engineers on a shared host run large build or test workloads, often against material the
site holds for someone else — a customer's data, under a contract or an NDA. Claude Code is
genuinely useful to them — it can drive a Makefile, read a log, chase a build failure — but
the same access that makes it useful is access to every other project's material, and to
credentials on a shared multi-tenant workstation.

The documents say "customer data" for that material throughout. A site with no customers
reads it as whatever it must keep apart: another team's project, a regulated dataset. The
controls are the same; only the contractual questions (`docs/RUNBOOK.md` §1.5) fall away.

So the deployment has one job: **let Claude Code run real commands, while making the boundaries
non-negotiable.** [`GOAL.md`](GOAL.md) states that goal and ranks the rules that decide between
two good things when they conflict. Concretely:

- **Bash is allowed.** Engineers must be able to run their build and test tools. A Claude
  that cannot run a command is not an assistant.
- **The policy is set by IT and cannot be overridden locally.** It lands in
  `/etc/claude-code/managed-settings.json`, a path compiled into the binary, and it takes precedence
  over every user, project and command-line setting. `allowManagedPermissionRulesOnly` and
  `allowManagedHooksOnly` close the routes around it.
- **Secrets and credentials are denied, and the denial is recorded.** A deny list (`docs/SETTINGS-REFERENCE.md` §3.2) plus a hook that
  blocks reads by filename pattern, so a new key file is covered before anyone writes a rule for it.
- **Everything is logged** to `/var/log/claude-code/activity/`, per user, append-only to the user
  themselves and unreadable by their colleagues.
- **Administrators get a separate, audited escalation path** rather than a loophole in the fleet
  policy. See [`docs/ADMIN-SESSION.md`](docs/ADMIN-SESSION.md).

### What it deliberately does not do

**There is no sandbox.** `sandbox.enabled` is `false` fleet-wide. This is not an oversight and not a
default left unchanged — it is a recorded decision. Read [`docs/SANDBOX-DECISION.md`](docs/SANDBOX-DECISION.md) before touching any
`sandbox.*` key, and treat any document that says the sandbox isolates as out of date.

The consequence is worth stating plainly, because it sets the ceiling on what this deployment can
promise: **the deny rules and the hooks see Claude's own tool calls, not a subprocess's syscalls.**
A script Claude runs is not contained by them. Filesystem separation between customers rests on
Unix permissions on the project storage, and network containment rests on egress filtering — neither of
which is in this repository. [`internal/LIMITATIONS-AND-RISKS.md`](internal/LIMITATIONS-AND-RISKS.md)
is the register; read it before claiming a control to a customer or an auditor.

---

## Requirements

- Rocky Linux 8 (or RHEL 8). The one resource limit shipped (`TasksMax`) is valid on both cgroup
  generations.
- `python3` (system python is fine — the hooks, the installer gates and the reports all use it)
- The `claude-code` RPM, installed and pinned. `make pin VERSION=x.y.z` does this on a fresh host;
  **upgrading** an existing host is a gated change, handled by `bin/cc-update.sh` — `cc-install.sh`
  itself never touches the package.
- Root, to apply.

Deliberately no dependency on `yq`, `jq`, or any pip/npm package. Nothing here needs network access
at install time.

## Install

**Governance only, one host, today** — the policy, the hooks and the log
directories, without the rest of the control plane:

```bash
make help                        # every target, and the paths in effect
make config                      # required: config.sh from the template, then set this site's values (QUICKSTART §9)
PIN=$(python3 -c 'import json; print(json.load(open("settings/managed-settings.json"))["requiredMinimumVersion"])')   # the fleet pin, read from the policy
sudo make pin VERSION="$PIN"     # the claude-code RPM, version-locked (skip if using cc-update.sh)
sudo make quickstart             # config + policy + hooks + statusline + log dirs, with guards
make verify                      # read-only conformance check
```

[`docs/QUICKSTART.md`](docs/QUICKSTART.md) is the specification behind those
targets — every raw command, what may be relocated and what may not, and the
central-vs-user-local install tradeoff.

**The full control plane** — everything above plus the three timers (health check, version
watch, weekly report), logrotate, `profile.d`, resource limits:

```bash
git clone <this repo> claude-code
cd claude-code

bin/cc-repo-setup.sh             # enables the git hooks, creates config.sh
${EDITOR:-vi} config.sh          # see Configure, below

sudo bin/cc-preflight.sh         # is this host suitable? changes nothing
sudo bin/cc-install.sh --check   # what would change? changes nothing
sudo bin/cc-install.sh --apply   # or: sudo make install
```

**Run `bin/cc-repo-setup.sh` in every clone.** Git will not install hooks on
`clone` — deliberately, since a repository that could execute code on clone would
be an obvious attack — so it has to be an explicit local step and **nothing
enforces it.** A clone that skips it simply has no pre-commit guard. See
[Working on this repository](#working-on-this-repository).

Then verify:

```bash
sudo bin/cc-healthcheck.sh       # every placement, mode and drift check
sudo bin/cc-audit.sh             # file this as the host's baseline record
claude doctor                    # does Claude Code accept the policy?
```

and as a normal user **in a fresh login shell** (the `profile.d` drop-ins need one):

```
/permissions                     # every effective rule, and its source file
/status                          # active managed source and login
```

Options to `cc-install.sh`:

| Flag | Effect |
| --- | --- |
| `--check` | Dry run. The default — you cannot apply by accident |
| `--apply` | Make the changes |
| `--with-admin` | Also install the privileged-session **policy and launcher** (`/etc/claude-code-admin/`, `cc-admin-session.sh`) — neither lands without the flag, so a host built without it carries no escalation path. **Only on hosts that need it**, and `--apply` itself requires root |
| `--remove-admin` | Take the privileged-session policy and launcher off a host that has them (copies are kept). On such a host an apply with neither `--with-admin` nor `--remove-admin` refuses, so the escalation path is never left behind unmanaged |
| `--gates-only` | Run the policy gates and stop, placing nothing. `make quickstart` runs this first |
| `--allow-below-floor` | Apply a policy whose version floor is above the installed `claude`. Every session on the host then refuses to start until the binary is upgraded — use only when that is intended |
| `--with-ide` | Seed the VSCodium defaults that point the Claude extension at the pinned CLI. Desktops only. See [`docs/IDE-INTEGRATION.md`](docs/IDE-INTEGRATION.md) |

`cc-install.sh` is idempotent and safe to re-run. It refuses to apply if the policy contains
placeholders, if the policy's hook paths disagree with `config.sh`, if the policy's
`requiredMinimumVersion` is above the installed version (every session would refuse to start —
`--allow-below-floor` overrides, knowingly), if it is run from inside a privileged session's
mount namespace, or while another apply or a `cc-update.sh apply`/`rollback` holds the control
lock.

An apply places the policy **last**, after everything it names, and stops at the first failed
step with the previous policy still in force. Every file is written beside its destination and
renamed into place, so no reader sees it half-written. Files it replaces or removes are kept in
`$CC_LOGDIR/install-backup/last`; a policy edited by hand since the last apply is reported and
kept there as `hand-edited-*`. A complete apply writes `$CC_ETC/install-record` — the commit it
came from and every file it placed — and the next apply removes any recorded file the repository
no longer ships. `--check` prints the deployed commit beside the checkout's.

## Configure

Site-specific values live in **`config.sh`**, which `.gitignore` keeps out of the repo (with any
`config.*.sh` copy, backups and per-user session state). `config.example.sh` is the committed
template and documents every key.

```bash
cp config.example.sh config.sh
```

It holds no credentials and must never be used to hold one — it is topology: install destinations,
the group that owns this tree, and who may open a privileged session. It is separated out so this
repository can be cloned, reviewed or handed to a vendor without redaction, and so that a second
site is a new `config.sh` rather than a patch set.

It is shell rather than YAML because a Rocky 8 base install has neither `yq` nor `jq`, and its only YAML
parser is PyYAML on the system python — a YAML config would make `cc-preflight.sh` depend on an
interpreter it exists to check for.

**Two things are not configured from there:**

- **`settings/managed-settings.json`** is never generated from `config.sh`. The policy is the one
  artefact where an operator must be able to read the literal effective value, so a site's values
  are edited in the file itself, and `cc-install.sh` has a gate that refuses to deploy a policy
  containing an unfilled placeholder — a substitution step at install time would turn that gate
  into a liability. A site's own repository holds the file concrete; the public template edition
  holds it with listed placeholders until a site fills them
  ([`docs/PUBLISHING.md`](docs/PUBLISHING.md) §1). §5 of `config.example.sh` lists what to
  hand-edit for a new site. [`docs/SETTINGS-REFERENCE.md`](docs/SETTINGS-REFERENCE.md) documents every key.
- **File modes and group ownership**, because git records only the owner-execute bit. Run
  `bin/cc-repo-perms.sh --apply` after any pull that adds files; see [Working on this
  repository](#working-on-this-repository).

## Layout

One directory per install destination, so where a file goes is never a question:

```
Makefile                                           deployment targets; make help
bin/         -> /usr/local/sbin              0750  operator scripts, root only
hooks/       -> /usr/local/sbin              0755  the managed hooks
share/       -> /usr/local/share/claude-code 0755  statusline.sh, IDE wrapper
lib/         -> /etc/claude-code             0644  the config loader
settings/    -> /etc/claude-code{,-admin}    0644  the policies
profile.d/   -> /etc/profile.d               0644  HOME and BROWSER, .sh + .csh
systemd/     -> /etc/systemd/system          0644  timer, units, resource limits
             -> /etc/logrotate.d
aws/         -> (image build, not this repo)       AMI/VDI: posture selector, userns sysctl, scoped sudoers
githooks/                                          pre-commit guard; post-merge + post-checkout perms
tests/                                             self-tests for the cc-* scripts
dashboard/   (not installed yet)                   read-only web dashboard over the logs; its own README
publish/                                           what the public template edition adds; docs/PUBLISHING.md
docs/                                              how to run it. Ships with the release
internal/                                          the record. 2770, group-only
.claude/skills/                                    maintenance skills, loaded by sessions in this repo
```

[`docs/REPO-MAP.md`](docs/REPO-MAP.md) is the coupling map for all of it: what
*else* must change when you change a file here, and which of those couplings
CI enforces versus which run on discipline.

`hooks/` is `0755` and not `0750` on purpose: those run as the engineer, inside their own session.
Tighten them and the hooks silently stop running — tool calls proceed *unaudited* with only a
transcript warning, which looks governed and is not (see `docs/QUICKSTART.md` §3). Likewise
`/var/log/claude-code/activity/` is `1733` — engineers append as themselves and cannot list or
delete each other's files; the hooks create the logs `0600`, which is what actually stops them
reading each other's history. Both are asserted by `cc-install.sh` and checked by
`cc-healthcheck.sh`.

### The documents

[`GOAL.md`](GOAL.md) is the top: the goal and the ranked rules, no detail.
[`docs/README.md`](docs/README.md) is the map: every document's type, what it delivers, when to
read which, and the reading orders — including the group-only `internal/` record (the state
register and the risk register). Start with
[`docs/QUICKSTART.md`](docs/QUICKSTART.md) to get a host governed today;
read [`docs/DOC-STYLE.md`](docs/DOC-STYLE.md) before editing any document.

## Upgrading Claude Code

Version changes are gated, not automatic. `requiredMinimumVersion` in the policy and
`/etc/claude-code/approved-version` are the two controls — the floor moves with the policy apply,
`approved-version` with the package move (`bin/cc-update.sh` / `make pin`), and the Part 7
sequence moves them as one change.
The full procedure is [`docs/OPERATIONS.md`](docs/OPERATIONS.md) **Part 7**: `make bump-audit`
runs the deterministic checks and re-asks every version-anchored question (the probe manifest),
agent lanes analyse the vendor changelog and the settings surface, and every transition lands as
an entry in [`docs/UPGRADES.md`](docs/UPGRADES.md) — CI refuses a pin without one. In a Claude
Code session opened in this repository, saying "upgrade Claude Code to \<version\>" starts the
whole run; the privileged steps always print for a human at a real terminal.

Re-verify §7–§9 of [`docs/RUNBOOK.md`](docs/RUNBOOK.md) at every version bump: they document
product behaviour this design depends on, some of it undocumented upstream.

In-session upgrade attempts (`claude update`, npm sideloads, the vendor installer) are blocked by
`hooks/cc-upgrade-guard-hook.sh` with a pointer to this procedure — the versionlock is what
holds the version; the hook replaces the bare denial with directions.

## Working on this repository

**The deployed tree is the checkout.** The shared checkout (`CC_REPO` in `config.sh`) is this
repository, owned by the repository group (`CC_REPO_GROUP` in `config.sh`) at mode `2770` —
group-only, because nothing in a running session reads the repository (sessions use the installed
copies under `/etc` and `/usr/local`), so no unprivileged account needs to see it. There is no
separate release copy to keep in step — a deploy is `git pull` followed by
`cc-install.sh --apply`. That is deliberate: two copies of the same file drift apart.

Three planes, three tools — git moves source, the installer moves source onto the host, and the
checks move nothing:

```
  SOURCE  (repo ↔ repo)      personal clone ──push──▶ GitHub ──pull──▶ this checkout
  DEPLOY  (repo → host)      sudo bash bin/cc-install.sh --apply   (or: sudo make quickstart)
                                  ▼
                             /etc/claude-code, /usr/local/sbin, /usr/local/share, systemd
  VERIFY  (host → report)    cc-healthcheck.sh (daily timer) · cc-version-watch.sh, cc-report.sh
                             (weekly timers) · cc-audit.sh · make verify
```

Engineers appear on none of these planes: their sessions read only the installed copies, and their
work lives in the project storage and their homes.

On the shared checkout, as a member of the repository group, from a real terminal (root for the `sudo` steps):

```bash
git pull
bin/cc-repo-perms.sh --apply       # git restores neither group, setgid, nor internal/'s 2770
sudo bin/cc-install.sh --check
sudo bin/cc-install.sh --apply
```

**Pass:** `cc-repo-perms.sh` ends `Nothing to change` or `Corrected N path(s)`, and `--apply` prints
`APPLIED, 0 error(s)` and exits 0.
**Fail:** `cc-install.sh` refuses to apply for the reasons listed under [Install](#install) —
placeholders in the policy, hook paths disagreeing with `config.sh`, a version floor above the
installed binary, or a privileged session's mount namespace; the recovery procedures are in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

The `post-merge` hook runs `cc-repo-perms.sh` for you, so the second line is a safety net rather
than a ritual — but only in a clone where `cc-repo-setup.sh` has been run.

**Why permissions need reasserting at all.** Git records exactly one permission bit —
owner-execute. Not the group, not the setgid bit, not `internal/`'s `2770`. A pull that creates a
file gives it the puller's umask, and a new directory loses the setgid bit that is the *entire*
group-inheritance mechanism here (the scheme uses no ACLs). The visible symptom is a
colleague unable to edit a file you just added. The invisible one is a findings document becoming
world-readable. The scheme `cc-repo-perms.sh` asserts, everywhere in the tree: directories `2770`
(setgid, group-only — setgid inheritance holds at `2770`), scripts and git hooks `770`, everything
else `660`. Before anything else it strips world access from every path it owns, `.git`
included (`.git/objects` holds every revision of `internal/`), so a host where the group does
not resolve still ends with nothing world-readable; that run then exits 1 and names the group.

This whole mechanism is a consequence of **sharing one checkout**. Where each person clones into
their own home — the normal git model — there is no group to assert: with `CC_REPO_GROUP=""` the
script still strips world access, then refuses and says the group is not set.

### The pre-commit guard

`githooks/pre-commit` refuses to commit:

| | |
| --- | --- |
| Files that are secrets by nature | `nslcd.conf`, `shadow`, `id_rsa`, `*.pem`, `.netrc`, `credentials`, anything under `.ssh/` |
| Recognised token formats | GitHub PAT, AWS access key, `sk-ant-…`, Slack, GitLab, Google, JWT |
| Assignment-shaped credential values | `KEY=value` where the value is ≥12 chars with both letters and digits |
| LDAP bind credentials **by shape** | a `binddn`+`bindpw` pair, even in a renamed file or a markdown fence |
| Session transcripts | `*.jsonl` — these record whole file contents, including anything read from `/etc` |
| Oversized files | >512 KB |
| `config.sh` | gitignored site config, force-added by mistake |

It exists because a credential can reach a commit without anyone typing it: a pasted
directory-client config, or a session transcript that recorded a file read from `/etc`. A register
in `internal/` that names an account is a considered decision; a pasted `nslcd.conf` would not
be, and `git push` is irreversible.

It matches **values, not vocabulary**. This repository legitimately discusses `bindpw` and
`password` in its documents and in deny rules — a guard that blocked those words would block
ordinary edits and would be switched off within a week. It is held both ways: the suite plants
credentials and asserts each is caught (cases PC1–PC8), and CI check [1] runs the guard over
every tracked file on every push, so a false positive fails CI.

Override with `git commit --no-verify`. That's a decision, not a formality — and if you're reaching
for it because the guard is wrong, fix the guard so the next person is covered too.

#### If someone skips `cc-repo-setup.sh`

They get no guard, and **GitHub's push protection does not fully cover the gap.** It is a genuine
second line of defence, but the two protect different things and neither is a superset of the other:

| Leak | Local guard | GitHub push protection |
| --- | --- | --- |
| GitHub PAT, AWS key, `sk-ant-…` | caught | caught |
| A directory-client config (`/etc/nslcd.conf`) holding a site's `bindpw` | caught | **not caught** — a site-specific password matches no known vendor pattern |
| A `*.jsonl` session transcript | caught | **not caught** |
| A bare `password:` assignment with a 12+ character value | caught | **not caught** |
| A 40 MB file | caught | not its job |
| A brand-new vendor's token format | missed | caught — GitHub's patterns are maintained, ours are not |

So the local guard covers what is specific to *one site* — which is exactly what an external
service cannot know about — and GitHub covers the vendor formats we'd never keep up with. Run both.

### CI

Both remotes run the same checks: everything lives in **`bin/cc-ci-check.sh`**, called by
`.github/workflows/ci.yml` and `.gitlab-ci.yml`, so the two platforms cannot drift. In a Rocky 8
container (fleet parity — "works on Ubuntu" proves nothing here) it: re-runs the secret guard over
**every tracked file** (`CC_SCAN_ALL=1` — this is what closes the guardless-clone gap above, at the
remote); validates every tracked JSON and scans the *effective* policy for placeholder markers;
asserts the executable bit is recorded in the index — whether a `chmod` reaches git depends on
each clone's `core.fileMode`, and a script committed without the bit reaches a fresh clone unrunnable;
syntax-checks every script; resolves every relative markdown link; stages the full deployment with
`make quickstart DESTDIR=` and asserts the manifest, with the hook list read from the Makefile
itself; holds every other list of hooks — both policies, the installer's two, the healthcheck's — to
that Makefile list; requires every `CC_*` loader parameter to appear in `config.example.sh`; refuses a site
value spelled in code — a default on a config key, or a value from `config.example.sh` written
literally in a script, hook, Makefile or workflow (comments may state it; the few compiled-in vendor
facts are an exception list in the check, each with its reason); refuses a policy, unit, logrotate
stanza or sudoers drop-in whose paths or contact disagree with the config (`lib/cc-coupling.py`, which
`make quickstart` and `cc-install.sh` also run against the site's own config.sh); and refuses a
`requiredMinimumVersion` change with no matching [`docs/UPGRADES.md`](docs/UPGRADES.md) entry —
a version bump cannot land unrecorded, and neither can a pin that is dropped or that differs between
the fleet and admin policies; and refuses an executable script that has neither test cases
nor a recorded reason for having none (`tests/test-cc-scripts.sh --coverage`, which derives the map
from the suite rather than from a table someone maintains); and holds four couplings no other
check sees — every systemd unit in each installer list, one mount-table predicate behind the
`CC_MOUNTINFO` seam, no copy of the pin in a script, a `tests/README.md` row for every test file,
and live `OPERATIONS.md` Part 7 sections behind every skill. A check whose own Python crashes fails
rather than reporting what it never examined. The checks iterate `git ls-files` rather
than fixed lists, so a file added next month is covered the day it lands. `CC_CI_ONLY=<n>` runs a
single check, which is how the test suite exercises them against scratch repos.

A second, **non-gating** GitHub workflow — `.github/workflows/version-watch.yml` — runs weekly on
GitHub's own machines and asks whether the vendor has published a Claude Code version above the pin
recorded in `settings/managed-settings.json`. It keeps exactly one issue in sync with the answer:
opened once, edited when the number moves, silent when nothing changed, and closed by itself once
the pin catches up. It reads the pin at run time and carries no version of its own, it never
chooses a target, and it moves nothing — it exists so that noticing a new release does not depend
on somebody remembering to look (`docs/OPERATIONS.md` §7.4, which also covers the on-host half).
It is **not** a gate: `bin/cc-ci-check.sh` and the self-test suite are the only things that can fail a push.

Two things CI deliberately does not do. Filesystem modes on the shared checkout — git does not
record them, so no remote can check them; `githooks/post-merge` and `bin/cc-repo-perms.sh` own
that, per checkout. And it cannot exercise the `claude` binary: version moves stay gated on-host
(`make pin` / `bin/cc-update.sh`), with `RUNBOOK.md` §7–§9 re-verified by a person at each bump.
The self-test suite runs in CI as a gating job, as root in a Rocky 8 container; what a container
cannot fabricate skips with its reason (`tests/README.md`, In CI).

GitLab note: `.gitlab-ci.yml` does nothing until a docker-executor runner is registered on the
instance. Pipelines stuck at "pending" forever is the symptom of a missing runner, not a broken
config.

Also check before relying on it: on a **private** repository, GitHub secret scanning and push
protection have historically required a paid add-on rather than being on by default. Confirm it is
actually enabled on the repo rather than assuming it.

And the failure mode that neither catches: **a clone with no hooks whose owner never pushes**, but
who copies a file into the shared checkout. Nothing scans that path at all.

**If you were recently added to the repository group, log out and back in.** Group membership is fixed at
login. A running shell never picks up a new group, however plainly `getent group` shows it, and the
resulting permission errors are baffling until you know this.

Conventions the documentation is maintained by:

1. **Each fact lives in exactly one document**, and everything else links to it. State in
   `CURRENT-STATE.md`, procedure in `OPERATIONS.md`, setting rationale in `SETTINGS-REFERENCE.md`.
   If you are updating the same number in two places, one of them should have been a link.
2. **Corrections replace text; they do not annotate it.** A wrong value beside a note saying it is
   wrong means an operator can copy either one.
3. **Every document carries 5W front matter** — What, Who, When, Where, Why, Status, Owner ([`docs/DOC-STYLE.md`](docs/DOC-STYLE.md) §2).
4. **Superseded documents move into the group-only record under `internal/`, with a banner — not
   deleted.** History is useful; unmarked history is a trap.

Never hand-edit a deployed file. Change it here, `--check`, then `--apply` — and never from inside a
Claude Code session, which is why `cc-install.sh` refuses to apply through a bind-mounted policy
path.

## Known gaps

A site's open findings are tracked in [`internal/CURRENT-STATE.md`](internal/CURRENT-STATE.md), and
the risks it has accepted in [`internal/LIMITATIONS-AND-RISKS.md`](internal/LIMITATIONS-AND-RISKS.md).
These follow from the design itself, on any site, and shape how much a deployment can be trusted:

- **Governance is per host.** Each host needs its own `cc-install.sh --apply`. A host without one
  is ungoverned, and if it mounts the same home directories, the credentials and private installs
  stored there are within reach of an ungoverned Claude Code. Check which hosts mount them.
- **No egress filtering ships here.** With the sandbox off it is the only network control that a
  user cannot `unshare` around, and it is host and network work outside this repository.
- **Customer separation rests on the project storage.** Its Unix ownership and modes, not anything
  in this repository, keep one customer's tree from another customer's team.
- **The repository group must resolve on every host that keeps reports.** A group that exists
  only locally on one host means nothing on another; where it does not resolve, the reports
  directory is created root-only.

## Licence and provenance

The template edition of this repository is released under the MIT licence, and carries the text
as `LICENSE` at its root (`docs/PUBLISHING.md` section 1 says which files only that edition
holds). The `claude-code` RPM itself is Anthropic's, under its own terms;
nothing here redistributes it.
