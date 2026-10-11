# Quick deployment — governed Claude Code on one host

| | |
| --- | --- |
| **What** | The shortest path to a Claude Code install governed by site policy: which files a host needs, where each one must or may live, and the commands — raw and as `make` targets — that put them there |
| **Who** | An administrator with root on the target host. No prior knowledge of this repository is assumed |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and [`UPGRADES.md`](UPGRADES.md) records every move of it. Exercised on Rocky Linux 8; re-verified at each bump (`OPERATIONS.md` Part 7) |
| **Where** | Any RHEL 8 / Rocky 8 host: a shared login machine, a compute box, or a cloud instance being baked into an image |
| **Why** | Governance is per-host and file-based. A host either has the policy or it does not; everything else in this repository is operations on top. Deploying the policy first means engineers start work today without a half-built control plane deciding who waits |
| **Status** | In force. CI check [6] runs `make quickstart` into a staging tree (`DESTDIR`) with its guards on every push; which hosts it has been executed on is recorded in `internal/CURRENT-STATE.md` |
| **Owner** | The maintainer |

---

## 1. The one idea this rests on

`/etc/claude-code/managed-settings.json` is a **path compiled into every Claude
Code build** on Linux. Not a search path, not an environment variable — there
is no flag or variable that relocates it. Every copy of Claude Code that runs
on a host reads that file at startup and cannot be told not to.

The consequence is the useful part:

> **Governance attaches to the machine, not to the install.** Put the policy on
> a host and *every* Claude Code on it is governed — the `dnf` one, an
> engineer's `npm install -g`, the CLI bundled inside the VSCodium extension,
> a binary someone downloaded to `~/bin`.

So you do not have to win the argument about how people install it. You have
to win the argument about who owns `/etc` on the machine, which you already
have. §5 and §6 turn this into two deployment methods and a tradeoff.

**Scope.** The policy governs Claude Code *running on this host*. Somebody
running Claude Code on their own laptop against a mounted share is outside it.

## 2. What a governed host must have — the file manifest

Twelve artefacts. The policy, everything the policy names — including the
engineer's guide its welcome banner points at — the directories the hooks
write to, and the site config the hooks read. `make quickstart` places exactly
this set. The paths shown are the template's values (`config.example.sh`);
a site's `config.sh` is what decides them.

