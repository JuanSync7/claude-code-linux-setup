# aws/ — AMI and per-user VDI artifacts

*Directory map — one line per file and where it is documented in full. The
reasoning for all of it is [`docs/LOCAL-VS-AWS.md`](../docs/LOCAL-VS-AWS.md) §8;
nothing here restates it.*

> **[PLANNED] — design, not validation.** Nothing in this directory has run on an
> AMI or a VDI. Read the grading warning at the top of `docs/LOCAL-VS-AWS.md`
> before treating any of it as tested.

| File | Installs to | What it is |
| --- | --- | --- |
| `bin/cc-apply-posture.sh` | `/usr/local/sbin/` root:root 0750 | Boot-time policy selector. Picks `fleet` or `admin` from `$CC_ETC/posture`, verifies the staged policy against the checksum baked beside it, installs it atomically over `managed-settings.json`, and copies the baked checksum across as the drift baseline. **Fails closed to `fleet`**; fails the unit outright rather than leave no policy. Paths are env-with-default, like `cc-healthcheck.sh`, so the failure paths are testable off-host. `docs/LOCAL-VS-AWS.md` §8.1 |
| `systemd/claude-code-posture.service` | `/etc/systemd/system/` root:root 0644 | Oneshot running the selector after `cloud-config.service` (the stage that writes the posture file) and before `systemd-user-sessions.service`. Carries no `ConditionPathExists` on purpose — a failed condition reports SUCCESS. `docs/LOCAL-VS-AWS.md` §8.1 |
| `systemd/systemd-user-sessions.service.d/10-claude-code-posture.conf` | `/etc/systemd/system/systemd-user-sessions.service.d/` root:root 0644 | `Requires=` the posture unit, so a policy failure refuses interactive logins instead of allowing an ungoverned one. **Optional and fail-closed** — the file's own header carries the trade-off and the SSM break-glass precondition. Omit it to choose fail-open. `docs/LOCAL-VS-AWS.md` §8.1 |
| `sysctl.d/50-claude-code-userns.conf` | `/etc/sysctl.d/` root:root 0644 | `user.max_user_namespaces = 0`. Removes the unprivileged-userns bypass of the managed policy. Required on **every** VDI, and per §8.2 wanted on-prem too. `docs/LOCAL-VS-AWS.md` §8.2 |
| `sudoers.d/cc-admins-admin-session` | `/etc/sudoers.d/` root:root 0440 | The scoped grant: `%cc-admins` may run `cc-admin-session.sh` as root, `NOPASSWD:NOSETENV:`. **ADMIN AMI only.** Validate with `visudo -cf` before it takes effect. `docs/LOCAL-VS-AWS.md` §8.4 |

Nothing in `bin/cc-install.sh` or the `Makefile` installs this directory — the
on-prem installer does not know about VDIs. Until a bake vehicle exists
(`docs/LOCAL-VS-AWS.md` §7), the "Installs to" column is the only instruction and
it is prose, not code.

## Staging the two policies

`cc-apply-posture.sh` reads `$CC_SHARE/policies/`, which **nothing in this repo
creates**. The image build must stage both policies *and a checksum beside each*
— the checksum is what stops the selector certifying whatever happens to be
staged:

```bash
. lib/cc-config.sh               # from the checkout, so CC_SHARE is this site's
install -d -o root -g root -m 0755 $CC_SHARE/policies
install -o root -g root -m 0644 settings/managed-settings.json \
        $CC_SHARE/policies/managed-settings.fleet.json
install -o root -g root -m 0644 settings/managed-settings-admin.json \
        $CC_SHARE/policies/managed-settings.admin.json
cd $CC_SHARE/policies
for p in fleet admin; do sha256sum "managed-settings.$p.json" > "managed-settings.$p.json.sha256"; done
```

Generate the checksums **at bake time from the repo files**, never on the running
instance — a checksum minted on the instance certifies whatever is already there.

## Build-time checks that must pass on the first AMI

These belong in `docs/OPERATIONS.md` Part 2 as executable steps once a bake
vehicle is chosen; they are listed here because that section does not cover the
posture artifacts yet.

1. **`cc-preflight.sh` passes with `user.max_user_namespaces = 0`.** It judges the
   sysctl against the deployed policy: `0` is correct when the sandbox is
   disabled, and a hard blocker when it is enabled. With **no readable policy**
   it neither passes nor fails — it warns that the check did not run, and
   preflight exits non-zero only on a hard failure. So an image built before the
   policy is staged does not fail here; it simply leaves the question open, which
   is why the build order below puts the policy first.
2. **The OAuth browser still launches with userns off.** Browser sandboxes are
   userns-based, and `profile.d/claude-code-browser.*` detects whichever browser
   the image ships. Verify a real login opens a window; if not, install a setuid
   `chrome-sandbox` helper or launch the login browser `--no-sandbox`.
3. **`cc-admin-session.sh` enforces its target-user policy** before the sudoers
   rule ships — its header must carry the `TARGET-USER POLICY` block. Otherwise
   the scoped grant is equivalent to full root via `-u root`.
4. **SSM is installed and enrolled** if the `systemd-user-sessions` drop-in ships,
   or a posture failure is unrecoverable without instance replacement.
5. **`CC_EVAL_BIN` is re-pointed for the image.** A per-user path
   set for a shared host will not exist on a VDI; an admin AMI wanting `-e` needs a shared
   root-owned binary named there.
6. **`cc-admins` resolves.** If it does not, the `%cc-admins` sudoers rule denies
   first and the wrapper's own group gate is never reached — so diagnose sudo,
   not the wrapper. Note the wrapper authorises on `CC_ADMIN_USERS` **or** group
   membership, so an unemptied name list can mask an unresolved group.
7. **The posture unit ran and the baseline matches** — check
   `/var/log/claude-code/posture.log` and `cc-healthcheck.sh` §2.
