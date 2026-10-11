# The privileged admin session — `claude-admin`

| | |
| --- | --- |
| **What** | The `claude-admin` mechanism: a Claude Code session for an authorised administrator that may run administrative commands, without weakening the policy every other user on the host receives — how it works, what it changes, who may use it, and how it is audited |
| **Who** | Administrators launching a privileged session, and anyone maintaining the mechanism. Assumes a built governed host (`QUICKSTART.md`); no namespace knowledge is assumed |
| **When** | Against the **pinned build** (`requiredMinimumVersion` in `settings/managed-settings.json`; [`UPGRADES.md`](UPGRADES.md) for the history) |
| **Where** | Any governed host placed with `cc-install.sh --with-admin`; a host built without the flag has neither the admin policy nor the launcher. Which hosts have it is recorded in `internal/CURRENT-STATE.md` |
| **Why** | Canonical home for the admin-session mechanism (`DOC-STYLE.md` §4). What is placed on a particular host is a state fact, owned by `internal/CURRENT-STATE.md` and not restated here |
| **Status** | The mechanism ships and is covered by the test suite. The sudoers grant that lets an administrator reach it is not installed by `cc-install.sh`; each site adds it by hand (§5) |
| **Owner** | The maintainer |

---

## 1. The problem it solves

Managed settings are the top precedence tier and cannot be overridden by user settings, project
settings, CLI flags or environment variables. That is the point of them — but it means an
administrator has no way to get a session that can run `sudo`, `dnf` or `systemctl`, because the
fleet policy denies those absolutely.

Managed settings also have no per-user conditionals. There is one policy per host.

## 2. Mechanism

`/etc/claude-code/managed-settings.json` is a fixed path — but a path is only fixed *within a
mount namespace*. `cc-admin-session.sh`, running as root, creates a private mount namespace,
bind-mounts the admin policy **file** over the fleet policy file, then drops to the target user
and execs `claude`:

```
unshare --mount --propagation private
  └─ mount --bind /etc/claude-code-admin/managed-settings.json \
                  /etc/claude-code/managed-settings.json
     (the admin policy's authored source is settings/managed-settings-admin.json
      in the repository; cc-install.sh --with-admin places it)
      └─ runuser -u <user> -- env HOME=<real home> /usr/bin/claude
```

Consequences:

- Only that process tree sees the admin policy. Every other session on the host, including other
  users logged in at the same time, continues to read the strict fleet policy.
- **Nothing on disk changes**, so the `cc-install.sh` checksum baseline and `cc-healthcheck.sh`
  both stay clean. No window during which a concurrent session could pick up the wrong policy.
- The mount is `--propagation private`, so it cannot leak back into the host mount table.

### Two implementation details that are not optional

**Bind the FILE, not the DIRECTORY.** `/etc/claude-code-admin` is `0700 root:root` so it cannot
be browsed. Bind-mounting that directory over `/etc/claude-code` makes the policy unreadable to
the unprivileged target user — they cannot traverse a `0700 root` directory — and Claude Code
fails at startup with:

```
Unable to read managed policy settings.
Detail: /etc/claude-code/managed-settings.json: EACCES: permission denied, stat
```

Binding the file means path traversal uses the normal `0755 /etc/claude-code` and only the
file's own `0644` mode applies. The admin directory stays `0700`, and the other contents of
`/etc/claude-code` (`approved-version`, the checksum baseline) remain visible so the `cc-*`
scripts behave normally.

**`unshare --mount` only — never `--user`.** A user namespace is precisely what remaps root to
`nobody` and breaks setuid, which would make `sudo` fail inside the very session created to run
it. With a mount namespace alone, `sudo -n id` inside an admin session returns `uid=0(root)`.

## 3. What it changes, exactly

The sandbox is disabled fleet-wide (`SANDBOX-DECISION.md`), so the admin session is
**purely a permissions difference**. Computed diff between the two policies:

