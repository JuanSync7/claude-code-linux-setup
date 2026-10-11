# Managed settings reference — every key, why it is set, and how to change it

| | |
| --- | --- |
| **What** | Every key in the managed policy — what it does, why it is set, and whether changing it is an operational preference or a dismantled control — plus the procedure for changing it safely (§2) |
| **Who** | Anyone who has to change or audit `/etc/claude-code/managed-settings.json`. No prior knowledge of this repository is assumed |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and [`UPGRADES.md`](UPGRADES.md) records every move of it. Re-verified at each bump (`OPERATIONS.md` Part 7) |
| **Where** | Every host carrying the fleet policy. The authored source is **`settings/managed-settings.json`** in this repository — take its current sha256 from `sha256sum settings/managed-settings.json`, never from prose. The sandbox block to start from, should the sandbox be enabled, is kept in the same file under the key `_sandbox_disabled` (§3.5) |
| **Why** | The policy file is the security boundary of this deployment, and this document is the canonical home for what each key means and how to change it — every other document points here |
| **Status** | Describes the policy as authored in `settings/`; what a given host carries is state, recorded in `internal/CURRENT-STATE.md`. **Sandbox disabled** (`SANDBOX-DECISION.md`); Posture A (gated interactive workstation) |
| **Owner** | The maintainer |
| **Schema review** | Quarterly (`OPERATIONS.md` §4.2), and before every version bump |

**Purpose.** The policy file is the security boundary of this deployment. This document exists so
that anyone who has to change it can tell, for each key, whether they are adjusting an
operational preference or dismantling a control — and can make the change without discovering the
hard way that the tool accepted their edit and quietly ignored it.

Read §1 and §2 before making any change. §3 is the key-by-key catalogue. §4 lists what is
deliberately *not* set, which is as much a part of the policy as what is.

---

## 1. Three properties of this settings surface that cause most mistakes

**1.1 Invalid entries are stripped, not rejected.** If a key or value fails schema validation,
Claude Code removes that entry, records a validation error, and applies everything else. A typo
therefore produces a policy that is quietly *weaker* than intended, and the tool starts normally.
There is no state in which the policy is loudly broken. `claude doctor` after every edit is
mandatory, and `cc-audit.sh` asserts that each named lock key is actually present rather than
merely dumping the file, because an absent key is the finding.

**1.2 Managed settings cannot be overridden — and deny propagates.** Managed is the highest of
the five scopes (managed → command line → local → project → user). No other scope, including a
command-line flag, can override a managed value. Separately, if a tool is denied at *any* scope,
no other scope can allow it. Two consequences follow: a managed value is genuinely binding, and a
managed value is genuinely inescapable — which is why UI preferences should normally be left out
of this file. The one deliberate exception is the status line (§3.9).

**1.3 A server-side policy would replace this file wholesale, and silently.** If managed settings
are ever enabled in the claude.ai organisation console, that payload takes over entirely and
`/etc/claude-code/managed-settings.json` stops being read. Nothing errors. The standing rule is
that the organisation console remains empty, with a named owner accountable for it. Whether it is
still empty is manual probe **M13** of `bin/cc-bump-audit.sh`. This is the single change that could disable every control in this document
without touching any host.

---

## 2. How to change a setting safely

### 2.1 The procedure

```bash
# Config loaded first: . /etc/claude-code/cc-config.sh (QUICKSTART.md §9)

# 0. WARN USERS FIRST. A policy rewrite breaks every session already running on the
#    host until the user restarts it. See OPERATIONS.md §1.5b.

# 1. Edit the AUTHORED SOURCE, never the deployed file
vi $CC_REPO/settings/managed-settings.json

# 2. There is nothing to promote: the tree holds exactly ONE authored copy,
#    settings/managed-settings.json, and the installer deploys from it
#    directly (§2.2).

# 3. Dry run: JSON validity, placeholder check, $defaults check
sudo bash $CC_REPO/bin/cc-install.sh --check

# 4. Apply — places the file, re-records the sha256 baseline
sudo bash $CC_REPO/bin/cc-install.sh --apply

# 5. Confirm Claude Code ACCEPTED it — this is the step that catches a stripped key
sudo claude doctor
sudo claude auto-mode config      # only if autoMode was touched; confirms $defaults expanded

# 6. Confirm from a user's point of view, in an interactive session
#    /permissions  -> rules attributed to /etc/claude-code/managed-settings.json
#    /status       -> managed source active
```

> **What `claude doctor` does and does not tell you.** The CLI form reports install and update
> state and **settings-schema** warnings — that is how a stripped or wrongly-typed key is caught,
> and it is the only vendor-side confirmation there is. It carries **no permission
> diagnostics**: it will not tell you whether a rule matches, and it says so itself, deferring to
> `/doctor` inside a session. Two probes rest on that split — **A7** can only assert the glob rules
> are *present* in the deployed policy, and **M10** must be run by a person in a session to ask
> whether they *enforce*. If a future build adds permission diagnostics to the CLI, A7 can be
> promoted from presence to enforcement; nothing else will announce that, so it is worth checking
> at each bump.

**Pass:** step 3 exits 0; step 5's `claude doctor` reports no stripped keys beyond the
expected glob-rule warnings (§3.2); step 6's `/permissions` attributes the rules to
`/etc/claude-code/managed-settings.json`.
**Fail:** a stripped key means the live policy is silently *weaker* than authored (§1.1) — fix
the authored source and re-run from step 3. If `/permissions` does not attribute rules to the
managed path, the file did not deploy: `OPERATIONS.md` §1.8.

Then file the change record (§2.3) and, if the file changed, re-record the checksum baseline —
step 4 does this, but a hand-edit of the deployed file would not, which is why step 1 says never
to hand-edit it.

> **Run every step from a real terminal (RDP or SSH), not from inside a Claude Code session.**
> The fleet policy denies `sudo` outright, and in an *admin* session the policy path is
> bind-mounted — an `--apply` from there writes the fleet policy over the admin copy, through
> the mount.

### 2.2 One authored copy

The repository holds the **single** authored copy of the policy, `settings/managed-settings.json`,
and the installer deploys from it directly. The only other copy of the policy anywhere is the
*deployed* file at `/etc/claude-code/`, whose drift against the recorded sha256 is what
`cc-healthcheck.sh` exists to catch. Never create a second source copy: two copies drift, and an installer
that deploys from the stale one puts back a policy that was deliberately changed — a disabled
control re-enabled, or an enabled one dropped — with nothing reporting it.

### 2.3 What requires a change record

