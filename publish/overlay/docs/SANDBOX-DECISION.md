# Decision record — the sandbox ships disabled

| | |
| --- | --- |
| **What** | Why the policy in this template sets `sandbox.enabled` to `false`, what that costs, what must replace it, and the conditions under which a site turns it on |
| **Who** | The maintainer deciding the `sandbox.*` keys for a site. Knowledge of Linux user namespaces is assumed |
| **When** | Against the pinned build — `requiredMinimumVersion` in `settings/managed-settings.json`. Re-test §2.3 at each version bump |
| **Where** | Every host the policy is installed on |
| **Why** | The sandbox is the one control in the policy that is off by default, and a reader who finds it off needs the reasons and the way back in one place |
| **Status** | The shipped default. A site that reaches a different decision replaces this record with its own, in the same shape |
| **Owner** | The maintainer |

This document is the authoritative account. Where any other document in this repository
disagrees about the sandbox, this one wins.

---

## 1. The decision

`sandbox.enabled` is `false` in the policy. Everything else in the policy is unchanged: the deny
and ask lists, both hook events, the auto-mode classifier, managed-rules-only, the bypass-mode
lock, the version floor, retention and telemetry settings (`SETTINGS-REFERENCE.md` holds each key).

## 2. Why — reasons that each stand alone

### 2.1 It must be proven per host before it is relied on

The sandbox depends on unprivileged user namespaces, a helper binary and the host's kernel and
security-module configuration. The same build can start it on one host and fail on another.
`bin/cc-preflight.sh` reports what a host offers; the only proof is the test in §4.

### 2.2 A failure has to be diagnosed on the real code path

When the sandbox fails to start, test the mechanism the product uses, not a look-alike: a
stand-alone namespace tool succeeding or failing says little about the product's own helper.
Compare against a host where the same build works before naming a root cause.

One failure of this class is known: every Bash command fails with
`apply-seccomp: unshare(CLONE_NEWUSER): Invalid argument` while a stand-alone `bwrap` works.
The failing step is the product's own helper. Its cause is not established here; a site that
meets it records what it finds in its own `CURRENT-STATE.md`, and the conditions in section 4
apply before the sandbox is enabled on that host.

### 2.3 It fits shared engineering hosts poorly

A sandbox narrow enough to mean something breaks ordinary work on a host where tools write to
project trees, the home directory and the temporary directory:

- **Write paths.** Tools that keep state under `$HOME`, write lock files under `/tmp`, or build
  inside a project tree fail unless each of those is listed in `allowWrite`. The session's
  working directory is always writable, whatever `allowWrite` says.
- **Read paths.** With `allowManagedReadPathsOnly: true` every new project mount needs a policy
  change.
- **The network cannot be switched off, only narrowed.** With `allowedDomains`, HTTP(S) reaches
  the listed hosts through a relay; raw TCP never leaves the sandbox, even to an allowed host. A
  client that speaks its own protocol — a database client, a message-queue client, `ssh` —
  works only when its command is listed in `excludedCommands`, and a command listed there runs
  with no sandbox at all.
- **`excludedCommands` takes the whole command line out.** A command chained to an excluded one
  runs unsandboxed too; a wrapper that calls the excluded tool stays sandboxed and the call fails.
- **Behaviour differs between builds.** Whether a `!` command typed by the user is sandboxed has
  changed between versions. Re-test it at each bump.
- **Permission deny rules are not a substitute.** A rule such as `Read(~/.ssh/**)` denies a
  command whose text names the path; a script that opens the same file is not stopped. Only the
  sandbox enforces paths on the programs a command starts.

Widened enough for real work, the sandbox still keeps credentials in `~/.ssh` unreadable and the
network narrowed. It does not contain writes inside the work trees, or anything
`excludedCommands` lets out.

### 2.4 A user can step outside it

Unprivileged user namespaces must stay enabled for the sandbox to work. A user can use the same
feature to enter a namespace, bind their own file over the managed policy, and start an
unsandboxed session. Closing that needs `user.max_user_namespaces=0`, which disables the sandbox
for everyone. So with the sandbox off, set that value to `0` (`bin/cc-preflight.sh` checks it);
with the sandbox on, accept that it binds only users who are not trying to avoid it.

## 3. What is lost, and what replaces it

Two real losses:

**(a) Filesystem containment of subprocesses.** Deny rules and the secret-guard hook inspect the
session's own tool calls: a command string, a file path. They do not see inside a running
process. A script that opens a credential file matches no rule.

**(b) Kernel-enforced network deny-by-default.** The deny list still blocks the common transfer
tools. An interpreter that opens a socket itself matches no rule.

Compensating controls, in order of value:

1. **Egress filtering at the firewall or proxy.** It covers every process on the host and no
   user can step around it. Put it in place before widening use beyond a pilot.
2. **POSIX permissions and ACLs.** Home directories closed to other users; group ownership and
   ACLs decided on shared project trees. This is the control that separates one project's data
   from another's, and it never depended on the sandbox.
3. **The secret-guard hook.** It catches the session's own attempts to read credential-shaped
   files.
4. **No passwordless `sudo` for accounts that run sessions.** With the sandbox off, a script a
   session runs can call `sudo` successfully for an account that needs no password. Requiring a
   password stops non-interactive `sudo` from a subprocess.

| Adversary | Effect of running without the sandbox |
| --- | --- |
| Careless or curious user | None: POSIX permissions are the control |
| Determined insider | None: they could leave the sandbox anyway (§2.4) |
| Prompt injection, or a confused agent | A real loss, reduced by the deny list, the secret guard, the classifier and firewall egress |

## 4. Conditions for enabling

All of these first:

1. On each kind of host, a **fresh session** under the site policy with `sandbox.enabled: true`
   runs `echo hi` successfully. That test is the gate.
2. `allowWrite` covers the project trees, `$HOME` and the temporary directory the site's tools
   need, and `allowManagedReadPathsOnly` is decided.
3. Every tool that needs raw network access is listed in `excludedCommands`, accepting that it
   runs unsandboxed and that the firewall owns the network boundary for it. A `PreToolUse` hook
   denies any compound command that contains an excluded one (§2.3).
4. A `!` command is re-tested for containment on the build being enabled (§2.3).
5. One volunteer runs real work under it for a week before it goes to every host.

## 5. Reporting a defect upstream

Report a sandbox failure to the vendor only when it reproduces on the real code path (§2.2) and
there is a contrasting host where the same build works. Include both hosts' kernel build and
security-module mode.

## 6. Evidence

A site keeps the evidence for its own decision in `internal/`, which is never published. This
shipped record cites none: every statement in §2.3 can be re-measured with the test in §4.

## 7. Method note

Three errors of reasoning are worth avoiding, whatever the outcome:

- Testing a plausible stand-in instead of the mechanism the product uses.
- Treating "the stand-alone helper works" as proof that the product uses it.
- Naming a root cause from one host. A root cause needs a host where the fault is absent as well
  as one where it is present.

The simplest direct test — a fresh session running `echo hi` — comes first.
