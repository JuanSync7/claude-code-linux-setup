# Claude Code in the IDE — VSCodium deployment method

| | |
| --- | --- |
| **What** | The method for putting Claude Code inside VSCodium on an engineer's desktop, and for making the editor use the version-pinned CLI rather than the copy the extension ships with |
| **Who** | Operators, for review and execution. Not an engineer-facing guide — engineers need only §7 |
| **When** | Against the **pinned build** (`requiredMinimumVersion`; `UPGRADES.md` for the history) and the Open VSX extension, whose bundled CLI version moves independently of the pin and can be **ahead** of it. Re-verify §3 and §6 at each version bump — probe M7 |
| **Where** | Machines where engineers run a graphical editor: shared Linux desktop hosts, and per-user AWS VDIs (`LOCAL-VS-AWS.md`). Not hosts used only for batch compute |
| **Why** | Engineers get the file tree and Claude in one window, which is most of the value. Delivering it centrally means the policy, the version and the settings are the same for everyone instead of however each person happened to install it |
| **Status** | **Method proposed, not yet executed.** The wrapper is written and unit-tested; no desktop has been built to this method |
| **Owner** | The maintainer |

---

## 1. The shape of it

VSCodium runs on the engineer's desktop. The Claude Code extension runs there
too, and drives a CLI on the same machine. Three things are therefore delivered
to every desktop:

```
dnf  ──▶ codium                       the editor
     ──▶ claude-code                  the CLI, version-pinned
repo ──▶ the control plane            the managed policy, hooks, and this wrapper —
                                      placed by cc-install.sh (§4 step 2)
```

The extension is installed from the **Open VSX registry**, where Anthropic
publish it as `Anthropic.claude-code` under a verified namespace. This matters
for VSCodium specifically: VSCodium cannot use Microsoft's marketplace, and Open
VSX is its default. No side-loading of a `.vsix` is required.

## 2. The problem this method exists to solve

**The extension does not use `claude` from `PATH`. It bundles its own CLI build
and runs that.** So on an unconfigured desktop, an engineer working in the
editor panel runs whatever CLI version the extension shipped with — not the one
`dnf` installed and `versionlock` pinned.

Be precise about what that does and does not mean, because the difference
decides how much of this needs enforcing:

| | Applies to the bundled CLI? |
| --- | --- |
| Managed policy — deny rules, `forceLoginMethod`, `autoMode` | **Yes.** `/etc/claude-code/managed-settings.json` is a compiled-in path in every Claude Code build |
| Hooks — every hook the policy registers | **Yes**, they are registered by that policy |
| Activity logging to `/var/log/claude-code/activity/` | **Yes** |
| The version pin — `versionlock`, `approved-version` | **No.** This is the entire gap |

So the exposure is **version drift, not policy escape**. An engineer using the
editor panel on an unconfigured desktop is still governed; they are just running
an unapproved build.

## 3. What is enforced, and what is only defaulted

This distinction is the one thing to carry into any conversation about this
method, because it is easy to overstate.

| Layer | Effect | Can an engineer undo it? |
| --- | --- | --- |
| `/etc/claude-code/managed-settings.json` | Deny rules, hooks, logging, login pin | **No.** Managed settings are the top precedence tier |
| `claude-code` RPM + `versionlock` | Pins the CLI on `PATH` | **No**, without root |
| Extension pre-installed in the image | Plugin present, no user action needed | Yes — they can uninstall it |
| `claudeCode.claudeProcessWrapper` seeded in defaults | Editor panel uses the pinned CLI | **Yes.** It is an ordinary user setting |

**VS Code and its forks have no managed-settings tier.** There is no
`/etc/vscodium/managed-settings.json` and no machine-wide enforced settings
layer. Editor settings can be *defaulted*, not *mandated*.

Version consistency in the editor is therefore a **default plus a detection
check**, not a control. See §8 for the accepted risk that follows, and §6 for
the check.

## 4. Prerequisite: the desktop must be a governed host

**Do not deploy the extension to a machine that has no managed policy.**

The policy is per-host — `/etc/claude-code` is a path compiled into the binary,
not something a client can be pointed at. A desktop with the extension but
without the control plane is an ungoverned Claude Code host with whatever the
desktop mounts — home directories, project storage — in reach: no deny rules,
no secret guard, no audit trail, full access to whatever data the site holds there.