| Change | Record needed | Sign-off beyond IT |
| --- | --- | --- |
| Any edit to `permissions.deny`, the lock keys, or the `env` block | Yes | Yes, if it removes or narrows a control |
| Adding a domain to `sandbox.network.allowedDomains` | Yes | Public domain: project lead. Internal domain: no |
| Adding an entry to `permissions.allow` or `sandbox.excludedCommands` | Yes | Yes |
| Enabling an MCP server or a plugin | Yes | Yes — an MCP server is arbitrary code holding the agent's permissions |
| Any change to `forceLoginMethod` / `forceLoginOrgUUID` | Yes | Yes |
| Any version-floor move (`requiredMinimumVersion`) | Yes | Notify affected users first (§3.11) |
| Adding a line to `autoMode.environment` for an internal destination | Lightweight | No — target 24-hour turnaround |
| `cleanupPeriodDays`, `companyAnnouncements`, `statusLine` | Lightweight | Retention: agree with whoever owns audit/IP |

---

## 3. The catalogue

Each key is classified:

| Class | Meaning |
| --- | --- |
| **Boundary** | A security control. Changing it weakens the posture. Change record and sign-off. |
| **Lock** | A meta-control that prevents users and projects from adding their own rules. Removing one does not itself permit anything, but it re-opens a channel. |
| **Tunable** | Operational. Change with a record; no sign-off needed. |
| **Pilot** | Deliberately relaxed while a deployment is piloted, with a defined path to tightening. |
| **Deferred** | Intentionally absent. The consequence is recorded; see §4. |

### 3.1 Permission mode

| Key | Value | Class | Why, and what changing it does |
| --- | --- | --- | --- |
| `permissions.defaultMode` | `"default"` | Tunable | Prompt on first use of each tool, so the engineer stays in the loop. Setting `"dontAsk"` switches to Posture B — genuine deny-by-default, but `AskUserQuestion` is denied too, so Claude cannot ask a clarifying question and will guess or stop. Suitable for a build agent, obstructive on an interactive workstation. |
| `permissions.disableBypassPermissionsMode` | `"disable"` | **Boundary** | Removes the escape hatch that skips prompting entirely. There is no second check behind `bypassPermissions`; this is the key that keeps the deny list meaningful. Do not relax. |
| `permissions.additionalDirectories` | `[]` | Boundary | Extra directories added to every session's working scope. Empty by design — a directory added here is in scope for every user on the host. |

### 3.2 The deny list — the absolute blocklist

**Class: Boundary.** 43 rules, in the seven categories below. No user, project, local or command-line
setting can lift any of them. Note that deny is evaluated first and cannot carry exceptions: a deny rule
plus a narrower allow rule blocks the narrower case too.

| Category | Rules | Reasoning |
| --- | --- | --- |
| Privilege and host administration | `sudo`, `su`, `dnf`, `yum`, `rpm`, `systemctl`, `firewall-cmd`, `useradd`, `usermod`, `passwd`, `chmod 777 *` | A shared instance is not the agent's to reconfigure. To confirm enforcement, ask a session to run `sudo id`: it is refused. |
| Unmanaged network egress | `curl`, `wget`, `nc`, `ncat`, `ssh`, `scp`, `rsync`, `aws` | **Load-bearing.** `WebFetch` rules constrain the `WebFetch` tool only; if Bash can reach a URL with `curl`, the `WebFetch` allowlist is decorative. Legitimate network use goes through the sandbox's domain allowlist instead. |
| Secrets and credentials | `~/.ssh/**`, `~/.aws/**`, `~/.gnupg/**`, `~/.claude/.credentials.json`, `//etc/claude-code/**`, `//etc/shadow`, `//etc/sudoers` | Directory-prefix rules, which the platform does enforce. `//etc/claude-code/**` stops the agent reading its own policy. |
| Secret filenames | `**/.env`, `**/*.pem`, `**/id_rsa*`, `**/id_ed25519*` | **Enforcement depends on the version**: probe M10 of `cc-bump-audit.sh` answers it for the version in use, and a site records the answer in `internal/LIMITATIONS-AND-RISKS.md` Part 3. The enforcement of record is `cc-secret-guard-hook.sh` (§3.7). There is deliberately **no** `**/.env.*` rule: where globs enforce, deny rules run before the hook, and that rule refused the allow-listed `.env.example`; the hook alone stops every other `.env.<name>`. Where a version warns about these rules in `claude doctor`, the warning is expected and should not be "fixed" by deleting them. |
| Persistence | `Edit(~/.ssh/**)`, `Edit(~/.local/bin/**)`, `Edit(~/.claude/settings.json)`, `Edit(~/.claude/settings.local.json)` | Stops a session writing something that outlives it: an SSH key or config, a binary in `~/.local/bin` that shadows the managed one on `PATH`, a user settings file. Edit rules cover every file-writing tool. A Bash command can still write there — the same subprocess limit as every rule |
| Shell startup files and system paths | `Edit(//etc/**)`, `Edit(//usr/**)`, `Edit(//opt/**)`, `Edit(~/.bashrc)`, `Edit(~/.bash_profile)`, `Edit(~/.profile)`, `Edit(~/.cshrc)`, `Edit(~/.tcshrc)` | Shell startup files are a persistence vector. The `csh`/`tcsh` entries matter wherever either is a login shell. |
| MCP | `mcp__*` | Belt and braces alongside the MCP locks in §3.6. |

> **Path anchoring.** A single leading slash anchors at the *settings file*, not the filesystem
> root. `Read(/etc/shadow)` does not protect `/etc/shadow`; `Read(//etc/shadow)` does. Check this
> on every rule you add — it is the most common error in hand-written policy.

> **Argument matching is fragile.** Do not attempt to constrain a command by its arguments —
> options before the URL, a different protocol, a redirect or a variable all evade it. Deny the
> command and use a tool-level control. Note also that `timeout`, `time`, `nice`, `nohup`,
> `stdbuf`, `command`, `builtin` and bare `xargs` are stripped before matching, so a rule for the
> inner command still applies; but `docker exec`, `npx`, `mise exec` and `devbox run` are **not**
> stripped, so an allow rule for any of those grants whatever follows it.

### 3.3 The ask list — human checkpoints

| Key | Value | Class | Why |
| --- | --- | --- | --- |
| `permissions.ask` | `Bash(git push *)`, `Bash(git remote *)`, `Bash(docker *)`, `Bash(podman *)` | Tunable | Content-scoped `ask` rules prompt **even in auto mode**, so these remain human decisions regardless of the classifier. This is the documented mechanism for a checkpoint that survives auto mode. Grow this list from the denial log rather than from speculation. |

### 3.4 The locks — what stops users writing their own policy

**Class: Lock.** Individually these permit nothing; collectively they are what makes the rest of
the file authoritative rather than advisory.

