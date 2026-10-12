# Claude Code on Rocky Linux 8

IT Deployment & Operations Runbook  |  For IT operators

| | |
| --- | --- |
| **What** | The *why* of this deployment and the product's behaviour — the decisions-and-product reference. Not the state record and not the build procedure |
| **Who** | IT staff operating or extending the deployment. No prior knowledge of this repository is assumed; `README.md` gives the reading orders |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and [`UPGRADES.md`](UPGRADES.md) records every move of it. Re-verified at each bump (`OPERATIONS.md` Part 7) |
| **Where** | Every Linux host in the fleet, each deployed individually (`cc-install.sh --apply` on each host). Windows machines and the Claude desktop app are out of scope (§1.4) |
| **Why** | Decisions and product behaviour outlive any one host's state, so they live apart from `CURRENT-STATE.md` (state) and `OPERATIONS.md` (procedure). New decisions do **not** go here — each gets its own record in the `SANDBOX-DECISION.md` shape |
| **Status** | In force. §9 (the sandbox) is retained as design reference only — the shipped policy disables the sandbox (`SANDBOX-DECISION.md`). What has been verified, and on which hosts, is each site's own record in `CURRENT-STATE.md`. Re-verify §7–§9 against code.claude.com at each version bump |
| **Owner** | The maintainer |

> **Where to look instead of here.** This runbook answers *why*. Three other documents answer the questions
> people more often have, and they are authoritative over this one on their own subjects:
>
> | Question | Document |
> | --- | --- |
> | What is live right now? Which hosts? What files, what open findings? | **`CURRENT-STATE.md`** |
> | How do I build a host, move a version, or recover from a failure? | **`OPERATIONS.md`** |
> | What does this setting do, and is it safe to change? | **`SETTINGS-REFERENCE.md`** |
>
> `docs/README.md` indexes the whole set with reading orders. Where this runbook implies a state that
> `CURRENT-STATE.md` contradicts, `CURRENT-STATE.md` is correct.

> **Scope: a multi-host fleet, governed per host.** Several interchangeable hosts, each deployed
> individually. Home directories may be on shared network storage, in which case `~` — and so every
> credential and transcript — is the same on every host (§17, §18). Every control in this
> document is a **per-host** control protecting **fleet-wide** assets, so read every control statement as
> scoped to the hosts that have it — which hosts those are is each site's own record in
> `CURRENT-STATE.md`. The deployable artefacts live in this repository: the policy in `settings/`, the evidence-layer
> hooks in `hooks/`, the slice drop-in in `systemd/`; `README.md` indexes the layout.
>
> Callouts below are graded **[RPM]** (read from the package) or **[UNVERIFIED]** (not tested); an
> ungraded statement about product behaviour is taken from the documentation at code.claude.com.
>
> **Install model:** RPM-per-host, baked into the golden image — *not* a central binary on shared storage. §3.1 has the
> reasoning.

## 1. Scope and deployment model

This runbook covers the IT-controlled deployment of Claude Code on shared Rocky Linux workstations accessed by engineers over RDP — the fleet described in the scope block above. It is written for the team that owns those hosts: what to build once, what to keep running, and what to do when something changes. Its subject matter is central policy, deny-by-default tool control, version gating and ongoing maintenance; self-service developer laptops are out of scope.

Almost everything here applies **per host** — the policy file, the health-check timer, the resource slice are per-host controls. Delivery is by golden image / configuration management rather than hand-placing files on one box: read "the instance" below as "each host built from that image."

### 1.1 Deployment decisions this document assumes

| **Decision** | **Value** | **Consequence** |
| --- | --- | --- |
| Platform | Rocky Linux 8 or 9, x86_64 | Served by the Anthropic dnf repository. Not on the published supported-OS list; validate on a pilot host. Anything OS-version-specific — the cgroup generation above all (§11.5) — is handled per host class. |
| Users | Multiple engineers per shared host, RDP desktop sessions; homes local or on shared network storage | Every user gets their own Linux account and credential file. Where homes are shared between hosts, that credential file and the transcripts are the *same file* on every host, not a per-host copy: policy is per host (the `/etc` file is local), credentials are fleet-wide (§18). |
| Authentication | A claude.ai Team plan (an Enterprise plan logs in the same way), claude.ai OAuth login | No API keys to issue or rotate. Each engineer logs in once with their own account. |
| Instances | One gated **image**, released by IT | Version is pinned and moved deliberately. Auto-update is disabled. Bake the RPM + versionlock + policy into the golden image so every host boots identical. |
| Policy delivery | Endpoint-managed settings file on the instance | Strongest option available: the file is root-owned on a machine users do not administer. |
| Tool policy | Deny by default, narrow allowlist | Covered in section 8. Two postures are given; pick one. |

### 1.2 Deployment context

The questions every site has to answer before it builds, the answer this design assumes, and what follows from it. A site records its own answers in `CURRENT-STATE.md`, so the next person does not have to re-establish them.

| **Question** | **Answer this design assumes** | **Consequence for this runbook** |
| --- | --- | --- |
| Where does inference run? | Anthropic infrastructure, via api.anthropic.com | Code and prompts — a customer's included, where the host holds any — are sent to Anthropic as the model provider. This is a property of the Claude for Teams agreement, not of where the hosts run — it is identical on a cloud instance and on a server in the office. The contractual question this raises is section 1.5; it is not a network-design question. |
| Does the organisation have machines this policy does not reach? | Possibly. The policy is a file on each governed Linux host; Windows machines and the Claude desktop app do not read it | This runbook governs the Linux hosts. No PowerShell permission rules, no Windows managed settings file. See section 7.5 for the residual exposure. |
| Server-managed or endpoint-managed policy? | Endpoint-managed, on the hosts themselves | Deliberate. Per-machine scope is the requirement, not a limitation — these hosts must be able to be stricter than the rest of the organisation's machines, and server-managed cannot express that. |
| Is auto mode permitted? | Yes — the shipped policy configures it | Reversal of the reflex to disable it. The classifier runs after the permission system, so the deny list still holds. See section 8.5. |
| How many hosts? | Any number, and the number will change. Each is governed only once `cc-install.sh --apply` has run on it | The per-host list and its coverage are `CURRENT-STATE.md` — never this row. Verify each host on its first build (§18). |
| Which identity source? | Any directory that gives each engineer one Linux account with a home under `CC_HOME_ROOT` | Where the directory hands out a home path that is a symlink, the `profile.d/claude-code-home` drop-ins resolve it (`OPERATIONS.md` §1.6). |
| Where are home directories? | Local disk or shared network storage | On shared storage the export's own access control decides who can read a credential, whatever its file mode; see §17. |
| Is egress open? | The hosts of §5.1 are reachable | `cc-preflight.sh` tests each of them and fails on a mandatory one it cannot reach. |

### 1.3 Ownership and review

| | **Value** |
| --- | --- |
| Document owner | The maintainer |
| Claude organisation owner | The person accountable for keeping the claude.ai console managed settings EMPTY, per section 7.3 |
| Validated against Claude Code version | The pinned build, from the RPM stable channel (`requiredMinimumVersion`; `UPGRADES.md` records every move). A private per-user install is outside that validation; probe A5 of `cc-bump-audit.sh` lists the ones below the floor (§3.3) |
| Release-notes and advisory watch | A named person subscribed to Anthropic release notes and advisories, with a recorded support route. This design depends on several undocumented behaviours (`LIMITATIONS-AND-RISKS.md` Part 3), so an unassigned watch is a real gap |
| Review cadence | Quarterly (`OPERATIONS.md` §4.2), and before every version bump |

Each site records who holds these roles in `CURRENT-STATE.md`. Claude Code ships frequently and settings keys are added often, so an unowned copy of this document is actively misleading within a quarter. The review task is in the section 11 cadence table.

### 1.4 What this document does not cover

- Amazon Bedrock or Claude Console authentication. Both are viable and would change sections 5 and 6 substantially; if the Teams model is revisited, this runbook needs a companion section rather than an edit.
- Developer workflow, prompting practice, or how to use Claude Code productively. That belongs in a separate user runbook.
- Network design — firewalls, proxies and address translation. The network requirements in section 5 state what must be reachable; how you permit it is your existing egress pattern.
- Windows machines and the Claude desktop app. Those are governed from the claude.ai admin console, not from these hosts — see section 7.4. The one place the two touch is the residual Claude Code exposure on Windows, recorded in section 7.5.
- **The configuration of shared storage.** Who may mount an export, and with which security flavour, is a storage-team matter, not a Claude Code setting; §17 states what to check and why.

> **Version note:** Every command, path and setting key in this document is checked against the official Claude Code documentation at code.claude.com for the pinned build. Claude Code ships frequently and settings keys are added often. Re-verify section 7 and 8 against the settings reference before each version bump.

### 1.5 Data handling and customer obligations

Two questions are independent and are easily conflated. Keeping them apart is what makes the second one answerable.

| **Question** | **What it turns on** | **What it does not affect** |
| --- | --- | --- |
| Where does the workstation run? | A cloud instance, a local server in the office, or a laptop. An infrastructure and access-control decision: it drives RDP, egress path, instance sizing, AVX availability and rebuild from an image. | Nothing about who processes customer code. The data flow to the model provider is identical on a cloud instance and on a server in the building. |
| Who performs inference, under which agreement? | Claude for Teams means Anthropic is the provider, under Anthropic's commercial terms. Amazon Bedrock, Google Cloud's Agent Platform and Microsoft Foundry each move inference to that vendor, under that vendor's agreement. | Where the workstation is hosted. Bedrock on a local server and Anthropic direct on a cloud instance are both coherent combinations. |

**What is established.** Claude for Teams is a commercial plan, and Anthropic's published policy for commercial plans is that it does not train generative models on code or prompts sent to Claude Code, unless the organisation has explicitly opted into a programme such as the Development Partner Program. Standard commercial retention is 30 days. Zero data retention is available for Claude Code on Enterprise only, enabled per organisation after an eligibility check — it is not part of the Team plan and not part of the standard Enterprise plan either. Re-confirm all of this against the Commercial Terms of Service for the plan actually purchased, and record the date.

**What is not established, and needs an owner.** These are contractual and commercial questions, not technical ones. This runbook cannot answer them; it can only refuse to let them stay implicit.

- Do the organisation's customer agreements and NDAs permit that customer's data to be sent to a third-party AI provider as a processor? Some customers name approved sub-processors explicitly. Owner: whoever holds the customer contracts, not IT.
- Is 30-day retention at Anthropic acceptable for every customer whose work will touch this host, or does one of them require zero data retention — which would mean moving from Team to an eligible Enterprise agreement?
- Is per-customer segregation needed, and can this host express it? If customer A's contract permits sending their data to Anthropic and customer B's does not, a single workstation can go some way towards separating them: restrict execution of the claude binary to a claude-users group, own each project tree by a per-customer group at mode 0750, and deny the restricted paths in both permissions.deny and sandbox.filesystem.denyRead, where managed settings make them unliftable. Three limits stop that being a guarantee. Path-based rules do not survive a copy, and staging a file into a scratch directory is routine rather than malicious. An engineer assigned to both customers cannot be expressed at all, because managed settings are per-machine and not per-user. And while failIfUnavailable remains false, the OS-enforced half of the boundary is best-effort by design — see section 9.5. Which answer is adequate therefore depends on how the obligation is written: a duty to apply reasonable technical measures controlling access is satisfied by the design above, documented and tested; a clause stating that customer materials shall not reside on systems able to reach a third-party AI service is not, because the files are present on a host that can. Read the clause before building anything. Note also that a second instance is unusually cheap here — an image plus this bundle, per section 11.3 — whereas a bespoke per-customer permission scheme is a permanent maintenance and audit obligation carrying a caveat you would have to explain to the customer who asked. Owner: whoever holds the customer contracts, with IT advising on feasibility.
- Who signs off, and is the decision recorded somewhere a customer audit would find it? Record it alongside the roles of section 1.3.

> **File modes are a boundary only where the storage enforces them.** If project trees or home directories
> are on a network export that other hosts can mount with a client-asserted identity, per-customer 0750
> group ownership is not a boundary against those hosts. Settle that (§17) **before** relying on any
> path-based per-customer scheme.

**Paths that carry code to Anthropic outside the inference request.** Three product features send conversation content, including code, independently of any model request. None of them is a tool call, so no permission rule, deny list, classifier rule or sandbox setting touches them. The env block is the only control, and all three are disabled in the deployed policy.

| **Feature** | **What it sends** | **Retention** | **Control** |
| --- | --- | --- | --- |
| /feedback, /bug, /share | Conversation history including code, and optionally opens a PUBLIC GitHub issue | 5 years | `DISABLE_FEEDBACK_COMMAND` |
| Session quality survey follow-up | Session transcript, subagent transcripts and the raw session log. Known key patterns are redacted; source and file contents are not | 6 months | `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` |
| Operational metrics and error reports | Latency, reliability and usage. Metrics never include code, prompts or file paths; error reports are redacted before leaving the host | — | `DISABLE_TELEMETRY, DISABLE_ERROR_REPORTING` |

CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC covers all of these in one variable. The deployed policy sets it and also lists them individually, so an audit report shows which path each one closes and /feedback does not rest on the umbrella. Neither approach affects the OpenTelemetry export to an internal collector in section 13, nor the WebFetch hostname safety check, which sends only a hostname and has its own opt-out.

> **The first row is the one to check on any host holding customer IP:** an engineer typing /feedback because Claude did something odd would, by default, send that session's customer source to Anthropic with a five-year retention and an option to file it publicly. Nothing in the tool policy prevents it, and no audit of permission rules would reveal it. Confirm DISABLE_FEEDBACK_COMMAND is in force with claude doctor and section 3 of the audit report.

**If the answer is that customer IP must not reach Anthropic at all.** That is not a reason to abandon the deployment; it is a reason to change the provider. Amazon Bedrock keeps inference inside AWS under the AWS agreement, with IAM-based authentication and no Anthropic login. It would rewrite sections 5 and 6 and is recorded as out of scope in section 1.4, but it is the lever that exists. Establish the contractual answer before the pilot opens to real customer projects, because retrofitting a provider change after engineers have run customer work through the current one does not undo the first request.

## 2. Platform prerequisites

### 2.1 Supported platform status

The published system requirements list macOS 13+, Windows 10 1809+, Ubuntu 20.04+, Debian 10+ and Alpine Linux 3.19+. Rocky Linux is not named. However, Anthropic publishes a signed dnf repository explicitly for Fedora and RHEL, and Rocky 8 is a RHEL 8 rebuild, so the packaged path is available to you.

> **Treat this as supported-in-practice, not supported-on-paper:** validate the binary on a pilot instance before fleet rollout, and record the validation as part of the change. If you later open a support case, expect to be asked to reproduce on a listed distribution.

> **[RPM]** The RPM's only dependency is `glibc >= 2.17`, and Rocky 8 and Rocky 9 are both RHEL rebuilds
> served by the same repository, so the packaged path is available on both. The per-version divergence
> that matters is the cgroup generation (§11.5).

### 2.2 Hardware and instance sizing

| **Requirement** | **Minimum** | **Notes for a shared RDP host** |
| --- | --- | --- |
| RAM | 4 GB | That is the per-user floor. Budget roughly 2 GB per concurrent interactive session on top of the desktop environment. |
| Architecture | x86_64 or ARM64 | Both are served. Do not mix architectures across your build and your instance. |
| CPU instruction set | AVX required on x86_64 | The native binary uses AVX. Confirm the hypervisor exposes it; without it the binary aborts with 'Illegal instruction'. |
| Disk | Sized for per-user session data | Each home directory accumulates transcripts under ~/.claude. Governed by cleanupPeriodDays; see section 11. |

On a virtual machine, verify explicitly that the hypervisor exposes AVX rather than assuming it, because a mismatch here is a hard failure with an obscure error message. The preflight script runs this check; the manual command is `grep -m1 -ow avx /proc/cpuinfo`.

> **Size from measurement, not from an assumed specification.** This matters for the resource slice (§11.5),
> and is one reason the delivered drop-in carries only `TasksMax`. Check each host's specification
> separately — a fleet is not necessarily uniform.
>
> **Disk note:** transcripts are not the only per-user consumer — Claude Code also keeps a cache under
> `~/.cache/claude-cli-nodejs/`. Where homes are on shared storage, both land on that volume; budget for it (§11.6).

### 2.3 C library

Rocky 8 ships glibc, which is the variant the installer should select. A stray musl cross-compilation toolchain on the host can make the installer misdetect the platform and fetch the musl binary, which then fails with `Error loading shared library libstdc++.so.6`. Confirm before installing:

