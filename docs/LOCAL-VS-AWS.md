# Claude Code: shared host vs per-user cloud desktop

| | |
| --- | --- |
| **What** | The register of how a governed Claude Code deployment differs between a **shared multi-user host** and a **per-user cloud desktop** (one VDI instance per engineer, the shape the artifacts under [`../aws/`](../aws/README.md) are written for): what must be configured differently, what stays the same, and what to settle before the first desktop image is built |
| **Who** | Whoever plans or builds a per-user desktop image, and anyone deciding whether a shared-host choice should travel to it. Assumes a governed shared host can already be built (`QUICKSTART.md`, `OPERATIONS.md` Part 1) |
| **When** | Against the **pinned build** (`requiredMinimumVersion` in `settings/managed-settings.json`; [`UPGRADES.md`](UPGRADES.md) for the history). Every statement is graded: **[HOST]** — what this repository's scripts and policy do on a shared host, the build `OPERATIONS.md` Part 1 produces and validates; **[PLANNED]** — designed, with artifacts in `aws/`, and not validated on an image; **[UNVERIFIED]** — depends on the site, to be confirmed there |
| **Where** | Shared Linux hosts (the supported build) and per-user AWS VDIs (the planned one). What a particular site runs, and on how many hosts, is recorded in `internal/CURRENT-STATE.md`, not here |
| **Why** | The two shapes differ in ways that change the configuration, not just the host names. This is the single place those differences are recorded, so that a shared-host workaround does not quietly become the desktop design, and nothing configured for one shape is assumed to hold on the other (`DOC-STYLE.md` §4) |
| **Status** | The shared-host column describes the shipped build. **The per-user desktop column is design, not validation** |
| **Owner** | The maintainer |

> **Read the grading, not just the tables.** Almost every per-user desktop statement here is
> **[PLANNED]**, and that is the honest state of it. Nothing under `aws/` is installed by
> `cc-install.sh` or the `Makefile`, and the design has not been exercised on cgroup v2, on a
> single-user host, on home directories local to an instance, or on a machine image. What the
> shipped scripts establish about dependencies, the browser login path and the sandbox
> (`SANDBOX-DECISION.md`) they establish on a shared host.
>
> So the desktop half of this document is a reasoned design, not a tested one. Treat the first
> desktop as a **pilot with written exit criteria** (`OPERATIONS.md` Part 2), not as the first of
> a fleet, and expect it to find interactions that reading does not surface.

---

## 1. The one difference that drives most others: tenancy

| | **Shared host** | **Per-user desktop (AWS VDI)** |
| --- | --- | --- |
| Machines | A few shared servers, each built individually | One instance **per engineer** [PLANNED] |
| Users per kernel | Many [HOST] | One |
| Consequence | Every noisy-neighbour control matters | Contention controls largely become moot |

Almost everything below follows from this row. On a shared host you are arbitrating between
engineers; on a single-user desktop you are only protecting the instance from its own runaway
processes. The sandbox is disabled in both shipped policies (`SANDBOX-DECISION.md`), so per-user
isolation comes from the instance boundary — which is exactly what one desktop per engineer
provides; the tenancy argument stands without the sandbox, and is stronger for its absence.

---

## 2. Configuration that MUST differ

### 2.1 Resource limits (`user-.slice.d`)

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Memory | **None** — deliberately absent [HOST] | **Omit.** The engineer should be able to use the whole instance |
| CPU | **None** — deliberately absent [HOST] | **Omit** |
| Tasks | `TasksMax` — the fork-bomb backstop, and the only directive in the file [HOST] | `TasksMax` — keep as a fork-bomb backstop |
| File to install | `systemd/user-.slice.d/50-claude-code.conf` — the `TasksMax`-only drop-in [HOST] | The same drop-in; re-check only the `TasksMax` sizing against the instance class. **No memory or CPU limit belongs on a single-tenant instance** |

> The reasoning — why `TasksMax` only, why a per-user memory cap kills legitimate large build or
> batch workloads, and why `CPUQuota` is deliberately absent — is owned by runbook
> §11.5–§11.5b, and the slice file's own header is the ground truth. Do not re-derive it here.

### 2.2 cgroup generation

- Shared hosts: detect per host (`stat -fc %T /sys/fs/cgroup`: `tmpfs` = v1, `cgroup2fs` = v2).
  The slice posture per generation is §2.1 / runbook §11.5.
- Per-user desktop: choose the image's OS deliberately — **build on a release that boots cgroup
  v2**, so no v1 consideration applies [PLANNED].

### 2.3 Home directories, and the sandbox