| Key | Value | What it closes |
| --- | --- | --- |
| `allowManagedPermissionRulesOnly` | `true` | User and project settings can define no `allow`, `ask` or `deny` rules at all. IT's rules are the only rules. |
| `allowManagedHooksOnly` | `true` | Hooks execute shell commands. Only the managed hooks (`hooks/README.md`) load. |
| `allowManagedMcpServersOnly` | `true` | Combined with an empty `allowedMcpServers`, this is MCP lockdown. |
| `allowedMcpServers` | `[]` | The allowlist that the previous key locks to. |
| `disableSideloadFlags` | `true` | Rejects `--plugin-dir`, `--plugin-url`, `--agents` and `--mcp-config` at startup. Without it, a single invocation bypasses the marketplace restrictions. |
| `strictPluginOnlyCustomization` | `["hooks", "mcp"]` | Deliberately granular — words open, code locked. The array names the **restricted** types; the listed types stay plugin/managed-only, the unlisted ones open. **Skills and agents** (unlisted) may come from user and project sources: they are instructions, inherit the session's permissions and can never widen them; this is what lets engineers author and iterate skills. **Hooks and MCP servers** (listed) stay locked: a hook is auto-executing shell code beside the audit machinery, an MCP server is new tool surface — and both are independently held by `allowManagedHooksOnly` and the MCP sibling keys regardless, so even a stripped value fails to the intended posture. The *object* form the vendor documents (`{skills, agents, …}`) **is not accepted**: the shipped schema takes `true` or an array and nothing else, and `claude doctor` says so in its own words. The schema embedded in the binary is the authority, not the documentation — and it holds for builds ahead of the pin too, so a bump does not license it. Re-verify against the schema, never the documentation, before adopting it ([`UPGRADES.md`](UPGRADES.md) records where that was checked). **The admin policy carries the same array** (`ADMIN-SESSION.md` §3): an admin session needs the repository's skills, and the hooks/MCP half matters more there, not less. |
| `disableClaudeAiConnectors` | `true` | Turns off claude.ai MCP connectors, and removes the need to allowlist `mcp-proxy.anthropic.com`. |
| `disableRemoteControl` | `true` | Disables device-side Remote Control. Disable it organisation-side as well, so this is defence in depth. |

**Verification that these hold** is a specific test, not an inference: have a test user add an
`allow` rule to `~/.claude/settings.json` and confirm `/permissions` does not show it.

### 3.5 The sandbox — OS-level enforcement

> **`sandbox.enabled` is `false`.** The policy contains only
> `"sandbox": {"enabled": false}`; the block documented below is kept in the file
> under the key **`_sandbox_disabled`** so it can be put in place in one edit. `SANDBOX-DECISION.md` is
> authoritative and lists the conditions for enabling.
>
> What this changes elsewhere in this document: any key under `sandbox.filesystem.*` or
> `sandbox.network.*` — `allowRead`, `allowWrite`, `denyRead`, `allowManagedReadPathsOnly`,
> `strictAllowlist`, `allowManagedDomainsOnly`, `allowedDomains` — is **inert**. In
> particular there is no OS-enforced network allowlist; the network boundary is owed to firewall
> egress filtering.
>
> Two cautions if you edit these keys:
>
> - **`failIfUnavailable: false` is not a safety net.** A sandbox that fails with the
>   `unshare(CLONE_NEWUSER)` error class hard-fails rather than failing open.
> - **`allowUnsandboxedCommands` and `excludedCommands` have not been exercised.** They are
>   present and the binary recognises them, but this repository tests no behaviour of theirs. Do not
>   rely on them without a fresh-session test.

| Key | Value | Class | Why, and what changing it does |
| --- | --- | --- | --- |
| `sandbox.enabled` | **`false`** | **Boundary — deliberately surrendered** | Permission rules do not reach subprocesses; one level of indirection through any interpreter turns every file and network rule advisory. The sandbox is the only layer that holds against that, and **with it disabled there is no such layer.** The reasons it is disabled, the compensating controls and the conditions for enabling it are in **`SANDBOX-DECISION.md`**; a site records its acceptance of the risk in `internal/LIMITATIONS-AND-RISKS.md`. |
| `sandbox.failIfUnavailable` | `false` | **Pilot** | Isolation cannot nest, so a session that is itself sandboxed hard-fails. With `true`, that condition would stop Claude Code starting for everyone on the host. **Do not flip to `true` on a shared host while a session can start inside another sandbox** — and note that fail-open does *not* cover the `unshare(CLONE_NEWUSER)` error class, so this setting protects less than its name suggests. It becomes affordable on a per-user desktop, where the blast radius is one engineer (`LOCAL-VS-AWS.md` §4). |
| `sandbox.allowUnsandboxedCommands` | `false` | **Boundary** | Ignores the `dangerouslyDisableSandbox` escape hatch, so a command that fails under the sandbox cannot simply be retried outside it. |
| `sandbox.excludedCommands` | `[]` | **Boundary, with a known gap** | Commands exempted from the sandbox. **There is no managed-only lock for this key** — a user can always append entries. Keep the managed list empty or narrow, and treat the audit report's `excludedCommands` line as something to read every time. |

#### Filesystem

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `filesystem.allowManagedReadPathsOnly` | `true` | Lock | Array keys normally merge across scopes, so a user could otherwise widen `allowRead`. This locks it to the managed values. |
| `filesystem.denyRead` | `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.claude`, `/etc/claude-code`, `/var/log/claude-code` | **Boundary** | `denyRead` wins over `allowRead`, so home is readable *except* these subtrees. Do not omit these on the assumption the sandbox is closed by default — **by default it allows reading the entire filesystem**. |
| `filesystem.allowRead` | `~/`, `/usr/share`, and the site's project, scratch and tool mounts — the list is in the `_sandbox_disabled` block | Tunable (locked) | Must name the mounts engineers really work in. With `allowManagedReadPathsOnly: true`, a list that names a path nobody uses blocks every real project directory on the first command. |
| `filesystem.allowWrite` | The scratch area, one entry | Tunable | Writes are closed by default — only the working directory and the session temp directory. If a tool must write elsewhere, add the path here rather than excluding the command from the sandbox. |

> **`~` expands to the value of `HOME`.** Where the directory service publishes a home path that
> is a symlink, `bubblewrap` cannot mount through it, so `/etc/profile.d/claude-code-home.{sh,csh}`
> resolves `HOME` to the real path first. That is load-bearing for every rule above that starts
> with `~`. The permanent fix is to publish the real path in the directory attribute the host's
> name service reads the home directory from; the drop-ins can be removed only once it does.