```bash
ldd --version | head -1        # expect: ldd (GNU libc) 2.28
ls /lib/libc.musl* 2>/dev/null # expect: no such file
```

> **[RPM]** The binary is dynamically linked against base glibc only (libc/libm/libpthread/libdl/librt)
> with a highest required symbol of `GLIBC_2.17`, so it runs on any EL7-or-later host.

### 2.4 Preflight validation

Run `cc-preflight.sh` as root on the target instance before installing. It checks platform, AVX, memory, libc, sandbox dependencies, browser availability, loopback, and outbound reachability to every host Claude Code needs. It exits non-zero on a hard blocker, so it can gate an automated build.

```bash
. lib/cc-config.sh          # from the checkout; QUICKSTART.md §9 lists the keys
sudo bash bin/cc-preflight.sh    # from the checkout: nothing is installed yet
```

> On a *fresh* host, preflight warns on two things, neither of which is a FAIL: `socat` not yet installed
> (§3.4) and `/etc/claude-code` not yet existing (§3.2). Both are resolved by the build. It also notes any
> pre-existing per-user native install (§3.3), which **must** be resolved first — see `OPERATIONS.md` §1.1.

## 3. Installing Claude Code

### 3.1 Choosing an install source

Three sourcing models are viable for a gated deployment. They differ mainly in how much of the supply chain you take ownership of.

| **Model** | **How it works** | **Control** | **Maintenance burden** |
| --- | --- | --- | --- |
| Anthropic dnf repository, stable channel, version-locked | Instance pulls signed RPMs from downloads.claude.ai. IT pins the version with dnf versionlock and moves it deliberately. | High. Version cannot move without an explicit unlock. | Low. One repo file, one lock entry, one update script. |
| Internal mirror | You reposync the Anthropic RPM repository into Artifactory or Satellite. The instance never contacts downloads.claude.ai. | Highest. You decide which versions exist at all, and can scan them first. | Medium. A sync job, storage, and a second signing/trust story to maintain. |
| Pinned native binary | IT stages one vetted binary, sets DISABLE_UPDATES, replaces it only on an approved change. | Highest on paper, but bypasses package management entirely. | High. No dependency handling, no rpm verification, manual placement and PATH. |

> **Recommendation:** start with the Anthropic dnf repository plus versionlock. It gives you a hard version gate on day one with almost no infrastructure, and every RPM is signature-verified by dnf automatically. Move to an internal mirror only if your supply-chain policy requires that no production host reach an external repository — the control gain over a version-locked repo is modest, and the pinned-binary option gives up package management for no additional control.

> **Decision — RPM-per-host, baked into the golden image (not a central binary on shared storage).** The
> tempting fourth option on a fleet with shared storage is *one* binary on a network mount that every host
> runs. Don't. Where homes are shared, the thing that benefits from being central — identity, credentials,
> history — is **already** central, so "log in once, works on every host" already holds. Putting the
> *binary* on network storage instead adds a fleet-wide single point of failure (a storage blip kills
> `claude` on every host at once) plus network exec latency, in exchange for a trivial disk saving
> (~294 MiB local per host), and it forfeits dnf's automatic signature check. RPM-per-host keeps each host
> self-sufficient and signature-verified; "per-host" is not "per-host effort" once it is in the golden
> image. This is also what the operational scripts (§12) implement — a central binary would mean rewriting
> `cc-update.sh` and the "healthy = owned by the RPM" logic in `cc-healthcheck.sh`.

### 3.2 Repository setup

The repo file, the GPG fingerprint to verify, and the install-and-versionlock sequence are specified once, in `QUICKSTART.md` §4 (Method A); the ordered build procedure that runs them is `OPERATIONS.md` §1.3–§1.4. Build from those, not from here. The deployment uses the **stable channel**, which is typically about one week behind the latest release and skips releases with major regressions.

Facts about the package that shape the procedure, read from the RPM itself **[RPM]**:

- The GPG signing key id is `baa929ff1a7ecace` and matches the published fingerprint (`QUICKSTART.md` §4 holds the digits — verify against that, out of band). A failed key download surfaces later as `NO_PUBKEY BAA929FF1A7ECACE`.
- The package installs **exactly two files** — `/usr/bin/claude` (~294 MiB, root:root 0755) and `/usr/share/doc/claude-code/copyright` — with **no scriptlets**. In particular it does **not** create `/etc/claude-code`: creating that directory is a build step (`OPERATIONS.md` §1.4), and any command writing under it fails until that step has run.

> **Package name versus command name:** the RPM is called claude-code; the command users type is claude. Both appear throughout this document and they are not interchangeable.

### 3.3 What not to do on a Method-A host

On any host where IT owns the binary lifecycle — Method A in `QUICKSTART.md` §4 (`QUICKSTART.md` §6 states the recommendation):

- Do not use the `curl | bash` native installer. It installs per-user into $HOME/.local, auto-updates in the background, and would give every engineer a different, self-updating version on the same machine.
- Do not install via `npm`. Same problem, plus a Node.js 22+ dependency you do not otherwise need.
- Never run either installer with `sudo`.

This prohibition is scoped to the deployment method, not absolute: `QUICKSTART.md` §5 (Method B) deliberately hands engineers the native installer on a governed host where IT cannot yet own the binary lifecycle — governance is retained, version discipline is not. That tradeoff is owned by `QUICKSTART.md` §6.

The health check script flags any per-user install it finds under `~/.local/bin/claude`, because that binary shadows the managed RPM on that user's PATH and silently exits your change control.

> **Resolving private installs is the first step of any build.** A private install below the
> `requiredMinimumVersion` floor refuses to start; one above it updates itself in the background, which is
> exactly the behaviour the packaged path exists to prevent. Where homes are on shared storage, each one is
> effectively present on every host the user logs into and shadows `/usr/bin/claude` on `PATH`
> everywhere — and equally, removing one cleans every host at once. An install *tree* can exist with no
> launcher on `PATH`, so a survey that tests only `~/.local/bin/claude` misses some.
>
> **Resolve the search path before installing anything** (`OPERATIONS.md` §1.1), or every subsequent
> verification — `claude --version`, `rpm -qf $(command -v claude)`, `claude doctor` — silently interrogates
> the private binary and returns a plausible, wrong answer. Then let the health check watch for their return.
>
> **This is a conversation before it is a cleanup.** A private install is someone's working tool and may have a
> live session attached, and the version floor stops the below-floor ones without warning. Tell those
> engineers, or lower the floor until they have migrated (`OPERATIONS.md` §3.4).
>
> **Relocating per-user state (reference):** `CLAUDE_CONFIG_DIR` relocates the *entire* `~/.claude` +
> `~/.claude.json` store, credentials included — the way to move per-user state off shared storage onto
> local disk. The one path it does **not** move is `/etc/claude-code` — that location is compiled into the
> binary (§7.1).

### 3.4 Sandbox dependencies

The shipped policy **disables the sandbox**; `SANDBOX-DECISION.md` is authoritative on the status, the failure and the re-enable conditions. Nothing on the host therefore *requires* `bubblewrap` or `socat`; leaving them installed is harmless and keeps the re-enable option open. A working `bwrap` alone does not prove the sandbox starts: Claude Code also runs its own `apply-seccomp` helper inside it (`SANDBOX-DECISION.md` §2.2).

**`socat` is in Rocky 8's base `appstream` repository; EPEL is not required and must not be added for it.** `dnf provides socat` on the host itself is the check — run it before any change record says "requires EPEL". Adding a third-party repository for a package the base distribution already ships is a permanent expansion of the supply chain on a host holding customer data.

Roles, for whenever the sandbox is re-enabled (the gate is `SANDBOX-DECISION.md` §4): the product documents **bubblewrap** for filesystem/process isolation and **socat** as the network relay through which the sandbox proxy enforces the domain allowlist — so socat matters only for sandboxed commands that use the network. Resolve the provider on the host itself before committing to the posture, rather than trusting any document — including this one:

```bash
# target host, as root, real terminal
dnf provides bubblewrap socat        # confirm which repo serves each
sudo dnf install bubblewrap socat
# 0 is REQUIRED when the sandbox is disabled (it stops a no-sudo user
# bind-mounting their own policy over managed-settings.json); non-zero is
# required only if the sandbox is enabled. LOCAL-VS-AWS.md 8.2
sysctl user.max_user_namespaces      # non-zero ONLY if sandbox.enabled is true
```

**Pass:** both packages resolve from the base distribution repos, **and the sysctl matches the posture**: non-zero if the deployed policy enables the sandbox, `0` if it does not. The two are opposite requirements and the value alone means nothing without the policy beside it.
**Fail:** if `dnf provides` names a repository the host does not carry, stop — adding a repository is a supply-chain decision, not a build step. With the sandbox **enabled**, `0` means user namespaces are off and the sandbox cannot start. With the sandbox **disabled** — the shipped posture — a non-zero value is the finding instead: any local user can then bind-mount their own policy over the managed one inside a user namespace and run ungoverned (`LOCAL-VS-AWS.md` §8.2).

The optional seccomp filter adds Unix domain socket blocking. If you want it, it is an npm package: `npm install -g @anthropic-ai/sandbox-runtime`. Everything else works without it.

## 4. Version control and update gating

### 4.1 Why the packaged install is the gate

Package-manager installations do not auto-update through Claude Code. Updates arrive only through your normal system upgrade workflow. That is the property you want, and it is why the packaged path was chosen over the native installer.

Two further belts are worth adding on a shared host, because a user who side-installs the native binary would otherwise get background auto-updates:

| **Control** | **Where** | **Effect** |
| --- | --- | --- |
| `dnf versionlock` | Host package manager | A routine 'dnf upgrade' cannot move claude-code. This is the primary gate. |
| `DISABLE_AUTOUPDATER` | env block in managed settings | Stops the background update check. claude update and claude install still work. |
| `DISABLE_UPDATES` | env block in managed settings | Blocks every update path including manual. Use when you distribute the binary yourself. |
| `requiredMinimumVersion` | Managed settings (managed-only) | Claude Code refuses to start below this version. Fail-open: an invalid value is stripped, not enforced. |
| `requiredMaximumVersion` | Managed settings (managed-only) | Refuses to start above this version. Useful to hard-stop a user's side install. |
| `autoUpdatesChannel` | Managed settings | Set to 'stable' so any path that does update lands about a week behind latest. |

> **Fail-open matters:** requiredMinimumVersion and requiredMaximumVersion are stripped rather than enforced if the value is malformed. Validate the JSON after every edit — the audit script does this — or you will believe you have a floor that is not there.

> `versionlock` governs only the RPM, not a `~/.local` copy. `DISABLE_AUTOUPDATER` in the policy is what
> stops a side-installed native binary updating itself in the background, and `requiredMaximumVersion` is
> available to hard-stop a stray newer side install.

### 4.2 The update workflow

`cc-update.sh` is the only sanctioned path from one approved version to the next, and it refuses to swap the binary while sessions are running — important on a shared host. The full workflow — check, stage, release-notes review, change record, apply, post-change audit diff, rollback — is owned by `OPERATIONS.md` Part 3 (§3.1–§3.5), together with the traps specific to version moves (§3.3 there) and the coordination of the version floor with private installs (§3.4 there). Do not run a version move from this section.

On an image-built fleet the primary update path is bumping the image; `cc-update.sh` remains the out-of-band / single-host path (e.g. a security advisory between image builds).

### 4.3 How often to move

Monthly on the stable channel, with an out-of-band path for security advisories. The reasoning: quarterly leaves you far behind on security fixes, weekly spends more change-management effort than the product warrants. The executable cadence and procedure are `OPERATIONS.md` Part 3 and §4.2 there.

## 5. Network requirements

### 5.1 Hosts that must be reachable

This is the complete documented allowlist. Three of these hosts are enough for install and inference but **not for login**: OAuth token exchange goes to `platform.claude.com`, and sign-in redirects through `claude.com`. Omitting either breaks authentication while leaving the install looking healthy.

| **Host** | **Required for** | **Needed here?** |
| --- | --- | --- |
| `api.anthropic.com` | Model inference, WebFetch safety check, feature flags, telemetry | Yes, mandatory |
| `platform.claude.com` | OAuth token exchange, refresh and revocation — for claude.ai logins too | Yes, mandatory |
| `claude.ai` | claude.ai account authentication | Yes, mandatory |
| `claude.com` | Sign-in page that redirects to claude.ai | Yes, mandatory |
| `downloads.claude.ai` | RPM repository, signing keys, binaries | Yes, for install and updates |
| `code.claude.com` | Documentation lookups by the built-in guide agent | Recommended |
| `registry.npmjs.org` | npx-launched MCP servers, plugin dependencies | Only if MCP or plugins are permitted |
| `mcp-proxy.anthropic.com` | claude.ai MCP connectors | No — disabled by policy in section 8 |
| `storage.googleapis.com` | Plugin metadata, artifact uploads | Only if plugins are permitted |
| `raw.githubusercontent.com` | Changelog feed for /release-notes | Optional |
| `bridge.claudeusercontent.com` | Claude in Chrome extension bridge | No |
| `formulae.brew.sh` | Homebrew version checks | No |
| `http-intake.logs.us5.datadoghq.com` | Operational telemetry | Optional; disabled by policy |
| `browser-intake-us5-datadoghq.com` | Operational error reports | Optional; disabled by policy |

> **Name-based, not IP-based:** Anthropic does not publish fixed IP ranges for these hosts, and several are CDN-fronted. Firewall rules written as IP ranges cannot express this allowlist. If your egress policy is deny-by-default at the network layer, you need an explicit proxy, or a firewall that filters on the TLS server name or the DNS name, in front.

> If the sandbox network allowlist (§9.2) is on, remember it is a *separate* allowlist from this egress
> list — any internal service the agent needs has to be named there, under the site's own internal domain.

### 5.2 Proxy and TLS configuration

If the instance reaches the internet through a corporate proxy or a TLS-inspecting gateway, these are the variables Claude Code reads. All of them can be set in the env block of managed settings, which is the right place on a shared host — see the note below about background sessions.

| **Variable** | **Purpose** |
| --- | --- |
| `HTTPS_PROXY` | Primary proxy. Lowercase variants also work; first set wins in the order https_proxy, HTTPS_PROXY, http_proxy, HTTP_PROXY. |
| `HTTP_PROXY` | Fallback where HTTPS proxying is unavailable. |
| `NO_PROXY` | Bypass list. Space- or comma-separated; '*' bypasses everything. |
| `NODE_EXTRA_CA_CERTS` | Path to a corporate root CA in PEM form. |
| `CLAUDE_CODE_CERT_STORE` | Which trust stores to use: 'bundled', 'system', or both. Default is bundled,system. |
| `CLAUDE_CODE_CLIENT_CERT` | Client certificate for mTLS. |
| `CLAUDE_CODE_CLIENT_KEY` | Client private key for mTLS. |
| `CLAUDE_CODE_CLIENT_KEY_PASSPHRASE` | Passphrase for an encrypted client key. |

- SOCKS proxies are not supported.
- Claude Code trusts both its bundled Mozilla CA set and the OS trust store by default, so a properly installed corporate root certificate usually needs no extra configuration. Zscaler and CrowdStrike Falcon style inspection works this way.
- Set these in managed settings, not in `/etc/profile`. Background agent sessions run under a per-user supervisor process that outlives the shell and may inherit no shell environment at all. A proxy exported only in a login script reaches interactive sessions and silently misses background ones.

### 5.3 Verifying

```bash
# reachability, one host at a time
for h in api.anthropic.com platform.claude.com claude.ai claude.com \
         downloads.claude.ai code.claude.com; do
  printf '%-28s ' "$h"
  curl -sSI --max-time 10 "https://$h" >/dev/null && echo OK || echo FAIL
done
```

```bash
# confirm proxy and CA files actually loaded
claude --debug        # writes to ~/.claude/debug/<session-id>.txt
# then in a session: /status  -> Proxy, mTLS and CA rows
```

## 6. Authentication

### 6.1 The model

Claude for Teams uses browser-based OAuth. There is no API key to provision, distribute or rotate. An organisation admin invites each engineer from the Teams admin dashboard; the engineer then signs in with their own Claude account the first time they run claude on the instance.

Because every engineer has their own Linux account, every engineer has their own credential store. Nothing is shared, and one person logging out does not affect anyone else.

| **Aspect** | **Detail** |
| --- | --- |
| Credential location on Linux | `~/.claude/.credentials.json`, file mode 0600, owner-only. |
| Managed by | `/login` and `/logout` inside a session. |
| Alternate location | If `CLAUDE_CONFIG_DIR` is set, the file lives under that directory instead. |
| Expiry | Claude Code warns at startup when a login is within three days of expiry. /status shows an 'Expired — log in again' row. |
| Free plan | Not eligible. Claude Code requires Pro, Max, Team, Enterprise or Console. |