| | fleet | admin |
|---|---|---|
| `permissions.deny` | the full list (`SETTINGS-REFERENCE.md` §3.2) | **9 rules** |
| `allowManagedPermissionRulesOnly` | `true` | `false` — admin may add session-scoped rules |
| `forceLoginMethod` | `claudeai` | **absent** — admin may change logins |
| `permissions.ask` | `git push`, `git remote`, `docker`, `podman` | `rm -rf`, `dd`, `mkfs`, `git push` |
| `companyAnnouncements` | The organisation banner and "managed Claude Code", with the engineer's guide and links | "*** PRIVILEGED ADMIN SESSION ***" |
| `sandbox` | `{enabled:false}` | `{enabled:false}` — **identical** |
| `hooks`, `env`, `statusLine`, `requiredMinimumVersion`, `cleanupPeriodDays`, `allowManagedHooksOnly`, `allowManagedMcpServersOnly`, `disableSideloadFlags`, `strictPluginOnlyCustomization`, `disableRemoteControl`, `autoUpdatesChannel` | | **identical** |
| `autoMode` | | `hard_deny` and `classifyAllShell` identical; ONE `environment[]` entry differs, naming the session privileged so the classifier judges shell against what it can actually do |

The fleet rules dropped in the admin policy (the test suite checks this list against both policy files):

```
Bash: sudo su dnf yum rpm systemctl firewall-cmd useradd usermod passwd
      curl wget nc ncat ssh scp rsync aws
Read: //etc/claude-code/**  //etc/sudoers  **/.env  **/*.pem
      **/id_rsa*  **/id_ed25519*
Edit: //etc/**  //usr/**  //opt/**  ~/.bashrc ~/.bash_profile ~/.profile
      ~/.cshrc ~/.tcshrc ~/.ssh/**  ~/.local/bin/**
      ~/.claude/settings.json  ~/.claude/settings.local.json
mcp__*
```

What the admin policy **keeps** deliberately:

- Every managed hook — audit, secret-guard, denial, upgrade-guard, redaction. An admin session is the one that most needs an
  evidence trail.
- `strictPluginOnlyCustomization: ["hooks", "mcp"]`, the fleet policy's granular value. Hooks and
  MCP servers stay plugin/managed-only — the admin session is the last place that should load
  someone else's auto-executing code — while **skills and agents load from user and project
  sources**, so the repository's own skills (`version-bump`, `repo-audit`, `fleet-drift`, …) work
  in an admin session exactly as they do in a fleet one. Skills and agents are instructions: they
  inherit this session's permission envelope and cannot widen it (`SETTINGS-REFERENCE.md` §3.4)
  — which in an admin session is a larger envelope, hence the hooks/MCP half staying shut.
- `Read(~/.ssh/**)`, `~/.aws/**`, `~/.gnupg/**`, `~/.claude/.credentials.json`, `//etc/shadow` —
  an admin has no reason to have *the agent* read private keys. They can still read them
  themselves outside Claude.
- `Edit(//etc/claude-code/**)`, `Edit(//etc/claude-code-admin/**)` and
  `Edit(//usr/local/sbin/cc-*)` — stops an admin session widening its own permissions mid-flight,
  whether by editing a policy or by editing the operator scripts and hooks that enforce it.
  **Note the consequence: you cannot apply policy changes, or edit the `cc-*` scripts, from inside
  an admin session.** That is intentional. Run those from a plain shell.
- `Bash(chmod 777 *)` — the one Bash deny the admin policy keeps, because there is no
  administrative task that needs it and it silently undoes the mode invariants the health check
  asserts.
- `autoMode` with `classifyAllShell: true`, so admin commands are still classified and logged.
- `disableBypassPermissionsMode: "disable"`, so genuinely destructive commands still prompt.
  With the administrative denies already removed, you get a prompt rather than a block — which is
  the intended admin experience. For an unattended run, delete that key and set
  `defaultMode: "bypassPermissions"`.

## 4. Usage

On the host, from a real terminal, as an account authorised per §5:

```
claude-admin                 # normal use
claude-admin -n              # dry run: show what would happen, mount nothing
# -u exists but only ever names the invoker; any other target, and uid 0, are REFUSED
claude-admin -- <claude args>
```