#### Network

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `network.strictAllowlist` | `true` | **Boundary** | Denies sandboxed commands any host outside the allowlist rather than prompting. This is the network deny-by-default switch, and the only genuine deny-by-default mechanism in the policy besides `dontAsk` mode. |
| `network.allowManagedDomainsOnly` | `true` | Lock | Same array-merge lock as `allowRead`. |
| `network.allowedDomains` | Six Anthropic hosts (`code.claude.com` among them), plus `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `github.com` | Tunable, change record | Separate from the *egress* allowlist in the runbook — these are two different lists. The public package hosts are there for a site with **no internal package mirror**. Where one exists, add its host under the site's internal domain **and remove the public ones**, so installs must route through it. Never name a public host as the internal registry: that switches the classifier's protection off. |

### 3.6 Auto mode — the classifier

Auto mode is deliberately **enabled**, which reverses the instinct to disable anything that
reduces prompting. The ordering is the argument: the classifier runs *after* the permission
system, so every deny rule and every `ask` rule still holds. It adds a gate rather than removing
one. The second argument is about people — an engineer facing dozens of prompts an hour stops
reading them.

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `autoMode.environment` | `$defaults` plus 7 organisation-context lines | Tunable | This is where the classifier learns what is legitimate here. Repeated blocks on the same destination mean this array is missing an entry — not that the engineer is doing something wrong. Adding an internal destination is routine; target 24 hours. |
| `autoMode.hard_deny` | `$defaults` plus one rule: customer data is never sent to a host outside the site's internal domain | **Boundary** | `hard_deny` and `permissions.deny` are the only two firm lists. `soft_deny` is **not** a policy boundary — a user's own `allow` entry can override an organisation `soft_deny`, because those lists combine additively. Put anything absolute in these two. |
| `autoMode.classifyAllShell` | `true` | Tunable, security-relevant | Narrow allow rules normally resolve before the classifier, so a destructive argument the prefix did not anticipate passes unseen. This routes every shell command through the classifier. It costs latency and a classifier call per command; on a host holding customer IP that is the right trade. |

> **Never omit `"$defaults"`.** Setting any `autoMode` array without it **replaces** the entire
> built-in list for that field. Dropping it from `hard_deny` discards the built-in
> data-exfiltration rule; dropping it from `soft_deny` discards force-push protection,
> curl-pipe-to-bash, production-deploy and auto-mode-bypass blocks. This is the sharpest single
> footgun in the settings surface. `claude auto-mode config` shows each list with `$defaults`
> expanded in place; run it after **every** `autoMode` edit.
>
> The classifier deliberately does **not** read `autoMode` from project settings, so a checked-out
> repository cannot inject its own trust. It is also a model making a judgement, not a
> deterministic rule — which is exactly why the deny list and the sandbox stay underneath it.

### 3.7 Hooks — the evidence layer and the secret guard

**Class: Boundary.** `allowManagedHooksOnly: true` means these are the only hooks that load.

| Event | Matcher | Script | Purpose |
| --- | --- | --- | --- |
| `PreToolUse` | `Bash\|Edit\|Write\|WebFetch` | `/usr/local/sbin/cc-audit-hook.sh` | One JSON line per call to `/var/log/claude-code/activity/<user>.jsonl` |
| `PreToolUse` | `Bash` | `/usr/local/sbin/cc-upgrade-guard-hook.sh` | Blocks self-update attempts (`claude update`, npm sideload, vendor installer, package-manager **transaction** verbs on `claude-code` — `install`, `localinstall`, `upgrade`, `dist-upgrade`, `upgrade-minimal`, `update`, `distro-sync`, `downgrade`, `reinstall`, `swap`) with a signpost to the version-bump procedure (`OPERATIONS.md` Part 7). **Query verbs pass** — `list`, `info`, `search`, `repoquery`, `check-update`, `rpm -q*` — because the bump procedure itself has to ask the repository what versions exist. A redirect, not the enforcement — the versionlock is |
| `PreToolUse` | `Read\|Edit\|Write\|NotebookEdit` | `/usr/local/sbin/cc-secret-guard-hook.sh` | Blocks a call whose target *basename* looks like a credential. The enforcement of record for the filename rules (§3.2), and covers `Read`, which the audit hook deliberately does not |
| `PostToolUse` | `*` | `/usr/local/sbin/cc-redact-hook.sh` | Replaces credential-shaped text in any tool's **output** before the model sees it, through `hookSpecificOutput.updatedToolOutput`, and logs the kind and count. Covers what a script prints, which no rule on the command can see. The rewrite must keep the tool's output shape exactly: a reshaped output is dropped and the original reaches the model |
| `PermissionDenied` | `Bash\|Edit\|Write\|WebFetch` | `/usr/local/sbin/cc-denied-hook.sh` | What the policy refused, to `/var/log/claude-code/denied/<user>.jsonl` |

Three design properties are load-bearing and must survive any edit:

- **They record the shape of a call, never its content.** A `Write`'s file path is evidence; the
  file's contents are the engineer's work and are not IT's to copy. Only `command`, `file_path`
  and `url` are whitelisted — `file_text` never is. The suite writes a canary string and asserts it never
  reaches the log. This is the line between an audit trail and employee monitoring.
- **The logging hooks always exit zero.** A `PreToolUse` exit of 2 **blocks the tool**, and any
  other non-zero exit warns on every call — a logging failure must never leak out as either. Tested against malformed JSON, empty
  input and a missing log directory. The secret guard is the deliberate exception: it exits 2 on a
  positive match, which is how it blocks, and it fails **open** on any parse error. The upgrade
  guard follows the secret guard's contract exactly: exit 2 only on a positive match, fail open
  on everything else, and it writes nothing.
- **Log directories are mode `1733`** — world-writable so any session can append, sticky so one
  user cannot delete another's record. That is the practical ceiling for an unprivileged append;
  ship the logs off-host if stronger tamper-evidence is required.

**A headless caveat.** `PermissionDenied` fires in interactive sessions, for a `permission_rule`
refusal and for an auto-mode **classifier** refusal alike, so classifier denials reach
`/var/log/claude-code/denied/<user>.jsonl` too. In headless (`claude -p`) sessions the event may not fire, so
an empty denial log from batch testing is not evidence the hook is broken — retest interactively
before concluding anything.

**Scope limit to state honestly:** the secret guard covers Claude's own file tools. It does not
see `python3 -c "open('/x/.env').read()"`, which is a Bash call. That is the same limitation the
permission rules have. Nor does it see `Grep` or `Glob`, which its matcher does not name. The
compensating control for a secret that *is* read is egress: the Bash denies on the network tools
(§3.2) and `autoMode.hard_deny` (§3.6). The OS-level egress control, `strictAllowlist`, is inert
while the sandbox is disabled (§3.5). Layered, not airtight;
record it as an accepted risk.

### 3.8 Data-egress controls (`env`)

**Class: Boundary.** These close the three paths that send conversation content — including code —
to Anthropic *independently of any model request*. None of them is a tool call, so no permission
rule, deny list, classifier rule or sandbox setting touches them. The `env` block is the only
control.

| Variable | Value | Closes |
| --- | --- | --- |
| `DISABLE_FEEDBACK_COMMAND` | `1` | `/feedback`, `/bug`, `/share` — sends conversation history including code, **5-year retention**, and optionally opens a **public** GitHub issue. The highest-risk single path in the product on a host holding customer IP. |
| `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` | `1` | The session-quality survey follow-up: session transcript, subagent transcripts and the raw session log. Known key patterns are redacted; source and file contents are not. 6-month retention. |
| `DISABLE_TELEMETRY` | `1` | Operational metrics. |
| `DISABLE_ERROR_REPORTING` | `1` | Error reports (redacted before leaving the host). |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | Umbrella covering the above. |
| `DISABLE_AUTOUPDATER` | `1` | The background update check. Does real work wherever private per-user installs exist, because they self-update. |
| `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL` | `1` | Automatic plugin-marketplace installation. |

**Two settings keys belong to this class rather than to session mechanics**, for exactly the reason
above — they move content, and no rule reaches them:

| Key | Value | Default when unset | Why it is set |
| --- | --- | --- | --- |
| `autoUploadSessions` | `false` | off | Set in both policies, by decision — off by default, pinned so the default cannot drift. It moves content without being a tool call, which is what puts it in this section |
| `syncClaudeAiSkills` | `false` | **on** — enabled server-side per account, and only `false` is honoured | Set in both policies, by decision. Because only `false` is honoured, an unset key means the sync is running, so "unset" is not a neutral default |

> **What setting `syncClaudeAiSkills: false` does to a user who was relying on it.** Synced skills
> stop running, are hidden from every session started afterwards, and move to
> `~/.claude/skills/.trash` at the next launch, where `cleanupPeriodDays` eventually deletes them.
> Re-enabling re-downloads rather than restores. Announce before applying (§2.1 step 0).

> **The keys are set individually and redundantly on purpose.** The umbrella variable would
> probably cover all of them, but the documentation does not state that it covers `/feedback`, and
> an audit report should show which specific path each key closes. Keeping them explicit makes the
> policy legible to a reviewer who is not going to read the product documentation.

> **Before building on OpenTelemetry:** `DISABLE_TELEMETRY=1` is set. Whether that also suppresses
> an OTLP exporter to an *internal* collector is not documented either way. Do not assume the two
> compose — deploy, run a session, and confirm metrics arrive. If they do not, drop
> `DISABLE_TELEMETRY` and close the Anthropic-bound paths with the three narrower keys instead.

### 3.9 Status line — a shipped default the engineer can replace

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `statusLine` | `{ "type": "command", "command": "bash /usr/local/share/claude-code/statusline.sh" }` | Tunable | Set in managed settings so that every user gets the default with no per-user step — `/etc/skel` reaches new accounts only, and none at all where home directories are not created from it (RUNBOOK §7.8), so managed settings are the one delivery path that reaches everyone. A user's own `statusLine` key is ignored because managed settings are the top precedence tier; the script itself provides the override instead. |

One global script at `/usr/local/share/claude-code/statusline.sh` (0755 root:root, **local disk,
not NFS**): editing it changes the default for every user on the host at once. It renders on every
prompt. The segments and their sources are listed in the script's own header — that header is the
one home for the list.

**The engineer's override.** If `~/.claude/statusline.sh` exists, is a regular file (not a
symlink), is owned by the user and is writable by nobody else, the shipped script hands over to it:
it gets the same JSON on stdin and its output is shown. An empty file hides the status line.
The ownership and mode checks exist because the file runs as the user on every prompt — one a
colleague could edit would let them run commands as that user. `CC_STATUSLINE_USER` names a
different file. The override is a file the default script defers to, rather than a settings key,
because a settings key cannot outrank the managed one.

**What the override is not.** It runs outside Claude's tool calls, so neither the deny rules nor
the audit hook see what it does — exactly as for anything else in the user's own shell. Writing the
file through the agent's Bash tool *is* a tool call and is logged by the audit hook.

**Cost segment is Bedrock-only.** The session cost appears only when `CLAUDE_CODE_USE_BEDROCK` is
set. On a claude.ai subscription a session is not billed per token, so a dollar figure there would
be notional and read as spend. Account-wide AWS spend is deliberately not fetched: it needs AWS
credentials on every host and a network call on every render.

### 3.10 Retention

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `cleanupPeriodDays` | `90` | Tunable — but a decision, not housekeeping | Three times the product default of 30. Transcripts under each home directory are the only record of what the agent did in a project; if the organisation may be asked about work six weeks later, 30 days is already too late. That costs disk on shared storage. The activity log is a durable IT-owned record independent of this, which is what makes a shorter window survivable if disk is tight. **Agree the final number with whoever owns audit and IP obligations** rather than inheriting either value. |

Note that a managed `cleanupPeriodDays` overrides the value `cc-install.sh` seeds into
`/etc/skel` (`14`), so the skel value is inert wherever the policy is deployed — and where home
directories are not created from `/etc/skel` it is never copied at all.

### 3.11 Version control

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `autoUpdatesChannel` | `"stable"` | Tunable | Any path that does update lands about a week behind latest, skipping releases with major regressions. |
| `requiredMinimumVersion` | the pin — `settings/managed-settings.json` | **Boundary, with a people impact** | Claude Code refuses to start below this version — **for every copy of the binary on the host, including private per-user installs** — so moving the floor is a change to other people's tooling. Announce it first and coordinate per `OPERATIONS.md` §3.4; which installs are affected is state (`internal/CURRENT-STATE.md`). **Fail-open: a malformed value is stripped, not enforced**, so validate after every edit or you will believe you have a floor that is not there. |
| `requiredMaximumVersion` | *unset* | Deferred, deliberate | Would hard-stop a newer side install, which is attractive — but it must stay absent for **two independent reasons**: it would stop a private comparison install kept ahead of the pin (`claude-local`, which `cc-bump-audit.sh` reads), and a ceiling at the pinned version would stop the **IDE extension's bundled CLI**, which runs ahead of the fleet pin, breaking the panel for anyone whose wrapper is not in effect (`IDE-INTEGRATION.md` §9). Retiring the comparison install alone does not free this key. Revisit only when neither reason holds. |

### 3.12 Identity

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `forceLoginMethod` | `"claudeai"` | **Boundary** | Pins the login method. Note that `claude setup-token` and `/install-github-app` enforce only this key, not the organisation pin — factor that into how freely token minting is permitted. |
| `forceLoginOrgUUID` | **absent** | **Deferred — see §4.1** | The most significant open item in the policy. |

### 3.13 User-facing text

| Key | Value | Class | Notes |
| --- | --- | --- | --- |
| `companyAnnouncements` | One multi-line entry: the organisation banner, the managed status, what is blocked, the logging, the support address, and where to read more — the installed engineer's guide and Anthropic's quickstart and Team/Enterprise pages | Tunable | Keep **one** array entry: with several, Claude Code shows one per start, so a reader would see a fragment. Keep it consistent with `docs/ENGINEER-GUIDE.md` and the acceptable-use policy on the activity log — a control an engineer discovers by accident costs more trust than it was worth. The guide path is drift-tested against `cc-install.sh` (`docs/REPO-MAP.md`) |

---

## 4. What is deliberately *not* set

### 4.1 `forceLoginOrgUUID` — deferred, and the consequence

The key is **absent**, not blank. A well-formed but wrong organisation UUID refuses **every**
login on the host, so a placeholder would have been an outage with an authentication error rather
than a configuration error.

**What the omission leaves open:**

- A personal Claude account can sign in on this host.
- Environment-credential logins are not blocked — `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
  `apiKeyHelper` would otherwise be refused, because organisation membership cannot be verified
  for an environment credential. A stray API key in a shell profile therefore still overrides the
  Teams subscription, which presents as an authentication failure despite a valid seat. Check
  `~/.cshrc` and `~/.tcshrc` as well as the bash files.