A directory service can publish a home directory that is a **symlink** to the real path on a
file server. bubblewrap cannot create a mount point through a symlinked parent, so every
`~`-derived sandbox path fails and every sandboxed command with it. With the sandbox disabled
(`SANDBOX-DECISION.md`) the defect is latent rather than load-bearing, but it returns with any
re-enable, and the workaround travels to the desktop image unless the directory is fixed first.

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Homes | Typically a network export, mounted on every host [UNVERIFIED — confirm per site] | Decide deliberately: storage local to the instance, or the same shared mount [PLANNED] |
| Sandbox impact | Where the published home is a symlink, all `~`-derived sandbox paths fail. Worked around by `/etc/profile.d/claude-code-home.{sh,csh}`, which resolve `HOME` to the real path and change nothing where it is not a symlink [HOST] | **Avoid the problem: do not symlink homes.** Publish the real path from the directory |
| Permanent fix | Publish the real path as the home-directory attribute in the directory service; the drop-ins are then not needed | Not applicable if homes are real paths from the start |

> **Carry-over risk:** a desktop image that joins the same directory service and inherits
> symlinked homes inherits this defect. Fix the directory attribute *before* the image is built
> and the workaround never needs to travel.

### 2.4 Identity and "log in once"

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Accounts | The site's directory service [UNVERIFIED — confirm per site] | The same directory, joined at first boot [PLANNED] |
| Credentials | Stored under the user's home. With homes on shared storage, **one login works on every host** and `--resume` works across hosts | If homes are **local** to each instance, each engineer logs in **once per instance**, and session history does not follow them |
| Action | — | Decide whether session history should follow the user. If yes, keep homes on shared storage or ship transcripts centrally |

Identity is not something a move to per-user desktops migrates: every instance is one more client
of the directory the shared hosts already use. Two things follow. Check where the directory
server sits relative to the desktop subnet, because login depends on that path. And check that
the directory bind is encrypted before multiplying its clients — over an unencrypted bind, every
additional instance is one more host sending the bind password in cleartext (§6).

### 2.5 Install model

Both shapes use the **same** model — one package per host, baked into an image (runbook §3.1) —
but the image differs:

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Image | Whatever provisions the shared servers | A golden machine image (AMI) |
| Version gate | `dnf versionlock` per host + `approved-version` | Same, baked into the image |
| Scale | A handful of hosts | One per engineer — **the image becomes the only sane path**; hand-installing per desktop does not scale |

> If the sandbox is ever enabled, the image must also carry the `apply-seccomp` helper — the
> `claude-code` RPM does not ship it. What that takes, and the conditions for enabling at all, are
> in `SANDBOX-DECISION.md` §4.

### 2.6 Egress and the sandbox network allowlist

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Path to Anthropic | The site's egress or corporate proxy [UNVERIFIED — confirm per site] | The desktop subnet's egress [UNVERIFIED] |
| Proxy/TLS variables | `HTTPS_PROXY` and `NODE_EXTRA_CA_CERTS` belong in the policy `env` block where the site inspects TLS; the shipped policy sets neither | Decide again for the desktop subnet; a shared-host answer may not apply |
| Internal domains | The site's internal domain, which the policy's `autoMode` block names | Confirm the same suffix resolves from the desktop subnet |

> Behind a TLS-inspecting proxy, the policy needs the proxy keys **in managed settings**, not in
> `/etc/profile` — background sessions may inherit no shell environment (runbook §5.2).

### 2.7 Audit logs

| | Shared host | Per-user desktop |
| --- | --- | --- |
| `/var/log/claude-code` | Host-local; a handful of hosts to collect from [HOST] | Host-local on **every instance** — with one desktop per engineer, per-host logs fragment badly |
| Action | Ship off-host (recommended) | **Shipping off-host is required** — an instance rebuild takes the logs, and there is one instance per person |

### 2.8 Data-protection posture

| | Shared host | Per-user desktop |
| --- | --- | --- |
| Where project and customer data sits | The site's shared storage | Depends on the storage decision in §2.4 |
| Network-export posture | **File modes are not a boundary on an export that other machines can mount with client-asserted identity** (`sec=sys`): anything that can mount it can read every credential and transcript stored there. Check how the home export is restricted, and record the answer in `internal/LIMITATIONS-AND-RISKS.md` [UNVERIFIED — confirm per site] | Do not carry an open export into the desktop design. Restrict exports to known clients, or use `sec=krb5`, or keep homes local to the instance |
| Contractual question | Unchanged by hosting: inference goes to Anthropic either way (runbook §1.5) | Identical. Hosting location does **not** change who processes the code |

---

## 3. Configuration that stays the SAME