| # | File | Install to | Mode (root:root) | Can it move? |
| --- | --- | --- | --- | --- |
| 1 | `settings/managed-settings.json` | `/etc/claude-code/managed-settings.json` | `0644` | **No.** The path is compiled into the binary |
| 2 | `hooks/cc-audit-hook.sh` | `/usr/local/sbin/` | `0755` | Yes — `CC_SBIN`, any root-owned path on **local disk**, and the `hooks[].command` values inside the policy must name it too |
| 3 | `hooks/cc-secret-guard-hook.sh` | `/usr/local/sbin/` | `0755` | Same rule as #2 |
| 4 | `hooks/cc-denied-hook.sh` | `/usr/local/sbin/` | `0755` | Same rule as #2 |
| 5 | `hooks/cc-upgrade-guard-hook.sh` | `/usr/local/sbin/` | `0755` | Same rule as #2 |
| 6 | `hooks/cc-redact-hook.sh` | `/usr/local/sbin/` | `0755` | Same rule as #2 |
| 7 | `share/statusline.sh` | `/usr/local/share/claude-code/` | `0755` | Yes — must match the policy's `statusLine.command` |
| 8 | `docs/ENGINEER-GUIDE.md` | `/usr/local/share/claude-code/` | `0644` | Yes — must match the path named in the policy's `companyAnnouncements` |
| 9 | *(directory)* | `/var/log/claude-code/activity/` | `1733` | Yes — `CC_LOGDIR` in `config.sh`; the hooks read it from #12. The logrotate stanza and the policy's deny rules name it too |
| 10 | *(directory)* | `/var/log/claude-code/denied/` | `1733` | Same rule as #9 |
| 11 | `lib/cc-config.sh` | `/etc/claude-code/cc-config.sh` | `0644` | **No.** The hooks find config only here — a fixed path, so an engineer's environment cannot steer them |
| 12 | `config.sh` (the site's, from `config.example.sh`) | `/etc/claude-code/config.sh` | `0644` | **No**, same reason. Without it the logging hooks write nothing and the guards cannot name the support contact |

Plus two **records**, convention not mechanism, both in `/etc/claude-code/`:
`approved-version` (the version the fleet is on) and
`managed-settings.json.sha256` (so drift is detectable later).

### The rules when you do move something

- **Change `config.sh` and the static files together.** The policy, the
  systemd units, the logrotate stanza and the sudoers drop-in are read by
  programs that never source `config.sh`, so they name paths literally. A
  mismatch does not error — it looks configured and enforces nothing.
  `make quickstart` and `cc-install.sh` cross-check every one against
  `config.sh` (`lib/cc-coupling.py`) and refuse.
- **Root-owned, never group- or world-writable.** The hooks run *as the
  engineer*; a hook the engineer can edit is a control the engineer owns.
- **Local disk, never NFS.** Hooks run synchronously before every matching
  tool call. A hung mount means every session on the host hangs with it.
- **`0755`, not `0750`.** The hooks execute as the engineer's own uid. Mode
  `1733` on the log directories lets engineers append to their own file and
  stops them listing, renaming or deleting anyone else's — but *reading* is
  governed by the file's own mode, and the names are guessable
  (`<user>.jsonl`). The hooks therefore create their logs `0600` (`umask 077`
  before the append); the directory mode alone would not keep one engineer's
  history from another.

### Base prerequisites

| Needed | Provided by | Note |
| --- | --- | --- |
| `bash`, `coreutils`, `awk` | base install | always present on Rocky 8 |
| `/usr/bin/python3` | `dnf -y install python36` | the hooks and status line parse JSON with it. **`platform-python` alone does not provide `/usr/bin/python3`** — a minimal Rocky 8 needs the package |
| the `claude` binary | §4 (dnf) or §5 (user-local) | governance files may precede it; nothing breaks if the policy lands first |

### Other `/etc` files, for completeness

| File | Written by | Needed for |
| --- | --- | --- |
| `/etc/yum.repos.d/claude-code.repo` | §4 / `make pin` | Method A only — where dnf gets the package |
| the `versionlock` entry | §4 / `make pin` | Method A only — holds the exact version |
| `profile.d` drop-ins, logrotate, systemd timer/units, `/etc/claude-code/{config.sh,cc-config.sh}`; with `--with-admin`, `/etc/claude-code-admin/` | `bin/cc-install.sh --apply` | the full control plane — §10 |

One product feature deliberately not used: Claude Code also merges policy from
an `/etc/claude-code/managed-settings.d/` drop-in directory. This deployment
ships one file on purpose — a single artefact you can read whole and hash.

## 3. The hooks: what each does, and why they are not optional

### How they are wired

The `hooks` key **inside the managed policy** registers them — there is no
other registration. For each matching tool call, Claude Code runs the named
command *as the engineer*, feeding one JSON object on stdin (tool name, tool
input, session id). The policy also sets `allowManagedHooksOnly: true`, so
hooks users add in their own settings are ignored: what the policy names is
all that runs.

The exit-code contract (per the product's hook documentation): **exit 0** =
proceed; **exit 2** = block the call, stderr becomes the reason shown to
Claude; **any other non-zero** = *non-blocking* error — the call proceeds and
a warning appears in the transcript.

That is all the wiring this runsheet needs. The key-by-key specification —
matchers, each hook's contract, and the three design properties any edit to
the hooks must preserve — is [SETTINGS-REFERENCE.md](SETTINGS-REFERENCE.md)
§3.7.

### `cc-audit-hook.sh` — the activity record

*PreToolUse on `Bash|Edit|Write|WebFetch`.* Appends one JSON line per call to
`/var/log/claude-code/activity/<user>.jsonl`: timestamp, user, session, tool,
and the command / path / URL. It records the **shape** of a call only — never
file contents, never prompts — and it always exits 0, so a logging failure
never becomes a denial of service. Both are load-bearing design properties;
[SETTINGS-REFERENCE.md](SETTINGS-REFERENCE.md) §3.7 specifies them, with the
reasoning, alongside the third.

One honest limit, stated rather than hidden: an engineer can redirect *their
own* trail. Treat these logs as best-effort operational evidence, not a
tamper-proof record — the deny rules and the secret guard do not depend on
them. The full evidence model — why the logs exist, the tamper ceiling of
mode `1733`, the `CC_*_DIR` override the test suite needs, and when to ship
logs off-host — is [RUNBOOK.md](RUNBOOK.md) §11.7.

### `cc-secret-guard-hook.sh` — the control that closes a documented gap

*PreToolUse on `Read|Edit|Write|NotebookEdit`.* This is the security
load-bearing one. The deny rules that match secrets by filename
(`Read(**/.env)`, `Read(**/*.pem)`, …) are glob patterns, and whether Claude
Code enforces those on Linux depends on the version: `/doctor`, run inside a
session on the build in use, says whether it does. This hook is the enforcement of record either way: it
matches the basename of every file-tool call against credential patterns
(`.env`, `.env.<name>`, `*.pem`, `id_rsa*`, `.netrc`, `credentials`, …) and
exits 2 — blocking the call — on a hit. For `.env.<name>` it is the only
control: the policy carries no `.env.*` rule, so that `.env.example` stays
readable.

### `cc-denied-hook.sh` — the denial record

*PermissionDenied on `Bash|Edit|Write|WebFetch`.* Appends one JSON line per
refusal to `/var/log/claude-code/denied/<user>.jsonl`. This is the **only**
source for the quarterly review of the rule set against what engineers
actually needed: a command showing up here repeatedly is usually a missing
allow-list entry, not misbehaviour.

### `cc-upgrade-guard-hook.sh` — the signpost

*PreToolUse on `Bash`.* Blocks self-update attempts — `claude update`, an npm
sideload of the CLI, the vendor's installer one-liner, a package-manager move
of `claude-code` — with exit 2 and a message pointing at the version-bump
procedure ([OPERATIONS.md](OPERATIONS.md) Part 7). The version was never
holdable by this hook: the RPM versionlock and root ownership do that. What
the hook removes is the *confusing dead end* — without it, an upgrade attempt
dies as a bare permission error that explains nothing.

### `cc-redact-hook.sh` — what comes back

*PostToolUse on every tool.* The rules and the guards above judge what Claude
asks for: a command line, a file name. None of them sees what a program prints,
so `python3 report.py` that prints a private key would put the key in front of
the model. This hook reads every tool's output after it runs and replaces
credential-shaped text — private keys, fixed-prefix cloud and SaaS tokens,
JWTs, a password inside a URL, and base64 or hex copies of those — with a
`[REDACTED by IT policy: <kind>]` marker before the model sees it, and logs the
event (never the text) to the activity log. It matches shapes, so a password
with no shape passes, and it cannot stop a program that sends a secret
somewhere itself; that is the network layer's job.

### What actually happens if they are missing

Precisely this, and it is worse than breakage: **nothing visible breaks.** A
missing or non-executable hook is a *non-blocking* error — every tool call
proceeds, with only a warning line in the transcript. The product
documentation itself warns that a typo in a hook path *silently disables the
policy*. So a host with the policy but not the hooks:

- runs fine, and **looks** governed;
- enforces the path-prefix deny rules (those live in the policy proper);
- loses the filename secret rules wherever the version ignores them, and
  stops no `.env.<name>` file on any version — that enforcement *is* the hook
  (the version-dependent gap above);
- accumulates **no evidence**: no activity trail, no denial log, nothing for
  an incident or the quarterly review.

That is why the manifest treats hooks as part of governance, not as an
operational extra: the fleet runs with the OS sandbox off (see
[SANDBOX-DECISION.md](SANDBOX-DECISION.md)), and these hooks are the named
compensating controls for that decision.

If a host genuinely must run without them, strip the `hooks` and `statusLine`
keys from its policy copy rather than letting them dangle — a policy that
names things that do not exist is exactly the "looks configured, enforces
nothing" state this document exists to prevent. And treat that host as
temporary: it is governed but evidence-free.

## 4. Method A — one central, version-pinned install (dnf)

The package comes from Anthropic's RPM repository; `versionlock` holds the
exact version; every user runs `/usr/bin/claude`.

As root, from this repository (`git clone`, or the `make dist` tarball —
tracked files only, minus `config.sh` and the `internal/` site record). In the public template
edition, fill the placeholders first (`TEMPLATE.md`): `make quickstart` refuses a policy that
still carries one.

```bash
make config                     # required: config.sh from the template — §9; edit it before installing
PIN=$(python3 -c 'import json; print(json.load(open("settings/managed-settings.json"))["requiredMinimumVersion"])')   # the fleet pin, read from the policy
make pin VERSION="$PIN"         # repo file + dnf install + versionlock + record
make quickstart                 # the §2 manifest: config, policy, hooks, statusline, guide, log dirs
make verify                     # read-only: §8's checks
```

**Pass:** each target exits 0 (`verify`'s other codes: 1 = a check failed,
2 = unverifiable from inside an admin session — §8).
**Fail:** `pin` and `quickstart` refuse with a message naming the guard that
tripped, rather than half-applying — `quickstart`'s guards are listed
after the raw commands below; `pin`'s own three (root required, `DESTDIR`
refused, `VERSION` explicit on the command line) are in §7's table. Read a
`verify` failure against §8.

What `pin` does, spelled out — this is the specification, the Makefile is the
wrapper:

```bash
. lib/cc-config.sh               # the package, repo and key come from config.sh
[ -f /etc/yum.repos.d/$CC_PKG_REPO_ID.repo ] || cat > /etc/yum.repos.d/$CC_PKG_REPO_ID.repo <<EOF
[$CC_PKG_REPO_ID]
name=Claude Code
baseurl=$CC_RPM_BASEURL
enabled=1
gpgcheck=1
gpgkey=$CC_RPM_GPGKEY
EOF
dnf -y install python3-dnf-plugin-versionlock python36
dnf versionlock delete "$CC_PKG" 2>/dev/null || true   # a re-pin: the old lock would block the install
dnf -y install "$CC_PKG-$PIN"     # $PIN as set in the block above
dnf versionlock add "$CC_PKG"       # locks the exact version just installed, respin releases included
install -d -m 0755 "$CC_ETC"
echo "$PIN" > "$CC_ETC/approved-version"         # the bare version string, nothing else
```

On the first install dnf downloads the signing key and prompts you to confirm
its fingerprint. **Accept only**
`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE` — `gpg --show-keys`
prints the same key unspaced, as
`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`. A failed key download surfaces
later as `NO_PUBKEY BAA929FF1A7ECACE`.

The repo file is written only if absent, so a site that has repointed
`baseurl` at an internal mirror survives a re-run.

And what `quickstart` does, with the paths read from `config.sh` the way the
Makefile reads them:

```bash
. lib/cc-config.sh               # refuses, naming the keys, a config.sh that does not set every one
install -d -m 0755 "$CC_ETC" "$CC_SBIN" "$CC_SHARE"
install -d -m 0755 "$CC_LOGDIR"
install -d -m 1733 "$CC_ACTIVITY_LOG_DIR" "$CC_DENIED_LOG_DIR"
install -m 0644 lib/cc-config.sh "$CC_ETC/cc-config.sh"
install -m 0644 config.sh        "$CC_ETC/config.sh"
install -m 0755 hooks/cc-audit-hook.sh hooks/cc-secret-guard-hook.sh \
                hooks/cc-denied-hook.sh hooks/cc-upgrade-guard-hook.sh \
                hooks/cc-redact-hook.sh "$CC_SBIN/"
install -m 0755 share/statusline.sh "$CC_STATUSLINE"
install -m 0644 docs/ENGINEER-GUIDE.md "$CC_SHARE/ENGINEER-GUIDE.md"
install -m 0644 settings/managed-settings.json "$CC_POLICY"
( cd "$CC_ETC" && sha256sum managed-settings.json > managed-settings.json.sha256 )
```

plus guards the raw commands do not give you: refuse a `config.sh` that is
missing or does not set every key; refuse a policy that still carries a
`REPLACE-WITH-*` placeholder; refuse when not root; refuse when the
policy is bind-mounted in this shell (an admin session — installing through
it would clobber the admin policy); refuse when `/usr/bin/python3` is absent
(the hooks depend on it); refuse a `SBIN=`/`SHARE=`/`LOGDIR=` on the command
line that differs from `config.sh`; and refuse when a static file — either
policy, a unit, logrotate, sudoers — disagrees with `config.sh`. Under
`DESTDIR` the root, bind-mount and python checks are skipped — they are facts
about the target host, not the build host — but the config and cross-checks
always run.

**Scaling out.** Shared hosts: the same `make` lines per machine —
nothing in them is host-specific, and an identical policy hash everywhere is
your drift signal. AWS: run them in the image build so instances launch
governed (`make quickstart DESTDIR=/tmp/image-root` stages into a tree for
image tooling; `pin` runs live in the build's chroot). Bake **no** user state:
`activity/` and `denied/` must be empty in the image.

## 5. Method B — engineers install their own; the host still governs

Deploy **only the §2 manifest** — no package, no repo file, no versionlock:

```bash
dnf -y install python36    # the hooks' one dependency; Method A's pin does this for you
make quickstart
make verify                # will note that no claude is on PATH yet — that is fine
```

Engineers then install their own copy. The route to hand them
is the native installer — it needs no pre-installed tooling and lands in
their own home:

```bash
curl -fsSL https://claude.ai/install.sh | bash    # installs to ~/.local/bin/claude
```

The npm route (`npm install -g @anthropic-ai/claude-code`) exists for hosts
where `npm` is already present — a minimal Rocky 8 has none, and its default
`nodejs` module stream is far too old (upstream wants a current Node; enable
`nodejs:22` or later). A non-root engineer also needs a user-writable prefix
first (`npm config set prefix ~/.local`) — never `sudo npm install -g`.
Either route needs outbound HTTPS per user; see the reachability row in §6.

Every copy they produce reads the same policy (§1). Concretely, the host still
gets: all permission rules, both audit trails, the secret guard, telemetry
off, MCP restrictions, and a **version floor** — `requiredMinimumVersion` in
the policy is a hard refusal at startup for anything older. The policy's
`DISABLE_AUTOUPDATER=1` also reaches every copy, so nothing drifts by
self-update after install.

What the host does *not* get: a version **ceiling**. `versionlock` is a
package-manager fact and binds only the dnf package; an npm-installed copy is
whatever npm handed out that day.

## 6. The tradeoff, and a recommendation

| | A — central dnf | B — user-local, governed |
| --- | --- | --- |
| Policy, hooks, audit trails, secret guard | **identical** | **identical** |
| Version | one, pinned, fleet-wide | floor only; spread above it |
| "What version are you on?" during support | never asked | asked every time |
| Update control | admin decides, `cc-update.sh` | each engineer, whenever |
| Works without outbound internet per user | yes (dnf can mirror internally) | no — npm/claude.ai reachability per user |
| Per-host admin work | `pin` + `quickstart` | `quickstart` only |
| Failure a year from now | version held too long (visible, low risk) | subtle version-specific bugs nobody can reproduce (invisible, annoying) |

**Recommendation: Method A on every host IT manages.** The row that decides it is support: a fleet at one pinned version
turns "works on my machine" into a class of ticket that cannot exist. Method B
is the honest stopgap for a host where you own `/etc` but cannot yet own the
binary's lifecycle — governance is not what you give up, version discipline
is. The two methods share the `quickstart` step, so B upgrades to A later by
running `pin` and asking engineers to delete their local copies.

### Why there is no Method C — one shared binary on the filer

**This is a decision, so do not quietly reverse it.** Placing one `claude` on
a network share so every host sees it looks like it removes
the per-host step. It does not, four times over:

1. **It puts capability ahead of governance.** The policy cannot be shared —
   `/etc/claude-code/` is compiled in, always local — so a shared binary runs
   the moment a host mounts the filer, and is governed only when someone
   deploys the §2 manifest there. An ungoverned host with the tool preloaded
   is strictly worse than an ungoverned host without it.
2. **Its writers and its runners are different trust domains.** A binary on a
   group-writable share, executed by every engineer on every host, is a
   privilege-escalation path for anyone who can write it. The RPM chain —
   signed repo → dnf → root-owned local file, `rpm -V` verifiable — is the
   integrity story an auditor accepts.
3. **It deletes version governance.** Replacing one shared file moves every
   host at the same instant: no `versionlock`, no `approved-version`, no
   staged `cc-update.sh` move with rollback, no watching one host first.
4. **It saves almost nothing.** The §2 manifest is per-host regardless; the
   only step avoided is `pin` — the very step carrying the lock and the
   record. And the filer becomes a session-availability dependency: an NFS
   hiccup takes out every host's sessions at once.

Share the data — repo, homes, project trees. Never the enforcement, and never
the executable.

## 7. The Makefile

`make help` lists everything. Paths resolve through `lib/cc-config.sh` — the
same source every `cc-*` script uses (`config.sh`, which must set every key —
the loader has no defaults of its own). `CONFIG=` names a different config
file; a path is moved by editing `config.sh`, never on the command line:

```bash
make quickstart CONFIG=/srv/site/config.sh  # install from that config
make quickstart DESTDIR=/tmp/image-root     # stage a tree; no root; host guards
                                            # skipped, config and cross-checks still run
```

`SBIN=`, `SHARE=` or `LOGDIR=` on the command line are refused unless they
equal `config.sh` — the installed hooks and scripts read `config.sh`, so a
directory chosen anywhere else is one they never look in. `ETC` cannot be
overridden at all, because `/etc/claude-code` is compiled into the binary —
passing `ETC=` is refused, not silently obeyed.

| Target | What | Root? |
| --- | --- | --- |
| `quickstart` | the §2 manifest, with the guards in §4 | yes (unless `DESTDIR`) |
| `pin VERSION=x.y.z` | Method A package steps; `VERSION` must be on the command line, an environment variable is refused | yes |
| `verify` | §8, read-only. Exit 0 verified, 1 failed, 2 unverifiable (run from inside an admin session) | no |
| `install` / `install-ide` | the **full** control plane (`bin/cc-install.sh --apply`) | yes |
| `check` | dry-run of the full installer | no |
| `config` | create `config.sh` from the template | no |
| `test` | the self-test suite (`tests/test-cc-scripts.sh`) | some tests |
| `bump-audit` | version-bump audit: pin coherence + the probe manifest (`OPERATIONS.md` Part 7) | no |
| `dist` | tarball of tracked files for hosts without repo access | no |

Where `make` itself is absent (minimal images): `dnf -y install make`, or run
the raw commands in §4 — they are the specification and the Makefile only
wraps them.

## 8. Verifying it took

`make verify` checks the manifest: policy present, root-owned, unwritable by
others and hash-identical to the checkout; hooks executable / root-owned /
not writable by others; the log directories **the installed hooks actually
name** at `1733`; statusline present and root-owned; `python3` present;
`claude` version against `approved-version`. It exits 0 only when everything
holds, 1 on any failure, and 2 when run inside an admin session's bind mount
— where the fleet policy is not the file it can see, so "unverifiable", not
"verified".

Then prove the policy is live, **as an ordinary engineer, not root**:

```bash
claude --version          # expect the approved version (Method A)
claude doctor             # expect the /usr/bin/claude install (Method A)
```

In a session, ask Claude Code to run something the policy denies — `sudo -v`
is the clearest. Expect a *refusal citing a managed setting*; a permission
*prompt* means the policy did not load. Then confirm evidence is flowing.
As the engineer, checking their own trail (the file is theirs, `0600`):

```bash
. /etc/claude-code/cc-config.sh     # readable by everyone: it holds paths, no secrets
test -s $CC_LOGDIR/activity/$USER.jsonl && echo "audit trail OK"
```

or from an admin shell, substituting the engineer's actual username — an
admin's own `$USER` would check the wrong file:

```bash
sudo test -s $CC_LOGDIR/activity/<engineer>.jsonl && echo "audit trail OK"
```

Empty or missing after a session means the hooks are not running — §3 explains
why nothing else will have visibly failed, which is exactly why this check
exists.

## 9. The two configuration files (and why there is no third)

**Claude Code's behaviour** is configured in exactly one governed place:
`settings/managed-settings.json` — permissions, hooks, telemetry, MCP, login,
version floor. It is never generated from `config.sh`: a site's values are
written in the file itself ([`PUBLISHING.md`](PUBLISHING.md) §1 says what the
public template edition holds in their place). Every key is
documented in [SETTINGS-REFERENCE.md](SETTINGS-REFERENCE.md). It is the file
this document installs to `/etc/claude-code/`.

**This deployment's paths and site facts** are configured in `config.sh`
(gitignored; `make config` — or `bin/cc-repo-setup.sh`, which also enables the
git hooks — creates it from `config.example.sh`): install destinations, admin
group, support contact. The scripts and the Makefile read it through
`lib/cc-config.sh`, which carries no defaults and refuses a config that does
not set every key. Both install paths copy it to `/etc/claude-code/config.sh`,
where every installed script and hook reads it. A checkout with no `config.sh`
runs on the template's sample values and says so in the health check's config
line; the install paths refuse to run without one.

### The keys

Every key below must be in `config.sh`. The loader refuses a file that leaves
one out, and **there is no fallback value anywhere in code**. The value column
holds the template's suggestion, *for reference*. Your site's `config.sh` is
the truth, and `config.example.sh` explains each key in full. CI check [7]
holds this table to the loader and the template, so a row cannot go stale.
"Optional" means the key must be present but may be empty, and empty has the
meaning given.

| Key | What it decides | Template value |
|-----|-----------------|----------------|
| `CC_SITE_NAME` | the heading of the health check and the weekly report | *(per site)* |
| `CC_SUPPORT_CONTACT` | the address an engineer is told to ask; the policy banner must spell the same one | *(per site)* |
| `CC_ETC` | the policy directory. The product fixes it, so do not move it | `/etc/claude-code` |
| `CC_ETC_ADMIN` | the admin policy directory, `0700` root | `/etc/claude-code-admin` |
| `CC_SBIN` | operator scripts and hooks; the policy and units name it | `/usr/local/sbin` |
| `CC_SHARE` | status line, IDE wrapper, the engineer guide | `/usr/local/share/claude-code` |
| `CC_LOGDIR` | activity, denial and admin logs, health check output | `/var/log/claude-code` |
| `CC_UNITS` | systemd units and timers | `/etc/systemd/system` |
| `CC_LOGROTATE` | the logrotate directory (the file is `claude-code` in it) | `/etc/logrotate.d` |
| `CC_PROFILED` | the `HOME` and `BROWSER` login drop-ins | `/etc/profile.d` |
| `CC_SKEL` | new-account defaults | `/etc/skel` |
| `CC_CLAUDE_BIN` | the managed binary | `/usr/bin/claude` |
| `CC_ADMIN_GROUP` | who may open a privileged session (sudoers names it) | `cc-admins` |
| `CC_ADMIN_USERS` | the members `cc-install.sh` puts in that group (an array) | *(per site)* |
| `CC_REPO_GROUP` | optional: the group that owns this tree and reads reports | *(per site)* |
| `CC_EVAL_BIN` | optional: the one binary `cc-admin-session.sh -e` may run. Empty means `-e` is off | *(empty)* |
| `CC_FLEET_HOSTS` | optional: every host in the fleet, for the fleet-drift skill. Empty means unknown | *(empty)* |
| `CC_PKG` | the RPM name | `claude-code` |
| `CC_PKG_REPO_ID` | the dnf repo id and `.repo` file name | `claude-code` |
| `CC_RPM_BASEURL` | the vendor RPM repository | `https://downloads.claude.ai/claude-code/rpm/stable` |
| `CC_RPM_GPGKEY` | the vendor signing key | `https://downloads.claude.ai/keys/claude-code.asc` |
| `CC_UPDATE_STAGE_DIR` | where `cc-update.sh stage` puts a download | `/var/cache/claude-code-staging` |
| `CC_RELEASE_CHANNEL_URL` | the release channel `cc-version-watch.sh` corroborates against | `https://downloads.claude.ai/claude-code-releases/stable` |
| `CC_WATCH_MAX_AGE_H` | hours before repo metadata counts as stale | `26` |
| `CC_REPO` | the shared checkout the weekly report compares against | *(per site)* |
| `CC_HOME_ROOT` | the directory holding every engineer's home | *(per site)* |
| `CC_REPO_RUNAS` | optional: the non-root account the root-run report uses for CI and git in `CC_REPO`. Empty means that section is skipped under root | *(empty)* |
| `CC_REPORT_KEEP` | how many weekly reports to keep | `52` |
| `CC_METRICS_FILE` | optional: the Prometheus textfile. Empty means none | `/var/lib/node_exporter/textfile_collector/claude_code.prom` |

### Commands in these documents

Command blocks that an operator runs use these keys as variables, not their
values, so they are correct at any site. Load the config into your shell once,
before the first command:

```bash
. /etc/claude-code/cc-config.sh     # on an installed host
. lib/cc-config.sh                  # in a checkout, before anything is installed
```

A path spelled out in a diagram, a table or sample output is the template's
value, shown so the text is easy to read. It is not a value to type.

Engineers keep `~/.claude/settings.json` for personal preferences — theme,
editor keybindings — which is by design: precedence runs managed policy →
CLI flags → project `.claude/settings.local.json` → project
`.claude/settings.json` → `~/.claude/settings.json`, so nothing a user writes
can override a managed key. If you find yourself wanting a third config file,
one of these two is missing a key, not a file.

## 10. What this deliberately leaves out

Everything below is operations rather than governance. A host without it is
governed but unmonitored — a reasonable place to stop for a week.

| Deferred | What you lose | Where it lives |
| --- | --- | --- |
| health-check timer | nothing detects policy drift or a dead hook | [OPERATIONS.md](OPERATIONS.md) |
| logrotate | `/var/log/claude-code` grows unbounded | [OPERATIONS.md](OPERATIONS.md) |
| `profile.d` drop-ins | OAuth login can fail silently against a terminal browser | [RUNBOOK.md](RUNBOOK.md) |
| admin session launcher | no sanctioned route for privileged agent work | [ADMIN-SESSION.md](ADMIN-SESSION.md) |
| the `TasksMax` slice drop-in | nothing stops a fork bomb from wedging the host (that is the only resource limit this deployment ships — it caps the offending user's own task count and touches nothing else) | [OPERATIONS.md](OPERATIONS.md) |
| IDE wrapper | VSCodium runs the extension's bundled CLI version | [IDE-INTEGRATION.md](IDE-INTEGRATION.md) |

`make install` (= `bin/cc-install.sh --apply`) adds all of it, and is the
intended end state once a host is more than an experiment.

Two of these bite harder than the rest. **logrotate** bites first — weeks, on
a busy host. The **health-check timer** bites worst: §3 showed that a removed
policy or a dead hook produces no signal at all, and the timer is what turns
that silence into an alert. Close those two before the number of hosts outgrows what
you can check by hand.