**To close it:** obtain the UUID from claude.ai → Admin settings → Organization, add the key, and
run the §2.1 procedure. Verify by attempting a login with an out-of-organisation account and
confirming refusal. Do not add a placeholder in the meantime.

### 4.2 Other keys deliberately absent

| Key | Why not set |
| --- | --- |
| `permissions.allow` | Posture A's baseline is prompt-on-use, so there is nothing to allowlist. An `allow` list is what Posture B (`dontAsk`) needs. Adding entries here narrows nothing and can widen a lot — prefer a narrow rule, and never one taking arbitrary arguments. |
| `DISABLE_UPDATES` | `DISABLE_AUTOUPDATER` plus `dnf versionlock` already gate the managed path. `DISABLE_UPDATES` blocks manual updates too, which is right only if IT distributes the binary itself. |
| `availableModels` | Model and effort choice is left to the engineer. Constraining it generates support tickets without reducing risk. |
| OpenTelemetry keys | Not deployed. If adopted, the collector must be a host under the site's internal domain and added to the sandbox allowlist, and the `DISABLE_TELEMETRY` interaction must be tested first (§3.8). |
| `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_DETAILS` | Would capture prompts, responses and tool detail. Employee-monitoring implications; involve HR and legal before considering. Deliberately off. |
| `forceRemoteSettingsRefresh` | Only relevant if server-managed settings are ever adopted, which would require revisiting this whole document rather than amending it. |
| `apiKeyHelper` | No API keys in this deployment; authentication is browser OAuth against a claude.ai Team or Enterprise plan. |