> Where homes are on shared storage, "every engineer has their own credential store" is still true, but
> that store is a single file on the shared volume, and a user who logs in once is then logged in on
> **every** host. Its mode is 0600, owner-only — but see §17: on an export that trusts the mounting
> client's claim of identity, that mode is only as trustworthy as the client.

### 6.2 Logging in without copying and pasting a code

The paste-the-code flow is not the normal login path, and you should not have to live with it. It appears specifically when the browser that completes the sign-in cannot reach the short-lived callback listener that Claude Code starts on the loopback interface of the machine running claude. That is the case in SSH sessions, WSL2 and containers, where the browser is on a different host.

> **A desktop session on the host should not hit this:** where engineers log in to a graphical session on the host itself (RDP, VNC), the browser and the claude process are on the same machine, and the loopback callback resolves normally. If your users are seeing a code to copy, something in the list below is missing — it is a fixable configuration gap, not an inherent limitation.

Checklist for a clean, native login on such a host:

1. A graphical browser is installed in the RDP session. **Do not assume which one** — the hosts of a fleet do not necessarily ship the same browser, so a check hardcoding one name reports MISSING and misleads you. Ask the host what the drop-in resolved to: `sh -c '. /etc/profile.d/claude-code-browser.sh; echo "$BROWSER"'`. Empty means no candidate exists and login will fail silently.
2. `xdg-open` is present and resolves to that browser. Confirm with `xdg-settings get default-web-browser`. Install `xdg-utils` if missing. On an Xfce desktop, xdg-open resolves through xfce4-web-browser.desktop → exo-open → the `WebBrowser=` entry in `~/.config/xfce4/helpers.rc`. If that entry points at `links` — a terminal text-mode browser — rather than the graphical one, OAuth fails silently: links launches with no TTY (the desktop entry sets Terminal=false), exits immediately with no window ever appearing, and xdg-open still reports exit 0. This is the fix in item 4 below, applied per host rather than per user.
3. The user's session has `DISPLAY` set. Over RDP through xrdp this is normally automatic; in a bare SSH session it is not, which is why SSH users see the code flow.
4. Set `BROWSER` for every engineer at the host level, not per user. Because this is a shared instance with one Linux account per engineer, a fix dropped into a single home directory does not cover the next person to log in. Ship `profile.d/claude-code-browser.sh` and its **required** `.csh` sibling (a csh-family login shell does not source `*.sh`). They DETECT the browser rather than hardcode a path: a constant naming a binary the host does not ship is worse than no drop-in at all, because BROWSER short-circuits xdg-open to something non-existent and login fails silently with nothing logged. Setting `BROWSER` short-circuits xdg-open entirely, so a misconfigured xfce4 default no longer matters. As a second, complementary fix, correct the root cause for every existing home directory in one pass, and seed it for accounts not yet created: `for h in "$CC_HOME_ROOT"/*; do sed -i "s/^WebBrowser=.*/WebBrowser=<the browser item 1 printed>/" "$h/.config/xfce4/helpers.rc" 2>/dev/null; done`, then seed the same corrected file into `/etc/skel/.config/xfce4/helpers.rc` for accounts not yet created (skel reaches an account only where its home is created from it — §7.8). Both changes are one-time, host-level, and land outside version control on this instance — treat them as part of the build, not a per-engineer workaround.
5. Loopback traffic to 127.0.0.1 is not filtered by firewalld or a host agent.

With those in place, running claude opens the browser in the RDP session, the engineer signs in, and the redirect completes automatically. No code changes hands.

> **csh-family login shells:** `/etc/profile.d/*.sh` is not sourced by csh or tcsh, so each drop-in ships
> with a `.csh` sibling (`setenv BROWSER …`); the same applies to any PATH drop-in. Where homes are on
> shared storage, the per-home `helpers.rc` fix in item 4 needs running only once per user.

### 6.3 Fallbacks, in order of preference

| **Situation** | **Approach** |
| --- | --- |
| Browser present, redirect fails intermittently | Press `c` at the login prompt to copy the OAuth URL, then paste it into the local browser. The redirect still completes normally. |
| Engineer connects over SSH rather than RDP | Forward the callback port with `ssh -L`, so the workstation's loopback listener is reachable from the laptop's browser. Determine the port from the login URL on first run — it is chosen per attempt, so this is a per-session step and is best treated as a stopgap. |
| Genuinely headless, or automation | `claude setup-token` mints a one-year OAuth token, printed once and saved nowhere. Supply it as `CLAUDE_CODE_OAUTH_TOKEN`. It can only make model requests: no Remote Control, no claude.ai connectors. |
| You want to remove browser login entirely | That is the Amazon Bedrock model — IAM-based auth, inference inside AWS, no Anthropic login at all. A significant change to sections 5 and 6. It is the lever to reach for if section 1.5 concludes that customer data must not be sent to Anthropic. |

> **On setup-token for interactive users:** it still requires a browser once to mint, and it is per-user and expires annually. It solves automation, not the interactive login experience. Fix the browser path instead.

### 6.4 Restricting which organisation users can log in to

Two managed-only keys pin logins to your organisation. Set both, and set them in the managed settings file — server-managed settings only reach accounts already authenticated into your organisation, so they cannot govern a first login.

```json
{
  "forceLoginMethod": "claudeai",
  "forceLoginOrgUUID": "<your organisation UUID>"
}
```

The organisation UUID is shown in claude.ai admin settings. With forceLoginOrgUUID set, a claude.ai credential belonging to any other organisation causes Claude Code to report an error and exit at startup. It also blocks sessions that try to authenticate with ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or an apiKeyHelper, because organisation membership cannot be verified for an environment credential.

- Terminal, VS Code extension and Agent SDK logins verify forceLoginOrgUUID.
- `claude setup-token` and `/install-github-app` enforce only forceLoginMethod, so they can still mint a token in a different organisation. Factor that into how freely you permit token minting.

> **Confirm the accepted value:** the authentication documentation shows forceLoginMethod set to "claudeai" and "gateway". Check the settings reference for the exact accepted values on the version you deploy before relying on it, and verify with claude doctor after deploying — an invalid value is stripped rather than enforced.