**Pass:** the session opens showing the `*** PRIVILEGED ADMIN SESSION ***` announcement (§3), and
a `START` line is stamped to `/var/log/claude-code/admin.log` (§6).
**Fail:** a `REFUSED` line in `admin.log` means the invoker failed the
`CC_ADMIN_GROUP`/`CC_ADMIN_USERS` gate; a sudo denial or password failure means no sudoers entry covers `cc-admin-session.sh`. Both
are access-control conditions — see §5.

`/usr/local/sbin/claude-admin` — beside the script it wraps; if `/usr/local/sbin` is not on an
administrator's login `PATH`, call it by full path — is a thin wrapper that execs
`sudo /usr/local/sbin/cc-admin-session.sh "$@"`. It is **not** setuid; all authorisation lives in
sudoers and in the script.

**Must be run from a real terminal (RDP/SSH), never from `!` inside Claude Code.** Nested
invocation is not supported.

## 5. Access control

Four layers:

1. `/usr/local/sbin/cc-admin-session.sh` is `0750 root:root`, and the script refuses unless
   `EUID == 0`. An ordinary user cannot execute it.
2. **sudoers is therefore the real gate.** Understand what this means: anyone with unrestricted
   sudo can already edit `/etc/claude-code/managed-settings.json` directly, so the wrapper grants
   such a user nothing new — it is a narrower, logged, non-destructive route to a privilege they
   already hold.
3. **Escalation risk to avoid:** never add bare `unshare`, `mount` or `runuser` to a
   *command-scoped* sudo grant. Each is a full root escape from a narrow grant.
   `cc-admin-session.sh` is the deliberate exception, and only because it enforces its own
   target-user policy: the agent runs as the invoker, never uid 0, never another account. Without
   that enforcement `-u root` makes a one-command grant equivalent to unrestricted root, which is
   exactly the escape this item warns about. Verify the wrapper's header carries the
   `TARGET-USER POLICY` block before granting it, and pair the grant with `NOSETENV:` — the
   wrapper's loader honours `$CC_CONFIG_LIB` first and sources it as root.
4. Second gate inside the script: the **invoker** (`SUDO_USER`, not the `-u` target) must be in
   the admin group (`CC_ADMIN_GROUP`, `cc-admins` unless `config.sh` says otherwise) or in the
   `CC_ADMIN_USERS` list. Refusals are logged. If the list is empty and the group does not
   resolve, nobody can open a privileged session — fail-closed, and `cc-install.sh --with-admin`
   warns about it.

`cc-install.sh --with-admin` installs **no sudoers rule**. Until a site adds one, `claude-admin`
works only for accounts that can already run `cc-admin-session.sh` through sudo. Who is enrolled
on a given host is recorded in `internal/CURRENT-STATE.md`.

To give the admin group access on a shared host, add (and validate with `visudo -cf`):

```
%cc-admins ALL=(root) PASSWD:NOSETENV: /usr/local/sbin/cc-admin-session.sh
```

`PASSWD:` rather than `NOPASSWD:` is the shared-host position, for one reason: on a shared host
the invoker may hold other sudo rights, some of them passwordless, and a password on this one
command is then the only thing that makes opening a privileged session a deliberate act rather
than something a subprocess can do silently.

The per-user desktop position differs and is not a contradiction: there the admin holds **no
other sudo at all**, so there is nothing beside the rule for a password to guard, and a prompt
would only hang non-interactive admin work — `aws/sudoers.d/cc-admins-admin-session` therefore
ships `NOPASSWD:NOSETENV:`. Both positions are reconciled in `docs/LOCAL-VS-AWS.md` §8.4; do not
change one without the other.

With the wrapper's target-user policy in force this grant is **not equivalent to unrestricted
root** — the agent cannot be run as uid 0 or as another account. It remains a grant to open a
session in which `sudo` is permitted, so the invoker can still escalate deliberately as themselves;
give it only to people you would trust with sudo.