### 4.3 Controls that are not in this file at all

Recorded so the boundary of this document is explicit.

| Control | Where it lives |
| --- | --- |
| Connector and MCP restrictions for the Claude desktop and web apps | claude.ai admin settings. Claude Code reads the organisation's per-tool connector settings at startup and enforces them locally, so they apply here too — a tool set to "ask" prompts on every call even in permissive modes. |
| Remote Control and web sessions, organisation-wide | claude.ai Claude Code admin settings. Disallow them there; `disableRemoteControl` is the device-side belt. |
| Windows desktop app policy | Intune, if anything is deployed. See the runbook on residual Windows exposure — the desktop app includes a Code tab and the VS Code extension bundles a private CLI copy, neither of which an installer gate would see. |
| The export policy of network home directories | The file server. Not a Claude Code setting, and none of the controls in this file touch it — but where homes are on a network export, it is where the credentials live. |

---

## 5. Keeping this current

Claude Code ships frequently and settings keys are added often. **A capability the policy does not
mention is a capability the policy does not restrict.** That is why the review below is a
scheduled task rather than a good intention.

| Cadence | Task | How |
| --- | --- | --- |
| After every policy edit | Confirm nothing was stripped | `claude doctor`; `claude auto-mode config` if `autoMode` changed |
| After every policy edit | Re-record the checksum baseline | `cc-install.sh --apply` does it; a hand-edit does not |
| Monthly | Full policy audit for the record | `cc-audit.sh`, filed with the change record |
| Quarterly | Re-verify every key in §3 against the current settings reference at code.claude.com; look for **new** keys that need a position | Manual review. New keys land in the §6 inventory with a position; keys we adopt move to §3. Update the front matter |
| Quarterly | Review the deny and ask lists against what engineers actually needed | The denial log is the only source for this — the telemetry metric covers code-editing tools only and misses blocked Bash commands |
| Before every version bump | Re-read the release notes for changes to settings keys, permission semantics and sandbox behaviour | These are the changes that silently alter the policy |
| Before every version bump | Take a `cc-audit.sh` report, bump, take another, diff | A new version can introduce a key the policy does not yet set |

**When Anthropic changes the product.** Three classes of change matter, in increasing order of
effort: a *new key* means deciding a position and adding it here; a *changed default* means the
policy may now permit something it did not; a *changed semantic* — a rule syntax, a precedence
order, a sandbox behaviour — means re-testing the controls rather than re-reading the file. The
pre-release validation checklist in the runbook is the re-test, and it exists so that this can be
answered by observation instead of argument.

---

## 6. The full key inventory — everything that exists, set or not

**A capability the policy does not mention is a capability the policy does not restrict** (§5) —
so this section lists every settings key the product recognises, not just the ones we set. Keys
we set are documented in §3; this inventory records our **position** on everything else, so "what
could we change?" is answerable from this file alone. The §5 quarterly review maintains this
section; source: the vendor settings reference at code.claude.com, cross-checked against the
pinned binary. Keys marked **▲** are **not available at the pin**: the pinned build does not
recognise them, so a policy that sets one is silently fail-open. The flag is a yes/no about the
pin, not a version note — which build introduced a key belongs in [`UPGRADES.md`](UPGRADES.md).
Every ▲ is re-adjudicated at each bump against the **shipped schema** — the settings schema read
out of the installed binary, cross-checked against any newer build kept for comparison —
never against the vendor documentation alone: the documentation describes builds ahead of the pin.
Two traps in that adjudication: **a name in the binary's strings is not necessarily a
settings key** (`modelPicker` at the pin is a keybinding context, not a key), and **a key the
documentation lists and no schema contains gets no position at all** rather than a flag.

**Positions:** `SET §3.x` = we set it, see that section. `default` = unset on purpose, the default
is acceptable. `decide` = a position is owed — candidates for the next policy review.

### 6.1 Security-relevant keys we do not set

