---
name: fleet-drift
description: Compare what is deployed on each reachable fleet host against this checkout. Use when the user asks whether hosts have drifted, whether a deploy landed everywhere, which hosts are behind, or for a fleet status check.
---

You are executing the fleet-drift check. The contract is `docs/OPERATIONS.md`
**Part 7, §7.2** (the `fleet-drift` row). Remedies are never improvised: a
host that was **never built** goes through §1.12 (the full rollout); a built
host that has **drifted or lags the repo** gets the deploy loop from the
repository `README.md`, *Working on this repository* — both printed for a
human, never run.

## Two checks first — they decide whether the answers below mean anything

**Is this a privileged session?** If the fleet policy path is a bind mount, every
deployed-vs-repository comparison here is against the ADMIN policy and any drift
you find is an artefact:

```bash
awk '$5 == "/etc/claude-code/managed-settings.json" \
     {print "PRIVILEGED SESSION - policy sha comparisons are invalid here"}' /proc/self/mountinfo
```

`make verify` (exit 2), `cc-healthcheck.sh [2]` and `cc-bump-audit.sh` A3/A7 all
detect this and say so. Do the same; do not report the difference as drift.

**Which peers are reachable?** Do not assume they are powered off — a state
register that says a host is down is a claim, and a host that has booted since
is reachable and ungoverned until someone looks.

The host list is site topology, so it lives in `config.sh` (`CC_FLEET_HOSTS`),
not here. An empty list is a failure to report, not a clean fleet:

```bash
. lib/cc-config.sh
[ -n "$CC_FLEET_HOSTS" ] || echo "CC_FLEET_HOSTS is empty in $CC_CONFIG_SOURCE - peer list UNKNOWN"
for h in $CC_FLEET_HOSTS; do
  (exec 3<>/dev/tcp/$h/22) 2>/dev/null && echo "$h ssh OPEN" || echo "$h unreachable"
done
```

Three states, never two: **governed**, **reachable-and-ungoverned** (the finding
— an ungoverned host mounting the same home-directory export), and **unreachable**.
Folding the middle one into "unreachable" is how a latent exposure stays
invisible after it has become an active one.

For **this** host (always reachable):

1. `make verify` — its exit contract is authoritative: 0 verified, 1 failed
   (any governance check — placement, ownership, mode, or drift), 2
   unverifiable from inside an admin session.
2. `sha256sum` of `/etc/claude-code/managed-settings.json` against
   `settings/managed-settings.json` here. A difference has **three** possible
   causes, not two: a pending `--apply`, real drift, or **you are in a privileged
   session and hashing the bind-mounted admin policy** (check that first, above).
   `make verify`'s output and `internal/CURRENT-STATE.md` distinguish the
   first two.
3. The same per hook: `sha256sum /usr/local/sbin/cc-*-hook.sh` against
   `hooks/` in this checkout — the §7.2 row promises hook *content* is
   diffed, and `make verify` checks presence and modes only.

For **other** hosts: the **fleet** policy denies outbound `ssh`, deliberately.
Do not work around it. Note the asymmetry honestly — an **admin** session's
policy does *not* deny `ssh`, so the fence is a rule you are keeping rather than
one that is holding you; keep it anyway, because reaching into an ungoverned host
from a privileged session is exactly the blast-radius this design refuses. Produce instead the exact read-only
command block a human runs per host (the three checks above, plus
`claude --version` vs `/etc/claude-code/approved-version`), ask them to
paste the output back, and diff it here.

Findings go to `internal/` (host names + drift state are group-only).

Report back with: per-host state (governed / drifted / unreachable /
awaiting-paste), and the remedy block for whatever is behind.