The script additionally validates at launch, in this order: the invoker is authorised (§5), the
**target-user policy** holds (the agent runs as the invoker — never uid 0, never another account),
the admin policy directory is `0700 root`, the policy file is `0644 root root`, the admin policy
is valid JSON, and `HOME` resolves to an existing real path (a home published as a symlink is
resolved, for the reason `profile.d/claude-code-home.sh` gives). The binary it will run must
exist and be executable.

Authorisation and the target-user policy are checked **first and in that order**, before any
filesystem or JSON check, so that neither can be masked by unrelated drift (a policy directory at
the wrong mode, say) and so each writes its own `admin.log` line before anything else can fail.
An unauthorised invoker passing `-u root` is recorded as unauthorised, which is the more serious
fact, rather than as a target-user violation.

## 6. Audit

Every launch **and every refusal** is stamped to `/var/log/claude-code/admin.log`. All lines share
one shape — `timestamp pid= invoker= target= tty=` then a message — so a single `awk` reads the
whole file regardless of line kind. Refusals carry a `reason=` key (`unauthorised`, `uid0`,
`impersonation`):

```
<UTC timestamp> pid=<pid> invoker=alice target=alice tty=/dev/pts/2 admin session START bin=/usr/bin/claude eval=0
<UTC timestamp> pid=<pid> invoker=alice target=alice tty=/dev/pts/2 admin session END rc=0
```

Refusals are logged the same way with `REFUSED`. Tool calls continue to land in
`/var/log/claude-code/activity/<user>.jsonl` and denials in `denied/<user>.jsonl`, exactly as for
a fleet session — the hooks are identical.

## 7. Files

What is placed on a particular host — the launcher, the session script, the admin policy
directory and file, the admin group, and `admin.log` — is recorded in
`internal/CURRENT-STATE.md`. This document does not restate it.

The one fact this document owns: the `/usr/local/sbin/claude-admin` launcher has **no source file
in the repository** — `cc-install.sh --with-admin` places the admin policy, its `0700` directory
and `cc-admin-session.sh`, but not this wrapper. It is created by hand, and this
is its content:

```bash
#!/bin/bash
# claude-admin - convenience entry point for a privileged Claude Code session.
# Thin wrapper only: ALL authorisation lives in sudoers plus the CC_ADMIN_GROUP /
# CC_ADMIN_USERS gate inside cc-admin-session.sh. This file is NOT setuid, so a user
# without a sudo grant for cc-admin-session.sh is simply refused by sudo.
exec sudo /usr/local/sbin/cc-admin-session.sh "$@"
```

Two things assert the `0700 root:root` directory mode, and they answer different questions.
`cc-admin-session.sh` self-checks it at launch and refuses otherwise — fail-closed, but it only
speaks to whoever tried to open a session, at the moment they needed one. `cc-healthcheck.sh`
check **[2d]** is the standing version: it runs daily on the timer and gives three distinct
answers — directory absent (a skip, because a host built without `--with-admin` has no admin
policy), `0700 root:root` (named as checked), or anything else (flagged, with the `chmod`/`chown`
to fix it, and a non-zero exit so `systemctl --failed` surfaces it). It checks the policy file's
`0644` in the same block, because tightening *that* breaks the session rather than securing it.

The directory mode carries the whole control here — the file is deliberately world-readable
(§3) — so it matters what could re-open it: an installer that creates the parent with
`install -d -m 0755` applies that mode to a directory that already exists, undoing the `0700` set
a moment earlier in the same step. `cc-install.sh` therefore creates a parent directory only when
it is absent, and re-reads the admin directory's mode after writing the policy into it, reporting
a failure if it is not `0700 root`. A change to any of these scripts is made in the repository
copy under `bin/`: the next `cc-install.sh --apply` replaces the installed copy.

## 8. Known gap

`/etc/claude-code-admin/managed-settings.json` omits `forceLoginOrgUUID`, as the fleet policy
does (`SETTINGS-REFERENCE.md` §4.1). When the org UUID is supplied, **add it to both
files** — otherwise the admin session becomes the one place on the host where a personal Claude
account can sign in.