| Key | Default when unset | Position | Note |
| --- | --- | --- | --- |
| `forceLoginOrgUUID` | any org accepted | **decide** | Deliberately absent — a wrong UUID refuses every login host-wide (§4.1) |
| `requiredMaximumVersion` | no ceiling | **default, deliberate** | Must stay absent wherever a build above the floor is kept for evaluation (§3.11) |
| `permissions.allow` | none | **default, deliberate** | We grant via `autoMode.environment` + ask list instead; an `allow` rule is prompt-free forever |
| `deniedMcpServers` / `enabledMcpjsonServers` / `disabledMcpjsonServers` | unused | **default** | The granular MCP road: if one vetted server is ever needed, allow it by name here rather than weakening the §3.4 blanket |
| `enableAllProjectMcpServers` | off | **default** | Never set to true — it auto-approves whatever a project's `.mcp.json` names |
| `strictKnownMarketplaces` / `blockedMarketplaces` / `extraKnownMarketplaces` | no marketplaces | **decide** when skills are distributed centrally | The allow-list mechanism for a site-curated plugin marketplace |
| `disableBundledSkills` / `skillOverrides` | bundled skills on, all visible | **decide** — skills are user-authorable (§3.4) | Per-skill visibility control |
| `disableSkillShellExecution` | skills may run inline shell | **decided: leave unset** (the maintainer) | Skills exist to drive build and test tools, so they need shell. Setting it would break the primary use case while adding nothing: a skill's shell runs inside the same permission fence as any Bash call — deny list, classifier and audit hook all still apply |
| `allowedHttpHookUrls` / `httpHookAllowedEnvVars` | n/a (hooks locked) | **default** | Moot while `allowManagedHooksOnly` is true |
| `disableAllHooks` | off | **never set** | Blanket that would kill our own audit hooks and status line |
| `apiKeyHelper` / `proxyAuthHelper` / `awsCredentialExport` / `awsAuthRefresh` / `gcpAuthRefresh` / `otelHeadersHelper` | unset | **default** | Credential-helper commands; none is used by this policy. `proxyAuthHelper` outputs a `Proxy-Authorization` header and becomes relevant only with authenticated egress filtering |
| `policyHelper` / `policyHelpers` | none | **default** | Dynamic managed-settings helpers; our policy is a static file by design. `policyHelpers` is the per-OS variant, and one of its entries may be a *static settings payload* rather than a helper — so it is a second way a managed policy could arrive. Both are honoured only from admin-controlled policy sources |
| `managedSourcesBehavior` ▲ / `parentSettingsBehavior` / `forceRemoteSettingsRefresh` | first-wins (the highest source alone) / first-wins (an SDK-supplied parent tier is dropped) / no block | **default** | Neither behaviour key defaults to a merge: the highest-priority managed source is the managed tier by itself, and a parent tier supplied through the SDK is discarded rather than layered underneath. This deployment has one managed source (the file); the claude.ai console must stay EMPTY (§7.3 of the runbook) |
| `disableCommandPluginSources` | unset, and unset follows `allowManagedHooksOnly` — so closed here, because we set that `true` | **decide** | Available at the pin, managed-only, and it covers exactly one path: a marketplace plugin source whose plugin directory is produced by *running a marketplace-declared command* on this machine. The inheritance is in the resolver rather than only in prose — unset falls through to `allowManagedHooksOnly`, and a value that fails validation is treated as `true`. It does **not** reach an MCP server's `headersHelper`, which is held by the workspace-trust check instead. Setting it explicitly changes no behaviour — the value is that the file names the path, which is what §5 asks of an audit trail. |
| `syncClaudeAiPlugins` ▲ | on, same server-side gating | **decide before the bump that brings it in** | The plugin sibling of `syncClaudeAiSkills` (set `false`, §3.8), with the same one-way semantics, into `~/.claude/plugins/synced`. A synced plugin loads like one installed by hand, so it is new **tool surface** rather than instructions — a stronger case for `false` than the skills key has, and a position is owed *before* it becomes settable rather than after, so that it is never on for a window |
| `allowedMarketplaces` / `additionalMarketplaces` | none | **default — never set** | Aliases for `strictKnownMarketplaces` / `extraKnownMarketplaces`. Prefer the canonical spellings: clients too old for the alias ignore it, and a private install below the floor or an IDE-bundled CLI is such a client. |
| `sshConfigs` | none | **default** | Named SSH connection profiles. Claude-driven SSH is governed by the Bash rules regardless — and there is **no** companion host-allowlist key to pair with it: `sshHostAllowlist` appears in no build's schema, so it carries no position rather than a ▲ |
| `allowAllClaudeAiMcps` | off — the managed MCP lockdown holds | **default — never set** | Managed-only, and **the single key that reopens what §3.4 closes**: `true` lets claude.ai cloud MCP connectors load *alongside* the managed allowlist instead of being suppressed by it. Nothing to do here except know it exists |
| `enabledPlugins` / `pluginConfigs` / `pluginTrustMessage` / `pluginSuggestionMarketplaces` | no plugins enabled; no suggestion marketplaces | **default** | Policy scope wins the plugin precedence chain, so these are the levers if a site marketplace ever lands. `pluginTrustMessage` is managed-only and appends organisation text to the pre-install trust warning |
| `forceLoginGatewayUrl` | unset | **default, moot** | Read only alongside `forceLoginMethod: "gateway"`; we pin `"claudeai"` |
| `subagentStatusLine` | none | **default** | A per-subagent status line. §3.9's argument for a fleet-managed status line has not been made for this one |
| `wslInheritsWindowsSettings` | off | **default, not applicable** | Admin-only opt-in making WSL read the whole Windows policy chain in addition to `/etc/claude-code`. Listed because residual Windows exposure can be a live item, not because a Linux host can set it |
| `disableRemoteControl` | off | **SET §3.4** | Listed for completeness — already a lock |
| `processWrapper` | none | **default** | Corporate launcher hook for background processes; unused |
| `sandbox.*` tree (filesystem / network / credentials lists) | n/a — `sandbox.enabled: false` | **default, moot** | The granularity that would make any future re-enable surgical; `SANDBOX-DECISION.md` owns that door |

### 6.2 Operational keys we do not set

