# Operations manual — build, upgrade, run, recover

| | |
| --- | --- |
| Document type | Operational procedures |
| Scope | Building a Claude Code host, moving versions, running it day to day, recovering from failure, decommissioning |
| Derived from | The scripts, units and policy in this repository: each procedure names the script it drives, and that script's header holds its exit-code table |
| Verified against | The pinned build — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`; [`UPGRADES.md`](UPGRADES.md) records each move and what was re-verified |
| Applies to | Rocky 8 hosts on cgroup v1 (Parts 1 and 3–7). Rocky 9, cgroup v2 and the AWS per-user VDI build (Part 2) are **designed, not validated**. Which hosts each part has been executed on is state, and its home is `internal/CURRENT-STATE.md` |
| Owner | The maintainer |
| Companion documents | `RUNBOOK.md` (why), `SETTINGS-REFERENCE.md` (the policy), `LOCAL-VS-AWS.md` (site differences), `internal/CURRENT-STATE.md` (what is true of each host) |

**How this document relates to the runbook.** The runbook holds the *decisions* and the reference
material — why the install model is a package per host, why auto mode stays on, why the sandbox
fails open. This document holds the *procedures*: the ordered steps, with the pass
condition for each. Where the two disagree, the runbook is the intent and
this is the practice.

**Two standing warnings before any procedure in this document.**

> **Run every root-level step from a real terminal — RDP or SSH — never from inside a Claude Code
> session.** Inside a session every command is sandbox-wrapped and root is remapped to an
> unprivileged UID, so `sudo` correctly refuses with an ownership error on `/etc/sudo.conf`. That
> is the sandbox working, not damage; the host's `sudo` is undamaged.

> **Never hand-edit a file that the installer owns.** `cc-install.sh --apply` redeploys every
> operator script and the policy from its bundle, so an edit made directly in `/usr/local/sbin` or
> `/etc/claude-code` survives exactly until the next apply, and nothing reports that it was
> reverted. Change the bundle copy.

---

# Part 1 — Build a host

The order below is not arbitrary. Steps 1 and 2 must precede everything, because until the search
path is resolved every subsequent verification interrogates the wrong binary and returns a
plausible, wrong answer.

## 1.0 Decide the host class first

Four attributes change what you install. Establish them before you start, and record them in the
change.

```bash
cat /etc/rocky-release                      # OS major version -> expected cgroup generation
stat -fc %T /sys/fs/cgroup                  # tmpfs = cgroup v1 ; cgroup2fs = cgroup v2
nproc; free -g; swapon --show                # sizing for the slice
getent passwd $(id -u) | cut -d: -f7         # login shell -> do you need the .csh drop-ins?
```

| Attribute | Consequence |
| --- | --- |
| OS major version | Rocky 8 → cgroup v1; Rocky 9 → cgroup v2. Do not guess from the OS alone: read `/sys/fs/cgroup`, because a Rocky 8 host can be switched to v2. The shipped slice drop-in (`systemd/user-.slice.d/50-claude-code.conf`, `TasksMax` only) is valid on both generations. |
| cgroup generation | v2-only directives are **silently ignored** on v1. A file carrying them enforces nothing and reports no error — read the effective values back from the kernel afterwards (§1.9). |
| Tenancy | Shared host → per-user limits arbitrate between engineers (`TasksMax` only). Per-user VDI → the engineer should be able to use the whole instance — still `TasksMax` only (§2.3). |
| Login shell | If it is `tcsh` or `csh`, every `/etc/profile.d` drop-in needs its `.csh` sibling: `/etc/profile.d/*.sh` is sourced only by sh-family shells, so the `.sh` file alone reaches nobody. The repository ships both variants of each drop-in. |

The resource-limit reasoning — why `TasksMax` is the only directive — is `RUNBOOK.md`
§11.5–§11.5b; the drop-in's own header comment is the ground truth.

## 1.1 Resolve the search path — sweep private installs *(do this first)*

Any per-user install under `~/.local/bin/claude` shadows the managed binary on that user's `PATH`.
Where home directories are on shared network storage, one private copy is present on **every** host
that user logs into, and one removal clears every host.

```bash
# survey, do not delete yet
for h in $CC_HOME_ROOT/*; do
  [ -e "$h/.local/bin/claude" ] && printf '%-28s %s\n' "$(basename "$h")" \
    "$("$h/.local/bin/claude" --version 2>/dev/null || echo unreadable)"
done
# also catch install trees with no launcher on PATH
ls -d $CC_HOME_ROOT/*/.local/share/claude 2>/dev/null
```

Then, per user, with their agreement:

```bash
rm -f  $CC_HOME_ROOT/<user>/.local/bin/claude
rm -rf $CC_HOME_ROOT/<user>/.local/share/claude $CC_HOME_ROOT/<user>/.cache/claude* \
       $CC_HOME_ROOT/<user>/.local/state/claude
```

**To preserve one deliberately** — useful during a pilot, to compare managed against private
behaviour — rename the launcher rather than deleting the tree, so it stays usable but stops
winning `PATH`:

```bash
ln -sfn $CC_HOME_ROOT/<user>/.local/share/claude/versions/<ver> \
        $CC_HOME_ROOT/<user>/.local/bin/claude-local
rm -f   $CC_HOME_ROOT/<user>/.local/bin/claude          # the bare symlink only
```

**Pass condition:** `command -v claude` returns nothing, or `/usr/bin/claude` once installed —
never a path under a home directory.

> **Coordinate before you sweep.** A private install is someone's working tool and may have a live
> session attached. This is a conversation, not a cleanup. It also intersects the version floor —
> see §3.4.

## 1.2 Site configuration, then preflight

If this checkout has no `config.sh` yet, create it first — `make config` copies the template, then
edit the site values if any differ (install paths, admin group, support contact; `QUICKSTART.md` §9
is the reference). `cc-install.sh` refuses to run without one rather than build a host on unstated
paths.

```bash
. lib/cc-config.sh                 # from the checkout: puts config.sh's values in this shell
sudo bash bin/cc-preflight.sh ; echo "exit=$?"     # from the checkout: nothing is installed yet
```

Every command block in this manual uses the config keys (`$CC_SBIN`, `$CC_ETC` and so on) rather
than their values, so keep this shell, or load the config again in a new one —
`. /etc/claude-code/cc-config.sh` once the host is installed. `QUICKSTART.md` §9 lists every key
with the template's value for reference. A path spelled out in prose or sample output is that
reference value, not something to type.

**Pass condition:** exit 0, no `FAIL` lines. Warnings are acceptable and expected on a fresh host:
`socat not installed` and `/etc/claude-code does not exist yet` are both resolved by later steps.

## 1.3 Repository, and verify the signing key out of band

This section and §1.4 are the ordered build steps. The pin **specification** — the repo-file
manifest, the raw command sequence, the `make pin` wrapper, and the Method A/B tradeoff — is
`QUICKSTART.md` §4–§6; where the two ever disagree, that is the spec.

```bash
sudo tee /etc/yum.repos.d/$CC_PKG_REPO_ID.repo <<EOF
[$CC_PKG_REPO_ID]
name=Claude Code
baseurl=$CC_RPM_BASEURL
enabled=1
gpgcheck=1
gpgkey=$CC_RPM_GPGKEY
EOF
```

On first install `dnf` prompts you to confirm the key fingerprint. **Confirm it against a source
other than the prompt** before accepting:

```
31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
```

`gpg --show-keys` prints the same fingerprint unspaced. A failed key download surfaces later as
`NO_PUBKEY BAA929FF1A7ECACE`. The key's user id reads `Anthropic Claude Code Release Signing`.

## 1.4 Install, pin, and create the policy directory

```bash
sudo dnf install $CC_PKG
sudo dnf install python3-dnf-plugin-versionlock
sudo dnf versionlock add $CC_PKG

sudo mkdir -p $CC_ETC                      # the RPM does NOT create this
claude --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | \
  sudo tee $CC_ETC/approved-version        # the BARE version string —
                                                    # the digits only, never "x.y.z (Claude Code)"
```

**What the package contains:** two files, `/usr/bin/claude` (root:root 0755) and
`/usr/share/doc/claude-code/copyright`. No scriptlets. Only dependency `glibc >= 2.17`. Read it
back with `rpm -ql claude-code` and `rpm -q --scripts claude-code` (§3.3). It does **not** create
`/etc/claude-code`, which is why the `mkdir` above precedes the `tee` — without it the `tee` fails.

**Pass conditions:** `rpm -q claude-code` names the intended version; `dnf versionlock list`
contains `claude-code`; `rpm -qf $(readlink -f "$(command -v claude)")` names the package.

> Note the `readlink -f`. On Rocky `/bin` is a symlink to `/usr/bin`, so `command -v` can answer
> `/bin/claude`, and `rpm -qf` on the unresolved path reports the file as unowned — a false drift
> finding.

## 1.5 Sandbox dependencies — check the provider on this host

> **The shipped policy disables the sandbox** (`SANDBOX-DECISION.md`). This section applies to a
> host whose policy re-enables it; the build installs `bubblewrap` and `socat` either way. Two things to know
> before you use it: Claude Code isolates commands with its own `apply-seccomp`
> helper, **not** bubblewrap, so a passing `bwrap` check tells you nothing about whether the sandbox
> works; and the only check that does is a **fresh session running `echo hi`**.

```bash
dnf provides bubblewrap socat        # resolve WHERE each comes from, on this host
sudo dnf install bubblewrap socat
# 0 is REQUIRED when the sandbox is disabled (it stops a no-sudo user
# bind-mounting their own policy over managed-settings.json); non-zero is
# required only if the sandbox is enabled. LOCAL-VS-AWS.md 8.2
sysctl user.max_user_namespaces      # non-zero ONLY if sandbox.enabled is true
```

**On Rocky 8, `socat` is in `appstream`; EPEL is not required.** `dnf provides` above is the
check, and it is run per host because the provider can differ between releases. Do not add a
third-party repository to a governed host to obtain a package the
base distribution already ships.

**What each does**, because it drives the fail-open decision: **bubblewrap** performs filesystem
and process isolation; **socat** is the network relay that lets the sandbox proxy enforce the
domain allowlist. Filesystem isolation works without socat; network enforcement does not.

### 1.5b Pushing a policy change — announce it first

**A managed-policy rewrite breaks every session already running on the host.** Sessions executing
normally begin failing every Bash call as soon as `managed-settings.json` is replaced underneath
them, and recover only on restart — including a session whose policy sets `sandbox.enabled: false`.
Probe **M2** (`bin/cc-bump-audit.sh`) re-asks at every version bump whether this still holds.

The failure is silent and looks to the user like Claude is broken. So:

1. Announce the push, with a time, to everyone who might have a session open.
2. Apply the policy and re-record the checksum baseline.
3. Tell users to **exit and restart their session**. `--resume <id>` picks the conversation back up.
4. Verify yourself in a **fresh** terminal: `echo hi` must return, and a denied command must be
   refused.

Do not push a policy change and walk away. Treat it as a change with user-visible impact, not a
silent config update.

## 1.6 Resolve `HOME` to a real path *(required while the directory publishes a symlink)*

A directory service can publish a user's home as a path that is a **symlink** to the real one — a
`/home/<user>` entry pointing at the mount the home lives on. `bubblewrap` cannot create a mount
point through a symlinked parent, so with the sandbox enabled every sandboxed command fails with
`bwrap: Can't mkdir /home/<user>/.ssh`. Ask the host: a login shell where `readlink -f "$HOME"`
prints something other than `$HOME` is affected.