Do not re-litigate these per shape — they are properties of Claude Code, not the host:

- The **policy file path** `/etc/claude-code/managed-settings.json` — compiled into the
  binary, per-host, immovable [HOST].
- The whole **fleet policy content**: deny list, `ask` rules, lock keys, `autoMode`
  classifier config with `$defaults`, `env` data-egress keys, `cleanupPeriodDays`
  (`SETTINGS-REFERENCE.md`).
- The **status line** (managed settings, one global script at
  `/usr/local/share/claude-code/statusline.sh`).
- The **evidence hooks** and the secret-filename guard.
- **`claude` is per-host, not client/server.** No desktop can point at a central Claude Code
  service; the binary runs where the shell is.
- The **health check** and the `cc-update.sh` workflow.
- **Product behaviours travel with the binary**: whether `Read`/`Edit` filename-glob deny rules
  enforce on Linux, which depends on the version (and is why the secret-filename guard hook exists), the
  version floor refusing any private install below it, and the sandbox helper defect
  (`SANDBOX-DECISION.md`). The denial log records both rule and classifier refusals on either
  shape; headless `claude -p` runs may not exercise it (`OPERATIONS.md` §4.2).

---

## 4. Things that get *easier* on a per-user desktop

Worth stating, so the move is not framed as pure cost:

- **Noisy neighbours disappear.** §2.1 and the whole runbook §11.5 discussion mostly stop
  mattering — one user, one instance.
- **Blast radius shrinks.** `failIfUnavailable: true` becomes far safer in principle: a sandbox
  dependency problem stops *one* engineer, not the whole team. **It stays blocked while the
  sandbox itself is unusable** — the helper defect fails every command in every session, and
  fail-open does not cover that error class (`SANDBOX-DECISION.md`) — so the hardening the
  runbook defers (§9.5, §9.7) becomes achievable only once the conditions in
  `SANDBOX-DECISION.md` §4 are met.
- **Rebuild is cheap.** A broken instance is replaced from the image rather than repaired.
- **Per-customer segregation becomes expressible.** The runbook notes it cannot be done with
  per-machine policy on a shared host (§1.5); with one instance per engineer, a
  per-customer instance and policy becomes a real option.

## 5. Things that get *harder* on a per-user desktop

- **Fleet size.** One instance per engineer instead of a handful of hosts — everything must be
  in the image or in configuration management; nothing hand-applied survives.
- **Log fragmentation** (§2.7) and **credential/session portability** (§2.4).
- **Cost visibility.** Idle instances cost money; the OpenTelemetry usage metrics (runbook §13)
  become more useful than they are on a shared host.

---

## 6. Transition checklist

| # | Before the first desktop image | Why |
| --- | --- | --- |
| 1 | Publish the real home path as the directory's home-directory attribute | Stops the symlink/sandbox defect travelling to the image (§2.3) |
| 2 | Build the image on an OS release that boots **cgroup v2** | No v1 consideration applies (§2.2) |
| 3 | Decide home storage: local to the instance, or shared | Determines login-once and history-follows-user (§2.4) |
| 4 | Stand up central log shipping | Per-instance logs fragment otherwise (§2.7), and nobody on the instance can read the health-check log (§8.5) |
| 5 | Ship the `TasksMax`-only slice file | Single-user instances should not be capped (§2.1) |
| 6 | Re-evaluate `failIfUnavailable: true` — **do not simply set it** | Blast radius is one engineer, so the hardening becomes affordable (§4). **But the sandbox is disabled in the shipped policy: its helper defect fails every command, and fail-open does not cover that error class.** Set it only once the conditions in `SANDBOX-DECISION.md` §4 are met. Runbook §9.7 |
| 7 | Confirm egress and proxy/CA needs from the desktop subnet | Shared-host proxy settings may not apply, or the reverse (§2.6) |
| 8 | Settle the home-export posture — do not replicate an open `sec=sys` export | Credentials, and any customer data the site holds, sit on it (§2.8) |
| 9 | Run `cc-preflight.sh` and `cc-audit.sh` on the first desktop | The build's own gate; records the baseline for the new shape |
| 10 | Confirm the directory bind is encrypted before the first desktop joins | Every instance is one more client of that bind (§2.4) |

> **Keep this file current as a move proceeds.** The risk it exists to manage is that a
> shared-host choice made for convenience — the `profile.d` `HOME` workaround, no memory limit,
> host-local logs — silently becomes the desktop design because nobody wrote down that it was
> specific to the shared host.

## 7. Where the build procedure lives

This document records *differences*. The ordered build procedures are in `OPERATIONS.md`:
Part 1 for a shared host and Part 2 for the machine image and the desktop (designed, not
validated — see the grading warning at the top of this file). Use this document to decide
*what* differs, and `OPERATIONS.md` to do it.