> **The shipped policy does not set `forceLoginOrgUUID` — deliberately.** The documented behaviour of a
> *wrong* organisation pin is that **every login on the host is refused**, so an invented value would be a
> total outage presenting as an authentication error; the key goes in only once the real UUID is in hand.
> The full rationale is `SETTINGS-REFERENCE.md` §4.1.
>
> **Until a site adds it, the gate this section describes gates nothing.** A clean `cc-install.sh --apply`
> is not confirmation that logins are pinned.
>
> **What the omission leaves open:** a personal Claude account can sign in on the host, and
> environment-credential logins (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`) are not
> blocked — so the stray-API-key failure in §6.5 is still possible. To close it: obtain the UUID from
> claude.ai → Admin settings → Organization, add the key, re-apply, and verify by attempting a login with
> an out-of-organisation account. **Never put an invented value in this key.**

### 6.5 A stray API key will override the subscription

If `ANTHROPIC_API_KEY` is set in the environment and has been approved, it takes precedence over the Teams subscription login. On a shared host this typically arrives through a stale entry in a user's shell profile or a project's .envrc, and presents as an authentication failure despite a valid seat.

```bash
unset ANTHROPIC_API_KEY
grep -rn ANTHROPIC_API_KEY ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null
# then confirm in a session:
/status     # 'Login method' row should show the Teams account, no 'API key' row
```

Setting forceLoginOrgUUID blocks this class of problem outright, which is a further reason to deploy it. **The shipped policy does not set it (§6.4), so until a site adds it this failure mode remains live** — check the shell startup files as part of any login-failure triage.

> On a host with csh-family login shells also check `~/.cshrc` / `~/.tcshrc` for a stray `setenv ANTHROPIC_API_KEY`.

## 7. Settings architecture: admin level and user level

### 7.0 How a tool call is actually decided, and what is per host

Two pictures the rest of this runbook assumes. The enforcement layers are described in four separate
sections, and without the first picture it is not possible to tell where a hook sits relative to a deny
rule; without the second, "per-host control, fleet-wide asset" stays abstract.

**The enforcement pipeline.** A tool call passes through these in order. Each stage can stop the call; none
of them can undo a stop made earlier.

```
  settings merge        managed > command line > local > project > user
        │               (managed cannot be overridden; deny propagates from ANY scope)
        ▼
  permissions.deny  ────────────────► BLOCKED, absolutely (§8.1)
        │  no match
        ▼
  permissions.ask   ────────────────► PROMPTS, even in auto mode (§8.3)
        │  no match
        ▼
  permissions.allow ────────────────► permitted, skips the prompt
        │  no match → prompt by default (Posture A) / deny (Posture B, dontAsk)
        ▼
  PreToolUse hooks  ────────────────► an EXIT OF 2 BLOCKS THE CALL; any other
        │                              non-zero exit warns and the call PROCEEDS
        │                              (per-hook purpose and contract: §11.7,
        │                               SETTINGS-REFERENCE.md §3.7)
        ▼
  autoMode classifier ──────────────► BLOCKED if it judges the call unsafe (§8.5)
        │               runs AFTER the permission system, so every deny above still holds
        ▼
  OS sandbox ───────────────────────► DISABLED as shipped (SANDBOX-DECISION.md);
        │               when enabled: filesystem and network enforced by the
        │               kernel (§9) — the only layer that reaches subprocesses
        ▼
      executes

  On any refusal above:  PermissionDenied hook → cc-denied-hook.sh → the denial log
```

Two things this makes visible that the prose does not. **A `PreToolUse` hook can block something the
permission layer let through** — which is exactly how the ignored-glob problem (§8.8) is remediated. And
**the sandbox is last**, which is why it is the only layer that holds against a subprocess: everything above
it reasons about the call Claude *made*, not about what the resulting process then does. With the sandbox
disabled, no layer holds against a subprocess — design for that (`SANDBOX-DECISION.md` §3).

**Per host and fleet-wide.** What is per-host, what is fleet-wide where homes are shared, and why that distinction is the whole security story:

```
  host   host   host   host   host   host        ← N interchangeable hosts
   │      │      │      │      │      │
   │      │      │      │      │      │   PER HOST, not shared:
   │      │      │      │      │      │     /etc/claude-code/managed-settings.json   ← the policy
   │      │      │      │      │      │     /usr/bin/claude (RPM, versionlocked)
   │      │      │      │      │      │     /usr/local/sbin/cc-*.sh  + its systemd timers
   │      │      │      │      │      │     /var/log/claude-code/    ← the audit trail
   │      │      │      │      │      │     /etc/systemd/.../user-.slice.d
   │      │      │      │      │      │     /tmp/claude-<uid>
   └──────┴──────┴──┬───┴──────┴──────┘
                    │
     ┌──────────────┴───────────────┐
     │  central directory           │   one account, every host
     │  shared home storage         │   FLEET-WIDE, one copy:
     │    ~/.claude/.credentials.json    ← log in once, valid everywhere
     │    ~/.claude/  transcripts        ← --resume works across hosts
     │    ~/.local/bin/claude            ← a private install is present on EVERY host
     │  shared project storage      │
     └──────────────────────────────┘
```

> **The consequence:** every control in this runbook is a per-host control protecting a fleet-wide asset — a
> policy on one host does not govern a shell on another, but both reach the same customer data with the same
> credential. Which hosts are governed is each site's record in `CURRENT-STATE.md`.

**Claude Code is per-host, not client/server.** There is no daemon and no port; a CLI on one machine cannot
attach to an install on another. "Using a host's Claude Code" means having a shell on that host. Remote Control and
claude.ai web sessions are session *continuations*, not remote CLI access — and the shipped policy
disables Remote Control (`disableRemoteControl`).

### 7.1 The five scopes

Claude Code reads configuration from five sources — four files and the command line. Understanding which one wins is the single most important thing for an administrator, because it determines whether your policy is advisory or binding.

| **Scope** | **Path on Linux** | **Who owns it** | **Can it override managed?** |
| --- | --- | --- | --- |
| Managed | `/etc/claude-code/managed-settings.json` | IT (root) | n/a — highest tier |
| Command line | `--settings`, `--allowedTools`, flags | User, per invocation | No |
| Local | `<repo>/.claude/settings.local.json` | User, per repository, git-ignored | No |
| Project | `<repo>/.claude/settings.json` | Whoever commits to the repository | No |
| User | `~/.claude/settings.json` | The individual engineer | No |

> **The key property:** no other level — including command-line arguments — can override a managed setting. And separately, if a tool is denied at any level, no other level can allow it. Deny propagates upward as well as downward.

> The path `/etc/claude-code/managed-settings.json` (and a `managed-settings.d/` drop-in directory beside
> it) is **compiled into the binary** — there is no environment variable or flag to relocate it. This is
> why the policy is genuinely per-host and belongs in the golden image. `managed-settings.d/` is the
> product's route to a fleet-common baseline plus per-host additions; this repository does not use it.

### 7.2 Two ways to deliver managed settings

| | **Endpoint-managed** | **Server-managed** |
| --- | --- | --- |
| Where it lives | `/etc/claude-code/managed-settings.json` on the instance | Claude.ai admin console, fetched by the client |
| Set by | Root on the host | Organisation Owner or Primary Owner |
| Best for | Machines you administer — this deployment | Fleets with no MDM, or unmanaged devices |
| Enforcement strength | Stronger: the file is root-owned on a machine users do not administer | Client-side control; a brief unenforced window exists on first launch |
| Precedence | Applies when server-managed delivers nothing | Checked first; if it delivers any keys, endpoint-managed is ignored |

**Use endpoint-managed for this deployment.** It is the stronger control, it matches the topology — root-owned, users without sudo — and its per-machine scope is exactly what is needed here, because these hosts must be governed more strictly than the rest of the organisation's machines. The precedence rule that makes this work also makes it fragile; the next subsection states the rule that protects it.

### 7.3 Standing rule: keep the claude.ai console empty

The precedence rule above is not a footnote — it is an operational hazard, because nothing errors when it bites. If an organisation Owner enables managed settings in the claude.ai console, that payload takes over wholesale and `/etc/claude-code/managed-settings.json` on this host stops being read. The policy does not fail loudly; it quietly stops being yours.

**Therefore: server-managed settings for this organisation are to remain empty.** Record that as an owned decision, not an assumption. Name the person accountable for the claude.ai organisation, and make sure they know that enabling one line in that console disables the entire policy on this instance.

Two things make this rule safe to hold rather than merely aspirational:

- Server-managed settings apply uniformly to every user in the organisation. There is no per-group scoping. Where the rest of the organisation's machines are deliberately governed more lightly than these hosts, a uniform org policy could not express what is actually wanted in either direction.
- The exceptions to the no-merge rule are narrow and known: a small set of cross-source lock keys, and the `env` block, which merges per variable. Everything else is all-or-nothing at the source level.

If the position ever changes and server-managed settings are adopted, this document needs revisiting in full — not amending. Sections 7, 8 and 9 all assume the endpoint-managed file is authoritative. Two keys worth knowing at that point: `forceRemoteSettingsRefresh` is an explicit exception that is honoured from any admin source, and proxy or CA variables must reach the client from somewhere other than the server payload, because the cached `env` block withholds them until a fetch succeeds.

### 7.4 Governance that lives outside this host

Three controls relevant to the organisation's Claude deployment are not configured on this instance at all. They are recorded here so the boundary between this runbook and the organisation's wider Claude governance is explicit.

| **Control** | **Where it is set** | **What it covers** |
| --- | --- | --- |
| Connector and MCP restrictions for the Claude apps | claude.ai admin settings, under the organisation's Connectors configuration | The desktop app and web app. Per-tool states are available: a tool set to 'ask' forces approval on every call, and a tool set to 'blocked' is filtered out before Claude sees it. |
| Remote Control and web sessions | claude.ai Claude Code admin settings | Organisation-wide toggles owned by an Owner. Remote Control can additionally be disabled per device with disableRemoteControl. |
| Windows desktop app policy | The organisation's device-management tool, if you choose to deploy anything | Optional. See the residual exposure below. |

> **Worth knowing about the connector controls:** Claude Code reads the organisation's per-tool connector settings at startup and enforces them locally, so they apply here too. A tool the organisation set to 'ask' prompts on every call even in permissive permission modes, and allow rules do not skip that prompt. In dontAsk mode it is denied outright. This host also sets disableClaudeAiConnectors to true, so the question does not arise in practice — but the interaction matters if that is ever relaxed.

### 7.5 Residual Claude Code exposure on Windows

This deployment puts Claude Code on Linux hosts only. Where the organisation also has Windows machines, gating the installer through device management does not mean Claude Code cannot run there. Two routes do not involve an installer that gate would see:

- **The Claude desktop app includes a Code tab.** Anthropic's own documentation presents the desktop app as a way to use Claude Code without the terminal. If the desktop app is approved on those machines, Claude Code is already available on them.
- **The VS Code extension bundles a private copy of the CLI** inside the extension directory for its own chat panel. It is not added to PATH, so it does not appear in the usual checks, but it runs.

Whether that is acceptable depends on what data those machines hold. It is recorded because the difference between 'engineers cannot run Claude Code on Windows' and 'they can, and those sessions are unpoliced' is worth stating deliberately rather than discovering.

If cover is wanted, it is cheap and adds no user-visible friction. Deploy a minimal managed settings file through device management to `C:\Program Files\ClaudeCode\managed-settings.json`, containing only:

```json
{
  "forceLoginOrgUUID": "<organisation UUID>",
  "requiredMinimumVersion": "<the fleet pin>",
  "permissions": {
    "deny": [
      "Read(**/.env)",
      "Read(**/*.pem)",
      "Read(~/.ssh/**)"
    ]
  }
}
```

`<the fleet pin>` is the `requiredMinimumVersion` in `settings/managed-settings.json`, copied at deploy
time — a version written into this page would be stale at the next bump.

> **Do not extend the Windows file beyond this:** the sandbox does not run on native Windows, and permission rules written for Bash do not apply to the PowerShell tool that Claude Code uses on Windows when Git for Windows is absent. A Windows policy that looks strict but only covers Bash rules gives false assurance. Keep it to identity, version floor and secret paths — the three that behave identically on every platform.

### 7.6 Deploying the file

**The only supported path is `cc-install.sh`; never hand-`install` the policy.** It also refuses to apply a policy whose `requiredMinimumVersion` is **above the version installed on this host** — that combination stops every session on the machine, and it arrives looking like an ordinary apply (`--allow-below-floor` is the deliberate override, and it says what it is permitting). The procedure — edit the authored source `settings/managed-settings.json`, then `--check` and `--apply` — is specified once, in `SETTINGS-REFERENCE.md` §2.1; the raw commands are deliberately not reproduced here. `--apply` performs the directory creation, the file placement, the checksum baseline and the validation in one idempotent step, and it **refuses to apply a file containing placeholder markers** — a guard a manual `install` silently bypasses: a hand-install can deploy a placeholder-ridden draft, record a clean checksum over it, and leave the daily health check reporting no drift. There is no second copy to promote: the authored source and the deployed source are the same file. **Warn users first — a policy rewrite breaks every session already running** (the announce-first mechanics are `OPERATIONS.md` §1.5b).

**The host policy is `settings/managed-settings.json` and nothing else** (`settings/managed-settings-admin.json` is the privileged session's policy, placed by the same installer — [`ADMIN-SESSION.md`](ADMIN-SESSION.md)). A draft or a variant kept for reference must never be placed by hand: one that drops the `statusLine` key or the `cc-secret-guard-hook.sh` registration removes the enforcement of record behind the secret-filename rules (§8.8), so `.env`, `*.pem` and `id_rsa*` would become readable by the agent again. Whether the policy in a checkout is concrete or still holds placeholders depends on the edition — `PUBLISHING.md` §1.

> **Invalid entries are stripped, not rejected:** if a key fails schema validation, Claude Code removes that entry, surfaces a validation error, and applies everything else. A typo in a lock key therefore produces a policy that is quietly weaker than you intended rather than a hard failure. Always run claude doctor after an edit, and let the audit script assert that each lock key is actually present.

> **On the checksum baseline:** `cc-install.sh --apply` re-records it on every approved apply; a hand-edit of the deployed file does not, which is the other reason never to hand-edit it. Never re-record the baseline to make a drift finding disappear (`SETTINGS-REFERENCE.md` §5).

### 7.7 What IT owns versus what the engineer owns

| **Concern** | **Managed (IT)** | **User** |
| --- | --- | --- |
| Permission allow / ask / deny rules | Yes — and lock it | Only if you do not set allowManagedPermissionRulesOnly |
| Permission mode default | Yes | Can switch modes unless disabled |
| Sandbox on/off and boundaries | Yes — and lock the read paths and domains | Can widen array keys unless locked |
| MCP servers | Yes — allowlist, and lock it | Blocked when locked to an empty allowlist |
| Hooks | Yes — and lock with allowManagedHooksOnly | Blocked when locked |
| Plugins and marketplaces | Yes — strictPluginOnlyCustomization, blockedMarketplaces | Blocked when locked |
| Model choice, effort level | Optionally constrain with availableModels | Reasonable to leave to the engineer |
| Editor mode, UI preferences | Leave alone | Yes — this is the engineer's workspace |
| Status line | **A managed default** — the only delivery path that reaches every user here (§7.8) | **Yes** — by their own `~/.claude/statusline.sh`, see below |
| Per-project CLAUDE.md and skills | Optionally seed | Yes, within the permission boundary |

Lock what constitutes your security boundary; leave the rest. A policy that also dictates `editorMode` generates support tickets without reducing risk.

> **The status line is a managed default that each engineer can replace.** The managed `statusLine` key
> points every session at one global script, `/usr/local/share/claude-code/statusline.sh`; that script
> hands over to the engineer's own `~/.claude/statusline.sh` when one exists, is theirs and is writable by
> nobody else. Mechanism, safety checks and the Bedrock-only cost segment: `SETTINGS-REFERENCE.md` §3.9.

### 7.8 Seeding a sane user baseline

**`/etc/skel` reaches an account only when its home directory is created from it.** That happens where the login path creates the home (`pam_mkhomedir`, `oddjob_mkhomedir`) or provisioning runs `useradd -m`. Where homes are pre-created elsewhere — on shared storage, by a separate provisioning process — skel is never consulted, and seeding it reaches nobody: not new accounts, not existing ones. Establish which case a host is in before relying on anything in this subsection.

Two consequences. Anything a new account *must* have has to come from managed settings (which override per-user files anyway) or from a `/etc/profile.d` drop-in, neither of which depends on the home directory existing first. And a "create a test account, confirm the file appears" verification proves something only where the login path creates the home.

**Why `/etc/skel` at all, and can it move?** It is the OS's own new-account template — `useradd -m` copies its contents into a fresh home — so placing seeds there is following an OS convention, not adding deployment clutter to `/etc`. The installer's `CC_SKEL` variable can point elsewhere, but only in tandem with the OS: `useradd` reads the location from `SKEL=` in `/etc/login.defs`, so moving one without the other plants seeds where nothing looks. Leave it at `/etc/skel` unless the site has already relocated skel OS-wide. And keep the classification straight: whatever skel copies becomes the user's own editable file — a **default, not a control** (the same class as the IDE wrapper seed). Enforcement lives only in the managed policy.

The seed is worth shipping either way — `cc-install.sh` places it. Keep it to preferences; anything security-relevant belongs in managed settings, where the user cannot change it:

```json
// /etc/skel/.claude/settings.json
{
  "autoUpdatesChannel": "stable",
  "cleanupPeriodDays": 14,
  "includeCoAuthoredBy": false
}
```

Note that `cleanupPeriodDays` in *managed* settings overrides any skel value, and the deployed policy sets **90** (§11.6) — keep the two consistent or drop the skel entry, to avoid a confusing mismatch for the next reader.

## 8. Building a deny-by-default tool policy

### 8.1 How rules are evaluated

Three arrays, evaluated in a fixed order. This order is the whole design and it is not what most administrators assume.

1. deny
2. ask
3. allow

The first match in that order determines the outcome. Rule specificity does not change the order.

> **The consequence, stated plainly:** a deny rule cannot carry allowlist exceptions. Bash(aws *) in deny blocks every matching call, including one that also matches a narrower Bash(aws s3 ls) allow rule. You cannot write 'deny everything, except these' using deny plus allow. Attempting it produces a policy that blocks more than intended and gives no error.

### 8.2 The two mechanisms that genuinely do deny-by-default

Since deny-plus-allow cannot express an allowlist, there are exactly two supported ways to start from nothing and permit exceptions.

| **Mechanism** | **Scope** | **Behaviour** |
| --- | --- | --- |
| `dontAsk` permission mode | Every tool | Auto-denies every tool call that would otherwise prompt. Claude runs only what matches permissions.allow, the built-in read-only Bash set, and calls approved by a PreToolUse hook. |
| `sandbox.network.strictAllowlist` / `allowManagedDomainsOnly` | Network, for sandboxed Bash | Denies sandboxed commands access to any host outside allowedDomains, instead of prompting. OS-enforced through the sandbox proxy. |

Everything else — the deny list, `ask` rules — is a blocklist layered on top of a prompt-by-default baseline. Both approaches are legitimate; they suit different users, which is why two postures are given below.

### 8.3 Posture A — gated interactive workstation (recommended)

Baseline is prompt-on-use, so the engineer stays in the loop and can approve unusual work. On top of that sits an absolute blocklist that no user, project or CLI flag can lift, plus a network allowlist enforced by the OS. This preserves normal interactive use while making the boundary real.

Key elements, with the reasoning:

| **Setting** | **Value** | **Why** |
| --- | --- | --- |
| `permissions.defaultMode` | `"default"` | Prompt on first use of each tool. Engineers keep agency; nothing runs silently. |
| `disableBypassPermissionsMode` | `"disable"` | Removes the escape hatch that skips prompts entirely. |
| `autoMode` | configured, not disabled | Auto mode is deliberately LEFT ENABLED and configured for the organisation. Section 8.5 explains why; 8.6 has the configuration. |
| `allowManagedPermissionRulesOnly` | `true` | User and project settings can define no allow, ask or deny rules at all. Your rules are the only rules. |
| `allowManagedHooksOnly` | `true` | Hooks execute shell commands. Only yours load. |
| `allowManagedMcpServersOnly` | `true` | Combined with an empty allowedMcpServers, this is MCP lockdown. |
| `disableSideloadFlags` | `true` | Rejects --plugin-dir, --plugin-url, --agents and --mcp-config at startup. Without it, a single run can bypass your marketplace restrictions. |
| `strictPluginOnlyCustomization` | `true`, or an array of the types to restrict | `true` closes all four customization types — skills, agents, hooks and MCP servers cannot come from user or project sources. An array names only the restricted types, leaving the rest open; the shipped policy uses `["hooks", "mcp"]` so engineers can author skills and agents (`SETTINGS-REFERENCE.md` §3.4). |
| `disableClaudeAiConnectors` | `true` | Turns off claude.ai MCP connectors, and removes the need to allowlist mcp-proxy.anthropic.com. |

The deny list itself should cover four categories. Keep it short and categorical rather than trying to enumerate every dangerous command.

- **Privilege and host administration** — `sudo`, `su`, `dnf`, `rpm`, `systemctl`, `useradd`, `passwd`. A shared instance is not the agent's to reconfigure.
- **Unmanaged network egress** — `curl`, `wget`, `nc`, `ssh`, `scp`, `rsync`, `aws`. Deny these in Bash and let the sandbox's domain allowlist handle legitimate network use. See the warning below on why this matters.
- **Secrets and credentials** — `~/.ssh/**`, `~/.aws/**`, `~/.gnupg/**`, `**/.env`, `**/*.pem`, `~/.claude/.credentials.json`, and `/etc/claude-code/**` so the agent cannot read its own policy.
- **System paths** — `Edit(//etc/**)`, `Edit(//usr/**)`, and the shell startup files, which are a persistence vector.

> **Why denying curl and wget matters more than it looks:** WebFetch permission rules constrain the WebFetch tool only. If Bash is available, the agent can reach any URL with curl regardless of your WebFetch rules. Bash network tools and WebFetch domain rules have to be configured together, or the WebFetch allowlist is decorative.

> The "shell startup files" in the System-paths category include the csh-family ones: the shipped policy
> denies `Edit(~/.cshrc)` and `Edit(~/.tcshrc)` alongside the bash files.

### 8.4 Posture B — hard lockdown

Set `"defaultMode": "dontAsk"` and enumerate everything permitted in `permissions.allow`. Nothing else runs, and nothing prompts.

Be clear-eyed about what this costs:

- AskUserQuestion is denied, so Claude cannot ask a clarifying question. It will guess or stop.
- Any command you did not anticipate simply fails. Expect a period of iterating on the allow list based on what engineers actually hit.
- The mode never appears in the Shift+Tab cycle. It is set with `--permission-mode dontAsk` or as `defaultMode` in settings.
- It is designed for CI and restricted environments. On an interactive engineering workstation it will feel obstructive.

**Recommendation:** deploy Posture A to the shared workstation. Hold Posture B for a build-agent or CI instance, where non-interactive is the point. If you do want Posture B for engineers, pilot it with two or three people for a fortnight and grow the allow list from real usage before rolling it out.

> **Posture B is not shipped.** `settings/managed-settings.json` is Posture A. A Posture B `allow` list has
> to name the site's real work paths and internal domains, and is grown from the denial log (§11.7).

### 8.5 Auto mode: why it stays on

Auto mode is enabled in this deployment. That is a deliberate reversal of the instinct to disable everything that reduces prompting, and the reasoning matters because the two settings look similar and are not.

| **Mode** | **What it does** | **Decision** |
| --- | --- | --- |
| `bypassPermissions` | Skips permission prompts. There is no second check behind it. | DISABLED via disableBypassPermissionsMode |
| `auto` | Routes tool calls through a classifier that blocks anything irreversible, destructive, or aimed outside the environment. It runs AFTER the permission system, not instead of it. | ENABLED and configured |

The ordering is the whole argument: deny rules and explicit ask rules are evaluated before the classifier and still block or prompt. Every entry in the deny list of section 8.3 holds in auto mode, and `permissions.deny` in managed settings cannot be overridden by the classifier or by user intent. Auto mode adds a gate; it does not remove one.

The second argument is about people. An engineer facing dozens of prompts an hour stops reading them and approves reflexively, or asks IT for a bypass. Prompt fatigue converts a control into a formality. Auto mode, a firm deny list and the sandbox together are a stronger real-world posture than default mode with a tired human clicking accept.

> **What the classifier trusts by default:** only the working directory and the current repository's configured remotes. Everything else — other source-control orgs, cloud buckets, internal domains — is treated as a potential exfiltration target until you name it. The defaults are conservative, which is why the configuration below exists: without it the classifier blocks routine internal work.

### 8.6 Configuring the classifier for the site

The `autoMode` block goes in managed settings, org-wide. Note that the classifier deliberately does NOT read `autoMode` from project settings, so a checked-out repository cannot inject its own trust.

```json
{
  "autoMode": {
    "environment": [
      "$defaults",
      "Organization: Example Organisation. Primary use: software engineering",
      "Cloud provider(s): none",
      "Source control: not yet specified - the classifier therefore treats every source-control host as an untrusted destination until an entry is added here",
      "Trusted internal domains: *.corp.example",
      "Internal storage: shared home and project storage under corp.example",
      "Sensitive data locations & audiences: customer data under the shared project storage, shared only within the assigned project team",
      "Additional context: shared multi-user Rocky 8 workstation holding customer data under NDA"
    ],
    "hard_deny": [
      "$defaults",
      "Never send customer data to any host outside corp.example"
    ],
    "classifyAllShell": true
  }
}
```

The values above are neutral examples of the form; the block a host runs is the one in `settings/managed-settings.json`.

Five things to get right before deploying this.

1. **Never omit** `"$defaults"`**.** Setting any of these arrays without it REPLACES the entire built-in list for that field. Dropping it from soft_deny discards force-push protection, curl-pipe-to-bash, production-deploy and auto-mode-bypass blocks. Dropping it from hard_deny discards the built-in data-exfiltration rule. This is the sharpest single footgun in the settings surface.
2. **soft_deny is not a policy boundary.** A developer can add their own `allow` entry that overrides an organisation `soft_deny` entry — the lists combine additively rather than as policy. Only `permissions.deny` and `autoMode.hard_deny` are firm. Put anything absolute in those two.
3. **classifyAllShell closes a real gap.** Narrow allow rules such as `Bash(npm test)` normally resolve before the classifier even in auto mode, so a destructive argument the prefix did not anticipate passes unseen. Setting it to true routes every shell command through the classifier. It costs latency and a classifier call per command; on a host holding customer IP that is the right trade.
4. **Your ask rules remain human checkpoints.** Content-scoped ask rules always prompt, even in auto mode, so `Bash(git push *)` stays a human decision. This is the documented mechanism for a checkpoint that survives auto mode.

5. **The Source control line can be explicit rather than filled.** Until the source-control host is known, the entry says so in words rather than holding an invented value. That is a working configuration, not a broken one: the classifier treats every source-control host as an untrusted destination, so pushes to any git host are treated as potential exfiltration — and the `Bash(git push *)` ask rule prompts anyway. Add the real host and org when the answer is known, and re-verify with `claude auto-mode config`.

### 8.7 When the classifier blocks something

The classifier will block legitimate work occasionally, usually because it is missing context about your infrastructure. There is a defined path for this, and it does not route through IT for most cases.

| **Situation** | **Fix** | **Who** |
| --- | --- | --- |
| A one-off action the engineer did intend | State the intent in the next message and let Claude retry. Or open /permissions, Recently denied tab, press r to mark for retry. | Engineer, self-service |
| A destination needed throughout a task — registry, internal domain, repo host | Add it to `autoMode.environment` | IT, via managed settings |
| Repeated blocks on the same destination | The classifier is missing context. Add the destination, then confirm with `claude auto-mode config` | IT |
| You want to react to denials programmatically | The `PermissionDenied` hook — deployed here as `cc-denied-hook.sh` (§11.7), which is what logs what engineers are actually blocked on. | IT |

Auto mode also self-limits: after three consecutive blocks, or twenty in a session, it pauses and reverts to prompting. A user hitting that repeatedly is a signal that `autoMode.environment` needs an entry, not that the engineer is doing something wrong. Route those requests to the support contact (`CC_SUPPORT_CONTACT`) and treat an addition as a change per section 11.

> **Be clear-eyed about what the classifier is:** a model making a judgement, not a deterministic rule. It is probabilistic, and it should never be the only thing between the agent and something irreversible. That is exactly why the deny list and the sandbox stay in place underneath it.

### 8.8 Writing rules correctly

Three syntax traps account for most misconfigured policies.

**1. Bash wildcards are shell-aware but argument matching is fragile.** A rule like `Bash(curl http://github.com/ *)` does not constrain curl: options before the URL, a different protocol, a redirect, or a variable all evade it. Do not try to restrict a command by its arguments. Deny the command and use a tool-level control instead.

**2. Wrappers are stripped, runners are not.** Claude Code strips `timeout`, `time`, `nice`, `nohup`, `stdbuf`, `command`, `builtin` and bare `xargs` before matching, so a rule for the inner command still applies. It does not strip `docker exec`, `npx`, `mise exec` or `devbox run`, which execute arbitrary arguments — so an allow rule for one of those grants whatever follows it.

**3. Read and Edit paths use gitignore syntax with anchors that are easy to get wrong.**

| **Pattern** | **Anchored at** | **Example** |
| --- | --- | --- |
| `//path` | Filesystem root | `Read(//etc/shadow)` |
| `~/path` | Home directory | `Read(~/.ssh/**)` |
| `/path` | The settings source — NOT the filesystem root | `Edit(/src/**)` |
| `path` | Current directory | `Read(*.env)` |

> **The trap:** a single leading slash anchors at the settings source, not at the filesystem root. Read(/etc/shadow) in your managed file does not protect /etc/shadow. You need Read(//etc/shadow). This is the most common error in hand-written policies.

**4. Filename glob patterns: enforcement depends on the version.**

> A rule intended to catch a secret *by filename anywhere* —
>
> ```
> Read(**/.env)   Read(**/*.pem)   Read(**/id_rsa*)   Read(**/id_ed25519*)
> ```
>
> — is not enforced by every build on Linux. A build that does not enforce them says so: `/doctor`, run inside a session,
> reports that glob patterns in permission rules "are not fully supported on Linux… will be ignored".
> **They cannot be rewritten as working path rules.** The underlying rules are expressed as directory
> *prefixes*, and a filename pattern is not a prefix — there is no equivalent. Directory-anchored rules
> (`Read(~/.ssh/**)`, `Read(//etc/**)`) are not affected and do enforce.
>
> The behaviour at the pin is a version-sensitive dependency: a site records what it verified in
> `internal/LIMITATIONS-AND-RISKS.md` Part 3. The policy keeps the four rules above; the enforcement of record is a `PreToolUse` hook matching
> on basename (§11.7), whichever way a version behaves. **Where the rules do enforce they run before the
> hook**, so a rule also refuses a name the hook allow-lists — which is why the policy has no
> `Read(**/.env.*)`: it would refuse `.env.example`. Where a version warns, the in-session `/doctor` warning is
> expected and must not be "fixed" by deleting the rules.

One helpful asymmetry: as a deny or ask rule, a single-segment pattern like `Read(secrets/**)` matches a directory of that name at any depth. As an allow rule the same pattern matches only the top level. Deny rules are deliberately broader than allow rules.

Finally, note that a bare tool name in deny removes the tool from Claude's context entirely — it never sees it. A scoped rule leaves the tool available and blocks matching calls. Both are useful; choose deliberately.

### 8.9 Verifying the policy actually applied

```bash
# in a session, as a normal user:
/permissions        # lists every effective rule and the file it came from
/status             # shows which managed source is active
```

```bash
# as root:
claude doctor            # settings validation errors and warnings
claude auto-mode config  # effective classifier rules, with $defaults expanded
claude auto-mode critique # AI review of your custom autoMode rules
cc-audit.sh              # lock keys, autoMode $defaults check, effective policy
```

Have a test user attempt something the policy should block — `sudo id` is a safe choice — and confirm it is refused. A policy nobody has tested is a policy you do not have.

## 9. OS-level enforcement with the sandbox

> ### THIS ENTIRE CHAPTER IS NOT IN FORCE
>
> **`sandbox.enabled` is `false` in the shipped policy.** `SANDBOX-DECISION.md` is authoritative on the
> status, the failure and the re-enable conditions (§4 there) — read it before acting on anything in §9.
> This chapter is retained as the product reference and as the design the decision was taken against. Two
> things from that record to carry through the chapter: when the sandbox helper cannot start,
> `failIfUnavailable: false` does **not** fail open (§9.5, §9.7); and a filesystem allowlist that does not
> name every path real work uses blocks that work, whether or not the sandbox starts
> (`SANDBOX-DECISION.md` §2.3).

### 9.1 Why permission rules alone are not enough

Read and Edit deny rules apply to Claude's built-in file tools and to file commands Claude Code recognises in Bash, such as `cat` and `sed`. They do not apply to arbitrary subprocesses. A Python script that opens a file itself is not covered.

The sandbox closes that gap by enforcing boundaries at the operating-system level for every Bash command and all of its child processes. On Linux it uses bubblewrap for filesystem isolation and a proxy for network control.

### 9.2 Recommended configuration

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": false,
    "allowUnsandboxedCommands": false,
    "excludedCommands": [],
    "filesystem": {
      "allowManagedReadPathsOnly": true,
      "denyRead": [
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.claude",
        "/etc/claude-code", "/var/log/claude-code"
      ],
      "allowRead": ["~/", "/srv/projects", "/srv/scratch", "/opt/toolchains", "/usr/share"],
      "allowWrite": ["/srv/scratch"]
    },
    "network": {
      "strictAllowlist": true,
      "allowManagedDomainsOnly": true,
      "allowedDomains": [
        "api.anthropic.com", "platform.claude.com",
        "claude.ai", "claude.com", "code.claude.com", "downloads.claude.ai",
        "registry.npmjs.org", "pypi.org", "files.pythonhosted.org", "github.com"
      ]
    }
  }
}
```

| **Key** | **Effect** |
| --- | --- |
| `failIfUnavailable` | Controls what happens when the sandbox cannot start. Set false for a pilot: commands run unsandboxed with a warning, so a dependency problem degrades protection instead of blocking the whole team. Set to true once proven, after which the same condition stops Claude Code starting. Either way the daily health check is what tells you — see section 9.5. |
| `allowUnsandboxedCommands` | Set false to ignore the dangerouslyDisableSandbox escape hatch, so a command that fails under the sandbox cannot be retried outside it. |
| `allowManagedReadPathsOnly` | Array keys normally merge across scopes, meaning a user could append entries that widen the policy. This locks allowRead to the managed values. |
| `allowManagedDomainsOnly` | Same lock for network domains, and non-allowed domains are blocked automatically instead of prompting. |
| `strictAllowlist` | Denies sandboxed commands any host outside the allowlist rather than prompting. This is the network deny-by-default switch. |

> **One gap to know about:** excludedCommands has no managed-only lockdown. A user can always append entries that run additional commands outside the sandbox. Keep your managed list narrow and review the deployed list at each audit.

> **The paths in the block above are examples.** `allowRead` has to name the directories real work
> actually uses: with `allowManagedReadPathsOnly: true`, a list missing them blocks reads of every project
> directory on the first command. `denyRead` still wins over `allowRead`, so home is readable except the
> secret subtrees (incl. `~/.claude`). Keep the public registries in `allowedDomains` unless the site has
> an internal package mirror. And keep `failIfUnavailable` **false** on a shared host: a helper failure
> hard-fails every command rather than failing open (§9.7).
>
> **A `~`-related trap.** Every rule above that begins with `~` expands to `$HOME`. Where the directory
> publishes `$HOME` as a symlink, mount-namespace isolation cannot mount through the symlinked parent, so
> all of these rules fail until `HOME` resolves to the real path — see `OPERATIONS.md` §1.6.

### 9.3 Default read behaviour is broader than you might expect

By default the sandbox allows reading the entire filesystem, denying only certain directories. Credential files such as `~/.aws/credentials` and `~/.ssh/` are readable unless you say otherwise. The `denyRead` entries above are doing real work — do not omit them on the assumption that the sandbox is closed by default. Writes are the opposite: only the working directory and the session temp directory are writable.

### 9.4 Protected paths

Independently of your configuration, the sandbox refuses writes to the files Claude Code loads its own configuration and code from — .claude settings, skills, agents, hooks, .mcp.json, shell startup files, .git internals. There is no way to exempt these. This is what stops a sandboxed command from granting itself permissions.

### 9.5 Why the sandbox, and why it starts fail-open

Two questions are worth answering explicitly, because the sandbox is the most operationally expensive control in this deployment and the case for it is narrower than it first appears.

**What it is for.** Permission rules do not reach subprocesses. Read and Edit deny rules cover Claude's own file tools and the Bash file commands Claude Code recognises, but not arbitrary child processes. Engineers on this host must be able to run python3, make and pip, so one level of indirection through any interpreter turns every file and network deny rule advisory:

```bash
python3 -c "print(open('/some/denied/path').read())"    # not a Read rule match
python3 -c "import urllib.request, sys; ..."              # not a Bash(curl *) match
```

The sandbox enforces the boundary at the operating-system level for every Bash command and all of its children, regardless of what the model chose to run. It is the only layer that holds against that class of bypass.

**What it is not for.** It is not an insider-threat control. An engineer who wants to take customer source opens a terminal and copies it; nothing in Claude Code's configuration touches that, and presenting the sandbox as protection against a determined insider would be false assurance. Whether it is the primary defence *between* engineers on this host depends on the home directory modes.

> **Check the home-directory modes before relying on the kernel for that separation.** Where homes are not `0700`, sandbox `denyRead` entries are the primary control between engineers rather than belt-and-braces; `cc-healthcheck.sh` section [3] reports each home's mode and the modes of `~/.ssh`, `~/.gnupg` and `~/.aws`. And on a network export that trusts the mounting client's claim of identity, a file mode is not a boundary against another host at all (§17). Until both are settled, do not describe filesystem permissions as an access control to a customer or an auditor.

Its real value is against **agent error and prompt injection**: a dependency pulled from somewhere unexpected, a Makefile that fetches, or Claude reading a customer file or web page containing instructions aimed at it. That last case is what justifies the cost. It is precisely where intent-based controls are the thing that has been compromised, where autoMode.hard_deny is a model policing a model, and where an OS-enforced network allowlist is the only control still standing.

**Why failIfUnavailable starts false.** This is stage one of two, and it is a deliberate trade rather than an oversight.

| | **false — stage one** | **true — the target state** |
| --- | --- | --- |
| Missing bubblewrap or socat | Warning; commands run unsandboxed | Claude Code refuses to start |
| Blast radius | Host is unprotected but the team keeps working | Every engineer on the instance is blocked |
| How IT finds out | cc-healthcheck.sh, within 24 hours | Immediately, from users |
| Risk accepted | Enforcement can lapse silently | A dependency problem becomes a total outage |

On a shared workstation, true converts any bubblewrap problem — a dnf transaction removing socat, a kernel change, an SELinux edge case — into an outage for the whole team. Fail-open accepts the opposite risk: the host can be unprotected while appearing healthy. That is why the daily health check treats a missing bubblewrap or socat as a finding whenever the policy enables the sandbox, and states which of the two failure modes applies.

**The staged plan ("run a clean fortnight, then set it `true`") holds only for the failures the table models.** The table covers a missing dependency. It does not cover the helper failure (§9.7): there, `failIfUnavailable: false` does **not** fail open — every command in the session hard-fails, and with `true` the same condition stops Claude Code starting. On a shared host `false` is therefore a semi-permanent posture rather than stage one of two, and the exit criterion is the re-enable gate in `SANDBOX-DECISION.md` §4, not "a clean fortnight". Fail-closed becomes affordable in a single-tenant model, where the blast radius is one engineer rather than the whole team (`LOCAL-VS-AWS.md`). The accepted risk belongs in `LIMITATIONS-AND-RISKS.md` Part 2. `cc-audit.sh` prints the sandbox keys in every report, so the stance stays visible rather than becoming an accident.

> **Deciding against the sandbox entirely is a legitimate position — and it is the position the shipped policy takes** (`SANDBOX-DECISION.md`, with the compensating controls in its §3 and the risk owned in `LIMITATIONS-AND-RISKS.md`): keep the deny list and the classifier, and accept that file and network deny rules are bypassable through any interpreter. What must not happen is the same outcome arriving by accident, because a dependency never installed and nobody noticed.

### 9.6 SELinux on Rocky 8

Rocky 8 enforces SELinux by default, and the sandbox is the part of this deployment most likely to interact with it: bubblewrap creates user namespaces and performs mount operations, which is exactly what a confined SELinux domain is often forbidden to do.

The likely outcome is that nothing happens, and the reason is worth recording so the next person does not re-investigate. Rocky's default targeted policy confines specific system daemons, not interactive users: Linux users map to __default__, which maps to unconfined_u, and processes in unconfined_t are subject to only minimal restrictions. An engineer's session, and the claude process it starts, are therefore effectively unrestricted by SELinux. The bubblewrap denials reported in the RHEL and Fedora bug trackers are consistently against confined domains, not unconfined ones.

Two residual risks remain, in increasing order of consequence.

- **File labels under /var/log/claude-code.** That directory is created by hand rather than by a package, written by a systemd unit and appended to by the hooks. Mislabelling is the ordinary, boring failure here, and the fix is semanage fcontext plus restorecon, not a policy module.
- **Confining the engineers themselves.** If IT ever maps users to a confined SELinux user such as staff_u — a plausible next hardening step on a host holding customer IP — that is precisely the configuration in which the reported bubblewrap namespace denials occur. Re-test the sandbox before and after any such change.

Establish the baseline on the pilot, with the policy deployed and after a real session and a health check run:

```bash
getenforce                            # expect: Enforcing
id -Z                                 # expect: unconfined_u:...:unconfined_t
# 0 is REQUIRED when the sandbox is disabled (it stops a no-sudo user
# bind-mounting their own policy over managed-settings.json); non-zero is
# required only if the sandbox is enabled. LOCAL-VS-AWS.md 8.2
sysctl user.max_user_namespaces       # non-zero ONLY if sandbox.enabled is true
sudo ausearch -m avc -ts recent       # any denials naming bwrap?
sudo ausearch -m avc -ts recent | audit2allow   # what a module would need
```

Record the output as evidence in the deployment change. If denials do appear against bubblewrap's namespace or mount operations, that is a genuine gap in this runbook rather than a local quirk, and the resolution belongs in this section.

> **Do not resolve this by setting SELinux permissive:** that trades a scoped, documented problem for an undocumented reduction in the security posture of the one machine holding customer data. A targeted policy module, or corrected file contexts, is the proportionate fix.

### 9.7 When the sandbox helper cannot start — and two consequences that outlive it

**The failure.** With the sandbox enabled, a host on which the helper cannot start fails every Bash call —
in *any* session, including a fresh, ordinary interactive one — immediately with:

```
apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument
```

**A working `bwrap` does not rule this out.** The failing step is Claude Code's own `apply-seccomp`
helper, which runs inside bubblewrap. What is established about the cause, what is still open, and the
re-enable gate are **`SANDBOX-DECISION.md`** (§2.2, §4); the shipped policy disables the sandbox as a
result.

**Consequence 1 — with the sandbox disabled, agent-SDK, CI and containerised use are not blocked.** If the
sandbox is ever re-enabled (`SANDBOX-DECISION.md` §4), re-test automation on the host before wiring a
pipeline: while the helper failure stands, any session — automated or interactive — fails as above.

**Consequence 2 — `failIfUnavailable: false` does not fail open for this error class.** §9.5 presents
fail-open as protecting the team from a dependency problem. It does; it does not protect them from this —
the session hard-fails. "Fails open" describes the failures its author anticipated.
That limit on the guarantee is the reason the flag stays `false` semi-permanently on a shared host rather
than as stage one of two.

**Why `sudo` fails from inside a session, and why the host is fine.** A related symptom that looks alarming
and is not:

```
sudo: /etc/sudo.conf is owned by uid 65534, should be 0
```

Inside the sandbox's user namespace, root is remapped to an unprivileged UID, so `/etc/sudo.conf` appears to
be owned by `nobody` and `sudo` — correctly — refuses to run a setuid binary against a file it cannot trust.
**The host's `sudo` is undamaged.** This is the sandbox working as designed.

**The operational rule that follows:** every root-level step in this runbook and in `OPERATIONS.md` must be
run from a real terminal — RDP or SSH — and never from inside a Claude Code session, including through the
interactive shell escape. Any procedure that says "run as root" means "in a real shell".

## 10. What IT sets up once

The one-time setup is the full host build, owned by `OPERATIONS.md` Part 1 (§1.0–§1.12) — with `QUICKSTART.md` (`make pin` + `make quickstart`) as the governance-first short path — and proven by the acceptance checks in `OPERATIONS.md` §1.10. Build and verify from those, not from this section. `CURRENT-STATE.md` is each site's record of what its built hosts hold.

Three conclusions that shape the procedure, stated here because they are decisions rather than steps:

- **Resolve the search path before everything** (§3.3; `OPERATIONS.md` §1.1). Otherwise the RPM is shadowed on `PATH` and every subsequent verification silently interrogates a private binary instead.
- **`cc-install.sh --apply` places the whole control plane** — the policy with its checksum baseline, the operator scripts, the managed hooks, the `1733` log directories, the slice drop-in, the status line, the IDE wrapper, and the `profile.d` drop-ins in both shell variants (`.sh` alone does not reach a csh-family login shell). `make quickstart` places the governance subset on its own. `OPERATIONS.md` §1.9 carries the hook-placement verification and the secret-guard smoke tests.
- **Two things the build does not settle by itself**: `forceLoginOrgUUID` is absent from the shipped policy until a site adds its own (§6.4), and the `/etc/skel` seed reaches an account only where its home is created from skel (§7.8).

## 11. What IT maintains over time

### 11.1 Recurring tasks

> This table states **what the cadence is and why**. The operational version — with the health-check
> triage table, the alert route and the joiner/mover/leaver steps — is `OPERATIONS.md` §4, and
> `SETTINGS-REFERENCE.md` §5 carries only the settings-specific rows. If the three ever disagree,
> `OPERATIONS.md` is the one being executed.

| **Cadence** | **Task** | **Mechanism** |
| --- | --- | --- |
| Daily | Health and drift check: version, settings integrity, credential modes, side installs, disk | cc-healthcheck.sh via systemd timer; a non-zero exit marks the unit failed |
| Weekly | Review the health check log for repeated warnings; check for security advisories | journalctl -u claude-code-healthcheck |
| Monthly | Version review and controlled update | cc-update.sh check, then stage / apply |
| Monthly | Full policy audit for the record | cc-audit.sh, filed with the change record |
| Quarterly | Re-verify the settings file against the current settings reference; new keys appear regularly | Manual review against code.claude.com |
| Quarterly | Review the allow list and deny list against what engineers actually needed | The denial log and support tickets |
| On joiner | Account created; user logs in once. **Do not rely on `/etc/skel`** — it reaches an account only where the home is created from it (§7.8), so anything a new account must have comes from managed settings or a profile.d drop-in. Confirm the home is mode 0700 at creation, and tell them the activity log exists (§11.7) | cc-audit.sh section 6 shows credentials present |
| On leaver | Revoke the Teams seat FIRST, then remove the Linux account and home directory. The seat is what grants access; removing the account alone leaves a live credential the person could use elsewhere — more so where the credential is on shared storage and not tied to a host. **Then verify the home is gone and not left owned by an unresolvable UID** | cc-audit.sh section 6 no longer lists the user; seat gone from the admin dashboard |
| On mover | An engineer reassigned between customers. **No procedure exists, and per-machine policy cannot express it** (§1.5). It is a conversation about which project directories they can reach, not a configuration change | — |
| On advisory | Out-of-band update outside the monthly cycle | cc-update.sh stage / apply, expedited change |

> On an image-built fleet, "version review and controlled update" primarily means **rebuild or replace
> the image**; the daily health check runs on every live host (the timer is per host). The leaver step
> matters most where homes and credentials are on shared storage: revoke the Teams seat first, then remove
> the home from that storage.

### 11.2 What tends to drift

- **Per-user side installs.** An engineer follows a public quickstart, runs the curl installer, and now has a self-updating private binary at `~/.local/bin/claude` that shadows the managed RPM. The health check looks for this specifically. It is the most likely way your version gate is defeated.
- **Settings file edited in place.** Someone fixes something at 2am and does not update the baseline checksum. The health check catches the change; the discipline of re-recording the checksum after every approved edit is what makes the signal useful.
- **New settings keys.** Claude Code adds capabilities frequently, and a capability your policy does not mention is a capability your policy does not restrict. This is why the quarterly re-verification exists.
- **Credential expiry.** Logins expire. Users get a three-day warning at startup, but a long-running background session that outlives the credential simply stops making progress. The health check surfaces credential files older than 80 days.
- **Disk growth.** Session transcripts accumulate in every home directory. `cleanupPeriodDays` governs retention — the default is 30 days.

> **Retention is a decision, not housekeeping:** those transcripts under ~/.claude are also the only record of what Claude actually did on this host. The settings file ships with 90 days, three times the product default of 30, because if you are ever asked what the agent touched in a customer project six weeks ago a 30-day window is already too late. That costs disk on a shared instance — section 11.6 has the sizing, and section 11.7 describes the activity log, which is a durable record independent of transcript retention and is what makes a shorter window survivable if disk is tight. Two pressures pull opposite ways here. Agree the number with whoever owns audit and IP obligations rather than accepting the shipped value, and if you need a longer window, size the volume for it or ship transcripts off-host.

### 11.3 If the instance is lost

Worth stating plainly because it shortens the conversation: Claude Code holds nothing on this host that needs backing up.

| **What** | **On rebuild** |
| --- | --- |
| The package | Reinstalled from the repository at the approved version, or already present in the image |
| The policy | Re-applied from version control — `settings/managed-settings.json` in this repository is the authored copy, never the instance's |
| The scripts and timer | Re-applied the same way |
| User credentials | Not recoverable and not needed. Each engineer runs claude and logs in again. No IT action |
| Session transcripts | Lost. See the retention note above — if they matter to you, they must be shipped off-host, because a rebuild takes them |
| Teams seats | Unaffected. Seats are held in the claude.ai organisation, not on the instance |

So recovery is: launch from the image, apply the policy and scripts, run `cc-preflight.sh` and `cc-audit.sh`, tell users to log in. The only thing that is genuinely gone is session history.

> Where homes are on shared storage the picture is *better* than the table implies — credentials and
> transcripts are not on the host, so a host rebuild does **not** lose them; only host-local
> `/tmp/claude-<uid>` scratch is lost, which is disposable. What a rebuild does lose is anything kept only
> in `/etc` or `/var/log` on that host — which is why the policy and scripts belong in the image, and the
> `/var/log/claude-code` logs are shipped off-host if they are to survive.

### 11.4 Change control triggers

Treat these as requiring a change record rather than routine maintenance:

- Any edit to managed-settings.json.
- Any version move, including a rollback.
- Adding a domain to the sandbox allowlist.
- Adding an entry to permissions.allow or excludedCommands.
- Enabling MCP servers or plugins.
- Any change to forceLoginOrgUUID or forceLoginMethod.
- **Promoting a host from cgroup v1 to v2** (kernel arg + reboot; re-test the sandbox after) — §11.5.
- **Any edit to an operator script or a hook.** These are code that runs as root (operators) or in
  every session (hooks), and they are redeployed from the bundle on every `cc-install.sh --apply` — so the
  edit must be made in the bundle, not on the host. See §12.3.
- **Deploying the policy to an additional host**, until fleet coverage is complete.

### 11.5 Resource limits on a shared host

Nothing in Claude Code limits what a single session consumes. An agent running a test sweep, a large build, or an accidental loop will take every core and as much memory as the kernel allows. On a shared RDP workstation that does not degrade one session, it degrades all of them, and the symptom reaches IT as "Claude is slow today" reported by the engineers who were not the cause. Sizing guidance alone does not prevent this; it only tells you how much you needed.

systemd already places every logged-in user in their own `user-<UID>.slice`, so a single drop-in applies limits to all of them and needs no per-user maintenance as engineers join and leave. The drop-in is placed by `cc-install.sh --apply` at `/etc/systemd/system/user-.slice.d/50-claude-code.conf`, followed by `systemctl daemon-reload`. Limits apply to **already-running** slices the moment the reload completes — which constrains what may safely appear in the file.

**What ships, and why it is only `TasksMax`.** The delivered drop-in — `systemd/user-.slice.d/50-claude-code.conf`, whose header is the authoritative, fuller statement of this reasoning — contains exactly one directive, valid on both cgroup generations:

```
[Slice]
TasksMax=12288
```

`TasksMax` is the one non-destructive runaway guard: new forks past the limit fail, nothing already running is touched, and no other user is affected — it stops a fork bomb, which is the failure mode that actually wedges a machine. Every other candidate directive is deliberately absent:

- **No memory limit.** cgroup v1's only systemd memory knob is `MemoryLimit=` — a hard, OOM-killing ceiling. One user slice can legitimately hold far more than any "fair share" figure, and a limit below real usage destroys running work the moment `daemon-reload` completes. The soft throttle (`MemoryHigh=`) is cgroup-v2-only. On a host where only a hard limit is expressible, the correct answer is no memory limit plus monitoring.
- **No `CPUQuota`.** A `user-.slice.d` drop-in is a *template*: it caps everything the user runs, not Claude Code, so a quota throttles unrelated work in the same slice. A quota is also a hard ceiling that wastes idle cores on a workstation whose large build or test workloads should burst to every core when the box is free. Fair share is a *weight*, not a quota — and the v1 weight (`CPUShares=1024`) is the systemd default, a no-op. Do not reinstate `CPUQuota` without reading the file header's account.
- **No `BlockIOWeight`.** It maps to cgroup v1 `blkio.weight`, enforced only by the CFQ/BFQ I/O schedulers — and RHEL 8 removed CFQ. Under any other scheduler the directive is accepted, written nowhere useful, and enforces nothing; it would read as an active control and not be one.

Detect the cgroup generation with `stat -fc %T /sys/fs/cgroup` (`tmpfs` = v1; `cgroup2fs` = v2). A v1 host can be promoted to v2 — `grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"` plus a reboot — which is what unlocks a real *soft* memory limit; treat promotion as a change (§11.4) and size it as §11.5b describes.

**Verify by reading the effective values back from the kernel, never by trusting the unit file** — v2-only directives are accepted and silently ignored on v1, so a file can look strict and enforce nothing. Any host, any user, real terminal:

```bash
stat -fc %T /sys/fs/cgroup          # tmpfs = v1 ; cgroup2fs = v2
systemctl show user-$(id -u).slice -p CPUQuotaPerSecUSec -p TasksMax -p MemoryMax
```

**Pass:** `CPUQuotaPerSecUSec=infinity`, `TasksMax=12288`, `MemoryMax=infinity` — the infinities are the decision, not an omission. **Fail:** any other value means a stale directive survives in the running slice (removing a line and reloading does not always clear one); clear it explicitly, e.g. `systemctl set-property user-<UID>.slice CPUQuota=`.

> **Measure before you limit.** Leave headroom for the OS and the desktop, divide the remainder by expected concurrency, and add roughly 30% so one busy session is not throttled while the host is otherwise idle. Under-provisioning is worse than no limit at all, because an OOM kill loses the engineer's work rather than merely slowing it — which is exactly why the shipped drop-in carries no memory limit.

### 11.5b Resource limits depend on the host's tenancy model

Resource limits are a **contention** control, so the correct answer differs per tenancy
model. There are two, and conflating them yields either a useless config or
a harmful one.

| | **Single-tenant (one engineer per instance)** | **Shared host (many engineers, one kernel)** |
| --- | --- | --- |
| Tenancy | One engineer per instance | Many engineers, one kernel |
| Memory cap on the user slice | **Not wanted.** The engineer *should* be able to use the whole instance; a cap wastes paid-for RAM and risks OOM-killing their own work | Wanted only as a *soft* limit — which cgroup v1 cannot express, so none ships (§11.5) |
| CPU quota | Not wanted, same reason | Not wanted either — a template-slice quota caps everything the user runs and wastes idle cores (§11.5) |
| Still worth setting | `TasksMax` only — a fork-bomb backstop that costs nothing | `TasksMax` only; add memory *protection* + soft ceiling if the host moves to cgroup v2 |
| What ships | The TasksMax-only drop-in | The same TasksMax-only drop-in |

**Reserve memory rather than cap users.** On a shared host the requirement is usually stated
as "leave enough for the OS and everyone else", and the instinct is to cap each user. Capping
is the blunt instrument — it throttles a user even when the machine is idle. cgroup v2 offers
the better primitive: **protect** what must not be squeezed instead of limiting what may grow.

- `MemoryMin=` on `system.slice` — memory the kernel will **not** reclaim from the OS and
  daemons under pressure. This is the actual "reserved space" control.
- `MemoryLow=` — softer protection; reclaimed only after other cgroups have been squeezed.
- `MemoryHigh=` on `user-.slice` — a soft ceiling that throttles a heavy user *only* when the
  host is contended, without OOM-killing them.

Together: an idle host lets one engineer use nearly all of RAM; a busy host protects the OS
first and slows the heaviest user rather than killing them. **This combination is only
expressible on cgroup v2** (§11.5), which is the argument for promoting a Rocky 8 host if
memory contention ever becomes the real problem.

**No cgroup-v2 sizing ships.** The drop-in is TasksMax-only on both generations, and
`cc-install.sh` accepts `--with-v2-slices` as a no-op that warns and continues, so a runsheet
that still passes the flag does not abort a build. For a cgroup v2 shared host: measure on that
host, install protection and soft ceiling **together** (a soft ceiling with nothing protected
underneath it achieves much less), ship the result through `cc-install.sh`, and read the
effective values back from the kernel rather than trusting the unit files. **Do not install
either on a single-tenant instance** — there is no contention to arbitrate.

See `LOCAL-VS-AWS.md` for the complete list of differences between the shared-host and
single-tenant deployments.

### 11.6 Disk sizing

| **Item** | **Guide** |
| --- | --- |
| RAM per concurrent session | Approximately 2 GB on top of the desktop environment |
| /home per engineer | 10 GB. Transcripts at 90-day retention run roughly 0.5–2 GB for a heavy user; the remainder is working files |
| /var/log/claude-code | 5 GB. Activity and denial logs are a few MB per engineer per month; audit reports are around 50 KB each, retained 24 months by the logrotate configuration (`systemd/claude-code-logrotate` in the repository, installed to `/etc/logrotate.d/`) |
| Alert threshold | /home at 85%, already implemented in cc-healthcheck.sh |

Put /home on its own volume. Filling the root filesystem with session transcripts takes the entire workstation down, not just Claude Code.

cleanupPeriodDays is set to 90 rather than the product default of 30. This is a decision to make rather than inherit: transcripts are the only record of what the agent did in a project, so if the organisation may be asked about work six weeks later, 30 days is already too late. The activity log described in the next subsection gives a durable record independent of transcript retention, which is what makes a shorter window survivable if disk is tight. Agree the number with whoever owns audit and IP obligations.

> Where `/home` is shared network storage, "put /home on its own volume" is already true — but that
> volume is shared across every host and every user, so the alert threshold in the health check watches a
> *shared* volume. Two more things to size for: the per-user cache under `~/.cache/claude-cli-nodejs/` as
> well as transcripts; and `/var/log/claude-code`, which is **host-local**, so on an image-built fleet the
> activity and denial logs need shipping to a central store to survive a rebuild.

### 11.7 The activity and denial logs

Two hooks provide the evidence layer, one enforces the secret-filename rules whose own enforcement depends on the version (§8.8), one converts self-update attempts into a signpost, and one redacts credential-shaped text from tool output. All are installed to /usr/local/sbin at mode 0755 — they run as the engineer, not as root — and are registered in the hooks block of managed settings. Because allowManagedHooksOnly is true, no other hook can load.

| **Hook** | **Script** | **What it does** |
| --- | --- | --- |
| PreToolUse | `cc-audit-hook.sh` | Evidence. One JSON line per Bash, Edit, Write or WebFetch call to /var/log/claude-code/activity/<user>.jsonl |
| PreToolUse | `cc-secret-guard-hook.sh` | **Enforcement.** Blocks a Read, Edit, Write or NotebookEdit whose target *basename* looks like a credential. The enforcement of record for the filename rules, whose own enforcement depends on the version (§8.8), and covers Read, which the audit hook deliberately does not |
| PreToolUse | `cc-upgrade-guard-hook.sh` | **Signpost.** Blocks a Bash call that tries to move the Claude Code version (`claude update`, npm sideload, vendor installer, package-manager transactions on `claude-code`) and points at the version-bump procedure, `OPERATIONS.md` Part 7. The versionlock is the enforcement; this replaces the bare denial with directions |
| PostToolUse | `cc-redact-hook.sh` | **Enforcement.** After any tool runs, replaces credential-shaped text in its output (keys, fixed-prefix tokens, JWTs, URL passwords, base64/hex copies) before the model sees it, and writes a `redaction` event (kind and count, never the text) to the activity log. Covers what a script prints, which the rules on the command cannot see; it cannot stop a program that sends a secret elsewhere itself |
| PermissionDenied | `cc-denied-hook.sh` | Evidence. What the policy refused, and the reason where Claude Code supplies it, to /var/log/claude-code/denied/<user>.jsonl |

**Why the activity log exists.** Session transcripts under each home directory are the only other record of what the agent did. They are owned by the user, who can delete them, and cleanupPeriodDays expires them. On a host holding customer IP under NDA that is not an audit trail. The activity log is a record IT owns, outside the user's reach, that survives transcript expiry and an instance rebuild if /var/log is shipped off-host.

**Why the denial log exists.** The telemetry metric claude_code.code_edit_tool.decision covers permission decisions for the code-editing tools only — it does not see a blocked Bash command. The hook is the only source for the quarterly "review the allow list against what engineers actually needed" task. The summariser script lives in `OPERATIONS.md` §4.2, so there is one copy to keep working. Test it on each build with a real refusal of each kind — a **classifier** refusal and a **rule** refusal — in an interactive session, because headless `claude -p` sessions may not fire it, and from a **fleet-policy** session, because the admin policy does not deny `sudo`.

A destination or command appearing repeatedly is not misbehaviour. It is autoMode.environment or permissions.allow missing an entry — see section 8.7.

**The design properties are specified once, in `SETTINGS-REFERENCE.md` §3.7, and are load-bearing** — do not edit any hook without reading them. The short form: the hooks record the **shape** of a call (`command`/`file_path`/`url`), never its content — a canary string placed in file content is asserted by the test suite never to reach the log, which is the line between an audit trail and employee monitoring, and the same reason OTEL_LOG_USER_PROMPTS stays disabled (section 13). The two evidence hooks **always exit zero** (an exit of 2 from a `PreToolUse` hook blocks the tool; any other non-zero exit warns on every call), while the secret guard and the upgrade guard exit 2 on a positive match by design and fail **open** on any parse error — the roles are distinct and all are intentional; do not "fix" any of them to behave like another.

**The tamper ceiling, stated honestly.** The log directories are mode `1733` — world-writable so any session can append, with the sticky bit set so one user cannot delete or rename another's record — and the hooks create each log file `0600`, so one engineer cannot read another's history. That is the practical ceiling for an unprivileged append. The honest limit: a determined user can append spurious lines to their own file — accepted and registered in `LIMITATIONS-AND-RISKS.md` Part 1. The log directories themselves cannot be steered from a session: the hooks clear every `CC_*` variable and read them only from the installed config. If stronger tamper-evidence is required, ship the logs off-host — which is separately necessary because `/var/log/claude-code` is host-local and a rebuild takes it (§11.6), and becomes mandatory in the single-tenant model (`LOCAL-VS-AWS.md` §2.7).

**The interplay with transcript retention.** Transcripts under `~/.claude` are user-owned, user-deletable, and expire with `cleanupPeriodDays`; the activity log is the durable record IT owns, independent of all three properties. That independence is what makes a shorter transcript window survivable if disk is tight (§11.6) — the two retention decisions should be taken together.

**Tell the engineers it exists, before they arrive.** This log records, per named person, every command run and every file path and URL touched. The runbook's position is that this is an audit trail rather than employee monitoring, and the content boundary above is what makes that true — but that is an argument for why the log is proportionate, not a reason to keep it quiet. Section 13 already says to involve HR and legal before enabling a weaker form of capture through OpenTelemetry, so the same applies here, and more so. Agree the wording with HR, state it in the onboarding material for this host, and keep the startup announcement in managed settings consistent with it. A control an engineer discovers by accident costs more trust than it was ever worth.

> **Implementation notes.** The delivered hooks parse stdin with **python3** (`jq` is not assumed) and
> whitelist only the shape fields, so `file_text` and other content never touch the log. The test suite
> asserts this section's own criteria: a canary string in file content does not appear in the log, and
> malformed and empty input both still exit 0. `settings/managed-settings.json` registers all five, and
> `allowManagedHooksOnly` keeps them the only hooks that load.

### 11.8 Exception requests

The policy locks MCP servers, plugins, marketplaces and sideload flags. Engineers will ask for exceptions, and **a lockdown with no published route is a lockdown that gets quietly worked around.** So the route is a deliverable of the deployment, not an afterthought — publish it, with the default answers, at the same time as the policy.

The table of request types and default answers is in `OPERATIONS.md` §4.5, and is kept there rather than in two places. Two properties of it are decisions rather than procedure, and belong here:

- **Target 24 hours** on the two most common requests — a destination the classifier keeps blocking, and an internal domain for the sandbox allowlist. An engineer blocked for a week finds another way, and that way will not be one you designed.
- **An MCP server or a plugin is arbitrary code holding the agent's permissions.** The default answer is no until someone has read what it does. That is not obstruction; it is the same standard applied to any other code granted the agent's authority.

## 12. Operational scripts

The scripts accompanying this runbook install to /usr/local/sbin. **Every operator script in the table below** is root-owned, mode 0750 — the table is the list, so that adding a script cannot leave a count stale somewhere else. The hooks run as the engineer, mode 0755. Each is self-contained and requires only bash, python3 and coreutils — `jq` is deliberately not assumed.

Two placement rules the table does not repeat per row. `cc-install.sh` step [6] places the operator scripts on every apply. `cc-admin-session.sh` is the exception: it lands **only** under `--with-admin`, in step [12], next to the policy it bind-mounts, so a host built without that flag carries no escalation path at all — its own reference is [`ADMIN-SESSION.md`](ADMIN-SESSION.md), not a row here.

The repository also carries **repo-side tooling that never installs to a host** and is therefore not in this table: `cc-repo-perms.sh` and `cc-repo-setup.sh` (checkout hygiene), `cc-ci-check.sh` with `.github/workflows/ci.yml` and `.gitlab-ci.yml` (the CI checks, run on every push to either remote), and the `githooks/` guards. All are documented in the repository `README.md`, "Working on this repository"; the CI cadence row is `OPERATIONS.md` §4.2.

| **Script** | **When** | **What it does** |
| --- | --- | --- |
| `cc-preflight.sh` | Before install, and after any instance rebuild | Validates platform, AVX, memory, libc, sandbox dependencies, browser and xdg-open availability, loopback, managed-settings validity, and outbound reachability to every required host. Exits non-zero on a hard blocker so it can gate an automated build. |
| `cc-report.sh` | Weekly, via systemd timer | The estate report: runs every other check, ranks what came back against last week, and answers **BUMP:** and **REPORT TO MANAGEMENT:** as fields rather than prose. Runs as root because the evidence logs are `0600` per user inside `1733` directories and two probes under-report without it; an unprivileged run still works and names what it could not read. Writes `/var/log/claude-code/reports/` (`2750`, root and the `CC_REPO_GROUP` group), never the checkout. Exit 1 = alerts exist; exit 3 = the run could not complete. Driven by `claude-code-report.service` + `claude-code-report.timer` (Mon 07:30). Contract: [`REPORTING.md`](REPORTING.md) |
| `cc-version-watch.sh` | Weekly, via systemd timer | Asks the vendor repository whether a version above `requiredMinimumVersion` is published. Reads the pin from the policy every run and carries no version of its own. Exit 1 means a newer version exists (the unit shows failed on purpose); exit 3 means it could not tell, which is deliberately not the same as "we are current". Installs nothing and moves no package. Driven by `claude-code-version-watch.service` + `claude-code-version-watch.timer` (Mon 07:15). `OPERATIONS.md` §7.4 |
| `cc-healthcheck.sh` | Daily, via systemd timer | Version against approved, managed settings integrity and checksum, per-user credential modes and age, unmanaged side installs, connectivity, disk. Exits non-zero when attention is needed, so systemctl --failed surfaces it without extra monitoring glue. |
| `cc-drift.sh` | Whenever a host is suspected of differing from the repository, and before a re-apply that would overwrite local changes | Read-only: compares every file, directory and timer the last apply recorded against what is on the host now (missing, replaced by a link, edited, mode, owner), and each placed file against the checkout (`CC_REPO`, or `--repo DIR`) to show what a re-apply would change. It only reads and hashes the checkout — a root process never executes code from a group-writable tree. `--json` and `--out FILE` give the same report for a collector. Exit 0 = no drift, 1 = drift, 3 = it could not tell (no record, an unreadable file, `systemctl` failing), which is deliberately not the same as "no drift". Sees only what the record lists: a file someone added by hand is not looked for, and a file added to the repository since the last apply shows only as differing commits. A record written before checksums were kept is refused until one re-apply |
| `cc-update.sh` | Monthly, and on advisory | check / stage / apply / rollback. Refuses to upgrade while sessions are running, handles the versionlock dance, records the approved version, and smoke-tests the result. |
| `cc-audit.sh` | Monthly, and before and after every policy change | Read-only, evidence-grade snapshot: package and lock state, the full effective policy pretty-printed, an explicit present/absent check on every lock key, sandbox posture, per-user credential table, side installs, and claude doctor output. |
| `cc-bump-audit.sh` | Every version bump, and whenever a version-anchored claim needs re-asking | The deterministic lane of a bump: pin coherence across both policies plus `approved-version`, and the **probe manifest** — every version-anchored question this design rests on, re-asked against the running build. `--list-probes` prints the manifest from the code, so it cannot drift from what runs. Installs to `/usr/local/sbin` as well as living in the repo, because probes A5 and A8 under-report unprivileged: A5 cannot see a private install under a `0700` home, and A8 cannot resolve another user's `/proc/<pid>/exe`. Skips A3/A7 inside a privileged session, where the policy path is a bind mount. `OPERATIONS.md` Part 7 |
| `cc-install.sh` | Deploy / re-apply the control plane | Idempotent: places the policy (+ checksum baseline), the operator scripts, the managed hooks, the `1733` log directories, the status line and IDE wrapper, the `profile.d` drop-ins (both shell variants), the slice drop-in, the systemd units and logrotate; seeds /etc/skel; **enables every timer it places** — a unit placed but never enabled is a silent no-op, so the enable list is part of the contract, not an afterthought. Refuses to apply while the policy contains placeholders, while an autoMode array is missing `$defaults`, while the policy floor is above the version installed here (`--allow-below-floor` overrides), or from inside a privileged session. |
| `cc-audit-hook.sh` | Every Bash, Edit, Write and WebFetch call, automatically | PreToolUse hook — the activity record: one JSON line per tool call to /var/log/claude-code/activity/<user>.jsonl (timestamp, user, session, working directory, tool, and the command, file path or URL — the shape of a call, never contents or prompts). Purpose and exit contract: §11.7, `SETTINGS-REFERENCE.md` §3.7. |
| `cc-denied-hook.sh` | Every refused tool call, automatically | PermissionDenied hook — the denial record, and the only source for the quarterly allow-list review (the telemetry metric covers the code-editing tools alone). See §11.7. |
| `cc-secret-guard-hook.sh` | Every Read, Edit, Write and NotebookEdit, automatically | PreToolUse hook — enforcement, not evidence: blocks a call whose target *basename* looks like a credential, the enforcement of record for the filename rules, whose own enforcement depends on the version (§8.8). Allowlists `id_rsa.pub`, `.env.example`, `ca-bundle.pem` and similar. Exit contract: §11.7, `SETTINGS-REFERENCE.md` §3.7. |
| `cc-upgrade-guard-hook.sh` | Every Bash call, automatically | PreToolUse hook — the signpost: blocks self-update attempts and points at the version-bump procedure (`OPERATIONS.md` Part 7). Exit contract: §11.7, `SETTINGS-REFERENCE.md` §3.7. |
| `cc-redact-hook.sh` | Every tool call's output, automatically | PostToolUse hook — enforcement: replaces credential-shaped text in tool output before the model sees it and logs a `redaction` event. Always exits 0. See §11.7, `SETTINGS-REFERENCE.md` §3.7. |
| `statusline.sh` | Every prompt render, automatically | Not an operator script and not in /usr/local/sbin: one global copy at `/usr/local/share/claude-code/statusline.sh` (0755 root:root, local disk), referenced by the `statusLine` key in managed settings. Editing this one file changes the status line for the whole fleet. See section 7.7. |

### 12.1 Installation

`cc-install.sh --apply` places everything in the table above — including the managed hooks, the `1733` log directories, the slice drop-in, the status line, the IDE wrapper and both sets of `profile.d` drop-ins — and is the only supported install path. The build procedure that runs it is `OPERATIONS.md` Part 1, with the hook-placement verification and secret-guard smoke tests in §1.9 there. Raw `install` equivalents are deliberately not reproduced here: a hand-install bypasses the placeholder guard and the checksum baseline (§7.6), and is silently overwritten on the next `--apply` (§12.3).

Post-install verification — any host, as root, from a real terminal:

```bash
systemctl list-unit-files 'claude-code-*'
systemctl list-timers 'claude-code-*' --all
sudo systemctl start claude-code-healthcheck.service   # run once now
journalctl -u claude-code-healthcheck -n 50
```

**Pass:** `list-unit-files` names every unit the apply placed and shows each timer **`enabled`**, `list-timers` gives each one a next elapse, and the on-demand run reports the real account population and exits 0 (a non-zero exit with findings listed is the check working, not the install failing — §12.2).

**Fail:** triage per `OPERATIONS.md` §4.1. Read `list-unit-files` before `list-timers`, and read both: a timer that is placed but **`disabled`** never fires and appears in neither `list-timers` nor `systemctl --failed`, so every check it drives is silently absent while the files on disk all look right. Enabling is `cc-install.sh --apply`'s job; do not enable by hand, or the next apply is the only thing that knows.

A timer being enabled is still not evidence it has produced anything. A weekly unit enabled mid-week first fires at its next boundary, so `list-timers` showing a future elapse and no artefact yet is correct, not broken. What each unit writes and where is [`REPORTING.md`](REPORTING.md) §1.

### 12.2 Design notes

- The health check exits non-zero on findings so the systemd unit enters a failed state. If you already alert on `systemctl --failed`, no additional integration is required.
- The update script refuses to proceed while claude processes are running. On a shared RDP host this is essential — replacing the binary under a live session produces confusing failures.
- The audit script asserts each lock key is present and prints its value, rather than only dumping the file. An absent lock key is the finding, and a dump alone will not make it obvious.
- All scripts avoid touching user data. The audit script reads metadata — file modes, ownership, timestamps — and never reads the contents of `.credentials.json` or any transcript. The hooks record call shape only, never file contents (§11.7).

### 12.2b The contract every script honours — exit codes and messages

This is the **canonical home** for the contract. It is what makes a timer, a
monitoring rule or another script able to act on a result without reading the
output, and what stops a script that could not answer from looking like one that
answered "fine".

| Exit | Means | Who relies on it |
| --- | --- | --- |
| **0** | **Checked, and clean.** Every check the script owns ran, and none found anything | A green unit; `make verify`'s pass condition |
| **1** | **Ran, and the finding exists.** For a timer-driven unit this marks the unit **failed on purpose**, so `systemctl --failed` surfaces it with no extra monitoring glue | `systemctl --failed`; the report's ledger |
| **2** | **Usage error** — a bad flag or argument. Never used for a finding | An operator typing; nothing automated |
| **3** | **Could not tell.** The run did not complete, or the answer is unavailable. **Deliberately distinct from both 0 and 1**: "clean", "bad week" and "no answer" are three different states, and collapsing the third into the first is the failure this contract exists to prevent | Anyone about to claim a control holds |

**Not every script uses every code, and that is not a defect** — a script with no
way to fail to determine its answer needs no 3. What *is* a defect is exiting 0
on a path where a check was skipped. Two shapes carry their own contract:

- **The hooks exit 0 on every path but one.** A `PreToolUse` exit of 2 **blocks**
  the tool call, and any other non-zero surfaces a warning on every call. So the
  two evidence hooks (`cc-audit-hook.sh`, `cc-denied-hook.sh`) exit 0 always,
  including on malformed input — a logging bug must never block the call it was
  only meant to witness. The two guards (`cc-secret-guard-hook.sh`,
  `cc-upgrade-guard-hook.sh`) exit 2 **only** on a positive match and 0 on
  everything else, including their own internal errors: a parsing bug that
  exited 2 would become a fleet-wide denial of service. Cases **AH5**, **D5**,
  **S4** and **G** fence exactly this.
- **`cc-audit.sh` exits 0 whenever its record is on file**, findings or not: it
  produces an evidence snapshot rather than a verdict, prints the count of `**`
  lines, and says in the record what it could not read. It exits 3 when it could
  not run or could not write the record — "no audit on file" must not look like
  one.

**Messages.** A finding must name the problem **and** the remedy — a command, a
document section, or a named next step. "Investigate" is not a remedy. Three
rules follow from the same principle:

1. **Never print a clean result for a check that did not run.** Say what was
   skipped and why. `cc-report.sh` §11 lists every collector whether it ran or
   not; that inventory is the denominator.
2. **State the denominator wherever you state a result.** "Audited 11 account(s)"
   beats "healthy" — a check that reports *healthy* over one account of many has
   answered a different question.
3. **A message must not assert what the code did not verify.** A wrong
   explanation in a comment is worse than none, because the next editor believes
   it.

Which script has which cases, and which have none and why, is not written down
anywhere by hand — run **`tests/test-cc-scripts.sh --coverage`**. CI check
**[10]** runs the same thing and fails a push that adds an untested script with
no recorded reason (`tests/README.md`).

### 12.3 The bundle is the source of truth — never patch `/usr/local/sbin` in place

`cc-install.sh --apply` **redeploys every operator script from its bundle**, overwriting whatever is at the
destination. "Idempotent: places the operator scripts" means *overwrites* the operator scripts. So a fix made
directly in `/usr/local/sbin` has a lifetime of exactly one apply cycle — and the revert is silent: the only
symptom is output that looks exactly as it did before the fix. The same holds for Ansible, golden
images, GitOps and every other reconciliation loop.

**The rule, in three parts:**

1. **Change the source, not the target.** The patched copy must live in `bin/`, so that
   `cc-install.sh` deploys the corrected version. Anything placed only on the host is temporary by
   construction.
2. **Version the artefact and verify after the apply.** Compare the installed script with
   the bundle's copy (`cmp`) *after* `cc-install.sh` has run, to prove the fix survived.
   A silent revert becomes a loud failure.
3. **Treat an edit to an operator script or hook as a change** (§11.4), because it is code running as root or
   in every session.

## 13. Optional: usage monitoring

Claude Code can export OpenTelemetry metrics and logs. On a single shared instance this is optional, but it is the only way to answer questions about who is using the tool and what it costs.

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.corp.example:4317"
  }
}
```

| **Metric** | **Useful for** |
| --- | --- |
| `claude_code.session.count` | Adoption and concurrency on the shared host |
| `claude_code.cost.usage` | Cost attribution per user or team |
| `claude_code.token.usage` | Capacity planning |
| `claude_code.code_edit_tool.decision` | Permission decisions for the code-editing tools only. It does not see a blocked Bash command, so this is not the allow-list signal — use the PermissionDenied hook for that, per section 8.7. |

> **Privacy by default:** prompts, responses and tool details are redacted unless you explicitly enable OTEL_LOG_USER_PROMPTS, OTEL_LOG_ASSISTANT_RESPONSES or OTEL_LOG_TOOL_DETAILS. Enabling those on a shared engineering host has employee-monitoring implications; involve HR and legal before you do. Note also that no metric here gives you a usable allow-list signal: code_edit_tool.decision covers the code-editing tools only, and a blocked Bash command is outside it. Use the PermissionDenied hook instead — it records what was actually refused, without capturing prompts or file contents.

**Verify this against DISABLE_TELEMETRY before building on it.** The deployed policy sets `DISABLE_TELEMETRY=1` to close the Anthropic-bound paths in section 1.5. Whether that also suppresses the OTLP exporter to your own collector is not documented either way, so do not assume the two compose: on a pilot host, deploy the block, run a session, and confirm metrics actually arrive. If they do not, drop `DISABLE_TELEMETRY` and the umbrella `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which the policy also sets, and close the same paths with the narrower `DISABLE_FEEDBACK_COMMAND`, `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` and `DISABLE_ERROR_REPORTING` instead.

Note that a delivered `OTEL_EXPORTER_OTLP_ENDPOINT` triggers a security approval dialog for the user when it arrives through server-managed settings. Delivered through the endpoint-managed file on a machine you administer, it applies directly.

> The shipped policy does not carry this block. If it is adopted, the collector must be a host under the
> site's own internal domain, and added to the sandbox allowlist if the sandbox is enabled. The shipped
> policy sets `DISABLE_TELEMETRY=1`, so run the compose check above before relying on OTLP.

## 14. Troubleshooting

| **Symptom** | **Cause and fix** |
| --- | --- |
| `claude: command not found` | PATH. The RPM places the binary on the system PATH, so this usually means a broken install or the user is on a shell that has not re-read its environment. Confirm with rpm -q claude-code and which claude. |
| `Illegal instruction` | The CPU or hypervisor does not expose AVX. There is no workaround for the native binary; move to an instance family that exposes it. |
| `Error loading shared library libstdc++.so.6` | The musl binary was installed on a glibc host, usually because a musl cross-toolchain is present. Reinstall and confirm with ldd --version. |
| Login shows a code to copy and paste | The browser cannot reach the loopback callback. Check that a browser and xdg-open exist in the RDP session, DISPLAY is set, and loopback is not filtered. See section 6. |
| Login fails despite a valid Teams seat | A stray ANTHROPIC_API_KEY is overriding the subscription. unset it, remove it from the shell profile (incl. ~/.cshrc/~/.tcshrc), confirm with /status. Setting forceLoginOrgUUID prevents this class of failure. |
| Login refused with an organisation error | forceLoginOrgUUID is set and the account belongs to a different organisation. Expected behaviour — verify the seat, not the config. |
| Managed policy does not appear to apply | Run /permissions to see which file each rule came from, and /status to see the active managed source. If server-managed settings are configured in the claude.ai console, they take over from the local file entirely. |
| A permission rule silently does nothing | Most often the anchor. Read(/etc/shadow) anchors at the settings source, not the filesystem root; you need Read(//etc/shadow). `claude doctor` reports a rule the schema rejects; whether a valid rule matches is answered by `/doctor` inside a session. |
| Sandbox will not start | **N/A while the shipped policy disables the sandbox (`SANDBOX-DECISION.md`).** If enabled: bubblewrap or socat missing, or user.max_user_namespaces is 0. With failIfUnavailable false sessions continue WITHOUT sandbox enforcement and only warn, so treat a health-check finding here as urgent rather than cosmetic; with it true the same condition blocks every session instead. On Rocky 8 also check for SELinux denials against bwrap — see section 9.6. `socat` comes from `appstream`, not EPEL (§3.4). |
| Every Bash command fails: `bwrap: Can't mkdir /home/<user>/…` | The `HOME` symlink. Where the directory publishes the home path as a symlink, mount-namespace isolation cannot create a mount point through the symlinked parent. Confirm with `readlink /home/<user>`; check `/etc/profile.d/claude-code-home.{sh,csh}` exist and the session is a fresh login. Permanent fix: the directory's home-directory attribute (`OPERATIONS.md` §1.6) |
| Every Bash command fails: `apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument` | The sandbox helper cannot start (§9.7; cause and status: `SANDBOX-DECISION.md` §2.2). `failIfUnavailable: false` does not fail open for this class; the remedy that works is the shipped one, `sandbox.enabled: false` |
| `sudo` fails inside a session: `/etc/sudo.conf is owned by uid 65534` | Expected, and not damage. Root is remapped to an unprivileged UID inside the sandbox's namespace, so setuid correctly refuses. **The host's `sudo` is undamaged.** Run root-level work from a real RDP/SSH terminal — see §9.7 |
| Version moved unexpectedly | Either versionlock was not applied, or the user has a private native install under ~/.local/bin. The health check reports both. **Resolve the search path before diagnosing anything else (§3.3).** |
| A fix to an operator script stopped working for no apparent reason | `cc-install.sh --apply` redeployed the bundle's copy over it. The patch must live in the bundle — see §12.3 |
| Auto-update not applying | Expected. Package-manager installs never auto-update, and DISABLE_AUTOUPDATER is set. Use cc-update.sh. |
| Resource limits not taking effect, or effects nobody configured | The delivered drop-in sets only `TasksMax=12288` (§11.5) — `CPUQuotaPerSecUSec=infinity` and `MemoryMax=infinity` are the intended readings, and any other value is a stale directive surviving in the running slice (clear with `systemctl set-property`). Remember v2-only directives are accepted and silently ignored on v1; check `stat -fc %T /sys/fs/cgroup`. See §11.5. |
| "Claude stopped working" partway through the day | Most likely a per-seat usage limit, not an outage. Have the user run /usage. Limits reset; there is nothing for IT to fix and nothing to investigate on the host. |
| An action was blocked and the engineer is stuck | Open `/permissions` and check the Recently denied tab; press r to retry. If the same destination keeps being blocked, it needs an `autoMode.environment` entry — see section 8.7. |
| General health check | `claude doctor` for install and settings diagnostics; `claude --debug` writes to ~/.claude/debug/<session-id>.txt. |

## 15. Decommissioning

### 15.1 Removing Claude Code from the instance

```bash
sudo dnf versionlock delete $CC_PKG
sudo dnf remove $CC_PKG
sudo rm /etc/yum.repos.d/$CC_PKG_REPO_ID.repo
sudo rm -rf "${CC_ETC:?load config first}"
```

```bash
# per-user settings, credentials and session history
# (run per account, or as part of account offboarding)
rm -rf ~/.claude ~/.claude.json
```

> Also remove any private native install (`~/.local/bin/claude`, `~/.local/share/claude`,
> `~/.cache/claude*`, `~/.local/state/claude`) — the RPM removal does not touch it. Where homes are on
> shared storage, the per-user `rm -rf ~/.claude …` cleans that user across all hosts at once.

### 15.2 Also required

- Revoke the Teams seat in the claude.ai admin dashboard. Removing the Linux account does not revoke the subscription seat.
- Remove the systemd timer and service units, the resource-slice drop-in, and archive the audit logs under /var/log/claude-code according to your retention policy.
- Remove the allowlist entries from the egress path if nothing else needs them.

## 16. Appendix: pre-release validation checklist

**The acceptance checklist is owned by `OPERATIONS.md` §1.10** — every check with a command and an observable pass condition — and the live pass/fail standing of each check is each site's record in `CURRENT-STATE.md`. Work through those before opening a host to engineers, and attach the results to the deployment change. A checklist you cannot fail is not a checklist, and it is not duplicated here so it cannot drift.

Three notes on reading it, which are decisions rather than checks:

- **The sandbox rows are N/A while the shipped policy disables the sandbox.** A host built per `OPERATIONS.md` Part 1 deploys a sandbox-off policy, so "sandbox starts" and "a non-allowlisted host is blocked" cannot pass — record them as not-applicable, not as failures. The re-enable gate is `SANDBOX-DECISION.md` §4.
- **The denial-log check is an interactive one.** Test the `PermissionDenied` hook with a real refusal in an interactive session — headless `claude -p` sessions may not fire it (§11.7).
- **A checklist passed on one machine is not a fleet gate.** The policy's host coverage, and the deviations a checklist run will meet (an absent `forceLoginOrgUUID`, a private install kept on purpose, home-directory modes), are each site's record in `CURRENT-STATE.md`.

## 17. Home directories on network storage: what to check, and why *(owner: the storage team)*

Claude Code keeps each engineer's OAuth credential (`~/.claude/.credentials.json`, mode `0600`) and every session transcript in the home directory. Where homes are on a network export, a file mode protects those files only as far as the export itself authenticates who is asking. On an export that accepts the mounting client's own claim of identity (NFS `sec=sys`), **any host permitted to mount it can present any UID and read every user's token and every session transcript**, customer-facing work included.

Two things to check, with the storage team:

- **Who may mount the export.** A host or subnet access list should limit it to the governed hosts.
- **Which security flavour it requires.** Kerberos (`sec=krb5` and stronger) authenticates the user instead of trusting the client.

This is independent of Claude Code, but Claude Code concentrates long-lived credentials and full transcripts there, and it undercuts the per-customer path-based segregation discussed in §1.5, which assumes file modes are a boundary. **Owner: the storage team.** It is not a Claude Code setting — none of this runbook's controls touch it. `cc-healthcheck.sh` section [3] checks what a host can see for itself — that each credential file is `0600`, each home's mode, and `~/.ssh`, `~/.gnupg` and `~/.aws` at `0700` — and cannot see who else may mount the export. A site records its answer, and any risk it accepts, in `LIMITATIONS-AND-RISKS.md`.

## 18. Reference: the access model the scripts assume

- **Claude Code is per-host, not client/server.** A CLI on one machine cannot attach to an install on another; there is no daemon or port. "Using a host's Claude Code" means having a shell on that host. Remote Control and claude.ai web sessions are session *continuations*, not remote CLI access, and the shipped policy disables Remote Control (`disableRemoteControl`).
- **One Linux account per engineer, with its home under `CC_HOME_ROOT`.** `cc-healthcheck.sh`, `cc-audit.sh` and probe A5 of `cc-bump-audit.sh` enumerate the homes under that root; per-user state anywhere else is outside those sweeps unless the account is a local one.
- **Engineers do not have root.** The policy is a root-owned file under `/etc/claude-code`, which binds only a user who cannot write there. With the sandbox disabled, `cc-preflight.sh` also checks that `user.max_user_namespaces` is `0`, because otherwise a local user can bind-mount their own policy over the managed one (`LOCAL-VS-AWS.md` §8.2).
- **Privileged work is a separate, gated session.** `cc-admin-session.sh` is placed only by `cc-install.sh --with-admin`, and who may open one is `CC_ADMIN_GROUP` and `CC_ADMIN_USERS` ([`ADMIN-SESSION.md`](ADMIN-SESSION.md)).
- **The stored reports are readable by one group.** `/var/log/claude-code/reports/` is `2750`, owned by root and the `CC_REPO_GROUP` group ([`REPORTING.md`](REPORTING.md)).
- **Shared homes make a fleet feel unified:** where accounts and homes are shared between hosts, any host you log into presents the same account (log in once, valid fleet-wide) and can `--resume` sessions started elsewhere. The only per-host requirements are an AVX CPU, glibc ≥ 2.17, and the `/etc/claude-code` policy file.
- **Concurrency caveat [UNVERIFIED]:** the same user running Claude Code *simultaneously* on two hosts against one shared home is not documented behaviour. State files use locking and timestamped backups, but network-filesystem lock semantics are weaker than local disk. Treat concurrent same-project sessions as unsupported until piloted.
- **Every host is verified on its own build:** facts verified on one host do not transfer to another. On each host's first build, re-verify OS build, AVX, mounts, cgroup version, and an end-to-end login (`cc-preflight.sh` covers most of it).

---

*Companion documents, indexed in `docs/README.md`: `CURRENT-STATE.md` (live state), `OPERATIONS.md` (build,
upgrade, run, recover), `SETTINGS-REFERENCE.md` (the policy key by key), `LIMITATIONS-AND-RISKS.md` (limits,
accepted risks, version-sensitive product dependencies), `LOCAL-VS-AWS.md` (site differences).*

*Artefacts: the host policy is `settings/managed-settings.json`. Also `hooks/` (the managed hooks),
`systemd/user-.slice.d/` (the TasksMax-only slice drop-in), `profile.d/` (the `HOME` and `BROWSER`
drop-ins, in both shell variants), and `share/` (`statusline.sh` and the IDE wrapper).*

*Re-verify sections 7–9 against code.claude.com before each version bump, and read
`LIMITATIONS-AND-RISKS.md` Part 3 at the same time — it lists the undocumented product behaviours this
design depends on.*