With the sandbox disabled by the shipped policy (`SANDBOX-DECISION.md`) this step is **not a build
blocker**. Install it anyway: it is harmless, and it stops the failure returning if the sandbox is
ever re-enabled.

**Install the shipped files — do not retype them.** Both variants are required: `/etc/profile.d/*.sh`
is sourced only by sh-family shells, so where the login shell is `tcsh` the `.sh` file alone
reaches nobody.

```bash
cd "$CC_REPO"
sudo install -o root -g root -m 0644 \
     profile.d/claude-code-home.sh profile.d/claude-code-home.csh $CC_PROFILED/
```

The shipped versions guard the result of `readlink -f` before assigning — an unguarded assignment
would unset `HOME` if the symlink target ever went missing, which turns a broken sandbox into a
broken login. Read them before editing; each carries its own reasoning in a header comment.

**Pass condition:** in a fresh login shell, `echo $HOME` and `readlink -f "$HOME"` print the same
path. (With the sandbox re-enabled, the confirming test is that a sandboxed command succeeds.)

> **This is a workaround with a defined end.** The permanent fix is in the directory service: set
> the attribute that supplies the POSIX home directory to the real path. Delete both drop-ins once
> that lands, and do it **before** an image build (Part 2) so the symlink does not travel into the
> image. Whether the fix has been requested or made at a site is state: `internal/CURRENT-STATE.md`.

## 1.7 Browser path for OAuth login *(interactive desktop hosts)*

Engineers should never see a paste-the-code login. Set `BROWSER` at host level so a misconfigured
per-user desktop default cannot break it:

```bash
cd "$CC_REPO"
sudo install -o root -g root -m 0644 \
     profile.d/claude-code-browser.sh profile.d/claude-code-browser.csh $CC_PROFILED/
```

**Do not assume which browser a host ships** — hosts differ, and a host can ship Chromium and no
Chrome. That is why the drop-ins **detect** rather than hardcode: they walk a
candidate list and export the first one that exists, leaving `BROWSER` unset if none does, so
`xdg-open` still gets its chance instead of being pointed at a missing binary (which fails OAuth
silently, with nothing logged). Ask the host what it resolved to rather than reading the file:

```bash
sh -c '. "$1/claude-code-browser.sh"; echo "BROWSER=$BROWSER"' _ "$CC_PROFILED"
```

Empty output means no candidate exists on this host and browser login will fail — install one, or
add it to the candidate list in **both** drop-ins (the `.sh` and the `.csh`, which must agree;
health check `[2c]` compares them).

Setting `BROWSER` short-circuits `xdg-open` entirely. Without it, `xdg-open` on an Xfce desktop
resolves through `xfce4-web-browser.desktop` → `exo-open` → the `WebBrowser=` entry in
`~/.config/xfce4/helpers.rc`; if that entry names `links`, OAuth fails **silently** — a text-mode
browser launches with no TTY, exits immediately, no window appears, and `xdg-open` still returns
0. Correct existing homes in one pass if needed:

```bash
for h in $CC_HOME_ROOT/*; do
  sed -i 's/^WebBrowser=.*/WebBrowser=google-chrome/' \
    "$h/.config/xfce4/helpers.rc" 2>/dev/null
done
```

**Pass condition:** a test engineer runs `claude`, the browser opens in their session, sign-in
completes, and no code changes hands.

## 1.8 Deploy the policy

```bash
cd "$CC_REPO"
sudo bash bin/cc-install.sh --check    # expect 0 errors
sudo bash bin/cc-install.sh --apply
```

`--apply` is idempotent and does all of: create `/etc/claude-code`, place the policy root:root
0644, record the sha256 baseline, install the operator scripts to `/usr/local/sbin`, install the
systemd units and logrotate config, seed `/etc/skel`, and enable the three timers (health check, version watch, report). Prefer it
over placing files by hand.

It **refuses** to apply while the policy contains placeholder markers or while an `autoMode` array
is missing `"$defaults"`. Both refusals are safety features. See `SETTINGS-REFERENCE.md` §2 for the
change procedure and §4.1 for why `forceLoginOrgUUID` is deliberately absent rather than
templated.

**Pass condition:** `APPLIED, 0 error(s)`, and `no unreplaced placeholders`.

## 1.9 Verify the hook placements, and smoke-test the guards

`cc-install.sh --apply` places the hooks, the `1733` log directories, the slice drop-in, the
status line, the IDE wrapper and both `profile.d` variants of each drop-in — so a host build
cannot omit them and a re-`--apply` cannot revert them (`make quickstart` places the governance
subset on its own). What no installer can do for you is prove the guard behaves before an
engineer hits it; that is this section.

Confirm the placements the installer made:

```bash
make verify        # from the repo root — read-only; exit 0 is the pass condition
```

**Smoke-test the secret guard before trusting it.** A false positive here blocks real work:

```bash
for t in '{"tool_name":"Read","tool_input":{"file_path":"/scratch/x/.env"}}:2' \
         '{"tool_name":"Read","tool_input":{"file_path":"/scratch/x/main.py"}}:0' \
         '{"tool_name":"Read","tool_input":{"file_path":"/h/.ssh/id_rsa.pub"}}:0' \
         '{"tool_name":"Read","tool_input":{"file_path":"/x/.env.example"}}:0'; do
  json=${t%:*}; want=${t##*:}
  echo "$json" | $CC_SBIN/cc-secret-guard-hook.sh >/dev/null 2>&1
  echo "got=$? want=$want"
done
echo 'not json' | $CC_SBIN/cc-secret-guard-hook.sh; echo "malformed exit=$? (want 0)"
printf ''       | $CC_SBIN/cc-secret-guard-hook.sh; echo "empty     exit=$? (want 0)"
```

**Pass condition:** all six cases as expected — four from the loop, plus malformed and empty. If
any "want 0" case returns 2, **do not wire it in**: a false positive here blocks real work on every
host at once, which is why this is a build gate and not an afterthought.

The full case set lives in the test suite (`tests/test-cc-scripts.sh`, the **S** cases), which
covers what this block cannot: allowlist-beats-pattern ordering, a `.pem` at depth, a non-object
`tool_input`, and the canary that a block message never echoes file content. Run it on any change
to the pattern list. This block stays because it exercises the **installed** copy at
`/usr/local/sbin`, which is a different question from whether the repository copy is correct.

**Smoke-test the upgrade guard the same way** — it carries the same false-positive risk:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"claude update"}}' \
  | $CC_SBIN/cc-upgrade-guard-hook.sh; echo "upgrade  exit=$? (want 2)"
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"claude update guard\""}}' \
  | $CC_SBIN/cc-upgrade-guard-hook.sh; echo "mention  exit=$? (want 0)"
echo '{"tool_name":"Bash","tool_input":{"command":"sudo dnf check-update claude-code"}}' \
  | $CC_SBIN/cc-upgrade-guard-hook.sh; echo "query    exit=$? (want 0)"
```

**Pass condition:** exactly `2`, `0`, `0` — it blocks the action, ignores the vocabulary, and lets
a **query** through. That third case is not decoration: §3.2 step 2 asks the repository what
versions exist, so a guard that blocks `check-update` blocks the procedure it signposts. The full
case set lives in the test suite (`tests/test-cc-scripts.sh`, the G cases).

**Verify the slice actually took effect** — read it back from the kernel, do not trust the file:

```bash
systemctl show user-$(id -u).slice \
  -p CPUQuotaPerSecUSec -p TasksMax -p MemoryLimit -p MemoryMax -p MemoryHigh