| Key | Default | Position | Note |
| --- | --- | --- | --- |
| `model` / `availableModels` / `enforceAvailableModels` / `fallbackModel` / `modelSettings` ▲ / `modelOverrides` / `modelPicker` ▲ / `modelPricing` ▲ / `effortLevel` / `advisorModel` | product defaults | **default** | Model choice is left to engineers; revisit if seat cost or consistency becomes an issue |
| `alwaysThinkingEnabled` / `fastMode` / `fastModePerSessionOptIn` / `promptCacheTtl` ▲ / `subagentPromptCacheTtl` ▲ | product defaults | **default** | Performance/cost dials |
| `autoContinueAtUsageLimit` | **on** when unset | **default, deliberate** | A recorded decision: **left unset on purpose, which leaves it on.** When a usage limit stops a session it waits for the reset and carries on rather than offering the wait as a choice; that only arises on subscription billing, which is what `forceLoginMethod` pins, and every deny and `ask` rule still binds while it waits. The unattended resume was weighed against the human-in-the-loop premise and accepted. **Setting `true` was considered and rejected**, because it would change no behaviour and would remove the `/config` row — an engineer could then not turn it off for a single session, which is the one case where somebody wants to babysit a run. This is not a security boundary, and `RUNBOOK.md` §7.7's rule applies: lock what constitutes the boundary, leave the rest. Revisit only if the vendor changes the default |
| `autoMemoryEnabled` | **on** | **default** | Memory lands under `~/.claude` in the user's home — same exposure class as transcripts, and covered by the same home-directory permissions |
| `autoMemoryDirectory` | `~/.claude` | **default** | Same note |
| `autoCompactEnabled` / `autoCompactWindow` / `fileCheckpointingEnabled` | on / product / on | **default** | Session mechanics |
| `claudeMd` / `claudeMdExcludes` | none | **decide someday** | `claudeMd` could carry org-wide instructions from the policy itself — a lighter-weight companion to the repo CLAUDE.md |
| `attribution` (`{commit, pr, sessionUrl}`) | product trailer | **decide** | The modern replacement for `includeCoAuthoredBy` (deprecated; still in the skel seed — migrate on next skel touch) |
| `includeGitInstructions` / `prUrlTemplate` | product defaults | **default** | |
| `cleanupPeriodDays` | **SET §3** (90) | — | Listed for completeness |
| `desktopSessionCleanupPeriodDays` ▲ / `feedbackSurveyRate` / `feedbackDrafts` | product defaults | **default** | The Desktop app is outside this deployment (§4.3) |
| `minimumVersion` | none | **default** | Auto-update floor only — the enforced floor is `requiredMinimumVersion` |
| `disableAgentView` / `enableWorkflows` / `disableWorkflows` | on / on | **default** | Background agents and workflows are governed by the same permission layer |
| `enableArtifact` / `disableArtifact` | on | **default** | Both are recognised at the pin. Resolution walks policy → flag → user and stops at the first scope that sets either, so a managed value wins outright and also hides the `/config` row; there is **no** exception that lets a `false` from a lower scope beat a managed `true`. |
| `crossSessionInbound` / `isolatePeerMachines` / `remoteControlAtStartup` / `agentPushNotifEnabled` / `inputNeededNotifEnabled` | product defaults | **default** | Remote Control itself is disabled (§3.4) |
| `channelsEnabled` / `allowedChannelPlugins` | product defaults | **default** | Channel notifications are a managed-org opt-in and nothing here uses them. The desktop-session, mobile-simulator and browser-pane keys the vendor documentation lists beside these are **not in the shipped settings schema** — not at the pin, and not in a newer build kept for comparison — so they carry no position at all rather than a ▲. `disableMobileSimulatorTools` is a retired key of the separate enterprise flat-config surface, not a settings key |
| `disableDeepLinkRegistration` / `skipWebFetchPreflight` / `respectGitignore` / `fileSuggestion` / `plansDirectory` / `showClearContextOnPlanAccept` | product defaults | **default** | |
| `useAutoModeDuringPlan` / `skipAutoPermissionPrompt` / `skipDangerousModePermissionPrompt` / `disableAutoMode` | product defaults | **default** | `permissions.defaultMode` and the auto-mode config are SET (§3). The two `skip*` keys are consent flags the product writes once a user has accepted a dialog, not knobs to set from policy |

### 6.3 Cosmetic and per-user keys — deliberately left to engineers

`editorMode`, `keybindingFlavor`, `defaultShell`, `language`, `outputStyle`, `axScreenReader`,
`prefersReducedMotion`, `syntaxHighlightingDisabled`, `spinnerTipsEnabled`, `spinnerTipsOverride`,
`spinnerVerbs`, `showTurnDuration`, `showThinkingSummaries`, `promptSuggestionEnabled`,
`emojiCompletionEnabled`, `autoScrollEnabled`, `awaySummaryEnabled`, `preferredNotifChannel`,
`respondToBashCommands`, `askUserQuestionTimeout`, `footerLinksRegexes`, `spellcheck`,
`skillListingBudgetFraction`, `skillListingMaxDescChars`, and the `.claude.json`-only keys
(`autoConnectIde`, `autoInstallIdeExtension`, `diffTool`, `externalEditorContext`). Personal
preference by design — nothing here can override a managed key (§1.2).

### 6.4 Environment-variable-only controls

No settings-file key exists for these; a managed `env` block can pin them fleet-wide:

| Variable | Our state | Note |
| --- | --- | --- |
| `DISABLE_TELEMETRY`, `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL` | **SET** in the policy `env` block (§3) | |
| `CLAUDE_CODE_TOOL_MEMORY_LIMIT` | unset | **decide** — a memory cgroup cap for Bash tool commands on Linux, e.g. `4G`. A stability control rather than a security one, and this is a shared workstation where one runaway build stalls everyone. |
| `CLAUDE_CODE_ENABLE_TODO_TOOLS` | unset | `=1` restores the Task/Todo tools, which current models do not carry. Leave unset; useful to know when a user asks where their todo list went. |
| `CLAUDE_CODE_FORK_SUBAGENT` | unset | `=0` opts out of subagent forking, the default in interactive sessions. A fork inherits the conversation but runs inside the same permission fence, so this is a behaviour note, not a control. |
| `CLAUDE_CODE_WEBFETCH_CACHE_TTL_MS` / `CLAUDE_CODE_PROJECT_DIR_NAME` / `CLAUDE_CODE_GOAL_CHECKIN_MINUTES` | unset | WebFetch cache TTL, per-project transcript directory name, `/goal` check-in interval. No position needed. |
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | unset | **decide** — strips Anthropic/cloud credentials from all subprocesses; attractive on a shared host, test for build-tool breakage first |
| `CLAUDE_CONFIG_DIR` | unset | Relocates `~/.claude` wholesale; leave unset — transcript/credential paths are load-bearing facts elsewhere |
| `CLAUDE_CODE_PLUGIN_SEED_DIR` / `PLUGIN_CACHE_DIR` / `PLUGIN_PREFER_HTTPS` / `PLUGIN_KEEP_MARKETPLACE_ON_FAILURE` | unset | Relevant only where a plugin marketplace is used |
| `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_MODEL` | unset | Per-session model override; engineer's own |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | unset | Becomes relevant with egress filtering |
| `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` | unset | Embedding-host concern; not applicable |

*Prepared against the pinned build and the policy in `settings/`. Companion documents:
`RUNBOOK.md` (decisions and reference), `LOCAL-VS-AWS.md` (shared host against per-user desktop),
`SANDBOX-DECISION.md` (why the sandbox is disabled).*