So each desktop needs, in this order:

1. `claude-code` RPM installed and version-locked
2. the control plane placed — `bin/cc-install.sh --apply`
3. `bin/cc-healthcheck.sh` clean
4. *then* `codium` and the extension

There is no client-only mode. `LOCAL-VS-AWS.md` states the
underlying constraint: `claude` is per-host, not client/server, so no desktop
can point at a central Claude Code.

### The alternative, where a desktop cannot be governed

Run VSCodium on the ungoverned desktop but connect it to a governed host over
Remote-SSH, using `jeanp413.open-remote-ssh` from Open VSX. The extension host
and the CLI then run on the remote machine, under its policy, and the desktop
holds nothing but the editor UI.

This has an unverified assumption: that the Claude extension declares itself
workspace-side rather than UI-side. If it runs client-side, the CLI executes on
the desktop and the governance is not obtained. **Verify before relying on it**
— §6 step 4 is the test.

## 5. Deployment

Per desktop on shared hosts; baked into the machine image for a per-user VDI.

### 5.1 The editor

```bash
sudo tee /etc/yum.repos.d/vscodium.repo <<'EOF'
[gitlab.com_paulcarroty_vscodium_repo]
name=gitlab.com_paulcarroty_vscodium_repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF

sudo dnf install codium
```

`gpgcheck` and `repo_gpgcheck` are both on in the upstream instructions. Keep
them. This is a third-party community repository, which is a supply-chain
decision worth making consciously rather than by copy-paste — the packages are
built by the VSCodium project, not by Rocky or by Microsoft.

### 5.2 The extension, for every user on the machine

```bash
sudo -u <engineer> codium --install-extension Anthropic.claude-code
```

Extensions are per-user; there is no system-wide extension directory. For the
AMI, install it once into the image's skeleton user and let the image carry it.

### 5.3 Default settings for new accounts

`bin/cc-install.sh --apply --with-ide` seeds this file. By hand it is:

```bash
. /etc/claude-code/cc-config.sh     # CC_SKEL and CC_SHARE are this site's
sudo install -d -m 0755 $CC_SKEL/.config/VSCodium/User
sudo tee $CC_SKEL/.config/VSCodium/User/settings.json <<EOF
{
  "claudeCode.claudeProcessWrapper": "$CC_SHARE/cc-vscode-claude-wrapper.sh",
  "claudeCode.initialPermissionMode": "default"
}
EOF
sudo chmod 0644 $CC_SKEL/.config/VSCodium/User/settings.json
```

`initialPermissionMode` is not decoration. The extension documents that a
wrapped setup starts conversations in Manual mode, because it skips the settings
and built-in-default steps when a wrapper is present. Without this key every
conversation begins in Manual and engineers will ask why.

`/etc/skel` reaches **new accounts only** — the same limitation
`cc-install.sh` already carries for `/etc/skel/.claude/settings.json`. Existing
users need the same two keys added to
`~/.config/VSCodium/User/settings.json` once, by hand or by a one-off push.

### 5.4 The wrapper

Placed by `bin/cc-install.sh --apply` at
`/usr/local/share/claude-code/cc-vscode-claude-wrapper.sh`, `0755 root:root`.

It exists because `claudeProcessWrapper` names a *wrapper*, and the extension
passes the path of its own bundled binary as the first argument. Pointing the
setting straight at `/usr/bin/claude` does not work: the bundled path arrives as
`argv[1]` and is treated as a prompt. The wrapper drops that argument and execs
the managed binary with the rest.

If `/usr/bin/claude` is missing it warns on stderr and falls back to the bundled
binary rather than refusing to start. That trades version consistency — not
policy enforcement — for an editor that opens.

## 6. Verification

Do not infer which binary is running. Prove it.

1. **The extension is the official one.** In the Extensions view, publisher must
   read `Anthropic`, not a lookalike. Open VSX namespaces are not curated the
   way a first-party marketplace is.