```

**Pass condition:** `TasksMax=12288` and `CPUQuotaPerSecUSec=infinity`. The drop-in deliberately
sets **no memory or CPU limit** — `TasksMax` is its only directive (`MemoryLimit=infinity` is the
correct reading). `MemoryHigh` on a v1 host will read as unset regardless of any file, because it
is a v2-only directive that systemd accepts and ignores. See `RUNBOOK.md` §11.5–§11.5b for the
reasoning. The general form of the trap: a setting the platform accepts and ignores looks applied
in the file, so only the value read back from the kernel is evidence.

## 1.10 Acceptance — prove the policy applied and the controls hold

A policy nobody has tested is a policy you do not have. Every check below has an observable pass
condition.

| # | Check | Command | Pass condition |
| --- | --- | --- | --- |
| 1 | Policy accepted, nothing stripped | `sudo claude doctor` | No validation errors. It says nothing about permission rules either way: whether the filename-glob rules enforce is asked with `/doctor` inside a session (probe M10) — see `SETTINGS-REFERENCE.md` §2.1 and §3.2 |
| 2 | Classifier config landed | `sudo claude auto-mode config` | Your `environment` and `hard_deny` entries appear **with `$defaults` expanded in place**, not replacing the built-ins |
| 3 | Classifier review | `sudo claude auto-mode critique` | Nothing flagged as ambiguous or likely to cause false positives |
| 4 | Rules attributed correctly | in a session: `/permissions` | Rules attributed to `/etc/claude-code/managed-settings.json` |
| 5 | A denied command is refused | in a session, ask for `sudo id` | Blocked |
| 6 | User settings cannot add rules | test user adds an `allow` rule to `~/.claude/settings.json` | `/permissions` does not show it |
| 7 | Activity hook records | run any Bash command | One line in `/var/log/claude-code/activity/<user>.jsonl` |
| 8 | Activity hook does **not** record content | write a file containing a distinctive string, then grep the activity log for it | **It must not appear.** This is the canary test that keeps the log an audit trail rather than employee monitoring |
| 9 | Denial log records | in an **interactive** session, ask for `sudo id`, then check `/var/log/claude-code/denied/<user>.jsonl` | A line appears. A classifier refusal and a **rule** refusal reach the hook by different paths; this row tests the rule path. Test interactively: headless `claude -p` sessions may not fire the hook (§4.2) |
| 10 | Secret guard fires in a real session | ask Claude to read a `.env` file | Blocked, quoting the IT policy message |
| 11 | Sandbox starts | in a session: `/sandbox` | **N/A while the policy disables the sandbox** (`SANDBOX-DECISION.md` §4 holds the re-enable conditions). On a host whose policy re-enables it: no Dependencies tab |
| 12 | A non-allowlisted host is blocked | sandboxed command to an unlisted domain | **N/A while the sandbox is disabled.** With it re-enabled: denied, not prompted |
| 13 | An `ask` rule survives auto mode | in an auto-mode session, `git push` | Still prompts |
| 14 | SELinux is not interfering | `getenforce`; `id -Z`; `sudo ausearch -m avc -ts recent` | `Enforcing`; `unconfined_t`; no denials naming `bwrap`. Record the output |
| 15 | Status line renders | open an interactive session | The status line appears at the bottom |
| 16 | Health check runs and can fail | `sudo /usr/local/sbin/cc-healthcheck.sh; echo exit=$?` | It reports the **real** account count, and exits non-zero when there are findings. See §4.1 |
| 17 | **Every** timer is enabled, not just placed | `systemctl list-unit-files 'claude-code-*'` then `systemctl list-timers 'claude-code-*' --all` | Every unit the apply placed is named, **each timer reads `enabled`**, and each has a next elapse. A timer placed but `disabled` fires nothing and shows in neither `list-timers` nor `systemctl --failed` — the check it drives is then silently absent while the files on disk look right. Weekly units enabled mid-week correctly show a future first elapse and no artefact yet |
| 18 | Baseline audit filed | `sudo /usr/local/sbin/cc-audit.sh` | Output attached to the deployment change |

## 1.11 Capture the evidence

Before the first change and after the last, capture state to numbered files in one directory. They
are the difference between asserting that the build did not disturb work already running on the
host and demonstrating it.

At minimum: pre-state (`rpm -q`, `command -v claude`, `ls /etc/claude-code`, slice state, disk,
per-user installs), the GPG fingerprint comparison, the package file list, `cc-install.sh` output,
`claude doctor`, `claude auto-mode config`, the canary test, the health-check run, and final state.

## 1.12 Rolling out to the rest of the fleet

A fleet is governed only when every host in it is. Where hosts share home or project storage, a
per-host control is guarding a fleet-wide asset: an unpoliced peer runs an ungoverned,
self-updating copy of the tool against the same data, with no audit trail. Which hosts are
built is state, and the coverage register is `internal/CURRENT-STATE.md`.

**Per host, in this order:**

1. **Establish the host class before assuming anything** (§1.0). A fleet can mix OS major versions,
   so the cgroup generation and the sizing can differ per host. A platform fact verified on one
   host has a sample size of one until a second host is built.
2. Run §1.1 through §1.11 in order. Where homes are shared across hosts, the private-install sweep
   is per *user*, not per host, and one sweep clears every host — so it does not need repeating
   once done.
3. Run the §1.10 acceptance checks on **each** host. A checklist passed on one host is not a fleet gate.
4. Confirm the health-check timer is enabled and that its output reaches the alert route (§4.1).
5. Update the coverage register as each host is completed, so coverage is a fact rather than a
   recollection.

**Sequence it deliberately:** bring one host up, complete it, and only then start the next.
Several half-built hosts is a worse position than one finished host and the rest untouched, because
the untouched ones are at least honestly described.

**A rollout plan needs a name and a date against it.** Record both in the state register.

---

# Part 2 — Build the AWS per-user VDI

Same install model, different vehicle: one VDI instance per engineer instead of a shared host.
`LOCAL-VS-AWS.md` records every difference and the transition checklist. This part is the build
sequence.

> ### ⚠ This part is design, not validation — read this before following it
>
> Nothing in this repository's CI or test suite runs on Rocky 9, on cgroup v2, on a single-user
> host, on local (non-network) home directories, or on an AMI: the suite runs in a Rocky 8
> container. The platform facts Part 1 states — socat's provider, bubblewrap availability, the
> SELinux interaction, the OAuth loopback path, the nested-sandbox failure — are Rocky 8 facts.
>
> So this part is a reasoned extrapolation, and it should be read that way. A first build on a new
> platform finds problems that no amount of document review surfaces. **Treat the first VDI as a
> pilot with written exit criteria (§2.6), not as the first of many.**

## 2.0 Decisions that must be made before this procedure is executable

Four choices belong to the site, and no document can make them by being written. Each changes the
procedure below.

| Decision | Options | Consequence |
| --- | --- | --- |
| **Base image** | Rocky 9 from the Marketplace, the community cloud image, or a self-built base | Provenance and patch baseline. Rocky 9 is required either way, to get cgroup v2 from the start |
| **Bake vehicle** | Packer, EC2 Image Builder, or a snapshot of a hand-built instance | Determines the repository layout and whether the build is reproducible. A snapshot of a hand-built instance is the option that looks quickest and is the one that produces an image nobody can rebuild |
| **Which git remote is authoritative** | Any git remote | A deploy is `git pull` then `cc-install.sh --apply` from a checkout (`README.md`). This row decides the remote the AMI build pipeline treats as authoritative, with backup and review |
| **Instance and volume spec** | — | A per-engineer VDI is sized for one engineer, not as a shared host is. This is a cost question IT does not own alone |

Also settle, because they are security-relevant and easy to inherit by accident: whether the
instance carries an **IAM instance role** (and if so, that `Bash(aws *)` is denied by policy, so an
agent cannot use it — but a subprocess could), whether **IMDS** is restricted to v2 with a hop limit
of 1, and whether **home directories persist** across an instance replacement.

## 2.1 Do these before the first AMI is baked

Each prerequisite is cheaper to fix now than to inherit into every instance. The checklist —
everything that must land before AWS rollout, and why — is `LOCAL-VS-AWS.md` §6. Three of its
items change this document's own procedures and are worth naming here:

- **Fix the home-directory attribute in the directory service first** (§1.6) — otherwise every
  instance inherits the symlink and the `profile.d` workaround travels with it, permanently.
- **If TLS is inspected on the VDI subnet, the proxy keys go in the policy `env` block, not
  `/etc/profile`** — background sessions may inherit no shell environment.
- **Do not carry a shared-export posture into the image.** If home directories sit on a network
  export that other hosts can mount with client-asserted identity (NFS `sec=sys`), credentials
  stored there are readable from those hosts and file modes are no boundary. Check the export's
  security flavour and its client list before building on it; a site's finding goes in
  `internal/LIMITATIONS-AND-RISKS.md`.

## 2.2 What goes in the image versus what happens at first boot

| Layer | Contents |
| --- | --- |
| **In the AMI** | The `claude-code` RPM at the approved version; `dnf versionlock`; `/etc/claude-code/managed-settings.json` and its checksum baseline; `/etc/claude-code/approved-version`; `bubblewrap` and `socat`; the operator scripts in `/usr/local/sbin`; the managed hooks; `/var/log/claude-code/{activity,denied}` at 1733; the systemd units, the timer and the logrotate config; the slice drop-in; `/usr/local/share/claude-code/statusline.sh` and `ENGINEER-GUIDE.md`; the `BROWSER` drop-ins in both shell variants |
| **First boot / instance-specific** | Hostname and directory join; log-shipping agent configuration; anything that must differ per instance |
| **Per user, once** | The engineer runs `claude` and completes browser OAuth. No IT action |
| **Never in the image** | Credentials of any kind. Each engineer logs in as themselves |

Build the image by running Part 1 on a clean instance, then validating with Part 1 §1.10 before
capturing. **Bake the validation, not just the install** — an AMI that has never passed §1.10 is
an AMI that will fail it on every instance at once.

## 2.3 What changes for a single-user instance

| Setting | Shared on-prem | Per-user VDI |
| --- | --- | --- |
| Memory limit on the user slice | Absent — deliberate (`RUNBOOK.md` §11.5) | **Omit.** The engineer should be able to use the instance they are paying for |
| `CPUQuota` | Absent — removed as the wrong instrument (`RUNBOOK.md` §11.5b) | **Omit** |
| `TasksMax` | Set | **Keep** — a fork-bomb backstop that costs nothing |
| `sandbox.failIfUnavailable` | `false`; a dependency problem must not become a team outage | **Becomes affordable as `true`** once nesting is resolved, because the blast radius is one engineer. This is the deferred hardening finally becoming reachable |
| `/var/log/claude-code` | Host-local, few hosts to collect from | **Ship off-host — required** |
| Update path | `cc-update.sh` per host, or rebuild | **Rebuild from the AMI.** Hand-installing per VDI does not scale |

A minimal `TasksMax`-only drop-in is the correct slice file for a VDI — which is the shape the
shipped file already has; re-check only the `TasksMax` sizing against the instance class. The
reasoning is `RUNBOOK.md` §11.5–§11.5b.

## 2.4 What gets easier, and what gets harder

Worth stating so the transition is not framed as pure cost: the shrinking blast radius is what
finally makes fail-closed hardening affordable, while the growing fleet size is what makes
anything hand-applied unsustainable. The full lists are `LOCAL-VS-AWS.md` §4 (easier) and §5
(harder).

## 2.5 Scrub before capture

An image captured from a working instance carries that instance's identity and secrets into every
copy. Run this before the snapshot, and verify it — a credential baked into every instance is not
recoverable by deleting it from every instance afterwards.

```bash
# Claude Code per-user state — no credential may be in the image
sudo rm -rf /root/.claude /root/.claude.json
for h in /home/* "${CC_HOME_ROOT:?load config first}"/*; do
  sudo rm -rf "$h/.claude" "$h/.claude.json" "$h/.cache/claude"* \
              "$h/.local/share/claude" "$h/.local/bin/claude"*
done

# audit logs from the build — the image must not ship someone else's evidence
sudo find "${CC_LOGDIR:?load config first}" -type f -delete

# host identity
sudo rm -f /etc/ssh/ssh_host_*
sudo truncate -s0 /etc/machine-id            # NOT rm: some tooling requires the file to exist
sudo rm -f /var/lib/dbus/machine-id

# general hygiene
sudo dnf clean all
sudo rm -rf /var/log/cloud-init*.log /var/lib/cloud/instances/*
sudo rm -f  /root/.bash_history /home/*/.bash_history
sudo rm -f  /etc/sysconfig/network-scripts/ifcfg-eth0   # if statically written during the build
```

**Verify the scrub, do not assume it.** The check that matters is that no credential or per-user
store exists anywhere in the image. Note the parentheses — without them the `-xdev` applies only to
the first `-name`, which is a classic `find` mistake — and note that home directories on a separate
mount need their own pass, because `-xdev` deliberately does not cross filesystems:

```bash
# every filesystem that will be captured, one at a time
for fs in / /home $CC_HOME_ROOT /var; do
  [ -d "$fs" ] && sudo find "$fs" -xdev \
      \( -name '.credentials.json' -o -name '.claude.json' -o -name '.claude' \) \
      -print 2>/dev/null