Two gaps that no document closes by being written, and that must be settled before the first
image:

- **No bake vehicle is shipped.** Nothing in `cc-install.sh` or the `Makefile` installs `aws/`;
  until an image pipeline exists, the "Installs to" column of [`../aws/README.md`](../aws/README.md)
  is the only instruction. The candidate vehicles and what each implies are in `OPERATIONS.md`
  §2.0. The version control the approach assumes does exist — a deploy is `git pull` then
  `cc-install.sh --apply` from a checkout — so the open question is the vehicle, not the
  repository.
- **No instance or volume specification.** A per-engineer desktop should not be sized like a
  shared server, and the sizing is a cost question that IT does not own alone (`OPERATIONS.md`
  §2.0).

---

## 8. Policy posture, privilege, and the user-namespace boundary

This is the largest single behavioural difference between the two shapes, and it follows
directly from tenancy (§1). The concrete artifacts are in [`../aws/`](../aws/README.md); this
section is the reasoning and the register.

### 8.1 Posture stops being a runtime switch and becomes an instance property

On a shared host, `cc-admin-session.sh` gives **one process tree** the loose admin policy while
everyone else keeps the strict fleet policy — a per-process switch that needs root, done via a
private mount namespace [HOST]. A desktop is single-tenant, so there is no "everyone else" to
protect: the instance simply runs the policy it was **provisioned with**, chosen once at boot by
`cc-apply-posture.sh`, run from the `claude-code-posture.service` oneshot as root before any
login [PLANNED]. The engineer never needs, and never gets, a runtime privilege for the *default*
posture.

- **Default / control / fallback / detection** are `aws/bin/cc-apply-posture.sh`: `fleet` unless
  `/etc/claude-code/posture` says otherwise; fails closed to `fleet` on any surprise; asserts the
  policy exists and parses, failing the systemd unit if not (a missing policy is fail-**open**, the
  one outcome worse than the wrong one).
- **The drift baseline is verified, never minted.** Each staged policy is baked with a `.sha256`
  beside it, and the selector refuses a staged policy that does not match its own checksum, then
  copies that baked value across as the runtime baseline. Recomputing the baseline from the file it
  had just written would make `cc-healthcheck.sh` §2 a tautology that always passes — and would
  silently re-certify a tampered staging directory on every boot.
- **`Before=` is ordering only, so it does not make login depend on the policy.** The hard
  dependency is `aws/systemd/systemd-user-sessions.service.d/10-claude-code-posture.conf`, which
  `Requires=` the posture unit so a failure refuses interactive logins rather than allowing an
  ungoverned one. That drop-in is optional and deliberately fail-closed: a desktop that will not
  log in is loudly broken and gets replaced (§4), whereas one that logs in with no policy is
  silently processing customer data outside the governed configuration. It gates PAM logins only,
  not the SSM agent, so Session Manager remains the break-glass path — **confirm SSM is enrolled
  in the image before shipping it.**

### 8.2 Managed settings are not a boundary unless unprivileged userns is off

With the sandbox disabled (`SANDBOX-DECISION.md`), the managed policy has **no kernel enforcement
behind it** — it is agent-side rules only. On a host with unprivileged user namespaces available,
any local user can neutralise it for their own sessions **without sudo**, by bind-mounting their
own policy file over `/etc/claude-code/managed-settings.json` inside a
`unshare --user --map-root-user --mount` namespace. The bind is private to that namespace: the
session inside it reads the substituted policy, the host view is untouched, and
`cc-healthcheck.sh` therefore cannot see it. `chmod`/`chown` on the directory does **not** prevent
it — a bind over a file needs traverse on the `0755` parent, not write on the target.

The fix is to remove the capability: `user.max_user_namespaces = 0`
(`aws/sysctl.d/50-claude-code-userns.conf`), required on **every** desktop. It does not break
`cc-admin-session.sh` (root, mount-namespace-only, not `--user`). **Known interaction to test on
the first image:** browser sandboxes are userns-based and the browser is the OAuth login path, so
login may need a setuid `chrome-sandbox` helper or `--no-sandbox` once userns is off
(`aws/README.md`, build-time check 2).

> Shared-host note, independent of AWS: read `sysctl -n user.max_user_namespaces` on each host.
> Any non-zero value means the fleet policy is a **guardrail, not a boundary**, against a
> determined local user. Ship the sysctl drop-in to shared hosts too, or record in
> `internal/LIMITATIONS-AND-RISKS.md` that the policy is advisory there. `cc-preflight.sh` judges
> the value against the deployed policy: `0` is correct with the sandbox disabled, and a blocker
> with it enabled.