2. **The wrapper is in effect.** Open the Claude panel, then on the host:
   ```bash
   pgrep -af 'cc-vscode-claude-wrapper|claude' | head
   ```
   Expect the wrapper in the ancestry and `/usr/bin/claude` as the running
   binary. If you see a path under `~/.vscode-oss/extensions/`, the setting has
   not taken effect.

3. **The version matches the pin.** In the panel, ask Claude to run
   `claude --version`, and compare with `cat /etc/claude-code/approved-version`.
   They must agree.

4. **The policy is loaded.** `/status` in the panel names the active managed
   settings source; `/permissions` should show the full fleet deny list
   (`SETTINGS-REFERENCE.md` §3.2), not the handful an unmanaged host would show. This is also the test
   for the Remote-SSH question in §4: run it over a Remote-SSH session and check
   *which host* the policy came from.

5. **The audit trail exists.** After a few tool calls,
   `/var/log/claude-code/activity/<user>.jsonl` must have grown. If the panel
   works but the log does not grow, the hooks are not firing and the deployment
   is not governed.

Record the results with `bin/cc-audit.sh` as the desktop's baseline.

## 7. What an engineer does

Open VSCodium. Files on the left, Claude on the right. Select lines and press
`Alt+K` to `@`-mention them with a line range. Claude proposes edits as inline
diffs to accept or reject.

Two things worth telling them, and no more:

- **Claude runs on this machine**, so it reaches what this machine reaches.
- **Some features are CLI-only.** For those, open the integrated terminal and
  run `claude`. That is the pinned binary and the same policy.

The engineer-facing guide is [`ENGINEER-GUIDE.md`](ENGINEER-GUIDE.md). This
section is not a substitute for it.

## 8. Accepted risk

**An engineer can remove `claudeProcessWrapper` from their own settings and
return the editor panel to the extension's bundled CLI.** Nothing prevents it;
VSCodium has no mandated-settings tier (§3).

The acceptance itself — acceptor, compensating controls and review trigger —
belongs in the risk register, `../internal/LIMITATIONS-AND-RISKS.md`. The basis
for accepting it:

- The managed policy still applies to the bundled build, so this is version
  drift, not policy escape (§2).
- With the editor delivered pre-configured, an engineer has no reason to touch
  the setting. The realistic path to it is deliberate action, not accident.
- **Stated position: change it and you own the consequences.** An engineer who
  repoints the extension away from the managed CLI is running an unapproved
  build and is responsible for that bundle — its version, its behaviour, and
  anything that follows. IT supports the pinned binary.
- It is detectable (§6) and reportable.

## 9. Known limits

- **No machine-wide editor settings tier.** §3. If enforcement is ever required,
  it needs a different mechanism — a login-time reconciler, or a policy check in
  the health check that raises a ticket.
- **Remote-SSH extension sidedness is unverified.** §4.
- **The Open VSX extension version and the pinned CLI version move
  independently,** and the extension's bundled CLI can be ahead of the fleet pin.
  This is why `requiredMaximumVersion` must stay absent from the policy: a
  ceiling at the pinned version would stop the bundled CLI starting, breaking
  the panel for anyone whose wrapper is not in effect. This constraint holds
  independently of the private comparison-install reason recorded against the key
  in `SETTINGS-REFERENCE.md` §3.11 — retiring such an install does not free the
  key while this method depends on its absence.
- **Third-party editor repository.** §5.1.
- **`codium` is not in the distribution's base repositories**, so a desktop
  build depends on reaching `paulcarroty.gitlab.io`. Egress from a VDI subnet is
  item 7 on the checklist in `LOCAL-VS-AWS.md` §6 and covers this too.
- **Not executed anywhere.** The wrapper is unit-tested against synthetic
  arguments; the method has not been run end to end on a real desktop.

## 10. Related

| Document | For |
| --- | --- |
| `SETTINGS-REFERENCE.md` | The managed policy key by key, including the version keys |
| `OPERATIONS.md` | Host build, version bumps, joiner/leaver |
| `../internal/CURRENT-STATE.md` | What is true of a site's hosts: what is deployed, and what is open |
| `../internal/LIMITATIONS-AND-RISKS.md` | The accepted-risk register, including the one in §8 |
| `LOCAL-VS-AWS.md` | How a per-user VDI differs from a shared host |