done
```

Expect **no output**. `.claude.json` (a dotfile in the home directory) is the one most often missed,
because it does not live under `.claude/`.

Keep in the image, deliberately: `/etc/claude-code/*` (the policy, its checksum and the approved
version), every installed file that is not per-user (the manifest is `QUICKSTART.md`), and the empty
`/var/log/claude-code/{activity,denied}` directories at mode 1733.

## 2.6 First-VDI pilot exit criteria

Do not bless the AMI on the strength of it booting. These are the observations that turn Part 2 from
design into validation: each names an assumption Part 1 makes that a new platform can break.

| # | Must be observed on one real instance | Why this one |
| --- | --- | --- |
| 1 | `cc-preflight.sh` exits 0 with no FAIL | The build's own gate |
| 2 | `stat -fc %T /sys/fs/cgroup` returns `cgroup2fs`, **and** `systemctl show` returns the expected slice values (§1.9) | v2 directives are silently ignored on v1; that the drop-in takes effect on v2 is to be read back from the kernel, not assumed |
| 3 | A sandboxed Bash command succeeds — with `HOME` a **real** path, and the `profile.d` workaround *removed* | Confirms the directory's home attribute (§1.6) is fixed and the workaround does not need to travel |
| 4 | Browser OAuth completes with no code paste | The `xdg-open`/`helpers.rc`/`links` failure mode (§1.7) is silent and desktop-stack-specific |
| 5 | `dnf provides socat bubblewrap` resolved on Rocky 9 before install | The provider of a package can differ between releases; do not inherit the Rocky 8 answer |
| 6 | `ausearch -m avc -ts recent` clean after real sessions, with `id -Z` recorded | bubblewrap under SELinux is benign only while users map to `unconfined_t` |
| 7 | Every managed hook fires; the canary test passes (file contents absent from the log) | The evidence layer is the audit story; prove it per platform |
| 8 | `claude doctor` warnings enumerated and each one explained, and `/doctor` run inside a session | The CLI form reports install and settings-schema problems only. A warning that glob patterns in permission rules are ignored on Linux appears in the in-session `/doctor`, and is expected on a build that does not enforce them. Any *other* warning on Rocky 9 is new information |
| 9 | Logs arrive at the central store | Mandatory in this model, and the only chance to find it broken cheaply |
| 10 | An instance replacement is performed, and the engineer's session history behaves as the home-storage decision predicted | This is the decision most likely to have been made on an assumption |
| 11 | `failIfUnavailable: true` tested deliberately, on the pilot instance only | The blast radius is one engineer here. This is where the deferred hardening gets tested rather than argued about |

Record the output (§1.11). The first VDI's evidence becomes the AMI's acceptance baseline.

## 2.7 Instance age becomes version drift — the trap long-lived hosts do not have

On long-lived on-prem hosts you *converge* a machine: re-run the config, and it is current. With
disposable instances the update path **is** replacement, and that changes the failure mode.

**An instance launched from an old image and never replaced is running that image's binary and
that image's policy indefinitely.** Nothing on it is wrong, nothing alerts, and `dnf versionlock` is working
exactly as intended — it is pinning the version it was told to pin. Left alone, the fleet silently
fans out across every AMI you have ever published, and "what version are we running?" stops having
a single answer.

This is not hypothetical bookkeeping. It interacts with three things already in this deployment:

| Interaction | Consequence |
| --- | --- |
| `requiredMinimumVersion` | See §3.5 — an old instance can be locked out by a policy change made elsewhere |
| The daily health check | It compares against that instance's *own* `approved-version` file, so an old instance reports healthy. The check cannot see that the image is stale |
| Security advisories | An advisory handled by rebaking reaches only instances launched afterwards. Anything long-lived needs `cc-update.sh` as well |

**What to put in place before the fleet is more than a handful of instances:**

- **A maximum instance age**, enforced rather than aspirational — 30 or 60 days is typical. Replacement
  is cheap in this model; that is the whole argument for it.
- **A way to see AMI ID per instance**, so "how many distinct images are live?" is a query and not an
  archaeology exercise. Tag instances with the AMI ID and the Claude Code version at launch.
- **A rule that an advisory triggers both** a rebake *and* an in-place `cc-update.sh` sweep of
  instances that will not be replaced within the window.
- **Add the AMI ID and the launch date to the coverage register** (`internal/CURRENT-STATE.md`).
  On a few named hosts, coverage is a list. On many instances it is a distribution, and the
  interesting number is the oldest one.

> **The general form, worth carrying to other work:** immutable infrastructure moves the drift problem
> rather than removing it. On mutable hosts, drift is *configuration* diverging from intent and you
> fix it by converging. On immutable instances, configuration cannot drift — but **instance age**
> does, and nothing on the instance can detect it. The control has to live outside the instance.

---

# Part 3 — Move versions

## 3.1 Which path

| Situation | Path |
| --- | --- |
| Routine monthly move, AMI-based fleet | **Rebuild the image.** Bump the version in the build, re-run Part 1 §1.10, re-bake, roll instances |
| Single host, or between image builds | `cc-update.sh` — the only sanctioned in-place path |
| Security advisory | `cc-update.sh` out of band, expedited change |

**Cadence.** Monthly on the stable channel, with an out-of-band path for advisories. Quarterly
leaves you far behind on security fixes; weekly spends more change-management effort than the
product warrants.

## 3.2 The in-place procedure

> **Every version move runs inside Part 7.** This section is the package-move core; Part 7 (§7.1)
> wraps it with the analysis before (`make bump-audit`, the agent lanes) and the record after (the
> `UPGRADES.md` entry, which CI check [9] holds against the policy pin). Do not run this section
> bare.

> **The first version move on a host needs a witness and a maintenance window.** `apply` and
> `rollback` change a package, so until one has run on a host there is no recorded real output to
> compare against. Record the first run's output so the second is routine.

> **Two additions at every version bump:**
>
> 1. **Re-test the sandbox.** In a **fresh** session with `sandbox.enabled: true`, run `echo hi`. If
>    it returns, the sandbox works on this host at this version and re-enabling becomes a live option under the
>    conditions in `SANDBOX-DECISION.md` §4. If it does not, keep the sandbox off and move on. Do not
>    infer this from `bwrap`, `unshare` or `claude doctor` — none of them exercise the failing path.
> 2. **Check whether the new version uses an external `apply-seccomp` helper.** Where
>    the binary embeds its own, an `@anthropic-ai/sandbox-runtime` package installed on the host is
>    not used. If a version starts to use it, it becomes a real dependency and needs pinning in
>    `cc-update.sh` and asserting in `cc-healthcheck.sh`.

> **Operator scripts are invoked by absolute path, always.** They install to `/usr/local/sbin`
> (`0750 root:root`), and the distribution's default for sudo's `secure_path` is
> `/sbin:/bin:/usr/sbin:/usr/bin` — **`/usr/local/sbin` is not on it**, so a bare `sudo cc-update.sh …` fails with "command not
> found" while the script sits there perfectly installed. Spell the path. Do not "fix" this by
> editing `secure_path`: widening the search path sudo uses is a larger change than typing 18
> characters, and the deployed copy is what a host is meant to run (`CLAUDE.md`) — running the
> checkout's `bin/…` copy instead is a different thing, and it is only correct for `cc-install.sh`,
> which has to read the repository anyway.

```bash
sudo $CC_SBIN/cc-update.sh sessions                   # 0. WHO would block the apply
sudo $CC_SBIN/cc-audit.sh > /tmp/audit-before.txt     # 1. baseline, BEFORE anything
sudo $CC_SBIN/cc-update.sh check                      # 2. what is available; changes nothing
sudo $CC_SBIN/cc-update.sh stage <target>             # 3. download + verify signature, do not install
```

**Step 0 is first for a reason.** `apply` refuses while anything is running the managed binary,
and the session that blocks you is the one you cannot see: a `claude-admin` session is a `runuser`
child, so it appears in no list of terminal tabs, and an operator who has genuinely closed
everything still gets refused. `sessions` names each blocker by pid, user, tty, elapsed time and
kind, and it is read-only, so run it early and again at the top of the window. Two asymmetries it
encodes: a **private install** such as `claude-local` is a different binary and never blocks — the
question is which processes have *this file* as their executable, not which are named `claude` —
and an unprivileged run says whose processes it could see rather than reporting a clear host.
Probe **A8** asks the same question during the step-2 audit, so the answer arrives before the
window is booked rather than at its door.

4. **Analyse the target version** — §7.1 step 3 (the four agent lanes: vendor changelog with
   references, settings-surface diff, script review, docs re-anchor). What matters most: changes
   in settings keys, permission semantics and sandbox behaviour — those silently alter your
   policy without touching your policy file. The findings land in the `UPGRADES.md` entry.
5. Raise the change, attaching `audit-before.txt`.
6. In the maintenance window: `sudo /usr/local/sbin/cc-update.sh apply <target>`. The script drops the versionlock,
   installs, re-locks, smoke-tests with `claude --version`, and only then records the approved
   version; `claude doctor` runs last and only warns. A failed re-lock exits 1, because an unlocked
   package moves with the next routine `dnf upgrade`. **It refuses, before changing anything, while
   a `claude` process is live** — essential on a shared host, where replacing the binary under a
   live session produces confusing failures — and for a target below the installed version (that
   is `rollback`) or below the deployed policy floor.
7. `sudo /usr/local/sbin/cc-audit.sh > /tmp/audit-after.txt` and **diff the two**. A new version can introduce a
   key the policy does not set, or change the meaning of one it does.
8. Re-run the acceptance checks in Part 1 §1.10. At minimum items 1, 2, 5, 7, 8 — plus 11–12 if
   the sandbox has been re-enabled on the host.
9. If anything is wrong: `sudo /usr/local/sbin/cc-update.sh rollback <previous>`.

> ### ⚠ Rolling back below `requiredMinimumVersion` locks every user out of the host
>
> The version floor is enforced against the binary that is actually installed. **A rollback to a
> version below the floor makes Claude Code refuse to start for everyone — including whoever is
> performing the rollback.** No amount of care during the rollback reveals it, because the failure
> appears at the *next* session start.
>
> **`cc-update.sh rollback` refuses this** — it reads `requiredMinimumVersion` out of the
> deployed policy, compares it to the target, and exits 1 with the working order printed, before it
> touches the package. `--force` is the deliberate override for an operator who has already lowered
> the floor or accepts the consequence; it logs the warning rather than proceeding quietly. The
> suite's rollback cases hold that behaviour (a policy whose floor cannot be read is refused too), along with the three other rollback failure modes: a failed
> transaction must leave the package **locked** at the version still installed, a rollback that
> leaves a dead binary must exit non-zero, and live sessions are reported but do **not** block —
> a rollback is an emergency, unlike `apply`, which refuses outright.
>
> The floor normally equals the deployed version, which means **any rollback at all locks the host
> out** until the policy is changed. Probe A4 reports the three numbers that must agree — binary,
> `approved-version`, floor.
>
> **Therefore: lower the floor first, roll back second.**
>
> ```bash
> # 1. In the policy, set requiredMinimumVersion to the ROLLBACK target (or lower)
> #    settings/managed-settings.json  ->  "requiredMinimumVersion": "<target>"
> # 2. Apply, from a real terminal
> sudo bash bin/cc-install.sh --apply
> sudo claude doctor                       # confirm the new floor took effect
> # 3. NOW roll the binary back
> sudo /usr/local/sbin/cc-update.sh rollback <target>
> sudo claude --version                    # confirm, and confirm a session starts
> ```
>
> Raising the floor again afterwards is a separate change, and remember it also governs private
> per-user installs (§3.4).
>
> **If you are already locked out**, the policy is a root-owned file on a host you administer:
> edit `requiredMinimumVersion` in `/etc/claude-code/managed-settings.json` directly, re-record the
> checksum, and then re-apply properly from the bundle so the two do not diverge.
>
> ```bash
> sudo vi /etc/claude-code/managed-settings.json     # lower or remove requiredMinimumVersion
> sudo sh -c 'sha256sum /etc/claude-code/managed-settings.json \
>             > /etc/claude-code/managed-settings.json.sha256'
> ```

## 3.3 Traps specific to version moves

- **`cc-install.sh --apply` redeploys the operator scripts from the bundle.** If an operator script
  has been patched, the patch must be in the bundle or the apply reverts it. The health
  check checksums only the policy, not the scripts — so after an apply, compare a patched script
  with the bundle's copy by hand (`cmp` of the installed file against the one in `bin/`).
- **Invalid keys are stripped, not rejected.** A key that a new version has renamed will simply
  vanish from the effective policy, silently weakening it. This is why step 7's diff exists.
- **`requiredMinimumVersion` applies to every copy of the binary on the host**, including private
  per-user installs. Raising the floor stops those installs from starting.
- **The version floor is fail-open.** A malformed value is stripped rather than enforced, so a typo
  leaves you believing you have a floor you do not have. Validate after every edit.
- **A rollback below the floor locks the host out.** Lower the floor first — see the warning in §3.2.
- **Check what the new package actually contains.** The RPM installs two files with no
  scriptlets and does not create `/etc/claude-code`. If a future package starts owning that
  directory, an upgrade could overwrite or `.rpmsave` the policy. Run `rpm -ql claude-code` and
  `rpm -q --scripts claude-code` at the staging step, and look for `.rpmnew`/`.rpmsave` afterwards.
- **Re-read `internal/LIMITATIONS-AND-RISKS.md` at every bump.** It is where a site lists the
  undocumented product behaviours its design depends on. One would change *silently* if the vendor
  changed it: filename globs starting to work (the retained rules would then double up with the
  guard hook).

## 3.4 Coordinating the version floor with private installs

A private per-user install that sits **below** the deployed floor stops starting once the floor
is applied. **Do not carry a count in this section** — it changes with every floor move as well as
with every private upgrade. The live answer is probe **A5** (`bash bin/cc-bump-audit.sh`), which
recomputes it against the floor in the policy; the register is `internal/CURRENT-STATE.md`. The
policy sets no `requiredMaximumVersion`, so an install kept deliberately for comparison (§1.1) is
bounded only from below.

**A floor move re-opens this duty, and the set of affected people changes.** Run A5 against the
*target* floor (`--target-version`) before the bump, not after: someone comfortably above today's
floor can be below tomorrow's, and §1.5b's announce-first rule applies to them just as much as to
the people already below it.

That is arguably the migration pressure you want, but it is an unannounced change to someone
else's working tool. Either:

- **Tell them first**, and pair the message with how to use the managed binary, so it reads as a
  migration rather than a breakage; or
- **Lower the floor** to below the oldest private install until they have moved, then raise it.

## 3.5 The version floor and the image must move together

§3.4 is the same mechanism pointed at other people's tooling. **This section is the same mechanism
pointed at your own fleet**, and in the VDI model it is easy to trigger by accident.

The policy and the binary are both baked into the image, so within any one instance they are
consistent by construction. The danger is pushing a **policy** change out of band — by config
management, or by hand — to instances whose **binary** came from an older image:

> Raise `requiredMinimumVersion` on running instances, and **every instance still on an image
> carrying an older binary stops starting Claude Code entirely.** Not degraded: refused at startup,
> for every user on it. You have applied a kill switch to part of your own fleet, using the same
> mechanism that stops the private installs below the floor.

It fails in the direction that looks like success, too: `cc-install.sh --apply` reports the policy
applied and the checksum recorded, `claude doctor` on a *current* instance is clean, and the daily
health check on a stale instance compares against its own `approved-version` file and reports
healthy. Nothing tells you which instances you just broke — the affected engineers do.

**The rule:** the floor may never exceed the version in the **oldest live image**.

Two ways to hold it, and the first is much easier to keep true:

| Approach | How it works | Trade-off |
| --- | --- | --- |
| **Move them as one unit** — preferred | The floor only ever changes *inside* the image. Bump the version and the floor in the same bundle commit, rebake, roll. Never push a floor change to running instances | Requires the instance-replacement discipline of §2.7. If old instances linger, you are back to the second row |
| **Let the floor lag** | Keep the floor at or below the oldest live AMI's version, and raise it only after the last stale instance is retired | Needs you to actually know the oldest live version — which is the tagging in §2.7 |

**Before any floor change, in either model, answer this:** what is the lowest Claude Code version
running on any live instance? If that question cannot be answered from tags or an inventory query,
the floor should not move yet.

The same reasoning applies in reverse to `requiredMaximumVersion` if it is ever set — a ceiling below
a *newer* image's version breaks the newest instances instead of the oldest. Both keys are startup
gates, and both are absolute.

> **The general form:** a policy that gates on the version of the thing it ships alongside must
> travel with it, not separately. Splitting the two delivery channels turns a version constraint into
> an availability risk — and the check that would catch it lives on the instance that has already
> been broken.

---

# Part 4 — Run it

## 4.1 The daily health check, and how to read it

`cc-healthcheck.sh` runs from a systemd timer and **exits non-zero when it finds something**, so
the unit enters a failed state and `systemctl --failed` surfaces it with no extra monitoring glue.

> ### ⚠ A check that reports to nobody is not a control
>
> "No extra monitoring glue" holds only if something already alerts on `systemctl --failed` for this
> host. Without that, the check's output lands in `journalctl` on the host and nowhere else: no
> alert route, no ticket queue, no named reader. A daily control reporting to nobody is a log file
> that happens to contain the answer.
>
> Pick one route, assign a name, and test it once by making the check fail on purpose:
>
> - Alert on `systemctl --failed` if the monitoring platform already does this — confirm this host
>   is in scope rather than assuming.
> - Or add `OnFailure=` to `claude-code-healthcheck.service`, pointing at a unit that emails
>   the support contact (`CC_SUPPORT_CONTACT` in `config.sh`).
> - Or have the timer's output posted to the team channel, which is the least good option and still
>   better than nothing.
>
> **Test the failure path.** A check whose alerting branch has never fired is untested code in the
> most load-bearing position you have.

> **A non-zero exit is the check working.** On a host with real findings, `N item(s) need
> attention` / exit 1 is the accurate result — do not treat exit 1 as a broken check, and do not
> accept a `healthy` verdict without its denominator.

It reports the size of the population it examined (`Audited N account(s)`). **If that number does
not match the number of real home directories, the check is blind and its other findings are
worthless** — the denominator is printed so that a blind run cannot pass silently.

| Finding | What it means | Action |
| --- | --- | --- |
| Version differs from `approved-version` | Either versionlock was not applied, or a private install is winning `PATH` | §1.1, then §3.2 |
| Policy checksum mismatch | The deployed policy has been edited without re-recording the baseline | Establish who and why. Re-apply from the bundle; never re-record a checksum to make a finding disappear |
| `unmanaged native install on PATH at $HOME/.local/bin/claude` | A private install shadows the managed binary — your version gate is defeated for that user | §1.1 |
| `preserved alternate install` (note, not a flag) | A deliberately renamed install that does not win `PATH` | None. This is the expected state for an install renamed as in §1.1 |
| `ungoverned install tree … with no launcher on PATH` | An install tree with no launcher — dormant but outside change control, and it will self-update | Sweep it, or rename a launcher if it is deliberate |
| `<user>: .ssh is mode 755` / `.aws is mode 755` | A credential directory readable by other engineers on a shared host | `chmod 700`. Raise the provisioning defect |
| Home directory mode is not 0700 | Cross-user readability. Note that on an NFSv3 `sec=sys` export, modes are not a boundary against another host in any case | `chmod 700`; escalate the export posture separately |
| Stranded home — owner UID does not resolve | A leaver process did not complete | Account provisioning, with a verification step added |
| Credential file older than 80 days | A login is approaching expiry. A long-running background session that outlives its credential simply stops making progress | Tell the user to `/login` |
| Sandbox enabled but `bwrap` or `socat` missing | **Urgent.** With `failIfUnavailable: false`, sessions continue with **no sandbox enforcement** and only warn — the host is unprotected while appearing healthy | Reinstall the dependency the same day |
| `[8] Install drift`: differs | A placed file, setting or timer is not what the install record says was placed: edited on the host, or the checkout has moved on since the last apply. The report is at `$CC_LOGDIR/drift.json`, which the dashboard's Hosts page reads | `sudo cc-install.sh --check` says what an apply would change. Establish who changed a host-side file before re-applying over it |
| `[8] Install drift`: cannot tell | No install record, or a part of it cannot be read. The report says *unknown* with the reason, never *as installed* | Re-apply to write a record, or fix what the reason names |
| Disk above 85% on the home volume | Session transcripts and caches accumulating. The largest single consumer is typically `~/.cache/claude-cli-nodejs/`, not transcripts | Reduce `cleanupPeriodDays`, or grow the volume |

## 4.2 Recurring tasks

| Cadence | Task | Mechanism |
| --- | --- | --- |
| Daily | Health and drift check | Timer; non-zero exit marks the unit failed |
| Weekly | Read the health-check log for repeated warnings; check for security advisories | `sudo journalctl -u claude-code-healthcheck` — **needs root**: the journal is readable only by root and the `systemd-journal` group, so an ordinary user gets "No journal files were opened" rather than an empty week |
| Weekly | Confirm nothing above the pin has been published, and that the check itself ran | `sudo /usr/local/sbin/cc-version-watch.sh` (or read `/var/log/claude-code/version-watch.json`); `systemctl list-timers claude-code-version-watch.timer` — §7.4 |
| Monthly | Version review and controlled move | §3 |
| Monthly | Full policy audit for the record | `cc-audit.sh`, filed with the change record |
| Quarterly | Re-verify every policy key against the current settings reference; decide a position on **new** keys | `SETTINGS-REFERENCE.md` §5 |
| Quarterly | Review the deny and ask lists against what engineers actually needed | The denial log is the only source — the telemetry metric covers code-editing tools only and misses blocked Bash commands |
| Every push | CI on the remotes: `bin/cc-ci-check.sh` — every content check it carries, run as one script — via GitHub Actions and `.gitlab-ci.yml`. **A red `main` is a stop-the-line defect** — the same script runs by hand on any clone. Canonical description: the repository `README.md`, "CI" |

Summarise the denial log with the block below — **and run it under `sudo`.**

The denial and activity directories are `1733`: an ordinary user cannot *list*
them, only open their own file by exact path. So an unprivileged run of this
block makes `glob` return an empty list, prints nothing, and exits 0 — which is
indistinguishable from a quiet week. So the snippet refuses to be ambiguous: it
says how many files it actually read, and it says so even when the answer is one.

```bash
sudo python3 - "$CC_DENIED_LOG_DIR" <<'PY'
import json, glob, collections, os, sys
d = sys.argv[1]                    # CC_DENIED_LOG_DIR, from the loaded config
files = sorted(glob.glob(d + "/*.jsonl"))
if not files:                      # unlistable directory, or genuinely none
    me = f"{d}/{os.environ.get('SUDO_USER') or os.getlogin()}.jsonl"
    files = [me] if os.path.exists(me) else []
    print("NOTE: could not enumerate the directory - run this as root, or this is "
          "one file of a multi-account host", file=sys.stderr)
c, opaque, n_lines = collections.Counter(), 0, 0
for f in files:
    for line in open(f):
        try: d = json.loads(line)
        except Exception: continue
        n_lines += 1
        c[(d.get("tool", ""), d.get("detail", ""))] += 1
        # The only triage field going blind is a finding about the
        # product, not a quiet week. Count it separately rather than folding it
        # in with the reasons that still say something.
        if d.get("denied_by", "") == "Blocked by classifier":
            opaque += 1
print(f"read {len(files)} file(s), {n_lines} denial(s); {opaque} carry no usable reason")
for (tool, detail), n in c.most_common(30):
    print(f"{n:5}  {tool}\t{detail}")
PY
```

A destination or command appearing repeatedly is **not** misbehaviour — it is `autoMode.environment`
or `permissions.ask` missing an entry.

> **Headless caveat.** The `PermissionDenied` hook fires in interactive sessions; headless
> (`claude -p`) sessions may not fire it — probe **M5** (`bin/cc-bump-audit.sh`) re-asks that at
> every bump. An empty denial log from headless-only usage is therefore
> not evidence of a broken hook; for the quarterly review, cross-reference the *activity* log,
> which records the attempt either way.

## 4.3 Joiner

1. The account is created in the directory service and the home directory is provisioned.
2. **Do not rely on `/etc/skel` unless the host creates homes at first login.** Where homes are
   pre-created on shared storage and the PAM stack has no `pam_mkhomedir`/`oddjob_mkhomedir`, skel
   is never copied. Anything a new user must have arrives from managed settings or a
   `/etc/profile.d` drop-in instead.
3. Confirm the home directory mode is `0700` at creation — the health check reports any that is
   not (§4.1).
4. Issue the Claude seat from the claude.ai admin dashboard.
5. The engineer runs `claude` once and completes browser OAuth. No IT action.
6. Tell them, in onboarding, that the activity log exists and what it records. This is a stated
   obligation, not a courtesy.
7. Confirm with `cc-audit.sh` that the credential is present and 0600.

## 4.4 Leaver

**Order matters.** Revoke the seat **first**, then remove the Linux account and home
directory. The seat is what grants access; removing the account alone leaves a live credential the
person could use elsewhere. With shared network homes and central identity this is more important,
not less, because the credential is not tied to a host.

1. Revoke the seat in the claude.ai admin dashboard.
2. Remove the Linux account.
3. Remove or archive the home directory, per retention policy — including
   `~/.claude`, `~/.claude.json`, and any private install under `~/.local`.

   > **This step deletes the transcripts, and the transcripts are the record.** The policy retains
   > them (`cleanupPeriodDays`) precisely because they are the only account of what the agent did in
   > a project, and the leaver step destroys them on the day the person leaves. The two
   > decisions contradict each other until someone reconciles them. **Archive rather than delete** if
   > the leaver worked on projects with an audit or contractual duty attached, settle the retention question with whoever owns audit
   > and IP obligations, and record the decision in `internal/LIMITATIONS-AND-RISKS.md`. The IT-owned
   > activity log is unaffected by this step, which is one of the reasons it exists.
4. **Verify the home is gone and not left owned by an unresolvable UID.** A stranded home is what
   a skipped step leaves, and the health check reports it (§4.1).
5. Confirm `cc-audit.sh` no longer lists the user.

## 4.5 Exception requests

A lockdown with no published route is a lockdown that gets quietly worked around. Publish this
table with the deployment.

| Request | What to include | Default answer |
| --- | --- | --- |
| A destination the classifier keeps blocking | The matching line from the denial log | Add to `autoMode.environment`. Routine, no change record for an internal host already reachable |
| An internal domain for the sandbox allowlist | The service, and why the agent needs it | Approved, with a change record |
| A public domain for the sandbox allowlist | The data that would flow over it | No, unless the project lead signs off. Change record either way |
| An MCP server or plugin | The source, and what it can reach | No until someone has read what it does. An MCP server is arbitrary code holding the agent's permissions |
| A new `permissions.allow` entry | The command, and how often it is needed | Prefer a narrow rule. Never one taking arbitrary arguments — `npx`, `docker exec` and `mise exec` are not stripped, so an allow rule for them grants whatever follows |
| "Turn the sandbox off for this task" | — | No. If a tool must write outside the working directory, add the path to `sandbox.filesystem.allowWrite` |

**Target 24 hours on the first two rows.** An engineer blocked for a week finds another way, and
that way will not be one you designed.

---

# Part 5 — Recover

## 5.1 Rollback, by scope

Roll back the smallest thing that fixes the problem. In increasing order of disruption:

```bash
# 1. Policy only — restore the previous file and re-record the baseline
sudo cp "$CC_POLICY.bak" "$CC_POLICY"
sudo sh -c "sha256sum $CC_POLICY > $CC_POLICY_SHA"
sudo claude doctor

# 2. Resource limits only
sudo rm $CC_UNITS/user-.slice.d/50-claude-code.conf
sudo systemctl daemon-reload

# 3. The HOME workaround only (e.g. after the directory's home attribute is fixed, 1.6)
sudo rm $CC_PROFILED/claude-code-home.sh $CC_PROFILED/claude-code-home.csh

# 4. Version
sudo $CC_SBIN/cc-update.sh rollback <previous-version>

# 5. Full removal — see Part 6
```

## 5.2 Failure playbooks

| Symptom | Cause and action |
| --- | --- |
| **Every Bash command fails**, `bwrap: Can't mkdir /home/<user>/…` | The `HOME` symlink. Confirm with `readlink /home/<user>`; check the `profile.d` drop-ins exist in **both** shell variants and that the session is a fresh login. §1.6 |
| **Every Bash command fails**, `apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument` | Isolation cannot nest — the session is already inside a user namespace. There is no configuration fix. Run outside the sandbox, or do not run Claude Code inside another sandbox on this host. Note that `failIfUnavailable: false` does **not** fail open for this class |
| **`sudo` fails inside a session**, `/etc/sudo.conf is owned by uid 65534` | Expected. Root is remapped to an unprivileged UID inside the namespace and setuid correctly refuses. The host's `sudo` is undamaged. Use a real terminal |
| **Claude Code refuses to start for everyone** | Three candidates, in likelihood order: a wrong `forceLoginOrgUUID`; `failIfUnavailable: true` with a missing sandbox dependency; `requiredMinimumVersion` above the installed version. Check `claude doctor` as root, then roll the policy back (§5.1 step 1) |
| **Login shows a code to paste** | The browser cannot reach the loopback callback. Check `BROWSER` is set in the user's shell, a graphical browser exists in the session, `DISPLAY` is set, and loopback is not filtered. §1.7 |
| **Login fails despite a valid seat** | A stray `ANTHROPIC_API_KEY` overriding the subscription. `unset` it and remove it from the shell profile — including `~/.cshrc` and `~/.tcshrc`. Confirm with `/status`. Setting `forceLoginOrgUUID` prevents this class outright |
| **Managed policy appears not to apply** | `/permissions` shows which file each rule came from; `/status` shows the active managed source. **If managed settings have been enabled in the claude.ai console, they take over from the local file entirely and nothing errors.** That is the first thing to check |
| **A permission rule silently does nothing** | Most often the path anchor: a single leading slash anchors at the settings file, not the filesystem root. Second most often: a filename glob, which some versions ignore on Linux (probe M10 of `cc-bump-audit.sh` answers it for the version in use; a site records the answer in `internal/LIMITATIONS-AND-RISKS.md`). `/doctor` inside a session reports the second where it applies; the CLI `claude doctor` does not |
| **Resource limits not taking effect** | The wrong cgroup variant for the host. Check `stat -fc %T /sys/fs/cgroup` and read the effective values back from `systemctl show`. v2 directives are accepted and ignored on v1 |
| **Version moved unexpectedly** | Either versionlock was not applied, or a private install is winning `PATH`. The health check reports both |
| **"Claude stopped working" partway through the day** | Most likely a per-seat usage limit, not an outage. Have the user run `/usage`. Limits reset; there is nothing to fix on the host |
| **An action was blocked and the engineer is stuck** | `/permissions` → Recently denied → press `r` to retry. If the same destination keeps being blocked it needs an `autoMode.environment` entry, not a workaround |
| **Illegal instruction** | No AVX on the CPU or hypervisor. No workaround for the native binary; move instance family |
| **`Error loading shared library libstdc++.so.6`** | The musl binary on a glibc host, usually because a musl cross-toolchain is present. Confirm with `ldd --version` |

## 5.3 If the host is lost

Claude Code holds nothing on a managed host that needs backing up. **Where home directories are on
network storage, credentials and transcripts live there, not on the host**, so a rebuild does not
lose them; with local homes they go with the host. What a rebuild always loses is anything that
exists only in `/etc` or `/var/log` on that host — which is exactly why the policy and scripts belong in the image and in
version control, and why `/var/log/claude-code` should be shipped off-host.

Recovery is: launch from the image, apply the policy and scripts, run `cc-preflight.sh` and
`cc-audit.sh`, tell users to log in. Seats are held in the claude.ai organisation and are
unaffected.

## 5.4 Security incidents and break-glass

The playbooks above cover things being broken. These cover things having gone wrong. **Agree the
declaration authority and the notification duty before you need them** — the technical steps are the
easy half.

### 5.4.1 Break-glass: stopping Claude Code immediately

There is no product kill switch, but three levers exist. They differ in blast radius and in how fast
they take effect, so pick deliberately.

| Lever | Effect | Speed | Notes |
| --- | --- | --- | --- |
| Set `requiredMinimumVersion` to an unreachable value (e.g. `"99.0.0"`) in the policy | **Every** copy of the binary on that host refuses to start, including private per-user installs | Next session start; running sessions continue | The cleanest host-level stop. Reversible in one edit. Remember it is fail-open on a *malformed* value — use a well-formed impossible version, not garbage |
| `sudo dnf remove claude-code` | Removes the managed binary only | Immediate for new invocations | **Does not stop private `~/.local` installs**, which is exactly why the lever above is preferable |
| Revoke the seat(s) in the claude.ai admin console | The account cannot authenticate anywhere — every host, and the desktop and web apps too | Immediate for new logins; an existing token works until it expires or is revoked | **The only fleet-wide lever**, because it acts on identity rather than on hosts |

> **Where homes are shared across hosts and not every host carries the policy, identity is the
> only thing you can stop everywhere at once.** Removing the binary from one host does not stop a
> private install reached from another. Plan around that.

### 5.4.2 Suspected credential compromise

A credential is a single file in the user's home. If homes are on a network export that other
hosts can mount, it is readable from those hosts (§2.1), so treat this as plausible rather than
exotic.

1. **Revoke the seat** in the claude.ai admin console. This is the action that matters; everything
   else is cleanup.
2. Remove the credential file: `rm -f $CC_HOME_ROOT/<user>/.claude/.credentials.json`. Where homes
   are shared, this clears it on every host at once.
3. Have the user re-authenticate, and confirm from `/status` that the login method is the
   organisation's subscription account with no API-key row.
4. **Review the activity log for the exposure window** — it records every command, path and URL per
   named user, and it is the only record that is not in the user's own control.
5. There is **no fleet-wide logout command**. Seat revocation is the equivalent.

### 5.4.3 Suspected exfiltration of customer data

The trigger is usually a line in the activity log naming a destination that is not on the allowlist,
or a denial-log entry showing repeated attempts.

1. **Preserve the evidence first.** Copy the relevant `/var/log/claude-code/**` files off the host to
   storage the user cannot reach, and note the times. The logs are **not tamper-evident** — copying
   them promptly is the only integrity measure available (the log model and its limits are
   `RUNBOOK.md` §11.7).
2. Establish whether the destination is reachable at all: `sandbox.network.strictAllowlist` denies
   sandboxed commands any host outside the allowlist, so a *sandboxed* command should not have
   succeeded. If it did, that is a control failure and a separate, more serious finding.
3. Check whether the sandbox was actually running. With `failIfUnavailable: false`, a session can run
   **unsandboxed with only a warning** — so "the allowlist would have stopped it"
   is a claim to verify, not assume.
4. Determine whose data was involved. Where it was a customer's, hand the contractual question
   — including any NDA notification duty — to whoever holds the customer contracts. **That duty is not IT's to
   assess, and it is not discharged by fixing the host.**

### 5.4.4 Prompt injection, or an agent that damaged a project tree

Prompt injection is the threat the sandbox exists for, so treat it as a control test rather than only
an incident.

1. Capture the session transcript from `~/.claude` **before** `cleanupPeriodDays` expires it, and the
   matching activity-log window.
2. Establish what the agent was reading when it changed behaviour — a customer file, a web page, a
   dependency, a Makefile. That artefact is the finding.
3. For damage to a project tree: recovery is the storage system's snapshot or the project's own version
   control. Nothing in this deployment backs up project storage.
4. Ask whether the boundary held: did `permissions.deny` refuse the destructive call, did the
   classifier, or did neither? If a deny rule should have matched and did not, check the path anchor
   — a single leading slash anchors at the settings file, not the filesystem root.
5. Feed the result back into `autoMode.hard_deny` or `permissions.deny`, and record it as a change.

### 5.4.5 A rogue skill, plugin or MCP server

Should not be possible — `allowManagedMcpServersOnly`, `strictPluginOnlyCustomization`,
`disableSideloadFlags` and `allowManagedHooksOnly` are all set, and `allowedMcpServers` is empty. **If
one is found running, the lockdown has a hole and that is the incident**, independent of what the
component did. Capture the effective configuration with `cc-audit.sh` and `/permissions` before
changing anything, then establish which lock was missing or stripped.

### 5.4.6 What to settle in advance

| Question | What a site needs written down |
| --- | --- |
| Who declares a Claude-Code-related security incident? | A named role, decided before the first incident |
| Who holds the vendor support relationship, and how is a case raised? | The account, the entitlement and the contact route |
| Where the site holds customer data: what is the NDA notification duty if it left the fleet? | **Owner: whoever holds the customer contracts.** Not IT |
| Where is preserved evidence stored, and for how long? | A location the affected user cannot reach, and a retention period. The logs are host-local and appendable until they are shipped off-host |

Each answer, or the fact that it is still open, is state: `internal/CURRENT-STATE.md`.

---

# Part 6 — Decommission

```bash
sudo dnf versionlock delete $CC_PKG
sudo dnf remove $CC_PKG
sudo rm /etc/yum.repos.d/$CC_PKG_REPO_ID.repo
sudo rm -rf "${CC_ETC:?load config first}"

# control plane
sudo systemctl disable --now claude-code-healthcheck.timer claude-code-version-watch.timer claude-code-report.timer
sudo rm -f $CC_UNITS/claude-code-{healthcheck,version-watch,report}.{service,timer}
sudo rm -f "${CC_LOGROTATE:?load config first}/claude-code"
sudo rm -f $CC_SKEL/.claude/settings.json
sudo rm -rf "${CC_ETC_ADMIN:?load config first}"      # present only after an install --with-admin
sudo rm -f $CC_UNITS/user-.slice.d/50-claude-code.conf
sudo rm -f $CC_SBIN/cc-*.sh
sudo rm -f $CC_PROFILED/claude-code-home.{sh,csh} \
           $CC_PROFILED/claude-code-browser.{sh,csh}
sudo rm -rf "${CC_SHARE:?load config first}"
sudo systemctl daemon-reload

# per user, as part of offboarding — with shared network homes this cleans every host at once
rm -rf ~/.claude ~/.claude.json ~/.local/bin/claude* \
       ~/.local/share/claude ~/.cache/claude* ~/.local/state/claude
```

Also required, and easy to forget:

- **Revoke the seats** in the claude.ai admin dashboard. Removing a Linux account does not
  revoke a subscription seat.
- **Archive `/var/log/claude-code`** per retention policy before removing the host. Where
  customer work is under NDA this is the IT-owned record of what the agent did, and it does not
  exist anywhere else.
- Remove the egress allowlist entries if nothing else needs them.

# Part 7 — Agentic maintenance: the version bump and the standing audits

## 7.0 The model — scripts decide, agents analyse, CI enforces, humans apply

Maintenance work here runs on a four-rung ladder, and every step of every procedure sits on the
lowest rung that can hold it:

1. **Scripts** (`bin/cc-*.sh`) — anything that must be exact, every time. Agents call them; they
   never re-implement them.
2. **CI checks** (`bin/cc-ci-check.sh`) — invariants that must hold before a push lands, whoever
   pushes. Check [9] is the one that makes this Part unskippable: a `requiredMinimumVersion`
   change with no `UPGRADES.md` entry is a red build.
3. **These sections** — the canonical procedures. The skills in `.claude/skills/` are *readers* of
   this Part: the `version-bump` skill executes §7.1 step by step, and each standing audit treats
   its §7.2 row as its contract. A skill may hold its **own** run steps — for the standing audits
   the skill body is those steps' one home — but never a second copy of anything written here.
   **Section headings in this Part are an interface** — before renaming one, grep
   `.claude/skills/` for it.
4. **Model judgment** — only classification, synthesis and suggestion: what the vendor changelog
   means for this deployment, which new settings key deserves a position, what a diff implies.

Two rules bound rung 4, and they are not style: **agents propose, humans apply** — no skill runs
`sudo`, applies a policy, or moves a package; the privileged commands are printed for a person at a
real terminal. And **findings go to `internal/`** — any output quoting log content, live findings
or risk state is group-only material, never `docs/`.

The skills load in any Claude Code session opened in this repository (the policy enables
project-level skills — `SETTINGS-REFERENCE.md` §3.4). Nobody needs a skill's name: saying
"upgrade Claude Code to the new release" or "run the estate audit" in plain words is enough, because skill
descriptions are matched semantically.

## 7.1 The version bump

The package move itself is §3.2 (`cc-update.sh check / stage / apply`), unchanged. This procedure
wraps §3.2 with the analysis before it and the record after it, so a bump is never just a number
moving. Entry state: a target version chosen (§3.1), a session open in this repository. Exit
state: the new pin live, verified, and recorded in [`UPGRADES.md`](UPGRADES.md).

**Step 1 — preflight.** Working tree clean, CI green:

```bash
git status --short          # pass: no output
bash bin/cc-ci-check.sh     # pass: "cc-ci-check: all checks passed", exit 0
```

**Fail:** fix the tree first. A bump on a red tree buries its own evidence.

**Step 2 — the deterministic audit.** In the session or by hand:

```bash
make bump-audit             # or: bash bin/cc-bump-audit.sh --target-version <x.y.z>
```

**Where this runs matters.** A bump is normally driven from a `claude-admin` session, because the
privileged half of it needs controls a fleet session does not have. In that session's mount
namespace `/etc/claude-code/managed-settings.json` is the **bind-mounted admin policy**, so any
probe that reads the deployed policy is reading the wrong file: A3 (baseline sha) and A7 (glob
rules present) detect this and **skip with a reason** instead of reporting drift that does not
exist. To close them, run `make bump-audit` once from a plain session — before opening
`claude-admin`, or in another terminal — or take them at step 6, whose `make verify` the human runs
in a real terminal anyway. The same detection guards `cc-install.sh --apply` (gate 1b) and
`cc-healthcheck.sh` `[2]`.

**Pass:** exits 0 — coherence holds and no auto probe regressed; skips are listed with reasons.
**Fail:** exits 1 names the exact break (floor/record mismatch, a probe whose answer changed). A
changed probe answer is not noise — it is the vendor changing behaviour this deployment depends on;
resolve it before moving the package.

**Step 3 — the agent lanes.** Four analysis lanes, run as parallel subagents (the `version-bump`
skill does this; each lane returns findings, never applies anything):

| Lane | Question | Lands in |
| --- | --- | --- |
| Vendor changelog | What shipped between the pins? Classify: security-relevant / new settings keys / behaviour changes / irrelevant, with links | `UPGRADES.md` entry part 1 |
| Settings surface | Which keys appeared, retired, changed defaults? Which ▲ flags in `SETTINGS-REFERENCE.md` §6 resolve? Suggested position for each new key | Entry part 2 + §6 rows, same commit |
| Script review | Do the hooks, statusline or cc-* scripts depend on behaviour the changelog says moved? | Entry part 3 |
| Docs re-anchor | Every front-matter **When** row or claim that names the old pin, and any claim the changes invalidate | Entry part 3 |

**Step 4 — record, then gate.** Write the `UPGRADES.md` entry (contract at the top of that file),
edit the policy's `requiredMinimumVersion`, commit. **Pass:** `bash bin/cc-ci-check.sh` exits 0 —
check [9] now holds the pin and its record together.

**Step 5 — the human moves the package.** From a real terminal, per §3.2 and §1.5b (announce
first: a policy apply breaks running sessions). The session prints these; it never runs them.
The printed block **opens with `cc-update.sh sessions`** and the order is package first, policy
second — the reverse of a rollback. Expect to be blocked by your own session at least once: the
analysis half of this procedure runs *inside* Claude Code, and that session is running the very
binary step 5 replaces, so the last thing the session does is tell you to close it.

**Step 6 — re-verify and close.** `make verify`, the §1.10 acceptance checks, the manual probes
from `bin/cc-bump-audit.sh` section [C] that this bump makes testable (each cites its doc home).
Fold the results into the entry's part 4, re-verify the claims the docs sweep found — the **When** rows point at the pin rather than repeating it (`DOC-STYLE.md`), so what the sweep hunts is *claims*, not numbers — and
update `internal/CURRENT-STATE.md`. The entry freezes; the bump is done.

## 7.2 The standing audits

Same architecture, no version move. Each is a skill a session runs on request; each cites this
table as its contract:

| Run | What it does | Cadence | Output lands in |
| --- | --- | --- | --- |
| `settings-review` | The §4.2 quarterly settings review: new vendor keys get a §6 row and a position; ▲ flags re-checked | Quarterly, and inside every bump (lane 2) | `SETTINGS-REFERENCE.md` §6 edits |
| `repo-audit` | Docs truth vs host truth: directory maps vs contents, RUNBOOK claims vs `cc-healthcheck`/`cc-audit` output, risk-register rows whose review triggers have fired | Quarterly, and after any structural change | Findings: `internal/`; doc fixes: normal commits |
| `fleet-drift` | Deployed `/etc/claude-code` + installed hooks on each reachable host, diffed against this checkout | After any deploy; standing on a fleet of more than one host | Report to `internal/`; fixes via §1.12 |
| `log-review` | Summarise `/var/log/claude-code/{activity,denied}` for anomalies and the §4.2 allow-list review | Monthly | `internal/` **only** — log shapes are group-sensitive. **The findings land in the existing registers** (`internal/CURRENT-STATE.md`, `internal/LIMITATIONS-AND-RISKS.md`); a run does **not** create a per-month file, because a record that accretes forever is a second history with no reader. If a run log is ever wanted, it is one register with a dated row and a denominator per run — not a file per month |
| `estate-status` | Answers "what is the state of Claude Code?" from the **stored** weekly report (`/var/log/claude-code/reports/latest.json`) — reads, never re-derives. Refuses a record older than 9 days, or a partial one, without saying so first | On demand | Nothing written; it cites `REPORTING.md` for the contract and the registers for findings |
| `cc-report.sh` (not a skill — a root timer) | Runs every check weekly, ranks what came back against the previous week, and answers **BUMP:** and **REPORT TO MANAGEMENT:** as fields | Weekly, Mon 07:30, automated | `/var/log/claude-code/reports/`, group-readable; [`REPORTING.md`](REPORTING.md) is its contract |
| `estate-audit` | The master: runs `log-review`, `fleet-drift`, `repo-audit` and `settings-review` as subagents in three waves, then synthesises one report. Owns no content of its own. `version-bump` is excluded because it moves a pin; `estate-status` because it reads the stored report rather than re-running a check | On demand — "run the full estate audit" | One report; each finding cites its child |

## 7.3 Failure modes this Part was built against

- **The forgotten record** — cannot happen: CI check [9] refuses the pin without the entry.
- **The silently changed platform** — the probe manifest (`bin/cc-bump-audit.sh --list-probes`)
  re-asks every version-anchored claim; a probe nobody wrote is the residual risk, so closing or
  adding probes is part of every bump's entry.
- **The blind in-session upgrade** — `hooks/cc-upgrade-guard-hook.sh` blocks the attempt and
  points here. The enforcement itself was never this hook: the versionlock and root ownership are.
- **The drifted skill** — a skill that copies a procedure out of these sections rots like any
  second copy. A skill's own run steps live in the skill, once; anything written here is cited,
  never restated.

## 7.4 The version watcher — so nobody has to remember to look

Everything in §7.1 begins with somebody deciding to check. That is the weakest
step in the whole Part: it depends on memory. The watcher removes the memory.

It sits on **rungs 1 and 2** of §7.0 — a script that answers one factual question
exactly, and a CI job that raises the answer where a person will see it. It
**classifies nothing**: whether a release matters is model judgment and belongs to
§7.1's changelog lane. It moves nothing.

| Half | What it is | Where the answer lands |
| --- | --- | --- |
| On host | `bin/cc-version-watch.sh`, weekly from `claude-code-version-watch.timer` (Mon 07:15) | `/var/log/claude-code/version-watch.json`, one greppable line in the journal, and a **failed unit** when a newer version exists |
| Off host | `.github/workflows/version-watch.yml`, weekly on GitHub's runners | **One GitHub issue**, created once, edited when the number moves, silent when nothing changed, and **closed automatically** when the pin catches up |

**Read the exit code, not the prose.** `0` nothing above the pin. `1` a newer
version exists — the finding, non-zero so `systemctl --failed` shows it. `2`
usage. `3` **could not tell**: no pin, an unparseable policy, a repository that
did not answer, or a cache-only run whose metadata is too old. Three is the code
that matters most, because a broken repository and a current deployment must never
look alike.

Two traps it exists to avoid:

- **The versionlock hides the answer.** `dnf` filters everything above a
  versionlock out of a query, so a locked host asked "is anything newer?" says
  no, forever. The watcher asks with `--disableplugin=versionlock`. This is a
  read-only query; the lock itself is untouched.
- **`--refresh` does not prove freshness the obvious way**, and the cached
  `repomd.xml` mtime does not answer what it looks like it answers. The mtime is
  *when this host fetched that copy* — nothing more. It is also unstable: dnf
  creates and removes a private `/var/tmp/dnf-<user>-*` tree per unprivileged
  invocation, so a reading taken across cache directories moves in both
  directions with no vendor change at all. Three separate
  questions, three separate answers:
  - **Has the vendor published since?** `published_age_h`, read from
    `repomd.xml`'s own `<revision>` — the timestamp the vendor stamps when it
    regenerates the repository, identical in every copy of a given state. It is
    `unknown`, never a guess, when no copy is readable, the value is not a
    plausible unix time, or our copies disagree about which state we hold.
  - **How old is the copy we hold?** `cache_age_h`, the mtime, scoped to the
    cache *this* run uses — `/var/cache/dnf` as root, the private tree as anyone
    else. This is the only input to `--max-age`, and only under `--cacheonly`,
    where no freshness claim is being made.
  - **Did we reach the vendor just now?** The successful `--refresh` itself, and
    nothing else. A failed refresh is reported as `unknown`.

**What to do when it fires:** nothing automatic. Read the entry in
[`UPGRADES.md`](UPGRADES.md) for the previous bump, then run §7.1 — in a session
opened in this repository, saying *version bump* is enough. The GitHub issue
closes itself once the pin reaches the version it names.

---

*Review with the runbook at each version bump, and again before the first AWS instance is built.*