### 8.3 `cc-admin-session.sh` does NOT retire — it narrows

Posture is baked at boot, so the admin session tool is absent from **engineer** desktops. It
stays on **admin** desktops, because an admin needs both policies reachable on one machine: the
strict one to run a new build against the rules and find what it breaks, the loose one to fix
what it finds. That per-process switch is exactly what the wrapper is for.

**An admin desktop therefore boots the FLEET posture, like every other instance**, and reaches
the loose policy per session. Baking `admin` on it would defeat the first of the two workflows
below — on a loose-posture instance there is no strict policy left to audit against, and the
wrapper's bind mount would be a no-op that leaves the scoped grant buying nothing but `-e`. Least
privilege points the same way: the loose policy should be something an admin steps into
deliberately and leaves, not the state their machine idles in. The `admin` posture value exists
for a dedicated always-loose instance, which is not what an admin desktop is.

| | Engineer desktop | Admin desktop | Shared host |
| --- | --- | --- | --- |
| Baked posture | fleet | **fleet** | fleet |
| `user.max_user_namespaces=0` | yes | yes | **should be** (§8.2) |
| `cc-admin-session.sh` | absent | **present** | present where built `--with-admin` |
| Grant to reach it | — | the scoped sudoers rule (§8.4) | the site's sudo arrangement (`ADMIN-SESSION.md` §5) |
| Shared eval binary | absent | present, root-owned, off `PATH` | `CC_EVAL_BIN` |

The two workflows then both work on one machine, and only one of them needs any privilege:

- **Gap audit** (eval binary × *strict* policy): run the shared eval binary directly. It reads the
  instance's active policy, which is the fleet one. No sudo, no bind mount. `-e` does not cover
  this — `-e` always pairs the eval binary with the *loose* policy.
- **Admin helper** (binary × *loose* policy): `sudo cc-admin-session.sh [-e]`. The only path needing
  the scoped grant, because loosening the policy for one process needs root.

### 8.4 The scoped sudoers grant, and its precondition

`aws/sudoers.d/cc-admins-admin-session` grants the admin group exactly one command — the
hardened, logged wrapper — as root, `NOPASSWD:NOSETENV:`. It is an allowlist entry, not general
root, and it makes membership of the admin group (`CC_ADMIN_GROUP`) the single control point once
that group is directory-backed and `CC_ADMIN_USERS` is emptied (the group is the half that can
gate a sudoers row; the name list cannot). Until then the wrapper authorises on either, so an
unemptied list masks an unresolved group.

`NOSETENV` is part of the grant, not decoration: the wrapper's loader honours `$CC_CONFIG_LIB` first
and sources it as root, which is safe only while sudo's `env_reset` default strips it.

**Precondition, load-bearing:** the wrapper enforces a target-user policy — the agent runs as the
invoker, never uid 0, never another account. Without it, `-u root` turns the one-command grant back
into unrestricted root, since the loose policy permits `sudo` inside the session. Verify the
wrapper's header carries the `TARGET-USER POLICY` block before deploying the rule against it.

The grant shape is not desktop-only: `ADMIN-SESSION.md` §5 gives the same rule for a shared host,
with `PASSWD:`. The two positions differ for one reason. On a desktop the admin holds no other
sudo, so there is nothing beside the rule for a password to guard, and a prompt would only hang
non-interactive work. On a shared host the invoker may hold other sudo rights, and a password on
this one command is what makes opening a privileged session a deliberate act. Do not change one
position without the other.

### 8.5 Nobody has sudo on a VDI, so nothing root-requiring has an executor

Engineers do not get sudo on their own desktop, and admins get exactly one allowlisted command.
That is a design decision, and it has a consequence the shared-host procedures do not account
for: **every root-requiring step in `OPERATIONS.md` Part 1 and the `RUNBOOK.md` fix procedures has
no one on the instance who can run it.**

- `cc-install.sh --apply`, `cc-update.sh` and the version-bump flow all need root. On a desktop
  they become an SSM document, a configuration-management run, or an image rebuild and instance
  replacement. There is no "log in and fix it", which is what §5's "nothing hand-applied survives"
  means in practice.
- The healthcheck timer runs as root and writes to a root-owned log the engineer cannot read, so
  central log shipping is the only way anyone sees its output — a second, independent reason for
  §2.7 beyond fragmentation.
- Remediation for flagged drift is a ticket and a rebuild, not a repair. That is the intended
  posture (rebuild is cheap, §4), but it must be written down, because the runbook assumes an
  operator with sudo on the host.
